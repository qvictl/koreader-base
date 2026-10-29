#!/usr/bin/env bash
# Product-release coverage for the exact base gitlink, using current fork CI tools.
# Usage: EXPECTED_BASE_SHA=... coverage_release.sh SOURCE ARTIFACTS KODIR
# ARTIFACTS/{base-unit-coverage,integration-coverage} each contain base-sha.txt
# and real *.stats.out files. KODIR is the product emulator (luajit + spec/rocks).
# Writes coverage-result.json in the caller's directory; never publishes by itself.

set -eo pipefail

tools="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$1" && pwd)"
artifacts="$(cd "$2" && pwd)"
kodir="$(cd "$3" && pwd)"
result="${PWD}/coverage-result.json"
: "${EXPECTED_BASE_SHA:?exact product base SHA is required}"
: "${GITHUB_OUTPUT:=/dev/stdout}" "${GITHUB_STEP_SUMMARY:=/dev/stdout}"
[[ "${EXPECTED_BASE_SHA}" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'invalid expected base SHA' >&2
    exit 2
}
head="$(git -C "${src}" rev-parse HEAD)"
[[ "${head}" == "${EXPECTED_BASE_SHA}" ]] || {
    echo 'base source SHA differs from product' >&2
    exit 2
}
git -C "${src}" diff --quiet HEAD -- || {
    echo 'base source has tracked changes' >&2
    exit 2
}

stats=()
for kind in base-unit-coverage integration-coverage; do
    dir="${artifacts}/${kind}"
    if [[ ! -f "${dir}/base-sha.txt" ]] || [[ "$(cat "${dir}/base-sha.txt")" != "${head}" ]]; then
        echo "${kind} is missing exact product base SHA provenance" >&2
        exit 2
    fi
    found=false
    while IFS= read -r -d '' file; do
        [[ -s "${file}" ]] || continue
        found=true
        if [[ "${kind}" == base-unit-coverage ]]; then
            stats+=(--unit "${file}")
        else
            stats+=(--integration "${file}")
        fi
    done < <(find "${dir}" -type f -name '*.stats.out' -print0 | sort -z)
    [[ "${found}" == true ]] || {
        echo "${kind} has no real coverage statistics" >&2
        exit 2
    }
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
if ! git -C "${src}" fetch --quiet origin '+refs/heads/coverage:refs/remotes/origin/coverage' 2>/dev/null; then
    echo 'cannot fetch established base coverage history; refusing to bypass release ratchet' >&2
    exit 2
fi
if ! git -C "${src}" show origin/coverage:history.jsonl >"${work}/history.jsonl" 2>/dev/null; then
    echo 'base coverage branch has no readable history.jsonl' >&2
    exit 2
fi
baseline=()
base=''
if parent="$(git -C "${src}" rev-parse --verify HEAD^ 2>/dev/null)" &&
    read -r base percent kind < <(cd "${src}" && "${tools}/coverage_baseline.sh" lookup "${parent}" "${work}/history.jsonl" combined); then
    echo "combined diff base: ${base} (previous actual measurement)"
else
    if git -C "${src}" rev-parse --verify origin/upstream >/dev/null 2>&1; then
        base="$(git -C "${src}" merge-base HEAD origin/upstream)"
    else
        base="$(git -C "${src}" hash-object -t tree /dev/null)"
    fi
fi
ratchet_base=''
if read -r ratchet_base percent kind < <(cd "${src}" && "${tools}/coverage_baseline.sh" lookup "${head}" "${work}/history.jsonl" combined); then
    baseline=(--baseline-overall "${percent}" --baseline-label "base@${ratchet_base:0:8} (latest actual combined measurement)")
else
    baseline=(--baseline-label 'no actual combined coverage; ratchet not established')
fi
git -C "${src}" diff -U0 "${base}" HEAD -- '*.lua' >"${work}/change.diff"
if git -C "${src}" rev-parse --verify origin/upstream >/dev/null 2>&1; then
    upstream="$(git -C "${src}" merge-base HEAD origin/upstream)"
    git -C "${src}" diff -U0 "${upstream}" HEAD -- '*.lua' >"${work}/fork.diff"
else
    empty="$(git -C "${src}" hash-object -t tree /dev/null)"
    git -C "${src}" diff -U0 "${empty}" HEAD -- '*.lua' >"${work}/fork.diff"
fi

"${tools}/coverage_test.sh" "${kodir}"
code=0
(
    cd "${kodir}"
    ./luajit -e "package.path='spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua;'..package.path" \
        "${tools}/coverage.lua" --mode combined --config "${src}/.ci/coverage_config.lua" --src "${src}" \
        --diff "${work}/change.diff" --fork-diff "${work}/fork.diff" "${stats[@]}" "${baseline[@]}" \
        --enforce diff,ratchet,owned,unit --title 'Base product-release coverage' \
        --md "${work}/coverage.md" --json "${result}"
) || code=$?
[[ "${code}" -le 1 ]] || exit "${code}"
jq --arg commit "${head}" --arg base "${base}" --arg ratchet "${ratchet_base}" --arg tooling "$(git -C "${tools}" rev-parse HEAD)" \
    '. + {commit: $commit, event: "product_release", diff_base: $base, ratchet_base: (if $ratchet == "" then null else $ratchet end), tooling_commit: $tooling}' \
    "${result}" >"${result}.tmp"
mv "${result}.tmp" "${result}"
cat "${work}/coverage.md" >>"${GITHUB_STEP_SUMMARY}"
{
    echo "base_sha=${head}"
    echo "baseline_sha=${base}"
    echo "diff_base_sha=${base}"
    echo "ratchet_base_sha=${ratchet_base}"
    echo "ok=$([[ "${code}" -eq 0 ]] && echo true || echo false)"
} >>"${GITHUB_OUTPUT}"
exit "${code}"
