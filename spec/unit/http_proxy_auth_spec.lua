require("ffi_wrapper")

local http = require("socket.http")
local mime = require("mime")

describe("HTTP proxy request-target authentication", function()
    local saved_proxy
    before_each(function()
        saved_proxy = http.PROXY
        http.PROXY = nil
    end)
    after_each(function()
        http.PROXY = saved_proxy
    end)

    -- Exercise the real request parser, URL builder and header writer without
    -- resolving names or opening a network connection. All credentials are fake.
    local function capture(request)
        local response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        local wire, destination, closed = {}, nil, false
        request.create = function()
            return {
                settimeout = function() return 1 end,
                connect = function(_, host, port)
                    destination = { host, tonumber(port) }
                    return 1
                end,
                send = function(_, chunk)
                    wire[#wire + 1] = chunk
                    return #chunk
                end,
                receive = function(_, pattern, prefix)
                    local chunk
                    if type(pattern) == "number" then
                        chunk, response = response:sub(1, pattern), response:sub(pattern + 1)
                    else
                        local last = assert(response:find("\r\n", 1, true))
                        chunk, response = response:sub(1, last - 1), response:sub(last + 2)
                    end
                    return (prefix or "") .. chunk
                end,
                close = function()
                    closed = true
                    return 1
                end,
            }
        end
        local result, code = http.request(request)
        assert.are.equal(1, result)
        assert.are.equal(200, code)
        assert.is_true(closed)
        local message = table.concat(wire)
        local request_line = assert(message:match("^(.-)\r\n"))
        local headers = {}
        for key, value in message:gmatch("\r\n([^:\r\n]+): ([^\r\n]*)") do
            headers[key:lower()] = value
        end
        return request_line, headers, destination
    end

    local function basic(user, password)
        return "Basic " .. mime.b64(user .. ":" .. password)
    end

    for _, method in ipairs({ "GET", "HEAD" }) do
        it("keeps reserved credentials in Authorization only for " .. method, function()
            local request = {
                url = "http://catalog.example.invalid:25600/opds/v2/catalog;v=2?q=a%40b%3Ac",
                proxy = "http://proxy.example.invalid:8080",
                user = "reader@example.invalid",
                password = "fake:@/?#[] &+",
                method = method,
            }
            local line, headers, destination = capture(request)
            assert.are.equal(method .. " http://catalog.example.invalid:25600/opds/v2/catalog;v=2?q=a%40b%3Ac HTTP/1.1", line)
            assert.are.equal(basic(request.user, request.password), headers.authorization)
            assert.are.equal("catalog.example.invalid:25600", headers.host)
            assert.are.same({ "proxy.example.invalid", 8080 }, destination)
            assert.are.equal("reader@example.invalid", request.user)
            assert.are.equal("fake:@/?#[] &+", request.password)
        end)
    end

    it("omits credentials parsed from the URL without changing password decoding", function()
        local line, headers = capture {
            url = "http://reader:fake%40%3Apass@catalog.example.invalid/catalog",
            proxy = "http://proxy.example.invalid",
        }
        assert.are.equal("GET http://catalog.example.invalid:80/catalog HTTP/1.1", line)
        assert.are.equal(basic("reader", "fake@:pass"), headers.authorization)
    end)

    it("omits fallback userinfo and authority fields", function()
        local line, headers = capture {
            url = "http://catalog.example.invalid/catalog",
            userinfo = "fake:fallback-secret",
            authority = "fake:stale-secret@stale.example.invalid:1234",
            proxy = "http://proxy.example.invalid",
        }
        assert.are.equal("GET http://catalog.example.invalid:80/catalog HTTP/1.1", line)
        assert.is_nil(headers.authorization)
    end)

    it("omits a username even without a password", function()
        local line, headers = capture {
            url = "http://reader@catalog.example.invalid/catalog",
            proxy = "http://proxy.example.invalid",
        }
        assert.are.equal("GET http://catalog.example.invalid:80/catalog HTTP/1.1", line)
        assert.is_nil(headers.authorization)
    end)

    it("supports the global proxy and keeps proxy authentication separate", function()
        http.PROXY = "http://proxy-user:proxy-secret@proxy.example.invalid:3129"
        local line, headers, destination = capture {
            url = "http://catalog.example.invalid",
            user = "origin-user",
            password = "origin-secret",
        }
        assert.are.equal("GET http://catalog.example.invalid:80/ HTTP/1.1", line)
        assert.are.equal(basic("origin-user", "origin-secret"), headers.authorization)
        assert.are.equal(basic("proxy-user", "proxy-secret"), headers["proxy-authorization"])
        assert.are.same({ "proxy.example.invalid", 3129 }, destination)
    end)

    it("prefers the per-request proxy over the global proxy", function()
        http.PROXY = "http://unused:unused-secret@unused.example.invalid:9000"
        local line, headers, destination = capture {
            url = "http://catalog.example.invalid/catalog",
            proxy = "http://selected:selected-secret@proxy.example.invalid:8080",
            user = "reader",
            password = "fake-secret",
        }
        assert.are.equal("GET http://catalog.example.invalid:80/catalog HTTP/1.1", line)
        assert.are.equal(basic("selected", "selected-secret"), headers["proxy-authorization"])
        assert.are.same({ "proxy.example.invalid", 8080 }, destination)
    end)

    it("preserves origin-form and authentication without a proxy", function()
        local line, headers, destination = capture {
            url = "http://catalog.example.invalid:25600/catalog;v=2?q=a%40b",
            user = "reader@example.invalid",
            password = "fake:secret",
        }
        assert.are.equal("GET /catalog;v=2?q=a%40b HTTP/1.1", line)
        assert.are.equal(basic("reader@example.invalid", "fake:secret"), headers.authorization)
        assert.is_nil(headers["proxy-authorization"])
        assert.are.same({ "catalog.example.invalid", 25600 }, destination)
    end)

    it("preserves caller-supplied Authorization with a generated absolute target", function()
        local line, headers = capture {
            url = "http://catalog.example.invalid/catalog",
            proxy = "http://proxy.example.invalid",
            user = "reader",
            password = "unused-secret",
            headers = { Authorization = "Bearer synthetic-token" },
        }
        assert.are.equal("GET http://catalog.example.invalid:80/catalog HTTP/1.1", line)
        assert.are.equal("Bearer synthetic-token", headers.authorization)
    end)

    it("preserves explicit request-target overrides", function()
        local line, headers = capture {
            url = "http://catalog.example.invalid/catalog",
            proxy = "http://proxy.example.invalid",
            user = "reader",
            password = "unused-secret",
            uri = "/explicit-target?token=a%40b",
            headers = { Authorization = "Bearer synthetic-token" },
        }
        assert.are.equal("GET /explicit-target?token=a%40b HTTP/1.1", line)
        assert.are.equal("Bearer synthetic-token", headers.authorization)
    end)

    it("preserves Basic authentication with an empty password", function()
        local line, headers = capture {
            url = "http://catalog.example.invalid/catalog",
            proxy = "http://proxy.example.invalid",
            user = "reader",
            password = "",
        }
        assert.are.equal("GET http://catalog.example.invalid:80/catalog HTTP/1.1", line)
        assert.are.equal(basic("reader", ""), headers.authorization)
    end)

    it("keeps unauthenticated absolute targets and IPv6 ports intact", function()
        local line, headers = capture {
            url = "http://[2001:db8::1]:25600/catalog?q=a%3Ab",
            proxy = "http://proxy.example.invalid",
        }
        assert.are.equal("GET http://[2001:db8::1]:25600/catalog?q=a%3Ab HTTP/1.1", line)
        assert.is_nil(headers.authorization)
    end)

    it("uses explicit host and port overrides instead of cached authority", function()
        local line, headers = capture {
            url = "http://reader:fake-secret@old.example.invalid:1234/catalog",
            host = "catalog.example.invalid",
            port = 25600,
            proxy = "http://proxy.example.invalid",
        }
        assert.are.equal("GET http://catalog.example.invalid:25600/catalog HTTP/1.1", line)
        assert.are.equal("catalog.example.invalid:25600", headers.host)
        assert.are.equal(basic("reader", "fake-secret"), headers.authorization)
    end)
end)
