#!/bin/bash
# umik-process.sh - the whole collection loop for every mounted medium, with
# the slow legs overlapped instead of run one after another.
#
#   seal (umik-ingest.sh)  ->  re-verify every new seal  ->
#       | clear the medium + eject          (the stick goes back in the field)
#       | S3 upload + verify-s3             (needs UMIK_S3_BUCKET)
#       | NAS copy (rsync) + re-hash there  (needs UMIK_NAS_DIR or --nas)
#   ->  delete the local audio once BOTH off-box copies verified.
#
#   umik process                   every mounted UMIK medium
#   umik process /Volumes/UMIK2    one medium
#   umik process --keep-local      never delete the archive's audio
#   umik process --nas <dir>       the NAS folder holding recordings/<unit>/
#
# Local audio is deleted only when the S3 verification AND the NAS re-hash
# both passed; seals, session.json and the manifest always stay. If the NAS
# is not mounted, or no bucket is configured, the audio simply stays and the
# summary says so - nothing here ever guesses. Leg logs land in
# $ARCHIVE/process/<utc-stamp>/.
#
# UMIK_NAS_DIR may list several candidates separated by ':' (the mount point
# moves between ~/mnt/nas and /Volumes/... on this Mac); the first one that
# exists wins.

set -uo pipefail

SELF="$0"
[ -L "$SELF" ] && SELF=$(readlink "$SELF")
TOOLS_DIR=$(cd "$(dirname "$SELF")" && pwd)

_ENV_ARCHIVE="${UMIK_ARCHIVE:-}"
_ENV_NAS="${UMIK_NAS_DIR:-}"
CONF="${UMIK_CONF:-$TOOLS_DIR/umik.local.conf}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
ARCHIVE="${_ENV_ARCHIVE:-${UMIK_ARCHIVE:-$HOME/UMIK-Archive}}"
BUCKET="${UMIK_S3_BUCKET:-}"
NAS_CANDIDATES="${_ENV_NAS:-${UMIK_NAS_DIR:-}}"
# The ingest reads its settings from the environment only; hand it the one
# the config may carry.
[ -n "${UMIK_INGEST_JOBS:-}" ] && export UMIK_INGEST_JOBS
INGEST="$TOOLS_DIR/umik-ingest.sh"

say()  { echo "==> $*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }
leg()  { printf '    [%s] %s\n' "$1" "$2"; }
leg_word() { case "$1" in 0) echo verified ;; 2) echo skipped ;; *) echo FAILED ;; esac; }

KEEP_LOCAL=0
NAS_ARG=""
MEDIA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --keep-local) KEEP_LOCAL=1 ;;
        --nas)        NAS_ARG=${2:-}; shift ;;
        --nas=*)      NAS_ARG=${1#--nas=} ;;
        -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)           die "unknown option '$1' (see umik process --help)" ;;
        *)            MEDIA+=("${1%/}") ;;
    esac
    shift
done
[ -n "$NAS_ARG" ] && NAS_CANDIDATES=$NAS_ARG

# --- what to work on ---------------------------------------------------------

if [ "${#MEDIA[@]}" -eq 0 ]; then
    for vol in /Volumes/*/; do
        vol=${vol%/}
        [ -d "$vol/recordings" ] && MEDIA+=("$vol")
    done
fi
[ "${#MEDIA[@]}" -gt 0 ] || die "no UMIK media mounted (looked for /Volumes/*/recordings)"

NAS=""
# (bash 3.2 + set -u: never expand an array that may be empty)
IFS=: read -ra cands <<< "$NAS_CANDIDATES"
if [ "${#cands[@]}" -gt 0 ]; then
    for c in "${cands[@]}"; do
        [ -n "$c" ] && [ -d "$c" ] && { NAS=$c; break; }
    done
fi

RUN="$ARCHIVE/process/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN"
say "run log: $RUN/"
[ -n "$BUCKET" ] || say "no UMIK_S3_BUCKET configured - the S3 leg is skipped, local audio stays"
if [ -n "$NAS" ]; then
    say "NAS copy: $NAS"
else
    say "NAS not mounted (candidates: ${NAS_CANDIDATES:-none}) - the NAS leg is skipped, local audio stays"
fi

# --- 1. seal ------------------------------------------------------------------
# Serial per medium (two sticks would fight over the same USB bus anyway).
# The set of NEW sessions is read off the ingest's own "sealed <relpath>"
# lines, so every later leg works on exactly what this run sealed.

declare -a CLEAN_MEDIA=()
ingest_failed=0
: > "$RUN/new-sessions"
for vol in "${MEDIA[@]}"; do
    say "sealing $vol"
    if "$INGEST" "$vol" 2>&1 | tee -a "$RUN/ingest.log"; then
        CLEAN_MEDIA+=("$vol")
    else
        ingest_failed=$((ingest_failed + 1))
        echo "!! $vol: ingest reported warnings - it will NOT be cleared" >&2
    fi
done
sed -n 's/^ *sealed \(recordings\/[^/]*\/[^/]*\)\/.*/\1/p' "$RUN/ingest.log" \
    | sort -u > "$RUN/new-sessions"
NEW=()
while IFS= read -r s; do [ -n "$s" ] && NEW+=("$s"); done < "$RUN/new-sessions"
say "${#NEW[@]} session(s) with new seals"

# --- 2. re-verify what was just sealed ---------------------------------------
# The ingest already re-read every byte it wrote; this is the independent
# check before anything is removed from the medium.

"$INGEST" --verify > "$RUN/verify.log" 2>&1 || die "manifest chain verification failed - see $RUN/verify.log"
if [ "${#NEW[@]}" -gt 0 ]; then
    dirs=()
    for s in "${NEW[@]}"; do dirs+=("$ARCHIVE/$s"); done
    "$INGEST" --check-sums "${dirs[@]}" >> "$RUN/verify.log" 2>&1 \
        || die "a new seal does not re-verify - nothing cleared, nothing uploaded; see $RUN/verify.log"
fi
say "seals verified"

# --- 3. the three legs, overlapped -------------------------------------------

leg_clear() { # clear + eject every medium whose ingest was clean
    local vol rc=0
    [ "${#CLEAN_MEDIA[@]}" -gt 0 ] || return 0
    for vol in "${CLEAN_MEDIA[@]}"; do
        if "$INGEST" --prune-verified "$vol" >> "$RUN/clear.log" 2>&1; then
            if diskutil eject "$vol" >> "$RUN/clear.log" 2>&1; then
                leg clear "$vol cleared + ejected - safe to unplug"
            else
                leg clear "$vol cleared but could not eject (see clear.log)"
            fi
        else
            leg clear "$vol: prune kept files - NOT ejected (see clear.log)"
            rc=1
        fi
    done
    return $rc
}

leg_s3() {
    [ -n "$BUCKET" ] || return 2
    "$TOOLS_DIR/umik-upload.sh" > "$RUN/upload.log" 2>&1 \
        || { leg s3 "upload FAILED (see upload.log)"; return 1; }
    leg s3 "upload done, verifying the bucket"
    "$TOOLS_DIR/umik-verify-s3.sh" > "$RUN/verify-s3.log" 2>&1 \
        || { leg s3 "verify-s3 FAILED (see verify-s3.log)"; return 1; }
    leg s3 "bucket verified against the seals"
}

leg_nas() {
    [ -n "$NAS" ] || return 2
    [ "${#NEW[@]}" -gt 0 ] || { leg nas "nothing new to copy"; return 0; }
    local s unit sname dst rc=0 dirs
    dirs=()
    for s in "${NEW[@]}"; do
        unit=$(basename "$(dirname "$s")"); sname=$(basename "$s")
        dst="$NAS/recordings/$unit/$sname"
        mkdir -p "$dst"
        # macOS rsync: no --info; owner/perms are the NAS's business.
        if rsync -rlt --no-perms --no-owner --no-group "$ARCHIVE/$s/" "$dst/" >> "$RUN/nas.log" 2>&1; then
            dirs+=("$dst")
        else
            leg nas "rsync FAILED for $sname (see nas.log)"; rc=1
        fi
    done
    [ "$rc" -eq 0 ] || return 1
    leg nas "copied ${#dirs[@]} session(s), re-hashing them on the NAS"
    "$INGEST" --check-sums "${dirs[@]}" >> "$RUN/nas.log" 2>&1 \
        || { leg nas "NAS re-hash FAILED (see nas.log)"; return 1; }
    leg nas "NAS copy verified against the seals"
}

say "starting legs: clear+eject | S3 | NAS"
leg_clear & p_clear=$!
leg_s3    & p_s3=$!
leg_nas   & p_nas=$!
wait $p_clear; rc_clear=$?
wait $p_s3;    rc_s3=$?
wait $p_nas;   rc_nas=$?

# --- 4. the local audio ------------------------------------------------------

deleted=0
if [ "$KEEP_LOCAL" -eq 1 ]; then
    say "--keep-local: archive audio kept"
elif [ "${#NEW[@]}" -eq 0 ]; then
    say "nothing new was sealed - archive untouched"
elif [ "$rc_s3" -eq 0 ] && [ "$rc_nas" -eq 0 ]; then
    for s in "${NEW[@]}"; do
        for f in "$ARCHIVE/$s"/*.wav; do
            [ -f "$f" ] || continue
            rm -f "$f" && deleted=$((deleted + 1))
        done
    done
    say "S3 and NAS both verified - deleted $deleted local audio file(s); seals kept"
else
    say "local audio KEPT: S3 leg rc=$rc_s3, NAS leg rc=$rc_nas (2 = leg not configured/mounted)"
fi

# --- summary ---------------------------------------------------------------

echo
say "process done"
echo "    sealed sessions : ${#NEW[@]}"
echo "    media cleared   : ${#CLEAN_MEDIA[@]} of ${#MEDIA[@]} (clear leg rc=$rc_clear)"
echo "    S3              : $(leg_word "$rc_s3")"
echo "    NAS             : $(leg_word "$rc_nas")"
echo "    local audio     : $([ "$deleted" -gt 0 ] && echo "$deleted file(s) deleted" || echo kept)"
echo "    logs            : $RUN/"

fail=0
[ "$ingest_failed" -eq 0 ] || fail=1
[ "$rc_clear" -eq 0 ] || fail=1
[ "$rc_s3" -eq 0 ] || [ "$rc_s3" -eq 2 ] || fail=1
[ "$rc_nas" -eq 0 ] || [ "$rc_nas" -eq 2 ] || fail=1
exit $fail
