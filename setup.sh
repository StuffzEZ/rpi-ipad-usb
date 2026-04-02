#!/bin/bash
# =============================================================
# RPi Link v4 — WiFi Hotspot Setup
# Creates a hidden WiFi hotspot on a USB WiFi adapter
# Full iPad remote desktop — no USB cable needed
#
# Run: sudo bash setup.sh
# =============================================================
set -e

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'

info()  { echo -e "  ${GRN}[✓]${NC} $1"; }
warn()  { echo -e "  ${YLW}[!]${NC} $1"; }
error() { echo -e "  ${RED}[✗]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYN}${BLD}── $1 ──${NC}"; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash setup.sh"

# ── Configuration ──────────────────────────────────────────
# Edit these before running setup.sh

HOTSPOT_SSID="remotePi-v4-aaej9ce-$(tr -dc a-z0-9 </dev/urandom | head -c2)"         # Network name (hidden, so clients must know it)
HOTSPOT_PASS="AAEEjjHH990011kkLo@"      # WPA2 password (min 8 chars)
HOTSPOT_CHANNEL="6"             # WiFi channel (1, 6, or 11 recommended)
HOTSPOT_IP="10.42.0.1"          # Pi's IP on the hotspot network
DHCP_RANGE_START="10.42.0.10"
DHCP_RANGE_END="10.42.0.50"
SERVER_PORT="80"                # Dashboard port

# Auto-detect USB WiFi adapter (anything that isn't the built-in wlan0)
detect_wifi_adapter() {
    for iface in $(ls /sys/class/net/ | grep -E '^wlan'); do
        # Skip built-in wlan0 if a USB adapter exists
        driver=$(readlink /sys/class/net/$iface/device/driver 2>/dev/null | xargs basename 2>/dev/null || echo "")
        if [ "$iface" != "wlan0" ]; then
            echo "$iface"
            return
        fi
    done
    # Fallback to wlan1, or wlan0 if nothing else
    ls /sys/class/net/ | grep -E '^wlan[1-9]' | head -1 || echo "wlan0"
}

WIFI_IFACE=$(detect_wifi_adapter)

echo -e "\n${BLD}RPi Link v4 — WiFi Hotspot Setup${NC}"
echo -e "  Hotspot interface: ${CYN}${WIFI_IFACE}${NC}"
echo -e "  SSID (hidden):     ${CYN}${HOTSPOT_SSID}${NC}"
echo -e "  Hotspot IP:        ${CYN}${HOTSPOT_IP}${NC}"
echo -e "  Dashboard port:    ${CYN}${SERVER_PORT}${NC}"
echo ""
warn "Make sure your USB WiFi adapter is plugged in!"
read -p "  Continue with interface ${WIFI_IFACE}? [y/N] " -n1 yn; echo
[[ "$yn" =~ ^[Yy]$ ]] || error "Aborted. Edit WIFI_IFACE in setup.sh if needed."

# ── Verify adapter supports AP mode ────────────────────────
if command -v iw &>/dev/null; then
    AP_SUPPORT=$(iw list 2>/dev/null | grep -A 10 "Supported interface modes" | grep "AP" || true)
    if [ -z "$AP_SUPPORT" ]; then
        warn "Could not confirm AP mode support. Proceeding anyway — some adapters report incorrectly."
    else
        info "WiFi adapter supports AP mode"
    fi
fi

# =============================================================
step "Installing packages"
# =============================================================
apt-get update -qq
apt-get install -y \
    hostapd \
    dnsmasq \
    python3 python3-pip \
    ffmpeg \
    xdotool x11-utils xvfb \
    avahi-daemon \
    pulseaudio pulseaudio-utils \
    net-tools iproute2 \
    iptables \
    xclip xsel \
    wmctrl \
    scrot \
    curl wget
info "System packages installed"

pip3 install --break-system-packages \
    flask flask-sock simple-websocket pillow 2>/dev/null \
    || pip3 install flask flask-sock simple-websocket pillow
info "Python packages installed"

# =============================================================
step "Configuring hostapd (hidden WiFi hotspot)"
# =============================================================

# Stop NM from managing our hotspot interface
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/rpi-link-hotspot.conf << EOF
[keyfile]
unmanaged-devices=interface-name:${WIFI_IFACE}
EOF

# Disable hostapd blocking service
systemctl unmask hostapd 2>/dev/null || true

cat > /etc/hostapd/rpi-link.conf << EOF
# RPi Link — Hidden WiFi Hotspot
interface=${WIFI_IFACE}
driver=nl80211
ssid=${HOTSPOT_SSID}
ignore_broadcast_ssid=1
hw_mode=g
channel=${HOTSPOT_CHANNEL}
wmm_enabled=0
macaddr_acl=0
auth_algs=1
wpa=2
wpa_passphrase=${HOTSPOT_PASS}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
beacon_int=100
dtim_period=2
max_num_sta=10
EOF

# Point hostapd to our config
sed -i 's|#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/rpi-link.conf"|' /etc/default/hostapd
grep -q 'DAEMON_CONF="/etc/hostapd/rpi-link.conf"' /etc/default/hostapd || \
    echo 'DAEMON_CONF="/etc/hostapd/rpi-link.conf"' >> /etc/default/hostapd

info "hostapd configured (hidden SSID: ${HOTSPOT_SSID})"

# =============================================================
step "Configuring dnsmasq (DHCP for hotspot)"
# =============================================================
cat > /etc/dnsmasq.d/rpi-link-hotspot.conf << EOF
# RPi Link — DHCP on hotspot interface
interface=${WIFI_IFACE}
bind-interfaces
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},255.255.255.0,24h
dhcp-option=option:router,${HOTSPOT_IP}
dhcp-option=option:dns-server,${HOTSPOT_IP}
# mDNS / hostname resolution
address=/raspberrypi.local/${HOTSPOT_IP}
address=/rpi.link/${HOTSPOT_IP}
no-resolv
no-hosts
EOF

info "dnsmasq DHCP configured"

# =============================================================
step "Setting static IP on hotspot interface"
# =============================================================
# Create a NetworkManager connection that stays unmanaged
# Use a startup script instead
cat > /usr/local/sbin/rpi-link-hotspot-up.sh << EOF
#!/bin/bash
# Bring up the hotspot interface with a static IP
IFACE="${WIFI_IFACE}"
IP="${HOTSPOT_IP}"

# Bring interface up
ip link set \$IFACE up 2>/dev/null || true
sleep 1
# Assign static IP
ip addr flush dev \$IFACE 2>/dev/null || true
ip addr add \${IP}/24 dev \$IFACE
ip link set \$IFACE up

# Enable IP forwarding (allows internet sharing from eth0/wlan0 if available)
echo 1 > /proc/sys/net/ipv4/ip_forward

echo "[rpi-link-hotspot] Interface \$IFACE up at \$IP"
EOF
chmod +x /usr/local/sbin/rpi-link-hotspot-up.sh

info "Hotspot startup script created"

# =============================================================
step "Configuring iptables (optional internet forwarding)"
# =============================================================
# Save iptables rules to enable NAT so hotspot clients can reach internet
# via the Pi's ethernet/main WiFi (optional — works even without this)
cat > /usr/local/sbin/rpi-link-nat.sh << 'NATEOF'
#!/bin/bash
# Optional: share Pi's internet connection to hotspot clients
# Detect outbound interface (eth0, wlan0, etc.)
OUTBOUND=$(ip route | grep default | awk '{print $5}' | head -1)
HOTSPOT_IFACE="WIFI_IFACE_PLACEHOLDER"

if [ -n "$OUTBOUND" ] && [ "$OUTBOUND" != "$HOTSPOT_IFACE" ]; then
    iptables -t nat -A POSTROUTING -o "$OUTBOUND" -j MASQUERADE 2>/dev/null || true
    iptables -A FORWARD -i "$HOTSPOT_IFACE" -o "$OUTBOUND" -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i "$OUTBOUND" -o "$HOTSPOT_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    echo "[rpi-link-nat] NAT forwarding enabled: $HOTSPOT_IFACE -> $OUTBOUND"
fi
NATEOF
sed -i "s/WIFI_IFACE_PLACEHOLDER/${WIFI_IFACE}/" /usr/local/sbin/rpi-link-nat.sh
chmod +x /usr/local/sbin/rpi-link-nat.sh

info "NAT script created"

# =============================================================
step "Configuring Avahi mDNS"
# =============================================================
systemctl enable avahi-daemon
info "avahi-daemon enabled (raspberrypi.local)"

# =============================================================
step "Installing app to /opt/rpi-link"
# =============================================================
mkdir -p /opt/rpi-link/static
cp server.py         /opt/rpi-link/server.py
cp static/index.html /opt/rpi-link/static/index.html
info "App installed to /opt/rpi-link"

# Write config file the server reads
cat > /opt/rpi-link/config.json << EOF
{
  "hotspot_iface": "${WIFI_IFACE}",
  "hotspot_ip": "${HOTSPOT_IP}",
  "hotspot_ssid": "${HOTSPOT_SSID}",
  "server_port": ${SERVER_PORT}
}
EOF
info "Config written to /opt/rpi-link/config.json"

# =============================================================
step "Xvfb virtual display service"
# =============================================================
cat > /etc/systemd/system/rpi-link-xvfb.service << 'EOF'
[Unit]
Description=RPi Link — Virtual Framebuffer
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
step "Hotspot network service"
# =============================================================
cat > /etc/systemd/system/rpi-link-hotspot.service << EOF
[Unit]
Description=RPi Link — Hotspot Interface Setup
After=network.target
Before=hostapd.service dnsmasq.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rpi-link-hotspot-up.sh
ExecStartPost=/usr/local/sbin/rpi-link-nat.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rpi-link-hotspot
info "rpi-link-hotspot service installed"

# =============================================================
step "Enabling hostapd and dnsmasq"
# =============================================================
systemctl enable hostapd
systemctl enable dnsmasq
info "hostapd and dnsmasq enabled"

# =============================================================
step "Dashboard service"
# =============================================================
cat > /etc/systemd/system/rpi-link.service << EOF
[Unit]
Description=RPi Link — iPad Dashboard Server
After=rpi-link-hotspot.service hostapd.service dnsmasq.service network.target rpi-link-xvfb.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/rpi-link
ExecStart=/usr/bin/python3 /opt/rpi-link/server.py
Restart=always
RestartSec=5
Environment=DISPLAY=:0
ExecStartPre=/bin/bash -c 'DISPLAY=:0 xdpyinfo >/dev/null 2>&1 || export DISPLAY=:99; true'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rpi-link
info "rpi-link service installed"

# =============================================================
echo ""
echo -e "${GRN}${BLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GRN}${BLD}║  ✓  RPi Link v4 setup complete!                          ║${NC}"
echo -e "${GRN}${BLD}║                                                          ║${NC}"
echo -e "${GRN}${BLD}║  Next steps:                                             ║${NC}"
echo -e "${GRN}${BLD}║    1.  sudo reboot                                       ║${NC}"
echo -e "${GRN}${BLD}║    2.  On iPad: Settings → WiFi → Other Network...       ║${NC}"
echo -e "${GRN}${BLD}║        Name: ${HOTSPOT_SSID}                                        ║${NC}"
echo -e "${GRN}${BLD}║        Security: WPA2  Password: ${HOTSPOT_PASS}            ║${NC}"
echo -e "${GRN}${BLD}║    3.  Safari → http://${HOTSPOT_IP}                     ║${NC}"
echo -e "${GRN}${BLD}║        or   → http://rpi.link                            ║${NC}"
echo -e "${GRN}${BLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YLW}The network is HIDDEN — iPad must use 'Other Network...' to join${NC}"
echo -e "  ${YLW}WiFi adapter detected: ${WIFI_IFACE}${NC}"
echo ""
echo -e " ${YLW} REMEMBER: You must remember the SSID and Password to get onto the wifi network. Maybe take a photo of this information. The only differentiation of the network SSID from other devices using this program is the last 2 letters so if you need to you only have to remember the last two letters. Aswell, the password is the same on all devices."
echo ""
echo -e "After reboot, verify:"
echo -e "  ${CYN}sudo systemctl status hostapd${NC}"
echo -e "  ${CYN}sudo systemctl status rpi-link${NC}"
echo -e "  ${CYN}ip addr show ${WIFI_IFACE}${NC}"
