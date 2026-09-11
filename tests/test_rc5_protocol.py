# SPDX-License-Identifier: AGPL-3.0-only
"""RC5 strict shared protocol, validated envelopes, and real upload deadlines."""
import contextlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from test_read_worker import server, invoke, TOKEN

ROOT = Path(__file__).resolve().parents[1]

def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT/"scripts"/file)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

read = load("rc5_read", "read-worker.py")
media = load("rc5_media", "media-worker.py")
protocol = read.protocol

class Reply(io.BytesIO):
    status = 200

class SharedProtocol(unittest.TestCase):
    def test_read_and_upload_use_same_source_helper(self):
        self.assertEqual(Path(read.protocol.__file__), Path(media.protocol.__file__))
        self.assertEqual(read.decode_json.__code__.co_filename, media.protocol.decode_json.__code__.co_filename)

    def test_surrogates_rejected_in_keys_values_and_arrays(self):
        for raw in [b'"\\ud800"', b'{"\\udfff":0}', b'["\\ud800"]', b'{"x":["\\udfff"]}']:
            with self.subTest(raw=raw), self.assertRaises(protocol.ProtocolError): protocol.decode_json(raw)

    def test_surrogate_pairs_and_multilingual_text_survive(self):
        value={'text':'João 音楽 🎵', 'key🎵':'\u202e'}
        self.assertEqual(protocol.decode_json(json.dumps(value).encode()), value)
        self.assertEqual(protocol.decode_json(json.dumps(value,ensure_ascii=False).encode()), value)

    def test_escaped_surrogate_literal_not_misread(self):
        value={'text':r'\ud800 is literal text, not a lone codepoint'}
        self.assertEqual(protocol.decode_json(json.dumps(value).encode()),value)

    def test_utf16_and_bom_not_silently_accepted(self):
        for raw in ['{"x":1}'.encode('utf-16'), b'\xef\xbb\xbf{"x":1}']:
            with self.subTest(raw=raw), self.assertRaises(protocol.ProtocolError): protocol.decode_json(raw)

    def test_depth_and_duplicate_checks_still_apply(self):
        for raw in [b'['*97+b'0'+b']'*97,b'{"x":0,"\\u0078":1}',b'{"x":1e309}']:
            with self.subTest(raw=raw), self.assertRaises(protocol.ProtocolError): protocol.decode_json(raw)

    @unittest.skipUnless(hasattr(signal,'setitimer'),'POSIX interval timer required')
    def test_total_deadline_triggers_and_restores_handler(self):
        before=signal.getsignal(signal.SIGALRM)
        with self.assertRaises(protocol.ProtocolError):
            with protocol.overall_deadline(.03): time.sleep(.2)
        self.assertIs(signal.getsignal(signal.SIGALRM),before)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL),(0.0,0.0))

    @unittest.skipUnless(hasattr(signal,'setitimer'),'POSIX interval timer required')
    def test_nested_deadline_preserves_outer_remaining_timer(self):
        with protocol.overall_deadline(1):
            first=signal.getitimer(signal.ITIMER_REAL)[0]
            with protocol.overall_deadline(.5): time.sleep(.01)
            remaining=signal.getitimer(signal.ITIMER_REAL)[0]
            self.assertGreater(remaining,.5); self.assertLess(remaining,first)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL),(0.0,0.0))

    def test_thread_calls_do_not_change_signal_handlers(self):
        errors=[]
        def work():
            try:
                with protocol.overall_deadline(.1): pass
            except Exception as exc:errors.append(type(exc).__name__)
        t=threading.Thread(target=work);t.start();t.join(1)
        self.assertEqual(errors,[])

class Envelopes(unittest.TestCase):
    def test_wire_preserves_validated_original_whitespace(self):
        raw=b'  [ { "jid" : "one", "last": "\\u00e9" } ] \n'
        with server(raw) as (url,hits): proc,data=invoke(url)
        self.assertEqual(proc.returncode,0)
        self.assertEqual(data['body'],json.loads(raw))
        self.assertIn(raw,proc.stdout);self.assertEqual(len(hits),1)

    def test_wire_is_three_writes_without_copying_raw(self):
        raw=b'{"text":"'+b'a'*10000+b'"}'
        parts=[]
        sink=mock.Mock();sink.write.side_effect=lambda value: parts.append(value)
        read.write_envelope(sink,200,raw)
        self.assertEqual(len(parts),3);self.assertIs(parts[1],raw)
        self.assertEqual(json.loads(b''.join(parts)),{'status':200,'body':json.loads(raw)})

    def test_main_rejects_lone_surrogates_before_forwarding(self):
        with server(b'[{"jid":"x","last":"\\ud800"}]') as (url,hits):proc,data=invoke(url)
        self.assertEqual(proc.returncode,1);self.assertIsNone(data['status'])
        self.assertNotIn(b'\\ud800',proc.stdout);self.assertEqual(len(hits),1)

    def test_unvalidated_trailing_json_is_never_forwarded(self):
        with server(b'[] {"secret":"'+TOKEN.encode()+b'"}') as (url,hits):proc,data=invoke(url)
        self.assertEqual(proc.returncode,1);self.assertIsNone(data['status'])
        self.assertNotIn(TOKEN.encode(),proc.stdout+proc.stderr)
        self.assertEqual(len(hits),1)

    def test_body_never_forwarded_from_error_status(self):
        with server(b'{"secret":"'+TOKEN.encode()+b'"}',status=503) as (url,hits):proc,data=invoke(url)
        self.assertEqual(data['status'],503);self.assertNotIn(TOKEN.encode(),proc.stdout+proc.stderr)
        self.assertEqual(len(hits),1)

    def test_api_and_wire_paths_return_equivalent_structures(self):
        value={'version':2,'revision':'one','unchanged':False,'chats':[{'jid':'one','last':'a\\b"🎵'}]}
        with server(json.dumps(value).encode()) as (url,_):
            control={'url':url,'path':'/chats?v=2','token':TOKEN,'timeout':2}
            normal=read.read_request(control);status,raw=read.read_request(control,raw_output=True)
        self.assertEqual(normal,{'status':status,'body':json.loads(raw)})

    def test_worker_ignores_protocol_module_in_working_directory(self):
        with tempfile.TemporaryDirectory() as tmp, server() as (url,hits):
            fake=Path(tmp)/'bridge_protocol.py';fake.write_text('raise RuntimeError("MUST NOT IMPORT")')
            control={'url':url,'path':'/chats?v=2','token':TOKEN,'timeout':2}
            proc=subprocess.run([sys.executable,'-I',str(ROOT/'scripts/read-worker.py')],cwd=tmp,
                input=json.dumps(control).encode(),capture_output=True,timeout=5)
        self.assertEqual(proc.returncode,0);self.assertEqual(len(hits),1)

class UploadAcknowledgements(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.path=Path(self.tmp.name)/'source.png';self.path.write_bytes(b'original')
        self.control={'url':'http://127.0.0.1:7337','token':TOKEN,'target':'5511','kind':'image','file':str(self.path),'timeout':1}
    def tearDown(self):self.tmp.cleanup()
    def reply(self, raw):
        opener=mock.Mock();opener.open.return_value=Reply(raw)
        result=media.upload(self.control,opener)
        self.assertEqual(opener.open.call_count,1)
        self.assertNotIn(TOKEN,json.dumps(result))
        return result

    def test_duplicate_acknowledgement_cannot_mask_failure(self):
        self.assertTrue(self.reply(b'{"wuzapi_status":500,"wuzapi_status":200}')['uncertain'])

    def test_nested_duplicate_acknowledgement_rejected(self):
        self.assertFalse(self.reply(b'{"wuzapi_status":200,"data":{"success":false,"success":true}}')['ok'])

    def test_nonfinite_acknowledgement_never_succeeds(self):
        for value in ['NaN','Infinity','1e999']:
            with self.subTest(value=value): self.assertTrue(self.reply(('{"wuzapi_status":200,"data":'+value+'}').encode())['uncertain'])

    def test_overdeep_acknowledgement_is_unknown_delivery(self):
        self.assertTrue(self.reply(b'{"wuzapi_status":200,"data":'+b'['*97+b'0'+b']'*97+b'}')['uncertain'])

    def test_surrogate_acknowledgement_rejected(self):
        self.assertTrue(self.reply(b'{"wuzapi_status":200,"data":"\\ud800"}')['uncertain'])

    def test_valid_acknowledgement_is_upstream_acceptance_only(self):
        self.assertTrue(self.reply(b'{"wuzapi_status":200,"data":{"success":true,"data":{"Id":"fixture-id"}}}')['ok'])
        self.assertEqual(self.path.read_bytes(),b'original')

    def test_token_and_origin_guards_are_consistent(self):
        for token in [' ', 'a b','x'*4097]:
            with self.subTest(token=token[:10]),self.assertRaises(media.WorkerError):media.upload(dict(self.control,token=token),mock.Mock())
        for origin in ['https://@example.com','https://example.com?','https://example.com#','http://127.0.0.1:0','http://127.0.0.1\x7f']:
            with self.subTest(origin=origin),self.assertRaises(media.WorkerError):media.bridge_url(origin)

    def test_nonfinite_timeouts_fail_before_post(self):
        for timeout in [float('nan'),float('inf'),False,0,121]:
            opener=mock.Mock()
            with self.subTest(timeout=timeout),self.assertRaises(media.WorkerError):media.upload(dict(self.control,timeout=timeout),opener)
            opener.open.assert_not_called()

    def test_duplicate_control_fields_fail_before_network(self):
        raw=json.dumps(self.control)[:-1]+',"target":"another"}'
        proc=subprocess.run([sys.executable,'-I',str(ROOT/'scripts/media-worker.py'),'send'],input=raw.encode(),capture_output=True,timeout=3)
        self.assertEqual(proc.returncode,1);self.assertIn('Duplicate',json.loads(proc.stdout)['error'])
        self.assertNotIn(TOKEN.encode(),proc.stdout+proc.stderr)

    @unittest.skipUnless(hasattr(signal,'setitimer'),'POSIX deadline required')
    def test_real_upload_slow_drip_stops_once_and_remains_uncertain(self):
        hits=[];stop=threading.Event()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*a):pass
            def do_POST(self):
                hits.append(self.rfile.read(int(self.headers['Content-Length'])))
                self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
                for byte in b'{"wuzapi_status":200}':
                    if stop.is_set():break
                    try:self.wfile.write(bytes([byte]));self.wfile.flush()
                    except (BrokenPipeError,ConnectionResetError):break
                    stop.wait(.2)
        httpd=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=httpd.serve_forever,kwargs={'poll_interval':.01},daemon=True);thread.start()
        try:
            control=dict(self.control,url=f'http://127.0.0.1:{httpd.server_port}')
            start=time.monotonic()
            proc=subprocess.run([sys.executable,'-I',str(ROOT/'scripts/media-worker.py'),'send'],input=json.dumps(control).encode(),capture_output=True,timeout=4)
            elapsed=time.monotonic()-start
        finally:stop.set();httpd.shutdown();httpd.server_close();thread.join(1)
        data=json.loads(proc.stdout)
        self.assertEqual(proc.returncode,1);self.assertTrue(data['uncertain'])
        self.assertLess(elapsed,3);self.assertEqual(len(hits),1)
        self.assertNotIn(TOKEN.encode(),proc.stdout+proc.stderr)
