#!/usr/bin/env bash
# Fork-owned CI tool: coverage gates & report (see .ci/fork/coverage.lua, CONTRIBUTING.md).
#
# Usage: coverage.sh ARTIFACTS_DIR
#
# ARTIFACTS_DIR holds the downloaded artifacts: a tarball with luajit & luacov
# (`koreader-emulator-x86_64.tar.xz`, or `base-luajit.tar.xz` for koreader-base), and the
# luacov stats: `*.stats.out` files under `unit-coverage*/` (unit tests) and
# `integration-coverage*/` (emulator integration tests).
#
# Environment: EVENT_NAME, PR_NUMBER, PR_BASE, PUSH_BEFORE, GH_TOKEN, GITHUB_REPOSITORY.
# Pull requests: all gates are enforced (diff, ratchet, owned modules, dated unit-test
# coverage target); upstream sync PRs
# (bringing upstream commits): only the owned modules gate. Pushes: report only.
# The ratchet compares with the coverage recorded for the main commit the change is based on
# (or its nearest recorded ancestor), not with main's latest: see coverage_baseline.sh.
# Outputs (GITHUB_OUTPUT): ok=true|false; writes coverage-result.json (for the history).

set -eo pipefail

artifacts="$(cd "$1" && pwd)"
: "${GITHUB_OUTPUT:=/dev/stdout}" "${GITHUB_STEP_SUMMARY:=/dev/stdout}"
tmp="${RUNNER_TEMP:-/tmp}"
src="${PWD}"

enforce=diff,ratchet,owned,unit
note=''
case "${EVENT_NAME}" in
    pull_request)
        # The merge ref's first parent (pull_request.base.sha may be older).
        base="$("${src}/.ci/fork/coverage_baseline.sh" base pull_request)" || base="${PR_BASE}"
        ;;
    workflow_dispatch)
        if [[ -n "${PR_NUMBER}" ]]; then
            base="$(gh pr view "${PR_NUMBER}" --json baseRefOid --jq .baseRefOid)"
        else
            enforce=''
            base="$(git rev-parse HEAD~1)"
        fi
        ;;
    *)
        enforce=''
        base="${PUSH_BEFORE}"
        if [[ -z "${base}" ]] || [[ "${base}" =~ ^0+$ ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
            base="$(git rev-parse HEAD~1)"
        fi
        note='(Push to main: reported, not enforced; this becomes the new baseline.)'
        ;;
esac
git fetch --quiet origin '+refs/heads/upstream:refs/remotes/origin/upstream' || true
git fetch --quiet origin '+refs/heads/coverage:refs/remotes/origin/coverage' 2>/dev/null || true
git fetch --quiet origin '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null || true
base="$(git merge-base "${base}" HEAD)"
# The ratchet's base: the main commit the change is based on.
case "${EVENT_NAME}" in
    workflow_dispatch) ratchet_base="$("${src}/.ci/fork/coverage_baseline.sh" base workflow_dispatch)" || ratchet_base="${base}" ;;
    *) ratchet_base="${base}" ;;
esac
if [[ -n "${enforce}" ]] && git rev-parse -q --verify origin/upstream >/dev/null; then
    all="$(git rev-list --count "${base}..HEAD")"
    own="$(git rev-list --count "${base}..HEAD" --not origin/upstream)"
    if [[ "${own}" != "${all}" ]]; then
        enforce=owned
        note="This change brings $((all - own)) upstream commit(s) (upstream sync): only the owned modules gate is enforced."
    fi
fi
echo "base: ${base}, ratchet base: ${ratchet_base}, head: $(git rev-parse HEAD), enforce: ${enforce:-none}"

git diff -U0 "${base}" HEAD -- '*.lua' >"${tmp}/change.diff"
if git rev-parse -q --verify origin/upstream >/dev/null; then
    git diff -U0 "$(git merge-base HEAD origin/upstream)" HEAD -- '*.lua' >"${tmp}/fork.diff"
else
    : >"${tmp}/fork.diff"
fi
git show origin/coverage:history.jsonl >"${tmp}/coverage-history.jsonl" 2>/dev/null || : >"${tmp}/coverage-history.jsonl"
if read -r bsha bpct bkind < <("${src}/.ci/fork/coverage_baseline.sh" lookup "${ratchet_base}" "${tmp}/coverage-history.jsonl"); then
    if [[ "${bkind}" == exact ]]; then
        label="main@${bsha:0:8} (this change's base)"
    else
        label="main@${bsha:0:8} (nearest ancestor with coverage of base ${ratchet_base:0:8})"
    fi
    baseline=(--baseline-overall "${bpct}" --baseline-label "${label}")
else
    baseline=(--baseline-label "no coverage recorded for base ${ratchet_base:0:8} or its ancestors")
fi
echo "ratchet baseline: ${baseline[*]}"

# luajit & luacov.
emu="${tmp}/coverage-luajit"
rm -rf "${emu}"
mkdir -p "${emu}"
tarball="$(find "${artifacts}" -name 'koreader-emulator-x86_64.tar.xz' -o -name 'base-luajit.tar.xz' | head -n1)"
tar -C "${emu}" -xJf "${tarball}" koreader/luajit koreader/spec/rocks 2>/dev/null || tar -C "${emu}" -xJf "${tarball}"
# Self-test of the gates' tool.
"${src}/.ci/fork/coverage_test.sh" "${emu}/koreader" || exit 2
stats=()
while read -r f; do
    case "${f}" in
        */integration-coverage*) stats+=(--integration "${f}") ;;
        *) stats+=(--unit "${f}") ;;
    esac
done < <(find "${artifacts}" -name '*.stats.out' | sort)
echo "stats: ${stats[*]}"

md="${tmp}/coverage.md"
code=0
(
    cd "${emu}/koreader"
    ./luajit -e "package.path='spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua;'..package.path" \
        "${src}/.ci/fork/coverage.lua" --config "${src}/.ci/coverage_config.lua" --src "${src}" \
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
