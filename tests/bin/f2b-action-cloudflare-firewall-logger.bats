#!/usr/bin/env bats

# ===== Setup / Teardown =====
setup() {

    export SANDBOX="./tests/sandbox"
    rm -rf "$SANDBOX"
    
    # Clean and create sandbox
    export TEST_SANDBOX="./tests/sandbox/f2b-service-cloudflare-firewall-logger"
    rm -rf "$TEST_SANDBOX"
    mkdir -p "$TEST_SANDBOX"
    
    # Set up environment variables (from wrapper)
    export BASE_DIR="$TEST_SANDBOX/base"
    export LOGFILE="$TEST_SANDBOX/test.log"
    mkdir -p "$BASE_DIR/domains"
    
    # Script path
    SCRIPT="$(pwd)/bin/f2b-action-cloudflare-firewall-logger.sh"
}

teardown() {
  rm -rf "$SANDBOX"
}

# Helper to check log content
log_contains() {
  local pattern="$1"
  grep -q "$pattern" "$TEST_SANDBOX/test.log"
}

# ===== Argument validation tests =====
@test "fails with insufficient arguments" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Usage:" ]]
}

@test "rejects invalid action" {
  run "$SCRIPT" invalid jail example.com
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Invalid action" ]]
}

# ===== Start / Stop / Ban / Unban (sandboxed) =====
@test "start initializes domain dir, state file and logs" {
  run "$SCRIPT" start myjail example.com
  [ "$status" -eq 0 ]
  [ -d "$TEST_SANDBOX/base/domains/example.com" ]
  [ -f "$TEST_SANDBOX/base/domains/example.com/state.json" ]
  jq -e '.domain == "example.com"' "$TEST_SANDBOX/base/domains/example.com/state.json"
  log_contains "Starting jail 'myjail' for example.com"
}

@test "stop removes domain dir and logs" {
  "$SCRIPT" start myjail example.com
  run "$SCRIPT" stop myjail example.com
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SANDBOX/base/domains/example.com" ]
  log_contains "Stopping jail 'myjail' for example.com"
}

@test "ban requires IP" {
  "$SCRIPT" start jail example.com
  run "$SCRIPT" ban jail example.com
  [ "$status" -eq 1 ]
  [[ "$output" =~ "IP address required" ]]
}

@test "ban requires bantime" {
  "$SCRIPT" start jail example.com
  run "$SCRIPT" ban jail example.com 1.2.3.4
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Bantime" ]]
}

@test "ban adds IP to state file and logs" {
  "$SCRIPT" start jail example.com
  run "$SCRIPT" ban jail example.com 1.2.3.4 600
  [ "$status" -eq 0 ]
  jq -e '.bans["1.2.3.4"] == 600' "$TEST_SANDBOX/base/domains/example.com/state.json"
  log_contains "Banned 1.2.3.4 with bantime 600 seconds for example.com"
}

@test "unban removes IP from state file and logs" {
  "$SCRIPT" start jail example.com
  "$SCRIPT" ban jail example.com 1.2.3.4 600
  run "$SCRIPT" unban jail example.com 1.2.3.4
  [ "$status" -eq 0 ]
  jq -e 'has("bans") and (.bans["1.2.3.4"] | not)' "$TEST_SANDBOX/base/domains/example.com/state.json"
  log_contains "Unbanned 1.2.3.4 for example.com"
}

@test "corrupted state file is reinitialized and logs" {
  "$SCRIPT" start jail example.com
  echo "garbage" > "$TEST_SANDBOX/base/domains/example.com/state.json"
  run "$SCRIPT" ban jail example.com 1.2.3.4 600
  [ "$status" -eq 0 ]
  jq -e '.bans["1.2.3.4"] == 600' "$TEST_SANDBOX/base/domains/example.com/state.json"
  log_contains "Corrupted state file detected for example.com, reinitializing"
}

@test "concurrent bans do not corrupt state" {
  "$SCRIPT" start jail example.com
  (
    "$SCRIPT" ban jail example.com 1.2.3.4 600 &
    "$SCRIPT" ban jail example.com 5.6.7.8 300 &
    wait
  )
  jq -e '.bans["1.2.3.4"] == 600 and .bans["5.6.7.8"] == 300' \
    "$TEST_SANDBOX/base/domains/example.com/state.json"
  log_contains "Banned 1.2.3.4 with bantime 600 seconds for example.com"
  log_contains "Banned 5.6.7.8 with bantime 300 seconds for example.com"
}

# ===== Trigger file =====

@test "trigger file is touched on ban" {
  "$SCRIPT" start jail example.com
  rm -f "$BASE_DIR/state.changed"
  run "$SCRIPT" ban jail example.com 1.2.3.4 600
  [ "$status" -eq 0 ]
  [ -f "$BASE_DIR/state.changed" ]
}

@test "trigger file is touched on unban" {
  "$SCRIPT" start jail example.com
  "$SCRIPT" ban jail example.com 1.2.3.4 600
  rm -f "$BASE_DIR/state.changed"
  run "$SCRIPT" unban jail example.com 1.2.3.4
  [ "$status" -eq 0 ]
  [ -f "$BASE_DIR/state.changed" ]
}

@test "concurrent updates leave state valid and trigger file exists" {
  "$SCRIPT" start jail example.com
  rm -f "$BASE_DIR/state.changed"
  (
    "$SCRIPT" ban jail example.com 1.2.3.4 600 &
    "$SCRIPT" ban jail example.com 5.6.7.8 300 &
    "$SCRIPT" unban jail example.com 1.2.3.4 &
    wait
  )
  jq -e '.bans["5.6.7.8"] == 300 and (.bans["1.2.3.4"] | not)' \
    "$TEST_SANDBOX/base/domains/example.com/state.json"
  [ -f "$BASE_DIR/state.changed" ]
}

@test "multiple consecutive changes update trigger file timestamp" {
  "$SCRIPT" start jail example.com
  run "$SCRIPT" ban jail example.com 1.2.3.4 600
  TS1=$(stat -c %Y "$BASE_DIR/state.changed")
  sleep 1
  run "$SCRIPT" ban jail example.com 5.6.7.8 300
  TS2=$(stat -c %Y "$BASE_DIR/state.changed")
  [ "$TS2" -gt "$TS1" ]
}