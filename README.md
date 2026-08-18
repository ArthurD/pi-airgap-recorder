# pi-airgap-recorder

A burnable Raspberry Pi 4B image that records continuously from a USB
microphone from the moment it is powered on, with no Wi-Fi, no Bluetooth, no
SSH and no network of any kind.

**Power on → recording. Pull the plug → recording stops. Nothing else.**

No app, no pairing, no configuration on the device, and no way to log into it
over a network — because there is no network. You build the card on a Mac, put
it in the Pi, and give it power. Everything after that is LEDs and files.

### What this adds over `arecord` in a startup script

| | |
|---|---|
| **Air-gapped by construction** | Radio disabled in the device tree, drivers blacklisted *and* stubbed, firmware blobs deleted, `openssh-server` purged from disk. A boot check asserts all of it, and **the recorder refuses to start if any radio is live**. |
| **Honest timestamps** | A clock is trusted only on anchored evidence — authenticated NTP, GPS, or an RTC proven to have ticked continuously. `clock_trusted: false` is a valid, common answer. |
| **Survives the plug being pulled** | 10-minute segments, dirty data capped at 1–2 s, `fsck.repair` on boot, and a repair tool for the truncated tail. |
| **Chain-of-custody ingest** | Recordings are SHA-256 sealed as they stream off the medium into an append-only hash-chained manifest, and deleted from the card only once the archived copy re-verifies. |
| **Verifiable off-site backup** | An optional S3 mirror whose bytes can be proven — server-side, no egress — to match the seals. |

**Who it's for:** anyone who needs a recording to be *defensible* as well as
audible — acoustic and noise surveys, environmental monitoring, evidence
capture — or who just wants a field recorder that provably cannot phone home.
Ignore the S3 and sealing sections and it is still simply "power on, record."

**Requirements:** a Raspberry Pi 4B, a USB microphone, an SD card, and **a Mac
to build the card** (the build scripts use `diskutil` and `hdiutil`; the on-Pi
half is plain Debian). Optional: a USB stick for recordings, a
[DS3231 RTC module](https://www.amazon.com/dp/B08X4H3NBR) (**recommended** —
see [Timestamps](#timestamps)), a USB GPS receiver, an AWS account.

> **Recording law is your responsibility.** In many places recording people
> without consent is illegal, and rules differ by country and state. This tool
> makes recordings hard to dispute; it does not make them lawful.

**Contents:** [Quick start](#quick-start) · [Hardware](#hardware) ·
[Timestamps](#timestamps) · [LEDs](#leds) · [Build](#build) ·
[Recordings](#recordings) · [S3 mirror](#s3-mirror) ·
[Chain of custody](#chain-of-custody) · [Commands](#command-reference) ·
[Security design](#security-design) · [Tunables](#tunables) ·
[Status](#status)

---

## Quick start

Build the card on a Mac (~15 minutes, mostly downloading):

```sh
git clone https://github.com/ArthurD/pi-airgap-recorder.git
cd pi-airgap-recorder

./build/00-fetch-verify.sh                     # download Pi OS + verify SHA-256
./build/01-decompress.sh                       # no `xz` binary needed
diskutil list external physical                # find your card, e.g. /dev/disk4
./build/02-flash.sh /dev/disk4                 # DESTRUCTIVE; verifies readback
./build/04-add-data-partition.sh /dev/disk4    # 8GiB root + Mac-readable exFAT
./build/03-inject.sh --unit umik1              # prompts for hostname + password
diskutil eject /dev/disk4
```

Card into the Pi, mic into a **black USB 2.0 port**, power on. First boot
provisions and reboots itself (~2–4 min); recording starts on the second boot
and every boot after.

**Check it from across the room:** green LED blipping every 2 s means audio is
verifiably hitting the disk; red LED solid means the clock is trusted.

Collect the audio:

```sh
./tools/umik link      # install the `umik` command once
# pull power → pull the stick → stick into the Mac
umik download          # seal, verify, then clear the stick
```

That is the whole loop. Everything below is detail and reasoning.

---

## Hardware

**The mic goes in a black USB 2.0 port. Not the USB-C port, and no hub.**

| Port | Device |
|---|---|
| black USB 2.0 | **microphone** (isochronous audio likes 2.0) |
| black USB 2.0 | **GPS** (optional) |
| blue USB 3.0 | **USB stick** — use the port *farthest* from the GPS |
| USB-C | power in — nothing else works there |

The Pi's USB-C is power-only, so the mic cannot go there. All four USB-A ports
sit behind the same VL805 controller, so port choice matters less than folklore
says; field captures through a black port verified bit-clean. USB 3.0 devices
radiate broadband noise around the GPS band (1.575 GHz), hence keeping a stick
away from a GPS module.

**Beware charge-only cables.** Two separate field failures were caused by
charging cables with no data pins: the device lights up yet is *electrically
absent* from the bus, and `umik.log` shows `no miniDSP device`. Vet any
substitute on the Mac first — if it doesn't appear in **System Information →
USB** within seconds, it's charge-only.

> **A USB-C UMIK-1 needs no adapter.** miniDSP moved the UMIK-1 from mini-USB
> to USB-C, but the supplied cable is USB-C (mic) to USB-A (host) and plugs
> straight into the Pi.

| | |
|---|---|
| Board | Raspberry Pi 4B |
| Mic | any USB audio capture device; miniDSP UMIK-1 out of the box (see [below](#using-a-different-microphone)) |
| RTC | [DS3231 plug-on module](https://www.amazon.com/dp/B08X4H3NBR) — **recommended** |
| Time set | one wired-ethernet boot (NTP) or a GT-U7 / any NMEA-over-USB GPS |
| Card | 128 GB ≈ 10 days of audio; anything ≥8 GB boots |
| Base OS | Raspberry Pi OS Lite arm64, Trixie (2026-06-18) |

**Storage budget.** 48 kHz / 24-bit / mono is 144 KB/s → 518 MB/hour →
**12.4 GB/day**; a 128 GB card holds ~10 days. A mic that enumerates as
2-channel doubles that. Below 512 MB free the recorder stops cleanly rather
than letting `arecord` crash-loop against a full disk.

### Using a different microphone

Out of the box the recorder matches the miniDSP USB vendor ID (`2752`),
accepting either UMIK-1 hardware revision. Nothing downstream is
miniDSP-specific — the format probe asks the hardware what it accepts, and the
calibration gain reads `unknown` when the product string has none — so the
vendor is a knob:

```sh
sudo systemctl edit umik-record     # then add, under [Service]:
# Environment=UMIK_VID=any          # first USB audio capture device found
# Environment=UMIK_VID=046d         # or pin a specific vendor (lsusb)
```

`/proc/asound` only lists sound cards, so even `any` cannot select a keyboard.
One catch: if you enabled the optional default-deny udev rule, add your
vendor's ID there too, or the device is refused before ALSA sees it.

---

## Timestamps

The Pi 4B has no built-in RTC and this box touches no network, so wall-clock
time is not trustworthy by default. Sessions are therefore ordered by a
**persistent counter**, and `session.json` sets `clock_trusted: true` only on
anchored evidence. Plausibility heuristics were tried and field-defeated — the
image's own build epoch looks recent, and every boot restarts at it — so trust
is anchored or nothing.

Hierarchy at boot, weakest first, each layer only improving on the last:

```
fake-hwclock (floor) → DS3231 restore (trusted) → Mac time-seed (floor,
forward-only) → wired NTP (trusted, disciplines the RTC) → GPS (trusted,
re-disciplines the RTC on a fix)
```

### Recommended: a DS3231 RTC + one ethernet boot

This turns "sync every boot" into **sync once, ever** — nothing stays attached
afterwards. It is the setup both field units run.

The [DS3231 module linked above](https://www.amazon.com/dp/B08X4H3NBR) is a
**direct drop-in**: no wiring, no soldering, no HAT. With the Pi powered off,
push it onto the **first five pins of the inner GPIO row** — physical pins
1/3/5/7/9, the row closer to the middle of the board, starting at the end
nearest the microSD slot — battery facing up. Seated right, the module sits
over the Pi rather than overhanging the edge. Wrong row is harmless but dead:
it simply never appears on I²C.

Then boot **once** with an ethernet cable from your router.
`umik-net-time.service` runs before the recorder: it spots the carrier, opens a
one-time network window (DHCP via `systemd-networkd`, otherwise dormant),
fetches **NTS-authenticated time** (RFC 8915) from `time.cloudflare.com` via a
one-shot `chronyd -q`, steps the clock, **disciplines the DS3231**, then tears
it all back down — services stopped and re-masked, link down. Watch for the red
LED going solid. Pull the cable whenever you like; every later boot carries
trusted time from the RTC.

**Why the RTC is trustworthy.** The DS3231 latches an oscillator-stop flag in
hardware whenever it quits ticking, and the kernel refuses to return a time
while that flag is set — it clears only when the chip is next written. So a
readable, plausible time at boot *is proof* that an authoritative source set
this chip once and it has run continuously since. Drift is ~1 min/year; redo a
cable boot whenever you want that zeroed. The flag lives in the chip on the
unit, so swapping or re-injecting SD cards never launders trust.

chrony is not on the stock image (nor is `hwclock` — Pi OS Lite omits
`util-linux-extra`), and provisioning is offline by design, so **the first
cable boot installs both through the window itself**, then disables and masks
chrony. If that install can't happen, the ladder degrades honestly to plain NTP
from `time.google.com` — but an unauthenticated answer counts only if it
survives a **TLS cross-check**: one HTTPS response from a WebPKI-validated
host whose `Date` header agrees within 10 s. Precision from NTP,
authentication from TLS. A disagreement or a failed certificate validation
**rejects the sync** — trust stays false and the RTC is never written.

No cable is a ~2-second logged no-op. **Radio silence holds either way** —
ethernet is copper, and `umik-radio-check` still proves no wireless hardware is
live. What you trade for those seconds is the air-gap, on your own LAN, only
while you have physically plugged a cable in. The window is
[outbound-only and enforced](#the-one-time-network-window).

### Alternative: GPS (fully off-grid)

A **GT-U7** (u-blox NEO-6 clone, ~$10) or any NMEA-over-USB module works
instead, and needs no LAN at all. `umik-gps-time.service` identifies the GPS by
behaviour rather than vendor ID, waits up to 3 minutes for a fix, and accepts
time only from a checksum-valid sentence with a plausible date. **A position
fix is preferred but not required**: if the window expires without one — typical
indoors — but the module has been reporting coherent UTC throughout, that is
accepted as `time_source: "gps-time-only"`. Only a real fix disciplines the RTC.

Seed a new module once outdoors, since it has never had a fix; afterwards its
battery-backed clock keeps approximate UTC for weeks. A GPS receiver only
listens, so the air-gap is unchanged. Note that fix coordinates land in
`session.json` — redact them if you publish those files.

### Fallback: the Mac time-seed

With no RTC, cable or GPS, the clock still gets a floor. `03-inject.sh` and
every `umik download` leave a `umik-time-seed` file (the Mac's NTP-disciplined
clock, as epoch seconds) on the medium; at boot the Pi steps its clock
**forward** to the newest plausible seed. Real time is *at least* the seed, so
session names carry real dates accurate to "when the media last touched the
Mac." `clock_trusted` stays `false`: it is a floor, not a sync.

---

## LEDs

With no screen and no network, the two onboard LEDs are the only live feedback.
`umik-status.service` repurposes both, and restores stock behaviour if stopped.

| LED | Pattern | Meaning |
|---|---|---|
| green (ACT) | off | still booting |
| green | solid | running but not writing yet — suspicious after minutes |
| green | **blip every 2 s** | **recording**, verified: the segment file is growing |
| green | fast blink | trouble: radio-check failed, recorder died, or disk full |
| red (PWR) | off | clock trust not yet determined |
| red | **solid** | **clock trusted** — NTP or GPS this boot, or carried by the RTC |
| red | slow blink | no trusted time |

Happy state at a distance: **green blipping, red solid.**

---

## Build

Flash the stock image, drop a provisioning payload on the FAT boot partition
(which macOS mounts natively), and let the Pi harden itself on first boot:

```
build/     runs on the Mac      fetch → verify → decompress → flash → inject
boot/      lands on the card    firstrun.sh + payload/ (services, scripts, config)
tools/     host-side utilities  umik · umik-ingest.sh · umik-upload.sh ·
                                umik-verify-s3.sh · umik-viewer.py · repair-wav.sh
```

```sh
./build/00-fetch-verify.sh              # download + SHA-256 verify
./build/01-decompress.sh                # python3 lzma; no xz needed
diskutil list external physical         # find your card
./build/02-flash.sh /dev/diskN          # DESTRUCTIVE; verifies readback
./build/04-add-data-partition.sh /dev/diskN   # 8GiB root + Mac-readable exFAT
./build/03-inject.sh --unit umik1       # prompts for hostname + console password
diskutil eject /dev/diskN
```

Layout: `p1` FAT32 boot · `p2` ext4 root (8 GiB) · `p3` **exFAT `UMIKDATA`** —
the rest of the card, mounted at `/data` and readable directly on a Mac. The
stock auto-resize cannot overrun it (`parted resizepart` fails harmlessly
against a following partition, and firstrun grows the root filesystem with
`resize2fs` instead). Skipping step 04 still works; recordings then live on the
ext4 root, which a Mac cannot read.

If it doesn't come up, put the card back in the Mac and read
`/Volumes/bootfs/umik-firstrun.log` — the provisioning log lands on the FAT
partition precisely so a headless failure stays diagnosable.

**The console password from `03-inject.sh` is the only way into a running box.
Lose it and you reflash.** Pass `--unit <name>` once per card to name the
recorder; the name prefixes every session directory and lands in
`session.json`, which is what keeps multiple units apart in the archive.

**Updating a provisioned card:** re-run `./build/03-inject.sh
--reuse-credentials` (or `umik inject`). It re-copies the payload and re-arms
firstrun, which re-runs idempotently; the console account, recordings and
session counters are untouched.

---

## Recordings

```
/data/recordings/
  umik1_000001_20260728T161500Z/
    session.json               device, gain, format, clock trust, GPS fix
    seg-20260728-161500.wav    10-minute segments
```

**Getting audio off — the easy way: a USB stick.** At every boot,
`umik-usb-detect` waits up to 6 s for a USB drive (exFAT, FAT32 or ext4). If
one is present it is mounted at `/data/usb` and recordings go there; if not,
they go to the SD card. The stick can never *block* recording — every failure
path falls back and says so. Each location keeps its own session counter.

**Collection loop:** pull power → pull stick → stick in the Mac →
`umik download` → eject, stick back, power on. Pulling power first means the
stick is never yanked mid-write.

`umik download` seals every mounted medium, then clears each recording **only
after its archived copy re-verifies by hash** — media go back empty,
`~/UMIK-Archive` is the truth, and anything unverified stays put loudly.

Without a stick, recordings land on the exFAT `UMIKDATA` partition, which
mounts straight onto a Mac. Only if both are absent do they fall back to the
ext4 root.

### Why it survives losing power

Yanking the plug gives the OS zero notice — nothing can make a graceful close
literal. Instead the design makes it not matter: `arecord` rotates and syncs
every 10 minutes, `vm.dirty_expire_centisecs=200` plus ext4 `commit=1` cap
unwritten audio at **1–2 seconds**, `fsck.repair=yes` runs each boot, and a
truncated tail loses nothing but its WAV header — all the audio bytes are on
disk. Fix one with `./tools/repair-wav.sh path/to/seg-*.wav`; `umik download`
does it automatically, sealing the repaired copy alongside the byte-exact
original.

### "It sounds like white noise" — no, it's just quiet

A measurement microphone has low sensitivity (roughly −12 dBFS at 94 dB SPL),
so a quiet room records around **−70 dBFS RMS**: near-silence at normal volume,
hiss when cranked — that's the noise floor, not a broken recording. Speech near
the mic lands at −30 to −18 dBFS. Apply ~+40 dB makeup gain to listen:

```sh
python3 tools/umik-viewer.py ~/UMIK-Archive     # then open the URL it prints
```

An offline web UI (python3 + numpy): collection → session → segment, an
Audacity-style spectrogram, click to move the playhead, play with adjustable
gain, arrow keys to thumb through segments. Binds `127.0.0.1` only.

---

## S3 mirror

`umik upload` mirrors the archive to your bucket (or `umik download --upload`
to chain it): dated sessions under `raw/<YYYY-MM-DD>/<unit>/<session>/`,
untrusted-clock sessions under `raw/undated/<unit>/…` — the date prefix is
earned by `clock_trusted`, never guessed. Uploads read only the archive, are
add-only and idempotent; the hash-chained manifest is mirrored too, pinning the
whole archive history off-site.

**Point it at your own bucket first.** There is deliberately no default — S3
bucket names are one global namespace, and a shipped default would have fresh
clones uploading into a stranger's bucket:

```sh
cp tools/umik.local.conf.example tools/umik.local.conf   # gitignored
$EDITOR tools/umik.local.conf                            # set UMIK_S3_BUCKET
```

<details>
<summary><b>Bucket + IAM setup</b> — one-time</summary>

1. Bucket `YOUR-BUCKET`: **Block all public access** on, **versioning** on
   (versioning is what makes the add-only design tamper-evident).
2. IAM user, no console access, one access key, scoped to just this bucket —
   deliberately **no `s3:DeleteObject`**, so even a stolen laptop's key cannot
   erase the mirror:

   ```json
   { "Version": "2012-10-17",
     "Statement": [
       { "Effect": "Allow",
         "Action": ["s3:PutObject", "s3:ListBucket", "s3:GetObject"],
         "Resource": ["arn:aws:s3:::YOUR-BUCKET",
                      "arn:aws:s3:::YOUR-BUCKET/*"] }
     ] }
   ```

   (`ListBucket`/`GetObject` let `aws s3 sync` skip what is already uploaded;
   `PutObject` also covers `verify-s3`, whose checksum stamp is written as a
   server-side copy.)
3. `brew install awscli`, `aws configure --profile umik`, then
   `aws s3 ls s3://YOUR-BUCKET/ --profile umik` to sanity-check.
</details>

### Proving the bucket holds what you sealed

Completeness is not correctness. `aws s3 sync` decides what to upload from size
and mtime, and an S3 ETag is a multipart digest comparable to nothing — so "the
mirror looks complete" never meant "the mirror is correct." That gap matters
the moment you consider deleting the local archive.

```sh
umik verify-s3                 # stamp what needs it, then verify everything
umik verify-s3 --dry-run       # report what would be stamped
umik verify-s3 --verify-only   # check what is already stamped
```

It asks S3 to copy each object onto itself with `--checksum-algorithm SHA256`.
S3 reads its own stored bytes, computes a whole-object SHA-256 and stores it;
the tool compares that against the `SHA256SUMS` seals. Because the hash comes
from what the bucket actually holds, this is a real end-to-end check — **and
the data never leaves AWS, so verifying hundreds of gigabytes costs API calls
instead of egress.**

```
==> VERIFIED (S3 bytes match the seal) : 1515
==> MISMATCHED                         : 0
==> ALL 1515 OBJECT(S) VERIFIED against their seals
```

It exits non-zero on any mismatch and says not to delete the local copy. Run it
after each upload: `umik upload` requests SHA-256 on transfer too, but
multipart uploads yield a *composite* checksum (a hash of part hashes) that is
**not** seal-comparable, so `verify-s3` is the authority.

> Stamping writes a new object version. On a versioned bucket the previous
> versions linger — add a lifecycle rule expiring noncurrent versions.

---

## Chain of custody

`tools/umik-ingest.sh` makes collection evidence-grade and fully offline.
`umik download` runs it for you; to seal automatically on every mount:

```sh
./tools/umik-ingest.sh --install-agent
```

Every new recording is SHA-256 hashed **as the bytes stream off the medium**,
copied to `~/UMIK-Archive/`, re-read and verified, and the hash recorded twice:
in a per-session `SHA256SUMS` (publish it next to the audio — anyone checks
with `shasum -a 256 -c SHA256SUMS`) and in an append-only, hash-chained
manifest whose head commits to every seal ever made. Editing any archived byte
or manifest line breaks verification. Card activity logs are snapshotted too.

```sh
umik verify              # check the manifest hash chain
umik verify --deep       # ...and re-hash every archived byte
```

**What this proves:** the audio is bit-identical from the moment of ingest
through publication. **What it cannot prove:** what happened before the card
reached the Mac — that would require signing on the Pi itself.

---

## Command reference

```sh
./tools/umik link        # symlink `umik` into the first writable dir on PATH
```

| Command | What it does |
|---|---|
| `umik download` | Seal every mounted medium into the archive, verify, clear the medium |
| `umik download --upload` | ...and mirror to S3 afterwards |
| `umik upload` | Mirror the archive to S3 (add-only, idempotent) |
| `umik upload --dry-run` | Show what would upload, touch nothing |
| `umik verify` | Re-verify the manifest hash chain (`--deep` re-hashes everything) |
| `umik verify-s3` | Prove the bucket holds the sealed bytes (server-side, no egress) |
| `umik inject --unit umik1` | Re-provision a mounted card, keeping its console account |

A collection, start to finish:

```console
$ umik download

=== /Volumes/UMIK2 ===
    sealed recordings/umik2/umik2_000012_.../seg-20260816-190515.wav (172800044 bytes)
    ...
    ingest done: 142 sealed, 1 repaired derivative(s), 0 already sealed, 0 warning(s)
==> pruned 142 verified file(s) from /Volumes/UMIK2, kept 0
=== /Volumes/UMIK2: downloaded + cleared; safe to eject ===

$ umik verify
==> manifest chain OK: 1468 seals, head fd3acd610c7dca14caec76d58415ac0ba4cb0c4501d18eaabc285ae08ce36494
```

That head hash commits to every seal ever made — publish it, and any later edit
to any archived byte breaks the chain.

`session.json` is the metadata of record:

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

## Security design

### Radio silence: four independent layers

Any one would suffice; all four are applied.

1. **Device tree** — `dtoverlay=disable-wifi`, `dtoverlay=disable-bt`. The
   hardware isn't present, so no driver can bind.
2. **Boot blacklist** — `modprobe.blacklist=brcmfmac,cfg80211,bluetooth,btusb,…`
3. **`install <mod> /bin/false`** — a blacklist only stops *automatic* loading;
   this makes even a deliberate `modprobe` fail.
4. **Firmware gone** — `firmware-brcm80211` and `bluez-firmware` purged, the
   Broadcom blobs deleted. Nothing remains to load into the radio.

Also purged: `bluez`, `wpasupplicant`, `network-manager`, `avahi-daemon`,
`rfkill`, `openssh-server`, `cloud-init`, `userconf-pi`.

**Enforced, not just configured.** `umik-radio-check.service` asserts at every
boot that there are no wireless interfaces, HCI devices, radio modules, rfkill
switches or radio firmware — and `umik-record.service` `Requires=` it, so **if
a radio is ever live, the box refuses to record.**

### The one-time network window

Nothing on the image can accept a login over a network: `openssh-server` is
purged from disk, and no TCP service listens. `umik-net-time` additionally
installs a drop-all inbound nftables policy *before* the link comes up — the
box originates DHCP and NTP and accepts only conntrack-matched replies. No ping
answers, no TCP resets. A port scan during the window sees a black hole (ARP
aside — the price of speaking IP). IPv6 is disabled wholesale; outside the
window the interface is administratively down, so plugging a cable into a
running box does nothing.

### Recorder sandbox

`umik-record.service` runs as an unprivileged `recorder` user under
`PrivateNetwork=yes` + `IPAddressDeny=any` (it structurally cannot open a
socket), `ProtectSystem=strict` with `ReadWritePaths=/data`,
`SystemCallFilter=@system-service`, `MemoryDenyWriteExecute=yes`,
`DevicePolicy=closed` with only ALSA character devices, and exactly
`CAP_SYS_NICE`.

### Access, and the supply chain

No SSH, no network. The console account works on HDMI + USB keyboard and on the
GPIO serial console. Optionally,
`/etc/udev/rules.d/99-umik-usb.rules.disabled` can be renamed to default-deny
every USB device except the mic — but that blocks keyboards too, so enable it
only with serial access.

The Pi OS image is verified over HTTPS (TLS ≥1.2, mandatory cert validation)
plus SHA-256 against the published checksum; everything else is already inside
that verified image. `fetch()` in `build/lib.sh` is the single network entry
point, with no `-k` and no way to disable certificate validation. Nothing is
injected that isn't in this repo — no third-party scripts, no `curl | bash` —
and because `alsa-utils` ships in Trixie Lite, **the Pi never touches a network
to provision.**

**Known gap:** the detached GPG signature is downloaded but not checked (this
host has no `gpg`, and bootstrapping it would rest on nothing stronger than the
TLS + SHA-256 already used). With a trusted keyring:
`gpg --verify <image>.img.xz.sig <image>.img.xz`.

---

## Tunables

Via `systemctl edit umik-record` (or the named unit), as `Environment=` lines:

| Variable | Default |
|---|---|
| `UMIK_VID` | `2752` (miniDSP). Any vendor ID, or `any` for the first USB capture device |
| `UMIK_PID` | unset (any product from that vendor) |
| `UMIK_SEGMENT_SECONDS` | `600` |
| `UMIK_RATE` | `48000` |
| `UMIK_CHANNELS` | `1` (falls back to `2`, then `1`) |
| `UMIK_FORMAT` | `S24_3LE S32_LE S16_LE` (first that works) |
| `UMIK_DATA_DIR` | unset (auto: stick if mounted, else SD) |
| `UMIK_MIN_FREE_MB` | `512` |
| `UMIK_LOG_INTERVAL` | `60` (heartbeat seconds) |
| `UMIK_USB_WAIT` | `6` (via `umik-usb-detect`) |
| `UMIK_GPS_WAIT` / `UMIK_GPS_FIX_TIMEOUT` | `6` / `180` (via `umik-gps-time`) |
| `UMIK_RTC_WAIT` | `5` (via `umik-rtc-time`) |
| `UMIK_NET_IFACE` | `eth0` (via `umik-net-time`) |
| `UMIK_NET_CARRIER_WAIT` / `DHCP_WAIT` / `NTP_WAIT` | `10` / `40` / `120` |
| `UMIK_NET_NTS_SERVER` | `time.cloudflare.com` |
| `UMIK_NET_NTP_SERVER` | `time.google.com` |
| `UMIK_NET_TLS_HOST` / `TLS_TOLERANCE` | `https://www.google.com/` / `10` s |

Raise the unit's `TimeoutStartSec` alongside any wait you increase.

**Activity log.** journald is volatile (RAM) here, so every service also appends
to a plain-text `logs/umik.log` on the same medium as the recordings. It records
each boot's radio-check verdict, USB and GPS detection, clock sync (timestamps
visibly jump when the clock is stepped — the jump *is* the adjustment), mic
discovery, session start/stop, and a heartbeat every minute showing segment
size and free space. A stalled recorder shows as a stopped heartbeat. Rotates
at 5 MB, keeping one previous file.

---

## Status

Two units have run this in the field. Nothing here is aspirational.

**Field-verified:** capture and format probe, segmentation, stick-vs-card
fallback, heartbeat, logs, diag, sealed ingest (every sampled segment
bit-clean), Mac time-seed floor, LED status, unit naming, `umik download` /
`umik upload` end-to-end with both dated and undated S3 prefixes, and GPS time
sync from a position fix (fix in 1 s with a warm module).

**The RTC design proved out unattended (2026-08-17).** Both units ran long
sessions with *nothing attached* and returned `time_source: "rtc"`,
`clock_trusted: true` — 23.4 h / 141 segments on one, 36.4 h / 219 segments on
the other. Across both runs the Pi's timestamps matched the collecting Mac's
clock to the second, so drift over a day and a half was under one second. 362
files sealed, zero warnings.

**The S3 mirror is provably correct (2026-08-18).** `umik verify-s3` stamped
and checked all 1515 objects against their seals: 1515 verified, 0 mismatched.
Previously only completeness had ever been checked, never content.

**Field-failed and pivoted from:** GPS→RTC disciplining. An outdoor boot got
its fix but `hwclock --systohc` failed with its error discarded, so the DS3231
stayed at its 2000-01-01 default. Both RTC writers now capture hwclock's error
text — which promptly exposed the real culprit: `hwclock: not found`, because
**Pi OS Lite doesn't ship it** (Debian split it into `util-linux-extra`). The
GPS boot never stood a chance. The network window now installs it alongside
chrony, and wired NTP replaced GPS as the primary time source.

Open:

- [ ] GPG signature verification (needs a trusted keyring on the Mac).
- [ ] Lifecycle rule to expire noncurrent S3 versions (needs admin credentials;
      the uploader IAM user has no DeleteObject by design).
- [ ] `umik-viewer.py` reads a local directory only; browsing straight from S3
      would need a fetch step.
- [ ] Optional field-power trim (powersave governor, Ethernet kill): ~15–20%
      more battery runtime.
- [ ] Optional UPS/supercap HAT for a truly graceful close.
- [ ] Root-cause one crash-loop boot from the first field run; mitigations are
      in and it has not recurred since.
- [ ] A Pi 5's built-in RTC should work identically (same kernel interface)
      minus the overlay — untested.

---

## Contributing and license

Issues and pull requests welcome, particularly field reports: what hardware you
ran it on, and what broke. Most of what is documented here was learned by
something failing in a field, so those are the most useful reports to send.

Forking for a different microphone is a config change, not a rewrite — see
[Using a different microphone](#using-a-different-microphone). The air-gap,
timestamp-trust and sealing layers do not care what is recording.

**License:** MIT — see [`LICENSE`](LICENSE). Use it, fork it, sell it; just
keep the copyright notice. It comes with no warranty, which for a device you
point at the world and walk away from is worth reading literally.
