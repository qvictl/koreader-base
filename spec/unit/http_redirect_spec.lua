require("ffi_wrapper")

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")

describe("HTTP permanent redirects", function()
    local saved_proxy
    before_each(function()
        saved_proxy, http.PROXY = http.PROXY, nil
    end)
    after_each(function()
        http.PROXY = saved_proxy
    end)

    -- Keep the real HTTP request/response machinery; only transport is fake.
    -- A fresh response/socket per hop also proves the old connection is closed.
    local function request(options, replies)
        options = options or {}
        options.url = options.url or "http://feed.example.invalid/start"
        options.scheme = options.scheme or "http"
        local observed, body = {}, {}
        options.sink = ltn12.sink.table(body)
        options.create = function()
            local index = #observed + 1
            local reply = assert(replies[index], "unexpected redirect")
            if index > 1 then assert.are.equal(1, observed[index - 1].closed) end
            local item = { sent = {}, closed = 0 }
            observed[index] = item
            local raw = "HTTP/1.1 " .. reply.code .. " Synthetic\r\n"
            for key, value in pairs(reply.headers or {}) do raw = raw .. key .. ": " .. value .. "\r\n" end
            raw = raw .. "Content-Length: " .. #(reply.body or "") .. "\r\n\r\n" .. (reply.body or "")
            return {
                settimeout = function() return 1 end,
                connect = function(_, host, port)
                    item.destination = { host, tonumber(port) }
                    return 1
                end,
                send = function(_, chunk)
                    item.sent[#item.sent + 1] = chunk
                    return #chunk
                end,
                receive = function(_, pattern, prefix)
                    local chunk
                    if type(pattern) == "number" then
                        chunk, raw = raw:sub(1, pattern), raw:sub(pattern + 1)
                    else
                        local last = assert(raw:find("\r\n", 1, true))
                        chunk, raw = raw:sub(1, last - 1), raw:sub(last + 2)
                    end
                    return (prefix or "") .. chunk
                end,
                close = function() item.closed = item.closed + 1; return 1 end,
            }
        end
        -- LuaSocket may reselect its factory between hops. Replace the default
        -- too, so every hop remains synthetic even after that reselection.
        local saved_tcp = socket.tcp
        socket.tcp = options.create
        local ok, result, code, headers = pcall(http.request, options)
        socket.tcp = saved_tcp
        assert.is_true(ok)
        assert.are.equal(1, result)
        for _, item in ipairs(observed) do
            assert.are.equal(1, item.closed)
            item.message = table.concat(item.sent)
        end
        return code, table.concat(body), observed, headers
    end

    local function redirect(code, location)
        return { code = code or 308, headers = { Location = location or "/feed" }, body = "not XML: redirect body" }
    end
    local function feed()
        return { code = 200, headers = { ["Content-Type"] = "application/rss+xml" }, body = "<rss>final feed</rss>" }
    end

    for _, code in ipairs{ 301, 302, 303, 307, 308 } do
        it("follows a bodyless GET through " .. code, function()
            local status, body, observed = request({ method = "GET" }, { redirect(code), feed() })
            assert.are.equal(200, status)
            assert.are.equal("<rss>final feed</rss>", body)
            assert.are.equal(2, #observed)
            assert.truthy(observed[2].message:find("GET /feed HTTP/1.1\r\n", 1, true))
        end)
    end

    it("follows 308 then 301 without mixing redirect response bodies into the sink", function()
        local statuses = {}
        local status, body, observed, headers = request({ response_headers = function(code)
            statuses[#statuses + 1] = code
        end }, { redirect(308, "/permanent"), redirect(301, "/feed"), feed() })
        assert.are.equal(200, status)
        assert.are.equal("<rss>final feed</rss>", body)
        assert.are.equal(3, #observed)
        assert.are.same({ 200 }, statuses)
        assert.are.equal("application/rss+xml", headers["content-type"])
    end)

    it("follows absolute 308 locations", function()
        local status, _, observed = request(nil, { redirect(308, "http://other.example.invalid:8080/final"), feed() })
        assert.are.equal(200, status)
        assert.are.same({ "other.example.invalid", 8080 }, observed[2].destination)
        assert.truthy(observed[2].message:find("GET /final HTTP/1.1\r\n", 1, true))
    end)

    for _, options in ipairs{
        { redirect = false }, { maxredirects = 0 }, { maxredirects = 2, nredirects = 2 },
        { method = "POST" }, { method = "PUT" }, { method = "DELETE" },
    } do
        it("retains redirect eligibility guards " .. (options.method or options.nredirects or options.maxredirects or "disabled"), function()
            local status, body, observed = request(options, { redirect() })
            assert.are.equal(308, status)
            assert.are.equal("not XML: redirect body", body)
            assert.are.equal(1, #observed)
        end)
    end

    it("does not replay a consumed GET source", function()
        local status, _, observed = request({ method = "GET", source = ltn12.source.string("request body"),
            headers = { ["content-length"] = 12 } }, { redirect() })
        assert.are.equal(308, status)
        assert.are.equal(1, #observed)
        assert.truthy(observed[1].message:find("request body", 1, true))
    end)

    it("retains the default five-redirect limit", function()
        local status, body, observed = request(nil, { redirect(), redirect(), redirect(), redirect(), redirect(), redirect() })
        assert.are.equal(308, status)
        assert.are.equal("not XML: redirect body", body)
        assert.are.equal(6, #observed)
    end)

    it("retains an explicit unlimited redirect setting", function()
        local status, _, observed = request({ maxredirects = false },
            { redirect(), redirect(), redirect(), redirect(), redirect(), redirect(), feed() })
        assert.are.equal(200, status)
        assert.are.equal(7, #observed)
    end)

    for _, location in ipairs{ "", " \t ", "ftp://other.example.invalid/feed", "file:///synthetic/feed" } do
        it("rejects an empty or unsupported location " .. location, function()
            local status, _, observed = request(nil, { redirect(308, location) })
            assert.are.equal(308, status)
            assert.are.equal(1, #observed)
        end)
    end

    it("does not follow 308 without a Location header", function()
        local status, _, observed = request(nil, { { code = 308, body = "missing location" } })
        assert.are.equal(308, status)
        assert.are.equal(1, #observed)
    end)

    it("does not follow an HTTPS downgrade", function()
        local status, _, observed = request({ url = "https://feed.example.invalid/start", scheme = "https" },
            { redirect(308, "http://feed.example.invalid/feed") })
        assert.are.equal(308, status)
        assert.are.equal(1, #observed)
    end)

    it("still returns a non-redirect status and its body", function()
        local status, body, observed = request(nil, { redirect(304) })
        assert.are.equal(304, status)
        assert.are.equal("", body)
        assert.are.equal(1, #observed)
    end)
end)
