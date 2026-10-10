#!/bin/bash
# Fetch the Debian packages the RTL-SDR recorder (umik-sdr) needs, and pin
# them.
#
# Pi OS Lite ships no rtl-sdr, and the Pi never touches a network to
# provision, so the packages ride along in the payload instead: this script
# fills cache/debs/, 03-inject copies it onto the card, and firstrun checks
# every file against SHA256SUMS again before dpkg ever sees it.
#
# Trust chain, the same shape as 00-fetch-verify.sh:
#   * HTTPS only, TLS >= 1.2, certificate validation mandatory, redirects
#     confined to https. See fetch() in build/lib.sh.
#   * SHA-256 pinned below, taken from Debian's trixie arm64 Packages index
#     (dists/trixie/main/binary-arm64/Packages) on 2026-10-10. A file that
#     does not match is deleted and the run stops. Moving to a newer version
#     means taking its Filename and SHA256 from that index, never from the
#     .deb itself.
#
# Three packages: rtl-sdr (rtl_power, rtl_sdr, rtl_test, ...), its library
# librtlsdr0 (which also installs the udev rule that gives the plugdev group
# the dongle), and libusb-1.0-0. The stock image already has that last one at
# this exact version; it rides along as a spare, and firstrun installs any of
# the three only when it is missing or older. libc6, the only other
# dependency, is on every image.
#
# Optional: skip this step and the card builds exactly as before, minus
# umik-sdr. Idempotent: a cached file that still matches its pin is kept.

set -euo pipefail
cd "$(dirname "$0")/.."
. build/lib.sh

# deb.debian.org drops a version from the pool once a point release
# supersedes it; snapshot.debian.org keeps every version ever published, so
# it is the fallback that keeps these pins fetchable for good. Where a file
# came from changes nothing about whether it is accepted: the pin decides.
DEBIAN=https://deb.debian.org/debian
SNAPSHOT=https://snapshot.debian.org/archive/debian/20261010T000000Z

#    pool path                                             pinned SHA-256
DEBS=(
    "pool/main/libu/libusb-1.0/libusb-1.0-0_1.0.28-1_arm64.deb 1eed4dc72f3e6fe22dc8c20aba32f0c0c596a51d3e1c1e4c401937005e78ef11"
    "pool/main/r/rtl-sdr/librtlsdr0_2.0.2-2+b1_arm64.deb       4edd72c4f9a250a237a1d6d56a3120638d147560fd9e3d7e78a693b010bbb7f9"
    "pool/main/r/rtl-sdr/rtl-sdr_2.0.2-2+b1_arm64.deb          d139e07182836a94244285f441ba8355ff7e953a58f03090837d203426d48e3e"
)

OUT="${CACHE}/debs"
mkdir -p "$OUT"
cd "$OUT"

say "SDR packages  ${OUT}"

: > SHA256SUMS.partial
for entry in "${DEBS[@]}"; do
    read -r path want <<< "$entry"
    deb=${path##*/}
    if [ ! -f "$deb" ]; then
        say "fetching ${deb}"
        fetch -o "${deb}.partial" "${DEBIAN}/${path}" \
            || fetch -o "${deb}.partial" "${SNAPSHOT}/${path}" \
            || { rm -f "${deb}.partial"; die "could not fetch ${deb} from deb.debian.org or snapshot.debian.org"; }
        mv "${deb}.partial" "$deb"
    fi
    have=$(shasum -a 256 "$deb" | cut -d' ' -f1)
    echo "    ${deb}"
    echo "        expected  ${want}"
    echo "        actual    ${have}"
    [ "$have" = "$want" ] || {
        rm -f "$deb" SHA256SUMS.partial
        die "CHECKSUM MISMATCH - ${deb} deleted, do not use"
    }
    # Two spaces: the format `sha256sum -c` (on the Pi) and `shasum -a 256 -c`
    # (here, in 03-inject) both read.
    printf '%s  %s\n' "$want" "$deb" >> SHA256SUMS.partial
done
mv SHA256SUMS.partial SHA256SUMS

say "SHA-256 VERIFIED: $(wc -l < SHA256SUMS | tr -d ' ') package(s); 03-inject carries them to the card"
