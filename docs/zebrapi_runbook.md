# Engineering Runbook: Zebra Bridge Appliance for Raspberry Pi Zero 2 W

## 1. Objective & System Overview

Adapt the `zebra-bridge` repository into a production-ready, headless,
"set-and-forget" embedded appliance image for the **Raspberry Pi Zero 2 W**.

The bridge is a **BLE GATT peripheral**, not a Bluetooth Classic printer:

- It advertises a Zebra-compatible BLE name and the custom GATT service
  `38eb4a80-c570-11e3-9507-0002a5d5c51b`.
- Rock Check-in connects to the advertised name and writes ZPL to
  characteristic `38eb4a82-c570-11e3-9507-0002a5d5c51b`.
- It forwards those bytes to a USB-attached Zebra printer (reference:
  GX420d on `/dev/usb/lp0`).
- **There is no pairing, bonding, or link-key persistence.** Do not add
  `JustWorksRepairing`, a Bluetooth agent, or `/var/lib/bluetooth` key
  persistence for the current Rock workflow. That state is not needed and
  would add SD-card writes.

### Physical wiring (test pads)

The printer is wired directly to the Pi Zero 2 W USB test pads, bypassing the
micro-USB OTG connector's ID pin:

| Pi Zero 2 W pad | USB signal |
| --- | --- |
| `PP1` | +5 V (only for a low-power printer) |
| `PP6` | GND |
| `PP22` | USB D+ |
| `PP23` | USB D- |

Power a Zebra GX420d from its own supply; do not power it from the Pi's 5 V
rail. Connect GND, D+, and D- only. Use a 5 V/2.5 A supply for the Pi itself.

### Core architectural requirements

1. **Repeatable deployment image**: an automated pipeline that outputs a
   ready-to-flash `.img` with all packages, configuration, and scripts.
2. **Auto-launch**: start `zebra_bridge.py` on boot and keep it alive.
3. **FAT32-accessible configuration**: `zebra-bridge.conf` on
   `/boot/firmware` so operators can edit it on any PC after flashing.
4. **Software USB host mode**: force `dwc2` into host mode because the OTG ID
   pin is not grounded.
5. **Offline & headless**: disable Wi-Fi, HDMI/video, networking, and SSH
   while keeping the shared radio's Bluetooth subsystem active.
6. **Fast boot & trimmed OS**: skip unused modules and services.
7. **Zero SD-card writes**: OverlayFS root backed by tmpfs, read-only
   `/boot/firmware`, volatile journald, and a hardware watchdog.

---

## 2. Repository Audit & Codebase Adaptation

### Step 2.1: Existing files

Audit and retain these files:

- `zebra_bridge.py` — BLE GATT server and USB forwarder.
- `zebra-bridge.conf.example` — operator-facing INI template.
- `99-zebra-printer.rules` — udev permissions for the USB printer.
- `run.sh` — manual start/stop/status wrapper (non-systemd fallback).
- `supervise.sh` — restart loop used by `run.sh start`.
- `README.md` — build, wiring, and operation instructions.

New appliance files:

- `systemd/zebra-bridge.service`
- `image-builder/Dockerfile`
- `image-builder/build-image.sh`
- `image-builder/provision.sh`
- `image-builder/config/config.txt`
- `image-builder/config/cmdline.txt`
- `image-builder/config/blacklist-appliance.conf`
- `image-builder/config/bluetooth-main.conf`
- `image-builder/config/journald-volatile.conf`
- `image-builder/config/modules-load.conf`
- `image-builder/config/watchdog.conf`
- `tests/test_config_loading.py`

### Step 2.2: Configuration loading (`zebra_bridge.py`)

1. **Search order** (first usable file wins). The bootfs file must win on the
   appliance so the operator can edit it on a PC:

   ```text
   --config PATH
   $ZEBRA_BRIDGE_CONFIG
   /boot/firmware/zebra-bridge.conf   # Bookworm bootfs
   /boot/zebra-bridge.conf            # legacy bootfs
   /etc/zebra-bridge.conf
   ./zebra-bridge.conf                # local development only
   ```

   The original repository put `./zebra-bridge.conf` first. That is wrong for
   an appliance: a stale file in `/opt/zebra-bridge` would silently override
   the SD-card configuration. It was moved to last; use `--config` or
   `ZEBRA_BRIDGE_CONFIG` for development.

2. **BOM and line-ending sanitization**. The parser must:
   - open the file with `encoding="utf-8-sig"` so a Windows UTF-8 BOM is
     stripped;
   - read the whole file and normalize `\r\n` and old-Mac `\r` to `\n`
     before handing it to `configparser`;
   - strip any stray `\r` from individual values;
   - fail with a clear "not valid UTF-8" error rather than a traceback;
   - report a missing `[bridge]` section clearly.

   `tests/test_config_loading.py` covers BOM + CRLF, CR-only, inline comments,
   duplicate keys, invalid UTF-8, missing sections, and search priority.

3. **Read-only compatibility**. The runtime must not write to
   `/opt/zebra-bridge` or `/boot/firmware`:
   - Route Python logs to stdout/stderr; systemd sends them to journald.
   - Keep the `flock` lock in `$TMPDIR` or `/run/zebra-bridge`.
   - Set `PYTHONDONTWRITEBYTECODE=1` and `PYTHONUNBUFFERED=1`.
   - Change `run.sh`'s default log path from `$SCRIPT_DIR/zebra-bridge.log`
     to `$XDG_RUNTIME_DIR/zebra-bridge.log` (fallback `/tmp`). Otherwise a
     manual `run.sh start` creates a log inside the read-only lower layer or,
     on a writable system, grows the SD-card image.
   - `supervise.sh` only writes to stdout; it does not need a log file.

### Step 2.3: Native systemd service (`systemd/zebra-bridge.service`)

Use the unit in the repository. Key corrections versus the original draft:

- **Do not use `DefaultDependencies=no`.** It removes ordering against
  `basic.target`, shutdown, and device units, which is dangerous for a service
  that needs D-Bus, udev, and the Bluetooth UART.
- **Wait for `hciuart.service`.** `bluetooth.service` alone does not guarantee
  that the onboard Bluetooth UART has been attached by `hciattach`. The unit
  orders after `bluetooth.service`, `hciuart.service`, and
  `systemd-udevd.service`.
- Use `Wants=` rather than `Requires=` for Bluetooth. If Bluetooth fails on a
  cold boot, the bridge should still start and retry internally instead of
  failing the unit permanently.
- Add `RuntimeDirectory=zebra-bridge`, `TMPDIR=/run/zebra-bridge`, and
  `ReadWritePaths=/run/zebra-bridge` so the lock/temp state is in RAM.
- Add `ExecStartPre=-/usr/sbin/rfkill unblock bluetooth` to clear a persisted
  soft block.
- Keep `Restart=always`, `RestartSec=2`, `StandardOutput=journal`, and
  `StandardError=journal`.
- Add basic hardening (`ProtectSystem=strict`, `ProtectHome=true`,
  `PrivateTmp=true`, `NoNewPrivileges=true`, etc.). Do **not** add
  `PrivateDevices=yes`: it would hide `/dev/usb/lp*`.
- Do not use `ProtectKernelModules=yes` if you rely on the service to load
  `usblp`; the image relies on udev to load it before the service starts.

The resulting unit is:

```ini
[Unit]
Description=Zebra BLE-to-USB Printer Bridge
Documentation=https://github.com/tokanada/zebra-bridge
After=bluetooth.service hciuart.service systemd-udevd.service
Wants=bluetooth.service hciuart.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=/opt/zebra-bridge
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONUNBUFFERED=1
Environment=TMPDIR=/run/zebra-bridge
RuntimeDirectory=zebra-bridge
RuntimeDirectoryMode=0755
ExecStartPre=-/usr/sbin/rfkill unblock bluetooth
ExecStart=/usr/bin/python3 /opt/zebra-bridge/zebra_bridge.py
Restart=always
RestartSec=2
TimeoutStartSec=infinity
StandardOutput=journal
StandardError=journal
SyslogIdentifier=zebra-bridge

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/run/zebra-bridge
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
```

### Step 2.4: Udev rules (`99-zebra-printer.rules`)

The rule must grant access to the `usblp` device node created for a Zebra
printer (vendor ID `0a5f`):

```udev
SUBSYSTEM=="usbmisc", KERNEL=="lp[0-9]*", SUBSYSTEMS=="usb", \
  ATTRS{idVendor}=="0a5f", GROUP="lp", MODE="0660"
```

Notes:

- `MODE="0660"` with `GROUP="lp"` is preferred over `MODE="0666"`. The
  systemd unit runs as root, and manual runs should use the `lp` group. Use
  `0666` only if you deliberately run the bridge as an unprivileged user that
  cannot join `lp`.
- The rule must not write to `/boot/firmware` or `/opt`.
- Do **not** blacklist `usblp`; it creates `/dev/usb/lp0`.
- The bridge opens the printer per write, so it tolerates a printer that is
  power-cycled after boot.

---

## 3. Hardware, Kernel, & Boot Configuration

Templates live in `image-builder/config/`.

### Step 3.1: `/boot/firmware/config.txt`

```ini
arm_64bit=1

# OverlayFS lives in the initramfs; the firmware must load initramfs8.
auto_initramfs=1
disable_overscan=1

# USB host mode on the test pads (PP22/PP23); the OTG ID pin is not grounded.
dtoverlay=dwc2,dr_mode=host

# Disable the WLAN half of the shared radio; Bluetooth stays active.
dtoverlay=disable-wifi

# Headless: no audio, camera, display probing, or framebuffers.
dtparam=audio=off
camera_auto_detect=0
display_auto_detect=0
max_framebuffers=0
disable_fw_kms_setup=1
gpu_mem=16

# Fast boot.
boot_delay=0
disable_splash=1
disable_poe_fan=1
initial_turbo=30

# BCM2835 hardware watchdog.  The hardware maximum is just under 16 seconds.
dtparam=watchdog=on

# Optional recovery console over GPIO 14/15.  This moves Bluetooth onto the
# slower mini UART; validate BLE throughput before shipping with these on.
#enable_uart=1
#dtoverlay=miniuart-bt
```

Notes:

- `auto_initramfs=1` is **required** because OverlayFS is implemented by the
  `overlayroot` initramfs hook. Overwriting the stock `config.txt` without it
  would silently disable overlay root.
- `dtoverlay=dwc2,dr_mode=host` is the correct overlay parameter for host
  mode. It is not a kernel module blacklist entry.
- `dtoverlay=disable-wifi` does not disable Bluetooth on the shared
  Cypress/Synaptics radio.
- `max_framebuffers=0` is valid for headless use and saves memory.
- `dtparam=watchdog=on` enables the BCM2835 watchdog device tree node. The
  hardware watchdog timeout is capped at just under 16 seconds.
- `initial_turbo=30` is optional. Remove it if the Pi is unstable on a marginal
  supply.

### Step 3.2: `/boot/firmware/cmdline.txt`

Keep this as a **single line**. Preserve the image's real root `PARTUUID`;
never hard-code `/dev/mmcblk0p2`, which breaks if the card enumerates
differently or the image is booted from another interface.

```text
console=tty1 root=PARTUUID=__ROOT_PARTUUID__ rootfstype=ext4 rootwait ro fsck.mode=skip quiet loglevel=0 systemd.show_status=false logo.nologo vt.global_cursor_default=0 ipv6.disable=1
```

`build-image.sh` replaces `__ROOT_PARTUUID__` with `blkid` output. Then
`raspi-config nonint do_overlayfs 0` prepends `overlayroot=tmpfs`:

```text
overlayroot=tmpfs console=tty1 root=PARTUUID=... rootfstype=ext4 rootwait ro ...
```

Corrections versus the original draft:

- The overlay parameter is `overlayroot=tmpfs`, **not** `boot=overlay`.
  `raspi-config` implements OverlayFS with the `overlayroot` package.
- `fastboot` is not a standard kernel/systemd parameter; use `fsck.mode=skip`.
- `noswap` is not needed; the image purges `dphys-swapfile` and has no swap
  entry.
- `noatime`/`nodiratime` belong in mount options, not the kernel command line.
  The root is read-only anyway.
- Do not remove `rootwait`; SD cards can enumerate late.

---

## 4. Fast Boot & Kernel/OS Trimming

Do not compile a custom kernel: it risks breaking the proprietary Bluetooth
UART firmware initialization on the Pi Zero 2 W.

### Step 4.1: Module blacklist (`/etc/modprobe.d/blacklist-appliance.conf`)

```ini
blacklist brcmfmac
blacklist brcmutil
blacklist cfg80211

blacklist snd_bcm2835
blacklist snd_pcm
blacklist snd_timer
blacklist snd

blacklist vc4
blacklist drm_kms_helper
blacklist drm
blacklist cec
blacklist v3d
blacklist bcm2835_v4l2
blacklist bcm2835_codec
blacklist bcm2835_isp
blacklist bcm2835_mmal_vchiq
```

**Do not blacklist** `btbcm`, `hci_uart`, `bluetooth`, `usblp`, `dwc2`, or
`bcm2835_wdt`. The original draft correctly warned about the first group but
did not mention `usblp` or the watchdog.

`image-builder/config/modules-load.conf` additionally loads `usblp` early
(`/etc/modules-load.d/zebra-usblp.conf`) so `/dev/usb/lp0` exists even if
udev's class-alias loading is delayed. Do not add `bcm2835_wdt` to
`modules-load.d`; the device-tree watchdog is handled by
`dtparam=watchdog=on` and systemd.

### Step 4.2: Systemd service stripping

Mask non-essential units **after** installing packages (so package
post-install scripts can run) and **before** enabling OverlayFS. Never mask:

- `dbus.service`
- `bluetooth.service`
- `hciuart.service`
- `systemd-udevd.service`
- `systemd-journald.service`
- `zebra-bridge.service`

Mask at least:

```bash
SERVICES_TO_MASK=(
    NetworkManager.service
    NetworkManager-wait-online.service
    wpa_supplicant.service
    networking.service
    dhcpcd.service
    ssh.service
    sshd.service
    avahi-daemon.service
    avahi-daemon.socket
    triggerhappy.service
    triggerhappy.socket
    ModemManager.service
    apt-daily.service
    apt-daily.timer
    apt-daily-upgrade.service
    apt-daily-upgrade.timer
    dpkg-db-backup.timer
    man-db.timer
    e2scrub_all.timer
    e2scrub_reap.service
    systemd-timesyncd.service
    systemd-networkd.service
    systemd-networkd.socket
    systemd-resolved.service
    systemd-resolved.socket
    cron.service
    rsyslog.service
    syslog.socket
    alsa-restore.service
    alsa-state.service
    raspi-config.service
    regenerate_ssh_host_keys.service
    userconfig.service
    getty@tty1.service
    rpi-eeprom-update.service
)
for svc in "${SERVICES_TO_MASK[@]}"; do
    systemctl --root=/ disable "$svc" >/dev/null 2>&1 || true
    systemctl --root=/ mask "$svc" >/dev/null 2>&1 || true
done
```

`getty@tty1` is masked because there is no HDMI output. A serial getty is not
masked, so an operator can enable the optional GPIO console if needed.

### Step 4.3: Build the initramfs

The stock Raspberry Pi OS image ships `MODULES=dep` in
`/etc/initramfs-tools/initramfs.conf`. **Do not rebuild the initramfs with
`dep` inside the image-build chroot.** `initramfs-tools` resolves `dep` by
reading `/proc/mounts`; in a chroot that shows the build host's root device, so
the generated initramfs would contain the host's storage drivers instead of the
Pi's `mmc`/`sdhci` stack and the image would not boot.

Force `most` before rebuilding in the chroot:

```bash
sed -i -E 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
```

`most` copies the broad module set, but it does not inspect host hardware.
The `overlayroot` hook additionally adds `overlay`, `overlayfs`, and the
device-mapper modules explicitly. This mirrors how official Raspberry Pi OS
images are produced: the shipped initramfs is built with `most`, while `dep`
is only used for later on-device kernel updates where `/proc` is real.

Raspberry Pi OS also ships `update_initramfs=no` while an image is being
assembled. Flip it back to `yes` or `update-initramfs -u` silently prints
"Not updating initramfs" and exits success without changing anything. This
build uses `-c` (create) as well, which bypasses that gate:

```bash
sed -i -E 's/^update_initramfs=.*/update_initramfs=yes/' \
    /etc/initramfs-tools/update-initramfs.conf
update-initramfs -c -k all
```

`update-initramfs` writes `/boot/initrd.img-<version>`. The
`raspi-firmware` post-update hook then copies the newest one to
`/boot/firmware/initramfs8`, which is the filename `auto_initramfs=1` looks
for with `kernel8.img`. Verify both the copy and its overlayroot hook:

```bash
test -s /boot/firmware/initramfs8
lsinitramfs /boot/firmware/initramfs8 | grep init-bottom/overlayroot
```

---

## 5. Read-Only Filesystem, Bluetooth & High Reliability

### Step 5.1: OverlayFS and read-only boot

1. Install the `overlayroot` package.
2. Run `raspi-config nonint do_overlayfs 0`. On current Raspberry Pi OS this:
   - prepends `overlayroot=tmpfs` to `cmdline.txt`;
   - installs `overlayroot` if missing;
   - sets the `/boot/firmware` fstab entry to `ro`.
3. Verify both invariants after `raspi-config` because it behaves differently
   inside a chroot:
   - `grep overlayroot=tmpfs /boot/firmware/cmdline.txt`
   - the `/boot/firmware` line in `/etc/fstab` contains `ro`
4. Rebuild the initramfs after changing OverlayFS or module configuration
   (also re-enable automatic updates first; see Step 4.3):

   ```bash
   sed -i -E 's/^update_initramfs=.*/update_initramfs=yes/' \
       /etc/initramfs-tools/update-initramfs.conf
   update-initramfs -c -k all
   test -s /boot/firmware/initramfs8
   lsinitramfs /boot/firmware/initramfs8 | grep init-bottom/overlayroot
   ```

   The `raspi-firmware` package copies the generated `/boot/initrd.img-<ver>`
   to `/boot/firmware/initramfs8` through
   `/etc/initramfs/post-update.d/z50-raspi-firmware`. If that file is missing,
   `auto_initramfs=1` finds nothing and the device boots with a writable root.

5. Purge `dphys-swapfile` and remove `/var/swap`; ensure `/etc/fstab` has no
   swap entry.

6. Configure journald with a drop-in rather than editing the vendor file:

   ```ini
   # /etc/systemd/journald.conf.d/99-volatile.conf
   [Journal]
   Storage=volatile
   RuntimeMaxUse=16M
   RuntimeKeepFree=16M
   ForwardToSyslog=no
   ForwardToKMsg=no
   ForwardToConsole=no
   Compress=yes
   ```

The original draft's `boot=overlay` note was wrong. The correct mechanism on
Raspberry Pi OS Bookworm is `overlayroot=tmpfs` plus the `overlayroot` package.

### Step 5.2: Bluetooth pairing/state — corrected for BLE GATT

**This bridge does not pair or bond.** Rock connects to the GATT service
without pairing. The original draft's Bluetooth agent, `JustWorksRepairing`,
`DiscoverableTimeout`, and `/var/lib/bluetooth` link-key tar are unnecessary
and should not be implemented for this workload. They add complexity and
SD-card writes.

Configure `/etc/bluetooth/main.conf` for a peripheral-only BLE device:

```ini
[General]
ReverseServiceDiscovery = false

[Policy]
AutoEnable = true

[LE]
MinConnectionInterval = 12
MaxConnectionInterval = 24
ConnectionLatency = 0
ConnectionSupervisionTimeout = 500
```

`ReverseServiceDiscovery = false` prevents iOS disconnects on a
peripheral-only device. The `[LE]` values improve iOS stability; BlueZ falls
back to defaults if a key is unsupported.

On an OverlayFS root, `/var/lib/bluetooth` is tmpfs and is recreated every
boot. That is harmless here because:

- there are no bonds or link keys to preserve;
- the adapter's hardware address is fixed;
- `zebra_bridge.py` sets the adapter `Powered` and `Alias` properties over
  D-Bus on every start;
- the GATT application and advertisement are registered on every start.

If a future requirement introduces bonding, persist state on a dedicated
writable ext4 data partition, not as a tar archive on FAT32. FAT does not
preserve Unix ownership/permissions and remounting bootfs read-write on every
pairing creates unnecessary SD-card wear.

### Step 5.3: Hardware watchdog

The BCM2835 watchdog's `PM_WDOG_TIME_SET` field is `0xfffff`, and the driver
keeps seconds in the upper 16 bits, so the hardware maximum is just under
16 seconds (about 15.99 s). The original draft's `RebootWatchdogSec=2m` cannot
be honored: systemd cannot extend the hardware timeout, and an over-range
request is clamped or ignored depending on the driver. Keep values at 15 s or
less.

Use a drop-in at `/etc/systemd/system.conf.d/99-watchdog.conf`:

```ini
[Manager]
RuntimeWatchdogSec=10s
RebootWatchdogSec=15s
```

`dtparam=watchdog=on` in `config.txt` enables the device tree node. Verify:

```bash
systemctl show -p RuntimeWatchdogUSec
cat /sys/class/watchdog/watchdog0/identity
cat /sys/class/watchdog/watchdog0/timeout
```

`wdctl` (from util-linux) prints the same state if it is installed:

```bash
wdctl
```

`kernel_watchdog_timeout=` is the newer firmware property and is preferred by
the Raspberry Pi documentation when you need watchdog coverage from power-on.
It sets systemd's `watchdog.open_timeout`; if boot takes longer than the
timeout, the Pi can reset before systemd starts. For this appliance, the
simpler `dtparam=watchdog=on` plus `RuntimeWatchdogSec=10s` avoids that
boot-loop risk. If you enable `kernel_watchdog_timeout`, measure cold-boot
time first and keep the value at or below 15s.

---

## 6. Automated Image Generation Pipeline

The pipeline lives in `image-builder/`.

### Directory layout

```text
image-builder/
├── Dockerfile
├── build-image.sh          # runs on x86_64 build host / in container
├── provision.sh            # runs inside the arm64 chroot under qemu
├── verify-image.py         # root-free post-build inspection of the .img
└── config/
    ├── config.txt
    ├── cmdline.txt
    ├── blacklist-appliance.conf
    ├── bluetooth-main.conf
    ├── journald-volatile.conf
    ├── modules-load.conf
    └── watchdog.conf
```

### Step 6.1: Build stages

1. **Download and verify**
   - Fetch the pinned Raspberry Pi OS Lite 64-bit Bookworm `.img.xz`.
   - Verify its pinned SHA256 before decompressing.
   - The current pin in `build-image.sh` is the 2024-11-19 release. Update the
     URL and checksum together.

2. **Extract, attach, mount**
   - Decompress with `xz -dc`.
   - Attach with `losetup --find --show --partscan`.
   - Confirm `p1` is `vfat` (bootfs) and `p2` is `ext4` (rootfs).
   - Mount root, then `bootfs` at `<root>/boot/firmware`.

3. **Chroot provisioning** (`provision.sh`):
   - Install packages **before** masking networking:
     `python3`, `python3-dbus`, `python3-gi`, `bluez`, `pi-bluetooth`,
     `rfkill`, `initramfs-tools`, `overlayroot`, `raspi-config`.
   - Copy `zebra_bridge.py`, `run.sh`, and `supervise.sh` to
     `/opt/zebra-bridge/` with executable permissions.
   - Copy `zebra-bridge.conf.example` to
     `/boot/firmware/zebra-bridge.conf` only if it does not already exist.
   - Create `/etc/zebra-bridge.conf -> /boot/firmware/zebra-bridge.conf`.
   - Install the udev rule, systemd unit, blacklist, journald drop-in,
     watchdog drop-in, and BlueZ `main.conf`.
   - Install `config.txt` and generate `cmdline.txt` with the real root
     `PARTUUID`.
   - Enable `bluetooth.service`, `hciuart.service`, and `zebra-bridge.service`.
   - Mask non-essential services.
   - Run `raspi-config nonint do_overlayfs 0`, verify the fstab and cmdline
     invariants, set `update_initramfs=yes` and `MODULES=most` (never `dep` in
     the chroot), run `update-initramfs -c -k all`, then assert that
     `/boot/firmware/initramfs8` exists and contains
     `init-bottom/overlayroot`.
   - Leave `/etc/machine-id` empty so systemd generates a unique id per unit
     on first boot (pre-generating it in the build would clone one id onto
     every flashed card).
   - Use `/usr/sbin/policy-rc.d` returning `101` so package post-install
     scripts do not start daemons inside the chroot.
   - Copy `qemu-aarch64-static` into the chroot and restore the image's
     original `/etc/resolv.conf` afterward.

4. **Cleanup and export**
   - `apt-get clean`; remove `/var/lib/apt/lists/*`, apt archives, logs, and
     temp files.
   - Remove the chroot's `qemu-aarch64-static` and `policy-rc.d`.
   - `sync`, unmount bind mounts, unmount bootfs and root, detach the loop
     device.
   - Write `dist/zebra-bridge-pi-zero2w.img` and its `.sha256`.

### Step 6.2: Running the build

```bash
docker build -t zebra-bridge-image -f image-builder/Dockerfile .
mkdir -p dist
docker run --rm --privileged \
    -v "$PWD/dist:/work/repo/dist" \
    zebra-bridge-image
```

`--privileged` is required for `losetup`, mounts, and writable
`binfmt_misc`. The container includes `qemu-user-static` and
`binfmt-support`. Because the package skips registration when it detects a
container, `build-image.sh` mounts `binfmt_misc` if necessary and registers the
`qemu-aarch64` handler itself, then copies the static binary into the chroot.

Docker's `/dev` is a private tmpfs even under `--privileged`, so the kernel's
`/dev/loop*` and `/dev/loopNpM` nodes are not visible inside the container.
`build-image.sh` recreates `/dev/loop-control` and the standard loop block
nodes, then derives the partition nodes (`loop0p1`, `loop0p2`) from
`/sys/block/loopN/loopNpM/dev` with `mknod`. Do not "fix" this by mounting the
host `/dev`; that is fragile and leaks host devices into the build.

Set `WORK_DIR` to a persistent directory so the ~460 MB base `.xz` is not
re-downloaded while iterating:

```bash
WORK=/var/cache/zebra-bridge-build
docker run --rm --privileged \
    -v "$PWD/dist:/work/repo/dist" \
    -v "$WORK:/work/work" -e WORK_DIR=/work/work \
    zebra-bridge-image
```

Resource notes (measured on a 26 GB x86_64 host):

- The build downloads ~460 MB; keep at least **6 GB free** before starting
  (base `.xz` + uncompressed image + package caches).
- Provisioning under qemu takes about **30 minutes** end to end, almost all of
  it in `apt-get` and `update-initramfs`. It is CPU-bound on the emulated
  arm64 chroot, not I/O-bound.
- `build-image.sh` assembles the image as `dist/.<name>.partial` and renames it
  at the end, so only one full copy exists at any time. Expect the final
  `dist/zebra-bridge-pi-zero2w.img` to be ~2.6 GiB (2,755,657,728 bytes for the
  reference build).
- The output `.img` is the full uncompressed image. Shrink it with
  `pishrink.sh` only if you understand the partition/overlay implications.

---

## 7. Deliverables & Acceptance Checklist

- [x] **Updated `zebra_bridge.py`**: loads `/boot/firmware/zebra-bridge.conf`
      first, accepts `--config`/`ZEBRA_BRIDGE_CONFIG` overrides, strips UTF-8
      BOM and CRLF/CR, and performs zero writes to persistent storage during
      runtime.
- [x] **Systemd unit (`systemd/zebra-bridge.service`)**: starts after
      `bluetooth.service`, `hciuart.service`, and `systemd-udevd.service`;
      restarts automatically; logs to volatile journald; runs with a runtime
      directory in `/run`.
- [x] **Boot configs (`image-builder/config/config.txt` & `cmdline.txt`)**:
      include `dtoverlay=dwc2,dr_mode=host`, `dtoverlay=disable-wifi`,
      `dtparam=watchdog=on`, headless/fast-boot parameters, and a real root
      `PARTUUID` placeholder.
- [x] **Read-only runtime**: `overlayroot=tmpfs`, read-only `/boot/firmware`,
      volatile journald, no swap, and no logs/PID/bytecode under `/opt` or
      `/boot/firmware`. The build asserts that `/boot/firmware/initramfs8`
      exists and contains the overlayroot hook, so the overlay cannot silently
      fail to activate.
- [x] **Bluetooth configuration**: `ReverseServiceDiscovery = false`,
      `AutoEnable = true`, and iOS-friendly `[LE]` parameters. No pairing or
      link-key persistence is implemented because the bridge is a BLE GATT
      peripheral and Rock does not bond.
- [x] **Automated image builder (`image-builder/build-image.sh` &
      `Dockerfile`)**: single-command build that verifies the base image,
      provisions the chroot, enables OverlayFS, masks non-essential services,
      and outputs `dist/zebra-bridge-pi-zero2w.img`.
- [x] **Updated `README.md`**: documents image build, test-pad wiring
      (`PP1` 5V, `PP6` GND, `PP22` D+, `PP23` D-), editing
      `zebra-bridge.conf` on the `bootfs` partition, read-only runtime, and
      recovery options.
- [x] **Config parser tests**: `python3 -m unittest discover -s tests -v`
      covers BOM, CRLF, CR, inline comments, duplicate keys, invalid UTF-8,
      missing sections, and bootfs priority.

### Host-side verification (no root, no loop device)

The repository ships `image-builder/verify-image.py`, which performs the
checks below. It reads the FAT bootfs with `mtools` and the ext4 rootfs with
`debugfs` directly from the image file, so it needs neither root nor a loop
device.

```bash
python3 image-builder/verify-image.py
sha256sum -c dist/zebra-bridge-pi-zero2w.img.sha256
```

For manual spot checks, `sfdisk` reports the partition offsets; `mtools` and
`debugfs` then read the partitions at those offsets.

```bash
IMG=dist/zebra-bridge-pi-zero2w.img
sha256sum -c dist/zebra-bridge-pi-zero2w.img.sha256
sfdisk --json "$IMG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"])'

# bootfs (offset from sfdisk start * sectorsize)
mdir  -i "$IMG@@4194304" ::/
mtype -i "$IMG@@4194304" ::/cmdline.txt

# rootfs
debugfs -R 'cat /etc/fstab' "$IMG?offset=541065216"
```

Assert at minimum:

- bootfs: `auto_initramfs=1`, `dtoverlay=dwc2,dr_mode=host`,
  `dtoverlay=disable-wifi`, `dtparam=watchdog=on`,
  `cmdline.txt` has `overlayroot=tmpfs`, `ro`, and a real
  `root=PARTUUID=` (no `__ROOT_PARTUUID__`), `initramfs8` is present and
  non-empty, and `zebra-bridge.conf` is present with LF endings.
- rootfs: `/boot/firmware` is `ro` in `/etc/fstab`, `MODULES=most`,
  `update_initramfs=yes`, `/etc/machine-id` is empty, `zebra-bridge.service` is
  enabled, `ssh.service` is masked to `/dev/null`, `/etc/zebra-bridge.conf`
  links to `/boot/firmware/zebra-bridge.conf`, and the watchdog, journald, and
  BlueZ drop-ins are in place.

The reference build produced on 2026-11-07 with the pinned base image:

```
61538efdc577488208d3f704d5dd00ce14e77c1077a1ade7ad2c6fc4f93595ac  zebra-bridge-pi-zero2w.img
```

All 32 bootfs/rootfs assertions passed. This hash is only a sanity reference;
it will change whenever the base image pin, packages, or provisioning scripts
change.

### First-boot verification

1. Flash the image and edit `zebra-bridge.conf` on `bootfs`; give each unit a
   unique `name` and `serial`.
2. Boot the Pi with the printer connected to the test pads and powered.
3. Check the service and the adapter:

   ```bash
   systemctl status zebra-bridge
   journalctl -u zebra-bridge -b --no-pager
   bluetoothctl show
   rfkill list bluetooth
   ls -l /dev/usb/lp0
   findmnt /
   findmnt /boot/firmware
   ```

4. Confirm Rock sees the configured name and that **Print Test Label** works.
5. Confirm the root is `overlay` and `/boot/firmware` is `ro`.
6. Power-cycle the Pi several times and confirm the printer is still visible
   and prints without re-pairing. This is expected: there is no bond to lose.

### Known limitations / operational notes

- **No network recovery console.** SSH and networking are masked by design.
  Keep the optional serial console block in `config.txt` or a reflash plan
  for field recovery.
- **bootfs is read-only at runtime.** Configuration changes require a
  power-off and SD-card edit on a PC.
- **The image is Pi Zero 2 W-specific.** Do not reuse `config.txt` on a Pi 4/5
  without reviewing USB host mode, framebuffer, and watchdog settings.
- **The base image pin will age.** Update the URL and SHA256 deliberately;
  do not silently track `latest`.
- **The watchdog maximum is just under 16s.** Use 15s or less; values above
  that are rejected or clamped. Do not set `RebootWatchdogSec=2m` as the
  original draft did.
