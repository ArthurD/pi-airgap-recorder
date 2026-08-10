# umik-autorecord

A burnable Raspberry Pi 4B image that records continuously from a miniDSP
UMIK-1 measurement microphone from the moment it is powered on, with no
Wi-Fi, no Bluetooth, no SSH and no network of any kind.

Power on → recording. Pull the plug → recording stops. Nothing else.

---

## Hardware

**The UMIK-1 goes in a black USB 2.0 port. Not the USB-C port, and no hub.**

The Pi 4B has **four USB-A ports** (2× USB 3.0, 2× USB 2.0) plus one USB-C.
The USB-C port is *power input only* — it has no host data role, so the mic
cannot go there. No hub is needed. Note that on the Pi 4B **all four USB-A
ports sit behind the same VL805 xHCI controller** — the black 2.0 ports are
not a separate controller, so port choice matters less than folklore says.
Field captures through a black port verified bit-clean; if USB audio
corruption ever appears, the fixes are a bootloader/VL805 firmware update
(`rpi-eeprom`) or a cheap high-speed USB 2.0 hub in front of the mic.

### Port map

| Port | Device |
|---|---|
| black USB 2.0 | **UMIK-1** (field-verified spot; isochronous audio likes 2.0) |
| black USB 2.0 | **GT-U7 GPS** (optional; slow serial, 2.0 is plenty) |
| blue USB 3.0, either | **USB stick** |
| USB-C | power in — nothing else works there |

No hub. The stick goes in a blue port on the *far side* from the GPS on
purpose: USB 3.0 devices radiate broadband noise right around the GPS
frequency (1.575 GHz). If a box struggles to get a fix, use the GPS cable
to move the module a hand-span away from the Pi, ideally near a window.

**Beware charge-only cables.** Two separate field failures were caused by
charging cables (vape/phone chargers) that carry power but have no data
pins: the device lights up yet is *electrically absent* from the USB bus —
`umik.log` shows `no miniDSP device` / `no GPS module on the bus`. Use the
cable that shipped with the device, and vet any substitute on the Mac
first: plug it in — if it doesn't appear in **System Information → USB**
within seconds, the cable is charge-only.

> **If your UMIK-1 has a USB-C socket, you still need no adapter.** miniDSP
> moved the UMIK-1 from mini-USB to USB-C on later units, but the cable in the
> box is **USB-C to USB-A**: USB-C at the mic end, USB-A at the host end. It
> plugs directly into the Pi. USB-C on the mic body and USB-C on the Pi are
> unrelated — the Pi's is a power inlet.
>
> Because those two revisions may not share a USB product ID, the recorder and
> the udev rule match on the miniDSP **vendor** ID (`2752`) and accept any
> audio device it presents, rather than pinning one product ID. Set `UMIK_PID`
> to narrow it only if you attach more than one miniDSP device.

| | |
|---|---|
| Board | Raspberry Pi 4B |
| Mic | miniDSP UMIK-1, either revision (USB vendor `2752`) |
| GPS (optional) | GT-U7 (u-blox NEO-6 clone) via USB — or any NMEA-over-USB receiver |
| Card | 128 GB (≈10 days of audio); anything ≥8 GB boots |
| Base OS | Raspberry Pi OS Lite arm64, Trixie (2026-06-18) |

### Storage budget

48 kHz / 24-bit / mono is **144 KB/s → 518 MB/hour → 12.4 GB/day**, so a
128 GB card holds **~10 days**. (A UMIK-1 that enumerates as 2-channel
doubles those rates — the recorder captures whatever channel count the
hardware accepts, and `session.json` records which.) When free space drops below 512 MB the
recorder stops cleanly and says so in the journal, instead of letting
`arecord` crash-loop against a full disk. Move old sessions off and
power-cycle to resume.

### Timestamps: plug in a GPS module (optional)

The Pi 4B has **no real-time clock**, and with no network there is nothing to
sync against, so wall-clock timestamps are not normally trustworthy. The
recorder handles this honestly: sessions are ordered by a **persistent
counter**, and `session.json` carries `clock_trusted: true` **only when the
clock was set from GPS that boot** — plausibility heuristics were tried and
field-defeated (the image's own build epoch looks recent, and every boot
restarts at it), so trust is GPS or nothing.

**A cheap USB GPS receiver fixes this.** Plug a **GT-U7** (u-blox NEO-6
clone, ~$10; its micro-USB into any free USB-A port) — or any module that
speaks NMEA over USB — and leave it attached. At every boot,
`umik-gps-time.service` runs *before* the recorder:

1. It waits up to 6 s for a USB serial device, then identifies the GPS by
   behaviour (whatever emits NMEA), not by vendor ID — clone boards use
   assorted serial bridges.
2. It waits up to **3 minutes** (tunable) for a satellite fix, taking time
   only from an NMEA sentence with a **valid checksum** and a plausible
   date — the dummy time modules emit from cold start is rejected.
3. **A position fix is preferred but not required for time.** If the window
   expires without a fix — typical indoors — but the module has been
   reporting coherent, plausible UTC the whole time (decoded from a single
   visible satellite, or from the GT-U7's battery-backed clock seeded by an
   earlier fix), that time is accepted anyway, marked
   `time_source: "gps-time-only"`.
4. It steps the system clock, so the session directory and every segment
   filename carry real UTC (to within a couple of seconds), and
   `session.json` gets `clock_trusted: true`, the `time_source`, and a
   `gps` block — with coordinates, satellite count and altitude when there
   was a real fix.

No module, no NMEA, or no fix in time → each is a logged no-op and recording
starts exactly as before, untrusted clock and all. The module can never block
recording. **The air-gap holds**: a GPS receiver only listens — it transmits
nothing — so the radio-silence posture is unchanged (`umik-radio-check` is
unaffected).

**Even with no GPS at all, the clock now gets a floor.** `03-inject.sh` and
every `umik-ingest.sh` collection leave a `umik-time-seed` file (the Mac's
NTP-disciplined clock, as epoch seconds) on whatever medium they touch; at
boot `umik-time-seed.service` steps the Pi's clock **forward** to the newest
plausible seed, before the session directory is named. Real time is *at
least* the seed — the file was written before the boot — so session names
carry real dates, accurate to "when the media last touched the Mac."
`session.json` says `time_source: "seeded"` and `clock_trusted` stays
`false`: it is a floor, not a sync, and GPS overrides it whenever it can.

**Seed the module once outdoors.** A brand-new GT-U7 has never had a fix, so
indoors it may know nothing: power the box (or just the module) for a few
minutes under open sky once. After that its battery-backed clock keeps
approximate UTC for days to weeks between power-ups, and indoor boots get
time via the no-fix fallback even with zero usable satellites. Cold-start
fix is ~30 s outdoors, minutes near a window, possibly never deep indoors.
Note that fix coordinates land in `session.json` and `umik.log`; redact them
if you publish those files. A DS3231 I²C RTC remains an alternative if the
deployment site never sees the sky and sits unpowered for weeks.

### Reading the box at a glance: the LEDs

With no screen and no network, the Pi's two onboard LEDs are the only live
feedback. `umik-status.service` repurposes both (and hands them back to
stock behaviour if stopped):

| LED | Pattern | Meaning |
|---|---|---|
| green (ACT) | off | still booting — recorder not started yet |
| green | solid | recorder running but not writing yet (mic probe); suspicious if it stays solid for minutes |
| green | **short blip every 2 s** | **recording** — verified on disk: the segment file is actually growing |
| green | fast blink | trouble: recorder or radio-check failed, recorder died, or storage full |
| red (PWR) | off | clock trust not determined yet (GPS sync still running) |
| red | **solid** | **clock synced from GPS this boot** (fix or time-only) |
| red | slow blink | no trusted time — no GPS module, or no usable signal |

Happy state at a distance: **green blipping, red solid**. Green blipping +
red slow-blinking = recording fine, but timestamps are not trusted.

---

## Does "stop gracefully on power removal" work?

**Not literally — nothing can make it literal.** Yanking the plug gives the OS
zero notice; you cannot flush a file you did not know was ending. What this
image does instead is make it not matter:

1. **Segmented capture.** `arecord` rotates every 10 minutes, closing and
   syncing each segment. A power cut can only damage the in-flight segment.
2. **Bounded dirty data.** `vm.dirty_expire_centisecs=200` plus ext4
   `commit=1` cap unwritten audio at roughly **1–2 seconds** (default ~30 s).
3. **`fsck.repair=yes`** on every boot cleans up the filesystem journal.
4. **Truncated ≠ lost.** All the audio bytes are on disk; only the WAV header
   size fields are stale. `tools/repair-wav.sh` rewrites them.

Realistic worst case: **1–2 seconds of audio at the moment of the cut.**
A genuinely clean close would need a UPS/supercap HAT with a power-fail GPIO;
the recorder already handles SIGTERM properly, so adding one later is a small
unit file, not a redesign.

---

## Architecture

One big partition, stock plumbing, our config on top:

> Flash the stock image, drop a provisioning payload on the **FAT boot
> partition** (which macOS mounts natively), and let the Pi harden itself on
> first boot. The stock initramfs auto-expands the root filesystem across the
> whole card (the `resize` flag in `cmdline.txt`, which we deliberately leave
> alone); recordings are simply a directory on it.

Everything injected is written in this repo. No third-party scripts, no
`curl | bash`, and — because `alsa-utils` already ships in Trixie Lite — the
Pi **never touches a network at any point**, not even to provision.

```
build/     runs on the Mac      fetch → verify → decompress → flash → inject
boot/      lands on the card    firstrun.sh + payload/
tools/     host-side utilities  repair-wav.sh · umik-ingest.sh · umik-viewer.py
```

### Trust chain

| Artifact | How it is verified |
|---|---|
| Raspberry Pi OS image | HTTPS (TLS ≥1.2, cert validation mandatory, https-only redirects) + SHA-256 against the published checksum |
| Everything else | Already inside that verified image |

`fetch()` in `build/lib.sh` is the single network entry point. There is no
`-k`, no `--insecure`, no way to disable certificate validation.

**Known gap:** the detached GPG signature is downloaded but not checked —
this host has no `gpg`, and bootstrapping gnupg from source would rest on
nothing stronger than the TLS + SHA-256 we already have. If you have a trusted
keyring: `gpg --verify <image>.img.xz.sig <image>.img.xz`.

---

## Radio silence: four independent layers

Any one of these alone would be sufficient. All four are applied.

1. **Device tree** — `dtoverlay=disable-wifi`, `dtoverlay=disable-bt` in
   `config.txt`. The hardware is not present, so no driver can bind to it.
2. **Boot blacklist** — `modprobe.blacklist=brcmfmac,cfg80211,bluetooth,btusb,…`
3. **`install <mod> /bin/false`** — a plain blacklist only stops *automatic*
   loading; this makes even a deliberate `modprobe` fail.
4. **Firmware gone** — `firmware-brcm80211` and `bluez-firmware` are purged
   and the Broadcom blobs deleted from `/lib/firmware/brcm/`. There is
   nothing left to load into the radio.

Also purged outright: `bluez`, `wpasupplicant`, `network-manager`,
`avahi-daemon`, `rfkill`, `openssh-server`, `cloud-init` (and its seed files
on the boot partition), and `userconf-pi` (the first-boot user wizard).

**Enforced, not just configured.** `umik-radio-check.service` asserts at every
boot that there are no wireless interfaces, no HCI devices, no radio modules,
no rfkill switches and no radio firmware. `umik-record.service` `Requires=`
it, so **if a radio is ever live, the box refuses to record.**

### Recorder sandbox

`umik-record.service` runs as an unprivileged `recorder` user under
`PrivateNetwork=yes` + `IPAddressDeny=any` (it structurally cannot open a
socket), `ProtectSystem=strict` with `ReadWritePaths=/data`,
`SystemCallFilter=@system-service`, `MemoryDenyWriteExecute=yes`,
`DevicePolicy=closed` with only ALSA character devices, and a capability set
of exactly `CAP_SYS_NICE`.

### Access

No SSH, no network. The console maintenance account (created at inject time)
works on HDMI + USB keyboard, and on the GPIO serial console (`enable_uart=1`
is set; with Bluetooth disabled the good PL011 UART serves it). Optionally,
`/etc/udev/rules.d/99-umik-usb.rules.disabled` can be renamed to default-deny
every USB device except the UMIK-1 — but that blocks keyboards too, so only
enable it if you have serial access.

---

## Build

```sh
./build/00-fetch-verify.sh              # download + SHA-256 verify
./build/01-decompress.sh                # python3 lzma; no xz needed
diskutil list external physical         # find your card
./build/02-flash.sh /dev/diskN          # DESTRUCTIVE; verifies readback
./build/04-add-data-partition.sh /dev/diskN   # 8GiB root + Mac-readable exFAT data
./build/03-inject.sh                    # prompts for hostname + console password
diskutil eject /dev/diskN
```

Layout produced: `p1` FAT32 boot · `p2` ext4 root (8 GiB) · `p3` **exFAT
`UMIKDATA`** — the rest of the card, mounted at `/data` on the Pi and readable
directly on a Mac. The stock initramfs auto-resize cannot overrun it: `parted
resizepart` fails harmlessly against a following partition, and firstrun grows
the root *filesystem* to its 8 GiB with `resize2fs` instead. Skipping step 04
still works — recordings then live on the ext4 root (not Mac-readable).

Then: card in the Pi, UMIK-1 in a black USB 2.0 port, power on.

First boot expands the filesystem, provisions, and reboots itself (~2–4 min).
Recording starts automatically on the second boot and on every boot after. If
it does not come up, put the card back in the Mac and read
`/Volumes/bootfs/umik-firstrun.log` — the provisioning log is written to the
FAT partition precisely so a headless failure is still diagnosable.

The console password prompted for by `03-inject.sh` is the **only** way into
the running box. Lose it and you reflash.

**Updating an already-provisioned card** (new script versions, tunables):
put the card in the Mac and re-run `./build/03-inject.sh --reuse-credentials`.
It re-copies the payload and re-arms firstrun, which re-runs idempotently on
the next boot and reinstalls everything; the console account, recordings and
session counters are untouched.

---

## Recordings

```
/data/recordings/
  000001_20260728T161500Z/
    session.json               device, calibration gain, format, clock trust, GPS fix
    seg-20260728-161500.wav    10-minute segments
    seg-20260728-162500.wav
```

`session.json` records the UMIK-1's per-unit **calibration gain**, which the
mic reports in its USB product string (e.g. `Umik-1  Gain:18dB`).

**Getting audio off — the easy way: a USB stick.** At every boot,
`umik-usb-detect` waits up to 6 s for a USB drive (exFAT, FAT32 or ext4). If
one is attached, it is mounted at `/data/usb` and **recordings go to the
stick**; if not, they go to the SD card. The stick can never *block*
recording — every failure path falls back to the SD card and says so in the
journal. `session.json` records which storage each session used, and each
location keeps its own session counter.

Collection loop: **pull power → pull stick → stick in the Mac → `umik
download` → eject, stick back, power on.** Pulling power first means the
stick is never yanked mid-write; a power cut costs the usual 1–2 s worst
case. `umik download` (install once with `./tools/umik link`) runs the
sealed ingest over every mounted UMIK medium, then clears each recording
off the medium **only after its archived copy re-verifies by hash** — media
go back empty, `~/UMIK-Archive` is the truth, and anything unverified stays
put loudly. `umik inject` is the matching one-word re-provision
(payload + fresh time-seed, credentials kept); run it before ejecting the
SD card whenever the payload changed. Pass `--unit umik1` / `--unit umik2`
once per card to name the recorder: the name prefixes every session
directory and lands in `session.json`, which is what keeps the two units'
recordings apart in the archive (`recordings/<unit>/…`) and in S3.

`umik upload` mirrors the archive to `s3://YOUR-BUCKET` (or
`umik download --upload` to chain it): GPS-dated sessions go under
`raw/<YYYY-MM-DD>/<unit>/<session>/`, untrusted-clock sessions under
`raw/undated/<unit>/…` — the date prefix is earned by `clock_trusted`,
never guessed. Uploads read only the archive, are add-only (no `--delete`,
IAM key has no DeleteObject) and idempotent; the hash-chained manifest is
mirrored too, pinning the whole archive history off-site. Credentials live
in the `umik` AWS profile (`aws configure --profile umik`).

Without a stick, recordings land on the card's **exFAT `UMIKDATA` partition**
(when created by step 04), which mounts straight onto a Mac: power off, card
in the Mac, drag the files. Only if both are absent do recordings fall back
to the ext4 root, which needs a Linux machine (or console copy) to read.

Repair a power-cut tail segment with:

```sh
./tools/repair-wav.sh path/to/seg-*.wav
```

### "It sounds like white noise" — no, it's just quiet

The UMIK-1 is a **measurement** microphone with low sensitivity (roughly
−12 dBFS at 94 dB SPL). A quiet room records around **−70 dBFS RMS**: played
back at normal volume that is near-silence, and cranked up it sounds like
hiss — which is the mic's noise floor, not a broken recording. Speech or
music near the mic lands at healthy −30 to −18 dBFS. Field data verified:
full 24-bit resolution in use, channels perfectly correlated, real
room-ambience spectrum. To *listen* to ambience, apply ~+40 dB makeup gain —
`tools/umik-viewer.py` (spectrogram browser with a gain control) does this
for you.

### Browsing recordings: the spectrogram viewer

```sh
python3 tools/umik-viewer.py "/path/to/collected/data"   # then open the URL it prints
```

A local, offline web UI (needs only python3 + numpy): pick a collection →
session → segment, see an Audacity-style spectrogram, click to move the
playhead, play with adjustable makeup gain, arrow keys to thumb through
segments. Nothing leaves the machine; it binds to 127.0.0.1 only.

### Chain of custody: sealing recordings for publication

`tools/umik-ingest.sh` turns collection into an evidence-grade, fully offline
pipeline. Install once:

```sh
./tools/umik-ingest.sh --install-agent
```

From then on, whenever the card (or a stick) mounts, every new recording is
automatically **sealed**: SHA-256 hashed as the bytes stream off the medium,
copied to `~/UMIK-Archive/`, the copy re-read and verified, and the hash
recorded in a per-session `SHA256SUMS` (publish it next to the audio — anyone
verifies with `shasum -a 256 -c SHA256SUMS`) and in an append-only,
hash-chained manifest. Editing any archived byte or manifest line breaks
`--verify`. Power-cut tail segments get a sealed `.repaired.wav` derivative;
the original is kept byte-exact. Card activity logs are snapshotted too.

```sh
./tools/umik-ingest.sh --verify --deep      # prove the whole archive intact
./tools/umik-ingest.sh --prune-verified     # free card space, only for files
                                            # whose seal re-verifies
```

What this proves: the audio is bit-identical from the moment of ingest
through publication. What it cannot prove: what happened before the card
reached the Mac — that would require signing on the Pi itself.

### Tunables

Via `systemctl edit umik-record` (`Environment=` lines):

| Variable | Default |
|---|---|
| `UMIK_SEGMENT_SECONDS` | `600` |
| `UMIK_RATE` | `48000` |
| `UMIK_CHANNELS` | `1` (auto-falls back to `2`, then `1` — many UMIK-1s enumerate as a 2-channel device) |
| `UMIK_FORMAT` | `S24_3LE S32_LE S16_LE` (first that works) |
| `UMIK_DATA_DIR` | unset (auto: `/data/usb/recordings` if a stick is mounted, else `/data/recordings`) |
| `UMIK_MIN_FREE_MB` | `512` |
| `UMIK_PID` | unset (any miniDSP device) |
| `UMIK_USB_WAIT` | `6` (seconds to wait for a USB drive; via `systemctl edit umik-usb-detect`) |
| `UMIK_LOG_INTERVAL` | `60` (seconds between heartbeat log lines) |
| `UMIK_GPS_WAIT` | `6` (seconds to wait for a USB GPS to enumerate; via `systemctl edit umik-gps-time`) |
| `UMIK_GPS_FIX_TIMEOUT` | `180` (seconds to wait for a GPS fix before recording starts anyway; raise the unit's `TimeoutStartSec` alongside it) |

### Activity log

journald is volatile (RAM) on this box, so every service also appends the
interesting events to a plain-text **`logs/umik.log`** on the same medium as
the recordings — the stick when recording to the stick, the card's exFAT
partition otherwise. Open it on the Mac like any text file. It records each
boot's radio-check verdict, USB-drive detection, GPS detection and clock
sync (the log's timestamps visibly jump when the clock is stepped — the jump
*is* the adjustment, documented), mic discovery, session start/stop, and a
heartbeat line every minute showing the current segment's
growing size and free space — a stalled recorder is visible as a stopped
heartbeat. Rotates at 5 MB, keeping one previous file.

---

## Status (2026-08-10)

**Field-verified** across two runs (2026-08): capture and format probe,
segmentation, stick-vs-card fallback, heartbeat, logs, diag, sealed ingest —
every sampled segment bit-clean.

**Built, awaiting field verification:** GPS time sync (incl. no-position-fix
fallback), Mac time-seed floor, LED status display, `umik download` /
`umik inject`, second unit (`umik2`).

Open items:

- [ ] GPS retest: first attempt the GT-U7 never enumerated on USB — suspect
      a charge-only micro-USB cable; retry with a known data cable.
- [ ] DS3231 RTC support (modules on hand shortly): GPS-disciplines-RTC;
      RTC-carried time counts as trusted. Covers Pi 5's built-in RTC too.
- [ ] GPG signature verification (needs a trusted keyring on the Mac).
- [ ] Optional field-power trim (powersave governor, Ethernet kill):
      ~15–20% more battery runtime.
- [ ] Optional UPS/supercap HAT for a truly graceful close.
- [ ] Root-cause the one crash-loop boot (`c1f05d17`, first field run);
      mitigations are in — check `logs/umik.log.1` next collection.
