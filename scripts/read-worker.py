#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""One bounded bridge GET per child process; no redirects, proxies or retries.

The control object (including its token) arrives over stdin. Only JSON results go
back to the parent. This worker never sends messages or modifies local files.
The /chat read flag is explicit; read=1 can mark the focused conversation read.
"""
from __future__ import annotations

import http.client
import json
import math
import re
import ssl
import sys
import time
from urllib.parse import parse_qsl, urlsplit

MAX_CONTROL = 16384
MAX_SNAPSHOT = 4 * 1024 * 1024
MAX_MEDIA = 24 * 1024 * 1024
ROUTES = {
    "/health": set(),
    "/status": set(),
    "/transport/status": {"refresh"},
    "/qr": set(),
    "/chats": {"v", "since"},
    "/chat": {"jid", "v", "read", "limit", "since"},
    "/media-job": {"id"},
}


# -I intentionally omits the working directory from imports. Load only the
# helper next to this installed script, never an import from the user's cwd.
import importlib.util
from pathlib import Path
_protocol_spec = importlib.util.spec_from_file_location(
    "whatsappel_bridge_protocol", Path(__file__).resolve().with_name("bridge_protocol.py"))
protocol = importlib.util.module_from_spec(_protocol_spec)
_protocol_spec.loader.exec_module(protocol)

# Retain the existing helper API for diagnostics and differential tests.
MAX_DEPTH = protocol.MAX_DEPTH
ReadError = protocol.ProtocolError
reject_constant = protocol.reject_constant
unique_object = protocol.unique_object
finite_float = protocol.finite_float
check_json_depth = protocol.check_json_depth
decode_json = protocol.decode_json
overall_deadline = protocol.overall_deadline

def validate(spec: dict):
    if not isinstance(spec, dict):
        raise ReadError("Invalid worker control object.")
    origin = spec.get("url")
    if not isinstance(origin, str) or len(origin) > 2048 or any(ord(c) < 33 or ord(c) == 127 for c in origin):
        raise ReadError("Invalid bridge origin.")
    try:
        url = urlsplit(origin)
        port = url.port
    except ValueError as exc:
        raise ReadError("Invalid bridge origin.") from exc
    if (url.scheme not in {"http", "https"} or not url.hostname or url.username is not None
            or url.password is not None or url.path not in {"", "/"}
            or url.query or url.fragment or "?" in origin or "#" in origin):
        raise ReadError("Use a bridge origin without credentials, path, query or fragment.")
    if url.scheme == "http" and url.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise ReadError("Plain HTTP requires loopback; use HTTPS or an SSH tunnel.")
    if port is not None and not 1 <= port <= 65535:
        raise ReadError("Invalid bridge port.")
    token = spec.get("token")
    if not isinstance(token, str) or not 1 <= len(token) <= 4096 or any(not 33 <= ord(c) <= 126 for c in token):
        raise ReadError("Invalid bridge token.")
    path = spec.get("path")
    if not isinstance(path, str) or not 1 <= len(path) <= 4096 or any(not 33 <= ord(c) <= 126 for c in path):
        raise ReadError("Invalid bridge read path.")
    if re.search(r"%(?![0-9A-Fa-f]{2})", path):
        raise ReadError("Invalid percent encoding in read path.")
    parts = urlsplit(path)
    if parts.scheme or parts.netloc or parts.fragment or "#" in path or parts.path not in ROUTES:
        raise ReadError("Unsupported bridge read path.")
    try:
        pairs = parse_qsl(parts.query, keep_blank_values=True, strict_parsing=True,
                          max_num_fields=8, encoding="utf-8", errors="strict")
    except ValueError as exc:
        raise ReadError("Invalid read query.") from exc
    params = dict(pairs)
    if len(params) != len(pairs) or set(params) - ROUTES[parts.path]:
        raise ReadError("Unsupported or duplicate query parameter.")
    for key, value in pairs:
        if not value or len(value) > 256 or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value):
            raise ReadError("Invalid read query value.")
        if key == "v" and value != "2":
            raise ReadError("Unsupported read API version.")
        if key == "refresh" and value != "1":
            raise ReadError("Invalid transport refresh flag.")
        if key == "read" and value not in {"0", "1"}:
            raise ReadError("Invalid read acknowledgement flag.")
        if key == "limit" and (not value.isascii() or not value.isdecimal() or not 1 <= int(value) <= 10000):
            raise ReadError("Invalid history window.")
    if parts.path == "/chat" and not {"jid", "read"} <= set(params):
        raise ReadError("A conversation and explicit read flag are required.")
    if parts.path == "/media-job" and ("id" not in params or len(params["id"]) >= 160):
        raise ReadError("Invalid media job identifier.")
    seconds = spec.get("timeout", 30)
    if type(seconds) not in {int, float} or not math.isfinite(seconds) or not 1 <= seconds <= 120:
        raise ReadError("Invalid read deadline.")
    ceiling = MAX_MEDIA if parts.path == "/media-job" else MAX_SNAPSHOT
    limit = spec.get("max_bytes", ceiling)
    if type(limit) is not int or not 1 <= limit <= ceiling:
        raise ReadError("Invalid response byte limit.")
    return url, path, token, float(seconds), limit



def media_failure(status, raw):
    """Keep only typed provider status and constant categories, never error text."""
    upstream = None
    try:
        obj = decode_json(raw)
        value = obj.get("wuzapi_status") if isinstance(obj, dict) else None
        if type(value) is int and 100 <= value <= 599:
            upstream = value
    except (ReadError, ValueError, TypeError, RecursionError):
        pass
    reason = {401: "bridge-auth", 403: "bridge-auth", 404: "bridge-route",
              400: "media-metadata", 410: "media-expired", 413: "media-limit",
              429: "media-busy"}.get(status, "media-provider")
    if status == 502:
        reason = {401: "provider-auth", 403: "provider-denied", 404: "provider-unavailable",
                  405: "provider-route", 410: "media-expired", 429: "provider-busy"}.get(upstream, reason)
    body = {"state": "unavailable", "reason": reason,
            "error": "Media retrieval failed; no message was sent."}
    if upstream is not None:
        body["wuzapi_status"] = upstream
    return body


def read_request(spec: dict, *, raw_output: bool = False):
    """Perform exactly one GET; return no untrusted error-response contents."""
    url, path, token, seconds, limit = validate(spec)
    start = time.monotonic()
    if url.scheme == "https":
        # Unlike create_default_context, this does not activate SSLKEYLOGFILE.
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_default_certs()
        context.set_alpn_protocols(["http/1.1"])
        connection = http.client.HTTPSConnection(url.hostname, url.port, timeout=seconds, context=context)
    else:
        connection = http.client.HTTPConnection(url.hostname, url.port, timeout=seconds)
    try:
        connection.request("GET", path, headers={"X-Whatsappel-Token": token,
                           "Accept": "application/json", "Accept-Encoding": "identity",
                           "Connection": "close"})
        with connection.getresponse() as response:
            status = response.status
            media_error = not 200 <= status < 300 and urlsplit(path).path == "/media-job"
            if not 200 <= status < 300 and not media_error:
                body = {"error": "Bridge read rejected; no redirect or retry was made."}
                if raw_output:
                    return status, json.dumps(body, separators=(",", ":")).encode("utf-8")
                return {"status": status, "body": body}
            if media_error:
                limit = min(limit, 65536)
            if response.getheader("Content-Encoding", "identity").lower() not in {"", "identity"}:
                raise ReadError("Compressed bridge responses are not accepted.")
            lengths = response.headers.get_all("Content-Length", [])
            if len(lengths) > 1 or (lengths and (not lengths[0].isascii() or not lengths[0].isdecimal())):
                raise ReadError("Invalid response length.")
            expected = int(lengths[0]) if lengths else None
            transfer = response.getheader("Transfer-Encoding", "").lower()
            if transfer not in {"", "chunked"} or (transfer and lengths):
                raise ReadError("Ambiguous response framing.")
            if expected is not None and expected > limit:
                raise ReadError("Bridge response exceeds the byte limit.")
            data = bytearray()
            while True:
                remaining = seconds - (time.monotonic() - start)
                if remaining <= 0:
                    raise protocol.DeadlineError("Bridge read deadline exceeded.")
                if connection.sock is not None:
                    connection.sock.settimeout(remaining)
                block = response.read1(min(65536, limit + 1 - len(data)))
                if not block:
                    break
                data.extend(block)
                if len(data) > limit:
                    raise ReadError("Bridge response exceeds the byte limit.")
            if expected is not None and len(data) != expected:
                raise ReadError("Incomplete bridge response.")
            raw = bytes(data)
            del data
            if media_error:
                body = media_failure(status, raw)
                if raw_output:
                    return status, json.dumps(body, separators=(",", ":")).encode("utf-8")
                return {"status": status, "body": body}
            body = decode_json(raw)
            route = urlsplit(path).path
            if route in {"/chat", "/chats"} and isinstance(body, dict) and body.get("version") != 2:
                raise ReadError("Expected a versioned snapshot or legacy record array.")
            if not isinstance(body, (dict, list)):
                raise ReadError("Expected a bridge object or record array.")
            # Only completely validated JSON can use the zero-reencode path.
            if raw_output:
                return status, raw
            return {"status": status, "body": body}
    finally:
        connection.close()


def write_envelope(stream, status: int, validated_raw: bytes) -> None:
    """Write an already validated response without building another large string.

    Internal API: call only with read_request(raw_output=True) results. The
    parent still validates the envelope; this is not an unvalidated raw proxy.
    """
    stream.write(b'{"status":' + str(status).encode("ascii") + b',"body":')
    stream.write(validated_raw)
    stream.write(b'}\n')


def main() -> int:
    spec = None
    try:
        raw = sys.stdin.buffer.read(MAX_CONTROL + 1)
        if len(raw) > MAX_CONTROL:
            raise ReadError("Worker control limit exceeded.")
        spec = decode_json(raw)
        _, _, _, seconds, _ = validate(spec)
        with overall_deadline(seconds):
            status, raw_reply = read_request(spec, raw_output=True)
        write_envelope(sys.stdout.buffer, status, raw_reply)
        return 0
    except (protocol.DeadlineError, TimeoutError):
        # Only fixed categories survive; deadlines never authorize a retry.
        media = isinstance(spec, dict) and str(spec.get("path", "")).startswith("/media-job?")
        sys.stdout.write(json.dumps({"status": None, "body": {
            "state": "unavailable", "reason": "media-timeout" if media else "read-timeout",
            "error": "Bridge read deadline exceeded; no automatic retry was made."}}) + "\n")
        return 1
    except ReadError as exc:
        message = str(exc)
    except (OSError, ValueError, TypeError, RecursionError, http.client.HTTPException):
        message = "Bridge read failed; cached history was not replaced."
    sys.stdout.write(json.dumps({"status": None, "body": {"error": message}}) + "\n")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
