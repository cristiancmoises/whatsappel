#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Isolated read-envelope serialization and SHA-256 allocation; NOT chat latency."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import statistics
import tempfile
import time
import tracemalloc

ROOT = Path(__file__).resolve().parents[1]

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

read = load("bench_read", "read-worker.py")
update = load("bench_update", "update-package.py")

class CountingSink:
    def __init__(self): self.size = 0
    def write(self, data): self.size += len(data); return len(data)


def measure(fn, samples):
    times = []
    for _ in range(samples):
        start = time.perf_counter_ns(); fn(); times.append((time.perf_counter_ns() - start) / 1e6)
    tracemalloc.start(); fn(); _, peak = tracemalloc.get_traced_memory(); tracemalloc.stop()
    ordered = sorted(times)
    return {"samples_ms": times, "median_ms": statistics.median(times),
            "p95_ms": ordered[min(len(ordered)-1, int(.95*len(ordered)))], "peak_traced_bytes": peak}


def benchmark(samples=5):
    reports = []
    fixtures = [("unchanged", {"version": 2, "revision": "fixture:1", "unchanged": True}),
                ("chats_1000", [{"jid": str(i), "name": f"Fixture {i}", "last": "Synthetic text"*8} for i in range(1000)]),
                ("text_4MiB", {"text": "a" * (4 * 1024 * 1024 - 128)}),
                ("media_16MiB", {"data": "a" * (16 * 1024 * 1024 - 128)})]
    for name, body in fixtures:
        raw = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
        # Validation cost is intentionally excluded from this serialization-only
        # comparison; the production fast path still performs it before any write.
        parsed = read.decode_json(raw)
        expected = {"status": 200, "body": parsed}
        out = io.BytesIO(); read.write_envelope(out, 200, raw)
        if json.loads(out.getvalue()) != expected: raise AssertionError("Envelope differs")
        def old():
            sink = CountingSink()
            sink.write(json.dumps(expected, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8") + b"\n")
        def new(): read.write_envelope(CountingSink(), 200, raw)
        old(); new()
        # Alternating paired samples; allocations measured separately.
        timings = {"rc4_reencode": [], "rc5_forward_validated": []}
        for i in range(samples):
            for key, fn in ([("rc4_reencode", old), ("rc5_forward_validated", new)] if i%2==0 else [("rc5_forward_validated", new), ("rc4_reencode", old)]):
                start = time.perf_counter_ns(); fn(); timings[key].append((time.perf_counter_ns()-start)/1e6)
        result = {"fixture": name, "raw_bytes": len(raw), "parsed_output_equal": True}
        for key, fn in [("rc4_reencode",old),("rc5_forward_validated",new)]:
            tracemalloc.start(); fn(); _, peak = tracemalloc.get_traced_memory(); tracemalloc.stop()
            values=timings[key]
            result[key]={"samples_ms": values, "median_ms": statistics.median(values), "peak_traced_bytes":peak}
        reports.append(result)
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp)/"synthetic.bin"
        with path.open("wb") as stream:
            for _ in range(32): stream.write(b"x"*(1024*1024))
        def previous_hash(): return hashlib.sha256(path.read_bytes()).hexdigest()
        def streamed_hash(): return update.digest(path)
        if previous_hash()!=streamed_hash(): raise AssertionError("Digest differs")
        hashes={"size_bytes":path.stat().st_size,"digests_equal":True,
                "read_all":measure(previous_hash,samples),"streamed":measure(streamed_hash,samples)}
    return {"scope":"Serialization to a counting sink after validation; no network, pipe scheduling, JSON parsing, Emacs rendering or delivery. Tracemalloc is Python allocation, not RSS.",
            "envelopes":reports,"hashing":hashes}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--samples",type=int,default=5)
    args=parser.parse_args()
    if not 1<=args.samples<=30:parser.error("samples must be 1..30")
    print(json.dumps(benchmark(args.samples),indent=2))

if __name__=="__main__":main()
