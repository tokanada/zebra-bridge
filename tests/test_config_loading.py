"""Configuration-loading tests that do not need a Bluetooth adapter.

zebra_bridge.py imports dbus/gi at module import time, so this test installs
minimal stubs before importing it.  The tests only exercise the pure config
parser, not the GATT server.
"""

import os
import sys
import tempfile
import types
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))


def _install_import_stubs():
    dbus = types.ModuleType("dbus")
    service = types.ModuleType("dbus.service")
    exceptions = types.ModuleType("dbus.exceptions")
    mainloop = types.ModuleType("dbus.mainloop")
    glib = types.ModuleType("dbus.mainloop.glib")

    class _Object:
        def __init__(self, *args, **kwargs):
            pass

    def _method(*args, **kwargs):
        def decorator(func):
            return func

        return decorator

    service.Object = _Object
    service.method = _method
    exceptions.DBusException = Exception
    glib.DBusGMainLoop = lambda **kwargs: None
    mainloop.glib = glib

    dbus.service = service
    dbus.exceptions = exceptions
    dbus.mainloop = mainloop
    dbus.Array = list
    dbus.ByteArray = bytes
    dbus.ObjectPath = str
    dbus.Boolean = bool
    dbus.String = str
    dbus.Interface = object

    gi = types.ModuleType("gi")
    repository = types.ModuleType("gi.repository")
    repository.GLib = type("GLib", (), {})
    repository.GLibUnix = type("GLibUnix", (), {})
    gi.repository = repository

    sys.modules["dbus"] = dbus
    sys.modules["dbus.service"] = service
    sys.modules["dbus.exceptions"] = exceptions
    sys.modules["dbus.mainloop"] = mainloop
    sys.modules["dbus.mainloop.glib"] = glib
    sys.modules["gi"] = gi
    sys.modules["gi.repository"] = repository


_install_import_stubs()
import zebra_bridge  # noqa: E402


class ConfigLoadingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def _write(self, name, data):
        path = self.dir / name
        path.write_bytes(data)
        return str(path)

    def test_windows_bom_and_crlf(self):
        path = self._write(
            "windows.conf",
            b"\xef\xbb\xbf[bridge]\r\n"
            b"name = ZD421-Front Desk\r\n"
            b"serial = ZD421-CHECKIN-0002\r\n"
            b"printer = /dev/usb/lp1\r\n",
        )
        values, resolved = zebra_bridge.load_config(path)
        self.assertEqual(resolved, path)
        self.assertEqual(values["name"], "ZD421-Front Desk")
        self.assertEqual(values["serial"], "ZD421-CHECKIN-0002")
        self.assertEqual(values["printer"], "/dev/usb/lp1")
        self.assertNotIn("\r", values["name"])

    def test_old_mac_cr_only(self):
        path = self._write(
            "mac.conf",
            b"[bridge]\rname = ZD421-Mac\rlog_level = DEBUG\r",
        )
        values, _ = zebra_bridge.load_config(path)
        self.assertEqual(values["name"], "ZD421-Mac")
        self.assertEqual(values["log_level"], "DEBUG")

    def test_inline_comments_and_duplicate_key(self):
        path = self._write(
            "comments.conf",
            b"[bridge]\n"
            b"name = First # operator note\n"
            b"name = Second\n",
        )
        values, _ = zebra_bridge.load_config(path)
        self.assertEqual(values["name"], "Second")

    def test_invalid_utf8_is_rejected_clearly(self):
        path = self._write("latin1.conf", b"[bridge]\nname = Caf\xe9\n")
        with self.assertRaises(RuntimeError) as ctx:
            zebra_bridge.load_config(path)
        self.assertIn("not valid UTF-8", str(ctx.exception))

    def test_missing_section_is_rejected(self):
        path = self._write("empty.conf", b"name = nope\n")
        with self.assertRaises(RuntimeError) as ctx:
            zebra_bridge.load_config(path)
        self.assertIn("[bridge]", str(ctx.exception))

    def test_boot_firmware_config_wins_over_local(self):
        boot = self._write("boot.conf", b"[bridge]\nname = Boot\n")
        local = self._write("local.conf", b"[bridge]\nname = Local\n")
        original = zebra_bridge.default_config_candidates
        try:
            zebra_bridge.default_config_candidates = lambda: [boot, local]
            self.assertEqual(zebra_bridge.find_config_path(), boot)
        finally:
            zebra_bridge.default_config_candidates = original

    def test_explicit_missing_path_is_an_error(self):
        missing = str(self.dir / "nope.conf")
        with self.assertRaises(FileNotFoundError):
            zebra_bridge.find_config_path(missing)


if __name__ == "__main__":
    unittest.main()
