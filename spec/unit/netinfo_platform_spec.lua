local ffi = require("ffi")

describe("NetInfo platform dispatch", function()
    it("should decode Ethernet interfaces on LuaJIT's OSX platform", function()
        local mac_ffi = setmetatable({
            os = "OSX",
            C = { AF_LINK = 18, IFT_ETHER = 6 },
            cast = function(ctype, value)
                assert.are.equal("struct sockaddr_dl *", ctype)
                return value
            end,
        }, { __index = ffi })
        local module = assert(loadfile("ffi/netinfo.lua"))
        setfenv(module, setmetatable({
            require = function(name)
                if name == "ffi" then return mac_ffi end
                if name == "ffi/posix" then return {} end
                return require(name)
            end,
        }, { __index = _G }))
        local NetInfo = module()
        local ni = NetInfo:new()
        assert.is_function(ni._process_ifaddr)
        local address = {
            sa_family = 18, sdl_index = 4, sdl_type = 6, sdl_alen = 6, sdl_nlen = 3,
            sdl_data = ffi.new("uint8_t[9]", { 101, 110, 48, 0, 17, 34, 51, 68, 255 }),
        }
        local ifa = { ifa_addr = address, ifa_name = "en0" }
        assert.are.same({ name = "en0", index = 4, mac = "00:11:22:33:44:FF" }, ni:_process_ifaddr(ifa))

        address.sa_family = 2
        assert.is_nil(ni:_process_ifaddr(ifa))
        address.sa_family, address.sdl_index = 18, 0
        assert.is_nil(ni:_process_ifaddr(ifa))
        address.sdl_index, address.sdl_type = 4, 24
        assert.is_nil(ni:_process_ifaddr(ifa))
    end)
end)
