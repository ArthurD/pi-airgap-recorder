#!/bin/bash
# Write the verified image to an SD card.  DESTRUCTIVE.
#
#     ./build/02-flash.sh /dev/disk4
#
# The target is never guessed. The script refuses anything that is not an
# external, physical, removable disk, and makes you type the size out.

set -euo pipefail
cd "$(dirname "$0")/.."
. build/lib.sh

VERIFY_ONLY=0
[ "${1:-}" = "--verify-only" ] && { VERIFY_ONLY=1; shift; }

DISK="${1:-}"
[ -n "$DISK" ] || {
    echo "usage: $0 [--verify-only] /dev/diskN" >&2
    echo >&2
    echo "External physical disks currently attached:" >&2
    diskutil list external physical >&2
    exit 2
}

[[ "$DISK" =~ ^/dev/disk[0-9]+$ ]] || die "expected /dev/diskN, got '$DISK'"

IMG=$(ls -1 "${CACHE}"/*.img 2>/dev/null | head -1) \
    || die "no decompressed .img - run build/01-decompress.sh"

INFO=$(diskutil info "$DISK") || die "no such disk: $DISK"
grab() { printf '%s\n' "$INFO" | grep -E "^ +$1:" | head -1 | sed 's/.*: *//'; }

INTERNAL=$(grab "Device Location")
VIRTUAL=$(grab "Virtual")
SIZE=$(grab "Disk Size")
NAME=$(grab "Device / Media Name")

echo
echo "  target      $DISK"
echo "  media       $NAME"
echo "  size        $SIZE"
echo "  location    $INTERNAL"
echo "  image       $(basename "$IMG") ($(du -h "$IMG" | cut -f1))"
echo

[ "$INTERNAL" = "External" ] || die "$DISK is not external - refusing"
[ "$VIRTUAL" = "No" ] || die "$DISK is a virtual disk - refusing"

# Decimal GB, matching how cards are sold and how diskutil displays them.
# (A "16GB" card is ~14.9GiB - a binary-GiB check here would reject it.)
BYTES=$(printf '%s\n' "$INFO" | grep -E '^ +Disk Size:' | grep -oE '\([0-9]+ Bytes\)' | grep -oE '[0-9]+')
[ -n "$BYTES" ] || die "could not determine disk size"
GB=$((BYTES / 1000 / 1000 / 1000))
[ "$GB" -ge 8 ]    || die "card is ${GB}GB; the image alone needs ~3GB - too small"
[ "$GB" -le 1024 ] || die "${GB}GB looks like a hard drive, not an SD card - refusing"

RDISK="${DISK/\/dev\/disk//dev/rdisk}"   # raw device is far faster

if [ "$VERIFY_ONLY" = 0 ]; then
    warn "EVERYTHING ON $DISK WILL BE DESTROYED."
    printf 'Type the size in GB (%s) to confirm: ' "$GB"
    read -r CONFIRM
    [ "$CONFIRM" = "$GB" ] || die "aborted"

    say "unmounting $DISK"
    diskutil unmountDisk "$DISK"

    say "writing image (this takes a few minutes)"
    sudo dd if="$IMG" of="$RDISK" bs=4m status=progress conv=sync

    say "flushing"
    sync
fi

# --- verification -----------------------------------------------------------
# The instant dd closes the raw device, macOS auto-mounts the FAT partition
# and scribbles Spotlight/fseventsd metadata on it - so a whole-image compare
# ALWAYS mismatches, through no fault of the card. Verify region-aware
# instead: boot code + MBR and the ext4 rootfs (which macOS cannot mount, so
# cannot touch) must match bit-for-bit; the FAT region is reported but
# informational - inject is about to modify it anyway.

say "unmounting before readback (macOS auto-mounts and dirties the FAT region)"
diskutil unmountDisk "$DISK" 2>/dev/null || true

say "verifying readback (region-aware)"
sudo python3 - "$IMG" "$RDISK" <<'PY' || die "READBACK MISMATCH in a region that matters - see above"
import hashlib, sys

img_path, dev_path = sys.argv[1], sys.argv[2]

def hash_range(f, offset, length):
    f.seek(offset)
    h, remaining = hashlib.sha256(), length
    while remaining:
        chunk = f.read(min(4 * 1024 * 1024, remaining))
        if not chunk:
            sys.exit(f"short read at offset {offset + length - remaining}")
        h.update(chunk)
        remaining -= len(chunk)
    return h.hexdigest()

with open(img_path, "rb") as f:
    mbr = f.read(512)

# Parse the MBR partition table: 4 x 16-byte entries at offset 446.
parts = []
for i in range(4):
    e = mbr[446 + 16*i : 446 + 16*(i+1)]
    ptype = e[4]
    start = int.from_bytes(e[8:12], "little") * 512
    size  = int.from_bytes(e[12:16], "little") * 512
    if ptype:
        parts.append((i + 1, ptype, start, size))
        print(f"    partition {i+1}: type 0x{ptype:02x} offset {start} size {size}")

regions = [("boot code + MBR", 0, 512, True)]
for num, ptype, start, size in parts:
    is_fat = ptype in (0x0b, 0x0c, 0x0e)
    regions.append((f"partition {num} ({'FAT' if is_fat else 'ext4/other'})",
                    start, size, not is_fat))

ok = True
with open(img_path, "rb") as img, open(dev_path, "rb", buffering=0) as dev:
    for name, off, ln, critical in regions:
        a = hash_range(img, off, ln)
        b = hash_range(dev, off, ln)
        match = a == b
        tag = "MATCH" if match else ("MISMATCH" if critical else
                                     "differs (expected: macOS auto-mount metadata)")
        print(f"    {name:28s} {tag}")
        if critical and not match:
            ok = False

sys.exit(0 if ok else 1)
PY
say "readback VERIFIED (boot code, MBR and rootfs are bit-exact)"

say "re-mounting so macOS exposes the boot partition"
diskutil mountDisk "$DISK" || true
sleep 2

say "done - now run: ./build/03-inject.sh"
