#!/bin/bash
#
# erase-internal-ssd.sh
# -----------------------------------------------------------------------------
# Wipe the INTERNAL SSD of an Intel Mac and lay down a fresh, empty volume ready
# for a clean macOS Sierra install.
#
# WHERE TO RUN THIS:
#   On the TARGET Intel MacBook Pro, after booting from the Sierra USB stick
#   (hold Option at power-on -> choose "Install macOS Sierra"). Then from the
#   menu bar choose  Utilities > Terminal  and run:
#
#       bash "/Volumes/OS X Base System/erase-internal-ssd.sh"
#
# What it does:
#   - Shows you every disk and asks which one is the internal SSD.
#   - Erases it as Mac OS Extended (Journaled) with a GUID Partition Map.
#     (Sierra predates APFS, so HFS+/JHFS+ is the correct format.)
#
# This is destructive and irreversible. It double-confirms before touching
# anything, and refuses to erase the disk you booted from.
# -----------------------------------------------------------------------------

set -euo pipefail

NEW_VOL_NAME="Macintosh HD"

echo "=========================================================="
echo " Internal SSD eraser for a clean macOS Sierra install"
echo "=========================================================="
echo
echo "Current disks on this machine:"
echo
diskutil list
echo
echo "----------------------------------------------------------"
echo "Find your INTERNAL SSD above. It is the whole disk (e.g."
echo "disk0), NOT the USB installer you booted from."
echo "----------------------------------------------------------"
echo
printf "Enter the disk identifier to ERASE (e.g. disk0): "
read -r DISKID

# Normalize: accept 'disk0' or '/dev/disk0'
DISKID="${DISKID#/dev/}"
DEV="/dev/$DISKID"

diskutil info "$DEV" >/dev/null 2>&1 || { echo "ERROR: $DEV is not a valid disk."; exit 1; }

# Refuse to erase the boot/installer device.
BOOT_DEV="$(diskutil info / 2>/dev/null | awk -F': *' '/Part of Whole|Device Identifier/{print $2; exit}')"
if [ "$DISKID" = "$BOOT_DEV" ]; then
  echo "ERROR: $DEV appears to be the device you booted from. Refusing."
  exit 1
fi

echo
echo "You selected:"
diskutil info "$DEV" | grep -E "Device Identifier|Device / Media Name|Disk Size|Internal|Solid State" || true
echo
echo "!!!  ALL DATA on $DEV will be PERMANENTLY DESTROYED.  !!!"
echo
printf "Type ERASE to continue: "
read -r c1
[ "$c1" = "ERASE" ] || { echo "Aborted."; exit 1; }
printf "Re-type the disk identifier (%s) to confirm: " "$DISKID"
read -r c2
[ "$c2" = "$DISKID" ] || { echo "Confirmation did not match. Aborted."; exit 1; }

echo
echo "==> Unmounting $DEV ..."
diskutil unmountDisk force "$DEV" || true

echo "==> Erasing $DEV as Mac OS Extended (Journaled), GUID scheme ..."
diskutil eraseDisk JHFS+ "$NEW_VOL_NAME" GPT "$DEV"

echo
echo "DONE. $DEV is now a single empty '$NEW_VOL_NAME' volume."
echo "Quit Terminal, return to the installer, and choose \"Install macOS\"."
echo "Select '$NEW_VOL_NAME' as the destination."
