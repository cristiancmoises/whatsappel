# SPDX-License-Identifier: AGPL-3.0-only
"""Actual worker process + loopback HTTP; no live WhatsApp account."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT=Path(__file__).resolve().parents[1]
def load(name):
    s=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
protocol=load('bridge_protocol'); doctor=load('doctor-delivery'); launcher=load('launch-whatsappel'); send=load('send-worker')
GOOD={'wuzapi_status':200,'data':{'success':True,'data':{'Id':'fixture-id'}}}
class Fixture(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*a): pass
    def do_POST(self):
        raw=self.rfile.read(int(self.headers.get('Content-Length','0')))
        self.server.calls.append((self.path,json.loads(raw),self.headers.get('X-Whatsappel-Token')))
        payload=self.server.payload
        self.send_response(self.server.status)
        if self.server.status==302:self.send_header('Location',self.server.base+'/leak')
        self.send_header('Content-Length',str(len(payload))); self.end_headers()
        try:
            if self.server.slow:
                for byte in payload: self.wfile.write(bytes([byte]));self.wfile.flush();time.sleep(.08)
            else:self.wfile.write(payload)
        except (BrokenPipeError,ConnectionResetError):pass
class SendWorkerTests(unittest.TestCase):
    def setUp(self):
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Fixture);self.server.daemon_threads=True
        self.server.base=f'http://127.0.0.1:{self.server.server_port}';self.server.payload=json.dumps(GOOD).encode();self.server.status=200;self.server.calls=[];self.server.slow=False
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
    def tearDown(self): self.server.shutdown();self.server.server_close();self.thread.join(3)
    def run_worker(self,**changes):
        control={'url':self.server.base,'token':'fixture-only-token','timeout':2,'path':'/send','payload':{'to':'551100000001','body':'Olá 日本 🎵'}};control.update(changes)
        return subprocess.run([sys.executable,'-I',str(ROOT/'scripts/send-worker.py')],input=json.dumps(control),text=True,capture_output=True,timeout=8)
    def test_one_text_post_and_confirmed_id(self):
        p=self.run_worker();self.assertEqual(p.returncode,0,p.stderr);b=json.loads(p.stdout)['body'];self.assertEqual(b['message_id'],'fixture-id');self.assertEqual(b['delivery'],'accepted');self.assertEqual(len(self.server.calls),1);self.assertEqual(self.server.calls[0][1]['body'],'Olá 日本 🎵');self.assertNotIn('fixture-only-token',p.stdout+p.stderr)
    def test_lid_target_is_preserved_by_actual_worker(self):
        target = '123456789012345@lid'
        p = self.run_worker(payload={'to': target, 'body': 'synthetic LID fixture'})
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(len(self.server.calls), 1)
        self.assertEqual(self.server.calls[0][1]['to'], target)
        self.assertEqual(json.loads(p.stdout)['body']['delivery'], 'accepted')

    def test_lid_and_phone_are_not_merged_by_worker(self):
        for target in ('123456789012345@lid', '123456789012345@s.whatsapp.net', '123456789012345'):
            with self.subTest(target=target):
                p = self.run_worker(payload={'to': target, 'body': 'synthetic namespace fixture'})
                self.assertEqual(p.returncode, 0, p.stdout)
                self.assertEqual(self.server.calls[-1][1]['to'], target)
        self.assertEqual(len(self.server.calls), 3)

    def test_http_ok_without_message_id_is_uncertain(self):
        self.server.payload=b'{"wuzapi_status":200,"data":{"success":true}}';p=self.run_worker();self.assertNotEqual(p.returncode,0);self.assertTrue(json.loads(p.stdout)['body']['uncertain']);self.assertEqual(len(self.server.calls),1)
    def test_nested_failure_is_not_success(self):
        data=copy.deepcopy(GOOD);data['data']['data']['success']=False;self.server.payload=json.dumps(data).encode();self.assertNotEqual(self.run_worker().returncode,0)
    def test_duplicate_response_key_not_accepted(self):
        self.server.payload=b'{"wuzapi_status":500,"wuzapi_status":200,"data":{"data":{"Id":"x"}}}';self.assertNotEqual(self.run_worker().returncode,0)
    def test_redirect_is_not_followed(self):
        self.server.status=302;p=self.run_worker();self.assertNotEqual(p.returncode,0);self.assertEqual(len(self.server.calls),1)
    def test_slow_drip_is_bounded_one_post(self):
        self.server.slow=True;start=time.monotonic();p=self.run_worker(timeout=1);self.assertNotEqual(p.returncode,0);self.assertLess(time.monotonic()-start,4);self.assertEqual(len(self.server.calls),1)
    def test_error_body_and_token_not_reflected(self):
        self.server.status=500;self.server.payload=b'{"token":"PRIVATE_PROVIDER_SECRET"}';p=self.run_worker();self.assertNotIn('PRIVATE_PROVIDER_SECRET',p.stdout+p.stderr);self.assertEqual(len(self.server.calls),1)
    def test_oversized_reply(self):
        self.server.payload=b' '*65537;p=self.run_worker();self.assertNotEqual(p.returncode,0)
    def test_unsupported_path_does_not_post(self):
        p=self.run_worker(path='/logout');self.assertNotEqual(p.returncode,0);self.assertEqual(self.server.calls,[])
    def test_invalid_recipient_does_not_post(self):
        p=self.run_worker(payload={'to':'abc\nsecret','body':'text'});self.assertNotEqual(p.returncode,0);self.assertEqual(self.server.calls,[])
    def test_repair_requires_explicit_confirmation(self):
        p=self.run_worker(path='/transport/repair',payload={'replace':True});self.assertNotEqual(p.returncode,0);self.assertEqual(self.server.calls,[])
    def test_one_authorized_repair_post(self):
        self.server.status=202;self.server.payload=b'{"accepted":true}';p=self.run_worker(path='/transport/repair',payload={'confirm':True,'replace':False});self.assertEqual(p.returncode,0,p.stdout);self.assertEqual(len(self.server.calls),1)
class AcknowledgementTests(unittest.TestCase):
    def test_positive(self):self.assertEqual(protocol.accepted_message_id(GOOD),'fixture-id')
    def test_status_only(self):self.assertIsNone(protocol.accepted_message_id({'wuzapi_status':200}))
    def test_empty_data(self):self.assertIsNone(protocol.accepted_message_id({'wuzapi_status':200,'data':{'data':{}}}))
    def test_nested_rejections(self):
        for path in ((),('data',),('data','data')):
            for key,val in [('error',None),('success',False),('success','true')]:
                with self.subTest(path=path,key=key,val=val):
                    obj=copy.deepcopy(GOOD);n=obj
                    for part in path:n=n[part]
                    n[key]=val;self.assertIsNone(protocol.accepted_message_id(obj))
    def test_contradictory_ids(self):
        o=copy.deepcopy(GOOD);o['data']['data']['ID']='other';self.assertIsNone(protocol.accepted_message_id(o))
    def test_wrong_top_id(self):
        o=copy.deepcopy(GOOD);o['message_id']='other';self.assertIsNone(protocol.accepted_message_id(o))
    def test_invalid_identifiers(self):
        for value in ('',False,None,'x y','x\n','\x80','x'*257):
            with self.subTest(value=repr(value)):
                o=copy.deepcopy(GOOD);o['data']['data']['Id']=value;self.assertIsNone(protocol.accepted_message_id(o))
    def test_bad_status(self):
        for code in (True,'200',500,None):
            o=copy.deepcopy(GOOD);o['wuzapi_status']=code;self.assertIsNone(protocol.accepted_message_id(o))
class DeliveryDoctorTests(unittest.TestCase):
    def fixture(self,responses):
        calls=[]
        def get(base,token,path,timeout):calls.append(path);return responses[path]
        return get,calls
    def test_old_status_is_redacted(self):
        get,calls=self.fixture({'/health':{'status':200,'body':{'status':'ok'}},'/status':{'status':200,'body':{'data':{'data':{'connected':False,'loggedIn':True,'token':'PRIVATE','jid':'PRIVATE','webhook':'PRIVATE'}}}}})
        r=doctor.diagnose('http://127.0.0.1:7337','fixture',fetch=get);self.assertFalse(r['connected']);self.assertTrue(r['logged_in']);self.assertNotIn('PRIVATE',json.dumps(r));self.assertEqual(calls,['/health','/status'])
    def test_alias_conflict_unknown(self):self.assertIsNone(doctor.boolean_alias({'connected':True,'Connected':False},'connected','Connected'))
    def test_missing_status_unknown(self):self.assertEqual(doctor.redacted_status({'success':True}),{'connected':None,'logged_in':None})
    def test_new_report_no_raw_fields(self):
        get,calls=self.fixture({'/health':{'status':200,'body':{'transport_api':1,'version':'3.2.0-rc11'}},'/transport/status':{'status':200,'body':{'checking':False,'connected':True,'logged_in':True,'callback_state':'no','subscription_state':'yes','token':'PRIVATE','messages_ingested':5}}})
        r=doctor.diagnose('http://127.0.0.1:7337','fixture',fetch=get);self.assertEqual(r['callback_state'],'no');self.assertEqual(r['messages_ingested'],5);self.assertNotIn('PRIVATE',json.dumps(r));self.assertEqual(calls,['/health','/transport/status'])
    def test_polling_bounded_without_post(self):
        get,calls=self.fixture({'/health':{'status':200,'body':{'transport_api':1}},'/transport/status':{'status':200,'body':{'checking':True}}})
        r=doctor.diagnose('http://127.0.0.1:7337','fixture',fetch=get,pause=lambda _:None);self.assertTrue(r['checking']);self.assertEqual(len(calls),13)
    def test_unauthorized_health_no_other_calls(self):
        get,calls=self.fixture({'/health':{'status':401,'body':{'error':'PRIVATE'}}});r=doctor.diagnose('http://127.0.0.1:7337','fixture',fetch=get);self.assertEqual(calls,['/health']);self.assertNotIn('PRIVATE',json.dumps(r))
    def test_disallows_nonloopback_http(self):
        with self.assertRaises(Exception):doctor.diagnose('http://example.com','fixture')
class ClientOriginTests(unittest.TestCase):
    def test_callback_never_used_as_client(self):
        with self.assertRaises(ValueError):launcher.client_origin({'WHATSAPPEL_PUBLIC_URL':'https://callback.example'})
    def test_host_port_pair(self):self.assertEqual(launcher.client_origin({'WHATSAPPEL_HOST':'0.0.0.0','WHATSAPPEL_PORT':'9999'}),'http://127.0.0.1:9999')
    def test_explicit_client_over_callback(self):self.assertEqual(launcher.client_origin({'WHATSAPPEL_BRIDGE_URL':'https://api.example','WHATSAPPEL_PUBLIC_URL':'https://callback.example'}),'https://api.example')
    def test_bad_bind_host_not_silently_used(self):
        with self.assertRaises(ValueError):launcher.client_origin({'WHATSAPPEL_HOST':'192.168.1.1'})
    def test_ipv6(self):self.assertEqual(launcher.client_origin({'WHATSAPPEL_HOST':'::','WHATSAPPEL_PORT':'7337'}),'http://[::1]:7337')
