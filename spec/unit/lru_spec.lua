-- ffi/lru backs the frontend caches (rendered pages, tiles, glyphs...): on a Kindle, these
-- are what keeps memory in check, so eviction order and size accounting must be exact.
local lru = require("ffi/lru")

local function keys(cache)
    local t = {}
    for k in cache:pairs() do
        table.insert(t, k)
    end
    return t
end

-- A value with an onFree() method, recording its frees in a shared log.
local function freeable(log, name)
    return {
        name = name,
        onFree = function(self) table.insert(log, self.name) end,
    }
end

describe("lru", function()
    describe("new", function()
        it("should validate its limits", function()
            assert.has_error(function() lru.new(0) end, "max_size must be >= 1")
            assert.has_error(function() lru.new(1, 0) end, "max_bytes must be >= 1")
            assert.has_no.errors(function() lru.new(1, 1) end)
        end)
    end)

    describe("slot-bound cache", function()
        it("should get and set values", function()
            local cache = lru.new(3)
            assert.is_nil(cache:get("a"))
            cache:set("a", 1)
            cache:set("b", false)
            assert.are.equal(1, cache:get("a"))
            -- (false is a value)
            assert.is_false(cache:get("b"))
            assert.are.equal(2, cache:used_slots())
            assert.are.equal(3, cache:total_slots())
            assert.are.equal(0, cache:used_size())
            assert.is_nil(cache:total_size())
        end)

        it("should evict the least recently used entry", function()
            local cache = lru.new(3)
            cache:set("a", 1)
            cache:set("b", 2)
            cache:set("c", 3)
            assert.are.same({ "c", "b", "a" }, keys(cache))
            -- Reading "a" makes it the most recent one, so "b" goes first.
            assert.are.equal(1, cache:get("a"))
            assert.are.same({ "a", "c", "b" }, keys(cache))
            cache:set("d", 4)
            assert.is_nil(cache:get("b"))
            assert.are.same({ "d", "a", "c" }, keys(cache))
            assert.are.equal(3, cache:used_slots())
        end)

        it("should replace an existing key without growing", function()
            local cache = lru.new(2)
            cache:set("a", 1)
            cache:set("b", 2)
            cache:set("a", 10)
            assert.are.equal(2, cache:used_slots())
            assert.are.equal(10, cache:get("a"))
            -- Replacing made "a" the most recent one.
            cache:set("c", 3)
            assert.is_nil(cache:get("b"))
            assert.are.same({ "c", "a" }, keys(cache))
        end)

        it("should delete entries, wherever they are in the list", function()
            local cache = lru.new(5)
            for i, k in ipairs({ "a", "b", "c", "d" }) do cache:set(k, i) end
            cache:delete("b") -- middle
            assert.are.same({ "d", "c", "a" }, keys(cache))
            cache:delete("a") -- oldest
            assert.are.same({ "d", "c" }, keys(cache))
            cache:delete("d") -- newest
            assert.are.same({ "c" }, keys(cache))
            cache:set("c", nil) -- only one
            assert.are.same({}, keys(cache))
            assert.are.equal(0, cache:used_slots())
            -- Deleting a missing key is fine, a nil key is not.
            assert.has_no.errors(function() cache:delete("missing") end)
            assert.has_error(function() cache:set(nil, nil) end, "Key may not be nil")
            -- Still usable.
            cache:set("e", 5)
            assert.are.same({ "e" }, keys(cache))
        end)

        it("should iterate key/value pairs, newest first", function()
            local cache = lru.new(3)
            cache:set(1, "one")
            cache:set(2, "two")
            local seen = {}
            for k, v in cache:pairs() do
                table.insert(seen, k .. "=" .. v)
            end
            assert.are.same({ "2=two", "1=one" }, seen)
            local n = 0
            for _ in lru.new(1):pairs() do n = n + 1 end
            assert.are.equal(0, n)
        end)

        it("should clear and chop", function()
            local cache = lru.new(10)
            for i = 1, 5 do cache:set(i, i) end
            -- chop evicts the oldest half.
            cache:chop()
            assert.are.same({ 5, 4 }, keys(cache))
            cache:clear()
            assert.are.equal(0, cache:used_slots())
            assert.are.same({}, keys(cache))
            -- Reusable after a clear.
            cache:set("x", 1)
            assert.are.equal(1, cache:get("x"))
        end)

        it("should resize its slots", function()
            local cache = lru.new(4)
            for i = 1, 4 do cache:set(i, i) end
            cache:resize_slots(4) -- no-op
            assert.are.equal(4, cache:used_slots())
            cache:resize_slots(2)
            assert.are.equal(2, cache:total_slots())
            assert.are.same({ 4, 3 }, keys(cache))
            cache:resize_slots(3)
            assert.are.equal(3, cache:total_slots())
            cache:set(5, 5)
            assert.are.same({ 5, 4, 3 }, keys(cache))
            assert.has_error(function() cache:resize_bytes(10) end, "Cannot resize a slot-bound cache")
        end)

        it("should call onFree on evicted, replaced, deleted and cleared values", function()
            local log = {}
            local cache = lru.new(2, nil, true)
            cache:set("a", freeable(log, "a1"))
            cache:set("b", freeable(log, "b"))
            cache:set("a", freeable(log, "a2")) -- replaced
            assert.are.same({ "a1" }, log)
            cache:set("c", freeable(log, "c")) -- evicts "b"
            assert.are.same({ "a1", "b" }, log)
            cache:delete("c")
            assert.are.same({ "a1", "b", "c" }, log)
            cache:set("d", freeable(log, "d"))
            cache:clear()
            table.sort(log)
            assert.are.same({ "a1", "a2", "b", "c", "d" }, log)
        end)
    end)

    describe("size-bound cache", function()
        it("should account for the size of its entries", function()
            local cache = lru.new(10, 100)
            cache:set("a", "A", 30)
            cache:set("b", "B", 50)
            assert.are.equal(80, cache:used_size())
            assert.are.equal(100, cache:total_size())
            -- Replacing an entry replaces its size.
            cache:set("a", "AA", 10)
            assert.are.equal(60, cache:used_size())
            cache:delete("b")
            assert.are.equal(10, cache:used_size())
            assert.are.equal(1, cache:used_slots())
        end)

        it("should evict the oldest entries until a new one fits", function()
            local cache = lru.new(10, 100)
            cache:set("a", 1, 40)
            cache:set("b", 2, 40)
            cache:set("c", 3, 10)
            cache:get("a")
            -- 90 used, 30 needed: "b" (the least recently used) is enough.
            cache:set("d", 4, 30)
            assert.are.same({ "d", "a", "c" }, keys(cache))
            assert.are.equal(80, cache:used_size())
            -- 80 used, 95 needed: everything goes.
            cache:set("e", 5, 95)
            assert.are.same({ "e" }, keys(cache))
            assert.are.equal(95, cache:used_size())
        end)

        it("should still honor the slot limit", function()
            local cache = lru.new(2, 1000)
            cache:set("a", 1, 1)
            cache:set("b", 2, 1)
            cache:set("c", 3, 1)
            assert.are.same({ "c", "b" }, keys(cache))
            assert.are.equal(2, cache:used_size())
        end)

        it("should refuse an entry larger than the whole cache", function()
            local cache = lru.new(10, 100)
            cache:set("a", 1, 10)
            assert.has_error(function() cache:set("big", 2, 101) end, "not enough storage for cache")
            -- (making room evicted everything first)
            assert.is_nil(cache:get("big"))
            assert.are.equal(0, cache:used_size())
        end)

        it("should resize its byte budget", function()
            local cache = lru.new(10, 100)
            for i = 1, 5 do cache:set(i, i, 20) end
            cache:resize_bytes(100) -- no-op
            assert.are.equal(5, cache:used_slots())
            cache:resize_bytes(50)
            assert.are.equal(50, cache:total_size())
            assert.are.same({ 5, 4 }, keys(cache))
            assert.are.equal(40, cache:used_size())
            cache:resize_bytes(200)
            assert.are.equal(200, cache:total_size())
            cache:set(6, 6, 150)
            assert.are.same({ 6, 5, 4 }, keys(cache))
            assert.are.equal(190, cache:used_size())
        end)

        it("should shrink its slots and keep its size accounting right", function()
            local cache = lru.new(5, 100)
            for i = 1, 5 do cache:set(i, i, i) end
            cache:resize_slots(2)
            assert.are.same({ 5, 4 }, keys(cache))
            assert.are.equal(9, cache:used_size())
            cache:chop()
            assert.are.same({ 5 }, keys(cache))
            assert.are.equal(5, cache:used_size())
            cache:clear()
            assert.are.equal(0, cache:used_size())
        end)

        it("should call onFree and keep its size accounting right", function()
            local log = {}
            local cache = lru.new(10, 100, true)
            cache:set("a", freeable(log, "a"), 60)
            cache:set("b", freeable(log, "b"), 30)
            cache:set("c", freeable(log, "c"), 30) -- evicts "a"
            assert.are.same({ "a" }, log)
            assert.are.equal(60, cache:used_size())
            cache:set("b", freeable(log, "b2"), 10) -- replaces "b"
            assert.are.same({ "a", "b" }, log)
            assert.are.equal(40, cache:used_size())
            cache:resize_bytes(15)
            assert.are.same({ "a", "b", "c" }, log)
            assert.are.equal(10, cache:used_size())
            cache:clear()
            assert.are.same({ "a", "b", "c", "b2" }, log)
            assert.are.equal(0, cache:used_size())
        end)
    end)
end)
