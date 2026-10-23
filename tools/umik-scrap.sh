#!/bin/bash
# umik-scrap.sh - clear a stick WITHOUT archiving all of it: destroy the
# recordings nobody needs, keep (and archive) only a chosen time range.
#
#   umik scrap /Volumes/UMIK2                         drop every recording
#   umik scrap /Volumes/UMIK2 --keep 2026-10-20T08:00..2026-10-20T12:00
#   umik scrap /Volumes/UMIK2 --drop 2026-10-18..2026-10-19 --reason "mic left on"
#   options: --keep <range>... | --drop <range>...   (not both)
#            --reason "..."   why, for the record (default: operator decision)
#            --dry-run        print the plan, change nothing
#            --yes            skip the typed confirmation
#            --no-process     seal + clear + eject only; no S3/NAS legs
#            --utc            times without a zone are UTC, not this Mac's
#
# A range is START..END, either end optional (START.. or ..END); each end is
# YYYY-MM-DD[THH:MM[:SS]][Z|+HH:MM|-HH:MM]. A bare date is that day's 00:00;
# a bare date as END means the end of that day. No zone = local time.
#
# Segment and clip names carry their start time in UTC: umik-record.service
# and umik-sdr.service both pin TZ=UTC, because arecord's strftime names are
# local time. Each file's end is its start plus a length worked out from its
# size and session.json's format block (600 s when that cannot be done); an
# SDR clip's length comes from its .sigmf-meta.
#
# --keep: a file is kept when ANY part of it overlaps a keep range. --drop: a
# file is dropped only when ALL of it lies inside one drop range. Either way,
# a file at an edge is kept: the rule always errs toward keeping audio. A file
# whose name carries no time is never destroyed by a ranged run.
#
# Nothing changes until the plan has been printed and the volume's label typed
# back. Then, for every session losing files, scrapped.json is written INTO the
# session on the stick, the dropped files are deleted, and `umik process` takes
# over: scrapped.json is sealed beside session.json and uploaded with the
# session, so the archive shows that the session existed, what was discarded,
# by whom, why and when. The dropped files are NOT hashed: the hash of a file
# that no longer exists proves nothing anyone can later check. Their names,
# sizes and times document the gap.
#
# Exit: 0 done (or nothing to do), 1 fatal, 2 usage.

set -uo pipefail

SELF="$0"
[ -L "$SELF" ] && SELF=$(readlink "$SELF")
TOOLS_DIR=$(cd "$(dirname "$SELF")" && pwd)

_ENV_ARCHIVE="${UMIK_ARCHIVE:-}"
CONF="${UMIK_CONF:-$TOOLS_DIR/umik.local.conf}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
ARCHIVE="${_ENV_ARCHIVE:-${UMIK_ARCHIVE:-$HOME/UMIK-Archive}}"
# The ingest reads its settings from the environment only (see umik-process.sh).
export UMIK_ARCHIVE="$ARCHIVE"
[ -n "${UMIK_INGEST_JOBS:-}" ] && export UMIK_INGEST_JOBS
INGEST="$TOOLS_DIR/umik-ingest.sh"
FALLBACK_SECONDS=600

say()  { echo "==> $*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }
usage_die() { echo "umik scrap: $*" >&2; echo "see: umik scrap --help" >&2; exit 2; }
help() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$SELF"; }

VOL=""
MODE=all
RANGE_ARGS=()
REASON="operator decision"
YES=0
DRY=0
NO_PROCESS=0
UTC_INPUT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --keep|--drop)
            m=${1#--}
            [ "$MODE" = all ] || [ "$MODE" = "$m" ] || usage_die "--keep and --drop cannot be combined"
            MODE=$m
            [ $# -ge 2 ] || usage_die "$1 needs a range"
            RANGE_ARGS+=("$2"); shift ;;
        --keep=*|--drop=*)
            m=${1%%=*}; m=${m#--}
            [ "$MODE" = all ] || [ "$MODE" = "$m" ] || usage_die "--keep and --drop cannot be combined"
            MODE=$m
            RANGE_ARGS+=("${1#*=}") ;;
        --reason)       [ $# -ge 2 ] || usage_die "--reason needs text"; REASON=$2; shift ;;
        --reason=*)     REASON=${1#--reason=} ;;
        --yes)          YES=1 ;;
        --dry-run)      DRY=1 ;;
        --no-process)   NO_PROCESS=1 ;;
        --utc)          UTC_INPUT=1 ;;
        -h|--help)      help; exit 0 ;;
        -*)             usage_die "unknown option '$1'" ;;
        *)              [ -z "$VOL" ] || usage_die "one volume at a time ('$VOL' and '$1')"
                        VOL=${1%/} ;;
    esac
    shift
done
# Never "every mounted medium": this command destroys data.
[ -n "$VOL" ] || usage_die "name the volume, e.g. umik scrap /Volumes/UMIK2"
[ -n "$REASON" ] || REASON="operator decision"

# --- time ----------------------------------------------------------------------
# File names and the record are UTC, so their conversions are plain calendar
# arithmetic (no fork per file on a stick holding thousands). Only what the
# operator types in local time goes through `date`, which knows the zone rules.

days_from_civil() { # <y> <m> <d> -> DAYS (days since 1970-01-01)
    local y=$1 m=$2 d=$3 era yoe doy doe
    [ "$m" -le 2 ] && y=$((y - 1))
    era=$(( (y >= 0 ? y : y - 399) / 400 ))
    yoe=$(( y - era * 400 ))
    doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
    doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
    DAYS=$(( era * 146097 + doe - 719468 ))
}
civil_from_days() { # <days> -> CY CM CD
    local z=$(( $1 + 719468 )) era doe yoe doy mp
    era=$(( (z >= 0 ? z : z - 146096) / 146097 ))
    doe=$(( z - era * 146097 ))
    yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 ))
    doy=$(( doe - (365 * yoe + yoe / 4 - yoe / 100) ))
    mp=$(( (5 * doy + 2) / 153 ))
    CD=$(( doy - (153 * mp + 2) / 5 + 1 ))
    CM=$(( mp < 10 ? mp + 3 : mp - 9 ))
    CY=$(( yoe + era * 400 + (CM <= 2 ? 1 : 0) ))
}
utc_epoch() { # <y> <m> <d> <H> <M> <S> -> EPOCH; fails on an impossible date
    local y=$((10#$1)) m=$((10#$2)) d=$((10#$3)) H=$((10#$4)) M=$((10#$5)) S=$((10#$6))
    [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$H" -le 23 ] && [ "$M" -le 59 ] && [ "$S" -le 60 ] || return 1
    days_from_civil "$y" "$m" "$d"
    civil_from_days "$DAYS"
    [ "$CD" -eq "$d" ] || return 1   # 2026-02-30 is not a day
    EPOCH=$(( DAYS * 86400 + H * 3600 + M * 60 + S ))
}
stamp() { # <epoch> -> STAMP, the repo's compact UTC form (YYYYMMDDTHHMMSSZ)
    local e=$1 s
    s=$(( e % 86400 )); [ "$s" -lt 0 ] && s=$((s + 86400))
    civil_from_days $(( (e - s) / 86400 ))
    STAMP=$(printf '%04d%02d%02dT%02d%02d%02dZ' "$CY" "$CM" "$CD" $((s / 3600)) $((s % 3600 / 60)) $((s % 60)))
}
local_str() { date -r "$1" '+%Y-%m-%d %H:%M:%S %Z'; }
utc_str()   { date -u -r "$1" '+%Y-%m-%d %H:%M:%SZ'; }

# One end of a range -> EPOCH. <is_end> turns a bare date into the next day's
# 00:00, so `..2026-10-20` includes all of the 20th.
RX_POINT='^([0-9]{4})-([0-9]{2})-([0-9]{2})(T([0-9]{2}):([0-9]{2})(:([0-9]{2}))?)?(Z|[+-][0-9]{2}:[0-9]{2})?$'
parse_point() { # <text> <is_end>
    local t=$1 y m d H=00 M=00 S=00 zone bare=0 off=0 txt back
    [[ $t =~ $RX_POINT ]] || return 1
    y=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}; d=${BASH_REMATCH[3]}
    if [ -n "${BASH_REMATCH[4]}" ]; then
        H=${BASH_REMATCH[5]}; M=${BASH_REMATCH[6]}; S=${BASH_REMATCH[8]:-00}
    else
        bare=1
    fi
    zone=${BASH_REMATCH[9]}
    utc_epoch "$y" "$m" "$d" "$H" "$M" "$S" || return 1   # validates the calendar
    if [ "$bare" -eq 1 ] && [ "$2" -eq 1 ]; then
        civil_from_days $(( DAYS + 1 ))
        y=$(printf '%04d' "$CY"); m=$(printf '%02d' "$CM"); d=$(printf '%02d' "$CD")
        utc_epoch "$y" "$m" "$d" 00 00 00
    fi
    [ -z "$zone" ] && [ "$UTC_INPUT" -eq 1 ] && zone=Z
    case "$zone" in
        Z) ;;
        [+-]*)
            off=$(( 10#${zone:1:2} * 3600 + 10#${zone:4:2} * 60 ))
            [ "${zone:0:1}" = + ] && EPOCH=$((EPOCH - off)) || EPOCH=$((EPOCH + off)) ;;
        *)  # this Mac's local time; a wall time that does not exist (the hour
            # skipped by a DST change) fails the round trip and is refused.
            txt="$y-$m-$d $H:$M:$S"
            EPOCH=$(date -j -f '%Y-%m-%d %H:%M:%S' "$txt" +%s 2>/dev/null) || return 1
            back=$(date -j -r "$EPOCH" '+%Y-%m-%d %H:%M:%S')
            [ "$back" = "$txt" ] || return 1 ;;
    esac
}

# RANGES: one "from<TAB>to" line per range, epochs, "-" for an open end.
RANGES=""
if [ "${#RANGE_ARGS[@]}" -gt 0 ]; then
    for r in "${RANGE_ARGS[@]}"; do
        case "$r" in *..*) ;; *) usage_die "range '$r' is not START..END" ;; esac
        a=${r%%..*}; b=${r#*..}
        [ -n "$a" ] || [ -n "$b" ] || usage_die "range '$r' has neither end"
        fa=-; fb=-
        if [ -n "$a" ]; then parse_point "$a" 0 || usage_die "cannot read '$a' (YYYY-MM-DD[THH:MM[:SS]][Z|+HH:MM])"; fa=$EPOCH; fi
        if [ -n "$b" ]; then parse_point "$b" 1 || usage_die "cannot read '$b' (YYYY-MM-DD[THH:MM[:SS]][Z|+HH:MM])"; fb=$EPOCH; fi
        [ "$fa" = - ] || [ "$fb" = - ] || [ "$fa" -lt "$fb" ] || usage_die "range '$r' ends before it starts"
        RANGES="$RANGES$(printf '%s\t%s' "$fa" "$fb")
"
    done
fi

# --- preconditions ------------------------------------------------------------

[ -d "$VOL/recordings" ] || die "$VOL has no recordings/ directory - not a UMIK medium"
[ -d "$ARCHIVE/.lock" ] && die "an ingest is running (or crashed leaving $ARCHIVE/.lock) - wait for it, or remove a stale lock"
for sj in "$VOL"/recordings/*/scrapped.json; do
    [ -f "$sj" ] || continue
    die "$(dirname "$sj") already holds scrapped.json - an earlier scrap did not finish.
       Run: umik process $VOL   (seals what is there, record included), then re-run umik scrap."
done
LABEL=$(basename "$VOL")
vol_tag=$(printf '%s' "$LABEL" | tr -cd 'A-Za-z0-9._-')

W=$(mktemp -d "${TMPDIR:-/tmp}/umik-scrap.XXXXXX") || die "cannot create a scratch directory"
trap 'rm -rf "$W"' EXIT

# Exactly the ingest's rule (umik-ingest.sh session_unit), so "already sealed"
# is looked up where the ingest would have put it.
session_unit() { # <session-dir> <fallback>
    local u
    u=$(sed -n 's/.*"unit": *"\([a-z0-9-]*\)".*/\1/p' "$1/session.json" 2>/dev/null | head -1)
    printf '%s' "${u:-$2}"
}
json_str() { # <file> <key>  as umik-lib.sh reads a machine-written json
    sed -n "s/.*\"$2\": *\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" 2>/dev/null | head -1
}
# encoding, sample_rate and channels from inside the "format" block only (an
# SDR session's json says "channels" about something else), one-line or
# pretty-printed alike. Prints "<bytes per second>" or nothing.
bytes_per_second() { # <session.json>
    awk '{ s = s $0 " " } END {
        i = index(s, "\"format\""); if (!i) exit
        s = substr(s, i); j = index(s, "}"); if (j) s = substr(s, 1, j)
        enc = s; if (!sub(/.*"encoding": *"/, "", enc)) exit; sub(/".*/, "", enc)
        r = s; if (!sub(/.*"sample_rate": */, "", r)) exit; sub(/[^0-9].*/, "", r)
        c = s; if (!sub(/.*"channels": */, "", c)) exit; sub(/[^0-9].*/, "", c)
        b = (enc == "S16_LE") ? 2 : (enc == "S24_3LE") ? 3 : (enc == "S32_LE" || enc == "FLOAT_LE") ? 4 : 0
        if (b && r + 0 > 0 && c + 0 > 0) print b * r * c
    }' "$1" 2>/dev/null
}

# --- classify every file on the stick -----------------------------------------
# $W/files: session, name, bytes, mtime, start, end, class (KEEP DROP ARCH)
# with "-" for an untimed start/end (never an empty field: tab is IFS
# whitespace and `read` would collapse it). $W/sessions: one line per session.

: > "$W/files"
: > "$W/sessions"
: > "$W/hits"
RX_NAME='^(seg|clip)-([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})[.-]'
for sdir in "$VOL"/recordings/*/; do
    [ -d "$sdir" ] || continue
    sname=$(basename "$sdir")
    unit=$(session_unit "$sdir" "$vol_tag")
    sj="$sdir/session.json"
    bps=$(bytes_per_second "$sj")
    printf '%s\t%s\t%s\t%s\t%s\n' "$sname" "$unit" "$(json_str "$sj" started_utc)" \
        "$(json_str "$sj" time_source)" "$(json_str "$sj" clock_trusted)" \
        | awk 'BEGIN { FS = OFS = "\t" } { for (i = 1; i <= NF; i++) if ($i == "") $i = "-"; print }' >> "$W/sessions"
    dest="$ARCHIVE/recordings/$unit/$sname"
    for f in "$sdir"*; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        case "$base" in .*|*.part|session.json) continue ;; esac   # .* covers AppleDouble ._*
        read -r bytes mtime < <(stat -f '%z %m' "$f")
        start=-; end=-
        if [[ $base =~ $RX_NAME ]] && utc_epoch "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
                "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}" "${BASH_REMATCH[7]}"; then
            start=$EPOCH
            secs=0
            case "$base" in
                clip-*)
                    meta="$sdir${base%.sigmf-*}.sigmf-meta"
                    secs=$(sed -n 's/.*"umik:duration_s": *\([0-9.]*\).*/\1/p' "$meta" 2>/dev/null | head -1)
                    secs=$(awk -v s="${secs:-0}" 'BEGIN { n = int(s); if (n < s) n++; print n }') ;;
                *)
                    # whole seconds, rounded up - but under one second is no answer
                    if [ -n "$bps" ] && [ "$bytes" -gt 44 ]; then
                        secs=$(( (bytes - 44) / bps ))
                        [ "$secs" -ge 1 ] && [ $(( (bytes - 44) % bps )) -gt 0 ] && secs=$((secs + 1))
                    fi ;;
            esac
            # Not sane (unknown format, a header-only file, a size no segment
            # could have) -> the recorder's default segment length (UMIK_SEGMENT_SECONDS,
            # 600), the most a segment normally spans, so the guess only widens
            # a file and a wider file is only ever kept more readily.
            { [ "$secs" -ge 1 ] && [ "$secs" -le 86400 ]; } 2>/dev/null || secs=$FALLBACK_SECONDS
            end=$((start + secs))
        fi

        class=DROP
        if [ "$start" = - ]; then
            [ "$MODE" = all ] || class=KEEP
        elif [ "$MODE" != all ]; then
            [ "$MODE" = keep ] && class=DROP || class=KEEP
            n=0
            while IFS=$'\t' read -r ra rb; do
                [ -n "$ra" ] || continue
                n=$((n + 1))
                if [ "$MODE" = keep ]; then
                    { [ "$rb" = - ] || [ "$start" -lt "$rb" ]; } && { [ "$ra" = - ] || [ "$end" -gt "$ra" ]; } \
                        && { class=KEEP; echo "$n" >> "$W/hits"; }
                else
                    { [ "$ra" = - ] || [ "$start" -ge "$ra" ]; } && { [ "$rb" = - ] || [ "$end" -le "$rb" ]; } \
                        && { class=DROP; echo "$n" >> "$W/hits"; }
                fi
            done <<< "$RANGES"
        fi
        # Sealed already: removing it from the stick is an ordinary prune.
        if [ -f "$dest/$base" ] && awk -v n="$base" '{ sub(/^[0-9a-f]+  /, "") } $0 == n { f = 1 } END { exit !f }' \
                "$dest/SHA256SUMS" 2>/dev/null; then
            class=ARCH
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sname" "$base" "$bytes" "$mtime" "$start" "$end" "$class" >> "$W/files"
    done
done

# --- the plan --------------------------------------------------------------------

size() { awk -v b="$1" 'BEGIN { if (b >= 1e9) printf "%.2f GB", b / 1e9; else printf "%.1f MB", b / 1e6 }'; }
hours() { awk -v s="$1" 'BEGIN { printf "%.1f h", s / 3600 }'; }
# count bytes min-start max-end seconds untimed, for one session (or all: "")
tally() { # <session|""> <class>
    awk -F'\t' -v s="$1" -v c="$2" '
        (s == "" || $1 == s) && $7 == c {
            n++; b += $3
            if ($5 != "-") { if (lo == "" || $5 < lo) lo = $5; if (hi == "" || $6 > hi) hi = $6; secs += $6 - $5 } else u++
        }
        END { printf "%d %.0f %s %s %d %d\n", n, b, (lo == "" ? "-" : lo), (hi == "" ? "-" : hi), secs, u }' "$W/files"
}
endpoint() { # <local_str|utc_str> <epoch|->
    if [ "$2" = - ]; then echo "(open)"; else "$1" "$2"; fi
}
span() { # <lo> <hi>
    [ "$1" = - ] && { echo "(untimed only)"; return; }
    echo "$(local_str "$1") .. $(local_str "$2")  ($(utc_str "$1") .. $(utc_str "$2"))"
}
row() { # <word> <session|"">
    local n b lo hi secs u
    read -r n b lo hi secs u < <(tally "$2" "$1")
    if [ "$1" = DROP ]; then
        printf '        %-5s %5d file(s) %10s  %s  %s\n' "$1" "$n" "$(size "$b")" "$(hours "$secs")" "$( [ "$n" -gt 0 ] && span "$lo" "$hi")"
    else
        printf '        %-5s %5d file(s) %10s  %s\n' "$1" "$n" "$(size "$b")" "$( [ "$n" -gt 0 ] && span "$lo" "$hi")"
    fi
}

echo
say "umik scrap $VOL - the plan (nothing has changed yet)"
echo "    archive: $ARCHIVE"
case "$MODE" in
    all)  echo "    selection: drop EVERY recording on the stick" ;;
    keep) echo "    selection: keep files overlapping any range below, drop the rest" ;;
    drop) echo "    selection: drop files lying wholly inside a range below, keep the rest" ;;
esac
while IFS=$'\t' read -r ra rb; do
    [ -n "$ra" ] || continue
    printf '      %s .. %s\n' "$(endpoint local_str "$ra")" "$(endpoint local_str "$rb")"
    printf '      %s .. %s\n' "$(endpoint utc_str "$ra")" "$(endpoint utc_str "$rb")"
done <<< "$RANGES"
while IFS=$'\t' read -r sname unit started tsrc trusted; do
    echo
    read -r fn fb < <(awk -F'\t' -v s="$sname" '$1 == s { n++; b += $3 } END { printf "%d %.0f\n", n, b }' "$W/files")
    echo "    $sname  unit $unit  started $started  clock $tsrc/trusted=$trusted"
    echo "        $fn file(s), $(size "$fb") (plus session.json)"
    [ "$trusted" = true ] || [ "$MODE" = all ] \
        || echo "        !! clock not trusted: its file names may not be real time - the ranges are matched against them anyway"
    row KEEP "$sname"
    row DROP "$sname"
    read -r an _ < <(tally "$sname" ARCH)
    un=$(awk -F'\t' -v s="$sname" '$1 == s && $5 == "-" && $7 != "ARCH" { n++ } END { print n + 0 }' "$W/files")
    echo "        ALREADY-ARCHIVED $an   UNTIMED $un$( [ "$un" -gt 0 ] && { [ "$MODE" = all ] && echo ' (dropped)' || echo ' (kept)'; })"
done < "$W/sessions"

echo
echo "    totals:"
row KEEP ""
row DROP ""
read -r an ab _ < <(tally "" ARCH)
echo "        ALREADY-ARCHIVED $an file(s), $(size "$ab") - removed by the ordinary prune"

# The ingest walks only recordings/; 53 GB once sat unseen in .Trashes.
if [ "$(df -P "$VOL" | awk 'NR==2 { print $6 }')" = "$VOL" ]; then
    used=$(df -Pk "$VOL" | awk 'NR==2 { print $3 * 1024 }')
    rec=$(du -sk "$VOL/recordings" | awk '{ print $1 * 1024 }')
    out=$(( used - rec ))
    [ "$out" -gt 1000000000 ] \
        && echo "    !! $(size "$out") on this volume sits outside recordings/ - check .Trashes before trusting this plan"
fi
n=0
while IFS=$'\t' read -r ra _; do
    [ -n "$ra" ] || continue
    n=$((n + 1))
    grep -qx "$n" "$W/hits" || echo "    !! range $n (${RANGE_ARGS[$((n - 1))]}) matched no file"
done <<< "$RANGES"
echo

read -r DROPN DROPB _ _ DROPSECS _ < <(tally "" DROP)
read -r KEEPN KEEPB _ _ KEEPSECS _ < <(tally "" KEEP)
[ "$DRY" -eq 1 ] && { say "dry run - nothing changed"; exit 0; }
[ "$DROPN" -gt 0 ] || { say "nothing to drop - nothing changed"; exit 0; }

# --- confirmation ----------------------------------------------------------------

if [ "$YES" -eq 0 ]; then
    [ -t 0 ] || die "stdin is not a terminal and --yes was not given - nothing changed"
    printf 'This DESTROYS %d unarchived file(s) (%s). Type the volume label (%s) to go ahead: ' \
        "$DROPN" "$(size "$DROPB")" "$LABEL"
    read -r answer || answer=
    [ "$answer" = "$LABEL" ] || { say "aborted - nothing changed"; exit 1; }
fi

# --- the record ----------------------------------------------------------------

json_esc() { # <text> -> JSON string body
    local s=$1 c out="" i
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
    # anything else below 0x20 is dropped rather than half-escaped
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case "$c" in [[:cntrl:]]) ;; *) out+=$c ;; esac
    done
    printf '%s' "$out"
}
jstamp() { # <epoch|-> -> "stamp" or null
    if [ "$1" = - ]; then printf 'null'; else stamp "$1"; printf '"%s"' "$STAMP"; fi
}

stamp "$(date -u +%s)"; NOW=$STAMP
BY="$(git -C "$TOOLS_DIR" config user.name 2>/dev/null || true)"
BY="${BY:-${USER:-unknown}}@$(hostname -s)"
SEL_RANGES=""
while IFS=$'\t' read -r ra rb; do
    [ -n "$ra" ] || continue
    SEL_RANGES="$SEL_RANGES${SEL_RANGES:+, }{ \"from\": $(jstamp "$ra"), \"to\": $(jstamp "$rb") }"
done <<< "$RANGES"

records=0
touched=0
while IFS=$'\t' read -r sname unit started _ _; do
    awk -F'\t' -v s="$sname" '$1 == s && $7 == "DROP" { f = 1 } END { exit !f }' "$W/files" || continue
    awk -F'\t' -v s="$sname" '$1 == s' "$W/files" > "$W/s"
    read -r dn db lo hi dsecs _ < <(tally "$sname" DROP)
    kb=$(awk -F'\t' '$7 == "KEEP" { b += $3 } END { printf "%.0f\n", b }' "$W/s")
    rec="$VOL/recordings/$sname/scrapped.json"
    {
        echo "{"
        echo "  \"scrapped_utc\": \"$NOW\","
        echo "  \"tool\": \"umik scrap\","
        echo "  \"by\": \"$(json_esc "$BY")\","
        echo "  \"reason\": \"$(json_esc "$REASON")\","
        echo "  \"selection\": { \"mode\": \"$MODE\", \"ranges\": [${SEL_RANGES:+ $SEL_RANGES }] },"
        echo "  \"session\": \"$(json_esc "$sname")\","
        echo "  \"unit\": \"$(json_esc "$unit")\","
        if [ "$started" = - ]; then echo "  \"started_utc\": null,"; else echo "  \"started_utc\": \"$(json_esc "$started")\","; fi
        echo "  \"dropped\": ["
        sep=""
        while IFS=$'\t' read -r _ name bytes mtime start end class; do
            [ "$class" = DROP ] || continue
            stamp "$mtime"
            printf '%s    { "name": "%s", "bytes": %s, "mtime_utc": "%s", "start_utc": %s, "end_utc": %s }' \
                "$sep" "$(json_esc "$name")" "$bytes" "$STAMP" "$(jstamp "$start")" "$(jstamp "$end")"
            sep=$',\n'
        done < "$W/s"
        echo
        echo "  ],"
        echo "  \"dropped_count\": $dn,"
        echo "  \"dropped_bytes\": $db,"
        echo "  \"dropped_seconds\": $dsecs,"
        if [ "$lo" = - ]; then echo "  \"dropped_span\": null,"
        else echo "  \"dropped_span\": { \"from\": $(jstamp "$lo"), \"to\": $(jstamp "$hi") },"; fi
        printf '  "kept": ['
        sep=""
        while IFS=$'\t' read -r _ name _ _ _ _ class; do
            [ "$class" = KEEP ] || continue
            printf '%s"%s"' "$sep" "$(json_esc "$name")"; sep=", "
        done < "$W/s"
        echo "],"
        echo "  \"kept_bytes\": $kb,"
        printf '  "already_archived": ['
        sep=""
        while IFS=$'\t' read -r _ name _ _ _ _ class; do
            [ "$class" = ARCH ] || continue
            printf '%s"%s"' "$sep" "$(json_esc "$name")"; sep=", "
        done < "$W/s"
        echo "]"
        echo "}"
    } > "$rec.tmp" || die "cannot write $rec.tmp - nothing deleted"
    mv "$rec.tmp" "$rec" || die "cannot write $rec - nothing deleted"
    records=$((records + 1))
    touched=$((touched + 1))
done < "$W/sessions"

# --- the destruction -------------------------------------------------------------
# Serial, and the first failure stops it: the records already say what was
# intended, and the ingest seals whatever is left.

dropped=0
while IFS=$'\t' read -r sname name _ _ _ _ class; do
    [ "$class" = DROP ] || continue
    rm "$VOL/recordings/$sname/$name" || die "rm failed on $sname/$name after $dropped deletion(s) - run: umik process $VOL"
    dropped=$((dropped + 1))
done < "$W/files"

echo
say "scrap done"
echo "    sessions touched: $touched"
echo "    files dropped   : $dropped ($(size "$DROPB"), $(hours "$DROPSECS"))"
echo "    files kept      : $KEEPN ($(size "$KEEPB"), $(hours "$KEEPSECS"))"
echo "    records written : $records (scrapped.json, sealed with each session)"

# --- hand-off: everything kept goes through the real pipeline --------------------

if [ "$NO_PROCESS" -eq 0 ]; then
    say "handing off to umik process $VOL"
    exec "$TOOLS_DIR/umik-process.sh" "$VOL"
fi

say "sealing what is left on $VOL"
"$INGEST" "$VOL" || die "ingest reported warnings - $VOL NOT cleared; the scrap records are on it, check the messages above"
"$INGEST" --prune-verified "$VOL" || die "prune failed - $VOL NOT ejected"
if diskutil eject "$VOL" > "$W/eject.log" 2>&1; then
    say "$VOL cleared + ejected - safe to unplug"
else
    say "$VOL cleared but could not eject ($(tail -1 "$W/eject.log"))"
fi
say "the scrap records wait in $ARCHIVE for the next umik upload / umik process"
