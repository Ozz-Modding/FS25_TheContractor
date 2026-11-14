-- 110: farmers and the local official - made the first time on a save from
-- 109's split, through a save, a load and a client join; land following a
-- player's purchases and sales (and land nobody has at load); who a job's
-- customer is (field, offField, a spilt crop's original job, none for a
-- repair contract), linking older jobs, and generating them again. The real
-- split, Job and Jobs (for the customer through the save and the stream);
-- names, looks, yards and the map are faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TCJobConsequences = {
        saveToXML = function() end,
        loadFromXML = function() end,
        writeReports = function() end,
        readReports = function() return {} end,
    }
    TCVehicleIds = { saveList = function() end, loadList = function() return {} end }
    TheContractorCropSpill = {
        writeStream = function() end,
        readStream = function() return nil end,
        saveToXML = function() end,
        loadFromXML = function() return nil end,
    }
    TheContractorJobGeneration = {
        JOB_TYPES = { plow = {}, fallenTree = { offField = true }, spillClearUp = { spill = true } },
        getOperationSkill = function() return nil end,
    }

    Enterable = {}
    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/util/TCLotInspections.lua")
    world:load("src/business/FarmerSplit.lua")
    world:load("src/business/Farmers.lua")
    world:load("src/business/FarmerFleet.lua")
    -- The grid below is sized for 30 acres a farmer, whatever the default.
    TheContractorFarmerSplit.TARGET_ACRES = 30

    world.nameCount = 0
    TheContractorStaff = {
        generateName = function(gender)
            world.nameCount = world.nameCount + 1
            return "Person " .. world.nameCount
        end,
        guessGender = function() return "male" end,
    }
    TCWorkerAppearance.roll = function(gender)
        return { model = gender .. ".xml", configs = { face = { name = "face1", color = 2 } } }
    end

    -- A 4 x 2 grid of farmlands 300 m apart, ids 1-8, each with one 10 ha
    -- field of the same id; farmland 9 has no field. Farm 1 owns farmland 1.
    world.owners = { [1] = 1 }
    world.fields = {}
    for id = 1, 8 do
        local x, z = ((id - 1) % 4) * 300, math.floor((id - 1) / 4) * 300
        local farmland = { getId = function() return id end }
        world.fields[id] = {
            getId = function() return id end,
            getFarmland = function() return farmland end,
            getAreaHa = function() return 10 end,
            getCenterOfFieldWorldPosition = function() return x, z end,
        }
    end
    g_fieldManager = {
        getFields = function()
            local list = {}
            for id = 1, 8 do
                if world.fields[id] ~= nil then
                    table.insert(list, world.fields[id])
                end
            end
            return list
        end,
        getFieldById = function(_, fieldId) return world.fields[fieldId] end,
    }
    g_farmlandManager = {
        getFarmlandOwner = function(_, farmlandId) return world.owners[farmlandId] or 0 end,
        getIsValidFarmlandId = function(_, farmlandId) return farmlandId >= 1 and farmlandId <= 9 end,
    }

    -- 108's yards: { farmlandId, x, z, how }; owner from world.owners.
    world.yards = {}
    local tc = g_currentMission.TheContractor
    tc.Yards = {
        getYards = function()
            local list = {}
            for _, yard in ipairs(world.yards) do
                table.insert(list, { farmlandId = yard.farmlandId, x = yard.x, z = yard.z,
                    ownerFarmId = world.owners[yard.farmlandId] or 0, how = yard.how or "detected" })
            end
            return list
        end,
    }

    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    TCFarmerLandEvent = {
        new = function(farmer)
            local ids = {}
            for _, id in ipairs(farmer.farmlandIds) do
                table.insert(ids, id)
            end
            return { kind = "land", personId = farmer.id, farmlandIds = ids, yardFarmlandId = farmer.yardFarmlandId }
        end,
    }
    TCFarmersEvent = { new = function(farmers, links) return { kind = "farmers", links = links } end }

    tc.Jobs = TheContractorJobs.new()
    tc.Farmers = TheContractorFarmers.new()
    world.farmers = tc.Farmers
    world:addRelationships()

    -- A job straight into the Jobs table (as a loaded one would be): def
    -- { id, farmId, jobType, fieldId, customerId, workshop, spill }.
    function world:addJob(def)
        local job = TheContractorJob.new(def.id, def.farmId or 1, def.jobType or "plow", def.fieldId or 0, 1, 1, 1, 1000)
        job.customerId = def.customerId
        job.workshop = def.workshop
        job.spill = def.spill
        tc.Jobs.jobsByFarm[job.farmId] = tc.Jobs.jobsByFarm[job.farmId] or {}
        tc.Jobs.jobsByFarm[job.farmId][job.id] = job
        return job
    end

    function world:holderId(farmlandId)
        local holder = self.farmers:getHolder(farmlandId)
        return holder ~= nil and holder.id or nil
    end
    return world
end

local function countHeld(farmers)
    local held = {}
    for _, farmer in ipairs(farmers:getFarmers()) do
        for _, farmlandId in ipairs(farmer.farmlandIds) do
            held[farmlandId] = (held[farmlandId] or 0) + 1
        end
    end
    return held
end

-- A plain copy of everyone, to compare after a round trip.
local function snapshot(farmers)
    local people = {}
    for id, person in pairs(farmers.people) do
        people[id] = {
            name = person.name, gender = person.gender, isOfficial = person.isOfficial,
            farmlands = table.concat(person.farmlandIds, ","), yard = person.yardFarmlandId,
            target = person.targetAcres, model = person.appearance ~= nil and person.appearance.model or nil,
        }
    end
    return people
end

local function assertSamePeople(expected, actual)
    local count = 0
    for id, person in pairs(expected) do
        count = count + 1
        local other = actual[id]
        assertTrue(other ~= nil, "person " .. id)
        for key, value in pairs(person) do
            if type(value) == "number" then
                assertNear(other[key], value, 0.001, key .. " of " .. id)
            else
                assertEquals(other[key], value, key .. " of " .. id)
            end
        end
    end
    for _ in pairs(actual) do
        count = count - 1
    end
    assertEquals(count, 0, "same number of people")
end

test("the first load makes farmers for every unowned field farmland, and the official", function()
    local world = setup()
    world.yards = { { farmlandId = 6, x = 300, z = 300 } }
    world.farmers:setUp()

    assertTrue(world.farmers:hasGenerated())
    local official = world.farmers:getOfficial()
    assertTrue(official.isOfficial)
    assertEquals(#official.farmlandIds, 0)
    assertTrue(official.name ~= nil)
    assertEquals(official.appearance.model, official.gender .. ".xml")

    -- 7 farmlands of 24.7 acres at 30 a farmer.
    local farmers = world.farmers:getFarmers()
    assertEquals(#farmers, 6)
    local held = countHeld(world.farmers)
    assertEquals(held[1], nil, "the player's farmland")
    for id = 2, 8 do
        assertEquals(held[id], 1, "farmland " .. id)
    end
    -- The yard started a farmer, who holds its farmland.
    assertEquals(world:holderId(6), world.farmers:getHolder(6).id)
    assertEquals(world.farmers:getHolder(6).yardFarmlandId, 6)

    -- Ids from their own counter, all different, and the split's seed kept.
    local ids = {}
    for _, person in pairs(world.farmers.people) do
        assertTrue(not ids[person.id])
        ids[person.id] = true
        assertTrue(person.id < world.farmers.nextId)
    end
    assertTrue(world.farmers.seed ~= nil)
    assertEquals(world.farmers.targetAcres, TheContractorFarmerSplit.TARGET_ACRES)

    -- Only once a load.
    local before = snapshot(world.farmers)
    world.farmers:setUp()
    assertSamePeople(before, snapshot(world.farmers))
end)

test("the people survive a save, a load and a client join", function()
    local world = setup()
    world.yards = { { farmlandId = 6, x = 300, z = 300 } }
    world.farmers:setUp()
    local before = snapshot(world.farmers)

    local xmlFile = {}
    world.farmers:saveToXmlFile(xmlFile)
    local loaded = TheContractorFarmers.new()
    loaded:loadFromXMLFile(xmlFile)
    assertSamePeople(before, snapshot(loaded))
    assertEquals(loaded.officialId, world.farmers.officialId)
    assertEquals(loaded.nextId, world.farmers.nextId)
    assertEquals(loaded.seed, world.farmers.seed)
    assertEquals(loaded:getOfficial().appearance.configs.face.color, 2)

    -- A loaded save isn't generated again: same people after setUp.
    g_currentMission.TheContractor.Farmers = loaded
    loaded:setUp()
    assertSamePeople(before, snapshot(loaded))

    local stream = world:newStream()
    world.farmers:writeInitialClientState(stream)
    local client = TheContractorFarmers.new()
    client:readInitialClientState(stream)
    assertSamePeople(before, snapshot(client))
    assertEquals(client.officialId, world.farmers.officialId)
    assertEquals(client.nextId, world.farmers.nextId)
end)

test("land a player buys leaves its farmer, who stays on the list", function()
    local world = setup()
    world.yards = { { farmlandId = 6, x = 300, z = 300 } }
    world.farmers:setUp()
    local farmer = world.farmers:getHolder(6)
    local farmerCount = #world.farmers:getFarmers()

    -- The player buys all of that farmer's land, yard and all.
    world.events = {}
    for _, farmlandId in ipairs(farmer.farmlandIds) do
        world.owners[farmlandId] = 1
    end
    world.farmers:onFarmlandOwnerChanged(6, 1, false)

    assertEquals(#farmer.farmlandIds, 0)
    assertEquals(farmer.yardFarmlandId, nil)
    assertEquals(#world.farmers:getFarmers(), farmerCount)
    assertTrue(world.farmers:getPerson(farmer.id) ~= nil)
    -- The clients hear about that farmer only.
    assertEquals(#world.events, 1)
    assertEquals(world.events[1].personId, farmer.id)
    assertEquals(#world.events[1].farmlandIds, 0)

    -- A savegame's own changes wait for setUp.
    world.owners[2] = 1
    world.farmers:onFarmlandOwnerChanged(2, 1, true)
    assertTrue(world:holderId(2) ~= nil)
end)

test("land a player sells goes to a nearby farmer, never a new one", function()
    local world = setup()
    world.farmers:setUp()
    local farmerCount = #world.farmers:getFarmers()
    local nextId = world.farmers.nextId

    world.owners[1] = nil
    world.farmers:onFarmlandOwnerChanged(1, 0, false)

    local holder = world.farmers:getHolder(1)
    assertTrue(holder ~= nil)
    assertEquals(#world.farmers:getFarmers(), farmerCount)
    assertEquals(world.farmers.nextId, nextId)
    assertEquals(world.events[#world.events].personId, holder.id)
    assertEquals(countHeld(world.farmers)[1], 1)
end)

test("sold land goes to the nearby farmer with the fewest acres for their target", function()
    setup()
    local land = {
        [1] = { id = 1, x = 0, z = 0, acres = 50 },
        [2] = { id = 2, x = 400, z = 0, acres = 20 },
        [3] = { id = 3, x = 5000, z = 0, acres = 1 },
        [4] = { id = 4, x = 200, z = 0, acres = 10 },
    }
    local near = { id = 1, farmlandIds = { 1 }, targetAcres = 40 }      -- 1.25 of target, 200 m
    local underNear = { id = 2, farmlandIds = { 2 }, targetAcres = 40 } -- 0.5 of target, 200 m
    local underFar = { id = 3, farmlandIds = { 3 }, targetAcres = 40 }  -- 0.025, 4.8 km
    local farmers = { near, underNear, underFar }

    assertEquals(TheContractorFarmers.chooseHolder(farmers, land[4], land, {}), underNear)
    -- Further than the margin beyond the nearest, the share doesn't count.
    land[2].x = 200 + 200 + TheContractorFarmers.NEAR_MARGIN + 50
    assertEquals(TheContractorFarmers.chooseHolder(farmers, land[4], land, {}), near)
    -- A farmer with no land counts from their yard.
    local yardOnly = { id = 4, farmlandIds = {}, yardFarmlandId = 9, targetAcres = 40 }
    table.insert(farmers, yardOnly)
    assertEquals(TheContractorFarmers.chooseHolder(farmers, land[4], land, { [9] = { x = 220, z = 0 } }), yardOnly)
    assertEquals(TheContractorFarmers.chooseHolder({}, land[4], land, {}), nil)
end)

test("at load, land nobody has finds a farmer and land that's gone is dropped", function()
    local world = setup()
    world.farmers:setUp()
    local xmlFile = {}
    world.farmers:saveToXmlFile(xmlFile)

    -- The save says a farmer holds farmland 9 (no fields now) and no one
    -- holds 8 (skipped while the player owned it).
    local holderOf8 = world.farmers:getHolder(8)
    local lost = {}
    for _, id in ipairs(holderOf8.farmlandIds) do
        if id ~= 8 then
            table.insert(lost, id)
        end
    end
    table.insert(lost, 9)
    for key, value in pairs(xmlFile) do
        if value == table.concat(holderOf8.farmlandIds, " ") then
            xmlFile[key] = table.concat(lost, " ")
        end
    end

    local loaded = TheContractorFarmers.new()
    loaded:loadFromXMLFile(xmlFile)
    assertTrue(loaded:getHolder(8) == nil)
    g_currentMission.TheContractor.Farmers = loaded
    loaded:setUp()

    local held = countHeld(loaded)
    assertEquals(held[9], nil)
    assertEquals(held[8], 1)
    for id = 2, 8 do
        assertEquals(held[id], 1, "farmland " .. id)
    end
end)

test("a job's customer: its field's farmer, the official, the original job's, or none", function()
    local world = setup()
    world.farmers:setUp()
    local farmers = world.farmers
    local officialId = farmers.officialId

    local fieldJob = world:addJob({ id = 1, fieldId = 5 })
    assertEquals(farmers:getCustomerIdForJob(fieldJob), world:holderId(5))
    -- The player's own land.
    assertEquals(farmers:getCustomerIdForJob(world:addJob({ id = 2, fieldId = 1 })), officialId)
    -- No field at all.
    assertEquals(farmers:getCustomerIdForJob(world:addJob({ id = 3, fieldId = 0 })), officialId)
    -- offField: the field only says where the job is.
    assertEquals(farmers:getCustomerIdForJob(world:addJob({ id = 4, jobType = "fallenTree", fieldId = 5 })),
        officialId)
    -- ADS repair contract.
    assertEquals(farmers:getCustomerIdForJob(world:addJob({ id = 5, fieldId = 5, workshop = {} })), nil)

    -- A spilt crop keeps its original job's customer, whoever holds the
    -- field now.
    fieldJob.customerId = 999
    local spill = world:addJob({ id = 6, jobType = "spillClearUp", fieldId = 5, spill = { sourceJobId = 1 } })
    assertEquals(farmers:getCustomerIdForJob(spill), 999)
    -- With its original job gone, the field decides.
    spill.spill.sourceJobId = 77
    assertEquals(farmers:getCustomerIdForJob(spill), world:holderId(5))

    -- Through the accessors.
    fieldJob.customerId = world:holderId(5)
    assertEquals(fieldJob:getCustomer(), farmers:getHolder(5))
    assertEquals(fieldJob:getCustomerName(), farmers:getHolder(5).name)
    assertEquals(world:addJob({ id = 7 }):getCustomer(), nil)
end)

test("a new job gets its customer as it's created", function()
    local world = setup()
    world.farmers:setUp()
    TCJobCreatedEvent = { new = function(job) return { kind = "jobCreated" } end }

    local job = g_currentMission.TheContractor.Jobs:createJob(1, "plow", 4, 1, 1, 1, 1000, true, nil, 10)
    assertEquals(job.customerId, world:holderId(4))
end)

test("older jobs are linked at load, and the customer survives the save and the stream", function()
    local world = setup()
    local tc = g_currentMission.TheContractor
    world:addJob({ id = 1, fieldId = 3 })
    world:addJob({ id = 2, fieldId = 1 })
    world:addJob({ id = 3, jobType = "fallenTree", fieldId = 3 })
    world:addJob({ id = 4, fieldId = 3, workshop = {} })
    world:addJob({ id = 5, jobType = "spillClearUp", fieldId = 3, spill = { sourceJobId = 1 } })
    world.farmers:setUp()
    local holder3 = world:holderId(3)

    local jobs = tc.Jobs.jobsByFarm[1]
    assertEquals(jobs[1].customerId, holder3)
    assertEquals(jobs[2].customerId, world.farmers.officialId)
    assertEquals(jobs[3].customerId, world.farmers.officialId)
    assertEquals(jobs[4].customerId, nil)
    assertEquals(jobs[5].customerId, holder3)

    -- A job whose customer is already set keeps them.
    jobs[2].customerId = holder3
    world.farmers:linkJobs(false)
    assertEquals(jobs[2].customerId, holder3)

    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, jobs[1])
    TheContractorJobs.writeJob(stream, jobs[4])
    assertEquals(TheContractorJobs.readJob(stream).customerId, holder3)
    assertEquals(TheContractorJobs.readJob(stream).customerId, nil)

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local loaded = TheContractorJobs.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getJob(1, 1).customerId, holder3)
    assertEquals(loaded:getJob(1, 4).customerId, nil)
end)

test("generating again makes new farmers, keeps the official and links every job again", function()
    local world = setup()
    world.farmers:setUp()
    local official = world.farmers:getOfficial()
    local oldIds = {}
    for _, farmer in ipairs(world.farmers:getFarmers()) do
        oldIds[farmer.id] = true
    end
    local job = world:addJob({ id = 1, fieldId = 5, customerId = world:holderId(5) })
    local treeJob = world:addJob({ id = 2, jobType = "fallenTree", fieldId = 5, customerId = official.id })
    -- 113: relationships with an old farmer and the official.
    local relationships = g_currentMission.TheContractor.Relationships
    local oldFarmerId = world:holderId(5)
    relationships:applyScore(1, oldFarmerId, 30)
    relationships:applyScore(1, official.id, -20)

    world.events = {}
    local links = world.farmers:regenerate(80)
    assertEquals(relationships:getScore(1, oldFarmerId), 0, "the old farmer's relationship goes")
    assertEquals(relationships:getScore(1, official.id), -20, "the official's stays")

    assertEquals(world.farmers:getOfficial(), official)
    for _, farmer in ipairs(world.farmers:getFarmers()) do
        assertTrue(not oldIds[farmer.id], "a new id")
    end
    assertEquals(world.farmers.targetAcres, 80)
    assertEquals(job.customerId, world:holderId(5))
    assertEquals(treeJob.customerId, official.id)
    -- Only the job whose customer changed, sent with everyone.
    assertEquals(#links, 1)
    assertEquals(links[1].jobId, 1)
    assertEquals(world.events[1].kind, "farmers")

    -- A client applies the new people and the links.
    local client = TheContractorFarmers.new()
    local stream = world:newStream()
    world.farmers:writeState(stream)
    local clientJob = TheContractorJob.new(1, 1, "plow", 5, 1, 1, 1, 1000)
    g_currentMission.TheContractor.Jobs.jobsByFarm[1][1] = clientJob
    client:applyState(TheContractorFarmers.readState(stream), links)
    assertSamePeople(snapshot(world.farmers), snapshot(client))
    assertEquals(clientJob.customerId, world:holderId(5))
end)

test("113: every farmer has a pay habit, saved but never streamed; older farmers get one at load", function()
    local world = setup()
    world.farmers:setUp()
    for _, farmer in ipairs(world.farmers:getFarmers()) do
        assertTrue(TheContractorFarmers.findPayHabit(farmer.payHabit) ~= nil, "a known habit")
    end
    assertEquals(world.farmers:getOfficial().payHabit, nil, "the official has none")
    assertEquals(world.farmers:getPayHabit(world.farmers.officialId).key, TheContractorFarmers.AVERAGE_PAY_HABIT)

    local farmer = world.farmers:getFarmers()[1]
    farmer.payHabit = "slow"
    local xmlFile = {}
    world.farmers:saveToXmlFile(xmlFile)
    local loaded = TheContractorFarmers.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getPayHabit(farmer.id).key, "slow")

    local stream = world:newStream()
    world.farmers:writeInitialClientState(stream)
    local client = TheContractorFarmers.new()
    client:readInitialClientState(stream)
    assertEquals(client:getPerson(farmer.id).payHabit, nil, "a client never learns it")

    -- A save from before 113.
    loaded:getPerson(farmer.id).payHabit = nil
    g_currentMission.TheContractor.Farmers = loaded
    loaded:setUp()
    assertTrue(TheContractorFarmers.findPayHabit(loaded:getPerson(farmer.id).payHabit) ~= nil)
end)

test("116, 121: a farmer's machines, their roles and what's been fitted survive a save; only some goes to a client", function()
    local world = setup()
    world.farmers:setUp()
    local farmer = world.farmers:getFarmers()[1]
    local other = world.farmers:getFarmers()[2]
    farmer.machines = {
        { id = 1, role = "combine", xmlFilename = "fendt.xml", seed = 1234, hours = 2400.5, hoursDay = 12,
            hoursPerMonth = 40, fitted = { battery = 12, airFilter = 30 } },
        { id = 2, role = "header", attachedTo = 1, xmlFilename = "deutz.xml", seed = 99, hoursPerMonth = 25,
            fitted = {} },
    }

    local xmlFile = {}
    world.farmers:saveToXmlFile(xmlFile)
    local loaded = TheContractorFarmers.new()
    loaded:loadFromXMLFile(xmlFile)
    local machines = loaded:getPerson(farmer.id).machines
    assertEquals(#machines, 2)
    assertEquals(machines[1].xmlFilename, "fendt.xml")
    assertEquals(machines[1].role, "combine")
    assertEquals(machines[1].attachedTo, nil)
    assertEquals(machines[2].role, "header")
    assertEquals(machines[2].attachedTo, 1)
    assertEquals(machines[1].seed, 1234)
    assertNear(machines[1].hours, 2400.5, 0.01)
    assertEquals(machines[1].hoursDay, 12)
    assertNear(machines[1].hoursPerMonth, 40, 0.01)
    assertEquals(machines[1].fitted.battery, 12)
    assertEquals(machines[1].fitted.airFilter, 30)
    assertEquals(machines[2].hours, nil, "not aged yet")
    assertEquals(loaded:getPerson(other.id).machines, nil, "nothing in this store to give them")

    -- 122: a client gets each machine's id, role, model and attachedTo, never
    -- its seed, age or parts.
    local stream = world:newStream()
    world.farmers:writeInitialClientState(stream)
    local client = TheContractorFarmers.new()
    client:readInitialClientState(stream)
    local streamed = client:getPerson(farmer.id).machines
    assertEquals(#streamed, 2)
    assertEquals(streamed[1].xmlFilename, "fendt.xml")
    assertEquals(streamed[2].role, "header")
    assertEquals(streamed[2].attachedTo, 1)
    assertEquals(streamed[1].seed, nil)
    assertEquals(streamed[1].hours, nil)
    assertEquals(streamed[1].fitted, nil)
    assertEquals(client:getPerson(other.id).machines, nil)
end)

test("116: a favour's customer is the farmer whose machine it is, while they're on the list", function()
    local world = setup()
    world.farmers:setUp()
    local farmer = world.farmers:getFarmers()[1]
    assertEquals(world.farmers:getCustomerIdForJob({ workshop = { farmerId = farmer.id } }), farmer.id)
    assertEquals(world.farmers:getCustomerIdForJob({ workshop = { farmerId = 999 } }), nil, "regenerated away")
    assertEquals(world.farmers:getCustomerIdForJob({ workshop = {} }), nil, "a repair contract")
end)

test("117: a declared yard leaves its field farmer and goes to the nearest farmer without a yard, however far", function()
    local world = setup()
    world.farmers:setUp()
    local fieldFarmer = world.farmers:getHolder(6)
    assertTrue(fieldFarmer ~= nil)

    -- Farmland 6 declared a yard: nobody farms it, and a farmer without a
    -- yard has it.
    world.yards = { { farmlandId = 6, x = 300, z = 300, how = "declared" } }
    world.farmers:reconcileLand()
    assertEquals(countHeld(world.farmers)[6], nil)
    local yardFarmer = nil
    for _, farmer in ipairs(world.farmers:getFarmers()) do
        if farmer.yardFarmlandId == 6 then
            yardFarmer = farmer
        end
    end
    assertTrue(yardFarmer ~= nil)

    -- Far from every field: a declared yard still finds a farmer, a
    -- detected one doesn't.
    table.insert(world.yards, { farmlandId = 9, x = 50000, z = 0 })
    world.farmers:reconcileLand()
    assertEquals(world.farmers:getHolder(9), nil)
    for _, farmer in ipairs(world.farmers:getFarmers()) do
        assertTrue(farmer.yardFarmlandId ~= 9)
    end
    world.yards[2].how = "declared"
    world.farmers:reconcileLand()
    local farOff = nil
    for _, farmer in ipairs(world.farmers:getFarmers()) do
        if farmer.yardFarmlandId == 9 then
            farOff = farmer
        end
    end
    assertTrue(farOff ~= nil)
    assertTrue(farOff ~= yardFarmer)

    -- Unset again: the yard's gone and its fields go back to a farmer.
    world.yards = {}
    world.farmers:reconcileLand()
    assertEquals(countHeld(world.farmers)[6], 1)
    for _, farmer in ipairs(world.farmers:getFarmers()) do
        assertEquals(farmer.yardFarmlandId, nil)
    end
end)

test("117: a declared yard goes to nobody when every farmer has a yard", function()
    setup()
    local land = { [1] = { id = 1, x = 0, z = 0, acres = 10 } }
    local farmers = {
        { id = 1, farmlandIds = { 1 }, yardFarmlandId = 4 },
        { id = 2, farmlandIds = {}, yardFarmlandId = 5 },
    }
    local yard = { farmlandId = 7, x = 10, z = 0, declared = true }
    assertEquals(TheContractorFarmers.chooseYardHolder(farmers, yard, land), nil)
    -- A farmer with no land and no yard takes it, though the nearest has one.
    table.insert(farmers, { id = 3, farmlandIds = {} })
    assertEquals(TheContractorFarmers.chooseYardHolder(farmers, yard, land), farmers[3])
end)

test("the yard markers: every farmer's yard with its farmer first, then the yards nobody holds", function()
    setup()
    local farmers = {
        { id = 3, name = "B", yardFarmlandId = 20 },
        { id = 2, name = "A", yardFarmlandId = 10 },
        -- No yard.
        { id = 4, name = "C" },
        -- Their yard was ruled out since.
        { id = 5, name = "D", yardFarmlandId = 99 },
    }
    local yards = {
        { farmlandId = 30, x = 3, z = 3, group = { yardBuildingCount = 7 } },
        { farmlandId = 20, x = 2, z = 2 },
        { farmlandId = 10, x = 1, z = 1 },
        -- No position: never marked.
        { farmlandId = 40 },
        { farmlandId = 15, x = 5, z = 5 },
    }
    local marks = TheContractorFarmers.getYardMarks(farmers, yards)
    assertEquals(4, #marks)
    assertEquals(10, marks[1].farmlandId)
    assertEquals(2, marks[1].farmer.id)
    assertEquals(20, marks[2].farmlandId)
    assertEquals(3, marks[2].farmer.id)
    assertEquals(15, marks[3].farmlandId)
    assertEquals(nil, marks[3].farmer)
    assertEquals(30, marks[4].farmlandId)
    assertEquals(3, marks[4].x)
    assertEquals(7, marks[4].buildings)
    assertEquals(0, marks[1].buildings)
end)
