#!/bin/bash
# Inject the provisioning payload onto the card's FAT boot partition.
#
# macOS cannot write ext4 without third-party kernel extensions, so every
# change we make from the Mac lands on the FAT partition, and firstrun.sh
# applies it to the root filesystem on the Pi itself. That constraint is
# what shapes this whole design - and it keeps the Mac side dependency-free.

set -euo pipefail
cd "$(dirname "$0")/.."
. build/lib.sh

# --reuse-credentials: re-provisioning an already-provisioned card. Writes no
# console-user/password files; firstrun sees the absent password file plus the
# existing account and keeps the current credentials. NEVER use this on a
# freshly flashed card - there would be no account and no way to log in.
REUSE=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --reuse-credentials) REUSE=1 ;;
        *) ARGS+=("$a") ;;
    esac
done
BOOT="${ARGS[0]:-}"
if [ -z "$BOOT" ]; then
    for c in /Volumes/bootfs /Volumes/boot; do
        [ -d "$c" ] && { BOOT="$c"; break; }
    done
fi
[ -n "$BOOT" ] && [ -d "$BOOT" ] || die "boot partition not found; pass it explicitly: $0 /Volumes/bootfs"
[ -f "${BOOT}/config.txt" ] || die "$BOOT does not look like a Pi boot partition (no config.txt)"

say "boot partition: $BOOT"

# --- console credentials ---------------------------------------------------
if [ "$REUSE" -eq 1 ]; then
    say "reuse mode: keeping the card's existing console account and password"
    HOSTNAME=umik
    CUSER=""
    PW1=""
else
printf 'Hostname [umik]: '
read -r HOSTNAME
HOSTNAME="${HOSTNAME:-umik}"
# These land in sed replacements, /etc files and adduser arguments on the Pi,
# unattended - so reject anything but the safe character set outright.
[[ "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || die "hostname must be lowercase letters/digits/hyphens (RFC 1123)"

printf 'Console username [maint]: '
read -r CUSER
CUSER="${CUSER:-maint}"
[[ "$CUSER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || die "username must start with a letter/underscore, then letters/digits/_/-"

echo "This is the ONLY way into the box: no SSH, no network, physical console only."
printf 'Console password: '; read -rs PW1; echo
printf 'Confirm:          '; read -rs PW2; echo
[ -n "$PW1" ] || die "empty password - you would be locked out permanently"
[ "$PW1" = "$PW2" ] || die "passwords do not match"
fi

# --- copy payload ----------------------------------------------------------
say "copying payload"
rm -rf "${BOOT}/umik"
mkdir -p "${BOOT}/umik"
cp -R boot/payload/. "${BOOT}/umik/"
cp boot/firstrun.sh "${BOOT}/firstrun.sh"
chmod 0755 "${BOOT}/firstrun.sh" 2>/dev/null || true

printf '%s\n' "$HOSTNAME" > "${BOOT}/umik/hostname"
if [ "$REUSE" -eq 0 ]; then
    printf '%s\n' "$CUSER"    > "${BOOT}/umik/console-user"
    printf '%s'   "$PW1"      > "${BOOT}/umik/console-password"
fi
unset PW1 PW2

# The stock image ships cloud-init seed files (user-data / network-config) and
# the userconf first-boot path; remove all of it so nothing competes with
# firstrun.sh. (cloud-init is also purged on the Pi, this is belt-and-braces.)
rm -f "${BOOT}/userconf.txt" "${BOOT}/userconf" "${BOOT}/custom.toml" \
      "${BOOT}/user-data" "${BOOT}/meta-data" "${BOOT}/network-config"

# --- config.txt ------------------------------------------------------------
say "patching config.txt"
cp "${BOOT}/config.txt" "${BOOT}/config.txt.orig"
# Drop any prior block so re-running is idempotent.
sed -i '' '/# >>> umik-autorecord >>>/,/# <<< umik-autorecord <<</d' "${BOOT}/config.txt"
cat >> "${BOOT}/config.txt" <<'EOF'

# >>> umik-autorecord >>>
# Layer 1 of the radio-silence strategy: the Wi-Fi and Bluetooth hardware is
# removed from the device tree entirely, so no driver ever binds to it. This
# is stronger than a blacklist - there is nothing there to drive.
dtoverlay=disable-wifi
dtoverlay=disable-bt

# The onboard audio codec is unused; the UMIK-1 is the only capture device.
dtparam=audio=off

# With no SSH and no network, the GPIO serial console is the recovery path of
# last resort. disable-bt already frees the good PL011 UART for it.
enable_uart=1

# Trim boot time - every second here is a second of missed recording.
disable_splash=1
boot_delay=0
# <<< umik-autorecord <<<
EOF

# --- cmdline.txt -----------------------------------------------------------
say "patching cmdline.txt"
cp "${BOOT}/cmdline.txt" "${BOOT}/cmdline.txt.orig"
CMD=$(tr -d '\n' < "${BOOT}/cmdline.txt")

# Remove the stock first-boot hook. If it ran, it would auto-expand the root
# filesystem across the whole card and leave no room for the data partition.
CMD=$(printf '%s' "$CMD" | sed -E 's#(^| )init=/usr/lib/raspberrypi-sys-mods/firstboot##g')
CMD=$(printf '%s' "$CMD" | sed -E 's#(^| )init=/usr/lib/raspberrypi-sys-mods/[^ ]*##g')

# Strip anything we are about to re-add, so this is idempotent.
CMD=$(printf '%s' "$CMD" | sed -E 's#(^| )modprobe\.blacklist=[^ ]*##g')
CMD=$(printf '%s' "$CMD" | sed -E 's#(^| )systemd\.(run|run_success_action|run_failure_action|unit)=[^ ]*##g')
CMD=$(printf '%s' "$CMD" | sed -E 's/  +/ /g; s/^ //; s/ $//')

# Layer 2: blacklist the radio modules at boot.
BLACKLIST="brcmfmac,brcmutil,brcmfmac_wcc,cfg80211,mac80211,bluetooth,btbcm,btintel,btusb,btsdio,hci_uart,bnep,rfcomm,rfkill"

printf '%s modprobe.blacklist=%s systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target\n' \
    "$CMD" "$BLACKLIST" > "${BOOT}/cmdline.txt"

echo
echo "cmdline.txt is now:"
fold -w 100 -s "${BOOT}/cmdline.txt" | sed 's/^/    /'
echo

# --- done ------------------------------------------------------------------
say "syncing"
sync

cat <<EOF

=== card ready ===

  1. Eject:  diskutil eject <disk>
  2. Put the card in the Pi.
  3. Plug the UMIK-1 into a BLACK USB 2.0 port (not a blue 3.0 one).
  4. Power on. The first boot provisions and then reboots itself
     (roughly 2-4 minutes). It does NOT need a network at any point.
  5. Recording starts automatically on the second boot.

If it does not come up, put the card back in your Mac and read:
    /Volumes/bootfs/umik-firstrun.log

EOF
