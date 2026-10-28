require("ffi_wrapper")
local Blitbuffer = require("ffi/blitbuffer")
local cre = require("libs/libkoreader-cre")

-- Exercise collection after LVDocView member destruction through the Lua API.
describe("crengine document font lifecycle", function()
    local views
    cre.registerFont("spec/base/unit/data/testfont.ttf")
    before_each(function()
        views = {}
    end)
    after_each(function()
        for _, view in ipairs(views) do view:close() end
    end)

    local function open()
        local view = cre.newDocView(600, 800, 0)
        views[#views + 1] = view
        view:setFontFace(cre.getFontFaces()[1])
        view:setHeaderFont(cre.getFontFaces()[1])
        view:setFontSize(24)
        assert.is_true(view:loadDocument("spec/base/unit/data/testdocument.odt"))
        view:renderDocument()
        assert.is_true(view:getPages() > 0)
        return view
    end
    local function pixels(view)
        local bb = Blitbuffer.new(600, 800, Blitbuffer.TYPE_BB8)
        view:drawCurrentPage(bb)
        local image = Blitbuffer.tostring(bb)
        bb:free()
        return image
    end

    it("preserves a live document when another view closes", function()
        local first, second = open(), open()
        local expected = pixels(second)
        first:close()
        first:close()
        assert.are.equal(expected, pixels(second))
    end)

    it("renders the same page after repeated close and reopen", function()
        local expected
        for _ = 1, 3 do
            local view = open()
            local image = pixels(view)
            expected = expected or image
            assert.are.equal(expected, image)
            view:close()
        end
    end)
end)
