#!/usr/bin/env bash
# Real local Git ranges and actual coverage/reporting; synthetic luacov counters.
# Usage: coverage_sync_test.sh RUNTIME_TARBALL (no native build or network).
set -eo pipefail

tools="$(cd "$(dirname "$0")" && pwd)"
tarball="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
repo="${work}/source"
mkdir -p "${repo}/ffi" "${repo}/spec/unit" "${repo}/.ci/fork" "${repo}/artifacts/unit-coverage"
git init -q "${repo}"
git -C "${repo}" config user.name fixture
git -C "${repo}" config user.email fixture@example.invalid
for file in select_tests.py coverage.lua; do
    ln -s "${tools}/${file}" "${repo}/.ci/fork/${file}"
done
# The caller tests these independently. Prevent nested selftest recursion in
# this generated source fixture while keeping the real Lua/reporting path.
for file in coverage_test.sh coverage_release_test.sh coverage_sync_test.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${repo}/.ci/fork/${file}"
    chmod +x "${repo}/.ci/fork/${file}"
done
cat >"${repo}/.ci/coverage_config.lua" <<'EOF'
return {
    gates = { diff_unit_min = 80, diff_combined_min = 90, ratchet_tolerance_pp = 0.1 },
    diff_include = { '^ffi/' }, owned_include = { '^ffi/' },
    overall = { paths = { 'ffi' }, exclude = {}, targets = {} },
    owned = { list = '.ci/owned-modules.txt', targets = {} }, stats_path_map = {},
}
EOF
: >"${repo}/.ci/owned-modules.txt"
printf 'a = 1\nb = 2\n' >"${repo}/ffi/own.lua"
printf 'x = 1\ny = 2\n' >"${repo}/ffi/upstream.lua"
printf 'require "ffi/own"\nrequire "ffi/upstream"\n' >"${repo}/spec/unit/example_spec.lua"
git -C "${repo}" add -A
git -C "${repo}" commit -qm base
base="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" checkout -qb upstream
printf 'z = 3\n' >>"${repo}/ffi/upstream.lua"
git -C "${repo}" commit -qam upstream
upstream="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" checkout -qb sync/upstream-fixture "${base}"
printf 'c = 3\n' >>"${repo}/ffi/own.lua"
git -C "${repo}" commit -qam own
own="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" checkout -qb upstream-based-own "${upstream}"
printf 'c = 3\n' >>"${repo}/ffi/own.lua"
git -C "${repo}" commit -qam 'own after upstream'
based="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" checkout -q sync/upstream-fixture
git -C "${repo}" branch -m ordinary-feature
git -C "${repo}" merge --quiet --no-ff upstream -m sync
merged="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" remote add origin "${repo}"
ln -s "${tarball}" "${repo}/artifacts/unit-coverage/base-luajit.tar.xz"
printf '3:ffi/own.lua\n1 1 0 \n3:ffi/upstream.lua\n1 1 0 \n' >"${repo}/artifacts/unit-coverage/sample.stats.out"

run() {
    local head="$1" comparison="$2" expected="$3" args=()
    git -C "${repo}" checkout -q --detach "${head}"
    [[ "${comparison}" == initial ]] || args+=(--base "${comparison}")
    python3 "${tools}/select_tests.py" --repo "${repo}" "${args[@]}" --out "${repo}/artifacts/unit-coverage/unit-selection.json" >"${work}/selection.log"
    mkdir -p "${work}/scratch"
    : >"${work}/summary"
    : >"${work}/outputs"
    (
        cd "${repo}"
        EVENT_NAME=push PUSH_BEFORE="$([[ "${comparison}" == initial ]] && echo 0000000000000000000000000000000000000000 || echo "${comparison}")" \
        PR_NUMBER='' GITHUB_REPOSITORY='' RUNNER_TEMP="${work}/scratch" \
        GITHUB_OUTPUT="${work}/outputs" GITHUB_STEP_SUMMARY="${work}/summary" \
            "${tools}/coverage.sh" artifacts
    ) >"${work}/log" 2>&1 || {
        cat "${work}/log" >&2
        return 1
    }
    jq -e --argjson expected "${expected}" \
        '.mode == "diff" and .ok == $expected and .overall == null and .overall_unit == null and .owned == null and .owned_unit == null and .diff_combined == null' \
        "${repo}/coverage-result.json" >/dev/null
    grep -qx "ok=${expected}" "${work}/outputs"
}

enforced() {
    jq -e '.upstream_sync == false and ([.gates[] | select(.id == "diff") | .enforced] == [true])' "${repo}/coverage-result.json" >/dev/null
}

run "${own}" "${base}" false
enforced
jq -e '.upstream_commits == 0 and .upstream_status == "verified" and .diff_unit.percent == 0' "${repo}/coverage-result.json" >/dev/null
if grep -q 'upstream sync' "${work}/summary"; then exit 1; fi
echo 'PASS: own-only range retains diff80 despite a sync-shaped branch name'

run "${based}" "${upstream}" false
enforced
jq -e '.upstream_commits == 0 and .upstream_status == "verified"' "${repo}/coverage-result.json" >/dev/null
echo 'PASS: upstream history outside the comparison range does not waive own changes'

for comparison in "${base}" "${own}"; do
    run "${merged}" "${comparison}" true
    jq -e '.upstream_sync == true and .upstream_commits == 1 and .upstream_status == "verified" and .diff_unit.percent == 0 and ([.gates[] | select(.id == "diff") | {ok,enforced}] == [{ok:false,enforced:false}])' "${repo}/coverage-result.json" >/dev/null
    grep -q '1 upstream commit(s) (upstream sync)' "${work}/summary"
    grep -q 'full release unit/combined gates remain enforced' "${work}/summary"
done
echo 'PASS: mixed and first-parent sync ranges report low actual coverage without enforcing diff80'

git -C "${repo}" branch -D upstream >/dev/null
run "${merged}" "${base}" false
enforced
jq -e '.upstream_commits == null and .upstream_status == "unavailable"' "${repo}/coverage-result.json" >/dev/null
echo 'PASS: missing upstream branch retains diff80 even with a cached matching ref'

git -C "${repo}" branch upstream "${upstream}"
git -C "${repo}" remote set-url origin "${work}/missing-remote"
run "${merged}" "${base}" false
enforced
jq -e '.upstream_commits == null and .upstream_status == "unavailable"' "${repo}/coverage-result.json" >/dev/null
grep -q 'Upstream ownership unavailable' "${work}/summary"
echo 'PASS: fetch failure cannot use a stale upstream ref to waive diff80'

git -C "${repo}" remote set-url origin "${repo}"
# A malformed remote branch must not become a verified commit classification.
git -C "${repo}" rev-parse "${upstream}^{tree}" >"${repo}/.git/refs/heads/upstream"
git -C "${repo}" fetch --quiet origin '+refs/heads/upstream:refs/remotes/origin/upstream'
if git -C "${repo}" rev-parse --verify 'origin/upstream^{commit}' >/dev/null 2>&1; then exit 1; fi
run "${merged}" "${base}" false
enforced
jq -e '.upstream_commits == null and .upstream_status == "unavailable"' "${repo}/coverage-result.json" >/dev/null
echo 'PASS: a non-commit upstream ref cannot waive diff80'

printf '%s\n' "${upstream}" >"${repo}/.git/refs/heads/upstream"
run "${merged}" initial false
enforced
jq -e '.upstream_commits == null and .upstream_status == "not_applicable"' "${repo}/coverage-result.json" >/dev/null
if grep -q 'upstream sync' "${work}/summary"; then exit 1; fi
echo 'PASS: initial empty-tree coverage remains enforced despite upstream ancestry'
echo 'coverage_sync_test.sh: all passed'
