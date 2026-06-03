#!/bin/bash
#
# make-sierra-usb.sh
# -----------------------------------------------------------------------------
# Build a BOOTABLE macOS Sierra (10.12) USB installer for an Intel-based Mac,
# WITHOUT using the bundled `createinstallmedia` tool.
#
# Why no createinstallmedia?
#   Sierra's createinstallmedia is an old x86_64 binary with a host-OS version
#   check. It refuses to run on modern macOS / Apple Silicon (e.g. an M-series
#   Mac on macOS 26). This script instead uses the "asr restore" method, which
#   works from any reasonably modern macOS because it just block-copies the
#   installer's BaseSystem image onto the USB and then bless-es it bootable.
#
# What it does:
#   1. Downloads Apple's official Sierra installer (InstallOS.dmg, ~5 GB) unless
#      you already have it.
#   2. Extracts "Install macOS Sierra.app" and its InstallESD.dmg.
#   3. Partitions your USB stick (GPT + Mac OS Extended Journaled).
#   4. asr-restores BaseSystem.dmg onto it.
#   5. Copies the install Packages + BaseSystem image and blesses the volume.
#   6. Drops erase-internal-ssd.sh onto the finished stick for use on the target.
#
# The resulting USB boots an INTEL Mac via the Startup Manager (hold Option at
# power-on). It will NOT boot an Apple Silicon Mac -- that is expected.
#
# Usage:
#   sudo ./make-sierra-usb.sh                 # lists candidate USB disks, then exits
#   sudo ./make-sierra-usb.sh /dev/diskN      # builds onto /dev/diskN (ERASES IT)
#
# Environment overrides:
#   WORKDIR=/path   where the 5 GB download + extracted app live (default ./work)
#   DMG=/path.dmg   use an InstallOS.dmg you already have instead of downloading
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Apple's official Sierra installer (verified live, 5,007,882,126 bytes) ---
readonly SIERRA_URL="http://updates-http.cdn-apple.com/2019/cert/061-39476-20191023-48f365f4-0015-4c41-9f44-39d3d2aca067/InstallOS.dmg"
readonly SIERRA_SIZE=5007882126

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$SCRIPT_DIR/work}"
DMG="${DMG:-$WORKDIR/InstallOS.dmg}"

readonly USB_LABEL="Install macOS Sierra"
readonly BASESYSTEM_VOL="/Volumes/OS X Base System"   # name asr gives the volume

# Mountpoints we manage (cleaned up on exit)
MNT_DMG="$WORKDIR/mnt_installos"
MNT_ESD="$WORKDIR/mnt_esd"
PKG_OUT="$WORKDIR/pkg_expanded"

# --- pretty logging ----------------------------------------------------------
c_blue=$'\033[1;34m'; c_grn=$'\033[1;32m'; c_red=$'\033[1;31m'; c_yel=$'\033[1;33m'; c_off=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%swarn%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '%s err%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# --- cleanup: detach any disk images we mounted ------------------------------
cleanup() {
  set +e
  [ -d "$MNT_ESD" ] && hdiutil detach -quiet "$MNT_ESD" 2>/dev/null
  [ -d "$MNT_DMG" ] && hdiutil detach -quiet "$MNT_DMG" 2>/dev/null
}
trap cleanup EXIT

# --- preflight ---------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "This script only runs on macOS."
[ "$(id -u)" -eq 0 ] || die "Run with sudo:  sudo $0 ${1:-/dev/diskN}"

mkdir -p "$WORKDIR"

# --- list candidate disks if no target given ---------------------------------
if [ $# -lt 1 ]; then
  step "Attached EXTERNAL physical disks (candidate USB sticks):"
  diskutil list external physical || true
  cat <<EOF

No target disk was given, so nothing has been changed.

Identify your USB stick above (e.g. /dev/disk6), make sure it is the right one,
then re-run:

    sudo $0 /dev/diskN

WARNING: that disk will be COMPLETELY ERASED.
EOF
  exit 0
fi

TARGET="$1"

# --- validate the target disk ------------------------------------------------
step "Validating target disk $TARGET"
diskutil info "$TARGET" >/dev/null 2>&1 || die "$TARGET is not a recognized disk."

is_internal="$(diskutil info "$TARGET" | awk -F': *' '/Device Location/{print $2}')"
is_virtual="$(diskutil info "$TARGET"  | awk -F': *' '/Virtual/{print $2}')"
disk_name="$(diskutil info "$TARGET"   | awk -F': *' '/Device \/ Media Name/{print $2}')"
disk_size="$(diskutil info "$TARGET"   | awk -F': *' '/Disk Size/{print $2}')"

[ "$is_internal" = "Internal" ] && die "$TARGET is an INTERNAL disk. Refusing. Pick the USB stick."
diskutil info "$TARGET" | grep -q "Whole:.*Yes" || die "$TARGET is a partition, not a whole disk. Use the whole disk, e.g. /dev/disk6."

printf '  Disk:     %s\n  Name:     %s\n  Size:     %s\n  Location: %s\n' \
  "$TARGET" "${disk_name:-?}" "${disk_size:-?}" "${is_internal:-?}"

echo
warn "EVERYTHING on $TARGET will be PERMANENTLY ERASED."
printf 'Type the disk identifier (%s) to confirm: ' "$(basename "$TARGET")"
read -r confirm
[ "$confirm" = "$(basename "$TARGET")" ] || die "Confirmation did not match. Aborting."

# --- 1. obtain the Sierra installer dmg --------------------------------------
step "Obtaining Sierra installer dmg"
if [ -f "$DMG" ] && [ "$(stat -f%z "$DMG")" -eq "$SIERRA_SIZE" ]; then
  ok "Found complete InstallOS.dmg at $DMG"
else
  warn "Downloading ~5 GB from Apple. This can take a while; it is resumable."
  curl -L -C - --fail --retry 3 -o "$DMG" "$SIERRA_URL"
  got="$(stat -f%z "$DMG")"
  [ "$got" -eq "$SIERRA_SIZE" ] || die "Download size mismatch (got $got, expected $SIERRA_SIZE). Re-run to resume."
  ok "Downloaded InstallOS.dmg"
fi

# --- 2. extract Install macOS Sierra.app + InstallESD.dmg --------------------
step "Mounting InstallOS.dmg"
rm -rf "$MNT_DMG"; mkdir -p "$MNT_DMG"
hdiutil attach "$DMG" -nobrowse -noverify -mountpoint "$MNT_DMG" >/dev/null
INSTALL_PKG="$(/usr/bin/find "$MNT_DMG" -maxdepth 1 -iname 'InstallOS.pkg' | head -1)"
[ -n "$INSTALL_PKG" ] || die "InstallOS.pkg not found inside the dmg."
ok "Found $INSTALL_PKG"

step "Expanding installer package to extract the app (uses temp space)"
rm -rf "$PKG_OUT"
pkgutil --expand-full "$INSTALL_PKG" "$PKG_OUT"
APP="$(/usr/bin/find "$PKG_OUT" -maxdepth 8 -type d -name 'Install macOS Sierra.app' | head -1)"
[ -n "$APP" ] || die "Could not locate 'Install macOS Sierra.app' in expanded package."
ok "App: $APP"

INSTALLESD="$APP/Contents/SharedSupport/InstallESD.dmg"
[ -f "$INSTALLESD" ] || die "InstallESD.dmg missing inside the app."

# We can detach the InstallOS.dmg now; we only need InstallESD from the app.
hdiutil detach -quiet "$MNT_DMG" 2>/dev/null || true

# --- 3. partition the USB ----------------------------------------------------
# Sierra predates APFS, so the installer media uses Mac OS Extended (Journaled).
step "Partitioning $TARGET as GPT + Mac OS Extended (Journaled)"
diskutil unmountDisk force "$TARGET" >/dev/null 2>&1 || true
diskutil partitionDisk "$TARGET" GPT JHFS+ "$USB_LABEL" 100%
ok "Partitioned. Volume mounted at /Volumes/$USB_LABEL"

# --- 4. asr restore BaseSystem onto the USB ----------------------------------
step "Mounting InstallESD.dmg"
rm -rf "$MNT_ESD"; mkdir -p "$MNT_ESD"
hdiutil attach "$INSTALLESD" -nobrowse -noverify -mountpoint "$MNT_ESD" >/dev/null

BASESYSTEM="$(/usr/bin/find "$MNT_ESD" -maxdepth 1 -iname '*BaseSystem.dmg' | head -1)"
CHUNKLIST="$(/usr/bin/find "$MNT_ESD" -maxdepth 1 -iname '*BaseSystem.chunklist' | head -1)"
PACKAGES="$(/usr/bin/find "$MNT_ESD" -maxdepth 1 -type d -iname 'Packages' | head -1)"
[ -n "$BASESYSTEM" ] || die "BaseSystem.dmg not found in InstallESD."
[ -n "$PACKAGES" ]   || die "Packages folder not found in InstallESD."
ok "BaseSystem: $BASESYSTEM"

step "Restoring BaseSystem onto the USB (asr) -- this reformats and copies"
asr restore --source "$BASESYSTEM" --target "/Volumes/$USB_LABEL" \
  --erase --noprompt --noverify
ok "BaseSystem restored"

# asr renames the target volume to 'OS X Base System' and remounts it.
sleep 3
[ -d "$BASESYSTEM_VOL" ] || die "Expected '$BASESYSTEM_VOL' after restore but it is not mounted."

# --- 5. add the installer payload + bless ------------------------------------
step "Copying install Packages onto the USB (several GB, be patient)"
rm -f "$BASESYSTEM_VOL/System/Installation/Packages"   # it's a dangling symlink
cp -R "$PACKAGES" "$BASESYSTEM_VOL/System/Installation/Packages"
ok "Packages copied"

step "Copying BaseSystem image + chunklist to volume root"
cp "$BASESYSTEM" "$BASESYSTEM_VOL/BaseSystem.dmg"
[ -n "$CHUNKLIST" ] && cp "$CHUNKLIST" "$BASESYSTEM_VOL/BaseSystem.chunklist"
ok "BaseSystem image in place"

step "Blessing the volume as bootable"
bless --folder "$BASESYSTEM_VOL/System/Library/CoreServices" --label "$USB_LABEL"
ok "Blessed"

# --- 6. ride-along erase helper for the target Mac ---------------------------
if [ -f "$SCRIPT_DIR/erase-internal-ssd.sh" ]; then
  step "Copying erase-internal-ssd.sh onto the USB"
  cp "$SCRIPT_DIR/erase-internal-ssd.sh" "$BASESYSTEM_VOL/erase-internal-ssd.sh"
  chmod +x "$BASESYSTEM_VOL/erase-internal-ssd.sh"
  ok "Erase helper added to the USB root"
else
  warn "erase-internal-ssd.sh not found next to this script; skipping ride-along copy."
fi

hdiutil detach -quiet "$MNT_ESD" 2>/dev/null || true

# --- done --------------------------------------------------------------------
cat <<EOF

${c_grn}DONE.${c_off} Your bootable Sierra installer is ready: ${BASESYSTEM_VOL}

Next, on the INTEL MacBook Pro:
  1. Insert this USB stick.
  2. Power on while holding the Option (Alt) key.
  3. Choose "$USB_LABEL" in the Startup Manager.
  4. (Recommended) Open Utilities > Terminal and run the erase helper:
         bash "/Volumes/OS X Base System/erase-internal-ssd.sh"
     ...or use Disk Utility to erase the internal SSD as Mac OS Extended
     (Journaled), GUID Partition Map.
  5. Quit back to the installer and click "Install macOS".

IMPORTANT GOTCHA: Sierra-era installers often fail with
"...application can't be verified / may be damaged" because the code-signing
certificate has expired. If that happens, in Utilities > Terminal set the clock
back to Sierra's era BEFORE installing:
         date 0901120016        # MMDDhhmmYY -> Sep 1 2016
Then re-launch the installer.
EOF
