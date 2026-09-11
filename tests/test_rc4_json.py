"""RC4 depth-scan equivalence, strict JSON and actual read-child regressions."""
# SPDX-License-Identifier: AGPL-3.0-only
import importlib.util
import json
from pathlib import Path
import random
import unittest

from test_read_worker import server, invoke, TOKEN

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rc4_read', ROOT/'scripts/read-worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class JSONDepthScan(unittest.TestCase):
    def test_exact_depth_boundary(self):
        for depth in [0, 1, 2, 95, 96]:
            raw = b'['*depth+b'0'+b']'*depth
            self.assertEqual(worker.decode_json(raw), json.loads(raw))
        with self.assertRaises(worker.ReadError):
            worker.decode_json(b'['*97+b'0'+b']'*97)

    def test_mixed_object_array_depth(self):
        value = 0
        for i in range(96):
            value = {'x': value} if i % 2 else [value]
        self.assertEqual(worker.decode_json(json.dumps(value).encode()), value)
        with self.assertRaises(worker.ReadError):
            worker.decode_json(json.dumps([value]).encode())

    def test_quoted_brackets_are_not_depth(self):
        value = {'text': '['*10000 + '}'*10000 + '"' + '\\'*2500}
        self.assertEqual(worker.decode_json(json.dumps(value).encode()), value)

    def test_backslash_parity_at_string_boundary(self):
        for count in range(200):
            value = {'text': '\\'*count+'"\\\"[]{}', 'next': ['ok']}
            self.assertEqual(worker.decode_json(json.dumps(value).encode()), value)

    def test_unicode_escape_and_utf8(self):
        value = {'text': 'João — 音楽 🎵\u202e "\\ [\n', 'literal': '\\u005b\\u0022'}
        for ascii_only in [True, False]:
            self.assertEqual(worker.decode_json(json.dumps(value, ensure_ascii=ascii_only).encode()), value)

    def test_3000_seeded_roundtrips(self):
        rng = random.Random(20260910)
        def value(depth=0):
            choice = rng.randrange(6 if depth < 7 else 4)
            if choice == 0: return rng.randrange(-1000000, 1000000)
            if choice == 1: return rng.choice([None, True, False, 0.25, 1e200])
            if choice == 2: return ''.join(rng.choice('abc\\"{}[] \t\nJoão音🎵') for _ in range(rng.randrange(150)))
            if choice == 3: return ''
            if choice == 4: return [value(depth+1) for _ in range(rng.randrange(6))]
            return {str(i): value(depth+1) for i in range(rng.randrange(6))}
        for i in range(3000):
            item = value()
            raw = json.dumps(item, ensure_ascii=bool(i % 2)).encode()
            self.assertEqual(worker.decode_json(raw), item, i)

    def test_all_single_byte_values_inside_quoted_strings(self):
        value = ''.join(chr(i) for i in range(256))
        self.assertEqual(worker.decode_json(json.dumps(value).encode()), value)

    def test_large_plain_text_and_base64_spans(self):
        for text in ['A'*(4*1024*1024-128), 'abcd1234+/='*250000]:
            item = {'data': text}
            self.assertEqual(worker.decode_json(json.dumps(item).encode()), item)

    def test_malformed_quoted_and_structural_input(self):
        for raw in [b'"', b'"abc\\', b'"abc\\"', b'[}', b'}', b'{]', b'[1,]', b'"x"[]', b'{"x": "\\uZZZZ"}']:
            with self.subTest(raw=raw), self.assertRaises(worker.ReadError):
                worker.decode_json(raw)

    def test_invalid_utf8_and_raw_controls(self):
        for raw in [b'"\xff"', b'"a\x00b"', b'"\xc3("', b'{"\xff":0}']:
            with self.subTest(raw=raw), self.assertRaises(worker.ReadError):
                worker.decode_json(raw)

    def test_exponent_overflow_is_rejected(self):
        for raw in [b'1e309', b'-1e9999', b'{"ts":1e999}', b'[1e400]', b'NaN', b'Infinity', b'-Infinity']:
            with self.subTest(raw=raw), self.assertRaises(worker.ReadError):
                worker.decode_json(raw)

    def test_valid_floats_underflow_and_booleans(self):
        raw = b'[1e308,-1e308,1e-999,0.0,-0.0,false,true,null]'
        self.assertEqual(worker.decode_json(raw), json.loads(raw))

    def test_escaped_duplicate_keys_rejected(self):
        for raw in [b'{"x":0,"x":1}', b'{"x":0,"\\u0078":1}', b'{"outer":{"k":1,"k":2}}']:
            with self.subTest(raw=raw), self.assertRaises(worker.ReadError):
                worker.decode_json(raw)

    def test_percent_encoding_is_strict(self):
        for path in ['/chat?jid=%&read=0', '/chat?jid=%0&read=0', '/chat?jid=%GG&read=0']:
            with self.subTest(path=path), self.assertRaises(worker.ReadError):
                worker.validate(dict(url='http://localhost', path=path, token=TOKEN))
        worker.validate(dict(url='http://localhost', path='/chat?jid=one%40g.us&read=0', token=TOKEN))


class JSONReadChild(unittest.TestCase):
    def test_real_child_rejects_overflow_without_leaking_response(self):
        with server(b'{"version":2,"text":"'+TOKEN.encode()+b'","ts":1e309}') as (url, hits):
            proc, data = invoke(url)
        self.assertEqual(len(hits), 1)
        self.assertEqual(proc.returncode, 1)
        self.assertIsNone(data['status'])
        self.assertNotIn(TOKEN.encode(), proc.stdout + proc.stderr)

    def test_real_child_accepts_large_plain_span(self):
        value = {'version': 2, 'revision': 'fixture', 'unchanged': False,
                 'chats': [{'jid': 'fixture', 'last': '音楽 ' * 100000}]}
        with server(json.dumps(value, ensure_ascii=False).encode()) as (url, hits):
            proc, data = invoke(url, timeout=3, max_bytes=2*1024*1024)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(data['body'], value)
        self.assertEqual(len(hits), 1)

    def test_real_child_rejects_nested_payload_once(self):
        with server(b'['*97+b'0'+b']'*97) as (url, hits):
            proc, data = invoke(url)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(len(hits), 1)
        self.assertIsNone(data['status'])

    def test_real_child_chunked_escaped_strings(self):
        value = [{'jid': 'x', 'last': '\\"{}[]' * 1000}]
        with server(json.dumps(value).encode(), mode='chunked') as (url, hits):
            proc, data = invoke(url, max_bytes=40000)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(data['body'], value)
        self.assertEqual(len(hits), 1)


class DenseEscapeFallback(unittest.TestCase):
    def test_dense_escapes_still_count_depth(self):
        text = json.dumps('\\'*10000).encode()
        raw = b'['*96 + text + b']'*96
        self.assertEqual(worker.decode_json(raw), json.loads(raw))
        with self.assertRaises(worker.ReadError):
            worker.decode_json(b'['+raw+b']')

    def test_density_threshold_does_not_change_result(self):
        for escapes in [0, 32, 100, 256, 1000, 4096]:
            value = {'data': 'plain'*1000+'\\"'*escapes+'[[[[', 'nested': [None]}
            raw = json.dumps(value).encode()
            self.assertEqual(worker.decode_json(raw), value)
