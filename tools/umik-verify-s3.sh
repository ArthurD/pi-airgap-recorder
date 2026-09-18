#!/bin/bash
# umik-verify-s3.sh - prove the BUCKET holds the sealed bytes, not just files
# of the right name and size.
#
# Why this exists: an object's ETag is a multipart digest, not a hash you can
# compare to anything, so "the mirror looks complete" has never meant "the
# mirror is correct". Before the local archive can be deleted, something has to
# check S3's actual bytes against the SHA256SUMS seals. This does.
#
# How, without downloading 175 GB: it doesn't have to. `umik upload` writes
# every object with a single-part PUT carrying --checksum-sha256 <the seal>,
# so S3 refuses bytes that do not hash to the seal and stores that whole-object
# SHA-256 permanently. This tool reads those checksums back with head-object
# and diffs them against the seals - read-only, no egress, and no new object
# versions. Nothing is stamped, repaired or rewritten here; the bucket carries
# Object Lock in compliance mode, where a "fix" is just a second undeletable
# version of the same key.
#
#   ./tools/umik-verify-s3.sh              read back every checksum and verify
#
# Exit 0 only when every object carries a FULL_OBJECT SHA-256 that matches its
# seal. Any mismatch is printed loudly and fails the run: a mismatch means the
# bucket copy is NOT the sealed copy, and local must not be deleted. An object
# with no whole-object SHA-256 at all counts as a mismatch too - it predates
# the write-once uploader and cannot be proven either way without downloading
# it, and it can no longer be stamped in place.
#
# Config via env: UMIK_S3_BUCKET, UMIK_AWS_PROFILE, UMIK_ARCHIVE, UMIK_JOBS.

set -uo pipefail

TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)

# Same precedence as umik-upload.sh: environment, then the untracked local
# config, then nothing. No bucket default ships in a public repo.
_ENV_ARCHIVE=${UMIK_ARCHIVE-}; _ENV_BUCKET=${UMIK_S3_BUCKET-}; _ENV_PROFILE=${UMIK_AWS_PROFILE-}
CONF="${UMIK_CONF:-$TOOLS_DIR/umik.local.conf}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
ARCHIVE="${_ENV_ARCHIVE:-${UMIK_ARCHIVE:-$HOME/UMIK-Archive}}"
BUCKET="${_ENV_BUCKET:-${UMIK_S3_BUCKET:-}}"
PROFILE="${_ENV_PROFILE:-${UMIK_AWS_PROFILE:-umik}}"
JOBS="${UMIK_JOBS:-5}"

# Let the SDK back off and retry rather than reporting a scary FAIL on an
# object that is actually fine.
export AWS_RETRY_MODE=adaptive
export AWS_MAX_ATTEMPTS="${UMIK_MAX_ATTEMPTS:-10}"

# --verify-only used to mean "skip the stamping pass". There is no stamping
# pass any more - this whole tool is verify-only - so the flag is accepted and
# ignored, rather than breaking anyone's habit or cron line.
case "${1:-}" in
    --verify-only) ;;
    "") ;;
    *) echo "usage: umik verify-s3 [--verify-only]" >&2; exit 2 ;;
esac

say() { echo "==> $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
[ -n "$BUCKET" ] || die "no S3 bucket configured - copy tools/umik.local.conf.example to
       $CONF and set UMIK_S3_BUCKET (or export it)"
[ -d "$ARCHIVE/recordings" ] || die "no archive at $ARCHIVE/recordings"

# shellcheck source=tools/umik-lib.sh
. "$TOOLS_DIR/umik-lib.sh" || die "cannot source $TOOLS_DIR/umik-lib.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/umik-verify-s3.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- expected hashes, keyed by the S3 key they should live at ----------------
# Exactly the map the uploader writes from - same code, so the two cannot
# disagree about which file is which key.

say "building expected-hash map from $ARCHIVE"
umik_build_expected "$WORK/map"
cut -f1,2 "$WORK/map" > "$WORK/expected"

# --- what the bucket currently holds -----------------------------------------

say "listing s3://$BUCKET"
aws s3api list-objects-v2 --bucket "$BUCKET" --profile "$PROFILE" \
    --query 'Contents[].Key' --output text 2>/dev/null \
    | tr '\t' '\n' | sed '/^$/d' | sort > "$WORK/keys" \
    || die "could not list the bucket"
say "$(wc -l < "$WORK/keys" | tr -d ' ') objects in bucket"

# --- the manifest sets -------------------------------------------------------
# Each upload run pins its own write-once manifest/<stamp>_<head>/ set. Only
# the CURRENT head can be checked against local files, because manifest.log and
# ingest.log have grown past every older set - their bytes are gone from the
# Mac, by design. So older sets are neither verified nor reported as strays;
# they are exactly what they look like, earlier honest snapshots.

msets=$(aws s3api list-objects-v2 --bucket "$BUCKET" --profile "$PROFILE" \
        --prefix manifest/ --delimiter / \
        --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null \
        | tr '\t' '\n' | sed -e '/^$/d' -e '/^None$/d')
mcount=$(printf '%s' "$msets" | grep -c . || true)
MHEAD=$(tr -d '[:space:]' < "$ARCHIVE/manifest.head" 2>/dev/null)
mpinned=no
if [ -n "$MHEAD" ]; then
    for p in $msets; do
        case "$p" in
            *"_$MHEAD/")
                mpinned=yes
                for m in manifest.log manifest.head ingest.log; do
                    [ -f "$ARCHIVE/$m" ] || continue
                    printf '%s%s\t%s\n' "$p" "$m" \
                        "$(shasum -a 256 "$ARCHIVE/$m" | awk '{print $1}')" >> "$WORK/expected"
                done
                ;;
        esac
    done
fi
sort -o "$WORK/expected" "$WORK/expected"
say "$(wc -l < "$WORK/expected" | tr -d ' ') expected hashes"
say "manifest sets in S3: $mcount (current head pinned: $mpinned)"

# --- verify: S3's own hash vs the seal ---------------------------------------
# The test is specifically for a whole-object SHA-256, because two other kinds
# of checksum turn up and neither is comparable to a seal:
#   - ChecksumCRC64NVME, which the AWS CLI adds to uploads by default. It is
#     FULL_OBJECT, so testing ChecksumType alone silently passes everything.
#   - a COMPOSITE SHA-256 ("<base64>-<n>") from a multipart upload, which
#     hashes the part hashes, not the file. Base64 has no "-", so the suffix
#     is an unambiguous marker.
# Either one now reads back as NONE and fails the run.

fetch_one() {
    local key=$1 b64 hex
    b64=$(retry_aws 4 aws s3api head-object --bucket "$BUCKET" --key "$key" \
          --checksum-mode ENABLED --profile "$PROFILE" \
          --query 'ChecksumSHA256' --output text) || { printf '%s\tERR\n' "$key"; return 0; }
    case "$b64" in None|""|*-[0-9]*) printf '%s\tNONE\n' "$key"; return 0 ;; esac
    hex=$(printf '%s' "$b64" | base64 -d 2>/dev/null | xxd -p -c64)
    printf '%s\t%s\n' "$key" "$hex"
    return 0
}
export -f fetch_one retry_aws
export BUCKET PROFILE WORK

say "reading back S3 checksums ($JOBS parallel)"
xargs -P "$JOBS" -I{} bash -c 'fetch_one "$@"' _ {} < "$WORK/keys" | sort > "$WORK/actual"

join -t $'\t' "$WORK/expected" "$WORK/actual" > "$WORK/joined"
matched=$(awk -F'\t' '$2 == $3' "$WORK/joined" | wc -l | tr -d ' ')
awk -F'\t' '$2 != $3 {print $1"\n  seal: "$2"\n  s3  : "$3}' "$WORK/joined" > "$WORK/mismatch"
mismatched=$(awk -F'\t' '$2 != $3' "$WORK/joined" | wc -l | tr -d ' ')
comm -23 <(cut -f1 "$WORK/expected") <(cut -f1 "$WORK/actual") > "$WORK/absent"
# Older manifest sets are unverifiable on purpose (see above), so they are not
# strays and must not be reported as such.
comm -13 <(cut -f1 "$WORK/expected") <(cut -f1 "$WORK/actual") \
    | grep -v '^manifest/' > "$WORK/unexpected"

echo
say "VERIFIED (S3 bytes match the seal) : $matched"
say "MISMATCHED                         : $mismatched"
say "expected but absent from S3        : $(wc -l < "$WORK/absent" | tr -d ' ')"
say "in S3 but not expected locally     : $(wc -l < "$WORK/unexpected" | tr -d ' ')"

fail=0
[ "$mismatched" -eq 0 ] || { echo; echo "!! MISMATCHED - the bucket copy is NOT the sealed copy:" >&2; cat "$WORK/mismatch" >&2; fail=1; }
[ ! -s "$WORK/absent" ]     || { echo; echo "!! expected but absent from S3:" >&2; head -50 "$WORK/absent" >&2; fail=1; }
[ ! -s "$WORK/unexpected" ] || { echo; echo "-- in S3 but not expected locally (informational):"; head -50 "$WORK/unexpected"; }

if [ "$fail" -eq 0 ]; then
    echo
    say "ALL $matched OBJECT(S) VERIFIED against their seals - S3 holds the sealed bytes"
else
    echo
    echo "FATAL: verification failed - do NOT delete the local archive" >&2
fi
exit "$fail"
