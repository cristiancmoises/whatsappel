# SPDX-License-Identifier: AGPL-3.0-only
"""Actual Python HTTP diagnostics, not proof of the native Guile implementation."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import threading
import tempfile
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('doctor',ROOT/'scripts/doctor-performance.py')
doctor=importlib.util.module_from_spec(spec);spec.loader.exec_module(doctor)
TOKEN='private-fixture-token-do-not-log'
JID='private-fixture-chat'
NAME='private-fixture-name'
TEXT='private-fixture-message'

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        parsed=urlsplit(self.path);q=parse_qs(parsed.query)
        self.server.calls.append((self.command,parsed.path,q,self.headers.get('X-Whatsappel-Token')))
        if self.headers.get('X-Whatsappel-Token') != TOKEN:
            self.send_response(401);self.end_headers();return
        if self.server.redirect:
            self.send_response(302);self.send_header('Location',self.server.redirect);self.end_headers();return
        if self.server.malformed:
            self.send_response(200);self.end_headers();self.wfile.write(b'bad json '+TOKEN.encode());return
        if parsed.path=='/health':obj={'service':'whatsappel', 'read_api':2 if self.server.v2 else 1}
        elif parsed.path=='/chats':
            chats=[{'jid':JID,'name':NAME,'last':TEXT,'unread':7}]
            if not self.server.v2:obj=chats
            elif 'since' in q:obj={'version':2,'revision':self.server.revision,'unchanged':True}
            else:obj={'version':2,'revision':self.server.revision,'unchanged':False,'chats':chats}
        elif parsed.path=='/chat':
            if q.get('read')!=['0']:self.server.mark_read=True
            obj={'version':2,'revision':self.server.revision,'unchanged':'since' in q,'total':500,'limit':60}
            if 'since' not in q:obj['messages']=[{'id':str(i),'text':TEXT} for i in range(60)]
        else:self.send_response(404);self.end_headers();return
        raw=json.dumps(obj).encode();self.send_response(200);self.end_headers();self.wfile.write(raw)

class DoctorTests(unittest.TestCase):
    def setUp(self):
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        self.server.calls=[];self.server.v2=True;self.server.revision='epoch:1';self.server.redirect=None;self.server.malformed=False;self.server.mark_read=False
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.url='http://127.0.0.1:'+str(self.server.server_port)
    def tearDown(self):self.server.shutdown();self.server.server_close();self.thread.join(timeout=2)
    def test_real_http_roundtrip_has_no_writes_and_no_account_data_in_report(self):
        report=doctor.diagnose(self.url,TOKEN,rounds=2)
        text=json.dumps(report)
        for secret in [TOKEN,JID,NAME,TEXT,self.url,self.server.revision]:self.assertNotIn(secret,text)
        self.assertEqual(len(self.server.calls),7)
        self.assertTrue(all(c[0]=='GET' for c in self.server.calls))
        self.assertFalse(self.server.mark_read)
        self.assertEqual(report['retained_messages_in_sample_chat'],500)
        self.assertTrue(all(c[3]==TOKEN for c in self.server.calls))
    def test_legacy_never_reads_chat_or_marks_unread(self):
        self.server.v2=False;r=doctor.diagnose(self.url,TOKEN)
        self.assertEqual(r['read_api'],1);self.assertEqual(len(self.server.calls),2)
        self.assertFalse(any(c[1]=='/chat' for c in self.server.calls))
    def test_redirect_is_not_followed(self):
        self.server.redirect=self.url+'/forbidden'
        with self.assertRaises(doctor.DoctorError):doctor.diagnose(self.url,TOKEN)
        self.assertEqual(len(self.server.calls),1)
    def test_wrong_token_error_is_sanitized(self):
        with self.assertRaises(doctor.DoctorError) as error:doctor.diagnose(self.url,'bad-token')
        self.assertNotIn('bad-token',str(error.exception));self.assertIn('401',str(error.exception))
    def test_malformed_json_does_not_echo_response_or_secret(self):
        self.server.malformed=True
        with self.assertRaises(doctor.DoctorError) as error:doctor.diagnose(self.url,TOKEN)
        self.assertNotIn(TOKEN,str(error.exception))
    def test_disabled_environment_proxy(self):
        with mock.patch.dict(os.environ,{'http_proxy':'http://127.0.0.1:1','HTTP_PROXY':'http://127.0.0.1:1','ALL_PROXY':'http://127.0.0.1:1'}):
            self.assertEqual(doctor.diagnose(self.url,TOKEN,rounds=1)['read_api'],2)
    def test_token_is_rejected_before_network(self):
        for token in ['',None,'x\r\nInjected: yes','é','a\0']:
            with self.subTest(token=repr(token)),self.assertRaises(doctor.DoctorError):doctor.diagnose(self.url,token)
        self.assertFalse(self.server.calls)
    def test_remote_http_and_credential_urls_refused(self):
        for url in ['http://example.test','https://x:y@example.test','https://example.test/?secret=x','https://example.test/#x','https://example.test/path','https://example.test:0','file:///tmp/x','http://127.0.0.1\n']:
            with self.subTest(url=url),self.assertRaises(doctor.DoctorError):doctor.origin(url)
    def test_rounds_and_timeout_bounds(self):
        for rounds,timeout in [(0,10),(11,10),(True,10),(1,float('nan')),(1,61),(1,0)]:
            with self.subTest(rounds=rounds,timeout=timeout),self.assertRaises(doctor.DoctorError):doctor.diagnose(self.url,TOKEN,rounds,timeout)
        self.assertFalse(self.server.calls)
    def test_unchanged_must_match_previous_revision(self):
        with self.assertRaises(doctor.DoctorError):doctor.snapshot({'version':2,'revision':'other','unchanged':True},'chats','old')
    def test_schema_and_bounds_reject_invalid_success(self):
        for obj in [{},[],{'version':True}, {'version':2,'revision':'x','unchanged':False,'messages':[],'total':True,'limit':60},
                    {'version':2,'revision':'x','unchanged':False,'messages':[{}]*61,'total':80,'limit':60}]:
            with self.subTest(obj=str(obj)[:50]),self.assertRaises(doctor.DoctorError):doctor.snapshot(obj,'messages')
    def test_private_report_never_overwrites_an_existing_file(self):
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp)/'report.json';doctor.write_report(p,{'a':1})
            self.assertEqual(stat.S_IMODE(p.stat().st_mode),0o600)
            with self.assertRaises(doctor.DoctorError):doctor.write_report(p,{'a':2})
            self.assertEqual(json.loads(p.read_text()),{'a':1})
    def test_symlink_report_is_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            dest=Path(temp)/'existing';dest.write_text('retain');link=Path(temp)/'link';link.symlink_to(dest)
            with self.assertRaises(doctor.DoctorError):doctor.write_report(link,{})
            self.assertEqual(dest.read_text(),'retain')
    def test_response_limit(self):
        with mock.patch.object(doctor,'MAX_RESPONSE',8):
            with self.assertRaises(doctor.DoctorError):doctor.diagnose(self.url,TOKEN)

if __name__=='__main__':unittest.main()
