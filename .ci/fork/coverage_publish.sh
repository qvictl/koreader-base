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
    {
        [[ ! -f history.jsonl ]] || jq -R -c --arg c "${commit}" 'fromjson? | objects | select(.commit != $c)' history.jsonl
        jq -c '{date, commit, overall: .overall.percent, unit: (.overall_unit.percent // null), owned: .owned.percent, owned_ok: .owned.ok,
                owned_min: .owned.min, diff_unit: .diff_unit.percent, diff_combined: .diff_combined.percent}' "${result}"
    } >history.jsonl.tmp
    mv history.jsonl.tmp history.jsonl
    # Baseline: unless this commit is an ancestor of the current one (older main commit).
    local old
    old="$(jq -r '.commit // empty' baseline.json 2>/dev/null || true)"
    if [[ -n "${old}" ]] && [[ "${old}" != "${commit}" ]] && git merge-base --is-ancestor "${commit}" "${old}" 2>/dev/null; then
        echo "baseline.json kept at ${old} (${commit} is older)"
    else
        jq '. + {updated: (now | todate)}' "${result}" >baseline.json
    fi

    overall="$(jq -r '.overall.percent' baseline.json)"
    owned="$(jq -r '.owned.percent' baseline.json)"
    jq -n --arg m "$(printf '%.1f%%' "${overall}")" --arg c "$(color "${overall}")" \
        '{schemaVersion: 1, label: "coverage", message: $m, color: $c}' >badge.json
    jq -n --arg m "$(printf '%.1f%%' "${owned}")" --arg c "$(color "${owned}")" \
        '{schemaVersion: 1, label: "fork-owned coverage", message: $m, color: $c}' >badge-owned.json
    {
        echo "# Coverage history of \`main\` (${repo})"
        echo
        echo "Unit + emulator integration tests (luacov). Updated by CI on every push to main; a PR's ratchet compares with the record of its base commit (\`history.jsonl\`)."
        echo
        echo "| Date | Commit | Overall | Unit tests only | Fork-owned modules | Owned target |"
        echo "|---|---|---:|---:|---:|---:|"
        tac history.jsonl | head -n 200 | jq -r --arg repo "${repo}" \
            '"| \(.date) | [\(.commit[0:10])](https://github.com/\($repo)/commit/\(.commit)) | \(.overall * 100 | round / 100)% | \(if .unit then "\(.unit * 100 | round / 100)%" else "–" end) | \(.owned * 100 | round / 100)% | \(.owned_min // "–")% |"'
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
    if git -C "${dir}" push --quiet origin HEAD:refs/heads/coverage; then
        echo "coverage branch updated with ${commit}: $(tail -n1 "${dir}/history.jsonl")"
        exit 0
    fi
    echo "push rejected (attempt ${attempt}), retrying on the updated coverage branch" 1>&2
    sleep $((attempt * 5))
done
echo "could not update the coverage branch" 1>&2
exit 1
