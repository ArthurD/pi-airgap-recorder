#!/bin/bash
# umik-upload.sh - write the sealed archive into S3 exactly once, proving as
# each object lands that S3 received the bytes SHA256SUMS says it should.
#
# Bucket layout (the seals travel with the audio):
#   raw/<YYYY-MM-DD>/<unit>/<session>/...   sessions whose clock was trusted
#                                           - date = start date
#   raw/undated/<unit>/<session>/...        untrusted clock: no date is
#                                           better than a wrong one
#   logs/<utc-stamp>/...                    card activity-log snapshots
#   manifest/<utc-stamp>_<head>/...         one write-once set per run:
#                                           manifest.log, manifest.head,
#                                           ingest.log - the head pins every
#                                           byte ever sealed, off-site
#
# WRITE ONCE. The bucket carries Object Lock in compliance mode, so an
# overwrite is not a correction - it is a second, locked, undeletable version
# of the same key, for years. So nothing here ever overwrites: every object is
# PUT once, checked at that moment, and then never touched again. That is also
# why this no longer uses `aws s3 sync`; sync decides from size and mtime, and
# it uploads multipart, which yields a COMPOSITE checksum (a hash of part
# hashes) that no seal can be compared against.
#
# How the proof works: each PUT is single-part and carries
# --checksum-sha256 <the seal, hex->base64>. S3 hashes what it actually
# receives and refuses the request unless it matches, so a truncated or
# corrupted transfer cannot be stored at all. The stored checksum is then
# FULL_OBJECT and directly comparable to SHA256SUMS forever after, which is
# what `umik verify-s3` reads back. Nothing is ever stamped after the fact.
#
# Add-only by construction: --if-none-match '*' makes each PUT conditional on
# the key not existing, every session prefix is unique (unit + counter +
# timestamp), and the Mac is the only writer. Idempotent: a key that already
# carries the right checksum is skipped, so a failed or offline run simply
# catches up next time. Uploads happen FROM the archive, never from the media:
# the archive is the truth.
#
#   umik upload             write everything new to the bucket
#   umik upload --dry-run   show what would upload, touch nothing
#
# Config: UMIK_S3_BUCKET (required - no default), UMIK_AWS_PROFILE (default
# umik), UMIK_ARCHIVE (default ~/UMIK-Archive), UMIK_JOBS (default 5). Set them
# in the environment or in tools/umik.local.conf (untracked; see
# umik.local.conf.example).

set -uo pipefail

TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)

# Where your bucket name lives. There is deliberately NO default bucket: this
# repo is public, so shipping one would both publish somebody's bucket name and
# let a fresh clone try to upload into a stranger's. Precedence is environment,
# then the untracked local config, then nothing (which is an error).
_ENV_ARCHIVE=${UMIK_ARCHIVE-}; _ENV_BUCKET=${UMIK_S3_BUCKET-}; _ENV_PROFILE=${UMIK_AWS_PROFILE-}
CONF="${UMIK_CONF:-$TOOLS_DIR/umik.local.conf}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
ARCHIVE="${_ENV_ARCHIVE:-${UMIK_ARCHIVE:-$HOME/UMIK-Archive}}"
BUCKET="${_ENV_BUCKET:-${UMIK_S3_BUCKET:-}}"
PROFILE="${_ENV_PROFILE:-${UMIK_AWS_PROFILE:-umik}}"
JOBS="${UMIK_JOBS:-5}"

# The SDK, not this script, owns transient-failure backoff.
export AWS_RETRY_MODE=adaptive
export AWS_MAX_ATTEMPTS="${UMIK_MAX_ATTEMPTS:-10}"

# A single-part PUT tops out at 5 GB. Segments run ~86-200 MB, so this is a
# guard rail rather than a real limit - but going multipart would silently
# hand back a COMPOSITE checksum, so hitting it has to be fatal, not quiet.
MAX_PUT=5368709120

DRY=0
case "${1:-}" in
    --dry-run|--dryrun) DRY=1 ;;
    "") ;;
    *) echo "usage: umik upload [--dry-run]" >&2; exit 2 ;;
esac

say() { echo "==> $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

[ -n "$BUCKET" ] || die "no S3 bucket configured - copy tools/umik.local.conf.example to
       $CONF and set UMIK_S3_BUCKET (or export it)"
command -v aws >/dev/null 2>&1 \
    || die "aws CLI not found - install it with: brew install awscli"
aws configure list --profile "$PROFILE" >/dev/null 2>&1 \
    || die "no AWS profile '$PROFILE' - set it up with: aws configure --profile $PROFILE"
[ -d "$ARCHIVE/recordings" ] || die "no archive at $ARCHIVE/recordings - run: umik download"

# shellcheck source=tools/umik-lib.sh
. "$TOOLS_DIR/umik-lib.sh" || die "cannot source $TOOLS_DIR/umik-lib.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/umik-upload.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- what should exist in the bucket -----------------------------------------

say "building expected-hash map from $ARCHIVE"
umik_build_expected "$WORK/map"
sessions=$(umik_count_sessions)
say "$(wc -l < "$WORK/map" | tr -d ' ') sealed file(s) across $sessions session(s)"

oversize=$(cut -f3 "$WORK/map" | tr '\n' '\0' | xargs -0 stat -f '%z %N' 2>/dev/null \
           | awk -v m="$MAX_PUT" '$1 > m')
[ -z "$oversize" ] || die "these files are too big for a single-part PUT (>5 GB), and a
       multipart upload would store a COMPOSITE checksum that no seal can be
       compared to:
$oversize"

# --- the manifest set --------------------------------------------------------
# manifest.log and ingest.log grow append-only, so the old design overwrote the
# bucket copy with the longer local one. Under Object Lock that is exactly the
# thing that cannot happen: each overwrite would leave a locked, undeletable
# previous version behind. So each run pins its own immutable set instead,
# named for the head it pins. If some earlier run already published this head,
# the archive has not grown since and there is nothing new to pin.

MSET=""
MHEAD=$(tr -d '[:space:]' < "$ARCHIVE/manifest.head" 2>/dev/null)
if [ -n "$MHEAD" ] && [ -f "$ARCHIVE/manifest.log" ]; then
    pinned=0
    for p in $(aws s3api list-objects-v2 --bucket "$BUCKET" --profile "$PROFILE" \
               --prefix manifest/ --delimiter / \
               --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null); do
        case "$p" in *"_$MHEAD/") pinned=1 ;; esac
    done
    if [ "$pinned" -eq 1 ]; then
        say "manifest head $MHEAD is already pinned off-site; nothing new to publish"
    else
        MSET="manifest/$(date -u +%Y%m%dT%H%M%SZ)_$MHEAD"
        # Not sealed in any SHA256SUMS, so these three are hashed here - which
        # still means S3 is handed a hash computed before the transfer and
        # verifies the bytes it receives against it.
        for m in manifest.log manifest.head ingest.log; do
            [ -f "$ARCHIVE/$m" ] || continue
            printf '%s/%s\t%s\t%s\n' "$MSET" "$m" \
                "$(shasum -a 256 "$ARCHIVE/$m" | awk '{print $1}')" \
                "$ARCHIVE/$m" >> "$WORK/map"
        done
        say "manifest set -> s3://$BUCKET/$MSET/ (head $MHEAD)"
    fi
fi

total=$(wc -l < "$WORK/map" | tr -d ' ')

# --- upload ------------------------------------------------------------------
# One object at a time, each one head-checked first so a re-run is cheap and a
# key that already exists is never written over.

head_sha() { # <key> -> base64 checksum, or NOTFOUND / NONE / ERR
    local out
    # First attempt un-retried: a 404 is the normal answer for a new key, and
    # backing off four times over it would make the first upload crawl.
    if out=$(aws s3api head-object --bucket "$BUCKET" --key "$1" \
             --checksum-mode ENABLED --profile "$PROFILE" \
             --query 'ChecksumSHA256' --output text 2>"$WORK/err.$$"); then
        case "$out" in None|"") echo NONE ;; *) echo "$out" ;; esac
        return 0
    fi
    grep -qiE '\(404\)|Not Found' "$WORK/err.$$" && { echo NOTFOUND; return 0; }
    if out=$(retry_aws 4 aws s3api head-object --bucket "$BUCKET" --key "$1" \
             --checksum-mode ENABLED --profile "$PROFILE" \
             --query 'ChecksumSHA256' --output text); then
        case "$out" in None|"") echo NONE ;; *) echo "$out" ;; esac
        return 0
    fi
    grep -qiE '\(404\)|Not Found' "$WORK/err.$$" && { echo NOTFOUND; return 0; }
    echo ERR
}

put_one() { # <line number in $WORK/map>
    # The line is looked up rather than passed in: BSD xargs caps an assembled
    # -I command line at 255 bytes, and key + seal + local path blows past it.
    local line key hex path b64 ctype have out replace rest
    line=$(sed -n "${1}p" "$WORK/map")
    key=${line%%$'\t'*}
    rest=${line#*$'\t'}
    hex=${rest%%$'\t'*}
    path=${rest#*$'\t'}

    [ -f "$path" ] || { printf 'FAIL\t%s\tlocal file is gone: %s\n' "$key" "$path"; return 0; }
    b64=$(umik_hex_to_b64 "$hex")
    [ -n "$b64" ] || { printf 'FAIL\t%s\tunreadable seal in SHA256SUMS: %s\n' "$key" "$hex"; return 0; }
    ctype=$(umik_content_type "$path")

    replace=0
    have=$(head_sha "$key")
    case "$have" in
        NOTFOUND) ;;
        ERR)      printf 'FAIL\t%s\thead-object failed\n' "$key"; return 0 ;;
        "$b64")   printf 'SKIP\t%s\n' "$key"; return 0 ;;
        *)
            # A session sealed across two ingests gets its SHA256SUMS appended
            # by the later one, so the bucket's copy is a genuine prefix of the
            # local one and must be replaced. Nothing else may be: a wav whose
            # stored checksum differs from its seal is evidence, not a typo.
            case "$key" in
                */SHA256SUMS) replace=1 ;;
                *) printf 'FAIL\t%s\texists in S3 but does not match the seal (s3: %s)\n' "$key" "$have"; return 0 ;;
            esac
            ;;
    esac

    if [ "$DRY" = 1 ]; then
        [ "$replace" -eq 1 ] && printf 'WOULD-REPLACE\t%s\n' "$key" || printf 'WOULD\t%s\n' "$key"
        return 0
    fi

    local -a cond=()
    [ "$replace" -eq 1 ] || cond=(--if-none-match '*')
    if out=$(retry_aws 4 aws s3api put-object --bucket "$BUCKET" --key "$key" \
             --body "$path" --checksum-sha256 "$b64" \
             --server-side-encryption AES256 --content-type "$ctype" \
             --profile "$PROFILE" --query 'ChecksumSHA256' --output text \
             ${cond[@]+"${cond[@]}"}); then
        if [ "$out" = "$b64" ]; then
            [ "$replace" -eq 1 ] && printf 'REPLACE\t%s\n' "$key" || printf 'UP\t%s\n' "$key"
        else
            printf 'FAIL\t%s\tS3 stored checksum %s, seal is %s\n' "$key" "$out" "$b64"
        fi
        return 0
    fi
    # A 412 means the key appeared underneath us (a concurrent or half-finished
    # earlier run). Re-head: if what is there matches the seal, this is a skip,
    # not a failure.
    have=$(head_sha "$key")
    if [ "$have" = "$b64" ]; then
        printf 'SKIP\t%s\n' "$key"
    else
        printf 'FAIL\t%s\tPUT failed (s3 now: %s)\n' "$key" "$have"
    fi
    return 0
}
export -f put_one head_sha retry_aws umik_hex_to_b64 umik_content_type
export BUCKET PROFILE WORK DRY

if [ "$DRY" = 1 ]; then
    say "dry run: checking $total object(s) against the bucket ($JOBS parallel)"
else
    say "writing $total object(s), single-part, checksum-verified on arrival ($JOBS parallel)"
fi
: > "$WORK/out"
[ "$total" -eq 0 ] || seq 1 "$total" | xargs -P "$JOBS" -I{} bash -c 'put_one "$@"' _ {} > "$WORK/out"

# Processed-vs-total is printed on purpose: a silent shortfall is what made an
# earlier run look like a mass data mismatch.
done_n=$(wc -l < "$WORK/out" | tr -d ' ')
[ "$done_n" -eq "$total" ] || say "WARNING: processed $done_n of $total - the run was cut short"

uploaded=$(grep -c -E '^(UP|REPLACE|WOULD|WOULD-REPLACE)	' "$WORK/out" || true)
skipped=$(grep -c '^SKIP	' "$WORK/out" || true)
failed=$(grep -c '^FAIL	' "$WORK/out" || true)

# --- what moved --------------------------------------------------------------

awk -F'\t' '$1 ~ /^(UP|REPLACE|WOULD|WOULD-REPLACE)$/ {
        k = $2; sub(/\/[^\/]*$/, "", k); n[k]++
    }
    END { for (k in n) print k "\t" n[k] }' "$WORK/out" | sort | \
while IFS=$'\t' read -r dir n; do
    IFS=/ read -r -a a <<< "$dir"
    case "${a[0]}" in
        raw)      label="${a[2]}/${a[3]}" ;;
        logs)     label="card logs ${a[1]}" ;;
        manifest) label="manifest + head + ingest.log" ;;
        *)        label="$dir" ;;
    esac
    say "$label: $n file(s) -> s3://$BUCKET/$dir/"
done

grep '^REPLACE	' "$WORK/out" | cut -f2 | sed 's/^/-- replaced (sealed across two ingests): /'
grep '^WOULD-REPLACE	' "$WORK/out" | cut -f2 | sed 's/^/-- would replace (sealed across two ingests): /'
awk -F'\t' '$1 == "FAIL" {print "!! " $2 ": " $3}' "$WORK/out" >&2

echo
if [ "$DRY" = 1 ]; then
    say "dry run: $sessions session(s) scanned, $uploaded file(s) WOULD upload, $skipped skipped (already verified), $failed failure(s)"
else
    say "done: $sessions session(s) scanned, $uploaded file(s) uploaded, $skipped skipped (already verified), $failed failure(s)"
fi
[ "$failed" -eq 0 ] || exit 1
exit 0
