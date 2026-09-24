#!/bin/bash
# umik-ingest.sh - offline chain-of-custody ingest for UMIK recordings.
#
# The moment the card (or a stick) is mounted, every new recording is sealed:
# its bytes are SHA-256 hashed AS THEY ARE READ off the medium, written to the
# local archive, the written copy is re-read and verified, and the hash is
# recorded twice - in a per-session SHA256SUMS file (publish this next to the
# audio; anyone verifies with `shasum -a 256 -c SHA256SUMS`) and in a single
# append-only, hash-chained manifest whose head hash commits to every seal
# ever made. Editing any archived byte, or any manifest line, breaks a check.
#
# Trust boundary, stated plainly: this proves integrity FROM INGEST ONWARD.
# It cannot prove what happened to the card before it reached this machine.
#
# Entirely offline - no network is touched, ever.
#
# Speed, without loosening any of that: files are sealed by a pool of workers
# (UMIK_INGEST_JOBS, default 4) that only ever write to <name>.part alongside
# the archive copy, and a single serial pass then promotes each .part to its
# final name, in the exact order a one-at-a-time run would have used. So the
# SHA256SUMS lines and the manifest chain are identical either way, and no
# half-written file ever exists under a final name. Hashing prefers
# /usr/bin/openssl (about five times faster than shasum here) and falls back to
# shasum; the hashes, and the files holding them, are unchanged.
#
#   ./tools/umik-ingest.sh                     ingest /Volumes/UMIKDATA now
#   ./tools/umik-ingest.sh /Volumes/MYSTICK    ingest a specific volume
#   ./tools/umik-ingest.sh --install-agent     auto-ingest whenever mounted
#   ./tools/umik-ingest.sh --uninstall-agent
#   ./tools/umik-ingest.sh --verify            check the manifest hash chain
#   ./tools/umik-ingest.sh --verify --deep     ...and re-hash every sealed file
#   ./tools/umik-ingest.sh --check-sums <dir>...  re-hash the files listed in
#                                              each dir's SHA256SUMS (any copy
#                                              of a sealed session, e.g. on a NAS)
#   ./tools/umik-ingest.sh --prune-verified [vol]  free card space: delete
#                                              source files whose sealed copy
#                                              re-verifies, never anything else
#
# Archive layout ($UMIK_ARCHIVE, default ~/UMIK-Archive):
#   recordings/<unit>/<session>/...            sealed originals (unit from
#                                              session.json; volume label for
#                                              pre-unit-stamping sessions)
#   recordings/<unit>/<session>/SHA256SUMS     publishable checksums
#   logs/<utc-stamp>/                          card activity-log snapshots
#   manifest.log, manifest.head                hash-chained seal record
#   ingest.log                                 human-readable run history
#
# The last segment of every session has a stale WAV header (power cut by
# design). The sealed original is kept byte-exact; a playable derivative
# <name>.repaired.wav is generated, sealed, and recorded separately. Whether a
# derivative is needed at all is decided by `repair-wav.sh --check`, which only
# reads the header - the copy is made (an APFS clone when it can be) solely for
# the files that really do need one.
#
# Environment: UMIK_ARCHIVE (default ~/UMIK-Archive), UMIK_INGEST_JOBS
# (default 4). Both are read from the environment only; this script
# deliberately sources no config file, so an unattended agent run behaves
# exactly like a hand-run one.

set -uo pipefail

ARCHIVE="${UMIK_ARCHIVE:-$HOME/UMIK-Archive}"
SRC_DEFAULT=/Volumes/UMIKDATA
AGENT_LABEL=com.umik.ingest
PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)
REPAIR="$TOOLS_DIR/repair-wav.sh"
SHASUM=/usr/bin/shasum
OPENSSL=/usr/bin/openssl
HASHER=shasum

JOBS="${UMIK_INGEST_JOBS:-4}"
case "$JOBS" in ''|*[!0-9]*|0) JOBS=4 ;; esac

AGENT_MODE=0
WORKDIR=

say()  { echo "==> $*"; }
note() { # log a line to the run history and to stdout
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$ARCHIVE/ingest.log"
    echo "    $*"
}
die() { echo "FATAL: $*" >&2; exit 1; }

notify() { # best-effort macOS notification; silent when unavailable
    osascript -e "display notification \"$1\" with title \"UMIK ingest\"" \
        >/dev/null 2>&1 || true
}

make_workdir() { # scratch for the work lists and result markers
    WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/umik-ingest.XXXXXX") \
        || die "cannot create a scratch directory"
}

# The one parallel pattern used here. Workers are handed a LINE NUMBER and look
# the record up themselves: BSD xargs caps an assembled -I command line at 255
# bytes, and two archive paths blow past it. Every worker must also exit 0 -
# BSD xargs abandons the whole run on some non-zero child exits (the same trap
# that once cut an upload short at 866 of 1515 objects, see umik-upload.sh).
run_parallel() { # <worker function> <record count>
    [ "$2" -gt 0 ] || return 0
    # shellcheck disable=SC2163  # the worker's NAME is the argument, on purpose
    export -f "$1" sha_of sha_stdin
    export HASHER SHASUM OPENSSL REPAIR WORKDIR
    seq 1 "$2" | xargs -P "$JOBS" -I{} bash -c "$1"' "$@"' _ {}
}

# Same SHA-256, five times the throughput: LibreSSL's dgst runs about
# 2500 MB/s here where the Perl shasum manages 500, and a 460 MB segment is
# hashed twice per seal. Nothing about the OUTPUT changes - bare lowercase hex,
# written into the same SHA256SUMS format third parties check with
# `shasum -a 256 -c`. The probe is the empty-input digest, so a build of
# openssl that cannot do the job is caught here rather than mid-ingest.
pick_hasher() {
    local probe
    probe=$(printf '' | "$OPENSSL" dgst -sha256 -r 2>/dev/null | awk '{print $1}')
    [ "$probe" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ] \
        && HASHER=openssl
    return 0
}

sha_of() { # <file> -> bare lowercase hex
    case "$HASHER" in
        openssl) "$OPENSSL" dgst -sha256 -r "$1" ;;
        *)       "$SHASUM" -a 256 "$1" ;;
    esac | awk '{print $1}'
}

sha_stdin() { # hash of stdin -> bare lowercase hex
    case "$HASHER" in
        openssl) "$OPENSSL" dgst -sha256 -r ;;
        *)       "$SHASUM" -a 256 ;;
    esac | awk '{print $1}'
}

sha_of_text() { printf '%s' "$1" | sha_stdin; }

# Archive under the UNIT that recorded the session (umik1, umik2, ...), not
# the medium's volume label: both units' media carry the same label, and
# sticks can move between Pis. The unit is read from session.json; sessions
# from before unit-stamping fall back to the volume label, which keeps every
# already-sealed path exactly where the manifest says it is.
session_unit() { # <session-dir> <fallback>
    local u
    u=$(sed -n 's/.*"unit": *"\([a-z0-9-]*\)".*/\1/p' "$1/session.json" 2>/dev/null | head -1)
    printf '%s' "${u:-$2}"
}

# --- hash-chained manifest ---------------------------------------------------
# Each line commits to the previous line's hash; manifest.head is the hash of
# the newest line. Publishing the head string pins the entire archive history.

manifest_append() { # <vol> <relpath> <bytes> <sha256>
    local prev line
    prev=$(cat "$ARCHIVE/manifest.head" 2>/dev/null || echo GENESIS)
    line="ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) vol=$1 path=$2 bytes=$3 sha256=$4 prev=$prev"
    printf '%s\n' "$line" >> "$ARCHIVE/manifest.log"
    sha_of_text "$line" > "$ARCHIVE/manifest.head"
}

manifest_has_hash() { grep -q "sha256=$1 " "$ARCHIVE/manifest.log" 2>/dev/null; }

verify_manifest() {
    [ -f "$ARCHIVE/manifest.log" ] || die "no manifest at $ARCHIVE/manifest.log"
    local run=GENESIS n=0 line prev
    while IFS= read -r line; do
        n=$((n + 1))
        prev=${line##*prev=}
        [ "$prev" = "$run" ] || die "manifest chain BROKEN at line $n (prev mismatch) - the manifest has been edited"
        run=$(sha_of_text "$line")
    done < "$ARCHIVE/manifest.log"
    [ "$run" = "$(cat "$ARCHIVE/manifest.head" 2>/dev/null)" ] \
        || die "manifest head does not match the chain - manifest.head or the last lines were edited"
    say "manifest chain OK: $n seals, head $run"
}

# Every sealed byte is re-read. The hashing runs $JOBS wide across the whole
# archive - it is entirely disk-and-CPU bound - but the reporting stays exactly
# as it was: one OK/FAIL line per directory, in directory order.
verify_worker() { # <line number in $WORKDIR/list>  prints dir<TAB>name<TAB>result
    local line dir name want have
    line=$(sed -n "${1}p" "$WORKDIR/list")
    dir=${line%%$'\t'*}
    want=${line##*$'\t'}
    line=${line#*$'\t'}
    name=${line%%$'\t'*}
    have=$(sha_of "$dir/$name" 2>/dev/null)
    if [ -n "$have" ] && [ "$have" = "$want" ]; then
        printf '%s\t%s\tOK\n' "$dir" "$name"
    else
        printf '%s\t%s\tFAILED\n' "$dir" "$name"
    fi
    return 0
}

# With no arguments: every sealed directory in the archive. With arguments:
# exactly those directories (each holding a SHA256SUMS) - which is how a copy
# of the archive somewhere else, a NAS say, is checked against the same seals.
verify_deep() { # [dir ...]
    local fails=0 sums dir total bad
    make_workdir
    trap 'rm -rf "$WORKDIR"' EXIT

    : > "$WORKDIR/dirs"
    if [ $# -gt 0 ]; then
        for dir in "$@"; do
            dir=${dir%/}
            [ -f "$dir/SHA256SUMS" ] || die "no SHA256SUMS in $dir"
            printf '%s\n' "$dir" >> "$WORKDIR/dirs"
        done
    else
        for sums in "$ARCHIVE"/recordings/*/*/SHA256SUMS "$ARCHIVE"/logs/*/SHA256SUMS; do
            [ -f "$sums" ] && dirname "$sums" >> "$WORKDIR/dirs"
        done
    fi

    : > "$WORKDIR/list"
    while IFS= read -r dir; do
        awk -v d="$dir" '{h=$1; sub(/^[0-9a-f]+  /, ""); print d"\t"$0"\t"h}' "$dir/SHA256SUMS" \
            >> "$WORKDIR/list"
    done < "$WORKDIR/dirs"
    total=$(wc -l < "$WORKDIR/list" | tr -d ' ')
    say "re-hashing $total sealed file(s), $JOBS at a time ($HASHER)"
    run_parallel verify_worker "$total" > "$WORKDIR/out"

    while IFS= read -r dir; do
        bad=$(awk -F'\t' -v d="$dir" '$1 == d && $3 != "OK" { print $2 ": FAILED" }' "$WORKDIR/out")
        if [ -z "$bad" ]; then
            say "OK   ${dir#"$ARCHIVE"/}"
        else
            echo "FAIL ${dir#"$ARCHIVE"/} - a sealed file no longer matches its checksum" >&2
            printf '%s\n' "$bad" >&2
            fails=$((fails + 1))
        fi
    done < "$WORKDIR/dirs"
    [ "$fails" -eq 0 ] || die "$fails director(ies) failed deep verification"
    say "deep verification OK: every sealed byte matches its seal"
}

# --- sealing -----------------------------------------------------------------

# Recording a seal - the publishable checksum line and the manifest link - is
# always serial, and always from a file already sitting under its final name.
seal_record() { # <file> <vol> <relpath> <bytes> <sha256>
    printf '%s  %s\n' "$5" "$(basename "$1")" >> "$(dirname "$1")/SHA256SUMS"
    manifest_append "$2" "$3" "$4" "$5"
}

seal_stream() { # <src> <dst> <vol> <relpath>  hash-while-copying, then verify
    local src=$1 dst=$2 vol=$3 rel=$4 bytes hsrc hdst
    bytes=$(stat -f%z "$src") || return 1
    hsrc=$(tee "$dst" < "$src" | sha_stdin)
    hdst=$(sha_of "$dst")
    if [ -z "$hsrc" ] || [ "$hsrc" != "$hdst" ]; then
        rm -f "$dst"
        note "ERROR: copy verification FAILED for $rel (src $hsrc dst $hdst) - copy discarded"
        return 1
    fi
    seal_record "$dst" "$vol" "$rel" "$bytes" "$hsrc"
    return 0
}

# The parallel half of a seal. It runs in a bare `bash -c`, with none of this
# script's shell options, several at a time, and it deliberately cannot do any
# damage: it writes <dst>.part and a marker saying how that went, and never
# touches SHA256SUMS, the manifest, or any final name. Always exits 0.
seal_worker() { # <line number in $WORKDIR/jobs>
    local line src dst rel bytes hsrc hdst rep rc
    line=$(sed -n "${1}p" "$WORKDIR/jobs")
    src=${line%%$'\t'*}
    rel=${line##*$'\t'}
    line=${line#*$'\t'}
    dst=${line%%$'\t'*}

    rm -f "$dst.part" "$dst.part.ok" "$dst.fail"
    if [ ! -r "$src" ]; then
        printf 'cannot read %s on the medium - nothing sealed\n' "$rel" > "$dst.fail"
        return 0
    fi
    bytes=$(stat -f%z "$src") || bytes=
    hsrc=$(tee "$dst.part" < "$src" | sha_stdin)
    hdst=$(sha_of "$dst.part" 2>/dev/null)
    if [ -z "$hsrc" ] || [ -z "$bytes" ] || [ "$hsrc" != "$hdst" ]; then
        rm -f "$dst.part"
        printf 'copy verification FAILED for %s (src %s dst %s) - copy discarded\n' \
            "$rel" "$hsrc" "$hdst" > "$dst.fail"
        return 0
    fi
    printf '%s\t%s\n' "$bytes" "$hsrc" > "$dst.part.ok"

    # Playable derivative for power-cut tails. --check reads the header and
    # nothing else, so the 460 MB copy happens only for the handful of files
    # that genuinely need one (exit 1; 0 is a good header, 2 is not a WAV).
    case "$dst" in
        *.repaired.wav) return 0 ;;
        *.wav) ;;
        *) return 0 ;;
    esac
    rep="${dst%.wav}.repaired.wav"
    [ ! -e "$rep" ] || return 0
    [ -x "$REPAIR" ] || return 0
    rm -f "$rep.part" "$rep.part.ok" "$rep.fail"
    "$REPAIR" --check "$dst.part" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 1 ] || return 0
    if ! cp -c "$dst.part" "$rep.part" 2>/dev/null && ! cp "$dst.part" "$rep.part"; then
        rm -f "$rep.part"
        printf 'could not copy %s to make its repaired derivative\n' "$rel" > "$rep.fail"
        return 0
    fi
    "$REPAIR" --in-place "$rep.part" >/dev/null 2>&1 || true
    printf '%s\t%s\n' "$(stat -f%z "$rep.part")" "$(sha_of "$rep.part")" > "$rep.part.ok"
    return 0
}

# --- ingest ------------------------------------------------------------------

ingest() {
    local SRC=$1 vol unit sdir sname dest base src dst rel rep bytes hsrc total
    local new=0 skipped=0 warned=0 repaired=0

    if [ ! -d "$SRC/recordings" ]; then
        [ "$AGENT_MODE" -eq 1 ] && exit 0
        die "$SRC has no recordings/ directory - not a UMIK medium (pass the volume explicitly?)"
    fi
    vol=$(basename "$SRC" | tr -cd 'A-Za-z0-9._-')
    mkdir -p "$ARCHIVE"

    # One ingest at a time; a stale lock from a crash is reported, not raced.
    if ! mkdir "$ARCHIVE/.lock" 2>/dev/null; then
        note "another ingest is running (or crashed leaving $ARCHIVE/.lock) - exiting"
        exit 0
    fi
    make_workdir
    trap 'rmdir "$ARCHIVE/.lock" 2>/dev/null; rm -rf "$WORKDIR"' EXIT

    note "ingest start: $SRC -> $ARCHIVE (volume '$vol')"

    # Phase A (serial): walk the medium in directory order and settle
    # everything that is already sealed, leaving a work list that holds only
    # new seals - in the order a one-file-at-a-time run would have done them.
    : > "$WORKDIR/jobs"
    for sdir in "$SRC"/recordings/*/; do
        [ -d "$sdir" ] || continue
        sname=$(basename "$sdir")
        unit=$(session_unit "$sdir" "$vol")
        dest="$ARCHIVE/recordings/$unit/$sname"
        mkdir -p "$dest"

        for src in "$sdir"*; do
            [ -f "$src" ] || continue
            base=$(basename "$src")
            case "$base" in .*|._*) continue ;; esac   # dotfiles, AppleDouble
            dst="$dest/$base"
            rel="recordings/$unit/$sname/$base"

            if [ -e "$dst" ]; then
                # Already sealed. The archive is the truth from that moment;
                # never overwrite it. A size change on the card is loud.
                if [ "$(stat -f%z "$src")" != "$(stat -f%z "$dst")" ]; then
                    note "WARNING: $rel exists sealed but the CARD copy now differs in size - card copy ignored, seal kept"
                    warned=$((warned + 1))
                else
                    skipped=$((skipped + 1))
                fi
                continue
            fi

            printf '%s\t%s\t%s\t%s\n' "$src" "$dst" "$vol" "$rel" >> "$WORKDIR/jobs"
        done
    done

    # Phase B (parallel): read the medium, copy, and verify - into .part files
    # and result markers only. Nothing here is a seal yet.
    total=$(wc -l < "$WORKDIR/jobs" | tr -d ' ')
    [ "$total" -eq 0 ] || note "sealing $total new file(s), $JOBS at a time ($HASHER)"
    run_parallel seal_worker "$total"

    # Phase C (serial, Phase A order): promote each verified .part to its final
    # name and record the seal. Same order, same lines, same log as a serial
    # run - and a file that never got here never existed under its real name.
    # Fresh names for the record's fields ($vol and friends are still needed
    # after this loop, and `read` empties whatever it was given at EOF). The
    # source path has done its job in Phase B and is dropped here.
    while IFS=$'\t' read -r _ dst jvol rel; do
        if [ -f "$dst.part.ok" ]; then
            IFS=$'\t' read -r bytes hsrc < "$dst.part.ok"
            rm -f "$dst.part.ok"
            mv "$dst.part" "$dst"
            seal_record "$dst" "$jvol" "$rel" "$bytes" "$hsrc"
            note "sealed $rel ($bytes bytes)"
            new=$((new + 1))
        else
            if [ -f "$dst.fail" ]; then
                note "ERROR: $(cat "$dst.fail")"
            else
                note "ERROR: $rel was never sealed - its worker did not finish"
            fi
            rm -f "$dst.part" "$dst.fail"
            warned=$((warned + 1))
            continue
        fi

        # Playable derivative for power-cut tails, sealed separately.
        rep="${dst%.wav}.repaired.wav"
        if [ -f "$rep.part.ok" ]; then
            IFS=$'\t' read -r bytes hsrc < "$rep.part.ok"
            rm -f "$rep.part.ok"
            mv "$rep.part" "$rep"
            seal_record "$rep" "$jvol" "${rel%.wav}.repaired.wav" "$bytes" "$hsrc"
            note "sealed $(basename "$rep") (repaired header derivative)"
            repaired=$((repaired + 1))
        elif [ -f "$rep.fail" ]; then
            note "ERROR: $(cat "$rep.fail")"
            rm -f "$rep.part" "$rep.fail"
            warned=$((warned + 1))
        fi
    done < "$WORKDIR/jobs"

    # Snapshot the card's activity/diag logs - they are evidence too. Skipped
    # when an identical byte-for-byte snapshot was already sealed.
    if [ -d "$SRC/logs" ]; then
        local ts logdest lf lh any=0
        ts=$(date -u +%Y%m%dT%H%M%SZ)
        logdest="$ARCHIVE/logs/$ts"
        for lf in "$SRC"/logs/*.log "$SRC"/logs/*.log.1; do
            [ -f "$lf" ] || continue
            lh=$(sha_of "$lf")
            manifest_has_hash "$lh" && continue
            mkdir -p "$logdest"
            if seal_stream "$lf" "$logdest/$(basename "$lf")" "$vol" "logs/$ts/$(basename "$lf")"; then
                any=$((any + 1))
            fi
        done
        [ "$any" -gt 0 ] && note "sealed $any card log file(s) -> logs/$ts/"
    fi

    # Leave a fresh time-seed on the medium: at next boot the Pi steps its
    # clock forward to this (a floor only - GPS still overrides; the seed is
    # never marked trusted). Written last so an ingest failure above still
    # aborts before touching the card.
    if date -u +%s > "$SRC/umik-time-seed" 2>/dev/null; then
        note "time-seed refreshed on '$vol'"
    else
        note "could not write time-seed on '$vol' (read-only medium?)"
    fi

    note "ingest done: $new sealed, $repaired repaired derivative(s), $skipped already sealed, $warned warning(s)"
    if [ "$new" -gt 0 ] || [ "$warned" -gt 0 ]; then
        notify "$new file(s) sealed, $warned warning(s) - archive: $ARCHIVE"
    fi
    [ "$warned" -eq 0 ] || exit 1
}

# --- prune -------------------------------------------------------------------
# Free card space: delete a source file ONLY after its sealed copy re-verifies
# against the recorded checksum. Anything unsealed or mismatched stays put.

# Hashing only - this worker deletes nothing and writes nothing but its own
# "this one re-verified" marker. Always exits 0.
prune_worker() { # <line number in $WORKDIR/cand>
    local line dst want have
    line=$(sed -n "${1}p" "$WORKDIR/cand")
    line=${line#*$'\t'}
    dst=${line%%$'\t'*}
    line=${line#*$'\t'}
    want=${line%%$'\t'*}
    [ "$want" != - ] || return 0
    [ -f "$dst" ] || return 0
    have=$(sha_of "$dst" 2>/dev/null)
    [ -n "$have" ] && [ "$have" = "$want" ] && : > "$WORKDIR/ok.$1"
    return 0
}

prune_verified() {
    local SRC=$1 vol unit sdir sname dest base src dst want label total n=0 removed=0 kept=0
    [ -d "$SRC/recordings" ] || die "$SRC has no recordings/ directory"
    vol=$(basename "$SRC" | tr -cd 'A-Za-z0-9._-')
    make_workdir
    trap 'rm -rf "$WORKDIR"' EXIT

    # Pass 1: list every candidate, in the order the messages have always come
    # out. A file with no seal line gets an empty hash and is never verified.
    : > "$WORKDIR/cand"
    : > "$WORKDIR/sessions"
    for sdir in "$SRC"/recordings/*/; do
        [ -d "$sdir" ] || continue
        sname=$(basename "$sdir")
        unit=$(session_unit "$sdir" "$vol")
        dest="$ARCHIVE/recordings/$unit/$sname"
        printf '%s\n' "$sdir" >> "$WORKDIR/sessions"
        for src in "$sdir"*; do
            [ -f "$src" ] || continue
            base=$(basename "$src")
            case "$base" in .*|._*) continue ;; esac
            dst="$dest/$base"
            want=$(grep -F "  $base" "$dest/SHA256SUMS" 2>/dev/null | awk 'NR==1{print $1}')
            # A dash, never an empty field: tab is IFS whitespace, so `read`
            # would collapse two tabs into one and shift every later column.
            [ -n "$want" ] || want=-
            printf '%s\t%s\t%s\t%s\n' "$src" "$dst" "$want" "$sname/$base" >> "$WORKDIR/cand"
        done
    done

    # Pass 2: re-hash the archive copies, $JOBS at a time.
    total=$(wc -l < "$WORKDIR/cand" | tr -d ' ')
    run_parallel prune_worker "$total"

    # Pass 3: delete, serially, only what pass 2 proved. Any doubt - no marker,
    # an unreadable archive copy, a missing seal line - keeps the source file.
    while IFS=$'\t' read -r src dst want label; do
        n=$((n + 1))
        if [ -f "$WORKDIR/ok.$n" ]; then
            rm "$src" && removed=$((removed + 1))
        else
            kept=$((kept + 1))
            echo "KEEP $label - no verified seal in the archive" >&2
        fi
    done < "$WORKDIR/cand"

    while IFS= read -r sdir; do
        rmdir "$sdir" 2>/dev/null || true   # only removes emptied sessions
    done < "$WORKDIR/sessions"
    say "pruned $removed verified file(s) from $SRC, kept $kept"
}

# --- launchd agent -----------------------------------------------------------

install_agent() {
    mkdir -p "$ARCHIVE" "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${TOOLS_DIR}/umik-ingest.sh</string>
        <string>--agent</string>
    </array>
    <key>StartOnMount</key><true/>
    <key>RunAtLoad</key><false/>
    <key>EnvironmentVariables</key>
    <dict><key>UMIK_ARCHIVE</key><string>${ARCHIVE}</string></dict>
    <key>StandardOutPath</key><string>${ARCHIVE}/agent.log</string>
    <key>StandardErrorPath</key><string>${ARCHIVE}/agent.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
    say "agent installed: every volume mount now triggers an ingest check"
    say "archive: $ARCHIVE   (agent activity -> $ARCHIVE/agent.log)"
    say "note: the agent points at ${TOOLS_DIR}; re-run --install-agent if the repo moves"
}

uninstall_agent() {
    launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null \
        || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    say "agent uninstalled"
}

# --- main --------------------------------------------------------------------

pick_hasher

case "${1:-}" in
    --install-agent)   install_agent ;;
    --uninstall-agent) uninstall_agent ;;
    --verify)
        verify_manifest
        if [ "${2:-}" = "--deep" ]; then verify_deep; fi
        ;;
    --check-sums)
        shift
        [ $# -gt 0 ] || die "usage: umik-ingest.sh --check-sums <dir> [dir ...]"
        verify_deep "$@"
        ;;
    --prune-verified)  prune_verified "${2:-$SRC_DEFAULT}" ;;
    --agent)           AGENT_MODE=1; ingest "$SRC_DEFAULT" ;;
    --help|-h)
        sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)                 ingest "${1:-$SRC_DEFAULT}" ;;
esac
