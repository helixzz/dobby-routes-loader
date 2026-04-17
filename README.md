# dobby-routes-loader

Bash script that fetches non-China IP routes from [dobby-routes](https://github.com/helixzz/dobby-routes) and incrementally syncs them into a Linux kernel routing table for BGP redistribution on VyOS routers.

## Why

If you run a VyOS router that peers via BGP and need to route non-China traffic through a specific gateway, this script keeps your routing table in sync with a daily-updated upstream list — without flushing the table or causing BGP flapping.

## How it works

```
Fetch upstream CIDRs ──► Validate & filter ──► Diff against kernel table ──► Batch apply deltas
```

1. **Fetch** — downloads ~13K IPv4 CIDRs from the [dobby-routes `data` branch](https://github.com/helixzz/dobby-routes/tree/data)
2. **Validate** — rejects malformed lines; aborts on corrupted data or suspiciously low route counts
3. **Guard** — single-pass `awk` filter drops any RFC 1918 / reserved CIDRs (14 ranges); aborts if too many are found
4. **Diff** — reads current kernel table via `ip -json`, computes additions and deletions with `comm`
5. **Apply** — writes batch files and executes via `ip -force -batch` (~750x faster than shell loops)
6. **Verify** — re-reads the table post-apply and logs any drift

## Quick start

```bash
# 1. Clone
git clone https://github.com/helixzz/dobby-routes-loader.git
cd dobby-routes-loader

# 2. Edit the config for your environment
vi dobby-routes-loader.conf

# 3. Dry run (no table changes)
bash dobby-routes-loader.sh --dry-run

# 4. Apply for real (requires root / ip route privileges)
sudo bash dobby-routes-loader.sh
```

## VyOS deployment

Copy both files to the router's persistent scripts directory:

```bash
scp dobby-routes-loader.sh dobby-routes-loader.conf vyos@router:/config/scripts/
ssh vyos@router chmod +x /config/scripts/dobby-routes-loader.sh
```

Configure the task scheduler and BGP redistribution:

```
configure

set system task-scheduler task dobby crontab-spec '0 */6 * * *'
set system task-scheduler task dobby executable path '/config/scripts/dobby-routes-loader.sh'
set protocols bgp address-family ipv4-unicast redistribute table 111

commit
save
```

Add to the boot hook so routes survive reboots:

```bash
echo '/config/scripts/dobby-routes-loader.sh' >> /config/scripts/vyos-postconfig-bootup.script
```

> **Requires VyOS 1.4.2+** for working `redistribute table`. See [examples/vyos-config.md](examples/vyos-config.md) for the full deployment guide and troubleshooting.

## Usage

```
dobby-routes-loader.sh [OPTIONS]

Options:
  --help          Show help and VyOS deployment instructions
  --dry-run       Fetch, validate, diff — but do not modify the routing table
  --config PATH   Path to config file (default: ./dobby-routes-loader.conf)
```

## Configuration

All settings live in `dobby-routes-loader.conf`. The script itself never needs editing.

| Variable | Default | Description |
|---|---|---|
| `UPSTREAM_URL` | dobby-routes `data` branch | URL of the upstream CIDR list |
| `ROUTE_TABLE` | `111` | Kernel routing table number |
| `NEXT_HOP` | `192.0.2.1` | Next-hop gateway for injected routes |
| `OUTGOING_DEV` | `eth0` | Outgoing interface |
| `PROTO` | `static` | Protocol tag isolating managed routes |
| `STATE_DIR` | `/config/user-data/dobby-routes-loader` | Persistent state directory |
| `MIN_ROUTE_COUNT` | `1000` | Abort if upstream has fewer routes than this |
| `MAX_PRIVATE_CIDRS` | `10` | Abort if more than N reserved CIDRs found |
| `CURL_TIMEOUT` | `60` | Fetch timeout in seconds |
| `CURL_RETRIES` | `3` | Fetch retry count |

## Safety mechanisms

- **Private CIDR guard** — rejects RFC 1918, CGNAT, loopback, link-local, multicast, and other reserved ranges
- **Minimum route count** — aborts if the upstream list looks truncated or empty
- **Incremental diff** — only adds/removes changed routes; no table flush
- **`ip route replace`** — idempotent; safe to re-run at any time
- **`flock`** — prevents concurrent runs from overlapping
- **`proto static` isolation** — never touches kernel, DHCP, or BGP routes in the same table

## Related projects

- **[dobby-routes](https://github.com/helixzz/dobby-routes)** — upstream route data generator. Produces the daily-updated `cn_routes_inverse.txt` (inverse of China mainland routes) from APNIC delegation data and operator IP feeds. This loader consumes that data.

## Requirements

- Bash 4+
- `curl`, `awk`, `comm`, `sort`, `mktemp`, `flock` (all standard on Debian/VyOS)
- `jq` (recommended; script falls back to `awk` parsing if absent)
- `ip` (iproute2)
- Root privileges (for `ip route` operations)

## License

[Apache-2.0](LICENSE)
