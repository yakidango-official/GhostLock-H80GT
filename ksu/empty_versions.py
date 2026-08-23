#!/usr/bin/env python3
"""Empty the __versions section of a kernel module (keep the header, sh_size=0).

Why (5.10.168, CONFIG_MODVERSIONS=y, no CONFIG_MODULE_FORCE_LOAD):
  - no __versions section      -> try_to_force_load -> -ENOEXEC (must exist)
  - section exists, symbol NOT listed -> pr_warn_once + PASS
  - symbol listed, crc mismatch -> FAIL
With no Module.symvers, modpost emits crc=0 entries -> guaranteed mismatch.
Emptying the section turns every CRC check into warn-once + PASS, and
same_magic() sees has_crcs=true so the vermagic release string is skipped.
"""
import struct
import sys

src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, 'rb').read())

assert data[:4] == b'\x7fELF', 'not ELF'
assert data[4] == 2 and data[5] == 1, 'need ELF64 little-endian'

e_shoff = struct.unpack_from('<Q', data, 0x28)[0]
e_shentsize = struct.unpack_from('<H', data, 0x3A)[0]
e_shnum = struct.unpack_from('<H', data, 0x3C)[0]
e_shstrndx = struct.unpack_from('<H', data, 0x3E)[0]
assert e_shnum != 0 and e_shstrndx != 0, 'SHN_XINDEX not handled'

shstr = e_shoff + e_shstrndx * e_shentsize
str_off = struct.unpack_from('<Q', data, shstr + 0x18)[0]  # sh_offset

found = False
for i in range(e_shnum):
    sh = e_shoff + i * e_shentsize
    name_off = struct.unpack_from('<I', data, sh)[0]
    end = data.index(b'\0', str_off + name_off)
    name = data[str_off + name_off:end].decode()
    if name == '__versions':
        old = struct.unpack_from('<Q', data, sh + 0x20)[0]
        struct.pack_into('<Q', data, sh + 0x20, 0)  # sh_size = 0
        print(f'__versions: sh_size {old} -> 0 (section kept)')
        found = True

if not found:
    print('WARNING: no __versions section found; vermagic release will be compared')

open(dst, 'wb').write(data)
print(f'wrote {dst} ({len(data)} bytes)')
