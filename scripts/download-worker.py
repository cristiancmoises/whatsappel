#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Submit one bounded media retrieval to the configured bridge, never a message.

Tokens arrive over stdin. Fixed routes, no redirects or environment proxies.
This returns the legacy bridge envelope so old and asynchronous media paths stay
compatible. Failed replies expose only allowlisted categories and status codes.
"""
from __future__ import annotations

import http.client
import importlib.util
import json
from pathlib import Path
import re
import socket
import ssl
import sys

_spec = importlib.util.spec_from_file_location('whatsappel_download_read', Path(__file__).resolve().with_name('read-worker.py'))
read = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(read)
Error = read.ReadError
MAX_CONTROL = 32768
MAX_REPLY = 24 * 1024 * 1024
FIELDS = {'kind', 'Url', 'DirectPath', 'MediaKey', 'Mimetype', 'FileSHA256', 'FileEncSHA256', 'FileLength'}
KINDS = {'image', 'video', 'gif', 'audio', 'document', 'sticker'}


def failure(status, upstream=None):
    reason = {401: 'bridge-auth', 403: 'bridge-auth', 404: 'bridge-route',
              405: 'bridge-route', 400: 'media-metadata', 413: 'media-limit',
              429: 'media-busy', 410: 'media-expired'}.get(status, 'media-provider')
    if status == 502 and type(upstream) is int:
        reason = {401: 'provider-auth', 403: 'provider-denied', 404: 'provider-unavailable',
                  405: 'provider-route', 410: 'media-expired', 429: 'provider-busy'}.get(upstream, reason)
    body = {'state': 'unavailable', 'reason': reason, 'error': 'Media retrieval failed; no message was sent.'}
    if type(upstream) is int and 100 <= upstream <= 599:
        body['wuzapi_status'] = upstream
    return {'status': status, 'body': body}


def validate(spec):
    if not isinstance(spec, dict) or set(spec) - {'url', 'token', 'path', 'payload', 'timeout', 'max_bytes'}:
        raise Error('Invalid media control.')
    path = spec.get('path')
    if path not in {'/download', '/download?async=1'}:
        raise Error('Unsupported media retrieval route.')
    url, _, token, seconds, _ = read.validate({**spec, 'path': '/health', 'max_bytes': 65536})
    limit = spec.get('max_bytes', MAX_REPLY)
    if type(limit) is not int or not 1 <= limit <= MAX_REPLY:
        raise Error('Invalid media response limit.')
    payload = spec.get('payload')
    if not isinstance(payload, dict) or set(payload) - FIELDS or payload.get('kind') not in KINDS:
        raise Error('Invalid media metadata.')
    for field in FIELDS - {'kind', 'FileLength'}:
        value = payload.get(field)
        maximum = 8192 if field in {'Url', 'DirectPath'} else 256
        if value is not None and (not isinstance(value, str) or len(value) > maximum
                                 or any(ord(c) < 32 or ord(c) == 127 for c in value)):
            raise Error('Invalid media metadata field.')
    length = payload.get('FileLength')
    if length is not None and not ((type(length) is int and 0 <= length <= 201326592)
                                   or (isinstance(length, str) and re.fullmatch(r'[0-9]{1,9}', length))):
        raise Error('Invalid media file length.')
    return url, path, token, seconds, limit, payload


def response_body(response, limit):
    lengths = response.headers.get_all('Content-Length', [])
    transfers = response.headers.get_all('Transfer-Encoding', [])
    if len(lengths) > 1 or len(transfers) > 1:
        raise Error('Ambiguous media response framing.')
    if lengths and (not lengths[0].isascii() or not lengths[0].isdecimal()):
        raise Error('Invalid media response length.')
    if transfers and (transfers[0].lower() != 'chunked' or lengths):
        raise Error('Ambiguous media response framing.')
    if response.getheader('Content-Encoding', 'identity').lower() not in {'identity', ''}:
        raise Error('Compressed media API response refused.')
    expected = int(lengths[0]) if lengths else None
    if expected is not None and expected > limit:
        raise Error('Media response limit exceeded.')
    raw = response.read(limit + 1)
    if len(raw) > limit or (expected is not None and len(raw) != expected):
        raise Error('Incomplete or oversized media response.')
    return read.decode_json(raw)


def execute(spec):
    url, path, token, seconds, limit, payload = validate(spec)
    if url.scheme == 'https':
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.load_default_certs()
        conn = http.client.HTTPSConnection(url.hostname, url.port, timeout=seconds, context=ctx)
    else:
        conn = http.client.HTTPConnection(url.hostname, url.port, timeout=seconds)
    try:
        with read.overall_deadline(seconds):
            conn.request('POST', path, json.dumps(payload, separators=(',', ':')).encode(),
                         {'X-Whatsappel-Token': token, 'Content-Type': 'application/json',
                          'Accept': 'application/json', 'Accept-Encoding': 'identity', 'Connection': 'close'})
            with conn.getresponse() as response:
                status = response.status
                if not 200 <= status < 300:
                    # Do not follow redirects or return remote error bodies. The
                    # integer provider status is the only permitted nested field.
                    upstream = None
                    if status == 502:
                        try:
                            body = response_body(response, 65536)
                            if isinstance(body, dict):
                                upstream = body.get('wuzapi_status')
                        except (Error, ValueError, http.client.HTTPException):
                            pass
                    return failure(status, upstream)
                body = response_body(response, limit)
                if not isinstance(body, dict):
                    raise Error('Media reply must be an object.')
                if status == 202 and (not isinstance(body.get('job'), str)
                                     or not re.fullmatch(r'[A-Za-z0-9:-]{1,159}', body['job'])):
                    raise Error('Invalid media job identifier.')
                return {'status': status, 'body': body}
    finally:
        conn.close()


def main():
    try:
        raw = sys.stdin.buffer.read(MAX_CONTROL + 1)
        if len(raw) > MAX_CONTROL:
            raise Error('Media control limit exceeded.')
        result = execute(read.decode_json(raw))
    except (read.protocol.DeadlineError, TimeoutError, socket.timeout):
        result = {'status': None, 'body': {'state': 'unavailable', 'reason': 'media-timeout'}}
    except (Error, OSError, ValueError, TypeError, KeyError, http.client.HTTPException):
        result = {'status': None, 'body': {'state': 'unavailable', 'reason': 'media-worker'}}
    sys.stdout.write(json.dumps(result, ensure_ascii=True, separators=(',', ':')) + '\n')
    return 0 if result['status'] is not None else 1


if __name__ == '__main__':
    raise SystemExit(main())
