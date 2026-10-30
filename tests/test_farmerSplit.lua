-- 109: dividing the land between farmers - every farmland claimed once,
-- how many farmers, holdings near their targets, the same seed giving the
-- same split, yards starting farmers, and player-owned land left out.

local function setup()
    local world = stubs.install()
    world:load("src/business/FarmerSplit.lua")
    return world
end

-- A cols x rows grid of farmlands 300 m apart, ids from 1 along the rows,
-- each `acres` (a number, or a function of the id).
local function grid(cols, rows, acres)
    local farmlands = {}
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local id = row * cols + col + 1
            table.insert(farmlands, { id = id, x = col * 300, z = row * 300,
                acres = type(acres) == "function" and acres(id) or acres })
        end
    end
    return farmlands
end

local function ownerCounts(result)
    local counts = {}
    for _, farmer in ipairs(result.farmers) do
        for _, farmlandId in ipairs(farmer.farmlandIds) do
            counts[farmlandId] = (counts[farmlandId] or 0) + 1
        end
    end
    return counts
end

local function findFarmer(result, farmlandId)
    return result.farmers[result.owners[farmlandId]]
end

test("every farmland is claimed exactly once, and the acres add up", function()
    setup()
    local farmlands = grid(8, 6, function(id) return 5 + (id * 7) % 23 end)
    local result = TheContractorFarmerSplit.split(farmlands, {}, 60, 42)

    local counts = ownerCounts(result)
    local total = 0
    for _, farmland in ipairs(farmlands) do
        assertEquals(1, counts[farmland.id])
        assertTrue(result.owners[farmland.id] ~= nil)
        total = total + farmland.acres
    end
    local held = 0
    for _, farmer in ipairs(result.farmers) do
        assertTrue(#farmer.farmlandIds > 0)
        held = held + farmer.acres
    end
    assertNear(total, held, 0.001)
    assertNear(total, result.totalAcres, 0.001)
end)

test("the farmer count follows the target, with at least four", function()
    setup()
    -- 48 farmlands of 20 acres: 960 acres.
    local farmlands = grid(8, 6, 20)
    assertEquals(16, #TheContractorFarmerSplit.split(farmlands, {}, 60, 1).farmers)
    assertEquals(10, #TheContractorFarmerSplit.split(farmlands, {}, 100, 1).farmers)
    -- 960 / 500 rounds to 2, but a map always gets four.
    assertEquals(4, #TheContractorFarmerSplit.split(farmlands, {}, 500, 1).farmers)

    -- A tiny map: never more farmers than farmlands.
    assertEquals(3, #TheContractorFarmerSplit.split(grid(3, 1, 10), {}, 30, 1).farmers)
    assertEquals(0, #TheContractorFarmerSplit.split({}, {}, 30, 1).farmers)
end)

test("targets stay within the spread and add up to the total", function()
    setup()
    local random = TheContractorFarmerSplit.newRandom(7)
    local targets = TheContractorFarmerSplit.getTargets(1000, 10, random)
    local sum = 0
    local spread = TheContractorFarmerSplit.SIZE_SPREAD
    for _, target in ipairs(targets) do
        sum = sum + target
        -- Normalising can push one a little past the raw factor's range.
        assertTrue(target >= 100 * (1 - spread) / (1 + spread))
        assertTrue(target <= 100 * (1 + spread) / (1 - spread))
    end
    assertNear(1000, sum, 0.001)
end)

test("holdings end up near their targets", function()
    setup()
    -- Plenty of small farmlands, so an even split is possible.
    local farmlands = grid(12, 10, function(id) return 8 + (id * 5) % 9 end)
    local result = TheContractorFarmerSplit.split(farmlands, {}, 120, 3)
    assertTrue(#result.farmers >= 10)
    for _, farmer in ipairs(result.farmers) do
        -- Within the largest farmland (16 acres) and a bit of the target.
        assertTrue(math.abs(farmer.acres - farmer.target) <= 16 + farmer.target * 0.15)
    end
end)

test("after balancing, no move between neighbours would bring both nearer their targets", function()
    setup()
    local S = TheContractorFarmerSplit
    local farmlands = grid(8, 6, function(id) return 5 + (id * 7) % 23 end)
    local result = S.split(farmlands, {}, 60, 6)
    assertTrue(result.moves > 0)

    local byId = {}
    for _, farmland in ipairs(farmlands) do
        byId[farmland.id] = farmland
    end
    for _, farmland in ipairs(farmlands) do
        local from = findFarmer(result, farmland.id)
        if #from.farmlandIds > 1 then
            local fromError = from.acres - from.target
            for _, to in ipairs(result.farmers) do
                local near = false
                for _, otherId in ipairs(to.farmlandIds) do
                    local other = byId[otherId]
                    if math.sqrt((other.x - farmland.x) ^ 2 + (other.z - farmland.z) ^ 2) <= S.MAX_SWAP_DISTANCE then
                        near = true
                    end
                end
                if to ~= from and near then
                    local toError = to.acres - to.target
                    assertTrue(not (math.abs(fromError - farmland.acres) < math.abs(fromError) and
                        math.abs(toError + farmland.acres) < math.abs(toError)))
                end
            end
        end
    end
end)

test("the same seed gives the same split, another seed can differ", function()
    setup()
    local farmlands = grid(8, 6, function(id) return 5 + (id * 7) % 23 end)
    local yards = { { farmlandId = 10, x = 300, z = 300 } }
    local a = TheContractorFarmerSplit.split(farmlands, yards, 60, 1234)
    local b = TheContractorFarmerSplit.split(farmlands, yards, 60, 1234)
    for _, farmland in ipairs(farmlands) do
        assertEquals(a.owners[farmland.id], b.owners[farmland.id])
    end
    for i, farmer in ipairs(a.farmers) do
        assertEquals(farmer.target, b.farmers[i].target)
        assertEquals(farmer.yardFarmlandId, b.farmers[i].yardFarmlandId)
    end

    local differs = false
    for seed = 1, 5 do
        local c = TheContractorFarmerSplit.split(farmlands, yards, 60, seed)
        for _, farmland in ipairs(farmlands) do
            if c.owners[farmland.id] ~= a.owners[farmland.id] then
                differs = true
            end
        end
    end
    assertTrue(differs)
end)

test("yards on or near field land start farmers, nearest first", function()
    setup()
    local farmlands = grid(6, 6, 20)
    local S = TheContractorFarmerSplit
    local yards = {
        -- On an eligible farmland.
        { farmlandId = 8, x = 300, z = 300 },
        -- A farmland with no fields, just off farmland 36's middle.
        { farmlandId = 90, x = 1500 + 100, z = 1500 },
        -- Too far from any field land to start anyone.
        { farmlandId = 91, x = 1500 + S.MAX_YARD_DISTANCE + 500, z = 0 },
    }
    local result = S.split(farmlands, yards, 120, 5)

    assertEquals(6, #result.farmers)
    local first, second = result.farmers[1], result.farmers[2]
    assertEquals(8, first.yardFarmlandId)
    assertTrue(first.startedAtYard)
    -- The yard's own farmland is in the holding.
    assertEquals(first.index, result.owners[8])
    assertEquals(90, second.yardFarmlandId)
    assertTrue(second.startedAtYard)
    assertEquals(second.index, result.owners[36])
    for _, farmer in ipairs(result.farmers) do
        assertTrue(farmer.yardFarmlandId ~= 91)
    end
end)

test("more yards than farmers: the rest go to a nearby farmer without one", function()
    setup()
    local farmlands = grid(4, 1, 30)
    local yards = {}
    -- A yard on each of the four farmlands, plus one more beside farmland 1.
    for id = 1, 4 do
        table.insert(yards, { farmlandId = id, x = (id - 1) * 300, z = 0 })
    end
    table.insert(yards, { farmlandId = 50, x = 0, z = 150 })
    local result = TheContractorFarmerSplit.split(farmlands, yards, 1000, 9)

    assertEquals(4, #result.farmers)
    local used = {}
    for _, farmer in ipairs(result.farmers) do
        assertTrue(farmer.yardFarmlandId ~= nil)
        assertTrue(not used[farmer.yardFarmlandId])
        used[farmer.yardFarmlandId] = true
    end
    -- The fifth is left over: farmer 1, nearest it, has a yard already.
    assertTrue(not used[50])
    assertEquals(1, findFarmer(result, 1).yardFarmlandId)
end)

test("a farmer can have land and no yard", function()
    setup()
    local result = TheContractorFarmerSplit.split(grid(4, 4, 25), {}, 100, 2)
    for _, farmer in ipairs(result.farmers) do
        assertEquals(nil, farmer.yardFarmlandId)
        assertTrue(#farmer.farmlandIds > 0)
    end
end)

test("only unowned farmlands with fields are split, in acres", function()
    setup()
    local function field(farmlandId, areaHa, x, z)
        return {
            getFarmland = function() return { getId = function() return farmlandId end } end,
            getAreaHa = function() return areaHa end,
            getCenterOfFieldWorldPosition = function() return x, z end,
        }
    end
    g_fieldManager = {
        getFields = function()
            return {
                -- Farmland 1: two fields, its middle weighted by area.
                field(1, 3, 0, 0),
                field(1, 1, 400, 0),
                -- Farmland 2: the player's.
                field(2, 10, 1000, 0),
                -- Farmland 3: one field.
                field(3, 2, 0, 500),
            }
        end,
    }
    g_farmlandManager = {
        getFarmlandOwner = function(_, farmlandId)
            return farmlandId == 2 and 1 or FarmlandManager.NO_OWNER_FARM_ID
        end,
    }

    local farmlands = TheContractorFarmerSplit.getEligibleFarmlands()
    assertEquals(2, #farmlands)
    assertEquals(1, farmlands[1].id)
    assertNear(4 * TheContractorFarmerSplit.ACRES_PER_HA, farmlands[1].acres, 0.001)
    assertNear(100, farmlands[1].x, 0.001)
    assertEquals(3, farmlands[2].id)
    assertNear(500, farmlands[2].z, 0.001)
end)

test("117: a declared yard goes to a farmer without one however far, and its land isn't split", function()
    setup()
    -- Eight farmlands in a row, so four farmers who start spread out; one
    -- yard far from every field, declared, and one as far, detected.
    local farmlands = grid(8, 1, 30)
    local yards = {
        { farmlandId = 60, x = 0, z = 9000 },
        { farmlandId = 61, x = 300, z = 9000, declared = true },
    }
    local result = TheContractorFarmerSplit.split(farmlands, yards, 60, 3)
    local holders = {}
    for _, farmer in ipairs(result.farmers) do
        if farmer.yardFarmlandId ~= nil then
            holders[farmer.yardFarmlandId] = farmer
        end
    end
    assertTrue(holders[61] ~= nil)
    assertEquals(nil, holders[60])

    -- On the live map, a declared yard's farmland is left out of the split.
    g_fieldManager = {
        getFields = function()
            local fields = {}
            for id = 1, 3 do
                table.insert(fields, {
                    getFarmland = function() return { getId = function() return id end } end,
                    getAreaHa = function() return 10 end,
                    getCenterOfFieldWorldPosition = function() return id * 300, 0 end,
                })
            end
            return fields
        end,
    }
    g_farmlandManager = { getFarmlandOwner = function() return 0 end }
    g_currentMission.TheContractor.Yards = {
        getYards = function()
            return { { farmlandId = 2, x = 600, z = 0, ownerFarmId = 0, how = "declared" } }
        end,
    }
    local live, liveFarmlands = TheContractorFarmerSplit.splitLiveMap(30, 1)
    assertEquals(2, #liveFarmlands)
    assertEquals(nil, live.owners[2])
end)
