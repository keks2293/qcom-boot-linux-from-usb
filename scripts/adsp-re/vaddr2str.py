#!/usr/bin/env python3
"""Resolve virtual addresses to strings using the PT_LOAD file<->vaddr map.

Usage:
    vaddr2str.py <adsp_strings.txt> <vaddr> [<vaddr> ...]
    vaddr2str.py <adsp_strings.txt> --base <seg_va_start> --segoff <seg_fileoff> <vaddr> ...

Defaults match the rp6 adsp.mbn build (PT_LOAD#19):
    vaddr = 0x60000000 + (fileoff - 0xa93000)
i.e. --base 0x60000000 --segoff 0xa93000.
Run adsp_elfmap.py on a different build to get its segment pair.

adsp_strings.txt format (produced by dump_adsp.sh): "0x<fileoff> <string>"
"""
import sys


def main():
    args = sys.argv[1:]
    base, segoff = 0x60000000, 0xa93000
    if "--base" in args:
        i = args.index("--base")
        base = int(args[i + 1], 16)
        del args[i:i + 2]
    if "--segoff" in args:
        i = args.index("--segoff")
        segoff = int(args[i + 1], 16)
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)
    path = args[0]
    table = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or " " not in line:
                continue
            off, s = line.split(" ", 1)
            try:
                table[int(off, 16)] = s
            except ValueError:
                continue
    for a in args[1:]:
        v = int(a, 16)
        fo = segoff + (v - base)
        s = table.get(fo)
        if s is None:
            print(f"{a}: (no string at fileoff {fo:#x})")
        else:
            print(f"{a}: {s}")


if __name__ == "__main__":
    main()
