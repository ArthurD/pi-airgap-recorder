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

- [x] ~~Re-inject both cards~~ with the two-mic recorder. Unit 2 and unit 1
      both done 2026-09-20; unit 2 field-verified same day (mic label,
      preference and burn-rate lines in the card log, new `device` keys).
- [x] ~~Viewer duration display hardcodes 24-bit stereo.~~ Stale: the session
      index reads each session's byte rate from its first WAV header, so any
      format and rate (RODE float, Ultramic 250 kHz) gets the right duration.
- [x] ~~Confirm the Ultramic 250K's USB VID:PID and product string.~~ Field-
      confirmed on unit 2, 2026-10-08: `0869:0306`, product "UltraMic 250K 16
      bit r4", matched by vendor, negotiated S16_LE @ 250000 mono (500 KB/s,
      ~1.8 GB/h as budgeted); two sessions, clock trusted from the RTC. The
      vendor default needed no change. Still open: note which of the three DIP
      gain levels the mic is set to.

- [x] ~~Unit 2 has not reported since 2026-08-16.~~ Collected 2026-09-19:
      five sessions (Sep 16-18), all `time_source: rtc`, `clock_trusted`.
- [ ] **Unit 1's stick is still labelled TESLADRIVE.** Harmless (sessions are
      unit-stamped) but rename it when convenient. Rotation as of 2026-10-07:
      three sticks (`TESLADRIVE` 256 GB, `UMIK2`, `UMIK3` 128 GB exFAT, added
      2026-10-07) between the two units.

## RTL-SDR (umik-sdr): first boot with the dongle

Nothing below has run on a Pi yet. Build with `./build/05-fetch-sdr-debs.sh`,
inject, and boot with the NESDR SMArt v5 attached; the answers are in
`umik-firstrun.log`, `logs/diag-latest.log` (`--- sdr ---`) and `umik.log`.

- [ ] **Provisioning.** The firstrun SDR step shows three checksum `OK`s,
      `libusb-1.0-0 2:1.0.28-1 already installed ... skipped`, one `dpkg -i`
      of librtlsdr0 + rtl-sdr, and `SDR support ready`.
- [ ] **USB ID and strings.** Expect `0bda:2838`, product `RTL2838UHIDIR`,
      manufacturer `Realtek` in `lsusb` and in `session.json`'s `device`. A
      different ID has to go into umik-record's exit-79 check, umik-sdr's
      device match, and the udev rule.
- [ ] **The plugdev rule took.** The dongle's node reads `crw-rw---- root
      plugdev`, `id recorder` lists `plugdev`, and umik-sdr opens the dongle
      from inside its sandbox: no `usb_open error`, `usb_claim_interface
      error` or `No supported devices found`. This is also the first real test
      of `DeviceAllow=char-usb_device` and `AF_NETLINK` in the unit.
- [ ] **DVB modules absent.** The `lsmod` line in `--- sdr ---` shows none of
      `dvb_usb_rtl28xxu rtl2832 rtl2830 rtl2832_sdr r820t`, and there is no
      `/dev/dvb`.
- [ ] **Gain vs the strong local FM station.** At the fixed 25.4 dB, check the
      FM-band clips for clipping (cu8 bytes piling up at 0 and 255) and the
      main scan for that station's images elsewhere in the band. If either
      shows, lower `UMIK_SDR_GAIN` and write down the value.
- [ ] **Green LED with the SDR alone.** Solid through the first scan, then
      blipping; confirm it does not drop back to solid between passes (the
      6-minute freshness window vs a real pass pause plus scan on the Pi).
- [ ] **Mic-only units unchanged.** After re-injecting unit 1 and unit 2 with
      this payload: umik-sdr logs its one "not my device" line and stays
      inactive (not failed), green blips as before, `systemctl --failed` is
      empty.

## Housekeeping

- [ ] The `admin` AWS profile is a browser login session that expires; every
      admin task starts with `aws login --profile admin`.
