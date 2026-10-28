describe("serpent module", function()
    local serpent

    setup(function()
        serpent = require("ffi/serpent")
    end)

    -- serialize with serpent.dump, then load back in the default (safe) mode
    local function roundtrip(value, opts)
        local ok, res = serpent.load(serpent.dump(value, opts))
        assert.is_true(ok, res)
        return res
    end

    it("should expose its metadata", function()
        assert.are.equal("serpent", serpent._NAME)
        assert.are.equal("0.303", serpent._VERSION)
        assert.truthy(serpent._COPYRIGHT)
        assert.truthy(serpent._DESCRIPTION)
    end)

    describe("line", function()
        it("should sort keys: array part, then numbers, then strings", function()
            local t = { 1, 2, 3, a = 1, ["end"] = 2, ["a b"] = 3, [10] = 4, [9] = 5 }
            assert.are.equal('{1, 2, 3, [9] = 5, [10] = 4, a = 1, ["a b"] = 3, ["end"] = 2}',
                serpent.line(t, { comment = false }))
        end)

        it("should quote keys that are not plain identifiers", function()
            assert.are.equal('{["1abc"] = 1, _ok = 2, ["with-dash"] = 3}',
                serpent.line({ _ok = 2, ["1abc"] = 1, ["with-dash"] = 3 }, { comment = false }))
            assert.are.equal('{[false] = 2, [true] = 1}',
                serpent.line({ [true] = 1, [false] = 2 }, { comment = false }))
        end)

        it("should accept a custom sort function", function()
            local reverse = function(keys)
                table.sort(keys, function(a, b) return tostring(a) > tostring(b) end)
            end
            assert.are.equal("{c = 3, b = 2, a = 1}",
                serpent.line({ a = 1, b = 2, c = 3 }, { comment = false, sortkeys = reverse }))
        end)

        it("should add comments with table addresses unless disabled", function()
            local t = { a = {} }
            local line = serpent.line(t)
            assert.truthy(line:find("^{a = {} %-%-%[%[table: 0x%x+%]%]} %-%-%[%[table: 0x%x+%]%]$"), line)
            -- comment = 1: only for the first level
            line = serpent.line(t, { comment = 1 })
            assert.truthy(line:find("^{a = {}} %-%-%[%[table: 0x%x+%]%]$"), line)
            assert.are.equal("{a = {}}", serpent.line(t, { comment = false }))
        end)

        it("should serialize scalars", function()
            assert.are.equal("1", serpent.line(1))
            assert.are.equal("0.5", serpent.line(0.5))
            assert.are.equal('"str"', serpent.line("str"))
            assert.are.equal("true", serpent.line(true))
            assert.are.equal("nil", serpent.line(nil))
            assert.are.equal("1/0 --[[math.huge]]", serpent.line(math.huge))
            assert.are.equal("-1/0 --[[-math.huge]]", serpent.line(-math.huge))
            assert.are.equal("0/0", serpent.line(0/0))
        end)

        it("should honour compact, numformat and nohuge", function()
            assert.are.equal("{1,2,{a=3}}", serpent.line({ 1, 2, { a = 3 } }, { comment = false, compact = true }))
            assert.are.equal("{x = 1.500}", serpent.line({ x = 1.5 }, { comment = false, numformat = "%.3f" }))
            assert.are.equal("{inf, -inf}", serpent.line({ math.huge, -math.huge }, { comment = false, nohuge = true }))
        end)

        it("should preserve special numbers when fixradix is enabled", function()
            local values = { math.huge, -math.huge, 0/0, 1.5 }
            local restored = roundtrip(values, { fixradix = true })
            assert.are.equal(math.huge, restored[1])
            assert.are.equal(-math.huge, restored[2])
            assert.are_not.equal(restored[3], restored[3])
            assert.are.equal(1.5, restored[4])
        end)

        it("should leave custom-format commas intact in a dot-decimal locale", function()
            assert.are.equal(1.5, roundtrip(1.5, {
                fixradix = true,
                numformat = "({%.1f, 0})[1]",
            }))
        end)

        it("should normalize decimal commas without changing the nohuge option", function()
            -- Exercise a comma-decimal locale without depending on installed locales.
            local format = string.format
            local formatter = stub(string, "format", function(fmt, ...)
                local formatted = format(fmt, ...)
                if type((...)) == "number" then
                    return (formatted:gsub("%.", ","))
                end
                return formatted
            end)
            finally(function() formatter:revert() end)
            assert.are.equal("{1.500, 1/0 --[[math.huge]], -1/0 --[[-math.huge]], 0/0}",
                serpent.line({ 1.5, math.huge, -math.huge, 0/0 },
                    { fixradix = true, comment = false, numformat = "%.3f" }))
            assert.are.equal("{1.500, inf, -inf}",
                serpent.line({ 1.5, math.huge, -math.huge },
                    { fixradix = true, nohuge = true, comment = false, numformat = "%.3f" }))
            assert.are.equal('"text"', serpent.line("text", { fixradix = true }))
        end)
    end)

    describe("block", function()
        it("should indent nested tables", function()
            assert.are.equal("{\n  a = 1,\n  b = {\n    c = 2\n  }\n}",
                serpent.block({ a = 1, b = { c = 2 } }, { comment = false }))
            assert.are.equal("{\n\t1,\n\t2\n}", serpent.block({ 1, 2 }, { comment = false, indent = "\t" }))
        end)

        it("should stop at maxlevel", function()
            local t = { a = { b = { c = 1 } } }
            assert.are.equal("{\n  a = {}\n}", serpent.block(t, { comment = false, maxlevel = 1 }))
            assert.are.equal("{\n  a = {\n    b = {}\n  }\n}", serpent.block(t, { comment = false, maxlevel = 2 }))
            local line = serpent.line(t, { comment = 2, maxlevel = 1 })
            assert.truthy(line:find("^{a = {} %-%-%[%[maxlvl%]%]} %-%-%[%[table: 0x%x+%]%]$"), line)
        end)

        it("should limit the number of elements with maxnum", function()
            assert.are.equal("{1, 2}", serpent.line({ 1, 2, 3, 4, 5 }, { comment = false, maxnum = 2 }))
            assert.are.equal("{1, 2, 3}", serpent.line({ 1, 2, 3, x = 1, y = 2 }, { comment = false, maxnum = 3 }))
        end)

        it("should truncate the output around maxlength", function()
            local full = serpent.line({ 1, 2, 3, 4, 5, 6, 7, 8 }, { comment = false })
            local short = serpent.line({ 1, 2, 3, 4, 5, 6, 7, 8 }, { comment = false, maxlength = 3 })
            assert.is_true(#short < #full)
            assert.are.equal("{1, 2, 3, 4}", short)
            assert.are.equal("{} --[[maxlen]]", serpent.line({ 1 }, { maxlength = -1 }))
        end)

        it("should call a custom formatter", function()
            local calls = {}
            local res = serpent.line({ 1, { 2 } }, {
                comment = false,
                custom = function(tag, head, body, tail, level)
                    table.insert(calls, level)
                    return tag .. head .. "<" .. level .. ">" .. body .. tail
                end,
            })
            assert.are.equal("{<0>1, {<1>2}}", res)
            assert.are.same({ 1, 0 }, calls)
        end)
    end)

    describe("filters", function()
        it("should skip ignored values, keys and value types", function()
            local t = { a = 1, b = 2, c = "x", d = true }
            assert.are.equal("{a = 1, d = true}",
                serpent.line(t, { comment = false, valignore = { [2] = true }, keyignore = { c = true } }))
            assert.are.equal("{a = 1}", serpent.line(t, { comment = false, keyallow = { a = true } }))
            assert.are.equal("{a = 1, b = 2}",
                serpent.line(t, { comment = false, valtypeignore = { string = true, boolean = true } }))
        end)

        it("should skip nils in sparse arrays", function()
            assert.are.equal("{[1] = 1, [3] = 3, x = 1}", serpent.line({ 1, nil, 3, x = 1 }, { comment = false, sparse = true }))
        end)
    end)

    describe("special values", function()
        it("should name known globals instead of serializing them", function()
            assert.are.equal("{f = print, g = string.format}",
                serpent.line({ f = print, g = string.format }, { comment = false }))
            assert.truthy(serpent.line({ print }):find("print %-%-%[%[function: builtin#%d+%]%]"))
            -- other userdata are not serializable: they end up as a descriptive string
            assert.truthy(serpent.line({ newproxy() }, { comment = false }):find('^{"userdata: 0x%x+"}$'))
        end)

        it("should skip code with nocode", function()
            local res = serpent.line({ f = function() end }, { comment = false, nocode = true })
            assert.are.equal("{f = function() --[[..skipped..]] end}", res)
        end)

        it("should serialize threads as strings, or fail when fatal", function()
            local co = coroutine.create(print)
            assert.truthy(serpent.line(co, { comment = false }):find('^"thread: 0x%x+"$'))
            local ok, err = pcall(serpent.line, co, { fatal = true })
            assert.is_false(ok)
            assert.truthy(err:find("Can't serialize thread", 1, true))
        end)

        it("should use __tostring and __serialize metamethods", function()
            local t = setmetatable({ secret = 1 }, { __tostring = function() return "TS" end })
            assert.are.equal('"TS"', serpent.line(t, { comment = false }))
            assert.are.equal("{secret = 1}", serpent.line(t, { comment = false, metatostring = false }))
            local s = setmetatable({ 3, 4 }, { __serialize = function(self) return { #self } end })
            assert.are.equal("{2}", serpent.line(s, { comment = false }))
            -- a failing __tostring is ignored
            local bad = setmetatable({ 5 }, { __tostring = function() error("boom") end })
            assert.are.equal("{5}", serpent.line(bad, { comment = false }))
        end)

        it("should mark self references in line mode", function()
            local t = {}
            t.self = t
            local res = serpent.line(t, { comment = false })
            assert.are.equal("{self = nil}", res)
            res = serpent.line(t)
            assert.truthy(res:find("self = nil --[[ref]]", 1, true))
            assert.truthy(res:find("incomplete output with shared/self-references skipped", 1, true))
        end)
    end)

    describe("dump and load", function()
        it("should dump a loadable chunk", function()
            assert.are.equal('do local _={[1]=1,[2]="a",b=true};return _;end', serpent.dump({ 1, "a", b = true }))
            assert.are.equal('do local _={1,"a"};return _;end', serpent.dump({ 1, "a" }))
            assert.are.equal("do local x = {1}; return x; end", serpent.serialize({ 1 }, { name = "x" }))
        end)

        it("should round trip nested data", function()
            local t = {
                1, 2.5, -3, "four",
                str = "line\nbreak \"quoted\" \\ \0 \026 end",
                nested = { deep = { deeper = { "x" } } },
                [10] = "ten",
                ["a key"] = false,
                ["end"] = "keyword",
            }
            assert.are.same(t, roundtrip(t))
        end)

        it("should round trip all byte values", function()
            local bytes = {}
            for i = 0, 255 do
                bytes[#bytes + 1] = string.char(i)
            end
            bytes = table.concat(bytes)
            assert.are.equal(bytes, roundtrip({ bytes })[1])
        end)

        it("should round trip special numbers", function()
            local r = roundtrip({ math.huge, -math.huge, 0/0, 2^53, -1e-300, 1/3 })
            assert.are.equal(math.huge, r[1])
            assert.are.equal(-math.huge, r[2])
            assert.are_not.equal(r[3], r[3])
            assert.are.equal(2^53, r[4])
            assert.are.equal(-1e-300, r[5])
            assert.are.equal(1/3, r[6])
        end)

        it("should round trip sparse arrays", function()
            local r = roundtrip({ 1, nil, 3, nil, nil, 6 })
            assert.are.same({ [1] = 1, [3] = 3, [6] = 6 }, r)
        end)

        it("should restore self and shared references", function()
            local shared = { "shared" }
            local t = { a = shared, b = shared }
            t.self = t
            t.list = { t, shared }
            local r = roundtrip(t)
            assert.are.equal(r, r.self)
            assert.are.equal(r, r.list[1])
            assert.are.equal(r.a, r.b)
            assert.are.equal(r.a, r.list[2])
            assert.are.same({ "shared" }, r.a)
        end)

        it("should restore table keys", function()
            local key = { id = 1 }
            local r = roundtrip({ [key] = "value", other = key })
            assert.are.equal("value", r[r.other])
            assert.are.same({ id = 1 }, r.other)
        end)

        it("should restore tables only used as keys", function()
            local r = roundtrip({ [{ id = 2 }] = "first", [{ id = 3 }] = "second" })
            local found = {}
            for k, v in pairs(r) do
                assert.are.equal("table", type(k))
                found[k.id] = v
            end
            assert.are.same({ [2] = "first", [3] = "second" }, found)
        end)

        it("should only run serialized functions in unsafe mode", function()
            local double = function(a) return a * 2 end
            local dumped = serpent.dump({ f = double })
            local ok, err = serpent.load(dumped)
            assert.is_false(ok)
            assert.truthy(err:find("cannot call functions", 1, true))
            local res
            ok, res = serpent.load(dumped, { safe = false })
            assert.is_true(ok)
            assert.are.equal(42, res.f(21))
        end)

        it("should not let data call functions or reach globals in safe mode", function()
            local ok, err = serpent.load("{os.exit()}")
            assert.is_false(ok)
            assert.truthy(err:find("cannot call functions", 1, true))
            ok, err = serpent.load("{print('x')}")
            assert.is_false(ok)
            -- globals are not reachable: names resolve to the sandbox itself
            assert.truthy(err:find("cannot call functions", 1, true))
            local res
            ok, res = serpent.load("{a = os, b = io}")
            assert.is_true(ok)
            assert.are_not.equal(os, res.a)
            assert.are_not.equal(io, res.b)
            -- unsafe mode resolves real globals
            ok, res = serpent.load("{a = math.pi}", { safe = false })
            assert.is_true(ok)
            assert.are.equal(math.pi, res.a)
        end)

        it("should load statements as well as expressions", function()
            local ok, res = serpent.load("do local _ = {1, 2}; return _; end")
            assert.is_true(ok)
            assert.are.same({ 1, 2 }, res)
            ok, res = serpent.load("{1, 2}")
            assert.is_true(ok)
            assert.are.same({ 1, 2 }, res)
        end)

        it("should report syntax errors", function()
            for _, data in ipairs({ "{", "{1,,2}", "\0\1\2", "return return" }) do
                local f, err = serpent.load(data)
                assert.is_nil(f)
                assert.are.equal("string", type(err))
            end
            -- truncated dump
            local dumped = serpent.dump({ a = { 1, 2, 3 }, b = "text" })
            local f, err = serpent.load(dumped:sub(1, #dumped - 10))
            assert.is_nil(f)
            assert.are.equal("string", type(err))
        end)
    end)
end)
