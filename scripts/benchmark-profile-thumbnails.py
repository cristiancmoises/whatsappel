#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Measure actual local FFmpeg fixture preparation, not Emacs or CDN latency."""
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import statistics
import struct
import time
import zlib

root=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('profile_thumbnail_bench',root/'profile-worker.py')
w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
def chunk(kind,data):
    return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
source=(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',256,128,8,2,0,0,0))
        +chunk(b'IDAT',zlib.compress((b'\0'+b'\x20\xa0\xa8'*256)*128))+chunk(b'IEND',b''))
original=hashlib.sha256(source).hexdigest();rows=[]
for edge in (96,256):
    times=[];sizes=[]
    for _ in range(7):
        start=time.perf_counter();result=w.thumbnail(source,edge)
        times.append((time.perf_counter()-start)*1000);sizes.append(len(result))
        assert w.dimensions(result)==(edge,edge) and len(result)<w.MAX_PNG
        assert hashlib.sha256(source).hexdigest()==original
    rows.append({'edge_px':edge,'samples_ms':times,'median_ms':statistics.median(times),
                 'p95_ms':sorted(times)[-1],'max_png_bytes':max(sizes)})
print(json.dumps({'scope':'Actual local FFmpeg on synthetic raster; includes process startup, excludes HTTP and Emacs. No baseline speedup claim.',
                  'python':platform.python_version(),'system':platform.platform(),'samples':7,'source_sha256':original,'measurements':rows},indent=2))
