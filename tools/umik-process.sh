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
#   umik process --defer-verify    seal, clear, upload and copy - but leave the
#                                  off-box verification (and so the local
#                                  delete) for one later --finish; the
#                                  sessions are noted in process/pending-verify
#   umik process --finish          verify S3 and the NAS once for everything
#                                  pending, then delete that local audio
#
# Local audio is deleted only when the S3 verification AND the NAS re-hash
# both passed; seals, session.json and the manifest always stay. If the NAS
# is not mounted, or no bucket is configured, the audio simply stays and the
# summary says so - nothing here ever guesses. Leg logs land in
# $ARCHIVE/process/<utc-stamp>/.
#
# UMIK_NAS_DIR may list several candidates separated by ':'; the first one
# that is a directory ON A NETWORK MOUNT (smbfs/afpfs/nfs) wins. A candidate
# that exists but sits on local disk - an unmounted mount point, a stale
# symlink target - is rejected, and the check is repeated right before each
# rsync: the NAS leg must never quietly copy onto this Mac and call it the NAS.
#
# Two sticks back to back: start the second run as soon as its stick is in.
# Its seal overlaps the first run's upload; its own S3 leg then waits on
# process/upload.lock, because two uploaders at once would race to PUT the
# same keys and, under Object Lock, leave a second undeletable version.
# With --defer-verify on both and one --finish after, the bucket is verified
# once instead of once per stick.

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
PENDING="$ARCHIVE/process/pending-verify"
UPLOAD_LOCK="$ARCHIVE/process/upload.lock"

say()  { echo "==> $*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }
leg()  { printf '    [%s] %s\n' "$1" "$2"; }
leg_word() { case "$1" in 0) echo verified ;; 2) echo skipped ;; 3) echo "copied, verification deferred" ;; *) echo FAILED ;; esac; }

KEEP_LOCAL=0
DEFER=0
FINISH=0
NAS_ARG=""
MEDIA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --keep-local)   KEEP_LOCAL=1 ;;
        --defer-verify) DEFER=1 ;;
        --finish)       FINISH=1 ;;
        --nas)          NAS_ARG=${2:-}; shift ;;
        --nas=*)        NAS_ARG=${1#--nas=} ;;
        -h|--help)      sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)             die "unknown option '$1' (see umik process --help)" ;;
        *)              MEDIA+=("${1%/}") ;;
    esac
    shift
done
[ -n "$NAS_ARG" ] && NAS_CANDIDATES=$NAS_ARG
[ "$DEFER" -eq 1 ] && [ "$FINISH" -eq 1 ] && die "--defer-verify and --finish are opposites; pick one"
[ "$FINISH" -eq 1 ] && [ "${#MEDIA[@]}" -gt 0 ] && die "--finish works on what earlier runs left pending; it takes no medium"

# --- what to work on ---------------------------------------------------------

if [ "$FINISH" -eq 0 ] && [ "${#MEDIA[@]}" -eq 0 ]; then
    for vol in /Volumes/*/; do
        vol=${vol%/}
        [ -d "$vol/recordings" ] && MEDIA+=("$vol")
    done
fi
[ "$FINISH" -eq 1 ] || [ "${#MEDIA[@]}" -gt 0 ] || die "no UMIK media mounted (looked for /Volumes/*/recordings)"

# The filesystem type behind a path, as `mount` reports it (smbfs, apfs, ...).
# macOS has no `df -T` / `stat -f %T`-for-fstype, so: df gives the mount point,
# mount gives its type.
fs_type_of() { # <path>
    local mp
    mp=$(df -P "$1" 2>/dev/null | awk 'NR==2{ $1=$2=$3=$4=$5=""; sub(/^ +/,""); print }')
    [ -n "$mp" ] || return 1
    mount | awk -v m="$mp" '
        index($0, " on " m " (") { s=$0; sub(/.*\(/, "", s); sub(/[,)].*/, "", s); print s; exit }'
}
# A usable NAS directory: exists, and its (symlink-resolved) path lives on a
# network filesystem. Prints the resolved path; fails otherwise.
nas_dir_ok() { # <path>
    local real t
    [ -n "$1" ] && [ -d "$1" ] || return 1
    real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    t=$(fs_type_of "$real") || return 1
    case "$t" in smbfs|afpfs|nfs|webdav) printf '%s' "$real" ;; *) return 1 ;; esac
}

NAS=""
# (bash 3.2 + set -u: never expand an array that may be empty)
IFS=: read -ra cands <<< "$NAS_CANDIDATES"
if [ "${#cands[@]}" -gt 0 ]; then
    for c in "${cands[@]}"; do
        if NAS=$(nas_dir_ok "$c"); then break; fi
        NAS=""
        [ -n "$c" ] && [ -d "$c" ] && say "NAS candidate $c exists but is on local disk ($(fs_type_of "$c" || echo '?')) - ignored"
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
# A --finish run seals nothing: its NEW set is whatever earlier --defer-verify
# runs noted in $PENDING.

declare -a CLEAN_MEDIA=()
ingest_failed=0
: > "$RUN/new-sessions"
if [ "$FINISH" -eq 1 ]; then
    [ -s "$PENDING" ] && sort -u "$PENDING" > "$RUN/new-sessions"
else
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
fi
NEW=()
while IFS= read -r s; do [ -n "$s" ] && [ -d "$ARCHIVE/$s" ] && NEW+=("$s"); done < "$RUN/new-sessions"
if [ "$FINISH" -eq 1 ]; then
    say "${#NEW[@]} session(s) pending verification"
    [ "${#NEW[@]}" -gt 0 ] || { say "nothing pending - nothing to finish"; exit 0; }
else
    say "${#NEW[@]} session(s) with new seals"
fi

# --- 2. re-verify what was just sealed ---------------------------------------
# The ingest already re-read every byte it wrote; this is the independent
# check before anything is removed from the medium. (--finish skips the
# per-session re-hash: it ran when those sessions were sealed, and what
# --finish is about is the copies off-box.)

"$INGEST" --verify > "$RUN/verify.log" 2>&1 || die "manifest chain verification failed - see $RUN/verify.log"
if [ "$FINISH" -eq 0 ] && [ "${#NEW[@]}" -gt 0 ]; then
    dirs=()
    for s in "${NEW[@]}"; do dirs+=("$ARCHIVE/$s"); done
    "$INGEST" --check-sums "${dirs[@]}" >> "$RUN/verify.log" 2>&1 \
        || die "a new seal does not re-verify - nothing cleared, nothing uploaded; see $RUN/verify.log"
    say "seals verified"
fi

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

# One uploader at a time, machine-wide: the lock is a directory (mkdir is
# atomic; macOS ships no flock) holding the owner's pid, so a lock left by a
# run that died is taken over rather than waited on forever.
take_upload_lock() {
    local owner said=0
    until mkdir "$UPLOAD_LOCK" 2>/dev/null; do
        owner=$(cat "$UPLOAD_LOCK/pid" 2>/dev/null || echo)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$UPLOAD_LOCK"; continue
        fi
        [ "$said" -eq 1 ] || { leg s3 "another run is uploading (pid ${owner:-?}) - waiting for it"; said=1; }
        sleep 20
    done
    echo $$ > "$UPLOAD_LOCK/pid"
}
drop_upload_lock() { rm -rf "$UPLOAD_LOCK"; }

leg_s3() {
    [ -n "$BUCKET" ] || return 2
    take_upload_lock
    "$TOOLS_DIR/umik-upload.sh" > "$RUN/upload.log" 2>&1 \
        || { drop_upload_lock; leg s3 "upload FAILED (see upload.log)"; return 1; }
    if [ "$DEFER" -eq 1 ]; then
        drop_upload_lock
        leg s3 "upload done - bucket verification deferred to --finish"
        return 3
    fi
    leg s3 "upload done, verifying the bucket"
    "$TOOLS_DIR/umik-verify-s3.sh" > "$RUN/verify-s3.log" 2>&1 \
        || { drop_upload_lock; leg s3 "verify-s3 FAILED (see verify-s3.log)"; return 1; }
    drop_upload_lock
    leg s3 "bucket verified against the seals"
}

leg_nas() {
    [ -n "$NAS" ] || return 2
    [ "${#NEW[@]}" -gt 0 ] || { leg nas "nothing new to copy"; return 0; }
    local s unit sname dst rc=0 dirs
    dirs=()
    for s in "${NEW[@]}"; do
        unit=$(basename "$(dirname "$s")"); sname=$(basename "$s")
        # Re-check before every write: a share that dropped mid-run leaves a
        # plain local directory behind, and rsync would happily fill it.
        if ! nas_dir_ok "$NAS" >/dev/null; then
            leg nas "$NAS is no longer a network mount - NAS leg FAILED, nothing written"; return 1
        fi
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
    if [ "$DEFER" -eq 1 ]; then
        leg nas "copied ${#dirs[@]} session(s) - NAS re-hash deferred to --finish"
        return 3
    fi
    nas_dir_ok "$NAS" >/dev/null || { leg nas "$NAS is no longer a network mount - NAS leg FAILED"; return 1; }
    leg nas "copied ${#dirs[@]} session(s), re-hashing them on the NAS"
    "$INGEST" --check-sums "${dirs[@]}" >> "$RUN/nas.log" 2>&1 \
        || { leg nas "NAS re-hash FAILED (see nas.log)"; return 1; }
    leg nas "NAS copy verified against the seals"
}

if [ "$FINISH" -eq 1 ]; then
    say "starting legs: S3 verify | NAS verify (nothing to clear)"
elif [ "$DEFER" -eq 1 ]; then
    say "starting legs: clear+eject | S3 upload | NAS copy (verification deferred)"
else
    say "starting legs: clear+eject | S3 | NAS"
fi
leg_clear & p_clear=$!
leg_s3    & p_s3=$!
leg_nas   & p_nas=$!
wait $p_clear; rc_clear=$?
wait $p_s3;    rc_s3=$?
wait $p_nas;   rc_nas=$?

# --- 4. the local audio ------------------------------------------------------

deleted=0
pending_now=0
if [ "$KEEP_LOCAL" -eq 1 ]; then
    say "--keep-local: archive audio kept"
elif [ "${#NEW[@]}" -eq 0 ]; then
    say "nothing new was sealed - archive untouched"
elif [ "$DEFER" -eq 1 ]; then
    # Noted whatever the legs did: --finish re-runs the (idempotent) upload
    # and rsync before verifying, so a leg that failed here gets its retry.
    mkdir -p "$(dirname "$PENDING")"
    printf '%s\n' "${NEW[@]}" >> "$PENDING"
    pending_now=$(sort -u "$PENDING" | grep -c .)
    say "local audio KEPT - ${#NEW[@]} session(s) noted for verification ($pending_now pending in all); run: umik process --finish"
elif [ "$rc_s3" -eq 0 ] && [ "$rc_nas" -eq 0 ]; then
    for s in "${NEW[@]}"; do
        # Mic segments and umik-sdr's raw IQ (the .sigmf-data half of each
        # clip) alike: both are bulk data with verified copies off-box; seals,
        # session.json, clips.jsonl, each clip's .sigmf-meta and the scan
        # files stay.
        for f in "$ARCHIVE/$s"/*.wav "$ARCHIVE/$s"/*.sigmf-data; do
            [ -f "$f" ] || continue
            rm -f "$f" && deleted=$((deleted + 1))
        done
    done
    say "S3 and NAS both verified - deleted $deleted local audio/IQ file(s); seals kept"
    if [ "$FINISH" -eq 1 ] && [ -f "$PENDING" ]; then
        # Only what this run verified leaves the list: a --defer-verify run
        # that ended meanwhile may have added more.
        grep -vxF -f "$RUN/new-sessions" "$PENDING" > "$PENDING.tmp"
        mv "$PENDING.tmp" "$PENDING"
        [ -s "$PENDING" ] || rm -f "$PENDING"
    fi
else
    say "local audio KEPT: S3 leg rc=$rc_s3, NAS leg rc=$rc_nas (2 = leg not configured/mounted)"
fi

# --- summary ---------------------------------------------------------------

echo
say "process done"
if [ "$FINISH" -eq 1 ]; then
    echo "    verified sessions: ${#NEW[@]}"
else
    echo "    sealed sessions : ${#NEW[@]}"
    echo "    media cleared   : ${#CLEAN_MEDIA[@]} of ${#MEDIA[@]} (clear leg rc=$rc_clear)"
fi
echo "    S3              : $(leg_word "$rc_s3")"
echo "    NAS             : $(leg_word "$rc_nas")"
echo "    local audio     : $([ "$deleted" -gt 0 ] && echo "$deleted file(s) deleted" || echo kept)"
[ "$DEFER" -eq 1 ] && echo "    pending verify  : $pending_now session(s) -> umik process --finish"
echo "    logs            : $RUN/"

fail=0
[ "$ingest_failed" -eq 0 ] || fail=1
[ "$rc_clear" -eq 0 ] || fail=1
[ "$rc_s3" -eq 0 ] || [ "$rc_s3" -eq 2 ] || [ "$rc_s3" -eq 3 ] || fail=1
[ "$rc_nas" -eq 0 ] || [ "$rc_nas" -eq 2 ] || [ "$rc_nas" -eq 3 ] || fail=1
exit $fail
