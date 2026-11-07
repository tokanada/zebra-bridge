#!/usr/bin/env bash
#
# Build a patched BlueZ 5.66 .deb for Raspberry Pi OS bookworm arm64.
#
# Host usage (from any directory):
#
#   image-builder/bluez/build-bluez-deb.sh
#
# The build runs inside an arm64 Debian bookworm container. The only input is
# 0001-gatt-server-fix-write-length-checks.patch in this directory; the
# resulting binary package is written to <repo>/dist/bluez/.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PATCH_NAME="0001-gatt-server-fix-write-length-checks.patch"
BLUEZ_VERSION="5.66-1+rpt2+deb12u2"
BUILD_VERSION="${BLUEZ_VERSION}+zebra1"
DEB_NAME="bluez_${BUILD_VERSION}_arm64.deb"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Container mode. Invoked by the host branch below as:
#
#   bash /bluez/build-bluez-deb.sh --in-container /bluez /out
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--in-container" ]; then
    BLUEZ_DIR="${2:?missing read-only bluez directory}"
    OUT_DIR="${3:?missing output directory}"
    PATCH_FILE="$BLUEZ_DIR/$PATCH_NAME"
    WORK_DIR=/work

    [ -f "$PATCH_FILE" ] || die "missing patch file: $PATCH_FILE"
    mkdir -p "$OUT_DIR"

    export DEBIAN_FRONTEND=noninteractive

    log "Installing build prerequisites"
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg dpkg-dev devscripts quilt

    log "Adding Debian and Raspberry Pi source repositories"
    curl -fsSL http://archive.raspberrypi.com/debian/raspberrypi.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/raspberrypi-archive-keyring.gpg

    cat > /etc/apt/sources.list.d/debian-src.list <<'EOF'
deb-src http://deb.debian.org/debian bookworm main
EOF

    cat > /etc/apt/sources.list.d/raspberrypi.list <<'EOF'
deb [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] http://archive.raspberrypi.com/debian/ bookworm main
deb-src [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] http://archive.raspberrypi.com/debian/ bookworm main
EOF

    apt-get update

    log "Checking that source version bluez=$BLUEZ_VERSION is available"
    if ! apt-cache showsrc bluez 2>/dev/null | grep -Fqx "Version: $BLUEZ_VERSION"; then
        {
            printf 'ERROR: source package bluez=%s is not available.\n' "$BLUEZ_VERSION"
            printf 'Refusing to fall back to a different version. Available source versions:\n'
            apt-cache showsrc bluez 2>/dev/null | sed -n 's/^Version: /  /p' || true
        } >&2
        exit 1
    fi

    log "Fetching source bluez=$BLUEZ_VERSION"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    chmod 0777 "$WORK_DIR"
    ( cd "$WORK_DIR" && apt-get source "bluez=$BLUEZ_VERSION" )

    SRC_DIR="$(find "$WORK_DIR" -maxdepth 1 -mindepth 1 -type d -name 'bluez-*' -print -quit)"
    [ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] \
        || die "could not find the extracted bluez source tree in $WORK_DIR"

    # Keep the quilt patches applied after --after-build so the verification
    # below inspects the same source tree that was compiled. This is the
    # documented dpkg-source mechanism (debian/source/local-options) and is
    # local to this build, so it never changes the produced packages.
    mkdir -p "$SRC_DIR/debian/source"
    printf '%s\n' 'no-unapply-patches' > "$SRC_DIR/debian/source/local-options"

    log "Installing build dependencies for $SRC_DIR"
    ( cd "$SRC_DIR" && apt-get build-dep -y . )

    log "Adding quilt patch and changelog entry"
    cp "$PATCH_FILE" "$SRC_DIR/debian/patches/$PATCH_NAME"
    SERIES="$SRC_DIR/debian/patches/series"
    [ -f "$SERIES" ] || : > "$SERIES"
    if [ -s "$SERIES" ] && [ -n "$(tail -c 1 "$SERIES")" ]; then
        printf '\n' >> "$SERIES"
    fi
    printf '%s\n' "$PATCH_NAME" >> "$SERIES"

    ( cd "$SRC_DIR" && \
        dch --newversion "$BUILD_VERSION" --distribution bookworm \
            "Rebuild with shared/gatt-server ATT write length fix." )

    log "Building binary package"
    ( cd "$SRC_DIR" && DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -uc -us )

    log "Verifying the patched source tree"
    GATT_SERVER="$SRC_DIR/src/shared/gatt-server.c"
    [ -f "$GATT_SERVER" ] || die "missing source file: $GATT_SERVER"

    verify_ok=1
    for expected in 'check_length(length - 2, 0)' 'check_length(length - 4, offset)'; do
        if grep -Fq -- "$expected" "$GATT_SERVER"; then
            printf 'OK present: %s\n' "$expected"
        else
            printf 'MISSING: %s\n' "$expected" >&2
            verify_ok=0
        fi
    done
    for original in 'check_length(length, 0)' 'check_length(length, offset)'; do
        if grep -Fq -- "$original" "$GATT_SERVER"; then
            printf 'STILL PRESENT: %s\n' "$original" >&2
            verify_ok=0
        else
            printf 'OK absent: %s\n' "$original"
        fi
    done
    [ "$verify_ok" -eq 1 ] || die "patched source tree verification failed"

    BUILT_DEB="$WORK_DIR/$DEB_NAME"
    [ -f "$BUILT_DEB" ] || die "expected binary package not found: $BUILT_DEB"
    cp "$BUILT_DEB" "$OUT_DIR/$DEB_NAME"

    OUT_OWNER="$(stat -c '%u:%g' "$OUT_DIR" 2>/dev/null || true)"
    if [ -n "$OUT_OWNER" ]; then
        chown "$OUT_OWNER" "$OUT_DIR/$DEB_NAME" 2>/dev/null || true
    fi

    log "Package metadata"
    dpkg-deb -f "$OUT_DIR/$DEB_NAME" Package Version Depends
    log "Package checksum"
    sha256sum "$OUT_DIR/$DEB_NAME"
    exit 0
fi

# ---------------------------------------------------------------------------
# Host mode
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$REPO_ROOT/dist/bluez"
PATCH_FILE="$SCRIPT_DIR/$PATCH_NAME"

[ -f "$PATCH_FILE" ] || die "missing patch file: $PATCH_FILE"
mkdir -p "$OUT_DIR"

log "Building patched BlueZ $BUILD_VERSION in an arm64 Debian bookworm container"
docker run --rm --platform linux/arm64 \
    -v "$SCRIPT_DIR:/bluez:ro" \
    -v "$OUT_DIR:/out" \
    debian:bookworm \
    bash /bluez/build-bluez-deb.sh --in-container /bluez /out

DEB_PATH="$OUT_DIR/$DEB_NAME"
[ -f "$DEB_PATH" ] || die "build finished but $DEB_PATH is missing"

log "Build artifact"
printf 'PATH: %s\n' "$DEB_PATH"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$DEB_PATH"
else
    shasum -a 256 "$DEB_PATH"
fi
