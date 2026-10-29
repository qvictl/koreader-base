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
# Environment: EVENT_NAME, PR_NUMBER, PUSH_BEFORE, GH_TOKEN, GITHUB_REPOSITORY.
# Own PR/push ranges enforce diff80; existing upstream-sync ranges only report it.
# Partial measurements cannot become whole baselines.
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
comparison_base="${base}"
mode="diff"
enforce="diff"
note='Affected unit suites only; overall coverage is measured by the full product-release gate.'
baseline=()
if [[ "${base}" == null ]]; then
    [[ "${selection}" == full ]] || exit 2
    if [[ "${EVENT_NAME}" == push && (-z "${PUSH_BEFORE}" || "${PUSH_BEFORE}" =~ ^0+$) ]]; then
        # No previous branch exists: test everything and enforce diff80 across
        # the complete initial source, without publishing any whole metric.
        base="$(git hash-object -t tree /dev/null)"
        note='Initial push: all suites; changed-line unit gate covers the complete source.'
    else
        # Only an explicit manual full run can publish a standalone unit record.
        [[ "${EVENT_NAME}" == workflow_dispatch && -z "${PR_NUMBER}" ]] || exit 2
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
fi
# Preserve the existing upstream-sync exception, using commit membership rather
# than labels/branch names. Failed classification retains the ordinary diff80.
upstream_sync=false
upstream_commits=null
upstream_status=not_applicable
if [[ "${mode}" == diff && "${comparison_base}" != null ]]; then
    upstream_status=unavailable
    if git fetch --quiet origin '+refs/heads/upstream:refs/remotes/origin/upstream' 2>/dev/null &&
        git rev-parse --verify 'refs/remotes/origin/upstream^{commit}' >/dev/null 2>&1 &&
        all="$(git rev-list --count "${base}..HEAD")" &&
        own="$(git rev-list --count "${base}..HEAD" --not refs/remotes/origin/upstream)" &&
        [[ "${all}" =~ ^[0-9]+$ && "${own}" =~ ^[0-9]+$ && "${own}" -le "${all}" ]]; then
        upstream_status=verified
        upstream_commits=$((all - own))
        if [[ "${upstream_commits}" -gt 0 ]]; then
            upstream_sync=true
            enforce=none
            note="This change brings ${upstream_commits} upstream commit(s) (upstream sync): changed-line unit coverage is report-only; full release unit/combined gates remain enforced."
        else
            note+=' Classification: own-only (verified; 0 upstream commits); changed-line unit coverage is enforced.'
        fi
    else
        note+=' Upstream ownership unavailable; changed-line unit coverage remains enforced.'
    fi
fi
echo "base: ${base}, head: $(git rev-parse HEAD), mode: ${mode}, selection: ${selection}, enforce: ${enforce}"
echo "upstream ownership: ${upstream_status}, sync: ${upstream_sync}, commits: ${upstream_commits}"
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
"${src}/.ci/fork/coverage_sync_test.sh" "${tarball}" || exit 2
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
jq --arg commit "$(git rev-parse HEAD)" --arg event "${EVENT_NAME}" \
    --argjson sync "${upstream_sync}" --argjson count "${upstream_commits}" --arg status "${upstream_status}" \
    '. + {commit: $commit, event: $event, upstream_sync: $sync, upstream_commits: $count, upstream_status: $status}' \
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
