# Contributing to the qvictl koreader-base fork

本仓库是 KOReader 底层库 koreader-base 的独立维护分支。欢迎任何 PR——无论由人编写还是由 AI 编写。我们以**测试**而非作者身份把关。
This repository is an independently maintained fork of koreader-base. Pull requests are welcome, whether written by people or by AI: we gate on **tests**, not on authorship.

It is the `base` submodule of [qvictl/koreader](https://github.com/qvictl/koreader), whose `main` follows this repository's `main`.

## Branches

| Branch | What it is |
|---|---|
| `main` | The fork's line (default branch): upstream koreader-base `master`, plus the fork's changes. All PRs target `main`. |
| `upstream` | A pure mirror of [koreader/koreader-base](https://github.com/koreader/koreader-base) `master`, fast-forwarded weekly by the *Upstream sync* workflow. Never commit to it. |
| `sync/upstream-<date>` | Automated weekly merge of `upstream` into `main` (a PR to `main`). Merge it with a **merge commit**. |
| `master` | Legacy branch from when this was a plain GitHub fork. Not maintained. |

## What every PR needs

1. **Tests for any code change.** If your PR changes code (`ffi/*.lua`, top-level C/C++ sources, `input/`), it must add or update unit tests in `spec/unit/` (busted). For every **user-visible** effect (i.e. one KOReader users can observe), also add or update an emulator integration scenario in [qvictl/koreader](https://github.com/qvictl/koreader) (`spec/integration/scenarios/`), and name it in the PR. The required **Tests policy** check fails when code changes come without any `spec/` change; only a maintainer can waive it, with the `no-tests-needed` label, for documentation, comments or log wording changes.
2. **Coverage gates** (required **Coverage** check; policy in [`.ci/coverage_config.lua`](.ci/coverage_config.lua)). PRs and pushes to `main` keep the native build, FFI declaration and binary checks, and run affected complete unit suites. They do not build KOReader or run emulator integration tests.

   | PR gate | Requirement (blocking) |
   |---|---|
   | Diff coverage, **unit tests** only | ≥ **80%** of changed executable `ffi/*.lua` lines |

   The existing upstream-sync exception uses commit provenance: when the comparison range contains a commit reachable from a freshly fetched `origin/upstream`, diff unit coverage is reported without enforcing 80%. Branch names and labels do not grant this exception. Own-only ranges, missing/failed upstream classification, and initial empty-tree comparisons retain diff80. Reports expose the classification and actual measured coverage; release diff90, independent full-unit/combined ratchets and dated/module targets remain enforced.

   CI explicitly supplies the entire PR base or push `before` SHA. `unit-selection.json` records the actual merge-base, tested HEAD, changed files, selected suites and reasons. The selector follows literal Lua dependencies in both revisions and their reverse consumers; opaque consumers are included conservatively. Each selected suite runs in its own Meson/LuaJIT process. Shared FFI loaders/declarations, native/build/test framework changes, unknown production dependencies or the shared-process busted backend use all suites. Git/parse errors fail the job; production changes cannot succeed with an empty selection. Documentation/integration-only changes explicitly select no unit suites. Local `make test`, release runs, and manual CI without a PR comparison remain full by default.

   **Product release gate:** base has no separate release. KOReader's *Fork release* runs all base unit suites and real integration tests with the emulator and the exact base gitlink being published. Its base coverage gate requires unit and integration statistics with matching base-SHA manifests. Unit diff coverage remains ≥ **80%**, combined diff coverage remains ≥ **90%**, and full-unit and combined overall coverage have independent ratchets (± 0.1 pp). The dated overall unit target remains **33.62%** from 2026-11-24 and **38.62%** from 2026-12-22 (day-one 28.62%). Fork-owned modules must each reach **80%**, then **85%** from 2026-11-24 and **90%** from 2026-12-22. Release diff coverage covers all changes since the nearest ancestor with actual combined coverage, including changes merged across multiple PRs. With no combined history, the complete fork diff is checked and the report explicitly states that no ratchet baseline exists. The overall ratchets also consider existing full measurements of the candidate itself. Release verification fails if the established coverage branch cannot be fetched or its history cannot be read. Combined overall dated targets remain report-only.

   Daily PR/push reports use coverage `mode=diff`, report whole metrics as `null`, and never publish baseline/history records, even when dependency uncertainty selected all suites. Partial records are rejected by the publisher and skipped by baseline lookup. Product releases and explicit manual full runs can update the [`coverage`](../../tree/coverage) branch, which preserves independent actual unit and combined measurements at the same commit. Thresholds and dated targets are unchanged; whole gates consume full release data.
3. **All CI checks green** (required by branch protection of `main`): **Lint** (shellcheck/shfmt, luacheck, cmakelint), **Build and unit tests** (emulator build, FFI cdecls check, bincheck, unit tests), **Coverage**, **Tests policy**. Integration scenarios remain required test source for user-visible changes; execution gates product publication.
4. **Test evidence in the description** (see the PR template).

## Review and merge

Every PR to `main` is reviewed by the AI reviewer CodeRabbit and evaluated by the *Review gate*
workflow, which keeps a checklist comment on the PR. There is no human gate: the gate approves and enables auto-merge
(merge commit) when, on the head commit, all required checks passed (coverage gates included), CodeRabbit reviewed it
and does not request changes, every review thread is resolved, and the PR is not a draft and has no `do-not-merge` label.
Regressions are fixed forward. (Exception: an upstream sync PR opened by github-actions when `SYNC_TOKEN` is not
configured cannot be approved or auto-merged by the gate; the owner merges it.) AI comments flagged as potential issues / bugs must be fixed or answered with a
justification before resolving them. Details: [REVIEW_POLICY.md](REVIEW_POLICY.md).

所有合入 `main` 的 PR 由 AI（CodeRabbit）审查并经 *Review gate* 评估，不设人工关卡：最新提交上
必需检查全部通过（含覆盖率门禁）、AI 已审查且没有要求修改、所有审查对话已解决、非草稿且无 `do-not-merge` 时，网关自动批准
并开启自动合并（merge commit），出了回归就向前修复（例外：未配置 `SYNC_TOKEN` 时由 github-actions 创建的上游同步 PR，网关不能批准也不会自动合并，
由所有者合并）。AI 标出的潜在问题 / bug 必须修复或回复理由后才能解决对话。
详见 [REVIEW_POLICY.md](REVIEW_POLICY.md)。

## Running the tests locally

```sh
make                 # emulator build
make test            # unit tests (busted)
make test T=--coverage
```

## Upstream

Changes made here are **not** submitted upstream. Upstream is merged weekly into `main` through a PR; if a merge conflicts, an "Upstream sync conflict" issue lists the conflicting files, to be resolved by hand. If upstream can no longer be merged cleanly, the fork continues independently.
