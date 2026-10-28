#!/usr/bin/env bash
# Fork-owned CI tool: self-test of .ci/fork/coverage.lua (run by coverage.sh before the gates).
#
# Usage: coverage_test.sh KODIR
#
# KODIR holds `luajit` and `spec/rocks` (luacov), e.g. the extracted emulator.
# Checks, on a synthetic repository, the overall unit-test coverage gate ("unit"): only
# the unit tests' stats count, and its dated targets are not enforced before their date,
# then enforced (exit code 1) from it.

set -eo pipefail

kodir="$(cd "$1" && pwd)"
tool="$(cd "$(dirname "$0")" && pwd)/coverage.lua"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# Synthetic repository: 2 files of 10 executable lines each.
repo="${work}/repo"
mkdir -p "${repo}/frontend" "${repo}/plugins/x.koplugin" "${repo}/.ci"
for i in $(seq 1 10); do echo "a${i} = ${i}"; done >"${repo}/frontend/a.lua"
for i in $(seq 1 10); do echo "b${i} = ${i}"; done >"${repo}/plugins/x.koplugin/main.lua"
: >"${repo}/.ci/owned-modules.txt"
git -C "${repo}" init --quiet
git -C "${repo}" add -A
cat >"${work}/config.lua" <<'EOF'
return {
    gates = { diff_unit_min = 80, diff_combined_min = 90, ratchet_tolerance_pp = 0.1 },
    diff_include = { "^frontend/", "^plugins/" },
    owned_include = { "^frontend/", "^plugins/" },
    overall = {
        paths = { "frontend", "plugins" },
        exclude = {},
        baseline = { date = "2026-10-27", percent = 30 },
        targets = { { from = "2026-11-24", delta_pp = 5 } },
        unit = {
            baseline = { date = "2026-10-27", percent = 42 },
            targets = {
                { from = "2026-11-24", delta_pp = 5 },
                { from = "2026-12-22", delta_pp = 10 },
            },
        },
    },
    owned = { list = ".ci/owned-modules.txt", targets = { { from = "2026-10-27", min = 80 } } },
    stats_path_map = {},
}
EOF
# Unit tests run all of a.lua (50% overall), integration tests all of main.lua (100%).
printf '10:frontend/a.lua\n1 1 1 1 1 1 1 1 1 1 \n' >"${work}/unit.stats.out"
printf '10:plugins/x.koplugin/main.lua\n2 2 2 2 2 2 2 2 2 2 \n' >"${work}/integration.stats.out"

failures=0
# run TODAY ENFORCE EXPECTED_EXIT JQ_CHECK DESCRIPTION
run() {
    local code=0
    (
        cd "${kodir}"
        ./luajit -e "package.path='spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua;'..package.path" \
            "${tool}" --config "${work}/config.lua" --src "${repo}" \
            --unit "${work}/unit.stats.out" --integration "${work}/integration.stats.out" \
            --enforce "$2" --today "$1" --md "${work}/out.md" --json "${work}/out.json" >/dev/null
    ) || code=$?
    if [[ ${code} -ne $3 ]]; then
        echo "FAIL: $5: exit code ${code}, expected $3" 1>&2
        failures=$((failures + 1))
    elif ! jq -e "$4" "${work}/out.json" >/dev/null; then
        echo "FAIL: $5: ${4} is false in $(cat "${work}/out.json")" 1>&2
        failures=$((failures + 1))
    else
        echo "ok: $5"
    fi
}
unit_gate='(.gates[] | select(.id == "unit"))'
run 2026-11-01 unit 0 ".overall_unit.percent == 50 and .overall.percent == 100 and .overall_unit.min == null and ${unit_gate}.ok" \
    'unit-only coverage ignores the integration stats; no target before its date'
run 2026-11-24 unit 0 ".overall_unit.min == 47 and ${unit_gate}.ok and ${unit_gate}.enforced" \
    'first target (42 + 5 = 47%) met from its date'
run 2026-12-22 unit 1 ".overall_unit.min == 52 and (${unit_gate}.ok | not) and .ok == false" \
    'second target (52%) missed: enforced gate fails'
run 2026-12-22 diff,ratchet,owned 0 "(${unit_gate}.ok | not) and (${unit_gate}.enforced | not) and .ok" \
    'missed target not enforced when the unit gate is not (upstream sync PRs, pushes)'
grep -q 'Overall, unit tests only' "${work}/out.md" || {
    echo 'FAIL: report lacks the unit-tests-only overall line' 1>&2
    failures=$((failures + 1))
}
# Without `overall.unit` in the config: no unit gate (koreader-base before its baseline, …).
sed -i '/unit = {/,/^        },$/d' "${work}/config.lua"
run 2026-12-22 diff,ratchet,owned,unit 0 '([.gates[] | select(.id == "unit")] | length) == 0 and .ok' \
    'no overall.unit config: no unit gate'

if [[ ${failures} -gt 0 ]]; then
    echo "coverage_test.sh: ${failures} failure(s)" 1>&2
    exit 1
fi
echo "coverage_test.sh: all passed"
