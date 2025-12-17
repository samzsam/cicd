#!/bin/bash
#
# Downloads/exports Nessus plugins for upload to Nexus
#
# Usage:
#   ./download-nessus-plugins.sh [OPTIONS]
#
# Options:
#   --config PATH    Path to config file (default: ../config/settings-linux.json)
#   --force          Force download even if recent
#   --help           Show this help

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/settings-linux.json"
FORCE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

    echo "[$timestamp] [$level] $message" >> "$log_dir/download.log"
}

show_help() {
    head -15 "$0" | tail -10
    exit 0
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "ERROR" "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    NESSUS_BIN=$(jq -r '.nessus.installPath' "$CONFIG_FILE")
    NESSUS_DATA=$(jq -r '.nessus.dataPath' "$CONFIG_FILE")
    PLUGIN_STORAGE=$(jq -r '.pluginStorage.localPath' "$CONFIG_FILE")

    log "INFO" "Loaded config from: $CONFIG_FILE"
}

check_nessus() {
    if [[ ! -x "$NESSUS_BIN/nessuscli" ]]; then
        log "ERROR" "Nessus CLI not found at: $NESSUS_BIN/nessuscli"
        exit 1
    fi
    log "INFO" "Nessus CLI: $NESSUS_BIN/nessuscli"
}

should_download() {
    local last_download_file="$PLUGIN_STORAGE/.last_download"

    if [[ "$FORCE" == true ]]; then
        return 0
    fi

    if [[ -f "$last_download_file" ]]; then
        local last_download=$(cat "$last_download_file")
        local last_epoch=$(date -d "$last_download" +%s 2>/dev/null || echo 0)
        local now_epoch=$(date +%s)
        local hours_since=$(( (now_epoch - last_epoch) / 3600 ))

        if [[ $hours_since -lt 24 ]]; then
            log "INFO" "Plugins downloaded ${hours_since} hours ago. Use --force to override."
            return 1
        fi
    fi

    return 0
}

export_plugins() {
    local plugins_dir="$NESSUS_DATA/plugins"

    if [[ ! -d "$plugins_dir" ]]; then
        log "ERROR" "Plugins directory not found: $plugins_dir"
        log "ERROR" "Ensure Nessus has downloaded plugins at least once"
        exit 1
    fi

    local plugin_count=$(find "$plugins_dir" -name "*.nasl" 2>/dev/null | wc -l)
    log "INFO" "Found $plugin_count plugin files"

    if [[ $plugin_count -eq 0 ]]; then
        log "ERROR" "No plugins found. Nessus may not have downloaded plugins yet."
        exit 1
    fi

    local timestamp=$(date '+%Y%m%d-%H%M%S')
    local archive_name="nessus-plugins-${timestamp}.tar.gz"
    local archive_path="$PLUGIN_STORAGE/$archive_name"

    log "INFO" "Creating plugin archive: $archive_path"

    # Create archive from Nessus data directory
    tar -czf "$archive_path" -C "$NESSUS_DATA" plugins

    if [[ ! -f "$archive_path" ]]; then
        log "ERROR" "Failed to create archive"
        exit 1
    fi

    local size=$(du -h "$archive_path" | cut -f1)
    log "SUCCESS" "Archive created: $archive_name ($size)"

    # Create/update latest symlink
    local latest_path="$PLUGIN_STORAGE/latest-plugins.tar.gz"
    ln -sf "$archive_path" "$latest_path"
    log "INFO" "Updated latest symlink: $latest_path"

    # Record download time
    date -Iseconds > "$PLUGIN_STORAGE/.last_download"

    # Output for pipeline
    echo "{\"success\": true, \"archive\": \"$archive_path\", \"latest\": \"$latest_path\", \"timestamp\": \"$(date -Iseconds)\"}"
}

cleanup_old_archives() {
    local retention_days=$(jq -r '.pluginStorage.retentionDays // 30' "$CONFIG_FILE")

    log "INFO" "Cleaning up archives older than $retention_days days..."

    find "$PLUGIN_STORAGE" -name "nessus-plugins-*.tar.gz" -mtime +${retention_days} -delete 2>/dev/null || true

    log "INFO" "Cleanup complete"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_FILE="$2"
            shift 2
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
log "INFO" "=== Nessus Plugin Download Started ==="

load_config
check_nessus

# Ensure storage directory exists
mkdir -p "$PLUGIN_STORAGE"

if should_download; then
    export_plugins
    cleanup_old_archives
fi

log "INFO" "=== Nessus Plugin Download Completed ==="
