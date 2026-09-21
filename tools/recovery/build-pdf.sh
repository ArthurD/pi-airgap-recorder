#!/bin/bash
# build-pdf.sh - render the "how to get the recordings back" instructions as a
# PDF for a non-technical successor.
#
# Why this exists: the archive is only useful to someone else if they can find
# it, log in, and download it without me. The instructions live as a template
# (instructions.md) with {{PLACEHOLDERS}}; this fills them from the live bucket
# (counts, size, date range, storage classes), the local config (bucket, NAS
# location, where the root login is kept), and optionally the credentials file
# written by create-recovery-user.sh, then renders Markdown -> HTML (pandoc) ->
# PDF (headless Chrome). The helper script umik-recover.sh is copied next to
# the PDF.
#
#   ./tools/recovery/build-pdf.sh                          # blanks on the credentials page
#   ./tools/recovery/build-pdf.sh --credentials ~/UMIK-Archive/recovery/umik-recovery-credentials.txt
#   ./tools/recovery/build-pdf.sh --offline                # skip the bucket inventory
#
# With --credentials the PDF CONTAINS the read-only key and console password:
# print it, store it with the will or in the safe, and treat it like a key.
# Without it the credentials page has blanks to fill in by hand.
#
# Config via env or tools/umik.local.conf: UMIK_S3_BUCKET, UMIK_AWS_PROFILE,
# UMIK_OWNER, UMIK_NAS_LOCATION, UMIK_ROOT_LOGIN_LOCATION, UMIK_REPO_URL.
# Output: ~/UMIK-Archive/recovery/UMIK-Recovery-Instructions.pdf (or --out DIR).

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOLS_DIR=$(dirname "$HERE")

_E_BUCKET=${UMIK_S3_BUCKET-}; _E_PROFILE=${UMIK_AWS_PROFILE-}; _E_OWNER=${UMIK_OWNER-}
_E_NAS=${UMIK_NAS_LOCATION-}; _E_ROOT=${UMIK_ROOT_LOGIN_LOCATION-}; _E_REPO=${UMIK_REPO_URL-}
CONF="${UMIK_CONF:-$TOOLS_DIR/umik.local.conf}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
BUCKET="${_E_BUCKET:-${UMIK_S3_BUCKET:-}}"
PROFILE="${_E_PROFILE:-${UMIK_AWS_PROFILE:-}}"
OWNER="${_E_OWNER:-${UMIK_OWNER:-$(git -C "$TOOLS_DIR" config user.name 2>/dev/null || echo "")}}"
NAS="${_E_NAS:-${UMIK_NAS_LOCATION:-}}"
ROOT_LOC="${_E_ROOT:-${UMIK_ROOT_LOGIN_LOCATION:-}}"
REPO="${_E_REPO:-${UMIK_REPO_URL:-$(git -C "$TOOLS_DIR" remote get-url origin 2>/dev/null | sed -E 's#git@github.com:#https://github.com/#; s#\.git$##')}}"

CREDS=""; OUT="$HOME/UMIK-Archive/recovery"; OFFLINE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --credentials) CREDS=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --offline) OFFLINE=1; shift ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
[ -n "$BUCKET" ] || die "UMIK_S3_BUCKET is not set (env or $CONF)"
command -v pandoc >/dev/null || die "pandoc not found (brew install pandoc)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || CHROME=$(command -v chromium || command -v google-chrome || true)
[ -n "$CHROME" ] || die "Google Chrome not found; it renders the PDF"
[ -f "$HERE/umik-recover.sh" ] || die "$HERE/umik-recover.sh missing"

mkdir -p "$OUT" && chmod 700 "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/umik-recovery-doc.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---- inventory: the numbers on page one come from the bucket, not from memory
OBJECT_COUNT="?"; WAV_COUNT="?"; TOTAL_GB="?"; SESSION_COUNT="?"; DATE_RANGE="?"; STORAGE_CLASSES="?"
if [ "$OFFLINE" = 0 ]; then
    echo "==> listing s3://$BUCKET (read-only)"
    aws s3api list-objects-v2 --bucket "$BUCKET" ${PROFILE:+--profile "$PROFILE"} \
        --query 'Contents[].[StorageClass,Size,Key]' --output text > "$WORK/inv.tsv" \
        || die "could not list the bucket; check credentials or use --offline"
    OBJECT_COUNT=$(wc -l < "$WORK/inv.tsv" | tr -d ' ')
    WAV_COUNT=$(grep -c '\.wav$' "$WORK/inv.tsv")
    TOTAL_GB=$(awk '{t+=$2} END {printf "%.0f", t/1e9}' "$WORK/inv.tsv")
    SESSION_COUNT=$(grep '/SHA256SUMS$' "$WORK/inv.tsv" | cut -f3 | xargs -n1 dirname | sort -u | wc -l | tr -d ' ')
    DATE_RANGE=$(cut -f3 "$WORK/inv.tsv" | grep -oE '^raw/[0-9]{4}-[0-9]{2}-[0-9]{2}' | cut -d/ -f2 | sort -u \
                 | awk 'NR==1{f=$0} {l=$0} END {print f " to " l " (plus undated sessions)"}')
    STORAGE_CLASSES=$(cut -f1 "$WORK/inv.tsv" | sort | uniq -c | awk '{printf "%s%s (%d)", (NR>1?", ":""), $2, $1}')
    echo "    $OBJECT_COUNT objects, $TOTAL_GB GB, $SESSION_COUNT sessions, $DATE_RANGE"
fi
MONTHLY_COST=$(awk -v g="$TOTAL_GB" 'BEGIN { if (g+0>0) printf "%.0f", g*0.023; else print "?" }')
EGRESS_COST=$(awk -v g="$TOTAL_GB" 'BEGIN { if (g+0>0) printf "%.0f", g*0.09; else print "?" }')
DISK_NEEDED_GB=$(awk -v g="$TOTAL_GB" 'BEGIN { if (g+0>0) printf "%.0f", g*1.1+10; else print "?" }')

# ---- credentials: from create-recovery-user.sh's file, or blanks to hand-write
ACCOUNT_ID=""; CONSOLE_URL=""; USERNAME=""; CONSOLE_PASSWORD=""; ACCESS_KEY_ID=""; SECRET_ACCESS_KEY=""; REGION="us-east-1"
if [ -n "$CREDS" ]; then
    [ -f "$CREDS" ] || die "credentials file not found: $CREDS"
    getv() { grep -E "^$1=" "$CREDS" | head -1 | cut -d= -f2- | sed 's/[[:space:]]*(.*)$//; s/^[[:space:]]*//; s/[[:space:]]*$//'; }
    ACCOUNT_ID=$(getv ACCOUNT_ID); CONSOLE_URL=$(getv CONSOLE_URL); USERNAME=$(getv USERNAME)
    CONSOLE_PASSWORD=$(getv CONSOLE_PASSWORD); ACCESS_KEY_ID=$(getv ACCESS_KEY_ID)
    SECRET_ACCESS_KEY=$(getv SECRET_ACCESS_KEY); REGION=$(getv REGION); REGION=${REGION:-us-east-1}
    [ -n "$SECRET_ACCESS_KEY" ] || die "no SECRET_ACCESS_KEY in $CREDS"
    echo "==> embedding credentials for user $USERNAME (the PDF will contain the secret)"
else
    echo "==> no --credentials: the credentials page will have blanks to fill in by hand"
fi
if [ -z "$ACCOUNT_ID" ] && [ "$OFFLINE" = 0 ]; then
    ACCOUNT_ID=$(aws sts get-caller-identity ${PROFILE:+--profile "$PROFILE"} --query Account --output text 2>/dev/null || true)
fi
# shellcheck disable=SC2089  # HTML in a variable, on purpose
BLANK='<span class="blank"></span>'
# Filled values are set in monospace so 0/O and 1/l are unambiguous on paper;
# missing ones become a line to write on.
mono_or_blank() { if [ -n "$1" ]; then printf '<code>%s</code>' "$1"; else printf '%s' "$BLANK"; fi; }
USERNAME=$(mono_or_blank "$USERNAME"); CONSOLE_PASSWORD=$(mono_or_blank "$CONSOLE_PASSWORD")
ACCESS_KEY_ID=$(mono_or_blank "$ACCESS_KEY_ID"); SECRET_ACCESS_KEY=$(mono_or_blank "$SECRET_ACCESS_KEY")
REGION="<code>$REGION</code>"
: "${ACCOUNT_ID:=$BLANK}"
[ -n "$CONSOLE_URL" ] || { case "$ACCOUNT_ID" in *span*) CONSOLE_URL="https://console.aws.amazon.com/ (then Account ID: $BLANK)";; *) CONSOLE_URL="https://$ACCOUNT_ID.signin.aws.amazon.com/console";; esac; }
[ -n "$NAS" ] || NAS="(no network-drive location was configured when this was printed; write it here: $BLANK)"
[ -n "$ROOT_LOC" ] || ROOT_LOC="$BLANK<br>$BLANK"

# ---- substitute
export BUILD_DATE; BUILD_DATE=$(date +"%B %-d, %Y")
export BUCKET_CODE="<code>$BUCKET</code>"
# shellcheck disable=SC2090  # some of these hold HTML on purpose
export OWNER BUCKET REGION REPO NAS ROOT_LOC OBJECT_COUNT WAV_COUNT TOTAL_GB SESSION_COUNT DATE_RANGE \
       STORAGE_CLASSES MONTHLY_COST EGRESS_COST DISK_NEEDED_GB ACCOUNT_ID CONSOLE_URL USERNAME \
       CONSOLE_PASSWORD ACCESS_KEY_ID SECRET_ACCESS_KEY
python3 - "$HERE/instructions.md" "$HERE/umik-recover.sh" "$WORK/doc.md" <<'PY'
import os, re, sys
src, script, out = sys.argv[1:4]
env = dict(os.environ)
env["REPO_URL"] = env.get("REPO", "")
env["NAS_LOCATION"] = env.get("NAS", "")
env["ROOT_LOGIN_LOCATION"] = env.get("ROOT_LOC", "")
env["SCRIPT"] = open(script).read().rstrip("\n")
text = open(src).read()
missing = set()
def sub(m):
    k = m.group(1)
    if k not in env: missing.add(k); return m.group(0)
    return env[k]
text = re.sub(r"\{\{([A-Z_]+)\}\}", sub, text)
open(out, "w").write(text)
if missing: sys.exit("unfilled placeholders: " + ", ".join(sorted(missing)))
PY
[ $? -eq 0 ] || die "placeholder substitution failed"

# ---- render
cat > "$WORK/style.css" <<'CSS'
@page { size: letter; margin: 0.9in 0.85in; }
html { font-size: 11.5pt; }
body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; line-height: 1.45;
       color: #111; max-width: 100%; margin: 0; }
header#title-block-header { border-bottom: 3px solid #111; margin-bottom: 1.4em; padding-bottom: .6em; }
h1.title { font-size: 26pt; margin: 0 0 .2em 0; line-height: 1.15; }
p.subtitle { font-size: 13pt; color: #444; margin: 0 0 .4em 0; }
p.author, p.date { margin: 0; color: #444; font-size: 10.5pt; }
h1 { font-size: 19pt; margin: 1.6em 0 .5em 0; padding-top: .3em; border-top: 1px solid #bbb; page-break-after: avoid; }
header + h1, h1:first-of-type { border-top: none; }
h2 { font-size: 13.5pt; margin: 1.2em 0 .4em 0; page-break-after: avoid; }
p, li { orphans: 3; widows: 3; }
ul, ol { padding-left: 1.4em; }
li { margin-bottom: .35em; }
code { font-family: Menlo, Consolas, "Courier New", monospace; font-size: 9.5pt; background: #f3f3f3;
       padding: 0 .25em; border-radius: 3px; }
pre { background: #f3f3f3; border: 1px solid #ddd; border-radius: 4px; padding: .7em .9em;
      font-size: 9pt; line-height: 1.35; white-space: pre-wrap; overflow-wrap: anywhere; page-break-inside: avoid; }
pre code { background: none; padding: 0; font-size: inherit; }
table { border-collapse: collapse; margin: .6em 0 1em 0; width: 100%; }
tr { page-break-inside: avoid; }
th, td { border: 1px solid #bbb; padding: .4em .6em; text-align: left; vertical-align: top; }
thead:empty, tr:first-child th:empty { display: none; }
td:first-child { width: 32%; font-weight: 600; background: #fafafa; }
strong { font-weight: 700; }
a { color: #0b4f9c; text-decoration: none; }
.pagebreak { page-break-before: always; }
.blank { display: inline-block; min-width: 3.4in; border-bottom: 1px solid #333; height: 1.1em; vertical-align: bottom; }
CSS
pandoc "$WORK/doc.md" -f markdown -t html5 --standalone --embed-resources \
    --css "$WORK/style.css" --metadata pagetitle="UMIK Recovery Instructions" \
    -o "$WORK/doc.html" || die "pandoc failed"
PDF="$OUT/UMIK-Recovery-Instructions.pdf"
"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="$PDF" \
    "file://$WORK/doc.html" >/dev/null 2>&1 || die "Chrome failed to render the PDF"
cp "$HERE/umik-recover.sh" "$OUT/umik-recover.sh" && chmod 755 "$OUT/umik-recover.sh"
chmod 600 "$PDF"
PAGES=$(python3 -c "import re,sys; print(len(re.findall(rb'/Type\s*/Page[^s]', open(sys.argv[1],'rb').read())))" "$PDF" 2>/dev/null || echo "?")
echo "==> wrote $PDF ($PAGES pages)"
echo "==> copied umik-recover.sh beside it"
[ -n "$CREDS" ] && echo "==> this PDF contains live credentials; store it accordingly"
exit 0
