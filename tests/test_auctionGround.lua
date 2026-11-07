-- 143: an auction's field may be grass, bare or harvested. A grass field is
-- cut short for the sale and left to grow back; any other is put down to
-- short grass for the day, its state kept (and saved) and put back when the
-- site's cleared, which a finished or cancelled auction both do.

local GRASS_CUT_STATE = 5
local WHEAT_CUT_STATE = 10
local WHEAT_WITHERED_STATE = 9

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorRepairContracts = { CLEARANCE = 1 }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    g_server = { broadcastEvent = function() end }
    getTimeSec = function() return 0 end

    FruitType = { UNKNOWN = 0, GRASS = 1, WHEAT = 2 }
    local fruits = {
        { index = FruitType.GRASS, name = "GRASS", cutState = GRASS_CUT_STATE,
            cutStates = { [GRASS_CUT_STATE] = true }, harvestGroundType = 16 },
        { index = FruitType.WHEAT, name = "WHEAT", cutState = WHEAT_CUT_STATE,
            cutStates = { [WHEAT_CUT_STATE] = true }, witheredState = WHEAT_WITHERED_STATE },
    }
    world.fruits = fruits
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index) return fruits[index] end,
        getFruitTypeByName = function(_, name)
            for _, fruit in pairs(fruits) do
                if fruit.name == name then
                    return fruit
                end
            end
            return nil
        end,
        getFruitTypeNameByIndex = function(_, index) return fruits[index] ~= nil and fruits[index].name or nil end,
    }
    -- Vanilla's enums, as Enum() gives them names.
    local function enum(values)
        local names = {}
        for name, value in pairs(values) do
            names[value] = name
        end
        values.getName = function(value) return names[value] end
        values.getByName = function(name) return values[name] end
        return values
    end
    FieldGroundType = enum({ NONE = 1, STUBBLE_TILLAGE = 2, CULTIVATED = 3, GRASS_CUT = 16 })
    FieldSprayType = enum({ NONE = 1, FERTILIZER = 2 })

    -- What reaches the density maps: every task, with what was set on it.
    world.tasks = {}
    local function newTask()
        local task = { values = {} }
        setmetatable(task, { __index = function(_, method)
            return function(self, ...)
                self.values[method] = { ... }
            end
        end })
        return task
    end
    FieldUpdateTask = { new = newTask }
    world.fields = {}
    g_fieldManager = {
        getFieldById = function(_, id) return world.fields[id] end,
        addFieldUpdateTask = function(_, task) table.insert(world.tasks, task) end,
    }

    TheContractorJobGeneration = { isGrass = function(index) return index == FruitType.GRASS end }
    world:load("src/business/Joyriders.lua")
    world:load("src/util/TCFieldPreparation.lua")
    world:load("src/util/TCVehicleIds.lua")
    world:load("src/util/TCAuctionCrowd.lua")
    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/business/FarmerFleet.lua")
    world:load("src/util/TCADSUsedLots.lua")
    world:load("src/business/AuctionSite.lua")
    world:load("src/events/TCAuctionSiteEvent.lua")

    local site = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = site
    world.site = site
    return world
end

-- A field whose state is one vanilla FieldState would read.
local function addField(world, id, state)
    local fieldState = {
        isValid = true, fruitTypeIndex = FruitType.UNKNOWN, growthState = 0, weedState = 0, stoneLevel = 0,
        groundType = FieldGroundType.STUBBLE_TILLAGE, sprayType = FieldSprayType.NONE, sprayLevel = 0,
        limeLevel = 0, rollerLevel = 0, plowLevel = 0, stubbleShredLevel = 0, waterLevel = 0,
    }
    for key, value in pairs(state or {}) do
        fieldState[key] = value
    end
    fieldState.createFieldUpdateTask = function() return FieldUpdateTask.new() end
    local field = {
        id = id,
        getId = function() return id end,
        getOwner = function() return 0 end,
        getAngle = function() return 0 end,
        getFieldState = function() return fieldState end,
    }
    world.fields[id] = field
    return field
end

local function addSite(world, fieldId)
    world.site.site = { fieldId = fieldId, lots = {}, planned = 0, unplaced = 0, isSpawning = false, walkways = {} }
    world.site:sync()
    return world.site.site
end

local function lastTask(world)
    return world.tasks[#world.tasks].values
end

test("a site may be grass, bare or a harvested crop, never a sown, growing or withered one", function()
    local world = setup()
    assertTrue(TheContractorAuctionSite.isCropFit(addField(world, 1)), "bare")
    assertTrue(TheContractorAuctionSite.isCropFit(addField(world, 2,
        { fruitTypeIndex = FruitType.GRASS, growthState = 3 })), "grass, any height")
    assertTrue(TheContractorAuctionSite.isCropFit(addField(world, 3,
        { fruitTypeIndex = FruitType.WHEAT, growthState = WHEAT_CUT_STATE })), "wheat stubble")
    assertTrue(not TheContractorAuctionSite.isCropFit(addField(world, 4,
        { fruitTypeIndex = FruitType.WHEAT, growthState = 1 })), "just sown")
    assertTrue(not TheContractorAuctionSite.isCropFit(addField(world, 5,
        { fruitTypeIndex = FruitType.WHEAT, growthState = 7 })), "growing")
    assertTrue(not TheContractorAuctionSite.isCropFit(addField(world, 6,
        { fruitTypeIndex = FruitType.WHEAT, growthState = WHEAT_WITHERED_STATE })), "withered")
    assertTrue(not TheContractorAuctionSite.isCropFit(addField(world, 7, { isValid = false })), "no state read")
end)

test("a harvested field is put down to short grass and put back as it was when the site's cleared", function()
    local world = setup()
    local field = addField(world, 4, { fruitTypeIndex = FruitType.WHEAT, growthState = WHEAT_CUT_STATE,
        weedState = 2, sprayType = FieldSprayType.FERTILIZER, sprayLevel = 1, limeLevel = 2, plowLevel = 1 })
    local site = addSite(world, 4)

    assertEquals(TheContractorAuctionSite.prepareGround(site, field), "grassed")
    local grass = lastTask(world)
    assertEquals(grass.setFruit[1], FruitType.GRASS)
    assertEquals(grass.setFruit[2], GRASS_CUT_STATE)
    assertEquals(grass.setGroundType[1], 16, "grass's own cut ground")
    assertEquals(grass.setWeedState[1], 0)
    assertEquals(site.groundSnapshot.fruitType, "WHEAT")

    world.site:clear()
    local restore = lastTask(world)
    assertEquals(#world.tasks, 2)
    assertEquals(restore.setField[1], field)
    assertEquals(restore.setFruit[1], FruitType.WHEAT)
    assertEquals(restore.setFruit[2], WHEAT_CUT_STATE)
    assertEquals(restore.setWeedState[1], 2)
    assertEquals(restore.setGroundType[1], FieldGroundType.STUBBLE_TILLAGE)
    assertEquals(restore.setSprayType[1], FieldSprayType.FERTILIZER)
    assertEquals(restore.setSprayLevel[1], 1)
    assertEquals(restore.setLimeLevel[1], 2)
    assertEquals(restore.setPlowLevel[1], 1)
    assertEquals(site.groundSnapshot, nil, "put back once")
end)

test("a bare field goes back bare", function()
    local world = setup()
    local field = addField(world, 4, { groundType = FieldGroundType.CULTIVATED })
    local site = addSite(world, 4)
    assertEquals(TheContractorAuctionSite.prepareGround(site, field), "grassed")
    world.site:clear()
    local restore = lastTask(world)
    assertEquals(restore.setFruit[1], FruitType.UNKNOWN)
    assertEquals(restore.setFruit[2], 0)
    assertEquals(restore.setGroundType[1], FieldGroundType.CULTIVATED)
end)

test("a grass field is cut and left to grow back: nothing kept, nothing put back", function()
    local world = setup()
    local field = addField(world, 4, { fruitTypeIndex = FruitType.GRASS, growthState = 3 })
    local site = addSite(world, 4)
    assertEquals(TheContractorAuctionSite.prepareGround(site, field), "cut")
    assertEquals(site.groundSnapshot, nil)
    assertEquals(field:getFieldState().growthState, GRASS_CUT_STATE)
    local count = #world.tasks
    world.site:clear()
    assertEquals(#world.tasks, count, "no restore")
end)

test("the kept state survives a save, by name, and is put back after the load", function()
    local world = setup()
    local field = addField(world, 9, { fruitTypeIndex = FruitType.WHEAT, growthState = WHEAT_CUT_STATE,
        stubbleShredLevel = 1, waterLevel = 2 })
    local site = addSite(world, 9)
    TheContractorAuctionSite.prepareGround(site, field)
    local xmlFile = {}
    world.site:saveToXmlFile(xmlFile)
    assertEquals(xmlFile["TheContractor.auctionSite.groundSnapshot#fruitType"], "WHEAT")
    assertEquals(xmlFile["TheContractor.auctionSite.groundSnapshot#groundType"], "STUBBLE_TILLAGE")

    -- The mod list changed: wheat has another index now.
    world.fruits[3] = world.fruits[2]
    world.fruits[2] = nil
    world.fruits[3].index = 3
    local loaded = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = loaded
    loaded:loadFromXMLFile(xmlFile)
    loaded:clear()
    local restore = lastTask(world)
    assertEquals(restore.setFruit[1], 3)
    assertEquals(restore.setFruit[2], WHEAT_CUT_STATE)
    assertEquals(restore.setStubbleShredLevel[1], 1)
    assertEquals(restore.setWaterLevel[1], 2)
end)

test("a crop gone from the game since the save is put back as no crop, with a warning", function()
    local world = setup()
    local field = addField(world, 9, { fruitTypeIndex = FruitType.WHEAT, growthState = WHEAT_CUT_STATE })
    local site = addSite(world, 9)
    TheContractorAuctionSite.prepareGround(site, field)
    world.fruits[2] = nil
    world.site:clear()
    local restore = lastTask(world)
    assertEquals(restore.setFruit[1], FruitType.UNKNOWN)
    assertEquals(restore.setGroundType[1], FieldGroundType.STUBBLE_TILLAGE)
    assertEquals(#world.warnings, 1)
end)

test("a site never set out (a sale day slept through) has nothing to put back", function()
    local world = setup()
    addField(world, 4, { fruitTypeIndex = FruitType.WHEAT, growthState = WHEAT_CUT_STATE })
    addSite(world, 4)
    world.site:clear()
    assertEquals(#world.tasks, 0)
    local xmlFile = {}
    addSite(world, 4)
    world.site:saveToXmlFile(xmlFile)
    assertEquals(xmlFile["TheContractor.auctionSite.groundSnapshot#fruitType"], nil)
end)
