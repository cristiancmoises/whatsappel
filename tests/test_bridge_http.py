"""Exercise the real Guile HTTP bridge against a local, deterministic wuzapi fake.

No WhatsApp account, credentials, external HTTP server, or Python packages are
used. Media roundtrips here prove byte-preserving bridge routing only; actual
WhatsApp delivery and backend compatibility require a separate live test.
"""

import base64
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlencode


ROOT = Path(__file__).resolve().parents[1]
BRIDGE_TOKEN = "integration-bridge-token-2026"
UPSTREAM_TOKEN = "integration-upstream-token-2026"
GUILE = shutil.which("guile")


class MockWuzapi(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), MockHandler)
        self.lock = threading.Lock()
        self.requests = []
        self.responses = {}
        self.sequence = 0
        self.download_uri = ""
        self.download_delay = 0

    def matching_requests(self, path):
        with self.lock:
            return [item for item in self.requests if item[1] == path]


class MockHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw) if raw else None
        with self.server.lock:
            self.server.requests.append(
                (self.command, self.path, body, self.headers.get("Token"))
            )
            if self.headers.get("Token") != UPSTREAM_TOKEN:
                status, response = 401, {"success": False}
            elif self.path in self.server.responses:
                status, response = self.server.responses[self.path]
            elif self.path.startswith("/chat/send/"):
                self.server.sequence += 1
                status, response = 200, {
                    "success": True,
                    "data": {"Id": f"mock-send-{self.server.sequence}"},
                }
            elif self.path.startswith("/chat/download"):
                status, response = 200, {
                    "success": True,
                    "data": {"Data": self.server.download_uri},
                }
            elif self.path == "/session/status":
                status, response = 200, {
                    "success": True,
                    "data": {"Connected": True, "LoggedIn": True},
                }
            else:
                # Empty contacts, groups and history keep startup sync local.
                status, response = 200, {"success": True, "data": {}}
        if self.path.startswith("/chat/download"):
            time.sleep(self.server.download_delay)
        encoded = json.dumps(response, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def unused_loopback_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


@unittest.skipUnless(GUILE, "Guile is required for real bridge HTTP integration tests")
class BridgeHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.backend = MockWuzapi()
        cls.backend_thread = threading.Thread(target=cls.backend.serve_forever, daemon=True)
        cls.backend_thread.start()
        cls.addClassCleanup(cls.stop_backend)
        cls.port = unused_loopback_port()
        cls.bridge_log = tempfile.TemporaryFile(mode="w+b")
        cls.addClassCleanup(cls.bridge_log.close)
        environment = os.environ.copy()
        # Guile's HTTP client does not implement no_proxy. These fixtures use
        # loopback only, so an inherited development proxy must never receive
        # even the synthetic credentials or intercept fixture requests.
        for name in ("http_proxy", "https_proxy", "all_proxy",
                     "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
            environment.pop(name, None)
        environment.update({
            "GUILE_AUTO_COMPILE": "0",
            "WHATSAPPEL_HOST": "127.0.0.1",
            "WHATSAPPEL_PORT": str(cls.port),
            "WHATSAPPEL_TOKEN": BRIDGE_TOKEN,
            "WHATSAPPEL_PUBLIC_URL": f"http://127.0.0.1:{cls.port}",
            "WHATSAPPEL_LIDMAP_DB": "",
            "WHATSAPPEL_HISTORY": "20",
            "WHATSAPPEL_CHAT_CAP": "20",
            "WHATSAPPEL_MAX_CHATS": "100",
            "WHATSAPPEL_MAX_BODY_BYTES": "4096",
            "WHATSAPPEL_MAX_MEDIA_BYTES": "1024",
            "WUZAPI_BASE_URL": f"http://127.0.0.1:{cls.backend.server_port}",
            "WUZAPI_TOKEN": UPSTREAM_TOKEN,
            "WUZAPI_TOKEN_HEADER": "Token",
        })
        cls.bridge = subprocess.Popen(
            [GUILE, "--no-auto-compile", str(ROOT / "whatsappel.scm")],
            cwd=ROOT,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=cls.bridge_log,
            stderr=subprocess.STDOUT,
        )
        cls.addClassCleanup(cls.stop_bridge)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if cls.bridge.poll() is not None:
                break
            try:
                status, _, _ = cls.request("GET", "/health", token=None)
                if status == 200:
                    return
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(0.05)
        cls.bridge_log.seek(0)
        details = cls.bridge_log.read().decode("utf-8", errors="replace")
        raise AssertionError(f"Guile bridge did not become healthy:\n{details}")

    @classmethod
    def stop_bridge(cls):
        if cls.bridge.poll() is None:
            cls.bridge.terminate()
            try:
                cls.bridge.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.bridge.kill()
                cls.bridge.wait(timeout=5)

    @classmethod
    def stop_backend(cls):
        cls.backend.shutdown()
        cls.backend.server_close()
        cls.backend_thread.join(timeout=5)

    def setUp(self):
        with self.backend.lock:
            self.backend.responses.clear()

    def tearDown(self):
        status, response, _ = self.request("GET", "/health", token=None)
        self.assertEqual(status, 200, "An invalid request must not kill the bridge")
        self.assertEqual(response["status"], "ok")

    @classmethod
    def request(cls, method, path, body=None, token=BRIDGE_TOKEN,
                content_type="application/json"):
        headers = {"Content-Type": content_type}
        if token is not None:
            headers["X-Whatsappel-Token"] = token
        if body is not None and not isinstance(body, (bytes, str)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        connection = http.client.HTTPConnection("127.0.0.1", cls.port, timeout=5)
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
            return response.status, json.loads(payload), dict(response.getheaders())
        finally:
            connection.close()

    def chats(self):
        status, result, _ = self.request("GET", "/chats")
        self.assertEqual(status, 200)
        return {chat["jid"]: chat for chat in result}

    def messages(self, jid):
        status, result, _ = self.request("GET", "/chat?" + urlencode({"jid": jid}))
        self.assertEqual(status, 200)
        return result

    def webhook(self, chat, message_id, text="A new message", mine=False):
        return {
            "type": "Message",
            "event": {
                "Info": {
                    "Chat": chat + "@s.whatsapp.net",
                    "Sender": chat + "@s.whatsapp.net",
                    "PushName": "Integração ç日本",
                    "ID": message_id,
                    "Timestamp": int(time.time()),
                    "IsFromMe": mine,
                },
                "Message": {"conversation": text},
            },
        }

    def post_webhook(self, payload):
        return self.request("POST", "/hook/" + BRIDGE_TOKEN, payload, token=None)

    def test_authentication_rejects_missing_and_wrong_tokens(self):
        for token in (None, "wrong-token", BRIDGE_TOKEN[:-1] + "X"):
            with self.subTest(token=token):
                self.assertEqual(self.request("GET", "/chats", token=token)[0], 401)
        count = len(self.backend.matching_requests("/chat/send/text"))
        self.assertEqual(self.request("POST", "/send", {
            "to": "551100000001", "body": "must not be sent"
        }, token=None)[0], 401)
        self.assertEqual(len(self.backend.matching_requests("/chat/send/text")), count)

    def test_health_and_status_use_local_backend(self):
        status, body, headers = self.request("GET", "/health", token=None)
        self.assertEqual((status, body["service"]), (200, "whatsappel"))
        self.assertIn("no-store", headers.get("Cache-Control", ""))
        status, body, _ = self.request("GET", "/status")
        self.assertEqual(status, 200)
        self.assertTrue(body["data"]["data"]["Connected"])
        self.assertEqual(self.backend.matching_requests("/session/status")[-1][3],
                         UPSTREAM_TOKEN)

    def test_malformed_json_and_nonobject_payloads_are_rejected(self):
        for path in ("/send", "/send/image", "/send/document", "/download",
                     "/react", "/delete", "/markread", "/mediaretry"):
            for invalid in (b"{", b"[]", b"42", b'"text"', b"null"):
                with self.subTest(path=path, invalid=invalid):
                    self.assertEqual(self.request("POST", path, invalid)[0], 400)

    def test_wrong_field_types_do_not_break_the_server(self):
        cases = (
            ("/send", {"to": 123, "body": "hello"}),
            ("/send", {"to": "551100000002", "body": {"bad": True}}),
            ("/send", {"to": "551100000002", "body": ""}),
            ("/react", {"to": "551100000002", "id": 123, "me": True}),
            ("/delete", {"to": "551100000002", "id": [], "me": True}),
            ("/send/document", {"to": "551100000002", "data": "not base64"}),
        )
        for path, payload in cases:
            with self.subTest(path=path, payload=payload):
                self.assertEqual(self.request("POST", path, payload)[0], 400)

    def test_unicode_text_is_forwarded_and_stored_once(self):
        chat, text = "551100000003", "Olá, ação! 日本語 🦜\nSecond line"
        status, response, _ = self.request("POST", "/send", {"to": chat, "body": text})
        self.assertEqual(status, 200)
        upstream = self.backend.matching_requests("/chat/send/text")[-1]
        self.assertEqual(upstream[2], {"Phone": chat, "Body": text})
        self.assertEqual(upstream[3], UPSTREAM_TOKEN)
        records = self.messages(chat)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["text"], text)
        self.assertTrue(records[0]["me"])
        self.assertEqual(records[0]["id"], response["data"]["data"]["Id"])
        self.assertEqual(self.chats()[chat]["unread"], 0)

    def test_binary_document_bytes_and_unicode_filename_are_preserved(self):
        original = bytes(range(256)) * 2
        uri = "data:application/octet-stream;base64," + base64.b64encode(original).decode()
        status, _, _ = self.request("POST", "/send/document", {
            "to": "551100000004", "data": uri, "filename": "arquivo-ação.bin",
            "caption": "Original bytes",
        })
        self.assertEqual(status, 200)
        payload = self.backend.matching_requests("/chat/send/document")[-1][2]
        self.assertEqual(payload["Document"], uri)
        self.assertEqual(payload["FileName"], "arquivo-ação.bin")
        self.assertEqual(payload["Caption"], "Original bytes")
        self.assertEqual(base64.b64decode(payload["Document"].split(",", 1)[1]), original)
        self.assertEqual(self.chats()["551100000004"]["unread"], 0)

    def test_image_upload_and_mock_download_preserve_original_bytes(self):
        original = base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8"
            "/x8AAwMCAO+aB9sAAAAASUVORK5CYII="
        )
        uri = "data:image/png;base64," + base64.b64encode(original).decode()
        status, _, _ = self.request("POST", "/send/image", {
            "to": "551100000005", "data": uri, "filename": "original.png",
            "caption": "No local recompression",
        })
        self.assertEqual(status, 200)
        uploaded = self.backend.matching_requests("/chat/send/image")[-1][2]["Image"]
        self.assertEqual(uploaded, uri)
        with self.backend.lock:
            self.backend.download_uri = uploaded
        status, response, _ = self.request("POST", "/download", {
            "kind": "image", "Url": "https://mmg.whatsapp.net/test-media",
            "MediaKey": base64.b64encode(bytes(32)).decode(),
            "Mimetype": "image/png", "FileLength": len(original),
        })
        self.assertEqual(status, 200)
        downloaded = response["data"]["data"]["Data"]
        self.assertEqual(base64.b64decode(downloaded.split(",", 1)[1]), original)
        payload = self.backend.matching_requests("/chat/downloadimage")[-1][2]
        self.assertEqual(payload["Mimetype"], "image/png")
        self.assertEqual(payload["FileLength"], len(original))

    def test_duplicate_webhook_does_not_double_unread(self):
        chat = "551100000006"
        incoming = self.webhook(chat, "deduplicated-incoming")
        self.assertEqual(self.post_webhook(incoming)[0], 200)
        self.assertEqual(self.post_webhook(incoming)[0], 200)
        self.assertEqual(self.chats()[chat]["unread"], 1)
        self.assertEqual(len(self.messages(chat)), 1)
        self.assertEqual(self.chats()[chat]["unread"], 0)

    def test_outbound_webhook_echo_does_not_duplicate_or_mark_unread(self):
        chat = "551100000007"
        status, response, _ = self.request("POST", "/send", {"to": chat, "body": "Own text"})
        self.assertEqual(status, 200)
        message_id = response["data"]["data"]["Id"]
        self.assertEqual(self.post_webhook(self.webhook(chat, message_id,
                                                      "Own text", mine=True))[0], 200)
        self.assertEqual(self.chats()[chat]["unread"], 0)
        records = self.messages(chat)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["id"], message_id)
        self.assertTrue(records[0]["me"])

    def test_form_webhook_preserves_utf8(self):
        chat, message = "551100000008", "Olá ação 日本語"
        form = urlencode({"jsonData": json.dumps(self.webhook(chat, "form-message", message),
                                                 ensure_ascii=False)})
        status, _, _ = self.request("POST", "/hook/" + BRIDGE_TOKEN, form,
                                    token=None, content_type="application/x-www-form-urlencoded")
        self.assertEqual(status, 200)
        self.assertEqual(self.messages(chat)[0]["text"], message)

    def test_malformed_webhook_does_not_create_unknown_chat(self):
        before = set(self.chats())
        for payload in (b"{", {"type": "Message", "event": 123},
                        {"type": "Message", "event": {"Info": {}, "Message": {}}}):
            with self.subTest(payload=payload):
                self.assertEqual(self.post_webhook(payload)[0], 400)
        self.assertEqual(set(self.chats()), before)

    def test_oversized_request_and_media_are_rejected_before_forwarding(self):
        count = len(self.backend.matching_requests("/chat/send/text"))
        self.assertEqual(self.request("POST", "/send", {
            "to": "551100000009", "body": "x" * 4500
        })[0], 413)
        self.assertEqual(len(self.backend.matching_requests("/chat/send/text")), count)
        uri = "data:application/octet-stream;base64," + base64.b64encode(bytes(1025)).decode()
        count = len(self.backend.matching_requests("/chat/send/document"))
        status = self.request("POST", "/send/document", {
            "to": "551100000009", "data": uri, "filename": "too-large.bin"
        })[0]
        self.assertIn(status, (400, 413))
        self.assertEqual(len(self.backend.matching_requests("/chat/send/document")), count)

    def test_download_rejects_unknown_kind_and_non_whatsapp_hosts(self):
        for payload in (
            {"kind": "unsupported", "Url": "https://mmg.whatsapp.net/media"},
            {"kind": "image", "Url": "http://127.0.0.1/internal"},
            {"kind": "image", "Url": "https://example.com/image.png"},
        ):
            with self.subTest(payload=payload):
                self.assertEqual(self.request("POST", "/download", payload)[0], 400)

    def test_upstream_failure_is_reported_and_not_stored_as_sent(self):
        with self.backend.lock:
            self.backend.responses["/chat/send/text"] = (
                200, {"success": False, "error": "mock rejection"}
            )
        status, _, _ = self.request("POST", "/send", {
            "to": "551100000010", "body": "Backend must reject this"
        })
        self.assertEqual(status, 502)
        self.assertNotIn("551100000010", self.chats())


if __name__ == "__main__":
    unittest.main()
