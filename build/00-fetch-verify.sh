#!/bin/bash
# Fetch Raspberry Pi OS Lite arm64 and verify it.
#
# Trust chain:
#   * HTTPS only, TLS >= 1.2, certificate validation mandatory, redirects
#     confined to https. See fetch() in build/lib.sh.
#   * SHA-256 compared against the checksum published alongside the image.
#
# The detached GPG signature (.sig) is downloaded for the record but is NOT
# verified here: this host has no gpg, and bootstrapping gnupg from source
# would itself rest on nothing stronger than TLS + SHA-256. If you have a
# trusted keyring, verify manually:
#
#     gpg --verify <image>.img.xz.sig <image>.img.xz

set -euo pipefail
cd "$(dirname "$0")/.."
. build/lib.sh

cd "$CACHE"

say "release  ${RELEASE}"
say "cache    ${CACHE}"

for suffix in .img.xz.sha256 .img.xz.sig; do
    [ -f "${IMAGE_BASE}${suffix}" ] && continue
    say "fetching ${IMAGE_BASE}${suffix}"
    fetch -O "${MIRROR}/${IMAGE_BASE}${suffix}"
done

if [ ! -f "${IMAGE_BASE}.img.xz" ]; then
    say "fetching ${IMAGE_BASE}.img.xz (~500 MB)"
    fetch --progress-bar -o "${IMAGE_BASE}.img.xz.partial" \
          "${MIRROR}/${IMAGE_BASE}.img.xz"
    mv "${IMAGE_BASE}.img.xz.partial" "${IMAGE_BASE}.img.xz"
fi

say "verifying SHA-256"
EXPECT=$(cut -d' ' -f1 < "${IMAGE_BASE}.img.xz.sha256")
ACTUAL=$(shasum -a 256 "${IMAGE_BASE}.img.xz" | cut -d' ' -f1)
echo "    expected  ${EXPECT}"
echo "    actual    ${ACTUAL}"
[ "$EXPECT" = "$ACTUAL" ] || {
    rm -f "${IMAGE_BASE}.img.xz"
    die "CHECKSUM MISMATCH - image deleted, do not use"
}

say "SHA-256 VERIFIED"
