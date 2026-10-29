-- Coverage policy of the qvictl/koreader-base fork (see CONTRIBUTING.md and .ci/fork/coverage.lua).
-- Dated targets tighten automatically: edit only to change the policy.
return {
    gates = {
        -- Diff unit gates run on PRs; whole unit/combined/owned gates run on releases.
        diff_unit_min = 80,         -- % of the changed executable ffi/*.lua lines run by the unit tests
        diff_combined_min = 90,     -- % run by the unit tests + qvictl/koreader's emulator integration tests
        ratchet_tolerance_pp = 0.1, -- selected metric may not regress beyond this tolerance
    },
    diff_include = { "^ffi/" },
    owned_include = { "^ffi/" },
    overall = {
        paths = { "ffi" },
        -- (generated FFI declarations)
        exclude = { "_h%.lua$" },
        baseline = { date = "2026-10-27", percent = 35.62 }, -- main @ d8df83d8
        targets = {
            { from = "2026-11-24", delta_pp = 5 },
            { from = "2026-12-22", delta_pp = 10 },
        },
        -- The same files, covered by the unit tests alone (spec/unit). Unlike the targets
        -- above, these are blocking (the "unit" gate) from their date. Plan: qvictl/koreader's
        -- doc/coverage-plan.md.
        unit = {
            baseline = { date = "2026-10-27", percent = 28.62 }, -- main @ de93ce40 (unit stats only)
            targets = {
                { from = "2026-11-24", delta_pp = 5 },  -- ≥ 33.62%
                { from = "2026-12-22", delta_pp = 10 }, -- ≥ 38.62%
            },
        },
    },
    owned = {
        list = ".ci/owned-modules.txt",
        targets = {
            { from = "2026-10-27", min = 80 },
            { from = "2026-11-24", min = 85 },
            { from = "2026-12-22", min = 90 },
        },
    },
    stats_path_map = {},
}
