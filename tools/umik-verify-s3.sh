#!/bin/bash
# umik-verify-s3.sh - prove the BUCKET holds the sealed bytes, not just files
# of the right name and size.
#
# Why this exists: `aws s3 sync` decides what to upload from size + mtime, and
# an object's ETag is a multipart digest, not a hash you can compare to
# anything. So "the mirror looks complete" has never meant "the mirror is
# correct". Before the local archive can be deleted, something has to check
# S3's actual bytes against the SHA256SUMS seals. This does.
#
# How, without paying to download 175 GB: ask S3 to copy each object onto
# itself with --checksum-algorithm SHA256. S3 reads the stored bytes, computes
# a FULL_OBJECT SHA-256, and stores it on the object. That hash is derived from
# what the bucket actually holds, so comparing it to the seal is a real
# end-to-end check - and the data never leaves AWS.
#
#   ./tools/umik-verify-s3.sh              stamp what needs it, then verify all
#   ./tools/umik-verify-s3.sh --dry-run    report what would be stamped
#   ./tools/umik-verify-s3.sh --verify-only  skip stamping; verify what exists
#
# Exit 0 only when every object carries a FULL_OBJECT SHA-256 that matches its
# seal. Any mismatch is printed loudly and fails the run: a mismatch means the
# bucket copy is NOT the sealed copy, and local must not be deleted.
#
# Config via env: UMIK_S3_BUCKET, UMIK_AWS_PROFILE, UMIK_ARCHIVE, UMIK_JOBS.
#
# NOTE ON COST: the bucket is versioned, so stamping writes a new version of
# each object and the previous version lingers. Expire noncurrent versions
# with a lifecycle rule (needs admin credentials; the `umik` uploader has no
# DeleteObject by design).

set -uo pipefail

ARCHIVE="${UMIK_ARCHIVE:-$HOME/UMIK-Archive}"
BUCKET="${UMIK_S3_BUCKET:-YOUR-BUCKET}"
PROFILE="${UMIK_AWS_PROFILE:-umik}"
JOBS="${UMIK_JOBS:-5}"

# S3 throttles a burst of server-side copies of 86-173 MB objects, and a bare
# call then fails transiently. Let the SDK back off and retry rather than
# reporting a scary FAIL on an object that is actually fine.
export AWS_RETRY_MODE=adaptive
export AWS_MAX_ATTEMPTS="${UMIK_MAX_ATTEMPTS:-10}"

# One retry wrapper for both phases. Every call site must exit 0 regardless of
# outcome: BSD xargs aborts the whole run on some non-zero child exits, which
# is how an earlier version silently stopped after 866 of 1515 objects.
retry_aws() { # <attempts> <aws args...>
    local n=$1; shift
    local i=1
    while :; do
        "$@" 2>"$WORK/err.$$" && return 0
        [ "$i" -ge "$n" ] && return 1
        sleep $((i * 2))
        i=$((i + 1))
    done
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/umik-verify-s3.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

MODE=stamp
case "${1:-}" in
    --dry-run|--dryrun) MODE=dryrun ;;
    --verify-only)      MODE=verifyonly ;;
    "") ;;
    *) echo "usage: umik verify-s3 [--dry-run|--verify-only]" >&2; exit 2 ;;
esac

say() { echo "==> $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
[ -d "$ARCHIVE/recordings" ] || die "no archive at $ARCHIVE/recordings"

json_str() { sed -n "s/.*\"$2\": *\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" 2>/dev/null | head -1; }

# --- expected hashes, keyed by the S3 key they should live at ----------------
# Session and log files take their hash from the SHA256SUMS sealed beside them
# (the published, checkable artifact). The few unsealed archive-root files are
# hashed here directly - they are small, and mirroring them is the point.

say "building expected-hash map from $ARCHIVE"
: > "$WORK/expected"

for sdir in "$ARCHIVE"/recordings/*/*/; do
    [ -d "$sdir" ] || continue
    unit=$(basename "$(dirname "$sdir")")
    sname=$(basename "$sdir")
    datepart=undated
    sj="$sdir/session.json"
    if [ -f "$sj" ] && [ "$(json_str "$sj" clock_trusted)" = "true" ] \
        && case "$(json_str "$sj" time_source)" in gps*|ntp|rtc) true ;; *) false ;; esac; then
        d=$(json_str "$sj" started_utc | sed -En 's/^([0-9]{4})([0-9]{2})([0-9]{2})T.*/\1-\2-\3/p')
        [ -n "$d" ] && datepart=$d
    fi
    prefix="raw/$datepart/$unit/$sname"
    [ -f "$sdir/SHA256SUMS" ] && awk -v p="$prefix" \
        '{h=$1; sub(/^[0-9a-f]+  /,""); print p"/"$0"\t"h}' "$sdir/SHA256SUMS" >> "$WORK/expected"
    # SHA256SUMS itself is not listed inside itself.
    [ -f "$sdir/SHA256SUMS" ] && \
        printf '%s/SHA256SUMS\t%s\n' "$prefix" "$(shasum -a 256 "$sdir/SHA256SUMS" | awk '{print $1}')" >> "$WORK/expected"
done

for ldir in "$ARCHIVE"/logs/*/; do
    [ -d "$ldir" ] || continue
    lname=$(basename "$ldir")
    [ -f "$ldir/SHA256SUMS" ] && awk -v p="logs/$lname" \
        '{h=$1; sub(/^[0-9a-f]+  /,""); print p"/"$0"\t"h}' "$ldir/SHA256SUMS" >> "$WORK/expected"
    [ -f "$ldir/SHA256SUMS" ] && \
        printf '%s/SHA256SUMS\t%s\n' "logs/$lname" "$(shasum -a 256 "$ldir/SHA256SUMS" | awk '{print $1}')" >> "$WORK/expected"
done

for m in manifest.log manifest.head ingest.log; do
    [ -f "$ARCHIVE/$m" ] && \
        printf 'manifest/%s\t%s\n' "$m" "$(shasum -a 256 "$ARCHIVE/$m" | awk '{print $1}')" >> "$WORK/expected"
done

sort -o "$WORK/expected" "$WORK/expected"
say "$(wc -l < "$WORK/expected" | tr -d ' ') expected hashes"

# --- what the bucket currently holds -----------------------------------------

say "listing s3://$BUCKET"
aws s3api list-objects-v2 --bucket "$BUCKET" --profile "$PROFILE" \
    --query 'Contents[].Key' --output text 2>/dev/null \
    | tr '\t' '\n' | sed '/^$/d' | sort > "$WORK/keys" \
    || die "could not list the bucket"
say "$(wc -l < "$WORK/keys" | tr -d ' ') objects in bucket"

# --- stamp: give every object a FULL_OBJECT SHA-256 --------------------------
# The test is specifically for a whole-object SHA-256, because two other kinds
# of checksum are already present and neither is comparable to a seal:
#   - ChecksumCRC64NVME, which the AWS CLI adds to uploads by default. It is
#     FULL_OBJECT, so testing ChecksumType alone silently skips every object.
#   - a COMPOSITE SHA-256 ("<base64>-<n>") on multipart uploads, which hashes
#     the part hashes, not the file. Base64 has no "-", so the suffix is an
#     unambiguous marker.

stamp_one() {
    local key=$1 info ctype sha
    info=$(retry_aws 4 aws s3api head-object --bucket "$BUCKET" --key "$key" \
           --checksum-mode ENABLED --profile "$PROFILE" \
           --query '[ChecksumSHA256,ContentType]' --output text) \
        || { echo "FAIL-HEAD $key"; return 0; }
    sha=${info%%$'\t'*}
    ctype=${info#*$'\t'}
    case "$sha" in
        None|"") ;;                      # no SHA-256 at all -> stamp
        *-[0-9]*) ;;                     # composite SHA-256 -> restamp whole-object
        *) echo "SKIP $key"; return 0 ;;  # already a whole-object SHA-256
    esac
    case "$ctype" in None|"") ctype=binary/octet-stream ;; esac
    if [ "$MODE" = dryrun ]; then echo "WOULD-STAMP $key"; return 0; fi
    retry_aws 4 aws s3api copy-object --bucket "$BUCKET" --key "$key" \
        --copy-source "$BUCKET/$key" --checksum-algorithm SHA256 \
        --metadata-directive REPLACE --content-type "$ctype" \
        --server-side-encryption AES256 --profile "$PROFILE" >/dev/null \
        && echo "STAMP $key" || echo "FAIL-STAMP $key"
    return 0
}
export -f stamp_one retry_aws
export BUCKET PROFILE MODE WORK

if [ "$MODE" != verifyonly ]; then
    say "stamping FULL_OBJECT SHA-256 (server-side, no download; $JOBS parallel)"
    xargs -P "$JOBS" -I{} bash -c 'stamp_one "$@"' _ {} < "$WORK/keys" > "$WORK/stamp.out" 2>&1
    # Processed-vs-total is printed on purpose: a silent shortfall here is what
    # made an earlier run look like a mass data mismatch.
    say "processed $(wc -l < "$WORK/stamp.out" | tr -d ' ') of $(wc -l < "$WORK/keys" | tr -d ' ') objects"
    say "stamped $(grep -c '^STAMP ' "$WORK/stamp.out" || true), already full-object $(grep -c '^SKIP ' "$WORK/stamp.out" || true), failed $(grep -c -E '^FAIL-(STAMP|HEAD) ' "$WORK/stamp.out" || true)"
    grep -E '^FAIL-(STAMP|HEAD) ' "$WORK/stamp.out" >&2 || true
    [ "$MODE" = dryrun ] && { say "dry run: $(grep -c '^WOULD-STAMP ' "$WORK/stamp.out" || true) object(s) would be stamped"; exit 0; }
fi

# --- verify: S3's own hash vs the seal ---------------------------------------

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
export WORK

say "reading back S3 checksums ($JOBS parallel)"
xargs -P "$JOBS" -I{} bash -c 'fetch_one "$@"' _ {} < "$WORK/keys" | sort > "$WORK/actual"

join -t $'\t' "$WORK/expected" "$WORK/actual" > "$WORK/joined"
matched=$(awk -F'\t' '$2 == $3' "$WORK/joined" | wc -l | tr -d ' ')
awk -F'\t' '$2 != $3 {print $1"\n  seal: "$2"\n  s3  : "$3}' "$WORK/joined" > "$WORK/mismatch"
mismatched=$(awk -F'\t' '$2 != $3' "$WORK/joined" | wc -l | tr -d ' ')
comm -23 <(cut -f1 "$WORK/expected") <(cut -f1 "$WORK/actual") > "$WORK/absent"
comm -13 <(cut -f1 "$WORK/expected") <(cut -f1 "$WORK/actual") > "$WORK/unexpected"

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
