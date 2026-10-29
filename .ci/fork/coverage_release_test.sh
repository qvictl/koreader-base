#!/usr/bin/env bash
# Synthetic exact-source/provenance and cumulative release-diff regression tests.
# Usage: coverage_release_test.sh KODIR
set -eo pipefail

tools="$(cd "$(dirname "$0")" && pwd)"
kodir="$(cd "$1" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
repo="${work}/source"
mkdir -p "${repo}/ffi" "${repo}/.ci" "${work}/artifacts/base-unit-coverage" "${work}/artifacts/integration-coverage" "${work}/output"
git init -q "${repo}"
git -C "${repo}" config user.email test@example.invalid
git -C "${repo}" config user.name test
cat >"${repo}/.ci/coverage_config.lua" <<'EOF'
return {
    gates = { diff_unit_min = 80, diff_combined_min = 90, ratchet_tolerance_pp = 0.1 },
    diff_include = { '^ffi/' }, owned_include = { '^ffi/' },
    overall = { paths = { 'ffi' }, exclude = {}, targets = {} },
    owned = { list = '.ci/owned-modules.txt', targets = {} }, stats_path_map = {},
}
EOF
: >"${repo}/.ci/owned-modules.txt"
printf 'a = 1\nb = 2\n' >"${repo}/ffi/example.lua"
git -C "${repo}" add -A
git -C "${repo}" commit -qm initial
first="$(git -C "${repo}" rev-parse HEAD)"
printf 'c = 3\n' >>"${repo}/ffi/example.lua"
git -C "${repo}" commit -qam 'untested change'
daily="$(git -C "${repo}" rev-parse HEAD)"
printf 'release\n' >"${repo}/version.txt"
git -C "${repo}" add version.txt
git -C "${repo}" commit -qm 'version only'
head="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" remote add origin "${repo}"

history() {
    local blob tree commit
    blob="$(printf '%s\n' "$1" | git -C "${repo}" hash-object -w --stdin)"
    tree="$(printf '100644 blob %s\thistory.jsonl\n' "${blob}" | git -C "${repo}" mktree)"
    commit="$(printf 'coverage\n' | git -C "${repo}" commit-tree "${tree}")"
    git -C "${repo}" update-ref refs/heads/coverage "${commit}"
}
history "$(jq -cn --arg a "${first}" --arg b "${daily}" '{commit:$a,overall:100,unit:100},{commit:$b,overall:null,unit:100}')"
for kind in base-unit-coverage integration-coverage; do
    printf '%s\n' "${head}" >"${work}/artifacts/${kind}/base-sha.txt"
    printf '3:ffi/example.lua\n1 1 0 \n' >"${work}/artifacts/${kind}/sample.stats.out"
done

run() {
    local expected="$1" claimed="${2:-${head}}" code=0
    (
        cd "${work}/output"
        EXPECTED_BASE_SHA="${claimed}" GITHUB_OUTPUT="${work}/outputs" GITHUB_STEP_SUMMARY="${work}/summary" \
            "${tools}/coverage_release.sh" "${repo}" "${work}/artifacts" "${kodir}"
    ) >"${work}/log" 2>&1 || code=$?
    if [[ "${code}" != "${expected}" ]]; then
        cat "${work}/log" >&2
        echo "expected ${expected}, received ${code}" >&2
        exit 1
    fi
}

run 2 "${daily}"
echo 'PASS: source HEAD differs from expected product SHA rejected'

run 1
jq -e --arg a "${first}" --arg h "${head}" \
    '.commit == $h and .diff_base == $a and .diff_combined.total == 1 and .diff_combined.covered == 0 and .ratchet.baseline == 100' \
    "${work}/output/coverage-result.json" >/dev/null
echo 'PASS: version-only candidate checks all changes since actual combined ancestor, skipping daily null record'

for kind in base-unit-coverage integration-coverage; do
    printf '3:ffi/example.lua\n1 1 1 \n' >"${work}/artifacts/${kind}/sample.stats.out"
done
run 0
jq -e --arg a "${first}" --arg h "${head}" \
    '.ok == true and .commit == $h and .diff_base == $a and .overall.percent == 100 and .diff_combined.percent == 100 and .diff_combined.total == 1' \
    "${work}/output/coverage-result.json" >/dev/null
grep -qx "base_sha=${head}" "${work}/outputs"
echo 'PASS: valid exact-source candidate with full unit and integration coverage passes release gate'
for kind in base-unit-coverage integration-coverage; do
    printf '3:ffi/example.lua\n1 1 0 \n' >"${work}/artifacts/${kind}/sample.stats.out"
done

printf '%s\n' "${daily}" >"${work}/artifacts/integration-coverage/base-sha.txt"
run 2
echo 'PASS: mismatched product integration SHA rejected'
printf '%s\n' "${head}" >"${work}/artifacts/integration-coverage/base-sha.txt"
mv "${work}/artifacts/integration-coverage/sample.stats.out" "${work}/artifacts/integration-coverage/absent"
run 2
echo 'PASS: missing real integration statistics rejected'
mv "${work}/artifacts/integration-coverage/absent" "${work}/artifacts/integration-coverage/sample.stats.out"
printf 'dirty = true\n' >>"${repo}/ffi/example.lua"
run 2
echo 'PASS: tracked source differs from claimed SHA rejected'
sed -i '$d' "${repo}/ffi/example.lua"

history "$(jq -cn --arg b "${daily}" '{commit:$b,overall:null,unit:100}')"
run 1
jq -e '.ratchet.baseline == null and .diff_combined.total == 3' "${work}/output/coverage-result.json" >/dev/null
echo 'PASS: first combined measurement has no invented ratchet and checks complete source without upstream'
echo 'coverage_release_test.sh: all passed'
