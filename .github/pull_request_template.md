<!--
Thanks for your contribution! PRs written by people or by AI are equally welcome here:
we gate on tests (see CONTRIBUTING.md). Please fill in every section.
AI reviewers and the review gate: see REVIEW_POLICY.md.
-->

### What and why

<!-- What does this change, and why? -->

### Tests

<!-- Which unit tests (spec/unit/…) did you add or change, and what do they check?
     User-visible effects: name the qvictl/koreader integration scenario (spec/integration/scenarios/…) covering them.
     If no test is possible, explain why: a maintainer may then apply `no-tests-needed`. -->

### Test evidence

<!-- How did you run them, and what was the result? e.g. `make test`: N successes / 0 failures;
     device testing (model, firmware); before/after numbers for performance or memory changes. -->

### Checklist

- [ ] Tests added or updated for every code change (or the reason why not is explained above)
- [ ] `make test` passes locally (or I rely on CI and checked its results)
- [ ] PR coverage green: affected unit suites cover ≥ 80% of changed executable lines (existing commit-provenance upstream-sync exception reports diff only); full unit/integration, independent overall ratchets and module targets gate the product release
- [ ] User-visible effects are covered by a qvictl/koreader integration scenario (named above)
- [ ] Every AI review comment flagged as a potential issue / bug is fixed or answered with a justification before resolving it ([REVIEW_POLICY.md](../blob/main/REVIEW_POLICY.md))
