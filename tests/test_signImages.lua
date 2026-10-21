-- 085's custom sign: one design per image in modSettings' signs/ folder,
-- single-player only, and the README written once into modSettings.

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

-- The custom sign's options as the store item builds them: the xml's company
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

test("anything but a .dds file in signs/ is left out, PNGs and folders too", function()
    setup({ "notes.txt", "open.png", "noextension", "archive.dds", "open.DDS" })
    local items = buildOptions()
    assertEquals(2, #items)
    assertEquals(SIGNS .. "open.DDS", items[2].filename)
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

test("in multiplayer the custom sign leaves the construction menu", function()
    setup({}, true)
    local storeItem = { brush = {}, showInStore = true }
    g_storeManager = {
        getItemByXMLFilename = function(_, filename)
            assertEquals("mods/FS25_TheContractor/xml/customSign.xml", filename)
            return storeItem
        end,
    }
    TCSignImages.hideCustomSignInMultiplayer()
    assertEquals(nil, storeItem.brush)
    assertEquals(false, storeItem.showInStore)
end)

test("in single-player the custom sign stays in the construction menu", function()
    setup({}, false)
    local storeItem = { brush = {}, showInStore = true }
    g_storeManager = { getItemByXMLFilename = function() return storeItem end }
    TCSignImages.hideCustomSignInMultiplayer()
    assertTrue(storeItem.brush ~= nil)
end)

-- The README: written with createFile/fileWrite, never over one already there.
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

test("a README that's already there is left alone", function()
    local written = setupFiles(true)
    TCCompanyLogo.createSettingsFolder()
    assertEquals(nil, written.path)
end)
