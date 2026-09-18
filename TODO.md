# TODO

Open items as of 2026-09-18. The archive model is now: S3 is the immutable
truth (Object Lock, compliance, 5 years), the NAS holds the quick-access
copy, the Mac keeps only seals and metadata, the stick is a courier.

## Tooling

- [ ] **`umik sync-nas`** — the post-upload tail is still done by hand:
      rsync new sessions to the NAS share, re-hash them there against
      SHA256SUMS, then delete the local wavs only when both `verify-s3` and
      the NAS re-hash pass. Make it one subcommand (and chain it from
      `umik download --upload`). Use `rsync -rlt --no-perms --no-owner
      --no-group`; macOS ships an old rsync with no `--info`.
- [ ] **Audio-less local archive** — `umik verify --deep` and `umik-viewer.py`
      both expect wavs beside the seals and now fail on the Mac. Either
      document `UMIK_ARCHIVE=<nas path>` for both, or have them fall back to
      the NAS path when the local wav is missing.
- [ ] **Bucket hardening as code** — the admin-side pieces (uploader deny
      policy, 30-day noncurrent-version lifecycle rule, Object Lock config,
      one-time `put-object-retention` pass) live only in
      `~/UMIK-Archive/admin-scripts/` on the Mac. Parametrise the bucket
      name and bring them into `tools/` so a fresh bucket can be set up the
      same way. Document the sequence in the README bucket-setup section.
- [ ] **Independent download spot-check** — `verify-s3` trusts S3 to compute
      the SHA-256 honestly. Add an optional mode that downloads N random
      objects and hashes them locally for a fully independent cross-check.

## Bucket

- [ ] **Confirm the overhang expired** — after 2026-10-18 the lifecycle rule
      should have removed ~2,450 noncurrent versions (~276 GB). Check with
      `list-object-versions` and confirm storage cost dropped by about half.
- [ ] **Storage class** — everything is in STANDARD. With the NAS as the
      fast copy, consider Glacier Instant Retrieval for `raw/` (about 6x
      cheaper, still millisecond access). Lifecycle transition, no rewrite.
- [ ] **Known allowed overwrite** — a session sealed across two ingests gets
      its `SHA256SUMS` appended, and the uploader replaces that one key.
      Under Object Lock the old version is retained 5 years. Small and rare;
      avoid by not uploading a session until its stick is pruned.

## Field units

- [ ] **Unit 2 has not reported since 2026-08-16.** Its RTC has not been
      re-proven since. Collect its stick and check `time_source`/`rtc`.
- [ ] **Unit 1's stick is still labelled TESLADRIVE.** Harmless (sessions are
      unit-stamped) but rename it when convenient.

## Housekeeping

- [ ] The `admin` AWS profile is a browser login session that expires; every
      admin task starts with `aws login --profile admin`.
