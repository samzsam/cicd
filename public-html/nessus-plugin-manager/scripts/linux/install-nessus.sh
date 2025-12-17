#!/bin/bash
#
# Downloads and installs Tenable Nessus on Amazon Linux
#
# Usage:
#   ./install-nessus.sh [OPTIONS]
#
# Options:
#   --version VER      Nessus version (default: latest available)
#   --license KEY      Activation code for Nessus
#   --skip-start       Don't start Nessus after install
#   --help             Show this help
#
# Note: Specific versions like 10.9.1 may not be available from Tenable.
#       Only the latest version is typically offered.

set -e

VERSION=""
LICENSE_KEY=""
SKIP_START=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "INFO")    echo -e "[$timestamp] [INFO] $message" ;;
        "SUCCESS") echo -e "[$timestamp] ${GREEN}[SUCCESS]${NC} $message" ;;
        "WARN")    echo -e "[$timestamp] ${YELLOW}[WARN]${NC} $message" ;;
        "ERROR")   echo -e "[$timestamp] ${RED}[ERROR]${NC} $message" ;;
        "STEP")    echo -e "[$timestamp] ${CYAN}[STEP]${NC} $message" ;;
    esac
}

show_help() {
    head -17 "$0" | tail -12
    exit 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_VERSION="$VERSION_ID"
    elif [[ -f /etc/system-release ]]; then
        OS_NAME=$(cat /etc/system-release | awk '{print $1}')
    else
        OS_NAME="Unknown"
    fi

    log "INFO" "Detected OS: $OS_NAME $OS_VERSION"

    # Determine package type
    if command -v rpm &> /dev/null; then
        PKG_TYPE="rpm"
        PKG_INSTALL="rpm -ivh"
    elif command -v dpkg &> /dev/null; then
        PKG_TYPE="deb"
        PKG_INSTALL="dpkg -i"
    else
        log "ERROR" "Unsupported package manager"
        exit 1
    fi
}

get_download_info() {
    log "INFO" "Fetching Nessus download information..."

    # Tenable's download page requires agreeing to license
    # The actual download URL pattern for Amazon Linux (RPM):
    # https://www.tenable.com/downloads/api/v2/pages/nessus/files/Nessus-<version>-amzn2.x86_64.rpm

    # For now, provide instructions since direct download requires authentication
    log "WARN" "Automatic download from Tenable requires authentication"
    log "INFO" ""
    log "INFO" "Please download Nessus manually:"
    log "INFO" "  1. Go to: https://www.tenable.com/downloads/nessus"
    log "INFO" "  2. Select 'Nessus - Amazon Linux' (x86_64 RPM)"
    log "INFO" "  3. Accept the license agreement"
    log "INFO" "  4. Download the RPM file"
    log "INFO" ""

    # Check if RPM already exists in current directory
    local rpm_file=$(ls -t Nessus-*.rpm 2>/dev/null | head -1)
    if [[ -n "$rpm_file" ]]; then
        log "SUCCESS" "Found existing RPM: $rpm_file"
        NESSUS_RPM="$rpm_file"
        return 0
    fi

    return 1
}

install_nessus() {
    local rpm_file="$1"

    if [[ ! -f "$rpm_file" ]]; then
        log "ERROR" "RPM file not found: $rpm_file"
        exit 1
    fi

    log "STEP" "Installing Nessus from: $rpm_file"

    # Install dependencies
    yum install -y java-1.8.0-openjdk 2>/dev/null || true

    # Install Nessus
    rpm -ivh "$rpm_file"

    if [[ $? -eq 0 ]]; then
        log "SUCCESS" "Nessus installed successfully"
    else
        log "ERROR" "Nessus installation failed"
        exit 1
    fi
}

start_nessus() {
    log "INFO" "Starting Nessus service..."

    systemctl daemon-reload
    systemctl enable nessusd
    systemctl start nessusd

    sleep 5

    if systemctl is-active --quiet nessusd; then
        log "SUCCESS" "Nessus service started"
    else
        log "ERROR" "Failed to start Nessus service"
        exit 1
    fi
}

register_nessus() {
    local license="$1"

    if [[ -z "$license" ]]; then
        log "WARN" "No license key provided"
        log "INFO" "Register Nessus manually:"
        log "INFO" "  /opt/nessus/sbin/nessuscli fetch --register <activation-code>"
        return
    fi

    log "INFO" "Registering Nessus..."

    /opt/nessus/sbin/nessuscli fetch --register "$license"

    if [[ $? -eq 0 ]]; then
        log "SUCCESS" "Nessus registered successfully"
    else
        log "WARN" "Registration may have failed - check manually"
    fi
}

show_completion_info() {
    local ip=$(hostname -I | awk '{print $1}')

    echo ""
    log "STEP" "========================================"
    log "SUCCESS" "  Nessus Installation Complete!"
    log "STEP" "========================================"
    echo ""
    echo -e "${CYAN}Access Nessus:${NC}"
    echo "  Local:  https://localhost:8834"
    echo "  Remote: https://${ip}:8834"
    echo ""
    echo -e "${CYAN}Initial Setup:${NC}"
    echo "  1. Open the URL above in a browser"
    echo "  2. Create an admin account"
    echo "  3. Enter your activation code (if not already registered)"
    echo "  4. Wait for plugins to download"
    echo ""
    echo -e "${CYAN}Disable Auto-Updates:${NC}"
    echo "  ./setup-nessus-plugin-manager.sh --disable-auto-update"
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  Status:  systemctl status nessusd"
    echo "  Stop:    systemctl stop nessusd"
    echo "  Start:   systemctl start nessusd"
    echo "  Logs:    journalctl -u nessusd -f"
    echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --license)
            LICENSE_KEY="$2"
            shift 2
            ;;
        --skip-start)
            SKIP_START=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            # Assume it's an RPM file path
            if [[ -f "$1" && "$1" == *.rpm ]]; then
                NESSUS_RPM="$1"
            else
                log "ERROR" "Unknown option: $1"
                show_help
            fi
            shift
            ;;
    esac
done

# Main execution
echo ""
log "STEP" "========================================"
log "STEP" "  Nessus Installation (Amazon Linux)"
log "STEP" "========================================"
echo ""

check_root
detect_os

# Check if Nessus already installed
if [[ -x /opt/nessus/sbin/nessuscli ]]; then
    log "WARN" "Nessus appears to be already installed"
    /opt/nessus/sbin/nessuscli --version || true
    echo ""
    read -p "Reinstall? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        exit 0
    fi
fi

# Get or verify RPM
if [[ -z "$NESSUS_RPM" ]]; then
    get_download_info || true

    if [[ -z "$NESSUS_RPM" ]]; then
        echo ""
        read -p "Enter path to Nessus RPM file: " NESSUS_RPM
    fi
fi

if [[ ! -f "$NESSUS_RPM" ]]; then
    log "ERROR" "RPM file not found: $NESSUS_RPM"
    exit 1
fi

# Install
install_nessus "$NESSUS_RPM"

# Start service
if [[ "$SKIP_START" != true ]]; then
    start_nessus
fi

# Register
if [[ -n "$LICENSE_KEY" ]]; then
    register_nessus "$LICENSE_KEY"
fi

show_completion_info
