-- 127: an emergency refuel. The roll (a farmer, never the official, never
-- one fallen out with or with a refuel on, weighted by the relationship;
-- one of their fields no player owns and nobody's working; a tractor of
-- theirs that's free and runs on diesel, or their combine at harvest), the
-- odds, the litres and the price, the tank's size from its XML, completion
-- at the target share of the tank, the console, and the job's refuel
-- through the save and the stream. The real EmergencyRefuel, Job,
-- FarmerFleet, YardBales (its weighted pick), Relationships and
-- TCJobSupplies, with the jobs, the farmers, the store and the engine
-- faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TheContractorRandomEvents = { DONE = "done", WAIT = "wait" }
    TheContractorJobGeneration = { JOB_TYPES = { emergencyRefuel = { offField = true } } }
    MathUtil = { getYRotationFromDirection = function(x, z) return math.atan2(x, z) end }
    FarmManager.SPECTATOR_FARM_ID = 0
    TCParking = { DEFAULT_HEIGHT = 4 }
    getWorldTranslation = function(node)
        return node.x or 0, 0, node.z or 0
    end
    g_currentMission.environment = { currentPeriod = 4, currentMonotonicDay = 30 }
    world.dieselPrice = 1.6

    -- Fields by farmland: Tom's is field 4, Ann's field 5. world.fieldOwners
    -- says which a player's bought.
    world.fieldOwners = {}
    g_fieldManager = {
        getFields = function()
            local fields = {}
            for _, farmlandId in ipairs({ 5, 4 }) do
                local field = { farmlandId = farmlandId }
                function field:getFarmland() local id = self.farmlandId return { getId = function() return id end } end
                function field:getId() return self.farmlandId end
                function field:getName() return tostring(self.farmlandId) end
                function field:getOwner() return world.fieldOwners[self.farmlandId] or 0 end
                table.insert(fields, field)
            end
            return fields
        end,
    }

    -- The store: a diesel tractor (400 l), a combine (1000 l) and its
    -- header, and an electric tractor (no diesel).
    local items = { ["tractor.xml"] = "Tractor", ["combine.xml"] = "Combine", ["header.xml"] = "Header",
        ["electric.xml"] = "E-Tractor" }
    g_storeManager = { getItemByXMLFilename = function(_, xml)
        return items[xml] ~= nil and { xmlFilename = xml, name = items[xml] } or nil
    end }
    StoreItemUtil = { getSizeValues = function() return { width = 3, length = 5, height = 3 } end }

    world:load("src/business/Job.lua")
    world:load("src/util/TCVehicleIds.lua")
    TCJobProgress = { POLL_INTERVAL_MS = 3000 }
    world:load("src/util/TCJobSupplies.lua")
    world:load("src/business/FarmerFleet.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/util/TCSiteClearance.lua")
    world:load("src/business/EmergencyRefuel.lua")
    local tanks = { ["tractor.xml"] = 400, ["combine.xml"] = 1000, ["electric.xml"] = 0 }
    TheContractorEmergencyRefuel.getTankCapacity = function(xml)
        return tanks[xml] or 0
    end

    local tc = g_currentMission.TheContractor
    world.protected = {}
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
        isFieldProtected = function(_, fieldId) return world.protected[fieldId] == true end,
    }
    tc.RepairContracts = { arrivals = {}, removals = {} }
    world:addRelationships()

    -- Tom (field 4: a tractor, a combine with its header, an electric
    -- tractor), Ann (field 5: a tractor), and the official.
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
    tc.Farmers.people[1] = { id = 1, name = "Tom Hargreaves", farmlandIds = { 4 }, machines = {
        { id = 1, role = "mediumTractor", xmlFilename = "tractor.xml" },
        { id = 2, role = "combine", xmlFilename = "combine.xml" },
        { id = 3, role = "header", xmlFilename = "header.xml", attachedTo = 2 },
        { id = 4, role = "smallTractor", xmlFilename = "electric.xml" },
    } }
    tc.Farmers.people[2] = { id = 2, name = "Ann Ridley", farmlandIds = { 5 }, machines = {
        { id = 1, role = "smallTractor", xmlFilename = "tractor.xml" },
    } }
    tc.Farmers.people[9] = { id = 9, name = "The Council", isOfficial = true, farmlandIds = { 4, 5 }, machines = {} }

    tc.EmergencyRefuel = TheContractorEmergencyRefuel.new()

    -- def: { id, farmId, state, farmerId, machineId, liters }
    function world:addRefuelJob(def)
        local job = TheContractorJob.new(def.id or 1, def.farmId or 1, "emergencyRefuel", 4, 1, 1, 1, 1000)
        job.state = def.state or TheContractorJob.STATE.ALLOCATED
        job.refuel = { farmerId = def.farmerId or 1, machineId = def.machineId or 1, reason = "gauge",
            liters = def.liters or 100, x = 10, z = 20, rotY = 0.5 }
        tc.Jobs.jobsByFarm[job.farmId] = tc.Jobs.jobsByFarm[job.farmId] or {}
        tc.Jobs.jobsByFarm[job.farmId][job.id] = job
        return job
    end

    -- The machine out on the field: a 400 l diesel tank with level in it.
    function world:addMachine(job, level)
        local vehicle = self:addVehicle({ dieselUsagePerHour = 10, dieselCapacity = 400, dieselLevel = level })
        job.refuel.machineVehicleId = vehicle.id
        return vehicle
    end

    return world, tc
end

local function fixed(value)
    return function() return value end
end

test("the roll: a farmer with a field and a diesel machine free, never the official or one fallen out with", function()
    local world, tc = setup()
    local data = tc.EmergencyRefuel:pickRequest(1)
    assertTrue(data ~= nil)
    assertTrue(data.farmerId == 1 or data.farmerId == 2, "a farmer, not the official")
    assertEquals(data.fieldId, data.farmerId == 1 and 4 or 5, "one of their own fields")
    assertEquals(data.machineId, 1, "their diesel tractor: no combine out of harvest, no electric one")
    local isReason = false
    for _, reason in ipairs(TheContractorEmergencyRefuel.REASONS) do
        isReason = isReason or data.reason == reason
    end
    assertTrue(isReason, "one of the reasons")

    -- Tom's fallen out with the farm: only Ann calls.
    tc.Relationships:applyScore(1, 1, TheContractorRelationships.REFUSES_BELOW - 1)
    for _ = 1, 10 do
        assertEquals(tc.EmergencyRefuel:pickRequest(1).farmerId, 2)
    end
    -- Ann's field is a player's now, and nobody else can call.
    world.fieldOwners[5] = 1
    assertEquals(tc.EmergencyRefuel:pickRequest(1), nil)
end)

test("the roll: a field with a job on it, or a machine that's out, won't do", function()
    local world, tc = setup()
    tc.EmergencyRefuel.forcedFarmerId = 2
    world.protected[5] = true
    assertEquals(tc.EmergencyRefuel:pickRequest(1), nil, "Ann's only field is being worked")
    world.protected[5] = nil
    table.insert(tc.RepairContracts.arrivals, { farmerId = 2, machineId = 1 })
    assertEquals(tc.EmergencyRefuel:pickRequest(1), nil, "her only tractor's out")
end)

test("the roll: weighted by the relationship", function()
    local world, tc = setup()
    tc.Relationships:applyScore(1, 2, TheContractorRelationships.MAX_SCORE)
    local candidates = tc.EmergencyRefuel:getCandidateFarmers(1, false)
    assertEquals(#candidates, 2)
    local weights = {}
    for _, candidate in ipairs(candidates) do
        weights[candidate.farmer.id] = candidate.weight
    end
    assertTrue(weights[2] > weights[1], "Ann thinks more of the farm, so she's likelier to call")
    assertEquals(TheContractorYardBales.pickWeighted(candidates, fixed(0.999)).id, 2)
end)

test("the roll: one at a time per farm, and a farmer with one on doesn't call another farm", function()
    local world, tc = setup()
    world:addRefuelJob({ farmerId = 2, state = TheContractorJob.STATE.OFFERED })
    assertEquals(tc.EmergencyRefuel:pickRequest(1), nil, "the farm has one already")
    for _ = 1, 10 do
        assertEquals(tc.EmergencyRefuel:pickRequest(2).farmerId, 1, "Ann's busy")
    end
    -- Finished, it holds nobody.
    tc.Jobs.jobsByFarm[1][1].state = TheContractorJob.STATE.COMPLETED
    assertTrue(tc.EmergencyRefuel:pickRequest(1) ~= nil)
end)

test("the machine: their combine at harvest now and then (with its header held), a tractor otherwise", function()
    local world, tc = setup()
    local tom = tc.Farmers.people[1]
    local choices = TheContractorEmergencyRefuel.getFreeMachines(tom, true)
    assertEquals(#choices, 2, "the tractor and the combine; not the electric tractor or the header")
    assertTrue(TheContractorEmergencyRefuel.pickMachine(choices, false, fixed(0)).isCombine)
    assertTrue(not TheContractorEmergencyRefuel.pickMachine(choices, false, fixed(0.99)).isCombine)
    assertEquals(#TheContractorEmergencyRefuel.getFreeMachines(tom, false), 1, "out of harvest, tractors only")

    g_currentMission.environment.currentPeriod = 6
    assertTrue(TheContractorEmergencyRefuel.isHarvest())
    g_currentMission.environment.currentPeriod = 11
    assertTrue(not TheContractorEmergencyRefuel.isHarvest())

    -- The header's out (the combine travels with it): the combine won't do.
    table.insert(tc.RepairContracts.arrivals, { farmerId = 1, machineId = 3 })
    assertEquals(#TheContractorEmergencyRefuel.getFreeMachines(tom, true), 1)
end)

test("the odds: twice as likely in spring and at harvest", function()
    setup()
    local R = TheContractorEmergencyRefuel
    g_currentMission.environment.currentPeriod = 2
    assertEquals(R.getRate(1), R.RATE_PER_PERIOD * R.BUSY_FACTOR)
    g_currentMission.environment.currentPeriod = 7
    assertEquals(R.getRate(1), R.RATE_PER_PERIOD * R.BUSY_FACTOR)
    g_currentMission.environment.currentPeriod = 4
    assertEquals(R.getRate(1), R.RATE_PER_PERIOD)
    g_currentMission.environment.currentPeriod = 10
    assertEquals(R.getRate(1), R.RATE_PER_PERIOD)
end)

test("the litres and the price: a quarter of the tank, at the diesel price x 1.5, plus the call-out at the pay rate", function()
    local world = setup()
    local R = TheContractorEmergencyRefuel
    assertEquals(R.getLiters(400), 100)
    assertEquals(R.getLiters(401), 101, "rounded up")
    local perLiter = R.getBasePricePerLiter()
    assertNear(perLiter, 1.6 * R.PRICE_FACTOR, 1e-6)
    assertEquals(R.getBasePrice(100, perLiter, 1), math.floor(100 * perLiter + R.CALL_OUT_FEE + 0.5))
    assertEquals(R.getBasePrice(100, perLiter, 2), math.floor(100 * perLiter + R.CALL_OUT_FEE * 2 + 0.5),
        "only the call-out follows the pay rate")

    -- With FS25_EconomyScale the diesel price is already scaled, so the base
    -- divides it back out (the job's price scales it again, live).
    g_currentMission.EconomyScale = { factor = 2 }
    world.dieselPrice = 3.2
    assertNear(R.getBasePricePerLiter(), perLiter, 1e-6)
end)

test("the tank's size: the diesel consumer's capacity, else its fill unit's; none without diesel", function()
    setup()
    local R = TheContractorEmergencyRefuel
    assertEquals(R.getDieselCapacityFromSpec({ consumers = { { { fillType = "diesel", fillUnitIndex = 1,
        capacity = 350 } } }, fillUnits = { { { capacity = 999 } } } }), 350)
    assertEquals(R.getDieselCapacityFromSpec({ consumers = { { { fillType = "def", fillUnitIndex = 1 },
        { fillType = "DIESEL", fillUnitIndex = 2 } } }, fillUnits = { { { capacity = 40 }, { capacity = 500 } } } }),
        500)
    assertEquals(R.getDieselCapacityFromSpec({ consumers = { { { fillType = "electricCharge", fillUnitIndex = 1 } } },
        fillUnits = { { { capacity = 300 } } } }), 0)
    assertEquals(R.getDieselCapacityFromSpec(nil), 0)
end)

test("the tank's size is read from the model's XML once a session", function()
    local world = setup()
    Vehicle = { xmlSchema = {} }
    world.xmlLoads = 0
    XMLFile = { load = function(_, filename)
        world.xmlLoads = world.xmlLoads + 1
        return { filename = filename, delete = function() end }
    end }
    Motorized = { loadSpecValueFuel = function()
        return { consumers = { { { fillType = "diesel", fillUnitIndex = 1 } } }, fillUnits = { { { capacity = 420 } } } }
    end }
    dofile("src/business/EmergencyRefuel.lua")
    TheContractorEmergencyRefuel.clearTankCache()
    assertEquals(TheContractorEmergencyRefuel.getTankCapacity("tractor.xml"), 420)
    TheContractorEmergencyRefuel.getTankCapacity("tractor.xml")
    assertEquals(world.xmlLoads, 1, "kept for the session")
    assertEquals(TheContractorEmergencyRefuel.getTankCapacity("nothing.xml"), 0, "not in the store")
end)

test("done at a quarter of the machine's tank, however it got there; nothing until it's out", function()
    local world = setup()
    local job = world:addRefuelJob({})
    assertEquals(TheContractorEmergencyRefuel.getCompletion(job), 0, "not out yet")
    local machine = world:addMachine(job, 0)
    assertEquals(TheContractorEmergencyRefuel.getCompletion(job), 0)
    machine.fillUnits[1].level = 60
    assertNear(TheContractorEmergencyRefuel.getCompletion(job), 0.6, 1e-6)
    machine.fillUnits[1].level = 100
    assertEquals(TheContractorEmergencyRefuel.getCompletion(job), 1)
    machine.fillUnits[1].level = 400
    assertEquals(TheContractorEmergencyRefuel.getCompletion(job), 1)
end)

test("emptying the tank takes out all its diesel", function()
    local world = setup()
    local job = world:addRefuelJob({})
    local machine = world:addMachine(job, 400)
    assertEquals(TheContractorEmergencyRefuel.emptyTank(machine, 1), 400)
    assertEquals(machine.fillUnits[1].level, 0)
    assertEquals(TheContractorEmergencyRefuel.emptyTank(machine, 1), 0)
end)

test("the console: reason, combine and farmer, in any order; a farmer nobody knows is refused", function()
    local world, tc = setup()
    assertEquals(tc.EmergencyRefuel:prepareTrigger({ "combine", "Tom", "Hargreaves", "forgot" }), nil)
    assertEquals(tc.EmergencyRefuel.forcedReason, "forgot")
    assertTrue(tc.EmergencyRefuel.forcedCombine)
    assertEquals(tc.EmergencyRefuel.forcedFarmerId, 1)
    local data = tc.EmergencyRefuel:pickRequest(1)
    assertEquals(data.farmerId, 1)
    assertEquals(data.machineId, 2, "the combine, out of harvest too")
    assertEquals(data.reason, "forgot")

    -- Ann has no combine.
    local ann = TheContractorEmergencyRefuel.new()
    assertEquals(ann:prepareTrigger({ "combine", "2" }), nil)
    assertEquals(ann:pickRequest(1), nil)

    local other = TheContractorEmergencyRefuel.new()
    assertTrue(other:prepareTrigger({ "Nobody" }) ~= nil)
    assertEquals(other.forcedReason, nil)
    assertTrue(other:prepareTrigger({ "The", "Council" }) ~= nil, "never the official")
end)

test("the refuel, its reason and its machine go through the save (by uniqueId) and the stream", function()
    local world = setup()
    local job = world:addRefuelJob({ machineId = 2 })
    job.refuel.attachmentMachineId = 3
    local machine = world:addMachine(job, 0)
    function machine:getUniqueId() return "combine7" end
    local header = world:addVehicle({})
    function header:getUniqueId() return "header8" end
    job.refuel.attachmentVehicleId = header.id
    job.refuel.collected = true

    local xmlFile = {}
    TheContractorEmergencyRefuel.saveToXML(xmlFile, "job", job.refuel)
    local loaded = TheContractorEmergencyRefuel.loadFromXML(xmlFile, "job")
    assertEquals(loaded.reason, "gauge")
    assertEquals(loaded.liters, 100)
    assertEquals(loaded.farmerId, 1)
    assertEquals(loaded.machineId, 2)
    assertEquals(loaded.attachmentMachineId, 3)
    assertNear(loaded.rotY, 0.5, 1e-6)
    assertEquals(loaded.machineUniqueId, "combine7")
    assertEquals(loaded.attachmentUniqueId, "header8")
    assertEquals(loaded.machineVehicleId, nil, "object ids change every load")
    assertTrue(loaded.collected)
    assertEquals(TheContractorEmergencyRefuel.loadFromXML({}, "job"), nil)

    local stream = world:newStream()
    TheContractorEmergencyRefuel.writeStream(stream, job.refuel)
    TheContractorEmergencyRefuel.writeStream(stream, nil)
    local copy = TheContractorEmergencyRefuel.readStream(stream)
    assertEquals(copy.reason, "gauge")
    assertEquals(copy.liters, 100)
    assertEquals(copy.farmerId, 1)
    assertEquals(copy.machineId, 2)
    assertEquals(copy.attachmentMachineId, 3)
    assertEquals(copy.machineVehicleId, machine.id)
    assertEquals(copy.attachmentVehicleId, header.id)
    assertEquals(copy.machineUniqueId, nil, "the server's own")
    assertEquals(copy.collected, nil)
    assertEquals(TheContractorEmergencyRefuel.readStream(stream), nil)
end)

test("the map marker: on the machine while it's taken on, following it; on its spot until it's out", function()
    local world = setup()
    local job = world:addRefuelJob({})
    local spot = TheContractorEmergencyRefuel.getSpot(job)
    assertEquals(spot.x, 10)
    assertEquals(spot.z, 20)
    local machine = world:addMachine(job, 0)
    machine.rootNode = { x = 900, z = 40 }
    assertEquals(TheContractorEmergencyRefuel.getSpot(job).x, 900)
    job.state = TheContractorJob.STATE.COMPLETED
    assertEquals(TheContractorEmergencyRefuel.getSpot(job), nil)
end)

test("the logbook: the litres asked for, what was in the tank as it ended, and the machine", function()
    local world = setup()
    local job = world:addRefuelJob({})
    local machine = world:addMachine(job, 130)
    local delivery = TheContractorEmergencyRefuel.getLogbookDelivery(job)
    assertEquals(delivery.fillTypeName, "DIESEL")
    assertEquals(delivery.requiredLiters, 100)
    assertEquals(delivery.deliveredLiters, 130)
    assertTrue(delivery.machineName ~= nil)
    assertEquals(TheContractorEmergencyRefuel.getLogbookDelivery(TheContractorJob.new(2, 1, "plow", 4, 1, 1, 1, 1)),
        nil)
end)
