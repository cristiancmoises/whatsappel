#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Bounded, shell-free WhatsAppel media worker. Secrets arrive only on stdin.

`send` uploads once, never retries an ambiguous result. `gif` makes a private,
explicitly requested MP4 copy; original files are never modified.
"""
from __future__ import annotations
import argparse
import base64
import json
import math
import os
from pathlib import Path
import shutil
import stat
import ssl
import subprocess
import sys
from urllib import error, parse, request

# -I intentionally omits the working directory from imports. Load only the
# helper next to this installed script, never an import from the user's cwd.
import importlib.util
from pathlib import Path
_protocol_spec = importlib.util.spec_from_file_location(
    "whatsappel_bridge_protocol", Path(__file__).resolve().with_name("bridge_protocol.py"))
protocol = importlib.util.module_from_spec(_protocol_spec)
_protocol_spec.loader.exec_module(protocol)

MAX_BYTES = 16 * 1024 * 1024
MAX_CONTROL = 131072
MAX_RESPONSE = 1024 * 1024
MIME = {
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
    ".webp": "image/webp", ".gif": "image/gif", ".mp4": "video/mp4",
    ".ogg": "audio/ogg", ".opus": "audio/ogg", ".mp3": "audio/mpeg",
    ".m4a": "audio/mp4", ".aac": "audio/aac", ".wav": "audio/wav",
    ".pdf": "application/pdf", ".txt": "text/plain", ".zip": "application/zip",
}
ALLOWED = {
    "image": {"image/jpeg", "image/png"}, "sticker": {"image/webp"},
    "video": {"video/mp4"}, "gif": {"video/mp4"},
    "audio": {"audio/ogg", "audio/mpeg", "audio/mp4", "audio/aac"},
}

class WorkerError(Exception):
    """A fixed, non-secret-bearing diagnostic."""

class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise WorkerError("The bridge redirected the request; credentials were not forwarded.")

def bridge_url(value):
    if not isinstance(value, str) or len(value) > 2048 or any(ord(c) < 33 or ord(c) == 127 for c in value):
        raise WorkerError("Invalid bridge URL.")
    try:
        url = parse.urlsplit(value)
        port = url.port
    except ValueError as exc:
        raise WorkerError("Invalid bridge URL.") from exc
    if (url.scheme not in {"http", "https"} or not url.hostname or url.username is not None
            or url.password is not None or url.query or url.fragment or url.path not in {"", "/"}
            or "?" in value or "#" in value or (port is not None and not 1 <= port <= 65535)):
        raise WorkerError("Use a bridge origin without credentials, path, query or fragment.")
    if url.scheme == "http" and url.hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise WorkerError("Plain HTTP is allowed only on loopback; use HTTPS or an SSH tunnel.")
    return value.rstrip("/")

def bounded_file(value, limit=MAX_BYTES):
    if not isinstance(value, str) or not value or "\x00" in value:
        raise WorkerError("Choose a local regular file.")
    p = Path(value).expanduser()
    if not p.is_absolute() or p.is_symlink():
        raise WorkerError("Choose an absolute, non-symlink local file.")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(p, flags)
        with os.fdopen(fd, "rb") as stream:
            st = os.fstat(stream.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_size == 0 or st.st_size > limit:
                raise WorkerError("Attachment must be nonempty and within the 16 MiB limit.")
            data = stream.read(limit + 1)
    except OSError as exc:
        raise WorkerError("The selected file cannot be read.") from exc
    if not data or len(data) > limit:
        raise WorkerError("Attachment changed or exceeds the size limit.")
    return p, data

def media_payload(spec):
    target = spec.get("target")
    if (not isinstance(target, str) or not target or len(target) > 256
            or any(c.isspace() or ord(c) < 32 or 127 <= ord(c) <= 159 for c in target)):
        raise WorkerError("Invalid recipient; reopen the conversation.")
    kind = spec.get("kind", "document")
    if kind not in {*ALLOWED, "document"}:
        raise WorkerError("Unsupported attachment kind.")
    caption = spec.get("caption", "")
    if not isinstance(caption, str) or len(caption) > 65536:
        raise WorkerError("Caption is too long.")
    limit = spec.get("max_bytes", MAX_BYTES)
    if type(limit) is not int or not 1 <= limit <= MAX_BYTES:
        raise WorkerError("Invalid attachment size limit.")
    path, data = bounded_file(spec.get("file"), limit)
    mime = MIME.get(path.suffix.lower(), "application/octet-stream")
    transport = kind if kind == "document" or mime in ALLOWED[kind] else "document"
    filename = path.name
    if (filename in {".", ".."} or len(filename) > 255
            or any(c in "/\\" or ord(c) < 32 or 127 <= ord(c) <= 159 for c in filename)):
        raise WorkerError("Rename the file to a simple filename before sending.")
    payload = {"to": target, "data": "data:" + mime + ";base64," + base64.b64encode(data).decode("ascii"),
               "mimetype": mime}
    if caption:
        payload["caption"] = caption
    if transport == "document":
        payload["filename"] = filename
    return transport, payload

def upload(spec, opener=None):
    origin = bridge_url(spec.get("url"))
    token = spec.get("token")
    if not isinstance(token, str) or not 1 <= len(token) <= 4096 or any(not 33 <= ord(c) <= 126 for c in token):
        raise WorkerError("Set a valid bridge token in Emacs.")
    timeout = spec.get("timeout", 45)
    if type(timeout) not in {int, float} or not math.isfinite(timeout) or not 1 <= timeout <= 120:
        raise WorkerError("Invalid upload timeout.")
    transport, payload = media_payload(spec)
    req = request.Request(origin + "/send/" + transport,
                          data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                          headers={"X-Whatsappel-Token": token, "Content-Type": "application/json"}, method="POST")
    if opener is None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_default_certs()
        opener = request.build_opener(request.ProxyHandler({}), NoRedirect(), request.HTTPSHandler(context=context))
    try:
        # A socket timeout alone can be prolonged by a slow-drip response.
        # One POST only: a deadline or bad acknowledgement means unknown delivery.
        with protocol.overall_deadline(timeout), opener.open(req, timeout=timeout) as reply:
            raw = reply.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                return {"ok": False, "uncertain": True, "error": "Oversized reply. Check the chat before retrying."}
            obj = protocol.decode_json(raw) if raw else {}
            if not isinstance(obj, dict) or obj.get("success") is False:
                return {"ok": False, "uncertain": True, "error": "Unconfirmed delivery. Check the chat before retrying."}
            message_id = protocol.accepted_message_id(obj)
            if message_id is None:
                return {"ok": False, "uncertain": True,
                        "error": "No upstream confirmation. Check the chat before retrying."}
            return {"ok": 200 <= reply.status < 300, "status": reply.status, "transport": transport,
                    "message_id": message_id, "delivery": "accepted"}
    except error.HTTPError as exc:
        code = exc.code
        exc.close()
        return {"ok": False, "status": code, "uncertain": code >= 500,
                "error": "Bridge rejected the request. For server errors, check the chat before retrying."}
    except (protocol.ProtocolError, WorkerError, error.URLError, TimeoutError,
            OSError, ValueError, RecursionError) as exc:
        return {"ok": False, "uncertain": True,
                "error": "Delivery is unknown after a connection/response error. Check the chat before retrying."}

def private_output(value):
    if not isinstance(value, str):
        raise WorkerError("A private output path is required.")
    path = Path(value)
    if not path.is_absolute() or path.exists() or path.is_symlink():
        raise WorkerError("Output must be a new absolute path.")
    parent = path.parent
    if parent.is_symlink() or not parent.is_dir():
        raise WorkerError("Output directory is missing or unsafe.")
    st = parent.stat()
    if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o077:
        raise WorkerError("Output directory must be user-owned and mode 0700.")
    return path

def gif_command(source, output, ffmpeg):
    return [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-protocol_whitelist", "file,pipe", "-f", "gif", "-i", str(source),
            "-t", "30", "-an", "-threads", "2", "-filter_threads", "1",
            "-vf", "scale=w='min(iw,720)':h='min(ih,720)':force_original_aspect_ratio=decrease,pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-c:v", "libx264", "-preset", "fast", "-crf", "23", "-pix_fmt", "yuv420p",
            "-movflags", "+faststart", "-fs", str(MAX_BYTES), "-f", "mp4", str(output)]

def conversion_limits():
    """Supplement pixel/time/output limits with a Linux address-space ceiling."""
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_AS, (1024 * 1024 * 1024, 1024 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CPU, (80, 85))

def convert_gif(spec):
    source, data = bounded_file(spec.get("file"))
    if not data.startswith((b"GIF87a", b"GIF89a")):
        raise WorkerError("Select a real GIF file for conversion.")
    # Refuse known oversized canvases before native decoder allocation.
    if len(data) < 10 or not 0 < int.from_bytes(data[6:8], "little") * int.from_bytes(data[8:10], "little") <= 16000000:
        raise WorkerError("GIF canvas exceeds the pixel limit.")
    output = private_output(spec.get("output"))
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise WorkerError("Install FFmpeg to prepare a GIF as MP4.")
    # Work on an owned snapshot so the selected file cannot change mid-conversion.
    snapshot = output.parent / "input.gif"
    fd = os.open(snapshot, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    try:
        result = subprocess.run(gif_command(snapshot, output, ffmpeg), stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90,
                                preexec_fn=conversion_limits if sys.platform.startswith("linux") else None,
                                env={k: v for k, v in os.environ.items() if k not in {"FFREPORT", "SSLKEYLOGFILE", "WHATSAPPEL_TOKEN", "WUZAPI_TOKEN"}})
        if result.returncode or not output.is_file() or not 0 < output.stat().st_size < MAX_BYTES:
            raise WorkerError("GIF conversion failed or reached the size limit; the original is unchanged.")
        os.chmod(output, 0o600)
        return {"ok": True, "file": str(output), "transport": "gif", "max_seconds": 30}
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise WorkerError("GIF conversion stopped; the original is unchanged.") from exc
    finally:
        snapshot.unlink(missing_ok=True)

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("send", "gif"))
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        raw = sys.stdin.buffer.read(MAX_CONTROL + 1)
        if len(raw) > MAX_CONTROL:
            raise WorkerError("Media control request is too large.")
        spec = protocol.decode_json(raw)
        if not isinstance(spec, dict):
            raise WorkerError("Invalid media request.")
        result = upload(spec) if args.operation == "send" else convert_gif(spec)
    except (WorkerError, protocol.ProtocolError) as exc:
        result = {"ok": False, "error": str(exc)}
    except Exception:
        result = {"ok": False, "error": "Media operation failed; no automatic retry was attempted."}
    print(json.dumps(result, ensure_ascii=True), flush=True)
    return 0 if result.get("ok") is True else 1

if __name__ == "__main__":
    raise SystemExit(main())
