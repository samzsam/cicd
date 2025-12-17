#!/bin/bash
#
# Downloads and applies Nessus plugins from Nexus Repository
#
# Usage:
#   ./apply-plugins-from-nexus.sh [OPTIONS]
#
# Options:
#   --config PATH      Path to config file
#   --version VER      Version to apply (default: latest, or date like 2024/12/16)
#   --dry-run          Download only, don't apply
#   --force            Skip confirmation prompt
#   --help             Show this help

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/settings-linux.json"
VERSION="latest"
DRY_RUN=false
FORCE=false

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
    local log_dir="${SCRIPT_DIR}/../logs"

    mkdir -p "$log_dir"

    case "$level" in
        "INFO")    echo -e "[$timestamp] [INFO] $message" ;;
        "SUCCESS") echo -e "[$timestamp] ${GREEN}[SUCCESS]${NC} $message" ;;
        "WARN")    echo -e "[$timestamp] ${YELLOW}[WARN]${NC} $message" ;;
        "ERROR")   echo -e "[$timestamp] ${RED}[ERROR]${NC} $message" ;;
    esac

    echo "[$timestamp] [$level] $message" >> "$log_dir/apply.log"
}

show_help() {
    head -16 "$0" | tail -11
    exit 0
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "ERROR" "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    NESSUS_BIN=$(jq -r '.nessus.installPath' "$CONFIG_FILE")
    NESSUS_DATA=$(jq -r '.nessus.dataPath' "$CONFIG_FILE")
    NEXUS_URL=$(jq -r '.nexus.url' "$CONFIG_FILE")
    NEXUS_REPO=$(jq -r '.nexus.repository' "$CONFIG_FILE")
    NEXUS_USER=$(jq -r '.nexus.username' "$CONFIG_FILE")
    NEXUS_PASS=$(jq -r '.nexus.password' "$CONFIG_FILE")
    PLUGIN_STORAGE=$(jq -r '.pluginStorage.localPath' "$CONFIG_FILE")
    MANUAL_APPROVAL=$(jq -r '.schedule.manualApprovalRequired // true' "$CONFIG_FILE")

    log "INFO" "Loaded config from: $CONFIG_FILE"
}

download_from_nexus() {
    local version="$1"
    local output_dir="$2"

    local auth=$(echo -n "$NEXUS_USER:$NEXUS_PASS" | base64)
    local download_url=""
    local output_file=""

    if [[ "$version" == "latest" ]]; then
        download_url="$NEXUS_URL/repository/$NEXUS_REPO/latest/nessus-plugins-latest.tar.gz"
        output_file="$output_dir/nessus-plugins-latest.tar.gz"
    else
        # Version is a date path like 2024/12/16
        # Try to find the file via Nexus search API
        local search_url="$NEXUS_URL/service/rest/v1/search/assets?repository=$NEXUS_REPO&group=/$version"

        local assets=$(curl -s -H "Authorization: Basic $auth" "$search_url")
        local plugin_url=$(echo "$assets" | jq -r '.items[] | select(.path | endswith(".tar.gz") and (contains("metadata") | not)) | .downloadUrl' | head -1)

        if [[ -n "$plugin_url" && "$plugin_url" != "null" ]]; then
            download_url="$plugin_url"
            output_file="$output_dir/$(basename "$plugin_url")"
        else
            # Fallback to direct path construction
            download_url="$NEXUS_URL/repository/$NEXUS_REPO/$version/nessus-plugins.tar.gz"
            output_file="$output_dir/nessus-plugins-${version//\//-}.tar.gz"
        fi
    fi

    log "INFO" "Downloading from: $download_url"

    local http_code=$(curl -s -w "%{http_code}" -o "$output_file" \
        -H "Authorization: Basic $auth" \
        "$download_url")

    if [[ "$http_code" != "200" ]]; then
        log "ERROR" "Download failed (HTTP $http_code)"
        rm -f "$output_file"
        return 1
    fi

    if [[ ! -f "$output_file" || ! -s "$output_file" ]]; then
        log "ERROR" "Downloaded file is empty or missing"
        return 1
    fi

    local size=$(du -h "$output_file" | cut -f1)
    log "SUCCESS" "Downloaded: $(basename "$output_file") ($size)"

    echo "$output_file"
}

verify_archive() {
    local archive="$1"

    log "INFO" "Verifying archive integrity..."

    if tar -tzf "$archive" > /dev/null 2>&1; then
        log "SUCCESS" "Archive is valid"
        return 0
    else
        log "ERROR" "Archive verification failed"
        return 1
    fi
}

get_current_plugin_info() {
    log "INFO" "Getting current plugin information..."

    if [[ -x "$NESSUS_BIN/nessuscli" ]]; then
        "$NESSUS_BIN/nessuscli" update --plugins-only --check 2>&1 || echo "Unable to check"
    else
        echo "Nessus CLI not found"
    fi
}

backup_plugins() {
    local backup_dir="$PLUGIN_STORAGE/backups"
    local plugins_dir="$NESSUS_DATA/plugins"

    if [[ ! -d "$plugins_dir" ]]; then
        log "WARN" "No existing plugins to backup"
        return
    fi

    mkdir -p "$backup_dir"

    local timestamp=$(date '+%Y%m%d-%H%M%S')
    local backup_file="$backup_dir/plugins-backup-${timestamp}.tar.gz"

    log "INFO" "Creating backup: $backup_file"

    tar -czf "$backup_file" -C "$NESSUS_DATA" plugins

    log "SUCCESS" "Backup created: $backup_file"
    echo "$backup_file"
}

stop_nessus() {
    log "INFO" "Stopping Nessus service..."

    if systemctl is-active --quiet nessusd 2>/dev/null; then
        systemctl stop nessusd
    elif service nessusd status > /dev/null 2>&1; then
        service nessusd stop
    else
        log "WARN" "Could not determine Nessus service status"
        return 0
    fi

    sleep 5
    log "SUCCESS" "Nessus service stopped"
}

start_nessus() {
    log "INFO" "Starting Nessus service..."

    if systemctl start nessusd 2>/dev/null; then
        :
    elif service nessusd start 2>/dev/null; then
        :
    else
        log "ERROR" "Failed to start Nessus service"
        return 1
    fi

    sleep 10
    log "SUCCESS" "Nessus service started"
}

apply_plugins() {
    local archive="$1"

    log "INFO" "Applying plugins from: $archive"

    if [[ ! -x "$NESSUS_BIN/nessuscli" ]]; then
        log "ERROR" "Nessus CLI not found: $NESSUS_BIN/nessuscli"
        return 1
    fi

    local result=$("$NESSUS_BIN/nessuscli" update "$archive" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log "SUCCESS" "Plugins applied successfully"
        log "INFO" "Output: $result"
        return 0
    else
        log "ERROR" "Plugin update failed: $result"
        return 1
    fi
}

record_application() {
    local archive="$1"
    local backup="$2"
    local history_file="$PLUGIN_STORAGE/apply-history.json"

    local record=$(cat << EOF
{
    "appliedAt": "$(date -Iseconds)",
    "archive": "$archive",
    "version": "$VERSION",
    "backup": "$backup",
    "hostname": "$(hostname)"
}
EOF
)

    if [[ -f "$history_file" ]]; then
        # Append to existing array
        local tmp=$(mktemp)
        jq --argjson new "$record" '. += [$new]' "$history_file" > "$tmp" && mv "$tmp" "$history_file"
    else
        echo "[$record]" > "$history_file"
    fi

    log "INFO" "Application recorded in: $history_file"
}

confirm_apply() {
    if [[ "$FORCE" == true ]]; then
        return 0
    fi

    if [[ "$MANUAL_APPROVAL" != "true" ]]; then
        return 0
    fi

    echo ""
    echo -e "${YELLOW}Plugin archive downloaded and ready to apply.${NC}"
    echo -e "${YELLOW}This will restart the Nessus service.${NC}"
    echo ""
    read -p "Apply plugins now? (y/N): " confirm

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        return 0
    else
        log "INFO" "Application cancelled by user"
        return 1
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
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
log "INFO" "=== Plugin Apply from Nexus Started ==="
log "INFO" "Version: $VERSION"
log "INFO" "Dry Run: $DRY_RUN"

load_config

# Ensure storage exists
mkdir -p "$PLUGIN_STORAGE"

# Download from Nexus
downloaded_archive=$(download_from_nexus "$VERSION" "$PLUGIN_STORAGE")

if [[ -z "$downloaded_archive" ]]; then
    log "ERROR" "Download failed"
    exit 1
fi

# Verify archive
if ! verify_archive "$downloaded_archive"; then
    exit 1
fi

# Show current status
current_info=$(get_current_plugin_info)
log "INFO" "Current plugin status: $current_info"

# Dry run check
if [[ "$DRY_RUN" == true ]]; then
    log "INFO" "DRY RUN: Would apply plugins from $downloaded_archive"
    log "INFO" "=== Dry Run Completed ==="
    exit 0
fi

# Confirm
if ! confirm_apply; then
    exit 0
fi

# Backup current plugins
backup_file=$(backup_plugins)

# Stop Nessus
stop_nessus

# Apply plugins
apply_result=0
if ! apply_plugins "$downloaded_archive"; then
    apply_result=1
fi

# Start Nessus (always, even if apply failed)
start_nessus

if [[ $apply_result -ne 0 ]]; then
    log "ERROR" "Plugin application failed. Backup available at: $backup_file"
    exit 1
fi

# Record application
record_application "$downloaded_archive" "$backup_file"

log "INFO" "=== Plugin Apply Completed ==="

# Output for pipeline
echo "{\"success\": true, \"archive\": \"$downloaded_archive\", \"backup\": \"$backup_file\", \"timestamp\": \"$(date -Iseconds)\"}"
