#!/usr/bin/env python3
"""Read-only inspection of a built zebra-bridge .img.

Reads the FAT bootfs with mtools and the ext4 rootfs with debugfs, directly
from the image file.  It needs no root, no loop device, and no mount, so it
works in CI and on minimal build hosts.

Usage:
    python3 image-builder/verify-image.py [path/to/image.img]

Exit status is 0 only when every assertion passes.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

DIST_DIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dist")
)
DEFAULT_IMAGE = os.path.join(DIST_DIR, "zebra-bridge-pi-zero2w.img")
DEBUG_IMAGE = os.path.join(DIST_DIR, "zebra-bridge-pi-zero2w-debug.img")

failures = []
passes = 0


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def ok(desc):
    global passes
    passes += 1
    print(f"  PASS  {desc}")


def bad(desc, detail=""):
    failures.append(desc)
    print(f"  FAIL  {desc}" + (f"  [{detail}]" if detail else ""))


def expect(desc, cond, detail=""):
    if cond:
        ok(desc)
    else:
        bad(desc, detail)


def expect_in(desc, text, needle):
    expect(desc, needle in (text or ""), f"missing {needle!r}")


def expect_not_in(desc, text, needle):
    expect(desc, needle not in (text or ""), f"unexpected {needle!r}")


def fat_read(img, off, path):
    with tempfile.NamedTemporaryFile() as tmp:
        r = run(["mcopy", "-n", "-i", f"{img}@@{off}", f"::{path}", tmp.name])
        if r.returncode != 0:
            return None
        with open(tmp.name, "rb") as handle:
            return handle.read().decode("utf-8", "replace")


def fat_list(img, off):
    r = run(["mdir", "-i", f"{img}@@{off}", "::/"])
    return r.stdout if r.returncode == 0 else ""


def ext_read(img, off, path):
    r = run(["debugfs", "-R", f"cat {path}", f"{img}?offset={off}"])
    if r.returncode != 0:
        return None
    return r.stdout


def ext_stat(img, off, path):
    r = run(["debugfs", "-R", f"stat {path}", f"{img}?offset={off}"])
    return r.stdout if r.returncode == 0 else ""


def main():
    if len(sys.argv) > 1:
        img = sys.argv[1]
    elif os.path.isfile(DEFAULT_IMAGE):
        img = os.path.normpath(DEFAULT_IMAGE)
    else:
        # Convenience for building only the temporary debug image.
        img = os.path.normpath(DEBUG_IMAGE)
    if not os.path.isfile(img):
        print(f"ERROR: image not found: {img}")
        return 2

    print(f"Image: {os.path.abspath(img)} ({os.path.getsize(img) / (1024**3):.2f} GiB)")

    r = run(["sfdisk", "--json", img])
    if r.returncode != 0:
        print("ERROR: sfdisk could not read the partition table")
        print(r.stderr)
        return 2
    table = json.loads(r.stdout)["partitiontable"]
    sector = int(table.get("sectorsize", 512))
    parts = table["partitions"]
    if len(parts) < 2:
        print("ERROR: expected at least two partitions")
        return 2
    boot_off = int(parts[0]["start"]) * sector
    root_off = int(parts[1]["start"]) * sector
    print(f"Boot partition offset: {boot_off}  root offset: {root_off}")

    print("\n[bootfs / FAT32]")
    config = fat_read(img, boot_off, "/config.txt")
    cmdline = fat_read(img, boot_off, "/cmdline.txt")
    bridge_conf = fat_read(img, boot_off, "/zebra-bridge.conf")
    boot_list = fat_list(img, boot_off)

    # The release image disables the WLAN function; the temporary debug image
    # leaves it enabled for SSH.  That one line identifies the variant.
    debug = config is not None and "dtoverlay=disable-wifi" not in config
    print(f"Variant: {'debug' if debug else 'release'}")

    if config is None:
        bad("config.txt is readable")
    else:
        ok("config.txt is readable")
        for line in (
            "arm_64bit=1",
            "auto_initramfs=1",
            "dtoverlay=dwc2,dr_mode=host",
            "dtparam=watchdog=on",
            "max_framebuffers=0",
        ):
            expect_in(f"config.txt: {line}", config, line)
        if debug:
            expect_not_in("config.txt: Wi-Fi enabled", config, "dtoverlay=disable-wifi")
            expect_in("config.txt: marked as debug", config, "DEBUG BUILD")
        else:
            expect_in("config.txt: dtoverlay=disable-wifi", config, "dtoverlay=disable-wifi")

    if cmdline is None:
        bad("cmdline.txt is readable")
    else:
        ok("cmdline.txt is readable")
        expect_in("cmdline.txt: root=PARTUUID=", cmdline, "root=PARTUUID=")
        expect_not_in("cmdline.txt: no PARTUUID placeholder", cmdline, "__ROOT_PARTUUID__")
        if debug:
            expect_not_in("cmdline.txt: no overlayroot (writable root)", cmdline, "overlayroot=")
            expect_not_in("cmdline.txt: writable root", cmdline, " ro ")
        else:
            expect_in("cmdline.txt: overlayroot=tmpfs", cmdline, "overlayroot=tmpfs")
            expect_in("cmdline.txt: read-only root", cmdline, " ro ")

    expect("initramfs8 is present", "initramfs8" in boot_list)
    if bridge_conf is None:
        bad("zebra-bridge.conf is readable")
    else:
        ok("zebra-bridge.conf is readable")
        expect_in("zebra-bridge.conf: [bridge]", bridge_conf, "[bridge]")
        expect_in("zebra-bridge.conf: name", bridge_conf, "name =")
        expect_not_in("zebra-bridge.conf: no CRLF", bridge_conf, "\r\n")
        if debug:
            expect_in(
                "zebra-bridge.conf: DEBUG logging",
                bridge_conf,
                "log_level = DEBUG",
            )

    print("\n[rootfs / ext4]")
    fstab = ext_read(img, root_off, "/etc/fstab")
    if fstab is None:
        bad("/etc/fstab is readable")
    else:
        ok("/etc/fstab is readable")
        boot_line = next(
            (
                line
                for line in fstab.splitlines()
                if "/boot/firmware" in line and not line.strip().startswith("#")
            ),
            "",
        )
        if debug:
            expect(
                "fstab: /boot/firmware is rw",
                bool(re.search(r"\brw\b", boot_line)),
                boot_line,
            )
        else:
            expect(
                "fstab: /boot/firmware is ro",
                bool(re.search(r"\bro\b", boot_line)),
                boot_line,
            )

    expect_in(
        "initramfs.conf: MODULES=most",
        ext_read(img, root_off, "/etc/initramfs-tools/initramfs.conf"),
        "MODULES=most",
    )
    expect_in(
        "update-initramfs.conf: update_initramfs=yes",
        ext_read(img, root_off, "/etc/initramfs-tools/update-initramfs.conf"),
        "update_initramfs=yes",
    )

    machine_id = ext_read(img, root_off, "/etc/machine-id")
    expect("machine-id is empty (unique per unit)", (machine_id or "").strip() == "")

    unit = ext_stat(img, root_off, "/etc/systemd/system/zebra-bridge.service")
    expect("zebra-bridge.service installed", "zebra-bridge" in unit or "Inode:" in unit)

    wants = ext_stat(img, root_off, "/etc/systemd/system/multi-user.target.wants/zebra-bridge.service")
    expect("zebra-bridge enabled at multi-user.target", "Fast link dest" in wants or "zebra-bridge" in wants)

    masked = ext_stat(img, root_off, "/etc/systemd/system/ssh.service")
    if debug:
        expect("ssh.service not masked", "/dev/null" not in masked)
        expect(
            "ssh.service enabled at multi-user.target",
            "Fast link dest" in ext_stat(
                img,
                root_off,
                "/etc/systemd/system/multi-user.target.wants/ssh.service",
            ),
        )
    else:
        expect("ssh.service masked to /dev/null", "/dev/null" in masked)

    expect_in(
        "bridge script installed",
        ext_read(img, root_off, "/opt/zebra-bridge/zebra_bridge.py"),
        "Zebra ZD421 BLE-to-USB",
    )

    conf_link = ext_stat(img, root_off, "/etc/zebra-bridge.conf")
    expect("config symlink points at bootfs", "/boot/firmware/zebra-bridge.conf" in conf_link)

    expect_in(
        "usblp loaded early",
        ext_read(img, root_off, "/etc/modules-load.d/zebra-usblp.conf"),
        "usblp",
    )
    expect_in(
        "watchdog drop-in",
        ext_read(img, root_off, "/etc/systemd/system.conf.d/99-watchdog.conf"),
        "RuntimeWatchdogSec=10s",
    )
    if debug:
        expect_in(
            "journald persistent drop-in",
            ext_read(img, root_off, "/etc/systemd/journald.conf.d/99-persistent.conf"),
            "Storage=persistent",
        )
        expect(
            "journald volatile drop-in absent",
            ext_stat(
                img, root_off, "/etc/systemd/journald.conf.d/99-volatile.conf"
            ) == "",
        )
    else:
        expect_in(
            "journald volatile drop-in",
            ext_read(img, root_off, "/etc/systemd/journald.conf.d/99-volatile.conf"),
            "Storage=volatile",
        )
    expect_in(
        "BlueZ reverse discovery disabled",
        ext_read(img, root_off, "/etc/bluetooth/main.conf"),
        "ReverseServiceDiscovery = false",
    )
    expect_in(
        "hostname set",
        ext_read(img, root_off, "/etc/hostname"),
        "zebra-bridge-debug" if debug else "zebra-bridge",
    )

    if debug:
        print("\n[debug image extras]")
        debug_conf = fat_read(img, boot_off, "/zebra-bridge-debug.conf")
        if debug_conf is None:
            bad("zebra-bridge-debug.conf is readable")
        else:
            ok("zebra-bridge-debug.conf is readable")
            expect_in("debug conf: [debug]", debug_conf, "[debug]")
            expect_in("debug conf: wifi_ssid", debug_conf, "wifi_ssid =")
            expect_in("debug conf: ssh_user", debug_conf, "ssh_user =")
        expect_in(
            "debug boot script installed",
            ext_read(img, root_off, "/usr/local/sbin/zebra-bridge-debug-boot.py"),
            "zebra-bridge-debug:",
        )
        expect(
            "debug boot unit enabled at sysinit.target",
            "Fast link dest" in ext_stat(
                img,
                root_off,
                "/etc/systemd/system/sysinit.target.wants/"
                "zebra-bridge-debug-network.service",
            ),
        )
        expect_in(
            "debug boot unit waits for rfkill state restore",
            ext_read(
                img,
                root_off,
                "/etc/systemd/system/zebra-bridge-debug-network.service",
            ),
            "After=local-fs.target systemd-rfkill.service",
        )
        expect(
            "NetworkManager enabled at multi-user.target",
            "Fast link dest" in ext_stat(
                img,
                root_off,
                "/etc/systemd/system/multi-user.target.wants/"
                "NetworkManager.service",
            ),
        )
        expect(
            "wpa_supplicant enabled at multi-user.target",
            "Fast link dest" in ext_stat(
                img,
                root_off,
                "/etc/systemd/system/multi-user.target.wants/"
                "wpa_supplicant.service",
            ),
        )
        expect_in(
            "NetworkManager debug drop-in",
            ext_read(
                img,
                root_off,
                "/etc/NetworkManager/conf.d/99-zebra-debug.conf",
            ),
            "dns=default",
        )
        expect_in(
            "sshd password authentication enabled",
            ext_read(
                img, root_off, "/etc/ssh/sshd_config.d/99-zebra-debug.conf"
            ),
            "PasswordAuthentication yes",
        )
        expect_not_in(
            "Wi-Fi modules not blacklisted",
            ext_read(img, root_off, "/etc/modprobe.d/blacklist-appliance.conf"),
            "brcmfmac",
        )
        expect(
            "no SSH host keys baked into the image",
            ext_stat(img, root_off, "/etc/ssh/ssh_host_ed25519_key") == "",
        )
        expect(
            "/var/log/journal exists",
            "Inode:" in ext_stat(img, root_off, "/var/log/journal"),
        )

    print(f"\n{passes} passed, {len(failures)} failed")
    if failures:
        print("Failures:")
        for item in failures:
            print(f"  - {item}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
