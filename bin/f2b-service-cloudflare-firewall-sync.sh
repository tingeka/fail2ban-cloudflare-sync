#!/bin/bash
# /usr/local/bin/f2b-cloudflare-sync.sh
#
# Sync Fail2Ban Cloudflare state files to Cloudflare API.
# Skips syncing if the state file hasn’t changed since last successful sync.
#
# Usage: run periodically (e.g., systemd timer or cron)

set -euo pipefail

readonly BASE_DIR="/run/fail2ban/cloudflare-firewall"
readonly DOMAINS_DIR="$BASE_DIR/domains"
readonly CACHE_DIR="$BASE_DIR/cache"
readonly LOGFILE="/var/log/fail2ban-cloudflare-firewall.log"
readonly API_ENDPOINT="https://endpoint.for.cloudflare.api/sync"  # Replace with actual endpoint

mkdir -p "$CACHE_DIR"

log() {
    printf '%s [cloudflare-firewall:sync] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE"
}

send_to_worker() {
    local domain="$1"
    local file="$2"

    log "Syncing domain '$domain' to Worker: $API_ENDPOINT"

    # Example API call, adapt the JSON payload and URL to your API endpoint
    # Here we assume the API expects the bans JSON as the request body.
    local response
    if ! response=$(curl -sS -X POST "$API_ENDPOINT" \
        -H "Content-Type: application/json" \
        --data @"$file"); then
        log "Error: Failed to reach Worker for domain '$domain'"
        return 1
    fi

    # Basic error check on API response (you might want to parse JSON here)
    if echo "$response" | grep -q '"success":false'; then
        log "Worker error syncing domain '$domain': $response"
        return 1
    fi

    log "Worker sync successful for domain '$domain'"
    return 0
}

main() {
    for domain_dir in "$DOMAINS_DIR"/*; do
        [[ -d "$domain_dir" ]] || continue
        local domain
        domain=$(basename "$domain_dir")
        local state_file="$domain_dir/state.json"
        [[ -f "$state_file" ]] || continue

        local checksum_file="$CACHE_DIR/$domain.sha256"

        # Calculate current checksum
        local current_checksum
        current_checksum=$(sha256sum "$state_file" | awk '{print $1}')

        # Read previous checksum if exists
        local previous_checksum=""
        if [[ -f "$checksum_file" ]]; then
            previous_checksum=$(<"$checksum_file")
        fi

        if [[ "$current_checksum" == "$previous_checksum" ]]; then
            log "No changes detected for '$domain', skipping sync."
            continue
        fi

        if send_to_worker "$domain" "$state_file"; then
            echo "$current_checksum" > "$checksum_file"
            log "Sync successful for '$domain'"
        else
            log "Sync failed for '$domain'; will retry on next run"
        fi
    done
}

main "$@"
