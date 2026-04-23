#!/usr/bin/env bash
# =============================================================================
# tag_nodes.sh
# =============================================================================
# Step 1 of the chef-client upgrade workflow.
# Removes conflicting tags and applies the upgrade tag to each Chef node.
#
# Usage:
#   bash scripts/tag_nodes.sh [options]
#
# Options:
#   --tag      TAG   Upgrade tag to apply (default: upgrade19)
#   --parallel N     Max concurrent knife calls (default: 20)
#   --dry-run        Print commands without executing them
#
# Environment variables (set by Jenkins or upgrade_workflow.sh):
#   NODE_LIST         Multi-line string of Chef node names, one per line.
#                     When set, overrides the hardcoded NODES fallback below.
#   UPGRADE_TAG       Tag to apply (overrides default; overridden by --tag).
#   CONFLICTING_TAGS  Space-separated list of tags to remove before applying
#                     UPGRADE_TAG (default: "upgrade19 rollback16").
#                     Should include all mutually exclusive tags so that running
#                     a rollback clears the upgrade tag, and vice versa.
#   MAX_PARALLEL      Max concurrent knife calls (overridden by --parallel).
#   DRY_RUN           Set to "true" to skip live knife mutations.
#   CHEF_SERVER_URL   Optional Chef server URL override.
#   CHEF_CLIENT_NAME  Optional Chef client name override.
#   CHEF_CLIENT_KEY   Optional path to Chef client key file.
#
# Outputs:
#   reports/raw/tagged_nodes.json   Audit JSON (archived as build artifact).
#   reports/raw/tag_success.list    One node per line — consumed by prepend_role.sh.
#
# Exit codes:
#   0  - all nodes tagged successfully
#   1  - one or more nodes failed tagging
#   2  - usage / configuration error
# =============================================================================

set -uo pipefail

# =============================================================================
# SECTION 1 — Node inventory
# =============================================================================
if [[ -n "${NODE_LIST:-}" ]]; then
    mapfile -t NODES <<< "$NODE_LIST"
    # Strip blank lines that Jenkins may append to multi-line parameters
    mapfile -t NODES < <(printf '%s\n' "${NODES[@]}" | sed '/^[[:space:]]*$/d')
else
    # Hardcoded fallback — edit this array when not driven by an env variable.
    NODES=(
        "node1"
        # "node2"
        # "node3"
        # "web-prod-01"
        # "web-prod-02"
        # "db-prod-01"
    )
fi

# =============================================================================
# SECTION 2 — Defaults and argument parsing
# =============================================================================
UPGRADE_TAG="${UPGRADE_TAG:-upgrade19}"
MAX_PARALLEL="${MAX_PARALLEL:-20}"
DRY_RUN="${DRY_RUN:-false}"
LOG_DIR="${WORKSPACE:-$(pwd)}/logs"
REPORTS_DIR="${WORKSPACE:-$(pwd)}/reports/raw"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)      UPGRADE_TAG="$2"; shift 2 ;;
        --parallel) MAX_PARALLEL="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --help|-h)
            sed -n '1,/^# ={10}/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Build conflicting tags list AFTER arg parsing so --tag override is respected.
# The env var CONFLICTING_TAGS (set by Jenkins) is a space-separated list of
# all mutually exclusive tags — e.g. "upgrade19 rollback16". Falls back to a
# safe default that covers both upgrade and rollback scenarios.
IFS=' ' read -ra CONFLICTING_TAGS <<< "${CONFLICTING_TAGS:-upgrade19 rollback16}"

# =============================================================================
# SECTION 3 — Logging setup
# =============================================================================
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/tag_nodes_$(date -u +%Y%m%dT%H%M%SZ).log"
ls -1t "${LOG_DIR}"/tag_nodes_*.log 2>/dev/null | tail -n +31 | xargs -r rm -f
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo "  tag_nodes.sh"
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
    echo "ERROR: NODES array is empty. Set NODE_LIST or edit the NODES fallback." >&2
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
echo "Upgrade tag      : $UPGRADE_TAG"
echo "Conflicting tags : ${CONFLICTING_TAGS[*]}"
echo "Max parallel     : $MAX_PARALLEL"
echo "Dry run          : $DRY_RUN"
echo ""

# =============================================================================
# SECTION 6 — Tag nodes (parallel)
# =============================================================================
echo "=============================================="
echo "  Tag Nodes"
echo "  $(date -u)"
echo "=============================================="

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

TAG_SUCCESS_FILE="${TMP_DIR}/tag_success.list"
TAG_FAILED_FILE="${TMP_DIR}/tag_failed.list"
touch "$TAG_SUCCESS_FILE" "$TAG_FAILED_FILE"

tag_single_node() {
    local node="$1"
    local node_log="${TMP_DIR}/tag_${node//\//_}.log"

    {
        echo "-- $node --"

        if [[ "$DRY_RUN" == true ]]; then
            IFS=' ' read -ra CONFLICTING_TAGS <<< "$CONFLICTING_TAGS_STR"
            for ct in "${CONFLICTING_TAGS[@]}"; do
                echo "  [DRY-RUN] Would remove conflicting tag '$ct' if present"
            done
            echo "  [DRY-RUN] knife tag create $node $UPGRADE_TAG"
            echo "$node" >> "$TAG_SUCCESS_FILE"
            return 0
        fi

        IFS=' ' read -ra CONFLICTING_TAGS <<< "$CONFLICTING_TAGS_STR"

        # Step 1a — Remove conflicting tags
        local existing_tags
        existing_tags=$(knife_cmd tag list "$node" 2>/dev/null || true)
        for ct in "${CONFLICTING_TAGS[@]}"; do
            if echo "$existing_tags" | grep -qw "$ct"; then
                echo "  [REMOVE] Removing conflicting tag '$ct'"
                knife_cmd tag delete "$node" "$ct" --yes 2>/dev/null || \
                    echo "  [WARN] Could not remove tag '$ct' (non-fatal)"
            fi
        done

        # Step 1b — Apply upgrade tag
        echo "  [+] Applying tag '$UPGRADE_TAG'"
        if ! knife_cmd tag create "$node" "$UPGRADE_TAG" 2>/dev/null; then
            echo "  [FAIL] FAILED to tag $node"
            echo "$node" >> "$TAG_FAILED_FILE"
            return 1
        fi
        echo "  [OK] Tag applied"
        echo "$node" >> "$TAG_SUCCESS_FILE"
        echo "  [OK] Done"

    } >> "$node_log" 2>&1

    {
        flock 9
        cat "$node_log"
    } 9>"${TMP_DIR}/stdout.lock"
}

export -f tag_single_node knife_cmd
export TMP_DIR UPGRADE_TAG DRY_RUN TAG_SUCCESS_FILE TAG_FAILED_FILE
export CONFLICTING_TAGS_STR="${CONFLICTING_TAGS[*]}"

active=0
for node in "${NODES[@]}"; do
    tag_single_node "$node" &
    (( active++ ))
    if [[ $active -ge $MAX_PARALLEL ]]; then
        wait -n 2>/dev/null || wait
        (( active-- ))
    fi
done
wait

mapfile -t TAG_SUCCEEDED < <(sort "$TAG_SUCCESS_FILE")
mapfile -t TAG_FAILED    < <(sort "$TAG_FAILED_FILE")
TAG_SUCCESS_COUNT=${#TAG_SUCCEEDED[@]}
TAG_FAIL_COUNT=${#TAG_FAILED[@]}

# =============================================================================
# SECTION 7 — Write audit JSON + inter-stage handoff list
# =============================================================================
mkdir -p "$REPORTS_DIR"
TAG_AUDIT_FILE="${REPORTS_DIR}/tagged_nodes.json"
TAG_SUCCESS_LIST="${REPORTS_DIR}/tag_success.list"

{
    printf '{\n'
    printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "tag": "%s",\n' "$UPGRADE_TAG"
    printf '  "dry_run": %s,\n' "$( [[ "$DRY_RUN" == true ]] && echo 'true' || echo 'false' )"
    printf '  "total": %d,\n' "${#NODES[@]}"
    printf '  "tagged": %d,\n' "$TAG_SUCCESS_COUNT"
    printf '  "failed": %d,\n' "$TAG_FAIL_COUNT"
    printf '  "failed_nodes": ['
    _first=true
    for _n in "${TAG_FAILED[@]:-}"; do
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
} > "$TAG_AUDIT_FILE"

# Write inter-stage handoff file (consumed by prepend_role.sh)
printf '%s\n' "${TAG_SUCCEEDED[@]}" > "$TAG_SUCCESS_LIST"

echo "Audit log written    -> $TAG_AUDIT_FILE"
echo "Handoff list written -> $TAG_SUCCESS_LIST"
echo ""
echo "  Tagging Summary"
echo "  Total    : ${#NODES[@]}"
echo "  Tagged   : $TAG_SUCCESS_COUNT"
echo "  Failed   : $TAG_FAIL_COUNT"
if [[ $TAG_FAIL_COUNT -gt 0 ]]; then
    echo "  Failed nodes:"
    printf '    - %s\n' "${TAG_FAILED[@]}"
fi
echo ""
echo "  Log      : $LOG_FILE"
echo "=============================================="

[[ $TAG_FAIL_COUNT -gt 0 ]] && exit 1
exit 0
