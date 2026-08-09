#!/bin/bash
# Add a Mac-readable exFAT data partition to the freshly-flashed card.
#
#     ./build/04-add-data-partition.sh /dev/diskN
#
# Layout produced (MBR):
#   p1  FAT32  bootfs          (unchanged, from the image)
#   p2  ext4   root            (grown to end at ROOT_GIB, default 8 GiB;
#                               firstrun runs resize2fs to fill it)
#   p3  exFAT  UMIKDATA        (rest of the card - recordings, Mac-readable)
#
# The stock initramfs auto-resize ("resize" in cmdline.txt) grows p2 with
# `parted resizepart`, which fails harmlessly when p3 sits after it - the new
# partition is its own guard rail. Run this AFTER 02-flash, BEFORE 03-inject.

set -euo pipefail
cd "$(dirname "$0")/.."
. build/lib.sh

ROOT_GIB=${UMIK_ROOT_GIB:-8}

DISK="${1:-}"
[ -n "$DISK" ] || {
    echo "usage: $0 /dev/diskN" >&2
    diskutil list external physical >&2
    exit 2
}
[[ "$DISK" =~ ^/dev/disk[0-9]+$ ]] || die "expected /dev/diskN, got '$DISK'"
RDISK="${DISK/\/dev\/disk//dev/rdisk}"

INFO=$(diskutil info "$DISK") || die "no such disk: $DISK"
printf '%s\n' "$INFO" | grep -qE '^ +Device Location: +External' || die "$DISK is not external - refusing"
BYTES=$(printf '%s\n' "$INFO" | grep -E '^ +Disk Size:' | grep -oE '\([0-9]+ Bytes\)' | grep -oE '[0-9]+')
[ -n "$BYTES" ] || die "could not determine disk size"

say "unmounting $DISK"
diskutil unmountDisk "$DISK" 2>/dev/null || true

say "rewriting MBR: root -> ${ROOT_GIB}GiB, exFAT data partition after it"
sudo python3 - "$RDISK" "$BYTES" "$ROOT_GIB" <<'PY' || die "MBR edit refused - see message above"
import sys

dev, disk_bytes, root_gib = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
disk_sectors = disk_bytes // 512
ALIGN = 8192                                # 4 MiB in sectors

with open(dev, "r+b", buffering=0) as f:
    mbr = bytearray(f.read(512))
    assert mbr[510:512] == b"\x55\xaa", "no MBR signature - is this a flashed card?"

    def entry(i):
        e = mbr[446 + 16*i : 446 + 16*(i+1)]
        return e[4], int.from_bytes(e[8:12], "little"), int.from_bytes(e[12:16], "little")

    t1, s1, n1 = entry(0)
    t2, s2, n2 = entry(1)
    t3, s3, n3 = entry(2)
    t4, s4, n4 = entry(3)

    if t1 not in (0x0b, 0x0c, 0x0e) or t2 != 0x83:
        sys.exit(f"unexpected layout: p1 type 0x{t1:02x}, p2 type 0x{t2:02x} - "
                 "expected FAT boot + Linux root from a fresh flash")
    if t3 or t4:
        sys.exit("partition 3/4 already present - card is not freshly flashed, refusing")

    root_end = (root_gib * 2 * 1024 * 1024 // ALIGN) * ALIGN   # sector count, aligned
    if root_end <= s2 + n2:
        sys.exit(f"root already ends at {s2+n2}, beyond the requested {root_end} - refusing to shrink")
    data_start = root_end
    data_size = disk_sectors - data_start
    if data_size < 2 * 1024 * 1024:
        sys.exit("less than 1 GiB would remain for data - card too small")

    # p2: same start, new size. CHS fields left as-is (ignored by everything modern).
    mbr[446 + 16*1 + 12 : 446 + 16*1 + 16] = (root_end - s2).to_bytes(4, "little")
    # p3: type 0x07 (exFAT), CHS set to the standard "use LBA" filler.
    mbr[446 + 16*2 : 446 + 16*3] = (
        b"\x00" + b"\xfe\xff\xff" + b"\x07" + b"\xfe\xff\xff"
        + data_start.to_bytes(4, "little") + data_size.to_bytes(4, "little")
    )

    f.seek(0)
    f.write(mbr)

print(f"    p2 root : sectors {s2}..{root_end}  ({(root_end-s2)*512//10**9} GB)")
print(f"    p3 data : sectors {data_start}..{disk_sectors}  ({data_size*512//10**9} GB)")
PY

# Closing the raw device makes diskarbitrationd re-read the partition table,
# so the new slice node appears on its own - no need to re-insert the card.
# (macOS may pop a "disk not readable" dialog for the unformatted slice;
# dismiss it with Ignore.)
say "waiting for ${DISK}s3 to appear"
for _ in $(seq 1 15); do
    [ -e "${DISK}s3" ] && break
    sleep 1
done
[ -e "${DISK}s3" ] || die "${DISK}s3 never appeared - eject, re-insert the card, and re-run"

say "formatting ${DISK}s3 as exFAT (UMIKDATA)"
diskutil unmountDisk "$DISK" 2>/dev/null || true
sudo newfs_exfat -v UMIKDATA "${DISK}s3"

say "re-mounting"
diskutil mountDisk "$DISK" 2>/dev/null || true
sleep 2

say "done - now run: ./build/03-inject.sh"
