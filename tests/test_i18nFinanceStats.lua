-- Our Finances screen rows: vanilla's FinanceStats.new names each stat with
-- g_i18n:getText("finance_" .. statName) and no mod env, which only our
-- I18N.getText patch fixes. Another mod's getText wrapper that drops the
-- env broke that, so the names are also put in straight from our own text
-- table after new runs.

local function readFile(path)
    local file = io.open(path, "r")
    assert(file ~= nil, "can't open " .. path)
    local content = file:read("*a")
    file:close()
    return content
end

-- Every stat name a src/ file registers with FinanceStats.
local function getRegisteredStatNames()
    local names = {}
    local listing = io.popen('dir /b /s src\\*.lua 2>nul || find src -name "*.lua"')
    for path in listing:lines() do
        for name in readFile(path):gmatch("table%.insert%(FinanceStats%.statNames,%s*\"([^\"]+)\"%)") do
            table.insert(names, name)
        end
    end
    listing:close()
    return names
end

local function setup()
    local world = stubs.install()
    -- Vanilla's new, behind a getText wrapper that drops the mod env (so
    -- every one of our keys comes back as the missing-text placeholder).
    FinanceStats = { statNames = { "other", "tcJobPayout", "tcWages" }, statNamesI18n = {} }
    function FinanceStats.new()
        local self = {}
        for _, statName in ipairs(FinanceStats.statNames) do
            self[statName] = 0
            FinanceStats.statNamesI18n[statName] = "missing:" .. statName
        end
        return self
    end
    I18N = { getText = function() return "missing" end }
    -- The mod's own I18N instance: our l10n's texts.
    g_i18n.texts = { finance_tcJobPayout = "jobPayoutText", finance_tcWages = "wagesText" }
    world:load("src/extensions/TCI18NExtension.lua")
    return world
end

test("FinanceStats.new still returns the stats", function()
    setup()
    local stats = FinanceStats.new()
    assertTrue(stats ~= nil)
    assertEquals(0, stats.tcJobPayout)
end)

test("our stats are named from our own texts, past a getText that drops the mod env", function()
    setup()
    FinanceStats.new()
    assertEquals("jobPayoutText", FinanceStats.statNamesI18n.tcJobPayout)
    assertEquals("wagesText", FinanceStats.statNamesI18n.tcWages)
end)

test("vanilla's own stats are left alone", function()
    setup()
    FinanceStats.new()
    assertEquals("missing:other", FinanceStats.statNamesI18n.other)
end)

test("every registered stat has both keys listed and in the l10n", function()
    local world = setup()
    local names = getRegisteredStatNames()
    assertTrue(#names > 0)
    for _, name in ipairs(names) do
        local financeKey = "finance_" .. name
        assertTrue(TCI18NExtension.theContractorTexts[financeKey] == true, financeKey .. " not in theContractorTexts")
        assertTrue(world.texts[financeKey] ~= nil, financeKey .. " not in l10n_en.xml")
    end
end)
