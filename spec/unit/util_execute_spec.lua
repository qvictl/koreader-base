local ffi = require("ffi")
local util = require("ffi/util")
local C = ffi.C

describe("execute failures", function()
    local paths
    before_each(function() paths = {} end)
    after_each(function() for _, value in ipairs(paths) do os.remove(value) end end)

    local function path()
        local value = os.tmpname()
        os.remove(value)
        paths[#paths + 1] = value
        return value
    end

    local function withC(overrides, check)
        local index, original
        for i = 1, 30 do
            local name, value = debug.getupvalue(util.execute, i)
            if name == "C" then index, original = i, value; break end
        end
        assert.is_number(index)
        debug.setupvalue(util.execute, index, setmetatable(overrides, { __index = original }))
        local ok, err = xpcall(check, debug.traceback)
        debug.setupvalue(util.execute, index, original)
        if not ok then error(err, 0) end
    end

    it("does not flush parent buffers when exec fails", function()
        local out = path()
        local f = assert(io.open(out, "w"))
        f:setvbuf("full", 1024)
        f:write("parent-buffer")
        local status = util.execute(path())
        f:close()
        local r = assert(io.open(out, "r"))
        local content = r:read("*all")
        r:close()
        assert.are.equal(255 * 256, status)
        assert.are.equal("parent-buffer", content)
    end)

    it("reports fork failure without waiting for unrelated children", function()
        local waited = false
        withC({
            fork = function() return -1 end,
            waitpid = function() waited = true; return -1 end,
        }, function()
            assert.are.equal(-1, util.execute("/bin/true"))
            assert.is_false(waited)
        end)
    end)

    it("retries interrupted waits and preserves raw status", function()
        local waits = 0
        withC({
            fork = function() return 123 end,
            waitpid = function(pid, status)
                assert.are.equal(123, pid)
                waits = waits + 1
                if waits == 1 then ffi.errno(C.EINTR); return -1 end
                status[0] = 7 * 256
                return pid
            end,
        }, function()
            assert.are.equal(7 * 256, util.execute("/bin/true"))
            assert.are.equal(2, waits)
        end)
    end)

    it("does not report an uncollected status as command success", function()
        withC({
            fork = function() return 123 end,
            waitpid = function() ffi.errno(C.EINVAL); return -1 end,
        }, function()
            assert.are.equal(-1, util.execute("/bin/true"))
        end)
    end)
end)
