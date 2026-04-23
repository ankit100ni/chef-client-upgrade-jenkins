#!/usr/bin/env bash
# =============================================================================
# remove_role.sh
# =============================================================================
# Post-upgrade cleanup: iterates nodes in the CSV, checks whether each node
# has reached the target chef-client version (PASSED), and removes the
# bootstrap role from the run list for those nodes.
#
# This is safe to run repeatedly — the operation is idempotent.
# Run via cron on the orchestration host (e.g., every 30 minutes) while the
# upgrade window is active, or invoke manually once the upgrade completes.
#
# Usage:
#   bash scripts/remove_role.sh [options]
#
# Options:
#   --csv        FILE     Input CSV (default: nodes.csv)
#   --role       ROLE     Role to remove (default: role[chef_upgrade_cron])
#   --target-ver PREFIX   Version prefix confirming upgrade (default: 19.)
#   --parallel   N        Max concurrent knife calls (default: 20)
#   --dry-run             Print actions without executing them
#
# Credential overrides (optional):
#   CHEF_SERVER_URL / CHEF_CLIENT_NAME / CHEF_CLIENT_KEY
#
# Exit codes:
#   0  – completed (even if some nodes still have the role; they just aren't PASSED yet)
#   2  – usage / configuration error
# =============================================================================

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
CSV_FILE="nodes.csv"
BOOTSTRAP_ROLE="role[chef_upgrade_cron]"
TARGET_VER="19."
MAX_PARALLEL=20
DRY_RUN=false
LOG_DIR="logs"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv)        CSV_FILE="$2";        shift 2 ;;
        --role)       BOOTSTRAP_ROLE="$2";  shift 2 ;;
        --target-ver) TARGET_VER="$2";      shift 2 ;;
        --parallel)   MAX_PARALLEL="$2";    shift 2 ;;
        --dry-run)    DRY_RUN=true;          shift   ;;
        --help|-h)
            sed -n '1,/^# ={10}/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ── Logging setup ─────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/remove_role_$(date -u +%Y%m%dT%H%M%SZ).log"
ls -1t "${LOG_DIR}"/remove_role_*.log 2>/dev/null | tail -n +31 | xargs -r rm -f
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo "  remove_role.sh"
echo "  $(date -u)"
echo "  Log: $LOG_FILE"
echo "=============================================="

# ── Validation ────────────────────────────────────────────────────────────────
if ! command -v knife &>/dev/null; then
    echo "ERROR: knife not found in PATH." >&2; exit 2
fi
if [[ ! -f "$CSV_FILE" ]]; then
    echo "ERROR: CSV file not found: $CSV_FILE" >&2; exit 2
fi

# ── Knife credential helpers ──────────────────────────────────────────────────
KNIFE_EXTRA_OPTS=()
[[ -n "${CHEF_SERVER_URL:-}" ]]  && KNIFE_EXTRA_OPTS+=(--server-url "$CHEF_SERVER_URL")
[[ -n "${CHEF_CLIENT_NAME:-}" ]] && KNIFE_EXTRA_OPTS+=(--user       "$CHEF_CLIENT_NAME")
[[ -n "${CHEF_CLIENT_KEY:-}" ]]  && KNIFE_EXTRA_OPTS+=(--key        "$CHEF_CLIENT_KEY")

knife_cmd() { knife "${@}" "${KNIFE_EXTRA_OPTS[@]}"; }

# ── Read CSV ──────────────────────────────────────────────────────────────────
mapfile -t NODES < <(tail -n +2 "$CSV_FILE" | sed '/^[[:space:]]*$/d' | tr -d '\r')
if [[ ${#NODES[@]} -eq 0 ]]; then
    echo "ERROR: No nodes found in $CSV_FILE" >&2; exit 2
fi

echo "Nodes to check   : ${#NODES[@]}"
echo "Bootstrap role   : $BOOTSTRAP_ROLE"
echo "Target version   : ${TARGET_VER}x"
echo "Dry run          : $DRY_RUN"
echo ""

# ── Shared counters ───────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

REMOVED_FILE="${TMP_DIR}/removed.list"
SKIPPED_FILE="${TMP_DIR}/skipped.list"   # not yet PASSED
ALREADY_FILE="${TMP_DIR}/already.list"   # PASSED but role already absent
touch "$REMOVED_FILE" "$SKIPPED_FILE" "$ALREADY_FILE"

# ── Per-node function ─────────────────────────────────────────────────────────
process_node() {
    local node="$1"
    local node_log="${TMP_DIR}/${node//\//_}.log"

    {
        # Fetch version and run list in one knife call
        local info
        info=$(knife_cmd node show "$node" \
                   -a chef_packages.chef.version \
                   -a run_list \
                   --format json 2>/dev/null || echo "{}")

        # Parse version + run list
        local parsed
        parsed=$(echo "$info" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    top = list(d.values())[0] if d else {}
    ver = top.get('chef_packages.chef.version', '') \
          or top.get('chef_packages', {}).get('chef', {}).get('version', '')
    rl  = top.get('run_list', [])
    print(json.dumps({'version': ver, 'run_list': rl}))
except Exception:
    print(json.dumps({'version': '', 'run_list': []}))
" 2>/dev/null || echo '{"version":"","run_list":[]}')

        local chef_ver run_list_json
        chef_ver=$(echo "$parsed" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null)
        run_list_json=$(echo "$parsed" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['run_list']))" 2>/dev/null || echo "[]")

        # Check if node has reached target version
        local is_passed=false
        if [[ -n "$chef_ver" ]] && [[ "$chef_ver" == ${TARGET_VER}* ]]; then
            is_passed=true
        fi

        if [[ "$is_passed" == false ]]; then
            echo "  ⏳ $node — still on ${chef_ver:-unknown} (not yet PASSED, skipping)"
            echo "$node" >> "$SKIPPED_FILE"
            return 0
        fi

        # Check if bootstrap role is in run list
        local role_present
        role_present=$(echo "$run_list_json" | python3 -c "
import sys, json
rl = json.load(sys.stdin)
print('yes' if '${BOOTSTRAP_ROLE}' in rl else 'no')
" 2>/dev/null || echo "no")

        if [[ "$role_present" != "yes" ]]; then
            echo "  ✓ $node — PASSED, role already absent"
            echo "$node" >> "$ALREADY_FILE"
            return 0
        fi

        # Remove the role
        if [[ "$DRY_RUN" == true ]]; then
            echo "  [DRY-RUN] $node — would remove '$BOOTSTRAP_ROLE' from run list"
            echo "$node" >> "$REMOVED_FILE"
            return 0
        fi

        echo "  ➖ $node — PASSED (v${chef_ver}), removing '$BOOTSTRAP_ROLE' from run list"
        local new_run_list
        new_run_list=$(echo "$run_list_json" | python3 -c "
import sys, json
rl = json.load(sys.stdin)
rl = [r for r in rl if r != '${BOOTSTRAP_ROLE}']
print(','.join(rl))
" 2>/dev/null)

        if knife_cmd node run_list set "$node" "$new_run_list" 2>/dev/null; then
            echo "  ✔ $node — role removed"
            echo "$node" >> "$REMOVED_FILE"
        else
            echo "  ✘ $node — failed to update run list"
        fi

    } >> "$node_log" 2>&1

    {
        flock 9
        cat "$node_log"
    } 9>"${TMP_DIR}/stdout.lock"
}

export -f process_node knife_cmd
export TMP_DIR BOOTSTRAP_ROLE TARGET_VER DRY_RUN REMOVED_FILE SKIPPED_FILE ALREADY_FILE

# ── Parallel execution ────────────────────────────────────────────────────────
active=0
for node in "${NODES[@]}"; do
    process_node "$node" &
    (( active++ ))
    if [[ $active -ge $MAX_PARALLEL ]]; then
        wait -n 2>/dev/null || wait
        (( active-- ))
    fi
done
wait

# ── Summary ───────────────────────────────────────────────────────────────────
REMOVED_COUNT=$(wc -l < "$REMOVED_FILE")
SKIPPED_COUNT=$(wc -l < "$SKIPPED_FILE")
ALREADY_COUNT=$(wc -l < "$ALREADY_FILE")

echo ""
echo "=============================================="
echo "  Cleanup Summary  ($(date -u))"
echo "=============================================="
echo "  Total checked    : ${#NODES[@]}"
echo "  Role removed     : $REMOVED_COUNT"
echo "  Already clean    : $ALREADY_COUNT  (PASSED, role already absent)"
echo "  Not yet PASSED   : $SKIPPED_COUNT  (upgrade still in progress)"
echo "  Log              : $LOG_FILE"
echo "=============================================="
exit 0
