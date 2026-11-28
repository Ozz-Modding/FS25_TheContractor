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

-- 188: a list's rows: the row under the mouse gives the tooltip, the same
-- key while the mouse stays on that row.
test("a list target: the hovered row's content, keyed by its row, none for a row without one", function()
    setup()
    GuiUtils = GuiUtils or {}
    GuiUtils.checkOverlayOverlap = function(x, y, px, py, sx, sy)
        return x >= px and x <= px + sx and y >= py and y <= py + sy
    end
    local cells = { { indexInSection = 1, absPosition = { 0, 0.5 }, absSize = { 1, 0.5 } },
        { indexInSection = 2, absPosition = { 0, 0 }, absSize = { 1, 0.5 } } }
    local list = { absPosition = { 0, 0 }, absSize = { 1, 1 } }
    function list:getIsVisible() return true end
    function list:getElementAtScreenPosition(x, y)
        for _, cell in ipairs(cells) do
            if y >= cell.absPosition[2] and y <= cell.absPosition[2] + cell.absSize[2] then
                return cell
            end
        end
        return nil
    end
    local tooltip = TCTooltip.new({})
    local tips = { [1] = { "Title", "Body" } }
    tooltip:addListTarget(list, function(index)
        local tip = tips[index]
        if tip == nil then
            return nil
        end
        return tip[1], tip[2]
    end)
    g_lastMousePosX, g_lastMousePosY = 0.5, 0.75
    local target = tooltip:getHoveredTarget()
    assertTrue(target ~= nil)
    assertEquals(target.element, cells[1])
    local title, body = target.getContent()
    assertEquals(title, "Title")
    assertEquals(body, "Body")
    assertEquals(tooltip:getHoveredTarget().key, target.key, "the same row, the same key")
    g_lastMousePosY = 0.25
    assertEquals(tooltip:getHoveredTarget(), nil, "a row with no tooltip")
    g_lastMousePosX = 2
    assertEquals(tooltip:getHoveredTarget(), nil, "off the list")
end)
