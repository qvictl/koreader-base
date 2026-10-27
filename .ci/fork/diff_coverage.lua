--[[
Diff coverage: which of the changed, executable Lua lines were run by the tests.

Fork-owned CI tool (qvictl/koreader, qvictl/koreader-base). Runs with the emulator's
luajit and luacov (from its spec/rocks), e.g.:

    cd koreader && ./luajit -e "package.path='spec/rocks/share/lua/5.1/?.lua;'..package.path" \
        diff_coverage.lua --diff pr.diff --src SRC_DIR --threshold 70 \
        --md summary.md --json result.json unit.stats.out integration.stats.out

    --diff FILE        unified diff (git diff -U0) of the change
    --src DIR          source tree the diff paths are relative to
    --map FROM=TO      map a path prefix of the stats files to a diff path prefix
                       (repeatable; e.g. "./ffi/=ffi/")
    --include PATTERN  only consider changed files matching this Lua pattern (repeatable)
    --threshold PCT    minimum coverage of changed executable lines (default: 70)
    --md FILE          write a markdown report
    --json FILE        write a JSON summary

Exit code: 0 if coverage >= threshold (or no changed executable line), 1 otherwise.
]]

local LineScanner = require("luacov.linescanner")

local args = { stats = {}, maps = {}, includes = {}, threshold = 70 }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--diff" then args.diff = arg[i + 1]; i = i + 2
        elseif a == "--src" then args.src = arg[i + 1]; i = i + 2
        elseif a == "--map" then
            local from, to = arg[i + 1]:match("^(.-)=(.*)$")
            table.insert(args.maps, { from, to }); i = i + 2
        elseif a == "--include" then table.insert(args.includes, arg[i + 1]); i = i + 2
        elseif a == "--threshold" then args.threshold = tonumber(arg[i + 1]); i = i + 2
        elseif a == "--md" then args.md = arg[i + 1]; i = i + 2
        elseif a == "--json" then args.json = arg[i + 1]; i = i + 2
        else table.insert(args.stats, a); i = i + 1
        end
    end
    assert(args.diff and args.src, "--diff and --src are required")
end

local function normalize(path)
    path = path:gsub("^@", ""):gsub("^%./", "")
    for _, m in ipairs(args.maps) do
        if path:sub(1, #m[1]) == m[1] then
            path = m[2] .. path:sub(#m[1] + 1)
        end
    end
    return path
end

-- Load & merge luacov stats ("max:filename\nhits hits …\n").
local hits = {}
for _, file in ipairs(args.stats) do
    local f = io.open(file, "r")
    if f then
        while true do
            local header = f:read("*l")
            if not header then break end
            local name = header:match("^%d+:(.*)$")
            local counts = f:read("*l") or ""
            if name then
                name = normalize(name)
                local t = hits[name] or {}
                hits[name] = t
                local n = 0
                for c in counts:gmatch("%d+") do
                    n = n + 1
                    t[n] = (t[n] or 0) + tonumber(c)
                end
            end
        end
        f:close()
    else
        io.stderr:write("warning: cannot read stats file ", file, "\n")
    end
end

-- Parse the diff: changed (added or modified) lines per file.
local changed = {}
local order = {}
do
    local cur
    for line in io.lines(args.diff) do
        local path = line:match("^%+%+%+ b/(.*)$")
        if path then
            cur = nil
            if path:match("%.lua$") then
                local keep = #args.includes == 0
                for _, pat in ipairs(args.includes) do
                    if path:match(pat) then keep = true end
                end
                if keep then
                    cur = {}
                    changed[path] = cur
                    table.insert(order, path)
                end
            end
        elseif line:match("^%+%+%+ /dev/null") then
            cur = nil
        elseif cur then
            local start, count = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
            if start then
                start = tonumber(start)
                count = count == "" and 1 or tonumber(count)
                for l = start, start + count - 1 do
                    cur[l] = true
                end
            end
        end
    end
end

-- Classify the changed lines, like luacov's reporter does.
local report = { files = {}, total = 0, covered = 0 }
for _, path in ipairs(order) do
    local lines = changed[path]
    local f = io.open(args.src .. "/" .. path, "r")
    if f then
        local scanner = LineScanner:new()
        local file_hits = hits[path] or {}
        local entry = { path = path, total = 0, covered = 0, missed = {}, loaded = hits[path] ~= nil }
        local n = 0
        for line in f:lines() do
            n = n + 1
            local always_excluded, excluded_when_not_hit = scanner:consume(line)
            if lines[n] then
                local h = file_hits[n] or 0
                local executable = not always_excluded and not (excluded_when_not_hit and h == 0)
                if executable then
                    entry.total = entry.total + 1
                    if h > 0 then
                        entry.covered = entry.covered + 1
                    else
                        table.insert(entry.missed, n)
                    end
                end
            end
        end
        f:close()
        if entry.total > 0 then
            table.insert(report.files, entry)
            report.total = report.total + entry.total
            report.covered = report.covered + entry.covered
        end
    end
end
report.percent = report.total > 0 and (100 * report.covered / report.total) or 100
report.threshold = args.threshold
report.ok = report.total == 0 or report.percent >= args.threshold

-- Ranges "1-3, 7" from a sorted list of line numbers.
local function ranges(list)
    local out, i = {}, 1
    while i <= #list do
        local j = i
        while j < #list and list[j + 1] == list[j] + 1 do j = j + 1 end
        table.insert(out, i == j and tostring(list[i]) or (list[i] .. "-" .. list[j]))
        i = j + 1
    end
    return table.concat(out, ", ")
end

local md = {}
local function w(s) table.insert(md, s) end
w("<!-- fork-diff-coverage -->")
w("## Diff coverage (unit + emulator integration tests)")
w("")
if report.total == 0 then
    w("No changed executable Lua line: nothing to cover. ✅")
else
    w(string.format("**%.1f%%** of the changed executable Lua lines are covered (%d / %d); minimum: %d%%. %s",
        report.percent, report.covered, report.total, args.threshold, report.ok and "✅" or "❌"))
    w("")
    w("| File | Covered | Changed lines not run by any test |")
    w("|---|---:|---|")
    for _, e in ipairs(report.files) do
        w(string.format("| `%s` | %d / %d (%.0f%%) | %s |", e.path, e.covered, e.total, 100 * e.covered / e.total,
            #e.missed > 0 and (ranges(e.missed) .. (e.loaded and "" or " (file never loaded)")) or "–"))
    end
end
local text = table.concat(md, "\n") .. "\n"
io.write(text)
if args.md then
    local f = assert(io.open(args.md, "w"))
    f:write(text)
    f:close()
end
if args.json then
    local f = assert(io.open(args.json, "w"))
    f:write(string.format('{"total": %d, "covered": %d, "percent": %.2f, "threshold": %d, "ok": %s}\n',
        report.total, report.covered, report.percent, args.threshold, tostring(report.ok)))
    f:close()
end
os.exit(report.ok and 0 or 1)
