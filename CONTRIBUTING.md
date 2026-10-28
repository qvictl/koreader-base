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
2. **Coverage gates** (required **Coverage** check; policy in [`.ci/coverage_config.lua`](.ci/coverage_config.lua)). Line coverage (luacov) of the unit tests, and of qvictl/koreader's emulator integration tests run against this base (the CI builds qvictl/koreader `main` with the PR's base):

   | Gate | Requirement (blocking) |
   |---|---|
   | Diff coverage, **unit tests** only | ≥ **80%** of the changed executable `ffi/*.lua` lines |
   | Diff coverage, **unit + integration** | ≥ **90%** |
   | **Overall** coverage of `ffi/*.lua` (minus generated `*_h.lua`) | must not drop below `main`'s at the PR's base commit (ratchet, ± 0.1 pp) |
   | **Fork-owned modules** ([`.ci/owned-modules.txt`](.ci/owned-modules.txt): `ffi/util.lua` subprocess code) | each ≥ **80%** from 2026-10-27, **85%** from 2026-11-24, **90%** from 2026-12-22 |
   | **Overall unit-test coverage** of `ffi/*.lua` (unit tests only) | ≥ **33.62%** from 2026-11-24, ≥ **38.62%** from 2026-12-22 (day-one 28.62%; not enforced before those dates; plan: [qvictl/koreader `doc/coverage-plan.md`](https://github.com/qvictl/koreader/blob/main/doc/coverage-plan.md)) |

   Overall targets (report only): day-one baseline +5 pp by 2026-11-24, +10 pp by 2026-12-22. Upstream sync PRs only enforce the owned-modules gate. Code run in subprocesses (`util.runInSubProcess`) is measured too (the tests save the children's stats). The ratchet compares a PR with the coverage recorded for the `main` commit it is based on (the first parent of the `refs/pull/N/merge` commit CI measures; for a run dispatched on a branch, its merge base with `main`), or else for its nearest recorded ancestor, not with `main`'s latest: PRs in flight do not have to merge one by one when another one adds tests; the report names the `main` commit the baseline comes from (no record at all: the ratchet is not checked). `main`'s per-commit coverage (`history.jsonl`), latest coverage (`baseline.json`), history and badges live on the [`coverage`](../../tree/coverage) branch, updated by CI on every push to `main`. Every PR gets a coverage comment and job summary.
3. **All CI checks green** (required by the branch protection of `main`): **Lint** (shellcheck/shfmt, luacheck, cmakelint), **Build and unit tests** (emulator build in upstream's `koreader/kobase` image, FFI cdecls check, bincheck, unit tests), **Integration tests** (qvictl/koreader's emulator scenarios with this base), **Coverage**, **Tests policy**.
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
