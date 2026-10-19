#!/usr/bin/env python3
"""Fetch the Redmi Note 9 Pro (joyeuse) touch IC firmware from a MIUI ROM.

  joyeuse-touch-fw.py OUTDIR [RECOVERY_ROM_ZIP_URL]

Downloads only vendor.new.dat.br + vendor.transfer.list from the recovery
ROM zip (HTTP ranges, tools/remotezip.py), unpacks the block OTA into a raw
ext4 image, and copies /firmware/focaltech_ts_fw_huaxing.bin (FT8756) and
/firmware/novatek_ts_tianma_fw.bin (NT36675) to OUTDIR after checking them
like the vendor drivers do. Needs the `brotli` CLI and ~1.5 GB of scratch
space in OUTDIR/rom (deleted at the end). Then:

  sudo tools/sweet-root-tweaks.py /mnt/iosroot --touch-fw OUTDIR

The default ROM is MIUI 14.0.3.0.SJZMIXM (global) on cdnorg.d.miui.com;
bigota.d.miui.com serves the same files, often at a few KB/s.
"""
import os, shutil, struct, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import remotezip  # noqa: E402

ROM = ('https://cdnorg.d.miui.com/V14.0.3.0.SJZMIXM/'
       'miui_JOYEUSEGlobal_V14.0.3.0.SJZMIXM_df17e3fabf_12.0.zip')
FILES = ('focaltech_ts_fw_huaxing.bin', 'novatek_ts_tianma_fw.bin')
B = 4096


def sdat2img(transfer_list, new_dat, out):
    """Block OTA (transfer list v2+ 'new' commands) -> raw image."""
    lines = open(transfer_list).read().split('\n')
    cmds = lines[4:] if int(lines[0]) >= 2 else lines[2:]
    end = 0
    with open(new_dat, 'rb') as src, open(out, 'wb') as dst:
        for line in filter(str.strip, cmds):
            op, rng = line.split(' ', 1)
            r = [int(x) for x in rng.split(',')]
            pairs = list(zip(r[1::2], r[2::2]))
            end = max([end] + [b for a, b in pairs])
            if op != 'new':
                continue
            for a, b in pairs:
                dst.seek(a * B)
                n = (b - a) * B
                while n:
                    chunk = src.read(min(n, 1 << 24))
                    assert chunk, 'new.dat too short'
                    dst.write(chunk)
                    n -= len(chunk)
        dst.truncate(end * B)


class Ext4:
    """Just enough read-only ext4: inodes, extent trees, linear directories."""

    def __init__(self, path):
        self.f = open(path, 'rb')
        sb = self.rd(1024, 1024)
        assert struct.unpack_from('<H', sb, 0x38)[0] == 0xef53, 'not ext4'
        self.bs = 1024 << struct.unpack_from('<I', sb, 0x18)[0]
        self.ipg = struct.unpack_from('<I', sb, 0x28)[0]
        self.isz = struct.unpack_from('<H', sb, 0x58)[0]
        self.dsz = struct.unpack_from('<H', sb, 0xfe)[0] if struct.unpack_from('<I', sb, 0x60)[0] & 0x80 else 32
        self.gdt = (1 if self.bs > 1024 else 2) * self.bs

    def rd(self, off, n):
        self.f.seek(off)
        return self.f.read(n)

    def inode(self, n):
        g, i = divmod(n - 1, self.ipg)
        d = self.rd(self.gdt + g * self.dsz, self.dsz)
        tbl = struct.unpack_from('<I', d, 8)[0] | ((struct.unpack_from('<I', d, 0x28)[0] << 32) if self.dsz >= 64 else 0)
        return self.rd(tbl * self.bs + i * self.isz, self.isz)

    def extents(self, node):
        magic, count, _, depth = struct.unpack_from('<HHHH', node, 0)
        assert magic == 0xf30a, 'bad extent header'
        for e in range(count):
            o = 12 + 12 * e
            if depth == 0:
                lblk, ln, hi, lo = struct.unpack_from('<IHHI', node, o)
                yield lblk, (hi << 32) | lo, ln - 32768 if ln > 32768 else ln
            else:
                _, lo, hi = struct.unpack_from('<IIH', node, o)
                yield from self.extents(self.rd(((hi << 32) | lo) * self.bs, self.bs))

    def data(self, ino):
        raw = self.inode(ino)
        size = struct.unpack_from('<I', raw, 4)[0] | (struct.unpack_from('<I', raw, 0x6c)[0] << 32)
        flags = struct.unpack_from('<I', raw, 0x20)[0]
        blk = raw[0x28:0x28 + 60]
        if flags & 0x10000000:  # inline data
            return blk[:size]
        assert flags & 0x80000, 'only extent-mapped files are supported'
        out = bytearray(size)
        for lblk, pblk, ln in self.extents(blk):
            start = lblk * self.bs
            if start < size:
                chunk = self.rd(pblk * self.bs, ln * self.bs)[:size - start]
                out[start:start + len(chunk)] = chunk
        return bytes(out)

    def lookup(self, path):
        ino = 2
        for part in filter(None, path.split('/')):
            d, o, nxt = self.data(ino), 0, None
            while o + 8 <= len(d) and nxt is None:
                child, rlen, nlen = struct.unpack_from('<IHB', d, o)
                if rlen < 8:
                    break
                if child and d[o + 8:o + 8 + nlen].decode(errors='replace') == part:
                    nxt = child
                o += rlen
            if nxt is None:
                raise FileNotFoundError(path)
            ino = nxt
        return self.data(ino)


def check_fts(b):
    """focaltech_flash.c fts_pram_write_ecc: app length and its complement."""
    code, code_n = struct.unpack_from('>HH', b, 0x100)
    assert code + code_n == 0xffff and code * 2 <= 88 * 1024, 'FT8756 app length'
    return f'pram {code * 2} bytes'


def check_nvt(b):
    """nt36xxx_fw_update.c: 'NVT'/'MOD' end flag and fw version bar."""
    need = next(i * B for i in range(len(b) // B, 0, -1) if b[i * B - 3:i * B] in (b'NVT', b'MOD'))
    assert b[need - B] + b[need - B + 1] == 0xff, 'NT36675 version bar'
    return f'fw version {b[need - B]:#x}'


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    out, url = sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else ROM
    rom = os.path.join(out, 'rom')
    os.makedirs(rom, exist_ok=True)
    entries = {e[0]: e for e in remotezip.central_dir(url)}
    for name in ('vendor.transfer.list', 'vendor.new.dat.br'):
        remotezip.extract(url, entries[name], rom)
    dat, img = os.path.join(rom, 'vendor.new.dat'), os.path.join(rom, 'vendor.img')
    subprocess.run(['brotli', '-d', '-f', os.path.join(rom, 'vendor.new.dat.br'), '-o', dat], check=True)
    sdat2img(os.path.join(rom, 'vendor.transfer.list'), dat, img)
    fs = Ext4(img)
    for name, check in zip(FILES, (check_fts, check_nvt)):
        blob = fs.lookup('/firmware/' + name)
        info = check(blob)
        with open(os.path.join(out, name), 'wb') as f:
            f.write(blob)
        print(f'{name}: {len(blob)} bytes, {info}')
    shutil.rmtree(rom)


if __name__ == '__main__':
    main()
