#!/bin/bash
# /usr/local/sbin/rpi-link-gadget.sh
#
# Configures a USB Ethernet gadget via libcomposite/ConfigFS.
# Works on Raspberry Pi 4 and Pi 5, Bookworm.
#
# Do NOT use set -e here — ConfigFS writes are sensitive and we
# want to handle errors explicitly, not abort mid-setup.

GADGET_DIR="/sys/kernel/config/usb_gadget/rpi-link"

log()  { echo "[gadget] $1"; }
fail() { echo "[gadget] ERROR: $1" >&2; exit 1; }

# ── 1. Load libcomposite ───────────────────────────────────
modprobe libcomposite || fail "Could not load libcomposite. Is dtoverlay=dwc2,dr_mode=peripheral in config.txt?"

# ── 2. Mount configfs if not already mounted ──────────────
if ! mountpoint -q /sys/kernel/config; then
    mount -t configfs none /sys/kernel/config || fail "Could not mount configfs"
fi

# ── 3. Tear down existing gadget cleanly ──────────────────
if [ -d "$GADGET_DIR" ]; then
    log "Tearing down existing gadget..."
    echo "" > "$GADGET_DIR/UDC" 2>/dev/null || true
    sleep 0.2
    find "$GADGET_DIR/configs" -maxdepth 2 -type l -delete 2>/dev/null || true
    find "$GADGET_DIR/os_desc" -maxdepth 1 -type l -delete 2>/dev/null || true
    for d in \
        functions/ecm.usb0 \
        functions/rndis.usb0 \
        configs/c.1/strings/0x409 \
        configs/c.2/strings/0x409 \
        configs/c.1 \
        configs/c.2 \
        strings/0x409; do
        rmdir "$GADGET_DIR/$d" 2>/dev/null || true
    done
    rmdir "$GADGET_DIR" 2>/dev/null || true
    sleep 0.3
fi

# ── 4. Generate stable MAC addresses from CPU serial ──────
SERIAL_RAW=$(grep -m1 Serial /proc/cpuinfo | awk '{print $3}' | tr -d '[:space:]')
if [ -z "$SERIAL_RAW" ] || [ "${#SERIAL_RAW}" -lt 8 ]; then
    SERIAL_RAW="deadbeef1234abcd"
fi
S="${SERIAL_RAW: -10}"
MAC_HOST="12:${S:0:2}:${S:2:2}:${S:4:2}:${S:6:2}:${S:8:2}"
MAC_DEV="02:${S:0:2}:${S:2:2}:${S:4:2}:${S:6:2}:${S:8:2}"
log "Device MAC: $MAC_DEV  |  Host MAC: $MAC_HOST"

# ── 5. Create gadget ──────────────────────────────────────
mkdir -p "$GADGET_DIR" || fail "Could not create gadget dir — libcomposite may not have loaded"
cd "$GADGET_DIR"

echo 0x1d6b > idVendor    # Linux Foundation
echo 0x0104 > idProduct   # Multifunction Composite Gadget
echo 0x0200 > bcdUSB      # USB 2.0
echo 0x0100 > bcdDevice

mkdir -p strings/0x409
echo "$SERIAL_RAW"  > strings/0x409/serialnumber
echo "Raspberry Pi" > strings/0x409/manufacturer
echo "RPi Link"     > strings/0x409/product

# ── 6. Functions ──────────────────────────────────────────
# ECM — iPad, macOS, Linux pick this natively
mkdir -p functions/ecm.usb0
echo "$MAC_DEV"  > functions/ecm.usb0/dev_addr
echo "$MAC_HOST" > functions/ecm.usb0/host_addr

# RNDIS — Windows picks this
mkdir -p functions/rndis.usb0
echo "$MAC_DEV"  > functions/rndis.usb0/dev_addr
echo "$MAC_HOST" > functions/rndis.usb0/host_addr

# ── 7. Configurations ─────────────────────────────────────
# Config 1: ECM  (iPad / macOS / Linux)
mkdir -p configs/c.1/strings/0x409
echo "ECM"  > configs/c.1/strings/0x409/configuration
echo 250    > configs/c.1/MaxPower
echo 0x80   > configs/c.1/bmAttributes
ln -s "$GADGET_DIR/functions/ecm.usb0" configs/c.1/ecm.usb0

# Config 2: RNDIS  (Windows)
mkdir -p configs/c.2/strings/0x409
echo "RNDIS" > configs/c.2/strings/0x409/configuration
echo 250     > configs/c.2/MaxPower
echo 0x80    > configs/c.2/bmAttributes
ln -s "$GADGET_DIR/functions/rndis.usb0" configs/c.2/rndis.usb0

# ── 8. OS Descriptors (Windows RNDIS auto-install) ────────
# These must be written AFTER configs are fully created
echo 1       > os_desc/use
echo 0xcd    > os_desc/b_vendor_code
echo MSFT100 > os_desc/qw_sign
ln -sf "$GADGET_DIR/configs/c.2" os_desc/config 2>/dev/null || true

# ── 9. Bind to UDC ────────────────────────────────────────
UDC=$(ls /sys/class/udc/ 2>/dev/null | head -n1)
if [ -z "$UDC" ]; then
    fail "No UDC found in /sys/class/udc/
Possible causes:
  - dtoverlay=dwc2,dr_mode=peripheral missing from config.txt
  - Pi 5: firmware not up to date (run: sudo rpi-eeprom-update)
  - Cable is charge-only (no data lines)
Run: dmesg | grep -i dwc2"
fi

log "Binding to UDC: $UDC"
echo "$UDC" > UDC

sleep 0.5
BOUND=$(cat UDC 2>/dev/null | tr -d '[:space:]')
if [ -z "$BOUND" ]; then
    fail "UDC write appeared to succeed but UDC is still empty"
fi
log "SUCCESS — gadget bound to: $BOUND"
