# AGENTS.md

## Project

VyOS route-loader that fetches non-China IP routes from an upstream GitHub source and injects them into the Linux kernel routing table for BGP redistribution.

## Upstream Data

- Route list: `https://raw.githubusercontent.com/helixzz/dobby-routes/data/cn_routes_inverse.txt`
- Format: one CIDR per line (IPv4), `#` comment header, ~13K routes
- Repo: `helixzz/dobby-routes`

## Target Environment

- VyOS router (Debian-based), VyOS 1.4.2+ required for `redistribute table`
- Routes go into a numbered routing table (e.g. `table 111`) via `ip route`
- Propagated via BGP — avoid mass churn
- Scheduled via VyOS `task-scheduler` (cron-like, runs every N hours)

## Key Constraints (from IDEA.md)

- **Smooth updates**: diff current vs fetched routes; add new, remove stale — no flush-and-reload to prevent BGP flapping
- **Private CIDR guard**: reject any route matching RFC 1918 / reserved ranges before injection (see `IDEA.md` for full list)
- **Daily cadence**: script runs periodically; must be idempotent and safe to re-run

## File Layout

```
dobby-routes-loader.sh        ← main script (fetch → validate → diff → batch apply)
dobby-routes-loader.conf      ← user-editable config (next-hop, table, interface, thresholds)
IDEA.md                     ← original requirements and legacy shell snippets
examples/vyos-config.md     ← VyOS deployment instructions
```

## Technical Decisions

- **`ip -batch -force`** for bulk route operations (750× faster than shell loops for 13K routes)
- **`ip route replace`** (not `add`) for idempotent additions
- **`proto static`** tag isolates managed routes from kernel/BGP routes in the same table
- **`ip -json` + `jq`** for reading kernel table (handles `/32` and blackhole; falls back to `awk`)
- **`comm`** on sorted lists for O(n) set diff (additions/deletions)
- **No `expires`** — IPv4 doesn't support it; diff-based cleanup is the TTL mechanism
- **`awk` single-pass** for private CIDR filtering (not per-line bash function calls)

## VyOS Gotchas

- Cron PATH is `/usr/bin:/bin` — script must `export PATH=/usr/sbin:/usr/bin:/sbin:/bin`
- Kernel routes don't survive reboot — must add loader to `/config/scripts/vyos-postconfig-bootup.script`
- Scripts must live under `/config/` to survive firmware upgrades
- `#!/bin/bash` (not `#!/bin/vbash`) — no VyOS config API needed

## Verification

```bash
# Dry run (no table changes)
bash dobby-routes-loader.sh --dry-run

# Shellcheck
shellcheck dobby-routes-loader.sh
```
