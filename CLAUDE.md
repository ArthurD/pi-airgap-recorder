# Working in this repo

Mac-side notes for whoever (or whatever) is running the collection loop.
The Pi side is documented in README.md; this file is only the operational
habits that are easy to forget between sticks.

## Processing a stick

"Process the stick" / "ingest" means `umik process /Volumes/<stick>`; it
seals, verifies, clears+ejects, uploads+verifies S3, copies+re-hashes the NAS,
and deletes local audio only once both off-box copies verified. Before it:

- **NAS on the wired link.** The Finder mount re-attaches over Wi-Fi after a
  sleep/wake even with the cable in, and the copy drops from ~117 MB/s to
  ~9. Check `netstat -an -f inet | grep '\.445 ' | grep ESTABLISHED`; the
  local address must be the wired interface's. If not:
  `diskutil unmount /Volumes/Network-Share` then
  `open "smb://guest:@DAntonioData.local/Network-Share"`.
  Never `lsof +D` the share to see if it is busy; that walks the whole NAS.
- **`UMIK_JOBS` stays at 10 or higher.** It is the number of S3 calls in
  flight for `umik upload` and `umik verify-s3`, both latency-bound (one aws
  CLI round trip per object). 10 verified the same 11.6k-object bucket in
  11 minutes where 5 took 45, and cut a whole run from 85 minutes to 47.
  The scripts default to 10 and `tools/umik.local.conf` pins it; do not
  "tidy" it back down.
- **Free space.** The whole stick sits locally until both legs verify; a
  stick bigger than free space needs the two-pass hold trick (README).
- **Look outside `recordings/`.** The ingest walks only `$vol/recordings`;
  compare `du -sh $vol/recordings` with the volume's used space and check
  `.Trashes` before trusting the count.
- **Scrap, not process, when the stick holds nothing worth keeping** (a mic
  left running for days): `umik scrap /Volumes/<stick>` drops it all, or
  `--keep`/`--drop` a time range, and leaves a sealed `scrapped.json`
  record. Destruction is unrecoverable; the printed plan and typing the
  volume label back are the safety. Show the user the `--dry-run` plan, and
  never pass `--yes` unless they explicitly asked to scrap.

Run logs: `~/UMIK-Archive/process/<utc-stamp>/`. A run that reports a leg
"skipped" or "FAILED" keeps local audio; nothing is lost, fix and re-run.

## Storage and cost questions

Start from `STORAGE-COSTS.md`: it logs every review (bytes per place, growth,
prices, five-year projection, decisions) and has the exact commands to redo
the measurement. Answer a new "how much are we using / what will it cost"
question by appending a dated section there, not by starting over. Keep
bucket names, hostnames, and folder names that identify people out of it.
