#!/usr/bin/env python3
"""ELF segment map for adsp.mbn (ELF 32-bit little-endian, Qualcomm Hexagon).

Usage:
    adsp_elfmap.py <adsp.mbn>

Prints the ELF header, the program-header list, NOTE segments, and the
LOAD-segment ranges as
    file [off_start:off_end]  vaddr [va_start:va_end]
which is the file-offset <-> virtual-address mapping needed to turn
`strings -t x` file offsets into the vaddrs used in the disassembly:

    vaddr = va_start + (fileoff - off_start)     (within one LOAD segment)

For the rp6 build the RE-relevant segment is PT_LOAD#19:
    file [0xa93000:0xcd67c4]  <->  vaddr [0x60000000:0x602437c4]
(the firmware has no section headers: shoff=0/shnum=0).
"""
import struct
import sys

path = sys.argv[1]
b = open(path, "rb").read()
assert b[:4] == b"\x7fELF", "not ELF"
ei_class = b[4]            # 1 = 32-bit
ei_data = b[5]             # 1 = LE
e_type, e_machine = struct.unpack_from("<HH", b, 16)
e_entry, e_phoff, e_shoff = struct.unpack_from("<III", b, 24)
e_ehsize, e_phentsize, e_phnum = struct.unpack_from("<HHH", b, 40)
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", b, 46)

PT = {1: "LOAD", 2: "DYN", 3: "INTERP", 4: "NOTE", 6: "PHDR", 7: "GNU_EH_FRAME",
      8: "GNU_STACK", 0x6474e550: "GNU_RELRO", 0x6474e551: "GNU_STACK2"}
print(f"ELF: class={ei_class} data={ei_data} type={e_type:#x} machine={e_machine:#x} entry={e_entry:#x}")
print(f"phoff={e_phoff:#x} phnum={e_phnum} phentsize={e_phentsize} shoff={e_shoff:#x} shnum={e_shnum}")
print()
segs = []
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    p_type = struct.unpack_from("<I", b, off)[0]
    p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align = \
        struct.unpack_from("<IIIIIII", b, off + 4)
    name = PT.get(p_type, f"0x{p_type:x}")
    print(f"PHDR[{i}] {name:10s} off={p_offset:#010x} vaddr={p_vaddr:#010x} paddr={p_paddr:#010x} "
          f"filesz={p_filesz:#010x} memsz={p_memsz:#010x} flags={p_flags:#x}")
    if p_type == 1:
        segs.append((p_offset, p_offset + p_filesz, p_vaddr, p_vaddr + p_filesz, p_memsz, p_flags))
print()
# NOTE segments (Qualcomm: DSP version, firmware version, ...)
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    p_type = struct.unpack_from("<I", b, off)[0]
    if p_type == 4:
        p_offset = struct.unpack_from("<I", b, off + 4)[0]
        p_filesz = struct.unpack_from("<I", b, off + 0x10)[0]
        print(f"--- NOTE segment @ {p_offset:#x} ({p_filesz} B):")
        p = p_offset
        end = p_offset + p_filesz
        while p + 12 <= end:
            namesz, descsz, n_type = struct.unpack_from("<III", b, p)
            if namesz > 1000 or descsz > 1000 or p + 12 + namesz + descsz > end:
                print(f"  (end/garbage @ {p:#x})")
                break
            name = b[p + 12:p + 12 + namesz].rstrip(b"\x00").decode("utf8", "replace")
            desc = b[p + 12 + namesz:p + 12 + namesz + descsz]
            if len(desc) <= 32:
                print(f"  note {name} type={n_type:#x}: {desc.hex()}")
            else:
                print(f"  note {name} type={n_type:#x}: {desc[:48].hex()}... ({len(desc)} B)")
            p += 12 + namesz + ((descsz + 3) & ~3)

print()
print("LOAD segments (off-range = what to read from the file; vaddr = where it is mapped):")
for (so, se, va, ve, memsz, fl) in segs:
    rw = "R" if fl & 4 else "-"
    x = "X" if fl & 1 else "-"
    w = "W" if fl & 2 else "-"
    print(f"  file [{so:#010x}:{se:#010x}] size={se - so:#010x}  "
          f"vaddr [{va:#010x}:{ve:#010x}] memsz={memsz:#x} {rw}{x}{w}")
