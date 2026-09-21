---
title: "The UMIK Recordings: How to Get Them Back"
subtitle: "Plain-language instructions for whoever needs to retrieve my audio archive"
author: "{{OWNER}}"
date: "Prepared {{BUILD_DATE}}"
---

# Read this first

If you are reading this, something has happened to me and you need to get at
my audio recordings. This document is written so that you can do it yourself,
without any special knowledge. Where a step is genuinely technical, it says so,
and the last pages contain everything a computer-literate friend or an IT
person would need to help you.

**The short version.** The recordings are safely stored in three places. The
most important copy lives in Amazon's cloud storage (a service called Amazon
S3), inside my Amazon Web Services account. You can look at them through a
website, download a few, or download all of them with one command. Nothing in
that storage can be deleted by anyone for at least five years, not even by
me, so there is no rush and nothing you can break.

**The one urgent thing.** The Amazon account has to keep being paid, or the
files will eventually be deleted. It costs roughly **${{MONTHLY_COST}} a month**.
See the section "Keeping the archive alive". Do that before anything
else if the payment card on the account may stop working.

## What is there

| | |
|---|---|
| Audio files | {{WAV_COUNT}} WAV files, each about 10 minutes long |
| Total size | about {{TOTAL_GB}} GB |
| Recording sessions | {{SESSION_COUNT}} |
| Dates | {{DATE_RANGE}} |
| Recorded by | two small standalone recorders, "umik1" and "umik2" |
| Where | Amazon S3 bucket **{{BUCKET}}** (account {{ACCOUNT_ID}}) |

## The three copies

1. **Amazon S3, in the cloud.** The master copy. Complete, verified, and
   locked against deletion. This document is mostly about getting at this one.
2. **The Synology at home.** {{NAS_LOCATION}} A quick-access copy of the same
   files on the network drive in the house. If you can get to the house and the
   drive is running, this is the fastest way to listen to anything.
3. **My Mac.** Holds only the "fingerprints" (checksums) and logs, **not** the
   audio. Do not expect to find recordings on it.

# What the recordings are and how they are named

Two small recorders ran continuously. Each time one was powered on it started a
new **session**, and each session was written as a series of 10-minute
**segments**. Every file is a plain WAV audio file. Any computer can play it:
double-click it, or open it in QuickTime, VLC, Windows Media Player, or iTunes.

Files are organised in folders like this:

```
raw / 2026-09-17 / umik2 / umik2_000015_20260917T101500Z / seg-20260917-101500.wav
      ^ date        ^ which   ^ session: unit, session      ^ one 10-minute piece,
        (UTC)         recorder   number, start time (UTC)      named by its start time
```

- **Dates and times are in UTC** (Greenwich time), not local time. Eastern
  time is 4 or 5 hours earlier, so a file stamped `T101500Z` was recorded at
  6:15 or 5:15 in the morning here.
- **`raw/undated/`** holds sessions where the recorder could not trust its own
  clock. The audio is fine; the date in the name is just not guaranteed.
  Inside each session folder a small file called `session.json` says what the
  recorder believed the time was.
- **`SHA256SUMS`** in each session folder is a list of fingerprints, one per
  audio file. It lets a computer prove that a file has not been altered since
  it was recorded. You can ignore it; the download command in this document
  uses it automatically.
- **`manifest/`** is the archive's own history log. You do not need it.

# Option 1: The copy at home (fastest)

The Synology network drive at the house holds a complete copy. On any computer
on the home network, open the drive in Finder (Mac) or File Explorer (Windows)
and look for the folder named in the table on the first page. The files are
organised exactly as described above. Copy whatever you want onto your own
computer or an external drive.

If the drive is gone, broken, or you cannot get to it, use Amazon instead. The
Amazon copy is the one that is guaranteed.

# Option 2: Browse and download a few files through the Amazon website

This is the way to go if you want to look around, or listen to a particular
day. It works in any web browser and needs nothing installed. It downloads one
file at a time, so it is not the way to fetch everything (that is Option 3).

1. In a web browser, go to **{{CONSOLE_URL}}**
2. Sign in with the **username** and **console password** from the
   credentials page at the end of this document. If the page asks for an
   "Account ID", it is **{{ACCOUNT_ID}}**. Choose "IAM user" if it asks what
   kind of user you are.
3. In the search box at the top of the page, type **S3** and click the "S3"
   result. You should see a list of "buckets" that includes
   **{{BUCKET}}**. Click it.
4. Click the folder **raw**, then a date, then a recorder (umik1 or umik2),
   then a session. You will see the 10-minute audio files listed with their
   sizes.
5. Tick the box next to a file and click **Download** near the top right. It
   lands in your Downloads folder like any other download. Each file is about
   85 MB.

If instead of downloading you see a message about the file being "archived" or
in "Glacier", read "If the files are in cold storage" below.

This login can only **read**. It cannot delete or change anything, so click
around freely.

# Option 3: Download everything with one command

This fetches the whole archive ({{TOTAL_GB}} GB) onto a computer of your own.
You need: a Mac or Windows PC, an internet connection, and a disk with at least
**{{DISK_NEEDED_GB}} GB** free (an external drive is fine). It will take hours,
possibly a day, on a home connection. It is safe to stop and start again; it
picks up where it left off.

Amazon charges for sending data out of its network, roughly **${{EGRESS_COST}}
one time** for the whole archive, billed to my account.

## Step 1: Install the Amazon command-line tool

- **Mac:** download and open <https://awscli.amazonaws.com/AWSCLIV2.pkg>, then
  click through the installer.
- **Windows:** download and run <https://awscli.amazonaws.com/AWSCLIV2.msi>.

## Step 2: Open a terminal window

- **Mac:** open the **Terminal** app (it is in Applications > Utilities, or
  search for it with the magnifying glass at the top right).
- **Windows:** press the Windows key, type **cmd**, and press Enter.

You will type the commands below into that window, one at a time, pressing
Enter after each.

## Step 3: Tell the tool who you are

```
aws configure
```

It asks four questions. Answer from the credentials page at the end:

```
AWS Access Key ID:      (the Access Key ID)
AWS Secret Access Key:  (the Secret Access Key)
Default region name:    us-east-1
Default output format:  (just press Enter)
```

## Step 4: Check that it works

```
aws s3 ls s3://{{BUCKET}}/raw/
```

You should see a list of dates. If you see an error instead, the most likely
cause is a typo in the key; run `aws configure` again.

## Step 5: Download everything

On a **Mac**:

```
aws s3 sync s3://{{BUCKET}} ~/UMIK-Recordings --force-glacier-transfer
```

On **Windows**:

```
aws s3 sync s3://{{BUCKET}} %USERPROFILE%\UMIK-Recordings --force-glacier-transfer
```

A folder called **UMIK-Recordings** appears in your home folder and fills up.
To put it on an external drive instead, replace `~/UMIK-Recordings` with a
folder on that drive, for example `/Volumes/MyDrive/UMIK-Recordings` on a Mac
or `E:\UMIK-Recordings` on Windows.

If the window closes or the computer sleeps, just run the same command again.
Files that are already complete are skipped.

## Step 6 (optional, Mac only): the helper script

A file called **`umik-recover.sh`** is stored alongside this document. It does
Steps 4 and 5 for you and then checks every file's fingerprint, and it handles
the cold-storage case below automatically. To use it, drag the file into a
Terminal window, type a space, then the bucket name, and press Enter:

```
/path/to/umik-recover.sh --bucket {{BUCKET}}
```

It explains what it is doing as it goes. A copy is printed at the very end of
this document in case the file is lost, but retyping it is a job for a
technical helper.

# If the files are in "cold storage"

To save money, I may at some point have moved the archive into Amazon's cheaper
"Glacier" storage tiers. If so, downloading takes one extra step. You will
know because the website shows files as **"Glacier Flexible Retrieval"** or
**"Glacier Deep Archive"**, or because a download fails with an error mentioning
**InvalidObjectState** or **Glacier**.

(A tier called "Glacier Instant Retrieval" does **not** need this step. Files in
it download normally.)

What to do: ask Amazon to bring the files back. Amazon then takes up to 12
hours (Flexible Retrieval) or up to 48 hours (Deep Archive), after which the
files download normally for the next 30 days.

- **Easiest:** run the helper script from Option 3, Step 6. It asks Amazon to
  restore everything, tells you to come back tomorrow, and finishes the job
  when you run it again.
- **By hand, one file at a time, on the website:** open the file in the S3
  website, click **Initiate restore**, choose **Bulk** retrieval and 30 days.
  This is fine for a handful of files.
- **By hand, for everything:** the command for a technical helper is in
  Appendix A.

Restoring is free at the Bulk speed. Faster speeds cost more; there is no
reason to use them.

# Keeping the archive alive {#alive}

**The files exist only as long as the Amazon account is paid.** If the payment
card on the account expires or is cancelled, Amazon sends warnings by email,
then suspends the account, and eventually closes it. About 90 days after
closure the data is gone for good. Object Lock (below) does not protect
against that.

- The cost is roughly **${{MONTHLY_COST}} a month** for storage, plus a one-time
  download charge (about ${{EGRESS_COST}}) if you fetch everything.
- The bill goes to the payment card on the account. To change the card or see
  invoices you need the account's **root** login, not the recovery login used
  above. See the credentials page for where that is kept.
- Amazon's billing emails go to the root email address for the account.
  Whoever is handling my email should watch for messages from
  `no-reply@amazon.com` or `aws-billing`.

**Nothing can be deleted, on purpose.** Every file is under "Object Lock" in
compliance mode: for five years after it was uploaded it cannot be deleted or
altered by anyone, including the account owner and Amazon support. If you or a
helper try to delete something and it fails, that is expected. Do not try to
"clean up" the bucket, and do not close the account to save money until you
have a copy you are happy with somewhere else.

**A simple long-term plan:** download everything once (Option 3), put it on two
external drives, keep them in two places, and only then decide whether to keep
paying Amazon.

# Getting help

Anyone comfortable with computers can do all of this from this document.
Appendix A gives them the exact details. If they want the full background, the
recorder software and its documentation live in a GitHub repository:
**{{REPO_URL}}**. The relevant sections there are "Recordings" and "S3 mirror".

<div class="pagebreak"></div>

# Credentials {#credentials}

**Keep this page private.** Anyone with it can read (but not change or delete)
every recording.

## Recovery login (read-only)

This login was created just for this document. It can list and download from
the bucket and nothing else.

| | |
|---|---|
| Sign-in page | {{CONSOLE_URL}} |
| Account ID | {{ACCOUNT_ID}} |
| Username | {{USERNAME}} |
| Console password | {{CONSOLE_PASSWORD}} |
| Access Key ID | {{ACCESS_KEY_ID}} |
| Secret Access Key | {{SECRET_ACCESS_KEY}} |
| Region | {{REGION}} |
| Bucket | {{BUCKET_CODE}} |

Type the key and secret exactly; they are case-sensitive. There are no spaces.

## Root login (full control, including billing)

The root login is the master key to the whole Amazon account. It is **not**
printed here. It is kept:

{{ROOT_LOGIN_LOCATION}}

You need it only to change the payment card, view invoices, or close the
account. Everything else in this document works with the recovery login.

<div class="pagebreak"></div>

# Appendix A: For a technical helper

Everything a sysadmin needs, with no narrative.

**Storage.** Amazon S3, bucket `{{BUCKET}}`, region `{{REGION}}`, account
`{{ACCOUNT_ID}}`. Versioning on, Object Lock in COMPLIANCE mode with a 5-year
default retention on every object; a bucket policy additionally denies the
uploader every delete and retention action. As of {{BUILD_DATE}}:
{{OBJECT_COUNT}} objects, {{TOTAL_GB}} GB, all in storage class
`{{STORAGE_CLASSES}}`. A lifecycle rule expires noncurrent versions after 30
days; a future rule may transition `raw/` to a Glacier class.

**Key layout.** `raw/<YYYY-MM-DD>/<unit>/<unit>_<seq>_<startUTC>/seg-<YYYYMMDD>-<HHMMSS>.wav`,
with `SHA256SUMS`, `session.json`, and card logs beside the segments. Sessions
whose clock was untrusted at record time are under `raw/undated/<unit>/…`.
`manifest/<utc-stamp>_<head>/` holds write-once snapshots of the local
hash-chained ingest manifest.

**Integrity.** Every object was written with a single-part `PutObject` carrying
`--checksum-sha256` equal to its `SHA256SUMS` seal, so S3 holds a whole-object
SHA-256 per object that can be read back with `head-object
--checksum-mode ENABLED` and compared to the seal without egress. After
download, `sha256sum -c SHA256SUMS` in each session folder is the local check.

**Credentials.** IAM user {{USERNAME}} with an inline policy allowing
`s3:ListBucket`, `s3:ListBucketVersions`, `s3:GetBucketLocation`,
`s3:GetObject*`, `s3:RestoreObject` on the bucket, plus
`s3:ListAllMyBuckets`, and an explicit Deny on every put, delete, retention,
and lifecycle action. Console password and one access key on the credentials
page. No MFA.

**Commands.**

```
aws configure                                          # key, secret, us-east-1
aws s3 ls s3://{{BUCKET}}/raw/                         # dated prefixes
aws s3api list-objects-v2 --bucket {{BUCKET}} \
  --query 'Contents[].[StorageClass,Size,Key]' --output text > inventory.tsv
aws s3 sync s3://{{BUCKET}} ./UMIK-Recordings --force-glacier-transfer
find ./UMIK-Recordings -name SHA256SUMS -execdir sha256sum -c --quiet SHA256SUMS \;
```

**Bulk restore from GLACIER or DEEP_ARCHIVE** (skip for GLACIER_IR):

```
aws s3api list-objects-v2 --bucket {{BUCKET}} \
  --query 'Contents[?StorageClass==`GLACIER` || StorageClass==`DEEP_ARCHIVE`].Key' \
  --output text | tr '\t' '\n' \
  | xargs -P 8 -I{} aws s3api restore-object --bucket {{BUCKET}} --key {} \
      --restore-request 'Days=30,GlacierJobParameters={Tier=Bulk}'
```

Check progress with `aws s3api head-object --bucket {{BUCKET}} --key <key>` and
look for `"Restore": "ongoing-request=\"false\""`. Then re-run the sync with
`--force-glacier-transfer`.

**Cost.** Storage about ${{MONTHLY_COST}}/month at STANDARD rates; egress about
${{EGRESS_COST}} for one full download. Bulk restores are free; Standard and
Expedited tiers are not.

**Software.** {{REPO_URL}} (the `umik` tool: `umik verify-s3` re-proves the
bucket against the seals read-only; `tools/recovery/` holds the script below
and the source of this document).

<div class="pagebreak"></div>

# Appendix B: The helper script

This is the full text of `umik-recover.sh`, for a technical helper to retype
or re-create if the digital copy is lost. It needs only `bash` and the AWS CLI.

```bash
{{SCRIPT}}
```
