# Bootable macOS Sierra USB installer (for Intel Macs)

Tooling to build a **bootable macOS Sierra (10.12) USB installer** and to **erase
the internal SSD** of an Intel-based MacBook Pro for a clean install.

This was built to run on a modern Mac (Apple Silicon / macOS 26) where Apple's
own `createinstallmedia` tool **will not run** — see "Why not createinstallmedia"
below.

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `make-sierra-usb.sh` | This Mac (the one you're building on) | Downloads Sierra and writes a bootable installer to a USB stick |
| `erase-internal-ssd.sh` | The target Intel Mac, booted from the USB | Wipes the internal SSD to a clean HFS+ volume |
| `README.md` | — | This file |

## Requirements

- A USB stick **≥ 8 GB** (it will be completely erased).
- ~12 GB free disk space on this Mac (5 GB download + extraction).
- Administrator rights (`sudo`).

## Step 1 — Build the USB (on this Mac)

Plug in the USB stick, then run:

```bash
cd reset_intell_mac
sudo ./make-sierra-usb.sh
```

The script **scans for attached USB / external disks and presents a numbered
menu** — pick your stick (or `q` to quit). It then asks you to re-type the disk
identifier as a final confirmation before erasing anything.

Prefer to skip the menu (e.g. for scripting)? Pass the disk explicitly:

```bash
sudo ./make-sierra-usb.sh /dev/disk6
```

The script will:

1. Download Apple's official `InstallOS.dmg` (~5 GB, resumable) into `./work/`.
2. Extract `Install macOS Sierra.app` and its `InstallESD.dmg`.
3. Partition the USB (GPT + Mac OS Extended Journaled).
4. `asr restore` the BaseSystem image onto it and copy the install packages.
5. Bless it bootable and drop `erase-internal-ssd.sh` onto its root.

> Already have the installer? Skip the download with
> `sudo DMG=/path/to/InstallOS.dmg ./make-sierra-usb.sh /dev/disk6`

## Step 2 — Boot the Intel MacBook Pro from the USB

1. Insert the USB stick into the Intel Mac.
2. Power on while holding **Option (⌥)**.
3. Choose **Install macOS Sierra** in the Startup Manager.

## Step 3 — Erase the internal SSD

From the installer menu bar choose **Utilities → Terminal**, then:

```bash
bash "/Volumes/OS X Base System/erase-internal-ssd.sh"
```

It lists the disks, asks which one is the internal SSD, double-confirms, and
erases it as **Mac OS Extended (Journaled) / GUID** — the correct format for
Sierra (which predates APFS).

(You can also just use **Disk Utility** from the same Utilities menu — erase the
internal drive as *Mac OS Extended (Journaled)*, scheme *GUID Partition Map*.)

## Step 4 — Install

Quit Terminal, click **Install macOS**, and pick the freshly-erased
`Macintosh HD` as the destination.

---

## ⚠️ The expired-certificate gotcha

Sierra-era installers are code-signed with a certificate that **has since
expired**. When you launch the installer you may see:

> *"This copy of the Install macOS Sierra application can't be verified. It may
> have been corrupted or tampered with during downloading."*

This is the cert, not a bad download. Fix it on the **target Intel Mac**, in
**Utilities → Terminal**, by setting the clock back to Sierra's era *before*
installing:

```bash
date 0901120016     # format MMDDhhmmYY  ->  Sep 1, 2016, 12:00
```

Then relaunch **Install macOS**. (The clock corrects itself once the Mac is
online again after install.)

## Why not `createinstallmedia`?

The usual one-liner —
`Install\ macOS\ Sierra.app/Contents/Resources/createinstallmedia ...` — relies
on a 2016-era x86_64 binary with a hard host-OS version check. On Apple Silicon
and modern macOS it fails outright. This tooling sidesteps it entirely by
restoring the installer's `BaseSystem.dmg` with `asr` and blessing the volume by
hand — a method that is independent of the host macOS version.

## Notes / limitations

- The finished USB boots **Intel** Macs only. It will not appear as a boot
  option on Apple Silicon (expected).
- `asr restore` block-copies the image; the USB's contents are destroyed.
- Sierra runs only on Macs Apple shipped with Sierra support. Very new Intel
  Macs may require a later macOS than Sierra.
