local lfs = require("libs/libkoreader-lfs")

describe("Archiver fixes", function()
    local Archiver, tmp

    setup(function()
        Archiver = require("ffi/archiver")
    end)

    before_each(function()
        tmp = os.tmpname()
        os.remove(tmp)
        assert(lfs.mkdir(tmp))
    end)

    after_each(function()
        for _, path in ipairs({ "/src/a.txt", "/out/a.txt", "/out/mem.txt", "/a.zip", "/tree.zip" }) do
            os.remove(tmp .. path)
        end
        lfs.rmdir(tmp .. "/out")
        lfs.rmdir(tmp .. "/src")
        lfs.rmdir(tmp)
    end)

    local function make_zip()
        local w = Archiver.Writer:new{}
        assert.is_true(w:open(tmp .. "/a.zip"))
        assert.is_true(w:addFileFromMemory("mem.txt", "from memory"))
        assert.is_true(w:addFileFromMemory("other.txt", "other"))
        w:close()
        return tmp .. "/a.zip"
    end

    it("should give files added from memory rw-r--r-- permissions", function()
        local r = Archiver.Reader:new()
        assert.is_true(r:open(make_zip()))
        r:next()
        assert.is_true(r:extractToPath("mem.txt", tmp .. "/out/mem.txt"))
        r:close()
        assert.are.equal("rw-r--r--", lfs.attributes(tmp .. "/out/mem.txt", "permissions"))
        local f = assert(io.open(tmp .. "/out/mem.txt", "rb"))
        assert.are.equal("from memory", f:read("*a"))
        f:close()
    end)

    it("should be reusable after close()", function()
        local path = make_zip()
        local r = Archiver.Reader:new()
        assert.is_true(r:open(path))
        assert.are.equal("mem.txt", r:next().path)
        r:close()
        assert.is_true(r:open(path))
        local paths = {}
        for entry in r:iterate() do
            table.insert(paths, entry.path)
        end
        assert.are.same({ "mem.txt", "other.txt" }, paths)
        assert.are.equal(2, r.size)
        r:close()
    end)

    it("should seek after close(true)", function()
        local r = Archiver.Reader:new()
        assert.is_true(r:open(make_zip()))
        for _ in r:iterate() do end
        r:close(true)
        assert.are.equal("other", r:extractToMemory("other.txt"))
        assert.are.equal("from memory", r:extractToMemory("mem.txt"))
        r:close()
    end)

    it("should report addPath success", function()
        assert(lfs.mkdir(tmp .. "/src"))
        local f = assert(io.open(tmp .. "/src/a.txt", "wb"))
        f:write("alpha")
        f:close()
        local w = Archiver.Writer:new{}
        assert.is_true(w:open(tmp .. "/tree.zip"))
        assert.is_true(w:addPath("root", tmp .. "/src", true))
        assert.is_true(w:addPath("single.txt", tmp .. "/src/a.txt"))
        assert.is_false(w:addPath("missing", tmp .. "/src/missing"))
        w:close()
        local r = Archiver.Reader:new()
        assert.is_true(r:open(tmp .. "/tree.zip"))
        local paths = {}
        for entry in r:iterate() do
            table.insert(paths, entry.path)
        end
        r:close()
        assert.are.same({ "root/", "root/a.txt", "single.txt" }, paths)
    end)
end)
