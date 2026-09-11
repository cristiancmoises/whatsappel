#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Run independent audit gates; missing tools never become successful checks."""
from __future__ import annotations
import argparse
import re
import datetime as dt
import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import selectors
import signal
import stat
import time
import uuid


def checks(root, scope):
    base = [
        ("lisp-structure-only", [sys.executable, "scripts/check-lisp-structure.py", "whatsapp.el", "whatsappel.scm", "whatsappel-transport.scm", "whatsapp-delivery.el", "tests/delivery-tests.el", "tests/recipient-ui-tests.el", "tests/performance-tests.el", "tests/benchmark-client.el", "tests/responsiveness-tests.el", "tests/navigation-tests.el", "tests/client-tests.el", "tests/workspace-tests.el", "tests/whatsapp-org-tests.el", "tests/selection-tests.el", "whatsapp-profiles.el", "whatsappel-profiles.scm", "tests/profiles-tests.el", "tests/benchmark-profiles.el", "tests/repair-tests.el"]),
        ("python-regressions", [sys.executable, "-I", "scripts/run-tests.py", "--pattern", "test_*.py"]),
        ("emacs-byte-compile", ["emacs", "-Q", "--batch", "-L", ".", "-f", "batch-byte-compile", "whatsapp.el", "whatsapp-org.el", "whatsapp-profiles.el", "whatsapp-delivery.el"]),
        ("emacs-ert", ["emacs", "-Q", "--batch", "-L", ".", "-L", "tests", "-l", "whatsapp.el", "-l", "whatsapp-org.el", "-l", "tests/client-tests.el", "-l", "tests/whatsapp-org-tests.el", "-l", "tests/workspace-tests.el", "-l", "tests/performance-tests.el", "-l", "tests/responsiveness-tests.el", "-l", "tests/navigation-tests.el", "-l", "tests/selection-tests.el", "-l", "tests/profiles-tests.el", "-l", "tests/delivery-tests.el", "-l", "tests/recipient-ui-tests.el", "-l", "tests/repair-tests.el", "-f", "ert-run-tests-batch-and-exit"]),
        ("emacs-layout-benchmark", ["emacs", "-Q", "--batch", "-L", ".", "-L", "tests", "-l", "tests/benchmark-client.el"]),
        ("emacs-profile-benchmark", ["emacs", "-Q", "--batch", "-L", ".", "-l", "tests/benchmark-profiles.el"]),
        ("read-envelope-benchmark", [sys.executable, "-I", "scripts/benchmark-read-envelope.py", "--samples", "5"]),
        ("read-json-benchmark", [sys.executable, "scripts/benchmark-read-json.py", "--samples", "7"]),
        ("profile-thumbnail-benchmark", [sys.executable, "-I", "scripts/benchmark-profile-thumbnails.py"]),
        ("ffmpeg-capabilities", [sys.executable, "scripts/check-media-tools.py"]),
        ("mpv-local-decode", [sys.executable, "scripts/probe-mpv.py"]),
    ]
    base += [("fish-" + p.stem, ["fish", "--no-execute", str(p)]) for p in sorted((root / "scripts").glob("*.fish"))]
    base += [("guile-unit", ["guile", "--no-auto-compile", "tests/bridge-tests.scm"]),
                 ("bridge-http", [sys.executable, "-I", "scripts/run-tests.py", "--pattern", "test_bridge_http.py"]),
                 ("native-read-api", [sys.executable, "-I", "scripts/run-tests.py", "--pattern", "test_read_api_http.py"]),
                 ("native-profile-api", [sys.executable, "-I", "scripts/run-tests.py", "--pattern", "test_profiles_http.py"]),
                 ("native-transport-api", [sys.executable, "-I", "scripts/run-tests.py", "--pattern", "test_transport_http.py"])]
    if scope == "full":
        base += [("rust-tests", ["cargo", "test", "--locked", "--manifest-path", "pqenv/Cargo.toml"]),
                 ("rust-format", ["cargo", "fmt", "--manifest-path", "pqenv/Cargo.toml", "--", "--check"]),
                 ("rust-clippy", ["cargo", "clippy", "--locked", "--manifest-path", "pqenv/Cargo.toml", "--all-targets", "--", "-D", "warnings"])]
    return base


# Keep this policy identical to update-package.py: receipts identify tested code
# and build inputs, not secrets or arbitrary unrelated data in the checkout.
SOURCE_SUFFIXES = {".el", ".scm", ".py", ".fish", ".rs", ".toml", ".lock", ".sh", ".c", ".h", ".go", ".yml", ".yaml"}
SOURCE_NAMES = {"Makefile", "Dockerfile"}
EXCLUDED_DIRS = {".git", "target", "__pycache__"}
TEST_GATES = {"python-regressions", "bridge-http", "native-read-api", "native-profile-api", "native-transport-api"}


def no_links(path):
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError("Symlink audit path refused")


def stream_digest(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("Nonregular audit source refused")
        value = hashlib.sha256()
        block = bytearray(1024 * 1024)
        while n := stream.readinto(block):
            value.update(memoryview(block)[:n])
        return value.hexdigest()


def source_fingerprint(root):
    no_links(root)
    result = {}
    for directory, folders, files in os.walk(root, followlinks=False):
        folders[:] = sorted(name for name in folders if name not in EXCLUDED_DIRS)
        for name in folders:
            if (Path(directory) / name).is_symlink():
                raise ValueError("Symlink source directory refused")
        for name in sorted(files):
            path = Path(directory) / name
            if path.suffix in SOURCE_SUFFIXES or path.name in SOURCE_NAMES:
                no_links(path)
                result[str(path.relative_to(root))] = stream_digest(path)
    return dict(sorted(result.items()))


def clean_environment():
    """Reduce accidental secret inheritance; tests remain trusted local code."""
    hidden = {"SSLKEYLOGFILE", "FFREPORT", "GIT_ASKPASS", "SSH_ASKPASS", "TOKEN", "PASSWORD", "SECRET"}
    env = {k: v for k, v in os.environ.items()
           if k not in hidden and not k.startswith(("WHATSAPPEL_", "WUZAPI_", "GIT_TRACE"))
           and not k.endswith(("_TOKEN", "_PASSWORD", "_SECRET", "_ACCESS_KEY", "_PRIVATE_KEY", "_API_KEY"))}
    env.update(PYTHONDONTWRITEBYTECODE="1", GUILE_AUTO_COMPILE="0", GIT_TERMINAL_PROMPT="0")
    return env


def kill_owned_group(process):
    """Best-effort cleanup of this POSIX child group, including inherited pipes."""
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    elif process.poll() is None:
        process.kill()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def run_gate(command, root, env, log, timeout=600, limit=8 * 1024 * 1024):
    """Bound wall time and captured log bytes without communicate's unbounded buffer.

    Linux/POSIX is the supported audit target. Detached subprocesses that create
    new sessions are outside group cleanup: this is not an adversarial sandbox.
    """
    started = time.monotonic()
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    process = None
    count = 0
    reason = None
    code = 126
    try:
        with os.fdopen(fd, "wb") as stream:
            process = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       start_new_session=(os.name == "posix"))
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                os.set_blocking(process.stdout.fileno(), False)
                while selector.get_map() or process.poll() is None:
                    left = timeout - (time.monotonic() - started)
                    if left <= 0:
                        code, reason = 124, "Audit command deadline exceeded"
                        break
                    for key, _ in selector.select(min(left, .05)):
                        data = os.read(key.fileobj.fileno(), 65536)
                        if not data:
                            selector.unregister(key.fileobj)
                            continue
                        keep = min(len(data), max(0, limit - count))
                        if keep:
                            stream.write(data[:keep])
                            count += keep
                        if keep != len(data):
                            code, reason = 125, "Audit output limit exceeded"
                            break
                    if reason:
                        break
                if reason is None:
                    code = process.wait(timeout=max(.001, timeout - (time.monotonic() - started)))
    except subprocess.TimeoutExpired:
        code, reason = 124, "Audit command deadline exceeded"
    except OSError:
        code, reason = 126, "Could not start or capture audit command"
    finally:
        if process is not None:
            kill_owned_group(process)
            if process.stdout:
                process.stdout.close()
    return {"exit_code": code, "reason": reason, "log_bytes": count,
            "seconds": time.monotonic() - started}


def write_private_json(path, obj):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(obj, stream, indent=2, ensure_ascii=True)
        stream.write("\n")


def test_outcome(path, exit_code):
    """A zero exit without complete, positive structured evidence cannot pass."""
    try:
        no_links(path)
        if not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
            raise ValueError("Missing test evidence")
        summary = json.loads(path.read_text())
        fields = ("discovered", "run", "passed", "skipped", "errors", "failures", "expected_failures", "unexpected_successes")
        if not isinstance(summary, dict) or summary.get("schema") != 1 or any(type(summary.get(k)) is not int or summary[k] < 0 for k in fields):
            raise ValueError("Invalid counts")
        status = summary.get("status")
        if not summary["discovered"] or summary["errors"] or summary["failures"] or summary["unexpected_successes"]:
            expected = "FAIL"
        elif summary["skipped"] or summary["expected_failures"] or not summary["run"]:
            expected = "PARTIAL"
        else:
            expected = "PASS"
        if status != expected or exit_code != {"PASS": 0, "FAIL": 1, "PARTIAL": 2}[expected]:
            raise ValueError("Exit/status mismatch")
        if expected == "PASS" and not summary["passed"] == summary["run"] == summary["discovered"]:
            raise ValueError("Incomplete passing suite")
        return status, {key: summary[key] for key in fields}
    except (ValueError, OSError, TypeError, KeyError):
        return "FAIL", {"evidence_error": "Missing, invalid or contradictory test receipt"}


def read_diagnostic_file(path, limit=8 * 1024 * 1024):
    """Read one bounded regular diagnostic file; never follow links or block on FIFOs."""
    no_links(path)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > limit:
            raise ValueError("Invalid or oversized diagnostic file")
        with os.fdopen(fd, "rb") as stream:
            fd = -1
            raw = stream.read(limit + 1)
        if len(raw) > limit:
            raise ValueError("Diagnostic file exceeded its size limit")
        return raw
    finally:
        if fd >= 0:
            os.close(fd)


def native_failure_ids(check, path):
    """Extract bounded test identifiers/line numbers, NOT assertion values or traces.

    This is diagnostic text only: it never changes the gate status or exit code.
    Unknown log formats retain the full original log and yield no guessed names.
    """
    if check in TEST_GATES:
        # The runner receipt is a fixed sibling, never a report-supplied path.
        # Only dotted test identifiers are printed; subtest values and tracebacks
        # may contain private values and remain in the operator's original logs.
        try:
            receipt = json.loads(read_diagnostic_file(path.with_suffix(".json")),
                                 object_pairs_hook=_diagnostic_object)
            if (not isinstance(receipt, dict) or receipt.get("schema") != 1
                    or receipt.get("status") != "FAIL"):
                return []
            values = []
            for field in ("failed_tests", "error_tests"):
                entries = receipt.get(field, [])
                if not isinstance(entries, list) or len(entries) > 4096:
                    return []
                values.extend(entry for entry in entries
                              if isinstance(entry, str) and len(entry) <= 240
                              and re.fullmatch(r"test_[A-Za-z0-9_]+(?:\.[A-Za-z_][A-Za-z0-9_]*)+", entry))
            return list(dict.fromkeys(values))[:20]
        except (OSError, ValueError, UnicodeDecodeError):
            return []
    if check not in {"emacs-ert", "guile-unit"}:
        return []
    try:
        text = read_diagnostic_file(path).decode("utf-8", errors="replace")
    except (OSError, ValueError):
        return []
    if check == "emacs-ert":
        names = re.findall(r"^[ \t]*FAILED[ \t]+(?:[0-9]+/[0-9]+[ \t]+)?([A-Za-z][A-Za-z0-9_.:+/-]{0,159})(?=[ \t\r\n]|$)", text, re.M)
    else:
        names = []
        for failure in text.split("* FAIL:")[1:]:
            match = re.search(r"^source-line:[ \t]*([0-9]{1,7})[ \t]*$", failure, re.M)
            names.append("tests/bridge-tests.scm:" + match[1] if match else "Guile assertion (see guile-unit.log)")
            if len(names) >= 20:
                break
    return list(dict.fromkeys(names))[:20]


def _diagnostic_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate audit report field")
        result[key] = value
    return result


def summarize_report(path):
    """Print reported outcomes without executing source, tests, or report commands."""
    try:
        report = json.loads(read_diagnostic_file(path), object_pairs_hook=_diagnostic_object)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ValueError("Invalid audit report encoding or JSON") from None
    if not isinstance(report, dict) or report.get("schema") != 2:
        raise ValueError("Unsupported diagnostic report")
    checks = report.get("checks")
    if not isinstance(checks, list) or not 1 <= len(checks) <= 256:
        raise ValueError("Empty or invalid audit gate list")
    counts = dict.fromkeys(("PASS", "FAIL", "PARTIAL", "BLOCKED"), 0)
    seen = set()
    for record in checks:
        if not isinstance(record, dict):
            raise ValueError("Invalid audit record")
        name, status = record.get("check"), record.get("status")
        if (not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,79}", name)
                or name in seen or not isinstance(status, str) or status not in counts):
            raise ValueError("Invalid/duplicate gate name or status")
        seen.add(name)
        counts[status] += 1
    passed = counts["PASS"] == len(checks)
    if report.get("passed") is not passed:
        raise ValueError("Contradictory report success flag")
    print("Reported outcomes: " + ", ".join(f"{count} {status}" for status, count in counts.items() if count))
    for record in checks:
        name, status = record["check"], record["status"]
        if status != "PASS":
            print(f"{status}: {name}")
            # Never resolve arbitrary paths supplied in the report's log field.
            for identity in native_failure_ids(name, path.parent / (name + ".log")):
                print("  failed test: " + identity)
    print("Read-only summary; this does not rerun or independently attest the audit.")
    return passed


def run_audit(root, output, scope="full", run_id=None):
    root, output = Path(root).absolute(), Path(output).absolute()
    no_links(output)
    if output == root or root in output.parents:
        raise ValueError("Audit output must be outside the source checkout")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    records = []
    source_hashes = source_fingerprint(root)
    env = clean_environment()
    for name, original_command in checks(root, scope):
        command = list(original_command)
        if name in TEST_GATES:
            command += ["--report", str(output / (name + ".json"))]
        required = "guile" if name in {"bridge-http", "native-read-api", "native-profile-api", "native-transport-api"} else ("mpv" if name == "mpv-local-decode" else ("ffmpeg" if name == "profile-thumbnail-benchmark" else command[0]))
        if not shutil.which(required):
            rec = {"check": name, "status": "BLOCKED", "reason": "Missing " + required, "exit_code": 127}
        else:
            log = output / (name + ".log")
            outcome = run_gate(command, root, env, log)
            rec = {"check": name, "status": "PASS" if outcome["exit_code"] == 0 else "FAIL",
                   "log": log.name, **outcome}
            if name in TEST_GATES:
                rec["status"], rec["tests"] = test_outcome(output / (name + ".json"), outcome["exit_code"])
        if rec["status"] == "FAIL" and name in ({"emacs-ert", "guile-unit"} | TEST_GATES):
            rec["failed_test_ids"] = native_failure_ids(name, output / (name + ".log"))
        records.append(rec)
        print(f'{rec["status"]}: {name}', flush=True)
        for identity in rec.get("failed_test_ids", []):
            print("  failed test: " + identity, flush=True)
    final_hashes = source_fingerprint(root)
    changed = sorted(name for name in set(source_hashes) | set(final_hashes)
                     if source_hashes.get(name) != final_hashes.get(name))
    records.append({"check": "source-integrity", "status": "FAIL" if changed else "PASS",
                    "exit_code": int(bool(changed)), "changed_paths": changed})
    print(("FAIL" if changed else "PASS") + ": source-integrity", flush=True)
    external = ["live WhatsApp pairing/delivery", "graphical Emacs mouse/zoom validation", "physical microphone",
                "mpv window playback", "IONOS deployment", "forge pushes", "current RustSec advisories"]
    passed = bool(records) and all(r["status"] == "PASS" for r in records)
    report = {"schema": 2, "run_id": run_id or uuid.uuid4().hex,
              "utc": dt.datetime.now(dt.timezone.utc).isoformat(), "scope": scope, "source": str(root),
              "passed": passed, "checks": records, "source_sha256": source_hashes,
              "source_sha256_after": final_hashes, "not_executed": external}
    write_private_json(output / "report.json", report)
    print("Report: " + str(output / "report.json"))
    return passed


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("source", nargs="?", type=Path, default=Path(__file__).absolute().parents[1])
    p.add_argument("--scope", choices=("changed", "full"), default="full")
    p.add_argument("--run-id")
    p.add_argument("--summarize", type=Path, help="Read one pass directory/report or a two-pass audit directory; run no tests")
    p.add_argument("--preflight", action="store_true", help="Check executable presence only; no audit or installation")
    p.add_argument("--output", type=Path, default=Path(tempfile.gettempdir()) / ("whatsappel-audit-" + uuid.uuid4().hex))
    a = p.parse_args(argv)
    if a.summarize:
        location = a.summarize.expanduser().absolute()
        no_links(location)
        if location.is_file():
            paths = [location]
        elif (location / "report.json").is_file():
            paths = [location / "report.json"]
        else:
            paths = [location / ("pass-" + str(i)) / "report.json" for i in (1, 2)]
        outcomes = []
        for path in paths:
            outcomes.append(summarize_report(path))
        return int(not all(outcomes))
    if a.preflight:
        required = {"guile", "mpv", "ffmpeg", "fish", "emacs", sys.executable}
        if a.scope == "full": required.add("cargo")
        missing = sorted(x for x in required if not shutil.which(x))
        print(json.dumps({"scope": a.scope, "missing_executables": missing,
                          "note": "Presence is not module, codec, version, or behavior validation."}, indent=2))
        return int(bool(missing))
    return 0 if run_audit(a.source.expanduser().absolute(), a.output.expanduser().absolute(), a.scope, a.run_id) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as exc:
        print("Audit stopped: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
