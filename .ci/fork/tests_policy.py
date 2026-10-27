#!/usr/bin/env python3
"""Tests policy check (fork-owned CI tool, qvictl/koreader & qvictl/koreader-base).

A pull request that changes code must also add or change tests, unless a maintainer
(admin or maintain permission) applied the `no-tests-needed` label.

Only the PR's own changes count: commits that come from the upstream mirror branch
(i.e. upstream sync merges) are left out; for merge commits, only the files changed
while resolving conflicts are considered.

Usage: tests_policy.py --kind koreader|base --base BASE_SHA --head HEAD_SHA
                       [--upstream REF] [--pr NUMBER] [--repo OWNER/REPO]
                       [--summary FILE]
Needs `gh` (GH_TOKEN) to read the PR labels.
"""

import argparse
import json
import re
import subprocess
import sys

LABEL = "no-tests-needed"
MAINTAINER_PERMISSIONS = {"admin", "maintain"}

RULES = {
    "koreader": {
        "code": [r"^(frontend|plugins)/.*(?<!\.md)$", r"^[^/]+\.lua$"],
        "tests": [r"^spec/"],
        "describe_code": "`frontend/`, `plugins/`, top-level `*.lua`",
        "describe_tests": "`spec/` (unit tests in `spec/unit/`, emulator integration scenarios in `spec/integration/`)",
    },
    "base": {
        "code": [r"^ffi/.*\.lua$", r"^[^/]+\.(c|cpp|h)$", r"^input/", r"^ffi-cdecl/.*\.(c|cpp|h)$"],
        "tests": [r"^spec/"],
        "describe_code": "`ffi/*.lua`, top-level C/C++ sources, `input/`",
        "describe_tests": "`spec/`",
    },
}


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def gh_json(path):
    out = subprocess.run(["gh", "api", "--paginate", path], check=True, capture_output=True, text=True).stdout
    # --paginate concatenates JSON arrays: "[...][...]"
    out = out.replace("][", ",")
    return json.loads(out) if out.strip() else []


def own_changed_files(base, head, upstream):
    """Files changed by the PR's own commits (excluding upstream's)."""
    rev_args = ["rev-list", "--parents", "%s..%s" % (base, head)]
    if upstream:
        rev_args += ["--not", upstream]
    files, commits, merges = set(), 0, 0
    for line in git(*rev_args).splitlines():
        shas = line.split()
        commit, parents = shas[0], shas[1:]
        commits += 1
        if len(parents) > 1:
            merges += 1
            # Only what was changed when resolving the merge (combined diff).
            out = git("diff-tree", "--cc", "--name-only", "--no-commit-id", commit)
        else:
            out = git("diff-tree", "-r", "--name-only", "--no-commit-id", "--root", commit)
        files.update(f for f in out.splitlines() if f)
    return sorted(files), commits, merges


def label_override(repo, pr):
    """Returns (applied, by, ok): whether the label is on the PR and was applied by a maintainer."""
    labels = [l["name"] for l in gh_json("repos/%s/issues/%s/labels" % (repo, pr))]
    if LABEL not in labels:
        return False, None, False
    actor = None
    for ev in gh_json("repos/%s/issues/%s/events?per_page=100" % (repo, pr)):
        if ev.get("event") == "labeled" and ev.get("label", {}).get("name") == LABEL:
            actor = (ev.get("actor") or {}).get("login")
    if not actor:
        return True, None, False
    owner = repo.split("/")[0]
    if actor == owner:
        return True, "%s (owner)" % actor, True
    proc = subprocess.run(["gh", "api", "repos/%s/collaborators/%s/permission" % (repo, actor)],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        # The workflow token may not be allowed to read permissions: labels can only be
        # applied by collaborators with triage access or more anyway.
        return True, "%s (permission unknown)" % actor, True
    perm = json.loads(proc.stdout)
    role = perm.get("role_name") or perm.get("permission")
    return True, "%s (%s)" % (actor, role), role in MAINTAINER_PERMISSIONS


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", choices=sorted(RULES), required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--upstream")
    ap.add_argument("--pr")
    ap.add_argument("--repo")
    ap.add_argument("--summary")
    a = ap.parse_args()
    rules = RULES[a.kind]
    base = git("merge-base", a.base, a.head).strip()
    files, commits, merges = own_changed_files(base, a.head, a.upstream)
    code = [f for f in files if any(re.search(p, f) for p in rules["code"])]
    tests = [f for f in files if any(re.search(p, f) for p in rules["tests"])]

    md = ["<!-- fork-tests-policy -->", "## Tests policy", ""]
    ok = True
    if not code:
        md.append("No code change in this PR's own commits (%d commit(s), %d merge(s)): no test required. ✅" % (commits, merges))
    elif tests:
        md.append("Code changes come with test changes. ✅")
    else:
        applied, by, by_maintainer = label_override(a.repo, a.pr) if (a.repo and a.pr) else (False, None, False)
        if applied and by_maintainer:
            md.append("Code changed without test changes, but a maintainer (%s) applied `%s`. ✅" % (by, LABEL))
        else:
            ok = False
            md.append("❌ This PR changes code but adds or changes no test.")
            md.append("")
            md.append("Code is %s; tests live in %s. Add or update tests covering the change "
                      "(see CONTRIBUTING.md). Only a maintainer can waive this, with the `%s` label%s."
                      % (rules["describe_code"], rules["describe_tests"], LABEL,
                         (" (the label was applied by %s, who is not a maintainer)" % by) if applied else ""))
    if code:
        md.append("")
        md.append("<details><summary>%d code file(s), %d test file(s) changed</summary>\n" % (len(code), len(tests)))
        md.extend("- `%s`" % f for f in code + tests)
        md.append("\n</details>")
    text = "\n".join(md) + "\n"
    print(text)
    if a.summary:
        with open(a.summary, "w", encoding="utf-8") as f:
            f.write(text)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
