#!/usr/bin/env bats

setup() {
  TEST_SANDBOX="$(pwd)/test_sandbox_sync"
  export TEST_SANDBOX
  rm -rf "$TEST_SANDBOX"

  # Base dirs inside sandbox
  mkdir -p "$TEST_SANDBOX/base/domains"
  mkdir -p "$TEST_SANDBOX/base/cache"
  touch "$TEST_SANDBOX/test.log"

  # Override paths for the script
  export BASE_DIR="$TEST_SANDBOX/base"
  export DOMAINS_DIR="$BASE_DIR/domains"
  export CACHE_DIR="$BASE_DIR/cache"
  export LOGFILE="$TEST_SANDBOX/test.log"

  # Mock curl always succeeds by default
  mkdir -p "$TEST_SANDBOX/bin"
  cat > "$TEST_SANDBOX/bin/curl" <<'EOF'
#!/bin/bash
echo '{"success":true}'
EOF
  chmod +x "$TEST_SANDBOX/bin/curl"
  export PATH="$TEST_SANDBOX/bin:$PATH"

  # Use the real sync script
  WRAPPER="$(pwd)/bin/f2b-service-cloudflare-firewall-sync.sh"
}
teardown() {
  rm -rf "$TEST_SANDBOX"
}

# Helper to check log content
log_contains() {
  local pattern="$1"
  grep -q "$pattern" "$TEST_SANDBOX/test.log"
}

@test "sync creates checksum and logs for a single domain" {
  mkdir -p "$TEST_SANDBOX/base/domains/domain1.com"
  echo '{"domain":"domain1.com","bans":{}}' > "$TEST_SANDBOX/base/domains/domain1.com/state.json"

  run "$WRAPPER"
  [ "$status" -eq 0 ]
  [ -f "$TEST_SANDBOX/base/cache/domain1.com.sha256" ]
  log_contains "Sync successful for 'domain1.com'"
}

@test "sync skips domains with unchanged state file" {
  mkdir -p "$TEST_SANDBOX/base/domains/domain2.com"
  echo '{"domain":"domain2.com","bans":{}}' > "$TEST_SANDBOX/base/domains/domain2.com/state.json"

  # Precompute checksum
  sha256sum "$TEST_SANDBOX/base/domains/domain2.com/state.json" | awk '{print $1}' \
    > "$TEST_SANDBOX/base/cache/domain2.com.sha256"

  run "$WRAPPER"
  [ "$status" -eq 0 ]
  log_contains "No changes detected for 'domain2.com', skipping sync."
}

@test "sync handles multiple domains independently" {
  for d in domain3.com domain4.com; do
    mkdir -p "$TEST_SANDBOX/base/domains/$d"
    echo "{\"domain\":\"$d\",\"bans\":{}}" > "$TEST_SANDBOX/base/domains/$d/state.json"
  done

  run "$WRAPPER"
  [ "$status" -eq 0 ]
  for d in domain3.com domain4.com; do
    [ -f "$TEST_SANDBOX/base/cache/$d.sha256" ]
    log_contains "Sync successful for '$d'"
  done
}

@test "sync retries on API failure" {
  # Override mock curl to simulate failure
  cat > "$TEST_SANDBOX/bin/curl" <<'EOF'
#!/bin/bash
echo '{"success":false}'
EOF
  chmod +x "$TEST_SANDBOX/bin/curl"

  mkdir -p "$TEST_SANDBOX/base/domains/faildomain.com"
  echo '{"domain":"faildomain.com","bans":{}}' > "$TEST_SANDBOX/base/domains/faildomain.com/state.json"

  run "$WRAPPER"
  [ "$status" -eq 0 ]
  log_contains "Sync failed for 'faildomain.com'; will retry on next run"

  # Restore default mock curl
  cat > "$TEST_SANDBOX/bin/curl" <<'EOF'
#!/bin/bash
echo '{"success":true}'
EOF
  chmod +x "$TEST_SANDBOX/bin/curl"
}

@test "checksum updates only on successful sync" {
  mkdir -p "$TEST_SANDBOX/base/domains/domain5.com"
  echo '{"domain":"domain5.com","bans":{}}' > "$TEST_SANDBOX/base/domains/domain5.com/state.json"

  # First sync
  run "$WRAPPER"
  [ "$status" -eq 0 ]
  initial_checksum=$(<"$TEST_SANDBOX/base/cache/domain5.com.sha256")

  # Modify state file
  echo '{"domain":"domain5.com","bans":{"1.2.3.4":600}}' > "$TEST_SANDBOX/base/domains/domain5.com/state.json"

  run "$WRAPPER"
  [ "$status" -eq 0 ]
  new_checksum=$(<"$TEST_SANDBOX/base/cache/domain5.com.sha256")
  [ "$initial_checksum" != "$new_checksum" ]
}
