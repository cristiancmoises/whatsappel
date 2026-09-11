#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Bounded profile enrichment, never a message sender.

Private control arrives on stdin. Bridge credentials are never sent to the photo
CDN. A CDN address is resolved once, checked, and used directly with TLS SNI and
certificate validation for the original hostname. Photo output is a small PNG
produced by an owned, limited FFmpeg process, not the original untrusted image.
"""
from __future__ import annotations

import base64
import http.client
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import time
from urllib.parse import urlencode, urlsplit


def _local(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


read = _local('whatsappel_profile_read', 'read-worker.py')
protocol = read.protocol
Error = protocol.ProtocolError
MAX_CONTROL = 16384
MAX_JSON = 65536
MAX_IMAGE = 2 * 1024 * 1024
MAX_PNG = 300000
JID = re.compile(r'(?:[0-9]{3,30}(?:@(?:s\.whatsapp\.net|lid))?|[0-9]{3,30}(?:-[0-9]{1,20})?@g\.us)\Z')
CDN_HOSTS = frozenset({'pps.whatsapp.net'})
ACTIONS = frozenset({'capabilities', 'snapshot', 'avatar', 'photo', 'about', 'subscribe'})


def jid(value):
    if not isinstance(value, str) or not JID.fullmatch(value):
        raise Error('Unsupported contact identity; use a phone JID, LID or group JID.')
    return value[:-15] if value.endswith('@s.whatsapp.net') else value


def validate(spec):
    if not isinstance(spec, dict) or set(spec) - {'url', 'token', 'action', 'jid', 'jids', 'consent', 'timeout'}:
        raise Error('Invalid profile control.')
    action = spec.get('action')
    if action not in ACTIONS:
        raise Error('Unsupported profile operation.')
    # Reuse the existing origin/token/deadline validator, not a second policy.
    origin, _, token, seconds, _ = read.validate({
        'url': spec.get('url'), 'token': spec.get('token'), 'path': '/health',
        'timeout': spec.get('timeout', 20), 'max_bytes': MAX_JSON})
    if seconds > 30:
        raise Error('Profile deadlines are limited to 30 seconds.')
    if action == 'snapshot':
        values = spec.get('jids')
        if not isinstance(values, list) or not 1 <= len(values) <= 12:
            raise Error('A profile snapshot contains 1..12 contacts.')
        keys = [jid(x) for x in values]
        if len(set(keys)) != len(keys):
            raise Error('Duplicate profile identity.')
    elif action != 'capabilities':
        key = jid(spec.get('jid'))
        if action == 'subscribe' and (spec.get('consent') is not True or key.endswith('@g.us')):
            raise Error('Presence subscription requires explicit consent and a direct contact.')
    return origin, token, seconds, action


def tls_context():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_default_certs()
    ctx.set_alpn_protocols(['http/1.1'])
    return ctx


def response_bytes(response, limit):
    """One bounded read; overall_deadline also bounds a continuously dripping peer."""
    lengths = response.headers.get_all('Content-Length', [])
    transfers = response.headers.get_all('Transfer-Encoding', [])
    if len(lengths) > 1 or len(transfers) > 1:
        raise Error('Ambiguous profile response framing.')
    if lengths and (not lengths[0].isascii() or not lengths[0].isdecimal()):
        raise Error('Invalid profile response length.')
    if transfers and (transfers[0].lower() != 'chunked' or lengths):
        raise Error('Unsupported profile transfer framing.')
    if response.getheader('Content-Encoding', 'identity').lower() not in {'identity', ''}:
        raise Error('Compressed profile HTTP responses are refused.')
    expected = int(lengths[0]) if lengths else None
    if expected is not None and expected > limit:
        raise Error('Profile response exceeds its byte limit.')
    raw = response.read(limit + 1)
    if len(raw) > limit or (expected is not None and len(raw) != expected):
        raise Error('Oversized or incomplete profile response.')
    return raw


def bridge_request(origin, token, method, path, body=None, timeout=10):
    """Internal fixed routes only. No redirects, environment proxies or retries."""
    if method == 'POST':
        if path != '/profile/request':
            raise Error('Unsupported profile write route.')
    elif method != 'GET' or urlsplit(path).path not in {'/profile/capabilities', '/profiles', '/profile/job'}:
        raise Error('Unsupported profile read route.')
    if origin.scheme == 'https':
        conn = http.client.HTTPSConnection(origin.hostname, origin.port, timeout=timeout, context=tls_context())
    else:
        conn = http.client.HTTPConnection(origin.hostname, origin.port, timeout=timeout)
    headers = {'X-Whatsappel-Token': token, 'Accept': 'application/json',
               'Accept-Encoding': 'identity', 'Connection': 'close'}
    payload = None
    if body is not None:
        payload = json.dumps(body, separators=(',', ':')).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    try:
        conn.request(method, path, body=payload, headers=headers)
        with conn.getresponse() as res:
            # Do not return upstream diagnostics/URLs/tokens in errors.
            if not 200 <= res.status < 300:
                return res.status, {'state': 'unsupported' if res.status in {404, 405, 501} else 'unavailable'}
            raw = response_bytes(res, MAX_JSON)
            data = protocol.decode_json(raw)
            if not isinstance(data, dict):
                raise Error('Profile reply must be an object.')
            return res.status, data
    finally:
        conn.close()


def validate_cdn_url(value):
    if (not isinstance(value, str) or len(value) > 8192
            or any(ord(c) <= 32 or ord(c) >= 127 or c == '\\' for c in value)
            or re.search(r'%(?![0-9a-fA-F]{2})', value)):
        raise Error('Invalid photo location.')
    try:
        url = urlsplit(value)
        if (url.scheme != 'https' or url.hostname not in CDN_HOSTS or url.username is not None
                or url.password is not None or url.port not in {None, 443} or url.fragment
                or '#' in value or not url.path.startswith('/') or url.path.startswith('//')):
            raise ValueError()
    except ValueError:
        raise Error('Photo provider is not supported by the CDN policy.') from None
    return url


def public_address(value):
    ip = ipaddress.ip_address(value)
    if not ip.is_global or ip.is_multicast or ip.is_unspecified or ip.is_loopback or ip.is_link_local:
        return False
    if ip.version == 6:
        # No mapped, translation or transition address may hide a private IPv4.
        if ip.ipv4_mapped or ip.sixtofour or ip.teredo or ip in ipaddress.ip_network('64:ff9b::/96'):
            return False
    return True


def resolve_cdn(host):
    rows = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP)
    if not rows or len(rows) > 64:
        raise Error('Photo DNS answer unavailable or oversized.')
    for family, socktype, proto, _, addr in rows:
        if family not in {socket.AF_INET, socket.AF_INET6} or not public_address(addr[0]):
            raise Error('Photo DNS resolved to a prohibited address.')
    # Choose one vetted address, preferring IPv4. Never perform a second lookup.
    return sorted(rows, key=lambda row: row[0] != socket.AF_INET)[0]


class PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, hostname, address, timeout=8):
        super().__init__(hostname, 443, timeout=timeout, context=tls_context())
        self.address = address

    def connect(self):
        family, socktype, proto, _, addr = self.address
        raw = socket.socket(family, socktype, proto)
        try:
            raw.settimeout(self.timeout)
            raw.connect(addr)
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except BaseException:
            raw.close()
            raise


class PhotoFailure(Error):
    def __init__(self, reason):
        super().__init__('Photo unavailable')
        self.reason = reason


def fetch_photo(location):
    try:
        url = validate_cdn_url(location)
    except (Error, ValueError):
        raise PhotoFailure('cdn-policy') from None
    connection = PinnedHTTPS(url.hostname, resolve_cdn(url.hostname))
    try:
        path = url.path + ('?' + url.query if url.query else '')
        # This list deliberately contains NO bridge token, cookie or Referer.
        connection.request('GET', path, headers={'Accept': 'image/jpeg,image/png',
                           'Accept-Encoding': 'identity', 'Connection': 'close'})
        with connection.getresponse() as res:
            if res.status != 200:
                raise Error('Photo unavailable; redirects are not followed.')
            mime = res.getheader('Content-Type', '').split(';', 1)[0].strip().lower()
            if mime not in {'image/jpeg', 'image/png'}:
                raise Error('Unsupported photo media type.')
            raw = response_bytes(res, MAX_IMAGE)
            dimensions(raw, mime)
            return raw
    finally:
        connection.close()


def dimensions(raw, mime=None):
    """Validate a small raster header before handing bytes to the decoder."""
    width = height = None
    if raw.startswith(b'\x89PNG\r\n\x1a\n') and len(raw) >= 33 and raw[8:16] == b'\0\0\0\rIHDR':
        if mime not in {None, 'image/png'}:
            raise Error('Photo signature and MIME disagree.')
        width, height = struct.unpack('>II', raw[16:24])
    elif raw.startswith(b'\xff\xd8'):
        if mime not in {None, 'image/jpeg'}:
            raise Error('Photo signature and MIME disagree.')
        i = 2
        while i + 4 <= len(raw):
            if raw[i] != 255:
                break
            while i < len(raw) and raw[i] == 255:
                i += 1
            if i >= len(raw):
                break
            marker = raw[i]; i += 1
            if marker in {0xda, 0xd9}:
                break
            if marker in {0x01, *range(0xd0, 0xd8)}:
                continue
            size = int.from_bytes(raw[i:i+2], 'big')
            if size < 2 or i + size > len(raw):
                break
            if marker in {0xc0, 0xc1, 0xc2} and size >= 8:
                height, width = struct.unpack('>HH', raw[i+3:i+7]); break
            i += size
    if width is None or not 1 <= width <= 4096 or not 1 <= height <= 4096 or width * height > 4_000_000:
        raise Error('Photo is corrupt, unsupported or exceeds the canvas limit.')
    return width, height


def decoder_limits():
    resource.setrlimit(resource.RLIMIT_CPU, (4, 4))
    resource.setrlimit(resource.RLIMIT_AS, (1024 ** 3, 1024 ** 3))
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_PNG, MAX_PNG))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def thumbnail(raw, edge=96):
    if edge not in {96, 256} or not isinstance(raw, bytes) or len(raw) > MAX_IMAGE:
        raise Error('Invalid thumbnail request.')
    dimensions(raw)
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise Error('FFmpeg is required for profile thumbnails.')
    command = [ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error', '-threads', '1',
               '-protocol_whitelist', 'pipe', '-i', 'pipe:0', '-frames:v', '1', '-an',
               '-vf', f'scale={edge}:{edge}:force_original_aspect_ratio=decrease,pad={edge}:{edge}:(ow-iw)/2:(oh-ih)/2:color=black',
               '-threads', '1', '-f', 'image2pipe', '-vcodec', 'png', 'pipe:1']
    env = {k: v for k, v in os.environ.items() if k in {'PATH', 'LANG', 'LC_ALL', 'GUIX_LOCPATH'}}
    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=env, start_new_session=True,
                            preexec_fn=decoder_limits)
    try:
        out, _ = proc.communicate(raw, timeout=6)
        if proc.returncode or len(out) > MAX_PNG or dimensions(out, 'image/png') != (edge, edge):
            raise Error('Photo could not be safely prepared for display.')
        return out
    except subprocess.TimeoutExpired:
        raise Error('Photo decoding deadline exceeded.') from None
    finally:
        # Also executed when an outer overall_deadline interrupts communicate.
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        proc.wait(timeout=3)
        for stream in (proc.stdin, proc.stdout):
            if stream:
                stream.close()


def valid_epoch(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9.-]{1,160}', value) is not None


def validate_snapshot(data, keys):
    if type(data.get('version')) is not int or data.get('version') != 1 or not valid_epoch(data.get('epoch')) or not isinstance(data.get('profiles'), list) or len(data['profiles']) > 12:
        raise Error('Invalid profile snapshot.')
    seen = set()
    for p in data['profiles']:
        if not isinstance(p, dict) or p.get('jid') not in keys or p['jid'] in seen:
            raise Error('Unexpected profile in snapshot.')
        seen.add(p['jid'])
        if p.get('availability') not in {'unknown', 'online', 'offline'} or p.get('activity') not in {'none', 'typing', 'recording'}:
            raise Error('Unsupported presence state.')
        if not {'availability_age', 'activity_age', 'photo_revision'} <= set(p):
            raise Error('Incomplete profile metadata.')
        if 'last_seen' in p and (p['availability'] != 'offline' or type(p['last_seen']) is not int or p['last_seen'] <= 0 or p['last_seen'] > int(time.time())):
            raise Error('Unsubstantiated last-seen timestamp.')
        for field in ('availability_age', 'activity_age', 'last_seen', 'photo_revision'):
            if field in p and (type(p[field]) is not int or not 0 <= p[field] <= 4102444800):
                raise Error('Invalid profile timestamp or revision.')
        if p.get('photo_state') not in {'unknown', 'changed', 'removed', 'unavailable'}:
            raise Error('Invalid photo state.')
    if seen != set(keys):
        raise Error('Incomplete profile snapshot.')
    fields = {'jid', 'availability', 'availability_age', 'activity', 'activity_age', 'photo_revision', 'photo_state', 'last_seen'}
    return {'version': 1, 'epoch': data['epoch'],
            'profiles': [{k: v for k, v in p.items() if k in fields} for p in data['profiles']]}


def execute(spec):
    origin, token, seconds, action = validate(spec)
    with protocol.overall_deadline(seconds):
        if action == 'capabilities':
            status, body = bridge_request(origin, token, 'GET', '/profile/capabilities', timeout=seconds)
            if status == 200 and (type(body.get('version')) is not int or body.get('version') != 1 or not valid_epoch(body.get('epoch'))):
                raise Error('Unsupported profile API version.')
            if status == 200:
                body = {'version': 1, 'epoch': body['epoch'], 'avatar': 'probe-on-request',
                        'presence': 'observed-events', 'subscribe': 'explicit-consent',
                        'remote_idle': False, 'stories': False}
            return status, body
        if action == 'snapshot':
            keys = [jid(x) for x in spec['jids']]
            status, body = bridge_request(origin, token, 'GET', '/profiles?' + urlencode({'jids': ','.join(keys)}), timeout=seconds)
            if status == 200:
                body = validate_snapshot(body, keys)
            return status, body
        key = jid(spec['jid'])
        payload = {'jid': key, 'kind': action}
        if action == 'subscribe':
            payload['consent'] = True
        status, body = bridge_request(origin, token, 'POST', '/profile/request', payload, timeout=seconds)
        if status != 202:
            return status, body
        job = body.get('job')
        if not isinstance(job, str) or not re.fullmatch(r'[a-zA-Z0-9:-]{1,160}', job):
            raise Error('Invalid profile job identifier.')
        while status == 202:
            time.sleep(.2)
            status, body = bridge_request(origin, token, 'GET', '/profile/job?' + urlencode({'id': job}), timeout=seconds)
        if status != 200:
            return status, body
        if body.get('state') not in {'ready', 'unavailable', 'unsupported', 'stale', 'subscribed'}:
            raise Error('Invalid profile job result.')
        if body['state'] in {'ready', 'subscribed'} and not valid_epoch(body.get('epoch')):
            raise Error('Missing profile generation.')
        if action in {'avatar', 'photo'} and body['state'] == 'ready':
            if type(body.get('photo_revision')) is not int or not 0 <= body['photo_revision'] <= 4102444800:
                raise Error('Invalid photo revision.')
            try:
                raw_photo = fetch_photo(body.get('url'))
            except PhotoFailure:
                raise
            except (Error, OSError, ValueError, http.client.HTTPException):
                raise PhotoFailure('cdn-network') from None
            if not shutil.which('ffmpeg'):
                raise PhotoFailure('decoder-unavailable')
            try:
                png = thumbnail(raw_photo, 256 if action == 'photo' else 96)
            except (Error, OSError, ValueError, subprocess.SubprocessError):
                raise PhotoFailure('decoder-failed') from None
            return 200, {'state': 'ready', 'jid': key, 'photo_revision': body.get('photo_revision', 0),
                         'epoch': body['epoch'], 'png': base64.b64encode(png).decode('ascii')}
        # Never echo a signed URL, arbitrary upstream response or diagnostic.
        result = {'state': body['state'], 'jid': key, 'epoch': body.get('epoch')}
        if body.get('reason') in {'provider-route', 'provider-rejected'}:
            result['reason'] = body['reason']
        if type(body.get('provider_http')) is int and 100 <= body['provider_http'] <= 599:
            result['provider_http'] = body['provider_http']
        if action == 'about' and body['state'] == 'ready':
            text = body.get('about')
            if not isinstance(text, str) or len(text) > 1024:
                raise Error('Invalid About text.')
            result['about'] = text
        return 200, result


def main():
    # Emacs cancellation must unwind owned decoder cleanup instead of abandoning it.
    def cancelled(_signum, _frame):
        raise SystemExit(1)
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, cancelled)
    try:
        raw = sys.stdin.buffer.read(MAX_CONTROL + 1)
        if len(raw) > MAX_CONTROL:
            raise Error('Profile control exceeded its byte limit.')
        status, body = execute(protocol.decode_json(raw))
        sys.stdout.write(json.dumps({'status': status, 'body': body}, ensure_ascii=True) + '\n')
        return 0
    except PhotoFailure as exc:
        sys.stdout.write(json.dumps({'status': None, 'body': {'state': 'unavailable',
                          'reason': exc.reason, 'error': 'Profile unavailable; no message was sent.'}}) + '\n')
        return 1
    except (Error, OSError, ValueError, TypeError, KeyError, http.client.HTTPException, subprocess.SubprocessError):
        # Do not leak signed URLs, input identities, tokens, paths or exception args.
        sys.stdout.write('{"status":null,"body":{"state":"unavailable","reason":"worker-failed","error":"Profile unavailable; no message or presence announcement was sent."}}\n')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
