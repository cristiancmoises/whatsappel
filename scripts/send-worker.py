#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""One bounded explicit text send or callback repair. Never retries a POST."""
from __future__ import annotations
import importlib.util
import http.client
import json
import math
import re
from pathlib import Path
import ssl
import sys
from urllib import request, error

def sibling(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

protocol = sibling("bridge_protocol")
media = sibling("media-worker")
LIMIT = 512 * 1024
REPLY_LIMIT = 65536

def canonical_recipient(value):
    """Preserve namespace; canonical phone keys match the bridge's history key."""
    if not isinstance(value, str) or not re.fullmatch(
            r"(?:[+]?[0-9]{3,30}(?:@(?:s\.whatsapp\.net|c\.us))?|[0-9]{3,30}@lid|[0-9]{3,30}(?:-[0-9]{1,20})?@g\.us)", value):
        raise ValueError("Use an explicit phone number, phone JID, LID or group JID")
    for suffix in ("@s.whatsapp.net", "@c.us"):
        if value.endswith(suffix):
            return value[:-len(suffix)]
    return value


def valid_text(value, maximum, required=False):
    return isinstance(value, str) and len(value) <= maximum and (not required or bool(value.strip()))

def validate(spec):
    if not isinstance(spec, dict): raise ValueError("Invalid control")
    origin = media.bridge_url(spec.get("url"))
    token = spec.get("token")
    if not valid_text(token, 4096, True) or any(not 33 <= ord(c) <= 126 for c in token):
        raise ValueError("Invalid token")
    timeout = spec.get("timeout", 30)
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 1 <= timeout <= 120:
        raise ValueError("Invalid timeout")
    path, payload = spec.get("path"), spec.get("payload")
    if not isinstance(payload, dict): raise ValueError("Invalid payload")
    if path in {"/send", "/send/verified"}:
        if set(payload) - {"to", "body", "reply_id", "reply_participant", "reply_text"}:
            raise ValueError("Unsupported fields")
        if (not valid_text(payload.get("to"), 256, True) or
            any(c.isspace() or ord(c) < 33 or 127 <= ord(c) <= 159 for c in payload["to"]) or
            not valid_text(payload.get("body"), 65536, True)):
            raise ValueError("Invalid message")
        if path == "/send/verified":
            canonical_recipient(payload["to"])
        for key in ("reply_id", "reply_participant", "reply_text"):
            if key in payload and not valid_text(payload[key], 65536 if key == "reply_text" else 256):
                raise ValueError("Invalid reply")
    elif path == "/transport/repair":
        if (set(payload) - {"confirm", "replace"} or payload.get("confirm") is not True or
            ("replace" in payload and type(payload["replace"]) is not bool)):
            raise ValueError("Callback repair requires confirmation")
    else: raise ValueError("Unsupported operation")
    return origin, token, timeout, path, payload

def execute(spec, opener=None):
    origin, token, timeout, path, payload = validate(spec)
    req = request.Request(origin + path, method="POST", headers={
        "X-Whatsappel-Token": token, "Content-Type": "application/json"},
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"))
    if opener is None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_default_certs()
        opener = request.build_opener(request.ProxyHandler({}), media.NoRedirect(),
                                      request.HTTPSHandler(context=context))
    try:
        with protocol.overall_deadline(timeout), opener.open(req, timeout=timeout) as response:
            raw = response.read(REPLY_LIMIT + 1)
            if len(raw) > REPLY_LIMIT: raise ValueError("Reply too large")
            obj = protocol.decode_json(raw)
            if not isinstance(obj, dict): raise ValueError("Invalid acknowledgement")
            if path in {"/send", "/send/verified"}:
                message_id = protocol.accepted_message_id(obj)
                if not message_id: raise ValueError("No accepted message ID")
                if path == "/send/verified" and (
                        type(obj.get("recipient_contract")) is not int or obj["recipient_contract"] != 1
                        or obj.get("accepted_chat") != canonical_recipient(payload["to"])):
                    return {"status": None, "body": {"uncertain": True,
                        "error": "Recipient acknowledgement mismatch. Draft retained; do not resend."}}
                body = {"wuzapi_status": obj["wuzapi_status"], "message_id": message_id,
                        "delivery": "accepted", "data": {"success": True, "data": {"Id": message_id}}}
            else:
                if response.status != 202 or obj.get("accepted") is not True:
                    raise ValueError("No repair job acknowledgement")
                body = {"accepted": True}
            return {"status": response.status, "body": body}
    except error.HTTPError as exc:
        code = exc.code
        upstream = None
        try:
            # Read only a bounded JSON error. Never relay its free-form text.
            with protocol.overall_deadline(timeout):
                raw = exc.read(REPLY_LIMIT + 1)
                obj = protocol.decode_json(raw) if len(raw) <= REPLY_LIMIT else None
                value = obj.get("wuzapi_status") if isinstance(obj, dict) else None
                if type(value) is int and 400 <= value <= 599:
                    upstream = value
        except (protocol.ProtocolError, ValueError, OSError, error.URLError, http.client.HTTPException):
            pass
        finally:
            exc.close()
        if path == "/send/verified" and code in {404, 405, 501}:
            return {"status": code, "body": {"uncertain": True,
                    "error": "Verified send route unavailable. Install and activate the matching bridge before sending."}}
        messages = {
            401: "Provider authentication failed. Draft retained; check the existing session configuration.",
            403: "Provider denied the request. Draft retained; check account permissions.",
            400: "Provider rejected the recipient or request. Draft retained; verify the contact identity.",
            422: "Provider rejected the recipient or request. Draft retained; verify the contact identity."}
        body = {"uncertain": True, "error": messages.get(upstream,
                "Request not confirmed. Check connection and conversation before retrying.")}
        if upstream is not None:
            body["provider_http"] = upstream
        return {"status": code, "body": body}
    except (protocol.ProtocolError, ValueError, OSError, TimeoutError, error.URLError, http.client.HTTPException):
        return {"status": None, "body": {"uncertain": True,
                "error": "No reliable confirmation; request was not automatically resent."}}

def main():
    try:
        raw = sys.stdin.buffer.read(LIMIT + 1)
        if len(raw) > LIMIT: raise ValueError("Control too large")
        spec = protocol.decode_json(raw)
        result = execute(spec)
    except (ValueError, OSError, protocol.ProtocolError):
        result = {"status": None, "body": {"error": "Invalid request; no message sent."}}
    print(json.dumps(result, ensure_ascii=True))
    return 0 if result.get("status") in (200, 201, 202) else 1
if __name__ == "__main__": raise SystemExit(main())
