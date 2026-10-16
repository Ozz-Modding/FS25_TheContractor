-- The Overview's company logo: the player's own logo.png/logo.dds from
-- modSettings if there is one, else the mod's default.

local function setup(files)
    stubs.install()
    TheContractor = { dir = "mods/FS25_TheContractor/" }
    g_currentModSettingsDirectory = "modSettings/FS25_TheContractor/"
    local existing = {}
    for _, name in ipairs(files) do
        existing[name] = true
    end
    fileExists = function(path)
        return existing[path] == true
    end
    dofile("src/util/TCCompanyLogo.lua")
end

test("no logo of the player's own shows the default", function()
    setup({})
    assertEquals("mods/FS25_TheContractor/images/defaultLogo.dds", TCCompanyLogo.getFilename())
end)

test("a logo.png in modSettings is used", function()
    setup({ "modSettings/FS25_TheContractor/logo.png" })
    assertEquals("modSettings/FS25_TheContractor/logo.png", TCCompanyLogo.getFilename())
end)

test("a logo.dds in modSettings is used", function()
    setup({ "modSettings/FS25_TheContractor/logo.dds" })
    assertEquals("modSettings/FS25_TheContractor/logo.dds", TCCompanyLogo.getFilename())
end)

test("logo.dds wins when both are there", function()
    setup({ "modSettings/FS25_TheContractor/logo.png", "modSettings/FS25_TheContractor/logo.dds" })
    assertEquals("modSettings/FS25_TheContractor/logo.dds", TCCompanyLogo.getFilename())
end)

test("the default logo file is in the mod", function()
    local file = io.open("images/defaultLogo.dds", "rb")
    assertTrue(file ~= nil)
    file:close()
end)
