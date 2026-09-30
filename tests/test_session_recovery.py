# SPDX-License-Identifier: AGPL-3.0-only
"""Real worker subprocess/HTTP tests; no WhatsApp account or service is contacted."""
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]

def load_worker(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

@contextlib.contextmanager
def server(status=502, body=None, raw=None, extra=None):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def reply(self):
            self.server.calls.append((self.command, self.path))
            length = int(self.headers.get('Content-Length', '0'))
            if length:
                self.server.inputs.append(json.loads(self.rfile.read(length)))
            value = raw if raw is not None else json.dumps(body or {}).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            for k,v in (extra or {}).items():
                self.send_header(k,v)
            self.send_header('Content-Length',str(len(value)))
            self.end_headers()
            self.wfile.write(value)
        do_GET = reply
        do_POST = reply
    srv = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    srv.calls, srv.inputs = [], []
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    try:
        yield srv
    finally:
        srv.shutdown(); srv.server_close(); thread.join(timeout=3)

class SessionWorkerTests(unittest.TestCase):
    def worker(self, srv, path='/media-job?id=synthetic', payload=None, worker='read-worker.py'):
        spec = {'url':f'http://127.0.0.1:{srv.server_port}', 'token':'synthetic-token-not-a-secret',
                'path':path, 'timeout':3, 'max_bytes':1048576}
        if payload is not None:
            spec['payload']=payload
        run = subprocess.run([sys.executable, '-I', str(ROOT / 'scripts' / worker)],
                             input=json.dumps(spec), text=True, capture_output=True, timeout=6)
        self.assertNotIn('PRIVATE_PROVIDER_TEXT',run.stdout+run.stderr)
        self.assertNotIn('PRIVATE_JID',run.stdout+run.stderr)
        self.assertNotIn('PRIVATE_TOKEN',run.stdout+run.stderr)
        return run, json.loads(run.stdout)

    def test_media_job_keeps_provider_auth_without_private_error(self):
        with server(body={'wuzapi_status':401, 'data':{'error':'PRIVATE_PROVIDER_TEXT','jid':'PRIVATE_JID','token':'PRIVATE_TOKEN'}}) as srv:
            run,obj=self.worker(srv)
            self.assertEqual(run.returncode,0)
            self.assertEqual(obj['status'],502)
            self.assertEqual(obj['body']['wuzapi_status'],401)
            self.assertEqual(obj['body']['reason'],'provider-auth')
            self.assertEqual(srv.calls,[('GET','/media-job?id=synthetic')])

    def test_media_failure_categories(self):
        for status,reason in [(403,'provider-denied'),(404,'provider-unavailable'),(405,'provider-route'),
                              (410,'media-expired'),(429,'provider-busy'),(500,'media-provider'),(502,'media-provider')]:
            with self.subTest(status=status), server(body={'wuzapi_status':status}) as srv:
                _,obj=self.worker(srv)
                self.assertEqual(obj['body']['reason'],reason)
                self.assertEqual(obj['body']['wuzapi_status'],status)

    def test_media_failure_rejects_untyped_provider_status(self):
        for value in [True,'401',None,{},[],3,600]:
            with self.subTest(value=value), server(body={'wuzapi_status':value}) as srv:
                _,obj=self.worker(srv)
                self.assertNotIn('wuzapi_status',obj['body'])

    def test_media_error_duplicate_keys_are_not_trusted(self):
        with server(raw=b'{"wuzapi_status":401,"wuzapi_status":410,"error":"PRIVATE_PROVIDER_TEXT"}') as srv:
            _,obj=self.worker(srv)
            self.assertEqual(obj['status'],502)
            self.assertNotIn('wuzapi_status',obj['body'])

    def test_media_error_non_json_is_redacted(self):
        with server(raw=b'<h1>PRIVATE_PROVIDER_TEXT</h1>') as srv:
            _,obj=self.worker(srv)
            self.assertEqual(obj['status'],502)
            self.assertEqual(obj['body']['reason'],'media-provider')

    def test_media_error_bound(self):
        with server(raw=b'x'*70000) as srv:
            run,obj=self.worker(srv)
            self.assertEqual(run.returncode,1)
            self.assertIsNone(obj['status'])
            self.assertLess(len(run.stdout),1000)

    def test_media_error_redirect_is_never_followed(self):
        with server(status=302,extra={'Location':'http://127.0.0.1:9/private'},body={}) as srv:
            _,obj=self.worker(srv)
            self.assertEqual(obj['status'],302)
            self.assertEqual(len(srv.calls),1)

    def test_non_media_error_keeps_existing_redaction(self):
        with server(body={'wuzapi_status':401,'error':'PRIVATE_PROVIDER_TEXT'}) as srv:
            _,obj=self.worker(srv,path='/status')
            self.assertNotIn('wuzapi_status',obj['body'])
            self.assertEqual(obj['body']['error'],'Bridge read rejected; no redirect or retry was made.')

    def test_successful_media_unchanged(self):
        body={'wuzapi_status':200,'data':{'success':True,'data':{'Data':'data:image/png;base64,AA=='}}}
        with server(status=200,body=body) as srv:
            _,obj=self.worker(srv)
            self.assertEqual(obj['body'],body)

    def test_refresh_and_qr_are_bounded_get_routes(self):
        for path in ['/transport/status?refresh=1','/qr']:
            with self.subTest(path=path), server(status=200,body={'test':'synthetic'}) as srv:
                _,obj=self.worker(srv,path=path)
                self.assertEqual(obj['status'],200)
                self.assertEqual(srv.calls,[('GET',path)])

    def test_refresh_query_validation(self):
        read=load_worker('read-worker.py')
        for path in ['/transport/status?refresh=0','/transport/status?refresh=1&refresh=1',
                     '/qr?token=bad','/transport/connect','/transport/status?connect=1']:
            with self.subTest(path=path), self.assertRaises(read.ReadError):
                read.validate({'url':'http://127.0.0.1:7337','token':'fixture','path':path})

    def test_confirmed_connect_single_post_redacted(self):
        with server(status=202,body={'accepted':True,'extra':'PRIVATE_PROVIDER_TEXT'}) as srv:
            run,obj=self.worker(srv,path='/transport/connect',payload={'confirm':True},worker='send-worker.py')
            self.assertEqual(run.returncode,0)
            self.assertEqual(obj,{'status':202,'body':{'accepted':True}})
            self.assertEqual(srv.calls,[('POST','/transport/connect')])
            self.assertEqual(srv.inputs,[{'confirm':True}])

    def test_unconfirmed_connect_never_posts(self):
        for payload in [{},{'confirm':False},{'confirm':1},{'confirm':'true'},{'confirm':True,'logout':True}]:
            with self.subTest(payload=payload), server(status=202,body={'accepted':True}) as srv:
                run,obj=self.worker(srv,path='/transport/connect',payload=payload,worker='send-worker.py')
                self.assertNotEqual(run.returncode,0)
                self.assertEqual(srv.calls,[])

    def test_connect_202_is_job_acceptance_not_login(self):
        with server(status=200,body={'accepted':True,'connected':True}) as srv:
            run,obj=self.worker(srv,path='/transport/connect',payload={'confirm':True},worker='send-worker.py')
            self.assertIsNone(obj['status'])
            self.assertNotEqual(run.returncode,0)
            self.assertEqual(len(srv.calls),1)

    def test_connect_busy_is_not_retried(self):
        with server(status=429,body={'error':'PRIVATE_PROVIDER_TEXT'}) as srv:
            run,obj=self.worker(srv,path='/transport/connect',payload={'confirm':True},worker='send-worker.py')
            self.assertEqual(obj['body']['reason'],'transport-busy')
            self.assertEqual(obj['status'],429)
            self.assertEqual(len(srv.calls),1)

    def test_connect_refuses_redirects(self):
        with server(status=307,body={},extra={'Location':'http://127.0.0.1:9/wrong'}) as srv:
            run,obj=self.worker(srv,path='/transport/connect',payload={'confirm':True},worker='send-worker.py')
            self.assertEqual(len(srv.calls),1)
            self.assertNotEqual(run.returncode,0)


    def test_message_redirect_also_returns_structured_uncertainty(self):
        with server(status=307,body={},extra={'Location':'http://127.0.0.1:9/wrong'}) as srv:
            run,obj=self.worker(srv,path='/send/verified',payload={'to':'123456789@lid','body':'synthetic'},worker='send-worker.py')
            self.assertEqual(srv.calls,[('POST','/send/verified')])
            self.assertIsNone(obj['status'])
            self.assertNotIn('Traceback',run.stderr)
            self.assertNotEqual(run.returncode,0)


import shutil
import time
import test_bridge_http as base

@unittest.skipUnless(shutil.which('guile'), 'Guile required for native session integration')
class SessionHTTPTests(unittest.TestCase):
    for _name in ('setUpClass','stop_bridge','stop_backend','request','chats','messages','webhook','post_webhook'):
        locals()[_name]=base.BridgeHTTPTests.__dict__[_name]

    def setUp(self):
        self.wait_status()
        with self.backend.lock:
            self.backend.responses.clear()
            self.backend.responses['/session/status']=(200,{'success':True,'data':{'Connected':False,'LoggedIn':False}})
            self.backend.responses['/webhook']=(200,{'success':True,'data':{'webhook':'https://other.example/hook','subscribe':['Message','CustomEvent','Picture']}})
            self.backend.responses['/session/connect']=(200,{'success':True,'data':{'details':'PRIVATE_PROVIDER_TEXT'}})
        self.before=len(self.backend.matching_requests('/session/connect'))
        self.hook_before=len([r for r in self.backend.matching_requests('/webhook') if r[0]=='POST'])

    def wait_status(self):
        end=time.monotonic()+8
        while time.monotonic()<end:
            code,body,_=self.request('GET','/transport/status')
            if not body.get('checking'):
                return body
            time.sleep(.05)
        self.fail('transport operation did not finish')

    def connect(self):
        end=time.monotonic()+8
        while time.monotonic()<end:
            code,_,_=self.request('POST','/transport/connect',{'confirm':True})
            if code==202:
                return self.wait_status()
            self.assertEqual(code,429)
            time.sleep(.05)
        self.fail('could not start fixture operation')

    def assert_no_connect(self):
        self.assertEqual(len(self.backend.matching_requests('/session/connect')),self.before)

    def test_connect_preserves_subscriptions_and_callback(self):
        result=self.connect()
        self.assertEqual(result['connect_result'],'requested-check-status')
        calls=self.backend.matching_requests('/session/connect')
        self.assertEqual(len(calls),self.before+1)
        self.assertEqual(set(calls[-1][2]['Subscribe']),{'Message','CustomEvent','Picture','ReadReceipt'})
        self.assertIs(calls[-1][2]['Immediate'],True)
        self.assertEqual(len([r for r in self.backend.matching_requests('/webhook') if r[0]=='POST']),self.hook_before)
        self.assertEqual(result['session_state'],'disconnected')
        self.assertNotIn('PRIVATE_PROVIDER_TEXT',json.dumps(result))

    def test_auth_and_explicit_confirmation_before_connect(self):
        self.assertEqual(self.request('POST','/transport/connect',{'confirm':True},token=None)[0],401)
        for value in ({},{'confirm':False},{'confirm':1},{'confirm':True,'replace':True}):
            self.assertEqual(self.request('POST','/transport/connect',value)[0],400)
        self.assert_no_connect()

    def test_already_connected_is_not_connected_twice(self):
        self.backend.responses['/session/status']=(200,{'success':True,'data':{'connected':True,'loggedIn':True}})
        result=self.connect()
        self.assertEqual(result['connect_result'],'already-connected')
        self.assertEqual(result['session_state'],'ready')
        self.assert_no_connect()

    def test_logged_out_connected_session_requests_qr_not_reset(self):
        self.backend.responses['/session/status']=(200,{'success':True,'data':{'Connected':True,'LoggedIn':False}})
        result=self.connect()
        self.assertEqual(result['session_state'],'pairing-required')
        self.assert_no_connect()

    def test_conflicting_state_is_unknown_not_false(self):
        self.backend.responses['/session/status']=(200,{'success':True,'data':{'Connected':False,'connected':True,'LoggedIn':False}})
        result=self.connect()
        self.assertEqual(result['connect_result'],'status-unverified-no-connect')
        self.assertEqual(result['session_state'],'unknown')
        self.assert_no_connect()

    def test_missing_webhook_schema_refuses_connect(self):
        self.backend.responses['/webhook']=(200,{'success':True,'data':{'webhook':'','subscribe':'Message'}})
        result=self.connect()
        self.assertEqual(result['connect_result'],'subscriptions-unverified-no-connect')
        self.assert_no_connect()

    def test_rejected_token_never_connects(self):
        self.backend.responses['/session/status']=(401,{'error':'PRIVATE_PROVIDER_TEXT'})
        result=self.connect()
        self.assertEqual(result['session_state'],'authentication-required')
        self.assert_no_connect()

    def test_rejected_connect_is_not_retried(self):
        self.backend.responses['/session/connect']=(500,{'error':'PRIVATE_PROVIDER_TEXT'})
        result=self.connect()
        self.assertEqual(result['connect_result'],'unconfirmed-no-automatic-retry')
        self.assertEqual(len(self.backend.matching_requests('/session/connect')),self.before+1)

if __name__=='__main__':
    unittest.main()
