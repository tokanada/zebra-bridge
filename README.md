# Zebra BLE-to-USB Bridge for Rock RMS

Emulates a Zebra **ZD421** Bluetooth LE printer and forwards the ZPL bytes
that Rock Check-in sends over BLE to a USB-attached Zebra printer. The current
reference hardware is a **GX420d** on `/dev/usb/lp0`.

The bridge is a BLE **GATT peripheral**. Rock's iOS app connects to the
advertised name and writes ZPL to a custom characteristic. There is no pairing,
no bonding, and no Bluetooth Classic SPP; the Pi does not need to store link
keys across reboots.

This repository now includes a repeatable Raspberry Pi OS Lite image builder
for the **Raspberry Pi Zero 2 W**. The image is headless, read-only at runtime,
and starts the bridge automatically with systemd. `run.sh` remains available
for manual testing on a normal Linux host.

The full engineering specification, build rationale, and acceptance criteria
are in [`docs/zebrapi_runbook.md`](docs/zebrapi_runbook.md).

## Files

| File | Purpose |
| --- | --- |
| `zebra_bridge.py` | BLE GATT server and USB printer forwarder |
| `run.sh` | Manual start/stop/status/logs wrapper with automatic restart |
| `supervise.sh` | Restart loop used by `run.sh start` |
| `zebra-bridge.conf.example` | Example per-Pi configuration file |
| `99-zebra-printer.rules` | udev rule for Zebra USB printer permissions |
| `systemd/zebra-bridge.service` | Native systemd unit used by the appliance image |
| `image-builder/Dockerfile` | Reproducible image-build container |
| `image-builder/build-image.sh` | Downloads, provisions, and exports the `.img` |
| `image-builder/verify-image.py` | Root-free post-build inspection of the `.img` |
| `image-builder/provision.sh` | Runs inside the arm64 image chroot |
| `image-builder/config/` | Boot, kernel, BlueZ, journald, and watchdog templates |
| `tests/test_config_loading.py` | BOM/CRLF/priority tests for the config parser |

## Build the appliance image

The build host needs Docker with `--privileged` support (loop devices, mounts,
and `binfmt_misc`). The build downloads the pinned Raspberry Pi OS Lite
64-bit Bookworm image, verifies its SHA256, provisions it under
`qemu-aarch64-static`, and writes:

```text
dist/zebra-bridge-pi-zero2w.img
dist/zebra-bridge-pi-zero2w.img.sha256
```

```bash
git clone https://github.com/tokanada/zebra-bridge.git
cd zebra-bridge

docker build -t zebra-bridge-image -f image-builder/Dockerfile .
mkdir -p dist
docker run --rm --privileged \
    -v "$PWD/dist:/work/repo/dist" \
    zebra-bridge-image
```

The base image URL and SHA256 are variables at the top of
`image-builder/build-image.sh`. Update them deliberately when moving to a
newer Raspberry Pi OS release.

To avoid re-downloading the base image between runs, persist `WORK_DIR`:

```bash
docker run --rm --privileged \
    -v "$PWD/dist:/work/repo/dist" \
    -v "$HOME/.cache/zebra-bridge-build:/work/work" -e WORK_DIR=/work/work \
    zebra-bridge-image
```

Check the finished image on the build host without root, a loop device, or a
mount:

```bash
python3 image-builder/verify-image.py
sha256sum -c dist/zebra-bridge-pi-zero2w.img.sha256
```

The verifier reads both partitions straight out of the file (`mtools` for
bootfs, `debugfs` for rootfs) and exits non-zero if any boot, OverlayFS,
Bluetooth, watchdog, or service assertion fails.

To build without Docker, run the same script as root on an x86_64 Linux host
with `qemu-user-static`, `binfmt-support`, `util-linux`, `dosfstools`,
`e2fsprogs`, `xz-utils`, and `curl` installed:

```bash
sudo RPI_IMAGE_URL=... RPI_IMAGE_SHA256=... image-builder/build-image.sh
```

The uncompressed build needs roughly 6 GB of free space in `WORK_DIR`
(default `/tmp/zebra-bridge-image`).

## Flash and configure the SD card

1. Flash `dist/zebra-bridge-pi-zero2w.img` with Raspberry Pi Imager
   (**Use custom image**) or `dd`. Do not use the Imager OS customisation
   screen; the image already contains its own boot configuration.
2. After flashing, mount the FAT32 **bootfs** partition on any Windows, macOS,
   or Linux machine. It contains `zebra-bridge.conf`.
3. Edit `zebra-bridge.conf` and give every Pi a unique BLE name and serial:

   ```ini
   [bridge]
   name = ZD421-Checkin-01
   serial = ZD421-CHECKIN-0001
   printer = /dev/usb/lp0
   ```

4. Save the file, eject the card safely, and boot the Pi.

The bootfs partition is mounted **read-only** while the Pi is running, so edit
`zebra-bridge.conf` by removing the SD card, not by editing it on a live
device. The parser accepts files saved with a UTF-8 BOM and Windows CRLF or
old-Mac CR line endings, which is why editing on a PC is safe.

Each Pi must use a different advertised name. Rock matches printers by
advertised name; two bridges with the same name conflict on the iPad.

## Wire the printer to the Pi Zero 2 W test pads

The printer is wired directly to the USB data test pads, bypassing the micro-USB
OTG connector's ID pin. `image-builder/config/config.txt` therefore forces the
USB controller into host mode with `dtoverlay=dwc2,dr_mode=host`.

| Pi Zero 2 W pad | USB signal | Printer end |
| --- | --- | --- |
| `PP1` | +5 V | VBUS (only if the printer is low-power) |
| `PP6` | GND | GND |
| `PP22` | USB D+ | D+ |
| `PP23` | USB D- | D- |

Keep the D+/D- leads short and twisted. The Pi Zero 2 W cannot safely power a
Zebra GX420d from its 5 V rail; power the printer from its own supply and
connect GND plus D+/D- only. Use a good 5 V/2.5 A supply for the Pi itself.
If the printer has its own 5 V supply, do **not** also connect `PP1` to the
printer's VBUS.

## Runtime behaviour of the image

- **Root filesystem:** OverlayFS backed by tmpfs (`overlayroot=tmpfs`). Every
  boot starts from the same clean lower filesystem; runtime writes stay in RAM.
- **bootfs:** mounted read-only in `/etc/fstab`.
- **Logs:** journald stores logs in RAM (`Storage=volatile`,
  `RuntimeMaxUse=16M`). Use `journalctl -u zebra-bridge -b`.
- **Service:** `zebra-bridge.service` starts after `bluetooth.service`,
  `hciuart.service`, and `systemd-udevd.service`, retries Bluetooth
  registration internally, and logs to the volatile journal.
- **Watchdog:** the BCM2835 watchdog is enabled. The hardware maximum is just
  under 16 seconds, so `RuntimeWatchdogSec=10s` and `RebootWatchdogSec=15s`.
- **Bluetooth state:** `/var/lib/bluetooth` is on tmpfs and is recreated each
  boot. This is harmless because the bridge does not bond. The adapter alias
  and powered state are re-applied over D-Bus at startup.
- **Wi-Fi and networking:** disabled/masked. SSH is masked.
- **Recovery:** there is no network console. A serial console over GPIO 14/15
  can be enabled by uncommenting `enable_uart=1` and
  `dtoverlay=miniuart-bt` in `config.txt`; this moves Bluetooth to the slower
  mini UART, so validate BLE throughput before shipping.

## Manual installation (without the image)

```bash
sudo apt update
sudo apt install -y bluez pi-bluetooth python3-dbus python3-gi

sudo install -d /opt/zebra-bridge
sudo install -m 0755 zebra_bridge.py run.sh supervise.sh /opt/zebra-bridge/
sudo install -m 0644 systemd/zebra-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now zebra-bridge.service
```

The service runs as root, so the `lp` group and udev rule are not strictly
required for it. They are still useful for manual `./run.sh` testing:

```bash
sudo usermod -aG lp "$USER"   # then log out/in
sudo cp 99-zebra-printer.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### BlueZ configuration

On a peripheral-only bridge, reverse service discovery can make iOS
disconnect. Set this in `/etc/bluetooth/main.conf`:

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

Restart Bluetooth after editing:

```bash
sudo systemctl restart bluetooth
```

The `[LE]` keys improve iOS stability; if the installed BlueZ ignores them,
the defaults are still usable. Do not add `JustWorksRepairing` or link-key
persistence for this bridge: Rock connects without bonding.

### Non-systemd fallback

`run.sh` can supervise the bridge without systemd:

```bash
./run.sh check
./run.sh start
./run.sh status
./run.sh logs
./run.sh stop
```

Its default log, PID, and lock files are now under `$XDG_RUNTIME_DIR` or
`/tmp`, never next to the script, so it remains compatible with a read-only
`/opt/zebra-bridge`.

## Configuration

The bridge uses the first config file found in this order:

1. `--config PATH` (Python script only)
2. `$ZEBRA_BRIDGE_CONFIG`
3. `/boot/firmware/zebra-bridge.conf` (Raspberry Pi OS Bookworm)
4. `/boot/zebra-bridge.conf` (older Raspberry Pi OS)
5. `/etc/zebra-bridge.conf`
6. `zebra-bridge.conf` next to `zebra_bridge.py` (local development)

The bootfs locations come first so the SD-card file wins on the appliance. Use
`--config` or `ZEBRA_BRIDGE_CONFIG` for development. `run.sh` resolves the same
file, so `./run.sh check`, `start`, and `run` all use the same name and printer.

The file is INI format:

```ini
[bridge]
name = ZD421-Checkin
serial = ZD421-CHECKIN-0001
printer = /dev/usb/lp0
adapter = hci0
log_level = INFO
```

| `[bridge]` key | Default | Meaning |
| --- | --- | --- |
| `name` | `ZD421-Emulation` | BLE advertised name |
| `serial` | `ZD421-EMULATION-0001` | Device Information Service serial |
| `printer` | `/dev/usb/lp0` | USB printer device |
| `adapter` | first suitable | Adapter hint such as `hci0` |
| `log_level` | `INFO` | `DEBUG` logs each BLE chunk |

Environment variables override the file:

| Variable | Meaning |
| --- | --- |
| `ZEBRA_BRIDGE_CONFIG` | Explicit config file path |
| `ZEBRA_BRIDGE_PRINTER` | Override the printer device |
| `ZEBRA_BRIDGE_NAME` | Override the BLE advertised name |
| `ZEBRA_BRIDGE_SERIAL` | Override the DIS serial number |
| `ZEBRA_BRIDGE_ADAPTER` | Override the adapter hint |
| `ZEBRA_BRIDGE_LOG_LEVEL` | Override the log level |
| `ZEBRA_BRIDGE_LOG` | Log file used by `run.sh` |
| `ZEBRA_BRIDGE_PIDFILE` | PID file used by `run.sh` |
| `ZEBRA_BRIDGE_LOCK` | Single-instance lock file |
| `ZEBRA_BRIDGE_RESTART_DELAY` | Seconds between supervisor restarts |

## What is hardened

- **BlueZ restarts:** the bridge watches BlueZ's D-Bus `NameOwnerChanged`
  signal and re-registers its GATT app and advertisement automatically.
- **Advertising loss:** a 10-second health check notices
  `ActiveInstances == 0` and re-registers.
- **Registration hangs:** a 10-second timeout retries if BlueZ does not answer.
- **Process crashes:** systemd `Restart=always` (or `run.sh`/`supervise.sh`).
- **Duplicate instances:** a `flock` lock file prevents two bridges from
  registering at the same time.
- **USB printer reconnects:** the printer is opened per write, and
  `/dev/usb/lpN` is discovered if the configured device is absent.
- **Clean shutdown:** SIGTERM/SIGINT withdraw the advertisement and stop the
  main loop.
- **Read-only runtime:** no logs, PID files, bytecode, or state are written to
  `/opt/zebra-bridge` or `/boot/firmware`.

## Testing

Send a known-good label directly to the printer:

```bash
printf '^XA^FO50,50^ADN,36,20^FDUSB Test OK^FS^XZ' > /dev/usb/lp0
```

Then test over BLE from Rock. In the Rock in-app settings, use **Print Test
Label**. If it prints, the bridge and printer are working.

The Rock test label includes a large compressed `^GFA` graphic. On some older
Zebra firmware this can be rejected even though ordinary text/barcode labels
print fine. If the Rock test label fails but a simple label works, test a real
check-in label before changing the bridge.

Run the config parser tests on any Linux host:

```bash
python3 -m unittest discover -s tests -v
```

## Troubleshooting

On the appliance:

```bash
systemctl status zebra-bridge
journalctl -u zebra-bridge -b --no-pager
journalctl -b --no-pager | tail -100
bluetoothctl show
rfkill list bluetooth
ls -l /dev/usb/lp0
findmnt /
findmnt /boot/firmware
```

| Symptom | Check |
| --- | --- |
| Printer name not visible in Rock | `systemctl status zebra-bridge`; `journalctl -u zebra-bridge -b`; `bluetoothctl show`; `rfkill list bluetooth` |
| iPad says "Unable to print to printer" | Bridge may not be advertising; restart the service and check the journal |
| Printer not printing | `ls -l /dev/usb/lp0`; send the direct test label above |
| Permission denied on `/dev/usb/lp0` | The systemd unit runs as root; for manual runs, check `groups` and install the udev rule |
| Works, then stops after a BlueZ restart | The bridge should self-heal; check the journal for re-registration |
| Config changes ignored | The bootfs file is read-only at runtime, and the local file is last in the search order; edit the SD card offline and reboot |
| Boots read-only but changes vanish | Expected: `/` is OverlayFS/tmpfs. Edit `zebra-bridge.conf` on bootfs instead |
| Pi reboots every ~15 seconds | Check `RuntimeWatchdogSec`; the BCM2835 watchdog max is just under 16s. Disable `dtparam=watchdog=on` only for debugging |

Useful BlueZ commands:

```bash
bluetoothctl show
bluetoothctl devices Connected
bluetoothctl info <address>
```

## Notes

- The emulated service UUID is `38eb4a80-c570-11e3-9507-0002a5d5c51b`; Rock
  writes ZPL to characteristic `38eb4a82-...`.
- Rock's iOS app finds the printer by its advertised **name**, not by address.
  No pairing/bonding is required.
- The bridge writes raw bytes to the configured printer device; it does not go
  through CUPS.
- Keep the iPad and Pi close, and prefer a 5 V/2.5 A supply on the Pi Zero 2 W.
- The appliance image is built from a pinned Raspberry Pi OS Lite 64-bit
  Bookworm release. `config.txt` assumes the Pi Zero 2 W and the test-pad USB
  wiring; do not reuse it on a Pi 4/5 without reviewing the USB and watchdog
  settings.

## License

The code and image-build tooling in this repository are MIT-licensed; see
[`LICENSE`](LICENSE).

A built image also contains Raspberry Pi OS components (Debian packages,
BlueZ, Raspberry Pi firmware, and Raspberry Pi OS scripts) that keep their own
licenses. Review those before redistributing a built image.
