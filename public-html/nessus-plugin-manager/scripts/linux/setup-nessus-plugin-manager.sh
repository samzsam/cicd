#!/bin/bash
#
# Setup script for Nessus Plugin Manager on Amazon Linux
#
# Usage:
#   ./setup-nessus-plugin-manager.sh [OPTIONS]
#
# Options:
#   --nexus-url URL          Nexus Repository URL
#   --nexus-user USER        Nexus username (default: admin)
#   --nexus-pass PASS        Nexus password
#   --nexus-repo REPO        Nexus repository name (default: nessus-plugins)
#   --disable-auto-update    Disable Nessus automatic updates
#   --create-cron            Create cron job for scheduled sync
#   --help                   Show this help message

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"
LOG_DIR="$(dirname "$SCRIPT_DIR")/logs"

# Default values
NEXUS_URL=""
NEXUS_USER="admin"
NEXUS_PASS=""
NEXUS_REPO="nessus-plugins"
DISABLE_AUTO_UPDATE=false
CREATE_CRON=false

# Nessus paths
NESSUS_BIN="/opt/nessus/sbin"
NESSUS_DATA="/opt/nessus/var/nessus"
NESSUS_CONFIG="/opt/nessus/etc/nessus"
PLUGIN_STORAGE="/var/lib/nessus-plugins"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

    mkdir -p "$LOG_DIR"
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/setup.log"
}

show_help() {
    head -20 "$0" | tail -15
    exit 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
}

check_dependencies() {
    log "INFO" "Checking dependencies..."

    local missing=()

    for cmd in curl jq tar; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "WARN" "Installing missing dependencies: ${missing[*]}"
        yum install -y "${missing[@]}" || amazon-linux-extras install -y epel && yum install -y "${missing[@]}"
    fi

    log "SUCCESS" "All dependencies available"
}

find_nessus() {
    log "INFO" "Looking for Nessus installation..."

    if [[ -x "$NESSUS_BIN/nessuscli" ]]; then
        log "SUCCESS" "Found Nessus at: $NESSUS_BIN"
        return 0
    fi

    # Try alternative locations
    for path in /opt/nessus/sbin /usr/local/nessus/sbin; do
        if [[ -x "$path/nessuscli" ]]; then
            NESSUS_BIN="$path"
            log "SUCCESS" "Found Nessus at: $NESSUS_BIN"
            return 0
        fi
    done

    log "ERROR" "Nessus installation not found"
    log "ERROR" "Install Nessus first:"
    log "ERROR" "  curl -o Nessus.rpm https://www.tenable.com/downloads/api/v1/public/pages/nessus/downloads/xxxxx/download?i_agree_to_tenable_license_agreement=true"
    log "ERROR" "  rpm -ivh Nessus.rpm"
    exit 1
}

disable_auto_update() {
    log "STEP" "Disabling Nessus automatic updates..."

    # Method 1: Use nessuscli
    if "$NESSUS_BIN/nessuscli" fix --set auto_update=no 2>/dev/null; then
        log "SUCCESS" "Disabled: auto_update"
    else
        log "WARN" "Could not set auto_update via CLI"
    fi

    if "$NESSUS_BIN/nessuscli" fix --set auto_update_ui=no 2>/dev/null; then
        log "SUCCESS" "Disabled: auto_update_ui"
    else
        log "WARN" "Could not set auto_update_ui via CLI"
    fi

    # Method 2: Direct config file modification
    local config_file="$NESSUS_CONFIG/nessusd.conf"

    if [[ -f "$config_file" ]]; then
        # Backup original
        cp "$config_file" "$config_file.bak.$(date +%Y%m%d%H%M%S)"

        # Update or add auto_update setting
        if grep -q "^auto_update" "$config_file"; then
            sed -i 's/^auto_update=.*/auto_update=no/' "$config_file"
        else
            echo "auto_update=no" >> "$config_file"
        fi

        # Update or add auto_update_ui setting
        if grep -q "^auto_update_ui" "$config_file"; then
            sed -i 's/^auto_update_ui=.*/auto_update_ui=no/' "$config_file"
        else
            echo "auto_update_ui=no" >> "$config_file"
        fi

        log "SUCCESS" "Updated $config_file"
    fi

    # Restart Nessus to apply
    log "INFO" "Restarting Nessus service..."
    systemctl restart nessusd || service nessusd restart
    sleep 10
    log "SUCCESS" "Nessus service restarted"
}

create_directories() {
    log "INFO" "Creating directories..."

    mkdir -p "$PLUGIN_STORAGE"
    mkdir -p "$PLUGIN_STORAGE/backups"
    mkdir -p "$LOG_DIR"
    mkdir -p "$CONFIG_DIR"

    chmod 755 "$PLUGIN_STORAGE"

    log "SUCCESS" "Created: $PLUGIN_STORAGE"
}

update_config() {
    log "INFO" "Updating configuration..."

    local config_file="$CONFIG_DIR/settings-linux.json"

    if [[ ! -f "$config_file" ]]; then
        log "WARN" "Config file not found, creating default..."
        cat > "$config_file" << 'EOF'
{
  "nessus": {
    "installPath": "/opt/nessus/sbin",
    "dataPath": "/opt/nessus/var/nessus",
    "configPath": "/opt/nessus/etc/nessus",
    "webUrl": "https://localhost:8834"
  },
  "nexus": {
    "url": "",
    "repository": "nessus-plugins",
    "username": "admin",
    "password": ""
  },
  "pluginStorage": {
    "localPath": "/var/lib/nessus-plugins",
    "retentionDays": 30
  },
  "schedule": {
    "manualApprovalRequired": true
  }
}
EOF
    fi

    # Update config with provided values using jq
    if [[ -n "$NEXUS_URL" ]]; then
        local tmp=$(mktemp)
        jq --arg url "$NEXUS_URL" '.nexus.url = $url' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
    fi

    if [[ -n "$NEXUS_USER" ]]; then
        local tmp=$(mktemp)
        jq --arg user "$NEXUS_USER" '.nexus.username = $user' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
    fi

    if [[ -n "$NEXUS_PASS" ]]; then
        local tmp=$(mktemp)
        jq --arg pass "$NEXUS_PASS" '.nexus.password = $pass' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
    fi

    if [[ -n "$NEXUS_REPO" ]]; then
        local tmp=$(mktemp)
        jq --arg repo "$NEXUS_REPO" '.nexus.repository = $repo' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
    fi

    # Update paths
    local tmp=$(mktemp)
    jq --arg path "$NESSUS_BIN" '.nessus.installPath = $path' "$config_file" > "$tmp" && mv "$tmp" "$config_file"

    chmod 600 "$config_file"
    log "SUCCESS" "Configuration updated: $config_file"
}

create_nexus_repo() {
    if [[ -z "$NEXUS_URL" || -z "$NEXUS_PASS" ]]; then
        log "WARN" "Nexus credentials not provided, skipping repository creation"
        return
    fi

    log "INFO" "Checking/creating Nexus repository: $NEXUS_REPO"

    local auth=$(echo -n "$NEXUS_USER:$NEXUS_PASS" | base64)

    # Check if repo exists
    local status=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Basic $auth" \
        "$NEXUS_URL/service/rest/v1/repositories/$NEXUS_REPO")

    if [[ "$status" == "200" ]]; then
        log "SUCCESS" "Repository '$NEXUS_REPO' already exists"
        return
    fi

    # Create raw hosted repository
    local payload=$(cat << EOF
{
  "name": "$NEXUS_REPO",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": false,
    "writePolicy": "ALLOW"
  }
}
EOF
)

    local result=$(curl -s -w "%{http_code}" -o /dev/null \
        -X POST \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$NEXUS_URL/service/rest/v1/repositories/raw/hosted")

    if [[ "$result" == "201" || "$result" == "200" ]]; then
        log "SUCCESS" "Repository '$NEXUS_REPO' created"
    else
        log "WARN" "Could not create repository (HTTP $result)"
        log "WARN" "Please create a 'raw (hosted)' repository named '$NEXUS_REPO' manually"
    fi
}

create_cron_job() {
    log "INFO" "Creating cron job for plugin sync..."

    local cron_file="/etc/cron.d/nessus-plugin-sync"

    cat > "$cron_file" << EOF
# Nessus Plugin Sync - runs weekly on Sunday at 3 AM
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 3 * * 0 root $SCRIPT_DIR/sync-plugin-workflow.sh --mode apply --force >> $LOG_DIR/cron.log 2>&1
EOF

    chmod 644 "$cron_file"
    log "SUCCESS" "Created cron job: $cron_file"
}

make_scripts_executable() {
    log "INFO" "Making scripts executable..."
    chmod +x "$SCRIPT_DIR"/*.sh
    log "SUCCESS" "Scripts are now executable"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nexus-url)
            NEXUS_URL="$2"
            shift 2
            ;;
        --nexus-user)
            NEXUS_USER="$2"
            shift 2
            ;;
        --nexus-pass)
            NEXUS_PASS="$2"
            shift 2
            ;;
        --nexus-repo)
            NEXUS_REPO="$2"
            shift 2
            ;;
        --disable-auto-update)
            DISABLE_AUTO_UPDATE=true
            shift
            ;;
        --create-cron)
            CREATE_CRON=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            show_help
            ;;
    esac
done

# Main execution
echo ""
log "STEP" "========================================"
log "STEP" "  Nessus Plugin Manager Setup (Linux)"
log "STEP" "========================================"
echo ""

check_root
check_dependencies
find_nessus
create_directories

if [[ "$DISABLE_AUTO_UPDATE" == true ]]; then
    disable_auto_update
fi

update_config
create_nexus_repo

if [[ "$CREATE_CRON" == true ]]; then
    create_cron_job
fi

make_scripts_executable

echo ""
log "STEP" "========================================"
log "SUCCESS" "  Setup Complete!"
log "STEP" "========================================"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "1. Edit $CONFIG_DIR/settings-linux.json with your Nexus credentials"
echo "2. Run: ./download-nessus-plugins.sh  (to export current plugins)"
echo "3. Run: ./upload-to-nexus.sh          (to upload to Nexus)"
echo "4. Run: ./apply-plugins-from-nexus.sh (to apply from Nexus)"
echo ""
