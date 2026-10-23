#!/usr/bin/env python3
"""rec2png.py REC OUTDIR: splits a sweet-rec stream into OUTDIR/<ms>-<id>.ppm frames (suffix b: the GPU was drawing it, f: free, likely on screen)."""
import os, struct, sys
data = open(sys.argv[1], 'rb').read()
os.makedirs(sys.argv[2], exist_ok=True)
off = 0
while off + 20 <= len(data):
    magic, sid, w, h, ms = struct.unpack_from('<5I', data, off)
    assert magic == 0x43455253, hex(magic)
    off += 20
    px = data[off:off + w * h * 3]
    off += w * h * 3
    busy = 'b' if sid & 0x80000000 else 'f'
    with open(os.path.join(sys.argv[2], '%06d-%d%s.ppm' % (ms, sid & 0x7fffffff, busy)), 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (w, h) + px)
