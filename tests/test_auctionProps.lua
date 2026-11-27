-- 140: the auction site's dressing, engine half (TCAuctionProps): what it
-- can be checked for outside the game. A row sign's numbers and where its
-- glyphs go, and every prop the layout makes has a model to load.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCAuctionCrowd.lua")
    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/util/TCAuctionScene.lua")
    world:load("src/util/TCAuctionProps.lua")
    return world
end

local function exists(path)
    local file = io.open(path, "rb")
    if file == nil then
        return false
    end
    file:close()
    return true
end

test("a row sign's numbers: a range, or one lot", function()
    setup()
    assertEquals(TCAuctionProps.getLotsText(1, 24), "1-24")
    assertEquals(TCAuctionProps.getLotsText(97, 120), "97-120")
    assertEquals(TCAuctionProps.getLotsText(7, 7), "7")
    assertEquals(TCAuctionProps.getLotsText(nil, nil), "")
end)

test("the glyphs sit side by side, centred on the sign", function()
    setup()
    local glyphs = TCAuctionProps.layOutGlyphs("12-240", 0.1, 0.1)
    assertEquals(#glyphs, 6)
    assertEquals(glyphs[3].char, "-")
    assertNear(glyphs[1].x, -0.25, 0.0001)
    assertNear(glyphs[6].x, 0.25, 0.0001)
    for i = 2, #glyphs do
        assertNear(glyphs[i].x - glyphs[i - 1].x, 0.1, 0.0001)
    end
    -- A sign has six digit slots and a dash: the longest range fits.
    local digits = 0
    for _, glyph in ipairs(TCAuctionProps.layOutGlyphs(TCAuctionProps.getLotsText(100, 999), 0.1, 0.1)) do
        if glyph.char ~= "-" then
            digits = digits + 1
        end
    end
    assertTrue(digits <= 6)
end)

test("every prop the layout makes has a model, and ours are in the mod", function()
    setup()
    local lots = {}
    for i = 1, 60 do
        lots[i] = { width = 3, length = 6 }
    end
    local polygon = { { x = 0, z = 0 }, { x = 400, z = 0 }, { x = 400, z = 220 }, { x = 0, z = 220 } }
    local layout = TCAuctionLayout.layOut(polygon, { x = 420, z = 90 }, lots)
    local dressed = TCAuctionScene.layOut(TCAuctionLayout.getScene(layout, { x = 420, z = 90 }, 5))
    local kinds = {}
    for _, prop in ipairs(dressed.props) do
        kinds[prop.kind] = true
    end
    for kind in pairs(kinds) do
        if kind == "car" then
            assertTrue(#TCAuctionScene.CAR_MODELS > 0)
        else
            local model = TCAuctionProps.MODELS[kind]
            assertTrue(model ~= nil, "no model for " .. kind)
            if model.isMod then
                assertTrue(exists(model.filename), model.filename .. " isn't in the mod")
            end
        end
    end
    -- The site sign's faces are the layout's, the gate's apart.
    local faces = {}
    for _, face in ipairs(TCAuctionProps.SIGN_FACES) do
        faces[face] = true
    end
    for _, face in pairs(TCAuctionScene.FACES) do
        assertTrue(face == TCAuctionScene.FACES.GATE or faces[face], "the sign has no " .. face .. " face")
    end
end)

local function setupShow()
    local world = setup()
    world:load("src/util/TCShowClasses.lua")
    world:load("src/util/TCShowPens.lua")
    world:load("src/util/TCShowScene.lua")
    return world
end

test("182: the rosette has a model in the mod and a face for every colour", function()
    setupShow()
    local model = TCAuctionProps.MODELS.rosette
    assertTrue(model ~= nil and model.isMod and exists(model.filename))
    local faces = {}
    for _, face in ipairs(TCAuctionProps.ROSETTE_FACES) do
        faces[face] = true
    end
    for _, colour in ipairs(TCShowScene.ROSETTE_COLOURS) do
        assertTrue(faces[colour], "no face for " .. colour)
    end
    assertTrue(faces[TCShowScene.ROSETTE_CHAMPION])
end)

test("182: the pens' props come from the show's livestock, only on the show's site", function()
    setupShow()
    local livestock = { pens = {}, penVersion = 3 }
    g_currentMission.TheContractor = { ShowLivestock = livestock }
    assertTrue(TCAuctionProps.getLateSource({ dressing = "show" }) == livestock)
    assertEquals(TCAuctionProps.getLateSource({ dressing = "auction" }), nil, "not the show's site")
    assertEquals(TCAuctionProps.getLateSource(nil), nil)
end)

test("182: an animal's posed model is its subtype's visual for its age; none without one", function()
    setupShow()
    local young = { filenamePosed = "young_posed.i3d", variations = {} }
    local adult = { filenamePosed = "adult_posed.i3d", variations = {} }
    g_currentMission.animalSystem = {
        getSubTypeIndexByName = function(_, name) return name == "COW_HOLSTEIN" and 3 or nil end,
        getVisualByAge = function(_, index, age)
            assertEquals(index, 3)
            return { visualAnimal = age >= 18 and adult or young }
        end,
    }
    assertTrue(TCAuctionProps.getVisualAnimal({ subTypeName = "COW_HOLSTEIN", age = 6 }) == young)
    assertTrue(TCAuctionProps.getVisualAnimal({ subTypeName = "COW_HOLSTEIN", age = 30 }) == adult)
    assertEquals(TCAuctionProps.getVisualAnimal({ subTypeName = "PIG", age = 30 }), nil)
    adult.filenamePosed = nil
    assertEquals(TCAuctionProps.getVisualAnimal({ subTypeName = "COW_HOLSTEIN", age = 30 }), nil)
    assertTrue(TCAuctionProps.MODELS.animal ~= nil and TCAuctionProps.MODELS.animal.wholeFile)
end)
