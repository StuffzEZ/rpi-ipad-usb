#!/bin/bash
# ============================================================
# RPi → iPad USB Dashboard v2 Setup
# sudo bash setup.sh
# ============================================================
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}══ $1 ══${NC}"; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash setup.sh"

step "Dependencies"
apt-get update -qq
apt-get install -y \
    python3 python3-pip python3-venv \
    ffmpeg \
    xdotool x11-utils xvfb \
    avahi-daemon dnsmasq \
    pulseaudio pulseaudio-utils \
    net-tools iproute2

# Python packages
pip3 install --break-system-packages flask flask-sock simple-websocket pillow 2>/dev/null || \
pip3 install flask flask-sock simple-websocket pillow

# ── USB GADGET ─────────────────────────────────────────────
step "USB Gadget (dwc2 + g_ether)"

for CFG in /boot/config.txt /boot/firmware/config.txt; do
    [[ -f $CFG ]] || continue
    grep -q "dtoverlay=dwc2" "$CFG" || echo "dtoverlay=dwc2" >> "$CFG"
    grep -q "dr_mode=peripheral" "$CFG" || \
        sed -i 's/dtoverlay=dwc2/dtoverlay=dwc2,dr_mode=peripheral/' "$CFG"
done

grep -q "dwc2"   /etc/modules || echo "dwc2"   >> /etc/modules
grep -q "g_ether" /etc/modules || echo "g_ether" >> /etc/modules

# ── NETWORK: usb0 ─────────────────────────────────────────
step "Static IP on usb0 (192.168.7.2)"
cat > /etc/network/interfaces.d/usb0 << 'EOF'
allow-hotplug usb0
iface usb0 inet static
    address 192.168.7.2
    netmask 255.255.255.0
EOF

# ── DNSMASQ ───────────────────────────────────────────────
step "DHCP for iPad (dnsmasq)"
cat > /etc/dnsmasq.d/usb0.conf << 'EOF'
interface=usb0
bind-interfaces
dhcp-range=192.168.7.10,192.168.7.20,255.255.255.0,12h
dhcp-option=3,192.168.7.2
dhcp-option=6,192.168.7.2
EOF

# ── AVAHI ─────────────────────────────────────────────────
step "mDNS (raspberrypi.local)"
systemctl enable avahi-daemon
systemctl start  avahi-daemon 2>/dev/null || true

# ── PULSEAUDIO SYSTEM MODE ─────────────────────────────────
step "PulseAudio (system mode for root service)"
cat > /etc/pulse/system.pa << 'EOF'
load-module module-device-restore
load-module module-stream-restore
load-module module-card-restore
load-module module-augment-properties
load-module module-switch-on-port-available
load-module module-udev-detect
load-module module-alsa-sink
load-module module-alsa-source device=hw:0,0
load-module module-native-protocol-unix
load-module module-default-device-restore
load-module module-rescue-streams
load-module module-role-cork
load-module module-suspend-on-idle
load-module module-position-event-sounds
EOF

# ── INSTALL APP ────────────────────────────────────────────
step "Installing to /opt/rpi-dashboard"
mkdir -p /opt/rpi-dashboard/static
cp server.py /opt/rpi-dashboard/server.py
cp static/index.html /opt/rpi-dashboard/static/index.html

# ── XVFB VIRTUAL DISPLAY (headless fallback) ────────────────
step "Virtual display service (headless fallback)"
cat > /etc/systemd/system/xvfb-rpi.service << 'EOF'
[Unit]
Description=Virtual Framebuffer Display
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :99 -screen 0 1920x1080x24 -ac
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ── DASHBOARD SERVICE ──────────────────────────────────────
step "Dashboard systemd service"
cat > /etc/systemd/system/rpi-dashboard.service << 'EOF'
[Unit]
Description=RPi iPad USB Dashboard v2
After=network.target xvfb-rpi.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/rpi-dashboard
ExecStart=/usr/bin/python3 /opt/rpi-dashboard/server.py
Restart=always
RestartSec=5
Environment=DISPLAY=:0
Environment=PULSE_RUNTIME_PATH=/run/pulse
# If no real display, fall back to virtual
ExecStartPre=/bin/bash -c 'DISPLAY=:0 xdpyinfo &>/dev/null || export DISPLAY=:99'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xvfb-rpi
systemctl enable rpi-dashboard
systemctl start  xvfb-rpi    2>/dev/null || warn "xvfb start skipped (will start on boot)"
systemctl start  rpi-dashboard 2>/dev/null || warn "dashboard start skipped (reboot needed)"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✓  Setup complete!                          ║${NC}"
echo -e "${GREEN}║                                              ║${NC}"
echo -e "${GREEN}║  1. sudo reboot                              ║${NC}"
echo -e "${GREEN}║  2. Plug USB cable → iPad                    ║${NC}"
echo -e "${GREEN}║  3. Safari → http://raspberrypi.local        ║${NC}"
echo -e "${GREEN}║     Fallback → http://192.168.7.2            ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
