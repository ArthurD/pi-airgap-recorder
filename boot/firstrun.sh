#!/bin/bash
# firstrun.sh - one-time provisioning, executed by systemd on the very first
# boot via `systemd.run=` in cmdline.txt, as root, with / mounted rw.
#
# This script performs NO network access whatsoever. Everything it needs is
# already present in the stock Raspberry Pi OS Lite image (notably alsa-utils,
# which ships with Trixie Lite). It only removes packages and writes config.
#
# Its log is written to the FAT boot partition so that it can be read on a Mac
# if the Pi fails to come up headless.

set -uo pipefail

BOOT=/boot/firmware
LOG="${BOOT}/umik-firstrun.log"
PAYLOAD="${BOOT}/umik"

exec > >(tee -a "$LOG") 2>&1
echo "=== umik-autorecord firstrun @ $(date -u) ==="

step() { echo; echo "--- $* ---"; }
warn() { echo "WARN: $*"; }
die()  { echo "FATAL: $*"; echo "=== firstrun ABORTED ==="; sync; exit 1; }

[ -d "$PAYLOAD" ] || die "payload directory $PAYLOAD is missing"

# ---------------------------------------------------------------------------
step "identity"
# ---------------------------------------------------------------------------
HOSTNAME=$(cat "${PAYLOAD}/hostname" 2>/dev/null || echo umik)
echo "$HOSTNAME" > /etc/hostname
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts 2>/dev/null || \
    echo -e "127.0.1.1\t${HOSTNAME}" >> /etc/hosts
echo "hostname = ${HOSTNAME}"

# ---------------------------------------------------------------------------
step "console maintenance account"
# ---------------------------------------------------------------------------
# There is no SSH and no network; this account exists purely for the physical
# serial/HDMI console. The plaintext password file is shredded immediately.
CONSOLE_USER=$(cat "${PAYLOAD}/console-user" 2>/dev/null || echo maint)
PWFILE="${PAYLOAD}/console-password"
if [ -f "$PWFILE" ]; then
    if ! id -u "$CONSOLE_USER" >/dev/null 2>&1; then
        adduser --disabled-password --gecos "" "$CONSOLE_USER"
    fi
    printf '%s:%s\n' "$CONSOLE_USER" "$(cat "$PWFILE")" | chpasswd
    for g in sudo adm systemd-journal; do adduser "$CONSOLE_USER" "$g" 2>/dev/null; done
    shred -u "$PWFILE" 2>/dev/null || rm -f "$PWFILE"
    echo "console account '${CONSOLE_USER}' created; password file shredded"
elif id -u "$CONSOLE_USER" >/dev/null 2>&1; then
    echo "no console-password file, but '${CONSOLE_USER}' already exists - this is a re-run; keeping existing credentials"
else
    warn "no console-password file and no existing console account - you will have NO way to log in"
fi

# The stock 'pi'/default user, if any, is removed.
for u in pi; do
    if id -u "$u" >/dev/null 2>&1 && [ "$u" != "$CONSOLE_USER" ]; then
        deluser --remove-home "$u" 2>/dev/null && echo "removed stock user '$u'"
    fi
done

# ---------------------------------------------------------------------------
step "purging radio, network and remote-access packages"
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
PURGE=(
    bluez bluez-firmware pi-bluetooth libbluetooth3 firmware-brcm80211
    wpasupplicant wireless-tools wireless-regdb crda rfkill iw
    network-manager network-manager-l10n modemmanager
    avahi-daemon avahi-utils libnss-mdns
    openssh-server openssh-sftp-server
    cloud-init cloud-guest-utils
    triggerhappy dphys-swapfile
    cifs-utils nfs-common rpcbind
    userconf-pi
)
INSTALLED=()
for p in "${PURGE[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed" \
        && INSTALLED+=("$p")
done
if [ ${#INSTALLED[@]} -gt 0 ]; then
    echo "purging: ${INSTALLED[*]}"
    swapoff -a 2>/dev/null
    apt-get purge -y --autoremove "${INSTALLED[@]}" \
        || warn "apt purge returned non-zero; continuing"
else
    echo "nothing to purge"
fi
apt-get autoremove -y --purge 2>/dev/null

# ---------------------------------------------------------------------------
step "deleting radio firmware blobs"
# ---------------------------------------------------------------------------
# Layer 4: even if the device tree, blacklist and modprobe overrides were all
# defeated, there is no firmware on disk to load into the radio.
if [ -d /lib/firmware/brcm ]; then
    find /lib/firmware/brcm -type f \
         \( -iname '*43455*' -o -iname '*4345*' -o -iname 'brcmfmac*' -o -iname 'BCM*' \) \
         -print -delete
fi
rm -rf /lib/firmware/cypress 2>/dev/null
echo "remaining in /lib/firmware/brcm: $(ls -A /lib/firmware/brcm 2>/dev/null | wc -l) file(s)"

# ---------------------------------------------------------------------------
step "installing umik-autorecord payload"
# ---------------------------------------------------------------------------
install -m 0755 "${PAYLOAD}/usr/local/bin/umik-record"      /usr/local/bin/umik-record
install -m 0755 "${PAYLOAD}/usr/local/bin/umik-radio-check" /usr/local/bin/umik-radio-check
install -m 0755 "${PAYLOAD}/usr/local/bin/umik-usb-detect"  /usr/local/bin/umik-usb-detect
install -m 0755 "${PAYLOAD}/usr/local/bin/umik-diag"        /usr/local/bin/umik-diag
install -m 0644 "${PAYLOAD}/etc/systemd/system/umik-record.service"      /etc/systemd/system/
install -m 0644 "${PAYLOAD}/etc/systemd/system/umik-radio-check.service" /etc/systemd/system/
install -m 0644 "${PAYLOAD}/etc/systemd/system/umik-usb-detect.service"  /etc/systemd/system/
install -m 0644 "${PAYLOAD}/etc/systemd/system/umik-diag.service"        /etc/systemd/system/
install -m 0644 "${PAYLOAD}/etc/modprobe.d/umik-no-radio.conf"  /etc/modprobe.d/
install -m 0644 "${PAYLOAD}/etc/sysctl.d/99-umik-hardening.conf" /etc/sysctl.d/
install -D -m 0644 "${PAYLOAD}/etc/udev/rules.d/99-umik-usb.rules.disabled" \
    /etc/udev/rules.d/99-umik-usb.rules.disabled
echo "payload installed"

# ---------------------------------------------------------------------------
step "recorder service account"
# ---------------------------------------------------------------------------
getent group recorder >/dev/null || groupadd --system recorder
id -u recorder >/dev/null 2>&1 || \
    useradd --system --gid recorder --groups audio \
            --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin recorder
echo "recorder uid=$(id -u recorder) groups=$(id -Gn recorder)"

# ---------------------------------------------------------------------------
step "growing root filesystem into its partition"
# ---------------------------------------------------------------------------
# 04-add-data-partition pre-sizes the root partition (default 8GiB) with the
# exFAT data partition after it; the filesystem inside still has the image's
# original size until grown. Safe no-op when already full-size.
resize2fs "$(findmnt -no SOURCE /)" 2>&1 || warn "resize2fs failed"

# ---------------------------------------------------------------------------
step "recording directory"
# ---------------------------------------------------------------------------
# Recordings go, in order of preference:
#   /data/usb/recordings   USB stick, mounted by umik-usb-detect at boot
#   /data/recordings       /data = the card's exFAT partition (UMIKDATA,
#                          readable on a Mac) when present, else a plain
#                          directory on the ext4 root.
RUID=$(id -u recorder); RGID=$(id -g recorder)
mkdir -p /data
# Provision the ext4 fallback layer FIRST, while /data is still the bare
# root-fs directory: if the exFAT partition ever fails to mount on a later
# boot (it is nofail), the recorder must find writable directories under
# /data rather than crash-looping against a root-owned empty one.
mkdir -p /data/recordings /data/logs
chown -R recorder:recorder /data/recordings /data/logs
chmod 0750 /data/recordings /data/logs
if ! grep -q 'LABEL=UMIKDATA' /etc/fstab; then
    cat >> /etc/fstab <<EOF

# UMIK-1 recordings: the card's Mac-readable exFAT partition. nofail = a
# missing or damaged partition must never stop the box from booting.
LABEL=UMIKDATA  /data  exfat  uid=${RUID},gid=${RGID},fmask=0077,dmask=0077,noatime,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=10  0  0
EOF
fi
if mount /data 2>/dev/null || mountpoint -q /data; then
    echo "/data = exFAT UMIKDATA partition (Mac-readable)"
else
    warn "no UMIKDATA partition mounted - recordings will live on the ext4 root"
fi
mkdir -p /data/recordings /data/logs
# chown/chmod fail harmlessly on exFAT (ownership comes from the mount options).
chown -R recorder:recorder /data/recordings /data/logs 2>/dev/null || true
chmod 0750 /data/recordings /data/logs 2>/dev/null || true
echo "recordings -> /data/recordings, activity log -> /data/logs/umik.log"

# ext4 commit=1 bounds power-loss damage to ~1s of unwritten audio (the
# default is 5s). Applied to the root mount as a fallback recording target.
if grep -qE '\s/\s+ext4\s' /etc/fstab && ! grep -qE '\s/\s+ext4\s+\S*commit=' /etc/fstab; then
    sed -i -E 's|(\s/\s+ext4\s+)(\S+)|\1\2,commit=1|' /etc/fstab
    echo "root fstab options now: $(grep -E '\s/\s+ext4' /etc/fstab)"
fi

# ---------------------------------------------------------------------------
step "masking services"
# ---------------------------------------------------------------------------
# userconfig.service is the tty1 first-boot "create a user" wizard from
# userconf-pi; if it ever ran it would replace our getty with a prompt.
# The package is purged above, but mask it too in case the purge failed.
for u in bluetooth hciuart wpa_supplicant avahi-daemon avahi-daemon.socket \
         ssh sshd systemd-timesyncd ModemManager NetworkManager \
         userconfig \
         apt-daily.timer apt-daily-upgrade.timer man-db.timer; do
    systemctl disable --now "$u" 2>/dev/null
    systemctl mask "$u" 2>/dev/null
done
echo "radio/network/remote-access units masked"

# ---------------------------------------------------------------------------
step "journald: volatile, bounded"
# ---------------------------------------------------------------------------
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-umik.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
ForwardToSyslog=no
EOF

# ---------------------------------------------------------------------------
step "enabling the recorder"
# ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable umik-radio-check.service
systemctl enable umik-usb-detect.service
systemctl enable umik-record.service
systemctl enable umik-diag.service

# ---------------------------------------------------------------------------
step "removing first-boot hooks from cmdline.txt"
# ---------------------------------------------------------------------------
CMD="${BOOT}/cmdline.txt"
if [ -f "$CMD" ]; then
    cp "$CMD" "${BOOT}/cmdline.txt.firstrun-backup"
    sed -i \
        -e 's| systemd\.run=[^ ]*||g' \
        -e 's| systemd\.run_success_action=[^ ]*||g' \
        -e 's| systemd\.run_failure_action=[^ ]*||g' \
        -e 's| systemd\.unit=[^ ]*||g' \
        "$CMD"
    # The strip has been observed to not persist across the forced reboot
    # once (FAT writeback); flush this file's filesystem explicitly and say
    # so if the hooks somehow survived, so a re-run is a warning, not a
    # mystery. Re-runs are harmless - every step above is idempotent.
    sync -f "$CMD" 2>/dev/null || sync
    grep -q 'systemd\.run=' "$CMD" && warn "first-boot hooks survived the strip - firstrun will run once more"
    echo "cmdline.txt is now: $(cat "$CMD")"
fi

step "verifying radio silence"
/usr/local/bin/umik-radio-check || warn "RADIO CHECK FAILED - see above"

echo
echo "=== firstrun COMPLETE @ $(date -u) - rebooting ==="
sync
sleep 2
systemctl reboot -f
