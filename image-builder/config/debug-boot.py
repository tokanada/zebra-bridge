#!/usr/bin/env python3
"""Boot-time setup for the zebra-bridge debug image.

Reads /boot/firmware/zebra-bridge-debug.conf and:

  * writes a NetworkManager Wi-Fi profile (so the Wi-Fi credentials survive
    the read-only bootfs being edited on any PC);
  * applies the Wi-Fi regulatory domain;
  * creates/updates the SSH login account and optional authorized key;
  * generates missing SSH host keys.

The systemd unit runs this before NetworkManager and sshd start, after
/boot/firmware has been mounted.
"""

import configparser
import glob
import grp
import os
import pwd
import subprocess
import sys
import uuid

CONFIG_PATH = "/boot/firmware/zebra-bridge-debug.conf"
SECTION = "debug"
NM_DIR = "/etc/NetworkManager/system-connections"
NM_FILE = os.path.join(NM_DIR, "zebra-debug-wifi.nmconnection")
SSH_GROUPS = (
    "sudo",
    "adm",
    "dialout",
    "lp",
    "gpio",
    "i2c",
    "spi",
    "netdev",
    "plugdev",
    "video",
    "audio",
    "users",
    "bluetooth",
    "systemd-journal",
)


def log(message):
    print(f"zebra-bridge-debug: {message}", flush=True)


def run(command, **kwargs):
    kwargs.setdefault("stdout", subprocess.DEVNULL)
    kwargs.setdefault("stderr", subprocess.DEVNULL)
    try:
        return subprocess.run(command, check=False, **kwargs)
    except FileNotFoundError:
        log(f"command not found: {command[0]}")
        return None


def read_config():
    parser = configparser.ConfigParser(interpolation=None)
    if not os.path.isfile(CONFIG_PATH):
        log(f"{CONFIG_PATH} is missing; using defaults")
        return parser
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8-sig", newline="") as handle:
            text = handle.read().replace("\r\n", "\n").replace("\r", "\n")
        parser.read_string(text, source=CONFIG_PATH)
    except Exception as exc:  # configparser.Error, UnicodeDecodeError, OSError
        log(f"could not read {CONFIG_PATH}: {exc}; using defaults")
    return parser


def get(parser, key, default=""):
    if not parser.has_section(SECTION):
        return default
    return parser.get(SECTION, key, fallback=default).strip()


def keyfile_escape(value):
    """Escape the two characters NetworkManager's keyfile reader treats specially."""
    return value.replace("\\", "\\\\").replace("\n", "\\n")


def configure_wifi(parser):
    ssid = get(parser, "wifi_ssid")
    password = get(parser, "wifi_password")
    country = get(parser, "wifi_country", "US").upper()
    hidden = get(parser, "wifi_hidden", "false").lower() in ("1", "true", "yes", "on")

    if country:
        # Both calls are best effort.  raspi-config persists the wpa_supplicant
        # country setting on Raspberry Pi OS; iw sets the runtime domain.
        run(["raspi-config", "nonint", "do_wifi_country", country])
        run(["iw", "reg", "set", country])
        log(f"Wi-Fi regulatory domain set to {country} (best effort)")

    if not ssid:
        log("wifi_ssid is empty; skipping Wi-Fi profile")
        return

    lines = [
        "[connection]",
        "id=zebra-debug-wifi",
        "uuid=%s" % uuid.uuid5(uuid.NAMESPACE_DNS, f"zebra-bridge-debug:{ssid}"),
        "type=wifi",
        "autoconnect=true",
        "autoconnect-priority=100",
        "",
        "[wifi]",
        "mode=infrastructure",
        f"ssid={keyfile_escape(ssid)}",
        f"hidden={'true' if hidden else 'false'}",
        "",
    ]
    if password:
        lines.extend(
            [
                "[wifi-security]",
                "key-mgmt=wpa-psk",
                f"psk={keyfile_escape(password)}",
                "",
            ]
        )
    lines.extend(["[ipv4]", "method=auto", "", "[ipv6]", "method=disabled", ""])

    try:
        os.makedirs(NM_DIR, mode=0o700, exist_ok=True)
        with open(NM_FILE, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines))
        os.chmod(NM_FILE, 0o600)
    except OSError as exc:
        log(f"could not write {NM_FILE}: {exc}")
        return
    log(f"wrote Wi-Fi profile for SSID {ssid!r}")

    # Harmless while NetworkManager is not running yet; makes a manual restart
    # of this unit apply an edited SSID/password immediately.
    run(["nmcli", "connection", "reload"])
    run(["nmcli", "connection", "up", "zebra-debug-wifi"])


def ensure_ssh_user(parser):
    user = get(parser, "ssh_user", "pi") or "pi"
    password = get(parser, "ssh_password", "zebra")
    public_key = get(parser, "ssh_authorized_key")

    try:
        account = pwd.getpwnam(user)
    except KeyError:
        result = run(["useradd", "--create-home", "--shell", "/bin/bash", user])
        if result is None or result.returncode != 0:
            log(f"could not create SSH user {user!r}")
            return
        account = pwd.getpwnam(user)
        log(f"created SSH user {user!r}")

    for group in SSH_GROUPS:
        try:
            grp.getgrnam(group)
        except KeyError:
            continue
        run(["usermod", "--append", "--groups", group, user])

    if password:
        result = run(["chpasswd"], input=f"{user}:{password}\n", text=True)
        if result is None or result.returncode != 0:
            log(f"could not set password for {user!r}")
        else:
            log(f"SSH password for {user!r} is set")

    if public_key:
        ssh_dir = os.path.join(account.pw_dir, ".ssh")
        authorized_keys = os.path.join(ssh_dir, "authorized_keys")
        try:
            os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
            existing = ""
            if os.path.exists(authorized_keys):
                with open(authorized_keys, "r", encoding="utf-8", errors="replace") as handle:
                    existing = handle.read()
            if public_key not in existing.splitlines():
                with open(authorized_keys, "a", encoding="utf-8") as handle:
                    if existing and not existing.endswith("\n"):
                        handle.write("\n")
                    handle.write(public_key + "\n")
            os.chmod(authorized_keys, 0o600)
            os.chown(ssh_dir, account.pw_uid, account.pw_gid)
            os.chown(authorized_keys, account.pw_uid, account.pw_gid)
            log(f"installed SSH authorized key for {user!r}")
        except OSError as exc:
            log(f"could not install SSH key for {user!r}: {exc}")


def ensure_ssh_host_keys():
    if glob.glob("/etc/ssh/ssh_host_*_key"):
        return
    result = run(["ssh-keygen", "-A"])
    if result is None or result.returncode != 0:
        log("could not generate SSH host keys")
    else:
        log("generated SSH host keys")


def main():
    parser = read_config()
    configure_wifi(parser)
    ensure_ssh_user(parser)
    ensure_ssh_host_keys()
    return 0


if __name__ == "__main__":
    sys.exit(main())
