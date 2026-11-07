#!/usr/bin/env bash
# Runs inside the arm64 image chroot under qemu-aarch64-static.
# Invoked by build-image.sh; not intended to be run on the host.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PYTHONDONTWRITEBYTECODE=1

SRC=/tmp/zebra-src
CFG=/tmp/zebra-config

log() { printf '\n--- %s\n' "$*"; }

# Configure initramfs generation before installing packages.  Package
# postinsts (notably overlayroot) activate an update-initramfs trigger; with
# Raspberry Pi OS's default MODULES=dep and the build host's /proc visible in
# the chroot, that trigger would build a non-booting initramfs.  Suppress it
# and build exactly once, with MODULES=most, after all configuration is done.
if [ -f /etc/initramfs-tools/update-initramfs.conf ]; then
    sed -i -E 's/^update_initramfs=.*/update_initramfs=no/' \
        /etc/initramfs-tools/update-initramfs.conf
fi
if [ -f /etc/initramfs-tools/initramfs.conf ]; then
    sed -i -E 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
fi

log "Installing packages"
apt-get update
apt-get install -y --no-install-recommends \
    python3 \
    python3-dbus \
    python3-gi \
    bluez \
    pi-bluetooth \
    rfkill \
    initramfs-tools \
    overlayroot \
    raspi-config

# The bridge writes raw bytes to /dev/usb/lp*; usblp must not be blacklisted.
log "Installing bridge files"
install -d -m 0755 /opt/zebra-bridge
install -m 0755 "$SRC/zebra_bridge.py" /opt/zebra-bridge/zebra_bridge.py
install -m 0755 "$SRC/run.sh" /opt/zebra-bridge/run.sh
install -m 0755 "$SRC/supervise.sh" /opt/zebra-bridge/supervise.sh
install -m 0644 "$SRC/99-zebra-printer.rules" /etc/udev/rules.d/99-zebra-printer.rules
install -m 0644 "$SRC/systemd/zebra-bridge.service" /etc/systemd/system/zebra-bridge.service

# The operator edits this on the FAT32 bootfs partition from any PC.
if [ ! -f /boot/firmware/zebra-bridge.conf ]; then
    install -m 0644 "$SRC/zebra-bridge.conf.example" /boot/firmware/zebra-bridge.conf
fi
ln -sfn /boot/firmware/zebra-bridge.conf /etc/zebra-bridge.conf

log "Installing boot / kernel / logging / watchdog configuration"
install -m 0644 "$CFG/blacklist-appliance.conf" /etc/modprobe.d/blacklist-appliance.conf
install -d -m 0755 /etc/modules-load.d
install -m 0644 "$CFG/modules-load.conf" /etc/modules-load.d/zebra-usblp.conf
install -d -m 0755 /etc/systemd/journald.conf.d
install -m 0644 "$CFG/journald-volatile.conf" /etc/systemd/journald.conf.d/99-volatile.conf
install -d -m 0755 /etc/systemd/system.conf.d
install -m 0644 "$CFG/watchdog.conf" /etc/systemd/system.conf.d/99-watchdog.conf

if [ -f /etc/bluetooth/main.conf ] && [ ! -f /etc/bluetooth/main.conf.orig ]; then
    cp -a /etc/bluetooth/main.conf /etc/bluetooth/main.conf.orig
fi
install -m 0644 "$CFG/bluetooth-main.conf" /etc/bluetooth/main.conf

log "Disabling swap"
systemctl --root=/ mask dphys-swapfile.service >/dev/null 2>&1 || true
apt-get purge -y dphys-swapfile >/dev/null 2>&1 || true
# Never call swapoff -a here: a chroot shares the build host's kernel, so it
# would try to disable the host's swap.  Purging the package and removing its
# unit/fstab entries is sufficient for the image.
rm -f /var/swap /etc/dphys-swapfile /etc/systemd/system/dphys-swapfile.service

log "Enabling required units"
enable_unit() {
    systemctl --root=/ enable "$1" >/dev/null 2>&1 \
        || systemctl enable "$1" >/dev/null 2>&1 \
        || true
}
enable_unit bluetooth.service
enable_unit hciuart.service
enable_unit zebra-bridge.service

# --root is normally enough, but make the boot-critical symlinks deterministic.
mkdir -p \
    /etc/systemd/system/multi-user.target.wants \
    /etc/systemd/system/bluetooth.target.wants \
    /etc/systemd/system/dev-serial1.device.wants
ln -sfn /etc/systemd/system/zebra-bridge.service \
    /etc/systemd/system/multi-user.target.wants/zebra-bridge.service
ln -sfn /usr/lib/systemd/system/bluetooth.service \
    /etc/systemd/system/bluetooth.target.wants/bluetooth.service
ln -sfn /usr/lib/systemd/system/bluetooth.service \
    /etc/systemd/system/dbus-org.bluez.service
ln -sfn /usr/lib/systemd/system/hciuart.service \
    /etc/systemd/system/dev-serial1.device.wants/hciuart.service

log "Masking non-essential services"
SERVICES_TO_MASK=(
    "NetworkManager.service"
    "NetworkManager-wait-online.service"
    "wpa_supplicant.service"
    "networking.service"
    "dhcpcd.service"
    "ssh.service"
    "sshd.service"
    "avahi-daemon.service"
    "avahi-daemon.socket"
    "triggerhappy.service"
    "triggerhappy.socket"
    "ModemManager.service"
    "apt-daily.service"
    "apt-daily.timer"
    "apt-daily-upgrade.service"
    "apt-daily-upgrade.timer"
    "dpkg-db-backup.timer"
    "man-db.timer"
    "e2scrub_all.timer"
    "e2scrub_reap.service"
    "systemd-timesyncd.service"
    "systemd-networkd.service"
    "systemd-networkd.socket"
    "systemd-resolved.service"
    "systemd-resolved.socket"
    "cron.service"
    "rsyslog.service"
    "syslog.socket"
    "alsa-restore.service"
    "alsa-state.service"
    "raspi-config.service"
    "regenerate_ssh_host_keys.service"
    "userconfig.service"
    "getty@tty1.service"
    "rpi-eeprom-update.service"
)
for svc in "${SERVICES_TO_MASK[@]}"; do
    systemctl --root=/ disable "$svc" >/dev/null 2>&1 || true
    systemctl --root=/ mask "$svc" >/dev/null 2>&1 || true
    # Deterministic fallback: masking is exactly a symlink to /dev/null.
    ln -sfn /dev/null "/etc/systemd/system/$svc"
done

log "Enabling OverlayFS (overlayroot=tmpfs) and read-only boot"
# raspi-config installs overlayroot (already present), prepends
# overlayroot=tmpfs to cmdline.txt, and sets the bootfs fstab entry to ro.
if ! raspi-config nonint do_overlayfs 0; then
    echo "raspi-config do_overlayfs failed; applying fallback" >&2
    grep -q 'overlayroot=tmpfs' /boot/firmware/cmdline.txt \
        || sed -i '1s/^/overlayroot=tmpfs /' /boot/firmware/cmdline.txt
fi

# Verify/fix the two invariants regardless of raspi-config's chroot quirks.
grep -q 'overlayroot=tmpfs' /boot/firmware/cmdline.txt \
    || sed -i '1s/^/overlayroot=tmpfs /' /boot/firmware/cmdline.txt

python3 - <<'PY'
from pathlib import Path

fstab = Path("/etc/fstab")
lines = []
for line in fstab.read_text().splitlines():
    stripped = line.strip()
    if stripped and not stripped.startswith("#"):
        parts = stripped.split()
        if len(parts) >= 4 and parts[1] == "/boot/firmware":
            opts = [o for o in parts[3].split(",") if o != "rw"]
            if "ro" not in opts:
                opts.append("ro")
            parts[3] = ",".join(opts)
            line = "\t".join(parts)
    lines.append(line)
fstab.write_text("\n".join(lines) + "\n")
PY

grep -qE '^[^#].*[[:space:]]/boot/firmware[[:space:]]+vfat[[:space:]]+[^[:space:]]*ro' /etc/fstab \
    || { echo "bootfs is not read-only in /etc/fstab" >&2; exit 1; }

log "Verifying boot configuration"
grep -q '^auto_initramfs=1' /boot/firmware/config.txt \
    || { echo "config.txt is missing auto_initramfs=1" >&2; exit 1; }
grep -q '^dtoverlay=dwc2,dr_mode=host' /boot/firmware/config.txt \
    || { echo "config.txt is missing dwc2 host mode" >&2; exit 1; }
grep -q '^dtoverlay=disable-wifi' /boot/firmware/config.txt \
    || { echo "config.txt is missing disable-wifi" >&2; exit 1; }
grep -q '^dtparam=watchdog=on' /boot/firmware/config.txt \
    || { echo "config.txt is missing watchdog=on" >&2; exit 1; }

log "Rebuilding initramfs (overlayroot hook)"
# Raspberry Pi OS ships the generator in "no automatic update" mode while
# images are assembled; without flipping this back on, update-initramfs -u
# prints "Not updating initramfs" and exits successfully, leaving the old
# initramfs without the overlayroot hook.  pi-gen does the same in finalise.
if [ -f /etc/initramfs-tools/update-initramfs.conf ]; then
    sed -i -E 's/^update_initramfs=.*/update_initramfs=yes/' \
        /etc/initramfs-tools/update-initramfs.conf
fi
# Build the initramfs with MODULES=most.  initramfs-tools' "dep" mode picks
# modules by reading /proc/mounts, which inside this chroot shows the build
# host's root device, so "dep" would omit the Pi's mmc/sdhci drivers and
# produce a non-booting image.  "most" is chroot-safe.  (Raspberry Pi OS can
# use "dep" later on the real device; the stock image's initramfs was also
# built with "most".)
if [ -f /etc/initramfs-tools/initramfs.conf ]; then
    sed -i -E 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
fi
update-initramfs -c -k all

# The raspi-firmware post-update hook copies /boot/initrd.img-<ver> to
# /boot/firmware/initramfs8 so auto_initramfs=1 can load it.  Verify both that
# copy and the overlayroot hook, otherwise the image silently boots writable.
[ -s /boot/firmware/initramfs8 ] \
    || { echo "initramfs8 was not installed into /boot/firmware" >&2; exit 1; }
# Do not use "grep -q" here: it exits on the first match, lsinitramfs then dies
# with SIGPIPE, and "set -o pipefail" turns that into a false failure.
if ! lsinitramfs /boot/firmware/initramfs8 \
        | grep -F 'scripts/init-bottom/overlayroot' >/dev/null; then
    echo "initramfs8 has no overlayroot hook" >&2
    exit 1
fi
grep -q 'overlayroot=tmpfs' /boot/firmware/cmdline.txt \
    || { echo "cmdline.txt is missing overlayroot=tmpfs" >&2; exit 1; }

log "Setting hostname and machine-id"
printf 'zebra-bridge\n' > /etc/hostname
if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E 's/^127\.0\.1\.1[[:space:]].*/127.0.1.1\tzebra-bridge/' /etc/hosts
else
    printf '127.0.1.1\tzebra-bridge\n' >> /etc/hosts
fi
rm -f /etc/machine-id
# Leave machine-id empty.  systemd generates a unique volatile id on first
# boot; pre-generating one here would clone the same id onto every unit.
: > /etc/machine-id

log "Cleaning package and log state"
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/log/*
rm -rf /root/.cache /tmp/*

log "Provisioning complete"
