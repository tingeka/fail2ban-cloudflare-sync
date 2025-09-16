#!/bin/bash
# /usr/local/bin/f2b-action-cloudflare-logger.sh
#
# Unified JSON-based Fail2Ban action handler that maintains a single state file
# per domain containing all active bans. Uses jq for atomic JSON operations
# to minimize Bash complexity and overhead.

set -euo pipefail

# Configuration
: "${BASE_DIR:=/run/fail2ban/cloudflare-firewall}"
: "${LOGFILE:=/var/log/fail2ban-cloudflare-firewall.log}"
readonly BASE_DIR LOGFILE

# Validate arguments early
if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <ban|unban|start|stop> <jail> <domain> [ip] [bantime]" >&2
    exit 1
fi

readonly ACTION="$1"
readonly JAIL="$2"
readonly DOMAIN="$3"
readonly IP="${4:-}"
readonly BANTIME="${5:-}"

# Paths
readonly DOMAINS_DIR="$BASE_DIR/domains"
readonly DOMAIN_DIR="$DOMAINS_DIR/$DOMAIN"
readonly STATE_FILE="$DOMAIN_DIR/state.json"
readonly LOCK_FILE="$DOMAIN_DIR/state.lock"

# Marker file for systemd .path unit
readonly TRIGGER_FILE="$BASE_DIR/state.changed"

# shellcheck disable=SC2329
cleanup_on_exit() {
    exec 200>&- 2>/dev/null || true
}
trap cleanup_on_exit EXIT

log() {
    printf '%s [cloudflare-firewall:logger] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE"
}

init_state_file() {
    if [[ -f "$STATE_FILE" ]]; then
        if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
            log "Corrupted state file detected for $DOMAIN, reinitializing"
            echo "{\"domain\":\"$DOMAIN\", \"bans\":{}}" > "$STATE_FILE" || {
                echo "Failed to reinitialize state file" >&2
                return 1
            }
        fi
    else
        echo "{\"domain\":\"$DOMAIN\", \"bans\":{}}" > "$STATE_FILE" || {
            echo "Failed to create state file" >&2
            return 1
        }
    fi
}

atomic_json_update() {
    local temp_file

    if ! temp_file=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null); then
        echo "Failed to create temporary file (disk full?)" >&2
        return 1
    fi

    exec 200>"$LOCK_FILE"
    if ! flock -x -w 10 200; then
        rm -f "$temp_file"
        echo "Failed to acquire lock within 10 seconds" >&2
        return 1
    fi

    if ! init_state_file; then
        rm -f "$temp_file"
        exec 200>&-
        return 1
    fi

    # Forward all arguments to jq
    if jq "$@" "$STATE_FILE" > "$temp_file" 2>/dev/null && mv "$temp_file" "$STATE_FILE" 2>/dev/null; then
        exec 200>&-
        return 0
    else
        local jq_exit=$?
        rm -f "$temp_file"
        exec 200>&-
        echo "JSON update failed (jq exit code: $jq_exit)" >&2
        return 1
    fi
}

case "$ACTION" in
    start)
        if ! mkdir -p "$DOMAIN_DIR" 2>/dev/null; then
            echo "Failed to create domain directory: $DOMAIN_DIR" >&2
            exit 1
        fi

        chmod 750 "$DOMAIN_DIR" 2>/dev/null || {
            echo "Failed to set permissions on domain directory" >&2
            exit 1
        }
        chown root:root "$DOMAIN_DIR" 2>/dev/null || true

        touch "$LOCK_FILE" || {
            echo "Failed to create lock file" >&2
            exit 1
        }

        if ! init_state_file; then
            echo "Failed to initialize state file" >&2
            exit 1
        fi

        log "Starting jail '$JAIL' for $DOMAIN"
        echo "Initialized jail '$JAIL' for $DOMAIN" >&2
        # Touch trigger file for systemd
        touch "$TRIGGER_FILE"
        ;;

    stop)
        if [[ -d "$DOMAIN_DIR" ]]; then
            rm -rf "$DOMAIN_DIR" 2>/dev/null || {
                log "Warning: Failed to remove domain directory: $DOMAIN_DIR"
            }
        fi

        log "Stopping jail '$JAIL' for $DOMAIN"
        echo "Stopped jail '$JAIL' for $DOMAIN" >&2
        # Touch trigger file for systemd
        touch "$TRIGGER_FILE"
        ;;

    ban)
        if [[ -z "$IP" ]]; then
            echo "IP address required for ban action" >&2
            exit 1
        fi

        if [[ -z "$BANTIME" ]]; then
            echo "Bantime (seconds) required for ban action" >&2
            exit 1
        fi

        # shellcheck disable=SC2016
        ban_filter='.bans[$ip] |= (if . == null or . < ($bantime | tonumber) then ($bantime | tonumber) else . end)'

        if atomic_json_update --arg ip "$IP" --argjson bantime "$BANTIME" "$ban_filter"; then
            log "Banned $IP with bantime $BANTIME seconds for $DOMAIN"
            echo "Banned $IP with bantime $BANTIME seconds for $DOMAIN" >&2
        else
            echo "Failed to update state for ban: $IP" >&2
            exit 1
        fi
        # Touch trigger file for systemd
        touch "$TRIGGER_FILE"
        ;;

    unban)
        if [[ -z "$IP" ]]; then
            echo "IP address required for unban action" >&2
            exit 1
        fi

        # shellcheck disable=SC2016
        unban_filter='del(.bans[$ip])'

        if atomic_json_update --arg ip "$IP" "$unban_filter"; then
            log "Unbanned $IP for $DOMAIN"
            echo "Unbanned $IP for $DOMAIN" >&2
        else
            echo "Failed to update state for unban: $IP" >&2
            exit 1
        fi
        # Touch trigger file for systemd
        touch "$TRIGGER_FILE"
        ;;

    *)
        echo "Invalid action: $ACTION (must be 'ban', 'unban', 'start', or 'stop')" >&2
        exit 1
        ;;
esac

exit 0
