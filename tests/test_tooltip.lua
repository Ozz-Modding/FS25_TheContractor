-- TCTooltip's wrapping (paths break at "/") and the Overview logo's
-- tooltip text (TCCompanyLogo.getTooltipContent).

local function setup(files)
    stubs.install()
    TheContractor = { dir = "mods/FS25_TheContractor/" }
    g_currentModSettingsDirectory = "C:/Users/me/Documents/My Games/FarmingSimulator2025/modSettings/FS25_TheContractor/"
    local existing = {}
    for _, name in ipairs(files or {}) do
        existing[name] = true
    end
    fileExists = function(path)
        return existing[path] == true
    end
    dofile("src/util/TCCompanyLogo.lua")
    dofile("src/gui/TCTooltip.lua")
end

-- One unit of width per character.
local function measure(text)
    return #text
end

test("short lines are left alone", function()
    setup()
    assertEquals("one two\nthree", TCTooltip.wrap("one two\nthree", 20, measure))
end)

test("words wrap at spaces without trailing spaces", function()
    setup()
    assertEquals("aaa bbb\nccc", TCTooltip.wrap("aaa bbb ccc", 8, measure))
end)

test("a long path breaks after a slash", function()
    setup()
    assertEquals("C:/Users/\nsomeone/\nmodSettings/", TCTooltip.wrap("C:/Users/someone/modSettings/", 12, measure))
end)

test("blank lines between paragraphs are kept", function()
    setup()
    assertEquals("first\n\nsecond", TCTooltip.wrap("first\n\nsecond", 20, measure))
end)

test("a word longer than the width gets a line of its own", function()
    setup()
    assertEquals("a\nabcdefghij\nb", TCTooltip.wrap("a abcdefghij b", 5, measure))
end)

test("the logo tooltip names the real folder, the README and the placeholder", function()
    setup()
    local title, body = TCCompanyLogo.getTooltipContent()
    assertEquals(g_i18n:getText("tc_logoTip_title"), title)
    assertTrue(body:find(g_currentModSettingsDirectory, 1, true) ~= nil)
    assertTrue(body:find("README.txt", 1, true) ~= nil)
    assertTrue(body:find(g_i18n:getText("tc_logoTip_placeholder"), 1, true) ~= nil)
end)

test("the logo tooltip names the save's own folder when there is one", function()
    setup()
    g_currentMission.missionInfo.savegameIndex = 4
    local _, body = TCCompanyLogo.getTooltipContent()
    assertTrue(body:find(g_currentModSettingsDirectory .. "savegame4/", 1, true) ~= nil)
end)

test("a joining client's tooltip has no save folder", function()
    setup()
    g_currentMission.missionInfo.savegameIndex = 0
    local _, body = TCCompanyLogo.getTooltipContent()
    assertTrue(body:find("savegame", 1, true) == nil)
end)

test("the logo tooltip names the player's logo when it's showing", function()
    local dir = "C:/Users/me/Documents/My Games/FarmingSimulator2025/modSettings/FS25_TheContractor/"
    setup({ dir .. "logo.png" })
    local _, body = TCCompanyLogo.getTooltipContent()
    assertTrue(body:find(dir .. "logo.png", 1, true) ~= nil)
    assertTrue(body:find(g_i18n:getText("tc_logoTip_placeholder"), 1, true) == nil)
end)
