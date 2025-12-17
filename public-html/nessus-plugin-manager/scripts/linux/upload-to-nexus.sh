#!/bin/bash
#
# Uploads Nessus plugin archives to Nexus Repository
#
# Usage:
#   ./upload-to-nexus.sh [OPTIONS]
#
# Options:
#   --config PATH      Path to config file
#   --archive PATH     Specific archive to upload (default: latest)
#   --help             Show this help

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/settings-linux.json"
ARCHIVE_PATH=""

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

    echo "[$timestamp] [$level] $message" >> "$log_dir/upload.log"
}

show_help() {
    head -13 "$0" | tail -8
    exit 0
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "ERROR" "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    NEXUS_URL=$(jq -r '.nexus.url' "$CONFIG_FILE")
    NEXUS_REPO=$(jq -r '.nexus.repository' "$CONFIG_FILE")
    NEXUS_USER=$(jq -r '.nexus.username' "$CONFIG_FILE")
    NEXUS_PASS=$(jq -r '.nexus.password' "$CONFIG_FILE")
    PLUGIN_STORAGE=$(jq -r '.pluginStorage.localPath' "$CONFIG_FILE")

    if [[ -z "$NEXUS_URL" || "$NEXUS_URL" == "null" ]]; then
        log "ERROR" "Nexus URL not configured"
        exit 1
    fi

    log "INFO" "Nexus URL: $NEXUS_URL"
    log "INFO" "Repository: $NEXUS_REPO"
}

test_nexus_connection() {
    log "INFO" "Testing Nexus connectivity..."

    local status=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 \
        "$NEXUS_URL/service/rest/v1/status")

    if [[ "$status" == "200" ]]; then
        log "SUCCESS" "Nexus is available"
        return 0
    else
        log "ERROR" "Cannot connect to Nexus (HTTP $status)"
        return 1
    fi
}

create_metadata() {
    local archive="$1"
    local metadata_file="${archive%.tar.gz}.metadata.json"

    local filename=$(basename "$archive")
    local size=$(stat -c %s "$archive" 2>/dev/null || stat -f %z "$archive")
    local sha256=$(sha256sum "$archive" | cut -d' ' -f1)

    cat > "$metadata_file" << EOF
{
    "filename": "$filename",
    "size": $size,
    "sha256": "$sha256",
    "uploadedAt": "$(date -Iseconds)",
    "uploadedBy": "$(whoami)",
    "hostname": "$(hostname)"
}
EOF

    echo "$metadata_file"
}

upload_file() {
    local file_path="$1"
    local target_path="$2"
    local filename=$(basename "$file_path")

    local auth=$(echo -n "$NEXUS_USER:$NEXUS_PASS" | base64)
    local upload_url="$NEXUS_URL/repository/$NEXUS_REPO/$target_path/$filename"

    log "INFO" "Uploading: $filename -> $upload_url"

    local http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/gzip" \
        --data-binary "@$file_path" \
        "$upload_url")

    if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then
        log "SUCCESS" "Uploaded: $filename"
        return 0
    else
        log "ERROR" "Upload failed (HTTP $http_code): $filename"
        return 1
    fi
}

upload_latest_pointer() {
    local archive="$1"
    local auth=$(echo -n "$NEXUS_USER:$NEXUS_PASS" | base64)
    local latest_url="$NEXUS_URL/repository/$NEXUS_REPO/latest/nessus-plugins-latest.tar.gz"

    log "INFO" "Updating latest pointer..."

    local http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/gzip" \
        --data-binary "@$archive" \
        "$latest_url")

    if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then
        log "SUCCESS" "Latest pointer updated"
        return 0
    else
        log "WARN" "Failed to update latest pointer (HTTP $http_code)"
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
        --archive)
            ARCHIVE_PATH="$2"
            shift 2
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
log "INFO" "=== Nexus Upload Started ==="

load_config

# Determine archive to upload
if [[ -z "$ARCHIVE_PATH" ]]; then
    ARCHIVE_PATH="$PLUGIN_STORAGE/latest-plugins.tar.gz"
fi

if [[ ! -f "$ARCHIVE_PATH" ]]; then
    log "ERROR" "Archive not found: $ARCHIVE_PATH"
    log "ERROR" "Run download-nessus-plugins.sh first"
    exit 1
fi

# Resolve symlink if needed
if [[ -L "$ARCHIVE_PATH" ]]; then
    ARCHIVE_PATH=$(readlink -f "$ARCHIVE_PATH")
fi

log "INFO" "Archive: $ARCHIVE_PATH"
log "INFO" "Size: $(du -h "$ARCHIVE_PATH" | cut -f1)"

# Test Nexus
if ! test_nexus_connection; then
    exit 1
fi

# Create metadata
metadata_file=$(create_metadata "$ARCHIVE_PATH")
log "INFO" "Created metadata: $metadata_file"

# Determine date-based path
date_path=$(date '+%Y/%m/%d')

# Upload archive
if ! upload_file "$ARCHIVE_PATH" "$date_path"; then
    exit 1
fi

# Upload metadata
if ! upload_file "$metadata_file" "$date_path"; then
    log "WARN" "Metadata upload failed, continuing..."
fi

# Update latest pointer
upload_latest_pointer "$ARCHIVE_PATH"

# Cleanup local metadata
rm -f "$metadata_file"

log "INFO" "=== Nexus Upload Completed ==="

# Output for pipeline
echo "{\"success\": true, \"uploadedTo\": \"$NEXUS_URL/repository/$NEXUS_REPO/$date_path/$(basename $ARCHIVE_PATH)\", \"timestamp\": \"$(date -Iseconds)\"}"
