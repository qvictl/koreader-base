local lfs = require("libs/libkoreader-lfs")

local data_dir = "spec/base/unit/data/"

local function rm_rf(path)
    local attr = lfs.symlinkattributes(path)
    if not attr then
        return
    end
    if attr.mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                rm_rf(path .. "/" .. name)
            end
        end
        lfs.rmdir(path)
    else
        os.remove(path)
    end
end

local function write_file(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

describe("Archiver module", function()
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
        rm_rf(tmp)
    end)

    -- Create an archive with the given {path, content} files.
    local function make_archive(path, files, opts)
        opts = opts or {}
        local w = Archiver.Writer:new{}
        assert.is_true(w:open(path, opts.format))
        if opts.compression then
            assert.is_true(w:setZipCompression(opts.compression))
        end
        for _, file in ipairs(files) do
            assert.is_true(w:addFileFromMemory(file[1], file[2], opts.mtime))
        end
        w:close()
        return path
    end

    -- List an archive: {path = {mode, size}}, plus the paths in order.
    local function list(path)
        local r = Archiver.Reader:new()
        assert.is_true(r:open(path))
        local entries, order = {}, {}
        for entry in r:iterate() do
            entries[entry.path] = { entry.mode, tonumber(entry.size) }
            table.insert(order, entry.path)
        end
        assert.is_nil(r.err)
        r:close()
        return entries, order
    end

    describe("Writer", function()
        it("should write zip archives readable back from memory", function()
            local binary = {}
            for i = 0, 255 do
                binary[#binary + 1] = string.char(i)
            end
            binary = table.concat(binary):rep(40)
            local files = {
                { "mimetype", "application/epub+zip" },
                { "OEBPS/content.opf", "<package/>" },
                { "OEBPS/image.bin", binary },
                { "empty.txt", "" },
            }
            for _, compression in ipairs({ "store", "deflate" }) do
                local path = make_archive(tmp .. "/book_" .. compression .. ".epub", files, { compression = compression })
                local r = Archiver.Reader:new()
                assert.is_true(r:open(path))
                local order = {}
                for entry in r:iterate() do
                    table.insert(order, entry.path)
                    assert.are.equal("file", entry.mode)
                end
                assert.are.same({ "mimetype", "OEBPS/content.opf", "OEBPS/image.bin", "empty.txt" }, order)
                for _, file in ipairs(files) do
                    assert.are.equal(#file[2], tonumber(r.entries[file[1]].size))
                    assert.are.equal(file[2], r:extractToMemory(file[1]))
                end
                r:close()
            end
            -- stored data is not compressed
            local stored = read_file(tmp .. "/book_store.epub")
            local deflated = read_file(tmp .. "/book_deflate.epub")
            assert.truthy(stored:find("application/epub+zip", 1, true))
            assert.is_true(#deflated < #stored)
        end)

        it("should pick the format from the extension or the explicit argument", function()
            local files = { { "dir/file.txt", "hello" } }
            for _, name in ipairs({ "a.zip", "a.epub", "a.tar", "a.tar.gz", "a.tgz", "a.targz", "a.tar.zst", "a.tzst", "a.cpio" }) do
                local entries = list(make_archive(tmp .. "/" .. name, files))
                assert.are.same({ "file", 5 }, entries["dir/file.txt"], name)
            end
            -- explicit format, extension ignored
            local path = make_archive(tmp .. "/noext", files, { format = "tgz" })
            assert.are.same({ "file", 5 }, list(path)["dir/file.txt"])
            -- it really is a gzip stream
            assert.are.equal("\31\139", read_file(path):sub(1, 2))
            assert.are.equal("PK", read_file(tmp .. "/a.zip"):sub(1, 2))
        end)

        it("should report unsupported formats and filters", function()
            local w = Archiver.Writer:new{}
            assert.is_nil(w:open(tmp .. "/a.bogus"))
            assert.are.equal("No such format 'bogus'", w.err)
            assert.is_nil(w.archive)
            assert.is_nil(w:open(tmp .. "/a.tar.bogus"))
            assert.are.equal("No such filter 'bogus'", w.err)
            assert.is_nil(w:open(tmp .. "/a.zip", "bogus"))
            assert.are.equal("No such format 'bogus'", w.err)
            -- nothing written
            assert.is_nil(read_file(tmp .. "/a.bogus"))
        end)

        it("should report unwritable destinations", function()
            local w = Archiver.Writer:new{}
            assert.is_nil(w:open(tmp .. "/missing/dir/a.zip"))
            assert.is_string(w.err)
            assert.is_nil(w.archive)
            -- a failed open turns the other methods into no-ops
            assert.is_nil(w:addFileFromMemory("x", "y"))
            assert.is_nil(w:setZipCompression("store"))
            assert.is_nil(w:addPath("x", tmp))
            w:close()
        end)

        it("should validate the zip compression method", function()
            local w = Archiver.Writer:new{}
            assert.is_true(w:open(tmp .. "/a.zip"))
            assert.is_nil(w:setZipCompression("lzma"))
            assert.are.equal("unsuported method", w.err)
            assert.is_true(w:setZipCompression("deflate"))
            assert.is_nil(w.err)
            w:close()
            -- only meaningful for zip
            assert.is_true(w:open(tmp .. "/a.tar"))
            assert.is_nil(w:setZipCompression("store"))
            assert.truthy(w.err:find("zip format", 1, true))
            w:close()
        end)

        it("should refuse to write after close", function()
            local w = Archiver.Writer:new{}
            assert.is_true(w:open(tmp .. "/a.zip"))
            assert.is_true(w:addFileFromMemory("one", "1"))
            w:close()
            assert.is_nil(w:addFileFromMemory("two", "2"))
            local _, order = list(tmp .. "/a.zip")
            assert.are.same({ "one" }, order)
        end)

        it("should produce identical archives with a fixed mtime", function()
            local files = { { "a.txt", "aaa" }, { "b/c.txt", "ccc" } }
            make_archive(tmp .. "/1.zip", files, { mtime = 1000000000 })
            make_archive(tmp .. "/2.zip", files, { mtime = 1000000000 })
            assert.are.equal(read_file(tmp .. "/1.zip"), read_file(tmp .. "/2.zip"))
        end)

        describe("addPath", function()
            local src

            before_each(function()
                src = tmp .. "/src"
                assert(lfs.mkdir(src))
                assert(lfs.mkdir(src .. "/sub"))
                write_file(src .. "/a.txt", "alpha")
                write_file(src .. "/sub/b.txt", string.rep("beta ", 20000))
                assert(lfs.link("a.txt", src .. "/link.txt", true))
            end)

            it("should add a directory tree recursively", function()
                local w = Archiver.Writer:new{}
                assert.is_true(w:open(tmp .. "/tree.tar"))
                w:addPath("root", src, true, 0)
                assert.is_nil(w.err)
                -- the disk reader is reused
                w:addPath("again", src .. "/a.txt")
                assert.is_nil(w.err)
                w:close()
                local entries = list(tmp .. "/tree.tar")
                assert.are.same({
                    ["root/"] = { "directory", 0 },
                    ["root/a.txt"] = { "file", 5 },
                    ["root/link.txt"] = { "link", 0 },
                    ["root/sub/"] = { "directory", 0 },
                    ["root/sub/b.txt"] = { "file", 100000 },
                    ["again"] = { "file", 5 },
                }, entries)
                local r = Archiver.Reader:new()
                assert.is_true(r:open(tmp .. "/tree.tar"))
                for _ in r:iterate() do end
                assert.are.equal(string.rep("beta ", 20000), r:extractToMemory("root/sub/b.txt"))
                assert.are.equal("alpha", r:extractToMemory("again"))
                -- links and directories have no content to extract
                assert.is_nil(r:extractToMemory("root/link.txt"))
                assert.is_nil(r:extractToMemory("root/sub/"))
                r:close()
            end)

            it("should only add the root when not recursive", function()
                local w = Archiver.Writer:new{}
                assert.is_true(w:open(tmp .. "/flat.zip"))
                w:addPath("root", src, false)
                w:close()
                local entries, order = list(tmp .. "/flat.zip")
                assert.are.same({ "root/" }, order)
                assert.are.equal("directory", entries["root/"][1])
            end)

            it("should report missing paths", function()
                local w = Archiver.Writer:new{}
                assert.is_true(w:open(tmp .. "/missing.zip"))
                assert.is_false(w:addPath("x", tmp .. "/does_not_exist", true))
                assert.truthy(w.err:find("does_not_exist", 1, true))
                -- the writer is still usable
                assert.is_true(w:addFileFromMemory("ok.txt", "ok"))
                w:close()
                local _, order = list(tmp .. "/missing.zip")
                assert.are.same({ "ok.txt" }, order)
            end)
        end)
    end)

    describe("Reader", function()
        local archive

        before_each(function()
            -- NOTE: built from files on disk, so that extracted files get sane permissions.
            assert(lfs.mkdir(tmp .. "/src"))
            local w = Archiver.Writer:new{}
            assert.is_true(w:open(tmp .. "/test.zip"))
            for _, file in ipairs({
                { "first.txt", "1st" },
                { "dir/second.txt", "2nd" },
                { "third.txt", string.rep("3", 10000) },
            }) do
                local src = tmp .. "/src/" .. file[1]:gsub("/", "_")
                write_file(src, file[2])
                w:addPath(file[1], src)
                assert.is_nil(w.err)
            end
            w:close()
            archive = tmp .. "/test.zip"
        end)

        it("should do nothing without a path", function()
            local r = Archiver.Reader:new()
            assert.is_nil(r:open())
            assert.is_nil(r.err)
            assert.is_nil(r:next())
        end)

        it("should report missing files", function()
            local r = Archiver.Reader:new()
            assert.is_nil(r:open(tmp .. "/nope.zip"))
            assert.truthy(r.err:find("Failed to open", 1, true))
            assert.is_nil(r:next())
            assert.is_nil(r.err)
        end)

        it("should report files that are not archives", function()
            write_file(tmp .. "/garbage.zip", "this is not an archive at all, just some text")
            local r = Archiver.Reader:new()
            assert.is_nil(r:open(tmp .. "/garbage.zip"))
            assert.are.equal("Unrecognized archive format", r.err)
        end)

        it("should report truncated compressed archives", function()
            make_archive(tmp .. "/big.tar.gz", { { "a.txt", string.rep("A", 50000) } })
            local data = read_file(tmp .. "/big.tar.gz")
            write_file(tmp .. "/cut.tar.gz", data:sub(1, math.floor(#data / 2)))
            local r = Archiver.Reader:new()
            assert.is_nil(r:open(tmp .. "/cut.tar.gz"))
            assert.are.equal("truncated gzip input", r.err)
        end)

        it("should report truncated zip archives while listing", function()
            make_archive(tmp .. "/big.zip", {
                { "a.txt", string.rep("A", 5000) },
                { "b.txt", string.rep("B", 5000) },
            }, { compression = "store" })
            local data = read_file(tmp .. "/big.zip")
            write_file(tmp .. "/cut.zip", data:sub(1, 3000))
            local r = Archiver.Reader:new()
            assert.is_true(r:open(tmp .. "/cut.zip"))
            local paths = {}
            for entry in r:iterate() do
                table.insert(paths, entry.path)
            end
            -- the first local header is readable, then the data is missing
            assert.are.same({ "a.txt" }, paths)
            assert.are.equal("Truncated ZIP file data", r.err)
            r:close()
        end)

        it("should list entries with their metadata", function()
            local r = Archiver.Reader:new()
            assert.is_true(r:open(archive))
            local entries = {}
            for entry in r:iterate() do
                table.insert(entries, { entry.path, entry.mode, tonumber(entry.size), entry.index })
            end
            assert.are.same({
                { "first.txt", "file", 3, 1 },
                { "dir/second.txt", "file", 3, 2 },
                { "third.txt", "file", 10000, 3 },
            }, entries)
            assert.are.equal(3, r.size)
            -- entries are indexed by position and by path
            assert.are.equal(r.entries[2], r.entries["dir/second.txt"])
            -- iterating again restarts from the beginning, reusing the same entries
            local first
            for entry in r:iterate() do
                first = first or entry
            end
            assert.are.equal(r.entries[1], first)
            assert.are.equal(3, r.size)
            r:close()
            assert.are.same({}, r.entries)
            assert.is_nil(r.filepath)
        end)

        it("should continue from the current position with keep_pos", function()
            local r = Archiver.Reader:new()
            assert.is_true(r:open(archive))
            assert.are.equal("first.txt", r:next().path)
            local rest = {}
            for entry in r:iterate(true) do
                table.insert(rest, entry.path)
            end
            assert.are.same({ "dir/second.txt", "third.txt" }, rest)
            r:close()
        end)

        it("should extract entries to memory in any order, repeatedly", function()
            local r = Archiver.Reader:new()
            assert.is_true(r:open(archive))
            for _ in r:iterate() do end
            assert.are.equal(string.rep("3", 10000), r:extractToMemory("third.txt"))
            -- going backwards reopens the archive
            assert.are.equal("1st", r:extractToMemory("first.txt"))
            -- the same entry twice: its data can only be consumed once per pass
            assert.are.equal("1st", r:extractToMemory("first.txt"))
            -- by index
            assert.are.equal("2nd", r:extractToMemory(2))
            assert.are.equal("2nd", r:extractToMemory("dir/second.txt"))
            -- unknown entries
            assert.is_nil(r:extractToMemory("nope.txt"))
            assert.is_nil(r:extractToMemory(42))
            r:close()
        end)

        it("should only know about entries already listed", function()
            local r = Archiver.Reader:new()
            assert.is_true(r:open(archive))
            assert.is_nil(r:extractToMemory("third.txt"))
            r:next()
            assert.are.equal("1st", r:extractToMemory("first.txt"))
            r:close()
        end)

        it("should extract entries to a path", function()
            local r = Archiver.Reader:new()
            assert.is_true(r:open(archive))
            for _ in r:iterate() do end
            assert.is_true(r:extractToPath("dir/second.txt", tmp .. "/out/nested/second.txt"))
            assert.are.equal("2nd", read_file(tmp .. "/out/nested/second.txt"))
            assert.is_true(r:extractToPath("first.txt", tmp .. "/out/first.txt"))
            assert.are.equal("1st", read_file(tmp .. "/out/first.txt"))
            local ok, err = r:extractToPath("nope.txt", tmp .. "/out/nope.txt")
            assert.is_false(ok)
            assert.are.equal("no such path", err)
            assert.is_nil(read_file(tmp .. "/out/nope.txt"))
            r:close()
        end)

        it("should extract entries relative to the current directory by default", function()
            local r = Archiver.Reader:new()
            assert.is_true(r:open(archive))
            for _ in r:iterate() do end
            local cwd = lfs.currentdir()
            assert(lfs.mkdir(tmp .. "/cwd"))
            assert(lfs.chdir(tmp .. "/cwd"))
            local ok = pcall(r.extractToPath, r, "dir/second.txt")
            lfs.chdir(cwd)
            assert.is_true(ok)
            assert.are.equal("2nd", read_file(tmp .. "/cwd/dir/second.txt"))
            r:close()
        end)

        it("should refuse to extract outside of the destination with ..", function()
            local r = Archiver.Reader:new()
            assert.is_true(r:open(archive))
            for _ in r:iterate() do end
            assert.is_false(r:extractToPath("first.txt", tmp .. "/out/../escaped.txt"))
            assert.is_string(r.err)
            assert.is_nil(read_file(tmp .. "/escaped.txt"))
            r:close()
        end)

        it("should keep the listing with close(true)", function()
            local r = Archiver.Reader:new()
            assert.is_true(r:open(archive))
            for _ in r:iterate() do end
            local listed = r.entries[2]
            r:close(true)
            assert.are.equal(3, r.size)
            assert.are.equal(archive, r.filepath)
            assert.is_nil(r:next())
            -- reopening reuses the listing
            assert.is_true(r:open(r.filepath))
            assert.are.equal(r.entries[1], r:next())
            assert.are.equal(listed, r:next())
            assert.are.equal("2nd", r:extractToMemory("dir/second.txt"))
            assert.are.equal(3, r.size)
            r:close()
        end)

        it("should handle encrypted zip entries", function()
            local r = Archiver.Reader:new()
            assert.is_true(r:open(data_dir .. "encrypted-none.zip"))
            local entry = r:next()
            assert.are.equal("file", entry.mode)
            local content = r:extractToMemory(entry.path)
            assert.are.equal(tonumber(entry.size), #content)
            assert.are.equal("\137PNG", content:sub(1, 4))
            r:close()
            for _, name in ipairs({ "encrypted-aes.zip", "encrypted-plain.zip" }) do
                r = Archiver.Reader:new()
                assert.is_true(r:open(data_dir .. name))
                entry = r:next()
                assert.is_nil(r:extractToMemory(entry.path))
                assert.are.equal("Passphrase required for this entry", r.err)
                r:close()
            end
        end)
    end)
end)
