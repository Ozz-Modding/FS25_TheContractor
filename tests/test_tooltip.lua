-- TCTooltip's wrapping (paths break at "/") and the folders the Overview
-- logo's tooltip points at (TCCompanyLogo.getTooltipContent).

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

test("the logo tooltip points at the save's own folder when there is one", function()
    setup()
    g_currentMission.missionInfo.savegameIndex = 4
    assertEquals(TCCompanyLogo.getSavegameDir(), g_currentModSettingsDirectory .. "savegame4/")
end)

test("a joining client's tooltip has no save folder", function()
    setup()
    g_currentMission.missionInfo.savegameIndex = 0
    assertEquals(TCCompanyLogo.getSavegameDir(), nil)
end)
