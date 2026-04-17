# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-04-17

### Added

- `dobby-routes-loader.sh` — main script implementing the full sync pipeline:
  fetch, validate, private CIDR guard, diff, batch apply, post-apply verification.
- `dobby-routes-loader.conf` — external config file for per-deployment settings
  (next-hop, table number, interface, thresholds).
- `examples/vyos-config.md` — VyOS deployment guide covering task-scheduler,
  boot persistence, BGP redistribution, and troubleshooting.
- `--dry-run` mode to preview changes without modifying the routing table.
- `--config PATH` option to use a non-default config file.
- `flock`-based concurrency guard to prevent overlapping runs.
- Private/reserved CIDR filter covering RFC 1918, CGNAT, loopback, link-local,
  TEST-NETs, benchmarking, multicast, and future-use ranges.
- Minimum route count safety gate to protect against truncated upstream data.
- `ip -batch -force` for bulk route operations instead of per-route shell loops.
- `ip -json` + `jq` for reliable kernel table reads, with `awk` fallback.
- `proto static` tagging to isolate managed routes from kernel/BGP entries.
- Post-apply drift detection with syslog warnings.
- State persistence (`last-applied.txt`, `last-run`) under a configurable directory.

[0.1.0]: https://github.com/helixzz/dobby-routes-loader/releases/tag/v0.1.0
