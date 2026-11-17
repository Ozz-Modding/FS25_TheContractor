-- 126: selling a load for a farmer. The load (a crop of the farmer's fields
-- the trailer carries and a selling point buys, else wheat or barley), its
-- litres, the trailer's store spec, the roll (a farmer with a yard, their
-- trailer free and room for it, never one fallen out with, one at a time,
-- weighted by the relationship), the fee, judging a miss (grain neither
-- delivered nor in the trailer was taken), the console, and the load
-- through the save and the stream. The real YardHaul, YardBales, Job,
-- FarmerFleet, FieldBreakdowns and TCHaulage, with the jobs, the farmers,
-- the store and the engine faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TheContractorRandomEvents = { DONE = "done", WAIT = "wait" }
    MathUtil = { getYRotationFromDirection = function(x, z) return math.atan2(x, z) end }
    FarmManager.SPECTATOR_FARM_ID = 0
    TCParking = { DEFAULT_HEIGHT = 4 }
    getWorldTranslation = function(node)
        return node.x or 0, 0, node.z or 0
    end
    world.barley = world:addFillType("BARLEY", "Barley")
    world.canola = world:addFillType("CANOLA", "Canola")
    world.grass = world:addFillType("GRASS_WINDROW", "Grass")

    -- Crops: wheat, canola and grass, each to its own fill type.
    FruitType = { UNKNOWN = 0, WHEAT = 2, CANOLA = 3, GRASS = 4 }
    local fruitFill = { [2] = FillType.WHEAT, [3] = world.canola, [4] = world.grass }
    g_fruitTypeManager = {
        getFillTypeIndexByFruitTypeIndex = function(_, index) return fruitFill[index] end,
    }
    TheContractorJobGeneration = {
        JOB_TYPES = { yardHaul = { offField = true, yardDelivery = true } },
        isGrass = function(fruitTypeIndex) return fruitTypeIndex == FruitType.GRASS end,
    }

    -- Stations: world.buys[fillTypeIndex] is the one that buys it, if any.
    world.station = { name = "Grain Mill", rootNode = { x = 3000, z = 0 } }
    world.buys = { [FillType.WHEAT] = world.station, [world.barley] = world.station }
    TCJobProgress = { POLL_INTERVAL_MS = 3000 }
    world:load("src/util/TCHaulage.lua")
    HarvestMission = { getSellingStationWithHighestPrice = function(fillTypeIndex) return world.buys[fillTypeIndex] end }

    -- Fields by farmland: world.crops[farmlandId] is the crop on its field.
    world.crops = { [4] = FruitType.CANOLA, [5] = FruitType.WHEAT, [6] = FruitType.GRASS }
    g_fieldManager = { getFields = function()
        local fields = {}
        for farmlandId, fruitTypeIndex in pairs(world.crops) do
            local field = { farmlandId = farmlandId, fruitTypeIndex = fruitTypeIndex }
            function field:getFarmland() local id = self.farmlandId return { getId = function() return id end } end
            function field:getFieldState() return { fruitTypeIndex = self.fruitTypeIndex } end
            function field:getId() return self.farmlandId end
            function field:getCenterOfFieldWorldPosition() return self.farmlandId * 100, 0 end
            table.insert(fields, field)
        end
        table.sort(fields, function(a, b) return a.farmlandId < b.farmlandId end)
        return fields
    end }

    -- The store: a grain trailer, and the farmers' yards (all open ground).
    g_storeManager = { getItemByXMLFilename = function(_, xml)
        return xml == "trailer.xml" and { xmlFilename = xml, name = "Trailer", categoryName = "TRAILERS" } or nil
    end }
    StoreItemUtil = { getSizeValues = function() return { width = 2.5, length = 8, height = 3 } end }
    TheContractorYards = { isOpenGround = function() return world.open ~= false end }
    g_farmlandManager = { getFarmlandOwner = function(_, farmlandId) return world.yardOwners[farmlandId] or 0 end }
    world.yardOwners = {}

    world:load("src/business/Job.lua")
    world:load("src/util/TCVehicleIds.lua")
    world:load("src/business/FarmerFleet.lua")
    world:load("src/business/FieldBreakdowns.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    TheContractorYardHaul.getTrailerSpec = function(xml)
        return xml == "trailer.xml" and
            { capacity = 20000, fillTypes = { [FillType.WHEAT] = true, [world.barley] = true, [world.canola] = true } }
            or nil
    end

    local tc = g_currentMission.TheContractor
    tc.Jobs = {
        jobsByFarm = {},
        getAllJobs = function(self, farmId)
            local result = {}
            for _, job in pairs(self.jobsByFarm[farmId] or {}) do
                table.insert(result, job)
            end
            return result
        end,
        getJob = function(self, farmId, jobId)
            return (self.jobsByFarm[farmId] or {})[jobId]
        end,
    }
    tc.RepairContracts = { arrivals = {}, removals = {} }
    tc.Yards = { getSpots = function(_, farmlandId)
        return { x = 0, z = 0, spots = { { x = 0, z = 30 } } }
    end }
    world:addRelationships()

    -- Two farmers with yards and trailers: Tom (canola on farmland 4) and
    -- Ann (wheat on 5).
    tc.Farmers = { people = {} }
    function tc.Farmers:getFarmers()
        local list = {}
        for _, person in pairs(self.people) do
            table.insert(list, person)
        end
        table.sort(list, function(a, b) return a.id < b.id end)
        return list
    end
    function tc.Farmers:getPerson(id) return self.people[id] end
    local function addFarmer(id, name, farmlandId, yardFarmlandId)
        tc.Farmers.people[id] = { id = id, name = name, farmlandIds = { farmlandId }, yardFarmlandId = yardFarmlandId,
            machines = { { id = 1, role = "trailer", xmlFilename = "trailer.xml", fitted = {} } } }
    end
    addFarmer(1, "Tom Hargreaves", 4, 40)
    addFarmer(2, "Ann Ridley", 5, 50)

    tc.YardHaul = TheContractorYardHaul.new()

    -- def: { id, farmId, state, farmerId, liters, delivered, fillType }
    function world:addHaulJob(def)
        local job = TheContractorJob.new(def.id or 1, def.farmId or 1, "yardHaul", 4, 1, 1, 1, 1000)
        job.state = def.state or TheContractorJob.STATE.ALLOCATED
        job.includesHaulage = true
        job.deliveryStationName = "Grain Mill"
        job.yardHaul = { farmerId = def.farmerId or 1, yardFarmlandId = 40, fillTypeName = "WHEAT",
            liters = def.liters or 20000, reason = "sick", machineId = 1, x = 0, z = 30, rotY = 0,
            pricePerLiter = 0.5, filled = def.filled ~= false }
        job.requiredLiters = job.yardHaul.liters * TCHaulage.DELIVERY_SUCCESS_FACTOR
        job.deliveredLiters = def.delivered or 0
        tc.Jobs.jobsByFarm[job.farmId] = tc.Jobs.jobsByFarm[job.farmId] or {}
        tc.Jobs.jobsByFarm[job.farmId][job.id] = job
        return job
    end

    -- The trailer: a vehicle with liters of wheat in it.
    function world:addTrailer(job, liters)
        local trailer = self:addVehicle({ fillUnits = { { capacity = 20000, level = liters, fillType = FillType.WHEAT,
            supported = { FillType.WHEAT } } } })
        job.yardHaul.trailerVehicleId = trailer.id
        return trailer
    end

    return world, tc
end

local function fixed(value)
    return function() return value end
end

test("the load: a crop of the farmer's fields the trailer carries and a station buys, never grass", function()
    local world = setup()
    local spec = TheContractorYardHaul.getTrailerSpec("trailer.xml")
    local farmer = { farmlandIds = { 5, 6 } }
    local fieldFillTypes = TheContractorYardHaul.getFieldFillTypes(farmer)
    assertEquals(#fieldFillTypes, 1, "the grass is left out")
    assertEquals(fieldFillTypes[1], FillType.WHEAT)
    local load = TheContractorYardHaul.pickLoad(fieldFillTypes, spec, nil, fixed(0))
    assertEquals(load.fillTypeIndex, FillType.WHEAT)
    assertEquals(load.station, world.station)
end)

test("the load: a crop nobody buys or the trailer won't take gives way to wheat or barley; with neither, none", function()
    local world = setup()
    local spec = TheContractorYardHaul.getTrailerSpec("trailer.xml")
    -- Canola: the trailer takes it, but nowhere buys it.
    local load = TheContractorYardHaul.pickLoad({ world.canola }, spec, nil, fixed(0.99))
    assertTrue(load.fillTypeIndex == FillType.WHEAT or load.fillTypeIndex == world.barley)
    -- Nothing the trailer carries is bought anywhere.
    world.buys = {}
    assertEquals(TheContractorYardHaul.pickLoad({ FillType.WHEAT }, spec, nil, fixed(0)), nil)
end)

test("the load: the console's crop, if the trailer carries it and it's bought", function()
    local world = setup()
    local spec = TheContractorYardHaul.getTrailerSpec("trailer.xml")
    local load = TheContractorYardHaul.pickLoad({ FillType.WHEAT }, spec, world.barley, fixed(0))
    assertEquals(load.fillTypeIndex, world.barley)
    assertEquals(TheContractorYardHaul.pickLoad({ FillType.WHEAT }, spec, world.grass, fixed(0)), nil)
end)

test("the litres: 90-100% of the trailer's capacity, in whole steps", function()
    setup()
    local low = TheContractorYardHaul.getLoadLiters(20000, fixed(0))
    local high = TheContractorYardHaul.getLoadLiters(20000, fixed(0.999))
    assertEquals(low, 20000 * TheContractorYardHaul.LOAD_SHARE[1])
    assertTrue(high <= 20000 and high > low)
    assertEquals(TheContractorYardHaul.getLoadLiters(17777, fixed(0.5)) % TheContractorYardHaul.LITER_STEP, 0)
end)

-- The real getTrailerSpec, with the store item and the XML's fill unit
-- configurations (each { capacity, fillTypes }) faked.
local function realSpec(world, storeItem, configs)
    dofile("src/business/YardHaul.lua")
    TheContractorYardHaul.clearSpecCache()
    g_storeManager = { getItemByXMLFilename = function(_, xml) return xml == "trailer.xml" and storeItem or nil end }
    world.xmlReads = 0
    TheContractorYardHaul.readFillUnitConfigurations = function()
        world.xmlReads = world.xmlReads + 1
        return configs
    end
end

local function grain(world, capacity)
    return { capacity = capacity, fillTypes = { [FillType.WHEAT] = true, [world.barley] = true } }
end
local function flatbed()
    return { capacity = 0, fillTypes = {} }
end

test("the trailer's spec: each fill unit configuration's capacity and fill types, from its XML", function()
    local world = setup()
    dofile("src/business/YardHaul.lua")
    Vehicle = { xmlSchema = {} }
    -- Config 1: a flatbed's empty unit. Config 2: a grain body (BULK) and a
    -- potato unit by name.
    local root = "vehicle.fillUnit.fillUnitConfigurations.fillUnitConfiguration"
    local values = {
        [root .. "(0).fillUnits.fillUnit(0)#capacity"] = 0,
        [root .. "(1).fillUnits.fillUnit(0)#capacity"] = 18000,
        [root .. "(1).fillUnits.fillUnit(0)#fillTypeCategories"] = "BULK",
        [root .. "(1).fillUnits.fillUnit(1)#capacity"] = 24000,
        [root .. "(1).fillUnits.fillUnit(1)#fillTypes"] = "potato",
    }
    local counts = {
        [root] = 2,
        [root .. "(0).fillUnits.fillUnit"] = 1,
        [root .. "(1).fillUnits.fillUnit"] = 2,
    }
    world.deletedXml = false
    XMLFile = { load = function()
        return {
            getRootName = function() return "vehicle" end,
            getValue = function(_, key) return values[key] end,
            iterate = function(_, path, closure)
                for i = 0, (counts[path] or 0) - 1 do
                    if closure(i + 1, path .. "(" .. i .. ")") == false then
                        return
                    end
                end
            end,
            delete = function() world.deletedXml = true end,
        }
    end }
    g_fillTypeManager.getFillTypesByCategoryNames = function(_, names, warning, list)
        if names == "BULK" then
            table.insert(list, FillType.WHEAT)
            table.insert(list, world.barley)
        end
        return list
    end
    g_fillTypeManager.getFillTypesByNames = function(_, names, warning, list)
        for name in string.gmatch(names or "", "%S+") do
            table.insert(list, FillType[string.upper(name)])
        end
        return list
    end
    local configs = TheContractorYardHaul.readFillUnitConfigurations("trailer.xml")
    assertEquals(#configs, 2)
    assertEquals(configs[1].capacity, 0)
    assertEquals(next(configs[1].fillTypes), nil, "the flatbed carries nothing")
    assertEquals(configs[2].capacity, 24000)
    assertTrue(configs[2].fillTypes[FillType.WHEAT] and configs[2].fillTypes[world.barley] and
        configs[2].fillTypes[FillType.POTATO])
    assertTrue(world.deletedXml)
end)

test("the trailer's spec: a flatbed by default with a grain body to choose comes out with the grain body", function()
    local world = setup()
    realSpec(world, { xmlFilename = "trailer.xml" }, { flatbed(), grain(world, 18000) })
    local spec = TheContractorYardHaul.getTrailerSpec("trailer.xml")
    assertEquals(spec.capacity, 18000)
    assertTrue(spec.fillTypes[FillType.WHEAT])
    assertEquals(spec.configurations.fillUnit, 2)
    TheContractorYardHaul.getTrailerSpec("trailer.xml")
    assertEquals(world.xmlReads, 1, "kept for the session")
end)

test("the trailer's spec: the default configuration if it's a grain body, not a bigger one", function()
    local world = setup()
    local storeItem = { xmlFilename = "trailer.xml", configurations = { fillUnit = {
        { isDefault = false }, { isDefault = true }, {} } } }
    ConfigurationUtil = { getDefaultConfigIdFromItems = function(items)
        for index, item in ipairs(items) do
            if item.isDefault then return index end
        end
        return 1
    end }
    realSpec(world, storeItem, { grain(world, 30000), grain(world, 15000), flatbed() })
    local spec = TheContractorYardHaul.getTrailerSpec("trailer.xml")
    ConfigurationUtil = nil
    assertEquals(spec.configurations.fillUnit, 2)
    assertEquals(spec.capacity, 15000)
end)

test("the trailer's spec: no configuration that takes wheat, or none a set allows, and it won't do", function()
    local world = setup()
    realSpec(world, { xmlFilename = "trailer.xml" },
        { flatbed(), { capacity = 20000, fillTypes = { [FillType.POTATO] = true } } })
    assertEquals(TheContractorYardHaul.getTrailerSpec("trailer.xml"), nil)
    local farmer = { id = 1, machines = { { id = 1, role = "trailer", xmlFilename = "trailer.xml", fitted = {} } } }
    assertEquals(TheContractorYardHaul.getFreeTrailer(farmer), nil, "the farmer's flatbed never brings an offer")

    -- A grain body no configuration set pairs.
    realSpec(world, { xmlFilename = "trailer.xml", configurationSets = {
        { isDefault = true, configurations = { fillUnit = 1, design = 1 } },
    } }, { flatbed(), grain(world, 18000) })
    assertEquals(TheContractorYardHaul.getTrailerSpec("trailer.xml"), nil)
end)

test("the trailer's spec: with configuration sets, the whole set that pairs the grain body", function()
    local world = setup()
    realSpec(world, { xmlFilename = "trailer.xml", configurationSets = {
        { isDefault = true, configurations = { fillUnit = 1, design = 1 } },
        { configurations = { fillUnit = 2, design = 3 } },
    } }, { flatbed(), grain(world, 18000) })
    local spec = TheContractorYardHaul.getTrailerSpec("trailer.xml")
    assertEquals(spec.configurations.fillUnit, 2)
    assertEquals(spec.configurations.design, 3)
end)

test("the trailer's spec: a model not in the store won't do, and its XML isn't read", function()
    local world = setup()
    realSpec(world, { xmlFilename = "trailer.xml" }, { grain(world, 18000) })
    assertEquals(TheContractorYardHaul.getTrailerSpec("nothing.xml"), nil)
    assertEquals(world.xmlReads, 0)
end)

test("the roll: a farmer with a yard, the trailer free and room for it, never one fallen out with", function()
    local world, tc = setup()
    local data = tc.YardHaul:pickRequest(1)
    assertTrue(data ~= nil)
    assertTrue(data.farmerId == 1 or data.farmerId == 2)
    assertTrue(data.liters >= 18000 and data.liters <= 20000)
    local isReason = false
    for _, reason in ipairs(TheContractorYardHaul.REASONS) do
        isReason = isReason or data.reason == reason
    end
    assertTrue(isReason, "one of the reasons")

    -- Tom's fallen out with the farm, Ann's yard is a player's: nobody.
    tc.Relationships:applyScore(1, 1, TheContractorRelationships.REFUSES_BELOW - 1)
    world.yardOwners[50] = 1
    assertEquals(tc.YardHaul:pickRequest(1), nil)
    world.yardOwners[50] = nil
    assertEquals(tc.YardHaul:pickRequest(1).farmerId, 2)

    -- No room in the yard: nothing.
    world.open = false
    assertEquals(tc.YardHaul:pickRequest(1), nil)
end)

test("the roll: Ann's load is her wheat; one at a time per farm; one job in a yard at a time, either way", function()
    local world, tc = setup()
    tc.YardHaul.forcedFarmerId = 2
    assertEquals(tc.YardHaul:pickRequest(1).fillTypeName, "WHEAT")
    tc.YardHaul.forcedFarmerId = nil

    world:addHaulJob({ farmerId = 2, state = TheContractorJob.STATE.OFFERED })
    assertEquals(tc.YardHaul:pickRequest(1), nil, "the farm has one already")
    assertEquals(tc.YardHaul:pickRequest(2).farmerId, 1, "Ann's busy, and her trailer's out")
    local _, baleFarmers = TheContractorYardBales.getOpenJobs()
    assertTrue(baleFarmers[2], "and nobody asks Ann's yard for bales meanwhile")

    -- A yard bale order in Tom's yard keeps him out of it too.
    local bales = TheContractorJob.new(9, 3, "yardBales", 4, 1, 1, 1, 1000)
    bales.yardDelivery = { farmerId = 1 }
    tc.Jobs.jobsByFarm[3] = { [9] = bales }
    assertEquals(tc.YardHaul:pickRequest(2), nil)
end)

test("the console: crop, reason and farmer, in any order; a farmer nobody knows is refused", function()
    local world, tc = setup()
    assertEquals(tc.YardHaul:prepareTrigger({ "left", "barley", "Ann", "Ridley" }), nil)
    assertEquals(tc.YardHaul.forcedReason, "left")
    assertEquals(tc.YardHaul.forcedFillTypeName, "BARLEY")
    assertEquals(tc.YardHaul.forcedFarmerId, 2)
    local data = tc.YardHaul:pickRequest(1)
    assertEquals(data.farmerId, 2)
    assertEquals(data.fillTypeName, "BARLEY")
    assertEquals(data.reason, "left")

    local other = TheContractorYardHaul.new()
    assertTrue(other:prepareTrigger({ "Nobody" }) ~= nil)
    assertEquals(other.forcedFillTypeName, nil)
end)

test("the fee: per load, and more the further the station is, at the pay rate", function()
    setup()
    local near = TheContractorYardHaul.getBasePrice(0, 1)
    local far = TheContractorYardHaul.getBasePrice(2000, 1)
    assertEquals(near, TheContractorYardHaul.LOAD_FEE)
    assertEquals(far - near, 2000 * TheContractorYardHaul.RATE_PER_METER)
    assertEquals(TheContractorYardHaul.getBasePrice(2000, 2), far * 2)
    assertEquals(TheContractorYardHaul.getDistance(0, 0, { rootNode = { x = 300, z = 400 } }), 500)
end)

test("a miss: grain neither delivered nor in the trailer was taken", function()
    local world, tc = setup()
    local job = world:addHaulJob({ delivered = 5000 })
    world:addTrailer(job, 3000)
    assertEquals(tc.YardHaul:judgeMiss(job), 12000)
    assertEquals(TheContractorYardHaul.getTheftPenalty(job), TheContractorYardHaul.THEFT_REPUTATION)
    assertEquals(TheContractorYardHaul.getClaimAmount(job), 6000, "at the price the day it was offered")
end)

test("a miss: with the grain still in the trailer, or within the allowance, nothing was taken", function()
    local world, tc = setup()
    local job = world:addHaulJob({ delivered = 5000 })
    world:addTrailer(job, 15000)
    assertEquals(tc.YardHaul:judgeMiss(job), 0)
    assertEquals(TheContractorYardHaul.getTheftPenalty(job), 0)

    local short = world:addHaulJob({ id = 2, delivered = 5000 })
    world:addTrailer(short, 15000 - 20000 * TheContractorYardHaul.THEFT_ALLOWANCE)
    assertEquals(tc.YardHaul:judgeMiss(short), 0, "a little spilt on the way")
end)

test("a miss: nothing's judged for a trailer never filled, or one that's gone", function()
    local world, tc = setup()
    local job = world:addHaulJob({ filled = false })
    assertEquals(tc.YardHaul:judgeMiss(job), 0)
    local gone = world:addHaulJob({ id = 2 })
    gone.yardHaul.trailerVehicleId = 999
    assertEquals(tc.YardHaul:judgeMiss(gone), 0)
end)

test("the load, its reason and its trailer go through the save (by uniqueId) and the stream", function()
    local world, tc = setup()
    local job = world:addHaulJob({})
    local trailer = world:addTrailer(job, 20000)
    function trailer:getUniqueId() return "trailer7" end
    job.yardHaul.missingLiters = 400

    local xmlFile = {}
    TheContractorYardHaul.saveToXML(xmlFile, "job", job.yardHaul)
    local loaded = TheContractorYardHaul.loadFromXML(xmlFile, "job")
    assertEquals(loaded.reason, "sick")
    assertEquals(loaded.fillTypeName, "WHEAT")
    assertEquals(loaded.liters, 20000)
    assertEquals(loaded.farmerId, 1)
    assertEquals(loaded.machineId, 1)
    assertEquals(loaded.trailerUniqueId, "trailer7")
    assertEquals(loaded.trailerVehicleId, nil, "object ids change every load")
    assertTrue(loaded.filled)
    assertEquals(loaded.missingLiters, 400)
    assertEquals(TheContractorYardHaul.loadFromXML({}, "job"), nil)

    local stream = world:newStream()
    TheContractorYardHaul.writeStream(stream, job.yardHaul)
    TheContractorYardHaul.writeStream(stream, nil)
    local copy = TheContractorYardHaul.readStream(stream)
    assertEquals(copy.reason, "sick")
    assertEquals(copy.liters, 20000)
    assertEquals(copy.trailerVehicleId, trailer.id)
    assertEquals(copy.trailerUniqueId, nil, "the server's own")
    assertEquals(copy.filled, nil)
    assertEquals(TheContractorYardHaul.readStream(stream), nil)
end)

test("the map marker: on the trailer while it's taken on, following it; on its spot until it's out", function()
    local world = setup()
    local job = world:addHaulJob({ filled = false })
    local spot = TheContractorYardHaul.getSpot(job)
    assertEquals(spot.x, 0)
    assertEquals(spot.z, 30)
    local trailer = world:addTrailer(job, 20000)
    trailer.rootNode = { x = 900, z = 40 }
    assertEquals(TheContractorYardHaul.getSpot(job).x, 900)
    job.state = TheContractorJob.STATE.COMPLETED
    assertEquals(TheContractorYardHaul.getSpot(job), nil)
end)
