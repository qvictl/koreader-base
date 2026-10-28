local ffi = require("ffi")

describe("bitser module", function()
    local bitser

    setup(function()
        bitser = require("ffi/bitser")
    end)

    local function roundtrip(value)
        return bitser.loads(bitser.dumps(value))
    end

    describe("scalars", function()
        it("should encode nil, booleans and small integers as a single byte", function()
            assert.are.equal("\247", bitser.dumps(nil))
            assert.are.equal("\248", bitser.dumps(false))
            assert.are.equal("\249", bitser.dumps(true))
            assert.are.equal("\0", bitser.dumps(-27))
            assert.are.equal("\27", bitser.dumps(0))
            assert.are.equal("\127", bitser.dumps(100))
            assert.is_nil(roundtrip(nil))
            assert.is_false(roundtrip(false))
            assert.is_true(roundtrip(true))
        end)

        it("should pick the smallest integer encoding and keep values exact", function()
            -- {value, encoded length}
            local cases = {
                {-27, 1}, {100, 1},
                {-28, 3}, {101, 3}, {-32768, 3}, {32767, 3},
                {-32769, 5}, {32768, 5}, {-2147483648, 5}, {2147483647, 5},
                -- out of int32 range: stored as double
                {2147483648, 9}, {-2147483649, 9}, {2^53, 9},
            }
            for _, case in ipairs(cases) do
                local value, len = case[1], case[2]
                local s = bitser.dumps(value)
                assert.are.equal(len, #s, "encoded length of " .. value)
                local r = bitser.loads(s)
                assert.are.equal("number", type(r))
                assert.are.equal(value, r)
            end
            assert.are.equal(250, bitser.dumps(1000):byte(1))
            assert.are.equal(245, bitser.dumps(100000):byte(1))
            assert.are.equal(246, bitser.dumps(0.5):byte(1))
        end)

        it("should round trip floats and special values", function()
            for _, v in ipairs({0.5, -1.25, 1/3, 1e300, -1e-300, math.pi, math.huge, -math.huge}) do
                assert.are.equal(v, roundtrip(v))
            end
            local nan = roundtrip(0/0)
            assert.are_not.equal(nan, nan)
        end)

        it("should round trip short, long and binary strings", function()
            local all_bytes = {}
            for i = 0, 255 do
                all_bytes[#all_bytes + 1] = string.char(i)
            end
            all_bytes = table.concat(all_bytes)
            local strings = {
                "",
                "a",
                string.rep("x", 31), -- longest short string
                string.rep("y", 32), -- shortest long string
                "nul\0inside\0",
                all_bytes,
                string.rep("0123456789", 10000), -- bigger than the initial 4 KiB buffer
            }
            for _, str in ipairs(strings) do
                assert.are.equal(str, roundtrip(str))
            end
            assert.are.equal(192, bitser.dumps(""):byte(1))
            assert.are.equal(192 + 31, bitser.dumps(string.rep("x", 31)):byte(1))
            assert.are.equal(244, bitser.dumps(string.rep("y", 32)):byte(1))
        end)
    end)

    describe("tables", function()
        it("should round trip arrays, hashes and nested tables", function()
            local t = {
                1, 2.5, "three", true, false,
                name = "book",
                nested = { list = { {}, { "deep" } }, [-1] = "neg", [0] = "zero", [1.5] = "frac" },
                [true] = "bool key",
                [12345] = "beyond the array part",
            }
            assert.are.same(t, roundtrip(t))
            assert.are.same({}, roundtrip({}))
        end)

        it("should keep table keys", function()
            local key = { id = 7 }
            local r = roundtrip({ [key] = "value" })
            local k, v = next(r)
            assert.are.same(key, k)
            assert.are.equal("value", v)
        end)

        it("should preserve shared references and cycles", function()
            local shared = { "shared" }
            local t = { a = shared, b = shared, list = { shared } }
            t.self = t
            local r = roundtrip(t)
            assert.are.equal(r, r.self)
            assert.are.equal(r.a, r.b)
            assert.are.equal(r.a, r.list[1])
            assert.are.same({ "shared" }, r.a)
        end)

        it("should store repeated strings as references", function()
            local str = string.rep("z", 100)
            local once = bitser.dumps({ str })
            local twice = bitser.dumps({ str, str })
            -- the second copy is a 1-byte reference, not another 100 bytes
            assert.is_true(#twice < #once + 3)
            assert.are.same({ str, str }, bitser.loads(twice))
        end)

        it("should resolve references beyond the small reference range", function()
            local t = {}
            for i = 1, 100 do
                t[i] = { i = i, name = "item" .. i }
            end
            -- references to the 70th and 100th tables need the long reference encoding
            t[101] = t[70]
            t[102] = t[100]
            t[103] = t[1]
            local r = roundtrip(t)
            assert.are.equal(103, #r)
            assert.are.equal(r[70], r[101])
            assert.are.equal(r[100], r[102])
            assert.are.equal(r[1], r[103])
            assert.are.same({ i = 70, name = "item70" }, r[101])
            -- seen index 70 is out of the 1-byte reference range: tag 243 + small int 70
            local strs = {}
            for i = 1, 70 do
                strs[i] = "s" .. i
            end
            strs[71] = strs[70]
            local s = bitser.dumps(strs)
            -- (followed by the empty hash part count, small int 0)
            assert.are.equal("\243" .. string.char(70 + 27) .. "\27", s:sub(-3))
            assert.are.same(strs, bitser.loads(s))
        end)

        it("should restore plain metatables, shared between instances", function()
            local mt = { __index = { greet = "hello" }, tag = "mt" }
            local a = setmetatable({ x = 1 }, mt)
            local b = setmetatable({ x = 2 }, mt)
            local r = roundtrip({ a, b })
            assert.are.equal(1, r[1].x)
            assert.are.equal(2, r[2].x)
            assert.are.equal("hello", r[1].greet)
            assert.are.equal("mt", getmetatable(r[1]).tag)
            assert.are.equal(getmetatable(r[1]), getmetatable(r[2]))
            assert.are.equal(253, bitser.dumps(a):byte(1))
        end)

        it("should drop metatables when includeMetatables(false)", function()
            local t = setmetatable({ x = 1 }, { tag = "mt" })
            bitser.includeMetatables(false)
            local ok, s = pcall(bitser.dumps, t)
            bitser.includeMetatables(true)
            assert.is_true(ok)
            assert.are.equal(240, s:byte(1))
            local r = bitser.loads(s)
            assert.are.same({ x = 1 }, r)
            assert.is_nil(getmetatable(r))
            -- data written with metatables is still readable, but the metatable is ignored
            local with_mt = bitser.dumps(t)
            bitser.includeMetatables(false)
            ok, r = pcall(bitser.loads, with_mt)
            bitser.includeMetatables(true)
            assert.is_true(ok)
            assert.are.equal(1, r.x)
            assert.is_nil(getmetatable(r))
        end)
    end)

    describe("cdata", function()
        setup(function()
            ffi.cdef("struct bitser_spec_point { int32_t x; double y; };")
        end)

        it("should round trip ctypes", function()
            local ty = ffi.typeof("struct bitser_spec_point")
            assert.are.equal(ty, roundtrip(ty))
            assert.are.equal(ffi.typeof("int32_t"), roundtrip(ffi.typeof("int32_t")))
        end)

        it("should round trip cdata values", function()
            local p = roundtrip(ffi.new("struct bitser_spec_point", 3, 2.5))
            assert.are.equal(ffi.typeof("struct bitser_spec_point"), ffi.typeof(p))
            assert.are.equal(3, p.x)
            assert.are.equal(2.5, p.y)
            -- NOTE: busted's LuaJIT shim caches ffi.typeof() by its first argument only,
            --       so bitser's ffi.typeof("$[1]", ctype) only works for one cdata type
            --       per test process: stick to the struct.
            local t = roundtrip({ a = ffi.new("struct bitser_spec_point", -1, 0.25), b = "x" })
            assert.are.equal(-1, t.a.x)
            assert.are.equal(0.25, t.a.y)
            assert.are.equal("x", t.b)
        end)
    end)

    describe("unsupported values", function()
        it("should refuse to serialize functions, userdata and threads", function()
            assert.has_error(function() bitser.dumps(print) end)
            assert.has_error(function() bitser.dumps({ f = function() end }) end)
            assert.has_error(function() bitser.dumps(io.stdout) end)
            assert.has_error(function() bitser.dumps(coroutine.create(print)) end)
            local ok, err = pcall(bitser.dumps, { 1, 2, print })
            assert.is_false(ok)
            assert.truthy(err:find("cannot serialize type function", 1, true))
        end)

        it("should still work after a failed serialization", function()
            assert.is_false(pcall(bitser.dumps, { a = print }))
            assert.are.same({ a = 1 }, roundtrip({ a = 1 }))
        end)
    end)

    describe("loading", function()
        it("should refuse empty input", function()
            local ok, err = pcall(bitser.loads, "")
            assert.is_false(ok)
            assert.truthy(err:find("cannot load value from empty string", 1, true))
            ok, err = pcall(bitser.loadData, ffi.new("uint8_t[1]"), 0)
            assert.is_false(ok)
            assert.truthy(err:find("cannot load value from empty data", 1, true))
        end)

        it("should reject unknown type tags", function()
            for _, tag in ipairs({ 254, 255 }) do
                local ok, err = pcall(bitser.loads, string.char(tag))
                assert.is_false(ok)
                assert.truthy(err:find("unsupported serialized type " .. tag, 1, true))
            end
        end)

        it("should reject strings longer than the input", function()
            bitser.clearBuffer()
            local ok, err = pcall(bitser.loads, "\200abc") -- short string of 8 bytes, only 3 given
            assert.is_false(ok)
            assert.truthy(err:find("malformed serialized data", 1, true))
            bitser.clearBuffer()
            ok, err = pcall(bitser.loads, "\240") -- table without its length
            assert.is_false(ok)
            assert.truthy(err:find("malformed serialized data", 1, true))
        end)

        it("should load from a raw memory buffer", function()
            local value = { title = "Alice", pages = { 1, 2, 3 }, ratio = 0.75 }
            local s = bitser.dumps(value)
            local data = ffi.new("uint8_t[?]", #s)
            ffi.copy(data, s, #s)
            assert.are.same(value, bitser.loadData(data, #s))
            -- the writable buffer is restored afterwards: dumps/loads keep working
            assert.are.same({ 1, "two" }, roundtrip({ 1, "two" }))
            assert.are.same(value, bitser.loadData(data, #s))
            assert.are.equal("after", bitser.loads(bitser.dumps("after")))
        end)

        it("should keep working with a cleared or pre-reserved buffer", function()
            bitser.clearBuffer()
            assert.are.same({ x = 1 }, roundtrip({ x = 1 }))
            bitser.reserveBuffer(65536)
            local big = string.rep("k", 50000)
            assert.are.equal(big, roundtrip(big))
            bitser.clearBuffer()
            assert.are.equal(big, roundtrip(big))
        end)

        it("should expose its version", function()
            assert.are.equal("1.1", bitser.version)
        end)
    end)

    describe("resources", function()
        it("should serialize registered resources by name", function()
            local res = { "not serialized" }
            assert.are.equal(res, bitser.register("res", res))
            finally(function() bitser.unregister("res") end)
            local s = bitser.dumps(res)
            assert.are.equal(224 + #"res", s:byte(1))
            assert.are.equal("res", s:sub(2))
            assert.are.equal(res, bitser.loads(s))
            local r = roundtrip({ res, res, other = res })
            assert.are.equal(res, r[1])
            assert.are.equal(res, r[2])
            assert.are.equal(res, r.other)
        end)

        it("should serialize resources with long names", function()
            local res = { "long" }
            local name = "a_resource_with_a_long_name"
            bitser.register(name, res)
            finally(function() bitser.unregister(name) end)
            local s = bitser.dumps(res)
            assert.are.equal(241, s:byte(1))
            assert.are.equal(res, bitser.loads(s))
            assert.are.equal(res, roundtrip({ res })[1])
        end)

        it("should refuse to register a name twice", function()
            bitser.register("dup", {})
            finally(function() bitser.unregister("dup") end)
            assert.has_error(function() bitser.register("dup", {}) end, "dup already registered")
        end)

        it("should serialize the value itself once unregistered", function()
            local res = { "content" }
            bitser.register("tmp", res)
            bitser.unregister("tmp")
            local r = roundtrip(res)
            assert.are_not.equal(res, r)
            assert.are.same(res, r)
            -- the name is free again
            bitser.register("tmp", res)
            bitser.unregister("tmp")
        end)
    end)

    describe("classes", function()
        it("should support hump.class style classes", function()
            local Point = { kind = "point" }
            Point.__index = Point
            bitser.registerClass("Point", Point)
            finally(function() bitser.unregisterClass("Point") end)
            local p = setmetatable({ x = 1, y = 2 }, Point)
            local s = bitser.dumps(p)
            assert.are.equal(242, s:byte(1))
            local r = bitser.loads(s)
            assert.are.equal(Point, getmetatable(r))
            assert.are.equal("point", r.kind)
            assert.are.equal(1, r.x)
            assert.are.equal(2, r.y)
            -- shared instances stay shared
            local t = roundtrip({ p, p })
            assert.are.equal(t[1], t[2])
            assert.are.equal(Point, getmetatable(t[1]))
        end)

        it("should support MiddleClass style classes", function()
            local Klass = { name = "MCKlass", __instanceDict = { kind = "mc" } }
            Klass.__instanceDict.__index = Klass.__instanceDict
            assert.are.equal(Klass, bitser.registerClass(Klass)) -- name taken from class.name
            finally(function() bitser.unregisterClass("MCKlass") end)
            local obj = setmetatable({ class = Klass, v = 42, 1, 2 }, Klass.__instanceDict)
            local r = roundtrip(obj)
            assert.are.equal(Klass, r.class) -- the class key is restored, not serialized
            assert.are.equal(Klass.__instanceDict, getmetatable(r))
            assert.are.equal("mc", r.kind)
            assert.are.equal(42, r.v)
            assert.are.same({ 1, 2 }, { r[1], r[2] })
        end)

        it("should support SECL style classes", function()
            local mt = { __index = { kind = "secl" } }
            local Klass = setmetatable({ __baseclass = {} }, mt)
            bitser.registerClass("SECLKlass", Klass)
            finally(function() bitser.unregisterClass("SECLKlass") end)
            local obj = setmetatable({ __baseclass = Klass, v = 1 }, mt)
            local r = roundtrip(obj)
            assert.are.equal(Klass, r.__baseclass)
            assert.are.equal(mt, getmetatable(r))
            assert.are.equal("secl", r.kind)
            assert.are.equal(1, r.v)
        end)

        it("should support Slither style classes", function()
            local instance_mt = { __index = { kind = "slither" } }
            local Klass = setmetatable({ __name__ = "SlitherKlass" }, {
                allocate = function(instance) return setmetatable(instance, instance_mt) end,
            })
            bitser.registerClass(Klass.__name__, Klass, "__class__")
            finally(function() bitser.unregisterClass("SlitherKlass") end)
            local obj = setmetatable({ __class__ = Klass, v = 3 }, instance_mt)
            local r = roundtrip(obj)
            assert.are.equal(Klass, r.__class__)
            assert.are.equal(instance_mt, getmetatable(r))
            assert.are.equal("slither", r.kind)
            assert.are.equal(3, r.v)
        end)

        it("should support Moonscript style classes", function()
            local base = { kind = "moon" }
            base.__index = base
            local Klass = { __base = base, __name = "MoonKlass" }
            base.__class = Klass
            bitser.registerClass(Klass) -- name taken from class.__name
            finally(function() bitser.unregisterClass("MoonKlass") end)
            local r = roundtrip(setmetatable({ v = 4 }, base))
            assert.are.equal(base, getmetatable(r))
            assert.are.equal(Klass, r.__class)
            assert.are.equal(4, r.v)
        end)

        it("should use a custom deserializer", function()
            local Klass = {}
            local seen_class
            bitser.registerClass("CustomKlass", Klass, nil, function(instance, class)
                seen_class = class
                instance.restored = true
                return setmetatable(instance, Klass)
            end)
            finally(function() bitser.unregisterClass("CustomKlass") end)
            local r = roundtrip(setmetatable({ v = 5 }, Klass))
            assert.are.equal(Klass, seen_class)
            assert.are.equal(Klass, getmetatable(r))
            assert.is_true(r.restored)
            assert.are.equal(5, r.v)
        end)

        it("should refuse classes it cannot deserialize", function()
            assert.has_error(function() bitser.registerClass("Unknown", {}) end,
                "no deserializer given for unsupported class library")
        end)

        it("should serialize instances as plain tables once unregistered", function()
            local Klass = { kind = "gone" }
            Klass.__index = Klass
            bitser.registerClass("GoneKlass", Klass)
            bitser.unregisterClass("GoneKlass")
            local r = roundtrip(setmetatable({ v = 6 }, Klass))
            assert.are.equal(6, r.v)
            -- the metatable is now a copy, not the class itself
            assert.are_not.equal(Klass, getmetatable(r))
            assert.are.equal("gone", r.kind)
        end)
    end)
end)
