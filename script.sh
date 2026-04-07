#!/usr/bin/env bash
# =============================================================================
#  ██████╗ ██████╗ ██████╗ ███████╗██████╗ ██╗
# ██╔════╝██╔═══██╗██╔══██╗██╔════╝██╔══██╗██║
# ██║     ██║   ██║██║  ██║█████╗  ██████╔╝██║
# ██║     ██║   ██║██║  ██║██╔══╝  ██╔═══╝ ██║
# ╚██████╗╚██████╔╝██████╔╝███████╗██║     ██║
#  ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝     ╚═╝
#
#  Raspberry Pi 5 × iPad Pro Development Environment Setup
#  --------------------------------------------------------
#  Author : av1155 (https://github.com/av1155)
#  Version: 1.0.0
# =============================================================================

set -euo pipefail

# ─── Color & Style Palette ────────────────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
ITALIC='\033[3m'

BLACK='\033[30m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
WHITE='\033[37m'

BG_BLACK='\033[40m'
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_BLUE='\033[44m'
BG_MAGENTA='\033[45m'
BG_CYAN='\033[46m'
BG_WHITE='\033[47m'

BRIGHT_RED='\033[91m'
BRIGHT_GREEN='\033[92m'
BRIGHT_YELLOW='\033[93m'
BRIGHT_BLUE='\033[94m'
BRIGHT_MAGENTA='\033[95m'
BRIGHT_CYAN='\033[96m'
BRIGHT_WHITE='\033[97m'

# ─── Terminal Width ────────────────────────────────────────────────────────────
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
[[ $TERM_WIDTH -lt 60 ]] && TERM_WIDTH=60
[[ $TERM_WIDTH -gt 120 ]] && TERM_WIDTH=120

# ─── Log File ─────────────────────────────────────────────────────────────────
LOG_FILE="$HOME/codepi-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ─── Utility: Print centered text ─────────────────────────────────────────────
center() {
    local text="$1"
    local color="${2:-}"
    local clean="${text//$'\033'[*m/}"  # strip ANSI for width calc
    clean=$(echo -e "$clean" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$(( (TERM_WIDTH - ${#clean}) / 2 ))
    [[ $pad -lt 0 ]] && pad=0
    printf "%${pad}s" ""
    echo -e "${color}${text}${RESET}"
}

# ─── Utility: Horizontal rule ─────────────────────────────────────────────────
hr() {
    local char="${1:-─}"
    local color="${2:-$DIM$CYAN}"
    local line=""
    for (( i=0; i<TERM_WIDTH; i++ )); do line+="$char"; done
    echo -e "${color}${line}${RESET}"
}

# ─── Utility: Box ─────────────────────────────────────────────────────────────
box() {
    local title="$1"
    local color="${2:-$CYAN}"
    local inner=$(( TERM_WIDTH - 4 ))
    local title_clean=$(echo -e "$title" | sed 's/\x1b\[[0-9;]*m//g')
    local title_pad=$(( (inner - ${#title_clean}) / 2 ))
    [[ $title_pad -lt 0 ]] && title_pad=0

    echo -e "${color}╔$(printf '═%.0s' $(seq 1 $((TERM_WIDTH-2))))╗${RESET}"
    echo -e "${color}║${RESET}$(printf ' %.0s' $(seq 1 $title_pad))${BOLD}${title}${RESET}$(printf ' %.0s' $(seq 1 $(( inner - title_pad - ${#title_clean} + 2 ))))${color}║${RESET}"
    echo -e "${color}╚$(printf '═%.0s' $(seq 1 $((TERM_WIDTH-2))))╝${RESET}"
}

# ─── Utility: Section header ──────────────────────────────────────────────────
section() {
    local num="$1"
    local title="$2"
    echo ""
    echo -e "${BOLD}${BG_BLUE}${WHITE} STEP ${num} ${RESET}${BOLD}${BLUE} ${title} ${RESET}"
    hr "─" "$DIM$BLUE"
}

# ─── Utility: Status messages ─────────────────────────────────────────────────
info()    { echo -e "  ${BRIGHT_CYAN}${BOLD}ℹ${RESET}  ${WHITE}$*${RESET}"; }
success() { echo -e "  ${BRIGHT_GREEN}${BOLD}✔${RESET}  ${BRIGHT_GREEN}$*${RESET}"; }
warn()    { echo -e "  ${BRIGHT_YELLOW}${BOLD}⚠${RESET}  ${BRIGHT_YELLOW}$*${RESET}"; }
error()   { echo -e "  ${BRIGHT_RED}${BOLD}✘${RESET}  ${BRIGHT_RED}$*${RESET}"; }
step()    { echo -e "  ${MAGENTA}${BOLD}→${RESET}  ${WHITE}$*${RESET}"; }
skip()    { echo -e "  ${DIM}${BOLD}–${RESET}  ${DIM}Skipped: $*${RESET}"; }

# ─── Utility: Prompt yes/no ───────────────────────────────────────────────────
ask() {
    local prompt="$1"
    local default="${2:-y}"
    local yn_hint
    [[ $default == "y" ]] && yn_hint="${BRIGHT_GREEN}Y${RESET}${DIM}/n${RESET}" || yn_hint="${DIM}y/${RESET}${BRIGHT_RED}N${RESET}"
    echo -e ""
    echo -ne "  ${BRIGHT_YELLOW}${BOLD}?${RESET}  ${BOLD}${prompt}${RESET} [${yn_hint}] "
    read -r reply
    reply="${reply:-$default}"
    [[ $reply =~ ^[Yy] ]]
}

# ─── Utility: Run a command with spinner ──────────────────────────────────────
run_spin() {
    local label="$1"
    shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    local pid

    echo -ne "  ${BRIGHT_CYAN}${frames[0]}${RESET}  ${label} …"

    ("$@" >> "$LOG_FILE" 2>&1) &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r  ${BRIGHT_CYAN}${frames[$i % ${#frames[@]}]}${RESET}  ${label} …"
        i=$(( i + 1 ))
        sleep 0.1
    done

    wait "$pid"
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo -e "\r  ${BRIGHT_GREEN}${BOLD}✔${RESET}  ${label}${RESET}          "
    else
        echo -e "\r  ${BRIGHT_RED}${BOLD}✘${RESET}  ${label} ${DIM}(see $LOG_FILE)${RESET}"
        return $exit_code
    fi
}

# ─── Utility: Run a command silently (no spinner, just logging) ───────────────
run_silent() {
    "$@" >> "$LOG_FILE" 2>&1
}

# ─── Checklist tracker ────────────────────────────────────────────────────────
declare -A COMPLETED

mark_done() { COMPLETED["$1"]=1; }
is_done()   { [[ "${COMPLETED[$1]+_}" ]]; }

# ─── Summary Checklist ────────────────────────────────────────────────────────
print_summary() {
    echo ""
    box "  INSTALLATION SUMMARY  " "$BRIGHT_GREEN"
    echo ""

    local all_steps=(
        "system_update:System Update & Upgrade"
        "usb0:USB0 Ethernet (iPad Connection)"
        "nodejs:Node.js LTS"
        "code_server:Code-Server (VS Code)"
        "vnc:VNC Remote Desktop"
        "zsh:ZSH + Oh My Zsh"
        "cockpit:Cockpit Web UI"
        "firewalld:Firewalld"
        "lazygit:Lazygit"
        "neovim:Neovim (via Snap)"
        "docker:Docker"
        "java:Java JDK 22"
        "miniforge:Miniforge (conda)"
        "tmux:TMUX + TPM"
        "ruby:Ruby + Colorls"
        "rust_cargo:Rust + Cargo tools"
        "luarocks:LuaRocks"
        "motd:Disable MOTD"
    )

    for entry in "${all_steps[@]}"; do
        local key="${entry%%:*}"
        local label="${entry##*:}"
        if is_done "$key"; then
            echo -e "  ${BRIGHT_GREEN}${BOLD}[✔]${RESET} ${label}"
        else
            echo -e "  ${DIM}[ ]${RESET} ${DIM}${label}${RESET}"
        fi
    done

    echo ""
    hr "─" "$DIM$CYAN"
    echo -e "  ${DIM}Full log saved to: ${ITALIC}${LOG_FILE}${RESET}"
    echo ""
}

# ─── Splash Screen ────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BRIGHT_CYAN}${BOLD}"
center "  ██████╗ ██████╗ ██████╗ ███████╗██████╗ ██╗  "
center " ██╔════╝██╔═══██╗██╔══██╗██╔════╝██╔══██╗██║  "
center " ██║     ██║   ██║██║  ██║█████╗  ██████╔╝██║  "
center " ██║     ██║   ██║██║  ██║██╔══╝  ██╔═══╝ ██║  "
center " ╚██████╗╚██████╔╝██████╔╝███████╗██║     ██║  "
center "  ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝     ╚═╝  "
echo -e "${RESET}"
echo ""
center "Raspberry Pi 5 × iPad Pro  —  Development Environment Setup" "$BOLD$WHITE"
center "USB-C Thunderbolt · SSH · VNC · Code-Server · and more" "$DIM$CYAN"
echo ""
hr "═" "$DIM$BLUE"
echo ""
center "Log file: ${LOG_FILE}" "$DIM"
echo ""
echo -e "  ${DIM}This script will guide you through each installation step.${RESET}"
echo -e "  ${DIM}You will be asked before each major component is installed.${RESET}"
echo -e "  ${DIM}Steps that modify system files require${RESET} ${BRIGHT_YELLOW}sudo privileges${RESET}${DIM}.${RESET}"
echo ""

if ! ask "Ready to begin setup?" "y"; then
    echo ""
    warn "Setup cancelled by user."
    exit 0
fi

# ─── Preflight: sudo check ────────────────────────────────────────────────────
echo ""
info "Verifying sudo access …"
if ! sudo -v; then
    error "sudo access is required. Please run as a user with sudo privileges."
    exit 1
fi
success "sudo access confirmed."

# Keep sudo alive throughout the script
( while true; do sudo -v; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; echo ""' EXIT

# ─── OS & Hardware Detection ──────────────────────────────────────────────────
IS_BOOKWORM=false
IS_RPI5=false
USING_NM=false

[[ $(grep -c "12 (bookworm)" /etc/os-release) -gt 0 ]] && IS_BOOKWORM=true
[[ $(grep -c "Raspberry Pi 5" /proc/device-tree/model 2>/dev/null) -gt 0 ]] && IS_RPI5=true
[[ $(systemctl is-active NetworkManager) == "active" ]] && USING_NM=true

info "Environment: RPI5=$IS_RPI5 | Bookworm=$IS_BOOKWORM | NetworkManager=$USING_NM"

# ─── STEP 0: System Update ────────────────────────────────────────────────────
section "0" "System Update & Full Upgrade"

if ask "Update and full-upgrade the system?" "y"; then
    run_spin "apt update"         sudo apt update
    run_spin "apt full-upgrade"   sudo apt full-upgrade -y
    run_spin "apt autoremove"     sudo apt autoremove -y
    mark_done "system_update"
    success "System is up to date."
else
    skip "system update"
fi

# ─── STEP 1: USB0 Ethernet ────────────────────────────────────────────────────
section "1" "USB0 Ethernet Connection to iPad"

echo ""
echo -e "  ${BOLD}${YELLOW}This step requires manual file edits.${RESET}"
echo -e "  ${DIM}The following files need to be configured:${RESET}"
echo -e "  ${BRIGHT_CYAN}  /boot/firmware/config.txt${RESET}   ${DIM}→ add dtoverlay=dwc2,dr_mode=peripheral${RESET}"
echo -e "  ${BRIGHT_CYAN}  /boot/firmware/cmdline.txt${RESET}  ${DIM}→ insert modules-load=dwc2,g_ether before rootwait${RESET}"
if $USING_NM; then
    echo -e "  ${BRIGHT_CYAN}  NetworkManager (usb0)${RESET}     ${DIM}→ static IP 10.55.0.1/24${RESET}"
else
    echo -e "  ${BRIGHT_CYAN}  /etc/network/interfaces.d/usb0${RESET}"
    echo -e "  ${BRIGHT_CYAN}  /etc/dhcpcd.conf${RESET}"
fi
echo -e "  ${BRIGHT_CYAN}  /etc/dnsmasq.d/usb0${RESET}"
echo ""

if ask "Configure USB0 Ethernet files now?" "y"; then

    # ── config.txt ──────────────────────────────────────────────────────────
    step "Patching /boot/firmware/config.txt …"
    CONFIG_TXT="/boot/firmware/config.txt"
    # Ensure /boot/firmware exists, fallback to /boot
    [[ ! -d "/boot/firmware" ]] && CONFIG_TXT="/boot/"
    if ! grep -q "dtoverlay=dwc2,dr_mode=peripheral" "$CONFIG_TXT" 2>/dev/null; then
        echo "" | sudo tee -a "$CONFIG_TXT" > /dev/null
        echo "dtoverlay=dwc2,dr_mode=peripheral" | sudo tee -a "$CONFIG_TXT" > /dev/null
        success "dtoverlay appended to config.txt"
    else
        info "config.txt already contains dtoverlay entry — skipping."
    fi

    # ── cmdline.txt ─────────────────────────────────────────────────────────
    step "Patching /boot/firmware/cmdline.txt …"
    CMDLINE_TXT="/boot/firmware/cmdline.txt"
    [[ ! -d "/boot/firmware" ]] && CMDLINE_TXT="/boot/cmdline.txt"
    if ! grep -q "modules-load=dwc2,g_ether" "$CMDLINE_TXT" 2>/dev/null; then
        sudo sed -i 's/rootwait/modules-load=dwc2,g_ether rootwait/' "$CMDLINE_TXT"
        success "modules-load inserted into cmdline.txt"
    else
        info "cmdline.txt already contains modules-load entry — skipping."
    fi

    # ── USB0 IP Configuration ───────────────────────────────────────────────
    if $USING_NM; then
        step "Configuring usb0 via NetworkManager …"
        # Check if connection already exists
        if ! nmcli con show usb0 >/dev/null 2>&1; then
            sudo nmcli con add type ethernet ifname usb0 con-name usb0 ip4 10.55.0.1/24
            sudo nmcli con mod usb0 ipv4.method manual
            success "Created usb0 connection via NetworkManager"
        else
            info "NetworkManager connection 'usb0' already exists — skipping."
        fi
    else
        # ── /etc/network/interfaces.d/usb0 ──────────────────────────────────────
        step "Creating /etc/network/interfaces.d/usb0 …"
        sudo tee /etc/network/interfaces.d/usb0 > /dev/null <<'EOF'
auto usb0
allow-hotplug usb0
iface usb0 inet static
    address 10.55.0.1
    netmask 255.255.255.0
EOF
        success "Created /etc/network/interfaces.d/usb0"

        # ── /etc/dhcpcd.conf ────────────────────────────────────────────────────
        step "Patching /etc/dhcpcd.conf …"
        if [[ -f /etc/dhcpcd.conf ]]; then
            if ! grep -q "interface usb0" /etc/dhcpcd.conf 2>/dev/null; then
                sudo tee -a /etc/dhcpcd.conf > /dev/null <<'EOF'

interface usb0
static ip_address=10.55.0.1/24
static routers=
static domain_name_servers=
nohook wpa_supplicant
EOF
                success "usb0 static config appended to /etc/dhcpcd.conf"
            else
                info "dhcpcd.conf already has usb0 entry — skipping."
            fi
        else
            info "dhcpcd.conf not found — skipping."
        fi
    fi

    # ── /etc/dnsmasq.d/usb0 ─────────────────────────────────────────────────
    step "Installing dnsmasq …"
    run_spin "apt install dnsmasq" sudo apt install -y dnsmasq

    step "Creating /etc/dnsmasq.d/usb0 …"
    sudo tee /etc/dnsmasq.d/usb0 > /dev/null <<'EOF'
interface=usb0
dhcp-range=10.55.0.2,10.55.0.6,255.255.255.0,1h
dhcp-option=3
leasefile-ro
EOF
    success "Created /etc/dnsmasq.d/usb0"

    mark_done "usb0"
    echo ""
    warn "A reboot is required to activate USB0 Ethernet. You will be prompted at the end."
else
    skip "USB0 Ethernet configuration"
fi

# ─── STEP 2: Node.js LTS ──────────────────────────────────────────────────────
section "2" "Node.js LTS (via NodeSource)"

if ask "Install Node.js LTS?" "y"; then
    run_spin "Fetching NodeSource setup script" \
        bash -c 'curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash -'
    run_spin "Installing nodejs" sudo apt-get install -y nodejs
    mark_done "nodejs"
    NODE_VER=$(node --version 2>/dev/null || echo "unknown")
    success "Node.js installed → ${NODE_VER}"
else
    skip "Node.js"
fi

# ─── STEP 3: Code-Server ──────────────────────────────────────────────────────
section "3" "Code-Server (VS Code in the browser)"

if ask "Install code-server?" "y"; then
    run_spin "Installing code-server" \
        bash -c 'curl -fsSL https://code-server.dev/install.sh | sh'
    mark_done "code_server"
    success "code-server installed."
    info "Start with: systemctl --user enable --now code-server"
    info "Access at:  http://10.55.0.1:8080"
else
    skip "code-server"
fi

# ─── STEP 4: VNC Remote Desktop ───────────────────────────────────────────────
section "4" "VNC Remote Desktop"

echo ""
if $IS_RPI5 || $IS_BOOKWORM; then
    echo -e "  ${BOLD}${YELLOW}RPI5/Bookworm detected: Using Wayland + WayVNC (Recommended)${RESET}"
    echo -e "  ${DIM}RealVNC is not currently supported on RPI5 Wayland.${RESET}"
    echo -e "  ${DIM}This script will ensure WayVNC is enabled.${RESET}"
else
    echo -e "  ${DIM}This step automates RealVNC, but also requires you to run${RESET}"
    echo -e "  ${BRIGHT_YELLOW}  sudo raspi-config${RESET} ${DIM}manually to:${RESET}"
    echo -e "  ${DIM}    • Interface Options > VNC > Enable${RESET}"
    echo -e "  ${DIM}    • Display Options > VNC Resolution > 1024x768${RESET}"
fi
echo ""

if ask "Configure VNC service?" "y"; then
    if $IS_RPI5 || $IS_BOOKWORM; then
        run_spin "Enabling wayvnc (Wayland VNC)" \
            sudo systemctl enable wayvnc.service 2>/dev/null || true
        run_spin "Starting wayvnc (Wayland VNC)" \
            sudo systemctl start wayvnc.service 2>/dev/null || true
        
        # RealVNC is incompatible, ensure it's off to avoid port conflicts
        run_silent sudo systemctl stop vncserver-x11-serviced.service 2>/dev/null || true
        run_silent sudo systemctl disable vncserver-x11-serviced.service 2>/dev/null || true
        
        success "WayVNC service configured for Wayland."
        warn "On RPI5/Bookworm, enable VNC via: sudo raspi-config > Interface Options > VNC"
        warn "This will automatically use WayVNC on Wayland."
    else
        run_spin "Enabling vncserver-x11-serviced" \
            sudo systemctl enable vncserver-x11-serviced.service
        run_spin "Starting vncserver-x11-serviced" \
            sudo systemctl start vncserver-x11-serviced.service
        run_spin "Stopping wayvnc (Wayland VNC)" \
            bash -c 'sudo systemctl stop wayvnc.service 2>/dev/null || true'
        run_spin "Disabling wayvnc (Wayland VNC)" \
            bash -c 'sudo systemctl disable wayvnc.service 2>/dev/null || true'
        success "RealVNC service configured for X11."
        warn "Please run 'sudo raspi-config' manually to enable VNC + X11 + resolution."
        warn "Set VNC password with: sudo vncpasswd -service"
    fi
    mark_done "vnc"
else
    skip "VNC"
fi

# ─── STEP 5: ZSH + Oh My Zsh ─────────────────────────────────────────────────
section "5" "ZSH + Oh My Zsh + Plugins + Pure Prompt"

if ask "Install ZSH, Oh My Zsh, Pure prompt, and plugins?" "y"; then

    run_spin "Installing zsh" sudo apt install -y zsh

    step "Setting ZSH as default shell …"
    if [[ "$SHELL" != "$(which zsh)" ]]; then
        sudo chsh -s "$(which zsh)" "$USER" >> "$LOG_FILE" 2>&1
        success "Default shell set to ZSH (takes effect on next login)"
    else
        info "ZSH is already the default shell."
    fi

    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        run_spin "Installing Oh My Zsh" \
            bash -c 'RUNZSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
    else
        info "Oh My Zsh already installed — skipping."
    fi

    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    if [[ ! -d "$ZSH_CUSTOM/themes/pure" ]]; then
        run_spin "Installing Pure prompt" \
            git clone https://github.com/sindresorhus/pure.git "$ZSH_CUSTOM/themes/pure"
    else
        info "Pure prompt already installed — skipping."
    fi

    if [[ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]]; then
        run_spin "Installing zsh-syntax-highlighting" \
            git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
            "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
    else
        info "zsh-syntax-highlighting already present — skipping."
    fi

    if [[ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]]; then
        run_spin "Installing zsh-autosuggestions" \
            git clone https://github.com/zsh-users/zsh-autosuggestions \
            "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
    else
        info "zsh-autosuggestions already present — skipping."
    fi

    if [[ ! -d "$ZSH_CUSTOM/plugins/zsh-completions" ]]; then
        run_spin "Installing zsh-completions" \
            git clone https://github.com/zsh-users/zsh-completions \
            "$ZSH_CUSTOM/plugins/zsh-completions"
    else
        info "zsh-completions already present — skipping."
    fi

    # Patch .zshrc
    ZSHRC="$HOME/.zshrc"
    step "Patching ~/.zshrc for Pure prompt and plugins …"
    if [[ -f "$ZSHRC" ]]; then
        sed -i 's/^ZSH_THEME=.*/ZSH_THEME=""/' "$ZSHRC"
        if ! grep -q "autoload -U promptinit" "$ZSHRC"; then
            cat >> "$ZSHRC" <<'ZSHEOF'

# Pure Prompt
fpath+=${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/pure
autoload -U promptinit; promptinit
prompt pure
ZSHEOF
        fi
        sed -i 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-completions)/' "$ZSHRC"
        success ".zshrc patched."
    else
        warn ".zshrc not found — manual configuration required."
    fi

    mark_done "zsh"
    success "ZSH environment fully configured."
else
    skip "ZSH + Oh My Zsh"
fi

# ─── STEP 6: Cockpit ──────────────────────────────────────────────────────────
section "6" "Cockpit Web UI"

if ask "Install Cockpit?" "y"; then
    run_spin "Installing cockpit" sudo apt install -y cockpit
    run_spin "Enabling cockpit.socket" sudo systemctl enable --now cockpit.socket
    mark_done "cockpit"
    success "Cockpit installed."
    info "Access at: https://10.55.0.1:9090"

    if ask "Also install Cockpit Navigator (file browser plugin)?" "y"; then
        run_spin "Downloading cockpit-navigator" \
            wget -q -O /tmp/cockpit-navigator.deb \
            https://github.com/45Drives/cockpit-navigator/releases/download/v0.5.10/cockpit-navigator_0.5.10-1focal_all.deb
        run_spin "Installing cockpit-navigator" \
            sudo apt install -y /tmp/cockpit-navigator.deb
        success "Cockpit Navigator installed."
    fi
else
    skip "Cockpit"
fi

# ─── STEP 7: Firewalld ────────────────────────────────────────────────────────
section "7" "Firewalld"

if ask "Install and configure firewalld?" "y"; then
    run_spin "Installing firewalld" sudo apt install -y firewalld

    step "Opening required ports …"
    PORTS=(22 53 631 25 5900 8080 8081 9090 67 5353 51314 40989)
    for port in "${PORTS[@]}"; do
        run_silent sudo firewall-cmd --zone=public --add-port="${port}/tcp" --permanent
        run_silent sudo firewall-cmd --zone=public --add-port="${port}/udp" --permanent
    done
    success "Ports opened: ${PORTS[*]}"

    run_spin "Adding usb0 to public zone" \
        sudo firewall-cmd --zone=public --add-interface=usb0 --permanent
    run_spin "Reloading firewalld" sudo firewall-cmd --reload
    run_spin "Enabling firewalld" sudo systemctl enable --now firewalld

    mark_done "firewalld"
    FSTATE=$(sudo firewall-cmd --state 2>/dev/null || echo "unknown")
    success "firewalld is: ${FSTATE}"
else
    skip "Firewalld"
fi

# ─── STEP 8: Lazygit ──────────────────────────────────────────────────────────
section "8" "Lazygit"

if ask "Install Lazygit?" "y"; then
    LAZYGIT_VER="0.40.2"
    LAZYGIT_TARBALL="lazygit_${LAZYGIT_VER}_Linux_arm64.tar.gz"
    LAZYGIT_URL="https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VER}/${LAZYGIT_TARBALL}"

    run_spin "Downloading Lazygit v${LAZYGIT_VER}" \
        wget -q -O "/tmp/${LAZYGIT_TARBALL}" "$LAZYGIT_URL"
    run_spin "Extracting Lazygit" \
        bash -c "tar -xzf /tmp/${LAZYGIT_TARBALL} -C /tmp"
    run_spin "Installing Lazygit to /usr/local/bin" \
        sudo mv /tmp/lazygit /usr/local/bin/
    mark_done "lazygit"
    LG_VER=$(lazygit --version 2>/dev/null | head -1 || echo "unknown")
    success "Lazygit installed → ${LG_VER}"
else
    skip "Lazygit"
fi

# ─── STEP 9: Neovim (via Snap) ────────────────────────────────────────────────
section "9" "Neovim (via Snap)"

if ask "Install Neovim via Snap?" "y"; then
    run_spin "Installing snapd" sudo apt install -y snapd
    run_spin "Installing snap core" sudo snap install core
    run_spin "Installing nvim (classic)" sudo snap install nvim --classic
    mark_done "neovim"
    NV_VER=$(nvim --version 2>/dev/null | head -1 || echo "unknown")
    success "Neovim installed → ${NV_VER}"
else
    skip "Neovim"
fi

# ─── STEP 10: Docker ──────────────────────────────────────────────────────────
section "10" "Docker"

if ask "Install Docker?" "y"; then
    run_spin "Installing docker.io" sudo apt install -y docker.io
    run_spin "Starting Docker service" sudo systemctl start docker
    run_spin "Enabling Docker service" sudo systemctl enable docker
    run_spin "Adding $USER to docker group" sudo usermod -aG docker "$USER"
    mark_done "docker"
    DOCKER_VER=$(docker --version 2>/dev/null || echo "unknown")
    success "Docker installed → ${DOCKER_VER}"
    warn "Log out and back in (or reboot) for docker group membership to take effect."
else
    skip "Docker"
fi

# ─── STEP 11: Java JDK 22 ────────────────────────────────────────────────────
section "11" "Java JDK 22 (Oracle aarch64)"

if ask "Install Java JDK 22 for aarch64?" "y"; then
    JDK_TARBALL="jdk-22_linux-aarch64_bin.tar.gz"
    JDK_URL="https://download.oracle.com/java/22/latest/${JDK_TARBALL}"

    run_spin "Downloading JDK 22" \
        wget -q -O "/tmp/${JDK_TARBALL}" "$JDK_URL"
    run_spin "Extracting JDK 22" \
        bash -c "tar -xvf /tmp/${JDK_TARBALL} -C /tmp >> $LOG_FILE 2>&1"
    run_spin "Moving JDK to /usr/lib/jvm" \
        bash -c "sudo mkdir -p /usr/lib/jvm && sudo mv /tmp/jdk-22* /usr/lib/jvm/ 2>/dev/null || true"

    JDK_DIR=$(ls -d /usr/lib/jvm/jdk-22* 2>/dev/null | head -1)
    if [[ -n "$JDK_DIR" ]]; then
        step "Setting JAVA_HOME in ~/.zshrc and ~/.bashrc …"
        for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
            if [[ -f "$RC" ]] && ! grep -q "JAVA_HOME" "$RC"; then
                echo "export JAVA_HOME=${JDK_DIR}" >> "$RC"
                echo 'export PATH=$JAVA_HOME/bin:$PATH' >> "$RC"
            fi
        done
        mark_done "java"
        success "Java JDK installed at ${JDK_DIR}"
    else
        error "JDK directory not found after extraction. Check $LOG_FILE for details."
    fi
else
    skip "Java JDK"
fi

# ─── STEP 12: Miniforge ───────────────────────────────────────────────────────
section "12" "Miniforge (conda for aarch64)"

if ask "Install Miniforge?" "y"; then
    MINIFORGE_SCRIPT="Miniforge3-$(uname)-$(uname -m).sh"
    run_spin "Downloading Miniforge installer" \
        curl -L -O "https://github.com/conda-forge/miniforge/releases/latest/download/${MINIFORGE_SCRIPT}"
    run_spin "Running Miniforge installer (batch mode)" \
        bash "$MINIFORGE_SCRIPT" -b -p "$HOME/miniforge3"
    rm -f "$MINIFORGE_SCRIPT"
    mark_done "miniforge"
    success "Miniforge installed at ~/miniforge3"
    info "Initialize with: ~/miniforge3/bin/conda init zsh"
else
    skip "Miniforge"
fi

# ─── STEP 13: TMUX + TPM ─────────────────────────────────────────────────────
section "13" "TMUX + TPM Plugin Manager"

if ask "Install TMUX and TPM?" "y"; then
    run_spin "Installing tmux" sudo apt install -y tmux

    if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
        run_spin "Cloning TPM" \
            git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
    else
        info "TPM already installed — skipping."
    fi

    step "Creating ~/.config/tmux directory …"
    mkdir -p "$HOME/.config/tmux"

    if [[ ! -f "$HOME/.config/tmux/tmux.conf" ]]; then
        cat > "$HOME/.config/tmux/tmux.conf" <<'TMUXEOF'
# codepi default tmux config
set -g default-terminal "screen-256color"
set -g history-limit 10000
set -g mouse on

# TPM plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'

# Initialize TPM (keep at the very bottom)
run '~/.tmux/plugins/tpm/tpm'
TMUXEOF
        success "Created ~/.config/tmux/tmux.conf with defaults."
    else
        info "tmux.conf already exists — skipping creation."
    fi

    mark_done "tmux"
    success "TMUX + TPM installed."
    info "Install plugins inside tmux with: Prefix + I"
else
    skip "TMUX + TPM"
fi

# ─── STEP 14: Ruby + Colorls ──────────────────────────────────────────────────
section "14" "Ruby + Colorls"

if ask "Install Ruby and Colorls?" "y"; then
    run_spin "Installing ruby-full" sudo apt install -y ruby-full
    run_spin "Installing colorls gem" gem install colorls
    mark_done "ruby"
    RUBY_VER=$(ruby --version 2>/dev/null || echo "unknown")
    success "Ruby installed → ${RUBY_VER}"
    success "Colorls installed."
else
    skip "Ruby + Colorls"
fi

# ─── STEP 15: Rust + Cargo Tools ─────────────────────────────────────────────
section "15" "Rust + Cargo Tools"

echo ""
echo -e "  ${DIM}Cargo tools to be installed:${RESET}"
echo -e "  ${BRIGHT_CYAN}  zoxide  fzf  eza  bat  cargo-update  cargo-cache${RESET}"
echo ""

if ask "Install Rust and Cargo tools?" "y"; then
    if ! command -v cargo &>/dev/null; then
        run_spin "Installing Rust via rustup" \
            bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env" 2>/dev/null || true
        export PATH="$HOME/.cargo/bin:$PATH"
    else
        info "Rust/cargo already installed — skipping rustup."
    fi

    CARGO_TOOLS=(zoxide fzf eza bat cargo-update cargo-cache)
    for tool in "${CARGO_TOOLS[@]}"; do
        run_spin "cargo install ${tool}" cargo install "$tool" || warn "Failed to install $tool — check $LOG_FILE"
    done

    # Remove apt fzf to avoid conflict
    if dpkg -l fzf &>/dev/null 2>&1; then
        run_spin "Removing apt fzf (replaced by cargo fzf)" sudo apt remove -y fzf
    fi

    # fd symlink
    if command -v fdfind &>/dev/null && [[ ! -L /usr/local/bin/fd ]]; then
        run_spin "Creating fd symlink → fdfind" \
            sudo ln -s "$(which fdfind)" /usr/local/bin/fd
    fi

    mark_done "rust_cargo"
    RUSTC_VER=$(rustc --version 2>/dev/null || echo "unknown")
    success "Rust installed → ${RUSTC_VER}"
    success "Cargo tools installed."
else
    skip "Rust + Cargo tools"
fi

# ─── STEP 16: LuaRocks ───────────────────────────────────────────────────────
section "16" "LuaRocks"

if ask "Install LuaRocks?" "y"; then
    run_spin "Installing luarocks" sudo apt install -y luarocks
    mark_done "luarocks"
    LR_VER=$(luarocks --version 2>/dev/null | head -1 || echo "unknown")
    success "LuaRocks installed → ${LR_VER}"
else
    skip "LuaRocks"
fi

# ─── STEP 17: Disable MOTD ───────────────────────────────────────────────────
section "17" "Disable MOTD"

if ask "Disable the Message of the Day (MOTD)?" "y"; then
    if [[ -f /etc/motd ]]; then
        run_spin "Moving /etc/motd → /etc/motdDisabled" \
            sudo mv /etc/motd /etc/motdDisabled
        mark_done "motd"
        success "MOTD disabled."
    else
        info "/etc/motd not found (may already be disabled)."
        mark_done "motd"
    fi
else
    skip "Disable MOTD"
fi

# ─── STEP 18: Optional apt packages ──────────────────────────────────────────
section "18" "Optional APT Packages (delta, thefuck)"

echo ""
echo -e "  ${DIM}delta  — better git diff pager${RESET}"
echo -e "  ${DIM}thefuck — correct previous commands${RESET}"
echo ""

if ask "Install optional packages (delta, thefuck)?" "n"; then
    run_spin "Installing delta" sudo apt install -y delta || warn "delta failed to install."
    run_spin "Installing thefuck" sudo apt install -y thefuck || warn "thefuck failed to install."
    success "Optional packages installed."
else
    skip "Optional packages"
fi

# ─── FINAL SUMMARY ───────────────────────────────────────────────────────────
echo ""
echo ""
hr "═" "$BRIGHT_GREEN"
print_summary
hr "═" "$BRIGHT_GREEN"
echo ""
info "To uninstall, run: ./uninstall.sh"
echo ""

# ─── Reboot prompt ────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BRIGHT_YELLOW}${BOLD}A system reboot is recommended to apply all changes.${RESET}"
echo -e "  ${DIM}(Required for: USB0 Ethernet, Docker group, new default shell)${RESET}"
echo ""

if ask "Reboot now?" "y"; then
    echo ""
    success "Rebooting in 3 seconds …"
    sleep 3
    sudo reboot
else
    echo ""
    success "All done! Reboot when you're ready."
    echo ""
    echo -e "  ${DIM}When reconnecting via SSH after reboot, connect to:${RESET}"
    echo -e "  ${BRIGHT_CYAN}  ssh $USER@10.55.0.1${RESET}  ${DIM}(over USB-C Ethernet)${RESET}"
    echo ""
fi
