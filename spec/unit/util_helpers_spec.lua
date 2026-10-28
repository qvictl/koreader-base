-- ffi/util helpers that util_spec.lua does not cover: file syncing (settings/cache writes must
-- reach the storage before a Kindle suspends or loses power), sysfs writes, collation, etc.
local ffi = require("ffi")
local util = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local C = ffi.C

local function tmpDir()
    local dir = os.tmpname()
    os.remove(dir)
    assert(lfs.mkdir(dir))
    return dir
end

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

describe("util helpers", function()
    local dir

    setup(function()
        dir = tmpDir()
    end)

    teardown(function()
        util.purgeDir(dir)
    end)

    describe("getTimestamp & getDuration", function()
        it("should return a fractional timestamp consistent with gettime", function()
            local sec = util.gettime()
            local ts = util.getTimestamp()
            assert.is_true(ts >= sec)
            assert.is_true(ts < sec + 2)
        end)

        it("should measure elapsed time", function()
            local start = util.getTimestamp()
            util.usleep(20000)
            local d = util.getDuration(start)
            assert.is_true(d >= 0.015)
            assert.is_true(d < 1)
        end)
    end)

    describe("strcoll", function()
        local orig_strcoll, orig_defaults

        setup(function()
            -- util.strcoll replaces itself on first use, according to the settings then.
            orig_strcoll = util.strcoll
            orig_defaults = rawget(_G, "G_defaults")
        end)

        teardown(function()
            util.strcoll = orig_strcoll
            rawset(_G, "G_defaults", orig_defaults)
        end)

        local function withSetting(case_insensitive)
            rawset(_G, "G_defaults", {
                readSetting = function(_, key)
                    if key == "DALPHA_SORT_CASE_INSENSITIVE" then return case_insensitive end
                end,
            })
            util.strcoll = orig_strcoll
        end

        it("should sort nil first", function()
            withSetting(false)
            assert.is_false(util.strcoll(nil, nil))
            assert.is_true(util.strcoll(nil, "a"))
            assert.is_false(util.strcoll("a", nil))
        end)

        it("should be case sensitive by default", function()
            withSetting(false)
            -- (C locale: byte order, uppercase first)
            assert.is_true(util.strcoll("B", "a"))
            assert.is_false(util.strcoll("a", "B"))
            assert.is_true(util.strcoll("abc", "abd"))
            assert.is_false(util.strcoll("abc", "abc"))
        end)

        it("should honor DALPHA_SORT_CASE_INSENSITIVE", function()
            withSetting(true)
            assert.is_false(util.strcoll("B", "a"))
            assert.is_true(util.strcoll("a", "B"))
            assert.is_false(util.strcoll("ABC", "abc"))
            assert.is_false(util.strcoll("abc", "ABC"))
        end)

        it("should be usable as a table.sort comparator", function()
            withSetting(true)
            local t = { "delta", "Charlie", "alpha", "Bravo" }
            table.sort(t, util.strcoll)
            assert.are.same({ "alpha", "Bravo", "Charlie", "delta" }, t)
        end)
    end)

    describe("realpath, basename & dirname", function()
        it("should resolve paths", function()
            local real = util.realpath(dir)
            assert.are.equal("/", real:sub(1, 1))
            assert.are.equal(real, util.realpath(dir .. "/./"))
            assert.is_nil(util.realpath(dir .. "/does/not/exist"))
        end)

        it("should split paths without modifying their input", function()
            local path = "/mnt/us/documents/book.epub"
            assert.are.equal("book.epub", util.basename(path))
            assert.are.equal("/mnt/us/documents", util.dirname(path))
            assert.are.equal("/mnt/us/documents/book.epub", path)
            assert.are.equal("documents", util.basename("/mnt/us/documents/"))
            -- (SUSv2: the root is its own basename)
            assert.are.equal("/", util.basename("/"))
            assert.are.equal("/", util.basename("//"))
            assert.are.equal(".", util.dirname("book.epub"))
            assert.are.equal("/", util.dirname("/book.epub"))
        end)
    end)

    describe("copyFile & purgeDir", function()
        it("should report a destination that cannot be created", function()
            local err = util.copyFile("spec/base/unit/data/simple.pdf", dir .. "/no/such/dir/out.pdf")
            assert.is.string(err)
            assert.truthy(err:find("No such file or directory", 1, true))
        end)

        it("should remove nested files and directories", function()
            local root = dir .. "/purge"
            assert(lfs.mkdir(root))
            assert(lfs.mkdir(root .. "/sub"))
            for _, p in ipairs({ root .. "/a.txt", root .. "/sub/b.txt" }) do
                local f = assert(io.open(p, "w"))
                f:write("x")
                f:close()
            end
            assert.is_true(util.purgeDir(root))
            assert.is_nil(lfs.attributes(root))
        end)
    end)

    describe("execute", function()
        it("should run a program and return its raw wait status", function()
            assert.are.equal(0, util.execute("/bin/sh", "-c", "exit 0"))
            -- (exit code in the second byte)
            assert.are.equal(3 * 256, util.execute("/bin/sh", "-c", "exit 3"))
        end)

        it("should pass the arguments", function()
            local out = dir .. "/exec.txt"
            assert.are.equal(0, util.execute("/bin/sh", "-c", 'printf "%s|%s" "$0" "$1" > "$2"', "a b", "c", out))
            assert.are.equal("a b|c", readFile(out))
        end)
    end)

    describe("getNonBlockingReadSize", function()
        it("should accept a raw fd", function()
            local pipe = ffi.new("int[2]")
            assert.are.equal(0, C.pipe(pipe))
            assert.are.equal(0, util.getNonBlockingReadSize(pipe[0]))
            assert.is_true(util.writeToFD(pipe[1], "abc"))
            assert.are.equal(3, util.getNonBlockingReadSize(pipe[0]))
            util.writeToFD(pipe[1], "", true)
            assert.are.equal("abc", util.readAllFromFD(pipe[0]))
        end)

        it("should return nil when unsupported", function()
            assert.is_nil(util.getNonBlockingReadSize(-1))
        end)
    end)

    describe("writeToSysfs", function()
        it("should write the value, coerced to a string", function()
            local path = dir .. "/knob"
            local f = assert(io.open(path, "w"))
            f:close()
            assert.is_true(util.writeToSysfs(42, path))
            assert.are.equal("42", readFile(path))
        end)

        it("should fail on a missing file, without creating it", function()
            local path = dir .. "/missing_knob"
            assert.is_nil(util.writeToSysfs("1", path))
            assert.is_nil(lfs.attributes(path))
        end)

        it("should report a failed write", function()
            if not lfs.attributes("/dev/full") then
                pending("no /dev/full")
                return
            end
            assert.is_false(util.writeToSysfs("1", "/dev/full"))
        end)
    end)

    describe("fsyncOpenedFile", function()
        it("should sync a lua file, flushing its buffers first", function()
            local path = dir .. "/sync.txt"
            local f = assert(io.open(path, "w"))
            f:write("buffered")
            assert.is_true(util.fsyncOpenedFile(f))
            -- The data reached the file before close.
            assert.are.equal("buffered", readFile(path))
            assert.is_true(util.fsyncOpenedFile(f, true))
            f:close()
        end)

        it("should sync a raw fd, and report errors", function()
            local fd = C.open(dir .. "/sync.txt", C.O_RDONLY)
            assert.is_true(fd >= 0)
            assert.is_true(util.fsyncOpenedFile(fd))
            assert.is_true(util.fsyncOpenedFile(fd, true))
            C.close(fd)
            local ok, err = util.fsyncOpenedFile(fd)
            assert.is_false(ok)
            assert.is.string(err)
        end)
    end)

    describe("fsyncDirectory", function()
        it("should sync a directory, or the directory of a file", function()
            assert.is_true(util.fsyncDirectory(dir))
            local path = dir .. "/file_in_dir"
            local f = assert(io.open(path, "w"))
            f:close()
            assert.is_true(util.fsyncDirectory(path))
        end)

        it("should fail on a missing path", function()
            local ok, err = util.fsyncDirectory(dir .. "/missing")
            assert.is_false(ok)
            assert.is.string(err)
        end)
    end)

    describe("utf8charcode", function()
        it("should decode 1 to 4 byte sequences", function()
            assert.are.equal(65, util.utf8charcode("A"))
            assert.are.equal(0xE9, util.utf8charcode("é"))
            assert.are.equal(0x20AC, util.utf8charcode("€"))
            assert.are.equal(0x1F600, util.utf8charcode("\240\159\152\128"))
        end)

        it("should return nil for longer strings", function()
            assert.is_nil(util.utf8charcode("abcde"))
        end)
    end)

    describe("platform checks", function()
        it("should not detect Android or PocketBook here", function()
            assert.is_false(util.isAndroid())
            -- (cached)
            assert.is_false(util.isAndroid())
            assert.falsy(util.isPocketbook())
        end)

        it("should cache the SDL3 library lookup", function()
            local lib = util.loadSDL3()
            assert.are.equal(lib, util.loadSDL3())
        end)
    end)

    describe("idiv", function()
        it("should truncate toward zero", function()
            assert.are.equal(3, util.idiv(7, 2))
            assert.are.equal(-3, util.idiv(-7, 2))
            assert.are.equal(-3, util.idiv(7, -2))
            assert.are.equal(2, util.idiv(6, 3))
            assert.are.equal(0, util.idiv(0, 5))
        end)
    end)

    describe("orderedPairs", function()
        it("should iterate keys in sorted order, and clean up after itself", function()
            local t = { c = 3, a = 1, b = 2 }
            local keys, values = {}, {}
            for k, v in util.orderedPairs(t) do
                table.insert(keys, k)
                table.insert(values, v)
            end
            assert.are.same({ "a", "b", "c" }, keys)
            assert.are.same({ 1, 2, 3 }, values)
            assert.is_nil(t.__orderedIndex)
        end)

        it("should handle mixed key types", function()
            local t = { [10] = "ten", [2] = "two", x = "x", y = "y" }
            local keys = {}
            for k in util.orderedPairs(t) do
                table.insert(keys, tostring(k))
            end
            -- Same types compare natively, mixed ones as strings.
            assert.are.equal(4, #keys)
            local pos = {}
            for i, k in ipairs(keys) do pos[k] = i end
            assert.is_true(pos["2"] < pos["10"])
            assert.is_true(pos["10"] < pos["x"])
            assert.is_true(pos["x"] < pos["y"])
        end)

        it("should iterate an empty table", function()
            local n = 0
            for _ in util.orderedPairs({}) do n = n + 1 end
            assert.are.equal(0, n)
        end)
    end)

    describe("isExecutable", function()
        it("should tell executable files apart", function()
            assert.is_true(util.isExecutable("/bin/sh"))
            local path = dir .. "/not_exec"
            local f = assert(io.open(path, "w"))
            f:close()
            assert.is_false(util.isExecutable(path))
            -- Directories are not executable files.
            assert.is_false(util.isExecutable(dir))
            local ok, err = util.isExecutable(dir .. "/missing")
            assert.is_false(ok)
            assert.is.string(err)
        end)
    end)
end)
