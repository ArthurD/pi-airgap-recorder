#!/bin/bash
# umik-recover.sh - pull the whole recordings archive out of S3 onto this
# computer, and check every file against its fingerprint, with one command.
#
# Why this exists: the recordings live in a single S3 bucket that cannot be
# altered or deleted (Object Lock, compliance mode). That protects the bytes
# for years, but it does nothing for the person who one day has to GET them
# back - who may never have used AWS, may be working from a printed sheet of
# paper, and will not have a copy of this repository. So this is deliberately
# ONE self-contained file with no local dependencies: copy it onto any Mac or
# Linux machine, install the AWS command line tool, paste in the read-only key
# from the printed instructions, and run it. It needs nothing else.
#
# What it does, in order:
#   1. INVENTORY  list what the bucket holds and write it to inventory.tsv
#   2. DISK       stop before starting if this computer has no room
#   3. RESTORE    if files have aged into Glacier or Deep Archive storage, ask
#                 Amazon to bring them back, then stop and say "come back
#                 later" - that retrieval takes hours and cannot be hurried
#   4. DOWNLOAD   copy everything down; resumable, so re-running is safe
#   5. VERIFY     every session folder carries a SHA256SUMS fingerprint file
#                 sealing its audio; check every one of them
#
# This script only READS the bucket. The one request it sends that is not a
# read is the Glacier restore request, which makes an archived file readable
# again and changes nothing about its contents. It never writes to the bucket,
# and it never deletes anything - there or on this computer.
#
# Written for the oldest bash that ships on macOS (3.2), so: no associative
# arrays, no mapfile, no fancy string operators. Needs only bash, the AWS CLI,
# and standard command line tools. jq is NOT required.
#
# Exit codes:
#   0  everything downloaded and every fingerprint matched
#   1  something needs a human
#   2  Amazon is still retrieving archived files; run the same command again
#      later and it will carry on

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

say()  { echo "==> $*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
umik-recover.sh - download the whole recordings archive and check every file

Usage:
  umik-recover.sh [options]

Options:
  --bucket NAME     the S3 bucket holding the recordings (see your printed
                    instructions). Also read from UMIK_S3_BUCKET, or from
                    tools/umik.local.conf if you are running this from a
                    checkout of the project. If none of those is set, you
                    will be asked for it.
  --profile NAME    use this AWS CLI profile instead of the default one
  --dest DIR        where to put the files (default: $HOME/UMIK-Recordings)
  --prefix PATH     only this part of the archive, e.g. raw/2026-09-17
                    (default: everything)
  --list-only       show what is in the archive, download nothing
  --restore-only    ask Amazon to bring archived files back, then stop
  --yes             do not ask for confirmation before downloading
  -h, --help        this text

What happens:
  1. it lists the archive and writes an inventory file
  2. it checks this computer has enough free space
  3. if any files are in long-term storage it asks Amazon for them, and tells
     you to come back later
  4. it downloads everything (safe to re-run; it picks up where it left off)
  5. it checks every file against the fingerprint stored alongside it

This only reads the archive. It never changes or deletes anything.

Exit status: 0 all good, 1 a problem to look at, 2 still waiting on Amazon.
EOF
}

# --- options -----------------------------------------------------------------

ARG_BUCKET=""; ARG_PROFILE=""; DEST=""; PREFIX=""
LIST_ONLY=0; RESTORE_ONLY=0; ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --bucket)  ARG_BUCKET="${2:-}";  shift 2 || die "--bucket needs a name" ;;
        --profile) ARG_PROFILE="${2:-}"; shift 2 || die "--profile needs a name" ;;
        --dest)    DEST="${2:-}";        shift 2 || die "--dest needs a directory" ;;
        --prefix)  PREFIX="${2:-}";      shift 2 || die "--prefix needs a path" ;;
        --list-only)    LIST_ONLY=1;   shift ;;
        --restore-only) RESTORE_ONLY=1; shift ;;
        --yes|-y)       ASSUME_YES=1;  shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; echo "try: $0 --help" >&2; exit 2 ;;
    esac
done

# Bucket and profile: the command line wins, then the environment, then the
# project's untracked local config if this happens to be a checkout, then we
# ask. There is deliberately no bucket name written into this file - the
# project is public, and a bucket name does not belong in it.
_ENV_BUCKET=${UMIK_S3_BUCKET-}; _ENV_PROFILE=${UMIK_AWS_PROFILE-}
CONF="${UMIK_CONF:-$SCRIPT_DIR/../umik.local.conf}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
BUCKET="${ARG_BUCKET:-${_ENV_BUCKET:-${UMIK_S3_BUCKET:-}}}"
PROFILE="${ARG_PROFILE:-${_ENV_PROFILE:-${UMIK_AWS_PROFILE:-}}}"
DEST="${DEST:-$HOME/UMIK-Recordings}"

# Leading and trailing slashes on a prefix are the easiest way to end up with
# an empty download, so they are trimmed here once rather than guessed at later.
while [ "${PREFIX#/}" != "$PREFIX" ]; do PREFIX=${PREFIX#/}; done
while [ "${PREFIX%/}" != "$PREFIX" ]; do PREFIX=${PREFIX%/}; done

# Let the AWS tool itself wait out a slow or flaky network rather than making
# this look like a failure.
export AWS_RETRY_MODE=adaptive
export AWS_MAX_ATTEMPTS="${UMIK_MAX_ATTEMPTS:-10}"

PRICE_PER_GB=0.09   # Amazon's charge for sending data out, per GB, one time
RESTORE_DAYS=30     # how long a restored archive file stays readable
JOBS=8

# --- the AWS tool, and whether it can talk to the archive ---------------------

# One wrapper so the profile (if there is one) is applied everywhere without
# every call having to think about it.
awsx() {
    if [ -n "$PROFILE" ]; then
        aws --profile "$PROFILE" "$@"
    else
        aws "$@"
    fi
}
export -f awsx

if ! command -v aws >/dev/null 2>&1; then
    cat >&2 <<'EOF'
FATAL: the AWS command line tool is not installed on this computer.

It is free, and it is the only thing you need to install.

  On a Mac, either:
      brew install awscli
    or download and double-click the official installer:
      https://awscli.amazonaws.com/AWSCLIV2.pkg

  On Linux:
      curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
      unzip awscliv2.zip
      sudo ./aws/install

Then close this window, open a new one, and run this command again.
EOF
    exit 1
fi

if ! awsx sts get-caller-identity >/dev/null 2>&1; then
    cat >&2 <<'EOF'
FATAL: Amazon did not accept the login details on this computer.

This usually just means the access key has not been entered yet. To enter it:

  1. Run this command:        aws configure
  2. It asks four questions. Answer them from your printed instructions:
       AWS Access Key ID      - the line labelled ACCESS_KEY_ID
       AWS Secret Access Key  - the line labelled SECRET_ACCESS_KEY
       Default region name    - type:  us-east-1
       Default output format  - press Enter to skip
  3. Run this same recovery command again.

Nothing you type is sent anywhere except to Amazon, and the key you were given
can only read the recordings. It cannot change or delete them.
EOF
    exit 1
fi

# Fingerprint checker: Linux calls it sha256sum, macOS calls it shasum.
if command -v sha256sum >/dev/null 2>&1; then
    SUMCMD=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    SUMCMD=shasum
else
    die "no sha256sum or shasum on this computer - cannot check fingerprints"
fi

check_sums() { # run inside a session folder; reads ./SHA256SUMS
    if [ "$SUMCMD" = sha256sum ]; then
        sha256sum -c --quiet SHA256SUMS
    else
        shasum -a 256 -c --quiet SHA256SUMS
    fi
}

if [ -z "$BUCKET" ]; then
    printf 'Bucket name (printed in your instructions): '
    read -r BUCKET
fi
[ -n "$BUCKET" ] || die "no bucket name given, so there is nothing to download"

mkdir -p "$DEST" || die "cannot create $DEST"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/umik-recover.XXXXXX") || die "cannot make a scratch directory"
trap 'rm -rf "$WORK"' EXIT

# --- 1. inventory ------------------------------------------------------------
# list-objects-v2 pages through the whole bucket by itself; --query keeps the
# answer to three columns so nothing here needs jq.

INV="$DEST/inventory.tsv"
say "reading the list of files in s3://$BUCKET${PREFIX:+/$PREFIX}"

list_bucket() {
    if [ -n "$PREFIX" ]; then
        awsx s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX/" \
            --query 'Contents[].[StorageClass,Size,Key]' --output text
    else
        awsx s3api list-objects-v2 --bucket "$BUCKET" \
            --query 'Contents[].[StorageClass,Size,Key]' --output text
    fi
}

if ! list_bucket > "$WORK/raw-list" 2>"$WORK/list.err"; then
    echo "FATAL: could not read the archive. Amazon said:" >&2
    sed 's/^/    /' "$WORK/list.err" >&2
    echo "If this says Access Denied, the key may be for a different bucket." >&2
    exit 1
fi

# An object with no storage class reported is ordinary standard storage.
awk -F'\t' 'NF >= 3 && $3 != "" && $3 != "None" {
        sc = ($1 == "" || $1 == "None") ? "STANDARD" : $1
        print sc "\t" $2 "\t" $3
    }' "$WORK/raw-list" > "$INV"

OBJECTS=$(wc -l < "$INV" | tr -d ' ')
[ "$OBJECTS" -gt 0 ] || die "the archive looks empty at s3://$BUCKET${PREFIX:+/$PREFIX} - check the bucket name (and the --prefix, if you used one)"

BYTES=$(awk -F'\t' '{t += $2} END {printf "%.0f", t + 0}' "$INV")
GB=$(awk -v b="$BYTES" 'BEGIN {printf "%.1f", b / 1000000000}')
COST=$(awk -v b="$BYTES" -v p="$PRICE_PER_GB" 'BEGIN {printf "%.2f", (b / 1000000000) * p}')
SESSIONS=$(awk -F'\t' '$3 ~ /\/SHA256SUMS$/ {n++} END {print n + 0}' "$INV")
FIRST_DAY=$(awk -F'\t' '$3 ~ /^raw\/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\// {split($3, a, "/"); print a[2]}' "$INV" | sort -u | head -1)
LAST_DAY=$(awk -F'\t' '$3 ~ /^raw\/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\// {split($3, a, "/"); print a[2]}' "$INV" | sort -u | tail -1)

echo
say "the archive holds:"
say "  files              : $OBJECTS"
say "  total size         : $GB GB"
say "  recording sessions : $SESSIONS"
[ -n "$FIRST_DAY" ] && say "  earliest recording : $FIRST_DAY"
[ -n "$LAST_DAY" ]  && say "  latest recording   : $LAST_DAY"
say "  storage types      :"
awk -F'\t' '{c[$1]++} END {for (k in c) printf "        %-22s %s\n", k, c[k]}' "$INV" | sort
say "the full list was written to $INV"
say "downloading all of it costs about \$$COST at Amazon's \$$PRICE_PER_GB per GB."
say "that is a one-time charge; once the files are on this computer they are yours."
echo

if [ "$LIST_ONLY" -eq 1 ]; then
    say "--list-only: nothing was downloaded."
    exit 0
fi

# --- 2. room on this computer ------------------------------------------------

AVAIL_KB=$(df -Pk "$DEST" 2>/dev/null | awk 'NR == 2 {print $4}')
if [ -n "$AVAIL_KB" ]; then
    AVAIL_GB=$(awk -v k="$AVAIL_KB" 'BEGIN {printf "%.1f", k * 1024 / 1000000000}')
    if awk -v k="$AVAIL_KB" -v b="$BYTES" 'BEGIN {exit !(k * 1024 < b)}'; then
        echo "FATAL: not enough free space on this computer." >&2
        echo "       the recordings need $GB GB, and $DEST has $AVAIL_GB GB free." >&2
        echo "       plug in a bigger drive and re-run with:  $0 --dest /path/on/that/drive" >&2
        exit 1
    fi
    say "space check: $GB GB needed, $AVAIL_GB GB free at $DEST - fine"
else
    say "space check: could not read the free space at $DEST; carrying on"
fi

# --- 3. files in long-term storage -------------------------------------------
# GLACIER and DEEP_ARCHIVE have to be brought back before they can be read, and
# that takes hours. GLACIER_IR (instant retrieval), STANDARD, STANDARD_IA and
# INTELLIGENT_TIERING can all be downloaded as they are.

awk -F'\t' '$1 == "GLACIER" || $1 == "DEEP_ARCHIVE" {print $3}' "$INV" > "$WORK/archived"
ARCHIVED=$(wc -l < "$WORK/archived" | tr -d ' ')
HAS_DEEP=$(awk -F'\t' '$1 == "DEEP_ARCHIVE" {n++} END {print n + 0}' "$INV")

restore_line() { # <line number in $WORK/archived>
    # The key is looked up by line number rather than passed in, because some
    # versions of xargs truncate a long substituted argument.
    local key out
    key=$(sed -n "${1}p" "$WORK/archived")
    [ -n "$key" ] || return 0
    if out=$(awsx s3api restore-object --bucket "$BUCKET" --key "$key" \
             --restore-request "Days=$RESTORE_DAYS,GlacierJobParameters={Tier=Bulk}" 2>&1); then
        printf 'ASKED\t%s\n' "$key"
        return 0
    fi
    case "$out" in
        # Already being fetched, or already fetched - both are good news.
        *RestoreAlreadyInProgress*) printf 'ASKED\t%s\n' "$key" ;;
        *) printf 'PROBLEM\t%s\t%s\n' "$key" "$(echo "$out" | tr '\n' ' ')" ;;
    esac
    return 0
}
export -f restore_line
export BUCKET PROFILE WORK RESTORE_DAYS

if [ "$ARCHIVED" -gt 0 ]; then
    say "$ARCHIVED file(s) are in Amazon's long-term storage and have to be fetched first"
    seq 1 "$ARCHIVED" | xargs -P "$JOBS" -I{} bash -c 'restore_line "$@"' _ {} > "$WORK/restore.out"
    problems=$(grep -c '^PROBLEM	' "$WORK/restore.out" || true)
    if [ "$problems" -gt 0 ]; then
        echo "!! Amazon refused $problems of the fetch requests:" >&2
        grep '^PROBLEM	' "$WORK/restore.out" | head -10 | cut -f2,3 | sed 's/^/   /' >&2
    fi
    say "fetch requested for $ARCHIVED file(s); they stay readable for $RESTORE_DAYS days"

    # Are they back yet? A sample is enough to tell, and costs nothing.
    head -25 "$WORK/archived" > "$WORK/sample"
    ready=0; waiting=0
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        state=$(awsx s3api head-object --bucket "$BUCKET" --key "$key" \
                --query 'Restore' --output text 2>/dev/null)
        case "$state" in
            *'ongoing-request="false"'*) ready=$((ready + 1)) ;;
            *)                           waiting=$((waiting + 1)) ;;
        esac
    done < "$WORK/sample"

    if [ "$RESTORE_ONLY" -eq 1 ]; then
        say "--restore-only: the fetch has been requested; nothing was downloaded."
        exit 0
    fi

    if [ "$waiting" -gt 0 ]; then
        echo
        say "Amazon is retrieving $ARCHIVED archived file(s) for you."
        if [ "$HAS_DEEP" -gt 0 ]; then
            say "This takes up to 48 hours (Deep Archive storage)."
        else
            say "This takes up to 12 hours (Glacier storage)."
        fi
        say "There is nothing to do in the meantime. Leave everything alone and run"
        say "the exact same command again tomorrow; it will pick up where it left off."
        exit 2
    fi
    say "all sampled files are back from long-term storage - carrying on"
elif [ "$RESTORE_ONLY" -eq 1 ]; then
    say "--restore-only: nothing is in long-term storage, so there is nothing to fetch."
    exit 0
fi

# --- 4. download -------------------------------------------------------------

if [ "$ASSUME_YES" -ne 1 ]; then
    echo
    say "about to download $OBJECTS file(s), $GB GB, into $DEST"
    say "Amazon will charge roughly \$$COST for sending it, once."
    printf 'Continue? [y/N] '
    read -r answer
    case "$answer" in
        y|Y|yes|YES|Yes) ;;
        *) say "stopped at your request; nothing was downloaded."; exit 0 ;;
    esac
fi

if [ -n "$PREFIX" ]; then
    SRC="s3://$BUCKET/$PREFIX"
    DST="$DEST/$PREFIX"
else
    SRC="s3://$BUCKET"
    DST="$DEST"
fi
mkdir -p "$DST" || die "cannot create $DST"

say "downloading into $DST - this can take hours, and it is safe to stop and"
say "re-run the same command later: it only fetches what is still missing."
awsx s3 sync "$SRC" "$DST" --force-glacier-transfer --no-progress
sync_rc=$?
if [ "$sync_rc" -ne 0 ]; then
    echo "!! the download did not finish cleanly (code $sync_rc)." >&2
    echo "   run the exact same command again - it will carry on from where it stopped." >&2
    exit 1
fi
say "download finished"

# --- 5. check every fingerprint ----------------------------------------------
# Each session folder was sealed at the moment it was recorded: SHA256SUMS
# holds one fingerprint per audio file. If a file matches its fingerprint, it
# is byte for byte the file that was recorded.

echo
say "checking every file against its fingerprint - this reads every byte, so it"
say "takes a while"

find "$DEST" -name SHA256SUMS -type f -print > "$WORK/seals" 2>/dev/null
SEALS=$(wc -l < "$WORK/seals" | tr -d ' ')
ok=0; bad=0
: > "$WORK/failures"

while IFS= read -r seal; do
    [ -n "$seal" ] || continue
    folder=$(dirname "$seal")
    if ( cd "$folder" && check_sums ) > "$WORK/check.out" 2>&1; then
        ok=$((ok + 1))
    else
        bad=$((bad + 1))
        { echo "$folder"; sed 's/^/    /' "$WORK/check.out"; } >> "$WORK/failures"
    fi
done < "$WORK/seals"

echo
say "session folders checked : $SEALS"
say "matched perfectly       : $ok"
say "did NOT match           : $bad"

if [ "$bad" -gt 0 ]; then
    echo
    echo "!! these folders did not match their fingerprints:" >&2
    head -100 "$WORK/failures" >&2
    echo >&2
    echo "This usually means the download was interrupted. Run the exact same" >&2
    echo "command again - it will re-fetch what is incomplete. Do not remove" >&2
    echo "anything; nothing here is wasted." >&2
    exit 1
fi

if [ "$SEALS" -eq 0 ]; then
    echo
    echo "!! no fingerprint files were found under $DEST, so nothing could be" >&2
    echo "   checked. The files may still be fine, but this cannot prove it." >&2
    exit 1
fi

echo
say "Everything downloaded and every file's fingerprint matches."
say "Your copy is at $DEST."
say "The archive in the cloud was not changed in any way."
exit 0
