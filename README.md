# Fail2Ban Cloudflare Sync

A service that bridges fail2ban actions with Cloudflare's firewall API through an event-driven architecture. Instead of making direct API calls from fail2ban, this system writes ban events to JSON state files and syncs them to Cloudflare via a worker endpoint.

## Overview

### Why This Repository Exists

This project originated from [fail2ban-rules](https://github.com/tingeka/fail2ban-rules), which grew beyond its original scope to include custom scripts, API integrations, and system services. To improve maintainability and modularity, the functionality was split:

- **fail2ban-rules**: Core fail2ban configurations (jails, filters, actions)
- **fail2ban-cloudflare-sync**: Cloudflare API integration layer

This separation allows each component to be used independently or together as needed.

### Architecture

The system uses an event-driven approach that decouples fail2ban from Cloudflare API calls:

```
fail2ban → JSON state files → systemd path watcher → sync service → Cloudflare Worker → Cloudflare API
```

**Key Benefits:**
- No API tokens stored on the fail2ban server
- Atomic JSON operations prevent race conditions
- Batched updates reduce API calls
- Works with multiple domains independently

## Components

### Core Components

- **Fail2Ban Action** (`cloudflare-firewall.conf`): Integrates with fail2ban's action system
- **Action Logger** (`f2b-action-cloudflare-firewall-logger.sh`): Receives fail2ban events and maintains JSON state files with deduplication logic
- **Sync Service** (`f2b-service-cloudflare-firewall-sync.sh`): Processes state changes and calls the worker API
- **Systemd Path Unit** (`f2b-cloudflare-firewall-sync.path`): Monitors state directory for changes
- **Systemd Service Unit** (`f2b-cloudflare-firewall-sync.service`): Run the sync service when path triggers.

### Design Decisions

**Deduplication Strategy:** When multiple jails target the same IP address, the system uses the "longest bantime wins" approach. This prevents situations where a shorter ban duration would accidentally reduce an existing longer ban.

**State-based Sync:** Rather than sending individual ban/unban commands, the system maintains complete state files and syncs the entire ban list. This approach is more reliable for maintaining consistency between the local state and Cloudflare's firewall rules.

### Data Flow

1. fail2ban detects an attack and triggers the configured action
2. Action logger receives the ban/unban event and updates the JSON state file
3. Systemd path unit detects the file change and triggers the sync service
4. Sync service reads the state and sends it to the Cloudflare Worker
5. Worker authenticates with Cloudflare API and updates firewall rules

## Installation

### Prerequisites

- fail2ban installed and running
- systemd
- `jq` for JSON processing
- `curl` for HTTP requests
- Deployed [Cloudflare Worker](https://github.com/tingeka/fail2ban-cloudflare-worker)

### Quick Install

```bash
curl -s https://raw.githubusercontent.com/tingeka/fail2ban-cloudflare-sync/main/install.sh | sudo bash
```

### Manual Installation

1. **Install scripts:**
   ```bash
   sudo cp bin/f2b-action-cloudflare-firewall-logger.sh /usr/local/bin/
   sudo cp bin/f2b-service-cloudflare-sync.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/f2b-*
   ```

2. **Install fail2ban action:**
   ```bash
   sudo cp fail2ban/action.d/cloudflare-firewall.conf /etc/fail2ban/action.d/
   ```

3. **Install and enable systemd units:**
   ```bash
   sudo cp systemd/f2b-cloudflare-firewall-sync.* /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable f2b-cloudflare-firewall-sync.path
   sudo systemctl start f2b-cloudflare-firewall-sync.path
   ```

## Configuration

### Cloudflare Worker Setup

Deploy the [fail2ban-cloudflare-worker](https://github.com/tingeka/fail2ban-cloudflare-worker) to your Cloudflare account with these environment variables:

- `ALLOWED_DOMAINS`: Comma-separated list of domains to protect
- `ALLOWED_IPS`: (Optional) IP addresses allowed to call the API
- `RULE_NAME`: Name for the firewall rule (e.g., "fail2ban")
- `ZONE_ID_<DOMAIN>`: Cloudflare Zone ID for each domain
- `API_TOKEN_<DOMAIN>`: Cloudflare API token for each domain

### Sync Service Configuration

Edit `/usr/local/bin/f2b-service-cloudflare-sync.sh` and update:
```bash
readonly API_ENDPOINT="https://your-worker.your-account.workers.dev/api/sync"
```

### Fail2Ban Integration

Add the cloudflare-firewall action to your jail configurations:

```ini
[jail-name]
enabled = true
filter = your-filter
action = cloudflare-firewall[domain=example.com]
logpath = /var/log/your-application.log
```

The `domain` parameter groups bans by domain, enabling multi-site management.

## Usage

### Operation

Once configured, the system operates automatically. Monitor operation through:

```bash
# Action logger events
sudo tail -f /var/log/fail2ban-cloudflare-firewall.log

# Sync service activity
sudo tail -f /var/log/fail2ban-cloudflare-sync.log

# Systemd service status
sudo systemctl status f2b-cloudflare-firewall-sync.path
```

### State Files

State files are stored in `/run/fail2ban/cloudflare-firewall/domains/` with this structure:

```json
{
  "domain": "example.com",
  "bans": {
    "192.168.1.100": 3600,
    "10.0.0.50": 7200
  }
}
```

**State Management Logic:**
- Each IP address maps to its ban duration in seconds
- When multiple jails ban the same IP with different durations, the **longest bantime wins**
- This prevents shorter bans from overriding longer ones (e.g., a 1-hour ban won't reduce an existing 24-hour ban)
- All ban/unban operations happen locally before syncing to Cloudflare
- The entire state file is sent to the worker on each sync (no partial updates)

## Troubleshooting

### Common Issues

**State files not being created**
- Verify jail configuration includes the cloudflare-firewall action
- Check script permissions and fail2ban logs
- Review `/var/log/fail2ban-cloudflare-firewall.log`

**Sync service not triggering**
- Check systemd path unit status: `systemctl status f2b-cloudflare-firewall-sync.path`
- Verify file system events: `journalctl -u f2b-cloudflare-firewall-sync.service`

**API calls failing**
- Confirm worker endpoint is accessible
- Check Cloudflare Worker logs for authentication issues
- Verify ALLOWED_DOMAINS and ALLOWED_IPS configuration
- Review `/var/log/fail2ban-cloudflare-sync.log` for HTTP responses

### Debug Mode

Enable verbose logging by adding `set -x` to the shell scripts for detailed execution traces.

## Related Projects

- **[fail2ban-rules](https://github.com/tingeka/fail2ban-rules)** - WordPress-focused fail2ban configurations and deployment scripts
- **[fail2ban-cloudflare-worker](https://github.com/tingeka/fail2ban-cloudflare-worker)** - Cloudflare Worker that handles API authentication and firewall rule management

### Integration Options

- **Complete setup**: All three repositories together for WordPress + Cloudflare protection
- **Custom rules**: This repository + worker with your own fail2ban configurations  
- **Standard blocking**: fail2ban-rules alone for iptables-based protection