#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Local WhatsAppel connection check; optional single received-image retrieval.

Only fixed bridge routes are permitted. No send, reconnect, repair, read receipt,
profile consent change or provider configuration write is supported. Raw replies,
credentials, media keys, contact identifiers and content are never saved/printed.
"""
from __future__ import annotations
import argparse
import base64
import contextlib
import datetime as dt
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import socket
import ssl
import stat
import sys
import tempfile
import time
from urllib.parse import parse_qsl, urlencode, urlsplit

MAX_JSON = 4 * 1024 * 1024
MAX_MEDIA = 24 * 1024 * 1024
SETTINGS = {'WHATSAPPEL_TOKEN', 'WHATSAPPEL_BRIDGE_URL', 'WHATSAPPEL_HOST',
            'WHATSAPPEL_PORT', 'WHATSAPPEL_PUBLIC_URL', 'WHATSAPPEL_LIDMAP_DB'}
MEDIA_FIELDS = {'Url', 'DirectPath', 'MediaKey', 'Mimetype', 'FileSHA256', 'FileEncSHA256', 'FileLength'}
LABELS = ('connection_state', 'login_state', 'callback_state', 'subscription_state',
          'presence_subscription_state', 'activity_subscription_state', 'picture_subscription_state')

class Stop(Exception):
    """Contains only an author-written constant, never an input value."""


def local_config(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as f:
            s = os.fstat(f.fileno())
            if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o077 or s.st_size > 65536:
                raise Stop('private-config-permissions')
            raw = f.read(65537)
    except OSError:
        raise Stop('private-config-unreadable') from None
    if len(raw) > 65536:
        raise Stop('private-config-too-large')
    result = {}
    try:
        for line in raw.decode('utf-8').splitlines():
            line = line.strip()
            if line.startswith('export '):
                line = line[7:].lstrip()
            key, sep, value = line.partition('=')
            key = key.strip()
            if not sep or key not in SETTINGS:
                continue
            if key in result:
                raise Stop('private-config-duplicate')
            words = shlex.split(value, comments=True)
            if len(words) != 1 or any(ord(c) < 32 or ord(c) == 127 or c in '`$' for c in words[0]):
                raise Stop('private-config-not-literal')
            result[key] = words[0]
    except (UnicodeError, ValueError):
        raise Stop('private-config-not-literal') from None
    return result


def select_account(settings, inherited):
    external = any(k in inherited for k in ('WHATSAPPEL_TOKEN', 'WHATSAPPEL_BRIDGE_URL'))
    chosen = inherited if external else settings
    token = chosen.get('WHATSAPPEL_TOKEN', '')
    if not token or token.startswith('CHANGE-ME') or len(token) > 4096 or any(not 33 <= ord(c) <= 126 for c in token):
        raise Stop('account-token-missing-or-invalid')
    origin = chosen.get('WHATSAPPEL_BRIDGE_URL')
    if not origin:
        host = chosen.get('WHATSAPPEL_HOST', '127.0.0.1')
        host = {'0.0.0.0':'127.0.0.1', '::':'::1', '[::]':'::1', '[::1]':'::1'}.get(host, host)
        port = chosen.get('WHATSAPPEL_PORT', '7337')
        if host not in {'127.0.0.1', 'localhost', '::1'} or not re.fullmatch(r'[0-9]{1,5}', port) or not 1 <= int(port) <= 65535:
            raise Stop('client-origin-needs-explicit-configuration')
        # The reverse callback PUBLIC_URL is never used as a client origin.
        if not external and 'WHATSAPPEL_PUBLIC_URL' in chosen and not any(k in chosen for k in ('WHATSAPPEL_HOST','WHATSAPPEL_PORT')):
            raise Stop('callback-url-is-not-client-origin')
        origin = 'http://' + ('[::1]' if host == '::1' else host) + ':' + port
    check_origin(origin)
    return origin.rstrip('/'), token, 'environment' if external else 'private-env'


def check_origin(origin):
    if not isinstance(origin, str) or len(origin) > 2048 or any(ord(c) <= 32 or ord(c) == 127 for c in origin):
        raise Stop('invalid-client-origin')
    try:
        u = urlsplit(origin)
        port = u.port
    except ValueError:
        raise Stop('invalid-client-origin') from None
    if (u.scheme not in {'http','https'} or not u.hostname or u.username is not None or u.password is not None
        or u.path not in {'','/'} or '?' in origin or '#' in origin or (port is not None and not 1 <= port <= 65535)
        or (u.scheme == 'http' and u.hostname not in {'127.0.0.1','localhost','::1'})):
        raise Stop('invalid-client-origin')
    return u


def route_allowed(method, path):
    u = urlsplit(path)
    if u.scheme or u.netloc or u.fragment or not path.startswith('/'):
        return False
    try:
        pairs = parse_qsl(u.query, keep_blank_values=True, strict_parsing=True, max_num_fields=6)
    except ValueError:
        return False
    p = dict(pairs)
    if len(p) != len(pairs): return False
    if method == 'POST': return u.path == '/download' and p == {'async':'1'}
    if method != 'GET': return False
    if u.path in {'/health','/profile/capabilities'}: return not p
    if u.path == '/transport/status': return not p or p == {'refresh':'1'}
    if u.path == '/chats': return p == {'v':'2'}
    if u.path == '/chat':
        return set(p) == {'jid','v','read','limit'} and p['v'] == '2' and p['read'] == '0' and p['limit'] == '60' and valid_jid(p['jid'])
    if u.path == '/media-job':
        return set(p) == {'id'} and re.fullmatch(r'[A-Za-z0-9:-]{1,159}', p['id']) is not None
    return False


def valid_jid(v):
    return isinstance(v, str) and re.fullmatch(r'(?:[0-9]{3,30}(?:@(?:s\.whatsapp\.net|lid))?|[0-9]{3,30}(?:-[0-9]{1,20})?@g\.us)',v) is not None


@contextlib.contextmanager
def deadline(seconds):
    def expire(_s, _f): raise Stop('request-deadline')
    old = signal.signal(signal.SIGALRM, expire)
    prior = signal.setitimer(signal.ITIMER_REAL, seconds)
    try: yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, *prior)
        signal.signal(signal.SIGALRM, old)


def parse_json(raw):
    def unique(items):
        d = {}
        for k,v in items:
            if k in d: raise Stop('duplicate-json-key')
            d[k]=v
        return d
    def bad(_): raise Stop('nonfinite-json')
    try:
        return json.loads(raw, object_pairs_hook=unique, parse_constant=bad)
    except (ValueError, UnicodeError, RecursionError):
        raise Stop('invalid-json-reply') from None


class Client:
    def __init__(self, origin, token):
        self.origin = check_origin(origin)
        self.token = token
        self.end = time.monotonic()+150
        self.downloads = 0

    def __call__(self, method, path, payload=None, limit=65536):
        if not route_allowed(method,path): raise Stop('forbidden-diagnostic-route')
        seconds = min(12, self.end-time.monotonic())
        if seconds <= 0: raise Stop('diagnostic-total-deadline')
        if method == 'POST':
            if self.downloads: raise Stop('only-one-download-per-run')
            self.downloads += 1
        u = self.origin
        if u.scheme == 'https':
            ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.load_default_certs()
            conn=http.client.HTTPSConnection(u.hostname,u.port,timeout=seconds,context=ctx)
        else:
            conn=http.client.HTTPConnection(u.hostname,u.port,timeout=seconds)
        try:
            with deadline(seconds):
                encoded=json.dumps(payload,separators=(',',':')).encode() if payload is not None else None
                if encoded is not None and len(encoded)>32768: raise Stop('metadata-limit')
                conn.request(method,path,body=encoded,headers={'X-Whatsappel-Token':self.token,
                    'Accept':'application/json','Accept-Encoding':'identity','Content-Type':'application/json','Connection':'close'})
                with conn.getresponse() as response:
                    status=response.status
                    if 300 <= status < 400: return status, {}
                    sizes=response.headers.get_all('Content-Length',[])
                    transfer=response.headers.get_all('Transfer-Encoding',[])
                    if len(sizes)>1 or len(transfer)>1 or (sizes and transfer): raise Stop('ambiguous-http-framing')
                    if sizes and (not sizes[0].isascii() or not sizes[0].isdecimal()): raise Stop('invalid-http-size')
                    if transfer and transfer[0].lower()!='chunked': raise Stop('invalid-http-encoding')
                    if response.getheader('Content-Encoding','identity').lower() not in ('','identity'): raise Stop('encoded-http-reply')
                    ceiling=limit if 200<=status<300 else 65536
                    size=int(sizes[0]) if sizes else None
                    if size is not None and size>ceiling: raise Stop('reply-size-limit')
                    raw=response.read(ceiling+1)
                    if len(raw)>ceiling or (size is not None and size!=len(raw)): raise Stop('incomplete-or-large-reply')
                    try: body=parse_json(raw) if raw else {}
                    except Stop:
                        if status>=400: return status, {}
                        raise
                    return status, body
        finally:
            conn.close()


def enum(v, choices): return v if isinstance(v,str) and v in choices else 'unknown'
def code(v): return v if type(v) is int and 100<=v<=599 else None

def safe_transport(body):
    body=body if isinstance(body,dict) else {}
    out={k:enum(body.get(k),{'yes','no','unknown'}) for k in LABELS}
    for k in ('connected','logged_in','checking','checked'):
        out[k]=body.get(k) if type(body.get(k)) is bool else None
    for k in ('status_http','webhook_http'): out[k]=code(body.get(k))
    out['session_state']=enum(body.get('session_state'), {'ready','disconnected','pairing-required','authentication-required','provider-unavailable','unknown'})
    age=body.get('checked_age')
    out['checked_age']=age if type(age) in (int,float) and math.isfinite(age) and 0<=age<=86400 else None
    return out


def timestamp(value):
    if isinstance(value,bool): return None
    try:
        if isinstance(value,(float,int)) or (isinstance(value,str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+)?',value)):
            v=float(value)
        else:
            date=dt.datetime.fromisoformat(value.replace('Z','+00:00'))
            if date.tzinfo is None: return None
            v=date.timestamp()
        return v if math.isfinite(v) else None
    except (ValueError,AttributeError,TypeError,OverflowError): return None


def metadata_summary(media):
    out={}
    for k in ('MediaKey','FileSHA256','FileEncSHA256'):
        value=media.get(k)
        out[k+'_present']=isinstance(value,str) and bool(value)
        try: valid=isinstance(value,str) and len(value)<257 and len(base64.b64decode(value,validate=True))==32
        except (ValueError,TypeError): valid=False
        out[k+'_is_base64_32_bytes']=valid
    out['Url_present']=isinstance(media.get('Url'),str) and bool(media['Url'])
    out['DirectPath_present']=isinstance(media.get('DirectPath'),str) and bool(media['DirectPath'])
    length=media.get('FileLength')
    if isinstance(length,str) and re.fullmatch(r'[0-9]{1,9}',length): length=int(length)
    out['declared_bytes']=length if type(length) is int and 0<=length<=201326592 else None
    return out


def reported_category(status, body):
    """Classify only reported failure text. Never return the original string."""
    upstream=code(body.get('wuzapi_status')) if isinstance(body,dict) else None
    messages=[]
    node=body
    for _ in range(4):
        if not isinstance(node,dict): break
        for k in ('error','message'):
            if isinstance(node.get(k),str): messages.append(node[k][:4096].lower())
        node=node.get('data')
    text=' '.join(messages)
    for name,terms in (
        ('reported-not-connected',('not connected','no active session','not logged in','logged out')),
        ('reported-integrity-or-decryption',('decrypt','hmac','hash mismatch','checksum mismatch','sha256 mismatch')),
        ('reported-missing-metadata',('media key','mediakey','directpath','url is required','missing url')),
        ('reported-upstream-not-found',('status code 404','status 404','404 not found')),
        ('reported-upstream-gone',('status code 410','status 410','410 gone')),
    ):
        if any(t in text for t in terms): return name
    n=upstream if upstream is not None else status
    return {401:'authentication',403:'permission-or-media-access',404:'route-or-media-not-found',
            405:'method-or-route',410:'gone',413:'size-limit',429:'busy',400:'metadata-rejected',
            500:'provider-internal',502:'upstream-transport-response-or-size-limit',503:'service-unavailable'}.get(n,'unclassified')


def download_summary(status, body):
    out={'bridge_http':code(status),'provider_http':code(body.get('wuzapi_status')) if isinstance(body,dict) else None,
         'failure_category':reported_category(status,body),'downloaded':False}
    node=body
    for _ in range(2): node=node.get('data') if isinstance(node,dict) else None
    uri=(node.get('Data') or node.get('data')) if isinstance(node,dict) else None
    if not 200<=status<300: return out
    if not isinstance(uri,str) or not uri.startswith('data:') or ';base64,' not in uri:
        out['failure_category']='successful-http-without-supported-data-uri'; return out
    prefix, payload=uri.split(';base64,',1)
    if len(payload)>MAX_MEDIA: out['failure_category']='data-uri-too-large'; return out
    try: image=base64.b64decode(payload,validate=True)
    except ValueError:
        out['failure_category']='invalid-base64-image'; return out
    if not image or len(image)>16*1024*1024:
        out['failure_category']='decoded-image-empty-or-too-large'; return out
    kind=('png' if image.startswith(b'\x89PNG\r\n\x1a\n') else 'jpeg' if image.startswith(b'\xff\xd8\xff')
          else 'gif' if image.startswith((b'GIF87a',b'GIF89a'))
          else 'webp' if image.startswith(b'RIFF') and image[8:12]==b'WEBP' else 'unrecognized')
    out.update(downloaded=True,decoded_bytes=len(image),image_header=kind,
               failure_category='none',graphical_render_tested=False)
    return out


def probe_recent_image(fetch, now=None, pause=time.sleep):
    """At most six cached chats, read=0, one received image younger than 48 hours."""
    now=time.time() if now is None else now
    status,body=fetch('GET','/chats?v=2',limit=MAX_JSON)
    if status!=200 or not isinstance(body,dict) or body.get('version')!=2 or not isinstance(body.get('chats'),list):
        return {'outcome':'v2-chat-list-unavailable','bridge_http':code(status)}
    choices=[]; checked=0
    for chat in body['chats'][:6]:
        jid=chat.get('jid') if isinstance(chat,dict) else None
        if not valid_jid(jid): continue
        path='/chat?'+urlencode({'jid':jid,'v':'2','read':'0','limit':'60'})
        st,obj=fetch('GET',path,limit=MAX_JSON); checked+=1
        if st!=200 or not isinstance(obj,dict) or obj.get('version')!=2: continue
        messages=obj.get('messages')
        if not isinstance(messages,list): continue
        for message in messages[:60]:
            if not isinstance(message,dict) or message.get('kind')!='image' or message.get('me') is not False: continue
            stamp=timestamp(message.get('ts')); media=message.get('media')
            if stamp is None or not -60<=now-stamp<=48*3600 or not isinstance(media,dict): continue
            choices.append((stamp,media))
    if not choices: return {'outcome':'no-received-image-in-bounded-48h-sample','chats_checked':checked}
    stamp, media=max(choices,key=lambda x:x[0])
    result={'chats_checked':checked,'age_seconds':max(0,int(now-stamp)),'metadata':metadata_summary(media)}
    if not result['metadata']['MediaKey_is_base64_32_bytes'] or not (result['metadata']['Url_present'] or result['metadata']['DirectPath_present']):
        result['outcome']='cached-download-metadata-incomplete'; return result
    length=result['metadata']['declared_bytes']
    if length is not None and length>16*1024*1024: result['outcome']='declared-image-exceeds-default-limit'; return result
    data={'kind':'image', **{k:v for k,v in media.items() if k in MEDIA_FIELDS}}
    status,body=fetch('POST','/download?async=1',data,limit=MAX_MEDIA)
    if status==202:
        job=body.get('job') if isinstance(body,dict) else None
        if not isinstance(job,str) or not re.fullmatch(r'[A-Za-z0-9:-]{1,159}',job):
            result['outcome']='invalid-job-response'; return result
        for _ in range(24):
            pause(.5)
            status,body=fetch('GET','/media-job?'+urlencode({'id':job}),limit=MAX_MEDIA)
            if status!=202: break
    if status==202: result['outcome']='download-job-still-pending'; return result
    result.update(download_summary(status,body)); result['outcome']='downloaded' if result['downloaded'] else 'download-failed'
    return result


def collect(fetch, probe=False, pause=time.sleep):
    report={'schema':1,'message_sent':False,'settings_changed':False,'read_receipt_requested':False,
            'media_probe_requested':probe,'media_saved':False,'gui_tested':False}
    status,health=fetch('GET','/health')
    report['bridge_http']=code(status)
    version=health.get('version') if isinstance(health,dict) else None
    report['bridge_version']=version if isinstance(version,str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-rc[0-9]+)?',version) else None
    if status!=200: report['stopped']='bridge-unavailable-or-unauthorized'; return report
    for attempt in range(16):
        status,body=fetch('GET','/transport/status?refresh=1' if attempt == 0 else '/transport/status')
        if status!=200 or not isinstance(body,dict) or body.get('checking') is not True: break
        pause(.5)
    report['transport_http']=code(status); report['transport']=safe_transport(body)
    status,body=fetch('GET','/profile/capabilities')
    report['profiles_http']=code(status)
    transport=report['transport']
    age=transport['checked_age']
    ready=(report['transport_http']==200 and transport['checked'] is True
           and transport['checking'] is False and age is not None and age<=45
           and transport['session_state']=='ready'
           and transport['connected'] is True and transport['logged_in'] is True)
    report['backend_ready_for_probe']=ready
    report['next_action']=('retry-one-recent-image' if ready else
        'open-connection-panel-in-emacs-and-check-selected-account')
    if probe:
        if not ready:
            report['media']={'outcome':'blocked-backend-session-not-verified-ready',
                             'download_attempted':False,'chats_checked':0}
        else:
            try: report['media']=probe_recent_image(fetch,pause=pause)
            except (Stop,OSError,ValueError,http.client.HTTPException) as err:
                report['media']={'outcome':str(err) if isinstance(err,Stop) else 'request-or-reply-failed'}
    return report


def write_report(output, report):
    output=Path(output).expanduser().absolute()
    parent=output.parent
    s=parent.stat()
    if parent.is_symlink() or not parent.is_dir() or s.st_uid!=os.getuid() or s.st_mode&0o077:
        raise Stop('report-directory-must-be-private-and-owned')
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(report,f,indent=2,ensure_ascii=True); f.write('\n'); f.flush(); os.fsync(f.fileno())
    return output


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=Path.home()/'whatsappel')
    parser.add_argument('--output',type=Path)
    parser.add_argument('--probe-recent-image',action='store_true')
    args=parser.parse_args()
    if os.geteuid()==0: raise Stop('run-as-normal-user-not-root')
    # Choose the account source before opening any file. A complete environment
    # must not depend on an unrelated .env; a partial environment still fails closed.
    external=any(k in os.environ for k in ('WHATSAPPEL_TOKEN','WHATSAPPEL_BRIDGE_URL'))
    settings={} if external else local_config(args.source/'.env')
    origin,token,selected=select_account(settings,os.environ)
    fetch=Client(origin,token)
    try:
        report=collect(fetch,args.probe_recent_image)
    except (Stop, OSError, ValueError, http.client.HTTPException) as err:
        report={'schema':1,'message_sent':False,'settings_changed':False,
                'read_receipt_requested':False,'media_probe_requested':args.probe_recent_image,
                'stopped':str(err) if isinstance(err,Stop) else 'bridge-connection-or-reply-failed'}
    report['config_source']=selected
    report['utc']=dt.datetime.now(dt.timezone.utc).isoformat()
    report['scope']='Selected terminal/.env account; not proof of the account loaded in Emacs.'
    report['notes']=['A registered callback is not proof of network reachability.',
                     'A successful download is not a graphical rendering test.']
    target=args.output
    if target is None:
        downloads=Path.home()/'Downloads'
        if not downloads.is_dir(): raise Stop('downloads-directory-missing')
        target=Path(tempfile.mkdtemp(prefix='whatsappel-session-check.',dir=downloads))/'report.json'
    write_report(target,report)
    print(json.dumps(report,indent=2))
    print('\nPrivate diagnostic report: '+str(target))

if __name__=='__main__':
    try: main()
    except KeyboardInterrupt: print('Interrupted. No message was sent.',file=sys.stderr); sys.exit(130)
    except Stop as err: print('Check stopped: '+str(err),file=sys.stderr); sys.exit(1)
    except Exception: print('Check stopped: local I/O or bridge response failed; private details omitted.',file=sys.stderr); sys.exit(1)
