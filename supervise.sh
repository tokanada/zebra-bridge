#!/usr/bin/env bash
# Keep zebra_bridge.py alive without systemd.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"
RESTART_DELAY="${ZEBRA_BRIDGE_RESTART_DELAY:-3}"

# Never leave __pycache__ on the read-only root filesystem.
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1

while true; do
    "$PYTHON" -u "$SCRIPT_DIR/zebra_bridge.py"
    rc=$?
    printf '%s bridge exited with status %s; restarting in %ss\n' \
        "$(date -Is)" "$rc" "$RESTART_DELAY"
    sleep "$RESTART_DELAY"
done
