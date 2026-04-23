#!/usr/bin/env bash
# =============================================================================
# switch_roles.sh
# =============================================================================
# Step 4 of the chef-client upgrade workflow.
# For each successfully tagged node, replaces one or more Chef roles in the
# run list with new roles according to the ROLE_SWITCHES parameter.
# All substitutions for a given node are applied atomically in a single
# knife exec call to avoid race conditions.
#
# Usage:
#   bash scripts/switch_roles.sh [options]
#
# Options:
#   --parallel N     Max concurrent knife calls (default: 20)
#   --dry-run        Print commands without executing them
#
# Environment variables (set by Jenkins):
#   ROLE_SWITCHES     Multi-line string of role substitutions, one per line,
#                     in the format: old_role:new_role
#                     Example:
#                       role[chef_client_16]:role[chef_client_19]
#                       role[old_monitoring]:role[new_monitoring]
#   TAG_SUCCESS_LIST  Path to tag_success.list written by tag_nodes.sh.
#                     This is the primary node source when calling from the pipeline.
#   NODE_LIST         Fallback: multi-line string of node names (one per line).
#                     Used only if TAG_SUCCESS_LIST is not set.
#   MAX_PARALLEL      Max concurrent knife calls (overridden by --parallel).
#   DRY_RUN           Set to "true" to skip live knife mutations.
#   CHEF_SERVER_URL   Optional Chef server URL override.
#   CHEF_CLIENT_NAME  Optional Chef client name override.
#   CHEF_CLIENT_KEY   Optional path to Chef client key file.
#
# Outputs:
#   reports/raw/switch_roles.json   Audit JSON (archived as build artifact).
#
# Exit codes:
#   0  - all nodes processed successfully (includes nodes where no matching roles were found)
#   1  - one or more nodes failed
#   2  - usage / configuration error
# =============================================================================

set -uo pipefail

# =============================================================================
# SECTION 1 — Defaults and argument parsing
# =============================================================================
MAX_PARALLEL="${MAX_PARALLEL:-20}"
DRY_RUN="${DRY_RUN:-false}"
LOG_DIR="${WORKSPACE:-$(pwd)}/logs"
REPORTS_DIR="${WORKSPACE:-$(pwd)}/reports/raw"
ROLE_SWITCHES_RAW="${ROLE_SWITCHES:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parallel) MAX_PARALLEL="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true;      shift ;;
        --help|-h)
            sed -n '1,/^# ={10}/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# =============================================================================
# SECTION 2 — Parse role switch pairs
# =============================================================================
declare -a OLD_ROLES=()
declare -a NEW_ROLES=()

while IFS= read -r line; do
    line="${line//$'\r'/}"      # strip Windows CR
    [[ -z "${line// }" ]] && continue
    if [[ "$line" != *:* ]]; then
        echo "ERROR: Invalid ROLE_SWITCHES entry (missing ':' delimiter): '$line'" >&2
        exit 2
    fi
    OLD_ROLES+=("${line%%:*}")
    NEW_ROLES+=("${line#*:}")
done <<< "$ROLE_SWITCHES_RAW"

if [[ ${#OLD_ROLES[@]} -eq 0 ]]; then
    echo "ERROR: ROLE_SWITCHES is empty or contains no valid old_role:new_role entries." >&2
    exit 2
fi

# =============================================================================
# SECTION 3 — Node list (from handoff file or NODE_LIST env var)
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
# SECTION 4 — Logging setup
# =============================================================================
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/switch_roles_$(date -u +%Y%m%dT%H%M%SZ).log"
ls -1t "${LOG_DIR}"/switch_roles_*.log 2>/dev/null | tail -n +31 | xargs -r rm -f
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo "  switch_roles.sh"
echo "  $(date -u)"
echo "  Log      : $LOG_FILE"
[[ -n "${BUILD_NUMBER:-}" ]] && echo "  Build    : ${BUILD_TAG:-#$BUILD_NUMBER}"
[[ -n "${GIT_COMMIT:-}" ]]   && echo "  Commit   : ${GIT_COMMIT:0:8}"
[[ -n "${NODE_NAME:-}" ]]    && echo "  Agent    : $NODE_NAME"
echo "=============================================="

# =============================================================================
# SECTION 5 — Validation
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
# SECTION 6 — Knife credential flags
# =============================================================================
KNIFE_EXTRA_OPTS=()
[[ -n "${CHEF_SERVER_URL:-}" ]]  && KNIFE_EXTRA_OPTS+=(--server-url "$CHEF_SERVER_URL")
[[ -n "${CHEF_CLIENT_NAME:-}" ]] && KNIFE_EXTRA_OPTS+=(--user       "$CHEF_CLIENT_NAME")
[[ -n "${CHEF_CLIENT_KEY:-}" ]]  && KNIFE_EXTRA_OPTS+=(--key        "$CHEF_CLIENT_KEY")

knife_cmd() {
    knife "${@}" "${KNIFE_EXTRA_OPTS[@]}"
}

echo "Nodes to process : ${#NODES[@]}"
echo "Role switches    : ${#OLD_ROLES[@]}"
for i in "${!OLD_ROLES[@]}"; do
    echo "  ${OLD_ROLES[$i]} -> ${NEW_ROLES[$i]}"
done
echo "Max parallel     : $MAX_PARALLEL"
echo "Dry run          : $DRY_RUN"
echo ""

# =============================================================================
# SECTION 7 — Switch roles (parallel)
# =============================================================================
echo "=============================================="
echo "  Switch Roles"
echo "  $(date -u)"
echo "=============================================="

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SWITCH_SUCCESS_FILE="${TMP_DIR}/switch_success.list"
SWITCH_FAILED_FILE="${TMP_DIR}/switch_failed.list"
touch "$SWITCH_SUCCESS_FILE" "$SWITCH_FAILED_FILE"

switch_roles_single_node() {
    local node="$1"
    local node_log="${TMP_DIR}/switch_${node//\//_}.log"

    {
        echo "-- $node --"

        # Re-parse role switches from the exported raw string (arrays can't be
        # exported to subshells directly, so we re-parse from the scalar).
        local -a old_roles=()
        local -a new_roles=()
        while IFS= read -r line; do
            line="${line//$'\r'/}"
            [[ -z "${line// }" ]] && continue
            old_roles+=("${line%%:*}")
            new_roles+=("${line#*:}")
        done <<< "$ROLE_SWITCHES_RAW"

        if [[ "$DRY_RUN" == true ]]; then
            for i in "${!old_roles[@]}"; do
                echo "  [DRY-RUN] Would replace '${old_roles[$i]}' -> '${new_roles[$i]}' if present"
            done
            echo "$node" >> "$SWITCH_SUCCESS_FILE"
            return 0
        fi

        # Build a Ruby array literal of [old, new] pairs to embed in knife exec.
        # Chef role names are [a-z0-9_-] wrapped in role[], so they contain no
        # single-quotes — safe to interpolate directly.
        local ruby_pairs="["
        local _first=true
        for i in "${!old_roles[@]}"; do
            [[ "$_first" == true ]] && _first=false || ruby_pairs+=","
            ruby_pairs+="['${old_roles[$i]}','${new_roles[$i]}']"
        done
        ruby_pairs+="]"

        # Single atomic knife exec: load node, apply all substitutions, save once.
        local result
        result=$(knife_cmd exec -E "
pairs = ${ruby_pairs}
n = Chef::Node.load('${node}')
rl = n.run_list.map(&:to_s)
original_rl = rl.dup
pairs.each do |old_r, new_r|
  rl.map! { |item| item == old_r ? new_r : item }
  rl.uniq!
end
if rl == original_rl
  puts 'no_change'
else
  n.run_list(rl)
  n.save
  puts 'updated'
end
" 2>/dev/null)

        case "$result" in
            no_change)
                echo "  [OK] None of the specified old roles found in run list — no change needed"
                echo "$node" >> "$SWITCH_SUCCESS_FILE"
                ;;
            updated)
                echo "  [OK] Run list updated — role substitutions applied"
                echo "$node" >> "$SWITCH_SUCCESS_FILE"
                ;;
            *)
                echo "  [FAIL] Unexpected output from knife exec for $node (got: '${result:-empty}')"
                echo "$node" >> "$SWITCH_FAILED_FILE"
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

export -f switch_roles_single_node knife_cmd
export TMP_DIR DRY_RUN SWITCH_SUCCESS_FILE SWITCH_FAILED_FILE ROLE_SWITCHES_RAW

active=0
for node in "${NODES[@]}"; do
    switch_roles_single_node "$node" &
    (( active++ ))
    if [[ $active -ge $MAX_PARALLEL ]]; then
        wait -n 2>/dev/null || wait
        (( active-- ))
    fi
done
wait

mapfile -t SWITCH_SUCCEEDED < <(sort "$SWITCH_SUCCESS_FILE")
mapfile -t SWITCH_FAILED    < <(sort "$SWITCH_FAILED_FILE")
SWITCH_SUCCESS_COUNT=${#SWITCH_SUCCEEDED[@]}
SWITCH_FAIL_COUNT=${#SWITCH_FAILED[@]}

# =============================================================================
# SECTION 8 — Write audit JSON
# =============================================================================
mkdir -p "$REPORTS_DIR"
SWITCH_AUDIT_FILE="${REPORTS_DIR}/switch_roles.json"

{
    printf '{\n'
    printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "dry_run": %s,\n' "$( [[ "$DRY_RUN" == true ]] && echo 'true' || echo 'false' )"
    printf '  "role_switches": ['
    _first=true
    for i in "${!OLD_ROLES[@]}"; do
        [[ "$_first" == true ]] && _first=false || printf ','
        printf '{"from":"%s","to":"%s"}' "${OLD_ROLES[$i]}" "${NEW_ROLES[$i]}"
    done
    printf '],\n'
    printf '  "total": %d,\n' "${#NODES[@]}"
    printf '  "updated": %d,\n' "$SWITCH_SUCCESS_COUNT"
    printf '  "failed": %d,\n' "$SWITCH_FAIL_COUNT"
    printf '  "failed_nodes": ['
    _first=true
    for _n in "${SWITCH_FAILED[@]:-}"; do
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
} > "$SWITCH_AUDIT_FILE"

echo "Audit log written -> $SWITCH_AUDIT_FILE"
echo ""
echo "  Role Switch Summary"
echo "  Total    : ${#NODES[@]}"
echo "  Updated  : $SWITCH_SUCCESS_COUNT"
echo "  Failed   : $SWITCH_FAIL_COUNT"
if [[ $SWITCH_FAIL_COUNT -gt 0 ]]; then
    echo "  Failed nodes:"
    printf '    - %s\n' "${SWITCH_FAILED[@]}"
fi
echo ""
echo "  Log      : $LOG_FILE"
echo "=============================================="

[[ $SWITCH_FAIL_COUNT -gt 0 ]] && exit 1
exit 0
