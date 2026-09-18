#!/bin/bash
# umik-lib.sh - the bits umik-upload.sh and umik-verify-s3.sh must agree on.
#
# Why a shared file: the uploader and the verifier both have to decide, from
# the same archive, which local file becomes which S3 key and which hash is
# that key's seal. When that logic lived twice - once in each script - any
# drift between the two would surface as a phantom "expected but absent from
# S3", or, far worse, as a key the verifier never thought to check. One copy,
# sourced by both, cannot drift.
#
# This file is sourced, never run. The caller must already have set:
#   ARCHIVE  the local archive root
#   WORK     a scratch dir (retry_aws parks stderr there)
# and is expected to define its own say()/die().

# ---------------------------------------------------------------------------

json_str() { # <file> <key>  first string value of "key" in a machine-written json
    sed -n "s/.*\"$2\": *\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" 2>/dev/null | head -1
}

# S3 throttles bursts of calls against 86-173 MB objects, and a bare call then
# fails transiently. Let the SDK back off and retry rather than reporting a
# scary FAIL on an object that is actually fine.
#
# Every call site must exit 0 regardless of outcome: BSD xargs aborts the whole
# run on some non-zero child exits, which is how an earlier version silently
# stopped after 866 of 1515 objects.
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

# S3 wants checksums base64; SHA256SUMS holds them hex. Converting the SEAL
# (rather than re-hashing the file) is the whole point: the value handed to S3
# comes from the sealed manifest, so S3 rejects the PUT if the bytes it
# receives are not the bytes that were sealed.
umik_hex_to_b64() { # <hex>
    printf '%s' "$1" | xxd -r -p | base64 | tr -d '\n'
}

# Content types are set at PUT time because, under write-once, there is no
# second chance to fix them: a metadata correction is an overwrite.
umik_content_type() { # <path-or-key>
    case "$1" in
        *.wav)                echo audio/x-wav ;;
        *SHA256SUMS|*.log|*.head) echo text/plain ;;
        *.json)               echo application/json ;;
        *)                    echo binary/octet-stream ;;
    esac
}

# --- the expected map: key <TAB> seal hex <TAB> local path -------------------
# Session and log files take their hash from the SHA256SUMS sealed beside them
# (the published, checkable artifact), never from a hash computed here - a
# fresh local hash would only prove the file matches itself. SHA256SUMS is not
# listed inside itself, so it is hashed here.
#
# The manifest trio is deliberately NOT in this map: it is not sealed in any
# SHA256SUMS and the two callers treat it differently (the uploader pins a new
# per-run set, the verifier can only check the current head).
umik_build_expected() { # <outfile>
    local out=$1 sdir unit sname datepart sj d prefix ldir lname

    : > "$out"

    for sdir in "$ARCHIVE"/recordings/*/*/; do
        [ -d "$sdir" ] || continue
        sdir=${sdir%/}
        unit=$(basename "$(dirname "$sdir")")
        sname=$(basename "$sdir")

        # The date prefix is earned, not assumed: only a session that recorded
        # clock_trusted=true files under its start date. Everything else -
        # seeded floors, dead clocks, pre-GPS sessions - goes under
        # raw/undated/ where nothing pretends to know when it was. time_source
        # must name a trusted source too (gps, gps-time-only, ntp, or a
        # disciplined rtc): old-payload sessions could claim clock_trusted=true
        # off the fake baseline clock with no time source at all.
        datepart=undated
        sj="$sdir/session.json"
        if [ -f "$sj" ] && [ "$(json_str "$sj" clock_trusted)" = "true" ] \
            && case "$(json_str "$sj" time_source)" in gps*|ntp|rtc) true ;; *) false ;; esac; then
            d=$(json_str "$sj" started_utc \
                | sed -En 's/^([0-9]{4})([0-9]{2})([0-9]{2})T.*/\1-\2-\3/p')
            [ -n "$d" ] && datepart=$d
        fi

        prefix="raw/$datepart/$unit/$sname"
        [ -f "$sdir/SHA256SUMS" ] || continue
        awk -v p="$prefix" -v d="$sdir" \
            '{h=$1; sub(/^[0-9a-f]+  /,""); print p"/"$0"\t"h"\t"d"/"$0}' \
            "$sdir/SHA256SUMS" >> "$out"
        printf '%s/SHA256SUMS\t%s\t%s\n' "$prefix" \
            "$(shasum -a 256 "$sdir/SHA256SUMS" | awk '{print $1}')" \
            "$sdir/SHA256SUMS" >> "$out"
    done

    for ldir in "$ARCHIVE"/logs/*/; do
        [ -d "$ldir" ] || continue
        ldir=${ldir%/}
        lname=$(basename "$ldir")
        [ -f "$ldir/SHA256SUMS" ] || continue
        awk -v p="logs/$lname" -v d="$ldir" \
            '{h=$1; sub(/^[0-9a-f]+  /,""); print p"/"$0"\t"h"\t"d"/"$0}' \
            "$ldir/SHA256SUMS" >> "$out"
        printf '%s/SHA256SUMS\t%s\t%s\n' "logs/$lname" \
            "$(shasum -a 256 "$ldir/SHA256SUMS" | awk '{print $1}')" \
            "$ldir/SHA256SUMS" >> "$out"
    done

    sort -o "$out" "$out"
}

# How many session directories the archive holds, sealed or not - the number
# the run summaries report as "scanned".
umik_count_sessions() {
    local sdir n=0
    for sdir in "$ARCHIVE"/recordings/*/*/; do
        [ -d "$sdir" ] && n=$((n + 1))
    done
    echo "$n"
}
