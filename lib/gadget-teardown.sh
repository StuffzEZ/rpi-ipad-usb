#!/bin/bash
# /usr/local/sbin/rpi-link-gadget-teardown.sh
# Cleanly unbinds and removes the USB gadget

GADGET_DIR="/sys/kernel/config/usb_gadget/rpi-link"

if [ ! -d "$GADGET_DIR" ]; then
    echo "[gadget-teardown] No gadget to remove."
    exit 0
fi

cd "$GADGET_DIR"

# Unbind from UDC first
echo "" > UDC 2>/dev/null || true

# Remove symlinks
find configs -maxdepth 2 -type l -exec rm {} \; 2>/dev/null || true
find os_desc  -maxdepth 1 -type l -exec rm {} \; 2>/dev/null || true

# Remove subdirs (deepest first)
for d in \
    functions/ecm.usb0/os_desc/interface.ecm \
    functions/rndis.usb0/os_desc/interface.rndis \
    functions/ecm.usb0/os_desc \
    functions/rndis.usb0/os_desc \
    functions/ecm.usb0 \
    functions/rndis.usb0 \
    configs/c.1/strings/0x409 \
    configs/c.2/strings/0x409 \
    configs/c.1 \
    configs/c.2 \
    strings/0x409 \
    os_desc; do
    rmdir "$GADGET_DIR/$d" 2>/dev/null || true
done

cd /
rmdir "$GADGET_DIR" 2>/dev/null || true
echo "[gadget-teardown] Done."
