#!/usr/bin/env bash
# Fork-owned CI tool: weekly upstream sync (qvictl/koreader, qvictl/koreader-base).
#
# Usage: upstream_sync.sh koreader|base UPSTREAM_URL UPSTREAM_BRANCH
#
# 1. Fast-forwards the `upstream` branch (pure mirror of upstream's master).
# 2. Mirrors upstream's new release tags (vYYYY.MM[.P]).
# 3. Merges `upstream` into `main` on a `sync/upstream-<date>` branch (koreader: and points
#    the `base` submodule at qvictl/koreader-base main), and opens a PR to `main`, whose CI
#    then runs. Merge-based: `main` is never rewritten.
# 4. On a merge conflict, opens (or updates) the "Upstream sync conflict" issue, listing the
#    conflicting files, and fails.
#
# Environment: GH_TOKEN (PR/issue API), USING_PAT=1 if pushes are made with a personal token
# (then PR events trigger CI by themselves; otherwise the PR's workflow runs, which wait for
# approval, are approved).

# Backquotes in single-quoted strings are markdown, not command substitutions.
# shellcheck disable=SC2016

set -eo pipefail

kind="$1"
upstream_url="$2"
upstream_branch="$3"
: "${GITHUB_STEP_SUMMARY:=/dev/stdout}"
repo="${GITHUB_REPOSITORY:?}"
issue_title='Upstream sync conflict'
label='upstream-sync'

log() {
    printf '%s\n' "$*" | tee -a "${GITHUB_STEP_SUMMARY}"
}

ensure_label() {
    gh label create "${label}" --color 0e8a16 --description 'Automated upstream sync' >/dev/null 2>&1 || true
}

open_issue_id() {
    gh issue list --state open --label "${label}" --search "in:title \"${issue_title}\"" --json number,title \
        --jq ".[] | select(.title == \"${issue_title}\") | .number" | head -n1
}

report_problem() {
    # $1: body (markdown)
    ensure_label
    local id
    id="$(open_issue_id || true)"
    if [[ -n "${id}" ]]; then
        gh issue edit "${id}" --body "$1" >/dev/null
        gh issue comment "${id}" --body "Still failing on $(date -u +%Y-%m-%d): see ${run_url}" >/dev/null
        log "Updated issue #${id}."
    else
        gh issue create --title "${issue_title}" --label "${label}" --body "$1" >/dev/null
        log "Opened issue \"${issue_title}\"."
    fi
}

close_issue_if_any() {
    local id
    id="$(open_issue_id || true)"
    if [[ -n "${id}" ]]; then
        gh issue close "${id}" --comment "$1" >/dev/null
        log "Closed issue #${id}."
    fi
}

run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID:-0}"
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

git remote remove upstream-src 2>/dev/null || true
git remote add upstream-src "${upstream_url}"
git fetch --quiet --no-tags upstream-src "+refs/heads/${upstream_branch}:refs/remotes/upstream-src/${upstream_branch}"
git fetch --quiet origin '+refs/heads/upstream:refs/remotes/origin/upstream' '+refs/heads/main:refs/remotes/origin/main'
new="$(git rev-parse "refs/remotes/upstream-src/${upstream_branch}")"
old="$(git rev-parse refs/remotes/origin/upstream)"
log "## Upstream sync (${kind})"
log ""
log "- upstream ${upstream_url} ${upstream_branch}: \`${new:0:12}\`"
log "- origin/upstream: \`${old:0:12}\`"

# 1. Mirror branch. {{{

if [[ "${old}" != "${new}" ]]; then
    if ! git merge-base --is-ancestor "${old}" "${new}"; then
        report_problem "$(printf '%s\n\n%s\n' \
            "Upstream's \`${upstream_branch}\` (\`${new}\`) is not a fast-forward of our \`upstream\` mirror (\`${old}\`): upstream history was rewritten." \
            "Please check and update \`upstream\` manually. Run: ${run_url}")"
        exit 1
    fi
    if ! git push origin "${new}:refs/heads/upstream" 2>push.err; then
        cat push.err 1>&2
        if grep -qi 'workflow' push.err; then
            report_problem "$(printf '%s\n\n%s\n' \
                "Upstream changed GitHub workflow files, which the default workflow token is not allowed to push." \
                "Add a \`SYNC_TOKEN\` repository secret (a token with the \`contents\`, \`pull-requests\`, \`issues\` and \`workflows\` permissions on this repository), or push \`upstream\` manually. Run: ${run_url}")"
        fi
        exit 1
    fi
    log "- \`upstream\` fast-forwarded: ${old:0:12} → ${new:0:12} ($(git rev-list --count "${old}..${new}") commit(s))"
fi

# }}}

# 2. Release tags. {{{

git fetch --quiet --no-tags upstream-src '+refs/tags/v*:refs/tags/v*' || true
mapfile -t ours < <(git ls-remote --tags origin 'refs/tags/v*' | sed -n 's,^[0-9a-f]*\trefs/tags/\([^^]*\)$,\1,p' | sort -u)
mapfile -t theirs < <(git ls-remote --tags upstream-src 'refs/tags/v*' | sed -n 's,^[0-9a-f]*\trefs/tags/\([^^]*\)$,\1,p' | grep -E '^v[0-9]{4}\.[0-9]{2}(\.[0-9]+)?$' | sort -u)
mapfile -t missing < <(comm -13 <(printf '%s\n' "${ours[@]}") <(printf '%s\n' "${theirs[@]}"))
for tag in "${missing[@]}"; do
    [[ -n "${tag}" ]] || continue
    if git push --quiet origin "refs/tags/${tag}:refs/tags/${tag}"; then
        log "- mirrored upstream tag \`${tag}\`"
    fi
done

# }}}

# 3. Merge into main. {{{

base_note=''
target_base=''
if [[ "${kind}" == koreader ]]; then
    # Our base: qvictl/koreader-base main.
    target_base="$(git ls-remote "https://github.com/${repo%%/*}/koreader-base.git" refs/heads/main | cut -f1)"
    upstream_pin="$(git ls-tree "${new}" base | awk '{print $3}')"
    status="$(gh api "repos/${repo%%/*}/koreader-base/compare/${upstream_pin}...${target_base}" --jq .status 2>/dev/null || echo unknown)"
    case "${status}" in
        ahead | identical) base_note="qvictl/koreader-base main (\`${target_base:0:12}\`) contains the base commit upstream now uses (\`${upstream_pin:0:12}\`). ✅" ;;
        *) base_note="⚠️ qvictl/koreader-base main (\`${target_base:0:12}\`) does not contain the base commit upstream now uses (\`${upstream_pin:0:12}\`, compare status: ${status}): merge koreader-base's own upstream sync PR first, then re-run this sync." ;;
    esac
    log "- ${base_note}"
fi

ours_base="$(git ls-tree refs/remotes/origin/main base 2>/dev/null | awk '{print $3}')"
if git merge-base --is-ancestor "${new}" refs/remotes/origin/main && { [[ -z "${target_base}" ]] || [[ "${ours_base}" == "${target_base}" ]]; }; then
    log "- \`main\` already contains upstream \`${new:0:12}\`: nothing to merge."
    close_issue_if_any "Resolved: \`main\` now contains upstream \`${new:0:12}\`."
    exit 0
fi

branch="sync/upstream-$(date -u +%Y%m%d)"
git checkout --quiet -B "${branch}" refs/remotes/origin/main
nb_commits="$(git rev-list --count "refs/remotes/origin/main..${new}")"
msg="Merge upstream ${upstream_branch} (${new:0:12}) into main"
if ! git merge --quiet --no-ff --no-edit -m "${msg}" "${new}"; then
    mapfile -t conflicts < <(git diff --name-only --diff-filter=U)
    # The base submodule is ours: always keep pointing at qvictl/koreader-base main.
    if [[ -n "${target_base}" ]] && printf '%s\n' "${conflicts[@]}" | grep -qx base; then
        git update-index --cacheinfo "160000,${target_base},base"
        mapfile -t conflicts < <(git diff --name-only --diff-filter=U)
    fi
    if [[ ${#conflicts[@]} -gt 0 ]] && [[ -n "${conflicts[0]}" ]]; then
        git merge --abort
        body="$(
            printf 'Merging upstream `%s` (`%s`, %s new commit(s)) into `main` conflicts in:\n\n' "${upstream_branch}" "${new:0:12}" "${nb_commits}"
            printf -- '- `%s`\n' "${conflicts[@]}"
            printf '\nResolve it by hand: `git checkout -b %s origin/main && git merge origin/upstream`, fix the conflicts, push and open a PR to `main`. If upstream can no longer be merged cleanly, the fork goes on independently (see README).\n\nRun: %s\n' "${branch}" "${run_url}"
        )"
        log "- ❌ merge conflict in ${#conflicts[@]} file(s): ${conflicts[*]}"
        report_problem "${body}"
        exit 1
    fi
    git -c core.editor=true commit --quiet --no-edit -m "${msg}" -m "Conflict on the base submodule resolved by keeping qvictl/koreader-base main."
fi
if [[ -n "${target_base}" ]] && [[ "$(git ls-tree HEAD base | awk '{print $3}')" != "${target_base}" ]]; then
    git update-index --cacheinfo "160000,${target_base},base"
    git commit --quiet -m "base: bump to qvictl/koreader-base main (${target_base:0:12})"
fi
git push --quiet --force origin "HEAD:refs/heads/${branch}"
log "- pushed \`${branch}\` ($(git rev-parse --short HEAD))"

# }}}

# 4. Pull request. {{{

ensure_label
compare="https://github.com/${repo}/compare/${old}...${new}"
body="$(
    printf 'Automated weekly merge of upstream `%s` into `main` (%s new upstream commit(s)).\n\n' "${upstream_branch}" "${nb_commits}"
    printf -- '- upstream: %s @ `%s`\n' "${upstream_url}" "${new}"
    printf -- '- upstream changes since the last sync: %s\n' "${compare}"
    [[ -z "${base_note}" ]] || printf -- '- base: %s\n' "${base_note}"
    printf '\nMerge it with a **merge commit** (not squash/rebase), so that upstream history is kept and future syncs stay clean.\n'
    printf 'Generated by %s\n' "${run_url}"
)"
pr="$(gh pr list --head "${branch}" --base main --state open --json number --jq '.[].number' | head -n1)"
if [[ -z "${pr}" ]]; then
    url="$(gh pr create --head "${branch}" --base main --title "Upstream sync $(date -u +%Y-%m-%d)" --label "${label}" --body "${body}")"
    pr="${url##*/}"
    log "- opened PR #${pr}"
else
    gh pr edit "${pr}" --body "${body}" >/dev/null
    log "- updated PR #${pr}"
fi
# Older sync PRs are superseded.
for old_pr in $(gh pr list --base main --state open --label "${label}" --json number,headRefName \
    --jq ".[] | select(.headRefName != \"${branch}\" and (.headRefName | startswith(\"sync/upstream-\"))) | .number"); do
    gh pr close "${old_pr}" --delete-branch --comment "Superseded by #${pr}." >/dev/null || true
    log "- closed superseded PR #${old_pr}"
done
if [[ -z "${USING_PAT}" ]]; then
    # PRs opened with the workflow token get their pull_request workflow runs created as
    # "action_required" (waiting for approval): approve them, so the PR's checks run. If
    # that's not allowed, run CI on the branch explicitly instead (its checks then count
    # for the branch protection only once the PR runs are approved by a maintainer).
    head_sha="$(git rev-parse HEAD)"
    approved=0
    for _ in $(seq 1 12); do
        mapfile -t runs < <(gh api "repos/${repo}/actions/runs?head_sha=${head_sha}&event=pull_request&per_page=50" \
            --jq '.workflow_runs[] | select(.status == "action_required" or .conclusion == "action_required") | .id')
        if [[ ${#runs[@]} -gt 0 ]] && [[ -n "${runs[0]}" ]]; then
            for run in "${runs[@]}"; do
                if gh api -X POST "repos/${repo}/actions/runs/${run}/approve" >/dev/null; then
                    approved=$((approved + 1))
                fi
            done
            break
        fi
        sleep 10
    done
    if [[ ${approved} -gt 0 ]]; then
        log "- approved ${approved} pull_request workflow run(s) of #${pr}"
    else
        log "- ⚠️ could not approve the PR's workflow runs: dispatching CI on \`${branch}\` (a maintainer must approve the PR's own runs for its required checks)"
        for wf in ci.yml tests_policy.yml; do
            if [[ -e ".github/workflows/${wf}" ]]; then
                gh workflow run "${wf}" --ref "${branch}" -f pr="${pr}"
                log "- dispatched ${wf} on \`${branch}\`"
            fi
        done
    fi
fi
close_issue_if_any "Resolved: upstream merged cleanly into #${pr}."

# }}}

# vim: foldmethod=marker foldlevel=0
