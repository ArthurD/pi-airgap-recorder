#!/bin/bash
# Decompress the verified .img.xz using python3's built-in lzma module.
# macOS has no xz(1), and python3 ships with the Command Line Tools, so this
# avoids pulling in a third-party archiver just to unpack one file.

set -euo pipefail
cd "$(dirname "$0")/.."
. build/lib.sh

XZ=$(ls -1 "${CACHE}"/*.img.xz 2>/dev/null | head -1) \
    || die "no .img.xz in ${CACHE} - run build/00-fetch-verify.sh first"
IMG="${XZ%.xz}"

if [ -f "$IMG" ]; then
    say "already decompressed: $IMG ($(du -h "$IMG" | cut -f1))"
    exit 0
fi

say "decompressing $(basename "$XZ") -> $(basename "$IMG")"
python3 - "$XZ" "$IMG" <<'PY'
import lzma, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
tmp = dst + ".partial"
with lzma.open(src, "rb") as fin, open(tmp, "wb") as fout:
    shutil.copyfileobj(fin, fout, length=8 * 1024 * 1024)
shutil.move(tmp, dst)
PY

say "decompressed: $IMG ($(du -h "$IMG" | cut -f1))"
