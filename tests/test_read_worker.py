"""Real bounded read-worker subprocesses against synthetic HTTP fixtures."""
# SPDX-License-Identifier: AGPL-3.0-only
import contextlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/read-worker.py"
spec = importlib.util.spec_from_file_location("read_worker", SCRIPT)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
TOKEN = "synthetic-test-token-never-a-real-credential"


@contextlib.contextmanager
def server(body=b'[]', status=200, headers=(), mode="normal", delay=0):
    hits = []
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *_args):
            pass
        def do_GET(self):
            hits.append((self.command, self.path, dict(self.headers)))
            try:
                if mode == "headers":
                    time.sleep(delay)
                self.send_response(status)
                self.send_header("Connection", "close")
                self.send_header("Content-Type", "application/json")
                for key, value in headers:
                    self.send_header(key, str(value))
                if not headers and mode not in {"drip", "chunked"}:
                    self.send_header("Content-Length", len(body))
                if mode == "chunked":
                    self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                if mode == "drip":
                    for byte in body:
                        self.wfile.write(bytes([byte])); self.wfile.flush(); time.sleep(delay)
                elif mode == "chunked":
                    for pos in range(0, len(body), 7):
                        block = body[pos:pos+7]
                        self.wfile.write(f"{len(block):x}\r\n".encode() + block + b"\r\n")
                    self.wfile.write(b"0\r\n\r\n")
                else:
                    self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}", hits
    finally:
        httpd.shutdown(); httpd.server_close(); thread.join(1)


def invoke(origin, path="/chats?v=2", timeout=2, max_bytes=4096, extra_env=None, raw=None):
    control = {"url": origin, "path": path, "token": TOKEN, "timeout": timeout, "max_bytes": max_bytes}
    result = subprocess.run([sys.executable, "-I", str(SCRIPT)],
                            input=json.dumps(control).encode() if raw is None else raw,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
                            env=dict(os.environ, **(extra_env or {})))
    return result, json.loads(result.stdout)


class ReadValidation(unittest.TestCase):
    def control(self, **kw):
        return dict(url="http://127.0.0.1", path="/chats?v=2", token=TOKEN, **kw)

    def test_origin_requires_loopback_or_https(self):
        for url in ["http://example.com", "file:///tmp/x", "http://127.0.0.1/x", "http://u:p@localhost",
                    "https://host?", "https://host#", "http://127.0.0.1:0", "https://ho\nst", "//localhost"]:
            with self.subTest(url=url), self.assertRaises(worker.ReadError):
                worker.validate(dict(self.control(), url=url))
        worker.validate(dict(self.control(), url="https://example.com"))
        worker.validate(dict(self.control(), url="http://[::1]:7337"))

    def test_only_supported_read_paths(self):
        for path in ["/send", "/download", "//example.com/chats", "http://example.com/chats", "/chat/../chats",
                     "/%63hats", "/chats#", "/chats?unknown=x", "/chats?v=2&v=2", "/health?v=2"]:
            with self.subTest(path=path), self.assertRaises(worker.ReadError):
                worker.validate(dict(self.control(), path=path))

    def test_chat_requires_explicit_read_flag(self):
        for path in ["/chat?jid=test", "/chat?read=0", "/chat?jid=test&read=2"]:
            with self.subTest(path=path), self.assertRaises(worker.ReadError):
                worker.validate(dict(self.control(), path=path))
        for read in (0, 1):
            worker.validate(dict(self.control(), path=f"/chat?jid=test%40g.us&v=2&read={read}&limit=60"))

    def test_query_controls_invalid_windows(self):
        for query in ["jid=a%0Ab&read=0", "jid=a&read=0&limit=0", "jid=a&read=0&limit=10001",
                      "jid=a&read=0&limit=x", "jid=&read=0", "jid=a&read=0&since=", "jid=a&read=0&v=3"]:
            with self.subTest(query=query), self.assertRaises(worker.ReadError):
                worker.validate(dict(self.control(), path="/chat?" + query))

    def test_media_result_cap_is_distinct(self):
        with self.assertRaises(worker.ReadError):
            worker.validate(self.control(max_bytes=worker.MAX_SNAPSHOT+1))
        worker.validate(dict(self.control(max_bytes=worker.MAX_MEDIA), path="/media-job?id=epoch%3A1"))

    def test_limits_types_and_nonfinite(self):
        for timeout in [True, False, 0, -1, 121, float("nan"), float("inf"), "5"]:
            with self.subTest(timeout=timeout), self.assertRaises(worker.ReadError):
                worker.validate(self.control(timeout=timeout))
        for limit in [False, -1, 0, "1", 1.2]:
            with self.subTest(limit=limit), self.assertRaises(worker.ReadError):
                worker.validate(self.control(max_bytes=limit))

    def test_token_header_injection_rejected(self):
        for token in [None, "", "a\nb", "a\rb", "a\x00b", "a b", "é", "x" * 4097]:
            with self.subTest(token=repr(token)[:40]), self.assertRaises(worker.ReadError):
                worker.validate(dict(self.control(), token=token))

    def test_json_depth_quoted_brackets_and_duplicates(self):
        self.assertEqual(worker.decode_json(b'{"text":"[[[\\\"[[[","x":[]}')["x"], [])
        for raw in [b'['*97+b'0'+b']'*97, b'{"a":1,"a":2}', b'{"x":NaN}', b'\xff', b'{} trailing']:
            with self.subTest(raw=raw[:20]), self.assertRaises(worker.ReadError):
                worker.decode_json(raw)

    def test_control_failure_is_redacted(self):
        result, data = invoke("http://127.0.0.1", raw=b'not-json-' + TOKEN.encode())
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(TOKEN.encode(), result.stdout + result.stderr)
        self.assertIsNone(data["status"])
        self.assertEqual(result.stderr, b"")

    def test_oversized_control_is_redacted(self):
        result, _ = invoke("http://127.0.0.1", raw=b'x'*(worker.MAX_CONTROL+1))
        self.assertEqual(result.returncode, 1)
        self.assertLess(len(result.stdout), 200)


class ReadHTTP(unittest.TestCase):
    def test_unicode_false_null_and_array_preserved(self):
        expected = [{"jid": "fixture", "name": "João — música", "empty": [], "ok": False, "null": None}]
        with server(json.dumps(expected, ensure_ascii=False).encode()) as (origin, hits):
            result, data = invoke(origin)
        self.assertEqual(result.returncode, 0); self.assertEqual(result.stderr, b"")
        self.assertEqual(data, {"status": 200, "body": expected})
        self.assertEqual(len(hits), 1); self.assertEqual(hits[0][0], "GET")
        self.assertEqual(hits[0][2]["X-Whatsappel-Token"], TOKEN)
        self.assertEqual(hits[0][2]["Accept-Encoding"], "identity")

    def test_read_only_flag_and_revision_transmitted_once(self):
        body = b'{"version":2,"revision":"epoch:1","unchanged":true}'
        path = "/chat?jid=fixture%40g.us&v=2&read=0&limit=60&since=epoch%3A1"
        with server(body) as (origin, hits):
            result, data = invoke(origin, path=path)
        self.assertEqual(result.returncode, 0); self.assertTrue(data["body"]["unchanged"])
        self.assertEqual([h[1] for h in hits], [path])

    def test_no_redirect_is_followed(self):
        with server() as (other, other_hits):
            for status in [301, 302, 303, 307, 308]:
                with self.subTest(status=status), server(status=status, headers=[("Location", other+"/chats")]) as (origin, hits):
                    result, data = invoke(origin)
                    self.assertEqual(data["status"], status); self.assertEqual(len(hits), 1)
        self.assertEqual(other_hits, [])

    def test_error_bodies_do_not_leak_and_no_retry(self):
        for status in [401, 403, 404, 429, 500, 503]:
            with self.subTest(status=status), server(TOKEN.encode(), status=status) as (origin, hits):
                result, data = invoke(origin)
                self.assertEqual(data["status"], status); self.assertEqual(len(hits), 1)
                self.assertNotIn(TOKEN.encode(), result.stdout + result.stderr)

    def test_proxy_environment_cannot_receive_credentials(self):
        with server() as (origin, hits), server() as (proxy, proxy_hits):
            result, _ = invoke(origin, extra_env={"http_proxy": proxy, "HTTP_PROXY": proxy,
                               "ALL_PROXY": proxy, "NO_PROXY": "", "no_proxy": ""})
        self.assertEqual(result.returncode, 0); self.assertEqual(len(hits), 1); self.assertEqual(proxy_hits, [])

    def test_advertised_response_size_rejected_before_body(self):
        with server(b"", headers=[("Content-Length", 999999)]) as (origin, _):
            result, data = invoke(origin, max_bytes=64)
        self.assertEqual(result.returncode, 1); self.assertIn("byte limit", data["body"]["error"])

    def test_streamed_response_limit(self):
        with server(b'["' + b'x'*20000 + b'"]', headers=[("X-Fixture", "no-length")]) as (origin, _):
            result, data = invoke(origin, max_bytes=512)
        self.assertEqual(result.returncode, 1); self.assertIn("byte limit", data["body"]["error"])

    def test_valid_chunked_and_chunk_limit(self):
        for limit, expected_code in [(100, 0), (4, 1)]:
            with self.subTest(limit=limit), server(b'[{"x":1}]', mode="chunked") as (origin, _):
                result, _ = invoke(origin, max_bytes=limit)
                self.assertEqual(result.returncode, expected_code)

    def test_truncated_response_rejected(self):
        with server(b'[]', headers=[("Content-Length", 50)]) as (origin, _):
            result, data = invoke(origin)
        self.assertEqual(result.returncode, 1); self.assertIn("Incomplete", data["body"]["error"])

    def test_bad_and_duplicate_lengths(self):
        cases = [[("Content-Length", "-2")], [("Content-Length", "2"), ("Content-Length", "2")],
                 [("Content-Length", "2"), ("Transfer-Encoding", "chunked")]]
        for headers in cases:
            with self.subTest(headers=headers), server(b'[]', headers=headers) as (origin, _):
                result, _ = invoke(origin)
                self.assertEqual(result.returncode, 1)

    def test_compression_is_not_accepted(self):
        with server(b'[]', headers=[("Content-Encoding", "gzip")]) as (origin, _):
            result, data = invoke(origin)
        self.assertEqual(result.returncode, 1); self.assertIn("Compressed", data["body"]["error"])

    def test_malformed_json_scalar_and_nonfinite_rejected(self):
        for body in [b'{}', b'{"error":"not a snapshot"}', b'{', b'null', b'true', b'4', b'"scalar"', b'{"v":Infinity}', b'{"v":1e400}', b'{"text":"\\ud800"}']:
            with self.subTest(body=body), server(body) as (origin, hits):
                result, data = invoke(origin)
                self.assertEqual(result.returncode, 1); self.assertIsNone(data["status"])
                self.assertEqual(len(hits), 1); self.assertEqual(result.stderr, b"")

    def test_media_202_result_is_not_retried_by_worker(self):
        with server(b'{"job":"fixture"}', status=202) as (origin, hits):
            result, data = invoke(origin, path="/media-job?id=fixture")
        self.assertEqual(result.returncode, 0); self.assertEqual(data["status"], 202); self.assertEqual(len(hits), 1)

    def test_total_deadline_on_slow_drip_body(self):
        with server(b'["abcdefghijk"]', mode="drip", delay=.2) as (origin, hits):
            start = time.monotonic(); result, data = invoke(origin, timeout=1)
            elapsed = time.monotonic() - start
        self.assertEqual(result.returncode, 1); self.assertLess(elapsed, 2.5)
        self.assertEqual(len(hits), 1); self.assertIn("deadline", data["body"]["error"])

    def test_total_deadline_before_headers(self):
        with server(mode="headers", delay=2) as (origin, hits):
            start = time.monotonic(); result, data = invoke(origin, timeout=1)
            elapsed = time.monotonic() - start
        self.assertEqual(result.returncode, 1); self.assertLess(elapsed, 2.5)
        self.assertEqual(len(hits), 1); self.assertIn("deadline", data["body"]["error"])


if __name__ == "__main__":
    unittest.main()
