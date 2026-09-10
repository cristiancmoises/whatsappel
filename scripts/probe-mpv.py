#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Decode a generated local fixture through the hardened mpv path, with no GUI/audio output."""
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    if not shutil.which("mpv") or not shutil.which("ffmpeg"):
        print("BLOCKED: mpv and FFmpeg are required for the native local decode probe")
        return 1
    with tempfile.TemporaryDirectory(prefix="whatsappel-mpv-probe-") as tmp:
        video = Path(tmp) / "fixture.mp4"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "color=size=64x64:rate=10:duration=0.2", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(video)], check=True, timeout=20)
        subprocess.run(["mpv", "--no-config", "--load-scripts=no", "--ytdl=no", "--access-references=no", "--sub-auto=no", "--audio-file-auto=no", "--demuxer-lavf-o=protocol_whitelist=file", "--keep-open=no", "--force-window=no", "--osc=yes", "--vo=null", "--ao=null", "--", str(video)], check=True, timeout=20)
    print("PASS: native local fixture decode; graphical window interaction is not covered")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
