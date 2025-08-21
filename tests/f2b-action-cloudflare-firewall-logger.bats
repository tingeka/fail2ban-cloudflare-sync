#!/usr/bin/env bats

# --- Setup / Teardown ---
setup() {
  # Sandbox path
  TEST_SANDBOX="$(pwd)/test_sandbox"
  export TEST_SANDBOX
  rm -rf "$TEST_SANDBOX"

  # Absolute path to wrapper script
  WRAPPER="$(pwd)/tests/f2b-logger-wrapper.sh"
}

teardown() {
  rm -rf "$TEST_SANDBOX"
}

# Helper to check log content
log_contains() {
  local pattern="$1"
  grep -q "$pattern" "$TEST_SANDBOX/test.log"
}

# --- Argument validation tests ---
@test "fails with insufficient arguments" {
  run "$WRAPPER"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Usage:" ]]
}

@test "rejects invalid action" {
  run "$WRAPPER" invalid jail example.com
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Invalid action" ]]
}

# --- Start / Stop / Ban / Unban (sandboxed) ---
@test "start initializes domain dir, state file and logs" {
  run "$WRAPPER" start myjail example.com
  [ "$status" -eq 0 ]
  [ -d "$TEST_SANDBOX/base/domains/example.com" ]
  [ -f "$TEST_SANDBOX/base/domains/example.com/state.json" ]
  jq -e '.domain == "example.com"' "$TEST_SANDBOX/base/domains/example.com/state.json"
  log_contains "Starting jail 'myjail' for example.com"
}

@test "stop removes domain dir and logs" {
  "$WRAPPER" start myjail example.com
  run "$WRAPPER" stop myjail example.com
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SANDBOX/base/domains/example.com" ]
  log_contains "Stopping jail 'myjail' for example.com"
}

@test "ban requires IP" {
  "$WRAPPER" start jail example.com
  run "$WRAPPER" ban jail example.com
  [ "$status" -eq 1 ]
  [[ "$output" =~ "IP address required" ]]
}

@test "ban requires bantime" {
  "$WRAPPER" start jail example.com
  run "$WRAPPER" ban jail example.com 1.2.3.4
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Bantime" ]]
}

@test "ban adds IP to state file and logs" {
  "$WRAPPER" start jail example.com
  run "$WRAPPER" ban jail example.com 1.2.3.4 600
  [ "$status" -eq 0 ]
  jq -e '.bans["1.2.3.4"] == 600' "$TEST_SANDBOX/base/domains/example.com/state.json"
  log_contains "Banned 1.2.3.4 with bantime 600 seconds for example.com"
}

@test "unban removes IP from state file and logs" {
  "$WRAPPER" start jail example.com
  "$WRAPPER" ban jail example.com 1.2.3.4 600
  run "$WRAPPER" unban jail example.com 1.2.3.4
  [ "$status" -eq 0 ]
  jq -e 'has("bans") and (.bans["1.2.3.4"] | not)' "$TEST_SANDBOX/base/domains/example.com/state.json"
  log_contains "Unbanned 1.2.3.4 for example.com"
}

@test "corrupted state file is reinitialized and logs" {
  "$WRAPPER" start jail example.com
  echo "garbage" > "$TEST_SANDBOX/base/domains/example.com/state.json"
  run "$WRAPPER" ban jail example.com 1.2.3.4 600
  [ "$status" -eq 0 ]
  jq -e '.bans["1.2.3.4"] == 600' "$TEST_SANDBOX/base/domains/example.com/state.json"
  log_contains "Corrupted state file detected for example.com, reinitializing"
}

@test "concurrent bans do not corrupt state" {
  "$WRAPPER" start jail example.com
  (
    "$WRAPPER" ban jail example.com 1.2.3.4 600 &
    "$WRAPPER" ban jail example.com 5.6.7.8 300 &
    wait
  )
  jq -e '.bans["1.2.3.4"] == 600 and .bans["5.6.7.8"] == 300' \
    "$TEST_SANDBOX/base/domains/example.com/state.json"
  log_contains "Banned 1.2.3.4 with bantime 600 seconds for example.com"
  log_contains "Banned 5.6.7.8 with bantime 300 seconds for example.com"
}
