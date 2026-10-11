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
see [Timestamps](#timestamps)), a USB GPS receiver, an RTL-SDR dongle (see
[Recording from an SDR](#recording-from-an-sdr)), an AWS account.

> **Recording law is your responsibility.** In many places recording people
> without consent is illegal, and rules differ by country and state. This tool
> makes recordings hard to dispute; it does not make them lawful.

**Contents:** [Quick start](#quick-start) · [Hardware](#hardware) ·
[Recording from an SDR](#recording-from-an-sdr) ·
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
./build/05-fetch-sdr-debs.sh                   # the SDR recorder's 3 pinned .debs (every card)
diskutil list external physical                # find your card, e.g. /dev/disk4
./build/02-flash.sh /dev/disk4                 # DESTRUCTIVE; verifies readback
./build/04-add-data-partition.sh /dev/disk4    # 8GiB root + Mac-readable exFAT
./build/03-inject.sh --unit umik1              # prompts for hostname + password
diskutil eject /dev/disk4
```

Card into the Pi, mic into **any USB-A port**, power on. First boot
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

**The mic goes in any of the four USB-A ports, black or blue. Not the USB-C port, and no hub.**

| Port | Device |
|---|---|
| any USB-A | **microphone** — black 2.0 by habit, blue 3.0 works the same |
| any USB-A | **USB stick** — whichever fits; some boards space the blue pair too tightly |
| any USB-A | **GPS** (optional) — keep it *farthest* from the stick |
| any USB-A | **RTL-SDR** (optional) — antenna on its magnetic-base cable, away from the stick and the Pi |
| USB-C | power in — nothing else works there |

The Pi's USB-C is power-only, so the mic cannot go there. All four USB-A ports
sit behind the same VL805 controller, so port choice matters less than folklore
says; field captures through a black port verified bit-clean, and nothing in
the software looks at which port a device is on. Unit 3 runs mic and stick off
whatever fits. USB 3.0 devices
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
| Mic | any USB audio capture device; miniDSP UMIK-1, RODE NT1 5th Gen and Dodotronic Ultramic 250K out of the box, swappable with no config change (see [below](#using-a-different-microphone)) |
| RTC | [DS3231 plug-on module](https://www.amazon.com/dp/B08X4H3NBR) — **recommended** |
| Time set | one wired-ethernet boot (NTP) or a GT-U7 / any NMEA-over-USB GPS |
| Card | 128 GB ≈ 10 days on the UMIK-1, ~2 on the RODE at 192 kHz float, ~2.9 on the Ultramic at 250 kHz; anything ≥8 GB boots |
| Base OS | Raspberry Pi OS Lite arm64, Trixie (2026-06-18) |

**Storage budget.** This is per-mic now, because the format and sample rate
are negotiated per-mic (see [below](#using-a-different-microphone)):

| Mic | Negotiated | Rate | 128 GB card |
|---|---|---|---|
| UMIK-1 | 48 kHz / 24-bit / mono | 144 KB/s → 518 MB/hour → **12.4 GB/day** | ~10 days |
| RODE NT1, mono | 192 kHz / 32-bit float | 768 KB/s → 2.8 GB/hour → **66 GB/day** | **~2 days** |
| RODE NT1, stereo | 192 kHz / 32-bit float | 1.5 MB/s → 5.5 GB/hour → **133 GB/day** | **~1 day** |
| Dodotronic Ultramic 250K | 250 kHz / 16-bit / mono | 500 KB/s → 1.8 GB/hour → **43 GB/day** | **~2.9 days** |

The RODE is asked for maximum quality on purpose. If that is the wrong trade
for your deployment, `UMIK_RATE=48000` brings it back to 691 MB/hour mono
without touching anything else. The recorder logs the negotiated format's
actual B/s and MB/hour on its `capture format` line, so the card's own log
always says what that particular mic cost that particular session. Below
512 MB free the recorder stops cleanly rather than letting `arecord`
crash-loop against a full disk.

### Using a different microphone

Out of the box the recorder matches three USB vendor IDs — miniDSP (`2752`,
both UMIK-1 hardware revisions), RODE (`19f7`, the NT1 5th Gen), and
Dodotronic (`0869`, the Ultramic) — so any of them can be plugged in and
recorded with no config change at all. Swap them freely;
whichever one is attached wins, and every session records which it was (see
[`session.json`](#chain-of-custody) below).

Each known vendor carries its own **capture preference** — the order in which
the probe asks the hardware for a format and a sample rate. The probe still
decides; the table only sets what gets asked for first, so a mic that cannot
do its first choice quietly lands on the next:

| Vendor | Formats tried, in order | Rates tried, in order |
|---|---|---|
| `2752` miniDSP | `S24_3LE S32_LE S16_LE FLOAT_LE` | `48000` |
| `19f7` RODE | `FLOAT_LE S32_LE S24_3LE S16_LE` | `192000 96000 48000` |
| `0869` Dodotronic | `S16_LE` | `250000 384000 200000 192000 96000 48000` |
| anything else | `S24_3LE S32_LE S16_LE FLOAT_LE` | `48000` |

The UMIK-1's row is exactly what this recorder has always asked for, so its
sessions stay byte-for-byte comparable with every one already in the archive.
The RODE's row asks for the best the mic will give — 32-bit float, highest
rate first — which is a deliberate quality-over-storage choice; the storage
budget table above says what it costs, and `UMIK_RATE` is the knob if that is
not the trade you want. The probe goes rate-outermost, then channel
count, then format, so at the top rate it tries mono before stereo before
dropping to the next rate down. Adding a vendor is one line in `mic_prefs()`.

**The Dodotronic Ultramic 250K** is an ultrasonic MEMS mic: fixed 250 kHz,
16-bit, mono (it captures 0–125 kHz), so its row asks for exactly that, with
its siblings' rates behind it. It is here for sounds that may start out
ultrasonic and land somewhere near the audible range after bouncing around a
room, so the full band matters. It needs a **mini-USB B** to USB-A cable (not
the UMIK's USB-C one). Gain is three hardware levels on DIP switches inside the
tube; there is no software control, so `session.json` cannot record which one
was set. Write it down. Its vendor ID is `0869` (a 250K enumerates as
`0869:0306`, product string "UltraMic 250K 16 bit r4" - field-confirmed). As a
belt to those braces the recorder also takes any sound card whose USB product
or manufacturer string contains `UltraMic`, `Ultramic`, or `Dodotronic`
(`UMIK_MATCH_NAME`), and the `found` line in the card log says which rule
matched. After its first boot, the card's `logs/diag-latest.log`
(written by `umik-diag`) shows what it really enumerates as: every USB
device's `VID:PID` and product string, plus the mic's own list of formats and
rates; `lsusb` says the same on any Linux box. If the ID differs, put it in
`UMIK_VID` (and in the udev rule, if you enabled that).

Nothing downstream is mic-specific — the format probe asks the hardware what it
accepts, and the calibration gain reads `unknown` when the product string has
none — so the vendor list is a knob:

```sh
sudo systemctl edit umik-record        # then add, under [Service]:
# Environment=UMIK_VID="2752 19f7 0869"       # the shipped default
# Environment=UMIK_VID="2752 19f7 0869 046d"  # add another (lsusb for the ID)
# Environment=UMIK_VID=046d            # or pin exactly one vendor
# Environment=UMIK_VID=any             # first USB audio capture device found
```

Space- or comma-separated, either works. `UMIK_PID` narrows the match to a
single product, but only when `UMIK_VID` names exactly one vendor — a product
ID is unique only within a vendor, so pairing it with a list is meaningless and
the recorder ignores it with a warning in the log.

`/proc/asound` only lists sound cards, so even `any` cannot select a keyboard.
Two catches:

* If you enabled the optional default-deny udev rule, add your vendor's ID
  there too, or the device is refused before ALSA ever sees it. `2752`,
  `19f7`, and `0869` are already in it; the product-string fallback cannot be
  expressed there, so an Ultramic under any other ID must be added by hand.
* `UMIK_FORMAT` and `UMIK_RATE` override the preference table above, and both
  take a list (space- or comma-separated) or a single value. Whatever they
  hold is tried in the order given.
* Whatever gets negotiated is recorded in `session.json` under `format`, and
  the whole toolchain follows it: `tools/repair-wav.sh` never looks at the
  sample format at all, and `tools/umik-viewer.py` decodes 16/24/32-bit
  integer PCM and 32/64-bit float at any rate, reading each file's own byte
  rate rather than assuming 48 kHz. Its frequency axis is labelled with the
  file's real Nyquist (24 kHz, 96 kHz, 125 kHz). Above 96 kHz, which browsers
  do not reliably play, it plays the audible band (low-passed and decimated to
  ≤50 kHz) by default, or a ×10 time expansion: the native samples at a tenth
  of the rate, so 20–125 kHz comes out as 2–12.5 kHz, ten times slower. The
  playhead stays in recording seconds either way.

---

## Recording from an SDR

The same box can record radio, too. Plug an RTL-SDR dongle into any USB-A
port and `umik-sdr` scans the spectrum, works out which channels are in use,
and records a short clip of raw IQ from each, pass after pass, for as long as
it has power. Same air-gap, same clock-trust ladder, same stick, same sealing;
the session holds IQ instead of WAV.

**Hardware.** A Nooelec NESDR SMArt v5: RTL2832U with an R820T2 tuner, 0.5 ppm
TCXO, 100 kHz to 1.75 GHz, USB ID `0bda:2838`. Put the antenna on its
magnetic-base cable, well away from the stick and the Pi; both radiate
broadband noise, the same reason a GPS module sits away from a USB 3.0 stick.
The dongle is **receive-only**: like the GPS it has no transmitter, so the
air-gap holds and none of the four radio-silence layers changes.
`umik-sdr.service` still `Requires=` the same radio check as the mic recorder.

**What it does.** Each pass starts with `rtl_power`: a sweep of 108 MHz to
1.75 GHz in 50 kHz bins, plus finer 10 kHz scans of the FM band and of the VHF
and UHF voice bands (136–174 and 400–520 MHz), three sweeps each. A signal is
anything 10 dB over the local noise floor in every sweep, or 14 dB if it comes
and goes. An FM station becomes one channel, and so does a wide transmitter (an
LTE carrier, a Wi-Fi channel, a UHF TV channel) rather than the dozens of bins
it covers; the phone uplink bands, your own phone's included, are never
listened to. A channel seen in two or more scans stays in the rotation for 8
passes after it was last seen (2 if it was seen once), so an intermittent
transmitter keeps getting visits. Up to 120 channels (the strongest, when there
are more) are then recorded in shuffled order, ~15 s each, with random gaps
between channels and a random pause of up to 3 minutes between passes. The
timing is randomised so the schedule can't be learned, and so is the scanning:
rtl_power always climbs from the bottom of a range, so each long scan is swept
as four contiguous parts in a fresh random order every sweep, and the order of
the scans themselves is shuffled every sweep too (`UMIK_SDR_SCAN_SEGMENTS`).

**Two gains.** Measured with the SMArt v5 (2026-10-10): in the FM band a strong
local station compresses the tuner above ~20 dB and its skirts read as signals,
so the band gets 15.7 dB (`UMIK_SDR_GAIN_WIDE`). Everywhere else the 8-bit ADC
is the limit, with ~2 LSB of noise at 25.4 dB (UHF); 37.2 dB (`UMIK_SDR_GAIN`)
lifts weak carriers 3–5 dB, and nothing clips, even at 49.6. The main scan
starts at 108 MHz, so the FM band is left to its own fine scan.

**Storage budget.** IQ costs 2 bytes a sample (8-bit I and Q), whatever the
signal:

| Channel | IQ rate | Rate | 15 s clip |
|---|---|---|---|
| everything outside the FM band | 250 kS/s | 500 KB/s | **7.5 MB** |
| FM broadcast (87.5–108 MHz) | 1.024 MS/s | 2 MB/s | **30 MB** |

Only the FM band gets the wide rate: a station spreads over ±100 kHz, while a
1 MHz slice of a 6 MHz TV channel or an LTE block buys nothing. Measured on the
Mac on 2026-10-10 with the defaults above: the scans take ~80 s, and one pass
found ~90 channels after filtering, ~20 of them FM stations. At 15 s a clip
plus the random gaps that is a pass of ~30 minutes and ~1.1 GB (20 × 30 MB +
70 × 7.5 MB), so ~2.2 GB an hour, or **~22 GB a 10-hour night**; the number of
FM stations in range moves it most, since each one is a 30 MB clip. A 128 GB
stick holds 5 nights, a 256 GB one about 11. Below 512 MB free it stops
cleanly, like the mic.

**Sessions** sit beside the mic's, with their own counter
(`.sdr-session-counter`):

```
/data/usb/recordings/
  umik1-sdr_000003_20261010T230000Z/
    session.json                              unit, clock trust, dongle, every scan and capture setting
    scan-p0001-main.csv.gz                    pass 1's raw rtl_power sweep, gzipped (also -fm, -vhf, -uhf)
    scan-p0001.json                           pass 1: every detection, and the channel plan
    clip-20261010-231502-104100k.sigmf-data   ~15 s of raw IQ at 104.1 MHz
    clip-20261010-231502-104100k.sigmf-meta   what that IQ is (SigMF metadata, JSON)
    clips.jsonl                               one line per clip: frequency, rate, SNR, kind, band
```

Each clip is a [SigMF](https://sigmf.org) recording, two files with one name.
The `.sigmf-data` is the IQ exactly as `rtl_sdr` wrote it; the `.sigmf-meta`
says what it is: sample rate, tuned frequency, start and end times, clock
trust, the scan's evidence for the channel, and a SHA-512 of the data.

Everything is flat in the session directory, because `umik download` seals
top-level files only. Each clip's data is written as `.part` and renamed once
it is complete, then its meta the same way, so pulling the plug costs at most
the clip in flight. That leftover `.part` is not a recording: it is never
sealed, `umik download` says how many it left on the stick, and `umik-sdr`
deletes it the next time it starts, along with any `.sigmf-data` whose
`.sigmf-meta` never landed (the plug pulled in the moment between the two
renames; without its meta the IQ is unreadable).

**Reading a clip.** A clip is a standard SigMF recording, so any SigMF-aware
tool opens it as it is; the `.sigmf-meta` carries everything needed to read
it. The data is `rtl_sdr`'s native `cu8`, untouched: unsigned 8-bit I, then
Q, and sample = (byte − 127.5) / 127.5. The meta has the sample rate, the
tuned centre (`core:frequency`), the start time to the millisecond, and a
SHA-512 of the data, and under `umik:` the target, the offset, the clock
trust, the scan's evidence, and `started_mono` (seconds since boot), which
spaces clips exactly even when the wall clock is not trusted. The dongle is
tuned a quarter of the IQ rate above the target to keep its DC spike off it,
so the target sits at −`umik:offset_hz` in the clip, where an annotation
marks the channel's measured width. `clips.jsonl` indexes the same clips, one
line each.

**Two recorders, one box.** Both are installed on every card, and each waits
for its own device (the mic for 60 s, the dongle for 30 s):

| Attached | `umik-record` | `umik-sdr` |
|---|---|---|
| mic | records | exits 79 |
| dongle | exits 79 | records |
| both | records | records, in its own session |
| neither | FATAL, retries with backoff | FATAL, retries with backoff |

Exit 79 means "not my device": mine is missing and the other recorder's is
here. The recorder logs one line and stops, and its unit counts that as
success and never restarts it, so it ends *inactive*, not failed. A mic-only
unit therefore runs exactly as before, plus one line in `umik.log` per boot. A
recorder that bowed out stays out until the next boot: plug the other device
in, then power-cycle.

**Build step.** Pi OS Lite has no `rtl-sdr`, and provisioning never touches a
network, so the packages ride along in the payload. Run this once, any time
before `03-inject`:

```sh
./build/05-fetch-sdr-debs.sh     # cached in cache/debs/; a re-run fetches nothing
```

It fetches three Debian trixie arm64 packages through the same `fetch()` as
the OS image: `rtl-sdr`, `librtlsdr0`, and `libusb-1.0-0` (already on the
image; a spare). Each one is checked against a SHA-256 pinned in the script,
and the script writes `cache/debs/SHA256SUMS` for the Pi. `03-inject` copies
them onto the card (about 140 KB), and firstrun re-checks them with
`sha256sum -c`, then installs with `dpkg` only what is missing or older.
Every card carries the SDR role: all units are functionally identical, and
what a box does is decided by what is plugged into it at boot. `03-inject`
therefore refuses to run without the cache; `--no-sdr` builds a mic-only
card on purpose, with `umik-sdr` left disabled.

**The DVB driver.** The RTL2832U started life as a DVB-T TV stick, and the
kernel's TV driver (`dvb_usb_rtl28xxu`) claims the dongle the moment it
enumerates. Neither Debian package blacklists it, so
`/etc/modprobe.d/umik-sdr.conf` does: `blacklist` plus `install … /bin/false`
for the driver, its demodulators, and its tuner. The `--- sdr ---` block of
`logs/diag-latest.log` shows whether any of them loaded, along with `lsusb` and
the dongle's device permissions.

**LEDs** mean what they always did; green now answers for both recorders. It
blips while either one is verifiably writing: a mic segment growing, or an SDR
clip or scan finished within the last 6 minutes (the SDR writes in bursts, and
a pass pause plus the next scan can leave minutes without a new file). Fast
blink means a recorder failed, or both have stopped. A recorder that exited 79
is idle, not trouble.

**Tunables**, via `sudo systemctl edit umik-sdr`, as `Environment=` lines:

| Variable | Default |
|---|---|
| `UMIK_SDR_GAIN` / `UMIK_SDR_GAIN_WIDE` | `37.2` / `15.7` dB of R820T2 tuner gain (everything outside the FM band / the FM band's scan and channels; a scan reaching past 87.5–108 MHz takes `UMIK_SDR_GAIN`). Fixed, so passes stay comparable; `auto` is allowed |
| `UMIK_SDR_PPM` | `0` (frequency correction; the SMArt's TCXO is 0.5 ppm) |
| `UMIK_SDR_SCAN` | `108-1750:50`, the main scan: MHz range, then bin width in kHz. It starts at 108 MHz, so the FM band is scanned only by its fine scan, at `UMIK_SDR_GAIN_WIDE` |
| `UMIK_SDR_FINE` | `87.5-108:10 136-174:10 400-520:10`, the finer scans (space-separated): the FM band, and the VHF and UHF voice bands, where a 12.5 kHz voice channel loses ~5 dB in the main scan's 44 kHz bins |
| `UMIK_SDR_SWEEPS` | `3` per scan |
| `UMIK_SDR_SCAN_SEGMENTS` | `4` rtl_power runs per sweep of a scan, over contiguous parts of its range in random order, so a sweep never has to start at the bottom; a scan with fewer than 8 hops a part (the FM and VHF fine scans) runs whole. `1` sweeps every scan in one run |
| `UMIK_SDR_THR` / `UMIK_SDR_THR_BURST` | `10` / `14` dB over the local floor, for a continuous / an intermittent signal. rtl_power averages many FFTs into every bin, so 10 dB is never noise; lower only adds real but dull channels, which `UMIK_SDR_MAX_CHANNELS` caps |
| `UMIK_SDR_EXCLUDE` | `698-716 777-787 824-849 960-1215` MHz, never listened to: the LTE uplink bands 12/17, 13 and 5, where phones (yours too) transmit, and the aviation DME/TACAN band, strong pulses that are never voice, with the SMArt v5's own strongest spur block (1004–1013 MHz) inside it |
| `UMIK_SDR_DWELL` / `UMIK_SDR_JITTER` | `15` s / `0.3`: each clip is dwell × U(0.7, 1.3) |
| `UMIK_SDR_GAP_MAX` / `UMIK_SDR_PASS_PAUSE_MAX` | `5` / `180` s of random idle, between channels / between passes |
| `UMIK_SDR_REMEMBER_PASSES` / `UMIK_SDR_REMEMBER_ONCE` | `8` / `2` passes a channel stays after it was last seen (seen in ≥2 scans / in one) |
| `UMIK_SDR_IQ_RATE` / `UMIK_SDR_IQ_RATE_WIDE` | `250000` / `1024000` samples/s (every channel outside the FM band / FM-band channels) |
| `UMIK_SDR_MAX_CHANNELS` | `120` per pass, strongest kept |
| `UMIK_SDR_CROP` | `0` (rtl_power `-c` percent, discarding each hop's rolled-off edges). Off by default: the recorder measures the hop-edge roll-off in every sweep and removes it instead; set 20 if a real spectrum proves that wrong |
| `UMIK_SDR_WAIT_SECONDS` | `30`, the wait for the dongle to enumerate |
| `UMIK_MIN_FREE_MB` / `UMIK_LOG_INTERVAL` | `512` / `60`, the same names (and defaults) as the mic's |

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
| green | solid | a recorder running but not writing yet — suspicious after minutes |
| green | **blip every 2 s** | **recording**, verified: the segment file is growing (or an SDR clip or scan was just written) |
| green | fast blink | trouble: radio-check failed, a recorder died, or disk full |
| red (PWR) | off | clock trust not yet determined |
| red | **solid** | **clock trusted** — NTP or GPS this boot, or carried by the RTC |
| red | slow blink | no trusted time |

Happy state at a distance: **green blipping, red solid.** With an RTL-SDR
attached, green answers for both recorders; see
[Recording from an SDR](#recording-from-an-sdr).

---

## Build

Flash the stock image, drop a provisioning payload on the FAT boot partition
(which macOS mounts natively), and let the Pi harden itself on first boot:

```
build/     runs on the Mac      fetch → verify → decompress → flash → inject
boot/      lands on the card    firstrun.sh + payload/ (services, scripts, config)
tools/     host-side utilities  umik · umik-ingest.sh · umik-upload.sh ·
                                umik-verify-s3.sh · umik-lib.sh · umik-viewer.py ·
                                repair-wav.sh · recovery/ (successor kit)
```

```sh
./build/00-fetch-verify.sh              # download + SHA-256 verify
./build/05-fetch-sdr-debs.sh            # RTL-SDR tools, 3 pinned .debs (every card gets them)
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
    session.json               mic, device, gain, format, clock trust, GPS fix
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

**Preparing a stick:** none needed beyond a filesystem the Pi can mount —
`umik-usb-detect` creates `recordings/` and `logs/` itself. exFAT is the
sensible choice (no 4 GB file cap, no per-write `flush` mount option), with a
label that names the stick, not a unit — sticks move between Pis and the
archive files sessions by the unit stamped in `session.json`, never by the
volume label:

```bash
diskutil eraseDisk ExFAT UMIK3 MBR /dev/diskN     # diskutil list → find N
date -u +%s > /Volumes/UMIK3/umik-time-seed       # optional clock floor for the first boot
```

Three sticks (`UMIK2`, `UMIK3`, and unit 1's still-labelled `TESLADRIVE`)
rotate between the two units: one in each Pi, one travelling or sitting in
the Mac. A spare means the collection loop never waits on `umik process`.

`umik download` seals every mounted medium, then clears each recording **only
after its archived copy re-verifies by hash** — media go back empty,
`~/UMIK-Archive` is the truth, and anything unverified stays put loudly.

`umik process` is the same loop with the off-site legs folded in and run at
the same time: seal + verify, then clear+eject the stick *while* the S3
upload+verify and the NAS copy+re-hash (`UMIK_NAS_DIR`, see
`umik.local.conf.example`; the path must sit on a mounted network share, and
is re-checked before every write, so an unmounted mount point can never pass
local disk off as the NAS) run alongside it. Local audio is deleted only once
**both** off-box copies verified against the seals (`--keep-local` to never
delete). Sealing itself runs `UMIK_INGEST_JOBS` files at a time (default 4),
hashing with the system `openssl` — about 5× faster than `shasum` on Apple
silicon — and the copy-and-compare it used to do per file to detect a
power-cut header is now a header check, so the ingest is bound by how fast
the stick reads.

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

`umik upload` writes the archive into your bucket (or `umik download --upload`
to chain it): dated sessions under `raw/<YYYY-MM-DD>/<unit>/<session>/`,
untrusted-clock sessions under `raw/undated/<unit>/…` — the date prefix is
earned by `clock_trusted`, never guessed. Uploads read only the archive, are
add-only and idempotent; each run also pins its own write-once
`manifest/<utc-stamp>_<head>/` set, putting the whole archive history off-site.

**Every object is written exactly once.** Each file goes up as a single-part
`PutObject` carrying `--checksum-sha256` set to *its `SHA256SUMS` seal*, so S3
hashes what it actually receives and refuses the request unless it matches the
seal — a corrupted or truncated transfer cannot be stored at all. Because the
PUT is single-part, the checksum S3 keeps is a whole-object SHA-256, directly
comparable to the seal forever after. `--if-none-match '*'` makes each write
conditional on the key not existing, so a re-run can only add. Nothing is ever
overwritten, restamped or repaired in place; that matters most on a bucket with
Object Lock, where a "fix" is just a second undeletable version of the same key.

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
   (versioning is what makes the add-only design tamper-evident). Object Lock
   in compliance mode is a good fit here and costs nothing extra, because the
   uploader never writes a key twice — so no locked, undeletable second
   version of anything is ever created.
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

   (`ListBucket`/`GetObject` are what let both tools read an object's stored
   checksum back with `HeadObject` — that is how `umik upload` skips what is
   already there and how `verify-s3` checks it. `verify-s3` needs no write
   permission at all.)
3. `brew install awscli`, `aws configure --profile umik`, then
   `aws s3 ls s3://YOUR-BUCKET/ --profile umik` to sanity-check.
</details>

### Proving the bucket holds what you sealed

Completeness is not correctness. An S3 ETag is a multipart digest comparable to
nothing, so "the mirror looks complete" never meant "the mirror is correct."
That gap matters the moment you consider deleting the local archive.

```sh
umik verify-s3                 # read back every stored checksum and verify
```

The proof is really made at write time — S3 will not store bytes that do not
hash to the seal `umik upload` hands it — and `verify-s3` is how you confirm,
later and independently, that the bucket still holds exactly that. It reads
each object's stored whole-object SHA-256 with `HeadObject` and diffs it
against the `SHA256SUMS` seals. **The data never leaves AWS, so verifying
hundreds of gigabytes costs API calls instead of egress**, and the run is
strictly read-only: no writes, no new object versions, nothing to expire.

```
==> VERIFIED (S3 bytes match the seal) : 2478
==> MISMATCHED                         : 0
==> ALL 2478 OBJECT(S) VERIFIED against their seals
```

It exits non-zero on any mismatch and says not to delete the local copy. An
object carrying no whole-object SHA-256 — none at all, or a *composite* one (a
hash of part hashes, left by a multipart upload) — counts as a mismatch, since
neither can be compared to a seal and neither can be repaired in place.

Both tools build the same local-file-to-S3-key map, from `tools/umik-lib.sh`.
That is on purpose: if the uploader and the verifier disagreed about which file
is which key, the disagreement would show up as a phantom gap, or as a key
nobody ever checked.

> `--verify-only` is still accepted and does nothing. It used to mean "skip the
> stamping pass"; there is no longer a stamping pass to skip.

### If something happens to you

An off-site archive nobody else can reach is not a backup. `tools/recovery/`
is a kit for whoever has to retrieve the recordings without you:

```sh
aws login --profile admin                                  # root/admin session
./tools/recovery/create-recovery-user.sh --profile admin   # read-only IAM user + key
./tools/recovery/build-pdf.sh \
    --credentials ~/UMIK-Archive/recovery/umik-recovery-credentials.txt
```

`create-recovery-user.sh` makes an IAM user that can list, read and restore
from the bucket and is explicitly denied every write, delete and retention
action; it writes the console password and access key to a `chmod 600` file
and self-tests both the read and the deny. `build-pdf.sh` fills
`instructions.md` from the live bucket (counts, size, dates, storage classes,
costs) and renders a plain-language PDF: where the copies are, how to browse
in the S3 console, how to download everything with one `aws s3 sync`, what to
do if the archive has been moved to a Glacier tier, and why the AWS bill must
keep being paid. With `--credentials` the PDF contains the key and password:
print it, and store it like a key. Without it, the credentials page has blanks
to fill in by hand. `umik-recover.sh` is the one-command downloader the PDF
points at (inventory, disk check, bulk Glacier restore, resumable sync,
`SHA256SUMS` verification); it is copied beside the PDF. Set `UMIK_NAS_LOCATION` and `UMIK_ROOT_LOGIN_LOCATION` in
`umik.local.conf` so the document can say where the local copy and the root
login live.

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
| `umik upload` | Write the archive into S3 (write-once, add-only, idempotent) |
| `umik upload --dry-run` | Show what would upload, touch nothing |
| `umik verify` | Re-verify the manifest hash chain (`--deep` re-hashes everything) |
| `umik verify-s3` | Prove the bucket holds the sealed bytes (read-only, no egress) |
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
  "device": {
    "usb_id": "2752:0007",
    "vendor_id": "2752",
    "product_id": "0007",
    "mic": "miniDSP UMIK-1",
    "product": "Umik-1  Gain:18dB",
    "manufacturer": "miniDSP",
    "serial": "unknown",
    "calibration_gain_db": "18",
    "alsa_card": 1
  },
  "format": { "encoding": "S24_3LE", "sample_rate": 48000, "bandwidth_hz": 24000, "channels": 1 }
}
```

The `device` block is how a session proves which microphone made it, which
matters once more than one mic is in rotation: `mic` is the friendly label
(`miniDSP UMIK-1`, `RODE NT1 5th Gen`), `vendor_id` / `product_id` are the two
halves of `usb_id`, and `product` / `manufacturer` / `serial` are the USB
device's own strings, sanitised, or `unknown` when the device does not publish
them. `calibration_gain_db` is parsed out of the UMIK-1's product string and
reads `unknown` for any mic that does not embed one. Under `format`,
`bandwidth_hz` is the captured band's upper edge (half the sample rate):
24000 for the UMIK-1, 96000 for the RODE at 192 kHz, 125000 for the Ultramic.

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
switches or radio firmware — and `umik-record.service` `Requires=` it (as does
`umik-sdr.service`), so **if a radio is ever live, the box refuses to record.**

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

`umik-sdr.service` gets the same sandbox with three changes, each explained in
the unit. Its only devices are USB device nodes (`char-usb_device`, which is
how libusb reaches the dongle; file permissions leave just the dongle's node
writable, by `plugdev`). It may open `AF_NETLINK` sockets, because libusb will
not start without its udev hotplug monitor, but only inside a private network
namespace that holds nothing but `lo`. And it has no capabilities at all.

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
to provision.** The one addition is optional: the SDR recorder's three Debian
packages, fetched by `05-fetch-sdr-debs.sh` through the same `fetch()`, pinned
by SHA-256 in that script, and checked again on the Pi before `dpkg` sees them.
(`rtl-sdr` also installs `rtl_tcp`, an IQ server; nothing starts it, and
`umik-sdr` runs in a network namespace holding only `lo`.)

**Known gap:** the detached GPG signature is downloaded but not checked (this
host has no `gpg`, and bootstrapping it would rest on nothing stronger than the
TLS + SHA-256 already used). With a trusted keyring:
`gpg --verify <image>.img.xz.sig <image>.img.xz`.

---

## Tunables

Via `systemctl edit umik-record` (or the named unit), as `Environment=` lines:

| Variable | Default |
|---|---|
| `UMIK_VID` | `2752 19f7 0869` (miniDSP, RODE, Dodotronic). A space- or comma-separated list of vendor IDs, or `any` for the first USB capture device |
| `UMIK_PID` | unset (any product from those vendors). Honoured only when `UMIK_VID` names exactly one vendor |
| `UMIK_MATCH_NAME` | `UltraMic Ultramic Dodotronic`. Also take a card from an unlisted vendor whose USB product or manufacturer string contains one of these (case-sensitive). Set it empty to disable; ignored under `UMIK_VID=any` or a `UMIK_PID` pin |
| `UMIK_SEGMENT_SECONDS` | `600` |
| `UMIK_RATE` | per-vendor (`48000` miniDSP, `192000 96000 48000` RODE, `250000 384000 200000 192000 96000 48000` Dodotronic). A list or a single value; first that works |
| `UMIK_CHANNELS` | `1` (falls back to `2`, then `1`) |
| `UMIK_FORMAT` | per-vendor (`S24_3LE S32_LE S16_LE FLOAT_LE` miniDSP, `FLOAT_LE S32_LE S24_3LE S16_LE` RODE, `S16_LE` Dodotronic). A list or a single value; first that works |
| `UMIK_DATA_DIR` | unset (auto: stick if mounted, else SD) |
| `UMIK_MIN_FREE_MB` | `512` |
| `UMIK_LOG_INTERVAL` | `60` (heartbeat seconds) |
| `UMIK_SDR_*` | the SDR recorder's own, via `systemctl edit umik-sdr`; see [Recording from an SDR](#recording-from-an-sdr) |
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
(or dongle) discovery, session start/stop, and a heartbeat every minute showing segment
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

**The S3 mirror is provably correct (2026-08-18).** `umik verify-s3` checked
all 1515 objects against their seals: 1515 verified, 0 mismatched. Previously
only completeness had ever been checked, never content. The uploader has since
become write-once — the seal is now handed to S3 *as* the PUT's required
checksum, so an object is proven correct the moment it lands and never has to
be touched again.

**Field-failed and pivoted from:** GPS→RTC disciplining. An outdoor boot got
its fix but `hwclock --systohc` failed with its error discarded, so the DS3231
stayed at its 2000-01-01 default. Both RTC writers now capture hwclock's error
text — which promptly exposed the real culprit: `hwclock: not found`, because
**Pi OS Lite doesn't ship it** (Debian split it into `util-linux-extra`). The
GPS boot never stood a chance. The network window now installs it alongside
chrony, and wired NTP replaced GPS as the primary time source.

Open:

- [ ] GPG signature verification (needs a trusted keyring on the Mac).
- [ ] Lifecycle rule to expire the noncurrent S3 versions left by the old
      stamping uploader (needs admin credentials; the uploader IAM user has no
      DeleteObject by design). Nothing new creates them — every write is now a
      first write.
- [ ] `umik-viewer.py` reads a local directory only; browsing straight from S3
      would need a fetch step.
- [ ] Optional field-power trim (powersave governor, Ethernet kill): ~15–20%
      more battery runtime.
- [ ] Optional UPS/supercap HAT for a truly graceful close.
- [ ] Root-cause one crash-loop boot from the first field run; mitigations are
      in and it has not recurred since.
- [ ] A Pi 5's built-in RTC should work identically (same kernel interface)
      minus the overlay — untested.
- [ ] The RTL-SDR recorder (`umik-sdr`) is new and has not run on a Pi yet;
      the first-boot checks are in `TODO.md`.

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
