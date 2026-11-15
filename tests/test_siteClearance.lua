-- Site clearance (156): what's done to the crop where something's put down
-- on a field (none, flatten, cut or refuse), the rounded patch, and the
-- painting through vanilla's area functions.

local function seeded(seed)
    local state = seed
    return function()
        state = (state * 1103515245 + 12345) % 2147483648
        return state / 2147483648
    end
end

-- Fruit types shaped like vanilla's (growth states from the game's
-- foliage XMLs, simplified).
local function fruit(index, name, def)
    local desc = { index = index, name = name, cutState = def.cut or 0,
        minHarvestingGrowthState = def.harvest or 0, maxHarvestingGrowthState = def.harvest or 0,
        minForageGrowthState = def.forage or 0 }
    function desc:getIsCut(state) return def.cut ~= nil and state >= def.cut end
    return desc
end

local function load()
    local world = stubs.install()
    world:load("src/util/TCJoyriderRuts.lua")
    world:load("src/util/TCSiteClearance.lua")
    -- Wheat: growing 1-7, ready 8, dead 9, cut 10. Maize: growing 1-3,
    -- forage-ready 4-5, ready 6, dead 7, cut 8. Grape: a vine. Spelt: a
    -- mod's crop nobody named.
    FruitType = { UNKNOWN = 0, WHEAT = 2, MAIZE = 5, GRAPE = 20, SPELT = 40 }
    world.fruits = {
        [FruitType.WHEAT] = fruit(FruitType.WHEAT, "WHEAT", { harvest = 8, cut = 10 }),
        [FruitType.MAIZE] = fruit(FruitType.MAIZE, "MAIZE", { harvest = 6, forage = 4, cut = 8 }),
        [FruitType.GRAPE] = fruit(FruitType.GRAPE, "GRAPE", { harvest = 10, cut = 11 }),
        [FruitType.SPELT] = fruit(FruitType.SPELT, "SPELT", { harvest = 8, cut = 10 }),
    }
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index) return world.fruits[index] end,
    }
    g_currentMission.getIsServer = function() return true end
    return world
end

local function rectangle(x1, z1, x2, z2)
    return { { x1, z1 }, { x2, z1 }, { x2, z2 }, { x1, z2 } }
end

-- A field over boundary in fruit at growthState, with painting recorded.
local function setupField(world, boundary, fruitTypeIndex, growthState)
    world.painted = {}
    FSDensityMapUtil = {
        updateWheelDestructionArea = function(sx, sz, wx, wz, hx, hz)
            table.insert(world.painted, { kind = "flatten", sx = sx, sz = sz, wx = wx, wz = wz, hx = hx, hz = hz })
        end,
        cutFruitArea = function(index, sx, sz, wx, wz, hx, hz, destroySpray, useForage, excluded, setsWeeds,
                                limitToField)
            table.insert(world.painted, { kind = "cut", fruit = index, forage = useForage,
                limitToField = limitToField, sx = sx, sz = sz, wx = wx, wz = wz, hx = hx, hz = hz })
        end,
        clearDecoArea = function() end,
    }
    getWorldTranslation = function(node) return node[1], 0, node[2] end
    return {
        fieldState = { fruitTypeIndex = fruitTypeIndex, growthState = growthState },
        getPolygonPoints = function() return boundary end,
        getFieldState = function(self) return self.fieldState end,
        getTeleportPosition = function() return -5, 30 end,
        getId = function() return 12 end,
    }
end

local function middle(call)
    return (call.wx + call.hx) / 2, (call.wz + call.hz) / 2
end

-- Whether (x, z) is in any of the pieces.
local function isCovered(pieces, x, z)
    for _, piece in ipairs(pieces) do
        local sx, sz = piece.sx or piece[1], piece.sz or piece[2]
        local ux, uz = (piece.wx or piece[3]) - sx, (piece.wz or piece[4]) - sz
        local vx, vz = (piece.hx or piece[5]) - sx, (piece.hz or piece[6]) - sz
        local px, pz = x - sx, z - sz
        local det = ux * vz - uz * vx
        local a, b = (px * vz - pz * vx) / det, (ux * pz - uz * px) / det
        if a >= -1e-9 and a <= 1 + 1e-9 and b >= -1e-9 and b <= 1 + 1e-9 then
            return true
        end
    end
    return false
end

-- What's done ---------------------------------------------------------------------

test("nothing standing, or cut: nothing done", function()
    local world = load()
    local T = TCSiteClearance.TREATMENT
    assertEquals(TCSiteClearance.getTreatmentFor(nil, 0), T.NONE)
    assertEquals(TCSiteClearance.getTreatmentFor(world.fruits[FruitType.WHEAT], 0), T.NONE, "sown, not up")
    assertEquals(TCSiteClearance.getTreatmentFor(world.fruits[FruitType.WHEAT], 10), T.NONE, "stubble")
    assertEquals(TCSiteClearance.getTreatmentFor(world.fruits[FruitType.MAIZE], 8), T.NONE, "maize stubble")
end)

test("a crop growing or dead is flattened, one ready is cut", function()
    local world = load()
    local T = TCSiteClearance.TREATMENT
    local wheat = world.fruits[FruitType.WHEAT]
    for state = 1, 7 do
        assertEquals(TCSiteClearance.getTreatmentFor(wheat, state), T.FLATTEN)
    end
    assertEquals(TCSiteClearance.getTreatmentFor(wheat, 9), T.FLATTEN, "dead")
    assertEquals(TCSiteClearance.getTreatmentFor(wheat, 8), T.CUT)
    assertEquals(TCSiteClearance.getCutMode(wheat, 8), "harvest")
    -- A crop nobody named is treated like wheat.
    assertEquals(TCSiteClearance.getTreatmentFor(world.fruits[FruitType.SPELT], 3), T.FLATTEN)
end)

test("a tall crop is refused until it can be cut, and a vine always", function()
    local world = load()
    local T = TCSiteClearance.TREATMENT
    local maize = world.fruits[FruitType.MAIZE]
    for _, state in ipairs({ 1, 2, 3, 7 }) do
        assertEquals(TCSiteClearance.getTreatmentFor(maize, state), T.REFUSE)
    end
    assertEquals(TCSiteClearance.getTreatmentFor(maize, 4), T.CUT, "forage-ready")
    assertEquals(TCSiteClearance.getCutMode(maize, 4), "forage")
    assertEquals(TCSiteClearance.getTreatmentFor(maize, 6), T.CUT)
    assertEquals(TCSiteClearance.getCutMode(maize, 6), "harvest")
    for _, state in ipairs({ 1, 10, 11 }) do
        assertEquals(TCSiteClearance.getTreatmentFor(world.fruits[FruitType.GRAPE], state), T.REFUSE)
    end
end)

test("a field is usable unless refused; one without a state is usable", function()
    local world = load()
    local boundary = rectangle(0, 0, 100, 60)
    assertTrue(TCSiteClearance.isUsableField(setupField(world, boundary, FruitType.WHEAT, 4)))
    assertTrue(TCSiteClearance.isUsableField(setupField(world, boundary, FruitType.UNKNOWN, 0)))
    assertTrue(not TCSiteClearance.isUsableField(setupField(world, boundary, FruitType.MAIZE, 3)))
    assertTrue(TCSiteClearance.isUsableField(setupField(world, boundary, FruitType.MAIZE, 6)))
    assertTrue(TCSiteClearance.isUsableField({ getId = function() return 1 end }))
end)

-- The rounded patch -----------------------------------------------------------------

test("a machine's patch leaves it clear all round, rounded off past it", function()
    load()
    for seed = 1, 10 do
        local heading = seed * 0.7
        local width, length = 3, 8
        local pieces = TCSiteClearance.getMachinePatch(50, 30, heading, width, length, seeded(seed))
        local dx, dz = math.sin(heading), math.cos(heading)
        local nx, nz = dz, -dx
        local margin = TCSiteClearance.MACHINE_MARGIN
        -- Every point of the footprint plus its margin is covered.
        for u = -(width / 2 + margin), width / 2 + margin, 0.25 do
            for v = -(length / 2 + margin), length / 2 + margin, 0.25 do
                assertTrue(isCovered(pieces, 50 + nx * u + dx * v, 30 + nz * u + dz * v),
                    string.format("covered at %.2f, %.2f", u, v))
            end
        end
        -- Its corners are cut off: well inside the bounding box's corner
        -- is left alone.
        local a, b = TCSiteClearance.getEnclosingAxes(width / 2 + margin, length / 2 + margin,
            TCSiteClearance.MACHINE_EXPONENT)
        local u, v = a - 0.3, b + TCSiteClearance.EDGE_JITTER - 0.1
        assertTrue(not isCovered(pieces, 50 + nx * u + dx * v, 30 + nz * u + dz * v), "corner rounded")
        -- And nothing reaches past the shape plus the jitter.
        for _, piece in ipairs(pieces) do
            for i = 0, 2 do
                local px, pz = piece[1 + i * 2] - 50, piece[2 + i * 2] - 30
                local along, across = px * dx + pz * dz, px * nx + pz * nz
                assertTrue(math.abs(across) <= a + TCSiteClearance.STRIP_OVERLAP + 1e-6)
                assertTrue(math.abs(along) <= b + TCSiteClearance.EDGE_JITTER + 1e-6)
            end
        end
    end
end)

test("a pile's patch is round, its middle clear", function()
    load()
    local pieces = TCSiteClearance.getPilePatch(10, 10, 0.3, seeded(2))
    local radius = TCSiteClearance.PILE_SIZE / 2
    for angle = 0, 2 * math.pi, 0.3 do
        assertTrue(isCovered(pieces, 10 + math.cos(angle) * radius * 0.95, 10 + math.sin(angle) * radius * 0.95))
    end
    -- The corner of its bounding square (in its own frame) is left alone.
    local dx, dz = math.sin(0.3), math.cos(0.3)
    local u, v = radius * 0.9, (radius + TCSiteClearance.EDGE_JITTER) * 0.9
    assertTrue(not isCovered(pieces, 10 + dz * u + dx * v, 10 - dx * u + dz * v), "no square corner")
end)

-- Painting ------------------------------------------------------------------------

test("a machine in a growing crop: its run in and its patch flattened, the run in on the field only", function()
    local world = load()
    local boundary = rectangle(0, 0, 100, 60)
    local field = setupField(world, boundary, FruitType.WHEAT, 5)
    -- 6 m in from the bottom edge, facing in (+z).
    local count = TCSiteClearance.paintMachineSite(field, 50, 6, 0, 3, 5, seeded(1))
    assertEquals(count, #world.painted)
    assertTrue(count > 3)
    for _, call in ipairs(world.painted) do
        assertEquals(call.kind, "flatten")
        local x, z = middle(call)
        assertTrue(x > 0 and x < 100 and z > 0 and z < 60, "on the field")
    end
    assertTrue(isCovered(world.painted, 50, 6), "under the machine")
    assertTrue(isCovered(world.painted, 50 - 0.9, 1), "the left track in from the edge")
end)

test("a machine in a ripe crop: the patch cut as a harvest, the run in flattened", function()
    local world = load()
    local field = setupField(world, rectangle(0, 0, 100, 60), FruitType.WHEAT, 8)
    TCSiteClearance.paintMachineSite(field, 50, 6, 0, 3, 5, seeded(1))
    local cuts, flats = 0, 0
    for _, call in ipairs(world.painted) do
        if call.kind == "cut" then
            cuts = cuts + 1
            assertEquals(call.fruit, FruitType.WHEAT)
            assertEquals(call.forage, false)
            assertEquals(call.limitToField, true)
        else
            flats = flats + 1
        end
    end
    assertTrue(cuts > 0 and flats > 0)

    -- Maize ready to forage is cut as forage.
    field.fieldState = { fruitTypeIndex = FruitType.MAIZE, growthState = 4 }
    world.painted = {}
    TCSiteClearance.paintMachineSite(field, 50, 6, 0, 3, 5, seeded(1))
    local forage = false
    for _, call in ipairs(world.painted) do
        forage = forage or (call.kind == "cut" and call.forage == true)
    end
    assertTrue(forage)
end)

test("nothing standing: nothing painted; not the server: nothing at all", function()
    local world = load()
    local field = setupField(world, rectangle(0, 0, 100, 60), FruitType.WHEAT, 10)
    assertEquals(TCSiteClearance.paintMachineSite(field, 50, 6, 0, 3, 5, seeded(1)), 0)
    assertEquals(#world.painted, 0)

    field.fieldState = { fruitTypeIndex = FruitType.WHEAT, growthState = 4 }
    g_currentMission.getIsServer = function() return false end
    assertEquals(TCSiteClearance.paintMachineSite(field, 50, 6, 0, 3, 5, seeded(1)), nil)
    assertEquals(TCSiteClearance.paintDumpSite(field, seeded(1)), nil)
    assertEquals(#world.painted, 0)
end)

test("a dump site is planned by the gate whatever the crop, and painted only in one", function()
    local world = load()
    local field = setupField(world, rectangle(0, 0, 100, 60), FruitType.UNKNOWN, 0)
    local site = TCSiteClearance.paintDumpSite(field, seeded(4))
    assertTrue(site ~= nil)
    assertEquals(site.treatment, TCSiteClearance.TREATMENT.NONE)
    assertNear(site.edgeX, 0, 1e-6)
    assertNear(site.edgeZ, 30, 1e-6)
    assertEquals(#world.painted, 0)

    field.fieldState = { fruitTypeIndex = FruitType.WHEAT, growthState = 6 }
    site = TCSiteClearance.paintDumpSite(field, seeded(4))
    assertEquals(site.treatment, TCSiteClearance.TREATMENT.FLATTEN)
    assertTrue(#world.painted > 2)
    assertTrue(isCovered(world.painted, site.x, site.z), "under the pile")
    for _, call in ipairs(world.painted) do
        assertEquals(call.kind, "flatten", "a van's tracks and the ground round the pile, run over")
    end

    -- A van doesn't harvest: a ripe crop's run over too.
    field.fieldState = { fruitTypeIndex = FruitType.WHEAT, growthState = 8 }
    world.painted = {}
    site = TCSiteClearance.paintDumpSite(field, seeded(4))
    assertEquals(site.treatment, TCSiteClearance.TREATMENT.FLATTEN)
    for _, call in ipairs(world.painted) do
        assertEquals(call.kind, "flatten")
    end
end)
