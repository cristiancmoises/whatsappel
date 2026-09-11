#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Hash-anchored WhatsAppel client/bridge update; configuration and sessions stay untouched.

Default is check-only. --apply runs native changed-code gates in an isolated
candidate BEFORE writing managed files. No force/bypass switch is provided.
"""
from __future__ import annotations
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import re
import subprocess
import sys
import tempfile
import importlib.util
import uuid


class UpdateError(Exception):
    pass


def digest(path):
    """Hash a regular, non-symlink file with fixed working memory."""
    no_links(path)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise UpdateError("Nonregular managed file refused")
        result = hashlib.sha256()
        block = bytearray(1024 * 1024)
        while count := stream.readinto(block):
            result.update(memoryview(block)[:count])
        return result.hexdigest()


def safe_relative(value):
    if not isinstance(value, str):
        raise UpdateError("Managed path must be text")
    p = PurePosixPath(value)
    if (not value or p.is_absolute() or any(x in {"", ".", "..", ".git"} for x in p.parts)
            or "\\" in value or any(ord(c) < 32 for c in value)
            or str(p) != value or p.name in {".env", "key", "credentials", "id_rsa", "id_ed25519"}):
        raise UpdateError("Unsafe managed path")
    return Path(*p.parts)


def no_links(path):
    for node in (path, *path.parents):
        if node.is_symlink():
            raise UpdateError("Symbolic-link destination refused: " + str(node))


def verify_bundle(bundle):
    no_links(bundle)
    manifest = bundle / "manifest.json"
    for metadata in (manifest, bundle / "SHA256SUMS"):
        no_links(metadata)
        if not metadata.is_file() or metadata.stat().st_size > 4 * 1024 * 1024:
            raise UpdateError("Missing or oversized bundle metadata")
    entries = (bundle / "SHA256SUMS").read_text().splitlines()
    if not 1 <= len(entries) <= 4096:
        raise UpdateError("Invalid checksum entry count")
    seen = set()
    for line in entries:
        expected, name = line.split("  ", 1)
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise UpdateError("Invalid checksum digest")
        rel = safe_relative(name)
        path = bundle / rel
        no_links(path)
        if name in seen or not path.is_file() or digest(path) != expected:
            raise UpdateError("Bundle checksum mismatch: " + name)
        seen.add(name)
    if "manifest.json" not in seen:
        raise UpdateError("Manifest is not covered by bundle checksums")
    spec = json.loads(manifest.read_text())
    if (not isinstance(spec, dict) or spec.get("format") != 1
            or not isinstance(spec.get("files"), list) or not 1 <= len(spec["files"]) <= 1024
            or not isinstance(spec.get("audit_inputs"), list)):
        raise UpdateError("Unsupported manifest")
    managed = set()
    for item in spec["files"]:
        rel = safe_relative(item["path"])
        compatible_baselines(item)
        if (type(item.get("mode", 0o644)) is not int
                or item.get("mode", 0o644) not in {0o600, 0o644, 0o700, 0o755}
                or not isinstance(item.get("after"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", item["after"])):
            raise UpdateError("Unsafe payload permissions or digest")
        if item["path"] in managed or "payload/" + item["path"] not in seen:
            raise UpdateError("Duplicate or unchecked payload path")
        if digest(bundle / "payload" / rel) != item["after"]:
            raise UpdateError("Payload digest mismatch")
        managed.add(item["path"])
    for value in spec["audit_inputs"]:
        safe_relative(value)
    return spec


def compatible_baselines(item):
    """Only explicitly enumerated SHA-256 anchors, never fuzzy patch matching."""
    extra = item.get("compatible_before", [])
    if not isinstance(extra, list) or len(extra) > 16:
        raise UpdateError("Invalid compatibility anchors")
    values = [item.get("before"), *extra]
    if any(value is not None and (not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value))
           for value in values):
        raise UpdateError("Invalid compatibility SHA-256")
    if len(set(values)) != len(values):
        raise UpdateError("Duplicate compatibility anchor")
    return set(values)


def preflight(target, bundle, spec):
    no_links(target)
    if not target.is_dir() or not (target / "whatsapp.el").is_file():
        raise UpdateError("Existing WhatsAppel source directory not found: " + str(target))
    changes = []
    for item in spec["files"]:
        path = target / safe_relative(item["path"])
        no_links(path)
        if path.exists() and not path.is_file():
            raise UpdateError("Managed destination is not a regular file: " + item["path"])
        current = digest(path) if path.exists() else None
        if current == item["after"]:
            continue
        if current not in compatible_baselines(item):
            raise UpdateError("Unrecognized local changes: " + item["path"] + "; current SHA-256=" + str(current))
        changes.append(item)
    return changes


def atomic_write(path, data, mode=0o644, owner=None):
    no_links(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".whatsappel-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
            if owner and os.geteuid() == 0:
                os.fchown(stream.fileno(), *owner)
        no_links(path)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def desktop_entries(target, home):
    launcher = home / ".local/bin/whatsappel"
    py = "#!/usr/bin/env python3\n# WhatsAppel managed launcher v1\nimport os, sys\nos.execv(sys.executable, [sys.executable, " + repr(str(target / "scripts/launch-whatsappel.py")) + "] + sys.argv[1:])\n"
    escaped = str(launcher).replace("\\", "\\\\").replace('"', '\\"').replace("`", "\\`").replace("$", "\\$").replace("%", "%%")
    desktop = '[Desktop Entry]\nType=Application\nName=WhatsAppel\nComment=WhatsApp conversations in Emacs\nExec="' + escaped + '"\nIcon=internet-chat\nTerminal=false\nCategories=Network;InstantMessaging;\nStartupWMClass=WhatsAppel\n'
    return [(launcher, py.encode(), 0o755), (home / ".local/share/applications/whatsappel.desktop", desktop.encode(), 0o644)]


def restore_backup(backup):
    no_links(backup)
    journal = json.loads((backup / "journal.json").read_text())
    # All checks occur before restoring anything, so newer edits are never silently discarded.
    for entry in journal["entries"]:
        p = Path(entry["destination"])
        no_links(p)
        current = digest(p) if p.is_file() else None
        if current not in {entry["after"], entry["before"]}:
            raise UpdateError("Rollback stopped: destination changed since update: " + str(p))
        if entry["before"] and digest(backup / entry["saved"]) != entry["before"]:
            raise UpdateError("Backup file checksum mismatch")
    for entry in reversed(journal["entries"]):
        p = Path(entry["destination"])
        if entry["before"] is None:
            if p.exists():
                p.unlink()
        else:
            atomic_write(p, (backup / entry["saved"]).read_bytes(), entry["mode"], tuple(entry["owner"]))
    print("Restored managed files. Existing Emacs processes must be restarted to load restored code.")


def apply_files(target, bundle, changes, backup, desktop=False, verified_payload=None):
    jobs = []
    for item in changes:
        path = target / item["path"]
        data = (verified_payload[item["path"]] if verified_payload is not None
                else (bundle / "payload" / item["path"]).read_bytes())
        if hashlib.sha256(data).hexdigest() != item["after"]:
            raise UpdateError("Payload changed after verification")
        jobs.append((path, data, item.get("mode", 0o644)))
        if path.suffix == ".el":
            compiled = path.with_suffix(".elc")
            no_links(compiled)
            if compiled.is_file():
                jobs.append((compiled, None, 0o644))
    if desktop:
        for path, data, mode in desktop_entries(target, Path.home()):
            no_links(path)
            if path.exists() and ((path.name == "whatsappel" and b"WhatsAppel managed launcher" not in path.read_bytes())
                                  or (path.suffix == ".desktop" and b"Name=WhatsAppel" not in path.read_bytes())):
                raise UpdateError("Refusing to replace an unrelated desktop launcher: " + str(path))
            jobs.append((path, data, mode))
    backup.mkdir(mode=0o700, parents=True, exist_ok=False)
    journal = {"target": str(target), "entries": [], "status": "preparing"}
    for index, (path, data, mode) in enumerate(jobs):
        no_links(path)
        old = path.read_bytes() if path.is_file() else None
        st = path.stat() if old is not None else None
        name = str(index) + ".before"
        if old is not None:
            atomic_write(backup / name, old, 0o600)
        journal["entries"].append({"destination": str(path), "saved": name,
                                   "before": hashlib.sha256(old).hexdigest() if old is not None else None,
                                   "after": hashlib.sha256(data).hexdigest() if data is not None else None,
                                   "mode": stat.S_IMODE(st.st_mode) if st else mode,
                                   "owner": [st.st_uid, st.st_gid] if st else [os.getuid(), os.getgid()]})
    atomic_write(backup / "journal.json", json.dumps(journal, indent=2).encode(), 0o600)
    shutil.copyfile(__file__, backup / "rollback.py")
    try:
        for (path, data, mode), entry in zip(jobs, journal["entries"]):
            current = digest(path) if path.is_file() else None
            if current != entry["before"]:
                raise UpdateError("Destination changed while preparing update: " + str(path))
            if data is None:
                path.unlink()
            else:
                atomic_write(path, data, entry["mode"] if entry["before"] else mode, tuple(entry["owner"]))
        journal["status"] = "complete"
        atomic_write(backup / "journal.json", json.dumps(journal, indent=2).encode(), 0o600)
    except Exception:
        # Only restore when the journal's ownership/hash checks still hold.
        restore_backup(backup)
        raise
    return backup


def stage_candidate(target, bundle, spec, candidate):
    candidate.mkdir()
    for name in spec["audit_inputs"]:
        rel = safe_relative(name)
        original = target / rel
        no_links(original)
        if original.is_file():
            (candidate / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, candidate / rel)
    for item in spec["files"]:
        p = candidate / item["path"]
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(bundle / "payload" / item["path"], p)
    for required in ("whatsapp-org.el", "tests/client-tests.el", "tests/whatsapp-org-tests.el", "scripts/publish.py", "scripts/apply-update.py"):
        if not (candidate / required).is_file():
            raise UpdateError("Installation lacks audit input: " + required + "; use a complete supported checkout")



def load_auditor(candidate):
    spec = importlib.util.spec_from_file_location("whatsappel_candidate_audit", candidate / "scripts/audit-workspace.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def installed_inputs(target, spec):
    """Capture unchanged audit inputs too, including independently newer PQ code."""
    values = sorted(set(spec["audit_inputs"]) | {item["path"] for item in spec["files"]})
    result = {}
    for value in values:
        path = target / safe_relative(value)
        no_links(path)
        if path.exists() and not path.is_file():
            raise UpdateError("Nonregular audit input")
        result[value] = digest(path) if path.exists() else None
    return result


def frozen_payload(candidate, spec):
    """Take one immutable copy of the exact payload before executing tests."""
    frozen = {}
    for item in spec["files"]:
        path = candidate / safe_relative(item["path"])
        no_links(path)
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != item["after"]:
            raise UpdateError("Staged payload does not match manifest")
        frozen[item["path"]] = raw
    return frozen


def verify_double_audit(candidate, report_paths, run_ids, expected, scope, plan, fingerprint):
    """Receipts prove consistency with these runs, not a third-party signature."""
    if len(report_paths) != 2 or len(set(run_ids)) != 2 or not expected:
        raise UpdateError("Two distinct complete audits are required")
    for path, run_id in zip(report_paths, run_ids):
        no_links(path)
        if not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
            raise UpdateError("Missing or oversized audit receipt")
        report = json.loads(path.read_text())
        if (not isinstance(report, dict) or report.get("schema") != 2 or report.get("run_id") != run_id
                or report.get("source") != str(candidate) or report.get("scope") != scope
                or report.get("passed") is not True
                or report.get("source_sha256") != expected
                or report.get("source_sha256_after") != expected):
            raise UpdateError("Audit receipt does not match the exact candidate/scope")
        checks = report.get("checks")
        if (not isinstance(checks, list) or any(not isinstance(record, dict) for record in checks)
                or [record.get("check") for record in checks] != plan):
            raise UpdateError("Incomplete or duplicate audit gate set")
        if any(record.get("status") != "PASS" or type(record.get("exit_code")) is not int
               or record["exit_code"] != 0 for record in checks):
            raise UpdateError("Failed, partial, or blocked audit gate")
    if fingerprint(candidate) != expected:
        raise UpdateError("Candidate code changed after audits")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("target", nargs="?", type=Path, default=Path.home() / "whatsappel")
    p.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument("--apply", action="store_true")
    p.add_argument("--audit-only", action="store_true", help="Assemble candidate and audit twice without installing")
    p.add_argument("--full-audit", action="store_true", help="Include retained Rust tests, format and Clippy in each pass")
    p.add_argument("--desktop", action="store_true")
    p.add_argument("--rollback", type=Path)
    a = p.parse_args(argv)
    if a.rollback:
        restore_backup(a.rollback.expanduser().absolute())
        return 0
    target, bundle = a.target.expanduser().absolute(), a.bundle.expanduser().absolute()
    spec = verify_bundle(bundle)
    bundle_identity = digest(bundle / "SHA256SUMS")
    changes = preflight(target, bundle, spec)
    print(f"Matched {spec['version']}: {len(changes)} managed file changes; configuration, pqenv and sessions excluded.", flush=True)
    if not (a.apply or a.audit_only):
        print("Check only. No installed files were changed.")
        return 0
    lock = target.parent / (".whatsappel-update-" + hashlib.sha256(str(target).encode()).hexdigest()[:16] + ".lock")
    no_links(lock)
    fd = os.open(lock, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0), 0o600)
    with os.fdopen(fd, "r+") as stream:
        st = os.fstat(stream.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != os.getuid():
            raise UpdateError("Unsafe installer lock")
        os.fchmod(stream.fileno(), 0o600)
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        preflight(target, bundle, spec)
        target_identity = installed_inputs(target, spec)
        with tempfile.TemporaryDirectory(prefix="whatsappel-candidate-") as temporary:
            candidate = Path(temporary) / "source"
            stage_candidate(target, bundle, spec, candidate)
            frozen = frozen_payload(candidate, spec)
            auditor = load_auditor(candidate)
            expected = auditor.source_fingerprint(candidate)
            scope = "full" if a.full_audit else "changed"
            plan = [name for name, _ in auditor.checks(candidate, scope)] + ["source-integrity"]
            stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            reports = target.parent / ("whatsappel-audit-" + stamp)
            no_links(reports)
            reports.mkdir(mode=0o700, exist_ok=False)
            codes, paths, run_ids = [], [], []
            for pass_number in (1, 2):
                output = reports / ("pass-" + str(pass_number))
                run_id = uuid.uuid4().hex
                result = subprocess.run([sys.executable, "-I", str(candidate / "scripts/audit-workspace.py"), str(candidate),
                                         "--scope", scope, "--output", str(output), "--run-id", run_id],
                                        env=auditor.clean_environment())
                codes.append(result.returncode)
                paths.append(output / "report.json")
                run_ids.append(run_id)
            if any(codes):
                raise UpdateError("Native audit failed, was partial, or blocked in one or both passes; installed files unchanged. Reports: " + str(reports))
            verify_double_audit(candidate, paths, run_ids, expected, scope, plan, auditor.source_fingerprint)
            if verify_bundle(bundle) != spec or digest(bundle / "SHA256SUMS") != bundle_identity:
                raise UpdateError("Bundle changed during audit; installed files unchanged")
            # Check *all* payloads, including documentation not in code fingerprints.
            if frozen_payload(candidate, spec) != frozen:
                raise UpdateError("Candidate payload changed during audit")
            if installed_inputs(target, spec) != target_identity:
                raise UpdateError("Installed source/audit inputs changed during audit")
            if a.audit_only:
                print("Both exact-candidate audits passed. No installed files changed. Reports: " + str(reports))
                return 0
            changes = preflight(target, bundle, spec)
            backup = target.parent / ("whatsappel-backup-" + stamp)
            # Install the immutable bytes actually staged and audited, not the
            # mutable download directory. This is not a sandbox against same-UID attackers.
            apply_files(target, bundle, changes, backup, a.desktop, verified_payload=frozen)
            print(f"Updated managed source. Restart Emacs AND the existing Guile bridge before testing {spec['version']}. Recipient delivery is not established by installation or provider acceptance. No service was restarted automatically.")
            print("Backup: " + str(backup))
            print("Rollback: python3 " + repr(str(backup / "rollback.py")) + " --rollback " + repr(str(backup)))
            if a.desktop:
                print("Launch from the application menu: WhatsAppel. Existing Emacs configuration is retained.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (UpdateError, OSError, ValueError, KeyError, TypeError) as exc:
        print("Stopped: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
