#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Shared strict, bounded JSON for local bridge workers; no network side effects."""
from __future__ import annotations
from contextlib import contextmanager
from itertools import chain
import json
import math
import re
import signal
import threading
import time
MAX_DEPTH = 96

class ProtocolError(Exception):
    """Fixed diagnostics only: never interpolate URLs, headers or bodies."""


def reject_constant(_value):
    raise ProtocolError("Non-finite JSON numbers are not supported.")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError("Duplicate JSON object key.")
        result[key] = value
    return result


# Scan only structural/escape bytes in Python. The regular expressions are
# single-character classes (no nested quantifiers or whole-string captures).
# Large text/base64 spans are searched by the C regex engine, not a Python loop.
_STRUCTURAL = re.compile(br'[{}\[\]"]')
_STRING_SPECIAL = re.compile(br'["\\]')


def finite_float(value: str) -> float:
    """Reject exponent overflow too; parse_constant alone only handles NaN/Inf."""
    number = float(value)
    if not math.isfinite(number):
        raise ProtocolError("Non-finite JSON numbers are not supported.")
    return number


def _dense_escape_depth(raw: bytes) -> None:
    """Linear fallback for dense escapes, where per-match dispatch costs more."""
    depth = 0
    quoted = escaped = False
    for value in raw:
        if quoted:
            if escaped:
                escaped = False
            elif value == 92:
                escaped = True
            elif value == 34:
                quoted = False
        elif value == 34:
            quoted = True
        elif value in (91, 123):
            depth += 1
            if depth > MAX_DEPTH:
                raise ProtocolError("JSON nesting limit exceeded.")
        elif value in (93, 125):
            depth -= 1
            if depth < 0:
                raise ProtocolError("Invalid JSON response.")


def check_json_depth(raw: bytes) -> None:
    """Bound nesting while skipping quoted spans in C, before native JSON parsing.

    Exactly one byte after an escape is skipped, which also handles runs of
    backslashes correctly. UTF-8 and escape syntax are validated by json.loads.
    No decoded strings or per-character token list are allocated by this pass.
    """
    # Counting is a bounded C pass. This changes only the scan algorithm, not
    # the depth limit, duplicate-key rules or subsequent strict JSON parser.
    if len(raw) >= 4096 and raw.count(b"\\") * 16 > len(raw):
        _dense_escape_depth(raw)
        return
    depth = pos = 0
    quoted = False
    size = len(raw)
    while pos < size:
        match = (_STRING_SPECIAL if quoted else _STRUCTURAL).search(raw, pos)
        if match is None:
            break
        pos = match.end()
        value = raw[pos - 1]
        if quoted:
            if value == 92:
                pos += 1
            else:
                quoted = False
        elif value == 34:
            quoted = True
        elif value in (91, 123):
            depth += 1
            if depth > MAX_DEPTH:
                raise ProtocolError("JSON nesting limit exceeded.")
        else:
            depth -= 1
            if depth < 0:
                raise ProtocolError("Invalid JSON response.")


def decode_json(raw: bytes):
    """Reject excessive depth, duplicate keys and non-finite values before use."""
    check_json_depth(raw)
    try:
        value = json.loads(raw.decode("utf-8"), parse_constant=reject_constant,
                           parse_float=finite_float, object_pairs_hook=unique_object)
        validate_unicode(value)
        return value
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise ProtocolError("Invalid JSON response.") from exc



_SURROGATE = re.compile(r"[\ud800-\udfff]")

def validate_unicode(value):
    """Reject lone surrogates in keys/values without a Python loop per character."""
    # Iterator frames need O(depth) traversal state, not a second list containing
    # every element of a wide JSON array/object. The decoder already caps depth.
    stack = [iter((value,))]
    while stack:
        try:
            item = next(stack[-1])
        except StopIteration:
            stack.pop()
            continue
        if isinstance(item, str):
            if _SURROGATE.search(item):
                raise ProtocolError("Invalid Unicode in JSON response.")
        elif isinstance(item, dict):
            stack.append(chain(item.keys(), item.values()))
        elif isinstance(item, list):
            stack.append(iter(item))


@contextmanager
def overall_deadline(seconds: float):
    """Bound an owned POSIX main-thread operation, preserving an outer timer.

    Worker entrypoints use this on their main thread. On non-POSIX systems or
    background threads the socket timeout/parent deadline remains necessary.
    This context manager is not a general-purpose thread cancellation API.
    """
    if not hasattr(signal, "setitimer") or threading.current_thread() is not threading.main_thread():
        yield
        return
    def expired(_signum, _frame):
        raise ProtocolError("Bridge operation deadline exceeded.")
    started = time.monotonic()
    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_delay, previous_interval = signal.getitimer(signal.ITIMER_REAL)
    # Do not extend an earlier caller's active deadline.
    delay = min(seconds, previous_delay) if previous_delay > 0 else seconds
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, delay)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_delay > 0:
            remaining = max(0.000001, previous_delay - (time.monotonic() - started))
            signal.setitimer(signal.ITIMER_REAL, remaining, previous_interval)


def accepted_message_id(envelope):
    """Require the nested provider acknowledgement; an HTTP 200 is not delivery.

    Support the existing bridge's {wuzapi_status, data: {data: {Id}}} contract.
    The optional new message_id must agree. Reject ambiguous/cross-layer failures.
    """
    if not isinstance(envelope, dict):
        return None
    code = envelope.get("wuzapi_status")
    if type(code) is not int or not 200 <= code < 300:
        return None
    node = envelope
    for _ in range(2):
        if not isinstance(node, dict) or "error" in node or ("success" in node and node["success"] is not True):
            return None
        node = node.get("data")
    if not isinstance(node, dict) or "error" in node or ("success" in node and node["success"] is not True):
        return None
    ids = [node[key] for key in ("Id", "ID", "id") if key in node]
    if "message_id" in envelope:
        ids.append(envelope["message_id"])
    if not ids or any(not isinstance(i, str) or not 1 <= len(i) <= 256 or
                      any(c.isspace() or ord(c) < 33 or 127 <= ord(c) <= 159 for c in i)
                      for i in ids) or len(set(ids)) != 1:
        return None
    return ids[0]
