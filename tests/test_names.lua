-- Name styles (TCNames and the nameStyle setting): every style and mix
-- gives a name that fits the edit limit, first name and surname come from
-- one style, Polish surnames follow gender, and Staff reads the setting.

local function setup(nameStyle)
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    Enterable = {}
    world:load("src/util/TCNames.lua")
    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")

    local settings = TheContractorSettings.new()
    if nameStyle ~= nil then
        settings:set("nameStyle", nameStyle)
    end
    g_currentMission.TheContractor = { Settings = settings }
    return world, settings
end

-- Characters, not bytes: the lists use accented letters.
local function utf8Length(text)
    local _, continuationBytes = string.gsub(text, "[\128-\191]", "")
    return string.len(text) - continuationBytes
end

local function contains(list, value)
    for _, candidate in ipairs(list) do
        if candidate == value then
            return true
        end
    end
    return false
end

local function styleOf(name)
    for _, styleKey in ipairs(TCNames.STYLE_ORDER) do
        local style = TCNames.STYLES[styleKey]
        for _, gender in ipairs({ "male", "female" }) do
            for _, firstName in ipairs(style[gender]) do
                for _, entry in ipairs(style.surnames) do
                    if name == firstName .. " " .. TCNames.getSurname(entry, gender) then
                        return styleKey
                    end
                end
            end
        end
    end
    return nil
end

test("every setting option is a style or a mix, with its l10n text", function()
    setup()
    for _, key in ipairs(TheContractorSettings.NAME_STYLES) do
        assertTrue(TCNames.STYLES[key] ~= nil or TCNames.MIXES[key] ~= nil or key == "all", key .. " unknown")
        g_i18n:getText("tc_nameStyle_" .. key)
    end
    for _, key in ipairs(TCNames.STYLE_ORDER) do
        assertTrue(contains(TheContractorSettings.NAME_STYLES, key), key .. " has no setting option")
    end
    for _, key in ipairs(TCNames.MIXES.european) do
        assertTrue(TCNames.STYLES[key] ~= nil, "european mix names unknown style " .. key)
    end
end)

test("every style has a good library of names", function()
    setup()
    for _, styleKey in ipairs(TCNames.STYLE_ORDER) do
        local style = TCNames.STYLES[styleKey]
        assertTrue(#style.male >= 30, styleKey .. " male names")
        assertTrue(#style.female >= 30, styleKey .. " female names")
        assertTrue(#style.surnames >= 50, styleKey .. " surnames")
    end
end)

test("no list repeats a name", function()
    setup()
    for _, styleKey in ipairs(TCNames.STYLE_ORDER) do
        local style = TCNames.STYLES[styleKey]
        for _, listKey in ipairs({ "male", "female", "surnames" }) do
            local seen = {}
            for _, entry in ipairs(style[listKey]) do
                local text = TCNames.getSurname(entry, "male")
                assertTrue(not seen[text], styleKey .. " " .. listKey .. " repeats " .. text)
                seen[text] = true
            end
        end
    end
end)

test("the longest name in every style fits the edit limit", function()
    setup()
    for _, styleKey in ipairs(TCNames.STYLE_ORDER) do
        local style = TCNames.STYLES[styleKey]
        for _, gender in ipairs({ "male", "female" }) do
            local longestFirst, longestSurname = 0, 0
            for _, firstName in ipairs(style[gender]) do
                longestFirst = math.max(longestFirst, utf8Length(firstName))
            end
            for _, entry in ipairs(style.surnames) do
                longestSurname = math.max(longestSurname, utf8Length(TCNames.getSurname(entry, gender)))
            end
            assertTrue(longestFirst + 1 + longestSurname <= TheContractorStaff.NAME_MAX_LENGTH,
                styleKey .. " " .. gender .. " can be too long")
        end
    end
end)

test("a style's names come from that style only", function()
    setup()
    for _, styleKey in ipairs(TCNames.STYLE_ORDER) do
        local style = TCNames.STYLES[styleKey]
        for _ = 1, 50 do
            local gender = math.random(2) == 1 and "male" or "female"
            local name = TCNames.generate(gender, styleKey)
            local firstName = string.match(name, "^(%S+)")
            assertTrue(contains(style[gender], firstName), name .. " isn't a " .. styleKey .. " " .. gender .. " name")
        end
    end
end)

test("Polish surnames follow the gender", function()
    setup()
    local sawMale, sawFemale = false, false
    for _ = 1, 400 do
        local male = TCNames.generate("male", "polish")
        local female = TCNames.generate("female", "polish")
        assertTrue(string.match(female, "ski$") == nil and string.match(female, "cki$") == nil, female)
        assertTrue(string.match(male, "ska$") == nil and string.match(male, "cka$") == nil, male)
        sawMale = sawMale or string.match(male, "ski$") ~= nil
        sawFemale = sawFemale or string.match(female, "ska$") ~= nil
    end
    assertTrue(sawMale and sawFemale, "gendered surnames rolled")
end)

test("the European mix draws whole names from several European styles", function()
    setup()
    local styles = {}
    for _ = 1, 400 do
        local styleKey = styleOf(TCNames.generate("female", "european"))
        assertTrue(styleKey ~= nil, "name from one style")
        assertTrue(contains(TCNames.MIXES.european, styleKey), styleKey .. " isn't European")
        styles[styleKey] = true
    end
    local count = 0
    for _ in pairs(styles) do
        count = count + 1
    end
    assertTrue(count >= 5, "only " .. count .. " styles")
end)

test("Mixed can draw American names", function()
    setup()
    local sawAmerican = false
    for _ = 1, 600 do
        local name = TCNames.generate("male", "all")
        assertTrue(styleOf(name) ~= nil, name)
        sawAmerican = sawAmerican or styleOf(name) == "american"
    end
    assertTrue(sawAmerican, "american picked")
end)

test("Staff names follow the setting, British by default", function()
    local _, settings = setup()
    assertEquals(settings:getNameStyle(), "british")
    local index = 0
    for i, key in ipairs(TheContractorSettings.NAME_STYLES) do
        if key == "italian" then
            index = i
        end
    end
    settings:set("nameStyle", index)
    assertEquals(settings:getNameStyle(), "italian")
    for _ = 1, 30 do
        local firstName = string.match(TheContractorStaff.generateName("female"), "^(%S+)")
        assertTrue(contains(TCNames.STYLES.italian.female, firstName), firstName)
    end
end)

test("an old save's gender is guessed from any style's first name", function()
    setup()
    assertEquals(TheContractorStaff.guessGender("Sarah Smith"), "female")
    assertEquals(TheContractorStaff.guessGender("Małgorzata Nowak"), "female")
    assertEquals(TheContractorStaff.guessGender("Søren Hansen"), "male")
end)

test("the setting saves its option number and loads back", function()
    local _, settings = setup()
    settings:set("nameStyle", 11)
    local xmlFile = {}
    settings:saveToXmlFile(xmlFile)
    local loaded = TheContractorSettings.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getNameStyle(), "european")
end)
