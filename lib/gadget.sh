#!/bin/bash
# /usr/local/sbin/rpi-link-gadget.sh
# Configures USB gadget via libcomposite/ConfigFS.
# Works on Pi 4 and Pi 5 running Bookworm.
# Creates: ECM + RNDIS composite Ethernet (covers macOS, Linux, Windows, iPad)
# ----------------------------------------------------------------
set -e

GADGET_DIR="/sys/kernel/config/usb_gadget/rpi-link"
SERIAL=$(grep Serial /proc/cpuinfo | sed 's/Serial\s*: 0000\(\w*\)/\1/' || echo "deadbeef1234")
# Derive stable MACs from serial
MAC_HOST="12:$(echo "$SERIAL" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\).*/\1:\2:\3:\4:\5/' | cut -c1-14)"
MAC_DEV="02:$(echo  "$SERIAL" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\).*/\1:\2:\3:\4:\5/' | cut -c1-14)"

# ── Load libcomposite ──────────────────────────────────────
modprobe libcomposite

# ── Tear down any existing gadget cleanly ─────────────────
if [ -d "$GADGET_DIR" ]; then
    if [ -f "$GADGET_DIR/UDC" ] && [ -n "$(cat $GADGET_DIR/UDC 2>/dev/null)" ]; then
        echo "" > "$GADGET_DIR/UDC" 2>/dev/null || true
    fi
    # Remove symlinks from configs
    find "$GADGET_DIR/configs" -maxdepth 2 -type l -exec rm {} \; 2>/dev/null || true
    # Remove config strings dirs
    find "$GADGET_DIR/configs" -maxdepth 3 -type d -name "strings" -exec rmdir {} \; 2>/dev/null || true
    # Remove config dirs
    find "$GADGET_DIR/configs" -maxdepth 1 -type d ! -name "configs" -exec rmdir {} \; 2>/dev/null || true
    # Remove function dirs
    find "$GADGET_DIR/functions" -maxdepth 1 -type d ! -name "functions" -exec rmdir {} \; 2>/dev/null || true
    # Remove gadget strings
    find "$GADGET_DIR/strings" -maxdepth 2 -type d ! -name "strings" -exec rmdir {} \; 2>/dev/null || true
    rmdir "$GADGET_DIR" 2>/dev/null || true
fi

# ── Create gadget ──────────────────────────────────────────
mkdir -p "$GADGET_DIR"
cd "$GADGET_DIR"

echo 0x1d6b > idVendor     # Linux Foundation
echo 0x0104 > idProduct    # Multifunction Composite Gadget
echo 0x0100 > bcdDevice    # v1.0.0
echo 0x0200 > bcdUSB       # USB 2.0

mkdir -p strings/0x409
echo "$SERIAL"       > strings/0x409/serialnumber
echo "Raspberry Pi"  > strings/0x409/manufacturer
echo "RPi Link"      > strings/0x409/product

# ── Functions ─────────────────────────────────────────────
# ECM — works natively on macOS, Linux, and iPad (iOS treats it as RNDIS/ECM)
mkdir -p functions/ecm.usb0
echo "$MAC_DEV"  > functions/ecm.usb0/dev_addr
echo "$MAC_HOST" > functions/ecm.usb0/host_addr

# RNDIS — for Windows hosts (bonus)
mkdir -p functions/rndis.usb0
echo "$MAC_DEV"  > functions/rndis.usb0/dev_addr
echo "$MAC_HOST" > functions/rndis.usb0/host_addr

# RNDIS OS descriptor magic so Windows binds automatically
echo 1       > os_desc/use
echo 0xcd    > os_desc/b_vendor_code
echo MSFT100 > os_desc/qw_sign
mkdir -p functions/rndis.usb0/os_desc/interface.rndis
echo RNDIS   > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
echo 5162001 > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id

# ── Config 1: RNDIS (Windows) ──────────────────────────────
mkdir -p configs/c.1/strings/0x409
echo "RNDIS"  > configs/c.1/strings/0x409/configuration
echo 250      > configs/c.1/MaxPower
echo 0x80     > configs/c.1/bmAttributes
ln -s functions/rndis.usb0 configs/c.1/

# ── Config 2: ECM (macOS / Linux / iPad) ──────────────────
mkdir -p configs/c.2/strings/0x409
echo "ECM"    > configs/c.2/strings/0x409/configuration
echo 250      > configs/c.2/MaxPower
echo 0x80     > configs/c.2/bmAttributes
ln -s functions/ecm.usb0 configs/c.2/

# Link os_desc to config 1 (RNDIS for Windows)
ln -s configs/c.1 os_desc 2>/dev/null || true

# ── Bind to UDC ───────────────────────────────────────────
# Find the UDC (differs between Pi 4 and Pi 5)
UDC=$(ls /sys/class/udc/ | head -n1)
if [ -z "$UDC" ]; then
    echo "[ERROR] No UDC found. Check dtoverlay=dwc2,dr_mode=peripheral in config.txt"
    exit 1
fi
echo "$UDC" > UDC
echo "[gadget] Bound to UDC: $UDC"
