#!/usr/bin/env bash
# Build a ready-to-flash Raspberry Pi OS Lite (64-bit Bookworm) image for the
# Zebra BLE-to-USB bridge.  Run as root on Linux, or inside the provided
# Docker image:
#
#   image-builder/bluez/build-bluez-deb.sh
#   docker build -t zebra-bridge-image -f image-builder/Dockerfile .
#   docker run --rm --privileged \
#       -v "$PWD/dist:/work/repo/dist" zebra-bridge-image
#
# The output is dist/zebra-bridge-pi-zero2w.img plus a .sha256 file.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
BLUEZ_DEB_VERSION="5.66-1+rpt2+deb12u2+zebra1"
BLUEZ_DEB="$REPO_ROOT/dist/bluez/bluez_${BLUEZ_DEB_VERSION}_arm64.deb"

OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"
WORK_DIR="${WORK_DIR:-/tmp/zebra-bridge-image}"
IMAGE_URL="${RPI_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.img.xz}"
IMAGE_SHA256="${RPI_IMAGE_SHA256:-6ac3a10a1f144c7e9d1f8e568d75ca809288280a593eb6ca053e49b539f465a4}"
# "release" is the shipping appliance.  "debug" is a temporary image with
# Wi-Fi, SSH, writable root, persistent journal, and DEBUG bridge logging.
IMAGE_VARIANT="${IMAGE_VARIANT:-release}"
if [ "$IMAGE_VARIANT" = "debug" ]; then
    OUTPUT_NAME="zebra-bridge-pi-zero2w-debug.img"
else
    OUTPUT_NAME="zebra-bridge-pi-zero2w.img"
fi

IMAGE_FILE="$WORK_DIR/$(basename "$IMAGE_URL")"
# Assemble the raw image directly in the output directory so the final rename
# is a no-op on the same filesystem and we never hold two full copies.
RAW_IMAGE="$OUTPUT_DIR/.$OUTPUT_NAME.partial"
ROOT_MNT="$WORK_DIR/root"
LOOP_DEV=""
ROOT_PART=""
BOOT_PART=""
RESOLV_BAK="$WORK_DIR/resolv.conf.bak"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case "$IMAGE_VARIANT" in
    release|debug) ;;
    *) die "IMAGE_VARIANT must be 'release' or 'debug' (got '$IMAGE_VARIANT')" ;;
esac

cleanup() {
    set +e
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT/dev/pts" && umount "$ROOT_MNT/dev/pts"
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT/dev" && umount "$ROOT_MNT/dev"
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT/proc" && umount "$ROOT_MNT/proc"
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT/sys" && umount "$ROOT_MNT/sys"
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT/boot/firmware" && umount "$ROOT_MNT/boot/firmware"
    [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT" && umount "$ROOT_MNT"
    [ -n "${LOOP_DEV:-}" ] && losetup -d "$LOOP_DEV"
    # Drop the partial image on failure; on success it has been renamed.
    [ -n "${RAW_IMAGE:-}" ] && rm -f "$RAW_IMAGE"
}
trap cleanup EXIT INT TERM

[ "$(id -u)" -eq 0 ] || die "must run as root (or with --privileged in Docker)"
HOST_ARCH="$(uname -m)"
NEED_QEMU=1
case "$HOST_ARCH" in
    aarch64|arm64) NEED_QEMU=0 ;;
esac
for cmd in curl xz sha256sum losetup partx mount chroot blkid; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done
if [ "$NEED_QEMU" -eq 1 ]; then
    command -v qemu-aarch64-static >/dev/null 2>&1 \
        || die "missing required command: qemu-aarch64-static"
    [ -x /usr/bin/qemu-aarch64-static ] || die "qemu-aarch64-static is not installed"
fi
[ -f "$CONFIG_DIR/config.txt" ] || die "missing $CONFIG_DIR/config.txt"
[ -f "$CONFIG_DIR/cmdline.txt" ] || die "missing $CONFIG_DIR/cmdline.txt"
[ -f "$SCRIPT_DIR/provision.sh" ] || die "missing $SCRIPT_DIR/provision.sh"
[ -f "$BLUEZ_DEB" ] || die "missing patched BlueZ package: $BLUEZ_DEB (run image-builder/bluez/build-bluez-deb.sh first)"
if [ "$IMAGE_VARIANT" = "debug" ]; then
    for f in debug-boot.conf debug-boot.py debug-network.service \
             journald-persistent.conf NetworkManager-debug.conf ssh-debug.conf; do
        [ -f "$CONFIG_DIR/$f" ] || die "missing $CONFIG_DIR/$f"
    done
fi

mkdir -p "$WORK_DIR" "$OUTPUT_DIR" "$ROOT_MNT"
chmod 0755 "$ROOT_MNT"

if [ "$NEED_QEMU" -eq 0 ]; then
    # Native arm64 builder: chroot will run the image's binaries directly.
    log "Builder is $HOST_ARCH; qemu/binfmt is not required"
else
    # qemu-user-static deliberately skips binfmt registration when it detects
    # a container, and binfmt_misc is often not mounted inside the container
    # even with --privileged.  Mount it and register aarch64 here; the
    # registration is a kernel-global property, so the host picks it up too.
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
fi

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
# Some container runtimes expose only a minimal /dev even with --privileged.
# The loop module creates /dev/loop-control through devtmpfs; if the nodes are
# missing but the host driver is present, recreate the standard ones.
if [ ! -e /dev/loop-control ]; then
    mknod /dev/loop-control c 10 237 2>/dev/null || true
fi
for _n in 0 1 2 3 4 5 6 7; do
    [ -e "/dev/loop$_n" ] || mknod "/dev/loop$_n" b 7 "$_n" 2>/dev/null || true
done
LOOP_DEV="$(losetup --find --show --partscan "$RAW_IMAGE")" || die \
    "losetup failed; load the loop module on the host (sudo modprobe loop) and pass --privileged"
LOOP_NAME="${LOOP_DEV##*/}"
partx -u "$LOOP_DEV" >/dev/null 2>&1 || true

# A container's /dev is a private tmpfs, so the kernel's devtmpfs partition
# nodes (loop0p1, loop0p2) do not appear there.  Create them from the sysfs
# major:minor numbers, which are visible even when /dev is isolated.
for _ in $(seq 1 50); do
    _ready=1
    for _part in p1 p2; do
        _node="${LOOP_DEV}${_part}"
        if [ ! -b "$_node" ]; then
            _sysdev="/sys/block/${LOOP_NAME}/${LOOP_NAME}${_part}/dev"
            if [ -r "$_sysdev" ]; then
                IFS=: read -r _major _minor < "$_sysdev"
                mknod "$_node" b "$_major" "$_minor" 2>/dev/null || true
            fi
        fi
        [ -b "$_node" ] || _ready=0
    done
    [ "$_ready" -eq 1 ] && break
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

log "Installing boot configuration ($IMAGE_VARIANT)"
if [ -f "$ROOT_MNT/boot/firmware/config.txt" ]; then
    cp -a "$ROOT_MNT/boot/firmware/config.txt" "$ROOT_MNT/boot/firmware/config.txt.orig"
fi
if [ -f "$ROOT_MNT/boot/firmware/cmdline.txt" ]; then
    cp -a "$ROOT_MNT/boot/firmware/cmdline.txt" "$ROOT_MNT/boot/firmware/cmdline.txt.orig"
fi
if [ "$IMAGE_VARIANT" = "debug" ]; then
    # Keep one source of truth for the hardware configuration.  The debug
    # image is identical except that the WLAN function is not disabled.
    DEBUG_CONFIG_TXT="$WORK_DIR/config.txt.debug"
    sed -E '/^[[:space:]]*dtoverlay=disable-wifi[[:space:]]*$/d' \
        "$CONFIG_DIR/config.txt" > "$DEBUG_CONFIG_TXT"
    printf '\n# DEBUG BUILD: Wi-Fi is enabled for SSH access.  Do not ship.\n' \
        >> "$DEBUG_CONFIG_TXT"
    install -m 0644 "$DEBUG_CONFIG_TXT" "$ROOT_MNT/boot/firmware/config.txt"
else
    install -m 0644 "$CONFIG_DIR/config.txt" "$ROOT_MNT/boot/firmware/config.txt"
fi
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
if [ "$IMAGE_VARIANT" = "debug" ]; then
    # The debug image must load the brcmfmac Wi-Fi stack, so drop only the
    # three WLAN blacklist lines from the appliance configuration.
    sed -E '/^[[:space:]]*blacklist[[:space:]]+(brcmfmac|brcmutil|cfg80211)[[:space:]]*$/d' \
        "$CONFIG_DIR/blacklist-appliance.conf" \
        > "$ROOT_MNT/tmp/zebra-config/blacklist-appliance.conf"
    printf '\n# DEBUG BUILD: Wi-Fi modules are intentionally loadable.\n' \
        >> "$ROOT_MNT/tmp/zebra-config/blacklist-appliance.conf"
    chmod 0644 "$ROOT_MNT/tmp/zebra-config/blacklist-appliance.conf"
else
    install -m 0644 "$CONFIG_DIR/blacklist-appliance.conf" "$ROOT_MNT/tmp/zebra-config/"
fi
install -m 0644 "$CONFIG_DIR/journald-volatile.conf" "$ROOT_MNT/tmp/zebra-config/"
install -m 0644 "$CONFIG_DIR/watchdog.conf" "$ROOT_MNT/tmp/zebra-config/"
install -m 0644 "$CONFIG_DIR/bluetooth-main.conf" "$ROOT_MNT/tmp/zebra-config/"
install -m 0644 "$CONFIG_DIR/modules-load.conf" "$ROOT_MNT/tmp/zebra-config/"
install -m 0644 "$BLUEZ_DEB" "$ROOT_MNT/tmp/zebra-config/bluez-patched.deb"
if [ "$IMAGE_VARIANT" = "debug" ]; then
    install -m 0644 "$CONFIG_DIR/debug-boot.conf" \
        "$ROOT_MNT/tmp/zebra-config/zebra-bridge-debug.conf"
    install -m 0755 "$CONFIG_DIR/debug-boot.py" \
        "$ROOT_MNT/tmp/zebra-config/zebra-bridge-debug-boot.py"
    install -m 0644 "$CONFIG_DIR/debug-network.service" "$ROOT_MNT/tmp/zebra-config/"
    install -m 0644 "$CONFIG_DIR/journald-persistent.conf" "$ROOT_MNT/tmp/zebra-config/"
    install -m 0644 "$CONFIG_DIR/NetworkManager-debug.conf" "$ROOT_MNT/tmp/zebra-config/"
    install -m 0644 "$CONFIG_DIR/ssh-debug.conf" "$ROOT_MNT/tmp/zebra-config/"
fi
install -m 0755 "$SCRIPT_DIR/provision.sh" "$ROOT_MNT/tmp/provision.sh"

log "Preparing chroot"
if [ "$NEED_QEMU" -eq 1 ]; then
    install -m 0755 /usr/bin/qemu-aarch64-static "$ROOT_MNT/usr/bin/qemu-aarch64-static"
fi
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
    IMAGE_VARIANT="$IMAGE_VARIANT" \
    DEBUG_WIFI_SSID="${DEBUG_WIFI_SSID:-}" \
    DEBUG_WIFI_PASSWORD="${DEBUG_WIFI_PASSWORD:-}" \
    DEBUG_WIFI_COUNTRY="${DEBUG_WIFI_COUNTRY:-}" \
    DEBUG_SSH_USER="${DEBUG_SSH_USER:-}" \
    DEBUG_SSH_PASSWORD="${DEBUG_SSH_PASSWORD:-}" \
    DEBUG_SSH_AUTHORIZED_KEY="${DEBUG_SSH_AUTHORIZED_KEY:-}" \
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
mv -f "$RAW_IMAGE" "$OUTPUT_DIR/$OUTPUT_NAME"
chmod 0644 "$OUTPUT_DIR/$OUTPUT_NAME"
( cd "$OUTPUT_DIR" && sha256sum "$OUTPUT_NAME" > "$OUTPUT_NAME.sha256" )
# The container runs as root, so the bind-mounted output directory's owner is
# the host user. Hand the artifacts back to that uid:gid; otherwise a build on
# another machine leaves root-owned files that need sudo to read or move.
OUT_OWNER="$(stat -c '%u:%g' "$OUTPUT_DIR" 2>/dev/null || true)"
if [ -n "$OUT_OWNER" ]; then
    chown "$OUT_OWNER" "$OUTPUT_DIR/$OUTPUT_NAME" \
        "$OUTPUT_DIR/$OUTPUT_NAME.sha256" 2>/dev/null || true
fi
log "Done: $OUTPUT_DIR/$OUTPUT_NAME"
cat "$OUTPUT_DIR/$OUTPUT_NAME.sha256"
