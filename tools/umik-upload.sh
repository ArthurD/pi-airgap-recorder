#!/bin/bash
# umik-upload.sh - mirror the sealed archive to S3, keyed by date and unit.
#
# Bucket layout (the seals travel with the audio):
#   raw/<YYYY-MM-DD>/<unit>/<session>/...   sessions whose clock was trusted
#                                           (GPS-backed) - date = start date
#   raw/undated/<unit>/<session>/...        untrusted clock: no date is
#                                           better than a wrong one
#   logs/<utc-stamp>/...                    card activity-log snapshots
#   manifest/manifest.log, manifest.head    hash chain - the head pins every
#                                           byte ever sealed, on- or off-site
#   manifest/ingest.log                     human-readable ingest run history
#
# Uploads request SHA-256 checksums, so S3 validates every part on arrival.
# NOTE: files above the CLI's multipart threshold get a COMPOSITE checksum
# (a hash of part hashes, suffixed "-<n>"), which is NOT comparable to the
# whole-file hash in SHA256SUMS. Proving the bucket holds the sealed bytes is
# `umik verify-s3`, which stamps every object with a FULL_OBJECT SHA-256
# server-side and diffs it against the seals.
#
# Add-only by construction: `aws s3 sync` without --delete never removes a
# key, every session prefix is unique (unit + counter + timestamp), and the
# Mac is the only writer - two field units can never overwrite each other.
# Idempotent: anything already uploaded is skipped, so a failed or offline
# run simply catches up next time. Uploads happen FROM the archive, never
# from the media: the archive is the truth.
#
#   umik upload             sync everything new to the bucket
#   umik upload --dry-run   show what would upload, touch nothing
#
# Config via env: UMIK_S3_BUCKET (default YOUR-BUCKET),
#                 UMIK_AWS_PROFILE (default umik), UMIK_ARCHIVE

set -euo pipefail

ARCHIVE="${UMIK_ARCHIVE:-$HOME/UMIK-Archive}"
BUCKET="${UMIK_S3_BUCKET:-YOUR-BUCKET}"
PROFILE="${UMIK_AWS_PROFILE:-umik}"

DRY=()
case "${1:-}" in
    --dry-run|--dryrun) DRY=(--dryrun) ;;
    "") ;;
    *) echo "usage: umik upload [--dry-run]" >&2; exit 2 ;;
esac

say() { echo "==> $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 \
    || die "aws CLI not found - install it with: brew install awscli"
aws configure list --profile "$PROFILE" >/dev/null 2>&1 \
    || die "no AWS profile '$PROFILE' - set it up with: aws configure --profile $PROFILE"
[ -d "$ARCHIVE/recordings" ] || die "no archive at $ARCHIVE/recordings - run: umik download"

json_str() { # <file> <key>  first string value of "key" in a machine-written json
    sed -n "s/.*\"$2\": *\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" 2>/dev/null | head -1
}

s3sync() { # <src-dir> <s3-prefix>  -> prints the number of files it uploaded
    local out
    out=$(aws s3 sync ${DRY[@]+"${DRY[@]}"} --profile "$PROFILE" --no-progress \
          --checksum-algorithm SHA256 "$1" "$2") || return 1
    printf '%s\n' "$out" | grep -c 'upload' || true
}

sessions=0 uploaded=0 failed=0

for sdir in "$ARCHIVE"/recordings/*/*/; do
    [ -d "$sdir" ] || continue
    unit=$(basename "$(dirname "$sdir")")
    sname=$(basename "$sdir")
    sessions=$((sessions + 1))

    # The date prefix is earned, not assumed: only a session that recorded
    # clock_trusted=true (GPS/NTP set the clock that boot) files under its
    # start date. Everything else - seeded floors, dead clocks, pre-GPS
    # sessions - goes under raw/undated/ where nothing pretends to know
    # when it was. time_source must name a trusted source too (gps,
    # gps-time-only, ntp, or a disciplined rtc): old-payload sessions could
    # claim clock_trusted=true off the fake baseline clock with no time
    # source.
    datepart=undated
    sj="$sdir/session.json"
    if [ -f "$sj" ] && [ "$(json_str "$sj" clock_trusted)" = "true" ] \
        && case "$(json_str "$sj" time_source)" in gps*|ntp|rtc) true ;; *) false ;; esac; then
        d=$(json_str "$sj" started_utc \
            | sed -En 's/^([0-9]{4})([0-9]{2})([0-9]{2})T.*/\1-\2-\3/p')
        [ -n "$d" ] && datepart=$d
    fi

    dst="s3://$BUCKET/raw/$datepart/$unit/$sname/"
    if n=$(s3sync "$sdir" "$dst"); then
        [ "$n" -eq 0 ] || say "$unit/$sname: $n file(s) -> $dst"
        uploaded=$((uploaded + n))
    else
        echo "!! $unit/$sname: sync FAILED - will retry next run" >&2
        failed=$((failed + 1))
    fi
done

if [ -d "$ARCHIVE/logs" ]; then
    if n=$(s3sync "$ARCHIVE/logs" "s3://$BUCKET/logs/"); then
        [ "$n" -eq 0 ] || say "card logs: $n file(s) -> s3://$BUCKET/logs/"
        uploaded=$((uploaded + n))
    else
        echo "!! card logs: sync FAILED" >&2
        failed=$((failed + 1))
    fi
fi

# These three grow append-only, so overwriting the bucket copy with the longer
# local one is safe - and bucket versioning keeps every prior head. Publishing
# the head pins the entire archive history off-site. ingest.log rides along
# because it is the only human-readable account of what was sealed when, and
# the archive it describes is meant to become deletable.
if [ -f "$ARCHIVE/manifest.log" ]; then
    ok=1
    for m in manifest.log manifest.head ingest.log; do
        [ -f "$ARCHIVE/$m" ] || continue
        aws s3 cp ${DRY[@]+"${DRY[@]}"} --profile "$PROFILE" --no-progress --only-show-errors \
            --checksum-algorithm SHA256 "$ARCHIVE/$m" "s3://$BUCKET/manifest/$m" || ok=0
    done
    if [ "$ok" -eq 1 ]; then
        say "manifest + head + ingest.log -> s3://$BUCKET/manifest/ (head $(cat "$ARCHIVE/manifest.head"))"
    else
        echo "!! manifest: upload FAILED" >&2
        failed=$((failed + 1))
    fi
fi

echo
if [ ${#DRY[@]} -gt 0 ]; then
    say "dry run: $sessions session(s) scanned, $uploaded file(s) WOULD upload, $failed failure(s)"
else
    say "done: $sessions session(s) scanned, $uploaded file(s) uploaded, $failed failure(s)"
fi
[ "$failed" -eq 0 ] || exit 1
