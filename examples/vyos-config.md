# VyOS Deployment Guide for dobby-routes-loader

## Prerequisites

- VyOS **1.4.2 or later** (for working `redistribute table` in BGP)
  - Ideally VyOS **1.4.4+** with FRR 10.2 to avoid the FRR table-direct regression
- Network connectivity to `raw.githubusercontent.com`
- BGP peering already configured

## Installation

```bash
# Copy the script and config to the persistent scripts directory
# (survives VyOS firmware upgrades)
scp dobby-routes-loader.sh dobby-routes-loader.conf vyos@router:/config/scripts/

# SSH into the router
ssh vyos@router

# Make executable
chmod +x /config/scripts/dobby-routes-loader.sh
```

## Configuration

Edit `/config/scripts/dobby-routes-loader.conf` to match your environment:

```bash
NEXT_HOP="192.0.2.1"       # Your BGP peering gateway
OUTGOING_DEV="eth0"        # Interface toward the next-hop
ROUTE_TABLE=111             # Routing table number
```

## VyOS Task Scheduler

```bash
configure

# Run every 6 hours
set system task-scheduler task dobby crontab-spec '0 */6 * * *'
set system task-scheduler task dobby executable path '/config/scripts/dobby-routes-loader.sh'

commit
save
```

## Boot Persistence

Routes in the kernel table don't survive reboots.
Add the loader to the post-config boot hook so it repopulates on startup:

```bash
echo '/config/scripts/dobby-routes-loader.sh' >> /config/scripts/vyos-postconfig-bootup.script
```

## BGP Redistribution

```bash
configure

set protocols bgp address-family ipv4-unicast redistribute table 111

# Optional: attach a route-map for filtering or metric control
# set protocols bgp address-family ipv4-unicast redistribute table 111 route-map DOBBY-ROUTES-OUT

commit
save
```

## Manual Operations

```bash
# First run / force sync now
/config/scripts/dobby-routes-loader.sh

# Preview what would change without modifying the table
/config/scripts/dobby-routes-loader.sh --dry-run

# Check logs
journalctl -t dobby-routes-loader --since today

# Verify routes are in the table
ip route show table 111 proto static | head -20
ip route show table 111 proto static | wc -l

# Verify BGP is redistributing
show bgp ipv4 unicast summary
```

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Script not running on schedule | `cat /etc/cron.d/vyos-crontab` — is the entry there? |
| `ip: command not found` | Script must have `export PATH=/usr/sbin:/usr/bin:/sbin:/bin` (already included) |
| Routes disappear after reboot | Verify `/config/scripts/vyos-postconfig-bootup.script` contains the loader path |
| BGP not advertising routes | Confirm `redistribute table 111` is committed; check VyOS version ≥ 1.4.2 |
| `jq: command not found` warnings | Non-critical — script falls back to awk parsing. Install jq for robustness: `sudo apt install jq` |
