#!/bin/bash
# scrap-selftest.sh - exercise `umik scrap` against a fake stick and a scratch
# archive. Never touches ~/UMIK-Archive, S3, the NAS, or a real medium: every
# run is --dry-run, refused, or --no-process (seal + prune into the scratch
# archive; the eject of a plain directory fails and must be tolerated).
#
#   tools/tests/scrap-selftest.sh [scratch-dir]
#
# Exit 0 and one PASS line when everything holds; non-zero otherwise.

set -uo pipefail

TOOLS_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRAP="$TOOLS_DIR/umik-scrap.sh"
T="${1:-${TMPDIR:-/tmp}/scrap-tests}"
STICK="$T/TESTSTICK"
export UMIK_ARCHIVE="$T/archive"
export UMIK_CONF=/dev/null          # never the real umik.local.conf
export TZ=America/New_York          # "local" for every run here: EDT in October
A=umik1_000060_20261020T120000Z     # S24_3LE 48 kHz mono: 144000 bytes/s
B=umik1_000061_20261021T000000Z     # FLOAT_LE 192 kHz mono: 768000 bytes/s

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check() { # <description> <command...>
    local what=$1; shift
    if "$@"; then ok; else bad "$what"; fi
}
# shellcheck disable=SC2329  # only ever called through check()
has() { grep -qF -- "$1" "$2"; }

session_json() { # <dir> <session> <started> <encoding> <rate>
    cat > "$1/session.json" <<EOF
{
  "session": "$2",
  "unit": "umik1",
  "started_utc": "$3",
  "clock_trusted": true,
  "time_source": "rtc",
  "rtc": { "present": true, "trusted": true, "note": "clock set from disciplined RTC" },
  "device": {
    "usb_id": "2752:0007",
    "mic": "miniDSP UMIK-1",
    "alsa_card": 1
  },
  "format": { "encoding": "$4", "sample_rate": $5, "bandwidth_hz": $(($5 / 2)), "channels": 1 }
}
EOF
}

# Segments are 1000 bytes: a real 600 s segment is 86-460 MB. That size
# implies under a second, so each must fall back to 600 s. The 14:00 one in
# session A is a short last segment the formula CAN size: 44 + 7 s of audio.
build() {
    rm -rf "$STICK" "$UMIK_ARCHIVE"
    mkdir -p "$STICK/recordings/$A" "$STICK/recordings/$B" "$STICK/logs" "$UMIK_ARCHIVE"
    session_json "$STICK/recordings/$A" 000060 20261020T120000Z S24_3LE 48000
    session_json "$STICK/recordings/$B" 000061 20261021T000000Z FLOAT_LE 192000
    local m
    for m in 00 10 20 30 40 50; do
        head -c 1000 /dev/zero > "$STICK/recordings/$A/seg-20261020-12${m}00.wav"
        head -c 1000 /dev/zero > "$STICK/recordings/$A/seg-20261020-13${m}00.wav"
        head -c 1000 /dev/zero > "$STICK/recordings/$B/seg-20261021-00${m}00.wav"
    done
    head -c $((44 + 144000 * 7)) /dev/zero > "$STICK/recordings/$A/seg-20261020-140000.wav"
    echo "mic moved to the porch" > "$STICK/recordings/$A/notes.txt"
    head -c 500 /dev/zero > "$STICK/recordings/$A/clip-20261020-123000-104100k.sigmf-data.part"
    head -c 100 /dev/zero > "$STICK/recordings/$A/._seg-20261020-120000.wav"
    echo 61 > "$STICK/recordings/.session-counter"
    echo "boot ok" > "$STICK/logs/umik.log"
}
snapshot() { find "$STICK" -exec stat -f '%N %z' {} + | sort; }
sums() { # <session> -> sealed names, sorted
    sed 's/^[0-9a-f]*  //' "$UMIK_ARCHIVE/recordings/umik1/$1/SHA256SUMS" 2>/dev/null | sort | tr '\n' ' '
}

mkdir -p "$T"
OUT="$T/out"

# --- usage errors -------------------------------------------------------------
build
"$SCRAP" "$STICK" --keep 2026-10-20..2026-10-21 --drop 2026-10-20..2026-10-21 > "$OUT" 2>&1
check "--keep with --drop is a usage error (exit 2)" [ $? -eq 2 ]
check "--keep with --drop says so" has "cannot be combined" "$OUT"
"$SCRAP" > "$OUT" 2>&1
check "no volume is a usage error" [ $? -eq 2 ]
"$SCRAP" "$STICK" --keep 2026-10-21..2026-10-20 > "$OUT" 2>&1
check "a backwards range is a usage error" [ $? -eq 2 ]
"$SCRAP" "$STICK" --keep 2026-02-30..2026-03-02 > "$OUT" 2>&1
check "an impossible date is a usage error" [ $? -eq 2 ]

# --- dry run: plan printed, nothing changed ---------------------------------
before=$(snapshot)
"$SCRAP" "$STICK" --dry-run > "$OUT" 2>&1
check "dry run exits 0" [ $? -eq 0 ]
check "dry run changes nothing" [ "$before" = "$(snapshot)" ]
check "dry run prints DROP totals" grep -qE '^ +DROP +20 file' "$OUT"
check "dry run prints KEEP totals" grep -qE '^ +KEEP +0 file' "$OUT"
check "dry run says it changed nothing" has "dry run - nothing changed" "$OUT"
check "untimed notes.txt is dropped under drop-everything" has "UNTIMED 1 (dropped)" "$OUT"

# --- refusals ----------------------------------------------------------------
"$SCRAP" "$STICK" < /dev/null > "$OUT" 2>&1
check "non-tty without --yes fails" [ $? -eq 1 ]
check "non-tty without --yes says why" has "not a terminal" "$OUT"
check "non-tty without --yes changes nothing" [ "$before" = "$(snapshot)" ]

mkdir "$UMIK_ARCHIVE/.lock"
"$SCRAP" "$STICK" --yes --no-process > "$OUT" 2>&1
check "a running ingest (.lock) is refused" [ $? -eq 1 ]
rmdir "$UMIK_ARCHIVE/.lock"

echo '{}' > "$STICK/recordings/$B/scrapped.json"
"$SCRAP" "$STICK" --yes --no-process > "$OUT" 2>&1
check "an unfinished earlier scrap (scrapped.json) is refused" [ $? -eq 1 ]
check "the refusal points at umik process" has "umik process $STICK" "$OUT"
rm "$STICK/recordings/$B/scrapped.json"
check "refusals changed nothing" [ "$before" = "$(snapshot)" ]

# --- local vs --utc ------------------------------------------------------------
# 08:25 in New York in October is 12:25Z: the middle of session A.
"$SCRAP" "$STICK" --keep 2026-10-20T08:25..2026-10-20T08:45 --dry-run > "$OUT" 2>&1
check "local time is read as local (EDT -> 12:25Z)" has "2026-10-20 12:25:00Z .. 2026-10-20 12:45:00Z" "$OUT"
check "local range keeps 3 segments + notes.txt" grep -qE '^ +KEEP +4 file' "$OUT"
"$SCRAP" "$STICK" --keep 2026-10-20T08:25..2026-10-20T08:45 --utc --dry-run > "$OUT" 2>&1
check "--utc reads the same text as UTC" has "2026-10-20 08:25:00Z .. 2026-10-20 08:45:00Z" "$OUT"
check "--utc range matches no file" has "matched no file" "$OUT"
check "--utc range keeps only notes.txt" grep -qE '^ +KEEP +1 file' "$OUT"
"$SCRAP" "$STICK" --keep ..2026-10-20 --utc --dry-run > "$OUT" 2>&1
check "a bare END date means the end of that day" has "(open) .. 2026-10-21 00:00:00Z" "$OUT"

# --- keep a range: record, delete, seal, prune ----------------------------------
# 12:25Z..12:45Z overlaps the 12:20 segment only because its 1000 bytes fall
# back to a 600 s span (12:20-12:30); 12:30 and 12:40 lie inside it.
"$SCRAP" "$STICK" --keep 2026-10-20T12:25Z..2026-10-20T12:45Z --reason 'mic left on; "test"' \
    --yes --no-process > "$OUT" 2>&1
rc=$?
check "keep run exits 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "keep run tolerates the failed eject" has "cleared but could not eject" "$OUT"
RA="$UMIK_ARCHIVE/recordings/umik1/$A/scrapped.json"
RB="$UMIK_ARCHIVE/recordings/umik1/$B/scrapped.json"
check "scrapped.json sealed into session A" [ -f "$RA" ]
check "scrapped.json sealed into session B" [ -f "$RB" ]
check "A dropped 10" has '"dropped_count": 10,' "$RA"
check "B dropped 6" has '"dropped_count": 6,' "$RB"
check "A kept list" has '"kept": ["notes.txt", "seg-20261020-122000.wav", "seg-20261020-123000.wav", "seg-20261020-124000.wav"],' "$RA"
check "B kept nothing" has '"kept": [],' "$RB"
check "fallback: a 1000-byte segment spans 600 s" \
    has '"name": "seg-20261020-121000.wav", "bytes": 1000, "mtime_utc": ' "$RA"
check "fallback: 12:10 ends 12:20" grep -qF '"start_utc": "20261020T121000Z", "end_utc": "20261020T122000Z"' "$RA"
check "formula: the 7 s last segment ends 14:00:07" \
    grep -qF '"start_utc": "20261020T140000Z", "end_utc": "20261020T140007Z"' "$RA"
check "A dropped_seconds = 9 x 600 + 7" has '"dropped_seconds": 5407,' "$RA"
check "reason is JSON-escaped" has '"reason": "mic left on; \"test\"",' "$RA"
check "selection recorded in UTC" \
    has '"selection": { "mode": "keep", "ranges": [ { "from": "20261020T122500Z", "to": "20261020T124500Z" } ] },' "$RA"
check "dropped files are not hashed" sh -c "! grep -q sha256 '$RA'"
check "A sealed: session.json + scrapped.json + kept files" [ "$(sums "$A")" = \
    "notes.txt scrapped.json seg-20261020-122000.wav seg-20261020-123000.wav seg-20261020-124000.wav session.json " ]
check "B sealed: session.json + scrapped.json only" [ "$(sums "$B")" = "scrapped.json session.json " ]
check "dropped audio never reached the archive" [ ! -e "$UMIK_ARCHIVE/recordings/umik1/$A/seg-20261020-120000.wav" ]
check "card log sealed" sh -c "ls '$UMIK_ARCHIVE'/logs/*/umik.log >/dev/null 2>&1"
left=$(cd "$STICK/recordings" && find . -type f | LC_ALL=C sort | tr '\n' ' ')
check "stick keeps only the .part, the AppleDouble and the counter (got: $left)" [ "$left" = \
    "./.session-counter ./$A/._seg-20261020-120000.wav ./$A/clip-20261020-123000-104100k.sigmf-data.part " ]
check "emptied session B removed from the stick" [ ! -d "$STICK/recordings/$B" ]
check "manifest chain still verifies" "$TOOLS_DIR/umik-ingest.sh" --verify > /dev/null 2>&1

# --- drop everything ------------------------------------------------------------
build
"$SCRAP" "$STICK" --yes --no-process > "$OUT" 2>&1
rc=$?
check "drop-all exits 0 (rc=$rc)" [ "$rc" -eq 0 ]
check "drop-all A sealed session.json + scrapped.json only" [ "$(sums "$A")" = "scrapped.json session.json " ]
check "drop-all B sealed session.json + scrapped.json only" [ "$(sums "$B")" = "scrapped.json session.json " ]
check "drop-all records mode all, no ranges" \
    has '"selection": { "mode": "all", "ranges": [] },' "$UMIK_ARCHIVE/recordings/umik1/$A/scrapped.json"
check "drop-all dropped notes.txt too" \
    has '"name": "notes.txt"' "$UMIK_ARCHIVE/recordings/umik1/$A/scrapped.json"
check "drop-all summary" has "files dropped   : 20" "$OUT"

# --- already archived: an ordinary prune, not a drop ------------------------------
build
"$TOOLS_DIR/umik-ingest.sh" "$STICK" > /dev/null 2>&1
"$SCRAP" "$STICK" --dry-run > "$OUT" 2>&1
check "sealed files count as already archived" has "ALREADY-ARCHIVED 20 file(s)" "$OUT"
check "sealed files are not dropped" grep -qE '^ +DROP +0 file' "$OUT"

# --- nothing to drop ---------------------------------------------------------------
build
before=$(snapshot)
"$SCRAP" "$STICK" --keep 2026-10-19..2026-10-22 --yes --no-process > "$OUT" 2>&1
check "a keep range over everything exits 0" [ $? -eq 0 ]
check "nothing to drop says so" has "nothing to drop" "$OUT"
check "nothing to drop changes nothing" [ "$before" = "$(snapshot)" ]

if [ "$fail" -eq 0 ]; then
    echo "PASS scrap-selftest: $pass checks"
    exit 0
fi
echo "FAILED scrap-selftest: $fail of $((pass + fail)) checks" >&2
exit 1
