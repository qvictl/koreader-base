#!/usr/bin/env bash
# Fork-owned CI tool: self-test of .ci/fork/coverage.lua (run by coverage.sh before the gates).
#
# Usage: coverage_test.sh KODIR
#
# KODIR holds `luajit` and `spec/rocks` (luacov), e.g. the extracted emulator.
# Checks, on a synthetic repository, the overall unit-test coverage gate ("unit"): only
# the unit tests' stats count, and its dated targets are not enforced before their date,
# then enforced (exit code 1) from it. Then, on a synthetic git history, the ratchet's
# baseline (coverage_baseline.sh): the PR's base commit (merge ref's first parent, or
# merge-base with main), its record in history.jsonl or its nearest recorded ancestor's,
# and PRs in flight on different bases each compared with their own base.

set -eo pipefail

kodir="$(cd "$1" && pwd)"
tool="$(cd "$(dirname "$0")" && pwd)/coverage.lua"
baseline_tool="$(cd "$(dirname "$0")" && pwd)/coverage_baseline.sh"
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

# Ratchet baseline. {{{
# main: A0 (before the coverage records) - A (49.95%) - X (record missing: CI cancelled) - B (59.95%:
# another PR merged with new tests).
h="${work}/hist"
g() { git -C "${h}" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
git init --quiet "${h}"
g checkout --quiet -b main
commit() {
    g commit --quiet --allow-empty -m "$1"
    g rev-parse HEAD
}
A0="$(commit A0)"
A="$(commit A)"
X="$(commit X)"
B="$(commit B)"
# PR branches: p1 from A, p2 from B, p3 from B, p4 from X.
for pr in p1:"${A}" p2:"${B}" p3:"${B}" p4:"${X}"; do
    g checkout --quiet -b "${pr%%:*}" "${pr#*:}"
    commit "${pr%%:*}" >/dev/null
done
# refs/pull/N/merge: the PR merged into its base (first parent).
merge_ref() {
    g checkout --quiet --detach "$2"
    g merge --quiet --no-ff --no-edit "$1"
    g rev-parse HEAD
}
M1="$(merge_ref p1 "${A}")"
M2="$(merge_ref p2 "${B}")"
M3="$(merge_ref p3 "${B}")"
M4="$(merge_ref p4 "${X}")"
# Out of order (B published before A), with a re-run of A (last record wins), and a bad line.
{
    echo "{\"date\":\"2026-10-28\",\"commit\":\"${B}\",\"overall\":59.95}"
    echo "{\"date\":\"2026-10-28\",\"commit\":\"${A}\",\"overall\":40.5}"
    echo 'not json'
    echo "{\"date\":\"2026-10-28\",\"commit\":\"${A}\",\"overall\":49.95}"
} >"${work}/history.jsonl"

# check DESCRIPTION ACTUAL EXPECTED
check() {
    if [[ "$2" == "$3" ]]; then
        echo "ok: $1"
    else
        echo "FAIL: $1: got '$2', expected '$3'" 1>&2
        failures=$((failures + 1))
    fi
}
lookup() { (cd "${h}" && "${baseline_tool}" lookup "$1" "${2:-${work}/history.jsonl}"); }
base_of() { (cd "${h}" && g checkout --quiet --detach "$1" && "${baseline_tool}" base "$2" main); }
check 'lookup: exact base SHA' "$(lookup "${B}")" "${B} 59.95 exact"
check 'lookup: re-run record of the same SHA wins' "$(lookup "${A}")" "${A} 49.95 exact"
check 'lookup: missing SHA -> nearest recorded ancestor' "$(lookup "${X}")" "${A} 49.95 ancestor"
check 'lookup: PR commit (not on main) -> nearest recorded ancestor' "$(lookup p2)" "${B} 59.95 ancestor"
check 'lookup: nothing recorded among the ancestors -> no baseline' "$(lookup "${A0}")" ''
: >"${work}/empty.jsonl"
check 'lookup: empty history -> no baseline' "$(lookup "${B}" "${work}/empty.jsonl")" ''
check 'lookup: missing history -> no baseline' "$(lookup "${B}" "${work}/missing.jsonl")" ''
check 'lookup: unknown base -> no baseline' "$(lookup 0123456789abcdef0123456789abcdef01234567)" ''
check 'base: pull_request merge ref -> first parent' "$(base_of "${M1}" pull_request)" "${A}"
check 'base: pull_request merge ref on a newer base' "$(base_of "${M2}" pull_request)" "${B}"
check 'base: workflow_dispatch on a branch -> merge-base with main' "$(base_of p4 workflow_dispatch)" "${X}"
check 'base: pull_request without a merge commit -> merge-base with main' "$(base_of p1 pull_request)" "${A}"

# Overall coverage of the synthetic repository: 50% (all of a.lua), 60% (+ 2 lines of main.lua).
printf '10:frontend/a.lua\n1 1 1 1 1 1 1 1 1 1 \n' >"${work}/cov50.stats.out"
cp "${work}/cov50.stats.out" "${work}/cov60.stats.out"
printf '10:plugins/x.koplugin/main.lua\n1 1 0 0 0 0 0 0 0 0 \n' >>"${work}/cov60.stats.out"
# ratchet MERGE_REF STATS EXPECTED_EXIT JQ_CHECK DESCRIPTION: the ratchet gate, as coverage.sh runs it.
ratchet() {
    local base bsha bpct bkind code=0 args=()
    base="$(base_of "$1" pull_request)"
    if read -r bsha bpct bkind < <(lookup "${base}"); then
        args=(--baseline-overall "${bpct}" --baseline-label "main@${bsha:0:8} (${bkind})")
    fi
    (
        cd "${kodir}"
        ./luajit -e "package.path='spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua;'..package.path" \
            "${tool}" --config "${work}/config.lua" --src "${repo}" --unit "${work}/$2" "${args[@]}" \
            --enforce ratchet --today 2026-10-28 --md "${work}/out.md" --json "${work}/out.json" >/dev/null
    ) || code=$?
    if [[ ${code} -ne $3 ]]; then
        echo "FAIL: $5: exit code ${code}, expected $3 ($(cat "${work}/out.json" 2>/dev/null))" 1>&2
        failures=$((failures + 1))
    elif ! jq -e "$4" "${work}/out.json" >/dev/null; then
        echo "FAIL: $5: ${4} is false in $(cat "${work}/out.json")" 1>&2
        failures=$((failures + 1))
    else
        echo "ok: $5"
    fi
}
ratchet_gate='(.gates[] | select(.id == "ratchet"))'
ratchet "${M1}" cov50.stats.out 0 ".ratchet.baseline == 49.95 and ${ratchet_gate}.ok" \
    'parallel PRs: PR on base A (49.95%) at 50% while B (59.95%) merged meanwhile: passes'
ratchet "${M2}" cov60.stats.out 0 ".ratchet.baseline == 59.95 and ${ratchet_gate}.ok" \
    'parallel PRs: PR on the newer base B (59.95%) at 60%: passes'
ratchet "${M3}" cov50.stats.out 1 ".ratchet.baseline == 59.95 and (${ratchet_gate}.ok | not) and .ok == false" \
    'parallel PRs: PR on base B (59.95%) dropping to 50%: fails'
ratchet "${M4}" cov50.stats.out 0 ".ratchet.baseline == 49.95 and (.ratchet.label | test(\"ancestor\")) and ${ratchet_gate}.ok" \
    'PR on X (no record): compared with its nearest recorded ancestor A'
grep -q "of main@${A:0:8} (ancestor)" "${work}/out.md" || {
    echo 'FAIL: report lacks the main commit the ratchet baseline comes from' 1>&2
    failures=$((failures + 1))
}
g checkout --quiet --detach "${A0}"
g merge --quiet --no-ff --no-edit p1
ratchet "$(g rev-parse HEAD)" cov50.stats.out 0 ".ratchet.baseline == null and ${ratchet_gate}.ok" \
    'PR on A0 (nothing recorded): no baseline, the ratchet passes (as before any record)'
# }}}

# Split measurements: daily unit gates cannot silently become combined measurements.
printf '10:frontend/a.lua\n1 1 1 1 1 1 1 1 0 0 \n' >"${work}/unit80.stats.out"
cat >"${work}/changed.diff" <<'EOF'
--- a/frontend/a.lua
+++ b/frontend/a.lua
@@ -1,10 +1,10 @@
EOF
mode_run() {
    local mode="$1" baseline="$2" expected="$3" expression="$4" code=0 extra=()
    [[ "${mode}" != combined ]] || extra=(--integration "${work}/integration.stats.out")
    (cd "${kodir}" && ./luajit -e "package.path='spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua;'..package.path" \
        "${tool}" --mode "${mode}" --config "${work}/config.lua" --src "${repo}" \
        --unit "${work}/unit80.stats.out" "${extra[@]}" --diff "${work}/changed.diff" \
        --baseline-overall "${baseline}" --enforce diff,ratchet --json "${work}/mode.json" >/dev/null) || code=$?
    check "$5: exit" "${code}" "${expected}"
    check "$5: metrics" "$(jq -e "${expression}" "${work}/mode.json")" true
}
mode_run unit 40 0 '.overall == null and .diff_combined == null and .owned == null and .owned_unit != null and .overall_unit.percent == 40 and .diff_unit.percent == 80' \
    'unit mode enforces 80%, measures only units, and leaves combined unmeasured'
mode_run combined 40 1 '([.gates[] | select(.name == "Diff coverage, unit + integration" and .enforced and (.ok | not))] | length) == 1' \
    'release still rejects combined changed-line coverage below 90%'
mode_run unit 50 1 '([.gates[] | select(.id == "ratchet" and .enforced and (.ok | not))] | length) == 1' \
    'daily unit overall ratchet rejects a regression'
{
    echo "{\"commit\":\"${A}\",\"overall\":49.95,\"unit\":30}"
    echo "{\"commit\":\"${B}\",\"mode\":\"unit\",\"overall\":null,\"unit\":40}"
} >"${work}/split-history.jsonl"
check 'combined lookup skips newer unmeasured unit-only main records' \
    "$(cd "${h}" && "${baseline_tool}" lookup "${B}" "${work}/split-history.jsonl" combined)" "${A} 49.95 ancestor"
check 'unit lookup uses the exact daily unit record, not the combined ancestor' \
    "$(cd "${h}" && "${baseline_tool}" lookup "${B}" "${work}/split-history.jsonl" unit)" "${B} 40 exact"
publisher="$(dirname "${tool}")/coverage_publish.sh"
jq --arg c "${A}" '. + {commit:$c,date:"2026-10-28"}' "${work}/mode.json" >"${work}/unit-result.json"
"${publisher}" --merge-record "${work}/unit-result.json" "${work}/split-history.jsonl" >"${work}/merged-record.json"
check 'unit-only rerun preserves an existing real combined measurement' \
    "$(jq -e '.overall == 49.95 and .unit == 40 and .mode == "combined"' "${work}/merged-record.json")" true
: >"${work}/empty-history.jsonl"
"${publisher}" --merge-record "${work}/unit-result.json" "${work}/empty-history.jsonl" >"${work}/new-record.json"
check 'new daily history never substitutes unit coverage for combined' \
    "$(jq -e '.overall == null and .unit == 40 and .mode == "unit" and .diff_combined == null' "${work}/new-record.json")" true

if [[ ${failures} -gt 0 ]]; then
    echo "coverage_test.sh: ${failures} failure(s)" 1>&2
    exit 1
fi
echo "coverage_test.sh: all passed"
