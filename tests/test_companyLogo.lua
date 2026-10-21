-- The Overview's company logo: the player's own logo.dds from
-- modSettings if there is one (the save's own savegame<N>/ folder first),
-- else the mod's default.

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

test("a logo.png in modSettings is ignored", function()
    setup({ "modSettings/FS25_TheContractor/logo.png" })
    assertEquals("mods/FS25_TheContractor/images/defaultLogo.dds", TCCompanyLogo.getFilename())
end)

test("a logo.dds in modSettings is used", function()
    setup({ "modSettings/FS25_TheContractor/logo.dds" })
    assertEquals("modSettings/FS25_TheContractor/logo.dds", TCCompanyLogo.getFilename())
end)

test("a logo.dds in the save's own folder comes before the shared one", function()
    setup({ "modSettings/FS25_TheContractor/logo.dds", "modSettings/FS25_TheContractor/savegame1/logo.dds" })
    g_currentMission.missionInfo.savegameIndex = 1
    assertEquals("modSettings/FS25_TheContractor/savegame1/logo.dds", TCCompanyLogo.getFilename())
end)

test("another save's folder is ignored", function()
    setup({ "modSettings/FS25_TheContractor/logo.dds", "modSettings/FS25_TheContractor/savegame1/logo.dds" })
    g_currentMission.missionInfo.savegameIndex = 2
    assertEquals("modSettings/FS25_TheContractor/logo.dds", TCCompanyLogo.getFilename())
end)

test("a save's own logo is used with no shared one", function()
    setup({ "modSettings/FS25_TheContractor/savegame3/logo.dds" })
    g_currentMission.missionInfo.savegameIndex = 3
    assertEquals("modSettings/FS25_TheContractor/savegame3/logo.dds", TCCompanyLogo.getFilename())
end)

test("a joining client (save index 0) only uses the shared logo", function()
    setup({ "modSettings/FS25_TheContractor/logo.dds", "modSettings/FS25_TheContractor/savegame0/logo.dds" })
    g_currentMission.missionInfo.savegameIndex = 0
    assertEquals("modSettings/FS25_TheContractor/logo.dds", TCCompanyLogo.getFilename())
end)

test("the default logo file is in the mod", function()
    local file = io.open("images/defaultLogo.dds", "rb")
    assertTrue(file ~= nil)
    file:close()
end)

-- 084's logo sign: the player's own logo only on their own farm's signs.
local function setupSign(files)
    setup(files)
    dofile("src/placeables/PlaceableTCLogoSign.lua")
end

test("a sign of the player's own farm shows their logo", function()
    setupSign({ "modSettings/FS25_TheContractor/logo.dds" })
    assertEquals("modSettings/FS25_TheContractor/logo.dds", PlaceableTCLogoSign.getLogoFilename(2, 2, false))
end)

test("another farm's sign shows the default logo", function()
    setupSign({ "modSettings/FS25_TheContractor/logo.dds" })
    assertEquals("mods/FS25_TheContractor/images/defaultLogo.dds", PlaceableTCLogoSign.getLogoFilename(3, 2, false))
end)

test("a sign being placed shows the player's logo", function()
    setupSign({ "modSettings/FS25_TheContractor/logo.dds" })
    assertEquals("modSettings/FS25_TheContractor/logo.dds", PlaceableTCLogoSign.getLogoFilename(nil, 2, true))
end)

test("a sign without an owner shows the default logo", function()
    setupSign({ "modSettings/FS25_TheContractor/logo.dds" })
    assertEquals("mods/FS25_TheContractor/images/defaultLogo.dds", PlaceableTCLogoSign.getLogoFilename(nil, 2, false))
end)
