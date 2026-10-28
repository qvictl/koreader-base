-- ffi/zstd compresses the frontend's persisted caches (persist.lua) and the cover thumbnails
-- of the cover browser (bookinfomanager): round trips must be exact, and a corrupted cache
-- entry must raise an error (that callers catch), not crash or return garbage.
local ffi = require("ffi")
local zstd = require("ffi/zstd")
local C = ffi.C

local function toString(ptr, len)
    local s = ffi.string(ptr, len)
    C.free(ptr)
    return s
end

local function compress(str, level)
    local ptr, len = zstd.zstd_compress(str, #str, level)
    return toString(ptr, len)
end

-- Some data that compresses well, with every byte value in it.
local function sample()
    local t = {}
    for i = 0, 255 do t[#t + 1] = string.char(i) end
    local bytes = table.concat(t)
    return string.rep("KOReader on Kindle " .. bytes, 64)
end

describe("zstd", function()
    it("should round trip data, compressing it", function()
        local data = sample()
        local packed = compress(data)
        assert.is_true(#packed < #data / 10)
        local ptr, len = zstd.zstd_uncompress(packed, #packed)
        assert.are.equal(#data, tonumber(len))
        assert.are.equal(data, toString(ptr, len))
    end)

    it("should honor the compression level", function()
        local data = sample()
        local fast = compress(data, 1)
        local best = compress(data, 19)
        assert.is_true(#best <= #fast)
        for _, packed in ipairs({ fast, best }) do
            local ptr, len = zstd.zstd_uncompress(packed, #packed)
            assert.are.equal(data, toString(ptr, len))
        end
    end)

    it("should compress from a raw buffer", function()
        local n = 4096
        local buf = ffi.new("uint8_t[?]", n)
        for i = 0, n - 1 do buf[i] = i % 7 end
        local packed = toString(zstd.zstd_compress(buf, n))
        local ptr, len = zstd.zstd_uncompress(packed, #packed)
        assert.are.equal(n, tonumber(len))
        assert.are.equal(ffi.string(buf, n), toString(ptr, len))
    end)

    it("should round trip an empty string", function()
        local packed = compress("")
        assert.is_true(#packed > 0)
        local ptr, len = zstd.zstd_uncompress(packed, #packed)
        assert.are.equal(0, tonumber(len))
        C.free(ptr)
    end)

    it("should raise an error on corrupted input", function()
        local packed = compress(sample())
        -- Not a zstd frame at all.
        assert.has_error(function() zstd.zstd_uncompress("not a zstd frame", 16) end)
        -- A valid header, but truncated data.
        local truncated = packed:sub(1, #packed - 8)
        assert.has_error(function() zstd.zstd_uncompress(truncated, #truncated) end)
    end)

    describe("with a decompression context", function()
        it("should round trip data, reusing its context", function()
            local data = sample()
            local packed = compress(data)
            for _ = 1, 3 do
                local ptr, len = zstd.zstd_uncompress_ctx(packed, #packed)
                assert.are.equal(data, toString(ptr, len))
            end
            local other = string.rep("x", 1000)
            local ptr, len = zstd.zstd_uncompress_ctx(compress(other), #compress(other))
            assert.are.equal(other, toString(ptr, len))
        end)

        it("should raise an error on corrupted input, and still work afterwards", function()
            local data = sample()
            local packed = compress(data)
            local truncated = packed:sub(1, #packed - 8)
            assert.has_error(function() zstd.zstd_uncompress_ctx(truncated, #truncated) end)
            -- The context is reset on the next call.
            local ptr, len = zstd.zstd_uncompress_ctx(packed, #packed)
            assert.are.equal(data, toString(ptr, len))
        end)
    end)
end)
