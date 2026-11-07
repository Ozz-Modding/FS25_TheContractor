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
