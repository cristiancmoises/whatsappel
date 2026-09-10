#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Run independent audit gates; missing tools never become successful checks."""
from __future__ import annotations
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def checks(root, scope):
    base = [
        ("python-regressions", [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py", "-v"]),
        ("emacs-byte-compile", ["emacs", "-Q", "--batch", "-L", ".", "-f", "batch-byte-compile", "whatsapp.el", "whatsapp-org.el"]),
        ("emacs-ert", ["emacs", "-Q", "--batch", "-L", ".", "-l", "tests/client-tests.el", "-l", "tests/whatsapp-org-tests.el", "-l", "tests/workspace-tests.el", "-f", "ert-run-tests-batch-and-exit"]),
        ("ffmpeg-capabilities", [sys.executable, "scripts/check-media-tools.py"]),
        ("mpv-local-decode", [sys.executable, "scripts/probe-mpv.py"]),
    ]
    base += [("fish-" + p.stem, ["fish", "--no-execute", str(p)]) for p in sorted((root / "scripts").glob("*.fish"))]
    if scope == "full":
        base += [("guile-unit", ["guile", "--no-auto-compile", "tests/bridge-tests.scm"]),
                 ("bridge-http", [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_bridge_http.py", "-v"]),
                 ("rust-tests", ["cargo", "test", "--locked", "--manifest-path", "pqenv/Cargo.toml"]),
                 ("rust-format", ["cargo", "fmt", "--manifest-path", "pqenv/Cargo.toml", "--", "--check"]),
                 ("rust-clippy", ["cargo", "clippy", "--locked", "--manifest-path", "pqenv/Cargo.toml", "--all-targets", "--", "-D", "warnings"])]
    return base


def run_audit(root, output, scope="full"):
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    records = []
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", GUILE_AUTO_COMPILE="0")
    for name, command in checks(root, scope):
        required = "guile" if name == "bridge-http" else ("mpv" if name == "mpv-local-decode" else command[0])
        if not shutil.which(required):
            rec = {"check": name, "status": "BLOCKED", "reason": "Missing " + required, "exit_code": 127}
        else:
            log = output / (name + ".log")
            try:
                with log.open("w") as stream:
                    result = subprocess.run(command, cwd=root, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=600)
                rec = {"check": name, "status": "PASS" if result.returncode == 0 else "FAIL", "exit_code": result.returncode, "log": log.name}
                if name == "python-regressions" and "skipped=" in log.read_text(errors="replace"):
                    rec["note"] = "Unittest reported skips; see log. Native bridge HTTP is a separate full-scope gate."
            except subprocess.TimeoutExpired:
                rec = {"check": name, "status": "FAIL", "reason": "Audit command timeout", "exit_code": 124, "log": log.name}
            except OSError:
                rec = {"check": name, "status": "FAIL", "reason": "Could not start audit command", "exit_code": 126}
        records.append(rec)
        print(f'{rec["status"]}: {name}', flush=True)
    # Scope must not be confused with independent penetration tests or external service validation.
    external = ["live WhatsApp pairing/delivery", "graphical Emacs mouse/zoom validation", "physical microphone", "mpv window playback", "IONOS deployment", "forge pushes", "current RustSec advisories"]
    passed = all(r["status"] == "PASS" for r in records)
    report = {"utc": dt.datetime.now(dt.timezone.utc).isoformat(), "scope": scope, "source": str(root),
              "passed": passed, "checks": records, "not_executed": external}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Report: " + str(output / "report.json"))
    return passed


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("source", nargs="?", type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument("--scope", choices=("changed", "full"), default="full")
    p.add_argument("--output", type=Path, default=Path(tempfile.gettempdir()) / ("whatsappel-audit-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")))
    a = p.parse_args(argv)
    return 0 if run_audit(a.source.resolve(), a.output.resolve(), a.scope) else 1

if __name__ == "__main__":
    raise SystemExit(main())
