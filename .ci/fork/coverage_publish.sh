#!/usr/bin/env bash
# Fork-owned CI tool: records main's coverage on the `coverage` branch (baseline for the
# ratchet, history, README badges).
#
# Usage: coverage_publish.sh COVERAGE_RESULT_JSON
#
# The `coverage` branch (data only, unprotected) holds:
#   baseline.json      main's latest coverage (the PR ratchet compares to its overall %)
#   history.jsonl      one line per push to main
#   HISTORY.md         the trend, as a table
#   badge.json, badge-owned.json   shields.io endpoint badges

set -eo pipefail

result="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
repo="${GITHUB_REPOSITORY:?}"
work="$(mktemp -d)"
git config --global user.name 'github-actions[bot]'
git config --global user.email '41898282+github-actions[bot]@users.noreply.github.com'
if git fetch --quiet origin '+refs/heads/coverage:refs/remotes/origin/coverage' 2>/dev/null; then
    git worktree add --quiet "${work}/c" refs/remotes/origin/coverage
    git -C "${work}/c" checkout --quiet -B coverage
else
    git worktree add --quiet --detach "${work}/c"
    git -C "${work}/c" checkout --quiet --orphan coverage
    git -C "${work}/c" rm -rq --cached . >/dev/null
    find "${work}/c" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
fi
cd "${work}/c"

jq -c '{date, commit, overall: .overall.percent, unit: (.overall_unit.percent // null), owned: .owned.percent, owned_ok: .owned.ok,
        owned_min: .owned.min, diff_unit: .diff_unit.percent, diff_combined: .diff_combined.percent}' \
    "${result}" >>history.jsonl
jq '. + {updated: (now | todate)}' "${result}" >baseline.json

color() {
    awk -v p="$1" 'BEGIN { if (p >= 90) print "brightgreen"; else if (p >= 80) print "green"; else if (p >= 60) print "yellowgreen"; else if (p >= 40) print "yellow"; else print "orange" }'
}
overall="$(jq -r '.overall.percent' "${result}")"
owned="$(jq -r '.owned.percent' "${result}")"
jq -n --arg m "$(printf '%.1f%%' "${overall}")" --arg c "$(color "${overall}")" \
    '{schemaVersion: 1, label: "coverage", message: $m, color: $c}' >badge.json
jq -n --arg m "$(printf '%.1f%%' "${owned}")" --arg c "$(color "${owned}")" \
    '{schemaVersion: 1, label: "fork-owned coverage", message: $m, color: $c}' >badge-owned.json
{
    echo "# Coverage history of \`main\` (${repo})"
    echo
    echo "Unit + emulator integration tests (luacov). Updated by CI on every push to main; the PR ratchet compares to \`baseline.json\`."
    echo
    echo "| Date | Commit | Overall | Unit tests only | Fork-owned modules | Owned target |"
    echo "|---|---|---:|---:|---:|---:|"
    tac history.jsonl | head -n 200 | jq -r --arg repo "${repo}" \
        '"| \(.date) | [\(.commit[0:10])](https://github.com/\($repo)/commit/\(.commit)) | \(.overall * 100 | round / 100)% | \(if .unit then "\(.unit * 100 | round / 100)%" else "–" end) | \(.owned * 100 | round / 100)% | \(.owned_min // "–")% |"'
} >HISTORY.md
git add -A
git commit --quiet -m "coverage: $(jq -r '.commit[0:12]' "${result}") overall ${overall}%, owned ${owned}%"
git push --quiet origin coverage
echo "coverage branch updated: overall ${overall}%, owned ${owned}%"
