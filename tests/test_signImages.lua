-- 085's sign designs: one per image in modSettings' signs/ folder,
-- single-player only, on every sign (084, 087), and the README written
-- into modSettings.

local SETTINGS = "modSettings/FS25_TheContractor/"
local SIGNS = SETTINGS .. "signs/"

-- files: names in signs/ (the order getFiles happens to return them in).
local function setup(files, isMultiplayer)
    local world = stubs.install()
    TheContractor = { dir = "mods/FS25_TheContractor/" }
    g_currentModSettingsDirectory = SETTINGS
    g_currentMission.missionDynamicInfo = { isMultiplayer = isMultiplayer == true }

    local existing = {}
    for _, name in ipairs(files) do
        existing[SIGNS .. name] = true
    end
    fileExists = function(path)
        return existing[path] == true
    end
    -- The engine's getFiles: a callback per entry, folders flagged.
    getFiles = function(folder, callbackName, target)
        assertEquals("modSettings/FS25_TheContractor/signs", folder)
        for _, name in ipairs(files) do
            target[callbackName](target, name, name == "archive.dds")
        end
    end

    -- The engine's Class: instances look methods up in the class, and the
    -- class in its base.
    Class = function(classTable, base)
        if base ~= nil then
            setmetatable(classTable, { __index = base })
        end
        return { __index = classTable }
    end
    PlaceableConfigurationItem = {
        new = function(configName, customMt)
            return setmetatable({ configName = configName, name = "", index = -1 }, customMt)
        end,
        setIndex = function(self, index)
            self.index = index
            if self.saveId == nil then
                self.saveId = tostring(index)
            end
        end,
        postLoad = function() end,
    }

    dofile("src/util/TCSignImages.lua")
    dofile("src/util/TCCompanyLogo.lua")
    dofile("src/placeables/PlaceableTCLogoSign.lua")
    return world
end

-- A sign's design options as the store item builds them: the xml's company
-- logo, then whatever postLoad adds.
local function buildOptions()
    local logo = TCSignDesignConfigurationItem.new("tcSignDesign")
    logo.name = "Company logo"
    logo.saveId = "logo"
    logo.configKey = "placeable.tcSignDesignConfigurations.tcSignDesignConfiguration(0)"
    logo.overwrittenTitle = "Design"
    logo:setIndex(1)
    local items = { logo }
    TCSignDesignConfigurationItem.postLoad(nil, nil, nil, nil, true, items, nil, "tcSignDesign")
    return items
end

local function signWithDesign(items, configId)
    return {
        configurations = { tcSignDesign = configId },
        storeItem = { configurations = { tcSignDesign = items } },
    }
end

test("each image in signs/ is a design, after the company logo, sorted by name", function()
    setup({ "keep_out.dds", "For-Sale.dds" })
    local items = buildOptions()
    assertEquals(3, #items)
    assertEquals("Company logo", items[1].name)
    assertEquals("For Sale", items[2].name)
    assertEquals("sign_for-sale", items[2].saveId)
    assertEquals(SIGNS .. "For-Sale.dds", items[2].filename)
    assertEquals(2, items[2].index)
    assertEquals("Keep Out", items[3].name)
    assertEquals(3, items[3].index)
    assertEquals(items[1].configKey, items[3].configKey)
    assertEquals("Design", items[3].overwrittenTitle)
end)

test("anything but a .dds or .png file in signs/ is left out, folders too", function()
    setup({ "notes.txt", "noextension", "archive.dds", "open.DDS", "closed.PNG" })
    local items = buildOptions()
    assertEquals(3, #items)
    assertEquals(SIGNS .. "closed.PNG", items[2].filename)
    assertEquals(SIGNS .. "open.DDS", items[3].filename)
end)

test("a .dds and a .png of the same name are one design, the .dds", function()
    setup({ "open.png", "Open.dds", "closed.png" })
    local items = buildOptions()
    assertEquals(3, #items)
    assertEquals("sign_closed", items[2].saveId)
    assertEquals("sign_open", items[3].saveId)
    assertEquals(SIGNS .. "Open.dds", items[3].filename)
end)

test("in multiplayer the only design is the company logo", function()
    setup({ "keep_out.dds", "for_sale.dds" }, true)
    assertEquals(1, #buildOptions())
end)

test("no more designs than a configuration can send", function()
    local files = {}
    for i = 1, 130 do
        table.insert(files, string.format("sign%03d.dds", i))
    end
    local world = setup(files)
    assertEquals(1 + TCSignImages.MAX_IMAGES, #buildOptions())
    assertEquals(1, #world.warnings)
end)

test("a sign shows its design's image, whoever owns it", function()
    setup({ "keep_out.dds" })
    local items = buildOptions()
    local design = PlaceableTCLogoSign.getDesignFilename(signWithDesign(items, 2))
    assertEquals(SIGNS .. "keep_out.dds", design)
    assertEquals(SIGNS .. "keep_out.dds", PlaceableTCLogoSign.getLogoFilename(3, 2, false, design))
end)

test("the company logo design, a missing image or the logo sign show the logo", function()
    setup({ "keep_out.dds" })
    local items = buildOptions()
    assertEquals(nil, PlaceableTCLogoSign.getDesignFilename(signWithDesign(items, 1)))
    fileExists = function() return false end
    assertEquals(nil, PlaceableTCLogoSign.getDesignFilename(signWithDesign(items, 2)))
    assertEquals(nil, PlaceableTCLogoSign.getDesignFilename({ configurations = {}, storeItem = {} }))
end)

-- Every sign store item (084's company sign, 087's wall signs) offers the
-- designs, and its logo faces' mappings reach a shape in its i3d.
local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

-- An i3dMapping's "0>0|2" in an i3d's <Scene>: the first top-level node,
-- then its first child, then that child's third. Returns the tag name and
-- the node's name.
local function resolveMapping(i3d, mapping)
    local component, path = mapping:match("^(%d+)>(.*)$")
    local indexes = { tonumber(component) }
    for index in path:gmatch("%d+") do
        table.insert(indexes, tonumber(index))
    end
    local scene = i3d:match("<Scene>(.-)</Scene>")
    -- Walk the tags, keeping the child index at each depth.
    local depth, counts, found = 0, { [0] = -1 }, nil
    for closing, tag, attributes, selfClosing in scene:gmatch("<(/?)(%w+)([^>]-)(/?)>") do
        if closing == "/" then
            depth = depth - 1
        else
            counts[depth] = counts[depth] + 1
            local matches = depth < #indexes
            for d = 0, depth do
                matches = matches and counts[d] == indexes[d + 1]
            end
            if matches and depth == #indexes - 1 then
                found = { tag = tag, name = attributes:match('name="([^"]*)"') }
            end
            if selfClosing ~= "/" then
                depth = depth + 1
                counts[depth] = -1
            end
        end
    end
    return found
end

test("every sign store item offers designs and maps its logo faces to shapes", function()
    local signs = 0
    for xmlFilename in readFile("modDesc.xml"):gmatch('<storeItem xmlFilename="([^"]+)"') do
        local xml = readFile(xmlFilename)
        if xml:find('type="FS25_TheContractor.tcLogoSign"', 1, true) ~= nil then
            signs = signs + 1
            assertTrue(xml:find('<tcSignDesignConfiguration name="$l10n_tc_signDesign_logo" saveId="logo" isDefault="true"', 1, true) ~= nil,
                xmlFilename .. " has no design configuration")
            local i3d = readFile(xml:match("<filename>([^<]+)</filename>"))
            local mappings = {}
            for id, node in xml:gmatch('<i3dMapping id="([^"]+)" node="([^"]+)"') do
                mappings[id] = node
            end
            local faces = 0
            for face in xml:gmatch('<face node="([^"]+)"') do
                faces = faces + 1
                local node = resolveMapping(i3d, assert(mappings[face], xmlFilename .. ": no mapping for " .. face))
                assertTrue(node ~= nil and node.tag == "Shape", xmlFilename .. ": " .. face .. " isn't a shape")
                assertEquals(node.name, face)
            end
            assertTrue(faces > 0, xmlFilename .. " has no logo faces")
        end
    end
    -- The company sign and six wall signs.
    assertEquals(signs, 7)
end)

-- The README: written with createFile/fileWrite on every load, over any one already there.
local function setupFiles(readmeExists)
    setup({})
    local written = {}
    local folders = {}
    createFolder = function(path) table.insert(folders, path) end
    FileAccess = { WRITE = 1 }
    createFile = function(path) written.path = path return 7 end
    fileWrite = function(file, text) written.text = (written.text or "") .. text end
    delete = function(file) written.closed = file end
    fileExists = function(path) return readmeExists and path == SETTINGS .. "README.txt" end
    return written, folders
end

test("the settings folder gets a signs folder and a README covering the logo and signs", function()
    local written, folders = setupFiles(false)
    TCCompanyLogo.createSettingsFolder()
    assertEquals(SETTINGS, folders[1])
    assertEquals(SIGNS, folders[2])
    assertEquals(SETTINGS .. "README.txt", written.path)
    assertEquals(7, written.closed)
    assertTrue(written.text:find("logo.dds", 1, true) ~= nil)
    assertTrue(written.text:find("signs folder", 1, true) ~= nil)
    assertTrue(written.text:find("\r\n", 1, true) ~= nil)
end)

test("a README that's already there is rewritten", function()
    local written = setupFiles(true)
    TCCompanyLogo.createSettingsFolder()
    assertEquals(SETTINGS .. "README.txt", written.path)
    assertTrue(written.text:find("savegame1", 1, true) ~= nil)
end)
