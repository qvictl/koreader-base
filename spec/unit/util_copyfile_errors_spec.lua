local ffi = require("ffi")
local util = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

-- These Linux-only limits are changed only in a disposable subprocess.
if ffi.os == "Linux" then
    ffi.cdef[[
        struct copyfile_test_rlimit { unsigned long current; unsigned long maximum; };
        int setrlimit(int resource, const void *rlim);
        void (*signal(int sig, void (*handler)(int)))(int);
    ]]
end

local function write(path, bytes)
    local file = assert(io.open(path, "wb"))
    assert(file:write(bytes))
    assert(file:close())
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local bytes = file:read("*a")
    assert(file:close())
    return bytes
end

local function wrap(file)
    return {
        read = function(_, ...) return file:read(...) end,
        write = function(_, ...) return file:write(...) end,
        close = function() return file:close() end,
    }
end

describe("copyFile failure reporting", function()
    local root, source, target, saved_open, saved_attributes, open_stub
    local bytes = string.rep("source bytes\000", 2000)

    before_each(function()
        root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        source, target = root .. "/source", root .. "/target"
        write(source, bytes)
        saved_open, saved_attributes = io.open, lfs.attributes
    end)

    after_each(function()
        if open_stub then open_stub:revert(); open_stub = nil end
        lfs.attributes = saved_attributes
        util.purgeDir(root)
    end)

    it("keeps the nil-on-success contract for multi-chunk and empty files", function()
        assert.is_nil(util.copyFile(source, target))
        assert.are.equal(bytes, read(target))
        write(source, "")
        assert.is_nil(util.copyFile(source, target))
        assert.are.equal("", read(target))
    end)

    it("does not touch an existing destination when source open fails", function()
        write(target, "existing destination")
        assert.is_string(util.copyFile(root .. "/missing", target))
        assert.are.equal("existing destination", read(target))
    end)

    it("closes its source when destination open fails", function()
        assert(lfs.mkdir(target))
        local source_handle
        open_stub = stub(io, "open", function(path, mode)
            local file, err = saved_open(path, mode)
            if path == source then source_handle = file end
            return file, err
        end)
        assert.is_string(util.copyFile(source, target))
        assert.are.equal("closed file", io.type(source_handle))
        assert.are.equal("directory", lfs.attributes(target, "mode"))
        open_stub:revert(); open_stub = nil
        assert.are.equal(bytes, read(source))
    end)

    for _, failure in ipairs({ "read", "write", "source close", "target close" }) do
        it("reports " .. failure .. " failure, closes both streams and removes the partial copy", function()
            local source_handle, target_handle
            local read_count = 0
            open_stub = stub(io, "open", function(path, mode)
                local file, err = saved_open(path, mode)
                if not file then return nil, err end
                local stream = wrap(file)
                if path == source then
                    source_handle = file
                    if failure == "read" then
                        stream.read = function(_, count)
                            read_count = read_count + 1
                            if read_count == 2 then return nil, "read failure" end
                            return file:read(count)
                        end
                    elseif failure == "source close" then
                        stream.close = function()
                            assert(file:close())
                            return nil, "source close failure"
                        end
                    end
                elseif path == target then
                    target_handle = file
                    if failure == "write" then
                        stream.write = function(_, chunk)
                            assert(file:write(chunk:sub(1, 17)))
                            return nil, "write failure"
                        end
                    elseif failure == "target close" then
                        stream.close = function()
                            assert(file:close())
                            return nil, "target close failure"
                        end
                    end
                end
                return stream
            end)
            assert.are.equal(failure .. " failure", util.copyFile(source, target))
            assert.are.equal("closed file", io.type(source_handle))
            assert.are.equal("closed file", io.type(target_handle))
            assert.is_nil(lfs.attributes(target))
            open_stub:revert(); open_stub = nil
            assert.are.equal(bytes, read(source))
        end)
    end

    it("does not unlink a special destination on a reported I/O failure", function()
        -- No device is modified: model its file type around an owned real file.
        open_stub = stub(io, "open", function(path, mode)
            local file, err = saved_open(path, mode)
            if not file or path ~= target then return file, err end
            local stream = wrap(file)
            stream.write = function() return nil, "special target failure" end
            return stream
        end)
        lfs.attributes = function(path, attribute)
            if path == target and attribute == "mode" then return "char device" end
            return saved_attributes(path, attribute)
        end
        assert.are.equal("special target failure", util.copyFile(source, target))
        assert.are.equal("file", saved_attributes(target, "mode"))
    end)

    it("distinguishes a real source-directory read error from EOF on Linux", function()
        if ffi.os ~= "Linux" then pending("Linux directory read semantics") end
        assert(lfs.mkdir(root .. "/directory"))
        assert.is_string(util.copyFile(root .. "/directory", target))
        assert.is_nil(lfs.attributes(target))
    end)

    for _, case in ipairs({ { "write", 16384 }, { "close", 1024 } }) do
        it("reports a real kernel " .. case[1] .. " failure after destination creation", function()
            if ffi.os ~= "Linux" then pending("requires Linux RLIMIT_FSIZE") end
            local contents = string.rep("x", case[2])
            write(source, contents)
            local pid, fd = util.runInSubProcess(function(_, output)
                local limit = ffi.new("struct copyfile_test_rlimit", { 0, 0 })
                assert(ffi.C.setrlimit(1, limit) == 0) -- RLIMIT_FSIZE; child only
                ffi.C.signal(25, ffi.cast("void (*)(int)", 1)) -- ignore SIGXFSZ
                -- Independently verify which real stdio operation fails at this size.
                local probe = assert(io.open(target, "wb"))
                local wrote = probe:write(contents)
                local closed = probe:close()
                if case[1] == "write" then
                    assert(not wrote)
                else
                    assert(wrote and not closed)
                end
                assert(os.remove(target))
                local err = util.copyFile(source, target)
                assert(type(err) == "string")
                assert(lfs.attributes(target) == nil)
                assert(util.writeToFD(output, "reported", true))
            end, true)
            assert.is_number(pid)
            -- Bounded wait before reading the pipe; a broken child cannot hang CI.
            local done
            for _ = 1, 200 do
                if util.isSubProcessDone(pid) then done = true; break end
                util.usleep(25000)
            end
            if not done then
                ffi.C.close(fd)
                util.terminateSubProcess(pid)
                for _ = 1, 200 do
                    if util.isSubProcessDone(pid) then break end
                    util.usleep(25000)
                end
            end
            assert.is_true(done)
            local result = util.readAllFromFD(fd)
            assert.are.equal("reported", result)
            assert.are.equal(contents, read(source))
            assert.is_nil(lfs.attributes(target))
        end)
    end
end)
