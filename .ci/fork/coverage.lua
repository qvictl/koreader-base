--[[
Coverage gates and report (fork-owned CI tool, qvictl/koreader & qvictl/koreader-base).

Runs with the emulator's luajit and luacov (from its spec/rocks). Computes, from luacov
stats of the unit tests and of the emulator integration tests:

  1. diff coverage (unit tests only) of the changed executable Lua lines;
  2. diff coverage (unit + integration);
  3. overall coverage of the configured paths, compared to main's at the change's base
     (ratchet; the baseline is chosen by coverage_baseline.sh);
  4. coverage of the fork-owned modules (.ci/owned-modules.txt), against dated targets;
  5. overall coverage vs its day-one baseline and dated targets (report only);
  6. overall coverage by the unit tests alone vs its day-one baseline and dated targets
     (`overall.unit` in the config): blocking from each target's date.

Usage:
  luajit coverage.lua --config CONFIG.lua --src DIR [--diff FILE] [--fork-diff FILE]
      [--unit STATS]... [--integration STATS]... [--baseline-overall PCT] [--baseline-label TEXT]
      [--enforce diff,ratchet,owned,unit] [--today YYYY-MM-DD] [--title TEXT] [--note TEXT]
      [--md FILE] [--json FILE]

  --diff       unified diff (-U0) of the change being checked (PR), for gates 1 & 2
  --fork-diff  unified diff (-U0) of the fork's changes vs upstream, for "fork" owned scopes
  --baseline-overall  main's overall coverage at the change's base, for the ratchet (gate 3)
  --baseline-label    where that baseline comes from (e.g. "main@1a2b3c4d (this change's base)")
  --enforce    gates whose failure makes the exit code 1 (others are reported only)

Exit code: 0, or 1 if an enforced gate fails.
]]

local LineScanner = require("luacov.linescanner")

local args = { unit = {}, integration = {}, enforce = {}, mode = "combined" }
do
    local i = 1
    local function nxt() i = i + 1; return arg[i] end
    while i <= #arg do
        local a = arg[i]
        if a == "--mode" then args.mode = nxt()
        elseif a == "--config" then args.config = nxt()
        elseif a == "--src" then args.src = nxt()
        elseif a == "--diff" then args.diff = nxt()
        elseif a == "--fork-diff" then args.fork_diff = nxt()
        elseif a == "--unit" then table.insert(args.unit, nxt())
        elseif a == "--integration" then table.insert(args.integration, nxt())
        elseif a == "--baseline-overall" then args.baseline_overall = tonumber(nxt())
        elseif a == "--baseline-label" then args.baseline_label = nxt()
        elseif a == "--enforce" then
            for g in nxt():gmatch("[^,]+") do args.enforce[g] = true end
        elseif a == "--today" then args.today = nxt()
        elseif a == "--title" then args.title = nxt()
        elseif a == "--note" then args.note = nxt()
        elseif a == "--md" then args.md = nxt()
        elseif a == "--json" then args.json = nxt()
        else error("unknown argument: " .. a)
        end
        i = i + 1
    end
    assert(args.config and args.src, "--config and --src are required")
end
assert(args.mode == "unit" or args.mode == "combined", "invalid coverage mode")
assert(args.mode ~= "unit" or #args.integration == 0, "unit mode cannot consume integration stats")
local unit_only = args.mode == "unit"
local config = dofile(args.config)
local today = args.today or os.date("!%Y-%m-%d")

-- Helpers. {{{

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return end
    local s = f:read("*a")
    f:close()
    return s
end

local function lines(path)
    local t = {}
    local s = readFile(path)
    if not s then return end
    for l in (s:gsub("\r", "") .. (s:sub(-1) == "\n" and "" or "\n")):gmatch("(.-)\n") do
        table.insert(t, l)
    end
    return t
end

local function matchesAny(path, patterns)
    for _, p in ipairs(patterns or {}) do
        if path:match(p) then return true end
    end
    return false
end

local function pct(covered, total)
    return total > 0 and (100 * covered / total) or 100
end

local function fmtPct(covered, total)
    if total == 0 then return "–" end
    return string.format("%.1f%%", pct(covered, total))
end

-- Value of a dated schedule ({ {from = "YYYY-MM-DD", value}, … }) for today.
local function scheduled(schedule, key)
    local v, from
    for _, s in ipairs(schedule or {}) do
        if s.from <= today then v, from = s[key], s.from end
    end
    return v, from
end

local function nextScheduled(schedule, key)
    for _, s in ipairs(schedule or {}) do
        if s.from > today then return s[key], s.from end
    end
end

-- }}}

-- Stats. {{{

-- Stats files use the paths KOReader loads files with (e.g. "./ffi/util.lua",
-- "frontend/ui/uimanager.lua"); map them to repository paths.
local function normalize(path)
    path = path:gsub("^@", ""):gsub("^%./", "")
    for _, m in ipairs(config.stats_path_map or {}) do
        if path:sub(1, #m[1]) == m[1] then
            path = m[2] .. path:sub(#m[1] + 1)
        end
    end
    return path
end

local function loadStats(files, into)
    into = into or {}
    for _, file in ipairs(files) do
        local f = io.open(file, "r")
        if not f then
            io.stderr:write("warning: cannot read stats file ", file, "\n")
        else
            while true do
                local header = f:read("*l")
                if not header then break end
                local name = header:match("^%d+:(.*)$")
                local counts = f:read("*l") or ""
                if name then
                    name = normalize(name)
                    local t = into[name] or {}
                    into[name] = t
                    local n = 0
                    for c in counts:gmatch("%d+") do
                        n = n + 1
                        t[n] = (t[n] or 0) + tonumber(c)
                    end
                end
            end
            f:close()
        end
    end
    return into
end

local unit_hits = loadStats(args.unit)
local combined_hits = loadStats(args.integration, loadStats(args.unit))

-- }}}

-- Line classification (as luacov's reporter does). {{{

local source_cache = {}
local function source(path)
    if source_cache[path] == nil then
        source_cache[path] = lines(args.src .. "/" .. path) or false
    end
    return source_cache[path] or nil
end

-- Returns { [line] = covered (bool) } for the executable lines of `path` (optionally
-- restricted to the `only` set of lines), with the given hits.
local function classify(path, hits_by_file, only)
    local src = source(path)
    if not src then return nil end
    local file_hits = hits_by_file[path] or {}
    local scanner = LineScanner:new()
    local result = {}
    for n, line in ipairs(src) do
        local always_excluded, excluded_when_not_hit = scanner:consume(line)
        if not only or only[n] then
            local h = file_hits[n] or 0
            if not always_excluded and not (excluded_when_not_hit and h == 0) then
                result[n] = h > 0
            end
        end
    end
    return result
end

local function count(classified)
    local covered, total, missed = 0, 0, {}
    for n, c in pairs(classified or {}) do
        total = total + 1
        if c then covered = covered + 1 else table.insert(missed, n) end
    end
    table.sort(missed)
    return covered, total, missed
end

local function ranges(list, max)
    local out, i = {}, 1
    while i <= #list do
        local j = i
        while j < #list and list[j + 1] == list[j] + 1 do j = j + 1 end
        table.insert(out, i == j and tostring(list[i]) or (list[i] .. "-" .. list[j]))
        i = j + 1
    end
    if max and #out > max then
        local n = #out
        out = { unpack(out, 1, max) }
        table.insert(out, string.format("… (%d more)", n - max))
    end
    return table.concat(out, ", ")
end

-- }}}

-- Diffs. {{{

-- Returns { [path] = { [line] = true } } of the added/modified lines, in order of appearance,
-- and the set of added files.
local function parseDiff(file, include)
    local changed, order, added = {}, {}, {}
    if not file then return changed, order, added end
    local cur, from_null
    for line in io.lines(file) do
        if line:match("^%-%-%- ") then
            from_null = line == "--- /dev/null"
        end
        local path = line:match("^%+%+%+ b/(.*)$")
        if path then
            cur = nil
            if path:match("%.lua$") and matchesAny(path, include) then
                cur = {}
                changed[path] = cur
                table.insert(order, path)
                if from_null then added[path] = true end
            end
        elseif line:match("^%+%+%+ /dev/null") then
            cur = nil
        elseif cur then
            local start, cnt = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
            if start then
                start = tonumber(start)
                cnt = cnt == "" and 1 or tonumber(cnt)
                for l = start, start + cnt - 1 do cur[l] = true end
            end
        end
    end
    return changed, order, added
end

local diff_changed, diff_order = parseDiff(args.diff, config.diff_include)
local fork_changed, fork_order, fork_added = parseDiff(args.fork_diff, config.owned_include or config.diff_include)

-- }}}

-- 1 & 2: diff coverage. {{{

local diff = { files = {}, unit = { covered = 0, total = 0 }, combined = { covered = 0, total = 0 } }
for _, path in ipairs(diff_order) do
    local u = classify(path, unit_hits, diff_changed[path])
    local c = classify(path, combined_hits, diff_changed[path])
    if c then
        local uc, ut = count(u)
        local cc, ct, missed = count(c)
        if ct > 0 then
            table.insert(diff.files, { path = path, unit_covered = uc, combined_covered = cc, total = ct, missed = missed,
                loaded = combined_hits[path] ~= nil })
            diff.unit.covered, diff.unit.total = diff.unit.covered + uc, diff.unit.total + ut
            diff.combined.covered, diff.combined.total = diff.combined.covered + cc, diff.combined.total + ct
        end
    end
end
diff.unit.percent = pct(diff.unit.covered, diff.unit.total)
diff.combined.percent = pct(diff.combined.covered, diff.combined.total)

-- }}}

-- 3 & 5: overall coverage. {{{

local overall = { covered = 0, total = 0, files = 0 }
local overall_unit = { covered = 0, total = 0 }
do
    local quoted = {}
    for _, p in ipairs(config.overall.paths) do table.insert(quoted, "'" .. p .. "'") end
    local p = io.popen("git -C '" .. args.src .. "' ls-files -- " .. table.concat(quoted, " "))
    for path in p:lines() do
        if path:match("%.lua$") and not matchesAny(path, config.overall.exclude) then
            local cc, ct = count(classify(path, combined_hits))
            overall.covered, overall.total, overall.files = overall.covered + cc, overall.total + ct, overall.files + 1
            local uc, ut = count(classify(path, unit_hits))
            overall_unit.covered, overall_unit.total = overall_unit.covered + uc, overall_unit.total + ut
        end
    end
    p:close()
end
overall.percent = pct(overall.covered, overall.total)
overall_unit.percent = pct(overall_unit.covered, overall_unit.total)

-- }}}

-- 4: owned modules. {{{

local owned = { modules = {}, covered = 0, total = 0 }
owned.min, owned.min_from = scheduled(config.owned.targets, "min")
owned.next_min, owned.next_from = nextScheduled(config.owned.targets, "min")

-- Lines of top-level functions `names` (e.g. "UIManager:widgetInvert"): from their
-- `function NAME(` line to the next line that is just `end`.
local function functionLines(path, names)
    local src = source(path)
    if not src then return nil end
    local set, found = {}, {}
    for name in names:gmatch("[^,]+") do
        local pat = "^function " .. name:gsub("[%.%:]", "%%%0") .. "%s*%("
        for n, l in ipairs(src) do
            if l:match(pat) then
                found[name] = true
                for m = n, #src do
                    set[m] = true
                    if m > n and src[m]:match("^end%s*$") then break end
                end
                break
            end
        end
        if not found[name] then
            io.stderr:write("warning: function ", name, " not found in ", path, "\n")
        end
    end
    return set
end

local listed = {}
local entries = {}
for _, l in ipairs(lines(args.src .. "/" .. config.owned.list) or {}) do
    local path, scope = l:match("^%s*([^#%s]+)%s+(%S+)")
    if path then
        listed[path] = true
        table.insert(entries, { path = path, scope = scope })
    end
end
-- Modules added by the fork are owned, even if not listed (yet).
for _, path in ipairs(fork_order) do
    if fork_added[path] and not listed[path] then
        table.insert(entries, { path = path, scope = "file", auto = true })
    end
end
for _, e in ipairs(entries) do
    local only
    if e.scope == "fork" then
        only = fork_changed[e.path] or {}
    elseif e.scope:match("^func:") then
        only = functionLines(e.path, e.scope:sub(6))
    end
    local c = classify(e.path, combined_hits, only)
    local cc, ct, missed = count(c)
    local _, file_total = count(classify(e.path, combined_hits))
    local file_covered = select(1, count(classify(e.path, combined_hits)))
    e.covered, e.total, e.missed = cc, ct, missed
    e.percent = pct(cc, ct)
    e.file_percent = file_total > 0 and pct(file_covered, file_total) or nil
    e.missing_source = c == nil
    e.ok = not e.missing_source and (ct == 0 or e.percent >= (owned.min or 0))
    owned.covered, owned.total = owned.covered + cc, owned.total + ct
    table.insert(owned.modules, e)
end
owned.percent = pct(owned.covered, owned.total)
owned.ok = true
for _, e in ipairs(owned.modules) do
    if not e.ok then owned.ok = false end
end
-- Fork-changed modules that are neither listed nor added by the fork: worth listing.
owned.unlisted = {}
for _, path in ipairs(fork_order) do
    if not listed[path] and not fork_added[path] then table.insert(owned.unlisted, path) end
end

-- }}}

-- Gates. {{{

local gates = {}
local function gate(id, name, ok, value, requirement)
    local g = { id = id, name = name, ok = ok, value = value, requirement = requirement, enforced = args.enforce[id] or false }
    table.insert(gates, g)
    return g
end
local cfg_gates = config.gates
if diff.combined.total == 0 then
    gate("diff", "Diff coverage, unit tests", true, "no changed executable line", "≥ " .. cfg_gates.diff_unit_min .. "%")
    if not unit_only then gate("diff", "Diff coverage, unit + integration", true, "no changed executable line", "≥ " .. cfg_gates.diff_combined_min .. "%") end
else
    gate("diff", "Diff coverage, unit tests", diff.unit.percent >= cfg_gates.diff_unit_min,
        string.format("%s (%d / %d)", fmtPct(diff.unit.covered, diff.unit.total), diff.unit.covered, diff.unit.total),
        "≥ " .. cfg_gates.diff_unit_min .. "%")
    if not unit_only then gate("diff", "Diff coverage, unit + integration", diff.combined.percent >= cfg_gates.diff_combined_min,
        string.format("%s (%d / %d)", fmtPct(diff.combined.covered, diff.combined.total), diff.combined.covered, diff.combined.total),
        "≥ " .. cfg_gates.diff_combined_min .. "%") end
end
if args.baseline_overall then
    gate("ratchet", "Overall coverage (ratchet)", overall.percent >= args.baseline_overall - cfg_gates.ratchet_tolerance_pp,
        string.format("%.2f%% (%+.2f pp)", overall.percent, overall.percent - args.baseline_overall),
        string.format("≥ %.2f%% (± %.2f pp) of %s", args.baseline_overall, cfg_gates.ratchet_tolerance_pp,
            args.baseline_label or "main"))
else
    gate("ratchet", "Overall coverage (ratchet)", true, string.format("%.2f%%", overall.percent),
        args.baseline_label or "no baseline for main yet")
end
gate("owned", unit_only and "Fork-owned modules, unit tests" or "Fork-owned modules", owned.ok,
    string.format("%s overall, lowest %s", fmtPct(owned.covered, owned.total),
        (function()
            local low
            for _, e in ipairs(owned.modules) do
                if e.total > 0 and (not low or e.percent < low.percent) then low = e end
            end
            return low and string.format("%.1f%% (%s)", low.percent, low.path:match("[^/]+$")) or "–"
        end)()),
    string.format("each ≥ %s%% (since %s)", owned.min or 0, owned.min_from or "–"))
-- 6: overall unit-test coverage vs its dated targets (blocking from each target's date).
local unit_cfg = config.overall.unit
local unit_base = unit_cfg and unit_cfg.baseline
local unit_target, unit_target_from, unit_next, unit_next_from
if unit_base and unit_base.percent then
    unit_target, unit_target_from = scheduled(unit_cfg.targets, "delta_pp")
    unit_next, unit_next_from = nextScheduled(unit_cfg.targets, "delta_pp")
    local value = string.format("%.2f%% (%+.2f pp vs day-one %.2f%%)", overall_unit.percent,
        overall_unit.percent - unit_base.percent, unit_base.percent)
    if unit_target then
        local min = unit_base.percent + unit_target
        overall_unit.min = min
        gate("unit", "Overall coverage, unit tests", overall_unit.percent >= min, value,
            string.format("≥ %.2f%% (since %s)%s", min, unit_target_from,
                unit_next and string.format("; %.2f%% from %s", unit_base.percent + unit_next, unit_next_from) or ""))
    elseif unit_next then
        gate("unit", "Overall coverage, unit tests", true, value,
            string.format("≥ %.2f%% from %s (not yet)", unit_base.percent + unit_next, unit_next_from))
    else
        gate("unit", "Overall coverage, unit tests", true, value, "no target")
    end
end
local failed = false
for _, g in ipairs(gates) do
    if g.enforced and not g.ok then failed = true end
end

-- Overall targets (report only).
local base = config.overall.baseline
local overall_target, overall_target_from = scheduled(config.overall.targets, "delta_pp")
local next_target, next_target_from = nextScheduled(config.overall.targets, "delta_pp")

-- }}}

-- Report. {{{

local md = {}
local function w(s) table.insert(md, s or "") end
w("<!-- fork-coverage -->")
w("## " .. (args.title or "Coverage"))
w()
w("| Gate | Value | Requirement | Status |")
w("|---|---|---|---|")
for _, g in ipairs(gates) do
    w(string.format("| %s | %s | %s | %s |", g.name, g.value, g.requirement,
        g.ok and "✅" or (g.enforced and "❌" or "⚠️ (not enforced)")))
end
w()
local otxt = string.format((unit_only and "**Overall, unit tests only** (%s, %d files):" or "**Overall, unit + integration** (%s, %d files):") .. " **%.2f%%** of %d executable lines",
    table.concat(config.overall.paths, ", "), overall.files, overall.percent, overall.total)
if not unit_only and base and base.percent then
    otxt = otxt .. string.format("; day-one baseline %.2f%% (%s)", base.percent, base.date)
    if overall_target then
        otxt = otxt .. string.format("; target %.2f%% since %s", base.percent + overall_target, overall_target_from)
    end
    if next_target then
        otxt = otxt .. string.format("; target %.2f%% from %s", base.percent + next_target, next_target_from)
    end
    otxt = otxt .. " (targets: report only)"
end
w(otxt .. ".")
if unit_base and unit_base.percent then
    w()
    w(string.format("**Overall, unit tests only**: **%.2f%%** of %d executable lines; day-one baseline %.2f%% (%s)%s%s (targets: blocking from their date).",
        overall_unit.percent, overall_unit.total, unit_base.percent, unit_base.date,
        unit_target and string.format("; target %.2f%% since %s", unit_base.percent + unit_target, unit_target_from) or "",
        unit_next and string.format("; target %.2f%% from %s", unit_base.percent + unit_next, unit_next_from) or ""))
end
w()
w(string.format("**Fork-owned modules** (`%s`; target each ≥ %s%%%s):", config.owned.list, owned.min or 0,
    owned.next_min and string.format(", %s%% from %s", owned.next_min, owned.next_from) or ""))
w()
w("| Module | Scope | Owned lines covered | Whole file | Status |")
w("|---|---|---:|---:|---|")
for _, e in ipairs(owned.modules) do
    w(string.format("| `%s`%s | %s | %s (%d / %d) | %s | %s |", e.path, e.auto and " (new, auto)" or "",
        e.scope, fmtPct(e.covered, e.total), e.covered, e.total,
        e.file_percent and string.format("%.1f%%", e.file_percent) or "–",
        e.missing_source and "❌ missing" or (e.ok and "✅" or ("❌ missed: " .. ranges(e.missed, 12)))))
end
if #owned.unlisted > 0 then
    w()
    w("Changed by the fork but not in the owned modules list: " .. table.concat((function()
        local t = {}
        for _, p in ipairs(owned.unlisted) do table.insert(t, "`" .. p .. "`") end
        return t
    end)(), ", ") .. ".")
end
if #diff.files > 0 then
    w()
    w("<details><summary>Changed lines (" .. #diff.files .. " file(s))</summary>")
    w()
    w(unit_only and "| File | Unit | Unit | Not run by unit tests |" or "| File | Unit | Unit + integration | Not run by any test |")
    w("|---|---:|---:|---|")
    for _, f in ipairs(diff.files) do
        w(string.format("| `%s` | %s | %s | %s |", f.path, fmtPct(f.unit_covered, f.total),
            fmtPct(f.combined_covered, f.total),
            #f.missed > 0 and (ranges(f.missed, 20) .. (f.loaded and "" or " (file never loaded)")) or "–"))
    end
    w()
    w("</details>")
end
if args.note then
    w()
    w(args.note)
end
local text = table.concat(md, "\n") .. "\n"
io.write(text)
if args.md then
    local f = assert(io.open(args.md, "w"))
    f:write(text)
    f:close()
end

-- JSON summary (baseline / history).
if args.json then
    local parts = {}
    local function add(k, v) table.insert(parts, string.format("%q: %s", k, v)) end
    add("date", string.format("%q", today))
    add("mode", string.format("%q", args.mode))
    add("overall", unit_only and "null" or string.format('{"covered": %d, "total": %d, "percent": %.3f, "files": %d}',
        overall.covered, overall.total, overall.percent, overall.files))
    add("overall_unit", string.format('{"covered": %d, "total": %d, "percent": %.3f, "min": %s}',
        overall_unit.covered, overall_unit.total, overall_unit.percent,
        overall_unit.min and string.format("%.3f", overall_unit.min) or "null"))
    add("diff_unit", string.format('{"covered": %d, "total": %d, "percent": %.3f}', diff.unit.covered, diff.unit.total, diff.unit.percent))
    add("diff_combined", unit_only and "null" or string.format('{"covered": %d, "total": %d, "percent": %.3f}',
        diff.combined.covered, diff.combined.total, diff.combined.percent))
    local mods = {}
    for _, e in ipairs(owned.modules) do
        table.insert(mods, string.format('%q: {"scope": %q, "covered": %d, "total": %d, "percent": %.3f}',
            e.path, e.scope, e.covered, e.total, e.percent))
    end
    add("ratchet", string.format('{"baseline": %s, "label": %s}',
        args.baseline_overall and string.format("%.3f", args.baseline_overall) or "null",
        args.baseline_label and string.format("%q", args.baseline_label) or "null"))
    add(unit_only and "owned_unit" or "owned", string.format('{"covered": %d, "total": %d, "percent": %.3f, "min": %s, "ok": %s, "modules": {%s}}',
        owned.covered, owned.total, owned.percent, owned.min or "null", tostring(owned.ok), table.concat(mods, ", ")))
    if unit_only then add("owned", "null") end
    local gs = {}
    for _, g in ipairs(gates) do
        table.insert(gs, string.format('{"id": %q, "name": %q, "ok": %s, "enforced": %s}', g.id, g.name, tostring(g.ok), tostring(g.enforced)))
    end
    add("gates", "[" .. table.concat(gs, ", ") .. "]")
    add("ok", tostring(not failed))
    local f = assert(io.open(args.json, "w"))
    f:write("{" .. table.concat(parts, ", ") .. "}\n")
    f:close()
end

os.exit(failed and 1 or 0)

-- }}}

-- vim: foldmethod=marker foldlevel=0
