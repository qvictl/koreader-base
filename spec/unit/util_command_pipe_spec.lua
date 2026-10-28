local ffi = require("ffi")
local util = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local C = ffi.C


local function collect(pid, fd)
    local chunks, eof, done = {}, false, false
    local pfd = ffi.new("struct pollfd[1]")
    pfd[0].fd, pfd[0].events = fd, C.POLLIN
    for _ = 1, 500 do
        if not eof then
            local chunk, finished, _, err = util.readAvailableFromFD(fd)
            assert.is_nil(err)
            chunks[#chunks + 1] = chunk
            eof = finished
        end
        done = done or util.isSubProcessDone(pid)
        if eof and done then C.close(fd); return table.concat(chunks) end
        C.poll(eof and nil or pfd, eof and 0 or 1, 10)
    end
    error("command did not finish before the bounded test deadline")
end

describe("util.openCommandPipe", function()
    setup(function()
        local runner = package.loaded["luacov.runner"]
        if not (runner and runner.initialized) then return end
        local source = debug.getinfo(util.openCommandPipe, "S").source
        local exits, n = {}, 0
        for line in io.lines(source:sub(2)) do
            n = n + 1
            if line:find("C.execl(", 1, true) or line:find("C._exit(", 1, true) then exits[n] = true end
        end
        local statsfile = runner.configuration.statsfile
        util.addRunInSubProcessAfterForkFunc("spec_command_coverage", function()
            -- Forked children must not attribute inherited parent hits to exec.
            for _, file in pairs(runner.data) do
                for line in pairs(file) do
                    if type(line) == "number" then file[line] = nil end
                end
            end
            runner.configuration.statsfile = statsfile .. ".command-" .. C.getpid()
            local hook = runner.debug_hook
            debug.sethook(function(event, line)
                hook(event, line, 3)
                if exits[line] and debug.getinfo(2, "S").source == source then pcall(runner.save_stats) end
            end, "l")
        end)
    end)
    teardown(function()
        util.removeRunInSubProcessAfterForkFunc("spec_command_coverage")
    end)
    local pids, fds, gates, original_run, original_android
    before_each(function()
        pids, fds, gates = {}, {}, {}
        original_run, original_android = util.runInSubProcess, util.isAndroid
    end)
    after_each(function()
        util.runInSubProcess, util.isAndroid = original_run, original_android
        for _, gate in ipairs(gates) do
            C.write(gate[1], "go\n", 3)
            C.close(gate[1]); C.close(gate[0])
        end
        for _, pid in ipairs(pids) do
            util.terminateSubProcess(pid)
            util.isSubProcessDone(pid, true)
        end
        for _, fd in ipairs(fds) do C.close(fd) end
    end)
    local function start(command)
        local pid, fd = util.openCommandPipe(command)
        assert.is_number(pid)
        assert.is_number(fd)
        pids[#pids + 1], fds[#fds + 1] = pid, fd
        return pid, fd
    end
    local function gate()
        local pipe = ffi.new("int[2]")
        assert.are.equal(0, C.pipe(pipe))
        gates[#gates + 1] = pipe
        util.runInSubProcess = function(func, with_pipe)
            return original_run(function(pid, fd)
                assert(C.dup2(pipe[0], 0) == 0)
                C.close(pipe[1])
                if pipe[0] ~= 0 then C.close(pipe[0]) end
                func(pid, fd)
            end, with_pipe)
        end
        return pipe
    end

    it("execs the shell as the returned pid and preserves shell syntax", function()
        local pid, fd = start("value=hello; printf '%s:%s' \"$$\" \"$value\"")
        assert.are.equal(tostring(pid) .. ":hello", collect(pid, fd))
    end)

    it("completes without any stdout even on a nonzero exit", function()
        local pid, fd = start("exit 7")
        assert.are.equal("", collect(pid, fd))
    end)

    it("distinguishes stdout EOF from a shell that has not exited", function()
        local ipc = gate()
        local pid, fd = start("exec 1>&-; read ready")
        local pfd = ffi.new("struct pollfd[1]")
        pfd[0].fd, pfd[0].events = fd, C.POLLIN
        assert.is_true(C.poll(pfd, 1, 2000) > 0)
        local chunk, eof, _, err = util.readAvailableFromFD(fd)
        assert.is_nil(err)
        assert.are.equal("", chunk)
        assert.is_true(eof)
        assert.is_false(util.isSubProcessDone(pid))
        assert.are.equal(3, C.write(ipc[1], "go\n", 3))
        assert.are.equal("", collect(pid, fd))
    end)

    it("survives actual closed standard streams in an isolated worker", function()
        local pid, fd = original_run(function(_, output_fd)
            C.close(0); C.close(1)
            util.runInSubProcess = function(func, with_pipe)
                return original_run(function(child_pid, writer)
                    assert(writer == 1, "the test must allocate stdout as the pipe writer")
                    func(child_pid, writer)
                end, with_pipe)
            end
            local shell_pid, reader = util.openCommandPipe("printf closed-stdout")
            assert(shell_pid)
            local output = collect(shell_pid, reader)
            assert(util.writeToFD(output_fd, output, true))
        end, true)
        assert.is_number(pid)
        pids[#pids + 1], fds[#fds + 1] = pid, fd
        assert.are.equal("closed-stdout", collect(pid, fd))
    end)

    it("keeps stdout open when the writer is descriptor one", function()
        util.runInSubProcess = function(func, with_pipe)
            return original_run(function(pid, fd)
                assert(C.dup2(fd, 1) == 1)
                if fd ~= 1 then C.close(fd) end
                assert(C.fcntl(1, C.F_SETFD, ffi.cast("int", C.FD_CLOEXEC)) == 0)
                func(pid, 1)
            end, with_pipe)
        end
        local pid, fd = start("printf descriptor-one")
        assert.are.equal("descriptor-one", collect(pid, fd))
    end)

    it("exits on redirection failure instead of escaping into Lua", function()
        util.runInSubProcess = function(func, with_pipe)
            return original_run(function(pid) func(pid, -1) end, with_pipe)
        end
        local pid, fd = start("printf must-not-run")
        local status = ffi.new("int[1]")
        assert.are.equal(pid, C.waitpid(pid, status, 0))
        assert.are.equal(127, bit.rshift(tonumber(status[0]), 8))
        assert.are.equal("", collect(pid, fd))
    end)

    if not lfs.attributes("/system/bin/sh") then
        it("exits with 127 when the selected shell cannot be executed", function()
            util.isAndroid = function() return true end
            local pid, fd = start("printf must-not-run")
            local status = ffi.new("int[1]")
            assert.are.equal(pid, C.waitpid(pid, status, 0))
            assert.are.equal(127, bit.rshift(tonumber(status[0]), 8))
            assert.are.equal("", collect(pid, fd))
        end)
    end

    it("forwards a spawn failure without inventing a descriptor", function()
        util.runInSubProcess = function() return false, "expected fork failure" end
        local pid, err = util.openCommandPipe("printf ignored")
        assert.is_false(pid)
        assert.are.equal("expected fork failure", err)
    end)
end)
