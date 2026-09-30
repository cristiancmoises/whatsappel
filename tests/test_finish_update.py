# SPDX-License-Identifier: AGPL-3.0-only
"""Real filesystem/process/HTTP checks plus explicitly mocked service sequencing.

Mocked updater results exercise ordering only: they never attest native audits.
No test restarts a real service or accesses a real messaging account.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
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
spec = importlib.util.spec_from_file_location('finish_fixture', ROOT / 'scripts/finish-update.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
VERSION = '3.2.0-rc17'
TOKEN = 'fixture-account-never-live'
BASE = 'http://127.0.0.1:7337'
RUNTIME = {'bridge_http': 200, 'bridge_version': VERSION, 'transport_api': True,
           'connected': True, 'logged_in': True, 'callback_state': 'yes', 'subscription_state': 'yes'}


def identity(pid=4321):
    return {'pid': pid, 'start_ticks': pid, 'source_verified': True,
            'account_verified': True, 'listener_verified': True}


class InstalledFiles(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'whatsappel.scm').write_bytes(b'fixture')
        self.manifest = {'version': VERSION, 'files': [{'path': 'whatsappel.scm',
                        'after': hashlib.sha256(b'fixture').hexdigest()}]}
    def test_matching_contents(self):
        self.assertTrue(m.installed_check(self.root, self.manifest)['matched'])
    def test_label_does_not_override_wrong_hash(self):
        (self.root / 'whatsappel.scm').write_text(VERSION)
        self.assertEqual(m.installed_check(self.root, self.manifest)['changed_count'], 1)
    def test_missing_file(self):
        (self.root / 'whatsappel.scm').unlink()
        self.assertEqual(m.installed_check(self.root, self.manifest)['missing'], ['whatsappel.scm'])
    def test_symlink_refused(self):
        (self.root / 'whatsappel.scm').unlink()
        (self.root / 'whatsappel.scm').symlink_to('/dev/null')
        with self.assertRaises(Exception): m.installed_check(self.root, self.manifest)
    def test_hash_read_is_not_an_evaluation(self):
        (self.root / 'whatsappel.scm').write_text('(system "DO NOT EXECUTE")')
        self.assertFalse(m.installed_check(self.root, self.manifest)['matched'])
    def test_traversal_is_refused(self):
        self.manifest['files'][0]['path'] = '../secret'
        with self.assertRaises(Exception): m.installed_check(self.root, self.manifest)
    def test_nonregular_source_is_refused(self):
        (self.root / 'whatsappel.scm').unlink(); (self.root / 'whatsappel.scm').mkdir()
        self.assertFalse(m.installed_check(self.root, self.manifest)['matched'])


class BoundedCommands(unittest.TestCase):
    def test_real_command_preserves_nonzero_exit(self):
        code, text = m.command([sys.executable, '-I', '-c', 'print("fixture"); raise SystemExit(7)'])
        self.assertEqual(code, 7); self.assertIn('fixture', text)
    def test_real_timeout_kills_child(self):
        start = time.monotonic()
        with self.assertRaises(m.FinishError):
            m.command([sys.executable, '-I', '-c', 'import time; time.sleep(30)'], timeout=.3)
        self.assertLess(time.monotonic() - start, 5)
    def test_real_output_cap(self):
        with self.assertRaises(m.FinishError):
            m.command([sys.executable, '-I', '-c', 'print("x"*10000)'], cap=128)
    def test_account_environment_not_passed_to_herd_command(self):
        with mock.patch.dict(os.environ, WHATSAPPEL_TOKEN='NO_LEAK', WUZAPI_TOKEN='NO_LEAK'):
            code, text = m.command([sys.executable, '-I', '-c', 'import os; print(os.getenv("WHATSAPPEL_TOKEN"));print(os.getenv("WUZAPI_TOKEN"))'])
        self.assertEqual(code, 0); self.assertNotIn('NO_LEAK', text)
    def test_pid_requires_success_and_unique_field(self):
        for status, text in [(1, 'Main PID: 123'), (0, 'Main PID: 1'), (0, 'Main PID: x'),
                             (0, 'Main PID: 22\nMain PID: 33'), (0, 'Command: secret')]:
            with self.subTest(status=status, shape=len(text)), self.assertRaises(m.FinishError):
                m.service_pid('/fixture/herd', lambda _: (status, text))
    def test_pid_parser_does_not_echo_command(self):
        commands = []
        def run(argv):
            commands.append(argv); return 0, '● Status\n  Main PID: 2763\n  Command: PRIVATE\n'
        self.assertEqual(m.service_pid('/fixture/herd', run), 2763)
        self.assertEqual(commands[0], ['/fixture/herd', '--log-history=0', 'status', 'whatsappel-bridge'])


class RuntimeProbe(unittest.TestCase):
    def fixture(self, data):
        calls = []
        def get(_base, _token, path, _timeout):
            calls.append(path); return data[path]
        return get, calls
    def test_independent_transport_without_health_flag(self):
        get, calls = self.fixture({'/health': {'status': 200, 'body': {}},
             '/transport/status': {'status': 200, 'body': {'version': VERSION, 'checking': False, 'connected': True}}})
        report = m.probe_runtime(BASE, TOKEN, fetch=get)
        self.assertTrue(report['transport_api']); self.assertTrue(m.expected_runtime(report, VERSION))
        self.assertEqual(calls, ['/health', '/transport/status'])
    def test_version_conflict_is_not_verified(self):
        get, _ = self.fixture({'/health': {'status': 200, 'body': {'version': '3.2.0-rc10'}},
             '/transport/status': {'status': 200, 'body': {'version': VERSION, 'checking': False}}})
        report = m.probe_runtime(BASE, TOKEN, fetch=get)
        self.assertTrue(report['conflicting_versions']); self.assertFalse(m.expected_runtime(report, VERSION))
    def test_untrusted_boolean_strings_and_raw_data_are_omitted(self):
        get, _ = self.fixture({'/health': {'status': 200, 'body': {'token': 'PRIVATE'}},
             '/transport/status': {'status': 200, 'body': {'version': VERSION, 'checking': False,
                 'connected': 'true', 'logged_in': True, 'callback_state': 'PRIVATE', 'token': 'PRIVATE', 'jid': 'PRIVATE'}}})
        report = m.probe_runtime(BASE, TOKEN, fetch=get)
        self.assertIsNone(report['connected']); self.assertEqual(report['callback_state'], 'unknown')
        self.assertNotIn('PRIVATE', json.dumps(report))
    def test_plain_200_is_not_capability(self):
        get, _ = self.fixture({'/health': {'status': 200, 'body': {}}, '/transport/status': {'status': 200, 'body': {'status': 'ok'}}})
        self.assertFalse(m.probe_runtime(BASE, TOKEN, fetch=get)['transport_api'])
    def test_health_denied_stops(self):
        get, calls = self.fixture({'/health': {'status': 401, 'body': {'error': 'PRIVATE'}}})
        self.assertFalse(m.probe_runtime(BASE, TOKEN, fetch=get)['transport_api'])
        self.assertEqual(calls, ['/health'])
    def test_missing_transport_uses_redacted_legacy_status(self):
        get, calls = self.fixture({'/health': {'status': 200, 'body': {}},
           '/transport/status': {'status': 404, 'body': {}},
           '/status': {'status': 200, 'body': {'data': {'connected': True, 'loggedIn': True, 'token': 'PRIVATE'}}}})
        report = m.probe_runtime(BASE, TOKEN, fetch=get)
        self.assertFalse(report['transport_api']); self.assertTrue(report['connected'])
        self.assertNotIn('PRIVATE', json.dumps(report)); self.assertEqual(len(calls), 3)
    def test_transport_auth_failure_does_not_probe_more_routes(self):
        get, calls = self.fixture({'/health': {'status': 200, 'body': {}}, '/transport/status': {'status': 401, 'body': {}}})
        m.probe_runtime(BASE, TOKEN, fetch=get); self.assertEqual(len(calls), 2)
    def test_polling_is_bounded(self):
        get, calls = self.fixture({'/health': {'status': 200, 'body': {}},
            '/transport/status': {'status': 200, 'body': {'version': VERSION, 'checking': True}}})
        m.probe_runtime(BASE, TOKEN, fetch=get, pause=lambda _: None)
        self.assertEqual(calls.count('/transport/status'), 5)
    def test_redirects_not_followed_actual_http(self):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                self.server.paths.append(self.path)
                self.send_response(302); self.send_header('Location', self.server.base + '/secret'); self.end_headers()
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.paths = []; server.base = 'http://127.0.0.1:' + str(server.server_port)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            report = m.probe_runtime(server.base, TOKEN)
            self.assertFalse(report['transport_api']); self.assertEqual(server.paths, ['/health'])
        finally:
            server.shutdown(); server.server_close(); thread.join(3)
    def test_real_http_contract_no_post(self):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                self.server.paths.append(self.path)
                body = {} if self.path == '/health' else {'version': VERSION, 'checking': False, 'connected': True, 'token': 'PRIVATE'}
                raw = json.dumps(body).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
            def do_POST(self):
                self.server.paths.append('UNEXPECTED POST'); self.send_response(500); self.end_headers()
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler); server.paths = []
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            report = m.probe_runtime('http://127.0.0.1:' + str(server.server_port), TOKEN)
            self.assertTrue(m.expected_runtime(report, VERSION)); self.assertNotIn('PRIVATE', json.dumps(report))
            self.assertEqual(server.paths, ['/health', '/transport/status'])
        finally:
            server.shutdown(); server.server_close(); thread.join(3)


class ProcessGuards(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.proc = Path(self.temp.name) / 'proc'; self.pid = 4321
        self.p = self.proc / str(self.pid); (self.p / 'fd').mkdir(parents=True); (self.p / 'net').mkdir()
        self.target = Path(self.temp.name) / 'source'; self.target.mkdir()
        (self.p / 'status').write_text('Name:\tguile\nUid:\t1000\t1000\t1000\t1000\n')
        (self.p / 'stat').write_bytes(b'4321 (guile fixture) S ' + b'0 ' * 18 + b'12345 0 0')
        (self.p / 'cmdline').write_bytes(b'/gnu/store/example/bin/guile\0' + os.fsencode(self.target / 'whatsappel.scm') + b'\0')
        (self.p / 'environ').write_bytes(b'WHATSAPPEL_TOKEN=' + TOKEN.encode() + b'\0WHATSAPPEL_PORT=7337\0')
        (self.p / 'fd' / '4').symlink_to('socket:[999]')
        (self.p / 'net' / 'tcp').write_text('header\n0: 0100007F:1CA9 00000000:0000 0A 0 0 0 1000 0 999\n')
    def inspect(self): return m.inspect_service(self.pid, self.target, BASE, TOKEN, proc_root=self.proc, uid=1000)
    def test_match(self): self.assertTrue(self.inspect()['listener_verified'])
    def test_wrong_uid(self):
        (self.p / 'status').write_text('Uid:\t0\t0\t0\t0\n')
        with self.assertRaises(m.FinishError): self.inspect()
    def test_wrong_source(self):
        (self.p / 'cmdline').write_bytes(b'/usr/bin/guile\0/tmp/other.scm\0')
        with self.assertRaises(m.FinishError): self.inspect()
    def test_eval_wrapper_is_not_direct_script(self):
        (self.p / 'cmdline').write_bytes(b'/usr/bin/guile\0-c\0' + os.fsencode(self.target / 'whatsappel.scm') + b'\0')
        with self.assertRaises(m.FinishError): self.inspect()
    def test_account_mismatch_is_redacted(self):
        (self.p / 'environ').write_bytes(b'WHATSAPPEL_TOKEN=PRIVATE_WRONG\0')
        with self.assertRaises(m.FinishError) as err: self.inspect()
        self.assertNotIn('PRIVATE_WRONG', str(err.exception))
    def test_port_mismatch(self):
        with self.assertRaises(m.FinishError): m.inspect_service(self.pid, self.target, 'http://127.0.0.1:1', TOKEN, self.proc, 1000)
    def test_socket_belongs_to_another_process(self):
        (self.p / 'fd' / '4').unlink(); (self.p / 'fd' / '4').symlink_to('socket:[888]')
        with self.assertRaises(m.FinishError): self.inspect()
    def test_no_remote_or_ambiguous_localhost_activation(self):
        for origin in ('https://bridge.example', 'http://localhost:7337', 'http://192.0.2.1:7337', 'http://user:secret@127.0.0.1:7337'):
            with self.subTest(origin=origin), self.assertRaises(m.FinishError): m.local_endpoint(origin)
    def test_duplicate_account_key(self):
        with self.assertRaises(m.FinishError): m.process_environment(b'WHATSAPPEL_TOKEN=x\0WHATSAPPEL_TOKEN=y\0')
    def test_real_owned_listener(self):
        sock = socket.socket(); sock.bind(('127.0.0.1', 0)); sock.listen()
        try:
            self.assertTrue(m.owns_listener(Path('/proc') / str(os.getpid()), '127.0.0.1', sock.getsockname()[1]))
        finally: sock.close()
    def test_symlink_process_input(self):
        (self.p / 'environ').unlink(); (self.p / 'environ').symlink_to('/dev/null')
        with self.assertRaises(OSError): self.inspect()


class Sequencing(unittest.TestCase):
    """Fake service/update results test boundaries, never native success."""
    def setUp(self):
        InstalledFiles.setUp(self)
        self.fake_uid = os.getuid() or 1000
        self.bundle = self.root / 'bundle'; self.bundle.mkdir()
        self.settings = self.root / '.env'; self.settings.write_text('WHATSAPPEL_TOKEN=' + TOKEN + '\nWHATSAPPEL_PORT=7337\n'); self.settings.chmod(0o600)
        if os.getuid() == 0:
            os.chown(self.settings, self.fake_uid, self.fake_uid)
        self.report = {'phase': 'preflight', 'installed': False, 'restart_attempted': False, 'service_restarted': False}
        self.calls = []; self.restarted = False
        self.envpatch = mock.patch.dict(os.environ, {}, clear=True); self.envpatch.start(); self.addCleanup(self.envpatch.stop)
    def run_command(self, args):
        self.calls.append(args)
        if args[1] == 'restart': self.restarted = True; return 0, 'do not publish raw output'
        return 0, 'Main PID: ' + str(4322 if self.restarted else 4321)
    def perform_update(self): self.calls.append('update'); return 0
    def inspect(self, pid, *_): return identity(pid)
    def run_work(self, **kwargs):
        options = dict(perform_update=self.perform_update, inspect=self.inspect, run=self.run_command,
                       diagnose=lambda *_a, **_k: dict(RUNTIME), pause=lambda _: None)
        options.update(kwargs)
        with mock.patch.object(m.os, 'getuid', return_value=self.fake_uid), mock.patch.object(m.shutil, 'which', return_value='/fixture/herd'), mock.patch.object(m.update, 'verify_bundle', return_value=self.manifest):
            return m.run_workflow(self.root, self.bundle, self.manifest, self.report, **options)
    def test_failed_update_cannot_restart(self):
        with self.assertRaises(m.FinishError): self.run_work(restart=True, perform_update=lambda: 1)
        self.assertFalse(self.restarted); self.assertFalse(self.report['installed'])
    def test_exception_in_audit_cannot_restart(self):
        def fail(): raise RuntimeError('fixture native failure')
        with self.assertRaises(RuntimeError): self.run_work(restart=True, perform_update=fail)
        self.assertFalse(self.restarted)
    def test_ordering_success_is_fixture_not_native_attestation(self):
        self.assertEqual(self.run_work(restart=True), 0)
        actions = [a if isinstance(a, str) else a[1] for a in self.calls]
        self.assertLess(actions.index('update'), actions.index('restart'))
        self.assertTrue(self.report['runtime_verified'])
    def test_wrong_installed_bytes_cannot_restart(self):
        def wrong(): (self.root / 'whatsappel.scm').write_text('WRONG'); return 0
        with self.assertRaises(m.FinishError): self.run_work(restart=True, perform_update=wrong)
        self.assertFalse(self.restarted)
    def test_check_never_installs_or_restarts(self):
        self.assertEqual(self.run_work(check=True), 0); self.assertEqual(self.calls, [])
    def test_check_reports_mismatch_without_install(self):
        (self.root / 'whatsappel.scm').write_text('old')
        self.assertEqual(self.run_work(check=True), 2); self.assertEqual(self.calls, [])
        self.assertEqual(self.report['phase'], 'files-mismatch')
    def test_update_does_not_restart_without_flag(self):
        self.assertEqual(self.run_work(), 0); self.assertEqual(self.calls, ['update'])
    def test_stale_live_version_not_success(self):
        self.assertEqual(self.run_work(diagnose=lambda *_a, **_k: {**RUNTIME, 'bridge_version': '3.2.0-rc10'}), 2)
        self.assertEqual(self.report['phase'], 'installed-not-active')
    def test_registration_failure_is_separate_from_runtime(self):
        self.assertEqual(self.run_work(diagnose=lambda *_a, **_k: {**RUNTIME, 'callback_state': 'no'}), 0)
        self.assertFalse(self.report['delivery_registration_verified'])
    def test_account_change_during_audit_refuses_restart(self):
        def change(): self.settings.write_text('WHATSAPPEL_TOKEN=another-account\n'); return 0
        with self.assertRaises(m.FinishError): self.run_work(restart=True, perform_update=change)
        self.assertFalse(self.restarted)
    def test_respawn_during_audit_refuses_restart(self):
        seen = [0]
        def changed(pid, *_):
            seen[0] += 1; return identity(pid + seen[0])
        with self.assertRaises(m.FinishError): self.run_work(restart=True, inspect=changed)
        self.assertFalse(self.restarted)
    def test_unverified_service_stops_before_update(self):
        def wrong(*_): raise m.FinishError('wrong source')
        with self.assertRaises(m.FinishError): self.run_work(restart=True, inspect=wrong)
        self.assertNotIn('update', self.calls)
    def test_restart_error_not_reported_as_success(self):
        def fail(args):
            if args[1] == 'restart': return 1, 'PRIVATE'
            return self.run_command(args)
        with self.assertRaises(m.FinishError) as err: self.run_work(restart=True, run=fail)
        self.assertTrue(self.report['installed']); self.assertFalse(self.report['service_restarted'])
        self.assertNotIn('PRIVATE', str(err.exception))
    def test_old_pid_after_restart_is_not_accepted(self):
        with self.assertRaises(m.FinishError): self.run_work(restart=True, inspect=lambda *_: identity())
        self.assertFalse(self.report['service_restarted'])
    def test_service_change_during_final_probe_is_not_success(self):
        switched = [False]
        def probe(*_a, **_k): switched[0] = True; return dict(RUNTIME)
        def inspect(pid, *_): return identity(pid + (10 if switched[0] else 0))
        with self.assertRaises(m.FinishError): self.run_work(restart=True, diagnose=probe, inspect=inspect)
        self.assertTrue(self.report['service_restarted'])
    def test_source_changes_during_health_probe_are_not_accepted(self):
        def mutate(*_a, **_k): (self.root / 'whatsappel.scm').write_text('changed after install'); return dict(RUNTIME)
        self.assertEqual(self.run_work(diagnose=mutate), 2)
        self.assertFalse(self.report['runtime_verified'])



class ActualCLI(unittest.TestCase):
    def test_stable_release_passes_version_validation(self):
        path = self.bundle / 'manifest.json'
        manifest = json.loads(path.read_text())
        manifest['version'] = '3.3.0'
        path.write_text(json.dumps(manifest))
        (self.bundle / 'SHA256SUMS').write_text(''.join(
            hashlib.sha256((self.bundle / name).read_bytes()).hexdigest() + '  ' + name + '\n'
            for name in ('manifest.json', 'payload/whatsappel.scm')))
        process = self.run_cli('--check')
        self.assertEqual(process.returncode, 2, process.stdout + process.stderr)
        report = json.loads((self.root / 'report.json').read_text())
        self.assertEqual(report['expected_version'], '3.3.0')
        self.assertNotEqual(report['phase'], 'preflight')
        self.assertFalse(report['runtime_verified'])

    """Actual CLI subprocess with a tiny verified fixture package and local HTTP."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / 'installed'; self.target.mkdir()
        self.bundle = self.root / 'bundle'; (self.bundle / 'payload').mkdir(parents=True)
        (self.bundle / 'payload' / 'whatsappel.scm').write_bytes(b'fixture no code executed')
        (self.target / 'whatsappel.scm').write_bytes(b'fixture no code executed')
        manifest = {'format': 1, 'version': VERSION, 'audit_inputs': [], 'files': [
            {'path': 'whatsappel.scm', 'before': None, 'after': hashlib.sha256(b'fixture no code executed').hexdigest(), 'mode': 420}]}
        (self.bundle / 'manifest.json').write_text(json.dumps(manifest))
        (self.bundle / 'SHA256SUMS').write_text(''.join(
            hashlib.sha256((self.bundle / name).read_bytes()).hexdigest() + '  ' + name + '\n'
            for name in ('manifest.json', 'payload/whatsappel.scm')))
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                self.server.calls.append(self.path)
                body = {'version': VERSION} if self.path == '/health' else {
                    'version': VERSION, 'checking': False, 'connected': True, 'token': 'PRIVATE_CLI_SECRET'}
                raw = json.dumps(body).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler); self.server.calls = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.addCleanup(self.cleanup_server)
        settings = self.target / '.env'
        settings.write_text('WHATSAPPEL_TOKEN=' + TOKEN + '\nWHATSAPPEL_PORT=' + str(self.server.server_port) + '\n')
        settings.chmod(0o600)
    def cleanup_server(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(3)
    def run_cli(self, *flags):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('WHATSAPPEL_', 'WUZAPI_'))}
        return subprocess.run([sys.executable, '-I', str(ROOT / 'scripts/finish-update.py'),
            str(self.target), '--bundle', str(self.bundle), '--output', str(self.root / 'report.json'), *flags],
            capture_output=True, text=True, timeout=10, env=env)
    def test_real_check_cli_private_report_no_source_changes(self):
        before = {p.name: p.read_bytes() for p in self.target.iterdir()}
        process = self.run_cli('--check')
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        report = json.loads((self.root / 'report.json').read_text())
        self.assertTrue(report['read_only']); self.assertFalse(report['service_restarted'])
        self.assertEqual(self.server.calls, ['/health', '/transport/status'])
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.target.iterdir()})
        self.assertEqual((self.root / 'report.json').stat().st_mode & 0o777, 0o600)
        self.assertNotIn(TOKEN, process.stdout + process.stderr); self.assertNotIn('PRIVATE_CLI_SECRET', process.stdout)
    def test_conflicting_check_restart_flags_do_not_connect(self):
        self.assertNotEqual(self.run_cli('--check', '--restart-local').returncode, 0)
        self.assertEqual(self.server.calls, []); self.assertFalse((self.root / 'report.json').exists())
    def test_existing_report_not_overwritten(self):
        (self.root / 'report.json').write_text('keep-existing')
        self.assertNotEqual(self.run_cli('--check').returncode, 0)
        self.assertEqual((self.root / 'report.json').read_text(), 'keep-existing')
        self.assertEqual(self.server.calls, [])
    def test_mismatched_target_returns_two_and_reports_not_ready(self):
        (self.target / 'whatsappel.scm').write_text('old source')
        process = self.run_cli('--check')
        self.assertEqual(process.returncode, 2, process.stdout + process.stderr)
        report = json.loads((self.root / 'report.json').read_text())
        self.assertEqual(report['phase'], 'files-mismatch'); self.assertFalse(report['runtime_verified'])
    def test_tampered_package_stops_before_network(self):
        (self.bundle / 'payload' / 'whatsappel.scm').write_text('tampered')
        process = self.run_cli('--check')
        self.assertNotEqual(process.returncode, 0); self.assertEqual(self.server.calls, [])


if __name__ == '__main__': unittest.main()
