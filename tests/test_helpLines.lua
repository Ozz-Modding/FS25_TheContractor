-- The in-game help pages (modDesc's helpLines): vanilla shows a missing
-- l10n key as the raw key and drops an icon it can't find, without a
-- word in the log, so every key and icon slot is checked here.

local function readFile(path)
    local file = io.open(path, "r")
    assert(file ~= nil, "can't open " .. path)
    local content = file:read("*a")
    file:close()
    return content
end

local function getHelpLines()
    local helpLines = readFile("modDesc.xml"):match("<helpLines>(.-)</helpLines>")
    assert(helpLines ~= nil, "modDesc.xml has no helpLines")
    return helpLines
end

local function getSlices()
    local slices = {}
    for id in readFile("xml/helpIcons.xml"):gmatch("<slice%s+id=\"([^\"]+)\"") do
        slices[id] = true
    end
    return slices
end

test("every help text in modDesc is in the l10n", function()
    local world = stubs.install()
    local count = 0
    for key in getHelpLines():gmatch("%$l10n_([%w_]+)") do
        assertTrue(world.texts[key] ~= nil, "missing l10n key " .. key)
        count = count + 1
    end
    assertTrue(count > 0, "no help texts found")
end)

test("every help l10n key is used by a page", function()
    local world = stubs.install()
    local used = {}
    for key in getHelpLines():gmatch("%$l10n_([%w_]+)") do
        used[key] = true
    end
    for key in pairs(world.texts) do
        if key:find("^tc_help_") ~= nil then
            assertTrue(used[key], "help text " .. key .. " isn't on any page")
        end
    end
end)

test("every help page has its own icon slot in the sheet", function()
    local slices = getSlices()
    local seen = {}
    local pages = 0
    for page in getHelpLines():gmatch("<page%s[^>]*>") do
        local sliceId = page:match("iconSliceId=\"tcHelpIcons%.([%w_]+)\"")
        assertTrue(sliceId ~= nil, "a help page has no tcHelpIcons icon: " .. page)
        assertTrue(slices[sliceId], "no slice for help icon " .. sliceId .. " (run dev/tools/genHelpIcons.py)")
        assertTrue(not seen[sliceId], "two help pages share icon " .. sliceId)
        seen[sliceId] = true
        pages = pages + 1
    end
    assertTrue(pages > 0, "no help pages found")
end)

test("the icon sheet is registered under the prefix the pages use", function()
    local main = readFile("src/main.lua")
    assertTrue(main:find("addTextureConfigFile%(TheContractor%.dir %.%. \"xml/helpIcons%.xml\", \"tcHelpIcons\"%)") ~= nil,
        "main.lua doesn't register xml/helpIcons.xml as tcHelpIcons")
end)

test("the icon config's image is found from the config's own folder", function()
    -- OverlayManager:addTextureConfigFile joins <filename> onto the config's folder.
    local filename = readFile("xml/helpIcons.xml"):match("<filename>(.-)</filename>")
    assertTrue(filename ~= nil, "xml/helpIcons.xml has no filename")
    local image = io.open("xml/" .. filename, "rb")
    assertTrue(image ~= nil, "xml/" .. filename .. " doesn't exist")
    image:close()
end)
