#!/bin/bash
# tests/f2b-sync-wrapper.sh

set -euo pipefail

export TEST_SANDBOX="${TEST_SANDBOX:-$(pwd)/test_sandbox_sync}"
mkdir -p "$TEST_SANDBOX/base/domains" "$TEST_SANDBOX/base/cache"

export BASE_DIR="$TEST_SANDBOX/base"
export DOMAINS_DIR="$BASE_DIR/domains"
export CACHE_DIR="$BASE_DIR/cache"
export LOGFILE="$TEST_SANDBOX/test.log"

# Resolve script path relative to wrapper location
SCRIPT="$(dirname "$0")/../bin/f2b-service-cloudflare-firewall-sync.sh"

"$SCRIPT" "$@"
