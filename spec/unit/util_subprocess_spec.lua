-- Failure paths of util.runInSubProcess & co: they back every background task of the
-- frontend (Trapper:dismissableRunInSubprocess, cover/metadata extraction...), and a
-- subprocess that does not exit, leaks fds or cannot be killed freezes a Kindle.
local ffi = require("ffi")
local util = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local C = ffi.C

pcall(ffi.cdef, [[
    struct spec_rlimit { unsigned long cur, max; };
    int getrlimit(int, struct spec_rlimit *);
    int setrlimit(int, const struct spec_rlimit *);
]])
pcall(ffi.cdef, [[
    typedef void (*spec_sighandler_t)(int);
    spec_sighandler_t signal(int, spec_sighandler_t);
]])
pcall(ffi.cdef, "int getpgrp(void);")
pcall(ffi.cdef, "int getpgid(int);")

local RLIMIT_NPROC = 6
local SIGCHLD = 17

local function openFds()
    local n = 0
    for f in lfs.dir("/proc/self/fd") do
        if tonumber(f) then n = n + 1 end
    end
    return n
end

-- Waits for a subprocess to exit, returns its exit status (or nil on timeout, after killing it).
local function waitForExitStatus(pid)
    local status = ffi.new("int[1]")
    for _ = 1, 200 do -- 5 seconds
        if C.waitpid(pid, status, C.WNOHANG) == pid then
            local st = tonumber(status[0])
            if bit.band(st, 0x7f) == 0 then
                return bit.band(bit.rshift(st, 8), 0xff)
            end
            return 128 + bit.band(st, 0x7f)
        end
        util.usleep(25000)
    end
    C.kill(pid, 9)
    C.waitpid(pid, status, 0)
end

local function waitForSubProcessDone(pid)
    for _ = 1, 200 do -- 5 seconds
        if util.isSubProcessDone(pid) then
            return true
        end
        util.usleep(25000)
    end
    return false
end

-- Coverage runs: subprocesses end with _exit(), which skips luacov's exit handler, so
-- have them save their own stats (to their own file), right before util.lua's _exit()
-- calls. Only the lines run in the child are saved (the parent saves its own).
local function setupChildCoverage()
    local runner = package.loaded["luacov.runner"]
    if not (runner and runner.initialized) then return end
    local statsfile = runner.configuration.statsfile
    local source = debug.getinfo(util.runInSubProcess, "S").source
    local exit_lines = {}
    local n = 0
    for line in io.lines(source:sub(2)) do
        n = n + 1
        if line:find("C._exit(", 1, true) then exit_lines[n] = true end
    end
    local function copy(data)
        local t = {}
        for name, file in pairs(data) do
            local f = {}
            for k, v in pairs(file) do f[k] = v end
            t[name] = f
        end
        return t
    end
    local parent_data
    util.addRunBeforeForkFunc("spec_cov_snapshot", function()
        parent_data = copy(runner.data)
    end)
    util.addRunInSubProcessAfterForkFunc("spec_cov_child", function()
        local inherited = parent_data
        local function save()
            if inherited then
                for name, file in pairs(runner.data) do
                    local base = inherited[name]
                    if base then
                        for k, v in pairs(file) do
                            if type(k) == "number" then
                                file[k] = v > (base[k] or 0) and v - (base[k] or 0) or nil
                            end
                        end
                    end
                end
                inherited = nil
            end
            runner.configuration.statsfile = statsfile .. ".child-" .. C.getpid()
            pcall(runner.save_stats)
        end
        local hook = runner.debug_hook
        debug.sethook(function(event, line)
            hook(event, line, 3)
            if exit_lines[line] and debug.getinfo(2, "S").source == source then
                save()
            end
        end, "l")
    end)
end

describe("util.runInSubProcess failure paths", function()
    setup(function()
        setupChildCoverage()
    end)

    teardown(function()
        util.removeRunBeforeForkFunc("spec_cov_snapshot")
        util.removeRunInSubProcessAfterForkFunc("spec_cov_child")
    end)

    it("should run the fork hooks in the right processes, in order", function()
        local parent_pid = C.getpid()
        local events = {}
        local in_child = false
        util.addRunBeforeForkFunc("spec_before", function()
            table.insert(events, "before:" .. (C.getpid() == parent_pid and "parent" or "child"))
        end)
        util.addRunAfterForkParentFunc("spec_after", function()
            table.insert(events, "after:" .. (C.getpid() == parent_pid and "parent" or "child"))
        end)
        util.addRunInSubProcessAfterForkFunc("spec_child", function()
            in_child = C.getpid() ~= parent_pid
        end)
        local pid, read_fd = util.runInSubProcess(function(_, write_fd)
            util.writeToFD(write_fd, in_child and "child hook ran" or "child hook missing", true)
        end, true)
        util.removeRunBeforeForkFunc("spec_before")
        util.removeRunAfterForkParentFunc("spec_after")
        util.removeRunInSubProcessAfterForkFunc("spec_child")
        assert.is.number(pid)
        assert.are.same({ "before:parent", "after:parent" }, events)
        -- The child-side hook ran in the child only.
        assert.is_false(in_child)
        assert.are.equal("child hook ran", util.readAllFromFD(read_fd))
        assert.are.equal(0, waitForExitStatus(pid))
        -- Removed hooks are not run anymore.
        pid = util.runInSubProcess(function() end)
        assert.are.equal(0, waitForExitStatus(pid))
        assert.are.same({ "before:parent", "after:parent" }, events)
    end)

    it("should exit with status 1 and report the error when the function errors", function()
        local pid, read_fd = util.runInSubProcess(function(_, write_fd)
            util.writeToFD(write_fd, "started", true)
            error("boom in subprocess")
        end, true)
        assert.is.number(pid)
        assert.are.equal("started", util.readAllFromFD(read_fd))
        assert.are.equal(1, waitForExitStatus(pid))
    end)

    it("should exit with status 1 (not run the parent's code) when the function yields", function()
        local parent_pid = C.getpid()
        local pid = util.runInSubProcess(function()
            coroutine.yield("escaped")
        end)
        -- If the yield escaped, the child would be running this code too.
        assert.are.equal(parent_pid, C.getpid())
        assert.are.equal(1, waitForExitStatus(pid))
    end)

    it("should fail cleanly when fork() fails, still running the after-fork hooks, and leak no fd", function()
        if C.getuid() == 0 then
            pending("root ignores RLIMIT_NPROC: cannot make fork() fail")
            return
        end
        local lim = ffi.new("struct spec_rlimit")
        assert.are.equal(0, C.getrlimit(RLIMIT_NPROC, lim))
        local saved = lim.cur
        local before, after = 0, 0
        util.addRunBeforeForkFunc("spec_before", function() before = before + 1 end)
        util.addRunAfterForkParentFunc("spec_after", function() after = after + 1 end)
        local fds = openFds()
        lim.cur = 0
        C.setrlimit(RLIMIT_NPROC, lim)
        local ok, err = util.runInSubProcess(function() end, "bidi")
        lim.cur = saved
        C.setrlimit(RLIMIT_NPROC, lim)
        util.removeRunBeforeForkFunc("spec_before")
        util.removeRunAfterForkParentFunc("spec_after")
        assert.is_false(ok)
        assert.truthy(tostring(err):find("^fork failed: "))
        -- The subsystems stopped before fork() must be restarted even on failure.
        assert.are.equal(1, before)
        assert.are.equal(1, after)
        -- The 4 pipe ends were closed.
        assert.are.equal(fds, openFds())
    end)

    it("should fail cleanly when the intermediate process of a double fork cannot be reaped", function()
        -- With SIGCHLD ignored, children are reaped automatically, and waitpid() fails (ECHILD).
        local marker = os.tmpname()
        local old = C.signal(SIGCHLD, ffi.cast("spec_sighandler_t", 1)) -- SIG_IGN
        local fds = openFds()
        local ok, err = util.runInSubProcess(function()
            local f = io.open(marker, "w")
            if f then f:write("ran") f:close() end
        end, true, true)
        local fds_after = openFds()
        C.signal(SIGCHLD, old)
        assert.is_false(ok)
        assert.truthy(tostring(err):find("^double fork failed: "))
        -- The pipe was closed.
        assert.are.equal(fds, fds_after)
        -- The grandchild still ran.
        local data
        for _ = 1, 40 do
            local f = io.open(marker)
            data = f and f:read("*a")
            if f then f:close() end
            if data == "ran" then break end
            util.usleep(25000)
        end
        os.remove(marker)
        assert.are.equal("ran", data)
    end)

    it("should pass the pipe written by a double forked grandchild", function()
        local pid, read_fd = util.runInSubProcess(function(child_pid, write_fd)
            util.writeToFD(write_fd, tostring(child_pid) .. ":" .. tostring(C.getpid()), true)
        end, true, true)
        assert.is.number(pid)
        -- The intermediate process is already reaped.
        assert.is_true(util.isSubProcessDone(pid))
        local data = util.readAllFromFD(read_fd)
        local child_pid, own_pid = data:match("^(%d+):(%d+)$")
        assert.truthy(child_pid)
        -- func gets its own pid, which is not the (reaped) intermediate one.
        assert.are.equal(own_pid, child_pid)
        assert.are_not.equal(tostring(pid), child_pid)
    end)
end)

describe("util.terminateSubProcess", function()
    it("should kill a subprocess that left its own process group", function()
        local parent_pgrp = C.getpgrp()
        local pid, read_fd, write_fd = util.runInSubProcess(function(_, child_write_fd, child_read_fd)
            -- Wait for the parent to be done with its setpgid(pid, pid)...
            local buf = ffi.new("char[1]")
            C.read(child_read_fd, buf, 1)
            -- ... then join the parent's process group, so that kill(-pid) fails.
            C.setpgid(0, parent_pgrp)
            util.writeToFD(child_write_fd, C.getpgid(0) == parent_pgrp and "moved" or "stuck", true)
            util.sleep(10)
        end, "bidi")
        assert.is.number(pid)
        util.writeToFD(write_fd, "g", true)
        assert.are.equal("moved", util.readAllFromFD(read_fd))
        assert.are_not.equal(pid, C.getpgid(pid))
        util.terminateSubProcess(pid)
        assert.is_true(waitForSubProcessDone(pid))
    end)

    it("should be a no-op for a subprocess that is already done", function()
        local pid = util.runInSubProcess(function() end)
        assert.is_true(waitForSubProcessDone(pid))
        assert.has_no.errors(function() util.terminateSubProcess(pid) end)
        assert.is_true(util.isSubProcessDone(pid))
    end)
end)

describe("util.isSubProcessDone", function()
    it("should block until the subprocess exits when asked to wait", function()
        local pid = util.runInSubProcess(function() util.usleep(100000) end)
        assert.is_false(util.isSubProcessDone(pid))
        assert.is_true(util.isSubProcessDone(pid, true))
        -- Already collected: waitpid() fails with ECHILD, which still means done.
        assert.is_true(util.isSubProcessDone(pid))
    end)
end)

describe("util.readAllFromFD", function()
    it("should read data larger than its chunk size", function()
        local big = string.rep("0123456789abcdef", 4096) -- 64 KiB, more than a pipe buffer too
        local pid, read_fd = util.runInSubProcess(function(_, write_fd)
            util.writeToFD(write_fd, big, true)
        end, true)
        local data = util.readAllFromFD(read_fd)
        assert.are.equal(#big, #data)
        assert.are.equal(big, data)
        assert.are.equal(0, waitForExitStatus(pid))
    end)

    it("should return an empty string when the writer exits without writing", function()
        local pid, read_fd = util.runInSubProcess(function() end, true)
        assert.are.equal("", util.readAllFromFD(read_fd))
        assert.are.equal(0, waitForExitStatus(pid))
    end)

    it("should stop on a read error (instead of looping) and close the fd", function()
        local pipe = ffi.new("int[2]")
        assert.are.equal(0, C.pipe(pipe))
        -- Reading the write end of a pipe fails with EBADF.
        assert.are.equal("", util.readAllFromFD(pipe[1]))
        -- It was closed.
        assert.are.equal(-1, C.close(pipe[1]))
        C.close(pipe[0])
    end)
end)
