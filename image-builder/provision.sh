#!/usr/bin/env bash
# Runs inside the arm64 image chroot under qemu-aarch64-static.
# Invoked by build-image.sh; not intended to be run on the host.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PYTHONDONTWRITEBYTECODE=1

SRC=/tmp/zebra-src
CFG=/tmp/zebra-config
IMAGE_VARIANT="${IMAGE_VARIANT:-release}"

log() { printf '\n--- %s\n' "$*"; }

case "$IMAGE_VARIANT" in
    release|debug) ;;
    *) echo "unknown IMAGE_VARIANT: $IMAGE_VARIANT" >&2; exit 1 ;;
esac

is_debug() { [ "$IMAGE_VARIANT" = "debug" ]; }

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
PACKAGES=(
    python3
    python3-dbus
    python3-gi
    bluez
    pi-bluetooth
    rfkill
    initramfs-tools
    overlayroot
    raspi-config
)
if is_debug; then
    # Networking, SSH, and the tools needed to debug the USB/print path.
    PACKAGES+=(
        network-manager
        wpasupplicant
        openssh-server
        avahi-daemon
        libnss-mdns
        iw
        wireless-regdb
        usbutils
        strace
        tcpdump
        less
        vim-tiny
        net-tools
        iproute2
        iputils-ping
        dnsutils
        passwd
    )
fi
apt-get install -y --no-install-recommends "${PACKAGES[@]}"

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

if is_debug; then
    log "Installing debug Wi-Fi/SSH configuration"
    install -m 0644 "$CFG/zebra-bridge-debug.conf" \
        /boot/firmware/zebra-bridge-debug.conf
    # Allow a build to pre-bake credentials without committing them:
    #   -e DEBUG_WIFI_SSID=... -e DEBUG_WIFI_PASSWORD=...
    # An empty variable leaves the template value untouched.
    if [ -n "${DEBUG_WIFI_SSID}${DEBUG_WIFI_PASSWORD}${DEBUG_WIFI_COUNTRY}${DEBUG_SSH_USER}${DEBUG_SSH_PASSWORD}${DEBUG_SSH_AUTHORIZED_KEY}" ]; then
        python3 - <<'PY'
import configparser
import os

path = "/boot/firmware/zebra-bridge-debug.conf"
parser = configparser.ConfigParser(interpolation=None)
parser.read(path, encoding="utf-8")
updates = {
    "wifi_ssid": os.environ.get("DEBUG_WIFI_SSID", ""),
    "wifi_password": os.environ.get("DEBUG_WIFI_PASSWORD", ""),
    "wifi_country": os.environ.get("DEBUG_WIFI_COUNTRY", ""),
    "ssh_user": os.environ.get("DEBUG_SSH_USER", ""),
    "ssh_password": os.environ.get("DEBUG_SSH_PASSWORD", ""),
    "ssh_authorized_key": os.environ.get("DEBUG_SSH_AUTHORIZED_KEY", ""),
}
for key, value in updates.items():
    if value:
        parser.set("debug", key, value)
with open(path, "w", encoding="utf-8") as handle:
    parser.write(handle)
PY
        chmod 0644 /boot/firmware/zebra-bridge-debug.conf
    fi

    # The bridge logs every BLE chunk at DEBUG; this is the main signal for
    # "did Rock send bytes to the Pi?".
    if grep -q '^# log_level = INFO' /boot/firmware/zebra-bridge.conf; then
        sed -i 's/^# log_level = INFO/log_level = DEBUG/' \
            /boot/firmware/zebra-bridge.conf
    elif ! grep -q '^log_level[[:space:]]*=' /boot/firmware/zebra-bridge.conf; then
        printf '\nlog_level = DEBUG\n' >> /boot/firmware/zebra-bridge.conf
    fi

    install -d -m 0755 /etc/NetworkManager/conf.d /etc/ssh/sshd_config.d
    install -m 0644 "$CFG/NetworkManager-debug.conf" \
        /etc/NetworkManager/conf.d/99-zebra-debug.conf
    install -m 0644 "$CFG/ssh-debug.conf" \
        /etc/ssh/sshd_config.d/99-zebra-debug.conf
    install -m 0755 "$CFG/zebra-bridge-debug-boot.py" \
        /usr/local/sbin/zebra-bridge-debug-boot.py
    install -m 0644 "$CFG/debug-network.service" \
        /etc/systemd/system/zebra-bridge-debug-network.service
fi

log "Installing boot / kernel / logging / watchdog configuration"
install -m 0644 "$CFG/blacklist-appliance.conf" /etc/modprobe.d/blacklist-appliance.conf
install -d -m 0755 /etc/modules-load.d
install -m 0644 "$CFG/modules-load.conf" /etc/modules-load.d/zebra-usblp.conf
install -d -m 0755 /etc/systemd/journald.conf.d
if is_debug; then
    install -m 0644 "$CFG/journald-persistent.conf" \
        /etc/systemd/journald.conf.d/99-persistent.conf
    install -d -m 2755 -o root -g systemd-journal /var/log/journal
else
    install -m 0644 "$CFG/journald-volatile.conf" \
        /etc/systemd/journald.conf.d/99-volatile.conf
fi
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
if is_debug; then
    enable_unit NetworkManager.service
    enable_unit wpa_supplicant.service
    enable_unit ssh.service
    enable_unit avahi-daemon.service
    enable_unit avahi-daemon.socket
    enable_unit zebra-bridge-debug-network.service
    enable_unit regenerate_ssh_host_keys.service
fi

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

if is_debug; then
    # The debug image deliberately unmasks the network/SSH units.  Remove any
    # stale mask left by the base image before creating the wants links.
    for svc in NetworkManager.service wpa_supplicant.service ssh.service \
               sshd.service avahi-daemon.service avahi-daemon.socket \
               regenerate_ssh_host_keys.service; do
        if [ -L "/etc/systemd/system/$svc" ] \
                && [ "$(readlink "/etc/systemd/system/$svc")" = "/dev/null" ]; then
            rm -f "/etc/systemd/system/$svc"
        fi
    done
    mkdir -p \
        /etc/systemd/system/sysinit.target.wants \
        /etc/systemd/system/sockets.target.wants
    ln -sfn /etc/systemd/system/zebra-bridge-debug-network.service \
        /etc/systemd/system/sysinit.target.wants/zebra-bridge-debug-network.service
    ln -sfn /usr/lib/systemd/system/NetworkManager.service \
        /etc/systemd/system/multi-user.target.wants/NetworkManager.service
    ln -sfn /usr/lib/systemd/system/wpa_supplicant.service \
        /etc/systemd/system/multi-user.target.wants/wpa_supplicant.service
    ln -sfn /usr/lib/systemd/system/ssh.service \
        /etc/systemd/system/multi-user.target.wants/ssh.service
    ln -sfn /usr/lib/systemd/system/avahi-daemon.service \
        /etc/systemd/system/multi-user.target.wants/avahi-daemon.service
    ln -sfn /usr/lib/systemd/system/avahi-daemon.socket \
        /etc/systemd/system/sockets.target.wants/avahi-daemon.socket
fi

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
if is_debug; then
    # Keep networking, SSH, and mDNS available in the debug image.  Everything
    # else (including systemd-networkd and dhcpcd, which would fight
    # NetworkManager) stays masked.
    DEBUG_KEEP=(
        "NetworkManager.service"
        "wpa_supplicant.service"
        "ssh.service"
        "sshd.service"
        "avahi-daemon.service"
        "avahi-daemon.socket"
        "regenerate_ssh_host_keys.service"
    )
    FILTERED=()
    for svc in "${SERVICES_TO_MASK[@]}"; do
        keep=0
        for wanted in "${DEBUG_KEEP[@]}"; do
            [ "$svc" = "$wanted" ] && keep=1 && break
        done
        [ "$keep" -eq 0 ] && FILTERED+=("$svc")
    done
    SERVICES_TO_MASK=("${FILTERED[@]}")
fi
for svc in "${SERVICES_TO_MASK[@]}"; do
    systemctl --root=/ disable "$svc" >/dev/null 2>&1 || true
    systemctl --root=/ mask "$svc" >/dev/null 2>&1 || true
    # Deterministic fallback: masking is exactly a symlink to /dev/null.
    ln -sfn /dev/null "/etc/systemd/system/$svc"
done

if is_debug; then
    log "Leaving root and boot writable (debug image)"
    # The debug image must be repairable over SSH: no OverlayFS, and the FAT
    # bootfs stays mounted rw so Wi-Fi/SSH settings can be edited in place.
    sed -i -E 's/(^|[[:space:]])overlayroot=[^[:space:]]+[[:space:]]*/\1/g; s/(^|[[:space:]])ro([[:space:]]|$)/\1\2/g; s/[[:space:]]+$//' \
        /boot/firmware/cmdline.txt
    python3 - <<'PY'
from pathlib import Path

fstab = Path("/etc/fstab")
lines = []
for line in fstab.read_text().splitlines():
    stripped = line.strip()
    if stripped and not stripped.startswith("#"):
        parts = stripped.split()
        if len(parts) >= 4 and parts[1] == "/boot/firmware":
            opts = [o for o in parts[3].split(",") if o not in ("ro", "rw")]
            opts.insert(0, "rw")
            parts[3] = ",".join(opts)
            line = "\t".join(parts)
    lines.append(line)
fstab.write_text("\n".join(lines) + "\n")
PY
    grep -q 'overlayroot=tmpfs' /boot/firmware/cmdline.txt \
        && { echo "debug cmdline still enables overlayroot" >&2; exit 1; }
    grep -qE '^[^#].*[[:space:]]/boot/firmware[[:space:]]+vfat[[:space:]]+[^[:space:]]*rw' /etc/fstab \
        || { echo "debug bootfs is not writable in /etc/fstab" >&2; exit 1; }
else
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
fi

log "Verifying boot configuration"
grep -q '^auto_initramfs=1' /boot/firmware/config.txt \
    || { echo "config.txt is missing auto_initramfs=1" >&2; exit 1; }
grep -q '^dtoverlay=dwc2,dr_mode=host' /boot/firmware/config.txt \
    || { echo "config.txt is missing dwc2 host mode" >&2; exit 1; }
if is_debug; then
    ! grep -q '^dtoverlay=disable-wifi' /boot/firmware/config.txt \
        || { echo "debug config.txt still disables Wi-Fi" >&2; exit 1; }
else
    grep -q '^dtoverlay=disable-wifi' /boot/firmware/config.txt \
        || { echo "config.txt is missing disable-wifi" >&2; exit 1; }
fi
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
if is_debug; then
    echo "debug variant: OverlayFS hook not required"
else
    if ! lsinitramfs /boot/firmware/initramfs8 \
            | grep -F 'scripts/init-bottom/overlayroot' >/dev/null; then
        echo "initramfs8 has no overlayroot hook" >&2
        exit 1
    fi
    grep -q 'overlayroot=tmpfs' /boot/firmware/cmdline.txt \
        || { echo "cmdline.txt is missing overlayroot=tmpfs" >&2; exit 1; }
fi

log "Setting hostname and machine-id"
if is_debug; then
    HOSTNAME_VALUE=zebra-bridge-debug
else
    HOSTNAME_VALUE=zebra-bridge
fi
printf '%s\n' "$HOSTNAME_VALUE" > /etc/hostname
if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\\.0\\.1\\.1[[:space:]].*/127.0.1.1\\t$HOSTNAME_VALUE/" /etc/hosts
else
    printf '127.0.1.1\t%s\n' "$HOSTNAME_VALUE" >> /etc/hosts
fi
if is_debug; then
    # Never ship a debug image with baked-in host keys; the debug boot unit
    # (and regenerate_ssh_host_keys.service) creates them on first boot.
    rm -f /etc/ssh/ssh_host_*
fi
rm -f /etc/machine-id
# Leave machine-id empty.  systemd generates a unique volatile id on first
# boot; pre-generating one here would clone the same id onto every unit.
: > /etc/machine-id

log "Cleaning package and log state"
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/log/*
rm -rf /root/.cache /tmp/*
if is_debug; then
    # journald needs its persistent directory with the journal group's setgid
    # bit; "rm -rf /var/log/*" removed the one created earlier.
    install -d -m 2755 -o root -g systemd-journal /var/log/journal
fi

log "Provisioning complete"
