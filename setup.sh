#!/bin/bash

# ==================================================================================================
#   Author:         Chaz Trickey
#   Description:    Initial update for Ubuntu 24.04 LTS and install docker if needed.
#                   Improved version with better error handling and Ubuntu 24.04 optimizations
#
#   Usage:          Create new script file using " nano setup.sh ". Then run the following
#                   Command to run the sh script using bash.
#
#   Command:        sudo bash ./setup.sh
#                   curl -fsSL    | bash
#
#   Bonus:          If you want to copy your ssh key over...
#                   First Create keypair if you haven't already...
#
#                   ssh-keygen -t rsa -b 4096
#
#                   Then Copy public key over to SSH server.
#
#                   ssh-copy-id -i ~/.ssh/id_rsa.pub chaz@            -- add host IP at end
#
#                   Windows type .\.ssh\id_rsa.pub | ssh user@host "cat >> .ssh/authorized_keys"     --if you are already in %USERPROFILE%
# ==================================================================================================

# Script configuration
SCRIPT_VERSION="2.1"
LOG_FILE="/var/log/ubuntu-setup-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/root/setup-backups-$(date +%Y%m%d-%H%M%S)"

# State tracking for idempotent sections
STATE_FILE="/var/log/ubuntu-setup.state"
touch "$STATE_FILE"

set_state() {
    local key="$1"
    local value="$2"
    sed -i "/^${key}=/d" "$STATE_FILE" 2>/dev/null || true
    echo "${key}=${value}" >> "$STATE_FILE"
    log "State updated: ${key}=${value}"
}

get_state() {
    local key="$1"
    local value
    value=$(grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)
    echo "$value"
}

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function with color support
log() {
    local level="${2:-INFO}"
    local timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"

    case $level in
        "ERROR")   echo -e "${RED}${timestamp} ERROR: $1${NC}" | tee -a "$LOG_FILE" ;;
        "WARNING") echo -e "${YELLOW}${timestamp} WARNING: $1${NC}" | tee -a "$LOG_FILE" ;;
        "SUCCESS") echo -e "${GREEN}${timestamp} SUCCESS: $1${NC}" | tee -a "$LOG_FILE" ;;
        *)         echo -e "${timestamp} $1" | tee -a "$LOG_FILE" ;;
    esac
}

# Error handling function
handle_error() {
    log "$1" "ERROR"
    echo -e "${RED}Error occurred. Check log file: $LOG_FILE${NC}"
    exit 1
}

# Create backup directory
create_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    log "Backup directory created: $BACKUP_DIR"
}

# Backup important files before modification
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp "$file" "$BACKUP_DIR/$(basename "$file").backup" 2>/dev/null
        log "Backed up $file to $BACKUP_DIR"
    fi
}

# Check if running in container (Docker/LXC)
check_container_environment() {
    if [[ -f /.dockerenv ]] || grep -q "lxc\|docker" /proc/1/cgroup 2>/dev/null; then
        log "Container environment detected" "WARNING"
        read -p "Running in a container may affect some features. Continue anyway? (y/n) " continue_container
        if [[ ! $continue_container =~ ^[Yy]$ ]]; then
            log "User chose to exit due to container environment"
            exit 1
        fi
    fi
}

# Enhanced reboot check with better handling
fnRebootCheck(){
    # Check if a Reboot is needed
    if [ -f /var/run/reboot-required ]; then
        log 'Reboot required detected' "WARNING"
        if [[ -f /var/run/reboot-required.pkgs ]]; then
            log "Packages requiring reboot: $(tr '\n' ' ' < /var/run/reboot-required.pkgs)"
        fi

        read -p "Do you want to reboot before continuing setup script... (y/n) " start_reboot
        if [[ $start_reboot =~ ^[Yy]$ ]]; then
            log "User chose to reboot. Rebooting now..."
            echo "CONTINUE_FROM=post_reboot" > /tmp/setup_continue
            sudo reboot
        fi
    fi
}

# Improved version check with support for newer versions
fnCheckUbuntuVersion(){
    # Verify we're running on Ubuntu
    if ! command -v lsb_release &> /dev/null; then
        apt update && apt install -y lsb-release
    fi

    UBUNTU_VERSION=$(lsb_release -rs)
    UBUNTU_CODENAME=$(lsb_release -cs)
    UBUNTU_ID=$(lsb_release -is)

    log "Detected $UBUNTU_ID $UBUNTU_VERSION ($UBUNTU_CODENAME)"

    # Check if it's Ubuntu
    if [[ "$UBUNTU_ID" != "Ubuntu" ]]; then
        log "This script is designed for Ubuntu. Detected: $UBUNTU_ID" "WARNING"
        read -p "Do you want to continue anyway? (y/n) " continue_anyway
        if [[ ! $continue_anyway =~ ^[Yy]$ ]]; then
            log "User chose to exit due to OS mismatch"
            exit 1
        fi
    fi

    # Version compatibility check - support Ubuntu 20.04 and newer
    local version_num
    version_num=$(echo "$UBUNTU_VERSION" | cut -d. -f1)
    if [[ $version_num -lt 20 ]]; then
        log "Ubuntu version $UBUNTU_VERSION may not be fully supported (minimum recommended: 20.04)" "WARNING"
        read -p "Do you want to continue anyway? (y/n) " continue_anyway
        if [[ ! $continue_anyway =~ ^[Yy]$ ]]; then
            log "User chose to exit due to version compatibility"
            exit 1
        fi
    elif [[ $version_num -ge 25 ]]; then
        log "Ubuntu $UBUNTU_VERSION detected - script tested up to 25.04" "SUCCESS"
    fi
}

# Enhanced needrestart configuration
fnConfigureNeedrestart(){
    if [ ! -f /etc/needrestart/conf.d/no-prompt.conf ]; then
        log "Configuring needrestart to avoid interactive prompts"
        mkdir -p /etc/needrestart/conf.d/
        backup_file "/etc/needrestart/needrestart.conf"

        cat > /etc/needrestart/conf.d/no-prompt.conf << 'EOF'
# Restart services automatically
$nrconf{restart} = 'a';

# Don't ask about kernel upgrades
$nrconf{kernelhints} = 0;
EOF

        log "Needrestart configured successfully" "SUCCESS"
    fi
}

# Enhanced package installation with retry logic
fnInstallEssentials(){
    log "Installing essential packages..."

    local retries=3
    for ((i=1; i<=retries; i++)); do
        if apt update; then
            break
        else
            log "Package list update failed (attempt $i/$retries)" "WARNING"
            if [[ $i -eq $retries ]]; then
                handle_error "Failed to update package lists after $retries attempts"
            fi
            sleep 5
        fi
    done

    local essential_packages=(
        "curl" "wget" "ca-certificates" "lsb-release"
        "software-properties-common" "apt-transport-https"
        "gnupg" "gpg-agent" "unattended-upgrades"
    )

    for package in "${essential_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            log "Installing $package..."
            if apt install -y "$package"; then
                log "$package installed successfully" "SUCCESS"
            else
                log "Failed to install $package" "WARNING"
            fi
        else
            log "$package already installed"
        fi
    done
}

# Configure automatic security updates (state-aware)
configure_unattended_upgrades() {
    local section="AUTO_UPDATES"
    local state
    state="$(get_state "$section")"

    if [[ "$state" == "success" ]]; then
        log "Skipping automatic security updates; already configured successfully" "INFO"
        return 0
    fi

    read -p "Do you want to enable automatic security updates? (Y/n) " auto_updates
    if [[ $auto_updates =~ ^[Nn]$ ]]; then
        log "User chose not to enable automatic security updates"
        set_state "$section" "skipped"
        return 0
    fi

    log "Configuring automatic security updates..."
    backup_file "/etc/apt/apt.conf.d/50unattended-upgrades"

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::DevRelease "auto";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

    if systemctl enable unattended-upgrades; then
        log "Automatic security updates configured" "SUCCESS"
        set_state "$section" "success"
    else
        log "Failed to enable unattended-upgrades service" "WARNING"
        set_state "$section" "failure"
    fi
}

# Enhanced SSH security configuration (state-aware)
configure_ssh_security() {
    local section="SSH_HARDENING"
    local state
    state="$(get_state "$section")"

    if [[ "$state" == "success" ]]; then
        log "Skipping SSH hardening; already completed successfully" "INFO"
        return 0
    fi

    read -p "Do you want to harden SSH configuration? (y/n) " harden_ssh
    if [[ ! $harden_ssh =~ ^[Yy]$ ]]; then
        log "User skipped SSH hardening"
        set_state "$section" "skipped"
        return 0
    fi

    log "Hardening SSH configuration..."
    backup_file "/etc/ssh/sshd_config"

    cat >> /etc/ssh/sshd_config << 'EOF'

# Added by Ubuntu Setup Script
Protocol 2
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxStartups 2
EOF

    if sshd -t; then
        systemctl reload sshd
        log "SSH security hardening completed" "SUCCESS"
        set_state "$section" "success"
    else
        log "SSH configuration test failed, reverting changes" "ERROR"
        cp "$BACKUP_DIR/sshd_config.backup" /etc/ssh/sshd_config
        systemctl reload sshd
        set_state "$section" "failure"
    fi
}

# Enhanced firewall setup (state-aware)
configure_firewall() {
    local section="FIREWALL"
    local state
    state="$(get_state "$section")"

    if [[ "$state" == "success" ]]; then
        log "Skipping UFW configuration; already completed successfully" "INFO"
        return 0
    fi

    read -p "Do you want to configure UFW firewall? (y/n) " config_firewall
    if [[ ! $config_firewall =~ ^[Yy]$ ]]; then
        log "User skipped firewall configuration"
        set_state "$section" "skipped"
        return 0
    fi

    log "Configuring UFW firewall..."

    if ! command -v ufw &> /dev/null; then
        apt install -y ufw
    fi

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh

    read -p "Do you want to allow HTTP (port 80)? (y/n) " allow_http
    [[ $allow_http =~ ^[Yy]$ ]] && ufw allow 80

    read -p "Do you want to allow HTTPS (port 443)? (y/n) " allow_https
    [[ $allow_https =~ ^[Yy]$ ]] && ufw allow 443

    ufw --force enable
    log "UFW firewall configured and enabled" "SUCCESS"
    ufw status verbose
    set_state "$section" "success"
}

# System performance tuning (state-aware)
optimize_system_performance() {
    local section="PERF_OPTIMIZE"
    local state
    state="$(get_state "$section")"

    if [[ "$state" == "success" ]]; then
        log "Skipping performance optimizations; already applied" "INFO"
        return 0
    fi

    read -p "Do you want to apply basic system performance optimizations? (y/n) " optimize_perf
    if [[ ! $optimize_perf =~ ^[Yy]$ ]]; then
        log "User skipped performance optimizations"
        set_state "$section" "skipped"
        return 0
    fi

    log "Applying system performance optimizations..."

    echo 'vm.swappiness=10' >> /etc/sysctl.conf

    cat >> /etc/sysctl.conf << 'EOF'
# Network optimizations added by setup script
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
EOF

    if sysctl -p; then
        log "System performance optimizations applied" "SUCCESS"
        set_state "$section" "success"
    else
        log "Failed to apply sysctl settings" "WARNING"
        set_state "$section" "failure"
    fi
}

# Cleanup function
cleanup_system() {
    log "Performing system cleanup..."

    apt autoremove -y
    apt autoclean

    journalctl --vacuum-time=30d

    find /tmp -type f -atime +7 -delete 2>/dev/null || true

    log "System cleanup completed" "SUCCESS"
}

# Display script header
clear
echo -e "${BLUE}======================================================================================================${NC}"
echo -e "${BLUE}  Ubuntu Server Setup Script v$SCRIPT_VERSION${NC}"
echo -e "${BLUE}  Author: Chaz Trickey${NC}"
echo -e "${BLUE}  Compatible with Ubuntu 20.04+ (tested up to 25.04)${NC}"
echo -e "${BLUE}  Log file: $LOG_FILE${NC}"
echo -e "${BLUE}======================================================================================================${NC}"

# Check for continuation from reboot
if [[ -f /tmp/setup_continue ]]; then
    # shellcheck disable=SC1091
    source /tmp/setup_continue
    rm -f /tmp/setup_continue
    if [[ "$CONTINUE_FROM" == "post_reboot" ]]; then
        log "Continuing setup after reboot"
    fi
fi

# Pre-flight checks
check_container_environment
fnCheckUbuntuVersion

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}$0 is not running as root. Try using sudo.${NC}"
    exit 2
fi

log "Starting Ubuntu server setup script"

# Create backup directory
create_backup_dir

# Configure needrestart early
fnConfigureNeedrestart

# Install essential packages
fnInstallEssentials

# Configure automatic security updates (state-aware wrapper already prompts)
configure_unattended_upgrades

# Initial reboot check
fnRebootCheck

pacman=apt

# Ask if the user wants to install Nala (state-aware)
install_nala_section="NALA_INSTALL"
nala_state="$(get_state "$install_nala_section")"
if [[ "$nala_state" == "success" ]]; then
    log "Skipping Nala installation; already completed successfully" "INFO"
else
    read -p "Do you want to install Nala? This is an alternative to apt with better visual package install experience... (Y/n) " install_nala
    if [[ $install_nala =~ ^[Nn]$ ]]; then
        log "User skipped Nala installation"
        set_state "$install_nala_section" "skipped"
    else
        log "Checking Nala installation conditions..."

        # Check if nala is installed
        if dpkg -s nala >/dev/null 2>&1; then
            echo "Nala is already installed."
        else
            echo "Nala is not installed. Installing now..."
            sudo apt update
            sudo apt install -y nala
            if dpkg -s nala >/dev/null 2>&1; then
                echo "Nala has been successfully installed."
                pacman=nala
            else
                echo "Error: Failed to install nala."
                exit 1
            fi
        fi
    fi
fi

# Run system updates
log "Running system updates..."
if $pacman update && $pacman upgrade -y; then
    log "System updates completed successfully" "SUCCESS"
else
    handle_error "System update failed"
fi

# Install system monitoring and utility tools
log "Installing system monitoring and utility tools..."
additional_tools=(
    "htop" "tree" "unzip" "zip" "git" "vim" "nano"
    "ncdu" "tmux" "screen" "rsync" "iotop" "nethogs"
    "curl" "wget" "jq" "bc" "dialog"
)

for tool in "${additional_tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        $pacman install -y "$tool" || log "Warning: Failed to install $tool" "WARNING"
    fi
done

# Install Neofetch with fallback
log "Installing system information tools..."
if ! $pacman install -y neofetch; then
    log "Neofetch not available in repos, trying alternative installation" "WARNING"
    if command -v snap &> /dev/null; then
        snap install neofetch || log "Failed to install neofetch via snap" "WARNING"
    fi
fi

# Install Duf (disk usage utility)
$pacman install -y duf || log "Warning: Failed to install Duf" "WARNING"

# Set timezone
log "Setting timezone to America/Chicago"
timedatectl set-timezone America/Chicago || log "Warning: Failed to set timezone" "WARNING"

# Configure login display (state-aware)
bashrc_section="LOGIN_DISPLAY"
bashrc_state="$(get_state "$bashrc_section")"
if [[ "$bashrc_state" == "success" ]]; then
    log "Skipping login display configuration; already completed successfully" "INFO"
else
    read -p "Do you want to update the login configuration to include system information? (y/n) " config_bashrc
    if [[ $config_bashrc =~ ^[Yy]$ ]]; then
        backup_file "/etc/bash.bashrc"

        # Inject color codes near the top of bash.bashrc (after line 2)
        if ! grep -q "# Color codes for output" /etc/bash.bashrc; then
            sed -i '2a\
\
# Color codes for output\
RED='"'"'\\e[0;31m'"'"'\
GREEN='"'"'\\e[0;32m'"'"'\
YELLOW='"'"'\\e[0;33m'"'"'\
BLUE='"'"'\\e[0;34m'"'"'\
MAGENTA='"'"'\\e[0;35m'"'"'\
CYAN='"'"'\\e[0;36m'"'"'\
WHITE='"'"'\\e[0;37m'"'"'\
BLACK='"'"'\\e[0;30m'"'"'\
GRAY='"'"'\\e[0;90m'"'"'\
BRIGHT_RED='"'"'\\e[0;91m'"'"'\
BRIGHT_GREEN='"'"'\\e[0;92m'"'"'\
BRIGHT_YELLOW='"'"'\\e[0;93m'"'"'\
BRIGHT_BLUE='"'"'\\e[0;94m'"'"'\
BRIGHT_MAGENTA='"'"'\\e[0;95m'"'"'\
BRIGHT_CYAN='"'"'\\e[0;96m'"'"'\
BRIGHT_WHITE='"'"'\\e[0;97m'"'"'\
NC='"'"'\\e[0m'"'"' # No Color' /etc/bash.bashrc
            log "Color codes added to /etc/bash.bashrc" "SUCCESS"
        else
            log "Color codes already present in /etc/bash.bashrc, skipping" "INFO"
        fi
 
        # Append the login display block
        cat >> /etc/bash.bashrc << 'EOF'

# Ubuntu Setup Script - Login Display Configuration
# Run system information display for interactive shells only
if [[ $- == *i* ]] && [ "$PS1" ]; then
    echo -e "${RED}====${GREEN}====${YELLOW}====${MAGENTA}====${BLUE}====${CYAN}====${WHITE}====${RED}====${GREEN}====${YELLOW}====${MAGENTA}====${BLUE}====${CYAN}====${WHITE}====${RED}====${GREEN}====${YELLOW}====${MAGENTA}====${BLUE}====${CYAN}====${WHITE}====${RED}====${GREEN}====${YELLOW}====${MAGENTA}====${BLUE}====${CYAN}====${WHITE}====${NC}"
    if command -v neofetch &> /dev/null; then
        neofetch
    else
        echo "System: $(lsb_release -d -s 2>/dev/null || echo "Unknown")"
        echo "Kernel: $(uname -r)"
        echo "Uptime: $(uptime -p 2>/dev/null || echo "Unknown")"
    fi
    echo -e "${RED}── ${BLUE}IP Address Info${RED} ───────────────────────────────────────────────────────${NC}"
    # Local IPs (all active interfaces, skipping loopback)
    echo -e "${CYAN}  Network Interfaces:${NC}"
    ip -4 addr show | awk '
        /^[0-9]+:/ { iface = $2; gsub(/:/, "", iface) }
        /inet / && iface != "lo" {
            print $2
        }
    ' | while IFS= read -r ip; do
        echo -e "    ${MAGENTA}$(printf "%-14s" "Local IP:")${GREEN}${ip}${NC}"
    done
    # Public IP (with timeout so it doesn't hang on no-internet servers)
    PUBLIC_IP=$(curl -sf --max-time 3 https://api.ipify.org 2>/dev/null)
    if [ -n "$PUBLIC_IP" ]; then
        echo -e "${MAGENTA}    Public IP   ${GREEN}  ${PUBLIC_IP}${NC}"
    else
        echo -e "${MAGENTA}    Public IP   ${YELLOW} Unavailable${NC}"
    fi
    echo -e "${RED}──────────────────────────────────────────────────────────────────────────${NC}"
    # Use DUF to display volume information.
    if command -v duf &> /dev/null; then
        duf --only local 2>/dev/null || true
    fi
    echo -e "${RED}====${GREEN}====${YELLOW}====${MAGENTA}====${BLUE}====${CYAN}====${WHITE}====${RED}====${GREEN}====${YELLOW}====${MAGENTA}====${BLUE}====${CYAN}====${WHITE}====${RED}====${GREEN}====${YELLOW}====${MAGENTA}====${BLUE}====${CYAN}====${WHITE}====${RED}====${GREEN}====${YELLOW}====${MAGENTA}====${BLUE}====${CYAN}====${WHITE}====${NC}"

 fi
EOF

        log "Login display configuration completed" "SUCCESS"
        set_state "$bashrc_section" "success"
    else
        log "User skipped login display configuration"
        set_state "$bashrc_section" "skipped"
    fi
fi

# Configure SSH security (state-aware)
configure_ssh_security

# Configure firewall (state-aware)
configure_firewall

# Install and configure Proxmox guest agent (state-aware)
guestagent_section="PROXMOX_AGENT"
guestagent_state="$(get_state "$guestagent_section")"
if [[ "$guestagent_state" == "success" ]]; then
    log "Skipping Proxmox guest agent; already installed" "INFO"
else
    read -p "Is this server running on ProxMox? If so, install and configure the Proxmox Guest Agent service. (y/n) " install_guestagent
    if [[ $install_guestagent =~ ^[Yy]$ ]]; then
        log "Installing and configuring Proxmox Guest Agent"
        if $pacman install qemu-guest-agent -y; then
            systemctl start qemu-guest-agent
            systemctl enable qemu-guest-agent
            log "Proxmox Guest Agent installed and enabled" "SUCCESS"
            set_state "$guestagent_section" "success"
            fnRebootCheck
        else
            log "Failed to install Proxmox Guest Agent" "WARNING"
            set_state "$guestagent_section" "failure"
        fi
    else
        log "User skipped Proxmox guest agent installation"
        set_state "$guestagent_section" "skipped"
    fi
fi

# Enhanced Fail2ban configuration (state-aware)
fail2ban_section="FAIL2BAN"
fail2ban_state="$(get_state "$fail2ban_section")"
if [[ "$fail2ban_state" == "success" ]]; then
    log "Skipping Fail2ban; already installed and configured" "INFO"
else
    read -p "Do you want to install Fail2ban? This is a daemon that will ban IP addresses with continuous failed logins... (y/n) " install_fail2ban
    if [[ $install_fail2ban =~ ^[Yy]$ ]]; then
        log "Installing Fail2ban"
        if $pacman install fail2ban -y; then
            systemctl enable fail2ban
            systemctl start fail2ban

            backup_file "/etc/fail2ban/jail.conf"
            cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
# Ban settings
bantime = 1h
findtime = 10m
maxretry = 5
banaction = iptables-multiport
protocol = tcp
chain = INPUT
action_ = %(banaction)s[name=%(__name__)s, port="%(port)s", protocol="%(protocol)s", chain="%(chain)s"]
action_mw = %(banaction)s[name=%(__name__)s, port="%(port)s", protocol="%(protocol)s", chain="%(chain)s"]
action_mwl = %(banaction)s[name=%(__name__)s, port="%(port)s", protocol="%(protocol)s", chain="%(chain)s"]
action = %(action_)s

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h

[apache-auth]
enabled = false

[apache-badbots]
enabled = false

[apache-noscript]
enabled = false

[apache-overflows]
enabled = false

[nginx-http-auth]
enabled = false
EOF

            systemctl restart fail2ban
            log "Fail2ban installed and configured" "SUCCESS"
            set_state "$fail2ban_section" "success"
            fnRebootCheck
        else
            log "Failed to install Fail2ban" "WARNING"
            set_state "$fail2ban_section" "failure"
        fi
    else
        log "User skipped Fail2ban installation"
        set_state "$fail2ban_section" "skipped"
    fi
fi

# Docker installation (state-aware)
docker_section="DOCKER_INSTALL"
docker_state="$(get_state "$docker_section")"
if [[ "$docker_state" == "success" ]]; then
    log "Skipping Docker installation; already completed successfully" "INFO"
else
    read -p "Do you want to install Docker? (y/n) " install_docker
    if [[ $install_docker =~ ^[Yy]$ ]]; then
        log "Starting Docker installation process"

        read -p "Do you want to uninstall unofficial Docker packages? (y/n) " uninstall_unof
        if [[ $uninstall_unof =~ ^[Yy]$ ]]; then
            log "Removing unofficial Docker packages"
            for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
                apt-get remove "$pkg" -y 2>/dev/null || true
            done
            log "Unofficial Docker packages removal completed"
        fi

        read -p "Would you like to set up Docker's official apt repository? (y/n) " setup_rep
        if [[ $setup_rep =~ ^[Yy]$ ]]; then
            log "Setting up Docker's official repository"

            $pacman update
            $pacman install -y ca-certificates curl || handle_error "Failed to install Docker prerequisites"

            install -m 0755 -d /etc/apt/keyrings
            if curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; then
                chmod a+r /etc/apt/keyrings/docker.asc
                log "Docker GPG key added successfully" "SUCCESS"
            else
                handle_error "Failed to download Docker GPG key"
            fi

            local_docker_codename="$UBUNTU_CODENAME"
            case "$UBUNTU_CODENAME" in
                "plucky"|"oracular"|"noble") local_docker_codename="noble" ;;
                "mantic") local_docker_codename="jammy" ;;
            esac

            echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$local_docker_codename stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

            log "Docker repository added to sources"

            if $pacman update; then
                log "Package lists updated successfully" "SUCCESS"
            else
                handle_error "Failed to update package lists after adding Docker repository"
            fi

            fnRebootCheck
        fi

        log "Installing Docker Engine and components"
        if $pacman install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
            log "Docker installed successfully" "SUCCESS"

            systemctl start docker
            systemctl enable docker
            log "Docker service started and enabled" "SUCCESS"

            if [ "$SUDO_USER" ]; then
                usermod -aG docker "$SUDO_USER"
                log "Added $SUDO_USER to docker group" "SUCCESS"
                echo -e "${YELLOW}Note: $SUDO_USER will need to log out and back in for docker group membership to take effect${NC}"
            fi

            set_state "$docker_section" "success"
            fnRebootCheck
        else
            handle_error "Failed to install Docker packages"
            set_state "$docker_section" "failure"
        fi

        read -p "Do you want to test Docker by running hello-world? (y/n) " install_hello
        if [[ $install_hello =~ ^[Yy]$ ]]; then
            log "Testing Docker installation"
            if timeout 30 docker run --rm hello-world; then
                log "Docker test successful" "SUCCESS"
            else
                log "Docker test failed or timed out" "WARNING"
            fi
        fi

        portainer_section="PORTAINER"
        portainer_state="$(get_state "$portainer_section")"
        if [[ "$portainer_state" == "success" ]]; then
            log "Skipping Portainer installation; already completed successfully" "INFO"
        else
            read -p "Do you want to install Portainer for Docker management? (y/n) " install_portainer
            if [[ $install_portainer =~ ^[Yy]$ ]]; then
                log "Installing Portainer"
                if docker volume create portainer_data; then
                    if docker run -d -p 8000:8000 -p 9443:9443 --name=portainer --restart=always \
                        -v /var/run/docker.sock:/var/run/docker.sock \
                        -v portainer_data:/data \
                        portainer/portainer-ce:latest; then
                        log "Portainer installed successfully" "SUCCESS"
                        echo -e "${GREEN}Portainer is now running!${NC}"
                        echo -e "${GREEN}Access it at: https://$(hostname -I | awk '{print $1}'):9443${NC}"
                        echo -e "${GREEN}Or: https://your-server-ip:9443${NC}"
                        set_state "$portainer_section" "success"
                    else
                        log "Failed to start Portainer container" "WARNING"
                        set_state "$portainer_section" "failure"
                    fi
                else
                    log "Failed to create Portainer volume" "WARNING"
                    set_state "$portainer_section" "failure"
                fi
                fnRebootCheck
            else
                log "User skipped Portainer installation"
                set_state "$portainer_section" "skipped"
            fi
        fi
    else
        log "User skipped Docker installation"
        set_state "$docker_section" "skipped"
    fi
fi

# Configure system aliases (state-aware)
aliases_section="ALIASES_CONFIG"
aliases_state="$(get_state "$aliases_section")"
if [[ "$aliases_state" == "success" ]]; then
    log "Skipping system aliases; already configured" "INFO"
else
    read -p "Do you want to configure useful system aliases? (y/n) " config_aliases
    if [[ $config_aliases =~ ^[Yy]$ ]]; then
        log "Configuring system aliases"

        ALIASES_FILE="/etc/bash.aliases"
        backup_file "$ALIASES_FILE"

        cat > "$ALIASES_FILE" <<'EOF'
# ====================================================================================================
# Ubuntu Setup Script - System Aliases Configuration
# ====================================================================================================
#
# This file contains custom aliases that are loaded for all users.
# Aliases are shortcuts that replace longer commands with shorter ones.
#
# HOW TO ADD NEW ALIASES:
# -----------------------
# 1. Add a new line in this format: alias shortcut='full command'
# 2. Example: alias ll='ls -alF'
# 3. Save the file and run: source /etc/bash.bashrc (or restart terminal)
#
# HOW TO REMOVE ALIASES:
# ----------------------
# 1. Comment out the line by adding # at the beginning
# 2. Or delete the entire line
# 3. Save the file and run: source /etc/bash.bashrc (or restart terminal)
#
# HOW TO VIEW ALL ACTIVE ALIASES:
# -------------------------------
# Run the command: alias
#
# HOW TO TEMPORARILY DISABLE AN ALIAS:
# ------------------------------------
# Use backslash before the command: \ls (runs original ls instead of alias)
#
# NOTES:
# ------
# - Aliases only work in interactive shells (not in scripts)
# - Use single quotes to prevent variable expansion in alias definition
# - For complex commands, consider creating functions instead of aliases
# ====================================================================================================

# File and Directory Operations
alias ls='ls -al --color=auto'
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'

# Directory Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias -- -='cd -'

# System Information
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ps='ps auxf'
alias psg='ps aux | grep -v grep | grep -i -e VSZ -e'

# System Monitoring
alias top='htop'
alias iotop='sudo iotop'
alias nethogs='sudo nethogs'

# File Operations
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias mkdir='mkdir -pv'

# Text Processing
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Network
alias ping='ping -c 5'
alias wget='wget -c'
alias curl='curl -L'

# Package Management (Ubuntu specific)
alias apt-update='sudo apt update && sudo apt upgrade'
alias apt-search='apt search'
alias apt-install='sudo apt install'
alias apt-remove='sudo apt remove'
alias apt-autoremove='sudo apt autoremove'

# Docker aliases (if Docker is installed)
alias docker-ps='docker ps -a'
alias docker-images='docker images'
alias docker-clean='docker system prune -f'
alias docker-stop-all='docker stop $(docker ps -q)'

# Git aliases (if Git is installed)
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline'

# System Services
alias systemctl='sudo systemctl'
alias journalctl='sudo journalctl'
alias service='sudo service'

# Useful shortcuts
alias h='history'
alias j='jobs -l'
alias path='echo -e ${PATH//:/\\n}'
alias now='date +"%T"'
alias nowtime=now
alias nowdate='date +"%d-%m-%Y"'

# Safety aliases
alias chown='chown --preserve-root'
alias chmod='chmod --preserve-root'
alias chgrp='chgrp --preserve-root'

# Fun aliases
alias please='sudo'
alias fucking='sudo'
alias weather='curl wttr.in'

# Custom aliases - Add your personal aliases below this line
# ====================================================================================================
# Example: alias myserver='ssh user@myserver.com'
# Example: alias backup='rsync -av /home/user/ /backup/location/'
# Example: alias logs='tail -f /var/log/syslog'
EOF

        if ! grep -q "source /etc/bash.aliases" /etc/bash.bashrc; then
            {
                echo ""
                echo "# Load custom aliases"
                echo "if [ -f /etc/bash.aliases ]; then"
                echo "    source /etc/bash.aliases"
                echo "fi"
            } >> /etc/bash.bashrc
            log "Added aliases source to /etc/bash.bashrc" "SUCCESS"
        fi

        if [ -d /etc/skel ]; then
            if ! grep -q "source /etc/bash.aliases" /etc/skel/.bashrc 2>/dev/null; then
                {
                    echo ""
                    echo "# Load custom aliases"
                    echo "if [ -f /etc/bash.aliases ]; then"
                    echo "    source /etc/bash.aliases"
                    echo "fi"
                } >> /etc/skel/.bashrc
                log "Added aliases source to /etc/skel/.bashrc for new users" "SUCCESS"
            fi
        fi

        log "System aliases configured successfully" "SUCCESS"
        echo ""
        echo -e "${GREEN}Aliases have been configured and saved to: $ALIASES_FILE${NC}"
        echo -e "${GREEN}To see all available aliases, run: alias${NC}"
        echo -e "${GREEN}To edit aliases, run: sudo nano $ALIASES_FILE${NC}"
        echo -e "${GREEN}Aliases will be active on next login or run: source /etc/bash.bashrc${NC}"
        echo ""
        set_state "$aliases_section" "success"
    else
        log "User skipped aliases configuration"
        set_state "$aliases_section" "skipped"
    fi
fi

# Install Webmin with better error handling (state-aware)
webmin_section="WEBMIN"
webmin_state="$(get_state "$webmin_section")"
if [[ "$webmin_state" == "success" ]]; then
    log "Skipping Webmin installation; already completed successfully" "INFO"
else
    read -p "Do you want to install Webmin? This will allow you to administer your Linux server via a web interface... (y/n) " install_webmin
    if [[ $install_webmin =~ ^[Yy]$ ]]; then
        log "Installing Webmin"

        WEBMIN_SETUP="/tmp/setup-repos.sh"
        if curl -fsSL -o "$WEBMIN_SETUP" https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh; then
            chmod +x "$WEBMIN_SETUP"
            if bash "$WEBMIN_SETUP"; then
                if $pacman install -y webmin; then
                    log "Webmin installed successfully" "SUCCESS"
                    systemctl enable webmin
                    systemctl start webmin

                    if ufw status | grep -q "Status: active"; then
                        ufw allow 10000
                        log "UFW rule added for Webmin (port 10000)" "SUCCESS"
                    fi

                    echo -e "${GREEN}Webmin is now running!${NC}"
                    echo -e "${GREEN}Access it at: https://$(hostname -I | awk '{print $1}'):10000${NC}"
                    echo -e "${GREEN}Or: https://your-server-ip:10000${NC}"
                    echo -e "${GREEN}Login with your system root credentials${NC}"
                    set_state "$webmin_section" "success"
                else
                    log "Failed to install Webmin package" "WARNING"
                    set_state "$webmin_section" "failure"
                fi
            else
                log "Webmin repository setup failed" "WARNING"
                set_state "$webmin_section" "failure"
            fi
            rm -f "$WEBMIN_SETUP"
        else
            log "Failed to download Webmin setup script" "WARNING"
            set_state "$webmin_section" "failure"
        fi
        fnRebootCheck
    else
        log "User skipped Webmin installation"
        set_state "$webmin_section" "skipped"
    fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# Dynamic DNS registration for Technitium (chazwall.lan)
# ──────────────────────────────────────────────────────────────────────────────
configure_ddns() {
    local section="DDNS_CONFIG"
    local state
    state="$(get_state "$section")"

    if [[ "$state" == "success" ]]; then
        log "Skipping DDNS configuration; already completed successfully" "INFO"
        return 0
    fi

    read -p "Do you want to configure Dynamic DNS registration with your Technitium DNS server (chazwall.lan)? (y/n) " config_ddns
    if [[ ! $config_ddns =~ ^[Yy]$ ]]; then
        log "User skipped DDNS configuration"
        set_state "$section" "skipped"
        return 0
    fi

    # Prompt for Technitium server IP
    read -p "Enter the IP address of your Technitium DNS server: " TECHNITIUM_IP
    if [[ -z "$TECHNITIUM_IP" ]]; then
        log "No DNS server IP provided, skipping DDNS configuration" "WARNING"
        set_state "$section" "skipped"
        return 0
    fi

    log "Installing dnsutils (nsupdate)..."
    if ! command -v nsupdate &> /dev/null; then
        apt install -y dnsutils || log "Warning: Failed to install dnsutils" "WARNING"
    fi

    # ── Create the registration script ────────────────────────────────────────
    log "Creating DDNS registration script at /usr/local/bin/ddns-register.sh..."
    cat > /usr/local/bin/ddns-register.sh << EOF
#!/bin/bash
# ============================================================
#  Technitium Dynamic DNS Updater
#  Zone   : chazwall.lan
#  Server : ${TECHNITIUM_IP}
#  Runs on: boot (systemd) + network change (networkd-dispatcher)
#            + every 5 min (cron fallback)
# ============================================================

DNS_SERVER="${TECHNITIUM_IP}"
ZONE="chazwall.lan"
HOSTNAME=\$(hostname -s)
TTL=300
LOCK_FILE="/var/run/ddns-register.lock"
LOG_FILE="/var/log/ddns-register.log"

log() {
    echo "[\\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG_FILE"
}

# Prevent overlapping runs
exec 200>"\$LOCK_FILE"
flock -n 200 || { log "Another instance is running, skipping."; exit 0; }

# Get primary LAN IP (first non-loopback global address)
IP=\$(ip -4 addr show scope global | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}' | head -1)

if [[ -z "\$IP" ]]; then
    log "ERROR: Could not determine IP address. Skipping update."
    exit 1
fi

# Compare with last registered IP to avoid unnecessary updates
LAST_IP_FILE="/var/run/ddns-last-ip"
LAST_IP=\$(cat "\$LAST_IP_FILE" 2>/dev/null)

if [[ "\$IP" == "\$LAST_IP" ]]; then
    log "IP unchanged (\$IP). No update needed."
    exit 0
fi

log "Registering \${HOSTNAME}.\${ZONE} -> \${IP} with \${DNS_SERVER}..."

nsupdate << NSEOF
server \$DNS_SERVER
zone \$ZONE
update delete \${HOSTNAME}.\${ZONE} A
update add \${HOSTNAME}.\${ZONE} \$TTL A \$IP
send
NSEOF

if [[ \$? -eq 0 ]]; then
    echo "\$IP" > "\$LAST_IP_FILE"
    log "SUCCESS: DNS record updated."
else
    log "ERROR: nsupdate failed. Check that your Technitium ACL includes \$IP."
    exit 1
fi
EOF

    chmod +x /usr/local/bin/ddns-register.sh
    log "DDNS registration script created" "SUCCESS"

    # ── Systemd service (runs at boot) ────────────────────────────────────────
    log "Creating systemd service for boot-time DNS registration..."
    cat > /etc/systemd/system/ddns-register.service << 'EOF'
[Unit]
Description=Register host with Technitium DNS (chazwall.lan)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ddns-register.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ddns-register.service
    log "Systemd DDNS service enabled" "SUCCESS"

    # ── networkd-dispatcher hook (triggers on IP change) ──────────────────────
    log "Installing networkd-dispatcher for interface-change triggers..."
    apt install -y networkd-dispatcher 2>/dev/null || log "networkd-dispatcher not available, skipping hook" "WARNING"

    if command -v networkd-dispatcher &> /dev/null || dpkg -l networkd-dispatcher &>/dev/null 2>&1; then
        mkdir -p /etc/networkd-dispatcher/routable.d
        cat > /etc/networkd-dispatcher/routable.d/ddns-register << 'EOF'
#!/bin/bash
# Triggered by networkd-dispatcher when an interface becomes routable.
# Re-registers this host with Technitium DNS so the record stays current
# whenever the network comes up or an IP changes.
/usr/local/bin/ddns-register.sh
EOF
        chmod +x /etc/networkd-dispatcher/routable.d/ddns-register
        log "networkd-dispatcher hook installed (triggers on network up/IP change)" "SUCCESS"
    fi

    # ── Cron fallback (every 5 minutes) ───────────────────────────────────────
    log "Adding cron fallback (runs every 5 minutes, skips if IP unchanged)..."
    CRON_ENTRY="*/5 * * * * root /usr/local/bin/ddns-register.sh >> /var/log/ddns-register.log 2>&1"
    CRON_FILE="/etc/cron.d/ddns-register"

    if ! grep -qF "ddns-register.sh" "$CRON_FILE" 2>/dev/null; then
        echo "$CRON_ENTRY" > "$CRON_FILE"
        chmod 644 "$CRON_FILE"
        log "Cron fallback installed at $CRON_FILE" "SUCCESS"
    else
        log "Cron entry already present, skipping" "INFO"
    fi

    # ── Run it now to register immediately ────────────────────────────────────
    log "Running initial DNS registration..."
    if bash /usr/local/bin/ddns-register.sh; then
        log "Initial DNS registration successful" "SUCCESS"
    else
        log "Initial DNS registration failed — verify Technitium is reachable at ${TECHNITIUM_IP} and this server's IP is within the ACL (10.55.20.0/23)" "WARNING"
    fi

    echo ""
    echo -e "${GREEN}DDNS configured! Summary:${NC}"
    echo -e "${GREEN}  Script    : /usr/local/bin/ddns-register.sh${NC}"
    echo -e "${GREEN}  Systemd   : ddns-register.service (runs at boot)${NC}"
    echo -e "${GREEN}  Net hook  : /etc/networkd-dispatcher/routable.d/ddns-register${NC}"
    echo -e "${GREEN}  Cron      : every 5 min, skips if IP unchanged${NC}"
    echo -e "${GREEN}  Log       : /var/log/ddns-register.log${NC}"
    echo -e "${YELLOW}  DNS server: ${TECHNITIUM_IP}  Zone: chazwall.lan${NC}"
    echo ""

    set_state "$section" "success"
}

configure_ddns

# System performance optimization (state-aware)
optimize_system_performance

# Final system cleanup
cleanup_system

# Final reboot check
fnRebootCheck

# Generate system summary report
generate_summary_report() {
    local report_file="/root/setup-summary-$(date +%Y%m%d-%H%M%S).txt"

    cat > "$report_file" << EOF
Ubuntu Server Setup Summary Report
Generated: $(date)
=========================================

System Information:
- OS: $(lsb_release -d -s 2>/dev/null || echo "Unknown")
- Kernel: $(uname -r)
- Architecture: $(dpkg --print-architecture)
- Hostname: $(hostname)
- IP Address: $(hostname -I | awk '{print $1}')

Installed Components:
$(dpkg -l | grep -E '^ii.*(docker|fail2ban|ufw|webmin|nala)' | awk '{print "- " $2 " " $3}' || echo "- None detected")

Active Services:
$(systemctl list-units --type=service --state=active | grep -E '(docker|fail2ban|ufw|webmin|ssh)' | awk '{print "- " $1}' || echo "- Standard services only")

Firewall Status:
$(ufw status 2>/dev/null || echo "UFW not configured")

Docker Status:
$(if command -v docker &> /dev/null; then echo "Installed - Version: $(docker --version)"; else echo "Not installed"; fi)

Setup Log: $LOG_FILE
Backup Directory: $BACKUP_DIR

Next Steps:
1. Review firewall rules if configured
2. Test SSH access if hardened
3. Configure any additional services as needed
4. Update system regularly with: sudo apt update && sudo apt upgrade

=========================================
EOF

    echo -e "${GREEN}Summary report saved to: $report_file${NC}"
}

# Display final system information
log "Ubuntu server setup completed successfully!" "SUCCESS"
echo ""
echo -e "${BLUE}======================================================================================================${NC}"
echo -e "${BLUE}  Setup Complete! Here's your system information:${NC}"
echo -e "${BLUE}======================================================================================================${NC}"

if command -v neofetch &> /dev/null; then
    neofetch
else
    echo "System: $(lsb_release -d -s 2>/dev/null || echo "Unknown")"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(dpkg --print-architecture)"
    echo "Uptime: $(uptime -p 2>/dev/null || echo "Unknown")"
    echo "Memory: $(free -h | awk '/^Mem:/ {print $3 "/" $2}' 2>/dev/null || echo "Unknown")"
    echo "Disk Usage: $(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' 2>/dev/null || echo "Unknown")"
fi

echo ""
echo -e "${GREEN}Log file saved to: $LOG_FILE${NC}"
echo -e "${GREEN}Configuration backups saved to: $BACKUP_DIR${NC}"

# Generate and display summary
generate_summary_report

echo -e "${BLUE}======================================================================================================${NC}"

log "Script execution completed successfully" "SUCCESS"
