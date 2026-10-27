#!/usr/bin/env bash
# Fork-owned CI tool: diff coverage of a change, from luacov stats (unit + integration).
#
# Usage: diff_coverage.sh koreader|base ARTIFACTS_DIR
#
# ARTIFACTS_DIR must hold the `koreader-emulator-x86_64` artifact (or, for koreader-base,
# `base-luajit`: a koreader/{luajit,spec/rocks} tarball), for luajit & luacov,
# and the coverage artifacts (any `*.stats.out` file under it is used).
#
# Environment: EVENT_NAME, PR_NUMBER, PR_BASE, PUSH_BEFORE, GH_TOKEN, GITHUB_REPOSITORY,
# DIFF_COVERAGE_THRESHOLD (default: 70).
# Outputs (GITHUB_OUTPUT): ok=true|false. Only pull requests are enforced: on pushes, and
# for upstream sync PRs (that bring upstream's commits), the coverage is only reported.

set -eo pipefail

kind="$1"
artifacts="$2"
threshold="${DIFF_COVERAGE_THRESHOLD:-70}"
: "${GITHUB_OUTPUT:=/dev/stdout}" "${GITHUB_STEP_SUMMARY:=/dev/stdout}"

mode=enforce
case "${EVENT_NAME}" in
    pull_request)
        base="${PR_BASE}"
        ;;
    workflow_dispatch)
        if [[ -n "${PR_NUMBER}" ]]; then
            base="$(gh pr view "${PR_NUMBER}" --json baseRefOid --jq .baseRefOid)"
        else
            mode=report
            base="$(git rev-parse HEAD~1)"
        fi
        ;;
    *)
        mode=report
        base="${PUSH_BEFORE}"
        if [[ -z "${base}" ]] || [[ "${base}" =~ ^0+$ ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
            base="$(git rev-parse HEAD~1)"
        fi
        ;;
esac
base="$(git merge-base "${base}" HEAD)"
note=''
if git rev-parse -q --verify origin/upstream >/dev/null; then
    all="$(git rev-list --count "${base}..HEAD")"
    own="$(git rev-list --count "${base}..HEAD" --not origin/upstream)"
    if [[ "${own}" != "${all}" ]]; then
        mode=report
        note="This change brings $((all - own)) upstream commit(s) (upstream sync): coverage is reported, not enforced."
    fi
fi
echo "base: ${base}, head: $(git rev-parse HEAD), mode: ${mode}"

case "${kind}" in
    koreader)
        pathspecs=('frontend/*.lua' 'plugins/*.lua' '*.lua')
        includes=(--include '^frontend/' --include '^plugins/' --include '^[^/]+%.lua$')
        ;;
    base)
        pathspecs=('ffi/*.lua')
        includes=(--include '^ffi/')
        ;;
    *)
        echo "unknown kind: ${kind}" 1>&2
        exit 2
        ;;
esac
git diff -U0 "${base}" HEAD -- "${pathspecs[@]}" >"${RUNNER_TEMP:-/tmp}/change.diff"

# luajit & luacov from the emulator build.
emu="${RUNNER_TEMP:-/tmp}/emu"
rm -rf "${emu}"
mkdir -p "${emu}"
# (koreader: the emulator build; koreader-base: a minimal luajit + test rocks tarball)
tarball="$(find "${artifacts}" -name 'koreader-emulator-x86_64.tar.xz' -o -name 'base-luajit.tar.xz' | head -n1)"
tar -C "${emu}" -xJf "${tarball}" koreader/luajit koreader/spec/rocks koreader/libs koreader/common 2>/dev/null ||
    tar -C "${emu}" -xJf "${tarball}"
mapfile -t stats < <(find "$(cd "${artifacts}" && pwd)" -name '*.stats.out' | sort)
echo "stats: ${stats[*]}"

md="${RUNNER_TEMP:-/tmp}/diff_coverage.md"
code=0
(
    cd "${emu}/koreader"
    ./luajit -e "package.path='spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua;'..package.path" \
        "${GITHUB_WORKSPACE:-${OLDPWD}}/.ci/fork/diff_coverage.lua" \
        --diff "${RUNNER_TEMP:-/tmp}/change.diff" --src "${GITHUB_WORKSPACE:-${OLDPWD}}" \
        "${includes[@]}" --threshold "${threshold}" --md "${md}" "${stats[@]}"
) || code=$?
if [[ ${code} -gt 1 ]]; then
    echo "diff_coverage.lua failed (${code})" 1>&2
    exit "${code}"
fi
if [[ -n "${note}" ]]; then
    printf '\n%s\n' "${note}" >>"${md}"
elif [[ "${mode}" == report ]]; then
    printf '\n%s\n' "(Push: coverage is reported, not enforced.)" >>"${md}"
fi
cat "${md}" >>"${GITHUB_STEP_SUMMARY}"

ok=true
if [[ "${mode}" == enforce ]] && [[ ${code} -ne 0 ]]; then
    ok=false
fi
echo "ok=${ok}" >>"${GITHUB_OUTPUT}"

# PR comment (best effort: the token is read-only for PRs from other repositories).
if [[ -n "${PR_NUMBER}" ]] && [[ -n "${GITHUB_REPOSITORY}" ]]; then
    body="$(cat "${md}")"
    id="$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --paginate \
        --jq '.[] | select(.body | startswith("<!-- fork-diff-coverage -->")) | .id' 2>/dev/null | tail -n1 || true)"
    if [[ -n "${id}" ]]; then
        gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${id}" -f body="${body}" >/dev/null || true
    else
        gh api -X POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" -f body="${body}" >/dev/null || true
    fi
fi
