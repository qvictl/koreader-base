local ffi = require("ffi")

describe("bitser malformed input", function()
    local bitser

    setup(function()
        bitser = require("ffi/bitser")
    end)

    local function assert_malformed(str)
        local ok, err = pcall(bitser.loads, str)
        assert.is_false(ok, "loaded: " .. tostring(err))
        assert.truthy(tostring(err):find("malformed serialized data", 1, true), err)
    end

    it("should reject truncated input even after a bigger dump", function()
        -- leave stale data in the (reused) buffer
        local long_string = bitser.dumps(string.rep("b", 100))
        local long_int = bitser.dumps(123456789)
        local double = bitser.dumps(0.1)
        local short_int = bitser.dumps(1000)
        bitser.dumps(string.rep("x", 10000))
        assert_malformed(long_string:sub(1, 10))
        assert_malformed(long_int:sub(1, 2))
        assert_malformed(double:sub(1, 5))
        assert_malformed(short_int:sub(1, 2))
        assert_malformed(bitser.dumps({ 1, 2, 3, "four" }):sub(1, 4))
        -- complete data still loads
        assert.are.equal(123456789, bitser.loads(long_int))
        assert.are.equal(string.rep("b", 100), bitser.loads(long_string))
    end)

    it("should reject truncated raw data", function()
        local s = bitser.dumps(0.1)
        local data = ffi.new("uint8_t[?]", #s)
        ffi.copy(data, s, #s)
        local ok, err = pcall(bitser.loadData, data, 5)
        assert.is_false(ok)
        assert.truthy(err:find("malformed serialized data", 1, true))
        assert.are.equal(0.1, bitser.loadData(data, #s))
    end)

    it("should reject negative lengths", function()
        -- long string whose length is the small int -27
        assert_malformed("\244\0")
    end)

    it("should keep references right after a resource with a long name", function()
        local res = { "resource" }
        local name = "a_resource_with_a_long_name"
        bitser.register(name, res)
        finally(function() bitser.unregister(name) end)
        local shared = { "shared" }
        local r = bitser.loads(bitser.dumps({ res, "x", "x", shared, shared }))
        assert.are.equal(res, r[1])
        assert.are.equal("x", r[2])
        assert.are.equal("x", r[3])
        assert.are.same({ "shared" }, r[4])
        assert.are.equal(r[4], r[5])
    end)
end)
