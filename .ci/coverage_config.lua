-- Coverage policy of the qvictl/koreader-base fork (see CONTRIBUTING.md and .ci/fork/coverage.lua).
-- Dated targets tighten automatically: edit only to change the policy.
return {
    gates = {
        -- Blocking on every PR to main.
        diff_unit_min = 80,         -- % of the changed executable ffi/*.lua lines run by the unit tests
        diff_combined_min = 90,     -- % run by the unit tests + qvictl/koreader's emulator integration tests
        ratchet_tolerance_pp = 0.1, -- overall coverage may not drop below main's by more than this
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
