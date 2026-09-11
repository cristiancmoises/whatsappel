#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Read-only latency diagnosis. Never sends messages or writes raw account data.

The token comes from a protected literal .env, environment, or hidden input.
No token argument, redirects, inherited proxy, response dump or mark-read call.
"""
from __future__ import annotations
import argparse
import datetime as dt
import getpass
import importlib.util
import json
import math
import os
from pathlib import Path
import ssl
import statistics
import sys
import tempfile
import time
from urllib import error, parse, request

MAX_RESPONSE = 24 * 1024 * 1024

class DoctorError(Exception):
    """Only fixed, sanitized messages may reach the report."""

class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise DoctorError("Redirect refused; credentials were not forwarded")

def origin(value):
    if not isinstance(value, str) or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise DoctorError("Invalid bridge origin")
    try:
        url = parse.urlsplit(value)
        port = url.port
    except ValueError:
        raise DoctorError("Invalid bridge origin") from None
    if (url.scheme not in {"http", "https"} or not url.hostname or url.username
            or url.password or url.path not in {"", "/"} or url.query or url.fragment
            or (port is not None and not 1 <= port <= 65535)):
        raise DoctorError("Use a bridge origin without credentials, path, query or fragment")
    if url.scheme == "http" and url.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise DoctorError("Non-loopback HTTP refused; use HTTPS or an SSH tunnel")
    return value.rstrip("/")

def valid_token(value):
    if not isinstance(value, str) or not value or any(not 32 <= ord(c) <= 126 for c in value):
        raise DoctorError("Missing or invalid bridge token")
    return value

def secure_opener():
    # Do not inherit SSLKEYLOGFILE from the environment.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_default_certs()
    return request.build_opener(request.ProxyHandler({}), NoRedirect(), request.HTTPSHandler(context=context))

def read_json(opener, base, token, path, timeout):
    req = request.Request(base + path, method="GET", headers={"X-Whatsappel-Token": token, "Accept": "application/json"})
    started = time.perf_counter()
    try:
        with opener.open(req, timeout=timeout) as response:
            if response.status != 200:
                raise DoctorError("Bridge returned a non-200 status")
            raw = response.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise DoctorError("Response exceeds diagnostic memory limit")
            value = json.loads(raw)
            return value, {"elapsed_ms": round((time.perf_counter() - started) * 1000, 3), "response_bytes": len(raw)}
    except error.HTTPError as exc:
        code = int(exc.code)
        exc.close()
        raise DoctorError("HTTP " + str(code) + "; check bridge availability and authentication") from None
    except (error.URLError, OSError, ValueError, RecursionError):
        raise DoctorError("Connection, timeout, or JSON parsing failed; raw details withheld") from None

def snapshot(obj, field, previous=None):
    if not isinstance(obj, dict) or type(obj.get("version")) is not int or obj["version"] != 2:
        raise DoctorError("Expected a v2 snapshot")
    revision = obj.get("revision")
    if not isinstance(revision, str) or not 1 <= len(revision) <= 256 or type(obj.get("unchanged")) is not bool:
        raise DoctorError("Malformed snapshot metadata")
    if obj["unchanged"]:
        if previous != revision:
            raise DoctorError("Unchanged response did not match the requested revision")
        return revision, None
    values = obj.get(field)
    if not isinstance(values, list) or not all(isinstance(x, dict) for x in values):
        raise DoctorError("Malformed snapshot records")
    if field == "messages":
        total, limit = obj.get("total"), obj.get("limit")
        if (type(total) is not int or total < 0 or type(limit) is not int or not 1 <= limit <= 10000
                or len(values) > min(total, limit)):
            raise DoctorError("Invalid retained-history window")
    return revision, values

def diagnose(url, token, rounds=3, timeout=10, opener=None):
    base, token = origin(url), valid_token(token)
    if type(rounds) is not int or not 1 <= rounds <= 10:
        raise DoctorError("Rounds must be 1..10")
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0.05 <= timeout <= 60:
        raise DoctorError("Timeout must be 0.05..60 seconds")
    opener = opener or secure_opener()
    report = {"version": "3.2.0-rc2", "utc": dt.datetime.now(dt.timezone.utc).isoformat(),
              "scope": "read-only bridge HTTP, not Emacs rendering or WhatsApp delivery", "samples": [], "notes": []}
    health, timing = read_json(opener, base, token, "/health", timeout)
    report["samples"].append({"phase": "health", **timing})
    if not isinstance(health, dict) or health.get("service") != "whatsappel":
        raise DoctorError("Destination did not identify itself as WhatsAppel")
    v2 = type(health.get("read_api")) is int and health["read_api"] == 2
    report["read_api"] = 2 if v2 else 1
    chats, timing = read_json(opener, base, token, "/chats?v=2" if v2 else "/chats", timeout)
    report["samples"].append({"phase": "chats-cold", **timing})
    if not v2:
        if not isinstance(chats, list):raise DoctorError("Invalid legacy conversation response")
        report["chat_count"] = len(chats)
        report["notes"].append("Legacy bridge: restart upgraded bridge to enable v2; /chat was NOT probed because legacy reads mark messages read")
        return report
    revision, records = snapshot(chats, "chats")
    report["chat_count"] = len(records)
    # This identifier is held in memory only, never written into the report.
    jid = next((r.get("jid") for r in records if isinstance(r.get("jid"), str) and r["jid"]), None)
    for _ in range(rounds):
        obj, timing = read_json(opener, base, token, "/chats?v=2&since=" + parse.quote(revision, safe=""), timeout)
        revision, _ = snapshot(obj, "chats", revision)
        report["samples"].append({"phase": "chats-conditional", "unchanged": obj["unchanged"], **timing})
    if jid:
        # v2 read=0 is the only chat read used by this tool. No fallback to /chat.
        path = "/chat?" + parse.urlencode({"jid": jid, "v": 2, "read": 0, "limit": 60})
        obj, timing = read_json(opener, base, token, path, timeout)
        revision, records = snapshot(obj, "messages")
        report["samples"].append({"phase": "chat-window", "record_count": len(records), **timing})
        report["retained_messages_in_sample_chat"] = obj["total"]
        for _ in range(rounds):
            obj, timing = read_json(opener, base, token, path + "&since=" + parse.quote(revision, safe=""), timeout)
            revision, _ = snapshot(obj, "messages", revision)
            report["samples"].append({"phase": "chat-conditional", "unchanged": obj["unchanged"], **timing})
    report["notes"].append("Measurements include network and bridge time; they do not isolate wuzapi, Emacs layout or decoder time")
    return report

def write_report(path, report):
    path = Path(path).expanduser().absolute()
    if path.exists() or path.is_symlink():raise DoctorError("Choose a new output file; existing files are never overwritten")
    for parent in path.parents:
        if parent.is_symlink():raise DoctorError("Symlink output directories are refused")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(report, stream, indent=2);stream.write("\n")

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    spec = importlib.util.spec_from_file_location("wa_launcher", Path(__file__).with_name("launch-whatsappel.py"))
    module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    values = module.literal_environment(args.config.expanduser()) if args.config else {}
    selected = module.account_environment(os.environ, values)
    token = selected.get("WHATSAPPEL_TOKEN") or getpass.getpass("Bridge token (hidden): ")
    url = args.url or selected.get("WHATSAPPEL_BRIDGE_URL") or "http://127.0.0.1:7337"
    report = diagnose(url, token, args.rounds, args.timeout)
    if args.output:write_report(args.output, report)
    print(json.dumps(report, indent=2))
    return 0

if __name__ == "__main__":
    try:raise SystemExit(main())
    except (DoctorError, ValueError, OSError):
        print("Diagnostic stopped: invalid configuration, denied request, unavailable bridge or invalid response. No raw account data was printed.", file=sys.stderr)
        raise SystemExit(1)
