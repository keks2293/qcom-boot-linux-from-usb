#!/bin/sh
# Disassembly pipeline for the ADSP/PPM firmware (adsp.mbn, Qualcomm Hexagon).
#
# Usage:
#   dump_adsp.sh <adsp.mbn> <out_dir>
#
# Produces in <out_dir>:
#   elfmap.txt       - ELF header, PHDR list, LOAD segment file<->vaddr map
#   adsp_strings.txt - strings with FILE offsets ("0x<off> <string>")
#   text_all.txt     - full disassembly (~3.7M lines for rp6)
#
# Toolchain: any LLVM/Clang with the Hexagon backend (Homebrew LLVM on macOS
# works; /opt/homebrew/opt/llvm). No cross-compiler build needed.
#
# Mapping (rp6 adsp.mbn, verified): the code+data segment used for RE is
#   PT_LOAD#19  file [0xa93000:0xcd67c4]  <->  vaddr [0x60000000:0x602437c4]
# so a string at file offset F has virtual address
#   vaddr = 0x60000000 + (F - 0xa93000)     (valid while F <= 0xcd67c4)
# Run adsp_elfmap.py to re-derive this for a different build.
set -eu

MBN=${1:?usage: dump_adsp.sh <adsp.mbn> <out_dir>}
OUT=${2:?usage: dump_adsp.sh <adsp.mbn> <out_dir>}
mkdir -p "$OUT"

OBJDUMP=${LLVM_OBJDUMP:-llvm-objdump}
STRINGS=${BINUTILS_STRINGS:-strings}

# 1. ELF map (segment ranges + NOTE segments)
python3 "$(dirname "$0")/adsp_elfmap.py" "$MBN" > "$OUT/elfmap.txt"

# 2. Strings with file offsets (decimal is what `strings -t d` prints;
#    we use hex here for direct use with vaddr2str.py)
$STRINGS -t x "$MBN" > "$OUT/adsp_strings_raw.txt"
awk '{ printf "0x%s %s\n", $1, substr($0, index($0, $2)) }' "$OUT/adsp_strings_raw.txt" \
  > "$OUT/adsp_strings.txt"

# 3. FULL disassembly.
#    GOTCHA: --start-address/--stop-address do NOT work on this file
#    ("no section overlaps" warning, ~164 KB slice produced). Dump the whole
#    file and slice text_all.txt afterwards.
$OBJDUMP --triple=hexagon -d "$MBN" > "$OUT/text_all.txt"

echo "done: $(wc -l < "$OUT/text_all.txt") disasm lines, $(wc -l < "$OUT/adsp_strings.txt") strings"
echo "xref technique: grep '##0x<vaddr>' $OUT/text_all.txt"
echo "  (the disassembler resolves the Hexagon split-immediate '##' extension"
echo "   into the full 32-bit value, so no immext resolver is needed)"
