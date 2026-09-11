# SPDX-License-Identifier: AGPL-3.0-only
"""Loopback-only HTTP, verified archives, and guarded Git integration fixtures."""
import base64
import hashlib
import http.server
import importlib.util
import io
import json
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]

def load(name, file):
    s = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m

deploy = load("workspace_deploy", "deploy-ionos.py")
commit = load("workspace_commit", "commit-update.py")
update = load("workspace_update", "update-package.py")

class LoopbackTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.file = self.root / "original.png"
        self.file.write_bytes(b"unchanged fixture bytes")
        self.calls = []
        self.response = b'{"wuzapi_status":200,"data":{"success":true,"data":{"Id":"fixture-id"}}}'
        self.code = 200
        outer = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                outer.calls.append((self.path, dict(self.headers), body))
                self.send_response(outer.code)
                self.send_header("Content-Type", "application/json")
                if outer.code == 302:
                    self.send_header("Location", "http://127.0.0.1:" + str(self.server.server_port) + "/stolen")
                self.send_header("Content-Length", str(len(outer.response)))
                self.end_headers()
                self.wfile.write(outer.response)
            def do_GET(self):
                outer.calls.append((self.path, dict(self.headers), b""))
                self.send_response(200)
                self.end_headers()
            def log_message(self, *_):
                pass
        try:
            self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        except PermissionError:
            self.tmp.cleanup()
            self.skipTest("Loopback socket binding prohibited in this runtime")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def run_worker(self):
        spec = {"url": "http://127.0.0.1:" + str(self.server.server_port), "token": "integration-test-token-not-real", "target": "5511", "kind": "image", "file": str(self.file)}
        p = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/media-worker.py"), "send"], input=json.dumps(spec), capture_output=True, text=True, timeout=10)
        self.assertNotIn(spec["token"], p.stdout + p.stderr)
        return p, json.loads(p.stdout)

    def test_real_process_posts_once_preserving_original(self):
        p, result = self.run_worker()
        self.assertEqual(p.returncode, 0)
        self.assertTrue(result["ok"])
        self.assertEqual(len(self.calls), 1)
        path, headers, body = self.calls[0]
        self.assertEqual(path, "/send/image")
        self.assertEqual(headers["X-Whatsappel-Token"], "integration-test-token-not-real")
        self.assertEqual(base64.b64decode(json.loads(body)["data"].split(",")[1]), self.file.read_bytes())

    def test_redirect_never_forwards_token(self):
        self.code = 302
        p, result = self.run_worker()
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse(result["ok"])
        self.assertEqual([call[0] for call in self.calls], ["/send/image"])

    def test_malformed_success_keeps_delivery_unknown_without_retry(self):
        self.response = b"not-json"
        _, result = self.run_worker()
        self.assertFalse(result["ok"])
        self.assertTrue(result["uncertain"])
        self.assertEqual(len(self.calls), 1)

    def test_server_failure_is_not_retried(self):
        self.code = 502
        _, result = self.run_worker()
        self.assertFalse(result["ok"])
        self.assertTrue(result["uncertain"])
        self.assertEqual(len(self.calls), 1)

class ArchiveTests(unittest.TestCase):
    def archive(self, root, name="package/manifest.json", kind=tarfile.REGTYPE):
        path = root / "fixture.tar.gz"
        with tarfile.open(path, "w:gz") as tf:
            member = tarfile.TarInfo(name)
            member.type = kind
            member.linkname = "/etc/passwd" if kind in {tarfile.SYMTYPE, tarfile.LNKTYPE} else ""
            data = b"{}"
            member.size = len(data) if kind == tarfile.REGTYPE else 0
            tf.addfile(member, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
        return path, hashlib.sha256(path.read_bytes()).hexdigest()

    def test_valid_archive_is_extracted(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            path, sha = self.archive(root)
            deploy.unpack_verified(path, sha, root / "unpacked")
            self.assertEqual((root / "unpacked/manifest.json").read_bytes(), b"{}")

    def test_traversal_links_and_absolute_paths_refused(self):
        for name, kind in [("package/../outside", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE), ("package/link", tarfile.SYMTYPE), ("package/hard", tarfile.LNKTYPE), ("package/device", tarfile.CHRTYPE)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                path, sha = self.archive(root, name, kind)
                with self.assertRaises(ValueError):
                    deploy.unpack_verified(path, sha, root / "unpacked")
                self.assertFalse((root / "unpacked").exists())

    def test_wrong_checksum_refused_before_extraction(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            path, _ = self.archive(root)
            with self.assertRaises(ValueError):
                deploy.unpack_verified(path, "0" * 64, root / "unpacked")
            self.assertFalse((root / "unpacked").exists())

    def test_remote_argv_is_quoted_and_host_key_check_is_mandatory(self):
        args = ["python3", "-c", 'print("hello")', "/path/with spaces/and'quote"]
        self.assertEqual(shlex.split(deploy.remote_command(*args)), args)
        self.assertIn("StrictHostKeyChecking=yes", deploy.SSH)
        self.assertEqual(deploy.PORT, "5119")
        self.assertEqual(deploy.HOST, "root@securityops.co")

class GitPublicationTests(unittest.TestCase):
    def test_commit_uses_isolated_worktree_and_preserves_original_edits(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "original"
            source.mkdir()
            def git(*args):
                return subprocess.run(["git", "-C", str(source), *args], capture_output=True, text=True, check=True)
            git("init", "-b", "main")
            git("config", "user.name", "Fixture Author")
            git("config", "user.email", "fixture@example.invalid")
            files = ["whatsapp.el", "whatsapp-org.el", "tests/client-tests.el", "tests/whatsapp-org-tests.el", "scripts/publish.py", "scripts/apply-update.py", "scripts/audit-workspace.py"]
            for name in files:
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                if name == "scripts/audit-workspace.py":
                    path.write_bytes((ROOT / name).read_bytes())
                else:
                    path.write_text("fixture-before\n")
            git("add", ".")
            git("commit", "-m", "fixture baseline")
            original_head = git("rev-parse", "HEAD").stdout
            (source / "whatsapp.el").write_text("uncommitted original work\n")
            (source / "private-untracked.txt").write_text("must stay untracked and local")
            bundle = root / "bundle"
            (bundle / "scripts").mkdir(parents=True)
            (bundle / "payload").mkdir()
            (bundle / "scripts/update-package.py").write_bytes((ROOT / "scripts/update-package.py").read_bytes())
            (bundle / "payload/whatsapp.el").write_text("fixture-after\n")
            manifest = {"format": 1, "version": "fixture", "audit_inputs": files, "files": [{"path": "whatsapp.el", "before": hashlib.sha256(b"fixture-before\n").hexdigest(), "after": update.digest(bundle / "payload/whatsapp.el"), "mode": 0o644}]}
            (bundle / "manifest.json").write_text(json.dumps(manifest))
            checked = ["manifest.json", "payload/whatsapp.el", "scripts/update-package.py"]
            (bundle / "SHA256SUMS").write_text("\n".join(update.digest(bundle / p) + "  " + p for p in checked) + "\n")
            real_run = subprocess.run
            def intercept(command, **kwargs):
                # Deliberately synthetic audit receipts: this fixture tests Git
                # isolation ONLY, never native Emacs/Guile correctness. The actual
                # installer has no way to enable this test-only interception.
                index = next((i for i, arg in enumerate(command)
                              if str(arg).endswith("/scripts/audit-workspace.py")), None)
                if index is not None:
                    candidate = Path(command[index + 1])
                    output = Path(command[command.index("--output") + 1])
                    scope = command[command.index("--scope") + 1]
                    run_id = command[command.index("--run-id") + 1]
                    auditor = update.load_auditor(candidate)
                    hashes = auditor.source_fingerprint(candidate)
                    names = [name for name, _ in auditor.checks(candidate, scope)] + ["source-integrity"]
                    output.mkdir(mode=0o700)
                    (output / "report.json").write_text(json.dumps({
                        "schema": 2, "run_id": run_id, "source": str(candidate),
                        "scope": scope, "passed": True, "source_sha256": hashes,
                        "source_sha256_after": hashes,
                        "checks": [{"check": name, "status": "PASS", "exit_code": 0} for name in names]}))
                    return subprocess.CompletedProcess(command, 0)
                return real_run(command, **kwargs)
            publication = root / "publication"
            with mock.patch.object(subprocess, "run", side_effect=intercept):
                self.assertEqual(commit.main([str(source), "--bundle", str(bundle), "--worktree", str(publication), "--commit-only"]), 0)
            self.assertEqual(git("rev-parse", "HEAD").stdout, original_head)
            self.assertEqual((source / "whatsapp.el").read_text(), "uncommitted original work\n")
            self.assertTrue((source / "private-untracked.txt").exists())
            self.assertFalse((publication / "private-untracked.txt").exists())
            self.assertEqual((publication / "whatsapp.el").read_text(), "fixture-after\n")
            status = subprocess.run(["git", "-C", str(publication), "status", "--porcelain"], capture_output=True, text=True, check=True)
            self.assertEqual(status.stdout, "")

if __name__ == "__main__":
    unittest.main()
