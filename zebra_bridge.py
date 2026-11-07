#!/usr/bin/env python3
"""
Zebra ZD421 BLE-to-USB print bridge for Rock RMS.

Emulates a Zebra printer's BLE GATT service and forwards raw ZPL bytes to a
USB-connected Zebra printer (for example, a GX420d on /dev/usb/lp0).

Designed to be portable: Raspberry Pi Zero 2 W, Fedora, Debian, etc.  It
self-heals when bluetoothd restarts and can be kept alive by run.sh without
systemd.

Configuration file (first one found wins):
  /boot/firmware/zebra-bridge.conf   (Raspberry Pi OS Bookworm boot partition)
  /boot/zebra-bridge.conf            (older Raspberry Pi OS boot partition)
  /etc/zebra-bridge.conf
  ./zebra-bridge.conf

The boot partition locations come first so an operator can edit the file on
the FAT32 bootfs partition after flashing the SD card.  Use --config or
ZEBRA_BRIDGE_CONFIG for development overrides.

The [bridge] section supports:
  name, serial, printer, adapter, log_level

Files edited on Windows or macOS may contain a UTF-8 BOM and CRLF line
endings; both are handled deliberately below.

Environment variables override the configuration file:
  ZEBRA_BRIDGE_CONFIG   explicit config file path
  ZEBRA_BRIDGE_PRINTER  printer device (default: /dev/usb/lp0)
  ZEBRA_BRIDGE_NAME     advertised BLE name (default: ZD421-Emulation)
  ZEBRA_BRIDGE_SERIAL   DIS serial number (default: ZD421-EMULATION-0001)
  ZEBRA_BRIDGE_ADAPTER  adapter hint, e.g. hci0 (default: first suitable)
  ZEBRA_BRIDGE_LOCK     lock file path (default: /tmp/zebra-bridge.lock)
"""

import argparse
import configparser
import fcntl
import glob
import logging
import os
import signal
import sys
import tempfile
import time

try:
    import dbus
    import dbus.service
    import dbus.exceptions
    import dbus.mainloop.glib
    from gi.repository import GLib
    try:
        from gi.repository import GLibUnix
    except ImportError:  # older PyGObject
        GLibUnix = None
except ImportError as exc:  # pragma: no cover - deployment guard
    sys.stderr.write(
        "Missing Python dependency: %s\n"
        "On Raspberry Pi OS install with:\n"
        "  sudo apt install python3-dbus python3-gi bluez\n" % exc
    )
    raise SystemExit(1)

LOG = logging.getLogger("zebra-bridge")

PRINTER_PATH = os.environ.get("ZEBRA_BRIDGE_PRINTER", "/dev/usb/lp0")
DEVICE_NAME = os.environ.get("ZEBRA_BRIDGE_NAME", "ZD421-Emulation")
SERIAL_NUMBER = os.environ.get("ZEBRA_BRIDGE_SERIAL", "ZD421-EMULATION-0001")
ADAPTER_HINT = os.environ.get("ZEBRA_BRIDGE_ADAPTER", "").strip()
LOCK_PATH = os.environ.get(
    "ZEBRA_BRIDGE_LOCK",
    os.path.join(tempfile.gettempdir(), "zebra-bridge.lock"),
)

HEALTH_INTERVAL_SECONDS = 10
REGISTRATION_TIMEOUT_SECONDS = 10
REGISTER_RETRY_SECONDS = 2

# BlueZ Constants
BLUEZ_SERVICE_NAME = "org.bluez"
GATT_MANAGER_IFACE = "org.bluez.GattManager1"
DBUS_OM_IFACE = "org.freedesktop.DBus.ObjectManager"
DBUS_PROP_IFACE = "org.freedesktop.DBus.Properties"
GATT_SERVICE_IFACE = "org.bluez.GattService1"
GATT_CHRC_IFACE = "org.bluez.GattCharacteristic1"
LE_ADV_MANAGER_IFACE = "org.bluez.LEAdvertisingManager1"
LE_ADVERTISEMENT_IFACE = "org.bluez.LEAdvertisement1"

# Zebra Custom BLE Service & Characteristics
ZEBRA_SVC_UUID = "38eb4a80-c570-11e3-9507-0002a5d5c51b"
ZEBRA_WRITE_UUID = "38eb4a82-c570-11e3-9507-0002a5d5c51b"
ZEBRA_READ_UUID = "38eb4a81-c570-11e3-9507-0002a5d5c51b"

CONFIG_SECTION = "bridge"
CONFIG_FILE = None
CONFIG_KEYS = ("name", "serial", "printer", "adapter", "log_level")


def default_config_candidates():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    return [
        "/boot/firmware/zebra-bridge.conf",
        "/boot/zebra-bridge.conf",
        "/etc/zebra-bridge.conf",
        os.path.join(script_dir, "zebra-bridge.conf"),
    ]


def find_config_path(explicit=None):
    """Return the first usable config file, honoring explicit paths first."""
    env_path = os.environ.get("ZEBRA_BRIDGE_CONFIG")
    for source, path in (("--config", explicit), ("ZEBRA_BRIDGE_CONFIG", env_path)):
        if not path:
            continue
        path = os.path.expanduser(path)
        if not os.path.isfile(path):
            raise FileNotFoundError(f"{source} file not found: {path}")
        return path

    for path in default_config_candidates():
        if os.path.isfile(path):
            return path
    return None


def load_config(explicit=None):
    """Load the [bridge] section. Returns (values, path)."""
    path = find_config_path(explicit)
    if path is None:
        return {}, None

    parser = configparser.ConfigParser(
        interpolation=None,
        inline_comment_prefixes=("#", ";"),
        strict=False,
    )
    try:
        # utf-8-sig strips a Windows/metadata BOM; reading the whole file lets
        # us normalise CRLF (and old-Mac CR) before configparser sees it.
        with open(path, "r", encoding="utf-8-sig", newline="") as handle:
            text = handle.read()
        text = text.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
        parser.read_string(text, source=path)
    except UnicodeDecodeError as exc:
        raise RuntimeError(
            f"Configuration {path} is not valid UTF-8: {exc}"
        ) from exc
    except configparser.MissingSectionHeaderError as exc:
        raise RuntimeError(
            f"Configuration {path} is missing the [{CONFIG_SECTION}] section: {exc}"
        ) from exc
    except (configparser.Error, OSError) as exc:
        raise RuntimeError(f"Could not read configuration {path}: {exc}") from exc
    if not parser.has_section(CONFIG_SECTION):
        raise RuntimeError(
            f"Configuration {path} is missing the [{CONFIG_SECTION}] section"
        )

    values = {}
    for key in CONFIG_KEYS:
        raw = parser.get(CONFIG_SECTION, key, fallback=None)
        if raw is None:
            continue
        value = raw.replace("\r", "").strip()
        if value:
            values[key] = value
    return values, path


def apply_config(values, path):
    """Apply config values, letting explicit environment variables win."""
    global PRINTER_PATH, DEVICE_NAME, SERIAL_NUMBER, ADAPTER_HINT, CONFIG_FILE

    CONFIG_FILE = path
    if "printer" in values and "ZEBRA_BRIDGE_PRINTER" not in os.environ:
        PRINTER_PATH = values["printer"]
    if "name" in values and "ZEBRA_BRIDGE_NAME" not in os.environ:
        DEVICE_NAME = values["name"]
    if "serial" in values and "ZEBRA_BRIDGE_SERIAL" not in os.environ:
        SERIAL_NUMBER = values["serial"]
    if "adapter" in values and "ZEBRA_BRIDGE_ADAPTER" not in os.environ:
        ADAPTER_HINT = values["adapter"].strip()


def resolve_log_level(values, debug=False):
    if debug:
        return "DEBUG"
    level = os.environ.get(
        "ZEBRA_BRIDGE_LOG_LEVEL", values.get("log_level", "INFO")
    ).upper()
    if level not in ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"):
        return "INFO"
    return level


def print_resolved_config(values, debug=False):
    print(f"config={CONFIG_FILE or ''}")
    print(f"name={DEVICE_NAME}")
    print(f"serial={SERIAL_NUMBER}")
    print(f"printer={PRINTER_PATH}")
    print(f"adapter={ADAPTER_HINT}")
    print(f"log_level={resolve_log_level(values, debug)}")


def printer_candidates():
    return sorted(glob.glob("/dev/usb/lp[0-9]*"))


def resolve_printer_path():
    """Return the configured printer, or the first available usblp device."""
    if os.path.exists(PRINTER_PATH):
        return PRINTER_PATH
    candidates = printer_candidates()
    if candidates:
        LOG.warning(
            "Configured printer %s is missing; using %s instead",
            PRINTER_PATH,
            candidates[0],
        )
        return candidates[0]
    return PRINTER_PATH


def write_to_printer(data):
    """Write raw ZPL to the printer, retrying once after a transient error."""
    path = resolve_printer_path()
    last_error = None
    for attempt in range(2):
        try:
            with open(path, "ab", buffering=0) as printer:
                printer.write(data)
            return True
        except OSError as exc:
            last_error = exc
            LOG.error(
                "Printer write failed (%s, attempt %d/2): %s",
                path,
                attempt + 1,
                exc,
            )
            if attempt == 0:
                time.sleep(0.2)
    LOG.error("Dropping %d bytes; printer %s unavailable: %s", len(data), path, last_error)
    return False


class Application(dbus.service.Object):
    def __init__(self, bus):
        self.path = "/"
        self.services = []
        super().__init__(bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_service(self, service):
        self.services.append(service)

    @dbus.service.method(DBUS_OM_IFACE, out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        response = {}
        for service in self.services:
            response[service.get_path()] = service.get_properties()
            for chrc in service.get_characteristics():
                response[chrc.get_path()] = chrc.get_properties()
        return response


class ZebraService(dbus.service.Object):
    def __init__(self, bus, index):
        self.path = dbus.ObjectPath(f"/org/bluez/service{index}")
        self.bus = bus
        self.uuid = ZEBRA_SVC_UUID
        self.primary = True
        self.characteristics = []
        super().__init__(bus, self.path)
        self.characteristics.append(ZebraWriteCharacteristic(bus, 0, self))
        self.characteristics.append(ZebraReadCharacteristic(bus, 1, self))

    def get_properties(self):
        return {
            GATT_SERVICE_IFACE: {
                "UUID": self.uuid,
                "Primary": self.primary,
                "Characteristics": dbus.Array(
                    [c.get_path() for c in self.characteristics], signature="o"
                ),
            }
        }

    def get_path(self):
        return self.path

    def get_characteristics(self):
        return self.characteristics


class ZebraWriteCharacteristic(dbus.service.Object):
    def __init__(self, bus, index, service):
        self.path = dbus.ObjectPath(f"{service.get_path()}/char{index}")
        self.bus = bus
        self.uuid = ZEBRA_WRITE_UUID
        self.service = service
        self.flags = ["write", "write-without-response"]
        super().__init__(bus, self.path)

    def get_properties(self):
        return {
            GATT_CHRC_IFACE: {
                "Service": self.service.get_path(),
                "UUID": self.uuid,
                "Flags": self.flags,
            }
        }

    def get_path(self):
        return self.path

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="aya{sv}")
    def WriteValue(self, value, options):
        data = bytes(value)
        LOG.debug("BLE write: %d bytes", len(data))
        write_to_printer(data)


class ZebraReadCharacteristic(dbus.service.Object):
    def __init__(self, bus, index, service):
        self.path = dbus.ObjectPath(f"{service.get_path()}/char{index}")
        self.bus = bus
        self.uuid = ZEBRA_READ_UUID
        self.service = service
        self.flags = ["notify", "read"]
        super().__init__(bus, self.path)

    def get_properties(self):
        return {
            GATT_CHRC_IFACE: {
                "Service": self.service.get_path(),
                "UUID": self.uuid,
                "Flags": self.flags,
            }
        }

    def get_path(self):
        return self.path

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, options):
        LOG.debug("ReadValue called on Zebra read characteristic")
        return dbus.ByteArray(b"\x020\x03")

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="", out_signature="")
    def StartNotify(self):
        LOG.info("StartNotify called")

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="", out_signature="")
    def StopNotify(self):
        LOG.info("StopNotify called")


class ReadOnlyCharacteristic(dbus.service.Object):
    def __init__(self, bus, index, service, uuid, value):
        self.path = dbus.ObjectPath(f"{service.get_path()}/char{index}")
        self.bus = bus
        self.uuid = uuid
        self.service = service
        self.value = value.encode("utf-8")
        self.flags = ["read"]
        super().__init__(bus, self.path)

    def get_properties(self):
        return {
            GATT_CHRC_IFACE: {
                "Service": self.service.get_path(),
                "UUID": self.uuid,
                "Flags": self.flags,
            }
        }

    def get_path(self):
        return self.path

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, options):
        LOG.debug("ReadValue %s: %r", self.uuid, self.value)
        return dbus.ByteArray(self.value)


class DeviceInfoService(dbus.service.Object):
    def __init__(self, bus, index):
        self.path = dbus.ObjectPath(f"/org/bluez/dis{index}")
        self.bus = bus
        self.uuid = "0000180a-0000-1000-8000-00805f9b34fb"
        self.primary = True
        self.characteristics = []
        super().__init__(bus, self.path)

        attributes = [
            ("00002a29-0000-1000-8000-00805f9b34fb", "Zebra Technologies"),
            ("00002a24-0000-1000-8000-00805f9b34fb", "ZD421"),
            ("00002a25-0000-1000-8000-00805f9b34fb", SERIAL_NUMBER),
            ("00002a26-0000-1000-8000-00805f9b34fb", "V1.0.0"),
            ("00002a27-0000-1000-8000-00805f9b34fb", "1.0"),
            ("00002a28-0000-1000-8000-00805f9b34fb", "1.0"),
        ]
        for i, (uuid, value) in enumerate(attributes):
            self.characteristics.append(
                ReadOnlyCharacteristic(bus, i, self, uuid, value)
            )

    def get_properties(self):
        return {
            GATT_SERVICE_IFACE: {
                "UUID": self.uuid,
                "Primary": self.primary,
                "Characteristics": dbus.Array(
                    [c.get_path() for c in self.characteristics], signature="o"
                ),
            }
        }

    def get_path(self):
        return self.path

    def get_characteristics(self):
        return self.characteristics


class Advertisement(dbus.service.Object):
    def __init__(self, bus, index):
        self.path = dbus.ObjectPath(f"/org/bluez/adv{index}")
        self.bus = bus
        super().__init__(bus, self.path)

    def get_properties(self):
        return {
            LE_ADVERTISEMENT_IFACE: {
                "Type": "peripheral",
                "LocalName": DEVICE_NAME,
                "ServiceUUIDs": [ZEBRA_SVC_UUID],
                "Discoverable": True,
                "Includes": ["tx-power"],
            }
        }

    def get_path(self):
        return self.path

    @dbus.service.method(DBUS_PROP_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != LE_ADVERTISEMENT_IFACE:
            raise dbus.exceptions.DBusException("Invalid interface")
        return self.get_properties()[LE_ADVERTISEMENT_IFACE]

    @dbus.service.method(LE_ADVERTISEMENT_IFACE, in_signature="", out_signature="")
    def Release(self):
        LOG.info("Advertisement released by BlueZ")


class Bridge:
    """Owns the GATT application and advertisement, and re-registers on reset."""

    def __init__(self, bus, loop):
        self.bus = bus
        self.loop = loop
        self.adapter_path = None
        self.adapter_props = None
        self.gatt_manager = None
        self.adv_manager = None
        self.app = None
        self.adv = None
        self.registering = False
        self.registered = False
        self.stopping = False
        self.retry_source_id = None
        self.registration_timeout_id = None
        self.registration_generation = 0

    # ------------------------------------------------------------------
    # Adapter setup
    # ------------------------------------------------------------------
    def _find_adapter_path(self):
        manager = dbus.Interface(
            self.bus.get_object(BLUEZ_SERVICE_NAME, "/"), DBUS_OM_IFACE
        )
        objects = manager.GetManagedObjects()
        candidates = []
        for path, interfaces in objects.items():
            if GATT_MANAGER_IFACE in interfaces and LE_ADV_MANAGER_IFACE in interfaces:
                candidates.append(path)
        if ADAPTER_HINT:
            candidates = [
                path for path in candidates if path.endswith("/" + ADAPTER_HINT)
            ]
        if not candidates:
            hint = f" (adapter hint: {ADAPTER_HINT})" if ADAPTER_HINT else ""
            raise RuntimeError(
                "No Bluetooth adapter with GATT and LE advertising support" + hint
            )
        return sorted(candidates)[0]

    def _setup_adapter(self):
        path = self._find_adapter_path()
        if (
            path != self.adapter_path
            or self.adapter_props is None
            or self.gatt_manager is None
            or self.adv_manager is None
        ):
            LOG.info("Using Bluetooth adapter %s", path)
            self.adapter_path = path
            self.adapter_props = dbus.Interface(
                self.bus.get_object(BLUEZ_SERVICE_NAME, path), DBUS_PROP_IFACE
            )
            self.gatt_manager = dbus.Interface(
                self.bus.get_object(BLUEZ_SERVICE_NAME, path), GATT_MANAGER_IFACE
            )
            self.adv_manager = dbus.Interface(
                self.bus.get_object(BLUEZ_SERVICE_NAME, path), LE_ADV_MANAGER_IFACE
            )

        try:
            self.adapter_props.Set(
                "org.bluez.Adapter1", "Powered", dbus.Boolean(True)
            )
        except dbus.exceptions.DBusException as exc:
            raise RuntimeError(
                "Could not power on the Bluetooth adapter: %s "
                "(check 'rfkill list bluetooth')" % exc
            )

        self.adapter_props.Set(
            "org.bluez.Adapter1", "Alias", dbus.String(DEVICE_NAME)
        )

        if self.app is None:
            self.app = Application(self.bus)
            self.app.add_service(ZebraService(self.bus, 0))
            self.app.add_service(DeviceInfoService(self.bus, 1))
        if self.adv is None:
            self.adv = Advertisement(self.bus, 0)

    # ------------------------------------------------------------------
    # Registration state machine
    # ------------------------------------------------------------------
    def register_all(self):
        if self.stopping or self.registering:
            return False

        self.registering = True
        self.registered = False
        self._start_registration_timeout()

        try:
            self._setup_adapter()
        except Exception as exc:
            LOG.warning("Bluetooth not ready: %s", exc)
            self.registering = False
            self._cancel_registration_timeout()
            self.schedule_retry()
            return False

        self.registration_generation += 1
        generation = self.registration_generation
        LOG.info("Registering GATT application...")
        try:
            self.gatt_manager.RegisterApplication(
                self.app.get_path(),
                {},
                reply_handler=lambda: self._on_app_registered(generation),
                error_handler=lambda error: self._on_app_error(generation, error),
            )
        except dbus.exceptions.DBusException as exc:
            LOG.error("GATT registration call failed: %s", exc)
            self.registering = False
            self._cancel_registration_timeout()
            self.schedule_retry()
        return False

    def _is_current(self, generation):
        return not self.stopping and generation == self.registration_generation

    def _on_app_registered(self, generation):
        if not self._is_current(generation):
            LOG.debug("Ignoring stale GATT registration reply")
            return
        LOG.info("GATT application registered.")
        self._register_advertisement(generation)

    def _on_app_error(self, generation, error):
        if not self._is_current(generation):
            LOG.debug("Ignoring stale GATT registration error")
            return
        text = str(error).lower()
        if "already" in text:
            LOG.info("GATT application already registered; continuing.")
            self._register_advertisement(generation)
            return
        LOG.error("GATT registration failed: %s", error)
        self.registering = False
        self._cancel_registration_timeout()
        self.schedule_retry()

    def _register_advertisement(self, generation):
        if not self._is_current(generation):
            return
        LOG.info("Registering BLE advertisement...")
        try:
            self.adv_manager.RegisterAdvertisement(
                self.adv.get_path(),
                {},
                reply_handler=lambda: self._on_adv_registered(generation),
                error_handler=lambda error: self._on_adv_error(generation, error),
            )
        except dbus.exceptions.DBusException as exc:
            LOG.error("Advertisement registration call failed: %s", exc)
            self.registering = False
            self._cancel_registration_timeout()
            self.schedule_retry()

    def _on_adv_registered(self, generation):
        if not self._is_current(generation):
            LOG.debug("Ignoring stale advertisement reply")
            return
        LOG.info("Advertising active as '%s'.", DEVICE_NAME)
        self.registering = False
        self.registered = True
        self._cancel_registration_timeout()

    def _on_adv_error(self, generation, error):
        if not self._is_current(generation):
            LOG.debug("Ignoring stale advertisement error")
            return
        text = str(error).lower()
        if "already" in text:
            LOG.info("Advertisement already registered.")
            self.registering = False
            self.registered = True
            self._cancel_registration_timeout()
            return
        LOG.error("Advertisement registration failed: %s", error)
        self.registering = False
        self._cancel_registration_timeout()
        self.schedule_retry()

    def schedule_retry(self, delay=REGISTER_RETRY_SECONDS):
        if self.stopping or self.retry_source_id is not None:
            return
        LOG.info("Retrying Bluetooth registration in %ss.", delay)
        self.retry_source_id = GLib.timeout_add_seconds(delay, self._retry)

    def _retry(self):
        self.retry_source_id = None
        self.register_all()
        return False

    def _start_registration_timeout(self):
        self._cancel_registration_timeout()
        self.registration_timeout_id = GLib.timeout_add_seconds(
            REGISTRATION_TIMEOUT_SECONDS, self._registration_timeout
        )

    def _cancel_registration_timeout(self):
        if self.registration_timeout_id is not None:
            GLib.source_remove(self.registration_timeout_id)
            self.registration_timeout_id = None

    def _registration_timeout(self):
        self.registration_timeout_id = None
        if self.registering:
            LOG.warning("Bluetooth registration timed out; retrying.")
            self.registration_generation += 1
            self.registering = False
            self.schedule_retry()
        return False

    # ------------------------------------------------------------------
    # Health checks
    # ------------------------------------------------------------------
    def health_check(self):
        if self.stopping:
            return False
        if self.registering or self.retry_source_id is not None:
            return True
        try:
            if self.adapter_props is None:
                self.register_all()
                return True
            active = int(
                self.adapter_props.Get(
                    LE_ADV_MANAGER_IFACE, "ActiveInstances"
                )
            )
            if active == 0:
                LOG.warning("BLE advertising is inactive; re-registering.")
                self.registered = False
                self.register_all()
        except dbus.exceptions.DBusException as exc:
            LOG.warning(
                "Bluetooth health check failed (%s); re-registering.", exc
            )
            self.adapter_path = None
            self.adapter_props = None
            self.gatt_manager = None
            self.adv_manager = None
            self.registered = False
            self.register_all()
        return True

    def on_name_owner_changed(self, name, old_owner, new_owner):
        if name != BLUEZ_SERVICE_NAME:
            return
        LOG.warning(
            "BlueZ D-Bus owner changed (%s -> %s); re-registering.",
            old_owner,
            new_owner,
        )
        self.registered = False
        self.registering = False
        self.registration_generation += 1
        self.adapter_path = None
        self.adapter_props = None
        self.gatt_manager = None
        self.adv_manager = None
        self._cancel_registration_timeout()
        if self.retry_source_id is not None:
            GLib.source_remove(self.retry_source_id)
            self.retry_source_id = None
        if new_owner:
            self.schedule_retry(1)

    # ------------------------------------------------------------------
    # Shutdown
    # ------------------------------------------------------------------
    def shutdown(self, *_args):
        if self.stopping:
            return False
        self.stopping = True
        LOG.info("Shutting down...")
        try:
            if self.adv_manager is not None and self.adv is not None:
                self.adv_manager.UnregisterAdvertisement(
                    self.adv.get_path(),
                    reply_handler=lambda: None,
                    error_handler=lambda _error: None,
                )
        except Exception:
            pass
        GLib.timeout_add(200, self._quit)
        return False

    def _quit(self):
        self.loop.quit()
        return False


def check_bluetooth_config():
    """Warn when BlueZ is configured for reverse discovery (bad for iOS)."""
    path = "/etc/bluetooth/main.conf"
    try:
        parser = configparser.ConfigParser()
        with open(path, "r", encoding="utf-8-sig", newline="") as handle:
            parser.read_string(
                handle.read().replace("\r\n", "\n").replace("\r", "\n"),
                source=path,
            )
        value = parser.get("General", "ReverseServiceDiscovery", fallback="")
    except Exception as exc:
        LOG.debug("Could not read %s: %s", path, exc)
        return
    value = value.split("#", 1)[0].strip().lower()
    if value not in ("false", "no", "0"):
        LOG.warning(
            "BlueZ ReverseServiceDiscovery is not disabled. On a peripheral-only "
            "bridge this can cause iOS disconnects. Set 'ReverseServiceDiscovery "
            "= false' in [General] of /etc/bluetooth/main.conf and restart "
            "Bluetooth."
        )


def check_environment():
    """Validate dependencies, adapter, printer, and BlueZ configuration."""
    ok = True
    print("Python dependencies: OK")
    print(f"Configuration file: {CONFIG_FILE or 'none (defaults)'}")

    try:
        bus = dbus.SystemBus()
        manager = dbus.Interface(
            bus.get_object(BLUEZ_SERVICE_NAME, "/"), DBUS_OM_IFACE
        )
        objects = manager.GetManagedObjects()
    except Exception as exc:
        print(f"BlueZ D-Bus: FAIL ({exc})")
        return False

    adapters = [
        path
        for path, interfaces in objects.items()
        if GATT_MANAGER_IFACE in interfaces and LE_ADV_MANAGER_IFACE in interfaces
    ]
    if ADAPTER_HINT:
        adapters = [
            path for path in adapters if path.endswith("/" + ADAPTER_HINT)
        ]
    if not adapters:
        print("Bluetooth adapter: FAIL (no GATT/LE advertising adapter)")
        ok = False
    else:
        adapter = sorted(adapters)[0]
        print(f"Bluetooth adapter: {adapter}")
        try:
            props = dbus.Interface(
                bus.get_object(BLUEZ_SERVICE_NAME, adapter), DBUS_PROP_IFACE
            )
            print(f"  Powered: {bool(props.Get('org.bluez.Adapter1', 'Powered'))}")
        except Exception as exc:
            print(f"  Adapter properties: FAIL ({exc})")
            ok = False

    printer = resolve_printer_path()
    if not os.path.exists(printer):
        print(f"Printer device: FAIL ({printer} not found)")
        ok = False
    elif not os.access(printer, os.W_OK):
        print(
            f"Printer device: FAIL ({printer} not writable; "
            "add the user to the 'lp' group or install the udev rule)"
        )
        ok = False
    else:
        print(f"Printer device: {printer} (writable)")

    print(f"BLE advertised name: {DEVICE_NAME}")
    print(f"DIS serial number: {SERIAL_NUMBER}")
    return ok


def acquire_lock():
    lock_dir = os.path.dirname(LOCK_PATH) or "."
    try:
        os.makedirs(lock_dir, exist_ok=True)
    except OSError as exc:
        sys.exit(f"Could not create lock directory {lock_dir}: {exc}")
    lock_file = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(
            f"Another zebra-bridge instance is already running (lock: {LOCK_PATH})"
        )
    lock_file.write(str(os.getpid()))
    lock_file.flush()
    return lock_file


def main():
    parser = argparse.ArgumentParser(
        description="Zebra BLE-to-USB print bridge for Rock RMS"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate the environment and exit",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="enable debug logging",
    )
    parser.add_argument(
        "--config",
        metavar="PATH",
        help="configuration file to use",
    )
    parser.add_argument(
        "--print-config",
        action="store_true",
        help="print the resolved configuration and exit",
    )
    args = parser.parse_args()

    try:
        config_values, config_path = load_config(args.config)
    except (RuntimeError, FileNotFoundError) as exc:
        sys.stderr.write(f"Configuration error: {exc}\n")
        raise SystemExit(1)

    apply_config(config_values, config_path)

    if args.print_config:
        logging.basicConfig(level=logging.WARNING, stream=sys.stderr)
        print_resolved_config(config_values, args.debug)
        return

    level_name = resolve_log_level(config_values, args.debug)
    logging.basicConfig(
        level=getattr(logging, level_name, logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )

    if not args.check:
        LOG.info(
            "Configuration file: %s",
            CONFIG_FILE or "none (defaults and environment)",
        )
    check_bluetooth_config()
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)

    if args.check:
        raise SystemExit(0 if check_environment() else 1)

    lock_file = acquire_lock()
    loop = GLib.MainLoop()
    bus = dbus.SystemBus()
    bridge = Bridge(bus, loop)

    bus.add_signal_receiver(
        bridge.on_name_owner_changed,
        signal_name="NameOwnerChanged",
        dbus_interface="org.freedesktop.DBus",
        bus_name="org.freedesktop.DBus",
    )
    if GLibUnix is not None:
        signal_add = GLibUnix.signal_add
    else:
        signal_add = GLib.unix_signal_add
    signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, bridge.shutdown)
    signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, bridge.shutdown)
    GLib.timeout_add_seconds(HEALTH_INTERVAL_SECONDS, bridge.health_check)

    LOG.info(
        "Starting Zebra BLE bridge: name=%r printer=%s lock=%s",
        DEVICE_NAME,
        resolve_printer_path(),
        LOCK_PATH,
    )
    if not os.path.exists(PRINTER_PATH):
        LOG.warning(
            "Printer device %s is not present yet; the bridge will keep running "
            "and write when it appears.",
            PRINTER_PATH,
        )
    bridge.register_all()

    try:
        loop.run()
    finally:
        lock_file.close()
        LOG.info("Zebra BLE bridge stopped.")


if __name__ == "__main__":
    main()
