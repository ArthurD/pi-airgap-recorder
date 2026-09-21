#!/bin/bash
# create-recovery-user.sh - mint the read-only AWS identity that whoever
# inherits this archive will use to get the recordings back out.
#
# Why this exists: the recordings are safe from deletion (Object Lock in
# compliance mode) but that is only half of "archived". The other half is that
# somebody who is not me can still READ them, years from now, without my
# password, without my phone, and without touching anything that could put the
# archive at risk. That identity has to be created while I am here to create
# it, written down on paper, and proven to work - which is what this does.
#
# It creates an IAM user that can list, read and un-archive objects in the one
# bucket, is explicitly DENIED every write and delete action, and holds no
# other permission on the account at all. Then it proves both halves for real:
# it uses the new key to read the bucket, and it uses the new key to attempt a
# write, which must be refused. A self-test that only checks the happy path
# would happily hand out a key that could overwrite the archive.
#
# Run it ONCE, with an admin session live. It is safe to re-run: every step
# checks before it creates, so a second run reports what already exists rather
# than making a second user, a second policy or a second access key.
#
#   ./tools/recovery/create-recovery-user.sh
#   ./tools/recovery/create-recovery-user.sh --profile admin --user umik-recovery
#
# The bucket name comes from UMIK_S3_BUCKET or tools/umik.local.conf, never
# from this file - the project is public.
#
# Output: $OUT/umik-recovery-credentials.txt, mode 600, in the labelled form
# the printed-instructions builder reads. The secret is written to that file
# and is never echoed to the terminal.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

say() { echo "==> $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: create-recovery-user.sh [--profile P] [--user NAME] [--out DIR] [--force]

  --profile P   AWS CLI profile with admin rights (default: admin)
  --user NAME   IAM user to create (default: umik-recovery)
  --out DIR     where to write the credentials file
                (default: $HOME/UMIK-Archive/recovery)
  --force       overwrite an existing credentials file
EOF
}

PROFILE="${UMIK_ADMIN_PROFILE:-admin}"
IAM_USER="umik-recovery"
OUT=""
FORCE=0
POLICY_NAME="umik-recovery-readonly"
REGION="${UMIK_AWS_REGION:-us-east-1}"

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:-}";  shift 2 || die "--profile needs a name" ;;
        --user)    IAM_USER="${2:-}"; shift 2 || die "--user needs a name" ;;
        --out)     OUT="${2:-}";      shift 2 || die "--out needs a directory" ;;
        --force)   FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

OUT="${OUT:-$HOME/UMIK-Archive/recovery}"
CREDS="$OUT/umik-recovery-credentials.txt"

# Same precedence as the rest of the tools: environment, then the untracked
# local config, then nothing (which is an error - no bucket ships in a public
# repo).
_ENV_BUCKET=${UMIK_S3_BUCKET-}
CONF="${UMIK_CONF:-$SCRIPT_DIR/../umik.local.conf}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
BUCKET="${_ENV_BUCKET:-${UMIK_S3_BUCKET:-}}"

export AWS_RETRY_MODE=adaptive
export AWS_MAX_ATTEMPTS="${UMIK_MAX_ATTEMPTS:-10}"

command -v aws >/dev/null 2>&1 || die "aws CLI not found - install it with: brew install awscli"
command -v openssl >/dev/null 2>&1 || die "openssl not found - it is needed to generate the console password"
[ -n "$BUCKET" ] || die "no S3 bucket configured - set UMIK_S3_BUCKET, or put it in
       $CONF (see tools/umik.local.conf.example)"

if ! aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1; then
    echo "FATAL: the '$PROFILE' admin session is not live." >&2
    echo "       run this first, then try again:" >&2
    echo "           aws login --profile $PROFILE" >&2
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query 'Account' --output text)
[ -n "$ACCOUNT_ID" ] || die "could not read the account id"
CALLER=$(aws sts get-caller-identity --profile "$PROFILE" --query 'Arn' --output text)
say "admin session: $CALLER (account $ACCOUNT_ID)"
say "bucket: $BUCKET"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/umik-recovery-user.XXXXXX") || die "cannot make a scratch directory"
trap 'rm -rf "$WORK"' EXIT

# --- 1. the user -------------------------------------------------------------

if aws iam get-user --user-name "$IAM_USER" --profile "$PROFILE" >/dev/null 2>&1; then
    say "IAM user $IAM_USER already exists - leaving it alone"
else
    aws iam create-user --user-name "$IAM_USER" \
        --tags Key=Purpose,Value=recovery \
        --profile "$PROFILE" >/dev/null \
        || die "could not create IAM user $IAM_USER"
    say "created IAM user $IAM_USER"
fi

# --- 2. the policy -----------------------------------------------------------
# Inline, not managed: it belongs to this user and disappears with them, and
# there is no chance of it drifting onto anything else. The Deny is the
# important half - an Allow list can be widened by a future managed policy,
# but an explicit Deny cannot be overridden by anything.

cat > "$WORK/policy.json" <<EOF
{ "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ReadTheArchive", "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:ListBucketVersions","s3:GetBucketLocation","s3:GetObject","s3:GetObjectVersion","s3:GetObjectAttributes","s3:GetObjectRetention","s3:RestoreObject"],
      "Resource": ["arn:aws:s3:::$BUCKET","arn:aws:s3:::$BUCKET/*"] },
    { "Sid": "SeeBucketListInConsole", "Effect": "Allow",
      "Action": ["s3:ListAllMyBuckets"], "Resource": "*" },
    { "Sid": "NeverWriteOrDelete", "Effect": "Deny",
      "Action": ["s3:PutObject","s3:DeleteObject","s3:DeleteObjectVersion","s3:PutObjectRetention","s3:PutObjectLegalHold","s3:BypassGovernanceRetention","s3:PutLifecycleConfiguration","s3:PutBucketVersioning","s3:PutBucketObjectLockConfiguration","s3:DeleteBucket"],
      "Resource": ["arn:aws:s3:::$BUCKET","arn:aws:s3:::$BUCKET/*"] }
  ] }
EOF

aws iam put-user-policy --user-name "$IAM_USER" --policy-name "$POLICY_NAME" \
    --policy-document "file://$WORK/policy.json" --profile "$PROFILE" \
    || die "could not attach the read-only policy"
say "policy $POLICY_NAME written (read $BUCKET, deny every write and delete)"

# --- 3. console password -----------------------------------------------------
# The heir may never touch a command line. A console login lets them click
# through the bucket and download a file or two by hand.

CONSOLE_URL="https://$ACCOUNT_ID.signin.aws.amazon.com/console"
CONSOLE_PASSWORD=""
if aws iam get-login-profile --user-name "$IAM_USER" --profile "$PROFILE" >/dev/null 2>&1; then
    say "(console password already set; delete the login profile to rotate)"
else
    # Generated here, never sent anywhere but to IAM, and written only to the
    # 600-mode credentials file. The suffix guarantees a digit and a symbol so
    # the account password policy cannot reject it.
    gen=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)
    CONSOLE_PASSWORD="${gen}-7"
    if aws iam create-login-profile --user-name "$IAM_USER" \
        --password "$CONSOLE_PASSWORD" --no-password-reset-required \
        --profile "$PROFILE" >/dev/null 2>"$WORK/login.err"; then
        say "created a console password for $IAM_USER"
    else
        CONSOLE_PASSWORD=""
        echo "!! could not create the console login profile:" >&2
        sed 's/^/   /' "$WORK/login.err" >&2
        echo "   carrying on - the access key below is what actually matters." >&2
    fi
fi

# --- 4. access key -----------------------------------------------------------
# AWS shows a secret exactly once, at creation. So if the user already holds a
# key, this cannot recover its secret and must not quietly mint a second one -
# two live keys for one heir is two things to leak.

AKID=""; SECRET=""
existing=$(aws iam list-access-keys --user-name "$IAM_USER" \
           --query 'AccessKeyMetadata[].AccessKeyId' --output text --profile "$PROFILE" 2>/dev/null)
case "$existing" in None) existing="" ;; esac
if [ -n "$existing" ]; then
    say "$IAM_USER already has access key(s): $existing"
    say "not creating another one. AWS only ever shows a secret once, so if the"
    say "secret for that key is lost, delete the key in the IAM console and re-run this."
else
    keypair=$(aws iam create-access-key --user-name "$IAM_USER" \
              --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text \
              --profile "$PROFILE") || die "could not create an access key"
    AKID=$(printf '%s' "$keypair" | awk '{print $1}')
    SECRET=$(printf '%s' "$keypair" | awk '{print $2}')
    [ -n "$AKID" ] && [ -n "$SECRET" ] || die "access key came back incomplete"
    say "created access key $AKID"
fi

# --- 5. the credentials file -------------------------------------------------

mkdir -p "$OUT" || die "cannot create $OUT"
chmod 700 "$OUT"

if [ -f "$CREDS" ] && [ "$FORCE" -ne 1 ]; then
    say "$CREDS already exists - left untouched (use --force to overwrite)"
elif [ -z "$AKID" ]; then
    say "no new access key was created, so no credentials file was written."
    say "delete the existing key in the IAM console and re-run to get a fresh one."
else
    umask 077
    cat > "$CREDS" <<EOF
These are the login details for reading the audio archive. Keep this page
safe: anyone holding it can download the recordings. Nobody holding it can
change or delete them - this login is read-only, and the archive itself is
locked against deletion.

To download everything, install the AWS command line tool, run "aws configure"
and paste in ACCESS_KEY_ID and SECRET_ACCESS_KEY below with region us-east-1,
then run umik-recover.sh. To just look around, open CONSOLE_URL in a browser
and sign in with USERNAME and CONSOLE_PASSWORD.

ACCOUNT_ID=$ACCOUNT_ID
CONSOLE_URL=$CONSOLE_URL
USERNAME=$IAM_USER
CONSOLE_PASSWORD=${CONSOLE_PASSWORD:-(already set previously - not recoverable)}
ACCESS_KEY_ID=$AKID
SECRET_ACCESS_KEY=$SECRET
BUCKET=$BUCKET
REGION=$REGION
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    chmod 600 "$CREDS"
    say "written to $CREDS; secret is NOT echoed here"
fi

# --- 6. prove it, with the new key -------------------------------------------
# Using the admin profile here would prove nothing about the key that is being
# handed over. Both directions are tested: it can read, and it cannot write.

if [ -z "$AKID" ]; then
    say "no new key to self-test (an access key already existed)"
    say "done."
    exit 0
fi

# A brand-new key takes a few seconds to become usable everywhere.
key_aws() {
    env -u AWS_PROFILE -u AWS_SESSION_TOKEN \
        AWS_ACCESS_KEY_ID="$AKID" AWS_SECRET_ACCESS_KEY="$SECRET" \
        AWS_DEFAULT_REGION="$REGION" aws "$@"
}

say "self-test: waiting for the new key to become active"
ok=0
for attempt in 1 2 3 4 5; do
    if key_aws sts get-caller-identity >/dev/null 2>&1; then ok=1; break; fi
    say "  not active yet (attempt $attempt of 5)"
    sleep 3
done
[ "$ok" -eq 1 ] || die "the new key never became usable - check it in the IAM console"

who=$(key_aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)
say "self-test: the key signs in as ${who:-(arn not returned; carrying on)}"

if key_aws s3api list-objects-v2 --bucket "$BUCKET" --max-keys 1 >/dev/null 2>"$WORK/read.err"; then
    say "self-test: the key CAN read s3://$BUCKET - good"
else
    echo "!! self-test: the key could NOT read the bucket:" >&2
    sed 's/^/   /' "$WORK/read.err" >&2
    exit 1
fi

# The bucket carries Object Lock, so even a successful write would be an
# undeletable object - which is exactly why the Deny has to stop it first.
# (--body must be a real file; the CLI rejects /dev/null before sending anything.)
: > "$WORK/empty"
if key_aws s3api put-object --bucket "$BUCKET" --key recovery-selftest/should-fail \
       --body "$WORK/empty" >/dev/null 2>"$WORK/write.err"; then
    echo >&2
    echo "!! !! THE RECOVERY KEY WAS ABLE TO WRITE TO THE BUCKET. !!" >&2
    echo "!! The Deny statement is not working. This key must not be handed out." >&2
    echo "!! Delete it now:  aws iam delete-access-key --user-name $IAM_USER --access-key-id $AKID --profile $PROFILE" >&2
    echo "!! Note the bucket has Object Lock, so the test object it just wrote" >&2
    echo "!! (recovery-selftest/should-fail) cannot be removed." >&2
    exit 1
fi
if grep -qiE 'AccessDenied|explicit deny|not authorized' "$WORK/write.err"; then
    say "self-test: the key CANNOT write to s3://$BUCKET - good"
else
    echo "!! self-test: the write was refused, but not with AccessDenied:" >&2
    sed 's/^/   /' "$WORK/write.err" >&2
    echo "   nothing was written, but check the policy by hand before handing this out." >&2
fi

echo
say "done. $IAM_USER can read s3://$BUCKET and nothing else."
say "next: build the printed instructions with the key embedded, and put the"
say "paper somewhere the right person will find it:"
say "    $SCRIPT_DIR/build-pdf.sh --credentials $CREDS"
exit 0
