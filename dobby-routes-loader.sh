#!/bin/bash
# dobby-routes-loader — Fetch non-China routes and sync them into a Linux routing table.
# Designed for VyOS routers with BGP redistribution from a numbered table.
#
# Usage: dobby-routes-loader.sh [--help] [--dry-run] [--config PATH]
#
# See dobby-routes-loader.conf for configuration.

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ---------------------------------------------------------------------------
# Defaults (overridden by config file)
# ---------------------------------------------------------------------------
UPSTREAM_URL=""
ROUTE_TABLE=111
NEXT_HOP=""
OUTGOING_DEV=""
PROTO="static"
LOG_TAG="dobby-routes-loader"
STATE_DIR="/config/user-data/dobby-routes-loader"
MIN_ROUTE_COUNT=1000
MAX_PRIVATE_CIDRS=10
CURL_TIMEOUT=60
CURL_RETRIES=3

# ---------------------------------------------------------------------------
# Runtime flags
# ---------------------------------------------------------------------------
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/dobby-routes-loader.conf"
LOCK_FILE="/var/lock/dobby-routes-loader.lock"
LOCK_FD=9
TMPDIR_WORK=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_info()  { logger -t "$LOG_TAG" -p user.info  -- "$*"; echo "[INFO]  $*"; }
log_warn()  { logger -t "$LOG_TAG" -p user.warning -- "$*"; echo "[WARN]  $*" >&2; }
log_err()   { logger -t "$LOG_TAG" -p user.err -- "$*"; echo "[ERROR] $*" >&2; }

die() { log_err "$*"; exit 1; }

cleanup() {
    [[ -n "${TMPDIR_WORK}" && -d "${TMPDIR_WORK}" ]] && rm -rf "${TMPDIR_WORK}"
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
dobby-routes-loader — sync non-China routes into a kernel routing table

Usage:
  dobby-routes-loader.sh [OPTIONS]

Options:
  --help          Show this help and VyOS deployment instructions
  --dry-run       Fetch, validate, diff — but do not modify the routing table
  --config PATH   Path to config file (default: ./dobby-routes-loader.conf)

VyOS deployment:

  # 1. Copy files to the persistent scripts directory:
  cp dobby-routes-loader.sh dobby-routes-loader.conf /config/scripts/
  chmod +x /config/scripts/dobby-routes-loader.sh

  # 2. Configure the task scheduler (runs every 6 hours):
  configure
  set system task-scheduler task dobby crontab-spec '0 */6 * * *'
  set system task-scheduler task dobby executable path '/config/scripts/dobby-routes-loader.sh'
  commit
  save

  # 3. Repopulate routes on boot — add to post-config hook:
  echo '/config/scripts/dobby-routes-loader.sh' >> /config/scripts/vyos-postconfig-bootup.script

  # 4. BGP redistribution (VyOS 1.4.2+):
  configure
  set protocols bgp address-family ipv4-unicast redistribute table 111
  commit
  save
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Phase 0: Parse arguments & load config
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)     usage ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --config)   CONF_FILE="$2"; shift 2 ;;
        *)          die "Unknown option: $1. Use --help for usage." ;;
    esac
done

[[ -f "$CONF_FILE" ]] || die "Config file not found: $CONF_FILE"
# shellcheck source=dobby-routes-loader.conf
source "$CONF_FILE"

[[ -n "$UPSTREAM_URL" ]] || die "UPSTREAM_URL is not set in $CONF_FILE"
[[ -n "$NEXT_HOP" ]]     || die "NEXT_HOP is not set in $CONF_FILE"
[[ -n "$OUTGOING_DEV" ]] || die "OUTGOING_DEV is not set in $CONF_FILE"

# ---------------------------------------------------------------------------
# Phase 1: Setup — temp dir, state dir, flock
# ---------------------------------------------------------------------------
TMPDIR_WORK="$(mktemp -d /tmp/dobby-routes-loader.XXXXXX)"
mkdir -p "$STATE_DIR"

# Acquire exclusive lock (non-blocking). Exit if another instance is running.
exec 9>"$LOCK_FILE"
if ! flock -n $LOCK_FD; then
    log_info "Another instance is already running. Exiting."
    exit 0
fi

log_info "Starting route sync (dry_run=$DRY_RUN)"

# ---------------------------------------------------------------------------
# Phase 2: Fetch upstream route list
# ---------------------------------------------------------------------------
raw_file="${TMPDIR_WORK}/upstream_raw.txt"

if ! curl -fsSL --max-time "$CURL_TIMEOUT" --retry "$CURL_RETRIES" \
     -o "$raw_file" "$UPSTREAM_URL"; then
    die "Failed to fetch upstream route list from $UPSTREAM_URL"
fi

header_count=""
if head -5 "$raw_file" | grep -q '^# Total routes:'; then
    header_count=$(head -5 "$raw_file" | grep '^# Total routes:' \
                   | sed 's/[^0-9]//g')
fi

routes_raw="${TMPDIR_WORK}/routes_raw.txt"
grep -v '^#' "$raw_file" | grep -v '^[[:space:]]*$' > "$routes_raw" || true

invalid_lines="${TMPDIR_WORK}/invalid_lines.txt"
grep -Evx '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$routes_raw" \
    > "$invalid_lines" 2>/dev/null || true

if [[ -s "$invalid_lines" ]]; then
    bad_count=$(wc -l < "$invalid_lines")
    log_err "Upstream contains $bad_count malformed line(s). First 5:"
    head -5 "$invalid_lines" | while IFS= read -r line; do
        log_err "  >> $line"
    done
    die "Aborting — upstream data is corrupted."
fi

fetched_count=$(wc -l < "$routes_raw")

if [[ "$fetched_count" -lt "$MIN_ROUTE_COUNT" ]]; then
    die "Upstream has only $fetched_count routes (minimum: $MIN_ROUTE_COUNT). Aborting to protect the table."
fi

if [[ -n "$header_count" && "$header_count" != "$fetched_count" ]]; then
    log_warn "Header claims $header_count routes but parsed $fetched_count — possible truncation."
fi

log_info "Fetched $fetched_count routes from upstream"

# ---------------------------------------------------------------------------
# Phase 3: Private / reserved CIDR guard (awk — single pass, fast)
# ---------------------------------------------------------------------------
clean_routes="${TMPDIR_WORK}/routes_clean.txt"
rejected_file="${TMPDIR_WORK}/routes_rejected.txt"

awk -F '[./]' -v clean_file="$clean_routes" -v reject_file="$rejected_file" '
# A.B.C.D/prefix splits to: $1=A, $2=B, $3=C, $4=D, $5=prefix
{
    a = int($1); b = int($2); c = int($3)

    reject = 0

    # 0.0.0.0/8        — "This" network
    if (a == 0)                                     reject = 1
    # 10.0.0.0/8       — RFC 1918
    if (a == 10)                                    reject = 1
    # 100.64.0.0/10    — CGNAT (Shared Address Space)
    if (a == 100 && b >= 64 && b <= 127)            reject = 1
    # 127.0.0.0/8      — Loopback
    if (a == 127)                                   reject = 1
    # 169.254.0.0/16   — Link-local
    if (a == 169 && b == 254)                       reject = 1
    # 172.16.0.0/12    — RFC 1918
    if (a == 172 && b >= 16 && b <= 31)             reject = 1
    # 192.0.0.0/29     — IETF Protocol Assignments
    if (a == 192 && b == 0 && c == 0)               reject = 1
    # 192.0.2.0/24     — TEST-NET-1
    if (a == 192 && b == 0 && c == 2)               reject = 1
    # 192.168.0.0/16   — RFC 1918
    if (a == 192 && b == 168)                       reject = 1
    # 198.18.0.0/15    — Benchmarking
    if (a == 198 && (b == 18 || b == 19))           reject = 1
    # 198.51.100.0/24  — TEST-NET-2
    if (a == 198 && b == 51 && c == 100)            reject = 1
    # 203.0.113.0/24   — TEST-NET-3
    if (a == 203 && b == 0 && c == 113)             reject = 1
    # 224.0.0.0/4      — Multicast
    # 240.0.0.0/4      — Reserved / Future use
    # 255.255.255.255  — Broadcast
    if (a >= 224)                                   reject = 1

    if (reject)
        print > reject_file
    else
        print > clean_file
}
' "$routes_raw"

touch "$clean_routes" "$rejected_file"

rejected_count=0
[[ -s "$rejected_file" ]] && rejected_count=$(wc -l < "$rejected_file")

if [[ "$rejected_count" -gt 0 ]]; then
    log_warn "Filtered out $rejected_count private/reserved CIDR(s):"
    head -20 "$rejected_file" | while IFS= read -r cidr; do
        log_warn "  REJECTED: $cidr"
    done
fi

if [[ "$rejected_count" -gt "$MAX_PRIVATE_CIDRS" ]]; then
    die "Too many private CIDRs ($rejected_count > $MAX_PRIVATE_CIDRS). Upstream may be compromised. Aborting."
fi

sort "$clean_routes" > "${TMPDIR_WORK}/desired_sorted.txt"
desired_file="${TMPDIR_WORK}/desired_sorted.txt"
desired_count=$(wc -l < "$desired_file")

log_info "After filtering: $desired_count clean routes ($rejected_count rejected)"

# ---------------------------------------------------------------------------
# Phase 4: Diff current kernel table vs desired
# ---------------------------------------------------------------------------
current_file="${TMPDIR_WORK}/current_sorted.txt"

# ip -json + jq handles /32 host routes and blackhole; awk fallback if jq absent.
# Table may not exist on first run — treat errors as empty.
if command -v jq &>/dev/null; then
    ip -json route show table "$ROUTE_TABLE" proto "$PROTO" 2>/dev/null \
        | jq -r '.[].dst' 2>/dev/null | sort > "$current_file" || true
else
    ip route show table "$ROUTE_TABLE" proto "$PROTO" 2>/dev/null \
        | awk '
            $1 == "blackhole" || $1 == "unreachable" || $1 == "prohibit" { print $2; next }
            $1 ~ /^[0-9]/ { print $1 }
        ' | sort > "$current_file" || true
fi

touch "$current_file"
current_count=$(wc -l < "$current_file")

to_add_file="${TMPDIR_WORK}/to_add.txt"
to_del_file="${TMPDIR_WORK}/to_del.txt"

comm -13 "$current_file" "$desired_file" > "$to_add_file"
comm -23 "$current_file" "$desired_file" > "$to_del_file"

add_count=$(wc -l < "$to_add_file")
del_count=$(wc -l < "$to_del_file")
unchanged_count=$(( current_count - del_count ))

log_info "Diff: +$add_count -$del_count =$unchanged_count (current: $current_count, desired: $desired_count)"

if [[ "$add_count" -eq 0 && "$del_count" -eq 0 ]]; then
    log_info "No changes needed. Table is in sync."
    date -Iseconds > "${STATE_DIR}/last-run"
    exit 0
fi

# ---------------------------------------------------------------------------
# Phase 5: Apply changes via ip -batch
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY RUN] Would add $add_count routes and delete $del_count routes."
    [[ "$add_count" -gt 0 ]] && log_info "[DRY RUN] First 5 additions:" && head -5 "$to_add_file" | while IFS= read -r r; do log_info "  + $r"; done
    [[ "$del_count" -gt 0 ]] && log_info "[DRY RUN] First 5 deletions:" && head -5 "$to_del_file" | while IFS= read -r r; do log_info "  - $r"; done
    exit 0
fi

SECONDS=0
errors=0

# Delete stale routes first (avoids conflicts with overlapping prefixes)
if [[ "$del_count" -gt 0 ]]; then
    batch_del="${TMPDIR_WORK}/batch_del.txt"
    awk -v tbl="$ROUTE_TABLE" -v proto="$PROTO" \
        '{printf "route del %s table %s proto %s\n", $1, tbl, proto}' \
        "$to_del_file" > "$batch_del"

    del_errors="${TMPDIR_WORK}/del_errors.txt"
    if ! ip -force -batch "$batch_del" 2>"$del_errors"; then
        err_count=$(wc -l < "$del_errors")
        log_warn "Some deletions failed ($err_count error lines). First 5:"
        head -5 "$del_errors" | while IFS= read -r line; do log_warn "  $line"; done
        errors=$((errors + err_count))
    fi
    log_info "Deleted $del_count routes"
fi

if [[ "$add_count" -gt 0 ]]; then
    batch_add="${TMPDIR_WORK}/batch_add.txt"
    awk -v gw="$NEXT_HOP" -v dev="$OUTGOING_DEV" -v tbl="$ROUTE_TABLE" -v proto="$PROTO" \
        '{printf "route replace %s via %s dev %s table %s proto %s\n", $1, gw, dev, tbl, proto}' \
        "$to_add_file" > "$batch_add"

    add_errors="${TMPDIR_WORK}/add_errors.txt"
    if ! ip -force -batch "$batch_add" 2>"$add_errors"; then
        err_count=$(wc -l < "$add_errors")
        log_warn "Some additions failed ($err_count error lines). First 5:"
        head -5 "$add_errors" | while IFS= read -r line; do log_warn "  $line"; done
        errors=$((errors + err_count))
    fi
    log_info "Added $add_count routes"
fi

elapsed=$SECONDS

# ---------------------------------------------------------------------------
# Phase 6: Post-apply verification & state persistence
# ---------------------------------------------------------------------------
if command -v jq &>/dev/null; then
    final_count=$(ip -json route show table "$ROUTE_TABLE" proto "$PROTO" 2>/dev/null \
                  | jq 'length' 2>/dev/null || echo 0)
else
    final_count=$(ip route show table "$ROUTE_TABLE" proto "$PROTO" 2>/dev/null \
                  | wc -l)
fi

drift=$(( final_count - desired_count ))
drift_abs=${drift#-}
threshold=$(( desired_count / 100 ))
[[ "$threshold" -lt 1 ]] && threshold=1

if [[ "$drift_abs" -gt "$threshold" ]]; then
    log_warn "Post-apply drift: table has $final_count routes but expected $desired_count (delta: $drift)"
fi

cp "$desired_file" "${STATE_DIR}/last-applied.txt"
date -Iseconds > "${STATE_DIR}/last-run"

if [[ "$errors" -gt 0 ]]; then
    log_warn "Completed with $errors error(s) in ${elapsed}s. Table: $final_count routes (+$add_count -$del_count)"
    exit 1
else
    log_info "Sync complete in ${elapsed}s. Table: $final_count routes (+$add_count -$del_count)"
    exit 0
fi
