#!/bin/bash
# =============================================================
# RPi Dashboard (v1 / v2) — Uninstall Script
# Removes everything installed by the old rpi-ipad-usb setup.sh
# Works for both v1 (rpi-ipad-usb) and v2 (rpi-ipad-usb-v2)
# Run: sudo bash uninstall-old.sh
# =============================================================

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GRN}[✓]${NC} $1"; }
warn()  { echo -e "${YLW}[!]${NC} $1"; }
skip()  { echo -e "    ${YLW}(skipped — not found)${NC}"; }
step()  { echo -e "\n${CYN}${BLD}── $1 ──${NC}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}[✗]${NC} Run as root: sudo bash uninstall-old.sh"; exit 1; }

echo -e "\n${BLD}RPi Dashboard v1/v2 — Uninstall${NC}"
echo -e "This removes services, config files, and boot changes"
echo -e "installed by the old ${CYN}rpi-ipad-usb${NC} / ${CYN}rpi-ipad-usb-v2${NC} setup scripts.\n"
read -p "Continue? [y/N] " -n1 yn; echo
[[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# =============================================================
step "Stopping and disabling services"
# =============================================================
for svc in rpi-dashboard xvfb-rpi; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop    "$svc" && info "Stopped $svc"
    else
        echo -e "  rpi-dashboard / xvfb-rpi $(skip)"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        systemctl disable "$svc" && info "Disabled $svc"
    fi
done

# =============================================================
step "Removing systemd unit files"
# =============================================================
for unit in \
    /etc/systemd/system/rpi-dashboard.service \
    /etc/systemd/system/xvfb-rpi.service; do
    if [ -f "$unit" ]; then
        rm -f "$unit" && info "Removed $unit"
    else
        echo -e "  $unit $(skip)"
    fi
done
systemctl daemon-reload
info "systemd reloaded"

# =============================================================
step "Removing app directory"
# =============================================================
if [ -d /opt/rpi-dashboard ]; then
    rm -rf /opt/rpi-dashboard && info "Removed /opt/rpi-dashboard"
else
    echo -e "  /opt/rpi-dashboard $(skip)"
fi

# =============================================================
step "Removing network config"
# =============================================================
if [ -f /etc/network/interfaces.d/usb0 ]; then
    rm -f /etc/network/interfaces.d/usb0 && info "Removed /etc/network/interfaces.d/usb0"
else
    echo -e "  /etc/network/interfaces.d/usb0 $(skip)"
fi

if [ -f /etc/dnsmasq.d/usb0.conf ]; then
    rm -f /etc/dnsmasq.d/usb0.conf && info "Removed /etc/dnsmasq.d/usb0.conf"
else
    echo -e "  /etc/dnsmasq.d/usb0.conf $(skip)"
fi

# =============================================================
step "Restoring PulseAudio system.pa (if modified)"
# =============================================================
# v2 overwrote /etc/pulse/system.pa — restore the default
PA_ORIG="/usr/share/pulseaudio/alsa-mixer/paths"   # just a check
if dpkg -l pulseaudio &>/dev/null; then
    # Reinstall to restore original config files
    apt-get install -y --reinstall pulseaudio -qq 2>/dev/null && \
        info "PulseAudio config restored via reinstall" || \
        warn "Could not reinstall pulseaudio — /etc/pulse/system.pa may still be modified"
fi

# =============================================================
step "Removing boot config changes"
# =============================================================
BOOT_DIR="/boot/firmware"
[ -d "$BOOT_DIR" ] || BOOT_DIR="/boot"
CONFIG_TXT="$BOOT_DIR/config.txt"
CMDLINE_TXT="$BOOT_DIR/cmdline.txt"

# Remove dtoverlay=dwc2 lines added by old setup
# (v3 uses a different line so won't be touched)
if grep -q "^dtoverlay=dwc2$" "$CONFIG_TXT" 2>/dev/null; then
    sed -i '/^dtoverlay=dwc2$/d' "$CONFIG_TXT"
    info "Removed 'dtoverlay=dwc2' from $CONFIG_TXT"
elif grep -q "^dtoverlay=dwc2,dr_mode=peripheral$" "$CONFIG_TXT" 2>/dev/null; then
    warn "Found 'dtoverlay=dwc2,dr_mode=peripheral' — this may be from v3 (not removed)"
else
    echo -e "  No dtoverlay=dwc2 line found $(skip)"
fi

# Remove modules-load from cmdline.txt if v1 added it
if grep -q "modules-load=dwc2,g_ether" "$CMDLINE_TXT" 2>/dev/null; then
    sed -i 's/ modules-load=dwc2,g_ether//' "$CMDLINE_TXT"
    sed -i 's/modules-load=dwc2,g_ether //' "$CMDLINE_TXT"
    info "Removed modules-load=dwc2,g_ether from $CMDLINE_TXT"
else
    echo -e "  modules-load in cmdline.txt $(skip)"
fi

# Remove dwc2 and g_ether from /etc/modules
sed -i '/^dwc2$/d'    /etc/modules 2>/dev/null && info "Removed dwc2 from /etc/modules"    || true
sed -i '/^g_ether$/d' /etc/modules 2>/dev/null && info "Removed g_ether from /etc/modules" || true

# =============================================================
step "Python packages (optional)"
# =============================================================
read -p "Remove Python packages (flask, flask-sock, pillow)? [y/N] " -n1 pypkg; echo
if [[ "$pypkg" =~ ^[Yy]$ ]]; then
    pip3 uninstall -y flask flask-sock simple-websocket pillow 2>/dev/null || true
    info "Python packages removed"
else
    warn "Python packages kept"
fi

# =============================================================
echo ""
echo -e "${GRN}${BLD}╔════════════════════════════════════════════╗${NC}"
echo -e "${GRN}${BLD}║  ✓  Old dashboard uninstalled!             ║${NC}"
echo -e "${GRN}${BLD}║  → sudo reboot  to fully clean up          ║${NC}"
echo -e "${GRN}${BLD}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "You can now install RPi Link v3 fresh."
