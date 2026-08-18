# pi-airgap-recorder

A burnable Raspberry Pi 4B image that records continuously from a miniDSP
UMIK-1 measurement microphone from the moment it is powered on, with no
Wi-Fi, no Bluetooth, no SSH and no network of any kind.

**Power on → recording. Pull the plug → recording stops. Nothing else.**

There is no app, no pairing step, no configuration on the device, and no way
to log into it over a network — because there is no network. You build the
card on a Mac, put it in the Pi, and give it power. Everything after that is
LEDs and files.

### What makes it different from "a Pi with `arecord` in rc.local"

| | |
|---|---|
| **Air-gapped by construction** | Radio hardware disabled in the device tree, drivers blacklisted *and* stubbed, firmware blobs deleted, `openssh-server` purged from disk. A boot-time check asserts all of it, and **the recorder refuses to start if any radio is live**. |
| **Honest timestamps** | A clock is only trusted on anchored evidence — NTS-authenticated NTP over one ethernet boot, GPS, or a DS3231 RTC proven to have ticked continuously. Guessing is treated as a bug; `clock_trusted: false` is a valid, common answer. |
| **Survives the plug being pulled** | 10-minute segments, dirty data capped at 1–2 s, `fsck.repair` on boot, and a repair tool for the truncated tail. Worst case is 1–2 seconds of audio. |
| **Chain-of-custody ingest** | Recordings are SHA-256 sealed as they stream off the medium into an append-only, hash-chained manifest, and only deleted from the card once the archived copy re-verifies. |
| **Verifiable off-site backup** | An optional S3 mirror whose bytes can be proven — server-side — to match the seals, without downloading them back. |

### Who this is for

People who need a recording to be *defensible* as well as audible: acoustic
and noise surveys, long-baseline environmental monitoring, evidence capture,
or anyone who wants a device that provably cannot phone home. It is equally
usable as a plain unattended field recorder — ignore the S3 and sealing
sections and it is still just "power on, record."

### Requirements

A Raspberry Pi 4B, a miniDSP UMIK-1, an SD card, and **a Mac to build the
card** (the build scripts use `diskutil` and Apple's `hdiutil`/`shasum`; the
on-Pi half is plain Debian and portable). Optional: a USB stick for
recordings, a DS3231 RTC module, a USB GPS receiver, an AWS account.

> **Recording law is your responsibility.** In many places recording people
> without consent is illegal, and the rules differ by country and by state.
> This tool makes recordings hard to dispute; it does not make them lawful.
> Know your jurisdiction before you deploy it.

---

## Quick start

Build the card on a Mac (about 15 minutes, most of it downloading):

```sh
git clone https://github.com/ArthurD/pi-airgap-recorder.git
cd pi-airgap-recorder

./build/00-fetch-verify.sh                     # download Pi OS + verify SHA-256
./build/01-decompress.sh                       # no `xz` binary needed
diskutil list external physical                # find your card, e.g. /dev/disk4
./build/02-flash.sh /dev/disk4                 # DESTRUCTIVE; verifies readback
./build/04-add-data-partition.sh /dev/disk4    # 8GiB root + Mac-readable exFAT
./build/03-inject.sh --unit umik1               # prompts for hostname + password
diskutil eject /dev/disk4
```

Card into the Pi, UMIK-1 into a **black USB 2.0 port**, power on. First boot
provisions and reboots itself (~2–4 min); recording starts on the second boot
and every boot after.

**Check it is working from across the room:** green LED blipping every 2 s
means audio is verifiably hitting the disk. Red LED solid means the clock is
trusted.

Collect the audio:

```sh
./tools/umik link            # install the `umik` command once
# pull power → pull the stick → stick into the Mac
umik download                # seal, verify, then clear the stick
```

That is the whole loop. Everything below is detail, options, and the
reasoning behind the defaults.

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
| Time set (pick one) | wired ethernet for ONE boot (NTP; recommended) — or a GT-U7 GPS (u-blox NEO-6 clone) / any NMEA-over-USB receiver |
| RTC (optional) | DS3231 plug-on module (e.g. Dorhea 4-pack) on GPIO pins 1–9 — carries the time so the cable/GPS comes off |
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

### Timestamps: the trust model

The Pi 4B has **no built-in real-time clock**, and in steady state this box
touches no network, so wall-clock timestamps are not normally trustworthy.
The recorder handles this honestly: sessions are ordered by a **persistent
counter**, and `session.json` carries `clock_trusted: true` only on
**anchored evidence** — the clock was set from NTP (one wired-ethernet
boot) or GPS that boot, or carried by the disciplined DS3231 RTC (below).
Plausibility heuristics were tried and field-defeated (the image's own
build epoch looks recent, and every boot restarts at it), so trust is
anchored or nothing.

### First time-set: one wired-ethernet boot (recommended)

Plug an **ethernet cable from your router into the Pi for a single boot**.
`umik-net-time.service` runs before the recorder: it spots the carrier,
opens a one-time network window (DHCP via `systemd-networkd`, otherwise
dormant), fetches **NTS-authenticated time** (RFC 8915) from
`time.cloudflare.com` via a one-shot `chronyd -q`, steps the clock,
**disciplines the DS3231 RTC**, then tears the whole thing back down —
services stopped and re-masked, link down. Watch for the **red PWR LED
going solid**: that is the sync landing. Pull the cable whenever you like;
every later boot carries trusted time from the RTC (`time_source: "ntp"`
that boot, `"rtc"` afterwards).

chrony is not on the stock image (nor, surprisingly, is `hwclock` — Pi OS
Lite omits `util-linux-extra`) and provisioning is offline by design, so
**the first cable boot installs both through the window itself**
(apt-verified signed packages; the chrony daemon is disabled and masked
the moment it lands — only the window ever runs it, one-shot). If the install can't happen (a LAN
with no internet, repo down), the ladder degrades honestly: plain NTP from
`time.google.com` (via chrony, or `systemd-timesyncd` if chrony never
arrived) — but an unauthenticated answer only counts if it survives a
**TLS cross-check**: one HTTPS response from a WebPKI-validated host, whose
`Date` header must agree with the fresh NTP time within 10 s. Precision
from NTP, authentication from TLS. A disagreement, or a failed certificate
validation (the man-in-the-middle signature), **rejects the sync** — trust
flags stay false and the RTC is never written.

No cable = a ~2-second logged no-op, and the box never touches a network.
**Radio silence holds either way** — ethernet is copper, and
`umik-radio-check` still proves no wireless hardware is live. What you
trade during that one boot is the air-gap, for the seconds the window is
open, on your own LAN, only while you have physically plugged the cable in.

**The window is outbound-only, enforced.** Nothing on the image can accept
a login over a network — `openssh-server` is purged from disk at
provisioning (and masked on top), telnetd has never shipped with Pi OS
Lite, and no TCP service listens. On top of that, `umik-net-time` installs
a drop-all inbound nftables policy *before* the link ever comes up: the
box originates DHCP and NTP and accepts only the conntrack-matched replies
— no ping answers, no TCP resets, no ICMP unreachables. A port scan during
the window sees a black hole (ARP aside — the price of speaking IP).
IPv6 is disabled wholesale by sysctl, and outside the window the interface
is administratively down: plugging a cable into a running box does
nothing. The time answer itself is authenticated too — NTS when chrony is
available, the TLS Date cross-check otherwise — so even a hostile network
can only deny the sync, not forge it (the residual exception: the
no-chrony, no-wget fallback accepts plain NTP with a loud
`UNAUTHENTICATED` log line).
This replaced GPS as the primary time source after a field cycle where the
GPS fix landed but the RTC write silently failed — see `umik.log` capture
of `hwclock` errors, which both writers now keep.

### Or: plug in a GPS module (works fully off-grid)

**A cheap USB GPS receiver also works.** Plug a **GT-U7** (u-blox NEO-6
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
`false`: it is a floor, not a sync, and NTP/GPS override it whenever they can.

**Seed the module once outdoors.** A brand-new GT-U7 has never had a fix, so
indoors it may know nothing: power the box (or just the module) for a few
minutes under open sky once. After that its battery-backed clock keeps
approximate UTC for days to weeks between power-ups, and indoor boots get
time via the no-fix fallback even with zero usable satellites. Cold-start
fix is ~30 s outdoors, minutes near a window, possibly never deep indoors.
Note that fix coordinates land in `session.json` and `umik.log`; redact them
if you publish those files.

### Set-and-forget time: the DS3231 RTC (optional, recommended)

A **DS3231 battery-backed RTC** turns "sync every boot" into "**sync once,
ever**": boot each box once with an ethernet cable (or outdoors with the
GPS), and from then on the coin cell carries real time across power-offs
for years — nothing stays attached.

**Hardware.** Use the plug-on kind (5-hole female socket underneath, e.g.
the Dorhea 4-pack). With the Pi powered off, push it onto the **first five
pins of the inner row** of the GPIO header — physical pins 1/3/5/7/9, the
row *closer to the middle of the board*, starting at the end nearest the
microSD slot — battery facing up. Seated right, the module body sits over
the Pi, not overhanging the board edge, and five bare pins of the outer row
remain visible beside it. (Wrong row/offset is harmless-but-dead: the module
simply never appears on I²C.)

**Trust model.** Exactly two code paths ever write the RTC:
`umik-net-time` (from an NTP sync over the one-time cable) and
`umik-gps-time` (**only from a position fix** — the weaker no-position-fix
time sync sets that boot's clock but never the RTC). The DS3231 latches an
oscillator-stop flag in hardware whenever it quits ticking (flat/removed
battery), and the kernel refuses to hand over a time while that flag is
set — it clears only when the RTC is next written. So at boot,
`umik-rtc-time.service` reading a valid, plausible time *is proof* that an
authoritative source set this chip once and it has run continuously since:
the clock is stepped and counts as **trusted** (`time_source: "rtc"`,
`clock_trusted: true`), within crystal drift (~1 min/year — redo the cable
boot whenever you want that zeroed). The flag lives in the chip on the
unit, so re-injecting or swapping SD cards never launders trust. Mac
time-seeds still apply on top — a seed only ever steps the clock
*forward*, and a genuine floor can only refine RTC drift, never regress it.

The full clock hierarchy at boot, weakest first, each layer only ever
improving on the last: `fake-hwclock` (floor) → DS3231 restore (trusted) →
Mac time-seed (floor, forward-only) → wired NTP (trusted, disciplines the
RTC) → GPS (trusted, re-disciplines the RTC on a fix). No RTC fitted,
never set, or battery dead → logged no-op, `clock_trusted` stays honest,
recording starts regardless.

**Rollout to an existing card**: `umik inject --reuse-credentials` (the
config.txt overlay and the new services ride along; firstrun re-runs
idempotently on next boot), then one boot with an ethernet cable attached.
Watch for the red PWR LED going **solid on a later cable-less boot** — that
is the RTC carrying trusted time, and nothing needs to stay plugged in.

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
| red (PWR) | off | clock trust not determined yet (NTP/GPS sync still running) |
| red | **solid** | **clock trusted** — wired-NTP or GPS sync this boot, or carried by the disciplined DS3231 RTC |
| red | slow blink | no trusted time — no NTP/GPS/RTC, or none had usable time |

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

`umik upload` mirrors the archive to your S3 bucket (or `umik download
--upload` to chain it): dated sessions go under
`raw/<YYYY-MM-DD>/<unit>/<session>/`, untrusted-clock sessions under
`raw/undated/<unit>/…` — the date prefix is earned by `clock_trusted`,
never guessed. Uploads read only the archive, are add-only (no `--delete`,
IAM key has no DeleteObject) and idempotent; the hash-chained manifest is
mirrored too, pinning the whole archive history off-site.

**Point it at your own bucket first.** There is deliberately no default —
S3 bucket names are one global namespace, and a repo that shipped one would
have fresh clones uploading into a stranger's bucket:

```sh
cp tools/umik.local.conf.example tools/umik.local.conf   # gitignored
$EDITOR tools/umik.local.conf                            # set UMIK_S3_BUCKET
```

Credentials live in the `umik` AWS profile (`aws configure --profile umik`).
`umik upload --dry-run` previews without touching the bucket. Anything in the
environment (`UMIK_ARCHIVE`, `UMIK_S3_BUCKET`, `UMIK_AWS_PROFILE`) overrides
the config file.

### Proving the bucket holds what you sealed

Completeness is not correctness. `aws s3 sync` decides what to upload from
size and mtime, and an S3 ETag is a multipart digest that compares to
nothing — so "the mirror looks complete" never meant "the mirror is correct."
That gap matters the moment you consider deleting the local archive.

```sh
umik verify-s3               # stamp what needs it, then verify everything
umik verify-s3 --dry-run     # report what would be stamped
umik verify-s3 --verify-only # skip stamping; check what is already stamped
```

It asks S3 to copy each object onto itself with `--checksum-algorithm
SHA256`. S3 reads its own stored bytes, computes a whole-object SHA-256, and
stores it; the tool compares that against the `SHA256SUMS` seals. Because the
hash is derived from what the bucket actually holds, this is a real
end-to-end check — **and the data never leaves AWS, so verifying hundreds of
gigabytes costs API calls instead of egress**. Real output:

```
==> stamping FULL_OBJECT SHA-256 (server-side, no download; 5 parallel)
==> processed 1515 of 1515 objects
==> stamped 648, already full-object 867, failed 0
==> reading back S3 checksums (5 parallel)

==> VERIFIED (S3 bytes match the seal) : 1515
==> MISMATCHED                         : 0
==> expected but absent from S3        : 0
==> in S3 but not expected locally     : 0

==> ALL 1515 OBJECT(S) VERIFIED against their seals - S3 holds the sealed bytes
```

It exits non-zero on any mismatch and says, in as many words, not to delete
the local copy. Run it after each upload; `umik upload` requests SHA-256 on
transfer too, but multipart uploads yield a *composite* checksum (a hash of
part hashes) that is **not** comparable to a whole-file seal, so `verify-s3`
is the authority.

> Note: stamping writes a new object version. On a versioned bucket the
> previous versions linger and cost storage — add a lifecycle rule expiring
> noncurrent versions.

<details>
<summary><b>S3 mirror setup</b> — one-time, or to rebuild on a new Mac</summary>

Replace `YOUR-BUCKET` below with the name you chose.

1. Bucket `YOUR-BUCKET`: **Block all public access** on, **versioning** on
   (versioning is the backstop that makes the add-only design
   tamper-evident — nothing can be silently clobbered).
2. IAM user `umik-uploader`, no console access, one access key, with a
   policy scoped to just this bucket — deliberately **no `s3:DeleteObject`**,
   so even a stolen laptop's key cannot erase the mirror:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       { "Effect": "Allow",
         "Action": ["s3:PutObject", "s3:ListBucket", "s3:GetObject"],
         "Resource": ["arn:aws:s3:::YOUR-BUCKET",
                      "arn:aws:s3:::YOUR-BUCKET/*"] }
     ]
   }
   ```

   (`ListBucket`/`GetObject` are what let `aws s3 sync` skip what is
   already uploaded. `umik verify-s3` needs `PutObject` as well, since the
   server-side checksum stamp is written as a copy.)
3. On the Mac: `brew install awscli`, then `aws configure --profile umik`
   with that key. Then point the tools at it:

   ```sh
   cp tools/umik.local.conf.example tools/umik.local.conf
   $EDITOR tools/umik.local.conf          # UMIK_S3_BUCKET=YOUR-BUCKET
   aws s3 ls s3://YOUR-BUCKET/ --profile umik    # sanity check
   ```
</details>

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
| `UMIK_RTC_WAIT` | `5` (seconds to wait for the DS3231 to appear; via `systemctl edit umik-rtc-time`) |
| `UMIK_NET_IFACE` | `eth0` (wired interface for the one-time NTP window; via `systemctl edit umik-net-time`) |
| `UMIK_NET_CARRIER_WAIT` | `10` (seconds to wait for an ethernet carrier before the no-cable no-op) |
| `UMIK_NET_DHCP_WAIT` | `40` (seconds to wait for a DHCP lease) |
| `UMIK_NET_NTP_WAIT` | `120` (seconds to wait per sync attempt; raise the unit's `TimeoutStartSec` alongside these) |
| `UMIK_NET_NTS_SERVER` | `time.cloudflare.com` (NTS-capable server for the authenticated sync) |
| `UMIK_NET_NTP_SERVER` | `time.google.com` (plain-NTP fallback server) |
| `UMIK_NET_TLS_HOST` | `https://www.google.com/` (WebPKI host for the fallback's Date cross-check) |
| `UMIK_NET_TLS_TOLERANCE` | `10` (max seconds of NTP-vs-TLS-date disagreement before the sync is rejected) |

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

## Command reference

Everything Mac-side is one command. Install it once:

```sh
./tools/umik link        # symlinks `umik` into the first writable dir on PATH
```

| Command | What it does |
|---|---|
| `umik download` | Seal every mounted medium into the archive, verify, then clear the medium |
| `umik download --upload` | ...and mirror to S3 afterwards |
| `umik upload` | Mirror the archive to S3 (add-only, idempotent) |
| `umik upload --dry-run` | Show what would upload, touch nothing |
| `umik verify` | Re-verify the manifest hash chain |
| `umik verify --deep` | ...and re-hash every archived byte |
| `umik verify-s3` | Prove the bucket holds the sealed bytes (server-side, no egress) |
| `umik inject --unit umik1` | Re-provision a mounted card, keeping its console account |
| `umik link` | Install the command on PATH |

### A collection, start to finish

```console
$ umik download

=== /Volumes/UMIK2 ===
    ingest start: /Volumes/UMIK2 -> /Users/you/UMIK-Archive (volume 'UMIK2')
    sealed recordings/umik2/umik2_000012_.../seg-20260816-190515.wav (172800044 bytes)
    ...
    sealed seg-20260817-182527.repaired.wav (repaired header derivative)
    ingest done: 142 sealed, 1 repaired derivative(s), 0 already sealed, 0 warning(s)
==> pruned 142 verified file(s) from /Volumes/UMIK2, kept 0
=== /Volumes/UMIK2: downloaded + cleared; safe to eject ===

archive: /Users/you/UMIK-Archive
eject with: diskutil eject /Volumes/<name>   (or Finder)
```

Nothing is deleted from the stick until its archived copy re-hashes to the
same value. If any file fails, the medium is left **entirely** untouched and
the run says so loudly.

```console
$ umik verify
==> manifest chain OK: 1468 seals, head fd3acd610c7dca14caec76d58415ac0ba4cb0c4501d18eaabc285ae08ce36494
```

That head hash commits to every seal ever made. Publish it — a dated head
pins the entire archive history, and any later edit to any archived byte or
manifest line breaks the chain.

```console
$ umik upload
==> umik1/umik1_000029_...: 222 file(s) -> s3://YOUR-BUCKET/raw/2026-08-15/umik1/...
==> manifest + head + ingest.log -> s3://YOUR-BUCKET/manifest/ (head fd3acd61...)
==> done: 26 session(s) scanned, 224 file(s) uploaded, 0 failure(s)
```

### Inspecting what you recorded

```sh
python3 tools/umik-viewer.py ~/UMIK-Archive     # spectrogram browser on 127.0.0.1
./tools/repair-wav.sh path/to/seg-*.wav         # fix a power-cut tail by hand
shasum -a 256 -c SHA256SUMS                     # anyone can check a published session
```

`session.json` in every session directory is the metadata of record — device,
calibration gain, sample format, clock trust and its source, GPS fix if there
was one:

```json
{
  "session": "000029",
  "unit": "umik1",
  "started_utc": "20260815T235050Z",
  "clock_trusted": true,
  "time_source": "rtc",
  "rtc": { "present": true, "trusted": true, "note": "clock set from disciplined RTC" },
  "format": { "encoding": "S24_3LE", "sample_rate": 48000, "channels": 1 }
}
```

---

## Status (2026-08-18)

Two units have been running this in the field. Nothing below is aspirational.

**Field-verified**: capture and format probe, segmentation, stick-vs-card
fallback, heartbeat, logs, diag, sealed ingest (every sampled segment
bit-clean), Mac time-seed floor, LED status display, unit naming,
`umik download` / `umik upload` end-to-end (dated + undated S3 prefixes
both exercised 2026-08-12), GPS time sync from a position fix (umik1,
2026-08-11: fix in 1 s with a warm module, session dir named with real
UTC, red LED solid).

**The RTC design proved out unattended (2026-08-17).** Both units ran long
sessions with *nothing attached* — no cable, no GPS — and came back with
`time_source: "rtc"`, `clock_trusted: true`: 23.4 h / 141 segments on umik2,
36.4 h / 219 segments on umik1. Across both runs the Pi's own timestamps
matched the collecting Mac's clock to the second, so DS3231 drift over a day
and a half was below one second. 362 files sealed, zero warnings, both sticks
verified and cleared.

**The S3 mirror is now provably correct (2026-08-18).** `umik verify-s3`
stamped and checked all 1515 objects against their seals: 1515 verified, 0
mismatched. Before this, only completeness had ever been checked, never
content.

**Field-FAILED and pivoted from:** GPS→RTC disciplining. The 2026-08-11
outdoor boot got its fix but `hwclock --systohc` failed with its error
discarded (`2>/dev/null`), so the DS3231 stayed at its 2000-01-01 default
and the next indoor boot fell back to the seed, red LED blinking. Both RTC
writers now capture hwclock's error text, and the primary time-set path is
now **wired NTP** (`umik-net-time`, one ethernet-cable boot) instead of an
outdoor GPS boot. The first bench run of that window (2026-08-12, NTS sync
verified end-to-end) also caught the culprit at last: `hwclock: not found`
— **Pi OS Lite doesn't ship hwclock** (Debian split it into
`util-linux-extra`), so the GPS boot never stood a chance. The window now
installs `util-linux-extra` alongside chrony.

Open items:

- [x] Bench-verify `umik-net-time` on umik1 (2026-08-12): chrony installed
      through the window, "clock SET from time.cloudflare.com via NTS",
      red solid — and the captured hwclock error exposed the missing
      `util-linux-extra`.
- [x] Second cable boot after the util-linux-extra fix (2026-08-12):
      "RTC disciplined from nts time", `rtc0/since_epoch` ticking true in
      2026.
- [x] RTC carry verified (2026-08-12): next boot, no network sync — "clock
      SET from battery-backed RTC ... TRUSTED" at 6 s uptime, red solid,
      `moved 0s`. Unit 1's clock chain is done: nothing stays plugged in.
- [x] umik2 cable boot (2026-08-12): its DS3231 was already seated and
      ticking; same two-act proof as umik1.
- [x] DS3231 field test (2026-08-17): both units ran a day-plus on RTC time
      alone with nothing attached. Note: a Pi 5's built-in RTC should work
      identically (same kernel interface) minus the overlay — untested.
- [x] Prove S3 holds the sealed bytes, not just files of the right size
      (2026-08-18): `umik verify-s3`, all 1515 objects.
- [ ] GPG signature verification (needs a trusted keyring on the Mac).
- [ ] Lifecycle rule to expire noncurrent S3 versions — `verify-s3` stamping
      writes a new version of each object, and the uploader IAM user has no
      DeleteObject by design, so this needs admin credentials.
- [ ] `umik-viewer.py` reads a local directory only; browsing straight from
      S3 would need a fetch step.
- [ ] Optional field-power trim (powersave governor, Ethernet kill):
      ~15–20% more battery runtime.
- [ ] Optional UPS/supercap HAT for a truly graceful close.
- [ ] Root-cause the one crash-loop boot (`c1f05d17`, first field run);
      mitigations are in, and it has not recurred in any collection since.

---

## Contributing and license

Issues and pull requests are welcome, particularly field reports: what
hardware you ran it on, and what broke. Much of what is documented here was
learned by something failing in a field, so that kind of report is the most
useful thing you can send.

If you fork this for a different microphone, the mic-specific parts are
narrow — `umik-record` matches USB vendor `2752` and probes formats; the
air-gap, timestamp-trust and sealing layers do not care what is recording.

**License:** MIT — see [`LICENSE`](LICENSE). Use it, fork it, sell it; just
keep the copyright notice. It comes with no warranty, which for a device you
point at the world and walk away from is worth reading literally.
