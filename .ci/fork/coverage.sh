#!/usr/bin/env bash
# Fork-owned CI tool: coverage gates & report (see .ci/fork/coverage.lua, CONTRIBUTING.md).
#
# Usage: coverage.sh ARTIFACTS_DIR
#
# ARTIFACTS_DIR holds the downloaded artifacts: a tarball with luajit & luacov
# (`koreader-emulator-x86_64.tar.xz`, or `base-luajit.tar.xz` for koreader-base), and the
# luacov stats: `*.stats.out` files under `unit-coverage*/` (unit tests only).
# Product-release combined coverage uses coverage_release.sh.
#
# Environment: EVENT_NAME, PR_NUMBER, GH_TOKEN, GITHUB_REPOSITORY.
# PR/push manifests enforce changed-line unit coverage only and cannot become baselines.
# An explicit manual full run also enforces the unit ratchet and dated unit target.
# Outputs (GITHUB_OUTPUT): ok=true|false; writes coverage-result.json.

set -eo pipefail

artifacts="$(cd "$1" && pwd)"
: "${GITHUB_OUTPUT:=/dev/stdout}" "${GITHUB_STEP_SUMMARY:=/dev/stdout}"
tmp="${RUNNER_TEMP:-/tmp}"
src="${PWD}"

manifest="${artifacts}/unit-coverage/unit-selection.json"
python3 "${src}/.ci/fork/select_tests.py" --consume "${manifest}" >/dev/null
selection="$(jq -r .mode "${manifest}")"
base="$(jq -r .base_sha "${manifest}")"
mode="diff"
enforce="diff"
note='Affected unit suites only; overall coverage is measured by the full product-release gate.'
baseline=()
if [[ "${base}" == null ]]; then
    # Only an explicit manual full run can publish a standalone full-unit record.
    [[ "${EVENT_NAME}" == workflow_dispatch && -z "${PR_NUMBER}" && "${selection}" == full ]] || exit 2
    mode=unit
    enforce=diff,ratchet,unit
    base="$(git rev-parse HEAD^)"
    note='Explicit manual full-unit measurement.'
    git fetch --quiet origin '+refs/heads/coverage:refs/remotes/origin/coverage'
    git show origin/coverage:history.jsonl >"${tmp}/coverage-history.jsonl"
    if read -r bsha bpct _kind < <("${src}/.ci/fork/coverage_baseline.sh" lookup HEAD "${tmp}/coverage-history.jsonl" unit); then
        baseline=(--baseline-overall "${bpct}" --baseline-label "main@${bsha:0:8} (latest actual unit measurement)")
    fi
fi
echo "base: ${base}, head: $(git rev-parse HEAD), mode: ${mode}, selection: ${selection}, enforce: ${enforce}"
git diff -U0 "${base}" HEAD -- '*.lua' >"${tmp}/change.diff"
# Whole fork-owned/module gates only consume full release data.
: >"${tmp}/fork.diff"

# luajit & luacov.
emu="${tmp}/coverage-luajit"
rm -rf "${emu}"
mkdir -p "${emu}"
tarball="$(find "${artifacts}" -name 'koreader-emulator-x86_64.tar.xz' -o -name 'base-luajit.tar.xz' | head -n1)"
tar -C "${emu}" -xJf "${tarball}" koreader/luajit koreader/spec/rocks 2>/dev/null || tar -C "${emu}" -xJf "${tarball}"
# Self-test of the gates' tool.
"${src}/.ci/fork/coverage_test.sh" "${emu}/koreader" || exit 2
# Synthetic source/provenance tests only; no KOReader build or integration suite.
"${src}/.ci/fork/coverage_release_test.sh" "${emu}/koreader" || exit 2
stats=()
while IFS= read -r -d '' f; do
    [[ -s "${f}" ]] && stats+=(--unit "${f}")
done < <(find "${artifacts}/unit-coverage" -name '*.stats.out' -print0 | sort -z)
if [[ "${selection}" == none ]]; then
    [[ ${#stats[@]} -eq 0 ]] || {
        echo 'no-test selection contains stale statistics' >&2
        exit 2
    }
else
    [[ ${#stats[@]} -gt 0 ]] || {
        echo 'unit run produced no coverage statistics' >&2
        exit 2
    }
fi
echo "stats: ${stats[*]}"

md="${tmp}/coverage.md"
code=0
(
    cd "${emu}/koreader"
    ./luajit -e "package.path='spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua;'..package.path" \
        "${src}/.ci/fork/coverage.lua" --mode "${mode}" --config "${src}/.ci/coverage_config.lua" --src "${src}" \
        --diff "${tmp}/change.diff" --fork-diff "${tmp}/fork.diff" "${stats[@]}" "${baseline[@]}" \
        --enforce "${enforce:-none}" --note "${note}" --md "${md}" --json "${src}/coverage-result.json"
) || code=$?
if [[ ${code} -gt 1 ]]; then
    echo "coverage.lua failed (${code})" 1>&2
    exit "${code}"
fi
cat "${md}" >>"${GITHUB_STEP_SUMMARY}"
jq --arg commit "$(git rev-parse HEAD)" --arg event "${EVENT_NAME}" '. + {commit: $commit, event: $event}' \
    coverage-result.json >coverage-result.json.tmp && mv coverage-result.json.tmp coverage-result.json
echo "ok=$([[ ${code} -eq 0 ]] && echo true || echo false)" >>"${GITHUB_OUTPUT}"

# PR comment (best effort: the token is read-only for PRs from other repositories).
if [[ -n "${PR_NUMBER}" ]] && [[ -n "${GITHUB_REPOSITORY}" ]]; then
    body="$(cat "${md}")"
    id="$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --paginate \
        --jq '.[] | select(.body | startswith("<!-- fork-coverage -->")) | .id' 2>/dev/null | tail -n1 || true)"
    if [[ -n "${id}" ]]; then
        gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${id}" -f body="${body}" >/dev/null || true
    else
        gh api -X POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" -f body="${body}" >/dev/null || true
    fi
fi
