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
#   ./tools/umik-ingest.sh                     ingest /Volumes/UMIKDATA now
#   ./tools/umik-ingest.sh /Volumes/MYSTICK    ingest a specific volume
#   ./tools/umik-ingest.sh --install-agent     auto-ingest whenever mounted
#   ./tools/umik-ingest.sh --uninstall-agent
#   ./tools/umik-ingest.sh --verify            check the manifest hash chain
#   ./tools/umik-ingest.sh --verify --deep     ...and re-hash every sealed file
#   ./tools/umik-ingest.sh --prune-verified [vol]  free card space: delete
#                                              source files whose sealed copy
#                                              re-verifies, never anything else
#
# Archive layout ($UMIK_ARCHIVE, default ~/UMIK-Archive):
#   recordings/<volume>/<session>/...          sealed originals
#   recordings/<volume>/<session>/SHA256SUMS   publishable checksums
#   logs/<utc-stamp>/                          card activity-log snapshots
#   manifest.log, manifest.head                hash-chained seal record
#   ingest.log                                 human-readable run history
#
# The last segment of every session has a stale WAV header (power cut by
# design). The sealed original is kept byte-exact; a playable derivative
# <name>.repaired.wav is generated, sealed, and recorded separately.

set -uo pipefail

ARCHIVE="${UMIK_ARCHIVE:-$HOME/UMIK-Archive}"
SRC_DEFAULT=/Volumes/UMIKDATA
AGENT_LABEL=com.umik.ingest
PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)
REPAIR="$TOOLS_DIR/repair-wav.sh"
SHASUM=/usr/bin/shasum

AGENT_MODE=0

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

sha_of()      { "$SHASUM" -a 256 "$1" | awk '{print $1}'; }
sha_of_text() { printf '%s' "$1" | "$SHASUM" -a 256 | awk '{print $1}'; }

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

verify_deep() {
    local fails=0 sums dir
    for sums in "$ARCHIVE"/recordings/*/*/SHA256SUMS "$ARCHIVE"/logs/*/SHA256SUMS; do
        [ -f "$sums" ] || continue
        dir=$(dirname "$sums")
        if (cd "$dir" && "$SHASUM" -a 256 -c SHA256SUMS >/dev/null 2>&1); then
            say "OK   ${dir#"$ARCHIVE"/}"
        else
            echo "FAIL ${dir#"$ARCHIVE"/} - a sealed file no longer matches its checksum" >&2
            (cd "$dir" && "$SHASUM" -a 256 -c SHA256SUMS 2>&1 | grep -v ': OK$' >&2) || true
            fails=$((fails + 1))
        fi
    done
    [ "$fails" -eq 0 ] || die "$fails director(ies) failed deep verification"
    say "deep verification OK: every sealed byte matches its seal"
}

# --- sealing -----------------------------------------------------------------

seal_stream() { # <src> <dst> <vol> <relpath>  hash-while-copying, then verify
    local src=$1 dst=$2 vol=$3 rel=$4 bytes hsrc hdst
    bytes=$(stat -f%z "$src") || return 1
    hsrc=$(tee "$dst" < "$src" | "$SHASUM" -a 256 | awk '{print $1}')
    hdst=$(sha_of "$dst")
    if [ -z "$hsrc" ] || [ "$hsrc" != "$hdst" ]; then
        rm -f "$dst"
        note "ERROR: copy verification FAILED for $rel (src $hsrc dst $hdst) - copy discarded"
        return 1
    fi
    printf '%s  %s\n' "$hsrc" "$(basename "$dst")" >> "$(dirname "$dst")/SHA256SUMS"
    manifest_append "$vol" "$rel" "$bytes" "$hsrc"
    return 0
}

seal_local() { # <file> <vol> <relpath>  seal a locally generated derivative
    local f=$1 vol=$2 rel=$3 h
    h=$(sha_of "$f")
    printf '%s  %s\n' "$h" "$(basename "$f")" >> "$(dirname "$f")/SHA256SUMS"
    manifest_append "$vol" "$rel" "$(stat -f%z "$f")" "$h"
}

# --- ingest ------------------------------------------------------------------

ingest() {
    local SRC=$1 vol sdir sname dest base src dst rel rep
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
    trap 'rmdir "$ARCHIVE/.lock" 2>/dev/null' EXIT

    note "ingest start: $SRC -> $ARCHIVE (volume '$vol')"

    for sdir in "$SRC"/recordings/*/; do
        [ -d "$sdir" ] || continue
        sname=$(basename "$sdir")
        dest="$ARCHIVE/recordings/$vol/$sname"
        mkdir -p "$dest"

        for src in "$sdir"*; do
            [ -f "$src" ] || continue
            base=$(basename "$src")
            case "$base" in .*|._*) continue ;; esac   # dotfiles, AppleDouble
            dst="$dest/$base"
            rel="recordings/$vol/$sname/$base"

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

            if seal_stream "$src" "$dst" "$vol" "$rel"; then
                note "sealed $rel ($(stat -f%z "$dst") bytes)"
                new=$((new + 1))
            else
                warned=$((warned + 1))
                continue
            fi

            # Playable derivative for power-cut tails, sealed separately.
            case "$base" in
                *.repaired.wav) ;;
                *.wav)
                    rep="${dst%.wav}.repaired.wav"
                    if [ ! -e "$rep" ] && [ -x "$REPAIR" ]; then
                        cp "$dst" "$rep"
                        "$REPAIR" --in-place "$rep" >/dev/null 2>&1 || true
                        if cmp -s "$dst" "$rep"; then
                            rm -f "$rep"    # header was already correct
                        else
                            seal_local "$rep" "$vol" "recordings/$vol/$sname/$(basename "$rep")"
                            note "sealed $(basename "$rep") (repaired header derivative)"
                            repaired=$((repaired + 1))
                        fi
                    fi ;;
            esac
        done
    done

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

    note "ingest done: $new sealed, $repaired repaired derivative(s), $skipped already sealed, $warned warning(s)"
    if [ "$new" -gt 0 ] || [ "$warned" -gt 0 ]; then
        notify "$new file(s) sealed, $warned warning(s) - archive: $ARCHIVE"
    fi
    [ "$warned" -eq 0 ] || exit 1
}

# --- prune -------------------------------------------------------------------
# Free card space: delete a source file ONLY after its sealed copy re-verifies
# against the recorded checksum. Anything unsealed or mismatched stays put.

prune_verified() {
    local SRC=$1 vol sdir sname dest base src dst want have removed=0 kept=0
    [ -d "$SRC/recordings" ] || die "$SRC has no recordings/ directory"
    vol=$(basename "$SRC" | tr -cd 'A-Za-z0-9._-')
    for sdir in "$SRC"/recordings/*/; do
        [ -d "$sdir" ] || continue
        sname=$(basename "$sdir")
        dest="$ARCHIVE/recordings/$vol/$sname"
        for src in "$sdir"*; do
            [ -f "$src" ] || continue
            base=$(basename "$src")
            case "$base" in .*|._*) continue ;; esac
            dst="$dest/$base"
            want=$(grep -F "  $base" "$dest/SHA256SUMS" 2>/dev/null | awk 'NR==1{print $1}')
            if [ -n "$want" ] && [ -f "$dst" ] && have=$(sha_of "$dst") && [ "$have" = "$want" ]; then
                rm "$src" && removed=$((removed + 1))
            else
                kept=$((kept + 1))
                echo "KEEP $sname/$base - no verified seal in the archive" >&2
            fi
        done
        rmdir "$sdir" 2>/dev/null || true   # only removes emptied sessions
    done
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

case "${1:-}" in
    --install-agent)   install_agent ;;
    --uninstall-agent) uninstall_agent ;;
    --verify)
        verify_manifest
        [ "${2:-}" = "--deep" ] && verify_deep
        ;;
    --prune-verified)  prune_verified "${2:-$SRC_DEFAULT}" ;;
    --agent)           AGENT_MODE=1; ingest "$SRC_DEFAULT" ;;
    --help|-h)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)                 ingest "${1:-$SRC_DEFAULT}" ;;
esac
