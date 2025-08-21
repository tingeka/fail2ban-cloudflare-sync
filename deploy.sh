#!/bin/bash
# deploy.sh - Testable, robust deploy with dry-run, debug, and force
# Requires systemd for real deployment

set -euo pipefail

# ===== Configuration =====
DEBUG=${DEBUG:-false}
DRY_RUN=false
FORCE=false
REPO_URL="${REPO_URL:-https://github.com/tingeka/fail2ban-cloudflare-sync.git}"
TMP_DIR="${TMP_DIR:-/tmp/fail2ban-cloudflare-sync}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
FAIL2BAN_ACTION_DIR="${FAIL2BAN_ACTION_DIR:-/etc/fail2ban/action.d}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SERVICE_NAME="${SERVICE_NAME:-f2b-cloudflare-firewall-sync.service}"

# ===== Usage =====
usage() {
    echo "Usage: $0 [--dry-run] [--debug] [--force] [--help]"
    echo "Options:"
    echo "  --dry-run   Show actions without making changes"
    echo "  --debug     Enable bash debug mode"
    echo "  --force     Skip all confirmation prompts"
    echo "  --help      Display this message"
}

# ===== Parse arguments =====
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --debug) DEBUG=true ;;
            --force) FORCE=true ;;
            --help) usage; exit 0 ;;
            *) echo "Unknown option: $arg"; usage; exit 1 ;;
        esac
    done
    $DEBUG && set -x
}

# ===== Logging =====
run_cmd() {
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    if $DRY_RUN; then
        echo "[$ts][DRY-RUN] $*"
    else
        echo "[$ts][RUN] $*"
        "$@"
    fi
}

confirm() {
    $FORCE && return 0
    read -r -p "$1 [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) true ;;
        *) false ;;
    esac
}

# ===== Environment Checks (injectable for tests) =====
check_environment() {
    local require_root=${1:-true}

    if $require_root && [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root." >&2
        exit 5
    fi

    local dirs=("$BIN_DIR" "$SYSTEMD_DIR")
    local fail2ban_present=true

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "Warning: fail2ban-client not found. Fail2Ban actions will be skipped."
        fail2ban_present=false
    else
        dirs+=("$FAIL2BAN_ACTION_DIR")
    fi

    local unwritable_dirs=()
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] || unwritable_dirs+=("$d")
        [[ -w "$d" ]] || unwritable_dirs+=("$d")
    done

    if (( ${#unwritable_dirs[@]} > 0 )); then
        echo "The following directories are missing or unwritable: ${unwritable_dirs[*]}"
        exit 2
    fi

    echo "$fail2ban_present"
}

# ===== File deployment helper =====
copy_file() {
    local src="$1"
    local dst="$2"
    local mode owner

    [[ -f "$src" ]] || { echo "Error: source file $src does not exist"; exit 3; }

    if [[ -e "$dst" && $FORCE == false ]]; then
        confirm "File $dst exists and will be overwritten. Continue?" || { echo "Skipping $dst"; return; }
    fi

    run_cmd cp -v "$src" "$dst"

    case "$dst" in
        $BIN_DIR/*) owner="root:root"; mode="0755" ;;
        $FAIL2BAN_ACTION_DIR/*) owner="root:root"; mode="0644" ;;
        $SYSTEMD_DIR/*) owner="root:root"; mode="0644" ;;
        *) owner="root:root"; mode="0644" ;;
    esac

    run_cmd chown "$owner" "$dst"
    run_cmd chmod "$mode" "$dst"
}

# ===== Deployment Steps =====
deploy_bin() {
    if confirm "Deploy bin scripts to $BIN_DIR?"; then
        copy_file "$TMP_DIR/bin/f2b-action-cloudflare-firewall-logger.sh" "$BIN_DIR/f2b-action-cloudflare-firewall-logger.sh"
        copy_file "$TMP_DIR/bin/f2b-service-cloudflare-firewall-sync.sh" "$BIN_DIR/f2b-service-cloudflare-firewall-sync.sh"
    else
        echo "Skipping bin deployment."
    fi
}

deploy_fail2ban_actions() {
    if [[ "$FAIL2BAN_AVAILABLE" == true ]]; then
        if confirm "Deploy Fail2Ban actions to $FAIL2BAN_ACTION_DIR?"; then
            copy_file "$TMP_DIR/fail2ban/action.d/cloudflare-firewall.conf" "$FAIL2BAN_ACTION_DIR/cloudflare-firewall.conf"
        else
            echo "Skipping Fail2Ban actions deployment."
        fi
    else
        echo "Fail2Ban not available. Skipping Fail2Ban actions."
    fi
}

deploy_systemd_units() {
    if confirm "Deploy systemd units to $SYSTEMD_DIR?"; then
        copy_file "$TMP_DIR/systemd/f2b-cloudflare-firewall-sync.path" "$SYSTEMD_DIR/f2b-cloudflare-firewall-sync.path"
        copy_file "$TMP_DIR/systemd/f2b-cloudflare-firewall-sync.service" "$SYSTEMD_DIR/f2b-cloudflare-firewall-sync.service"
        run_cmd systemctl daemon-reload
        if confirm "Enable and restart service $SERVICE_NAME?"; then
            run_cmd systemctl enable "$SERVICE_NAME"
            run_cmd systemctl restart "$SERVICE_NAME"
        else
            echo "Skipping service restart."
        fi
    else
        echo "Skipping systemd deployment."
    fi
}

cleanup_tmp() {
    if $DRY_RUN; then
        echo "[DRY-RUN] Would remove temporary directory $TMP_DIR"
        return
    fi

    [[ -d "$TMP_DIR" ]] || return

    if confirm "Clean up temporary directory $TMP_DIR?"; then
        run_cmd rm -rf "$TMP_DIR"
    else
        echo "Temporary directory retained at $TMP_DIR."
    fi
}

# ===== Main Flow =====
main() {
    parse_args "$@"

    # Environment check (injectable for testing)
    FAIL2BAN_AVAILABLE=$(check_environment)

    trap cleanup_tmp EXIT

    if [[ -d "$TMP_DIR" ]]; then
        confirm "Temporary directory $TMP_DIR exists. Remove and continue?" || { echo "Deployment aborted."; exit 4; }
        run_cmd rm -rf "$TMP_DIR"
    fi

    run_cmd git clone "$REPO_URL" "$TMP_DIR"

    # Verify expected files
    required_files=(
        "$TMP_DIR/bin/f2b-action-cloudflare-firewall-logger.sh"
        "$TMP_DIR/bin/f2b-service-cloudflare-firewall-sync.sh"
        "$TMP_DIR/fail2ban/action.d/cloudflare-firewall.conf"
        "$TMP_DIR/systemd/f2b-cloudflare-firewall-sync.service"
        "$TMP_DIR/systemd/f2b-cloudflare-firewall-sync.path"
    )

    for f in "${required_files[@]}"; do
        [[ -f "$f" ]] || { echo "Expected file $f missing in repo"; exit 3; }
    done

    deploy_bin
    deploy_fail2ban_actions
    deploy_systemd_units
}

# ===== Execute =====
# Only run main if the script is executed directly, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi