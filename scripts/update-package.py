#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Hash-anchored WhatsAppel client update; existing state and bridge are untouched.

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
import subprocess
import sys
import tempfile


class UpdateError(Exception):
    pass


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe_relative(value):
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
    entries = (bundle / "SHA256SUMS").read_text().splitlines()
    seen = set()
    for line in entries:
        expected, name = line.split("  ", 1)
        rel = safe_relative(name)
        path = bundle / rel
        no_links(path)
        if name in seen or not path.is_file() or digest(path) != expected:
            raise UpdateError("Bundle checksum mismatch: " + name)
        seen.add(name)
    if "manifest.json" not in seen:
        raise UpdateError("Manifest is not covered by bundle checksums")
    spec = json.loads(manifest.read_text())
    if spec.get("format") != 1 or not isinstance(spec.get("files"), list):
        raise UpdateError("Unsupported manifest")
    managed = set()
    for item in spec["files"]:
        rel = safe_relative(item["path"])
        if item["path"] in managed or "payload/" + item["path"] not in seen:
            raise UpdateError("Duplicate or unchecked payload path")
        if digest(bundle / "payload" / rel) != item["after"]:
            raise UpdateError("Payload digest mismatch")
        managed.add(item["path"])
    return spec


def preflight(target, bundle, spec):
    no_links(target)
    if not target.is_dir() or not (target / "whatsapp.el").is_file():
        raise UpdateError("Existing WhatsAppel 3.1.0 source directory not found: " + str(target))
    changes = []
    for item in spec["files"]:
        path = target / safe_relative(item["path"])
        no_links(path)
        if path.exists() and not path.is_file():
            raise UpdateError("Managed destination is not a regular file: " + item["path"])
        current = digest(path) if path.exists() else None
        if current == item["after"]:
            continue
        if current != item.get("before"):
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


def apply_files(target, bundle, changes, backup, desktop=False):
    jobs = []
    for item in changes:
        path = target / item["path"]
        jobs.append((path, (bundle / "payload" / item["path"]).read_bytes(), item.get("mode", 0o644)))
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
            raise UpdateError("Installation lacks audit input: " + required + "; use a complete 3.1.0 checkout")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("target", nargs="?", type=Path, default=Path.home() / "whatsappel")
    p.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument("--apply", action="store_true")
    p.add_argument("--desktop", action="store_true")
    p.add_argument("--rollback", type=Path)
    a = p.parse_args(argv)
    if a.rollback:
        restore_backup(a.rollback.expanduser().absolute())
        return 0
    target, bundle = a.target.expanduser().absolute(), a.bundle.expanduser().absolute()
    spec = verify_bundle(bundle)
    changes = preflight(target, bundle, spec)
    print(f"Matched {spec['version']}: {len(changes)} managed file changes; configuration, bridge, pqenv and session files excluded.")
    if not a.apply:
        print("Check only. No installed files were changed.")
        return 0
    # Serialize this installer without creating an untracked file in the repository.
    lock = target.parent / (".whatsappel-update-" + hashlib.sha256(str(target).encode()).hexdigest()[:16] + ".lock")
    no_links(lock)
    with lock.open("a") as stream:
        os.chmod(lock, 0o600)
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix="whatsappel-candidate-") as temporary:
            candidate = Path(temporary) / "source"
            stage_candidate(target, bundle, spec, candidate)
            stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            reports = target.parent / ("whatsappel-audit-" + stamp)
            result = subprocess.run([sys.executable, str(candidate / "scripts/audit-workspace.py"), str(candidate), "--scope", "changed", "--output", str(reports)])
            if result.returncode:
                raise UpdateError("Native changed-code audit failed or was blocked; installed files unchanged. Report: " + str(reports))
        changes = preflight(target, bundle, spec)
        backup = target.parent / ("whatsappel-backup-" + stamp)
        apply_files(target, bundle, changes, backup, a.desktop)
        print("Updated client source; no bridge/wuzapi restart or network change was needed.")
        print("Backup: " + str(backup))
        print("Rollback: python3 " + repr(str(backup / "rollback.py")) + " --rollback " + repr(str(backup)))
        if a.desktop:
            print("Launch from the application menu: WhatsAppel. Existing Emacs configuration is retained.")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (UpdateError, OSError, ValueError, KeyError) as exc:
        print("Stopped: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
