#!/usr/bin/env bash
# Portable launcher/supervisor for the Zebra BLE-to-USB bridge.
# No systemd required. Works on Raspberry Pi OS, Fedora, Debian, etc.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"
PRINTER="${ZEBRA_BRIDGE_PRINTER:-/dev/usb/lp0}"
NAME="${ZEBRA_BRIDGE_NAME:-ZD421-Emulation}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
USER_NAME="${USER:-$(id -un)}"
PIDFILE="${ZEBRA_BRIDGE_PIDFILE:-$RUNTIME_DIR/zebra-bridge.pid}"
LOGFILE="${ZEBRA_BRIDGE_LOG:-$SCRIPT_DIR/zebra-bridge.log}"
LOCKFILE="${ZEBRA_BRIDGE_LOCK:-$RUNTIME_DIR/zebra-bridge.lock}"
RESTART_DELAY="${ZEBRA_BRIDGE_RESTART_DELAY:-3}"
MAX_LOG_BYTES="${ZEBRA_BRIDGE_MAX_LOG_BYTES:-1048576}"
ADAPTER="${ZEBRA_BRIDGE_ADAPTER:-}"
LOG_LEVEL="${ZEBRA_BRIDGE_LOG_LEVEL:-}"
CONFIG_FILE=""
USE_SG=0

export ZEBRA_BRIDGE_LOCK="$LOCKFILE"
export ZEBRA_BRIDGE_RESTART_DELAY="$RESTART_DELAY"

usage() {
    cat <<EOF
Usage: $(basename "$0") {start|stop|restart|status|logs|check|run}

  start    Start in the background with automatic restart
  stop     Stop the background process
  restart  Stop, then start
  status   Show whether it is running
  logs     Follow the log file
  check    Validate BlueZ, printer access, and dependencies
  run      Run in the foreground (Ctrl-C to stop)

Configuration:
  ./zebra-bridge.conf, /boot/firmware/zebra-bridge.conf,
  /boot/zebra-bridge.conf, or /etc/zebra-bridge.conf
  [bridge] keys: name, serial, printer, adapter, log_level

Environment (override the file):
  ZEBRA_BRIDGE_CONFIG    explicit config file path
  ZEBRA_BRIDGE_PRINTER   printer device (default: /dev/usb/lp0)
  ZEBRA_BRIDGE_NAME      advertised BLE name (default: ZD421-Emulation)
  ZEBRA_BRIDGE_LOG       log path (default: $SCRIPT_DIR/zebra-bridge.log)
  ZEBRA_BRIDGE_PIDFILE   PID file (default: \$XDG_RUNTIME_DIR/zebra-bridge.pid)
  ZEBRA_BRIDGE_LOCK      lock file (default: \$XDG_RUNTIME_DIR/zebra-bridge.lock)
  ZEBRA_BRIDGE_RESTART_DELAY  seconds between restarts (default: 3)
EOF
}

is_running() {
    [ -f "$PIDFILE" ] || return 1
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

check_dependencies() {
    if ! command -v "$PYTHON" >/dev/null 2>&1; then
        echo "error: $PYTHON not found" >&2
        return 1
    fi
    if ! "$PYTHON" -c 'import dbus, dbus.service; from gi.repository import GLib' \
        >/dev/null 2>&1; then
        echo "error: missing Python dependencies" >&2
        echo "  Raspberry Pi OS: sudo apt install python3-dbus python3-gi bluez" >&2
        return 1
    fi
}

load_resolved_config() {
    local output key value
    if ! output="$("$PYTHON" "$SCRIPT_DIR/zebra_bridge.py" --print-config)"; then
        echo "error: could not load configuration" >&2
        return 1
    fi
    while IFS='=' read -r key value; do
        case "$key" in
            config) CONFIG_FILE="$value" ;;
            name) NAME="$value" ;;
            printer) PRINTER="$value" ;;
            adapter) ADAPTER="$value" ;;
            log_level) LOG_LEVEL="$value" ;;
        esac
    done <<< "$output"
}

detect_sg() {
    # If the user is in the lp group but this login session predates the
    # group change, use `sg lp` for this launch instead of requiring a reboot.
    USE_SG=0
    if [ -e "$PRINTER" ] && [ ! -w "$PRINTER" ]; then
        if id -nG "$USER_NAME" 2>/dev/null | tr ' ' '\n' | grep -qx lp; then
            USE_SG=1
        fi
    fi
}

check_printer() {
    if [ ! -e "$PRINTER" ]; then
        echo "warning: printer $PRINTER not found yet" >&2
        echo "         the bridge will keep running and write when it appears" >&2
        return 0
    fi
    if [ ! -w "$PRINTER" ]; then
        if [ "$USE_SG" -eq 1 ]; then
            echo "note: using 'sg lp' because this login session has not picked up the lp group yet" >&2
            return 0
        fi
        echo "error: no write access to $PRINTER" >&2
        echo "  Add yourself to the lp group:" >&2
        echo "    sudo usermod -aG lp $USER_NAME" >&2
        echo "  Then log out and back in (or reboot)." >&2
        echo "  Optional: install 99-zebra-printer.rules for a udev rule." >&2
        return 1
    fi
}

rotate_log() {
    if [ -f "$LOGFILE" ]; then
        local size
        size="$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)"
        if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
            mv -f "$LOGFILE" "$LOGFILE.1"
        fi
    fi
}

start() {
    if is_running; then
        echo "already running (supervisor pid $(cat "$PIDFILE"))"
        return 0
    fi
    check_dependencies
    load_resolved_config
    detect_sg
    check_printer
    rotate_log

    echo "Configuration: ${CONFIG_FILE:-none (defaults)}"
    echo "Starting Zebra BLE bridge as '$NAME' (printer $PRINTER)..."
    local launcher
    if [ "$USE_SG" -eq 1 ]; then
        launcher=(sg lp -c "$SCRIPT_DIR/supervise.sh")
    else
        launcher=("$SCRIPT_DIR/supervise.sh")
    fi
    if command -v setsid >/dev/null 2>&1; then
        setsid "${launcher[@]}" >> "$LOGFILE" 2>&1 < /dev/null &
    else
        nohup "${launcher[@]}" >> "$LOGFILE" 2>&1 < /dev/null &
    fi
    local pid=$!
    echo "$pid" > "$PIDFILE"
    sleep 1
    if is_running; then
        echo "Started (supervisor pid $(cat "$PIDFILE"))."
        echo "Log: $LOGFILE"
    else
        echo "Failed to start. Recent log:" >&2
        tail -n 20 "$LOGFILE" >&2 || true
        rm -f "$PIDFILE"
        return 1
    fi
}

stop() {
    if ! is_running; then
        echo "not running"
        rm -f "$PIDFILE"
    else
        local pid
        pid="$(cat "$PIDFILE")"
        echo "Stopping (pid $pid)..."
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq 1 25); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f "$PIDFILE"
        echo "Stopped."
    fi

    # Clean up an orphaned child if the supervisor died without it.
    if [ -f "$LOCKFILE" ]; then
        local lock_pid
        lock_pid="$(cat "$LOCKFILE" 2>/dev/null || true)"
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            kill -TERM "$lock_pid" 2>/dev/null || true
        fi
    fi
}

status() {
    if is_running; then
        local pid
        pid="$(cat "$PIDFILE")"
        echo "running (supervisor pid $pid)"
        if command -v pgrep >/dev/null 2>&1; then
            pgrep -a -P "$pid" || true
        fi
    else
        echo "not running"
        return 1
    fi
}

case "${1:-}" in
    start|stop|restart|status|logs|check|run)
        ;;
    *)
        usage
        exit 1
        ;;
esac

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        start
        ;;
    status)
        status
        ;;
    logs)
        touch "$LOGFILE"
        tail -n 100 -f "$LOGFILE"
        ;;
    check)
        check_dependencies
        load_resolved_config
        detect_sg
        if [ "$USE_SG" -eq 1 ]; then
            exec sg lp -c "$PYTHON -u $SCRIPT_DIR/zebra_bridge.py --check"
        fi
        exec "$PYTHON" -u "$SCRIPT_DIR/zebra_bridge.py" --check
        ;;
    run)
        check_dependencies
        load_resolved_config
        detect_sg
        check_printer
        if [ "$USE_SG" -eq 1 ]; then
            exec sg lp -c "$PYTHON -u $SCRIPT_DIR/zebra_bridge.py"
        fi
        exec "$PYTHON" -u "$SCRIPT_DIR/zebra_bridge.py"
        ;;
esac
