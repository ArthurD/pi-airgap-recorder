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
cannot go there. No hub is needed. Prefer a **black USB 2.0** port over a blue
3.0 one: the UMIK-1 is a USB Audio Class device at full speed, and the VL805
xHCI controller behind the 3.0 ports is a known source of intermittent
dropouts with UAC hardware.

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

### The one thing worth adding: an RTC

The Pi 4B has **no real-time clock**, and with no network there is nothing to
sync against, so wall-clock timestamps are not trustworthy. The recorder
handles this honestly: sessions are ordered by a **persistent counter**, and
`session.json` carries `clock_trusted: false` whenever the clock is implausible
(including when it has gone backwards since the previous session). A ~$5
DS3231 I²C RTC module fixes timestamps permanently, if you ever care.

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
tools/     host-side utilities  repair-wav.sh
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

---

## Recordings

```
/data/recordings/
  000001_20260728T161500Z/
    session.json               device, calibration gain, format, clock trust
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

Collection loop: **pull power → pull stick → copy on your Mac (exFAT reads
natively) → stick back in → power on.** Pulling power first means the stick
is never yanked mid-write; a power cut costs the usual 1–2 s worst case.

Without a stick, recordings land on the card's **exFAT `UMIKDATA` partition**
(when created by step 04), which mounts straight onto a Mac: power off, card
in the Mac, drag the files. Only if both are absent do recordings fall back
to the ext4 root, which needs a Linux machine (or console copy) to read.

Repair a power-cut tail segment with:

```sh
./tools/repair-wav.sh path/to/seg-*.wav
```

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

### Activity log

journald is volatile (RAM) on this box, so every service also appends the
interesting events to a plain-text **`logs/umik.log`** on the same medium as
the recordings — the stick when recording to the stick, the card's exFAT
partition otherwise. Open it on the Mac like any text file. It records each
boot's radio-check verdict, USB-drive detection, mic discovery, session
start/stop, and a heartbeat line every minute showing the current segment's
growing size and free space — a stalled recorder is visible as a stopped
heartbeat. Rotates at 5 MB, keeping one previous file.

---

## Open items

- [ ] Not yet booted on real hardware. The log lands on the FAT partition.
- [ ] GPG signature verification (needs a trusted keyring on the Mac).
- [ ] RTC module for trustworthy timestamps.
- [ ] Optional UPS/supercap HAT for a truly graceful close.
