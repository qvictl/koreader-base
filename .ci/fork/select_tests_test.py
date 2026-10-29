#!/usr/bin/env python3
"""Offline selection/provenance checks using generated Git fixtures."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("selection", Path(__file__).with_name("select_tests.py"))
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.repo = Path(self.work.name)
        self.git("init", "-q")
        self.git("config", "user.name", "fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write("ffi/leaf.lua", "return {}\n")
        self.write("ffi/wrapper.lua", 'return require("ffi/leaf")\n')
        self.write("ffi/other.lua", "return {}\n")
        self.write("spec/unit/leaf_spec.lua", 'local leaf = require "ffi/wrapper"\n')
        self.write("spec/unit/other_spec.lua", 'local other = require "ffi/other"\n')
        self.base = self.save()

    def git(self, *args):
        return selection.git(self.repo, *args).strip()

    def write(self, name, source):
        file = self.repo / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(source)

    def save(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def changed(self, name="ffi/leaf.lua", source="return {changed = true}\n"):
        self.write(name, source)
        self.save()
        return selection.select(self.repo, self.base)

    def manifest(self, result):
        file = self.repo / "manifest.json"
        file.write_text(json.dumps(result))
        return file

    def test_default_full(self):
        result = selection.select(self.repo)
        self.assertEqual(result["mode"], "full")
        self.assertIsNone(result["base_sha"])
        self.assertEqual(len(result["tests"]), 2)

    def test_reverse_dependencies_and_whole_range(self):
        self.changed()
        result = self.changed("README.md", "documentation\n")
        self.assertEqual(result["mode"], "selected")
        self.assertEqual(result["base_sha"], self.base)
        self.assertEqual(result["tests"], ["spec/unit/leaf_spec.lua"])
        self.assertEqual(result["changed_files"], ["README.md", "ffi/leaf.lua"])

    def test_merge_base_is_actual_common_ancestor(self):
        self.changed()
        head = self.git("rev-parse", "HEAD")
        self.git("checkout", "-qb", "parallel", self.base)
        self.changed("README.md", "parallel\n")
        parallel = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "--detach", head)
        self.assertEqual(selection.select(self.repo, parallel)["base_sha"], self.base)

    def test_pr_merge_uses_current_main_parent_and_entire_pr(self):
        self.git("checkout", "-qb", "pr")
        self.changed()
        self.changed("README.md", "later PR commit\n")
        self.git("checkout", "-qb", "advanced-main", self.base)
        self.changed("ffi/other.lua", "return {main = true}\n")
        main_parent = self.git("rev-parse", "HEAD")
        self.git("merge", "-q", "--no-ff", "pr", "-m", "synthetic PR merge")
        helper = Path(__file__).with_name("coverage_baseline.sh").resolve()
        actual_base = subprocess.check_output([str(helper), "base", "pull_request"], cwd=self.repo, text=True).strip()
        result = selection.select(self.repo, actual_base)
        self.assertEqual(result["base_sha"], main_parent)
        self.assertEqual(result["changed_files"], ["README.md", "ffi/leaf.lua"])
        self.assertEqual(result["tests"], ["spec/unit/leaf_spec.lua"])

    def test_direct_spec_only(self):
        self.assertEqual(self.changed("spec/unit/other_spec.lua", "assert(true)\n")["tests"], ["spec/unit/other_spec.lua"])

    def test_docs_and_integration_none(self):
        for path in ("README.md", "spec/integration/scenario.lua", "spec/emulator/example.lua"):
            with self.subTest(path=path):
                result = self.changed(path, "fixture\n")
                self.assertEqual((result["mode"], result["tests"]), ("none", []))

    def test_shared_native_and_unknown_full(self):
        for path in ("ffi/loadlib.lua", "ffi/util.lua", "ffi/posix.lua", "ffi/example_h.lua", "blitbuffer.c", "Makefile", "test-runner/runtests", "spec/unit/fixture.lua"):
            with self.subTest(path=path):
                self.git("reset", "-q", "--hard", self.base)
                self.assertEqual(self.changed(path)["mode"], "full")

    def test_unknown_production_consumer_full(self):
        self.assertEqual(self.changed("ffi/new.lua")["mode"], "full")

    def test_dynamic_production_loader_full(self):
        self.assertEqual(self.changed("ffi/wrapper.lua", 'return require("ffi/" .. name)\n')["mode"], "full")

    def test_opaque_suite_is_always_included(self):
        self.write("spec/unit/opaque_spec.lua", "local m = require(name)\n")
        self.base = self.save()
        self.assertEqual(self.changed()["tests"], ["spec/unit/leaf_spec.lua", "spec/unit/opaque_spec.lua"])

    def test_old_and_new_dependency_graphs(self):
        self.write("ffi/wrapper.lua", 'return require "ffi/other"\n')
        self.write("ffi/leaf.lua", "return {changed = true}\n")
        self.save()
        self.assertIn("spec/unit/leaf_spec.lua", selection.select(self.repo, self.base)["tests"])

    def test_computed_global_loaders_are_opaque(self):
        self.write("spec/unit/opaque_spec.lua", '_G["require"](module_name)\n')
        self.base = self.save()
        self.assertIn("spec/unit/opaque_spec.lua", self.changed()["tests"])
        result = self.changed("ffi/wrapper.lua", 'return package.loaders[1](module_name)\n')
        self.assertEqual(result["mode"], "full")

    def test_static_module_cache_access_has_an_edge(self):
        self.write("spec/unit/cache_spec.lua", 'local cached = package.loaded["ffi/leaf"]\n')
        self.base = self.save()
        self.assertEqual(self.changed()["tests"], ["spec/unit/cache_spec.lua", "spec/unit/leaf_spec.lua"])
        for source in ('package.loaded[name]', 'local loaded = package.loaded', 'package.path = path'):
            self.assertTrue(selection.dependencies(source, {"ffi/leaf.lua"})[1])

    def test_unresolved_lua_library_is_an_opaque_consumer(self):
        self.write("spec/unit/vendor_spec.lua", 'local vendor = require "ExternalLibrary"\n')
        self.base = self.save()
        self.assertIn("spec/unit/vendor_spec.lua", self.changed()["tests"])
        self.assertEqual(self.changed("ffi/wrapper.lua", 'return require "ExternalLibrary"\n')["mode"], "full")
        for name in ("ffi", "bit", "string.buffer", "libs/libkoreader-cre"):
            self.assertFalse(selection.dependencies('require "' + name + '"', set())[1])

    def test_out_of_graph_repository_wrapper_is_opaque(self):
        self.write("helper.lua", 'return require "ffi/leaf"\n')
        self.write("spec/unit/helper_spec.lua", 'local helper = require "helper"\n')
        self.base = self.save()
        self.assertIn("spec/unit/helper_spec.lua", self.changed()["tests"])

    def test_deleted_module_keeps_old_consumer(self):
        (self.repo / "ffi/leaf.lua").unlink()
        self.save()
        self.assertEqual(selection.select(self.repo, self.base)["tests"], ["spec/unit/leaf_spec.lua"])

    def test_renamed_suite_full(self):
        self.git("mv", "spec/unit/leaf_spec.lua", "spec/unit/new_spec.lua")
        self.save()
        self.assertEqual(selection.select(self.repo, self.base)["mode"], "full")

    def test_lexer_literals_comments_pcall_and_loadfile(self):
        edges, opaque = selection.dependencies('''
-- require "ffi/ignored"
--[=[ require "ffi/also_ignored" ]=]
local text = "require 'ffi/ignored'"
local a = pcall(require, "ffi.leaf")
local b = loadfile [=[ffi/wrapper.lua]=]
''', {"ffi/leaf.lua", "ffi/wrapper.lua"})
        self.assertEqual(edges, {"ffi/leaf.lua", "ffi/wrapper.lua"})
        self.assertFalse(opaque)

    def test_parser_and_git_errors_hard_fail(self):
        for ref in ("missing", "", "--all"):
            with self.assertRaises(selection.SelectionError):
                selection.select(self.repo, ref)
        self.write("ffi/leaf.lua", 'return "unterminated\n')
        self.save()
        with self.assertRaises(selection.SelectionError):
            selection.select(self.repo, self.base)

    def test_head_must_be_checked_out(self):
        self.changed()
        with self.assertRaises(selection.SelectionError):
            selection.select(self.repo, self.base, self.base)

    def test_empty_test_tree_hard_fails(self):
        self.git("rm", "-qr", "spec")
        self.save()
        with self.assertRaises(selection.SelectionError):
            selection.select(self.repo, self.base)

    def test_manifest_backend_fallback(self):
        file = self.manifest(self.changed())
        self.assertEqual(selection.read_manifest(self.repo, file, "meson")["mode"], "selected")
        self.assertEqual(selection.read_manifest(self.repo, file, "busted")["mode"], "full")
        self.assertEqual(len(selection.read_manifest(self.repo, file)["tests"]), 2)

    def test_manifest_cannot_hide_code_or_use_stale_sha(self):
        result = self.changed()
        for patch in ({"mode": "none", "tests": []}, {"tests": []}, {"head_sha": self.base}, {"changed_files": []}):
            with self.subTest(patch=patch), self.assertRaises(selection.SelectionError):
                selection.read_manifest(self.repo, self.manifest(dict(result, **patch)))

    def test_cli_failure_does_not_create_manifest(self):
        output = self.repo / "output.json"
        process = subprocess.run(["python3", str(Path(__file__).with_name("select_tests.py")), "--repo", str(self.repo), "--base", "bad-ref", "--out", str(output)], capture_output=True)
        self.assertEqual(process.returncode, 2)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
