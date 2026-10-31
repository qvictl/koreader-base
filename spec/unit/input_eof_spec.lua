local ffi = require("ffi")
if ffi.os ~= "Linux" then return end
require("ffi/posix_h")
require("ffi/linux_input_h")

local C = ffi.C
local input = assert(package.loadlib("./libs/libkoreader-input-test.so", "luaopen_input_test"))()

describe("native input pipe EOF", function()
    local writers
    before_each(function() writers = {} end)
    after_each(function()
        input.closeAll()
        for fd in pairs(writers) do C.close(fd) end
    end)

    local function pipe()
        local fds = ffi.new("int[2]")
        assert.are.equal(0, C.pipe(fds))
        local reader, writer = tonumber(fds[0]), tonumber(fds[1])
        assert.are.equal(0, C.fcntl(reader, C.F_SETFL, ffi.cast("int", C.O_NONBLOCK)))
        assert.are.equal(0, C.fcntl(writer, C.F_SETFL, ffi.cast("int", C.O_NONBLOCK)))
        writers[writer] = true
        input.fdopen(reader)
        return reader, writer
    end
    local function closeWriter(writer)
        assert.are.equal(0, C.close(writer))
        writers[writer] = nil
    end
    local function send(writer, count)
        local events = ffi.new("struct input_event[?]", count)
        for i = 0, count - 1 do
            events[i].type = 1
            events[i].code = 30
            events[i].value = i + 1
        end
        assert.are.equal(ffi.sizeof(events), C.write(writer, events, ffi.sizeof(events)))
    end
    local function pollError(expected)
        local ok, err, timer, retired = input.waitForEvent(0, 0)
        assert.is_false(ok)
        assert.are.equal(tonumber(expected), err)
        assert.is_nil(timer)
        return retired
    end

    it("retires an empty EOF descriptor and reports EPIPE only once", function()
        local reader, writer = pipe()
        closeWriter(writer)
        assert.are.equal(reader, pollError(C.EPIPE))
        assert.are.equal(-1, C.fcntl(reader, C.F_GETFD))
        pollError(C.ETIME)
        local ok, err = input.close(reader)
        assert.is_false(ok)
        assert.are.equal(tonumber(C.ENODEV), err)
    end)

    for _, count in ipairs({ 1, 256, 257 }) do
        it("delivers all " .. count .. " final events with their original fd", function()
            local reader, writer = pipe()
            send(writer, count)
            closeWriter(writer)
            local ok, events, timer, retired = input.waitForEvent(0, 0)
            assert.is_true(ok)
            assert.is_nil(timer)
            assert.are.equal(reader, retired)
            assert.are.equal(count, #events)
            for i, event in ipairs(events) do
                assert.are.equal(reader, event.fd)
                assert.are.equal(i, event.value)
                assert.are.equal(1, event.type)
                assert.are.equal(30, event.code)
            end
            assert.are.equal(-1, C.fcntl(reader, C.F_GETFD))
            assert.is_nil(pollError(C.ETIME))
        end)
    end

    it("does not starve another ready input after repacking the closed slot", function()
        local _, first_writer = pipe()
        local second_reader, second_writer = pipe()
        closeWriter(first_writer)
        send(second_writer, 1)
        pollError(C.EPIPE)
        local ok, events = input.waitForEvent(0, 0)
        assert.is_true(ok)
        assert.are.equal(1, #events)
        assert.are.equal(second_reader, events[1].fd)
        -- A live, temporarily drained pipe must remain registered.
        pollError(C.ETIME)
        send(second_writer, 1)
        assert.is_true(input.waitForEvent(0, 0))
    end)

    it("preserves the timer fd when the highest input descriptor reaches EOF", function()
        -- An absolute deadline in the past is already ready; no timing race.
        local timer = input.setTimer(C.CLOCK_MONOTONIC, 1, 0)
        assert.is_not_nil(timer)
        local _, writer = pipe()
        closeWriter(writer)
        pollError(C.EPIPE)
        local ok, err, expired = input.waitForEvent(0, 0)
        assert.is_false(ok)
        assert.are.equal(tonumber(C.ETIME), err)
        assert.are.equal(timer, expired)
        assert.is_true(input.clearTimer(timer))
        pollError(C.ETIME)
    end)
end)
