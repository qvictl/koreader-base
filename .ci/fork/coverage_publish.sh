#!/usr/bin/env bash
# Fork-owned CI tool: records main's coverage on the `coverage` branch (baseline for the
# ratchet, history, README badges).
#
# Usage: coverage_publish.sh COVERAGE_RESULT_JSON
#
# The `coverage` branch (data only, unprotected) holds:
#   history.jsonl      one record per measured main commit, keyed by its SHA (a re-run replaces
#                      its commit's record): the PR ratchet compares a PR with the record of its
#                      base commit, or of the base's nearest recorded ancestor (coverage_baseline.sh)
#   baseline.json      main's latest measured coverage (full result; only moves forward: an
#                      out-of-order publish of an older main commit does not replace it)
#   HISTORY.md         the trend, as a table
#   badge.json, badge-owned.json   shields.io endpoint badges (from baseline.json)
#
# Needs main's history (to order commits): checkout with fetch-depth 0. Publishes may run in
# parallel (one per main commit): a rejected push is retried on the updated branch.

set -eo pipefail

# Also exercised offline: a unit-only re-run must not erase real combined data.
merge_record() {
    local result="$1" history="$2" commit
    commit="$(jq -r '.commit' "${result}")"
    jq -n --arg c "${commit}" --slurpfile result "${result}" --rawfile history "${history}" '
        ($history | split("\n") | map(fromjson? | objects | select(.commit == $c)) | last // {}) as $old |
        $result[0] as $new |
        $old + {date: $new.date, commit: $c,
            overall: ($new.overall.percent // $old.overall),
            unit: ($new.overall_unit.percent // $old.unit),
            owned: ($new.owned.percent // $old.owned),
            owned_unit: ($new.owned_unit.percent // $old.owned_unit),
            owned_ok: (if $new.owned != null then $new.owned.ok else $old.owned_ok end),
            owned_min: ($new.owned.min // $old.owned_min),
            diff_unit: ($new.diff_unit.percent // $old.diff_unit),
            diff_combined: ($new.diff_combined.percent // $old.diff_combined)} |
        .mode = (if .overall == null then "unit" else "combined" end)'
}
if [[ "${1:-}" == --merge-record ]]; then
    merge_record "$2" "$3"
    exit
fi
result="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
repo="${GITHUB_REPOSITORY:?}"
commit="$(jq -r '.commit' "${result}")"
work="$(mktemp -d)"
git config --global user.name 'github-actions[bot]'
git config --global user.email '41898282+github-actions[bot]@users.noreply.github.com'

color() {
    awk -v p="$1" 'BEGIN { if (p >= 90) print "brightgreen"; else if (p >= 80) print "green"; else if (p >= 60) print "yellowgreen"; else if (p >= 40) print "yellow"; else print "orange" }'
}

# checkout DIR: the coverage branch (new if missing) in a new worktree DIR (detached HEAD:
# pushed to the branch).
checkout() {
    if git fetch --quiet origin '+refs/heads/coverage:refs/remotes/origin/coverage' 2>/dev/null; then
        git worktree add --quiet --detach "$1" refs/remotes/origin/coverage
    else
        git worktree add --quiet --detach "$1"
        git -C "$1" checkout --quiet --orphan "coverage-$(basename "$1")"
        git -C "$1" rm -rq --cached --ignore-unmatch . >/dev/null
        find "$1" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    fi
}

update() {
    # History: this commit's record replaces any previous one (re-run).
    [[ -f history.jsonl ]] || : >history.jsonl
    {
        [[ ! -f history.jsonl ]] || jq -R -c --arg c "${commit}" 'fromjson? | objects | select(.commit != $c)' history.jsonl
        merge_record "${result}" history.jsonl | jq -c .
    } >history.jsonl.tmp
    mv history.jsonl.tmp history.jsonl
    # Keep separate latest measured baselines: daily unit data is never combined data.
    local target old
    for target in baseline.json baseline-unit.json; do
        if [[ "${target}" == baseline.json ]] && ! jq -e '.overall.percent != null' "${result}" >/dev/null; then
            continue
        fi
        old="$(jq -r '.commit // empty' "${target}" 2>/dev/null || true)"
        if [[ -n "${old}" ]] && [[ "${old}" != "${commit}" ]] && git merge-base --is-ancestor "${commit}" "${old}" 2>/dev/null; then
            echo "${target} kept at ${old} (${commit} is older)"
        else
            jq '. + {updated: (now | todate)}' "${result}" >"${target}"
        fi
    done
    if [[ -f baseline.json ]]; then
        overall="$(jq -r '.overall.percent' baseline.json)"
        owned="$(jq -r '.owned.percent' baseline.json)"
        jq -n --arg m "$(printf '%.1f%%' "${overall}")" --arg c "$(color "${overall}")" \
            '{schemaVersion: 1, label: "coverage", message: $m, color: $c}' >badge.json
        jq -n --arg m "$(printf '%.1f%%' "${owned}")" --arg c "$(color "${owned}")" \
            '{schemaVersion: 1, label: "fork-owned coverage", message: $m, color: $c}' >badge-owned.json
    fi
    {
        echo "# Coverage history of \`main\` (${repo})"
        echo
        echo "Unit coverage is recorded on main pushes; combined coverage only on validated release candidates. Unmeasured values are shown as –."
        echo
        echo "| Date | Commit | Overall | Unit tests only | Fork-owned modules | Owned target |"
        echo "|---|---|---:|---:|---:|---:|"
        tail -n 200 history.jsonl | tac | jq -r --arg repo "${repo}" \
            '"| \(.date) | [\(.commit[0:10])](https://github.com/\($repo)/commit/\(.commit)) | \(if .overall != null then "\(.overall * 100 | round / 100)%" else "–" end) | \(if .unit then "\(.unit * 100 | round / 100)%" else "–" end) | \(if .owned != null then "\(.owned * 100 | round / 100)%" else "–" end) | \(.owned_min // "–")% |"'
    } >HISTORY.md
    git add -A
    git diff --cached --quiet || git commit --quiet -m "coverage: ${commit:0:12} overall $(jq -r '.overall.percent' "${result}")%, owned $(jq -r '.owned.percent' "${result}")%"
}

for attempt in 1 2 3 4 5; do
    dir="${work}/c${attempt}"
    checkout "${dir}"
    (
        cd "${dir}"
        update
    )
    if git -C "${dir}" -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
        push --quiet origin HEAD:refs/heads/coverage; then
        echo "coverage branch updated with ${commit}: $(tail -n1 "${dir}/history.jsonl")"
        exit 0
    fi
    echo "push rejected (attempt ${attempt}), retrying on the updated coverage branch" 1>&2
    sleep $((attempt * 5))
done
echo "could not update the coverage branch" 1>&2
exit 1
