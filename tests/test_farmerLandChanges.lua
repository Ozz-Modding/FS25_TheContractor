-- 128: land changing hands between farmers. The field-sold pick (a farmer
-- with more than one farmland, never their yard's, the taker by 110's rule,
-- no sale when the rule gives it back), the sale itself (both holdings to
-- the clients, open jobs keeping their customer, the notice to every
-- company farm), the retirement setting's gate and the console, and the
-- retirement's hand-over (land, yard, fleet, half the relationship, jobs
-- and everything else holding the old id) on the server, a client and
-- through a save. The real FarmerLandChanges, Farmers, FarmerFleet,
-- Relationships, Settings, Job and Jobs; the map, the inbox and the random
-- events framework are faked.

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
        JOB_TYPES = { plow = {}, yardHaul = { offField = true } },
        getOperationSkill = function() return nil end,
    }
    TheContractorRandomEvents = { DONE = "done", WAIT = "wait" }
    Enterable = {}
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end

    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/business/FarmerSplit.lua")
    world:load("src/business/Farmers.lua")
    world:load("src/business/FarmerFleet.lua")
    world.texts.ui_on, world.texts.ui_off = "On", "Off"
    world:load("src/business/Settings.lua")
    world:load("src/business/FarmerLandChanges.lua")
    world:load("src/events/TCFarmerRetiredEvent.lua")

    world.nameCount = 0
    TheContractorStaff = {
        generateName = function(gender)
            world.nameCount = world.nameCount + 1
            return "Successor " .. world.nameCount
        end,
        guessGender = function() return "male" end,
    }
    TCWorkerAppearance.roll = function(gender)
        return { model = gender .. ".xml", configs = {} }
    end

    -- A 4 x 2 grid of farmlands 300 m apart, ids 1-8, each with one 10 ha
    -- field of the same id, except farmland 8, which has fields 8 and 9.
    world.owners = {}
    world.fields = {}
    local function addField(fieldId, farmlandId)
        local x, z = ((farmlandId - 1) % 4) * 300, math.floor((farmlandId - 1) / 4) * 300
        local farmland = { getId = function() return farmlandId end }
        world.fields[fieldId] = {
            getId = function() return fieldId end,
            getFarmland = function() return farmland end,
            getAreaHa = function() return fieldId == 9 and 0.01 or 10 end,
            getCenterOfFieldWorldPosition = function() return x, z end,
        }
    end
    for id = 1, 8 do
        addField(id, id)
    end
    addField(9, 8)
    g_fieldManager = {
        getFields = function()
            local list = {}
            for id = 1, 9 do
                table.insert(list, world.fields[id])
            end
            return list
        end,
        getFieldById = function(_, fieldId) return world.fields[fieldId] end,
    }
    g_farmlandManager = {
        getFarmlandOwner = function(_, farmlandId) return world.owners[farmlandId] or 0 end,
    }

    local tc = g_currentMission.TheContractor
    world.yards = { { farmlandId = 1, x = 0, z = 0 } }
    tc.Yards = {
        getYards = function()
            local list = {}
            for _, yard in ipairs(world.yards) do
                table.insert(list, { farmlandId = yard.farmlandId, x = yard.x, z = yard.z,
                    ownerFarmId = world.owners[yard.farmlandId] or 0, how = "detected" })
            end
            return list
        end,
    }

    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    TCFarmerLandEvent = {
        new = function(farmer)
            return { kind = "land", personId = farmer.id, farmlandIds = farmer.farmlandIds }
        end,
    }
    TCFarmerFleetEvent = { new = function(farmer) return { kind = "fleet", personId = farmer.id } end }

    tc.Company = { companyNames = { [1] = "One Ltd", [2] = "Two Ltd" } }
    tc.Settings = TheContractorSettings.new()

    -- The framework: definitions kept, two company farms, open incidents.
    world.definitions = {}
    tc.RandomEvents = {
        incidents = {},
        registerEventType = function(_, key, definition) world.definitions[key] = definition end,
        getCompanyFarmIds = function()
            local ids = {}
            for farmId in pairs(tc.Company.companyNames) do
                table.insert(ids, farmId)
            end
            table.sort(ids)
            return ids
        end,
    }
    world.posts = {}
    tc.Inbox = {
        messagesById = {},
        registerMessageKind = function(self, kind, definition) world.kinds = world.kinds or {}; world.kinds[kind] = definition end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
            table.insert(world.posts, { farmId = farmId, kind = kind, titleKey = titleKey, bodyKey = bodyKey,
                args = args, payload = payload })
        end,
    }
    tc.RepairContracts = { arrivals = {}, removals = {} }

    tc.Jobs = TheContractorJobs.new()
    world:addRelationships()

    -- The people: the official (#1); Ann (#2), farmlands 1-3 and her yard
    -- on 1; Bob (#3), farmland 4; Cat (#4), farmlands 5-8.
    local farmers = TheContractorFarmers.new()
    tc.Farmers = farmers
    local function addPerson(def)
        local person = { id = def.id, name = def.name, gender = "female", appearance = { model = "f.xml", configs = {} },
            isOfficial = def.isOfficial == true, farmlandIds = def.farmlandIds or {}, yardFarmlandId = def.yard,
            targetAcres = def.target or 0, payHabit = def.isOfficial and nil or "prompt", machines = def.machines }
        farmers.people[person.id] = person
        return person
    end
    addPerson({ id = 1, name = "Official", isOfficial = true })
    farmers.officialId = 1
    world.ann = addPerson({ id = 2, name = "Ann", farmlandIds = { 1, 2, 3 }, yard = 1, target = 50,
        machines = { { id = 1, role = "smallTractor", xmlFilename = "edited.xml", seed = 7, fitted = {} },
            { id = 2, role = "trailer", xmlFilename = "trailer.xml", seed = 8, fitted = {} } } })
    world.bob = addPerson({ id = 3, name = "Bob", farmlandIds = { 4 }, target = 50 })
    world.cat = addPerson({ id = 4, name = "Cat", farmlandIds = { 5, 6, 7, 8 }, target = 100 })
    farmers.nextId = 5
    farmers.isSetUp = true
    world.farmers = farmers
    -- No store in these tests: nobody's fleet grows.
    TheContractorFarmerFleet.ensureAll = function() return 0 end

    tc.FarmerLandChanges = TheContractorFarmerLandChanges.new()
    tc.FarmerLandChanges:register(tc.RandomEvents, tc.Inbox)
    world.changes = tc.FarmerLandChanges

    function world:addJob(def)
        local job = TheContractorJob.new(def.id, def.farmId or 1, def.jobType or "plow", def.fieldId or 0, 1, 1, 1, 1000)
        job.customerId = def.customerId
        job.yardHaul = def.yardHaul
        tc.Jobs.jobsByFarm[job.farmId] = tc.Jobs.jobsByFarm[job.farmId] or {}
        tc.Jobs.jobsByFarm[job.farmId][job.id] = job
        return job
    end
    return world
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

local function findSale(sales, sellerId, farmlandId)
    for _, sale in ipairs(sales) do
        if sale.sellerId == sellerId and sale.farmlandId == farmlandId then
            return sale
        end
    end
    return nil
end

-- A field sold -----------------------------------------------------------------

test("a sale is one of a farmer's several farmlands, never their yard's, to the taker by 110's rule", function()
    local world = setup()
    local land = TheContractorFarmers.getLand()
    local yards = TheContractorFarmers.getFreeYards()
    local sales = TheContractorFarmerLandChanges.findSales(world.farmers:getFarmers(), land, yards)

    -- Bob has one farmland: he never sells.
    for _, sale in ipairs(sales) do
        assertTrue(sale.sellerId ~= world.bob.id, "a farmer with one farmland")
        assertTrue(sale.farmlandId ~= 1, "Ann's yard's farmland")
    end
    -- Ann's farmland 3: everyone's 300 m off, Bob is furthest under target.
    assertEquals(findSale(sales, world.ann.id, 3).buyerId, world.bob.id)

    -- A farmland a player owns isn't the farmer's to sell, nor counted.
    world.owners[2] = 1
    sales = TheContractorFarmerLandChanges.findSales(world.farmers:getFarmers(), TheContractorFarmers.getLand(), yards)
    assertEquals(findSale(sales, world.ann.id, 2), nil)
    assertTrue(findSale(sales, world.ann.id, 3) ~= nil, "her yard's and 3 are still free")
    world.owners[3] = 1
    sales = TheContractorFarmerLandChanges.findSales(world.farmers:getFarmers(), TheContractorFarmers.getLand(), yards)
    assertEquals(findSale(sales, world.ann.id, 3), nil, "only her yard's farmland left free")
end)

test("no sale when 110's rule would give the farmland straight back, or nobody else is near", function()
    setup()
    local land = {
        [1] = { id = 1, x = 0, z = 0, acres = 10, ownerFarmId = 0 },
        [2] = { id = 2, x = 300, z = 0, acres = 10, ownerFarmId = 0 },
        [3] = { id = 3, x = 9000, z = 0, acres = 10, ownerFarmId = 0 },
    }
    -- Under her target with two farmlands; the only other farmer is far off.
    local seller = { id = 2, farmlandIds = { 1, 2 }, targetAcres = 100 }
    local far = { id = 3, farmlandIds = { 3 }, targetAcres = 100 }
    assertEquals(#TheContractorFarmerLandChanges.findSales({ seller, far }, land, {}), 0)
    -- Nobody else at all.
    assertEquals(#TheContractorFarmerLandChanges.findSales({ seller }, land, {}), 0)
    -- A near neighbour further under target takes one.
    far.farmlandIds = {}
    far.yardFarmlandId = 9
    assertTrue(#TheContractorFarmerLandChanges.findSales({ seller, far }, land, { [9] = { x = 400, z = 0 } }) > 0)
end)

test("a sale moves the farmland, tells the clients and every company farm; open jobs keep their customer", function()
    local world = setup()
    local tc = g_currentMission.TheContractor
    local openJob = world:addJob({ id = 1, fieldId = 3, customerId = world.ann.id })
    tc.Relationships:applyScore(1, world.ann.id, 20)

    local definition = world.definitions[TheContractorFarmerLandChanges.FIELD_SOLD_EVENT]
    assertEquals(definition.console.prepareTrigger(1, { "bereavement", "Ann" }), nil)
    local data = definition.canTrigger(1)
    definition.console.clearTrigger()
    assertEquals(data.sellerId, world.ann.id)
    assertEquals(data.reason, "bereavement")
    assertTrue(data.farmlandId == 2 or data.farmlandId == 3)
    data.farmlandId = 3
    data.buyerId = world.bob.id

    world.events = {}
    assertEquals(definition.stages[1].run({ id = 1, farmId = 1, data = data }), "done")
    assertTrue(not contains(world.ann.farmlandIds, 3))
    assertTrue(contains(world.bob.farmlandIds, 3))
    assertEquals(world.ann.yardFarmlandId, 1, "her yard stays with her")
    assertEquals(#world.events, 2)
    assertEquals(world.events[1].personId, world.ann.id)
    assertEquals(world.events[2].personId, world.bob.id)

    -- Every company farm's told, naming both and the field.
    assertEquals(#world.posts, 2)
    for i, post in ipairs(world.posts) do
        assertEquals(post.farmId, i)
        assertEquals(post.kind, TheContractorFarmerLandChanges.FIELD_SOLD_KIND)
        assertEquals(post.bodyKey, "tc_fieldSold_body_bereavement")
        assertEquals(post.args[1], "Ann")
        assertEquals(post.args[2], "Bob")
        assertEquals(post.payload.farmlandId, 3)
        assertEquals(post.payload.fieldId, 3)
    end

    -- The open job's still Ann's, through a re-link; the next one's Bob's.
    tc.Farmers:linkJobs(false)
    assertEquals(openJob.customerId, world.ann.id)
    assertEquals(tc.Farmers:getCustomerIdForJob(world:addJob({ id = 2, fieldId = 3 })), world.bob.id)
    -- The relationship stays with the person.
    assertEquals(tc.Relationships:getScore(1, world.ann.id), 20)
    assertEquals(tc.Relationships:getScore(1, world.bob.id), 0)
end)

test("a notice names the farmland when it has several fields", function()
    assertEquals(TheContractorFarmerLandChanges.getOnlyFieldId(8), nil)
    assertEquals(TheContractorFarmerLandChanges.getOnlyFieldId(5), 5)
end)

-- Retirements --------------------------------------------------------------------

test("retirements: never with the setting off, unless the console asks; never the official", function()
    local world = setup()
    local tc = g_currentMission.TheContractor
    local definition = world.definitions[TheContractorFarmerLandChanges.RETIREMENT_EVENT]

    -- Off by default: no odds, and nothing to act on.
    assertEquals(definition.ratePerPeriod(1), 0)
    assertEquals(definition.canTrigger(1), nil)

    -- The console works either way, and only for that trigger.
    assertEquals(definition.console.prepareTrigger(1, { "Cat" }), nil)
    assertEquals(definition.canTrigger(1).farmerId, world.cat.id)
    definition.console.clearTrigger()
    assertEquals(definition.canTrigger(1), nil)
    assertTrue(definition.console.prepareTrigger(1, { "Official" }) ~= nil, "the official can't be named")
    assertEquals(definition.canTrigger(1), nil, "and that leaves nothing forced")

    tc.Settings.values.farmerRetirements = true
    assertTrue(definition.ratePerPeriod(1) > 0)
    for _ = 1, 50 do
        assertTrue(definition.canTrigger(1).farmerId ~= tc.Farmers.officialId)
    end

    -- Shared out between the company farms, so the map's odds stay the same.
    local twoFarms = definition.ratePerPeriod(1)
    tc.Company.companyNames[2] = nil
    assertNear(definition.ratePerPeriod(1), twoFarms * 2, 0.0001)
end)

test("a retirement hands everything to a new person at half the relationship", function()
    local world = setup()
    local tc = g_currentMission.TheContractor
    local ann = world.ann
    local land, yard, target, machines = ann.farmlandIds, ann.yardFarmlandId, ann.targetAcres, ann.machines

    tc.Relationships:applyScore(1, ann.id, 31)
    tc.Relationships:applyScore(2, ann.id, -31)
    tc.Relationships:applyScore(3, ann.id, 1)
    tc.Relationships:applyScore(1, world.bob.id, 40)
    local openJob = world:addJob({ id = 1, jobType = "yardHaul", customerId = ann.id,
        yardHaul = { farmerId = ann.id, fillTypeName = "WHEAT" } })
    local bobJob = world:addJob({ id = 2, fieldId = 4, customerId = world.bob.id })
    tc.RandomEvents.incidents[7] = { id = 7, data = { farmerId = ann.id } }
    tc.Inbox.messagesById[3] = { id = 3, payload = { farmerId = ann.id } }
    table.insert(tc.RepairContracts.arrivals, { farmerId = ann.id, machineId = 1 })
    table.insert(tc.RepairContracts.removals, { farmerId = world.cat.id, machineId = 1 })

    -- A client holding the same before the retirement.
    local stream = world:newStream()
    tc.Farmers:writeInitialClientState(stream)
    tc.Relationships:writeInitialClientState(stream)
    TheContractorJobs.writeJob(stream, openJob)
    local clientFarmers = TheContractorFarmers.new()
    clientFarmers:readInitialClientState(stream)
    local clientRelationships = TheContractorRelationships.new()
    clientRelationships:readInitialClientState(stream)
    local clientJobs = TheContractorJobs.new()
    local clientJob = TheContractorJobs.readJob(stream)
    clientJobs.jobsByFarm[1] = { [clientJob.id] = clientJob }

    local definition = world.definitions[TheContractorFarmerLandChanges.RETIREMENT_EVENT]
    world.events = {}
    assertEquals(definition.stages[1].run({ id = 9, farmId = 1, data = { farmerId = ann.id } }), "done")

    local successor = tc.Farmers:getPerson(5)
    assertEquals(tc.Farmers:getPerson(ann.id), nil, "gone from the People tab")
    assertEquals(successor.name, "Successor 1")
    assertEquals(tc.Farmers.nextId, 6)
    assertEquals(successor.farmlandIds, land)
    assertEquals(successor.yardFarmlandId, yard)
    assertEquals(successor.targetAcres, target)
    assertEquals(successor.machines, machines, "the same records, edits and all")
    assertEquals(successor.machines[1].id, 1)
    assertEquals(successor.machines[1].xmlFilename, "edited.xml")
    assertTrue(TheContractorFarmers.findPayHabit(successor.payHabit) ~= nil)
    assertEquals(tc.Farmers:getHolder(2), successor)

    -- Half, rounded towards 0; the old scores dropped; others untouched.
    assertEquals(tc.Relationships:getScore(1, successor.id), 15)
    assertEquals(tc.Relationships:getScore(2, successor.id), -15)
    assertEquals(tc.Relationships:getScore(3, successor.id), 0)
    assertEquals(tc.Relationships.scores[1][ann.id], nil)
    assertEquals(tc.Relationships.scores[3][ann.id], nil)
    assertEquals(tc.Relationships:getScore(1, world.bob.id), 40)

    -- Everything holding her id holds the successor's.
    assertEquals(openJob.customerId, successor.id)
    assertEquals(openJob.yardHaul.farmerId, successor.id)
    assertEquals(bobJob.customerId, world.bob.id)
    assertEquals(tc.RandomEvents.incidents[7].data.farmerId, successor.id)
    assertEquals(tc.Inbox.messagesById[3].payload.farmerId, successor.id)
    assertEquals(tc.RepairContracts.arrivals[1].farmerId, successor.id)
    assertEquals(tc.RepairContracts.removals[1].farmerId, world.cat.id)

    -- Every company farm's told, naming both.
    assertEquals(#world.posts, 2)
    for _, post in ipairs(world.posts) do
        assertEquals(post.kind, TheContractorFarmerLandChanges.RETIREMENT_KIND)
        assertEquals(post.bodyKey, "tc_farmerRetirement_body")
        assertEquals(post.args[1], "Ann")
        assertEquals(post.args[2], "Successor 1")
    end

    -- The client gets one event and comes out the same.
    local event = nil
    for _, sent in ipairs(world.events) do
        if getmetatable(sent) ~= nil and sent.successor ~= nil then
            event = sent
        end
    end
    assertTrue(event ~= nil, "a TCFarmerRetiredEvent")
    tc.Farmers, tc.Relationships, tc.Jobs = clientFarmers, clientRelationships, clientJobs
    tc.RandomEvents.incidents = {}
    tc.Inbox.messagesById = {}
    tc.RepairContracts = nil
    local eventStream = world:newStream()
    event:writeStream(eventStream)
    local received = TCFarmerRetiredEvent.emptyNew()
    received:readStream(eventStream, { getIsServer = function() return true end })

    assertEquals(clientFarmers:getPerson(ann.id), nil)
    local clientSuccessor = clientFarmers:getPerson(successor.id)
    assertEquals(clientSuccessor.name, "Successor 1")
    assertEquals(table.concat(clientSuccessor.farmlandIds, ","), "1,2,3")
    assertEquals(clientSuccessor.yardFarmlandId, 1)
    assertEquals(#clientSuccessor.machines, 2)
    assertEquals(clientSuccessor.machines[1].xmlFilename, "edited.xml")
    assertEquals(clientSuccessor.payHabit, nil, "never streamed")
    assertEquals(clientFarmers.nextId, 6)
    assertEquals(clientRelationships:getScore(1, successor.id), 15)
    assertEquals(clientRelationships:getScore(2, successor.id), -15)
    assertEquals(clientJob.customerId, successor.id)
    assertEquals(clientJob.yardHaul.farmerId, successor.id)
end)

test("after a retirement the successor and their jobs survive a save; ids are never reused", function()
    local world = setup()
    local tc = g_currentMission.TheContractor
    local job = world:addJob({ id = 1, fieldId = 2, customerId = world.ann.id })
    tc.Relationships:applyScore(1, world.ann.id, 50)
    local successor = tc.Farmers:retireFarmer(world.ann.id)

    local xmlFile = {}
    tc.Farmers:saveToXmlFile(xmlFile)
    tc.Relationships:saveToXmlFile(xmlFile)
    tc.Jobs:saveToXmlFile(xmlFile)
    local farmers = TheContractorFarmers.new()
    farmers:loadFromXMLFile(xmlFile)
    local relationships = TheContractorRelationships.new()
    relationships:loadFromXMLFile(xmlFile)
    local jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)

    assertEquals(farmers:getPerson(world.ann.id), nil)
    assertEquals(farmers:getPerson(successor.id).name, successor.name)
    assertEquals(table.concat(farmers:getPerson(successor.id).farmlandIds, ","), "1,2,3")
    assertEquals(farmers:getPerson(successor.id).machines[1].xmlFilename, "edited.xml")
    assertEquals(relationships:getScore(1, successor.id), 25)
    assertEquals(jobs:getJob(1, job.id).customerId, successor.id)
    assertEquals(farmers.nextId, successor.id + 1)

    -- A second retirement takes a new id, not the old one back.
    g_currentMission.TheContractor.Farmers = farmers
    assertEquals(farmers:retireFarmer(successor.id).id, successor.id + 1)
    assertEquals(farmers:retireFarmer(farmers.officialId), nil, "never the official")
end)
