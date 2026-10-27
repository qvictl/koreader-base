local util = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local function waitForSubProcessDone(pid)
    for i = 1, 40 do -- 1 second
        util.usleep(25000)
        if util.isSubProcessDone(pid) then
            return true
        end
    end
    return false
end

-- Waits for a subprocess to exit, returns its exit status (or nil on timeout, after killing it).
local function waitForExitStatus(pid)
    local ffi = require("ffi")
    local C = ffi.C
    local status = ffi.new("int[1]")
    for i = 1, 200 do -- 5 seconds
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

local function waitForData(fd_or_luafile)
    local available = 0
    for i = 1, 40 do -- 1 second
        util.usleep(25000)
        available = util.getNonBlockingReadSize(fd_or_luafile) or 0
        if available ~= 0 then
            return available
        end
    end
    return available
end

describe("util module", function()
    describe("util.gettime", function()

        it("should return sec and usec", function()
            local sec, usec = util.gettime()
            assert.are_not.equal(sec, nil)
            assert.are_not.equal(usec, nil)
        end)

    end)

    describe("util.template", function()

        it("should not affect string without arguments", function()
            local str_regular = ("just a string")
            local str_template = util.template(
                ("just a string")
            )
            assert.are.equal(str_regular, str_template)

            local str_regular_marker = ("just a string %1")
            local str_template_marker = util.template(
                ("just a string %1")
            )
            assert.are.equal(str_regular_marker, str_template_marker)
        end)

        it("should not replace %0", function()
            local str_regular = ("The argument goes %0.")
            local str_template = util.template(
                ("The argument goes %0."),
                "argument"
            )
            assert.are.equal(str_regular, str_template)
        end)

        it("should replace place markers with arguments", function()
            local str_regular = ("The arguments go here and there.")
            local str_template = util.template(
                ("The arguments go %1 and %2."),
                "here",
                "there"
            )
            assert.are.equal(str_regular, str_template)
        end)

        it("should allow dynamic positioning of place markers", function()
            local str_regular = ("The arguments go there and here.")
            local str_template = util.template(
                ("The arguments go %2 and %1."),
                "here",
                "there"
            )
            assert.are.equal(str_regular, str_template)
        end)

        it("should replace place markers no matter how many times they appear", function()
            local str_regular = ("bark bark bark bark")
            local str_template = util.template(
                ("%1 %1 %1 %1"),
                "bark"
            )
            assert.are.equal(str_regular, str_template)
        end)

        it("should treat %10 as %10, not %1", function()
            local str_regular = ("First: success1; tenth: success10.")
            local str_template = util.template(
                ("First: %1; tenth: %10."),
                "success1",
                "success2",
                "success3",
                "success4",
                "success5",
                "success6",
                "success7",
                "success8",
                "success9",
                "success10"
            )
            assert.are.equal(str_regular, str_template)
        end)

        it("should treat %100 as %10", function()
            local str_regular = ("First: success1-; tenth: success10-; hundredth: success10-0.")
            local template_args = {}
            for i=1,100,1 do
                template_args[i] = "success" .. i .. "-"
            end
            local str_template = util.template(
                ("First: %1; tenth: %10; hundredth: %100."),
                unpack(template_args)
            )
            assert.are.equal(str_regular, str_template)
        end)

        it("should not allow escaping", function()
            local str_regular = ("This %argument tried to escape.")
            local str_template = util.template(
                ("This %%1 tried to escape."),
                "argument"
            )
            assert.are.equal(str_regular, str_template)
        end)

    end)

    describe("util.copyFile", function()
        local sample_pdf = "spec/base/unit/data/simple.pdf"

        it("should copy properly", function()
            local tmp_f = os.tmpname()
            local from_f = io.open(sample_pdf, "r")
            local from_data = from_f:read("*a")
            util.copyFile(sample_pdf, tmp_f)
            local to_f = io.open(tmp_f, "r")
            local to_data = to_f:read("*a")
            assert.equals(from_data, to_data)
            from_f:close()
            to_f:close()
            os.remove(tmp_f)
        end)

        it("fail at non-exists files", function()
            local tmp_f = os.tmpname()
            local err = util.copyFile("/tmp/abc/123/foo/bar/baz/777.pkg", tmp_f)
            assert.is_not_nil(err)
            os.remove(tmp_f)
        end)
    end)

    describe("util.joinPath", function()
        it("should join path properly", function()
            assert.equals(util.joinPath("/abc/123", "foo"), "/abc/123/foo")
            assert.equals(util.joinPath("/abc/123/", "bar"), "/abc/123/bar")
            assert.equals(util.joinPath("/123/", "/bar"), "/bar")
            assert.equals(util.joinPath("/tmp", "bar.pdf"), "/tmp/bar.pdf")
        end)
    end)

    describe("util.df", function()
        it("should report a filesystem's size, free and available space", function()
            local total, free, available = util.df(".")
            assert.is_number(total)
            assert.is_true(total > 0)
            -- Free space cannot exceed the filesystem, and what is available to
            -- an unprivileged user cannot exceed what is free.
            assert.is_true(free <= total)
            assert.is_true(available <= free)
        end)

        it("should error out on a non-existent path", function()
            local ok, err = util.df("/tmp/123/abc/567/foobar")
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)
    end)

    describe("util.purgeDir", function()
        it("should error out on non-exists directory", function()
            local ok, err = util.purgeDir('/tmp/123/abc/567/foobar')
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)

        it("should delete non-empty directory", function()
            local tmp_dir = "spec/base/unit/data/test_purge_dir"
            local tmp_subdir = util.joinPath(tmp_dir, "morestuff")
            lfs.mkdir(tmp_dir)
            lfs.mkdir(tmp_subdir)
            assert.equals(lfs.attributes(tmp_dir).mode, "directory")
            assert.equals(lfs.attributes(tmp_subdir).mode, "directory")
            util.purgeDir(tmp_dir)
            local _, err = lfs.attributes(tmp_dir)
            assert.is_not_nil(err)
            _, err = lfs.attributes(tmp_subdir)
            assert.is_not_nil(err)
        end)
    end)

    describe("util.getNonBlockingReadSize", function()
        it("should read pipe when data is available", function()
            local std_out = io.popen("sleep 0.1; echo 'done'; sleep 0.1", "r")
            assert.are.equal(0, util.getNonBlockingReadSize(std_out))
            assert.are.equal(5, waitForData(std_out))
            local startsec = util.gettime()
            local data = std_out:read("*all")
            local donesec = util.gettime()
            assert.are.equal("done\n", data)
            assert.is_true(donesec - startsec <= 1)
        end)
    end)

    describe("util.runInSubProcess and related", function()
        setup(function()
            -- Coverage runs: subprocesses end with _exit(), skipping luacov's exit handler.
            -- Have them save their stats (to their own file) when their function is done.
            local runner = package.loaded["luacov.runner"]
            if runner and runner.initialized then
                local ffi = require("ffi")
                util.addRunInSubProcessAfterForkFunc("spec_luacov_child", function()
                    runner.configuration.statsfile = runner.configuration.statsfile .. ".child-" .. ffi.C.getpid()
                    runner.data = {}
                    local function save() pcall(runner.save_stats) end
                    local raw_create = coroutine.create
                    coroutine.create = function(f) -- luacheck: ignore 122
                        coroutine.create = raw_create -- luacheck: ignore 122
                        return raw_create(function(...)
                            local res = { pcall(f, ...) }
                            save()
                            if not res[1] then error(res[2], 0) end
                            return unpack(res, 2)
                        end)
                    end
                    local raw_print = print
                    print = function(...) -- luacheck: ignore 121
                        save()
                        return raw_print(...)
                    end
                end)
            end
        end)
        teardown(function()
            util.removeRunInSubProcessAfterForkFunc("spec_luacov_child")
        end)
        it("should run usleep 100000 in subprocess", function()
            local var = "var_set_in_parent"
            local pid = util.runInSubProcess(function()
              var = "var_overriden_in_child"
              util.usleep(100000)
            end)
            assert.is_true(pid ~= 0)
            assert.is_false(util.isSubProcessDone(pid))
            assert.is_true(waitForSubProcessDone(pid))
            assert.is.same(var, "var_set_in_parent")
        end)
        it("should write a file in subprocess", function()
            local tmp_f = os.tmpname()
            local pid = util.runInSubProcess(function()
                local f = io.open(tmp_f, "w")
                if f then
                    f:write("test1")
                    f:close()
                end
            end)
            assert.is_true(pid ~= 0)
            assert.is_true(waitForSubProcessDone(pid))
            local f = io.open(tmp_f)
            assert.is_not_nil(f)
            local data = f:read("*all")
            f:close()
            assert.is.same(data, "test1")
            os.remove(tmp_f)
        end)
        it("should not modify a file in subprocess as we kill it before", function()
            local tmp_f = os.tmpname()
            local f
            f = io.open(tmp_f, "w")
            if f then
                f:write("test1")
                f:close()
            end
            local pid = util.runInSubProcess(function()
                util.sleep(2)
                f = io.open(tmp_f, "w")
                if f then
                    f:write("test2")
                    f:close()
                end
            end)
            assert.is_true(pid ~= 0)
            assert.is_false(util.isSubProcessDone(pid))
            util.usleep(100000)
            util.terminateSubProcess(pid)
            assert.is_true(waitForSubProcessDone(pid))
            f = io.open(tmp_f)
            assert.is_not_nil(f)
            local data = f:read("*all")
            f:close()
            assert.is.same(data, "test1")
            os.remove(tmp_f)
        end)
        it("should exit with status 0 when the function succeeds", function()
            local pid = util.runInSubProcess(function() end)
            assert.is_true(pid ~= 0)
            assert.are.equal(0, waitForExitStatus(pid))
        end)
        it("should exit with status 1 when the function errors", function()
            local pid = util.runInSubProcess(function()
                error("expected error in subprocess")
            end)
            assert.is_true(pid ~= 0)
            assert.are.equal(1, waitForExitStatus(pid))
        end)
        it("should contain a function that yields (called from a coroutine)", function()
            local ffi = require("ffi")
            local parent_pid = ffi.C.getpid()
            local marker = os.tmpname()
            os.remove(marker)
            local co = coroutine.create(function()
                return util.runInSubProcess(function()
                    coroutine.yield("escaped")
                end)
            end)
            local ok, pid = coroutine.resume(co)
            if ffi.C.getpid() ~= parent_pid then
                -- We are the child, and the yield escaped from runInSubProcess.
                local f = io.open(marker, "w")
                if f then f:write("escaped") f:close() end
                ffi.C._exit(3)
            end
            assert.is_true(ok)
            assert.is.number(pid)
            assert.are.equal(1, waitForExitStatus(pid))
            assert.is_nil(io.open(marker, "r"))
        end)
        it("should support bidirectional pipes", function()
            local pid, read_fd, write_fd = util.runInSubProcess(function(_, child_write_fd, child_read_fd)
                local got = util.readAllFromFD(child_read_fd)
                util.writeToFD(child_write_fd, "echo:" .. got, true)
            end, "bidi")
            assert.is.number(pid)
            assert.truthy(read_fd)
            assert.truthy(write_fd)
            util.writeToFD(write_fd, "ping", true)
            assert.are.equal("echo:ping", util.readAllFromFD(read_fd))
            assert.are.equal(0, waitForExitStatus(pid))
        end)
        it("should double fork", function()
            local marker = os.tmpname()
            local pid = util.runInSubProcess(function()
                local f = io.open(marker, "w")
                if f then f:write("ran") f:close() end
            end, false, true)
            assert.is.number(pid)
            -- The intermediate process is already reaped, there's no process group to kill.
            util.terminateSubProcess(pid)
            assert.is_true(util.isSubProcessDone(pid))
            local data
            for i = 1, 40 do
                local f = io.open(marker)
                data = f and f:read("*a")
                if f then f:close() end
                if data == "ran" then break end
                util.usleep(25000)
            end
            assert.are.equal("ran", data)
            os.remove(marker)
        end)
        it("should report pipe creation failures without leaking fds", function()
            local ffi = require("ffi")
            local C = ffi.C
            pcall(ffi.cdef, [[
                struct spec_rlimit { unsigned long cur, max; };
                int getrlimit(int, struct spec_rlimit *);
                int setrlimit(int, const struct spec_rlimit *);
            ]])
            local RLIMIT_NOFILE = 7
            local function fds()
                local t = {}
                for f in lfs.dir("/proc/self/fd") do
                    if tonumber(f) then table.insert(t, tonumber(f)) end
                end
                return t
            end
            -- Fill the gaps in fd numbers, so that the limit means "N more fds".
            local highest = math.max(unpack(fds()))
            local fillers = {}
            while true do
                local fd = C.open("/dev/null", 0)
                if fd < 0 or fd > highest then
                    if fd >= 0 then C.close(fd) end
                    break
                end
                table.insert(fillers, fd)
            end
            local lim = ffi.new("struct spec_rlimit")
            C.getrlimit(RLIMIT_NOFILE, lim)
            local saved = lim.cur
            local results = {}
            for _, extra in ipairs({ 0, 2 }) do
                local before = #fds()
                lim.cur = highest + 1 + extra
                C.setrlimit(RLIMIT_NOFILE, lim)
                local ok, err = util.runInSubProcess(function() end, "bidi")
                lim.cur = saved
                C.setrlimit(RLIMIT_NOFILE, lim)
                results[extra] = { ok = ok, err = err, leaked = #fds() - before }
            end
            for _, fd in ipairs(fillers) do C.close(fd) end
            for _, r in pairs(results) do
                assert.is_false(r.ok)
                assert.truthy(tostring(r.err):find("failed creating pipe", 1, true))
                assert.are.equal(0, r.leaked)
            end
        end)
        it("should terminate a subprocess and its children", function()
            local pid = util.runInSubProcess(function()
                os.execute("sleep 10")
            end)
            assert.is.number(pid)
            util.usleep(100000)
            util.terminateSubProcess(pid)
            assert.is_true(waitForSubProcessDone(pid))
        end)
        it("should read data from subprocess via pipe", function()
            local pid, parent_fd = util.runInSubProcess(function(pid, child_fd)
                util.writeToFD(child_fd, "test3", true)
            end, true)
            assert.is_true(pid ~= 0)
            assert.truthy(parent_fd)
            local data = util.readAllFromFD(parent_fd, true)
            assert.is.same(data, "test3")
            assert.is_true(waitForSubProcessDone(pid))
        end)
    end)

end)
