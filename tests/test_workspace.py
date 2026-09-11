# SPDX-License-Identifier: AGPL-3.0-only
"""New workspace worker/installer tests; no real credentials or WhatsApp traffic."""
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from urllib import error, request

ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


worker = load("workspace_worker", "media-worker.py")
installer = load("workspace_installer", "update-package.py")
launcher = load("workspace_launcher", "launch-whatsappel.py")


class Reply(io.BytesIO):
    status = 200


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.file = self.root / "photo.png"
        self.file.write_bytes(b"synthetic original bytes\x00\xff")
        self.spec = {"url": "http://127.0.0.1:7337", "token": "test-only-token", "target": "5511", "file": str(self.file), "kind": "image"}

    def tearDown(self):
        self.tmp.cleanup()

    def test_orig_bytes_survive_payload(self):
        kind, data = worker.media_payload(self.spec)
        self.assertEqual(kind, "image")
        self.assertEqual(data["to"], "5511")
        self.assertEqual(base64.b64decode(data["data"].split(",")[1]), self.file.read_bytes())

    def test_unsupported_inline_formats_are_documents(self):
        for extension, kind in [("gif", "gif"), ("wav", "audio"), ("heic", "image"), ("zip", "video")]:
            with self.subTest(extension=extension):
                file = self.root / ("Original." + extension)
                file.write_bytes(b"unchanged")
                mode, data = worker.media_payload({**self.spec, "file": str(file), "kind": kind})
                self.assertEqual("document", mode)
                self.assertEqual(file.name, data["filename"])
                self.assertEqual(b"unchanged", base64.b64decode(data["data"].split(",")[1]))

    def test_origin_restrictions(self):
        for url in ["http://evil.example", "file:///etc/passwd", "https://u:p@example.com", "https://example.com/path", "https://example.com/?token=x", "https://example.com/#x", "https://example.com:bad", "http://127.0.0.1\n"]:
            with self.subTest(url=url), self.assertRaises(worker.WorkerError):
                worker.bridge_url(url)
        for url in ["http://127.0.0.1:7337", "http://[::1]:7337", "https://bridge.example"]:
            self.assertEqual(worker.bridge_url(url), url)

    def test_header_injection_is_refused_before_network(self):
        for token in ["", "x\r\nAuthorization: stolen", "x\0", "é"]:
            with self.subTest(token=repr(token)), self.assertRaises(worker.WorkerError):
                worker.upload({**self.spec, "token": token}, opener=mock.Mock())

    def test_invalid_targets_are_rejected(self):
        for value in ["", "5511 x", "\r\n", "a" * 257, None, []]:
            with self.subTest(value=value), self.assertRaises(worker.WorkerError):
                worker.media_payload({**self.spec, "target": value})

    def test_file_guards(self):
        link = self.root / "symlink.png"
        link.symlink_to(self.file)
        empty = self.root / "empty.png"
        empty.touch()
        for file in [link, empty, self.root, self.root / "missing"]:
            with self.subTest(file=file.name), self.assertRaises(worker.WorkerError):
                worker.bounded_file(str(file))
        with self.assertRaises(worker.WorkerError):
            worker.bounded_file(str(self.file), limit=1)
        with self.assertRaises(worker.WorkerError):
            worker.bounded_file("relative.png")

    def test_fifo_never_blocks(self):
        fifo = self.root / "pipe.png"
        os.mkfifo(fifo)
        with self.assertRaises(worker.WorkerError):
            worker.bounded_file(str(fifo))

    def test_success_requires_upstream_confirmation(self):
        opener = mock.Mock()
        opener.open.return_value = Reply(b'{"wuzapi_status":200,"data":{"success":true,"data":{"Id":"fixture-id"}}}')
        self.assertTrue(worker.upload(self.spec, opener)["ok"])
        req = opener.open.call_args.args[0]
        self.assertEqual(req.full_url, "http://127.0.0.1:7337/send/image")
        self.assertEqual(req.get_header("X-whatsappel-token"), "test-only-token")
        self.assertNotIn("test-only-token", req.full_url)
        self.assertEqual(opener.open.call_count, 1)
        for response in [b"{}", b"", b"[]", b"not-json", b'{"success":false}', b'{"wuzapi_status":500}']:
            with self.subTest(response=response):
                opener.open.return_value = Reply(response)
                result = worker.upload(self.spec, opener)
                self.assertFalse(result["ok"])
                self.assertTrue(result["uncertain"])

    def test_network_errors_never_retry_or_echo_secrets(self):
        opener = mock.Mock()
        opener.open.side_effect = error.URLError("test-only-token deliberately in exception")
        result = worker.upload(self.spec, opener)
        self.assertEqual(opener.open.call_count, 1)
        self.assertTrue(result["uncertain"])
        self.assertNotIn("test-only-token", json.dumps(result))

    def test_redirects_are_rejected(self):
        with self.assertRaises(worker.WorkerError):
            worker.NoRedirect().redirect_request(request.Request("https://origin.example"), None, 302, "redirect", {}, "https://attacker.example")

    def test_response_size_is_bounded(self):
        opener = mock.Mock()
        opener.open.return_value = Reply(b"x" * (worker.MAX_RESPONSE + 1))
        result = worker.upload(self.spec, opener)
        self.assertFalse(result["ok"])
        self.assertTrue(result["uncertain"])

    def test_output_must_be_private_new_and_absolute(self):
        with self.assertRaises(worker.WorkerError):
            worker.private_output(str(self.file))
        with self.assertRaises(worker.WorkerError):
            worker.private_output("relative.mp4")
        self.root.chmod(0o755)
        with self.assertRaises(worker.WorkerError):
            worker.private_output(str(self.root / "new.mp4"))
        self.root.chmod(0o700)
        self.assertEqual(worker.private_output(str(self.root / "new.mp4")), self.root / "new.mp4")

    def test_gif_size_and_magic_checked_before_decoder(self):
        for raw in [b"not-a-gif", b"GIF89a", b"GIF89a" + b"\xff\xff" * 2, b"GIF89a\0\0\0\0"]:
            self.file.write_bytes(raw)
            with self.subTest(raw=raw), self.assertRaises(worker.WorkerError):
                worker.convert_gif({"file": str(self.file), "output": str(self.root / "new.mp4")})

    def test_gif_argv_is_not_a_shell_command(self):
        path = "/tmp/a $(touch nope); quote'.gif"
        command = worker.gif_command(path, "/tmp/private/new.mp4", "/usr/bin/ffmpeg")
        self.assertIn(path, command)
        self.assertIn("file,pipe", command)
        self.assertIn("-nostdin", command)
        self.assertEqual(command[-3:], ["-f", "mp4", "/tmp/private/new.mp4"])

    def test_cli_diagnostics_do_not_echo_secret_json(self):
        proc = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/media-worker.py"), "send"],
                              input=json.dumps({"token": "test-only-token", "url": "invalid"}), text=True, capture_output=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn("test-only-token", proc.stdout + proc.stderr)
        self.assertFalse(json.loads(proc.stdout)["ok"])

    def test_control_input_bounded(self):
        proc = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/media-worker.py"), "send"],
                              input="x" * (worker.MAX_CONTROL + 1), text=True, capture_output=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("too large", json.loads(proc.stdout)["error"])

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg/ffprobe absent")
    def test_actual_gif_to_mp4_preserves_original(self):
        # A tiny deterministic GIF avoids an extra Pillow dependency in deployed tests.
        gif = self.root / "tiny.gif"
        gif.write_bytes(base64.b64decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        before = gif.read_bytes()
        output = self.root / "converted.mp4"
        result = worker.convert_gif({"file": str(gif), "output": str(output)})
        self.assertTrue(result["ok"])
        self.assertEqual(before, gif.read_bytes())
        self.assertFalse((self.root / "input.gif").exists())
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        probe = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(output)], capture_output=True, text=True, check=True)
        video = json.loads(probe.stdout)["streams"][0]
        self.assertEqual(video["codec_name"], "h264")
        self.assertEqual(video["pix_fmt"], "yuv420p")
        self.assertEqual(video["width"] % 2, 0)
        self.assertEqual(video["height"] % 2, 0)
        self.assertLessEqual(video["width"], 720)

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg/ffprobe absent")
    def test_actual_opus_container_without_microphone(self):
        output = self.root / "synthetic.ogg"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2", "-ac", "1", "-ar", "48000", "-c:a", "libopus", "-b:a", "32k", str(output)], check=True, timeout=20)
        probe = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(output)], capture_output=True, text=True, check=True)
        audio = json.loads(probe.stdout)["streams"][0]
        self.assertEqual(audio["codec_name"], "opus")
        self.assertEqual(audio["channels"], 1)
        self.assertEqual(audio["sample_rate"], "48000")


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.target = self.root / "installed"
        self.target.mkdir()
        (self.target / "whatsapp.el").write_bytes(b"old source")
        (self.target / ".env").write_bytes(b"private state that must be preserved")
        self.bundle = self.root / "bundle"
        (self.bundle / "payload").mkdir(parents=True)
        (self.bundle / "payload/whatsapp.el").write_bytes(b"new source")
        self.item = {"path": "whatsapp.el", "before": installer.digest(self.target / "whatsapp.el"), "after": installer.digest(self.bundle / "payload/whatsapp.el"), "mode": 0o644}
        self.spec = {"format": 1, "version": "test", "files": [self.item], "audit_inputs": []}
        (self.bundle / "manifest.json").write_text(json.dumps(self.spec))
        (self.bundle / "SHA256SUMS").write_text("\n".join(installer.digest(self.bundle / p) + "  " + p for p in ["manifest.json", "payload/whatsapp.el"]) + "\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_bundle_checksums_detect_tampering(self):
        self.assertEqual(installer.verify_bundle(self.bundle)["version"], "test")
        (self.bundle / "payload/whatsapp.el").write_bytes(b"changed")
        with self.assertRaises(installer.UpdateError):
            installer.verify_bundle(self.bundle)

    def test_paths_cannot_escape_or_target_credentials(self):
        for name in ["../out", "/tmp/out", ".env", "a/../out", "a//out", "a/./out", ".git/config", "a\\b", "key", "x\n"]:
            with self.subTest(name=name), self.assertRaises(installer.UpdateError):
                installer.safe_relative(name)

    def test_preflight_refuses_unrecognized_edits(self):
        self.assertEqual(len(installer.preflight(self.target, self.bundle, self.spec)), 1)
        (self.target / "whatsapp.el").write_bytes(b"Codex in-progress changes")
        with self.assertRaises(installer.UpdateError):
            installer.preflight(self.target, self.bundle, self.spec)
        self.assertEqual((self.target / "whatsapp.el").read_bytes(), b"Codex in-progress changes")

    def test_preflight_is_idempotent(self):
        (self.target / "whatsapp.el").write_bytes(b"new source")
        self.assertEqual(installer.preflight(self.target, self.bundle, self.spec), [])

    def test_symlink_destination_is_refused(self):
        (self.target / "whatsapp.el").unlink()
        (self.target / "whatsapp.el").symlink_to(self.bundle / "payload/whatsapp.el")
        with self.assertRaises(installer.UpdateError):
            installer.preflight(self.target, self.bundle, self.spec)

    def test_real_transaction_preserves_state_and_rolls_back(self):
        (self.target / "whatsapp.elc").write_bytes(b"old bytecode")
        before = (self.target / ".env").read_bytes()
        backup = self.root / "backup"
        installer.apply_files(self.target, self.bundle, [self.item], backup)
        self.assertEqual((self.target / "whatsapp.el").read_bytes(), b"new source")
        self.assertFalse((self.target / "whatsapp.elc").exists())
        self.assertEqual((self.target / ".env").read_bytes(), before)
        installer.restore_backup(backup)
        self.assertEqual((self.target / "whatsapp.el").read_bytes(), b"old source")
        self.assertEqual((self.target / "whatsapp.elc").read_bytes(), b"old bytecode")
        self.assertEqual((self.target / ".env").read_bytes(), before)

    def test_rollback_does_not_overwrite_later_changes(self):
        backup = self.root / "backup"
        installer.apply_files(self.target, self.bundle, [self.item], backup)
        (self.target / "whatsapp.el").write_bytes(b"later edits")
        with self.assertRaises(installer.UpdateError):
            installer.restore_backup(backup)
        self.assertEqual((self.target / "whatsapp.el").read_bytes(), b"later edits")

    def test_failed_audit_keeps_installed_source_unchanged(self):
        def stage_fixture(target, bundle, spec, candidate):
            # Only the failed exit is mocked; prepare actual candidate bytes so
            # stronger pre-audit integrity checks are exercised too.
            candidate.mkdir()
            (candidate / "whatsapp.el").write_bytes((bundle / "payload/whatsapp.el").read_bytes())
            (candidate / "scripts").mkdir()
            (candidate / "scripts/audit-workspace.py").write_bytes((ROOT / "scripts/audit-workspace.py").read_bytes())
        with mock.patch.object(installer, "stage_candidate", side_effect=stage_fixture), mock.patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaises(installer.UpdateError):
                installer.main([str(self.target), "--bundle", str(self.bundle), "--apply"])
        self.assertEqual((self.target / "whatsapp.el").read_bytes(), b"old source")
        self.assertFalse(list(self.root.glob("whatsappel-backup-*")))

    def test_desktop_launcher_is_scoped_and_has_no_token(self):
        entries = installer.desktop_entries(self.target, self.root)
        self.assertEqual(entries[0][0], self.root / ".local/bin/whatsappel")
        text = b"\n".join(e[1] for e in entries).decode()
        self.assertNotIn("WHATSAPPEL_TOKEN", text)
        self.assertIn("Terminal=false", text)

    def test_check_mode_does_not_install(self):
        self.assertEqual(installer.main([str(self.target), "--bundle", str(self.bundle)]), 0)
        self.assertEqual((self.target / "whatsapp.el").read_bytes(), b"old source")


class LauncherTests(unittest.TestCase):
    def test_env_is_parsed_not_executed(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / ".env"
            path.write_text('export WHATSAPPEL_TOKEN="test-only-token"\nexport WHATSAPPEL_PUBLIC_URL="http://127.0.0.1:7337"\nexport UNRELATED="ignored"\n')
            path.chmod(0o600)
            self.assertEqual(launcher.literal_environment(path), {"WHATSAPPEL_TOKEN": "test-only-token", "WHATSAPPEL_PUBLIC_URL": "http://127.0.0.1:7337"})
            path.write_text('WHATSAPPEL_TOKEN="$(touch attacker-output)"\n')
            with self.assertRaises(ValueError):
                launcher.literal_environment(path)
            self.assertFalse((Path(td) / "attacker-output").exists())

    def test_emacs_command_contains_no_secret_or_shell(self):
        cmd = launcher.launch_command(Path('/tmp/quote"; strange'), "/usr/bin/emacs")
        self.assertEqual(cmd[0], "/usr/bin/emacs")
        self.assertIn("--eval", cmd)
        self.assertNotIn("bash", cmd)
        self.assertNotIn("WHATSAPPEL_TOKEN", " ".join(cmd))
        self.assertIn('quote\\"', cmd[-1])

    def test_world_writable_env_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / ".env"
            path.write_text("WHATSAPPEL_TOKEN=test-only-token")
            path.chmod(0o666)
            with self.assertRaises(ValueError):
                launcher.literal_environment(path)

if __name__ == "__main__":
    unittest.main()
