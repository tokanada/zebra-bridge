"""Tests for the dpkg-status parser in image-builder/verify-image.py.

The hyphen in "verify-image.py" prevents a normal import, so the module is
loaded by path with importlib.  The tests only exercise the pure
dpkg_stanza helper, not the image-reading code.
"""

import importlib.util
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VERIFY_IMAGE_PATH = REPO_ROOT / "image-builder" / "verify-image.py"

_spec = importlib.util.spec_from_file_location("verify_image", VERIFY_IMAGE_PATH)
verify_image = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verify_image)

SAMPLE_STATUS = """Package: bluez-tools
Status: install ok installed
Version: 2.0~20170911.0.7cb788c-4
Description: Set of tools to manage Bluetooth devices for linux

Package: bluez
Status: hold ok installed
Version: 5.66-1+rpt2+deb12u2+zebra1
Description: Bluetooth tools and daemons

Package: libbluetooth3
Status: install ok installed
Version: 5.66-1+rpt2+deb12u2
Description: Library to use the BlueZ Linux Bluetooth stack
"""


class DpkgStanzaTests(unittest.TestCase):
    def test_returns_only_bluez_stanza(self):
        stanza = verify_image.dpkg_stanza(SAMPLE_STATUS, "bluez")
        self.assertIn("Package: bluez", stanza.splitlines())
        self.assertNotIn("bluez-tools", stanza)
        self.assertNotIn("libbluetooth3", stanza)

    def test_missing_package_returns_empty(self):
        self.assertEqual(verify_image.dpkg_stanza(SAMPLE_STATUS, "bluez-firmware"), "")

    def test_none_returns_empty(self):
        self.assertEqual(verify_image.dpkg_stanza(None, "bluez"), "")

    def test_stanza_contains_status_and_version(self):
        stanza = verify_image.dpkg_stanza(SAMPLE_STATUS, "bluez")
        self.assertIn("Status: hold ok installed", stanza)
        self.assertIn("Version: 5.66-1+rpt2+deb12u2+zebra1", stanza)


if __name__ == "__main__":
    unittest.main()
