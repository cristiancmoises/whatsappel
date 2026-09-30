# SPDX-License-Identifier: AGPL-3.0-only
"""Real worker/HTTP deadline regressions; synthetic data and no WhatsApp account."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]

def load(name):
    spec = importlib.util.spec_from_file_location('rc20_' + name.replace('-', '_'), ROOT/'scripts'/(name+'.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

doctor = load('doctor-session')
protocol = load('bridge_protocol')

@contextlib.contextmanager
def endpoint(drip=False):
    calls = []
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_POST(self): self.handle_request()
        def do_GET(self): self.handle_request()
        def handle_request(self):
            calls.append((self.command, self.path))
            if self.command == 'POST':
                self.rfile.read(int(self.headers.get('Content-Length', '0')))
            if drip:
                raw = b'{' + b' '*50 + b'"private":"PRIVATE_PROVIDER_TEXT"}'
            elif self.path == '/health':
                raw = json.dumps({'version': '3.2.0-rc19'}).encode()
            elif self.path.startswith('/transport/status'):
                raw = json.dumps({'checked':True, 'checking':False, 'checked_age':0,
                                  'connected':False, 'logged_in':False, 'session_state':'disconnected'}).encode()
            else: raw = b'{}'
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            try:
                if drip:
                    for b in raw:
                        self.wfile.write(bytes([b])); self.wfile.flush(); time.sleep(.08)
                else: self.wfile.write(raw)
            except (BrokenPipeError, ConnectionResetError, OSError): pass
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try: yield 'http://127.0.0.1:'+str(server.server_port), calls
    finally: server.shutdown(); server.server_close(); thread.join(2)

@unittest.skipUnless(hasattr(signal, 'setitimer'), 'POSIX deadline timers required')
class WorkerDeadlineTests(unittest.TestCase):
    def run_worker(self, filename, control):
        with endpoint(drip=True) as (url, calls):
            start = time.monotonic()
            result = subprocess.run([sys.executable, '-I', str(ROOT/'scripts'/filename)],
                input=json.dumps({'url':url, 'token':'synthetic-token', 'timeout':1, **control}),
                text=True, capture_output=True, timeout=5)
            elapsed = time.monotonic()-start
            self.assertLess(elapsed, 3.5)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('PRIVATE_PROVIDER_TEXT', result.stdout+result.stderr)
            self.assertNotIn('synthetic-token', result.stdout+result.stderr)
            self.assertNotIn('Traceback', result.stderr)
            self.assertEqual(len(calls), 1)
            out = json.loads(result.stdout)
            self.assertIsNone(out['status'])
            return out, calls
    def test_download_wall_deadline_has_timeout_category(self):
        out,calls=self.run_worker('download-worker.py', {'path':'/download?async=1', 'payload':{'kind':'image'}})
        self.assertEqual(out['body']['reason'], 'media-timeout')
        self.assertEqual(calls, [('POST','/download?async=1')])
    def test_media_poll_deadline_has_timeout_category(self):
        out,calls=self.run_worker('read-worker.py', {'path':'/media-job?id=fixture'})
        self.assertEqual(out['body'].get('reason'), 'media-timeout')
        self.assertEqual(calls, [('GET','/media-job?id=fixture')])
    def test_session_read_deadline_has_read_timeout_category(self):
        out,calls=self.run_worker('read-worker.py', {'path':'/transport/status'})
        self.assertEqual(out['body'].get('reason'), 'read-timeout')
        self.assertEqual(calls, [('GET','/transport/status')])
    def test_profile_deadline_has_worker_timeout_category(self):
        out,calls=self.run_worker('profile-worker.py', {'action':'capabilities'})
        self.assertEqual(out['body']['reason'], 'worker-timeout')
        self.assertEqual(calls, [('GET','/profile/capabilities')])
    def test_typed_deadline_remains_a_protocol_error(self):
        self.assertTrue(issubclass(protocol.DeadlineError, protocol.ProtocolError))
        with self.assertRaises(protocol.DeadlineError):
            with protocol.overall_deadline(.025): time.sleep(.2)
    def test_nested_timer_does_not_extend_outer_deadline(self):
        started=time.monotonic()
        with self.assertRaises(protocol.ProtocolError):
            with protocol.overall_deadline(.06):
                with protocol.overall_deadline(1): time.sleep(.2)
        self.assertLess(time.monotonic()-started,.5)
    def test_deadline_restores_signal_handler(self):
        previous=signal.getsignal(signal.SIGALRM)
        with self.assertRaises(protocol.ProtocolError):
            with protocol.overall_deadline(.025): time.sleep(.2)
        self.assertIs(signal.getsignal(signal.SIGALRM),previous)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL),(0.0,0.0))

class SessionProbeTests(unittest.TestCase):
    def fixture(self, state):
        calls=[]
        def fetch(method,path,payload=None,limit=65536):
            calls.append((method,path))
            if path=='/health': return 200,{'version':'3.2.0-rc19'}
            if path.startswith('/transport/status'): return 200,state
            if path=='/profile/capabilities': return 200,{}
            if path=='/chats?v=2': return 200,{'version':2,'chats':[]}
            raise AssertionError('unexpected diagnostic route')
        return fetch,calls
    def test_contradictory_state_cannot_authorize_media_probe(self):
        for state in ('disconnected','pairing-required','authentication-required','provider-unavailable','unknown',None):
            with self.subTest(state=state):
                fetch,calls=self.fixture({'session_state':state,'connected':True,'logged_in':True,
                                          'checked':True,'checking':False,'checked_age':0})
                out=doctor.collect(fetch,True,pause=lambda _:None)
                self.assertFalse(out['backend_ready_for_probe'])
                self.assertNotIn(('GET','/chats?v=2'),calls)
    def test_consistent_ready_state_retains_explicit_sampling(self):
        fetch,calls=self.fixture({'session_state':'ready','connected':True,'logged_in':True,
                                 'checked':True,'checking':False,'checked_age':0})
        self.assertTrue(doctor.collect(fetch,True)['backend_ready_for_probe'])
        self.assertIn(('GET','/chats?v=2'),calls)
    def test_pending_refresh_does_not_allow_a_cached_ready_probe(self):
        fetch,calls=self.fixture({'session_state':'ready','connected':True,'logged_in':True,
                                 'checked':True,'checking':True,'checked_age':0})
        self.assertFalse(doctor.collect(fetch,True,pause=lambda _:None)['backend_ready_for_probe'])
        self.assertNotIn(('GET','/chats?v=2'),calls)

class AccountSelectionTests(unittest.TestCase):
    def test_complete_environment_does_not_open_unrelated_local_env(self):
        env={'WHATSAPPEL_TOKEN':'synthetic-token', 'WHATSAPPEL_BRIDGE_URL':'http://127.0.0.1:7337'}
        with mock.patch.dict(os.environ,env,clear=True), mock.patch.object(os,'geteuid',return_value=1000), \
             mock.patch.object(sys,'argv',['doctor','--source','/nonexistent','--output','/synthetic/report.json']), \
             mock.patch.object(doctor,'local_config',side_effect=AssertionError('wrong credential source')), \
             mock.patch.object(doctor,'Client'), mock.patch.object(doctor,'collect',return_value={}), \
             mock.patch.object(doctor,'write_report'), mock.patch('builtins.print'):
            doctor.main()
    def test_partial_environment_never_borrows_local_token(self):
        with self.assertRaises(doctor.Stop):
            doctor.select_account({'WHATSAPPEL_TOKEN':'private-file-token'},
                                  {'WHATSAPPEL_BRIDGE_URL':'http://127.0.0.1:7337'})
    def test_environment_only_cli_without_local_env(self):
        with tempfile.TemporaryDirectory() as directory, endpoint() as (url,calls):
            root=Path(directory); outdir=root/'reports'; outdir.mkdir(mode=0o700)
            uid=os.getuid(); gid=os.getgid()
            kwargs={}
            if uid==0:
                uid=65534; gid=65534; root.chmod(0o755); os.chown(outdir,uid,gid)
                kwargs={'user':uid,'group':gid}
            env={'PATH':os.environ.get('PATH',''), 'HOME':str(root),
                 'WHATSAPPEL_TOKEN':'synthetic-token', 'WHATSAPPEL_BRIDGE_URL':url}
            report=outdir/'report.json'
            result=subprocess.run([sys.executable,'-I',str(ROOT/'scripts/doctor-session.py'),
                                   '--source',str(root/'no-installed-source'), '--output',str(report)],
                                  env=env,text=True,capture_output=True,timeout=10,**kwargs)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue(report.is_file())
            data=json.loads(report.read_text())
            self.assertEqual(data['config_source'],'environment')
            self.assertFalse(data['backend_ready_for_probe'])
            self.assertNotIn('synthetic-token',result.stdout+result.stderr+report.read_text())
            self.assertEqual(report.stat().st_mode&0o777,0o600)
            self.assertTrue(all(m=='GET' for m,_ in calls))
