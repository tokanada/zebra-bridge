#!/usr/bin/env bash
# Build a ready-to-flash Raspberry Pi OS Lite (64-bit Bookworm) image for the
# Zebra BLE-to-USB bridge.  Run as root on Linux, or inside the provided
# Docker image:
#
#   docker build -t zebra-bridge-image -f image-builder/Dockerfile .
#   docker run --rm --privileged \
#       -v "$PWD/dist:/work/repo/dist" zebra-bridge-image
#
# The output is dist/zebra-bridge-pi-zero2w.img plus a .sha256 file.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"

OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"
WORK_DIR="${WORK_DIR:-/tmp/zebra-bridge-image}"
IMAGE_URL="${RPI_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.img.xz}"
IMAGE_SHA256="${RPI_IMAGE_SHA256:-6ac3a10a1f144c7e9d1f8e568d75ca809288280a593eb6ca053e49b539f465a4}"
OUTPUT_NAME="zebra-bridge-pi-zero2w.img"

IMAGE_FILE="$WORK_DIR/$(basename "$IMAGE_URL")"
RAW_IMAGE="$WORK_DIR/$OUTPUT_NAME"
ROOT_MNT="$WORK_DIR/root"
LOOP_DEV=""
ROOT_PART=""
BOOT_PART=""
RESOLV_BAK="$WORK_DIR/resolv.conf.bak"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
    set +e
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT/dev/pts" && umount "$ROOT_MNT/dev/pts"
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT/dev" && umount "$ROOT_MNT/dev"
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT/proc" && umount "$ROOT_MNT/proc"
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT/sys" && umount "$ROOT_MNT/sys"
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT/boot/firmware" && umount "$ROOT_MNT/boot/firmware"
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT" && umount "$ROOT_MNT"
    [ -n "${LOOP_DEV:-}" ] && losetup -d "$LOOP_DEV"
}
trap cleanup EXIT INT TERM

[ "$(id -u)" -eq 0 ] || die "must run as root (or with --privileged in Docker)"
for cmd in curl xz sha256sum losetup partx mount chroot blkid qemu-aarch64-static; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done
[ -x /usr/bin/qemu-aarch64-static ] || die "qemu-aarch64-static is not installed"
[ -f "$CONFIG_DIR/config.txt" ] || die "missing $CONFIG_DIR/config.txt"
[ -f "$CONFIG_DIR/cmdline.txt" ] || die "missing $CONFIG_DIR/cmdline.txt"
[ -f "$SCRIPT_DIR/provision.sh" ] || die "missing $SCRIPT_DIR/provision.sh"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR" "$ROOT_MNT"
chmod 0755 "$ROOT_MNT"

# qemu-user-static deliberately skips binfmt registration when it detects a
# container, and binfmt_misc is often not mounted inside the container even
# with --privileged.  Mount it and register aarch64 here; the registration is
# a kernel-global property, so the host picks it up too.
if [ ! -f /proc/sys/fs/binfmt_misc/status ]; then
    mkdir -p /proc/sys/fs/binfmt_misc 2>/dev/null || true
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi
[ -f /proc/sys/fs/binfmt_misc/status ] \
    || die "binfmt_misc is not available; run the container with --privileged"

if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
        && command -v update-binfmts >/dev/null 2>&1; then
    update-binfmts --enable qemu-aarch64 >/dev/null 2>&1 || true
fi
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
        && [ -r /usr/lib/binfmt.d/qemu-aarch64.conf ]; then
    cat /usr/lib/binfmt.d/qemu-aarch64.conf \
        > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
fi
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
    || die "could not register the qemu-aarch64 binfmt handler"

log "Downloading Raspberry Pi OS Lite 64-bit Bookworm"
if [ ! -s "$IMAGE_FILE" ]; then
    curl -fL --retry 3 --retry-delay 5 -o "$IMAGE_FILE.part" "$IMAGE_URL"
    mv "$IMAGE_FILE.part" "$IMAGE_FILE"
fi

log "Verifying SHA256"
printf '%s  %s\n' "$IMAGE_SHA256" "$IMAGE_FILE" | sha256sum -c -

log "Extracting image"
rm -f "$RAW_IMAGE"
xz -dc "$IMAGE_FILE" > "$RAW_IMAGE"

log "Attaching loop device"
LOOP_DEV="$(losetup --find --show --partscan "$RAW_IMAGE")"
partx -u "$LOOP_DEV" >/dev/null 2>&1 || true
for _ in $(seq 1 50); do
    [ -b "${LOOP_DEV}p2" ] && break
    sleep 0.2
done
ROOT_PART="${LOOP_DEV}p2"
BOOT_PART="${LOOP_DEV}p1"
[ -b "$ROOT_PART" ] || die "root partition $ROOT_PART did not appear"
[ -b "$BOOT_PART" ] || die "boot partition $BOOT_PART did not appear"
[ "$(blkid -s TYPE -o value "$BOOT_PART")" = "vfat" ] || die "$BOOT_PART is not vfat"
[ "$(blkid -s TYPE -o value "$ROOT_PART")" = "ext4" ] || die "$ROOT_PART is not ext4"

log "Mounting image"
mount "$ROOT_PART" "$ROOT_MNT"
mkdir -p "$ROOT_MNT/boot/firmware"
mount "$BOOT_PART" "$ROOT_MNT/boot/firmware"

ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$ROOT_PART")"
[ -n "$ROOT_PARTUUID" ] || die "could not read root PARTUUID"

log "Installing boot configuration"
if [ -f "$ROOT_MNT/boot/firmware/config.txt" ]; then
    cp -a "$ROOT_MNT/boot/firmware/config.txt" "$ROOT_MNT/boot/firmware/config.txt.orig"
fi
if [ -f "$ROOT_MNT/boot/firmware/cmdline.txt" ]; then
    cp -a "$ROOT_MNT/boot/firmware/cmdline.txt" "$ROOT_MNT/boot/firmware/cmdline.txt.orig"
fi
install -m 0644 "$CONFIG_DIR/config.txt" "$ROOT_MNT/boot/firmware/config.txt"
sed "s/__ROOT_PARTUUID__/$ROOT_PARTUUID/g" \
    "$CONFIG_DIR/cmdline.txt" > "$ROOT_MNT/boot/firmware/cmdline.txt"

log "Staging repository and provisioner into the image"
rm -rf "$ROOT_MNT/tmp/zebra-src" "$ROOT_MNT/tmp/zebra-config"
mkdir -p "$ROOT_MNT/tmp/zebra-src/systemd" "$ROOT_MNT/tmp/zebra-config"
install -m 0644 "$REPO_ROOT/zebra_bridge.py" "$ROOT_MNT/tmp/zebra-src/"
install -m 0755 "$REPO_ROOT/run.sh" "$ROOT_MNT/tmp/zebra-src/"
install -m 0755 "$REPO_ROOT/supervise.sh" "$ROOT_MNT/tmp/zebra-src/"
install -m 0644 "$REPO_ROOT/zebra-bridge.conf.example" "$ROOT_MNT/tmp/zebra-src/"
install -m 0644 "$REPO_ROOT/99-zebra-printer.rules" "$ROOT_MNT/tmp/zebra-src/"
install -m 0644 "$REPO_ROOT/systemd/zebra-bridge.service" "$ROOT_MNT/tmp/zebra-src/systemd/"
install -m 0644 "$CONFIG_DIR/blacklist-appliance.conf" "$ROOT_MNT/tmp/zebra-config/"
install -m 0644 "$CONFIG_DIR/journald-volatile.conf" "$ROOT_MNT/tmp/zebra-config/"
install -m 0644 "$CONFIG_DIR/watchdog.conf" "$ROOT_MNT/tmp/zebra-config/"
install -m 0644 "$CONFIG_DIR/bluetooth-main.conf" "$ROOT_MNT/tmp/zebra-config/"
install -m 0644 "$CONFIG_DIR/modules-load.conf" "$ROOT_MNT/tmp/zebra-config/"
install -m 0755 "$SCRIPT_DIR/provision.sh" "$ROOT_MNT/tmp/provision.sh"

log "Preparing chroot"
install -m 0755 /usr/bin/qemu-aarch64-static "$ROOT_MNT/usr/bin/qemu-aarch64-static"
rm -f "$RESOLV_BAK"
cp -a "$ROOT_MNT/etc/resolv.conf" "$RESOLV_BAK"
rm -f "$ROOT_MNT/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOT_MNT/etc/resolv.conf"
cat > "$ROOT_MNT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$ROOT_MNT/usr/sbin/policy-rc.d"

mount --bind /dev "$ROOT_MNT/dev"
mount --bind /dev/pts "$ROOT_MNT/dev/pts"
mount -t proc proc "$ROOT_MNT/proc"
mount -t sysfs sysfs "$ROOT_MNT/sys"

log "Provisioning (this takes several minutes under qemu)"
chroot "$ROOT_MNT" /usr/bin/env \
    DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    /bin/bash /tmp/provision.sh

log "Cleaning up chroot"
rm -f "$ROOT_MNT/usr/sbin/policy-rc.d" "$ROOT_MNT/usr/bin/qemu-aarch64-static"
rm -f "$ROOT_MNT/etc/resolv.conf"
cp -a "$RESOLV_BAK" "$ROOT_MNT/etc/resolv.conf"
rm -rf "$ROOT_MNT/tmp/zebra-src" "$ROOT_MNT/tmp/zebra-config" "$ROOT_MNT/tmp/provision.sh"

sync
umount "$ROOT_MNT/boot/firmware"
umount "$ROOT_MNT/dev/pts" "$ROOT_MNT/dev" "$ROOT_MNT/proc" "$ROOT_MNT/sys"
umount "$ROOT_MNT"
losetup -d "$LOOP_DEV"
LOOP_DEV=""

log "Writing output"
install -m 0644 "$RAW_IMAGE" "$OUTPUT_DIR/$OUTPUT_NAME"
( cd "$OUTPUT_DIR" && sha256sum "$OUTPUT_NAME" > "$OUTPUT_NAME.sha256" )
log "Done: $OUTPUT_DIR/$OUTPUT_NAME"
cat "$OUTPUT_DIR/$OUTPUT_NAME.sha256"
