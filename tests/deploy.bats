#!/usr/bin/env bats

setup() {
    # ===== Create sandbox inside repo =====
    export SANDBOX="./tests/sandbox"
    rm -rf "$SANDBOX"
    
    export TEST_SANDBOX="$SANDBOX/deploy"
    rm -rf "$TEST_SANDBOX"
    mkdir -p "$TEST_SANDBOX"

    export BIN_DIR="$TEST_SANDBOX/bin"
    export FAIL2BAN_ACTION_DIR="$TEST_SANDBOX/f2ban_action"
    export SYSTEMD_DIR="$TEST_SANDBOX/systemd"
    export TMP_DIR="$TEST_SANDBOX/deploy_tmp"
    export REPO_URL="https://github.com/tingeka/fail2ban-cloudflare-sync.git"
    export FORCE=true
    export DRY_RUN=false

    mkdir -p "$BIN_DIR" "$FAIL2BAN_ACTION_DIR" "$SYSTEMD_DIR"

    # ===== Stub systemctl to avoid touching real system =====
    export PATH="$TEST_SANDBOX/mockbin:$PATH"
    mkdir -p "$TEST_SANDBOX/mockbin"
    cat > "$TEST_SANDBOX/mockbin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl called $*"
EOF
    chmod +x "$TEST_SANDBOX/mockbin/systemctl"

    # ===== Allow environment check to succeed =====
    # shellcheck disable=SC2329
    check_environment() { echo true; }

    # ===== Source the real deploy script =====
    # shellcheck disable=SC1091
    source ./deploy.sh
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "full deployment sandbox" {
    # Run main with force to skip confirmations
    run main --force

    # Check exit status
    [ "$status" -eq 0 ]

    # Git clone should appear in output
    [[ "$output" == *"git clone"* ]]

    # Bin deployment
    [[ "$output" == *"cp -v $TMP_DIR/bin/f2b-action-cloudflare-firewall-logger.sh $BIN_DIR/f2b-action-cloudflare-firewall-logger.sh"* ]]
    [[ "$output" == *"cp -v $TMP_DIR/bin/f2b-service-cloudflare-firewall-sync.sh $BIN_DIR/f2b-service-cloudflare-firewall-sync.sh"* ]]

    # Fail2Ban deployment (sandboxed)
    [[ "$output" == *"Fail2Ban not available. Skipping Fail2Ban actions."* ]] || [[ "$output" == *"cp -v"* ]] 

    # Systemd (stubbed)
    [[ "$output" == *"systemctl called daemon-reload"* ]]
    [[ "$output" == *"systemctl called enable"* ]]
    [[ "$output" == *"systemctl called restart"* ]]

    # TMP_DIR cleanup
    [[ "$output" == *"rm -rf $TEST_SANDBOX"* ]]
}
