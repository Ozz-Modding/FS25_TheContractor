-- Where a haulage job delivers to (162): the best-paying selling point the
-- job's farm can actually unload at. Reported on a modded map where a farm
-- silo on land nobody owns had been made a selling point: it paid best, so
-- it was picked, and the farm couldn't tip there. Vanilla's pick
-- (HarvestMission.getSellingStationWithHighestPrice) stays first when the
-- farm can use it; a job already pointing somewhere it can't unload is
-- moved when its delivery starts.

local FARM = 1

local function setup()
    local world = stubs.install()

    ToolType.BALE = 7
    world:addFillType("WHEAT", "Wheat")
    world:addFillType("STRAW", "Straw")
    world:addFillType("BARLEY", "Barley")
    FruitType = { UNKNOWN = 0, GRASS = 2, WHEAT = 1 }
    FieldGroundType = {}
    local fruits = { [FruitType.WHEAT] = { index = FruitType.WHEAT, name = "WHEAT", fillType = FillType.WHEAT } }
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
        getFillTypeIndexByFruitTypeIndex = function(_, index)
            return fruits[index] ~= nil and fruits[index].fillType or nil
        end,
        getWindrowFillTypeIndexByFruitTypeIndex = function()
            return FillType.STRAW
        end,
    }

    TCJobProgress = { POLL_INTERVAL_MS = 3000, clearJob = function() end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    world:load("src/business/Job.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCHaulage.lua")

    BaleUnloadTrigger = { name = "bale" }
    WoodUnloadTrigger = { name = "wood" }
    PalletUnloadTrigger = { name = "pallet" }

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
    -- Vanilla's pick: the best price among selling points allowing missions,
    -- whoever can unload there.
    HarvestMission = {
        getSellingStationWithHighestPrice = function(fillTypeIndex)
            local best, bestPrice = nil, 0
            for _, station in ipairs(world.stations) do
                if station.isSellingPoint and station.allowMissions and station.acceptedFillTypes[fillTypeIndex] and
                    station.price > bestPrice then
                    best, bestPrice = station, station.price
                end
            end
            return best
        end,
    }

    world.jobs = {}
    world.deliveries = {}
    g_currentMission.TheContractor.Jobs = {
        getJobById = function(_, jobId)
            return world.jobs[jobId]
        end,
        getAllJobs = function(_, farmId)
            local jobs = {}
            for _, job in pairs(world.jobs) do
                if job.farmId == farmId then
                    table.insert(jobs, job)
                end
            end
            return jobs
        end,
        applyJobDelivery = function(_, farmId, jobId, delivered, required)
            local job = world.jobs[jobId]
            job.deliveredLiters = delivered
            job.requiredLiters = required
        end,
    }
    world.broadcasts = {}
    g_server = {
        broadcastEvent = function(_, event)
            table.insert(world.broadcasts, event)
        end,
    }
    TCJobDeliveryEvent = {
        new = function(farmId, jobId, delivered, required, stationName)
            return { farmId = farmId, jobId = jobId, stationName = stationName }
        end,
    }
    return world
end

-- def: { name, price, fillTypes (default WHEAT and STRAW), farms (which
-- farms may unload; default all), triggerFillTypes (default the station's),
-- trigger ("bulk" default, "bale", "wood", "none"), allowMissions }
local function addStation(world, def)
    local fillTypes = {}
    for _, fillTypeIndex in ipairs(def.fillTypes or { FillType.WHEAT, FillType.STRAW }) do
        fillTypes[fillTypeIndex] = true
    end
    local triggerFillTypes = fillTypes
    if def.triggerFillTypes ~= nil then
        triggerFillTypes = {}
        for _, fillTypeIndex in ipairs(def.triggerFillTypes) do
            triggerFillTypes[fillTypeIndex] = true
        end
    end
    local kind = def.trigger or "bulk"
    local triggerClass = ({ bale = BaleUnloadTrigger, wood = WoodUnloadTrigger })[kind]
    local trigger = {
        isa = function(_, class)
            return class == triggerClass
        end,
        getIsFillTypeSupported = function(_, fillTypeIndex)
            return triggerFillTypes[fillTypeIndex] == true
        end,
        getIsFillTypeAllowed = function(_, fillTypeIndex)
            return triggerFillTypes[fillTypeIndex] == true
        end,
        getIsToolTypeAllowed = function(_, toolType)
            return toolType == ToolType.BALE
        end,
    }
    local placeable = { uniqueId = def.name, stations = {} }
    function placeable:getUniqueId() return self.uniqueId end
    local station = {
        name = def.name,
        price = def.price,
        owningPlaceable = placeable,
        isSellingPoint = true,
        allowMissions = def.allowMissions == nil or def.allowMissions,
        acceptedFillTypes = fillTypes,
        unloadTriggers = kind == "none" and {} or { trigger },
        missions = {},
        getEffectiveFillTypePrice = function(self)
            return self.price
        end,
        getName = function(self)
            return self.name
        end,
        getIsFillAllowedFromFarm = function(_, farmId)
            return def.farms == nil or def.farms[farmId] == true
        end,
    }
    table.insert(placeable.stations, station)
    world.placeables[def.name] = placeable
    table.insert(world.stations, station)
    return station
end

local function addHaulageJob(world, jobType, stationName)
    local job = TheContractorJob.new(#world.jobs + 1, FARM, jobType, 7, 3, 1, 1, 1000)
    job.fruitTypeName = "WHEAT"
    job.includesHaulage = true
    job.state = TheContractorJob.STATE.ALLOCATED
    job.requiredLiters = 5000
    job.deliveredLiters = 0
    TCHaulage.setDeliveryStation(job, world.placeables[stationName].stations[1])
    world.jobs[job.id] = job
    return job
end

test("vanilla's pick stands when the farm can unload there", function()
    local world = setup()
    addStation(world, { name = "Elevator", price = 0.9 })
    addStation(world, { name = "Mill", price = 0.5 })

    assertEquals(TCHaulage.findDeliveryStation(FillType.WHEAT, FARM).name, "Elevator")
end)

test("a best-paying station the farm can't unload at is passed over for the next best", function()
    local world = setup()
    addStation(world, { name = "Dryer", price = 0.95, farms = { [15] = true } })
    addStation(world, { name = "Elevator", price = 0.9 })
    addStation(world, { name = "Mill", price = 0.5 })

    assertEquals(TCHaulage.findDeliveryStation(FillType.WHEAT, FARM).name, "Elevator")
    assertEquals(TCHaulage.findDeliveryStation(FillType.WHEAT, 15).name, "Dryer", "its owner still gets it")
end)

test("a station whose triggers don't take the crop is passed over", function()
    local world = setup()
    addStation(world, { name = "Narrow", price = 0.95, triggerFillTypes = { FillType.BARLEY } })
    addStation(world, { name = "Logs only", price = 0.93, trigger = "wood" })
    addStation(world, { name = "No triggers", price = 0.92, trigger = "none" })
    addStation(world, { name = "Bales only", price = 0.91, trigger = "bale" })
    addStation(world, { name = "Mill", price = 0.5 })

    assertEquals(TCHaulage.findDeliveryStation(FillType.WHEAT, FARM).name, "Mill")
end)

test("the farm-wide rules still apply among the fallbacks", function()
    local world = setup()
    addStation(world, { name = "Dryer", price = 0.95, farms = {} })
    addStation(world, { name = "No contracts", price = 0.9, allowMissions = false })
    addStation(world, { name = "Barley only", price = 0.85, fillTypes = { FillType.BARLEY } })
    addStation(world, { name = "Mill", price = 0.5 })

    assertEquals(TCHaulage.findDeliveryStation(FillType.WHEAT, FARM).name, "Mill")
end)

test("nowhere to deliver when the farm can unload nowhere", function()
    local world = setup()
    addStation(world, { name = "Dryer", price = 0.95, farms = {} })

    assertEquals(TCHaulage.findDeliveryStation(FillType.WHEAT, FARM), nil)
end)

test("bale delivery skips a bale point the farm can't unload at", function()
    local world = setup()
    addStation(world, { name = "Locked bales", price = 0.9, trigger = "bale", farms = {} })
    addStation(world, { name = "Dairy", price = 0.6, trigger = "bale" })

    assertEquals(TCHaulage.findBaleDeliveryStation(FillType.STRAW, FARM).name, "Dairy")
end)

test("a job pointing where its farm can't unload is moved when delivery starts, and clients told", function()
    local world = setup()
    addStation(world, { name = "Dryer", price = 0.95, farms = {} })
    addStation(world, { name = "Elevator", price = 0.9 })
    local job = addHaulageJob(world, "harvest", "Dryer")

    TCHaulage.resumeDelivery(job)

    assertEquals(job.deliveryStationUniqueId, "Elevator")
    assertEquals(job.deliveryStationName, "Elevator")
    assertTrue(next(world.placeables.Elevator.stations[1].missions) ~= nil, "tracker on the new station")
    assertTrue(next(world.placeables.Dryer.stations[1].missions) == nil, "nothing on the old one")

    g_currentMission.getIsServer = function() return true end
    TCHaulage.update(TCHaulage.POLL_INTERVAL_MS)
    assertEquals(#world.broadcasts, 1)
    assertEquals(world.broadcasts[1].stationName, "Elevator")
end)

test("a bale job is moved to a bale point, never a tipping one", function()
    local world = setup()
    addStation(world, { name = "Locked bales", price = 0.95, trigger = "bale", farms = {} })
    addStation(world, { name = "Tip only", price = 0.9 })
    addStation(world, { name = "Dairy", price = 0.6, trigger = "bale" })
    local job = addHaulageJob(world, "bale", "Locked bales")

    TCHaulage.resumeDelivery(job)

    assertEquals(job.deliveryStationUniqueId, "Dairy")
end)

test("a job whose station the farm can use is left alone", function()
    local world = setup()
    addStation(world, { name = "Mill", price = 0.5 })
    addStation(world, { name = "Elevator", price = 0.9 })
    local job = addHaulageJob(world, "harvest", "Mill")

    TCHaulage.resumeDelivery(job)

    assertEquals(job.deliveryStationUniqueId, "Mill")
    assertTrue(next(world.placeables.Mill.stations[1].missions) ~= nil, "tracker on its station")
end)

test("a job with nowhere it can deliver keeps its station and counts nothing", function()
    local world = setup()
    addStation(world, { name = "Dryer", price = 0.95, farms = {} })
    local job = addHaulageJob(world, "harvest", "Dryer")

    TCHaulage.resumeDelivery(job)

    assertEquals(job.deliveryStationUniqueId, "Dryer")
    assertTrue(next(world.placeables.Dryer.stations[1].missions) == nil, "no tracker")
end)
