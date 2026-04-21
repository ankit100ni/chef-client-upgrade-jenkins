#!/usr/bin/env bash
# =============================================================================
# prepend_role.sh
# =============================================================================
# Step 2 of the chef-client upgrade workflow.
# Prepends the bootstrap role to the Chef run list of each successfully tagged node.
#
# Usage:
#   bash scripts/prepend_role.sh [options]
#
# Options:
#   --role     ROLE  Bootstrap role to prepend (default: role[chef_upgrade_cron])
#   --parallel N     Max concurrent knife calls (default: 20)
#   --dry-run        Print commands without executing them
#
# Environment variables (set by Jenkins or upgrade_workflow.sh):
#   TAG_SUCCESS_LIST  Path to tag_success.list written by tag_nodes.sh.
#                     This is the primary node source when calling from the pipeline.
#   NODE_LIST         Fallback: multi-line string of node names (one per line).
#                     Used only if TAG_SUCCESS_LIST is not set.
#   BOOTSTRAP_ROLE    Role to prepend (overrides default; overridden by --role).
#   MAX_PARALLEL      Max concurrent knife calls (overridden by --parallel).
#   DRY_RUN           Set to "true" to skip live knife mutations.
#   CHEF_SERVER_URL   Optional Chef server URL override.
#   CHEF_CLIENT_NAME  Optional Chef client name override.
#   CHEF_CLIENT_KEY   Optional path to Chef client key file.
#
# Outputs:
#   reports/raw/prepend_role.json   Audit JSON (archived as build artifact).
#
# Exit codes:
#   0  - all nodes updated successfully
#   1  - one or more nodes failed
#   2  - usage / configuration error
# =============================================================================

set -uo pipefail

# =============================================================================
# SECTION 1 — Defaults and argument parsing
# =============================================================================
BOOTSTRAP_ROLE="${BOOTSTRAP_ROLE:-role[chef_upgrade_cron]}"
MAX_PARALLEL="${MAX_PARALLEL:-20}"
DRY_RUN="${DRY_RUN:-false}"
LOG_DIR="${WORKSPACE:-$(pwd)}/logs"
REPORTS_DIR="${WORKSPACE:-$(pwd)}/reports/raw"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)     BOOTSTRAP_ROLE="$2"; shift 2 ;;
        --parallel) MAX_PARALLEL="$2";   shift 2 ;;
        --dry-run)  DRY_RUN=true;        shift ;;
        --help|-h)
            sed -n '1,/^# ={10}/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# =============================================================================
# SECTION 2 — Node list (from handoff file or NODE_LIST env var)
# =============================================================================
NODES=()
if [[ -n "${TAG_SUCCESS_LIST:-}" ]]; then
    if [[ ! -f "$TAG_SUCCESS_LIST" ]]; then
        echo "ERROR: TAG_SUCCESS_LIST file not found: $TAG_SUCCESS_LIST" >&2
        exit 2
    fi
    mapfile -t NODES < <(grep -v '^[[:space:]]*$' "$TAG_SUCCESS_LIST" || true)
elif [[ -n "${NODE_LIST:-}" ]]; then
    mapfile -t NODES <<< "$NODE_LIST"
    mapfile -t NODES < <(printf '%s\n' "${NODES[@]}" | sed '/^[[:space:]]*$/d')
fi

# =============================================================================
# SECTION 3 — Logging setup
# =============================================================================
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/prepend_role_$(date -u +%Y%m%dT%H%M%SZ).log"
ls -1t "${LOG_DIR}"/prepend_role_*.log 2>/dev/null | tail -n +31 | xargs -r rm -f
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo "  prepend_role.sh"
echo "  $(date -u)"
echo "  Log      : $LOG_FILE"
[[ -n "${BUILD_NUMBER:-}" ]] && echo "  Build    : ${BUILD_TAG:-#$BUILD_NUMBER}"
[[ -n "${GIT_COMMIT:-}" ]]   && echo "  Commit   : ${GIT_COMMIT:0:8}"
[[ -n "${NODE_NAME:-}" ]]    && echo "  Agent    : $NODE_NAME"
echo "=============================================="

# =============================================================================
# SECTION 4 — Validation
# =============================================================================
if ! command -v knife &>/dev/null; then
    echo "ERROR: knife not found in PATH. Is Chef Workstation installed?" >&2
    exit 2
fi

if [[ ${#NODES[@]} -eq 0 ]]; then
    echo "ERROR: No nodes to process. Set TAG_SUCCESS_LIST or NODE_LIST." >&2
    exit 2
fi

# =============================================================================
# SECTION 5 — Knife credential flags
# =============================================================================
KNIFE_EXTRA_OPTS=()
[[ -n "${CHEF_SERVER_URL:-}" ]]  && KNIFE_EXTRA_OPTS+=(--server-url "$CHEF_SERVER_URL")
[[ -n "${CHEF_CLIENT_NAME:-}" ]] && KNIFE_EXTRA_OPTS+=(--user       "$CHEF_CLIENT_NAME")
[[ -n "${CHEF_CLIENT_KEY:-}" ]]  && KNIFE_EXTRA_OPTS+=(--key        "$CHEF_CLIENT_KEY")

knife_cmd() {
    knife "${@}" "${KNIFE_EXTRA_OPTS[@]}"
}

echo "Nodes to process : ${#NODES[@]}"
echo "Bootstrap role   : $BOOTSTRAP_ROLE"
echo "Max parallel     : $MAX_PARALLEL"
echo "Dry run          : $DRY_RUN"
echo ""

# =============================================================================
# SECTION 6 — Prepend bootstrap role (parallel)
# =============================================================================
echo "=============================================="
echo "  Prepend Bootstrap Role"
echo "  $(date -u)"
echo "=============================================="

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

ROLE_SUCCESS_FILE="${TMP_DIR}/role_success.list"
ROLE_FAILED_FILE="${TMP_DIR}/role_failed.list"
touch "$ROLE_SUCCESS_FILE" "$ROLE_FAILED_FILE"

prepend_role_single_node() {
    local node="$1"
    local node_log="${TMP_DIR}/role_${node//\//_}.log"

    {
        echo "-- $node --"

        if [[ "$DRY_RUN" == true ]]; then
            echo "  [DRY-RUN] knife node run_list prepend $node '$BOOTSTRAP_ROLE' (if not present)"
            echo "$node" >> "$ROLE_SUCCESS_FILE"
            return 0
        fi

        # Use knife exec (embedded Ruby) to atomically read and prepend the role.
        # This avoids the fetch→parse→set race and does not depend on system ruby/python.
        local result
        result=$(knife_cmd exec -E "
n = Chef::Node.load('${node}')
rl = n.run_list.map(&:to_s)
if rl.first == '${BOOTSTRAP_ROLE}'
  puts 'already_first'
elsif rl.include?('${BOOTSTRAP_ROLE}')
  puts 'present_elsewhere'
else
  n.run_list(['${BOOTSTRAP_ROLE}'] + rl)
  n.save
  puts 'prepended'
end
" 2>/dev/null)

        case "$result" in
            already_first)
                echo "  [OK] Bootstrap role already first in run list - skipped"
                echo "$node" >> "$ROLE_SUCCESS_FILE"
                ;;
            present_elsewhere)
                echo "  [OK] Bootstrap role present at non-leading position - leaving as-is"
                echo "$node" >> "$ROLE_SUCCESS_FILE"
                ;;
            prepended)
                echo "  [OK] Bootstrap role prepended"
                echo "$node" >> "$ROLE_SUCCESS_FILE"
                ;;
            *)
                echo "  [FAIL] Failed to update run list for $node (knife exec returned: '${result:-empty}')"
                echo "$node" >> "$ROLE_FAILED_FILE"
                return 1
                ;;
        esac

        echo "  [OK] Done"

    } >> "$node_log" 2>&1

    {
        flock 9
        cat "$node_log"
    } 9>"${TMP_DIR}/stdout.lock"
}

export -f prepend_role_single_node knife_cmd
export TMP_DIR DRY_RUN ROLE_SUCCESS_FILE ROLE_FAILED_FILE BOOTSTRAP_ROLE

active=0
for node in "${NODES[@]}"; do
    prepend_role_single_node "$node" &
    (( active++ ))
    if [[ $active -ge $MAX_PARALLEL ]]; then
        wait -n 2>/dev/null || wait
        (( active-- ))
    fi
done
wait

mapfile -t ROLE_SUCCEEDED < <(sort "$ROLE_SUCCESS_FILE")
mapfile -t ROLE_FAILED    < <(sort "$ROLE_FAILED_FILE")
ROLE_SUCCESS_COUNT=${#ROLE_SUCCEEDED[@]}
ROLE_FAIL_COUNT=${#ROLE_FAILED[@]}

# =============================================================================
# SECTION 7 — Write audit JSON
# =============================================================================
mkdir -p "$REPORTS_DIR"
ROLE_AUDIT_FILE="${REPORTS_DIR}/prepend_role.json"

{
    printf '{\n'
    printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "bootstrap_role": "%s",\n' "$BOOTSTRAP_ROLE"
    printf '  "dry_run": %s,\n' "$( [[ "$DRY_RUN" == true ]] && echo 'true' || echo 'false' )"
    printf '  "total": %d,\n' "${#NODES[@]}"
    printf '  "updated": %d,\n' "$ROLE_SUCCESS_COUNT"
    printf '  "failed": %d,\n' "$ROLE_FAIL_COUNT"
    printf '  "failed_nodes": ['
    _first=true
    for _n in "${ROLE_FAILED[@]:-}"; do
        [[ -z "$_n" ]] && continue
        [[ "$_first" == true ]] && _first=false || printf ','
        printf '"%s"' "$_n"
    done
    printf '],\n'
    printf '  "all_nodes": ['
    _first=true
    for _n in "${NODES[@]}"; do
        [[ -z "$_n" ]] && continue
        [[ "$_first" == true ]] && _first=false || printf ','
        printf '"%s"' "$_n"
    done
    printf ']\n'
    printf '}\n'
} > "$ROLE_AUDIT_FILE"

echo "Audit log written -> $ROLE_AUDIT_FILE"
echo ""
echo "  Role Prepend Summary"
echo "  Total    : ${#NODES[@]}"
echo "  Updated  : $ROLE_SUCCESS_COUNT"
echo "  Failed   : $ROLE_FAIL_COUNT"
if [[ $ROLE_FAIL_COUNT -gt 0 ]]; then
    echo "  Failed nodes:"
    printf '    - %s\n' "${ROLE_FAILED[@]}"
fi
echo ""
echo "  Log      : $LOG_FILE"
echo "=============================================="

[[ $ROLE_FAIL_COUNT -gt 0 ]] && exit 1
exit 0
