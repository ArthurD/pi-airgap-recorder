#!/bin/bash
# repair-wav.sh - repair WAV files truncated by a power cut.
#
# When power is pulled mid-segment, the audio samples are all on disk but the
# RIFF/data size fields in the header still say whatever arecord wrote when it
# opened the file. Players then either refuse the file or stop early.
#
# Nothing is actually lost. This rewrites the two size fields to match the
# bytes that are really there. It walks the chunk list rather than assuming a
# 44-byte header, and never looks at the sample format - so 16/24/32-bit
# integer and 32-bit float, at any sample rate, are all repaired identically.
#
#     ./tools/repair-wav.sh path/to/recordings/000001_*/seg-*.wav
#     ./tools/repair-wav.sh --check seg-*.wav     ask, without writing
#
# Originals are kept as <name>.orig unless --in-place is given.
#
# --check writes nothing at all - it only reports, and says so in its exit
# status: 0 when every file's header is already correct, 1 when any file needs
# repair, 2 when nothing needs repair but something could not be read or was
# not a RIFF/WAVE file. The ingest leans on that 1: it is the cheap way to ask
# "is a repaired derivative worth making?" without copying a 460 MB file first.

set -euo pipefail

INPLACE=0
CHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --in-place) INPLACE=1; shift ;;
        --check)    CHECK=1; shift ;;
        *)          break ;;
    esac
done

[ $# -gt 0 ] || { echo "usage: $0 [--in-place|--check] file.wav [file.wav ...]" >&2; exit 2; }

python3 - "$INPLACE" "$CHECK" "$@" <<'PY'
import os, shutil, struct, sys

inplace = sys.argv[1] == "1"
check = sys.argv[2] == "1"
paths = sys.argv[3:]
fixed = ok = bad = 0

for p in paths:
    try:
        size = os.path.getsize(p)
        with open(p, "rb") as f:
            head = f.read(12)
            if len(head) < 12 or head[0:4] != b"RIFF" or head[8:12] != b"WAVE":
                print(f"SKIP  {p}: not a RIFF/WAVE file")
                bad += 1
                continue

            # Walk the chunk list to find where 'data' starts.
            f.seek(12)
            data_off = data_declared = None
            while True:
                hdr = f.read(8)
                if len(hdr) < 8:
                    break
                cid, clen = struct.unpack("<4sI", hdr)
                if cid == b"data":
                    data_off = f.tell()
                    data_declared = clen
                    break
                f.seek(clen + (clen & 1), os.SEEK_CUR)

        if data_off is None:
            print(f"SKIP  {p}: no data chunk")
            bad += 1
            continue

        actual = size - data_off
        riff_should = size - 8

        with open(p, "rb") as f:
            f.seek(4)
            riff_declared = struct.unpack("<I", f.read(4))[0]

        if riff_declared == riff_should and data_declared == actual:
            print(f"OK    {p}: header already correct ({actual} bytes of audio)")
            ok += 1
            continue

        if check:
            print(f"NEEDS-REPAIR {p}: data {data_declared} -> {actual} bytes")
            fixed += 1
            continue

        if not inplace:
            shutil.copy2(p, p + ".orig")

        with open(p, "r+b") as f:
            f.seek(4);            f.write(struct.pack("<I", riff_should))
            f.seek(data_off - 4); f.write(struct.pack("<I", actual))
            f.flush(); os.fsync(f.fileno())

        print(f"FIXED {p}: data {data_declared} -> {actual} bytes"
              + ("" if inplace else "  (original kept as .orig)"))
        fixed += 1

    except Exception as e:
        print(f"ERROR {p}: {e}")
        bad += 1

if check:
    print(f"\n{fixed} need repair, {ok} already fine, {bad} skipped/failed")
    sys.exit(1 if fixed else (2 if bad else 0))

print(f"\n{fixed} repaired, {ok} already fine, {bad} skipped/failed")
PY
