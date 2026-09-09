"""Publication/apply regression tests. All forge requests and pushes are mocked.

Git integration tests use disposable local repositories; no live destinations or
real tokens are used. Run: python3 -m unittest discover -s tests -p test_publish.py
"""

import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


publisher = load_module("whatsappel_publisher", "publish.py")
applier = load_module("whatsappel_applier", "apply-update.py")


def result(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


def options(**overrides):
    values = dict(dry_run=False, create_missing=False, visibility=None,
                  credentials_dir="/unused", timeout=180)
    values.update(overrides)
    return argparse.Namespace(**values)


class CredentialTests(unittest.TestCase):
    def setUp(self):
        self.forge = publisher.Forge("github", "test-token-not-real")
        self.fields = {"protocol": "https", "host": "github.com", "path": "cristiancmoises/whatsappel.git"}

    def test_credentials_scoped_to_protocol_host_account_and_repository(self):
        self.assertTrue(publisher.credential_allowed(self.fields, self.forge))
        for field, value in (
            ("protocol", "http"), ("host", "github.com.attacker.example"),
            ("host", "evil.example"), ("host", "github.com:80"),
            ("path", "cristiancmoises/another.git"), ("path", "attacker/whatsappel.git"),
            ("path", "/cristiancmoises/whatsappel.git"), ("username", "attacker"),
        ):
            with self.subTest(field=field, value=value):
                self.assertFalse(publisher.credential_allowed({**self.fields, field: value}, self.forge))

    def test_socket_helper_returns_secret_only_for_the_exact_repository(self):
        # Some CI sandboxes prohibit all socket creation, including local IPC.
        try:
            probe = publisher.socket.socket(publisher.socket.AF_UNIX, publisher.socket.SOCK_STREAM)
            probe.close()
        except PermissionError:
            self.skipTest("Runtime prohibits AF_UNIX socket creation (EPERM); scoped helper checks are covered separately")
        with tempfile.TemporaryDirectory() as temporary:
            with publisher.credential_socket(self.forge, temporary) as socket_path:
                command = [sys.executable, str(SCRIPTS / "publish.py"), "--credential", socket_path, "get"]
                correct = subprocess.run(command, input="protocol=https\nhost=github.com\npath=cristiancmoises/whatsappel.git\n\n",
                                         capture_output=True, text=True, timeout=10)
                self.assertEqual(correct.returncode, 0)
                self.assertIn("password=test-token-not-real", correct.stdout)
                wrong = subprocess.run(command, input="protocol=https\nhost=evil.example\npath=cristiancmoises/whatsappel.git\n\n",
                                       capture_output=True, text=True, timeout=10)
                self.assertNotEqual(wrong.returncode, 0)
                self.assertNotIn(self.forge.token, wrong.stdout + wrong.stderr)
                self.assertNotIn(self.forge.token, " ".join(command))
                self.assertEqual(os.stat(socket_path).st_mode & 0o777, 0o600)
            self.assertFalse(Path(socket_path).exists())

    def test_credential_store_operation_creates_no_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            process = subprocess.run(
                [sys.executable, str(SCRIPTS / "publish.py"), "--credential", temporary + "/none", "store"],
                input="password=test-token-not-real\n", capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(process.returncode, 0)
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_unavailable_socket_is_a_safe_reportable_failure(self):
        with mock.patch.object(publisher.socketserver, "UnixStreamServer", side_effect=PermissionError("EPERM")):
            with self.assertRaisesRegex(publisher.PublishError, "Cannot open a local credential socket"):
                with publisher.credential_socket(self.forge, "/tmp"):
                    self.fail("Socket should not start")

    def test_trace_config_and_askpass_environment_are_removed(self):
        with mock.patch.dict(os.environ, {
            "GIT_TRACE": "1", "GIT_TRACE_CURL": "1", "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.sslVerify", "GIT_CONFIG_VALUE_0": "false",
            "GIT_ASKPASS": "evil", "SSH_ASKPASS": "evil", "SSLKEYLOGFILE": "/tmp/secrets",
        }):
            env = publisher.clean_environment()
        for key in ("GIT_TRACE", "GIT_TRACE_CURL", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "SSH_ASKPASS", "SSLKEYLOGFILE"):
            self.assertNotIn(key, env)
        self.assertEqual(env["GIT_ASKPASS"], "/bin/false")
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], os.devnull)

    def test_remote_error_body_never_leaks_a_token(self):
        with mock.patch.object(publisher.subprocess, "run", return_value=result(1, stderr="fatal: secret-token Authentication failed")):
            with self.assertRaises(publisher.PublishError) as caught:
                publisher.git("/tmp", "push", "https://example.invalid/repo")
        self.assertNotIn("secret-token", str(caught.exception))

    def test_api_redirect_is_refused(self):
        with self.assertRaisesRegex(publisher.PublishError, "redirects are refused"):
            publisher.NoRedirect().redirect_request(None, None, 302, "Moved", {}, "https://evil.example/")

    def test_git_network_settings_disable_redirects_and_extra_credentials(self):
        config = publisher.network_config("/private/socket")
        self.assertIn("credential.helper=", config)
        self.assertIn("http.followRedirects=false", config)
        self.assertIn("http.sslVerify=true", config)
        self.assertIn("credential.useHttpPath=true", config)
        self.assertIn("protocol.allow=never", config)


class ForgeTests(unittest.TestCase):
    def test_account_identity_is_checked_before_repo_mutations(self):
        forge = publisher.Forge("github", "test-token")
        forge.api_call = mock.Mock(return_value=(200, {"login": "wrong-user"}))
        with self.assertRaisesRegex(publisher.PublishError, "different account"):
            forge.inspect()
        forge.api_call.assert_called_once_with("GET", "/user")

    def test_malformed_login_does_not_escape_as_attribute_error(self):
        for account in ([], {"login": None}, {"login": 17}):
            forge = publisher.Forge("github", "test-token")
            forge.api_call = mock.Mock(return_value=(200, account))
            with self.subTest(account=account), self.assertRaises(publisher.PublishError):
                forge.inspect()

    def test_malformed_permissions_fail_closed(self):
        forge = publisher.Forge("github", "test-token")
        forge.api_call = mock.Mock(side_effect=[(200, {"login": "cristiancmoises"}),
                                                 (200, {"private": False, "permissions": []})])
        with self.assertRaisesRegex(publisher.PublishError, "invalid repository permissions"):
            forge.inspect()

    def test_server_failure_is_not_classified_as_invalid_token(self):
        message = publisher.api_failure(500, "account verification")
        self.assertIn("does not prove an invalid token", message)

    def test_create_requires_explicit_visibility_and_empty_repo(self):
        forge = publisher.Forge("forgejo-co", "test-token")
        forge.api_call = mock.Mock()
        with self.assertRaisesRegex(publisher.PublishError, "requires --visibility"):
            forge.create(None, "main")
        forge.api_call.assert_not_called()
        forge.api_call.side_effect = [(201, {}), (200, {"private": True})]
        forge.create("private", "development")
        forge.api_call.assert_any_call("POST", "/user/repos", {
            "name": "whatsappel", "private": True, "auto_init": False, "default_branch": "development",
        })
        self.assertTrue(forge.created)

    def test_cli_rejects_creation_without_visibility(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            publisher.parse_args(["/tmp/repo", "--create-missing"])

    def test_dry_run_missing_repo_never_creates_or_requests_credentials(self):
        forge = publisher.Forge("github")
        forge.inspect = mock.Mock(return_value=None)
        forge.create = mock.Mock()
        with mock.patch.object(publisher, "credential_socket") as credential:
            status, _ = publisher.publish_one("/unused", forge, "main", "a" * 40,
                                              options(dry_run=True, create_missing=True, visibility="public"))
        self.assertEqual(status, "UNVERIFIED")
        forge.create.assert_not_called()
        credential.assert_not_called()
        forge.inspect.assert_called_once_with(authenticated=False)

    def test_visibility_mismatch_refuses_push(self):
        forge = publisher.Forge("github", "test-token")
        forge.inspect = mock.Mock(return_value={"private": True})
        with mock.patch.object(publisher, "git") as git:
            with self.assertRaisesRegex(publisher.PublishError, "differing from --visibility"):
                publisher.publish_one("/unused", forge, "main", "a" * 40, options(visibility="public"))
        git.assert_not_called()

    def test_divergence_refuses_push_after_remote_fetch(self):
        forge = publisher.Forge("github", "test-token")
        forge.inspect = mock.Mock(return_value={"private": False})
        with mock.patch.object(publisher, "credential_socket", return_value=contextlib.nullcontext("socket")), \
             mock.patch.object(publisher, "remote_head", return_value="b" * 40), \
             mock.patch.object(publisher, "git", side_effect=[result(), result(stdout="b" * 40), result(1)]) as git:
            with self.assertRaisesRegex(publisher.PublishError, "diverges or is ahead"):
                publisher.publish_one("/unused", forge, "main", "a" * 40, options())
        self.assertFalse(any("push" in call.args for call in git.call_args_list))

    def test_normal_push_is_followed_by_commit_verification(self):
        forge = publisher.Forge("github", "test-token")
        forge.inspect = mock.Mock(return_value={"private": False})
        commit = "a" * 40
        with mock.patch.object(publisher, "credential_socket", return_value=contextlib.nullcontext("socket")), \
             mock.patch.object(publisher, "remote_head", side_effect=[None, commit]), \
             mock.patch.object(publisher, "git", return_value=result()) as git:
            status, _ = publisher.publish_one("/unused", forge, "main", commit, options())
        self.assertEqual(status, "PUSHED")
        self.assertIn(commit + ":refs/heads/main", git.call_args.args)
        self.assertFalse(any("--force" in str(value) for value in git.call_args.args))

    def test_post_push_verification_mismatch_is_reported(self):
        forge = publisher.Forge("github", "test-token")
        forge.inspect = mock.Mock(return_value={"private": False})
        with mock.patch.object(publisher, "credential_socket", return_value=contextlib.nullcontext("socket")), \
             mock.patch.object(publisher, "remote_head", side_effect=[None, "b" * 40]), \
             mock.patch.object(publisher, "git", return_value=result()):
            with self.assertRaisesRegex(publisher.PublishError, "verification differs"):
                publisher.publish_one("/unused", forge, "main", "a" * 40, options())


class LocalGitTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "original"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test User")
        self.git("config", "user.email", "test@example.invalid")
        (self.repo / "tracked.txt").write_text("base\n")
        self.git("add", "tracked.txt")
        self.git("commit", "-m", "base")
        self.baseline = self.git("rev-parse", "HEAD").stdout.strip()
        (self.repo / "tracked.txt").write_text("upgrade\n")
        self.patch = self.root / "upgrade.patch"
        self.patch.write_text(self.git("diff", "--binary", "--full-index").stdout)
        self.git("restore", "tracked.txt")
        self.target = self.root / "upgraded"

    def git(self, *args, repo=None):
        return subprocess.run(["git", "-C", str(repo or self.repo), *args], capture_output=True,
                              text=True, check=True, timeout=20)

    def apply(self, *extra):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = applier.main([str(self.repo), str(self.patch), self.baseline,
                                 "--worktree", str(self.target), "--branch", "upgrade-test", *extra])
        return code, output.getvalue()

    def test_apply_starts_at_newer_head_and_preserves_dirty_original_index(self):
        (self.repo / "later.txt").write_text("committed after baseline\n")
        self.git("add", "later.txt")
        self.git("commit", "-m", "later work")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        (self.repo / "later.txt").write_text("staged ongoing work\n")
        self.git("add", "later.txt")
        (self.repo / "tracked.txt").write_text("unstaged ongoing work\n")
        (self.repo / "untracked.txt").write_text("ongoing untracked work\n")
        before = self.git("status", "--porcelain").stdout
        code, output = self.apply("--commit")
        self.assertEqual(code, 0, output)
        self.assertEqual(before, self.git("status", "--porcelain").stdout)
        self.assertEqual((self.repo / "tracked.txt").read_text(), "unstaged ongoing work\n")
        self.assertEqual((self.repo / "later.txt").read_text(), "staged ongoing work\n")
        self.assertEqual((self.target / "tracked.txt").read_text(), "upgrade\n")
        self.assertEqual((self.target / "later.txt").read_text(), "committed after baseline\n")
        self.assertEqual(self.git("rev-parse", "HEAD^", repo=self.target).stdout.strip(), head)
        self.assertEqual(self.git("status", "--porcelain", repo=self.target).stdout, "")
        self.assertIn("--branch 'main'", output)

    def test_conflict_is_retained_only_in_new_worktree(self):
        (self.repo / "tracked.txt").write_text("independent committed change\n")
        self.git("add", "tracked.txt")
        self.git("commit", "-m", "conflicting current work")
        code, output = self.apply("--commit")
        self.assertEqual(code, 2, output)
        self.assertEqual((self.repo / "tracked.txt").read_text(), "independent committed change\n")
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        self.assertIn("UU tracked.txt", self.git("status", "--porcelain", repo=self.target).stdout)

    def test_existing_worktree_path_is_never_overwritten(self):
        self.target.mkdir()
        marker = self.target / "keep.txt"
        marker.write_text("keep me")
        code, _ = self.apply()
        self.assertEqual(code, 1)
        self.assertEqual(marker.read_text(), "keep me")
        self.assertEqual(self.git("branch", "--list", "upgrade-test").stdout, "")

    def test_wrong_patch_checksum_refuses_before_branch_creation(self):
        code, _ = self.apply("--sha256", "0" * 64)
        self.assertEqual(code, 1)
        self.assertFalse(self.target.exists())
        self.assertEqual(self.git("branch", "--list", "upgrade-test").stdout, "")

    def test_missing_baseline_refuses_before_branch_creation(self):
        self.baseline = "0" * 40
        code, _ = self.apply()
        self.assertEqual(code, 1)
        self.assertFalse(self.target.exists())

    def test_dirty_publication_checkout_is_refused_before_token_prompt(self):
        (self.repo / "untracked.txt").write_text("dirty")
        with mock.patch.object(publisher, "read_token") as token, contextlib.redirect_stderr(io.StringIO()):
            code = publisher.main([str(self.repo)])
        self.assertEqual(code, 1)
        token.assert_not_called()

    def test_all_hosts_receive_independent_status_even_when_one_fails(self):
        before = self.git("config", "--local", "--list").stdout
        responses = [publisher.PublishError("API HTTP 500; simulated"),
                     ("READY", "mock"), ("READY", "mock"), ("READY", "mock")]
        output = io.StringIO()
        with mock.patch.object(publisher, "publish_one", side_effect=responses) as publish, \
             mock.patch.object(publisher, "read_token") as token, contextlib.redirect_stdout(output):
            code = publisher.main([str(self.repo), "--dry-run"])
        self.assertEqual(code, 1)
        self.assertEqual(publish.call_count, 4)
        token.assert_not_called()
        self.assertIn("forgejo-com-br: READY", output.getvalue())
        self.assertEqual(before, self.git("config", "--local", "--list").stdout)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")


if __name__ == "__main__":
    unittest.main()
