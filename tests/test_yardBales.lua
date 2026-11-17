-- 124: bales to a farmer's yard. What the farm holds (loose bales, and
-- stored ones abstract or kept live), what's asked for (the commonest
-- size, a share of it, within the limits), the roll (a farmer with a yard
-- and their kit free, never one fallen out with), the drop area (open
-- ground with the telehandler beside it), counting in the area (resting,
-- not mounted, the fill type, the farm's), delivering (each bale gone as
-- it counts, largest first, the one past the order whole, the excess paid
-- on top), the price, the farmer's kit held by the job, and the order
-- and the area through the save and the stream. The real YardBales, Job
-- and FarmerFleet, with the jobs, the farmers and the engine faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TheContractorJobGeneration = { JOB_TYPES = { yardBales = { offField = true, yardDelivery = true } } }
    TheContractorRandomEvents = { DONE = "done", WAIT = "wait" }
    MathUtil = { getYRotationFromDirection = function(x, z) return math.atan2(x, z) end }
    FarmManager.SPECTATOR_FARM_ID = 0
    TCParking = { DEFAULT_HEIGHT = 4 }
    world.straw = world:addFillType("STRAW", "Straw")
    world.hay = world:addFillType("DRYGRASS_WINDROW", "Hay")
    world.silage = world:addFillType("SILAGE", "Silage")
    world.grass = world:addFillType("GRASS_WINDROW", "Grass")

    -- Bales: plain tables that say they're one.
    Bale = {}
    world.items = {}
    world.nextUniqueId = 1
    g_currentMission.itemSystem = {
        itemsToSave = world.items,
        getItemByUniqueId = function(_, uniqueId)
            for _, entry in pairs(world.items) do
                if entry.item.uniqueId == uniqueId then
                    return entry.item
                end
            end
            return nil
        end,
    }
    getWorldTranslation = function(node)
        return node.x or 0, 0, node.z or 0
    end
    getLinearVelocity = function(node)
        return node.vx or 0, 0, node.vz or 0
    end

    -- def: { fillType, fillLevel, farmId, x, z, isFermenting, mounted, vx }
    function world:addBale(def)
        local bale = {
            fillType = def.fillType or world.straw,
            fillLevel = def.fillLevel or 4000,
            ownerFarmId = def.farmId or 1,
            isFermenting = def.isFermenting == true,
            mounted = def.mounted == true,
            nodeId = { x = def.x or 0, z = def.z or 0, vx = def.vx },
            uniqueId = "bale" .. world.nextUniqueId,
            canBeSold = true,
        }
        world.nextUniqueId = world.nextUniqueId + 1
        function bale:isa(class) return class == Bale end
        function bale:getOwnerFarmId() return self.ownerFarmId end
        function bale:setOwnerFarmId(farmId) self.ownerFarmId = farmId end
        function bale:setCanBeSold(canBeSold) self.canBeSold = canBeSold end
        function bale:getUniqueId() return self.uniqueId end
        function bale:getIsMounted() return self.mounted end
        function bale:delete()
            self.isDeleted = true
            for key, entry in pairs(world.items) do
                if entry.item == self then
                    world.items[key] = nil
                end
            end
        end
        world.items[bale.uniqueId] = { item = bale }
        return bale
    end

    -- A bale storage: def { farmId, objects = { { fillType, fillLevel,
    -- isLive, isFermenting } } }, abstract (baleAttributes) or kept live
    -- (baleObject).
    function world:addBaleStorage(def)
        local stored = {}
        for _, object in ipairs(def.objects or {}) do
            local bale = { fillType = object.fillType, fillLevel = object.fillLevel,
                isFermenting = object.isFermenting == true }
            table.insert(stored, object.isLive and { baleObject = bale } or { baleAttributes = bale })
        end
        return world:addPlaceable({ farmId = def.farmId or 1, specs = { spec_objectStorage = { storedObjects = stored } } })
    end

    world:load("src/business/Job.lua")
    world:load("src/util/TCVehicleIds.lua")
    world:load("src/business/FarmerFleet.lua")
    world:load("src/business/YardBales.lua")

    local tc = g_currentMission.TheContractor
    world.completed, world.deliveries = {}, {}
    tc.Jobs = {
        jobsByFarm = {},
        getAllJobs = function(self, farmId)
            local result = {}
            for _, job in pairs(self.jobsByFarm[farmId] or {}) do
                table.insert(result, job)
            end
            table.sort(result, function(a, b) return a.id < b.id end)
            return result
        end,
        getJob = function(self, farmId, jobId)
            return (self.jobsByFarm[farmId] or {})[jobId]
        end,
        applyJobDelivery = function(self, farmId, jobId, delivered, required)
            local job = self:getJob(farmId, jobId)
            job.deliveredLiters, job.requiredLiters = delivered, required
            table.insert(world.deliveries, delivered)
        end,
        completeJob = function(_, job)
            job.state = TheContractorJob.STATE.COMPLETED
            job.paymentAmount = job:getPrice() + TheContractorYardBales.getExcessPay(job)
            table.insert(world.completed, job.id)
        end,
    }
    tc.RepairContracts = { arrivals = {}, removals = {} }

    -- def: { id, farmId, state, required, x, z, rotY, fillType, pricePerLiter,
    -- farmerId, machineId, attachmentMachineId }
    function world:addYardJob(def)
        local job = TheContractorJob.new(def.id or 1, def.farmId or 1, "yardBales", 7, 1, 1, 1, def.price or 1000)
        job.state = def.state or TheContractorJob.STATE.ALLOCATED
        job.requiredLiters = def.required or 8000
        job.yardDelivery = {
            farmerId = def.farmerId or 3,
            yardFarmlandId = 9,
            fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(def.fillType or world.straw),
            baleSize = 4000,
            baleCount = 2,
            liters = job.requiredLiters,
            pricePerLiter = def.pricePerLiter or 0.3,
            x = def.x or 100,
            z = def.z or 100,
            rotY = def.rotY or 0,
            width = 12,
            length = 12,
            kitX = 110,
            kitZ = 100,
            kitRotY = 0,
            machineId = def.machineId or 5,
            attachmentMachineId = def.attachmentMachineId or 6,
        }
        tc.Jobs.jobsByFarm[job.farmId] = tc.Jobs.jobsByFarm[job.farmId] or {}
        tc.Jobs.jobsByFarm[job.farmId][job.id] = job
        return job
    end

    return world, tc
end

local function sequence(values)
    local index = 0
    return function()
        index = index + 1
        return values[math.min(index, #values)]
    end
end

-- What the farm holds ------------------------------------------------------------

test("held bales: loose and stored (abstract or live), by fill type and size, only the farm's straw, hay and silage", function()
    local world, tc = setup()
    world:addBale({ fillLevel = 4000 })
    world:addBale({ fillLevel = 3999.6 })
    world:addBale({ fillLevel = 2400 })
    world:addBale({ fillType = world.hay, fillLevel = 2000 })
    world:addBale({ fillLevel = 4000, isFermenting = true })
    world:addBale({ fillLevel = 4000, farmId = 2 })
    world:addBale({ fillType = world.silage, fillLevel = 4000 })
    -- A wrapped grass bale still fermenting isn't silage yet.
    world:addBale({ fillType = world.grass, fillLevel = 4000, isFermenting = true })
    world:addBaleStorage({ objects = {
        { fillType = world.silage, fillLevel = 4000, isLive = true },
        { fillType = world.straw, fillLevel = 4000 },
        { fillType = world.straw, fillLevel = 4000, isLive = true },
        { fillType = world.straw, fillLevel = 4000, isLive = true, isFermenting = true },
        { fillType = world.hay, fillLevel = 2000 },
    } })
    world:addBaleStorage({ farmId = 2, objects = { { fillType = world.straw, fillLevel = 4000 } } })

    -- A bale a live job laid out is the job's, not the farm's.
    local job = world:addYardJob({ state = TheContractorJob.STATE.ALLOCATED })
    job.yardDelivery = nil
    job.spawnedBaleIds = { world:addBale({ fillLevel = 4000 }).uniqueId }

    local holdings = TheContractorYardBales.getHoldings(1)
    assertEquals(holdings[world.straw][4000], 4, "straw 4000s: two loose, one stored, one stored live")
    assertEquals(holdings[world.straw][2400], 1)
    assertEquals(holdings[world.hay][2000], 2, "hay: one loose, one stored")
    assertEquals(holdings[world.silage][4000], 2, "silage: one loose, one stored live")
    assertEquals(holdings[world.grass], nil, "no grass")
end)

test("asked for: the commonest size, a share of those held, between 6 and 24 and never more than held", function()
    local world = setup()
    local holdings = { [world.straw] = { [4000] = 20, [2400] = 8 }, [world.hay] = {} }

    local least = TheContractorYardBales.pickBales(holdings, nil, sequence({ 0, 0 }))
    assertEquals(least.fillTypeIndex, world.straw)
    assertEquals(least.baleSize, 4000)
    assertEquals(least.baleCount, 6, "30% of 20")
    assertEquals(least.liters, 6 * 4000)
    local most = TheContractorYardBales.pickBales(holdings, nil, sequence({ 0, 0.999 }))
    assertEquals(most.baleCount, 14, "70% of 20")

    local many = TheContractorYardBales.pickBales({ [world.straw] = { [4000] = 40 } }, nil, sequence({ 0, 0.999 }))
    assertEquals(many.baleCount, TheContractorYardBales.MAX_BALES)
    local few = TheContractorYardBales.pickBales({ [world.straw] = { [4000] = 7 } }, nil, sequence({ 0, 0 }))
    assertEquals(few.baleCount, TheContractorYardBales.MIN_BALES)
end)

test("asked for: nothing with fewer than 6 of the commonest size, or none of the fill type wanted", function()
    local world = setup()
    -- A tie goes to the bigger bale, of which there are only 5.
    assertEquals(TheContractorYardBales.pickBales({ [world.straw] = { [4000] = 5, [2400] = 5 } }, nil, math.random),
        nil)
    local holdings = { [world.straw] = { [4000] = 10 }, [world.hay] = {} }
    assertEquals(TheContractorYardBales.pickBales(holdings, world.hay, math.random), nil)
    assertEquals(TheContractorYardBales.pickBales(holdings, world.straw, sequence({ 0, 0 })).fillTypeIndex, world.straw)
end)

-- The roll -----------------------------------------------------------------------------

local function setupFarmers(world, tc)
    world.store = {}
    g_storeManager = { getItemByXMLFilename = function(_, xml) return world.store[xml] end }
    StoreItemUtil = { getSizeValues = function() return { width = 3, length = 6, height = 3 } end }
    for _, xml in ipairs({ "telehandler.xml", "fork.xml" }) do
        world.store[xml] = { xmlFilename = xml, name = xml }
    end
    local function farmer(id, yardFarmlandId)
        return { id = id, name = "Farmer " .. id, farmlandIds = { 20 + id }, yardFarmlandId = yardFarmlandId,
            machines = {
                { id = 1, role = "telehandler", xmlFilename = "telehandler.xml" },
                { id = 2, role = "baleFork", xmlFilename = "fork.xml", attachedTo = 1 },
            } }
    end
    world.farmers = { farmer(1, 11), farmer(2, 12), farmer(3, nil) }
    world.weights = { [1] = 1, [2] = 0, [3] = 1 }
    tc.Farmers = {
        getFarmers = function() return world.farmers end,
        getPerson = function(_, id) return world.farmers[id] end,
    }
    tc.Relationships = { getOfferWeight = function(_, farmId, id) return world.weights[id] end }
    TheContractorFieldBreakdowns = { getUsableYard = function(person) return person.yardFarmlandId end }
end

test("the roll: a farmer with a yard and their kit free, never one fallen out with, one order at a time", function()
    local world, tc = setup()
    setupFarmers(world, tc)
    for _ = 1, 8 do
        world:addBale({ fillLevel = 4000 })
    end
    local yardBales = TheContractorYardBales.new()

    -- Farmer 2's fallen out (weight 0) and farmer 3 has no yard.
    for _ = 1, 5 do
        local data = yardBales:pickRequest(1)
        assertEquals(data.farmerId, 1)
        assertEquals(data.fillTypeName, "STRAW")
        assertEquals(data.baleSize, 4000)
        assertTrue(data.baleCount >= 6 and data.baleCount <= 8)
    end

    -- Farmer 1's telehandler is out on something else.
    table.insert(tc.RepairContracts.arrivals, { farmerId = 1, machineId = 1 })
    assertEquals(yardBales:pickRequest(1), nil)
    tc.RepairContracts.arrivals = {}

    -- The farm has an order on already.
    world:addYardJob({ state = TheContractorJob.STATE.OFFERED, farmerId = 1 })
    assertEquals(yardBales:pickRequest(1), nil)
end)

test("the roll: nothing with too few bales; the console picks the fill type and the farmer", function()
    local world, tc = setup()
    setupFarmers(world, tc)
    for _ = 1, 5 do
        world:addBale({ fillLevel = 4000 })
    end
    local yardBales = TheContractorYardBales.new()
    assertEquals(yardBales:pickRequest(1), nil)

    for _ = 1, 6 do
        world:addBale({ fillType = world.hay, fillLevel = 2000 })
    end
    world.weights[2] = 1
    assertEquals(yardBales:prepareTrigger({ "hay", "2" }), nil)
    local data = yardBales:pickRequest(1)
    assertEquals(data.fillTypeName, "DRYGRASS_WINDROW")
    assertEquals(data.farmerId, 2)
    assertTrue(yardBales:prepareTrigger({ "nobody" }) ~= nil, "an unknown farmer is refused")

    for _ = 1, 6 do
        world:addBale({ fillType = world.silage, fillLevel = 4000 })
    end
    assertEquals(yardBales:prepareTrigger({ "silage" }), nil)
    assertEquals(yardBales:pickRequest(1).fillTypeName, "SILAGE")
end)

-- The drop area ------------------------------------------------------------------------

test("the drop area: on open ground, facing the yard's middle, with the telehandler's footprint open beside it", function()
    local world, tc = setup()
    tc.Yards = { getSpots = function() return { x = 0, z = 0, spots = { { x = 0, z = 20 }, { x = 30, z = 0 } } } end }
    -- Everything past z 14 is a building.
    local function isOpen(_, x, z)
        return z <= 14
    end
    local footprint = { width = 3, length = 9 }
    local area = TheContractorYardBales.pickDropArea(9, footprint, sequence({ 0 }), isOpen)
    assertEquals(area.x, 30)
    assertEquals(area.z, 0)
    assertNear(area.rotY, -math.pi / 2, 1e-6, "facing the middle")
    local offset = TheContractorYardBales.DROP_WIDTH * 0.5 + TheContractorYardBales.KIT_GAP + footprint.width * 0.5
    assertNear(math.sqrt((area.kitX - area.x) ^ 2 + (area.kitZ - area.z) ^ 2), offset, 1e-6)
    assertTrue(not TheContractorYardBales.isInArea(area, area.kitX, area.kitZ), "the kit's outside the area")

    -- No room anywhere: no area.
    assertEquals(TheContractorYardBales.pickDropArea(9, footprint, sequence({ 0 }), function() return false end), nil)
end)

-- Counting --------------------------------------------------------------------------------

test("counting: only the farm's bales of the fill type, put down and still, inside the area", function()
    local world = setup()
    local job = world:addYardJob({ x = 100, z = 100 })
    world:addBale({ x = 101, z = 99 })
    world:addBale({ x = 104, z = 105, fillLevel = 2400 })
    world:addBale({ x = 100, z = 100, mounted = true })
    world:addBale({ x = 100, z = 100, vx = 1 })
    world:addBale({ x = 100, z = 100, fillType = world.hay })
    world:addBale({ x = 100, z = 100, farmId = 2 })
    world:addBale({ x = 107, z = 100 })

    local bales, liters = TheContractorYardBales.getAreaBales(job)
    assertEquals(#bales, 2)
    assertEquals(liters, 6400)
end)

test("counting a silage order: fermented silage bales count, a wrapped bale still fermenting doesn't", function()
    local world = setup()
    local job = world:addYardJob({ x = 100, z = 100, fillType = world.silage })
    world:addBale({ x = 101, z = 99, fillType = world.silage })
    world:addBale({ x = 100, z = 100, fillType = world.grass, isFermenting = true })
    world:addBale({ x = 100, z = 100 })

    local bales, liters = TheContractorYardBales.getAreaBales(job)
    assertEquals(#bales, 1)
    assertEquals(liters, 4000)
end)

test("the area turns with its heading", function()
    setup()
    local area = { x = 0, z = 0, rotY = math.pi / 4, width = 12, length = 2 }
    assertTrue(TheContractorYardBales.isInArea(area, 3, -3), "along its width")
    assertTrue(not TheContractorYardBales.isInArea(area, 3, 3), "off its length")
end)

-- Taking ---------------------------------------------------------------------------------

test("taking: whole bales, largest first, until the order's covered; the rest stay", function()
    setup()
    local bales = { { liters = 2400 }, { liters = 4000 }, { liters = 4000 }, { liters = 2400 } }
    local taken, liters, excess = TheContractorYardBales.pickBalesToTake(bales, 9000)
    assertEquals(#taken, 3)
    assertEquals(taken[1].liters, 4000)
    assertEquals(taken[3].liters, 2400)
    assertEquals(liters, 10400)
    assertEquals(excess, 1400)

    local exact, exactLiters, none = TheContractorYardBales.pickBalesToTake(bales, 8000)
    assertEquals(#exact, 2)
    assertEquals(exactLiters, 8000)
    assertEquals(none, 0)
end)

test("delivered: each bale put down goes, its litres count, and the one past the order goes whole, paid as excess", function()
    local world = setup()
    g_currentMission.EconomyScale = { factor = 2 }
    local job = world:addYardJob({ required = 7000, pricePerLiter = 0.3 })
    local first = world:addBale({ x = 101, z = 100 })
    local yardBales = TheContractorYardBales.new()

    assertEquals(TheContractorYardBales.getCompletion(job), 0)
    yardBales:countJobs()
    assertTrue(first.isDeleted, "gone as it's delivered")
    assertEquals(job.deliveredLiters, 4000)
    assertEquals(#world.completed, 0)

    -- Two more at once: the bigger one covers the order, the other stays.
    local small = world:addBale({ x = 100, z = 100, fillLevel = 2400 })
    local big = world:addBale({ x = 102, z = 100 })
    yardBales:countJobs()
    assertTrue(big.isDeleted)
    assertTrue(not small.isDeleted, "not needed, so still the farm's")
    assertEquals(job.deliveredLiters, 8000)
    assertEquals(world.completed[1], job.id)
    assertEquals(job.yardDelivery.takenBales, 2)
    assertEquals(job.yardDelivery.takenLiters, 8000)
    assertEquals(job.yardDelivery.excessLiters, 1000)
    assertEquals(TheContractorYardBales.getExcessPay(job), TCEconomyScale.scale(1000 * 0.3))
    assertEquals(job.paymentAmount, job:getPrice() + TCEconomyScale.scale(1000 * 0.3))
    assertEquals(TheContractorYardBales.getCompletion(job), 1)

    -- Done: nothing more is taken.
    yardBales:countJobs()
    assertTrue(not small.isDeleted)

    local delivery = TheContractorYardBales.getLogbookDelivery(job)
    assertEquals(delivery.requiredLiters, 7000)
    assertEquals(delivery.deliveredLiters, 8000)
    assertEquals(delivery.excessLiters, 1000)
end)

test("short of the order: what's in counts and goes, never done; an offer takes nothing", function()
    local world = setup()
    local job = world:addYardJob({ required = 8000 })
    local bale = world:addBale({ x = 100, z = 100 })
    local outside = world:addBale({ x = 120, z = 100 })
    local yardBales = TheContractorYardBales.new()
    yardBales:countJobs()
    assertEquals(job.deliveredLiters, 4000)
    assertTrue(bale.isDeleted)
    assertTrue(not outside.isDeleted)
    assertEquals(#world.completed, 0)
    assertNear(TheContractorYardBales.getCompletion(job), 0.5, 1e-6)

    -- Even at the order, the sweep can't finish it first.
    job.deliveredLiters = 9000
    assertEquals(TheContractorYardBales.getCompletion(job), 0.99)

    job.state = TheContractorJob.STATE.OFFERED
    job.deliveredLiters = 0
    local offered = world:addBale({ x = 100, z = 100 })
    yardBales:countJobs()
    assertEquals(job.deliveredLiters, 0)
    assertTrue(not offered.isDeleted)
end)

-- Price ------------------------------------------------------------------------------------

test("price: the sell price back to base, times the factor, for the litres, plus the call-out fee", function()
    local world = setup()
    g_currentMission.EconomyScale = { factor = 2 }
    g_currentMission.economyManager.getPricePerLiter = function(_, fillTypeIndex)
        return fillTypeIndex == world.straw and 0.2 or 0
    end
    local perLiter = TheContractorYardBales.getBasePricePerLiter(world.straw)
    assertNear(perLiter, 0.2 * TheContractorYardBales.PRICE_FACTOR / 2, 1e-9)
    assertEquals(TheContractorYardBales.getBasePrice(10000, perLiter),
        math.floor(10000 * perLiter + TheContractorYardBales.CALL_OUT_FEE + 0.5))
end)

-- The kit -----------------------------------------------------------------------------------

test("the farmer's telehandler and fork are out while the job's open, and free once it's over", function()
    local world = setup()
    local job = world:addYardJob({ state = TheContractorJob.STATE.OFFERED, farmerId = 3, machineId = 5,
        attachmentMachineId = 6 })
    assertTrue(TheContractorFarmerFleet.isMachineOut(3, 5))
    assertTrue(TheContractorFarmerFleet.isMachineOut(3, 6))
    assertTrue(not TheContractorFarmerFleet.isMachineOut(3, 7))
    assertTrue(not TheContractorFarmerFleet.isMachineOut(4, 5), "another farmer's")
    job.state = TheContractorJob.STATE.COMPLETED
    assertTrue(not TheContractorFarmerFleet.isMachineOut(3, 5))
end)

test("a finished job's kit goes home once, wherever it's been left", function()
    local world, tc = setup()
    local job = world:addYardJob({ state = TheContractorJob.STATE.MISSED })
    job.yardDelivery.kitVehicleId, job.yardDelivery.kitAttachmentId = 40, 41
    local queued = {}
    function tc.RepairContracts:queueLoanCollection(farmId, farmerId, vehicleId, uniqueId, machineId)
        table.insert(queued, { vehicleId = vehicleId, machineId = machineId })
    end
    local yardBales = TheContractorYardBales.new()
    yardBales:collectFinishedKit()
    yardBales:collectFinishedKit()
    assertEquals(#queued, 2)
    assertEquals(queued[1].vehicleId, 40)
    assertEquals(queued[1].machineId, 5)
    assertEquals(queued[2].machineId, 6)
end)

-- Save and stream ---------------------------------------------------------------------------

test("the order, the area and the kit go through the save (by uniqueId) and the stream", function()
    local world = setup()
    local telehandler = world:addVehicle({ name = "Telehandler" })
    function telehandler:getUniqueId() return "veh-telehandler" end
    local job = world:addYardJob({ rotY = 0.5 })
    local yard = job.yardDelivery
    yard.kitVehicleId = telehandler.id
    yard.kitCollected = true
    yard.takenLiters, yard.takenBales, yard.excessLiters = 8400, 2, 400

    local xmlFile = {}
    TheContractorYardBales.saveToXML(xmlFile, "job", yard, 3500)
    local loaded = TheContractorYardBales.loadFromXML(xmlFile, "job")
    for _, key in ipairs({ "fillTypeName", "farmerId", "yardFarmlandId", "baleSize", "baleCount", "liters",
        "pricePerLiter", "x", "z", "rotY", "width", "length", "kitX", "kitZ", "kitRotY", "machineId",
        "attachmentMachineId", "takenLiters", "takenBales", "excessLiters" }) do
        assertEquals(loaded[key], yard[key], key)
    end
    assertEquals(loaded.deliveredLiters, 3500, "the job's delivered litres, kept with the order")
    assertEquals(loaded.kitUniqueId, "veh-telehandler")
    assertEquals(loaded.kitVehicleId, nil, "the object id isn't saved")
    assertTrue(loaded.kitCollected)
    assertEquals(TheContractorYardBales.loadFromXML({}, "job"), nil)

    local stream = world:newStream()
    TheContractorYardBales.writeStream(stream, yard)
    TheContractorYardBales.writeStream(stream, nil)
    local read = TheContractorYardBales.readStream(stream)
    for _, key in ipairs({ "fillTypeName", "farmerId", "baleCount", "x", "z", "rotY", "width", "length",
        "machineId" }) do
        assertEquals(read[key], yard[key], key)
    end
    assertEquals(read.kitVehicleId, telehandler.id)
    assertEquals(read.kitAttachmentId, nil)
    assertEquals(TheContractorYardBales.readStream(stream), nil)
end)

-- The marking ---------------------------------------------------------------------------------

test("the marking: one on each of the farm's drop areas while the job's taken on, at the area, gone after", function()
    local world = setup()
    g_client = {}
    TheContractor.dir = ""
    world.loaded, world.released, world.nodes = {}, {}, {}
    world.triggerMarkers = {}
    function g_currentMission:addTriggerMarker(node) world.triggerMarkers[node] = true end
    function g_currentMission:removeTriggerMarker(node) world.triggerMarkers[node] = nil end
    g_i3DManager = {
        loadSharedI3DFile = function(_, filename)
            table.insert(world.loaded, filename)
            local root = { child = { live = true } }
            return root, #world.loaded
        end,
        releaseSharedI3DFile = function(_, id) table.insert(world.released, id) end,
    }
    getChildAt = function(root) return root.child end
    getRootNode = function() return {} end
    link = function() end
    delete = function(node) node.live = false end
    entityExists = function(node) return node.live == true end
    setTranslation = function(node, x, y, z) node.x, node.y, node.z = x, y, z end
    setRotation = function(node, _, ry) node.rotY = ry end
    getTerrainHeightAtWorldPos = function() return 7 end
    g_terrainNode = 1

    local job = world:addYardJob({ state = TheContractorJob.STATE.OFFERED, x = 40, z = 50, rotY = 0.5 })
    world:addYardJob({ id = 2, farmId = 2, state = TheContractorJob.STATE.ALLOCATED })
    local yardBales = TheContractorYardBales.new()
    yardBales:refreshMarkings()
    assertEquals(#world.loaded, 0, "not for an offer, nor another farm's job")

    job.state = TheContractorJob.STATE.ALLOCATED
    yardBales:refreshMarkings()
    yardBales:refreshMarkings()
    assertEquals(#world.loaded, 2, "the marking and its icon, loaded once")
    assertEquals(world.loaded[1], TheContractorYardBales.MARKING_FILENAME)
    assertEquals(world.loaded[2], TheContractorYardBales.ICON_FILENAME)
    local node = yardBales.markings[job.id].node
    assertEquals(node.x, 40)
    assertEquals(node.y, 7)
    assertEquals(node.z, 50)
    assertEquals(node.rotY, 0.5)
    local icon = yardBales.markings[job.id].iconNode
    assertEquals(icon.x, 40)
    assertNear(icon.y, 7 + TheContractorYardBales.ICON_GROUND_OFFSET, 0.0001)
    assertEquals(icon.z, 50)
    assertTrue(world.triggerMarkers[icon], "the icon is a trigger marker, so the game's setting hides it")

    job.state = TheContractorJob.STATE.COMPLETED
    yardBales:refreshMarkings()
    assertTrue(not node.live)
    assertTrue(not icon.live)
    assertEquals(world.triggerMarkers[icon], nil)
    assertEquals(#world.released, 2)
    assertEquals(yardBales.markings[job.id], nil)
end)

-- The map marker -------------------------------------------------------------------------------

test("the map marker: on the area's centre, as wide as its diagonal, only while it's taken on", function()
    local world = setup()
    local job = world:addYardJob({ state = TheContractorJob.STATE.OFFERED, x = 40, z = 50 })
    assertEquals(TheContractorYardBales.getSpot(job), nil, "not for an offer")

    job.state = TheContractorJob.STATE.ACCEPTED
    local spot = TheContractorYardBales.getSpot(job)
    assertEquals(spot.x, 40)
    assertEquals(spot.z, 50)
    assertNear(spot.radius, math.sqrt(12 * 12 + 12 * 12), 0.0001)

    job.state = TheContractorJob.STATE.COMPLETED
    assertEquals(TheContractorYardBales.getSpot(job), nil)
end)
