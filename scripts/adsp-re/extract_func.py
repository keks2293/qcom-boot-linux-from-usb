#!/usr/bin/env python3
"""Extract the Hexagon function enclosing a reference site.

Usage:
    extract_func.py <text_all.txt> <out_dir> <vaddr> [<vaddr> ...]

Hexagon function shape in the llvm-objdump dump:
    prologue:  ... ;  allocframe(#0xNN)      (first real instruction of the fn)
    epilogue:  deallocframe  /  dealloc_return  +  jump <addr>

Given a vaddr (a site inside a fn), scan backward for the nearest preceding
`allocframe` and forward for the nearest following `deallocframe`/
`dealloc_return`; write that range (capped) to <out_dir>/func_at_<vaddr>.txt
and print head/tail previews to stdout.

Addresses are the virtual addresses from the disassembly (see the
PT_LOAD mapping printed by adsp_elfmap.py, e.g. 0x60000000+ for rp6).
"""
import os
import sys

CAP = 600  # max lines scanned for prologue/epilogue


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    txt_path, out_dir = sys.argv[1], sys.argv[2]
    targets = sys.argv[3:]
    os.makedirs(out_dir, exist_ok=True)

    with open(txt_path, "r", errors="replace") as f:
        lines = f.read().splitlines()
    n = len(lines)
    print(f"loaded {n} lines", file=sys.stderr)

    def find_idx(vaddr: str):
        pref = vaddr.lower() + ":"
        for i in range(n):
            if lines[i].startswith(pref):
                return i
        return None

    def extract(idx: int):
        start = idx
        for i in range(idx, max(-1, idx - CAP), -1):
            if "allocframe" in lines[i]:
                start = i
                break
        end = idx
        for i in range(idx, min(n, idx + CAP)):
            if "deallocframe" in lines[i] or "dealloc_return" in lines[i]:
                end = i
                j = i + 1
                while j < min(n, i + 5) and "jump" in lines[j]:
                    end = j
                    j += 1
                break
        return start, end

    def addr_of(i: int):
        col = lines[i].find(":")
        return lines[i][:col] if 0 < col < 12 else "?"

    for v in targets:
        idx = find_idx(v)
        if idx is None:
            print(f"\n##### {v}: NOT FOUND")
            continue
        start, end = extract(idx)
        rng = end - start + 1
        name = f"func_at_{v}"
        out = f"{out_dir}/{name}.txt"
        with open(out, "w") as f:
            f.write(f"# function enclosing site {v}  (lines {start+1}..{end+1}, {rng} lines)\n")
            f.write(f"# start vaddr {addr_of(start)}   end vaddr {addr_of(end)}\n")
            for k in range(start, end + 1):
                f.write(f"{k+1:>7}: {lines[k]}\n")
        print(f"\n##### site {v} (line {idx+1}) -> fn lines {start+1}..{end+1} ({rng} lines)  "
              f"[{addr_of(start)} .. {addr_of(end)}]  -> {out}")
        print("  -- head --")
        for k in range(start, min(start + 12, end + 1)):
            print(f"    {k+1:>7}: {lines[k]}")
        if end - start > 20:
            print("    ...")
            for k in range(max(start, end - 7), end + 1):
                print(f"    {k+1:>7}: {lines[k]}")


if __name__ == "__main__":
    main()
