#!/usr/bin/env python3
"""Select complete, isolated base suites without a persistent dependency map."""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import subprocess


class SelectionError(ValueError):
    pass


SHARED = {"ffi/loadlib.lua", "ffi/posix.lua", "ffi/__gc.lua", "ffi/util.lua", "ffi/blitbuffer.lua"}
LONG = re.compile(r"\[(=*)\[")


def git(repo, *args):
    try:
        return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE).decode()
    except (subprocess.CalledProcessError, UnicodeError) as exc:
        raise SelectionError("cannot read the requested Git history") from exc


def commit(repo, ref):
    if not ref or ref.startswith("-"):
        raise SelectionError("invalid commit reference")
    return git(repo, "rev-parse", "--verify", ref + "^{commit}").strip()


def paths(repo, sha):
    return set(git(repo, "ls-tree", "-r", "--name-only", "-z", sha).split("\0")) - {""}


def changes(repo, base, head):
    fields = git(repo, "diff", "--name-status", "--find-renames", "-z", base, head, "--").split("\0")
    result, deleted, index = set(), set(), 0
    while index < len(fields) and fields[index]:
        status, name = fields[index:index + 2]
        index += 2
        result.add(name)
        if status.startswith(("R", "C")):
            result.add(fields[index])
            index += 1
        if status.startswith(("D", "R")):
            deleted.add(name)
    return sorted(result), deleted


def tokens(source):
    """Separate strings/comments before recognizing loader calls."""
    result, index = [], 0
    while index < len(source):
        char = source[index]
        if char.isspace():
            index += 1
            continue
        comment = source.startswith("--", index)
        start = index + 2 if comment else index
        long = LONG.match(source, start)
        if long:
            end = source.find("]" + long[1] + "]", long.end())
            if end < 0:
                raise SelectionError("unterminated Lua long string/comment")
            if not comment:
                result.append(("string", source[long.end():end]))
            index = end + len(long[1]) + 2
        elif comment:
            end = source.find("\n", start)
            index = len(source) if end < 0 else end + 1
        elif char in "\"'":
            end, escaped = index + 1, False
            while end < len(source) and source[end] != char:
                if source[end] == "\\":
                    escaped = True
                    end += 2
                elif source[end] in "\r\n":
                    raise SelectionError("unterminated Lua quoted string")
                else:
                    end += 1
            if end >= len(source):
                raise SelectionError("unterminated Lua quoted string")
            result.append(("string", None if escaped else source[index + 1:end]))
            index = end + 1
        else:
            match = re.match(r"[A-Za-z_][A-Za-z_0-9]*", source[index:])
            value = match[0] if match else char
            result.append(("name" if match else "punct", value))
            index += len(value)
    return result


def dependencies(source, available):
    items = tokens(source)
    edges, opaque = set(), False
    for index, (kind, name) in enumerate(items):
        if kind != "name":
            continue
        before = items[index - 1][1] if index else None
        if name in ("execute", "popen") and before == "." and index >= 2 and items[index - 2][1] in ("os", "io"):
            opaque = True
        if name not in ("require", "loadfile", "dofile", "loadstring", "load"):
            continue
        if name != "require" and before in (".", ":", "function"):
            continue  # ffi.load is native, not Lua's load().
        tail = index + 1
        if before == "(" and index >= 2 and items[index - 2][1] == "pcall":
            if tail < len(items) and items[tail][1] == ",":
                tail += 1
        elif tail < len(items) and items[tail][1] == "(":
            tail += 1
        elif tail < len(items) and items[tail][1] == "=":
            continue  # A fixture's callback definition; its body is scanned.
        if tail >= len(items) or items[tail][0] != "string" or items[tail][1] is None:
            opaque = True
            continue
        value = items[tail][1]
        if tail + 2 < len(items) and items[tail + 1][1] == items[tail + 2][1] == ".":
            opaque = True
            continue
        if name in ("load", "loadstring"):
            opaque = True
            continue
        if name == "require":
            candidates = [value.replace(".", "/") + ".lua", "spec/unit/" + value + ".lua"]
        else:
            candidates = [value.removeprefix("./").replace("spec/base/", "spec/", 1)]
        found = set(candidates) & available
        edges.update(found)
        if not found and (name != "require" or value.startswith(("ffi/", "ffi."))):
            opaque = True
    return edges, opaque


def suite(path):
    return path.startswith("spec/unit/") and path.endswith("_spec.lua")


def documentation(path):
    return (path.endswith(".md") and ("/" not in path or path.startswith(("docs/", ".github/")))) or path.startswith(("spec/integration/", "spec/emulator/"))


def select(repo, base=None, head="HEAD"):
    head_sha = commit(repo, head)
    if head_sha != commit(repo, "HEAD"):
        raise SelectionError("head must be the actual checked-out commit")
    present = paths(repo, head_sha)
    tests = sorted(path for path in present if suite(path))
    if not tests:
        raise SelectionError("no base test suites found")
    result = dict(schema_version=1, mode="full", base_sha=None, head_sha=head_sha,
                  tests=tests, changed_files=[], reasons=[], total_tests=len(tests))
    def full(reason):
        result["reasons"] = [reason]
        return result
    if base is None:
        return full("no explicit comparison: local/manual/release defaults to full")
    base_sha = git(repo, "merge-base", commit(repo, base), head_sha).strip()
    changed, deleted = changes(repo, base_sha, head_sha)
    result.update(base_sha=base_sha, changed_files=changed)
    if not changed or all(documentation(path) for path in changed):
        result.update(mode="none", tests=[], reasons=["no production or unit-test changes"])
        return result
    for path in changed:
        if documentation(path):
            continue
        if path in SHARED or path.endswith("_h.lua"):
            return full("shared FFI implementation or declarations changed: " + path)
        if suite(path):
            if path in deleted:
                return full("a suite was removed or renamed")
            continue
        if not (path.startswith("ffi/") and path.endswith(".lua")):
            return full("native/build/framework/data or unknown path changed: " + path)

    reverse, opaque = defaultdict(set), set()
    trees = {sha: paths(repo, sha) for sha in (base_sha, head_sha)}
    available = set.union(*trees.values())
    nodes = {path for path in available if path.endswith(".lua") and path.startswith(("ffi/", "spec/unit/"))}
    for sha, tree in trees.items():
        for path in sorted(nodes & tree):
            edges, uncertain = dependencies(git(repo, "show", sha + ":" + path), available)
            for dependency in edges:
                reverse[dependency].add(path)
            if uncertain:
                opaque.add(path)
    def affected(starts):
        seen, queue = set(starts), list(starts)
        while queue:
            for consumer in reverse[queue.pop()]:
                if consumer not in seen:
                    seen.add(consumer)
                    queue.append(consumer)
        return seen
    production = {path for path in changed if path.startswith("ffi/") and path.endswith(".lua")}
    closure = affected(production)
    if any(path.startswith("ffi/") for path in closure & opaque):
        return full("affected production loader cannot be statically resolved")
    selected = (closure | set(changed)) & set(tests)
    if production and not selected:
        return full("production change has no proven suite consumer")
    if production:
        # Opaque consumers are wildcard dependencies. Each complete Meson suite
        # has its own LuaJIT process, so always including them cannot hide a test.
        for path in opaque:
            selected.update(affected({path}) & set(tests))
    if not selected:
        return full("cannot prove an empty unit selection safe")
    result.update(mode="selected", tests=sorted(selected), reasons=["changed suites and reverse dependencies; opaque consumers included"])
    return result


def read_manifest(repo, filename, backend=None):
    """Validate provenance and recompute selection before running/reporting it."""
    try:
        result = json.loads(filename.read_text())
        expected = select(repo, result["base_sha"], result["head_sha"])
        if result["schema_version"] != 1 or result["mode"] not in ("full", "selected", "none"):
            raise SelectionError("unsupported selection manifest")
        for field in ("base_sha", "head_sha", "changed_files", "total_tests"):
            if result[field] != expected[field]:
                raise SelectionError("selection manifest disagrees with Git: " + field)
        all_tests = sorted(path for path in paths(repo, result["head_sha"]) if suite(path))
        if result["mode"] == "full":
            valid = result["tests"] == all_tests
        else:
            valid = result["mode"] == expected["mode"] and result["tests"] == expected["tests"]
        if not valid:
            raise SelectionError("unsafe or stale test selection")
        if backend == "busted" and result["mode"] == "selected":
            result.update(mode="full", tests=all_tests)
            result["reasons"].append("shared-process busted backend: run all suites")
            filename.write_text(json.dumps(result, indent=2) + "\n")
        return result
    except (KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
        raise SelectionError("invalid selection manifest") from exc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--consume", type=Path)
    parser.add_argument("--backend", choices=("meson", "busted"))
    args = parser.parse_args()
    try:
        if args.consume:
            result = read_manifest(args.repo, args.consume, args.backend)
            print(result["mode"])
            if result["mode"] == "selected":
                names = [Path(path).name.removesuffix("_spec.lua") for path in result["tests"]]
                if len(set(names)) != len(names):
                    raise SelectionError("ambiguous Meson test names")
                print("\n".join(names))
            return
        if args.out is None:
            raise SelectionError("--out is required when generating a manifest")
        result = select(args.repo, args.base, args.head)
    except SelectionError as exc:
        parser.exit(2, str(exc) + "\n")
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(f"{result['mode']}: {len(result['tests'])}/{result['total_tests']} suites; " + "; ".join(result['reasons']))


if __name__ == "__main__":
    main()
