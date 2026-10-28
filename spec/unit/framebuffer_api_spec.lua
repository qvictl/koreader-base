describe("Framebuffer API", function()
    local BB, Framebuffer, DummyFB

    setup(function()
        BB = require("ffi/blitbuffer")
        Framebuffer = require("ffi/framebuffer")
        DummyFB = require("ffi/framebuffer_dummy")
    end)

    local function make_device(caps)
        caps = caps or {}
        return {
            display_dpi = caps.dpi,
            screen = { fb_bpp = caps.bpp or 8 },
            canHWInvert = function() return caps.hw_invert or false end,
            canHWDither = function() return caps.hw_dither or false end,
            hasBGRFrameBuffer = function() return caps.bgr or false end,
        }
    end

    -- A minimal implementation with a bb of the given size.
    local function sized_fb(w, h, o)
        local Impl = Framebuffer:extend{
            init = function(self)
                self.bb = BB.new(w, h)
                self.bb:fill(BB.COLOR_WHITE)
                Framebuffer.init(self)
            end,
        }
        return Impl:new(o)
    end

    -- Record the arguments the given *Imp methods get called with.
    local function record(fb, ...)
        local calls = {}
        for _, name in ipairs({ ... }) do
            fb[name] = function(_, x, y, w, h, d)
                table.insert(calls, { name, x, y, w, h, d })
            end
        end
        return calls
    end

    local function pixel(bb, x, y)
        return bb:getPixel(x, y):getColor8().a
    end

    describe("initialization", function()
        it("should set up a portrait framebuffer", function()
            local fb = DummyFB:new{ device = make_device() }
            assert.are.same({ w = 600, h = 800 }, fb:getRawSize())
            assert.are.equal(600, fb:getWidth())
            assert.are.equal(800, fb:getHeight())
            assert.are.equal(600, fb:getScreenWidth())
            assert.are.equal(800, fb:getScreenHeight())
            assert.are.equal(fb.DEVICE_ROTATED_UPRIGHT, fb.native_rotation_mode)
            assert.are.equal(fb.DEVICE_ROTATED_UPRIGHT, fb:getRotationMode())
            assert.are.equal(0, fb.blitbuffer_rotation_mode)
            assert.are.equal("portrait", fb:getScreenMode())
            assert.are.equal("portrait", fb:getScreenOrientation())
            assert.are.equal(0, fb:getTouchRotation())
            assert.are.equal(0, fb:getHWRotation())
            assert.is_false(fb:getHWNightmode())
            assert.are.equal(fb.parent, DummyFB)
        end)

        it("should rotate landscape buffers when always portrait", function()
            local fb = sized_fb(800, 600, { is_always_portrait = true })
            assert.are.same({ w = 600, h = 800 }, fb.screen_size)
            -- the buffer is rotated 90° CCW
            assert.are.equal(3, fb.bb:getRotation())
            assert.are.equal(3, fb.blitbuffer_rotation_mode)
            assert.are.equal(600, fb:getWidth())
            assert.are.equal(800, fb:getHeight())
            assert.are.equal("portrait", fb:getScreenMode())
            -- rotation modes stay relative to the initial rotation
            fb:setRotationMode(fb.DEVICE_ROTATED_UPRIGHT)
            assert.are.equal(3, fb.bb:getRotation())
            fb:setRotationMode(fb.DEVICE_ROTATED_CLOCKWISE)
            assert.are.equal(2, fb.bb:getRotation())
            assert.are.equal("landscape", fb:getScreenMode())
        end)

        it("should not rotate portrait buffers when always portrait", function()
            local fb = sized_fb(600, 800, { is_always_portrait = true })
            assert.are.equal(0, fb.bb:getRotation())
            assert.are.same({ w = 600, h = 800 }, fb.screen_size)
        end)

        it("should refuse always portrait together with forced HW rotation", function()
            assert.has_error(function()
                sized_fb(800, 600, { is_always_portrait = true, forced_rotation = { 0, 1, 2, 3 } })
            end)
        end)

        it("should honour forced rotation mappings", function()
            local fb = DummyFB:new{ forced_rotation = { 3, 0, 1, 2, default = 1 } }
            assert.are.equal(1, fb.native_rotation_mode)
            assert.are.equal(1, fb:getRotationMode())
            assert.are.equal(0, fb:getCanonicalRotationMode(3))
            assert.are.equal(1, fb:getCanonicalRotationMode(0))
            assert.are.equal(3, fb:getCanonicalRotationMode(2))
            assert.is_nil(fb:getCanonicalRotationMode(7))
        end)
    end)

    describe("rotation", function()
        it("should rotate the buffer according to the rotation mode", function()
            local fb = DummyFB:new{}
            -- {mode, bb rotation, width, height, screen mode, orientation}
            for _, case in ipairs({
                { fb.DEVICE_ROTATED_CLOCKWISE, 3, 800, 600, "landscape", "landscape" },
                { fb.DEVICE_ROTATED_UPSIDE_DOWN, 2, 600, 800, "portrait", "portrait" },
                { fb.DEVICE_ROTATED_COUNTER_CLOCKWISE, 1, 800, 600, "landscape", "landscape" },
                { fb.DEVICE_ROTATED_UPRIGHT, 0, 600, 800, "portrait", "portrait" },
            }) do
                fb:setRotationMode(case[1])
                assert.are.equal(case[1], fb:getRotationMode())
                assert.are.equal(case[1], fb:getTouchRotation())
                assert.are.equal(case[2], fb.bb:getRotation())
                assert.are.equal(case[3], fb:getWidth())
                assert.are.equal(case[4], fb:getHeight())
                assert.are.equal(case[5], fb:getScreenMode())
                assert.are.equal(case[6], fb:getScreenOrientation())
                -- the physical screen size does not change
                assert.are.equal(600, fb:getScreenWidth())
                assert.are.equal(800, fb:getScreenHeight())
            end
        end)
    end)

    describe("refresh", function()
        it("should route every refresh type to the full refresh by default", function()
            local fb = DummyFB:new{}
            local calls = record(fb, "refreshFullImp")
            local methods = {
                "refreshFull", "refreshPartial", "refreshNoMergePartial", "refreshFlashPartial",
                "refreshUI", "refreshNoMergeUI", "refreshFlashUI", "refreshFast", "refreshA2",
            }
            for i, method in ipairs(methods) do
                fb[method](fb, i, i + 1, 10, 20, "dither")
            end
            assert.are.equal(#methods, #calls)
            for i, call in ipairs(calls) do
                assert.are.same({ "refreshFullImp", i, i + 1, 10, 20, "dither" }, call)
            end
        end)

        it("should route through the intermediate implementations", function()
            local fb = DummyFB:new{}
            local calls = record(fb, "refreshFullImp", "refreshPartialImp", "refreshUIImp", "refreshFastImp")
            fb:refreshNoMergePartial(0, 0, 1, 1)
            fb:refreshFlashPartial(0, 0, 1, 1)
            fb:refreshNoMergeUI(0, 0, 1, 1)
            fb:refreshFlashUI(0, 0, 1, 1)
            fb:refreshA2(0, 0, 1, 1)
            local names = {}
            for _, call in ipairs(calls) do
                table.insert(names, call[1])
            end
            assert.are.same({ "refreshPartialImp", "refreshFullImp", "refreshUIImp", "refreshFullImp", "refreshFastImp" }, names)
            local waited = false
            fb.refreshWaitForLastImp = function() waited = true end
            fb:refreshWaitForLast()
            assert.is_true(waited)
        end)

        it("should pass coordinates through unchanged without a viewport", function()
            local fb = DummyFB:new{}
            assert.are.same({ -5, 900, 10000, 3 }, { fb:calculateRealCoordinates(-5, 900, 10000, 3) })
        end)
    end)

    describe("viewport", function()
        it("should refuse viewports outside of the screen", function()
            local fb = DummyFB:new{}
            for _, vp in ipairs({
                { x = -1, y = 0, w = 10, h = 10 },
                { x = 601, y = 0, w = 0, h = 10 },
                { x = 0, y = -1, w = 10, h = 10 },
                { x = 0, y = 801, w = 10, h = 0 },
                { x = 0, y = 0, w = -1, h = 10 },
                { x = 100, y = 0, w = 501, h = 10 },
                { x = 0, y = 0, w = 10, h = -1 },
                { x = 0, y = 100, w = 10, h = 701 },
            }) do
                assert.has_error(function() fb:setViewport(vp) end, "fb:setViewport() bad viewport")
            end
            assert.is_nil(fb.viewport)
            assert.is_nil(fb.full_bb)
        end)

        it("should work on a sub-buffer and translate refresh coordinates", function()
            local fb = DummyFB:new{}
            local full = fb.bb
            full:paintRect(0, 0, 600, 800, BB.COLOR_BLACK)
            local calls = record(fb, "refreshFullImp")
            local vp = { x = 10, y = 20, w = 500, h = 700 }
            fb:setViewport(vp)
            assert.are.equal(full, fb.full_bb)
            assert.are.equal(500, fb:getWidth())
            assert.are.equal(700, fb:getHeight())
            -- the whole screen is blanked and refreshed
            assert.are.equal(0xFF, pixel(full, 0, 0))
            assert.are.same({ "refreshFullImp", 10, 20, 500, 700 }, calls[1])
            -- drawing in the viewport lands at the offset in the full buffer
            fb.bb:paintRect(0, 0, 1, 1, BB.COLOR_BLACK)
            assert.are.equal(0, pixel(full, 10, 20))
            assert.are.equal(0xFF, pixel(full, 9, 19))

            -- vx2 = 600 - 510 = 90, vy2 = 800 - 720 = 80
            for _, case in ipairs({
                { fb.DEVICE_ROTATED_UPRIGHT, 10, 20 },
                { fb.DEVICE_ROTATED_CLOCKWISE, 80, 10 },
                { fb.DEVICE_ROTATED_UPSIDE_DOWN, 90, 80 },
                { fb.DEVICE_ROTATED_COUNTER_CLOCKWISE, 20, 90 },
            }) do
                fb:setRotationMode(case[1])
                assert.are.equal(fb.bb:getRotation(), fb.full_bb:getRotation())
                assert.are.same({ case[2] + 1, case[3] + 2, 5, 6 }, { fb:calculateRealCoordinates(1, 2, 5, 6) })
            end
            fb:setRotationMode(fb.DEVICE_ROTATED_UPRIGHT)
            -- out of bounds requests are clipped to the viewport first
            assert.are.same({ 10, 20, 5, 10 }, { fb:calculateRealCoordinates(-5, 0, 10, 10) })
            assert.are.same({ 10, 20, 0, 0 }, { fb:calculateRealCoordinates(1000, 1000, 10, 10) })

            -- switching viewports keeps the full buffer
            fb:setViewport({ x = 0, y = 0, w = 300, h = 400 })
            assert.are.equal(full, fb.full_bb)
            assert.are.equal(300, fb:getWidth())
        end)

        it("should clear the full buffer", function()
            local fb = DummyFB:new{}
            local full = fb.bb
            full:paintRect(0, 0, 600, 800, BB.COLOR_BLACK)
            fb:clear()
            assert.are.equal(0xFF, pixel(full, 300, 400))
            fb:setViewport({ x = 10, y = 10, w = 100, h = 100 })
            full:paintRect(0, 0, 600, 800, BB.COLOR_BLACK)
            fb:clear()
            assert.are.equal(0xFF, pixel(full, 0, 0))
            assert.are.equal(0xFF, pixel(full, 50, 50))
        end)
    end)

    describe("DPI", function()
        local env_dpi = os.getenv("EMULATE_READER_DPI")

        it("should use the device DPI, overrides, and defaults", function()
            if env_dpi then
                pending("EMULATE_READER_DPI is set")
                return
            end
            local fb = DummyFB:new{ device = make_device({ dpi = 300 }) }
            assert.are.equal(300, fb:getDPI())
            assert.are.equal(19, fb:scaleByDPI(10))
            fb:setDPI(200)
            assert.are.equal(200, fb:getDPI())
            assert.is_true(fb.dpi_override)
            fb:setDPI(nil)
            assert.are.equal(300, fb:getDPI())
            assert.is_nil(fb.dpi_override)
            assert.are.equal(160, DummyFB:new{}:getDPI())
            assert.are.equal(160, DummyFB:new{ device = make_device() }:getDPI())
        end)

        it("should scale by screen size, and DPI only when overridden", function()
            local fb = DummyFB:new{ device = make_device({ dpi = 300 }) }
            -- 600 px wide: scale 1
            assert.are.equal(10, fb:scaleBySize(10))
            fb:setDPI(320)
            assert.are.equal(15, fb:scaleBySize(10))
            fb:clearDPI()
            local big = sized_fb(1200, 1600, {})
            assert.are.equal(20, big:scaleBySize(10))
            assert.are.equal(1, big:scaleBySize(0.1))
        end)
    end)

    describe("night mode", function()
        it("should use HW inversion when available", function()
            local fb = DummyFB:new{ device = make_device({ hw_invert = true }) }
            local states = {}
            fb.setHWNightmode = function(_, toggle) table.insert(states, toggle) end
            fb:toggleNightMode()
            fb:toggleNightMode()
            assert.are.same({ true, false }, states)
            assert.are.equal(0, fb.bb:getInverse())
        end)

        it("should invert the buffer otherwise", function()
            local fb = DummyFB:new{ device = make_device() }
            fb:toggleNightMode()
            assert.is_true(fb.night_mode)
            assert.are.equal(1, fb.bb:getInverse())
            fb:toggleNightMode()
            assert.is_false(fb.night_mode)
            assert.are.equal(0, fb.bb:getInverse())
        end)

        it("should invert and blank the full buffer with a viewport", function()
            local fb = DummyFB:new{ device = make_device() }
            local full = fb.bb
            fb:setViewport({ x = 10, y = 10, w = 100, h = 100 })
            full:paintRect(0, 0, 5, 5, BB.COLOR_BLACK)
            fb:toggleNightMode()
            assert.are.equal(1, fb.bb:getInverse())
            assert.are.equal(1, full:getInverse())
            -- blanked
            assert.are.equal(0xFF, pixel(full, 0, 0))
        end)
    end)

    describe("dithering", function()
        it("should toggle HW and SW dithering", function()
            local fb = DummyFB:new{}
            fb:toggleHWDithering(true)
            assert.is_true(fb.hw_dithering)
            fb:toggleHWDithering()
            assert.is_false(fb.hw_dithering)
            fb:toggleHWDithering()
            assert.is_true(fb.hw_dithering)
            fb:toggleHWDithering(false)
            assert.is_false(fb.hw_dithering)
            fb:toggleSWDithering(true)
            assert.is_true(fb.sw_dithering)
            fb:toggleSWDithering()
            assert.is_false(fb.sw_dithering)
            fb:toggleSWDithering()
            assert.is_true(fb.sw_dithering)
            fb:toggleSWDithering(false)
            assert.is_false(fb.sw_dithering)
        end)

        it("should prefer HW dithering, and SW dithering only at 8bpp", function()
            -- {caps, hw, sw}
            for _, case in ipairs({
                { { hw_dither = true, bpp = 8 }, true, false },
                { { hw_dither = false, bpp = 8 }, false, true },
                { { hw_dither = false, bpp = 32 }, false, false },
            }) do
                local fb = DummyFB:new{ device = make_device(case[1]) }
                fb:setupDithering()
                assert.are.equal(case[2], fb.hw_dithering)
                assert.are.equal(case[3], fb.sw_dithering)
            end
        end)
    end)

    describe("misc", function()
        it("should expose waveform and driver settings", function()
            local fb = DummyFB:new{ wf_level = 3, wf_level_max = 2 }
            assert.are.equal(2, fb:getWaveformLevel())
            fb.wf_level = 1
            assert.are.equal(1, fb:getWaveformLevel())
            assert.is_false(fb:getMxcWaitForBypass())
            assert.is_false(fb:noCFAPostProcess())
            fb.mxcfb_bypass_wait_for = true
            fb.no_cfa_post_processing = true
            assert.is_true(fb:getMxcWaitForBypass())
            assert.is_true(fb:noCFAPostProcess())
        end)

        it("should manage the window title", function()
            local fb = sized_fb(10, 10, {})
            assert.is_nil(fb:getWindowTitle())
            fb:setWindowTitle("Book")
            assert.are.equal("Book - KOReader", fb:getWindowTitle())
            fb:setWindowTitle("")
            assert.are.equal("KOReader", fb:getWindowTitle())
            fb:setWindowTitle(nil)
            assert.are.equal("KOReader", fb:getWindowTitle())
        end)

        it("should have no-op defaults for driver hooks", function()
            local fb = sized_fb(10, 10, {})
            assert.is_nil(fb:beforePaint())
            assert.is_nil(fb:afterPaint())
            assert.is_nil(fb:setHWRotation(1))
            assert.is_nil(fb:setHWNightmode(true))
            assert.is_nil(fb:setSwipeAnimations(true))
            assert.is_nil(fb:setSwipeDirection(1))
            assert.is_nil(fb:refreshFull(0, 0, 10, 10))
            assert.is_nil(fb:refreshWaitForLast())
            assert.is_nil(fb:close())
        end)

        it("should save and restore the screen content", function()
            local fb = DummyFB:new{}
            fb:restoreFromSavedBB() -- nothing saved: no-op
            fb.bb:paintRect(0, 0, 10, 10, BB.COLOR_BLACK)
            fb:saveCurrentBB()
            fb:saveCurrentBB() -- replaces the previous copy
            fb.bb:fill(BB.COLOR_WHITE)
            assert.are.equal(0xFF, pixel(fb.bb, 5, 5))
            fb:restoreFromSavedBB()
            assert.are.equal(0x00, pixel(fb.bb, 5, 5))
            assert.are.equal(0xFF, pixel(fb.bb, 50, 50))
            assert.is_nil(fb.saved_bb)
        end)

        it("should take screenshots", function()
            local tmp = os.tmpname()
            finally(function() os.remove(tmp) end)
            for _, caps in ipairs({ {}, { bgr = true } }) do
                local fb = DummyFB:new{ device = make_device(caps) }
                fb.bb:paintRect(0, 0, 10, 10, BB.COLOR_BLACK)
                for _, night in ipairs({ false, true }) do
                    fb.night_mode = night
                    os.remove(tmp)
                    assert.is_true(fb:shot(tmp))
                    local f = assert(io.open(tmp, "rb"))
                    local header = f:read(8)
                    f:close()
                    assert.are.equal("\137PNG\r\n\26\n", header)
                end
                -- the night mode copy does not alter the screen
                assert.are.equal(0, fb.bb:getInverse())
            end
        end)

        it("should keep rotation and inversion when the dummy buffer is resized", function()
            local fb = DummyFB:new{}
            fb.bb:setRotation(1)
            fb.bb:invert()
            fb:_newBB(300, 400)
            assert.are.equal(BB.TYPE_BBRGB32, fb.bb:getType())
            assert.are.equal(1, fb.bb:getRotation())
            assert.are.equal(1, fb.bb:getInverse())
            assert.are.equal(400, fb.bb:getWidth()) -- rotated
            assert.are.equal(300, fb.bb:getHeight())
            assert.is_not_nil(fb.invert_bb)
            fb:_newBB(100, 100)
            assert.are.equal(100, fb.bb:getWidth())
            -- the other dummy hooks do nothing
            assert.is_nil(fb:resize(1, 1))
            assert.is_nil(fb:_render(fb.bb, 0, 0, 1, 1))
            assert.is_nil(fb:setWindowIcon("icon"))
        end)
    end)
end)
