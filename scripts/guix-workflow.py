#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""One entry point for an existing Guix checkout or explicit fresh source install.

Uses the operator's current native tools. Does not pull channels, reconfigure
Guix, mutate profiles, source .env, restart services, or perform Git publication.
"""
from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import errno
import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile
import uuid


def load_installer(bundle):
    spec = importlib.util.spec_from_file_location("whatsappel_guix_installer", bundle / "scripts/update-package.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def snapshot_entries(bundle, update):
    """Read the complete source snapshot, never use it to overwrite an update."""
    index = bundle / "SOURCE_SHA256SUMS"
    update.no_links(index)
    if not index.is_file() or index.stat().st_size > 1024 * 1024:
        raise ValueError("Complete source index missing; use the complete current package for a fresh install")
    source = bundle / "source"
    result = {}
    for line in index.read_text(encoding="utf-8").splitlines():
        sha, name = line.split("  ", 1)
        rel = update.safe_relative(name)
        if name in result or not __import__("re").fullmatch(r"[0-9a-f]{64}", sha):
            raise ValueError("Invalid complete-source checksum index")
        if update.digest(source / rel) != sha:
            raise ValueError("Complete source snapshot hash mismatch: " + name)
        result[name] = sha
    if not result or len(result) > 2048 or "whatsapp.el" not in result:
        raise ValueError("Incomplete or oversized source snapshot")
    verify_snapshot(source, result, update)
    return result


def verify_snapshot(root, expected, update):
    found = set()
    for folder, dirs, names in os.walk(root, followlinks=False):
        for name in dirs:
            update.no_links(Path(folder) / name)
        for name in names:
            path = Path(folder) / name
            rel = str(path.relative_to(root))
            if rel not in expected or update.digest(path) != expected[rel]:
                raise ValueError("Snapshot changed or contains unindexed files")
            found.add(rel)
    if found != set(expected):
        raise ValueError("Snapshot files are missing")


def rename_new_directory(source, target):
    """Linux renameat2(RENAME_NOREPLACE): never replace a concurrent destination."""
    if not sys.platform.startswith("linux"):
        raise ValueError("Fresh atomic installation requires Linux; existing-source updates remain supported")
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        rename = libc.renameat2
    except AttributeError:
        raise ValueError("Atomic no-replace rename is unavailable; target was not changed") from None
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(source), -100, os.fsencode(target), 1):
        code = ctypes.get_errno()
        if code in {errno.EEXIST, errno.ENOTEMPTY}:
            raise ValueError("Destination appeared during validation; refusing to replace it")
        raise OSError(code, "Atomic fresh-install publication failed")


def install_new(target, bundle, update, spec, audit_only=False):
    """Validate a fresh source in a sibling; no source directory appears on failure."""
    update.no_links(target)
    if target.exists():
        raise ValueError("--new-install requires a nonexistent destination; use the normal update command for your installed copy")
    if not target.parent.is_dir():
        raise ValueError("Create the parent directory first; no guessed installation location is created")
    expected = snapshot_entries(bundle, update)
    for item in spec["files"]:
        if expected.get(item["path"]) != item["after"]:
            raise ValueError("Complete source does not match the managed payload")
    bundle_identity = update.digest(bundle / "SHA256SUMS")
    stage = Path(tempfile.mkdtemp(prefix=".whatsappel-new-", dir=target.parent))
    try:
        for name in expected:
            dest = stage / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(bundle / "source" / name, dest)
        # The normal exact-candidate gate executes both full passes; no bypass.
        # Reports are siblings of this stage and survive its cleanup on failure.
        update.main([str(stage), "--bundle", str(bundle), "--audit-only", "--full-audit"])
        if update.verify_bundle(bundle) != spec or update.digest(bundle / "SHA256SUMS") != bundle_identity:
            raise ValueError("Bundle changed during fresh-install validation")
        verify_snapshot(stage, expected, update)
        if audit_only:
            print("Fresh-install candidate validated; destination was not created.")
            return 0
        rename_new_directory(stage, target)
        stage = None
        print("Validated source installed: " + str(target), flush=True)
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
        backup = target.parent / ("whatsappel-launcher-backup-" + stamp)
        try:
            update.apply_files(target, bundle, [], backup, desktop=True, verified_payload={})
        except Exception:
            print("Source remains installed; launcher registration failed. Existing services/configuration were not changed.", file=sys.stderr)
            raise
        print("Menu entry: WhatsAppel. Configure/link your own existing bridge before first use.")
        print("Launcher rollback: python3 " + repr(str(backup / "rollback.py")) + " --rollback " + repr(str(backup)))
        print("Fresh source is retained on launcher rollback; no account/configuration was generated.")
        return 0
    finally:
        if stage is not None:
            shutil.rmtree(stage)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", nargs="?", type=Path, default=Path.home() / "whatsappel")
    parser.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parents[1])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Validate bundle and target only; no installation, tests or network")
    mode.add_argument("--audit-only", action="store_true", help="Run both full audits without installing")
    parser.add_argument("--new-install", action="store_true", help="Explicitly install complete source into a nonexistent directory")
    args = parser.parse_args(argv)
    bundle = args.bundle.expanduser().absolute()
    target = args.target.expanduser().absolute()
    if any(ord(c) < 32 or ord(c) == 127 for c in str(target)):
        raise ValueError("Unsupported control character in installation path")
    if target == Path("/gnu/store") or Path("/gnu/store") in target.parents:
        raise ValueError("Do not update Guix store paths; choose your editable source checkout")
    update = load_installer(bundle)
    try:
        spec = update.verify_bundle(bundle)
        if args.new_install:
            if args.check:
                update.no_links(target)
                if target.exists():
                    raise ValueError("Fresh installation requires a nonexistent destination")
                snapshot_entries(bundle, update)
                print("Complete source and destination checked; nothing installed.")
                return 0
            return install_new(target, bundle, update, spec, args.audit_only)
        command = [str(target), "--bundle", str(bundle)]
        if args.audit_only:
            command += ["--audit-only", "--full-audit"]
        elif not args.check:
            command += ["--apply", "--desktop", "--full-audit"]
        print("Using your current native toolchain. No guix pull, profile mutation, service restart or Git push.", flush=True)
        return update.main(command)
    except update.UpdateError as exc:
        raise ValueError(str(exc)) from None


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Interrupted. Retain printed audit reports/backups; no force update was attempted.", file=sys.stderr)
        raise SystemExit(130)
    except (ValueError, OSError, RuntimeError, KeyError, TypeError) as exc:
        print("Stopped: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
