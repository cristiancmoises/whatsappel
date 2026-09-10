#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Transfer a verified delta to IONOS with SSH host verification and fail-closed installation."""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import importlib.util
import os
from pathlib import Path, PurePosixPath
import shlex
import subprocess
import sys
import tarfile
import tempfile
import uuid

HOST = "root@securityops.co"
PORT = "5119"
SSH = ["ssh", "-p", PORT, "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15", HOST]
# This same function is copied to the remote interpreter and tested locally.
def unpack_verified(archive, expected, destination):
    import hashlib, os, tarfile
    from pathlib import Path, PurePosixPath
    archive, destination = Path(archive), Path(destination)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise ValueError("Transferred archive SHA-256 mismatch")
    if destination.exists() or destination.is_symlink():
        raise ValueError("Extraction destination must be new")
    total, names = 0, set()
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()
        if len(members) > 2000:
            raise ValueError("Too many archive entries")
        for member in members:
            p = PurePosixPath(member.name)
            if (p.is_absolute() or ".." in p.parts or str(p) != member.name or "\\" in member.name
                    or not p.parts or p.parts[0] != "package" or any(ord(c) < 32 for c in member.name)
                    or not (member.isfile() or member.isdir()) or member.name in names
                    or member.size < 0 or member.size > 16 * 1024 * 1024):
                raise ValueError("Unsafe archive member")
            total += member.size
            names.add(member.name)
        if total > 64 * 1024 * 1024:
            raise ValueError("Archive exceeds extraction budget")
        destination.mkdir(mode=0o700)
        for member in members:
            relative = PurePosixPath(member.name).parts[1:]
            if not relative:
                if not member.isdir():
                    raise ValueError("Archive root must be a directory")
                continue
            path = destination.joinpath(*relative)
            path.parent.mkdir(parents=True, exist_ok=True)
            if member.isdir():
                path.mkdir(exist_ok=True)
            else:
                with tf.extractfile(member) as source, path.open("xb") as output:
                    # Archive size, each entry size and total bytes were bounded before writes.
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        output.write(chunk)
                os.chmod(path, 0o755 if member.mode & 0o111 else 0o644)
    return destination


def remote_command(*arguments):
    return " ".join(shlex.quote(str(arg)) for arg in arguments)


def checked(command, **kwargs):
    result = subprocess.run(command, **kwargs)
    if result.returncode:
        raise RuntimeError("Command stopped with exit " + str(result.returncode) + "; earlier uploaded files/backups are retained.")
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--target", help="Exact existing remote source directory; otherwise check /root/whatsappel and /opt/whatsappel")
    parser.add_argument("--stage-only", action="store_true", help="Upload/extract/check only; do not change installed source")
    args = parser.parse_args(argv)
    bundle = args.bundle.expanduser().absolute()
    spec = importlib.util.spec_from_file_location("whatsappel_update", bundle / "scripts/update-package.py")
    update = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(update)
    update.verify_bundle(bundle)
    if args.target and (not args.target.startswith("/") or any(ord(c) < 32 for c in args.target)):
        raise ValueError("Use an absolute remote source path without control characters")
    remote_dir = "/root/.cache/whatsappel-update-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    setup = "import os,sys; from pathlib import Path; os.umask(0o077); p=Path(sys.argv[1]); p.parent.mkdir(parents=True,exist_ok=True); p.mkdir(mode=0o700)"
    print("Destination: " + HOST + ":" + PORT + "; SSH host-key verification is mandatory.", flush=True)
    checked(SSH + [remote_command("python3", "-c", setup, remote_dir)], timeout=45)
    with tempfile.TemporaryDirectory(prefix="whatsappel-transfer-") as td:
        archive = Path(td) / "update.tar.gz"
        with tarfile.open(archive, "w:gz") as tf:
            names = [(line.split("  ", 1)[1]) for line in (bundle / "SHA256SUMS").read_text().splitlines()]
            for name in [*names, "SHA256SUMS"]:
                tf.add(bundle / name, arcname="package/" + name, recursive=False)
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        checked(["scp", "-P", PORT, "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15", str(archive), HOST + ":" + remote_dir + "/update.tar.gz"], timeout=180)
        import inspect
        bootstrap = inspect.getsource(unpack_verified) + '''
import subprocess,sys,os
from pathlib import Path
os.umask(0o077)
folder,expected,target,stage=sys.argv[1:]
package=unpack_verified(Path(folder)/"update.tar.gz", expected, Path(folder)/"package")
if not target:
    choices=[p for p in (Path("/root/whatsappel"),Path("/opt/whatsappel")) if (p/"whatsapp.el").is_file()]
    if len(choices)!=1:
        print("Upload verified. Installed source was not changed. Specify --target with its exact path.")
        print("Verified package: "+str(package))
        raise SystemExit(2)
    target=str(choices[0])
command=[sys.executable,str(package/"scripts/update-package.py"),target,"--bundle",str(package)]
if stage!="yes": command.append("--apply")
print("Verified package: "+str(package),flush=True)
raise SystemExit(subprocess.call(command))
'''
        checked(SSH + [remote_command("python3", "-c", bootstrap, remote_dir, sha, args.target or "", "yes" if args.stage_only else "no")], timeout=1800)
    print("Staging/check completed; no installed files changed." if args.stage_only else "Remote installer completed. The bridge/wuzapi services were not restarted; this is a client-source update.")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print("Stopped: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
