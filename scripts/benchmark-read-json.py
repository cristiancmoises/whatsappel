#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Deterministic RC3/RC4 Python JSON costs; NOT GUI/network/WhatsApp latency."""
from __future__ import annotations
import argparse
import gc
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import statistics
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bench_read', ROOT/'scripts/read-worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


def rc3_reference(raw):
    """The retained RC3 depth pass, with the same strict object parser.

    Fixtures contain finite values, so RC4 exponent-overflow refusal does not
    affect timing comparability. Keep this baseline outside application code.
    """
    depth = 0
    quoted = escaped = False
    for value in raw:
        if quoted:
            if escaped: escaped = False
            elif value == 92: escaped = True
            elif value == 34: quoted = False
        elif value == 34: quoted = True
        elif value in (91, 123):
            depth += 1
            if depth > worker.MAX_DEPTH: raise worker.ReadError('JSON nesting limit exceeded.')
        elif value in (93, 125):
            depth -= 1
            if depth < 0: raise worker.ReadError('Invalid JSON response.')
    return json.loads(raw.decode('utf-8'), parse_constant=worker.reject_constant,
                      object_pairs_hook=worker.unique_object)


def percentile(samples, q):
    values = sorted(samples)
    index = (len(values)-1)*q
    lo = int(index)
    return values[lo] + (values[min(lo+1, len(values)-1)]-values[lo])*(index-lo)


def run(samples=11):
    fixtures = {
        'unchanged_snapshot': {'version': 2, 'revision': 'fixture:1', 'unchanged': True},
        'chat_list_1000': [{'jid': f'fixture-{i}', 'name': f'Contact {i}', 'last': 'Example preview ' * 8,
                            'ts': 1700000000+i, 'unread': i % 3} for i in range(1000)],
        'text_4MiB_span': {'text': 'a'*(4*1024*1024-32)},
        'media_16MiB_span': {'data': 'A'*(16*1024*1024)},
        'escape_heavy': {'text': '\\"[]{}' * 120000},
    }
    results=[]
    for name, body in fixtures.items():
        raw=json.dumps(body, ensure_ascii=False, separators=(',', ':')).encode()
        assert rc3_reference(raw) == worker.decode_json(raw) == body
        old=[]; new=[]
        for i in range(samples):
            # Alternate order rather than timing all baseline runs first.
            for function, target in ([(rc3_reference, old), (worker.decode_json, new)] if i%2==0 else
                                     [(worker.decode_json, new), (rc3_reference, old)]):
                gc.collect()
                start=time.perf_counter(); result=function(raw); target.append((time.perf_counter()-start)*1000)
                assert result == body
                del result
        results.append({'fixture': name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
                        'rc3_p50_ms': statistics.median(old), 'rc4_p50_ms': statistics.median(new),
                        'rc3_p95_ms': percentile(old,.95), 'rc4_p95_ms': percentile(new,.95),
                        'rc3_over_rc4_p50': statistics.median(old)/statistics.median(new),
                        'rc3_samples_ms': old, 'rc4_samples_ms': new, 'equivalent_output': True})
    return {'scope': __doc__, 'python': platform.python_version(), 'platform': platform.platform(),
            'samples_per_variant': samples, 'gating': 'Output equivalence only; no flaky speed threshold',
            'worker_sha256': hashlib.sha256((ROOT/'scripts/read-worker.py').read_bytes()).hexdigest(),
            'results': results}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples', type=int, default=11)
    args=parser.parse_args()
    if not 3 <= args.samples <= 101: parser.error('samples must be between 3 and 101')
    print(json.dumps(run(args.samples), indent=2, allow_nan=False))
