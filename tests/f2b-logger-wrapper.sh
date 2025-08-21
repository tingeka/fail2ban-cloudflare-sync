#!/bin/bash
# Wrapper to run f2b-action-cloudflare-logger.sh in a sandbox

set -euo pipefail

export TEST_SANDBOX="${TEST_SANDBOX:-$(pwd)/test_sandbox}"
mkdir -p "$TEST_SANDBOX"

export BASE_DIR="$TEST_SANDBOX/base"
export LOGFILE="$TEST_SANDBOX/test.log"
mkdir -p "$BASE_DIR/domains"

# Resolve logger script path absolutely
SCRIPT="$(pwd)/bin/f2b-action-cloudflare-firewall-logger.sh"

"$SCRIPT" "$@"
