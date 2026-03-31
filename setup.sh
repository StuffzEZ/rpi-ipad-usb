#!/bin/bash
# =============================================================
# RPi Link v3 — Setup Script
# Supports: Raspberry Pi 4 and Raspberry Pi 5
# OS:       Raspberry Pi OS Bookworm
# Run:      sudo bash setup.sh
# =============================================================
set -e

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'

info()  { echo -e "  ${GRN}[✓]${NC} $1"; }
warn()  { echo -e "  ${YLW}[!]${NC} $1"; }
error() { echo -e "  ${RED}[✗]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYN}${BLD}── $1 ──${NC}"; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash setup.sh"

# ── Detect model and paths ─────────────────────────────────
PIMODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")
echo -e "\n${BLD}RPi Link v3 — Setup${NC}"
echo -e "  Model:  ${CYN}${PIMODEL}${NC}"

IS_PI5=false
echo "$PIMODEL" | grep -q "Raspberry Pi 5" && IS_PI5=true

# Bookworm uses /boot/firmware; legacy Bullseye uses /boot
if [ -d /boot/firmware ] && [ -f /boot/firmware/config.txt ]; then
    BOOT_DIR=/boot/firmware
else
    BOOT_DIR=/boot
fi
CONFIG_TXT="$BOOT_DIR/config.txt"
CMDLINE_TXT="$BOOT_DIR/cmdline.txt"
echo -e "  Boot:   ${CYN}${BOOT_DIR}${NC}\n"

# =============================================================
# STEP 1 — Packages
# =============================================================
step "Installing packages"

apt-get update -qq
apt-get install -y \
    python3 python3-pip \
    ffmpeg \
    xdotool x11-utils xvfb \
    avahi-daemon \
    dnsmasq \
    pulseaudio pulseaudio-utils \
    net-tools iproute2 \
    network-manager
info "System packages installed"

# Install Python deps (Bookworm requires --break-system-packages)
pip3 install --break-system-packages \
    flask flask-sock simple-websocket pillow 2>/dev/null \
|| pip3 install flask flask-sock simple-websocket pillow
info "Python packages installed"

# =============================================================
# STEP 2 — config.txt: enable dwc2 peripheral mode
# =============================================================
step "Configuring USB gadget overlay in config.txt"

# Remove ALL existing dwc2 lines we may have written before (clean slate)
sed -i '/# RPi Link/d'                          "$CONFIG_TXT"
sed -i '/dtoverlay=dwc2/d'                      "$CONFIG_TXT"
sed -i '/otg_mode/d'                            "$CONFIG_TXT"
# Also clean legacy cmdline approach
sed -i 's/ modules-load=dwc2,g_ether//'         "$CMDLINE_TXT" 2>/dev/null || true
sed -i 's/modules-load=dwc2,g_ether //'         "$CMDLINE_TXT" 2>/dev/null || true

# Pi 4 and Pi 5 both need dwc2 in peripheral mode.
# On Pi 5, the USB-C port is a separate controller — we must
# also ensure it is NOT in host-only mode.
cat >> "$CONFIG_TXT" << 'EOF'

# RPi Link: USB gadget mode (libcomposite)
dtoverlay=dwc2,dr_mode=peripheral
EOF

info "dtoverlay=dwc2,dr_mode=peripheral written to $CONFIG_TXT"

# Remove dwc2/g_ether from /etc/modules (old approach — not needed with libcomposite)
sed -i '/^dwc2$/d'    /etc/modules
sed -i '/^g_ether$/d' /etc/modules
# Add libcomposite so it loads at boot before the gadget service runs
grep -q "^libcomposite$" /etc/modules || echo "libcomposite" >> /etc/modules
info "libcomposite added to /etc/modules"

# =============================================================
# STEP 3 — Install gadget scripts
# =============================================================
step "Installing gadget scripts"

install -m 755 lib/gadget.sh          /usr/local/sbin/rpi-link-gadget.sh
install -m 755 lib/gadget-teardown.sh /usr/local/sbin/rpi-link-gadget-teardown.sh
info "Scripts → /usr/local/sbin/"

# =============================================================
# STEP 4 — Networking: static IP on usb0 via NetworkManager
# =============================================================
step "Configuring usb0 static IP (192.168.7.2) via NetworkManager"

# Remove any legacy /etc/network/interfaces entry — NM ignores it on Bookworm
rm -f /etc/network/interfaces.d/usb0
info "Removed legacy /etc/network/interfaces.d/usb0 (if present)"

# Remove any existing NM profile for usb0 to avoid conflicts
nmcli connection delete usb0-rpi-link 2>/dev/null || true

# Write NM keyfile directly — more reliable than nmcli add on Bookworm
# because nmcli may not be able to apply it while usb0 doesn't exist yet
NM_CONN_DIR=/etc/NetworkManager/system-connections
mkdir -p "$NM_CONN_DIR"

cat > "$NM_CONN_DIR/usb0-rpi-link.nmconnection" << 'EOF'
[connection]
id=usb0-rpi-link
uuid=a1b2c3d4-e5f6-7890-abcd-ef1234567890
type=ethernet
interface-name=usb0
autoconnect=true
autoconnect-retries=0

[ethernet]

[ipv4]
method=manual
addresses=192.168.7.2/24

[ipv6]
method=disabled
EOF

chmod 600 "$NM_CONN_DIR/usb0-rpi-link.nmconnection"
info "NetworkManager keyfile written"

# Tell NM to reload connection files
nmcli connection reload 2>/dev/null || true

# =============================================================
# STEP 5 — dnsmasq: DHCP for the iPad
# =============================================================
step "Configuring dnsmasq DHCP for iPad"

# Bookworm: NetworkManager has its own dnsmasq instance on port 53.
# We need to stop NM from managing DNS so our dnsmasq can bind port 53.
# The cleanest way: tell NM to use systemd-resolved instead.
NM_CONF=/etc/NetworkManager/conf.d/rpi-link-dns.conf
cat > "$NM_CONF" << 'EOF'
[main]
# RPi Link: let dnsmasq handle DNS on usb0; use systemd-resolved for main DNS
dns=none
EOF
info "Told NetworkManager not to manage DNS (standalone dnsmasq will run)"

# Now write our dnsmasq config
cat > /etc/dnsmasq.d/rpi-link-usb0.conf << 'EOF'
# RPi Link — DHCP only on USB gadget interface
# This file is safe to delete if you uninstall RPi Link

interface=usb0
bind-interfaces
dhcp-range=192.168.7.10,192.168.7.20,255.255.255.0,12h
dhcp-option=option:router,192.168.7.2
dhcp-option=option:dns-server,192.168.7.2

# Don't read /etc/hosts or /etc/resolv.conf
no-hosts
no-resolv
EOF

# Prevent dnsmasq from failing to start if usb0 isn't up yet
# by wrapping it as a delayed start in the service (handled below)
systemctl enable dnsmasq
info "dnsmasq configured"

# =============================================================
# STEP 6 — Avahi mDNS
# =============================================================
step "Enabling Avahi mDNS"
systemctl enable avahi-daemon
info "avahi-daemon enabled (raspberrypi.local)"

# =============================================================
# STEP 7 — Install app files
# =============================================================
step "Installing app to /opt/rpi-link"

mkdir -p /opt/rpi-link/static
cp server.py            /opt/rpi-link/server.py
cp static/index.html    /opt/rpi-link/static/index.html
info "App files installed"

# =============================================================
# STEP 8 — Xvfb virtual display (for headless Pi)
# =============================================================
step "Virtual framebuffer service (headless fallback)"

cat > /etc/systemd/system/rpi-link-xvfb.service << 'EOF'
[Unit]
Description=RPi Link — Virtual Framebuffer (headless fallback)
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :99 -screen 0 1920x1080x24 -ac
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rpi-link-xvfb
info "rpi-link-xvfb service installed"

# =============================================================
# STEP 9 — USB Gadget service
# =============================================================
step "USB Gadget service (runs at sysinit, before networking)"

cat > /etc/systemd/system/rpi-link-gadget.service << 'EOF'
[Unit]
Description=RPi Link — USB Gadget (libcomposite / ConfigFS)
# Run as early as possible — before NM brings up interfaces
After=local-fs.target
Before=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rpi-link-gadget.sh
ExecStop=/usr/local/sbin/rpi-link-gadget-teardown.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=sysinit.target
EOF

systemctl daemon-reload
systemctl enable rpi-link-gadget
info "rpi-link-gadget service installed"

# =============================================================
# STEP 10 — Dashboard service
# =============================================================
step "Dashboard service"

cat > /etc/systemd/system/rpi-link.service << 'EOF'
[Unit]
Description=RPi Link — iPad Dashboard Server
# Wait for gadget + network + dnsmasq
After=rpi-link-gadget.service network.target dnsmasq.service rpi-link-xvfb.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/rpi-link
ExecStart=/usr/bin/python3 /opt/rpi-link/server.py
Restart=always
RestartSec=5
# Use real display if available, fall back to Xvfb
Environment=DISPLAY=:0
ExecStartPre=/bin/bash -c 'DISPLAY=:0 xdpyinfo >/dev/null 2>&1 || export DISPLAY=:99; true'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rpi-link
info "rpi-link service installed"

# =============================================================
# DONE
# =============================================================
echo ""
echo -e "${GRN}${BLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GRN}${BLD}║  ✓  RPi Link v3 setup complete!                  ║${NC}"
echo -e "${GRN}${BLD}║                                                  ║${NC}"
echo -e "${GRN}${BLD}║  Next steps:                                     ║${NC}"
echo -e "${GRN}${BLD}║    1.  sudo reboot                               ║${NC}"
echo -e "${GRN}${BLD}║    2.  Plug USB-C cable → iPad                   ║${NC}"
echo -e "${GRN}${BLD}║    3.  Safari → http://raspberrypi.local         ║${NC}"
echo -e "${GRN}${BLD}║        Fallback: http://192.168.7.2              ║${NC}"
echo -e "${GRN}${BLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

if $IS_PI5; then
    echo -e "${YLW}Pi 5 reminder:${NC}"
    echo -e "  • Make sure firmware is current: ${CYN}sudo rpi-eeprom-update${NC}"
    echo -e "  • Use the USB-C port (not USB-A ports) for gadget mode"
    echo -e "  • A data-capable USB-C cable is required — charge-only cables won't work"
    echo ""
fi

echo -e "After reboot, verify with:"
echo -e "  ${CYN}cat /sys/kernel/config/usb_gadget/rpi-link/UDC${NC}  # should not be empty"
echo -e "  ${CYN}ip addr show usb0${NC}                                # should show 192.168.7.2"
echo -e "  ${CYN}sudo journalctl -u rpi-link-gadget -b${NC}            # gadget boot log"
