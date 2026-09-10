#!/usr/bin/env python3
"""Publish one clean WhatsAppel commit to explicit forges without storing tokens.

No force pushes, tag changes, persisted credentials, remote configuration edits,
or redirects.  The source checkout is read only; network Git runs in a temporary
bare repository built from a bundle of the chosen local branch.
"""

from __future__ import annotations

import argparse
import contextlib
import getpass
import json
import os
from pathlib import Path
import shlex
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
from urllib import error, request
import warnings


class PublishError(Exception):
    """A safe, non-secret-bearing message suitable for terminal output."""


DESTINATIONS = {
    "codeberg": ("codeberg.org", "berkeley", "forgejo"),
    "github": ("github.com", "cristiancmoises", "github"),
    "forgejo-co": ("git.securityops.co", "cristiancmoises", "forgejo"),
    "forgejo-com-br": ("git.securityops.com.br", "cristiancmoises", "forgejo"),
}
REPO_NAME = "whatsappel"
MAX_RESPONSE = 1024 * 1024


def clean_environment():
    """Do not inherit Git rewrites, trace logging, askpass, or TLS key logging."""
    env = {
        key: value for key, value in os.environ.items()
        if not key.startswith("GIT_")
        and key not in {"SSH_ASKPASS", "CURL_VERBOSE", "SSLKEYLOGFILE"}
    }
    env.update({
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/bin/false",
        "LC_ALL": "C",
    })
    return env


def git(repo, *args, timeout=120, check=True, config=()):
    command = ["git", "-C", str(repo)]
    for setting in ("core.hooksPath=" + os.devnull, *config):
        command.extend(["-c", setting])
    command.extend(args)
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, encoding="utf-8",
            errors="replace", timeout=timeout, env=clean_environment(),
        )
    except subprocess.TimeoutExpired as exc:
        raise PublishError(f"Git operation timed out after {timeout}s.") from exc
    except OSError as exc:
        raise PublishError("Cannot run Git; install git and retry.") from exc
    if check and result.returncode:
        raise PublishError(git_failure(result.stderr))
    return result


def git_failure(stderr):
    # Deliberately never print server-controlled stderr: it could contain secrets.
    msg = stderr.lower()
    if "non-fast-forward" in msg or "fetch first" in msg:
        return "Remote changed or diverged; fetch and reconcile it locally. No force push was used."
    if "authentication failed" in msg or "could not read username" in msg or "403" in msg:
        return "Git authentication/authorization failed; check token repository-write permission."
    if "certificate" in msg or "ssl" in msg:
        return "Git TLS validation failed. TLS verification remains enabled."
    if "redirect" in msg or "301" in msg or "302" in msg:
        return "Git endpoint redirected; redirects are disabled to protect credentials."
    return "Git operation failed; inspect the destination/service separately (raw server output suppressed)."


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise PublishError(f"API returned HTTP {code}; authenticated redirects are refused.")


class Forge:
    def __init__(self, name, token=None, timeout=30):
        self.name = name
        self.host, self.owner, self.kind = DESTINATIONS[name]
        self.token = token
        self.created = False
        self.timeout = timeout
        self.url = f"https://{self.host}/{self.owner}/{REPO_NAME}.git"
        self.api = "https://api.github.com" if self.kind == "github" else f"https://{self.host}/api/v1"

    def api_call(self, method, path, data=None):
        if not path.startswith("/") or path.startswith("//") or "\n" in path or "\r" in path:
            raise PublishError("Invalid API path.")
        headers = {"Accept": "application/json", "User-Agent": "whatsappel-publisher/1"}
        if self.token:
            headers["Authorization"] = ("Bearer " if self.kind == "github" else "token ") + self.token
        if self.kind == "github":
            headers["X-GitHub-Api-Version"] = "2022-11-28"
        body = None if data is None else json.dumps(data).encode("utf-8")
        if body is not None:
            headers["Content-Type"] = "application/json"
        req = request.Request(self.api + path, data=body, headers=headers, method=method)
        # Construct the context explicitly: SSLKEYLOGFILE must not enable token-bearing TLS session logs.
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_default_certs()
        opener = request.build_opener(NoRedirect(), request.HTTPSHandler(context=context))
        try:
            with opener.open(req, timeout=self.timeout) as response:
                payload = response.read(MAX_RESPONSE + 1)
                if len(payload) > MAX_RESPONSE:
                    raise PublishError("API response is too large.")
                return response.status, json.loads(payload) if payload else {}
        except error.HTTPError as exc:
            code = exc.code
            exc.close()
            return code, {}
        except (error.URLError, TimeoutError, OSError) as exc:
            raise PublishError("API connection/TLS/timeout failure; token validity is unknown.") from exc
        except (ValueError, UnicodeError, RecursionError) as exc:
            raise PublishError("API did not return valid JSON.") from exc

    def inspect(self, authenticated=True):
        if authenticated:
            status, account = self.api_call("GET", "/user")
            if status != 200:
                raise PublishError(api_failure(status, "account verification"))
            login = account.get("login") if isinstance(account, dict) else None
            if not isinstance(login, str) or login.lower() != self.owner.lower():
                raise PublishError(f"Token belongs to a different account; expected {self.owner}.")
        status, metadata = self.api_call("GET", f"/repos/{self.owner}/{REPO_NAME}")
        if status == 404:
            return None
        if status != 200:
            raise PublishError(api_failure(status, "repository lookup"))
        if not isinstance(metadata, dict) or not isinstance(metadata.get("private"), bool):
            raise PublishError("API repository metadata has no trustworthy visibility field.")
        permissions = metadata.get("permissions")
        if permissions is not None and not isinstance(permissions, dict):
            raise PublishError("API returned invalid repository permissions.")
        if authenticated and (permissions or {}).get("push") is False:
            raise PublishError("Token has no push permission for this repository.")
        if metadata.get("archived") or metadata.get("mirror"):
            raise PublishError("Repository is archived or a read-only mirror.")
        return metadata

    def create(self, visibility, branch):
        if visibility not in {"private", "public"}:
            raise PublishError("Creating a repository requires --visibility public or private.")
        payload = {"name": REPO_NAME, "private": visibility == "private", "auto_init": False}
        if self.kind != "github":
            payload["default_branch"] = branch
        status, _ = self.api_call("POST", "/user/repos", payload)
        if status != 201:
            raise PublishError(api_failure(status, "repository creation"))
        self.created = True
        metadata = self.inspect(authenticated=False)
        if metadata is None or metadata.get("private") != (visibility == "private"):
            raise PublishError("Repository was created, but its visibility could not be verified; no push attempted.")
        return metadata


def api_failure(status, action):
    if status in {401, 403}:
        return f"API HTTP {status} during {action}; verify account, token permissions, and rate limits."
    if status == 404:
        return f"API HTTP 404 during {action}; missing resource or insufficient token access."
    if status >= 500:
        return f"API HTTP {status} during {action}; server/proxy failure does not prove an invalid token."
    return f"API HTTP {status} during {action}; no further mutation attempted for this host."


def credential_allowed(fields, forge):
    return (
        fields.get("protocol") == "https"
        and fields.get("host") in {forge.host, forge.host + ":443"}
        and fields.get("path") in {f"{forge.owner}/{REPO_NAME}", f"{forge.owner}/{REPO_NAME}.git"}
        and fields.get("username", forge.owner) == forge.owner
    )


@contextlib.contextmanager
def credential_socket(forge, directory):
    """Only credentials for this exact HTTPS repository leave this memory socket."""
    socket_path = str(Path(directory) / "credential.sock")

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            self.connection.settimeout(5)
            try:
                raw = self.rfile.readline(16385)
                if len(raw) > 16384:
                    return
                fields = json.loads(raw)
                if not isinstance(fields, dict) or not credential_allowed(fields, forge):
                    return
                self.wfile.write(json.dumps({"username": forge.owner, "password": forge.token}).encode() + b"\n")
            except (ValueError, OSError, TypeError):
                return

    try:
        server = socketserver.UnixStreamServer(socket_path, Handler)
    except OSError as exc:
        raise PublishError("Cannot open a local credential socket; check Unix socket support and temporary-directory path length.") from exc
    os.chmod(socket_path, 0o600)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield socket_path
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        Path(socket_path).unlink(missing_ok=True)


def credential_client(socket_path, operation):
    if operation != "get":
        return 0  # Never persist "store" or "erase" payloads.
    fields = {}
    for line in sys.stdin.read(16385).splitlines():
        key, separator, value = line.partition("=")
        if separator and key in {"protocol", "host", "path", "username"}:
            fields[key] = value
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(socket_path)
            sock.sendall(json.dumps(fields).encode() + b"\n")
            with sock.makefile("rb") as stream:
                data = json.loads(stream.readline(16385))
        for key in ("username", "password"):
            value = data[key]
            if not isinstance(value, str) or any(c in value for c in "\r\n\0"):
                return 1
        print(f"username={data['username']}\npassword={data['password']}\n")
        return 0
    except (OSError, ValueError, KeyError, TypeError):
        return 1


def network_config(socket_path=None):
    values = [
        "credential.helper=", "credential.useHttpPath=true", "credential.interactive=never",
        "http.sslVerify=true", "http.followRedirects=false", "http.extraHeader=",
        "http.lowSpeedLimit=1024", "http.lowSpeedTime=30", "protocol.allow=never",
        "protocol.https.allow=always",
    ]
    if socket_path:
        helper = "!" + " ".join(shlex.quote(part) for part in [
            sys.executable, str(Path(__file__).resolve()), "--credential", socket_path,
        ])
        values.append("credential.helper=" + helper)
    return values


def remote_head(transport, forge, branch, config):
    result = git(transport, "ls-remote", "--exit-code", "--heads", forge.url,
                 f"refs/heads/{branch}", check=False, config=config)
    if result.returncode == 2:
        return None
    if result.returncode:
        raise PublishError(git_failure(result.stderr))
    rows = [row.split() for row in result.stdout.splitlines() if row]
    if len(rows) != 1 or len(rows[0]) != 2 or rows[0][1] != f"refs/heads/{branch}":
        raise PublishError("Unexpected branch response from Git server.")
    return rows[0][0]


def publish_one(transport, forge, branch, commit, args):
    metadata = forge.inspect(authenticated=not args.dry_run)
    created = False
    if metadata is None:
        if args.dry_run:
            return "UNVERIFIED", "Repository absent or private to anonymous requests; no changes made."
        if not args.create_missing:
            raise PublishError("Repository missing or inaccessible; --create-missing with --visibility can create it.")
        metadata = forge.create(args.visibility, branch)
        created = True
    visibility = "private" if metadata["private"] else "public"
    if args.visibility and args.visibility != visibility:
        raise PublishError(f"Existing repository is {visibility}, differing from --visibility {args.visibility}; no visibility change made.")
    context = contextlib.nullcontext(None) if args.dry_run else credential_socket(forge, args.credentials_dir)
    with context as socket_path:
        config = network_config(socket_path)
        head = remote_head(transport, forge, branch, config)
        if head == commit:
            return "UP-TO-DATE", f"{visibility}; branch already at {commit[:12]}."
        if head:
            # Fetch to the temporary transport only; original refs/index remain untouched.
            git(transport, "fetch", "--no-tags", "--no-write-fetch-head", forge.url,
                f"refs/heads/{branch}:refs/inspection/{forge.name}", config=config)
            fetched = git(transport, "rev-parse", f"refs/inspection/{forge.name}").stdout.strip()
            ancestor = git(transport, "merge-base", "--is-ancestor", fetched, commit, check=False)
            if ancestor.returncode == 1:
                raise PublishError("Remote branch diverges or is ahead; reconcile it locally. No force push attempted.")
            if ancestor.returncode:
                raise PublishError("Could not prove remote history is an ancestor; no push attempted.")
        if args.dry_run:
            return "READY", f"{visibility}; {'fast-forward' if head else 'new branch'}; public read checked, push permission unverified."
        # An ordinary push still rejects a race that makes the update non-fast-forward.
        try:
            git(transport, "push", "--porcelain", forge.url,
                f"{commit}:refs/heads/{branch}", config=config, timeout=args.timeout)
        except PublishError as exc:
            suffix = " Empty repository was created and has been retained." if created else ""
            raise PublishError(str(exc) + suffix) from exc
        verified = remote_head(transport, forge, branch, config)
        if verified != commit:
            raise PublishError("Push returned success but branch verification differs; inspect the remote before retrying.")
        return "PUSHED", f"{visibility}; verified {commit[:12]}" + ("; repository created." if created else ".")


def read_token(forge):
    # getpass normally falls back to echoing input without a TTY. Refuse that path.
    try:
        with open("/dev/tty", "w") as tty:
            with warnings.catch_warnings():
                warnings.simplefilter("error", getpass.GetPassWarning)
                token = getpass.getpass(f"Token for {forge.owner}@{forge.host}: ", stream=tty).strip()
    except (OSError, EOFError, getpass.GetPassWarning) as exc:
        raise PublishError("A terminal with hidden input is required to enter a token.") from exc
    if not token or any(char in token for char in "\r\n\0"):
        raise PublishError("Token is empty or contains invalid control characters.")
    return token


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path, help="Existing clean local Git checkout to publish")
    parser.add_argument("--remote", action="append", choices=DESTINATIONS,
                        help="Only this destination; repeat as needed (default: all four)")
    parser.add_argument("--branch", help="Destination branch; defaults to the current local branch")
    parser.add_argument("--dry-run", action="store_true", help="Anonymous read-only checks; no tokens or remote mutations")
    parser.add_argument("--create-missing", action="store_true", help="Create empty repositories through each forge API")
    parser.add_argument("--visibility", choices=("public", "private"),
                        help="Required for creation; refuse existing repositories of a different visibility")
    parser.add_argument("--timeout", type=int, default=180, help="Push timeout in seconds (30..900; default: 180)")
    args = parser.parse_args(argv)
    if args.create_missing and not args.visibility:
        parser.error("--create-missing requires an explicit --visibility public or private")
    if not 30 <= args.timeout <= 900:
        parser.error("--timeout must be between 30 and 900 seconds")
    return args


def main(argv=None):
    args = parse_args(argv)
    repo = args.repository.expanduser().resolve()
    try:
        if git(repo, "rev-parse", "--is-inside-work-tree").stdout.strip() != "true":
            raise PublishError("Choose a normal Git checkout, not a bare repository.")
        if git(repo, "status", "--porcelain", "--untracked-files=all").stdout:
            raise PublishError("Checkout has staged, modified, or untracked files. Review and commit them first.")
        source_branch = git(repo, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
        if source_branch.returncode:
            raise PublishError("Detached HEAD is not supported; create a branch first.")
        source_branch = source_branch.stdout.strip()
        branch = args.branch or source_branch
        if git(repo, "check-ref-format", f"refs/heads/{branch}", check=False).returncode:
            raise PublishError("Invalid destination branch name.")
        commit = git(repo, "rev-parse", "HEAD").stdout.strip()
        print(f"Source: {repo}\nCommit: {commit}\nBranch: {source_branch} -> {branch}")
        print("Mode: anonymous checks only" if args.dry_run else "Mode: publish committed snapshot; no tags or force pushes")
        results = []
        with tempfile.TemporaryDirectory(prefix="whatsappel-publish-") as temporary:
            directory = Path(temporary)
            bundle = directory / "snapshot.bundle"
            transport = directory / "transport.git"
            args.credentials_dir = temporary
            git(repo, "bundle", "create", str(bundle), f"refs/heads/{source_branch}")
            git(directory, "clone", "--bare", str(bundle), str(transport))
            bundled_commit = git(transport, "rev-parse", f"refs/heads/{source_branch}").stdout.strip()
            if bundled_commit != commit or git(repo, "rev-parse", "HEAD").stdout.strip() != commit:
                raise PublishError("Source branch changed during snapshot creation; retry after ongoing Git work finishes.")
            for name in dict.fromkeys(args.remote or DESTINATIONS):
                forge = Forge(name)
                print(f"\n[{name}] {forge.url}", flush=True)
                try:
                    if not args.dry_run:
                        forge.token = read_token(forge)
                    status, message = publish_one(transport, forge, branch, commit, args)
                except PublishError as exc:
                    status, message = "FAILED", str(exc)
                except Exception as exc:
                    # Keep other destinations independent and never print an
                    # unexpected exception's data, which may contain a secret.
                    status, message = "FAILED", f"Unexpected local {type(exc).__name__}; inspect this host separately."
                finally:
                    forge.token = None
                if status == "FAILED" and forge.created and "created" not in message.lower():
                    message += " Repository was created and has been retained."
                results.append((name, status, message))
                print(f"{status}: {message}", flush=True)
        print("\nPublication report:")
        for name, status, message in results:
            print(f"  {name}: {status} — {message}")
        return 1 if any(status in {"FAILED", "UNVERIFIED"} for _, status, _ in results) else 0
    except PublishError as exc:
        print(f"Stopped: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    with contextlib.suppress(ImportError, OSError, ValueError):
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    try:
        if len(sys.argv) == 4 and sys.argv[1] == "--credential":
            raise SystemExit(credential_client(sys.argv[2], sys.argv[3]))
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nInterrupted. Earlier successful pushes remain published; rerun to continue.", file=sys.stderr)
        raise SystemExit(130)
