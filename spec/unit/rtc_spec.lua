-- ffi/rtc schedules the RTC wakeup alarms used by suspend on Kindle/Kobo (autosuspend,
-- autoshutdown, the "wake up to check for an unexpected wakeup" logic): a wrong alarm,
-- or a failure that goes unnoticed, means a device that never wakes up (or never sleeps).
-- There is no /dev/rtc0 to play with here: the module is loaded with a fake ffi.C, whose
-- open/ioctl/close/settimeofday emulate the RTC driver (everything else is the real libc).
local ffi = require("ffi")
require("ffi/posix_h")
require("ffi/rtc_h")
local real_C = ffi.C

local ENOENT, EIO, ENOTTY, EPERM = 2, 5, 25, 1

local function setTm(dst, src)
    dst.tm_sec, dst.tm_min, dst.tm_hour = src.sec or 0, src.min or 0, src.hour or 0
    dst.tm_mday, dst.tm_mon, dst.tm_year = src.mday or 1, src.mon or 0, src.year or 70
end

-- Broken down UTC time of an epoch, as the fake driver stores it.
local function utc(epoch)
    local tm = ffi.new("struct tm")
    real_C.gmtime_r(ffi.new("time_t[1]", epoch), tm)
    return { sec = tm.tm_sec, min = tm.tm_min, hour = tm.tm_hour, mday = tm.tm_mday, mon = tm.tm_mon, year = tm.tm_year }
end

local function timegm(tm)
    return tonumber(real_C.timegm(tm))
end

-- A fake RTC driver. dev.fail[name] = errno makes that call fail.
local function fakeDevice()
    local dev = {
        calls = {},
        fail = {},
        alarm = utc(0), -- what RTC_WKALM_RD reports
        alarm_enabled = 0,
        time = utc(os.time()), -- what RTC_RD_TIME reports
        open_fds = 0,
    }
    local function failed(name)
        local err = dev.fail[name]
        if err then
            ffi.errno(err)
            return true
        end
    end
    local C = setmetatable({}, { __index = real_C })
    function C.open(path, flags)
        table.insert(dev.calls, { "open", path, flags })
        if failed("open") then return -1 end
        dev.open_fds = dev.open_fds + 1
        return 42
    end
    function C.close(fd)
        table.insert(dev.calls, { "close", fd })
        dev.open_fds = dev.open_fds - 1
        if failed("close") then return -1 end
        return 0
    end
    function C.ioctl(fd, request, arg)
        local name
        if request == real_C.RTC_WKALM_SET then
            name = "RTC_WKALM_SET"
            dev.set = {
                enabled = arg.enabled,
                sec = arg.time.tm_sec, min = arg.time.tm_min, hour = arg.time.tm_hour,
                mday = arg.time.tm_mday, mon = arg.time.tm_mon, year = arg.time.tm_year,
                wday = arg.time.tm_wday, yday = arg.time.tm_yday, isdst = arg.time.tm_isdst,
            }
        elseif request == real_C.RTC_WKALM_RD then
            name = "RTC_WKALM_RD"
            if not dev.fail.ioctl then
                arg.enabled = dev.alarm_enabled
                setTm(arg.time, dev.alarm)
            end
        elseif request == real_C.RTC_RD_TIME then
            name = "RTC_RD_TIME"
            if not dev.fail.ioctl then
                setTm(arg, dev.time)
            end
        elseif request == real_C.RTC_AIE_ON then
            name = "RTC_AIE_ON"
        elseif request == real_C.RTC_AIE_OFF then
            name = "RTC_AIE_OFF"
        end
        table.insert(dev.calls, { "ioctl", fd, name })
        if failed("ioctl") then return -1 end
        return 0
    end
    function C.settimeofday(tv, tz)
        table.insert(dev.calls, {
            "settimeofday",
            tv ~= nil and tonumber(tv.tv_sec) or nil,
            tz ~= nil and tonumber(tz.tz_minuteswest) or nil,
        })
        dev.settimeofday_calls = (dev.settimeofday_calls or 0) + 1
        if dev.settimeofday_calls == dev.settimeofday_fail_at then
            dev.settimeofday_calls = 0
            ffi.errno(EPERM)
            return -1
        end
        if failed("settimeofday") then return -1 end
        return 0
    end
    return dev, C
end

-- Loads a fresh ffi/rtc module, bound to the given fake ffi.C.
local function loadRTC(fake_C)
    local saved_ffi = package.loaded.ffi
    package.loaded["ffi/rtc"] = nil
    package.loaded.ffi = setmetatable({ C = fake_C }, { __index = ffi })
    local ok, RTC = pcall(require, "ffi/rtc")
    package.loaded.ffi = saved_ffi
    package.loaded["ffi/rtc"] = nil
    assert(ok, RTC)
    return RTC
end

local function callNames(dev)
    local t = {}
    for _, c in ipairs(dev.calls) do
        table.insert(t, c[1] == "ioctl" and c[3] or c[1])
    end
    return t
end

describe("RTC", function()
    local dev, RTC

    before_each(function()
        local C
        dev, C = fakeDevice()
        RTC = loadRTC(C)
    end)

    it("should compute epochs from now", function()
        local now = os.time()
        local epoch = RTC:secondsFromNowToEpoch(3600)
        assert.is_true(epoch >= now + 3600 and epoch <= now + 3601)
    end)

    describe("setWakeupAlarm", function()
        it("should program the alarm in UTC, and remember it", function()
            local epoch = 1700000000 -- 2023-11-14 22:13:20 UTC
            assert.is_false(RTC:isWakeupAlarmScheduled())
            assert.is_nil(RTC:getWakeupAlarmEpoch())
            assert.is_true(RTC:setWakeupAlarm(epoch))
            assert.are.same({ "open", "RTC_WKALM_SET", "close" }, callNames(dev))
            assert.are.equal("/dev/rtc0", dev.calls[1][2])
            assert.are.same({
                enabled = 1, sec = 20, min = 13, hour = 22, mday = 14, mon = 10, year = 123,
                wday = -1, yday = -1, isdst = -1,
            }, dev.set)
            assert.are.equal(0, dev.open_fds)
            assert.is_true(RTC:isWakeupAlarmScheduled())
            assert.are.equal(epoch, RTC:getWakeupAlarmEpoch())
            local tm = RTC:getWakeupAlarm()
            assert.are.equal(123, tm.tm_year)
            assert.are.equal(22, tm.tm_hour)
        end)

        it("should program a disabled alarm when asked to", function()
            assert.is_true(RTC:setWakeupAlarm(1700000000))
            assert.is_true(RTC:setWakeupAlarm(0, false))
            assert.are.equal(0, dev.set.enabled)
            assert.is_false(RTC:isWakeupAlarmScheduled())
            assert.is_nil(RTC:getWakeupAlarm())
            assert.is_nil(RTC:getWakeupAlarmEpoch())
        end)

        it("should report a missing RTC", function()
            dev.fail.open = ENOENT
            local ok, re, err = RTC:setWakeupAlarm(1700000000)
            assert.is_nil(ok)
            assert.are.equal(-1, re)
            assert.are.equal("No such file or directory", err)
            assert.is_false(RTC:isWakeupAlarmScheduled())
        end)

        it("should report an RTC without alarm support", function()
            dev.fail.ioctl = ENOTTY
            local ok, re, err = RTC:setWakeupAlarm(1700000000)
            assert.is_nil(ok)
            assert.are.equal(-1, re)
            assert.are.equal("Inappropriate ioctl for device", err)
            assert.is_false(RTC:isWakeupAlarmScheduled())
            assert.is_nil(RTC:getWakeupAlarmEpoch())
        end)

        it("should report a failed close", function()
            dev.fail.close = EIO
            local ok, re, err = RTC:setWakeupAlarm(1700000000)
            assert.is_nil(ok)
            assert.are.equal(-1, re)
            assert.are.equal("Input/output error", err)
            assert.is_false(RTC:isWakeupAlarmScheduled())
        end)
    end)

    describe("unsetWakeupAlarm", function()
        it("should forget the alarm", function()
            assert.is_true(RTC:setWakeupAlarm(1700000000))
            dev.calls = {}
            RTC:unsetWakeupAlarm()
            assert.are.same({ "open", "RTC_AIE_OFF", "close" }, callNames(dev))
            assert.are.equal(0, dev.open_fds)
            assert.is_false(RTC:isWakeupAlarmScheduled())
            assert.is_nil(RTC:getWakeupAlarm())
            assert.is_nil(RTC:getWakeupAlarmEpoch())
        end)

        it("should forget the alarm even if the RTC cannot be reached", function()
            assert.is_true(RTC:setWakeupAlarm(1700000000))
            dev.fail.open = ENOENT
            RTC:unsetWakeupAlarm()
            assert.is_false(RTC:isWakeupAlarmScheduled())
            assert.is_nil(RTC:getWakeupAlarmEpoch())
        end)
    end)

    describe("toggleAlarmInterrupt", function()
        it("should enable the alarm interrupt", function()
            assert.is_true(RTC:toggleAlarmInterrupt(true))
            assert.are.same({ "open", "RTC_AIE_ON", "close" }, callNames(dev))
            dev.calls = {}
            assert.is_true(RTC:toggleAlarmInterrupt())
            assert.are.same({ "open", "RTC_AIE_ON", "close" }, callNames(dev))
        end)

        it("should disable the alarm interrupt", function()
            assert.is_true(RTC:toggleAlarmInterrupt(false))
            assert.are.same({ "open", "RTC_AIE_OFF", "close" }, callNames(dev))
            dev.fail.ioctl = ENOTTY
            local ok, re, err = RTC:toggleAlarmInterrupt(false)
            assert.is_nil(ok)
            assert.are.equal(-1, re)
            assert.are.equal("Inappropriate ioctl for device", err)
        end)

        it("should report failures", function()
            for _, case in ipairs({ { "open", ENOENT }, { "ioctl", ENOTTY }, { "close", EIO } }) do
                dev.fail = { [case[1]] = case[2] }
                local ok, re, err = RTC:toggleAlarmInterrupt(true)
                assert.is_nil(ok)
                assert.are.equal(-1, re)
                assert.are.equal(ffi.string(real_C.strerror(case[2])), err)
            end
        end)
    end)

    describe("getWakeupAlarmSys & readHardwareClock", function()
        it("should read the RTC alarm", function()
            dev.alarm = utc(1700000000)
            local tm = RTC:getWakeupAlarmSys()
            assert.are.equal(1700000000, timegm(tm))
            assert.are.same({ "open", "RTC_WKALM_RD", "close" }, callNames(dev))
        end)

        it("should read the RTC time", function()
            dev.time = utc(1600000000)
            local tm = RTC:readHardwareClock()
            assert.are.equal(1600000000, timegm(tm))
            assert.are.same({ "open", "RTC_RD_TIME", "close" }, callNames(dev))
        end)

        it("should report failures", function()
            for _, case in ipairs({ { "open", ENOENT }, { "ioctl", ENOTTY }, { "close", EIO } }) do
                for _, method in ipairs({ "getWakeupAlarmSys", "readHardwareClock" }) do
                    dev.fail = { [case[1]] = case[2] }
                    local ok, re, err = RTC[method](RTC)
                    assert.is_nil(ok)
                    assert.are.equal(-1, re)
                    assert.are.equal(ffi.string(real_C.strerror(case[2])), err)
                end
            end
        end)
    end)

    describe("validateWakeupAlarmByProximity", function()
        -- The alarm we set fired `ago` seconds ago, the RTC reports `sys_alarm`.
        local function firedAgo(ago, sys_alarm)
            local alarm = os.time() - ago
            assert.is_true(RTC:setWakeupAlarm(alarm))
            dev.alarm = utc(sys_alarm or alarm)
            dev.time = utc(os.time())
            return alarm
        end

        it("should not validate without an alarm", function()
            assert.is_nil(RTC:validateWakeupAlarmByProximity())
        end)

        it("should not validate when the RTC alarm cannot be read", function()
            firedAgo(5)
            dev.fail.open = ENOENT
            assert.is_nil(RTC:validateWakeupAlarmByProximity())
        end)

        it("should validate our alarm that just fired", function()
            local alarm = firedAgo(5)
            assert.is_true(RTC:validateWakeupAlarmByProximity())
            assert.is_true(RTC:validateWakeupAlarmByProximity(alarm))
            -- Kobo checks 15 s after the wakeup.
            alarm = firedAgo(20)
            assert.is_true(RTC:validateWakeupAlarmByProximity(alarm))
        end)

        it("should honor the proximity", function()
            local alarm = firedAgo(40)
            assert.is_nil(RTC:validateWakeupAlarmByProximity(alarm))
            assert.is_true(RTC:validateWakeupAlarmByProximity(alarm, 60))
            assert.is_nil(RTC:validateWakeupAlarmByProximity(alarm, 10))
        end)

        it("should not validate an alarm that is still to come", function()
            local alarm = firedAgo(-60)
            assert.is_nil(RTC:validateWakeupAlarmByProximity(alarm))
        end)

        it("should not validate an RTC alarm set by someone else", function()
            local alarm = firedAgo(5, os.time() - 3600)
            assert.is_nil(RTC:validateWakeupAlarmByProximity(alarm))
        end)

        it("should not validate another task's alarm", function()
            local alarm = firedAgo(5)
            assert.is_nil(RTC:validateWakeupAlarmByProximity(alarm - 1))
        end)

        it("should trust our alarm on a dodgy RTC reporting a bogus alarm", function()
            local alarm = firedAgo(5, 0)
            assert.is_nil(RTC:validateWakeupAlarmByProximity(alarm))
            RTC.dodgy_rtc = true
            assert.is_true(RTC:validateWakeupAlarmByProximity(alarm))
            -- (only bogus values are overridden)
            alarm = firedAgo(5, os.time() - 3600)
            assert.is_nil(RTC:validateWakeupAlarmByProximity(alarm))
        end)
    end)

    describe("HCToSys", function()
        it("should set the system clock and the kernel timezone from the RTC", function()
            dev.time = utc(1650000000)
            assert.is_true(RTC:HCToSys())
            assert.are.same({ "open", "RTC_RD_TIME", "close", "settimeofday", "settimeofday", "settimeofday" },
                callNames(dev))
            -- First, a zero timezone (locks the kernel's warp_clock)...
            assert.are.same({ "settimeofday", nil, 0 }, dev.calls[4])
            -- ... then the local timezone...
            local cur = ffi.new("time_t[1]", os.time())
            local minuteswest = -tonumber(real_C.localtime(cur).tm_gmtoff) / 60
            assert.are.same({ "settimeofday", nil, minuteswest }, dev.calls[5])
            -- ... and finally the time, as is: the RTC is in UTC.
            assert.are.same({ "settimeofday", 1650000000, nil }, dev.calls[6])
        end)

        it("should report failures to read the RTC, without touching the clock", function()
            for _, case in ipairs({ { "open", ENOENT }, { "ioctl", ENOTTY }, { "close", EIO } }) do
                dev.fail = { [case[1]] = case[2] }
                dev.calls = {}
                local ok, re, err = RTC:HCToSys()
                assert.is_nil(ok)
                assert.are.equal(-1, re)
                assert.are.equal(ffi.string(real_C.strerror(case[2])), err)
                for _, c in ipairs(dev.calls) do
                    assert.are_not.equal("settimeofday", c[1])
                end
            end
        end)

        it("should report failures to set the clock", function()
            dev.fail.settimeofday = EPERM
            local ok, re, err = RTC:HCToSys()
            assert.is_nil(ok)
            assert.are.equal(-1, re)
            assert.are.equal("Operation not permitted", err)
        end)

        it("should report a failure to set the local timezone, or the time", function()
            for _, nth in ipairs({ 2, 3 }) do
                dev.calls = {}
                dev.settimeofday_fail_at = nth
                local ok, re, err = RTC:HCToSys()
                assert.is_nil(ok)
                assert.are.equal(-1, re)
                assert.are.equal("Operation not permitted", err)
                -- It stopped there.
                assert.are.equal(nth, #dev.calls - 3)
            end
        end)
    end)
end)
