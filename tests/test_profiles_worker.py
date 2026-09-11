# SPDX-License-Identifier: AGPL-3.0-only
"""Actual profile child/HTTP/raster tests. No external account or CDN is contacted."""
import base64
import contextlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import patch, MagicMock
import zlib

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('profile_worker', ROOT/'scripts/profile-worker.py')
w = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(w)
TOKEN = 'synthetic-profile-token-not-a-real-account'

def png(width=8, height=4):
    def chunk(kind, value):
        return struct.pack('>I',len(value))+kind+value+struct.pack('>I',zlib.crc32(kind+value)&0xffffffff)
    return (b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB',width,height,8,2,0,0,0))
            +chunk(b'IDAT',zlib.compress((b'\0'+b'\x24\x81\x96'*width)*height))+chunk(b'IEND',b''))

def metadata(key='123456789'):
    return {'version':1,'epoch':'fixture-1','profiles':[{'jid':key,'availability':'unknown','availability_age':100,
            'activity':'none','activity_age':100,'photo_revision':0,'photo_state':'unknown'}]}

def control(**changes):
    return {'url':'http://127.0.0.1:7337','token':TOKEN,'action':'capabilities','timeout':5,**changes}

class Server(ThreadingHTTPServer):
    daemon_threads=True
    def __init__(self):
        super().__init__(('127.0.0.1',0),Handler)
        self.requests=[]; self.custom=None; self.delay=0; self.drip=False

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*_): pass
    def do_POST(self): self.respond()
    def do_GET(self): self.respond()
    def respond(self):
        raw=self.rfile.read(int(self.headers.get('Content-Length','0')))
        self.server.requests.append((self.command,self.path,raw,dict(self.headers)))
        if self.headers.get('X-Whatsappel-Token') != TOKEN: status,obj=401,{}
        elif self.path=='/profile/capabilities': status,obj=200,{'version':1,'epoch':'fixture-1'}
        elif self.path.startswith('/profiles?'): status,obj=200,metadata()
        elif self.path=='/profile/request': status,obj=202,{'job':'123-456-789:1:profile'}
        elif self.path.startswith('/profile/job?'): status,obj=200,{'state':'ready','about':'Synthetic About · Olá', 'epoch':'fixture-1'}
        else: status,obj=404,{}
        if self.server.custom: status,obj=self.server.custom
        data=obj if isinstance(obj,bytes) else json.dumps(obj).encode()
        time.sleep(self.server.delay)
        try:
            self.send_response(status)
            self.send_header('Content-Length',str(len(data)));self.send_header('Content-Type','application/json')
            if 300<=status<400: self.send_header('Location','http://127.0.0.1:1/never')
            self.end_headers()
            if self.server.drip:
                for part in data:
                    self.wfile.write(bytes([part])); self.wfile.flush(); time.sleep(.08)
            else:self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError): pass

@contextlib.contextmanager
def server():
    srv=Server(); thread=threading.Thread(target=srv.serve_forever,daemon=True);thread.start()
    try:yield srv
    finally:srv.shutdown();srv.server_close();thread.join(timeout=2)

def child(srv,**options):
    return subprocess.run([sys.executable,'-I',str(ROOT/'scripts/profile-worker.py')],
        input=json.dumps(control(url=f'http://127.0.0.1:{srv.server_port}',**options)).encode(),
        capture_output=True,timeout=10)

class ControlTests(unittest.TestCase):
    def test_identity_normalization_preserves_lid_and_group(self):
        self.assertEqual(w.jid('123456@s.whatsapp.net'),'123456');self.assertEqual(w.jid('123456@lid'),'123456@lid')
        self.assertEqual(w.jid('123456-789@g.us'),'123456-789@g.us')
    def test_hostile_identities_refused(self):
        for value in ['../.env','123\n','12','123@foreign','+12345',True,None,'3'*31]:
            with self.subTest(value=value),self.assertRaises(w.Error):w.jid(value)
    def test_actions_allowlisted(self):
        for action in ['send','online','download','shell',None]:
            with self.assertRaises(w.Error):w.validate(control(action=action))
    def test_subscribe_needs_explicit_true_and_direct_contact(self):
        for consent in [False,None,'true',1]:
            with self.assertRaises(w.Error):w.validate(control(action='subscribe',jid='12345',consent=consent))
        with self.assertRaises(w.Error):w.validate(control(action='subscribe',jid='12345@g.us',consent=True))
        self.assertEqual(w.validate(control(action='subscribe',jid='12345',consent=True))[3],'subscribe')
    def test_snapshot_bounds_and_normalized_duplicates(self):
        for keys in [[],['123']*2,['123','123@s.whatsapp.net'],[str(1000+i) for i in range(13)]]:
            with self.assertRaises(w.Error):w.validate(control(action='snapshot',jids=keys))
    def test_cleartext_remote_origin_and_token_controls_refused(self):
        for kwargs in [{'url':'http://example.com'},{'token':'test\nOther: 1'},{'url':'https://u:pw@site.test'}]:
            with self.assertRaises(w.Error):w.validate(control(**kwargs))
    def test_unknown_control_field_and_long_deadline(self):
        for kwargs in [{'command':'whoami'},{'timeout':31}]:
            with self.assertRaises(w.Error):w.validate(control(**kwargs))
    def test_no_generic_proxy_route(self):
        origin,*_=w.validate(control())
        with self.assertRaises(w.Error):w.bridge_request(origin,TOKEN,'POST','/chat/send/text',{})

class SnapshotTests(unittest.TestCase):
    def test_unknown_not_offline_and_missing_lastseen(self):
        obj=w.validate_snapshot(metadata(),['123456789']);self.assertEqual(obj['profiles'][0]['availability'],'unknown')
        self.assertNotIn('last_seen',obj['profiles'][0])
    def test_invented_idle_rejected(self):
        obj=metadata();obj['profiles'][0]['availability']='idle'
        with self.assertRaises(w.Error):w.validate_snapshot(obj,['123456789'])
    def test_future_and_online_lastseen_rejected(self):
        for stamp in [-1,int(time.time())+1000,1]:
            obj=metadata();obj['profiles'][0]['last_seen']=stamp
            with self.assertRaises(w.Error):w.validate_snapshot(obj,['123456789'])
    def test_duplicates_wrong_account_and_missing_records(self):
        for profiles in [[],metadata()['profiles']*2,[{**metadata()['profiles'][0],'jid':'987654321'}]]:
            obj=metadata();obj['profiles']=profiles
            with self.assertRaises(w.Error):w.validate_snapshot(obj,['123456789'])
    def test_boolean_age_and_missing_epoch_rejected(self):
        obj=metadata();obj['profiles'][0]['availability_age']=True
        with self.assertRaises(w.Error):w.validate_snapshot(obj,['123456789'])
        obj=metadata();del obj['epoch']
        with self.assertRaises(w.Error):w.validate_snapshot(obj,['123456789'])

class CDNTests(unittest.TestCase):
    def test_exact_https_host_only(self):
        self.assertEqual(w.validate_cdn_url('https://pps.whatsapp.net/photo?v=1').hostname,'pps.whatsapp.net')
        for value in ['http://pps.whatsapp.net/p','https://pps.whatsapp.net.evil.test/p','https://x.pps.whatsapp.net/p',
                      'https://user:pw@pps.whatsapp.net/p','https://127.0.0.1/p','https://pps.whatsapp.net:8443/p',
                      'https://pps.whatsapp.net/p#secret','https://pps.whatsapp.net/%GG','https://pps.whatsapp.net//evil/p']:
            with self.subTest(url=value),self.assertRaises(w.Error):w.validate_cdn_url(value)
    def test_forbidden_addresses(self):
        for ip in ['127.0.0.1','10.0.0.1','169.254.169.254','224.0.0.1','::1','fc00::1','fe80::1','::ffff:8.8.8.8','64:ff9b::808:808']:
            self.assertFalse(w.public_address(ip),ip)
    def test_dns_mixed_public_private_refused(self):
        rows=[(socket.AF_INET,socket.SOCK_STREAM,6,'',('8.8.8.8',443)),(socket.AF_INET,socket.SOCK_STREAM,6,'',('127.0.0.1',443))]
        with patch.object(w.socket,'getaddrinfo',return_value=rows),self.assertRaises(w.Error):w.resolve_cdn('pps.whatsapp.net')
    def test_pin_uses_verified_address_and_original_tls_hostname(self):
        row=(socket.AF_INET,socket.SOCK_STREAM,6,'',('8.8.8.8',443)); raw=MagicMock();ctx=MagicMock()
        with patch.object(w,'tls_context',return_value=ctx),patch.object(w.socket,'socket',return_value=raw),patch.object(w.socket,'getaddrinfo',side_effect=AssertionError('second DNS lookup')):
            conn=w.PinnedHTTPS('pps.whatsapp.net',row);conn.connect()
        raw.connect.assert_called_once_with(('8.8.8.8',443));ctx.wrap_socket.assert_called_once_with(raw,server_hostname='pps.whatsapp.net')
    def test_cdn_get_never_contains_account_credentials(self):
        reply=MagicMock();reply.__enter__.return_value=reply;reply.status=200
        reply.getheader.side_effect=lambda name,default='': 'image/png' if name=='Content-Type' else default
        conn=MagicMock();conn.getresponse.return_value=reply
        with patch.object(w,'PinnedHTTPS',return_value=conn),patch.object(w,'resolve_cdn',return_value=()),patch.object(w,'response_bytes',return_value=png()):
            w.fetch_photo('https://pps.whatsapp.net/photo?signature=synthetic')
        headers=conn.request.call_args.kwargs['headers']
        self.assertEqual(set(headers),{'Accept','Accept-Encoding','Connection'});self.assertNotIn(TOKEN,str(conn.request.call_args))
    def test_cdn_redirect_no_follow(self):
        reply=MagicMock();reply.__enter__.return_value=reply;reply.status=302
        conn=MagicMock();conn.getresponse.return_value=reply
        with patch.object(w,'PinnedHTTPS',return_value=conn),patch.object(w,'resolve_cdn',return_value=()),self.assertRaises(w.Error):w.fetch_photo('https://pps.whatsapp.net/p')
        self.assertEqual(conn.request.call_count,1)
    def test_png_dimension_mime_and_signature_limits(self):
        self.assertEqual(w.dimensions(png()),(8,4))
        for data,mime in [(png(),'image/jpeg'),(png(4097,1),'image/png'),(b'<svg/>','image/png'),(png()[:25],'image/png')]:
            with self.assertRaises(w.Error):w.dimensions(data,mime)
    def test_real_thumbnail_preserves_original_and_bounds_output(self):
        if not shutil.which('ffmpeg'):self.skipTest('FFmpeg unavailable')
        source=png(80,40);copy=bytes(source)
        for edge in [96,256]:
            out=w.thumbnail(source,edge);self.assertEqual(w.dimensions(out),(edge,edge));self.assertLess(len(out),w.MAX_PNG)
        self.assertEqual(source,copy)
    def test_corrupt_raster_decode_is_rejected(self):
        if not shutil.which('ffmpeg'):self.skipTest('FFmpeg unavailable')
        with self.assertRaises(w.Error):w.thumbnail(png()[:33])

class RealHTTPTests(unittest.TestCase):
    def test_capability_child_one_read(self):
        with server() as srv:
            result=child(srv);self.assertEqual(result.returncode,0,result.stdout)
            self.assertEqual(json.loads(result.stdout)['body']['version'],1)
            self.assertEqual([(x[0],x[1]) for x in srv.requests],[('GET','/profile/capabilities')])
    def test_snapshot_child_is_read_only(self):
        with server() as srv:
            result=child(srv,action='snapshot',jids=['123456789']);self.assertEqual(result.returncode,0,result.stdout)
            self.assertTrue(all(x[0]=='GET' and x[1].startswith('/profiles?') for x in srv.requests))
            self.assertNotIn(TOKEN,result.stdout.decode())
    def test_about_one_post_then_job_read(self):
        with server() as srv:
            result=child(srv,action='about',jid='123456789');self.assertEqual(result.returncode,0,result.stdout)
            self.assertEqual(json.loads(result.stdout)['body']['about'],'Synthetic About · Olá')
            posts=[x for x in srv.requests if x[0]=='POST'];self.assertEqual(len(posts),1)
            self.assertEqual(json.loads(posts[0][2]),{'jid':'123456789','kind':'about'})
    def test_subscription_invalid_consent_sends_nothing(self):
        with server() as srv:
            result=child(srv,action='subscribe',jid='123456789');self.assertEqual(result.returncode,1)
            self.assertEqual(srv.requests,[])
    def test_busy_job_not_retried(self):
        with server() as srv:
            srv.custom=(429,{'state':'busy'});result=child(srv,action='avatar',jid='123456789')
            self.assertEqual(json.loads(result.stdout)['status'],429);self.assertEqual(len(srv.requests),1)
    def test_redirect_refused(self):
        with server() as srv:
            srv.custom=(302,{});result=child(srv)
            self.assertEqual(json.loads(result.stdout)['status'],302);self.assertEqual(len(srv.requests),1)
    def test_strict_json_duplicate_and_invalid_scalar(self):
        for raw in [b'{"version":0,"version":1}',b'{"version":1,"x":NaN}',b'{"version":1,"x":"\\ud800"}']:
            with server() as srv:
                srv.custom=(200,raw);result=child(srv);self.assertEqual(result.returncode,1)
    def test_oversized_reply_is_redacted(self):
        with server() as srv:
            srv.custom=(200,b'"'+TOKEN.encode()+b'x'*70000+b'"');result=child(srv)
            self.assertEqual(result.returncode,1);self.assertNotIn(TOKEN.encode(),result.stdout)
    def test_dripping_response_has_total_deadline(self):
        with server() as srv:
            srv.custom=(200,{'version':1,'epoch':'fixture-1','padding':'x'*100});srv.drip=True
            started=time.monotonic();result=child(srv,timeout=1)
            self.assertEqual(result.returncode,1);self.assertLess(time.monotonic()-started,3.5)
            self.assertEqual(len(srv.requests),1)
    def test_cdn_url_never_echoed_in_successful_avatar(self):
        replies=[(202,{'job':'fixture'}),(200,{'state':'ready','url':'https://pps.whatsapp.net/private?sig=secret','epoch':'fixture-1','photo_revision':0})]
        with patch.object(w,'bridge_request',side_effect=replies),patch.object(w,'fetch_photo',return_value=png()),patch.object(w,'thumbnail',return_value=png(96,96)),patch.object(w.time,'sleep'):
            status,body=w.execute(control(action='avatar',jid='123456789'))
        self.assertEqual(status,200);self.assertEqual(body['epoch'],'fixture-1');self.assertNotIn('url',body);self.assertNotIn('secret',json.dumps(body))

if __name__=='__main__':unittest.main()
