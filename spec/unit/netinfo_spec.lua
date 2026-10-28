local ffi = require("ffi")

describe("NetInfo module", function()

    describe("on the host system", function()
        it("should list up, non-loopback interfaces sorted by index", function()
            local NetInfo = require("ffi/netinfo")
            local ni = NetInfo:new()
            local ifaces = ni:retrieve()
            assert.are.equal("table", type(ifaces))
            local last_index = -1
            for _, iface in ipairs(ifaces) do
                assert.are.equal("string", type(iface.name))
                assert.are_not.equal("lo", iface.name)
                assert.truthy(iface.mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$"), iface.mac)
                assert.is_true(iface.index > last_index)
                last_index = iface.index
                if iface.ipv4 then
                    assert.truthy(iface.ipv4:match("^[%d%.%s/]+$"), iface.ipv4)
                    assert.is_nil(iface.ipv4:find("^127%."))
                end
            end
            ni:free()
        end)
    end)

    if ffi.os ~= "Linux" then
        pending("fake interfaces (Linux only)")
        return
    end

    describe("with fake interfaces", function()
        local C = ffi.C
        local NetInfo
        -- Behaviour of the faked libc functions, set by each test.
        local fake
        -- Keep the fake C structures alive.
        local anchors

        local function anchor(cdata)
            table.insert(anchors, cdata)
            return cdata
        end

        local function packet_addr(index, mac)
            local sll = anchor(ffi.new("struct sockaddr_ll"))
            sll.sll_family = C.AF_PACKET
            sll.sll_ifindex = index
            sll.sll_halen = 6
            for i = 1, 6 do
                sll.sll_addr[i - 1] = mac[i]
            end
            return ffi.cast("struct sockaddr *", sll)
        end

        local function inet_addr(family, ctype, field, bytes)
            local sa = anchor(ffi.new(ctype))
            local raw = ffi.cast("uint8_t *", sa)
            ffi.cast("struct sockaddr *", sa).sa_family = family
            local offset = ffi.offsetof(ctype, field)
            for i, b in ipairs(bytes) do
                raw[offset + i - 1] = b
            end
            return ffi.cast("struct sockaddr *", sa)
        end

        local function ipv4_addr(a, b, c, d)
            return inet_addr(C.AF_INET, "struct sockaddr_in", "sin_addr", { a, b, c, d })
        end

        local function ipv6_addr(bytes)
            return inet_addr(C.AF_INET6, "struct sockaddr_in6", "sin6_addr", bytes)
        end

        -- Build a struct ifaddrs linked list from {name, flags, addr} entries.
        local function ifaddrs(list)
            local arr = anchor(ffi.new("struct ifaddrs[?]", #list))
            for i, e in ipairs(list) do
                local ifa = arr[i - 1]
                ifa.ifa_name = anchor(ffi.new("char[?]", #e[1] + 1, e[1]))
                ifa.ifa_flags = e[2]
                ifa.ifa_addr = e[3]
                ifa.ifa_next = i < #list and arr + i or nil
            end
            return arr
        end

        local UP = C.IFF_UP
        local LOOPBACK = C.IFF_LOOPBACK
        local IPV6 = { 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } -- 2001:db8::1

        setup(function()
            -- Load the module with a fake `ffi.C`, forwarding everything but the faked functions.
            require("ffi/posix")
            local real_ffi = package.loaded.ffi
            local fake_C = setmetatable({
                getifaddrs = function(pp)
                    fake.getifaddrs_calls = fake.getifaddrs_calls + 1
                    if not fake.ifaddrs then
                        return -1
                    end
                    pp[0] = fake.ifaddrs
                    return 0
                end,
                freeifaddrs = function(p)
                    table.insert(fake.freed, p)
                end,
                getnameinfo = function(sa, len, host, hostlen, serv, servlen, flags)
                    if fake.getnameinfo_error then
                        return fake.getnameinfo_error
                    end
                    return C.getnameinfo(sa, len, host, hostlen, serv, servlen, flags)
                end,
                access = function(path)
                    return fake.paths[path] and 0 or -1
                end,
                socket = function()
                    fake.sockets = fake.sockets + 1
                    return fake.socket_fd
                end,
                fcntl = function()
                    return fake.fcntl_ret
                end,
                ioctl = function(sd, request, iwr)
                    assert.are.equal(fake.socket_fd, sd)
                    assert.are.equal(C.SIOCGIWESSID, request)
                    local name = ffi.string(iwr.ifr_ifrn.ifrn_name)
                    local ssid = fake.ssids[name]
                    if ssid == false then
                        return -1
                    end
                    if ssid then
                        ffi.copy(iwr.u.essid.pointer, ssid)
                        iwr.u.essid.flags = 1
                    end
                    return 0
                end,
                close = function(fd)
                    table.insert(fake.closed, fd)
                    return 0
                end,
            }, { __index = real_ffi.C })
            package.loaded["ffi/netinfo"] = nil
            package.loaded.ffi = setmetatable({ C = fake_C }, { __index = real_ffi })
            local ok, mod = pcall(require, "ffi/netinfo")
            package.loaded.ffi = real_ffi
            package.loaded["ffi/netinfo"] = nil
            assert(ok, mod)
            NetInfo = mod
        end)

        before_each(function()
            anchors = {}
            fake = {
                getifaddrs_calls = 0,
                freed = {},
                paths = {},
                sockets = 0,
                socket_fd = 42,
                fcntl_ret = 0,
                ssids = {},
                closed = {},
            }
        end)

        local function standard_ifaddrs()
            return ifaddrs({
                { "lo", UP + LOOPBACK, packet_addr(1, { 0, 0, 0, 0, 0, 0 }) },
                { "eth0", UP, packet_addr(3, { 0x00, 0x11, 0x22, 0xaa, 0xbb, 0xcc }) },
                { "wlan0", UP, packet_addr(2, { 0xde, 0xad, 0xbe, 0xef, 0x00, 0x01 }) },
                { "down0", 0, packet_addr(4, { 1, 2, 3, 4, 5, 6 }) },
                { "noaddr", UP, nil },
                { "zero", UP, packet_addr(0, { 1, 2, 3, 4, 5, 6 }) },
                { "unix", UP, inet_addr(C.AF_UNIX, "struct sockaddr_in", "sin_addr", {}) },
                { "lo", UP + LOOPBACK, ipv4_addr(127, 0, 0, 1) },
                { "eth0", UP, ipv4_addr(192, 168, 1, 42) },
                { "eth0", UP, ipv4_addr(10, 0, 0, 2) },
                { "eth0", UP, ipv6_addr(IPV6) },
                { "down0", 0, ipv4_addr(10, 9, 9, 9) },
            })
        end

        it("should keep up, non-loopback link interfaces with their addresses", function()
            fake.ifaddrs = standard_ifaddrs()
            fake.paths["/sys/class/net/wlan0/wireless/"] = true
            fake.ssids.wlan0 = "MyWiFi"
            local ni = NetInfo:new()
            local ifaces = ni:retrieve()
            assert.are.same({
                {
                    name = "wlan0", index = 2, mac = "DE:AD:BE:EF:00:01",
                    wireless = true, ssid = "MyWiFi",
                },
                {
                    name = "eth0", index = 3, mac = "00:11:22:AA:BB:CC",
                    wireless = false, ipv4 = "192.168.1.42 / 10.0.0.2", ipv6 = "2001:db8::1",
                },
            }, ifaces)
            -- the list is freed once fully iterated
            assert.are.equal(1, #fake.freed)
            assert.are.equal(fake.ifaddrs, fake.freed[1])
            -- the ioctl socket is kept open until free()
            assert.are.equal(1, fake.sockets)
            assert.are.same({}, fake.closed)
            ni:retrieve()
            assert.are.equal(1, fake.sockets)
            ni:free()
            assert.are.same({ 42 }, fake.closed)
            assert.is_nil(ni.sd)
            ni:free()
            assert.are.same({ 42 }, fake.closed)
        end)

        it("should detect Kindle wireless interfaces", function()
            fake.ifaddrs = standard_ifaddrs()
            fake.paths["/sys/class/net/wlan0/phy82011/"] = true
            local ni = NetInfo:new()
            local ifaces = ni:retrieve()
            assert.is_true(ifaces[1].wireless)
            -- not associated: no SSID
            assert.is_nil(ifaces[1].ssid)
            assert.is_false(ifaces[2].wireless)
            ni:free()
        end)

        it("should survive SSID retrieval failures", function()
            fake.ifaddrs = standard_ifaddrs()
            fake.paths["/sys/class/net/wlan0/wireless/"] = true
            fake.paths["/sys/class/net/eth0/wireless/"] = true
            fake.ssids.wlan0 = false -- ioctl fails
            fake.ssids.eth0 = "Other"
            fake.fcntl_ret = -1
            local ni = NetInfo:new()
            local ifaces = ni:retrieve()
            assert.are.equal(2, #ifaces)
            assert.is_true(ifaces[1].wireless)
            assert.is_nil(ifaces[1].ssid)
            assert.are.equal("Other", ifaces[2].ssid)
            ni:free()
            assert.are.same({ 42 }, fake.closed)
            -- no socket at all
            fake.closed = {}
            fake.socket_fd = -1
            ni = NetInfo:new()
            ifaces = ni:retrieve()
            assert.are.equal(2, #ifaces)
            assert.is_nil(ifaces[1].ssid)
            assert.is_nil(ifaces[2].ssid)
            assert.is_nil(ni.sd)
            ni:free()
            assert.are.same({}, fake.closed)
        end)

        it("should skip addresses getnameinfo cannot format", function()
            fake.ifaddrs = standard_ifaddrs()
            fake.getnameinfo_error = -6 -- EAI_FAMILY
            local ifaces = NetInfo:new():retrieve()
            assert.are.equal(2, #ifaces)
            assert.is_nil(ifaces[1].ipv4)
            assert.is_nil(ifaces[2].ipv4)
            assert.is_nil(ifaces[2].ipv6)
        end)

        it("should return nothing when getifaddrs fails", function()
            fake.ifaddrs = nil
            assert.are.same({}, NetInfo:new():retrieve())
            assert.are.equal(1, fake.getifaddrs_calls)
            assert.are.same({}, fake.freed)
        end)

        it("should dump interfaces", function()
            fake.ifaddrs = standard_ifaddrs()
            fake.paths["/sys/class/net/wlan0/wireless/"] = true
            local lines = {}
            local orig_print = print
            _G.print = function(...) table.insert(lines, table.concat({ ... }, " ")) end
            local ok, err = pcall(NetInfo.dump, NetInfo:new())
            _G.print = orig_print
            assert.is_true(ok, err)
            assert.are.same({
                "2:\twlan0",
                "\tmac: DE:AD:BE:EF:00:01",
                "\tssid: off/any",
                "3:\teth0",
                "\tmac: 00:11:22:AA:BB:CC",
                "\tipv4: 192.168.1.42 / 10.0.0.2",
                "\tipv6: 2001:db8::1",
            }, lines)
        end)
    end)
end)
