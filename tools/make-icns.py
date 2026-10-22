#!/usr/bin/env python3
"""Packs the PNGs from tools/make-icon.swift into an .icns file.

iconutil doesn't run inside Claude's sandbox, so this writes the format
directly: an 'icns' header, then one chunk per size, each wrapping a PNG.
Usage: tools/make-icns.py <png-dir> <out.icns>
"""
import pathlib
import struct
import sys

# chunk type -> pixel size of the PNG it holds (@2x types reuse larger PNGs)
CHUNKS = [("icp4", 16), ("icp5", 32), ("ic07", 128), ("ic08", 256),
          ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]

src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
body = b""
for kind, px in CHUNKS:
    png = (src / f"icon_{px}.png").read_bytes()
    if not png.startswith(b"\x89PNG"):
        sys.exit(f"icon_{px}.png isn't a PNG")
    body += kind.encode("ascii") + struct.pack(">I", 8 + len(png)) + png
out.write_bytes(b"icns" + struct.pack(">I", 8 + len(body)) + body)
print(f"wrote {out} ({8 + len(body)} bytes, {len(CHUNKS)} sizes)")
