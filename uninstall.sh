#!/bin/bash
# =============================================================
# RPi Link v3 — Uninstall Script
# sudo bash uninstall.sh
# =============================================================
set -e

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GRN}[✓]${NC} $1"; }
warn()  { echo -e "${YLW}[!]${NC} $1"; }
step()  { echo -e "\n${CYN}${BLD}── $1 ──${NC}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}[✗]${NC} Run as root: sudo bash uninstall.sh"; exit 1; }

echo -e "\n${BLD}RPi Link v3 — Uninstall${NC}\n"
read -p "This will remove all RPi Link services and config. Continue? [y/N] " -n1 yn
echo
[[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# =============================================================
step "Stopping and disabling services"
# =============================================================
for svc in rpi-link rpi-link-gadget rpi-link-xvfb; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc" && info "Stopped $svc"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        systemctl disable "$svc" && info "Disabled $svc"
    fi
done

# =============================================================
step "Removing USB gadget (ConfigFS)"
# =============================================================
if [ -x /usr/local/sbin/rpi-link-gadget-teardown.sh ]; then
    /usr/local/sbin/rpi-link-gadget-teardown.sh && info "Gadget torn down"
fi

# =============================================================
step "Removing systemd unit files"
# =============================================================
for unit in \
    /etc/systemd/system/rpi-link.service \
    /etc/systemd/system/rpi-link-gadget.service \
    /etc/systemd/system/rpi-link-xvfb.service; do
    rm -f "$unit" && info "Removed $unit"
done
systemctl daemon-reload
info "systemd reloaded"

# =============================================================
step "Removing installed scripts and app"
# =============================================================
rm -f  /usr/local/sbin/rpi-link-gadget.sh
rm -f  /usr/local/sbin/rpi-link-gadget-teardown.sh
rm -rf /opt/rpi-link
info "Scripts and app removed"

# =============================================================
step "Removing network config"
# =============================================================
rm -f /etc/NetworkManager/system-connections/usb0-rpi-link.nmconnection
rm -f /etc/network/interfaces.d/usb0
rm -f /etc/dnsmasq.d/rpi-link-usb0.conf
info "Network config removed"

# Reload NM
nmcli connection reload 2>/dev/null || true

# =============================================================
step "Removing boot config changes"
# =============================================================
BOOT_DIR="/boot/firmware"
[ -d "$BOOT_DIR" ] || BOOT_DIR="/boot"
CONFIG_TXT="$BOOT_DIR/config.txt"
CMDLINE_TXT="$BOOT_DIR/cmdline.txt"

# Remove lines added by setup
sed -i '/# RPi Link: USB gadget mode/d'         "$CONFIG_TXT" 2>/dev/null || true
sed -i '/dtoverlay=dwc2,dr_mode=peripheral/d'   "$CONFIG_TXT" 2>/dev/null || true
sed -i '/# Pi5: enable USB-C OTG peripheral/d'  "$CONFIG_TXT" 2>/dev/null || true
sed -i '/modules-load=dwc2,g_ether/d'           "$CMDLINE_TXT" 2>/dev/null || true
info "Boot config cleaned"

# Remove libcomposite from /etc/modules
sed -i '/^libcomposite$/d' /etc/modules 2>/dev/null || true
info "libcomposite removed from /etc/modules"

# =============================================================
step "Removing Python packages (optional)"
# =============================================================
read -p "Remove Python packages (flask, flask-sock, pillow)? [y/N] " -n1 pypkg
echo
if [[ "$pypkg" =~ ^[Yy]$ ]]; then
    pip3 uninstall -y flask flask-sock simple-websocket pillow 2>/dev/null || true
    info "Python packages removed"
else
    warn "Python packages kept"
fi

# =============================================================
echo ""
echo -e "${GRN}${BLD}╔═══════════════════════════════════════════╗${NC}"
echo -e "${GRN}${BLD}║  ✓  RPi Link fully uninstalled!           ║${NC}"
echo -e "${GRN}${BLD}║  → sudo reboot  to fully clean up         ║${NC}"
echo -e "${GRN}${BLD}╚═══════════════════════════════════════════╝${NC}"
