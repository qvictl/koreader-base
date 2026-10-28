local ffi = require("ffi")
local bit = require("bit")
local util = require("ffi/util")
local C = ffi.C

describe("subprocess result pipes", function()
    local fds, pids
    before_each(function() fds, pids = {}, {} end)
    after_each(function()
        for _, fd in ipairs(fds) do C.close(fd) end
        for _, pid in ipairs(pids) do
            util.terminateSubProcess(pid)
            util.isSubProcessDone(pid, true)
        end
    end)

    local function pipe()
        local pair = ffi.new("int[2]")
        assert.are.equal(0, C.pipe(pair))
        fds[#fds + 1], fds[#fds + 2] = pair[0], pair[1]
        return tonumber(pair[0]), tonumber(pair[1])
    end

    it("returns available bytes without waiting for a live writer or closing the reader", function()
        local reader, writer = pipe()
        assert.are.equal(6, C.write(writer, "prefix", 6))
        local original_flags = C.fcntl(reader, C.F_GETFL)
        local data, eof, drained = util.readAvailableFromFD(reader)
        assert.are.equal(original_flags, C.fcntl(reader, C.F_GETFL))
        assert.are.equal("prefix", data)
        assert.is_false(eof)
        assert.is_true(drained)
        data, eof, drained = util.readAvailableFromFD(reader)
        assert.are.equal("", data)
        assert.is_false(eof)
        assert.is_true(drained)
        assert.are.equal(0, C.close(writer))
        table.remove(fds)
        data, eof, drained = util.readAvailableFromFD(reader)
        assert.are.equal("", data)
        assert.is_true(eof)
        assert.is_true(drained)
        assert.is_true(C.fcntl(reader, C.F_GETFL) >= 0)
    end)

    it("preserves multi-megabyte results while yielding between reads", function()
        local payload = string.rep("result-data-", 200000)
        local pid, reader = util.runInSubProcess(function(_, writer)
            util.writeToFD(writer, payload, true)
        end, true)
        assert.is_truthy(pid)
        pids[#pids + 1], fds[#fds + 1] = pid, reader
        local chunks = {}
        local ready = ffi.new("struct pollfd[1]")
        ready[0].fd, ready[0].events = reader, C.POLLIN
        while true do
            local polled = C.poll(ready, 1, -1)
            assert.is_true(polled > 0 or ffi.errno() == C.EINTR)
            local done = util.isSubProcessDone(pid)
            local data, eof, drained = util.readAvailableFromFD(reader)
            assert.is_string(data)
            chunks[#chunks + 1] = data
            if eof or (done and drained) then break end
        end
        assert.are.equal(payload, table.concat(chunks))
    end)

    it("marks both directions close-on-exec without making worker writes nonblocking", function()
        local pid, reader, writer = util.runInSubProcess(function(_, child_writer, child_reader)
            local flags = {
                write_cloexec = bit.band(C.fcntl(child_writer, C.F_GETFD), C.FD_CLOEXEC),
                read_cloexec = bit.band(C.fcntl(child_reader, C.F_GETFD), C.FD_CLOEXEC),
                nonblock = bit.band(C.fcntl(child_writer, C.F_GETFL), C.O_NONBLOCK),
            }
            util.writeToFD(child_writer, table.concat({ flags.write_cloexec, flags.read_cloexec, flags.nonblock }, ":"), true)
        end, "bidi")
        assert.is_truthy(pid)
        pids[#pids + 1] = pid
        fds[#fds + 1], fds[#fds + 2] = reader, writer
        assert.are.equal(tonumber(C.FD_CLOEXEC), bit.band(C.fcntl(reader, C.F_GETFD), C.FD_CLOEXEC))
        assert.are.equal(tonumber(C.FD_CLOEXEC), bit.band(C.fcntl(writer, C.F_GETFD), C.FD_CLOEXEC))
        local result = util.readAllFromFD(reader)
        table.remove(fds, #fds - 1)
        assert.are.equal("1:1:0", result)
    end)

    local function withC(func, overrides, check)
        local index, original
        for i = 1, 30 do
            local name, value = debug.getupvalue(func, i)
            if name == "C" then index, original = i, value; break end
        end
        assert.is_number(index)
        debug.setupvalue(func, index, setmetatable(overrides, { __index = original }))
        local ok, err = xpcall(check, debug.traceback)
        debug.setupvalue(func, index, original)
        if not ok then error(err, 0) end
    end

    it("bounds a continuously readable pipe to one MiB per poll", function()
        local reads = 0
        withC(util.readAvailableFromFD, {
            fcntl = function() return tonumber(C.O_NONBLOCK) end,
            read = function(_, buf, size)
                reads = reads + 1
                ffi.fill(buf, size, 65)
                return size
            end,
        }, function()
            local data, eof, drained = util.readAvailableFromFD(123)
            assert.are.equal(1024 * 1024, #data)
            assert.are.equal(128, reads)
            assert.is_false(eof)
            assert.is_false(drained)
        end)
    end)

    it("retries interrupted reads and returns available data at EAGAIN", function()
        local reads = 0
        withC(util.readAvailableFromFD, {
            fcntl = function() return tonumber(C.O_NONBLOCK) end,
            read = function(_, buf)
                reads = reads + 1
                if reads == 1 then ffi.errno(C.EINTR); return -1 end
                if reads == 2 then ffi.copy(buf, "ok", 2); return 2 end
                ffi.errno(C.EAGAIN)
                return -1
            end,
        }, function()
            local data, eof, drained = util.readAvailableFromFD(123)
            assert.are.equal("ok", data)
            assert.is_false(eof)
            assert.is_true(drained)
        end)
    end)

    it("closes all pipe ends if close-on-exec setup fails before forking", function()
        local opened = {}
        withC(util.runInSubProcess, {
            pipe = function(pair)
                local result = C.pipe(pair)
                opened[#opened + 1], opened[#opened + 2] = pair[0], pair[1]
                return result
            end,
            fcntl = function() ffi.errno(C.EINVAL); return -1 end,
            fork = function() error("must not fork with unprotected pipe ends") end,
        }, function()
            local pid, err = util.runInSubProcess(function() end, "bidi")
            assert.is_false(pid)
            assert.is_truthy(err:find("close%-on%-exec"))
        end)
        assert.are.equal(4, #opened)
        for _, fd in ipairs(opened) do assert.are.equal(-1, C.fcntl(fd, C.F_GETFD)) end
    end)

    it("reports failure to restore the original descriptor flags", function()
        local sets = 0
        withC(util.readAvailableFromFD, {
            fcntl = function(_, cmd)
                if cmd == C.F_GETFL then return 0 end
                sets = sets + 1
                if sets == 1 then return 0 end
                ffi.errno(C.EINVAL)
                return -1
            end,
            read = function() return 0 end,
        }, function()
            local data, eof, drained, err = util.readAvailableFromFD(123)
            assert.is_nil(data)
            assert.is_false(eof)
            assert.is_false(drained)
            assert.is_string(err)
            assert.are.equal(2, sets)
        end)
    end)

    it("reports an invalid descriptor without claiming EOF", function()
        local data, eof, drained, err = util.readAvailableFromFD(-1)
        assert.is_nil(data)
        assert.is_false(eof)
        assert.is_false(drained)
        assert.is_string(err)
    end)
end)
