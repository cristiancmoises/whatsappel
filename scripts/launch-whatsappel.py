#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Launch a dedicated Emacs window using existing init and literal .env settings."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import sys


def literal_environment(path):
    """Read only whitelisted literal assignments; never source shell code."""
    if not path.is_file() or path.is_symlink():
        return {}
    st = path.stat()
    if st.st_uid != os.getuid() or st.st_mode & 0o022 or st.st_size > 65536:
        raise ValueError("The .env must be user-owned, non-writable by others, and below 64 KiB.")
    result = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line.startswith("export "):
            line = line[7:].strip()
        key, sep, raw = line.partition("=")
        key = key.strip()
        if not sep or key not in {"WHATSAPPEL_TOKEN", "WHATSAPPEL_BRIDGE_URL", "WHATSAPPEL_PUBLIC_URL"}:
            continue
        values = shlex.split(raw, comments=True)
        if len(values) != 1 or any(c in values[0] for c in "\r\n\x00`$"):
            raise ValueError("Use literal bridge settings in .env, without shell substitutions.")
        result[key] = values[0]
    if "WHATSAPPEL_BRIDGE_URL" not in result and "WHATSAPPEL_PUBLIC_URL" in result:
        result["WHATSAPPEL_BRIDGE_URL"] = result["WHATSAPPEL_PUBLIC_URL"]
    result.pop("WHATSAPPEL_PUBLIC_URL", None)
    return result


def launch_command(root, executable):
    # JSON strings are valid here for a POSIX source path; no shell, read/eval of .env, or tokens.
    if any(ord(c) < 32 for c in str(root)):
        raise ValueError("Unsupported control character in installation path.")
    expression = "(progn (load " + json.dumps(str(root / "whatsapp.el"), ensure_ascii=False) + ") (whatsapp-launch))"
    return [executable, "--name", "WhatsAppel", "--title", "WhatsAppel", "--eval", expression]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    emacs = shutil.which("emacs")
    if not emacs:
        raise ValueError("Install graphical Emacs 28.1 or later.")
    env = dict(os.environ)
    for key, value in literal_environment(root / ".env").items():
        env.setdefault(key, value)
    if args.check:
        print("Launcher ready; bridge token " + ("available from environment/.env" if env.get("WHATSAPPEL_TOKEN") else "must come from existing Emacs init or setup"))
        return 0
    os.execve(emacs, launch_command(root, emacs), env)

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as exc:
        print("WhatsAppel: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
