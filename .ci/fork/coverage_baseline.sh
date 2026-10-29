#!/usr/bin/env bash
# Fork-owned CI tool: the baseline of the overall coverage ratchet (see coverage.sh).
#
# A PR's overall coverage is compared with the coverage of the main commit it is based on,
# not with main's latest: PRs in flight at the same time do not have to merge one by one
# (another PR merging with new tests raises main's coverage, not this PR's base's).
#
# Usage:
#   coverage_baseline.sh base EVENT_NAME [MAIN_REF]
#       Prints the commit the change being measured (HEAD) is based on:
#       - pull_request: actions/checkout checks out refs/pull/N/merge (github.sha, shared by
#         all the jobs of the run), the PR merged into the base branch commit GitHub built it
#         on: its first parent. (The event's pull_request.base.sha may be older than it.)
#       - otherwise (workflow_dispatch on a branch, e.g. by the upstream sync), and for a PR
#         checkout that is not a merge: git merge-base HEAD MAIN_REF (default origin/main).
#   coverage_baseline.sh lookup BASE HISTORY_JSONL [unit|combined]
#       Selects the unit or combined metric (default combined), skipping unmeasured values.
#       Prints "SHA PERCENT exact|ancestor": main's selected coverage recorded for BASE on the
#       `coverage` branch (history.jsonl: one record per measured main commit, keyed by its
#       SHA; the last record of a commit wins), or else for BASE's nearest recorded ancestor
#       (needs BASE's history: full clone). Prints nothing when no ancestor has a record.

set -eo pipefail

case "$1" in
    base)
        if [[ "$2" == pull_request ]] && git rev-parse -q --verify 'HEAD^2' >/dev/null; then
            git rev-parse 'HEAD^1'
        else
            git merge-base HEAD "${3:-origin/main}"
        fi
        ;;
    lookup)
        base="$(git rev-parse -q --verify "$2^{commit}")" || exit 0
        metric="${4:-combined}"
        [[ "${metric}" == unit || "${metric}" == combined ]] || exit 2
        declare -A pct
        while IFS=$'\t' read -r c p; do
            [[ -z "${c}" ]] || [[ -z "${p}" ]] || pct[${c}]="${p}"
        done < <(jq -R -r --arg metric "${metric}" 'fromjson? | objects | select(.mode != "diff")
            | [.commit, (if $metric == "unit" then (.overall_unit.percent // .unit) else
                (if .mode == "unit" then null else (.overall | if type == "object" then .percent else . end) end) end)]
            | select(.[0] != null and .[1] != null) | @tsv' "$3" 2>/dev/null)
        [[ ${#pct[@]} -gt 0 ]] || exit 0
        kind=exact
        # Topological order: a recorded commit comes before its recorded ancestors.
        while read -r c; do
            if [[ -n "${pct[${c}]}" ]]; then
                echo "${c} ${pct[${c}]} ${kind}"
                exit 0
            fi
            kind=ancestor
        done < <(git rev-list --topo-order "${base}")
        ;;
    *)
        echo "usage: $0 base EVENT_NAME [MAIN_REF] | lookup BASE HISTORY_JSONL [unit|combined]" 1>&2
        exit 2
        ;;
esac
