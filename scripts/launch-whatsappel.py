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
    """Read private literal settings through one bounded, non-following descriptor.

    Absence is supported for init-only setup. An insecure existing file is an
    error, not a reason to silently switch account/configuration sources.
    """
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                     | getattr(os, "O_NONBLOCK", 0))
    except FileNotFoundError:
        return {}
    except OSError:
        raise ValueError("Cannot securely open .env; use a regular private file.") from None
    try:
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid()
                or st.st_mode & 0o077 or st.st_size > 65536):
            raise ValueError("The .env must be a user-owned regular file, private (chmod 600), and below 64 KiB.")
        with os.fdopen(fd, "rb") as stream:
            fd = -1  # The stream now owns the descriptor, including exceptions.
            raw_file = stream.read(65537)
    finally:
        if fd >= 0:
            os.close(fd)
    if len(raw_file) > 65536:
        raise ValueError("The .env exceeds the 64 KiB limit.")
    try:
        text = raw_file.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        raise ValueError("The .env must contain valid UTF-8 literal assignments.") from None
    result = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("export "):
            line = line[7:].strip()
        key, sep, raw = line.partition("=")
        key = key.strip()
        if not sep or key not in {"WHATSAPPEL_TOKEN", "WHATSAPPEL_BRIDGE_URL", "WHATSAPPEL_PUBLIC_URL", "WHATSAPPEL_HOST", "WHATSAPPEL_PORT"}:
            continue
        if key in result:
            raise ValueError("Duplicate bridge setting in .env; use one assignment per setting.")
        try:
            values = shlex.split(raw, comments=True)
        except ValueError:
            raise ValueError("Malformed literal bridge setting in .env.") from None
        if len(values) != 1 or any(ord(c) < 32 or ord(c) == 127 or c in "`$" for c in values[0]):
            raise ValueError("Use literal bridge settings in .env, without shell substitutions or control characters.")
        result[key] = values[0]
    return result


def client_origin(settings):
    """Callback PUBLIC_URL is provider-to-bridge, never a client API origin."""
    if "WHATSAPPEL_BRIDGE_URL" in settings:
        return settings["WHATSAPPEL_BRIDGE_URL"]
    if "WHATSAPPEL_HOST" in settings or "WHATSAPPEL_PORT" in settings:
        host = settings.get("WHATSAPPEL_HOST", "127.0.0.1")
        host = {"0.0.0.0": "127.0.0.1", "::": "::1", "[::]": "::1", "[::1]": "::1"}.get(host, host)
        port = settings.get("WHATSAPPEL_PORT", "7337")
        if host not in {"127.0.0.1", "localhost", "::1"}:
            raise ValueError("Remote client access needs an explicit HTTPS WHATSAPPEL_BRIDGE_URL.")
        if not isinstance(port, str) or not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
            raise ValueError("Invalid client port.")
        return "http://" + ("[::1]" if host == "::1" else host) + ":" + port
    if "WHATSAPPEL_PUBLIC_URL" in settings:
        raise ValueError("PUBLIC_URL is the incoming callback, not the client address. Set WHATSAPPEL_BRIDGE_URL or HOST/PORT explicitly.")
    return DEFAULT_ORIGIN


DEFAULT_ORIGIN = "http://127.0.0.1:7337"
ACCOUNT_KEYS = ("WHATSAPPEL_TOKEN", "WHATSAPPEL_BRIDGE_URL")


def account_environment(inherited, settings):
    """Select a complete account from one source; never join two accounts.

    Explicit process settings take precedence as a unit. A token alone uses the
    documented loopback origin, not an unrelated init/.env URL. URL-only input
    is refused instead of borrowing a token from the other configuration source.
    Emacs init remains authoritative when neither external source specifies one.
    """
    result = dict(inherited)
    chosen = inherited if any(key in inherited for key in ACCOUNT_KEYS) else settings
    if not any(key in chosen for key in ACCOUNT_KEYS):
        return result
    token = chosen.get("WHATSAPPEL_TOKEN")
    if not isinstance(token, str) or not token or len(token) > 4096 or any(not 33 <= ord(c) <= 126 for c in token):
        raise ValueError("External bridge settings require their own nonempty ASCII token; never mix .env, environment and Emacs-init accounts.")
    origin = client_origin(chosen)
    # Identical origin policy to the read worker, without importing its process code.
    from urllib.parse import urlsplit
    try:
        if not isinstance(origin, str) or not origin or len(origin) > 2048 or any(ord(c) < 33 or ord(c) == 127 for c in origin):
            raise ValueError()
        url = urlsplit(origin)
        port = url.port
        if (url.scheme not in {"http", "https"} or not url.hostname or url.username is not None
                or url.password is not None or url.path not in {"", "/"}
                or "?" in origin or "#" in origin or (port is not None and not 1 <= port <= 65535)
                or (url.scheme == "http" and url.hostname not in {"localhost", "127.0.0.1", "::1"})):
            raise ValueError()
    except (ValueError, TypeError):
        raise ValueError("Invalid external bridge origin; use HTTPS or loopback HTTP, without credentials, path, query or fragment.") from None
    result.update(WHATSAPPEL_TOKEN=token, WHATSAPPEL_BRIDGE_URL=origin.rstrip("/"))
    return result


def launch_command(root, executable, quick=False):
    # JSON strings are valid here for a POSIX source path; no shell, read/eval of .env, or tokens.
    if any(ord(c) < 32 for c in str(root)):
        raise ValueError("Unsupported control character in installation path.")
    expression = "(progn (load " + json.dumps(str(root / "whatsapp.el"), ensure_ascii=False) + ") (whatsapp-launch))"
    return [executable, *(["-Q"] if quick else []), "--name", "WhatsAppel", "--title", "WhatsAppel", "--eval", expression]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--quick", action="store_true", help="Use Emacs -Q; requires bridge token in protected .env/environment instead of init")
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    emacs = shutil.which("emacs")
    if not emacs:
        raise ValueError("Install graphical Emacs 28.1 or later.")
    env = account_environment(os.environ, literal_environment(root / ".env"))
    if args.quick and not env.get("WHATSAPPEL_TOKEN"):
        raise ValueError("Quick launch requires WHATSAPPEL_TOKEN in protected .env/environment; use normal launch for credentials stored in Emacs init.")
    if args.check:
        print("Launcher ready; bridge token " + ("available from environment/.env" if env.get("WHATSAPPEL_TOKEN") else "must come from existing Emacs init or setup"))
        return 0
    os.execve(emacs, launch_command(root, emacs, args.quick), env)

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as exc:
        print("WhatsAppel: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
