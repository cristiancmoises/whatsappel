#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Check installed FFmpeg capabilities; does not access a microphone or a player."""
import shutil
import subprocess
import sys


def main():
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        print("BLOCKED: FFmpeg is missing")
        return 1
    required = [("-encoders", ("libopus", "libx264")), ("-devices", ("pulse",)), ("-filters", ("scale", "pad"))]
    for argument, words in required:
        p = subprocess.run([ffmpeg, "-hide_banner", argument], capture_output=True, text=True, timeout=20)
        text = p.stdout + p.stderr
        if p.returncode or any(word not in text for word in words):
            print("FAIL: missing FFmpeg capability " + ", ".join(words))
            return 1
    print("PASS: FFmpeg advertises PulseAudio input, libopus, libx264, scale and pad. No microphone was accessed.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
