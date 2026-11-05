# Zebra BLE-to-USB Bridge for Rock RMS

Emulates a Zebra **ZD421** Bluetooth LE printer and forwards the ZPL bytes
that Rock Check-in sends over BLE to a USB-attached Zebra printer. The current
reference hardware is a **GX420d** on `/dev/usb/lp0`.

This bundle is designed for a **Raspberry Pi Zero 2 W** (Raspberry Pi OS
Bookworm/Bullseye) but also runs on Fedora, Debian, Ubuntu, etc. It does **not**
require systemd. `run.sh` provides its own small supervisor loop.

## Files

| File | Purpose |
| --- | --- |
| `zebra_bridge.py` | The BLE GATT server and USB printer forwarder |
| `run.sh` | Start/stop/status/logs wrapper with automatic restart |
| `supervise.sh` | Restart loop used by `run.sh start` |
| `zebra-bridge.conf.example` | Example per-Pi configuration file |
| `99-zebra-printer.rules` | Optional udev rule for Zebra USB printer permissions |
| `README.md` | This file |

## Raspberry Pi Zero 2 W setup

### 1. Install OS and dependencies

Use Raspberry Pi OS Lite (64-bit is fine). Then:

```bash
sudo apt update
sudo apt install -y bluez python3-dbus python3-gi
```

The bridge needs BlueZ's `GattManager1` and `LEAdvertisingManager1` APIs.
Raspberry Pi OS's packaged BlueZ supports both.

### 2. Allow your user to write to the printer

```bash
sudo usermod -aG lp "$USER"
```

Then **log out and back in**, or reboot. Verify:

```bash
ls -l /dev/usb/lp0
```

You want something like `crw-rw---- root lp`. The optional udev rule can also
be installed:

```bash
sudo cp 99-zebra-printer.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

If the current login session has not picked up the `lp` group yet, `run.sh`
detects that you are in the group database and uses `sg lp` automatically.
Logging out and back in (or rebooting) is still the cleaner long-term fix.

### 3. Configure BlueZ for peripheral-only use

On a peripheral-only bridge, BlueZ's reverse service discovery can make iOS
disconnect. Edit `/etc/bluetooth/main.conf` and set:

```ini
[General]
ReverseServiceDiscovery = false
```

Then restart Bluetooth:

```bash
sudo systemctl restart bluetooth
```

Optional, for better iOS connection stability, add these to the `[LE]` section
of the same file:

```ini
[LE]
MinConnectionInterval = 12
MaxConnectionInterval = 24
ConnectionLatency = 0
ConnectionSupervisionTimeout = 500
```

Restart Bluetooth again after changing them. If your BlueZ version ignores
these keys, the bridge still works; the values just fall back to defaults.

### 4. Copy the bundle to the Pi

Copy this entire directory, for example to `/home/pi/zebra-bridge`. Make the
scripts executable:

```bash
chmod +x zebra_bridge.py run.sh supervise.sh
```

### 5. Set this printer's BLE name

Each Pi must advertise a unique name. Create `zebra-bridge.conf` next to the
scripts, or put it on the boot partition so you can edit it by mounting the SD
card:

```ini
[bridge]
name = ZD421-Checkin
serial = ZD421-CHECKIN-0001
```

Save it as one of:

- `/home/pi/zebra-bridge/zebra-bridge.conf`
- `/boot/firmware/zebra-bridge.conf` (Raspberry Pi OS Bookworm)
- `/boot/zebra-bridge.conf` (older Raspberry Pi OS)
- `/etc/zebra-bridge.conf`

The first file found in the search order wins. Restart after changing it:

```bash
./run.sh restart
```

### 6. Validate before starting

```bash
./run.sh check
```

This checks Python dependencies, the Bluetooth adapter, the configured printer,
the resolved BLE name, and BlueZ's `ReverseServiceDiscovery` setting. Fix
anything it reports before continuing.

### 7. Start it

```bash
./run.sh start
./run.sh status
./run.sh logs
```

The bridge advertises the name from `zebra-bridge.conf`. If no config file is
present, the default is **`ZD421-Emulation`**. In Rock Check-in, set the printer
override to the same name. The Device Information Service also exposes the
configured serial number (`ZD421-EMULATION-0001` by default).

Stop or restart it with:

```bash
./run.sh stop
./run.sh restart
```

### 8. Start at boot without systemd

Pick one of these.

**cron (simplest):**

```bash
crontab -e
```

Add this to the **same user's** crontab that owns the files and is in the `lp`
group (usually `pi`; do not use root's crontab):

```cron
@reboot sleep 20 && /home/pi/zebra-bridge/run.sh start >> /home/pi/zebra-bridge/boot.log 2>&1
```

The sleep gives Bluetooth time to come up. `run.sh` starts `supervise.sh`,
which restarts the Python bridge if it exits, and the bridge itself retries
BlueZ registration until `bluetoothd` and the adapter are ready. A longer delay
is harmless.

`boot.log` captures startup errors from `run.sh`. The bridge's normal output
still goes to `zebra-bridge.log`.

**/etc/rc.local (if enabled on your image):**

```bash
su - pi -c '/home/pi/zebra-bridge/run.sh start'
```

Do not add this to both cron and rc.local; the lock file prevents two
instances, but one startup method is enough.

## Configuration

The bridge uses the first config file found in this order:

1. `--config PATH` (Python script only)
2. `$ZEBRA_BRIDGE_CONFIG`
3. `zebra-bridge.conf` next to `zebra_bridge.py`
4. `/boot/firmware/zebra-bridge.conf` (Raspberry Pi OS Bookworm)
5. `/boot/zebra-bridge.conf` (older Raspberry Pi OS)
6. `/etc/zebra-bridge.conf`

`run.sh` resolves the same file, so `./run.sh check`, `start`, and `run` all use
the same name and printer. The file is INI format:

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

Environment variables override the file. This is useful for temporary tests:

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

Example with a different printer device:

```bash
ZEBRA_BRIDGE_PRINTER=/dev/usb/lp1 ./run.sh restart
```

Use a **different `name` on every Pi**. Rock matches printers by advertised name;
two bridges with the same name will conflict on the iPad.

## What is hardened

- **BlueZ restarts:** the bridge watches BlueZ's D-Bus `NameOwnerChanged`
  signal and re-registers its GATT app and advertisement automatically.
- **Advertising loss:** a 10-second health check notices
  `ActiveInstances == 0` and re-registers.
- **Registration hangs:** a 10-second timeout retries if BlueZ does not answer.
- **Process crashes:** `run.sh start` runs `supervise.sh`, which restarts the
  Python process after a crash.
- **Duplicate instances:** a `flock` lock file prevents two bridges from
  registering at the same time.
- **USB printer reconnects:** the printer is opened per write, and `/dev/usb/lpN`
  is discovered if the configured device is absent.
- **Clean shutdown:** SIGTERM/SIGINT withdraw the advertisement and stop the
  main loop.
- **Log rotation:** `run.sh start` rotates the log once it exceeds 1 MiB.

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

## Troubleshooting

```bash
./run.sh status
./run.sh logs
./run.sh check
```

| Symptom | Check |
| --- | --- |
| Printer name not visible in Rock | `./run.sh check` (shows the resolved name/config); `./run.sh status`; `bluetoothctl show`; `rfkill list bluetooth` |
| iPad says "Unable to print to printer" | Bridge may not be advertising; `./run.sh status`, then `./run.sh restart` |
| Printer not printing | `ls -l /dev/usb/lp0`; `./run.sh check`; send the direct test label above |
| Permission denied on `/dev/usb/lp0` | `groups`; log out/in after `usermod -aG lp`; install the udev rule |
| Works, then stops after a BlueZ restart | The bridge should self-heal; check `./run.sh logs` for re-registration |
| Two copies running | Remove stale PID/lock files under `/tmp`, then `./run.sh restart` |

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
