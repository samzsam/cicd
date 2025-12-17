#!/bin/bash
#
# Full plugin sync workflow: Download -> Upload to Nexus -> Apply from Nexus
#
# Usage:
#   ./sync-plugin-workflow.sh [OPTIONS]
#
# Options:
#   --mode MODE     Workflow mode: full, upload, apply (default: full)
#   --config PATH   Path to config file
#   --force         Skip confirmation prompts
#   --help          Show this help
#
# Modes:
#   full   - Download -> Upload -> Apply
#   upload - Download -> Upload (no apply)
#   apply  - Apply from Nexus only

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/settings-linux.json"
MODE="full"
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
        "STEP")    echo -e "[$timestamp] ${CYAN}[STEP]${NC} $message" ;;
    esac

    echo "[$timestamp] [$level] $message" >> "$log_dir/workflow.log"
}

show_help() {
    head -18 "$0" | tail -13
    exit 0
}

run_step() {
    local step_name="$1"
    local script="$2"
    shift 2
    local args=("$@")

    echo ""
    log "STEP" "=== $step_name ==="

    if "$SCRIPT_DIR/$script" "${args[@]}"; then
        log "SUCCESS" "$step_name completed"
        return 0
    else
        log "ERROR" "$step_name failed"
        return 1
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            if [[ ! "$MODE" =~ ^(full|upload|apply)$ ]]; then
                log "ERROR" "Invalid mode: $MODE (must be full, upload, or apply)"
                exit 1
            fi
            shift 2
            ;;
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
echo ""
log "STEP" "========================================"
log "STEP" "  Nessus Plugin Sync Workflow (Linux)"
log "STEP" "  Mode: $MODE"
log "STEP" "========================================"

# Build common args
common_args=("--config" "$CONFIG_FILE")
force_args=()
if [[ "$FORCE" == true ]]; then
    force_args=("--force")
fi

# Step 1: Download plugins (for 'full' and 'upload' modes)
if [[ "$MODE" == "full" || "$MODE" == "upload" ]]; then
    download_args=("${common_args[@]}")
    if [[ "$FORCE" == true ]]; then
        download_args+=("--force")
    fi

    if ! run_step "Step 1: Download Plugins" "download-nessus-plugins.sh" "${download_args[@]}"; then
        log "ERROR" "Workflow aborted due to download failure"
        exit 1
    fi
fi

# Step 2: Upload to Nexus (for 'full' and 'upload' modes)
if [[ "$MODE" == "full" || "$MODE" == "upload" ]]; then
    if ! run_step "Step 2: Upload to Nexus" "upload-to-nexus.sh" "${common_args[@]}"; then
        log "ERROR" "Workflow aborted due to upload failure"
        exit 1
    fi
fi

# Step 3: Apply from Nexus (for 'full' and 'apply' modes)
if [[ "$MODE" == "full" || "$MODE" == "apply" ]]; then
    apply_args=("${common_args[@]}" "--version" "latest")
    if [[ "$FORCE" == true ]]; then
        apply_args+=("--force")
    fi

    if ! run_step "Step 3: Apply Plugins from Nexus" "apply-plugins-from-nexus.sh" "${apply_args[@]}"; then
        log "WARN" "Workflow completed with warnings (apply step had issues)"
        exit 1
    fi
fi

echo ""
log "STEP" "========================================"
log "SUCCESS" "  Workflow Completed Successfully!"
log "STEP" "========================================"
echo ""
