-- Straw bale delivery (067): bale & deliver (a straw bale job with
-- includesHaulage) and the straw delivery job type. Where the bales go
-- (TCHaulage.findBaleDeliveryStation), who can do it (crew shape), how much
-- has to be delivered, and the bales a straw delivery lays out - owned by
-- the job's farm, counted by the delivery tracker.

local STRAW_CAPACITY = 4000

local function setup()
    local world = stubs.install()

    ToolType.BALE = 7
    world:addFillType("STRAW", "Straw")
    world:addFillType("GRASS_WINDROW", "Grass")
    world:addFillType("DRYGRASS_WINDROW", "Hay")
    FruitType = { UNKNOWN = 0, GRASS = 1, WHEAT = 2 }
    FieldGroundType = {}
    MathUtil = {
        haToSqm = function(ha)
            return ha * 10000
        end,
        vector2Length = function(x, z)
            return math.sqrt(x * x + z * z)
        end,
        vector2Normalize = function(x, z)
            local length = math.sqrt(x * x + z * z)
            return x / length, z / length
        end,
        getYRotationFromDirection = function()
            return 0
        end,
    }
    table.hasElement = table.hasElement or function(list, value)
        for _, element in ipairs(list) do
            if element == value then
                return true
            end
        end
        return false
    end

    local fruits = {
        [FruitType.GRASS] = { index = FruitType.GRASS, name = "GRASS", windrowLiterPerSqm = 1, cutState = 5,
            windrow = FillType.GRASS_WINDROW },
        [FruitType.WHEAT] = { index = FruitType.WHEAT, name = "WHEAT", windrowLiterPerSqm = 1, cutState = 9,
            windrow = FillType.STRAW },
    }
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index)
            return fruits[index]
        end,
        getFruitTypeByName = function(_, name)
            for _, fruit in pairs(fruits) do
                if fruit.name == name then
                    return fruit
                end
            end
            return nil
        end,
        getWindrowFillTypeIndexByFruitTypeIndex = function(_, index)
            return fruits[index] ~= nil and fruits[index].windrow or nil
        end,
    }

    -- One round straw bale, unless a test takes it away.
    world.bales = { { isRoundbale = true, fillType = FillType.STRAW, capacity = STRAW_CAPACITY } }
    g_baleManager = {
        getBaleIndex = function(_, fillTypeIndex, isRoundbale)
            for index, bale in ipairs(world.bales) do
                if bale.fillType == fillTypeIndex and bale.isRoundbale == isRoundbale then
                    return index
                end
            end
            return nil
        end,
        getBaleCapacityByBaleIndex = function(_, index, fillTypeIndex)
            local bale = world.bales[index]
            return bale ~= nil and bale.fillType == fillTypeIndex and bale.capacity or 0
        end,
        getBaleXMLFilenameByIndex = function(_, index)
            return "bale" .. index .. ".xml"
        end,
        getBaleDescByIndex = function()
            return { diameter = 1.5, height = 0.9 }
        end,
        getIsRoundBale = function(_, index)
            return world.bales[index].isRoundbale
        end,
    }

    TCJobProgress = { POLL_INTERVAL_MS = 3000, clearJob = function() end }
    TheContractorNegotiation = {
        rollInitialEagerness = function()
            return 1
        end,
    }
    world:load("src/business/Job.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCEquipmentClass.lua")
    world:load("src/business/Allocation.lua")
    world:load("src/util/TCHaulage.lua")
    world:load("src/util/TCFieldPreparation.lua")

    world.jobs = {}
    world.deliveries = {}
    g_currentMission.TheContractor.Jobs = {
        getJobById = function(_, jobId)
            return world.jobs[jobId]
        end,
        applyJobDelivery = function(_, farmId, jobId, delivered, required)
            local job = world.jobs[jobId]
            job.deliveredLiters = delivered
            job.requiredLiters = required
            table.insert(world.deliveries, { delivered = delivered, required = required })
        end,
    }

    world.stations = {}
    world.placeables = {}
    g_currentMission.storageSystem.getUnloadingStations = function()
        return world.stations
    end
    g_currentMission.storageSystem.getPlaceableUnloadingStation = function(_, placeable, index)
        return placeable.stations[index]
    end
    g_currentMission.storageSystem.getPlaceableUnloadingStationIndex = function(_, placeable, station)
        for index, other in ipairs(placeable.stations) do
            if other == station then
                return index
            end
        end
        return nil
    end
    g_currentMission.placeableSystem = {
        getPlaceableByUniqueId = function(_, uniqueId)
            return world.placeables[uniqueId]
        end,
    }

    BaleUnloadTrigger = {}
    world.items = {}
    g_currentMission.itemSystem = {
        getItemByUniqueId = function(_, uniqueId)
            return world.items[uniqueId]
        end,
    }
    return world
end

-- def: { name, price, takesStraw (default true), baleTrigger (default true),
--        baleTool (default true), allowMissions (default true) }
local function addStation(world, def)
    local function default(value)
        return value == nil or value
    end
    local takesStraw = default(def.takesStraw)
    local trigger = {
        isa = function(_, class)
            return class == BaleUnloadTrigger and default(def.baleTrigger)
        end,
        getIsFillTypeAllowed = function(_, fillTypeIndex)
            return fillTypeIndex == FillType.STRAW and takesStraw
        end,
        getIsFillTypeSupported = function(_, fillTypeIndex)
            return fillTypeIndex == FillType.STRAW and takesStraw
        end,
        getIsToolTypeAllowed = function(_, toolType)
            return toolType == ToolType.BALE and default(def.baleTool)
        end,
    }
    local placeable = { uniqueId = def.name, stations = {} }
    function placeable:getUniqueId() return self.uniqueId end
    local station = {
        name = def.name,
        owningPlaceable = placeable,
        isSellingPoint = true,
        allowMissions = default(def.allowMissions),
        acceptedFillTypes = { [FillType.STRAW] = takesStraw },
        unloadTriggers = { trigger },
        missions = {},
        rootNode = def.name,
        getEffectiveFillTypePrice = function()
            return def.price
        end,
        getName = function(self)
            return self.name
        end,
    }
    table.insert(placeable.stations, station)
    world.placeables[def.name] = placeable
    table.insert(world.stations, station)
    return station
end

local function addJob(world, jobType, includesHaulage)
    local job = TheContractorJob.new(#world.jobs + 1, 1, jobType, 7, 3, 1, 1, 1000)
    job.fruitTypeName = "WHEAT"
    job.includesHaulage = includesHaulage
    job.state = TheContractorJob.STATE.ALLOCATED
    world.jobs[job.id] = job
    return job
end

-- A field of `areaHa` hectares of wheat. Its course is one straight 100 m
-- run, laid out at once.
local function addField(world, areaHa)
    local fieldState = {
        isValid = true,
        fruitTypeIndex = FruitType.WHEAT,
        createFieldUpdateTask = function()
            return {
                setField = function() end,
                setGroundAngle = function() end,
                clearHeight = function() end,
            }
        end,
    }
    local field = {
        getAreaHa = function()
            return areaHa
        end,
        getFieldState = function()
            return fieldState
        end,
        getAngle = function()
            return 0
        end,
        getOwner = function()
            return 0
        end,
        getCenterOfFieldWorldPosition = function()
            return 0, 0
        end,
    }
    g_fieldManager = {
        getFieldById = function()
            return field
        end,
        addFieldUpdateTask = function() end,
    }
    FieldCourseSettings = {
        new = function()
            return {}
        end,
    }
    FieldCourseIterator = {
        new = function(x, z, settings, onSegment, onFinished)
            onSegment(0, 0, 100, 0, nil, nil, nil, 100)
            onFinished()
        end,
    }
    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function()
        return 0
    end
    local nextUniqueId = 1
    Bale = {
        new = function()
            local bale = { fillLevel = 0 }
            function bale:loadFromConfigXML() return true end
            function bale:setFillType(fillTypeIndex) self.fillType = fillTypeIndex end
            function bale:setFillLevel(level) self.fillLevel = level end
            function bale:getFillLevel() return self.fillLevel end
            function bale:setOwnerFarmId(farmId) self.ownerFarmId = farmId end
            function bale:register()
                self.uniqueId = "bale" .. nextUniqueId
                nextUniqueId = nextUniqueId + 1
                world.items[self.uniqueId] = self
            end
            function bale:getUniqueId() return self.uniqueId end
            return bale
        end,
    }
    return field
end

-- Where the bales go ------------------------------------------------------------

test("straw goes to the best-paying station with a bale trigger that takes it", function()
    local world = setup()
    addStation(world, { name = "Mill", price = 0.9, baleTrigger = false })
    addStation(world, { name = "Farm Shop", price = 0.4 })
    addStation(world, { name = "Dairy", price = 0.6 })
    addStation(world, { name = "Pallets Only", price = 0.8, baleTool = false })
    addStation(world, { name = "No Contracts", price = 0.7, allowMissions = false })

    local station = TCHaulage.findBaleDeliveryStation(FillType.STRAW)
    assertEquals(station ~= nil and station.name, "Dairy")
end)

test("no straw delivery anywhere when nothing takes straw bales", function()
    local world = setup()
    addStation(world, { name = "Mill", price = 0.9, baleTrigger = false })
    addStation(world, { name = "Dairy", price = 0.6, takesStraw = false })

    assertEquals(TCHaulage.findBaleDeliveryStation(FillType.STRAW), nil)
    assertEquals(#TheContractorJobGeneration:getCandidateFields(1, TheContractorJobGeneration.JOB_TYPES
        .strawDelivery), 0, "straw delivery candidates")
end)

test("only straw is delivered, never hay", function()
    setup()
    assertEquals(TheContractorJobGeneration.getStrawFillType(FruitType.WHEAT), FillType.STRAW)
    assertEquals(TheContractorJobGeneration.getStrawFillType(FruitType.GRASS), nil)
    assertEquals(TheContractorJobGeneration.getStrawFillType(nil), nil)
end)

-- Who can do it -----------------------------------------------------------------

test("bale & deliver is the player's alone; a plain bale job isn't", function()
    local world = setup()
    local baleAndDeliver = addJob(world, "bale", true)
    local plainBale = addJob(world, "bale", false)

    assertEquals(TheContractorAllocation.getCrewShapeError(baleAndDeliver, {}), nil, "player alone")
    assertEquals(TheContractorAllocation.getCrewShapeError(baleAndDeliver, { 1 }), "tc_allocation_playerOnly")
    assertEquals(TheContractorAllocation.getCrewShapeError(baleAndDeliver, { 1, 2 }), "tc_allocation_playerOnly")
    assertEquals(TheContractorAllocation.getCrewShapeError(plainBale, { 1 }), nil, "one worker baling")
end)

test("a straw delivery is the player's alone and needs no equipment", function()
    local world = setup()
    local job = addJob(world, "strawDelivery", true)
    local jobDef = TheContractorJobGeneration.JOB_TYPES.strawDelivery

    assertEquals(TheContractorAllocation.getCrewShapeError(job, { 1 }), "tc_allocation_playerOnly")
    assertEquals(#TCEquipmentClass.getMissingEquipment({}, jobDef, FruitType.WHEAT), 0, "missing with no vehicles")
end)

test("harvest & haul still takes two workers", function()
    local world = setup()
    local job = addJob(world, "harvest", true)
    assertEquals(TheContractorAllocation.getRequiredWorkerCount(job), 2)
    assertEquals(TheContractorAllocation.getCrewShapeError(job, { 1 }), "tc_allocation_needsSecondWorker")
end)

-- How much has to go in ---------------------------------------------------------

test("bale & deliver has to deliver the windrow it bales, once it's laid out", function()
    local world = setup()
    local station = addStation(world, { name = "Dairy", price = 0.6 })
    local job = addJob(world, "bale", true)
    TCHaulage.setDeliveryStation(job, station)

    assertEquals(TCHaulage.getRequiredLiters(job), nil, "before the windrow's laid out")
    TCHaulage.startDelivery(job)
    assertEquals(next(station.missions), nil, "no tracker counting against nothing")

    job.workTotal = 10000
    assertNear(TCHaulage.getRequiredLiters(job), 10000 * TCHaulage.DELIVERY_SUCCESS_FACTOR, 0.001)
end)

test("both straw jobs deliver straw", function()
    local world = setup()
    assertEquals(TCHaulage.getDeliveryFillType(addJob(world, "bale", true)), FillType.STRAW)
    assertEquals(TCHaulage.getDeliveryFillType(addJob(world, "strawDelivery", true)), FillType.STRAW)
end)

-- Vanilla's SellingStation:addFillLevelFromTool, the part that decides
-- whether a load counts towards a mission or sells: the matching mission
-- with the highest completion, starting from 0 and only taking one above
-- it. Returns true if it went to a mission.
local function deliverToStation(station, farmId, liters, fillTypeIndex)
    local bestCompletion, best = 0, nil
    for _, mission in pairs(station.missions) do
        if mission.fillSold ~= nil and mission.fillTypeIndex == fillTypeIndex and mission.farmId == farmId then
            local completion = mission:getCompletion()
            if bestCompletion < completion then
                best, bestCompletion = mission, completion
            end
        end
    end
    if best == nil then
        return false
    end
    best:fillSold(liters)
    return true
end

test("the first bale in counts towards the job rather than selling", function()
    local world = setup()
    local station = addStation(world, { name = "Dairy", price = 0.6 })
    local job = addJob(world, "bale", true)
    TCHaulage.setDeliveryStation(job, station)
    job.workTotal = 10000
    TCHaulage.startDelivery(job)

    assertTrue(deliverToStation(station, job.farmId, STRAW_CAPACITY, FillType.STRAW), "first bale counted")
    assertEquals(job.deliveredLiters, STRAW_CAPACITY)
    assertEquals(deliverToStation(station, 2, STRAW_CAPACITY, FillType.STRAW), false, "another farm's straw sells")
end)

-- Laying out a straw delivery -----------------------------------------------------

test("a straw delivery lays out whole straw bales owned by the job's farm", function()
    local world = setup()
    local station = addStation(world, { name = "Dairy", price = 0.6 })
    addField(world, 1)
    local job = addJob(world, "strawDelivery", true)
    job.farmId = 3
    TCHaulage.setDeliveryStation(job, station)

    assertTrue(TCFieldPreparation.prepareFieldForJob(job), "prepared")

    -- 1 ha of wheat at 1 l/m2 is 10000 l: two 4000 l bales, the rest
    -- too little for a third.
    assertEquals(#job.spawnedBaleIds, 2, "bales")
    assertEquals(job.workTotal, 2, "workTotal")
    for _, uniqueId in ipairs(job.spawnedBaleIds) do
        local bale = world.items[uniqueId]
        assertEquals(bale.fillType, FillType.STRAW, "fill type")
        assertEquals(bale.fillLevel, STRAW_CAPACITY, "fill level")
        assertEquals(bale.ownerFarmId, 3, "owner")
    end
end)

test("laying out a straw delivery starts counting what's delivered", function()
    local world = setup()
    local station = addStation(world, { name = "Dairy", price = 0.6 })
    addField(world, 1)
    local job = addJob(world, "strawDelivery", true)
    TCHaulage.setDeliveryStation(job, station)

    TCFieldPreparation.prepareFieldForJob(job)

    local required = 2 * STRAW_CAPACITY * TCHaulage.DELIVERY_SUCCESS_FACTOR
    assertNear(job.requiredLiters, required, 0.001, "required")
    local tracker = next(station.missions)
    assertTrue(tracker ~= nil, "tracker in the station")
    assertEquals(tracker.fillTypeIndex, FillType.STRAW, "tracker fill type")

    tracker:fillSold(STRAW_CAPACITY)
    assertEquals(job.deliveredLiters, STRAW_CAPACITY, "after one bale")
    assertTrue(next(station.missions) ~= nil, "still counting")

    tracker:fillSold(STRAW_CAPACITY)
    assertNear(job.deliveredLiters, required, 0.001, "capped at the terms")
    assertEquals(next(station.missions), nil, "terms met - the rest sells as normal")
end)

test("a map with no round straw bale lays out square ones", function()
    local world = setup()
    world.bales = { { isRoundbale = false, fillType = FillType.STRAW, capacity = STRAW_CAPACITY } }
    assertEquals(TCFieldPreparation.getStrawBaleIndex(), 1)
    world.bales = {}
    assertEquals(TCFieldPreparation.getStrawBaleIndex(), nil)
end)

-- Price ---------------------------------------------------------------------------

test("a straw delivery is priced per bale and per metre for each load", function()
    local world = setup()
    local field = addField(world, 3)
    getWorldTranslation = function()
        return 1000, 0, 0
    end
    local station = addStation(world, { name = "Dairy", price = 0.6 })

    -- 3 ha: 30000 l, seven whole 4000 l bales, two loads of five.
    assertEquals(TheContractorJobGeneration.estimateStrawBales(field), 7)
    local expected = 7 * TheContractorJobGeneration.STRAW_DELIVERY_REWARD_PER_BALE +
        2 * 1000 * TheContractorJobGeneration.STRAW_DELIVERY_REWARD_PER_METER
    assertNear(TheContractorJobGeneration.getStrawDeliveryReward(field, station), expected, 0.001)
end)
