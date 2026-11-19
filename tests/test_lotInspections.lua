-- 152: farmers asking for auction lots to be inspected. On the sale day,
-- with ADS treating lots as for sale and able to say what's been
-- inspected: 2 to 7 requests (never more than the open tractor lots ADS
-- looks after, or farmers to ask), shared round the company farms evenly,
-- each a different lot and farmer (never the official, the host or one
-- fallen out with the farm), once an auction. Done when every part of the
-- tractor's been inspected at standard depth or deeper since the offer
-- (the impact wrench's standard inspection, or a workshop's; never the
-- quick visual one, nor one zone on its own); ended at the lot's close
-- (an offer lapses, a job taken on is done or missed); a lot gone or the
-- auction called off ends it with nothing lost. Its lot goes to clients
-- and into the save (where ADS stood, the server's only), and a farmer's
-- retirement hands it on. The real Jobs, Job, JobGeneration, Allocation,
-- Auctions, TCADSUsedLots and TCLotInspections; ADS, the site and the rest
-- of the mod faked.

local SALE_FIELD = 12
local HOST_ID = 7
local OFFICIAL_ID = 8

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    FarmManager.SPECTATOR_FARM_ID = 0
    FSBaseMission.INGAME_NOTIFICATION_INFO = "info"
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    MessageType = { DAY_CHANGED = 1, HOUR_CHANGED = 2, FARMLAND_OWNER_CHANGED = 3 }
    g_messageCenter = { subscribe = function() end, unsubscribeAll = function() end }
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TCJobConsequences = {
        saveToXML = function() end,
        loadFromXML = function() end,
        writeReports = function() end,
        readReports = function() return {} end,
        getReportLines = function() return {} end,
        applyOnCompletion = function() end,
    }
    TCVehicleIds = { saveList = function() end, loadList = function() return {} end }
    getWorldTranslation = function(node) return node.x, 0, node.z end

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCAuctionCrowd.lua")
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCEquipmentClass.lua")
    world:load("src/business/Allocation.lua")
    world:load("src/util/TCAuctionAttendance.lua")
    world:load("src/util/TCADSUsedLots.lua")
    world:load("src/util/TCLotInspections.lua")
    world:load("src/business/EventDay.lua")
    world:load("src/business/Auctions.lua")
    world:load("src/events/TCJobCreatedEvent.lua")
    world:load("src/events/TCJobStateChangedEvent.lua")
    world:load("src/events/TCJobCompletedEvent.lua")
    world:load("src/events/TCJobMissedEvent.lua")
    world:load("src/events/TCJobRemovedEvent.lua")
    TCAuctionEvent = { new = function(auction) return { auction = auction } end }
    TheContractorAuctionSite = {
        CLOSE_HOURS = { 17, 18 },
        LOT_STATE = { OPEN = "open", CLOSED = "closed" },
        formatCloseTime = function(minute) return string.format("%02d:%02d", math.floor(minute / 60), minute % 60) end,
    }
    TheContractorFarmerFleet = {
        ROLE = { SMALL_TRACTOR = "smallTractor", MEDIUM_TRACTOR = "mediumTractor", LARGE_TRACTOR = "largeTractor" },
        getModelName = function(xml) return xml end,
    }
    TheContractorInbox = { getCustomerNamedArgs = function(message) return message.args end }
    TheContractorRelationships = { DECLINE_REASON = { LAPSED = "lapsed" } }

    g_currentMission.environment = {
        currentYear = 1, currentPeriod = 3, currentDayInPeriod = 5, daysPerPeriod = 10, plannedDaysPerPeriod = 10,
        currentMonotonicDay = 25, currentHour = 6, dayTime = 6 * 3600000,
        getPeriodFromDay = function() return 3 end,
        getDayInPeriodFromDay = function(_, day) return day - 20 end,
    }
    local field = { id = SALE_FIELD }
    function field:getId() return self.id end
    function field:getName() return tostring(self.id) end
    function field:getAreaHa() return 2 end
    g_fieldManager = { getFieldById = function(_, id) return id == SALE_FIELD and field or nil end }

    -- Every consequence a finished job could have, as it's asked for.
    world.consequences = {}
    local function record(name)
        return function() table.insert(world.consequences, name) end
    end
    local tc = g_currentMission.TheContractor
    tc.Jobs = TheContractorJobs.new()
    tc.Allocation = TheContractorAllocation.new()
    tc.Reputation = { addReputation = function(_, farmId, amount)
        table.insert(world.consequences, "reputation " .. amount)
    end }
    tc.Relationships = {
        onJobCompleted = record("relationship"),
        onJobMissed = record("relationship"),
        onJobDeclined = function(_, job, reason)
            table.insert(world.consequences, "declined " .. tostring(reason))
        end,
        -- Farm 2's fallen out with farmer 3.
        getOfferWeight = function(_, farmId, farmerId)
            return (farmId == 2 and farmerId == 3) and 0 or 1
        end,
    }
    tc.Logbook = { recordJobCompleted = record("logbook"), recordJobMissed = record("logbook"),
        onWorkStarted = function() end }
    tc.Finances = { invoiceJob = record("invoice") }
    tc.Claims = { rollForJob = record("claim") }
    tc.RandomEvents = { incidents = {}, onJobCompleted = record("jobEvent"),
        getCompanyFarmIds = function() return world.companyFarms end }
    tc.Staff = { applyGrowthFromJob = record("growth"), getWorker = function() return nil end }
    tc.Cooldown = { startCooldown = record("cooldown") }
    tc.Dispatch = { stopJob = function() end, takeRanOutOfFill = function() end,
        isJobActive = function() return false end }
    tc.Association = { getReputationBonus = function() return 0 end }
    tc.Settings = { getJobPayMultiplier = function() return world.payMultiplier or 1 end }
    world.messages = {}
    tc.Inbox = {
        messagesById = {},
        removeMessagesForJob = function() end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
            table.insert(world.messages, { farmId = farmId, kind = kind, bodyKey = bodyKey, args = args,
                payload = payload })
        end,
        registerMessageKind = function(_, kind, definition) world.messageKinds = { [kind] = definition } end,
    }
    -- Farmers 1 to 6, the host (7) and the official (8).
    world.farmers = {}
    for id = 1, 8 do
        table.insert(world.farmers, { id = id, name = "Farmer " .. id, isOfficial = id == OFFICIAL_ID })
    end
    tc.Farmers = {
        getFarmers = function() return world.farmers end,
        getCustomerIdForJob = function(_, job)
            return job.lotInspection ~= nil and job.lotInspection.farmerId or nil
        end,
        getPerson = function(_, id) return world.farmers[id] end,
    }
    TCJobProgress = { clearJob = function() end, POLL_INTERVAL_MS = 1000 }
    TCHaulage = { stopDelivery = function() end, emptyHarvestersAfterJob = function() end,
        startDelivery = function() end, resumeDelivery = function() end }
    TCJobSupplies = { topUp = function() end }
    AIMessageSuccessFinishedJob = { new = function() return {} end }
    AIMessageSuccessStoppedByUser = { new = function() return {} end }
    tc.Parking = { isPending = function() return false end, sendToShop = function() return {} end,
        returnVehicles = function() end, returnHiddenVehicles = function() end }
    TCFieldPreparation = { clearUpAfterJob = function() end, clearUpAtCompletion = function() end,
        prepareFieldForJob = function() end }
    TCFieldAccess = { refresh = function() end }
    TCJobAllocatedEvent = { new = function(job) return { job = job } end }
    world.companyFarms = { 1, 2 }

    -- The site: the server's lots, which every machine sees too.
    world.lots = {}
    tc.AuctionSite = {
        fieldId = SALE_FIELD,
        site = { fieldId = SALE_FIELD, lots = world.lots, isSpawning = false },
        getLot = function(_, number)
            for _, lot in ipairs(world.lots) do
                if lot.number == number then
                    return lot
                end
            end
            return nil
        end,
        getLotStateNow = function(_, lot) return lot.closed and "closed" or "open" end,
        isLot = function(_, vehicle)
            for _, lot in ipairs(world.lots) do
                if lot.vehicleId == vehicle.id then
                    return true
                end
            end
            return false
        end,
    }
    tc.AuctionSigns = { month = 0, signs = {} }

    tc.Auctions = TheContractorAuctions.new()
    tc.Auctions.event = {
        id = 4, fieldId = SALE_FIELD, hostFarmerId = HOST_ID, announcedDay = 1, signsDay = 1, day = 25,
        state = TheContractorAuctions.STATE.SET_OUT,
    }
    world.auction = tc.Auctions.event
    return world, tc
end

-- ADS: a seller registry, and the inspection coverage of each vehicle's
-- parts (vehicle.coverage[partId] = { entryId, level }), as ADS_Maintenance's
-- public functions give it.
local STANDARD, VISUAL, COMPLETE = 2, 1, 3
local function addADS(world, without)
    without = without or {}
    local registry = { sellers = {} }
    function registry.registerSeller(id, isListed)
        registry.sellers[id] = isListed
        return true
    end
    function registry.unregisterSeller(id) registry.sellers[id] = nil end
    local maintenance = {
        INSPECTION_LEVELS = { BREAKDOWNS = VISUAL, CONSUMABLES = STANDARD, COMPONENTS = COMPLETE },
        getInspectionZones = function(vehicle) return vehicle.zones or {} end,
        getConfirmedData = function(vehicle) return { coverage = vehicle.coverage or {} } end,
        getConfirmedComponentCoverage = function(report, partId) return report.coverage[partId] end,
    }
    for _, name in ipairs(without) do
        maintenance[name] = nil
    end
    world.adsEnv = { ADS_UsedVehicles = registry, ADS_Maintenance = maintenance,
        AdvancedDamageSystem = { reinitializeVehicle = function() return true end } }
    TheContractorDrivers = { getModEnv = function() return world.adsEnv end }
    TCADSUsedLots.detect()
end

-- A lot: a tractor ADS looks after (two zones, three parts) unless said.
local function addLot(world, number, def)
    def = def or {}
    local vehicle = world:addVehicle({ name = "Lot " .. number, farmId = 0 })
    vehicle.rootNode = { x = number * 10, z = 5 }
    if not def.noADS then
        vehicle.spec_AdvancedDamageSystem = {}
    end
    vehicle.zones = { { id = "engine", components = { { id = "engine" }, { id = "starter" } } },
        { id = "front", components = { { id = "radiator" } } } }
    vehicle.coverage = {}
    local lot = { number = number, role = def.role or "mediumTractor", xmlFilename = "tractor" .. number .. ".xml",
        vehicleId = vehicle.id, closeMinute = 17 * 60 + number }
    table.insert(world.lots, lot)
    return lot, vehicle
end

-- ADS records an inspection: every part named, at a depth, in a new record.
local function inspect(vehicle, entryId, level, parts)
    for _, partId in ipairs(parts or { "engine", "starter", "radiator" }) do
        vehicle.coverage[partId] = { entryId = entryId, level = level }
    end
end

local function inspectionJobs(tc, farmId)
    local found = {}
    for _, job in ipairs(tc.Jobs:getAllJobs(farmId)) do
        if job.lotInspection ~= nil then
            table.insert(found, job)
        end
    end
    return found
end

-- A random that walks a list, then repeats its last value.
local function sequence(values)
    local i = 0
    return function()
        i = math.min(i + 1, #values)
        return values[i]
    end
end

local function offerOne(world, tc, lotDef)
    world.companyFarms = { 1 }
    addADS(world)
    local lot, vehicle = addLot(world, 1, lotDef)
    local made = TCLotInspections.makeOffers(world.auction, 1, sequence({ 0 }))
    assertEquals(made, 1)
    return inspectionJobs(tc, 1)[1], lot, vehicle
end

local function accept(tc, job)
    assertTrue(tc.Jobs:transitionJobState(job.farmId, job.id, TheContractorJob.STATE.ACCEPTED))
end

-- Offered ------------------------------------------------------------------------------

test("requests are shared round the farms evenly", function()
    setup()
    local counts = {}
    for _, farmId in ipairs(TCLotInspections.shareRequests({ 1, 2, 3 }, 7, sequence({ 0.5 }))) do
        counts[farmId] = (counts[farmId] or 0) + 1
    end
    local sizes = { counts[1], counts[2], counts[3] }
    table.sort(sizes)
    assertEquals(table.concat(sizes, ","), "2,2,3")

    local few = TCLotInspections.shareRequests({ 1, 2, 3 }, 2, sequence({ 0.5 }))
    assertEquals(#few, 2)
    assertTrue(few[1] ~= few[2], "fewer requests than farms: one each, some none")
    assertEquals(#TCLotInspections.shareRequests({}, 3, math.random), 0)
end)

test("only open tractor lots ADS looks after are asked about, each once, by different farmers", function()
    local world, tc = setup()
    addADS(world)
    addLot(world, 1)
    addLot(world, 2, { role = "largeTractor" })
    addLot(world, 3, { role = "baler" })
    addLot(world, 4, { noADS = true })
    local closed = addLot(world, 5)
    closed.closed = true
    local sold = addLot(world, 6)
    sold.soldTo = 1

    local made = TCLotInspections.makeOffers(world.auction, 7, sequence({ 0 }))
    assertEquals(made, 2, "lots 1 and 2 only")
    local lotsAsked, farmersAsking = {}, {}
    for _, farmId in ipairs({ 1, 2 }) do
        for _, job in ipairs(inspectionJobs(tc, farmId)) do
            lotsAsked[job.lotInspection.lotNumber] = true
            assertTrue(farmersAsking[job.customerId] == nil, "a farmer asks once")
            farmersAsking[job.customerId] = true
            assertTrue(job.customerId ~= HOST_ID and job.customerId ~= OFFICIAL_ID)
        end
    end
    assertTrue(lotsAsked[1] and lotsAsked[2])
    assertEquals(#inspectionJobs(tc, 1), 1, "one each")
    assertEquals(#inspectionJobs(tc, 2), 1)
end)

test("an offer: the lot, the farmer, the fee, due by the lot's close, in the inbox", function()
    local world, tc = setup()
    world.payMultiplier = 1.5 * TheContractorJobGeneration.JOB_PAY_BASELINE
    local job, lot = offerOne(world, tc)
    assertEquals(job.jobType, "lotInspection")
    assertEquals(job.state, TheContractorJob.STATE.OFFERED)
    assertEquals(job.fieldId, SALE_FIELD)
    assertEquals(job.lotInspection.auctionId, 4)
    assertEquals(job.lotInspection.lotNumber, 1)
    assertEquals(job.lotInspection.closeMinute, lot.closeMinute)
    assertEquals(job.customerId, 1)
    -- The setting at 150%: the fee half as much again.
    assertEquals(job:getPrice(), math.floor(TCLotInspections.PRICE * 1.5 + 0.5), "the fee at the job pay rate")
    assertEquals(job.deadlineDay, 25)
    local message = world.messages[1]
    assertEquals(message.kind, TCLotInspections.MESSAGE_KIND)
    assertEquals(message.farmId, 1)
    assertEquals(message.payload.jobId, job.id)
    assertEquals(message.args[1], "1", "the lot number")
end)

test("a farmer fallen out with the farm never asks it", function()
    local world, tc = setup()
    world.companyFarms = { 2 }
    world.farmers = { world.farmers[3], world.farmers[HOST_ID], world.farmers[OFFICIAL_ID] }
    addADS(world)
    addLot(world, 1)
    assertEquals(TCLotInspections.makeOffers(world.auction, 1, sequence({ 0 })), 0)
end)

test("without ADS treating lots as for sale, or saying what's inspected, nobody asks", function()
    local world, tc = setup()
    addLot(world, 1)
    TheContractorDrivers = { getModEnv = function() return nil end }
    TCADSUsedLots.detect()
    assertEquals(TCLotInspections.makeOffers(world.auction, 3), nil)

    addADS(world, { "getConfirmedComponentCoverage" })
    assertTrue(TCADSUsedLots.isSellerRegistered())
    assertTrue(not TCADSUsedLots.canReadInspections())
    assertEquals(TCLotInspections.makeOffers(world.auction, 3), nil)
end)

test("on the sale day from 07:00, once an auction, and only once the lots are out", function()
    local world, tc = setup()
    addADS(world)
    addLot(world, 1)
    addLot(world, 2)
    TCLotInspections.onHour(world.auction, 25, 6)
    assertEquals(#world.messages, 0, "before 07:00")
    tc.AuctionSite.site.isSpawning = true
    TCLotInspections.onHour(world.auction, 25, 7)
    assertEquals(#world.messages, 0, "still setting out")
    assertTrue(not world.auction.inspectionsOffered)
    tc.AuctionSite.site.isSpawning = false
    TCLotInspections.onHour(world.auction, 25, 8)
    assertTrue(#world.messages >= 1)
    assertTrue(world.auction.inspectionsOffered)
    local count = #world.messages
    TCLotInspections.onHour(world.auction, 25, 9)
    assertEquals(#world.messages, count, "never twice")
end)

test("lots still coming out when a sleep passes 07:00: the farmers ask once the last is out", function()
    local world, tc = setup()
    addADS(world)
    addLot(world, 1)
    tc.AuctionSite.site.isSpawning = true
    TCLotInspections.onHour(world.auction, 25, 7)
    TCLotInspections.onHour(world.auction, 25, 8)
    assertEquals(#world.messages, 0)

    g_currentMission.environment.currentHour = 8
    tc.AuctionSite.site.isSpawning = false
    TCLotInspections.onLotsOut()
    assertEquals(#world.messages, 1, "without waiting for 09:00")

    -- Not before 07:00, nor once the lots are closing.
    local other = setup()
    addADS(other)
    addLot(other, 1)
    g_currentMission.environment.currentHour = 3
    TCLotInspections.onLotsOut()
    g_currentMission.environment.currentHour = 17
    TCLotInspections.onLotsOut()
    assertEquals(#other.messages, 0)
end)

-- Done --------------------------------------------------------------------------------

test("a standard inspection of every part since the offer does it; visual, partial or older ones don't", function()
    local world, tc = setup()
    addADS(world)
    local lot, vehicle = addLot(world, 1)
    inspect(vehicle, 3, STANDARD)
    world.companyFarms = { 1 }
    assertEquals(TCLotInspections.makeOffers(world.auction, 1, sequence({ 0 })), 1)
    local job = inspectionJobs(tc, 1)[1]
    assertEquals(job.lotInspection.inspectionMark, 3, "where ADS stood")
    assertEquals(TCLotInspections.getCompletion(job), 0, "one before the offer doesn't count")

    inspect(vehicle, 4, VISUAL)
    assertEquals(TCLotInspections.getCompletion(job), 0, "the quick visual one")
    inspect(vehicle, 5, STANDARD, { "engine", "starter" })
    assertEquals(TCLotInspections.getCompletion(job), 0, "one zone of two")
    inspect(vehicle, 5, STANDARD, { "radiator" })
    assertEquals(TCLotInspections.getCompletion(job), 1, "every zone, standard")
    inspect(vehicle, 6, COMPLETE)
    assertEquals(TCLotInspections.getCompletion(job), 1, "a complete one counts too")
end)

test("accepted, it's the player's; inspected, it's done and paid", function()
    local world, tc = setup()
    local job, _, vehicle = offerOne(world, tc)
    accept(tc, job)
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED, "allocated to the farm's players")
    inspect(vehicle, 1, STANDARD)
    job.completionPercentage = 100 * TCLotInspections.getCompletion(job)
    tc.Jobs:checkForCompletions()
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    local found = {}
    for _, name in ipairs(world.consequences) do
        found[name] = true
    end
    assertTrue(found.invoice and found.relationship, "paid, and the farmer's pleased")
end)

-- Ended --------------------------------------------------------------------------------

test("at the lot's close: an offer lapses, a job not done is missed, one done is done", function()
    local world, tc = setup()
    addADS(world)
    addLot(world, 1)
    addLot(world, 2)
    local _, vehicle3 = addLot(world, 3)
    world.companyFarms = { 1 }
    assertEquals(TCLotInspections.makeOffers(world.auction, 3, sequence({ 0 })), 3)
    local byLot = {}
    for _, job in ipairs(inspectionJobs(tc, 1)) do
        byLot[job.lotInspection.lotNumber] = job
    end
    accept(tc, byLot[2])
    accept(tc, byLot[3])
    inspect(vehicle3, 1, STANDARD)

    for number = 1, 3 do
        TCLotInspections.onLotClosed(4, number)
    end
    assertEquals(byLot[1].state, TheContractorJob.STATE.DECLINED)
    assertTrue(table.concat(world.consequences, ","):find("declined lapsed", 1, true) ~= nil)
    assertEquals(byLot[2].state, TheContractorJob.STATE.MISSED)
    assertEquals(byLot[3].state, TheContractorJob.STATE.COMPLETED, "done since the last poll counts")
end)

test("a lot gone or the auction called off ends it with nothing lost", function()
    local world, tc = setup()
    addADS(world)
    local _, vehicle1 = addLot(world, 1)
    addLot(world, 2)
    world.companyFarms = { 1 }
    TCLotInspections.makeOffers(world.auction, 2, sequence({ 0 }))
    local byLot = {}
    for _, job in ipairs(inspectionJobs(tc, 1)) do
        byLot[job.lotInspection.lotNumber] = job
    end
    accept(tc, byLot[1])
    world.consequences = {}
    vehicle1.isDeleted = true
    TCLotInspections.dropGoneLots(world.auction)
    assertEquals(byLot[1].state, TheContractorJob.STATE.MISSED)
    assertEquals(byLot[2].state, TheContractorJob.STATE.OFFERED, "its lot's still out")
    for _, name in ipairs(world.consequences) do
        local amount = tonumber(name:match("^reputation (%-?[%d%.]+)$") or "0")
        assertTrue(amount == 0 and name ~= "relationship", "nothing lost: " .. name)
    end

    -- The auction called off (Auctions:cancel).
    TCLotInspections.endAll(4)
    assertTrue(tc.Jobs:getJob(1, byLot[2].id) == nil, "the offer's taken away")
end)

test("it isn't a live job on the sale's field", function()
    local world, tc = setup()
    offerOne(world, tc)
    assertTrue(not tc.Jobs:hasLiveJob(SALE_FIELD))
end)

-- Clients, the save, retirements -------------------------------------------------------------

test("its lot goes to clients without where ADS stood, and into the save with it", function()
    local world, tc = setup()
    local job, _, vehicle = offerOne(world, tc)
    inspect(vehicle, 9, VISUAL)
    job.lotInspection.inspectionMark = 9

    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    local copy = TheContractorJobs.readJob(stream)
    assertEquals(copy.lotInspection.lotNumber, 1)
    assertEquals(copy.lotInspection.auctionId, 4)
    assertEquals(copy.lotInspection.farmerId, 1)
    assertEquals(copy.lotInspection.closeMinute, job.lotInspection.closeMinute)
    assertEquals(copy.lotInspection.inspectionMark, nil, "the server's only")

    local xmlFile = {}
    TCLotInspections.saveToXML(xmlFile, "job.lotInspection", job.lotInspection)
    local loaded = TCLotInspections.loadFromXML(xmlFile, "job.lotInspection")
    assertEquals(loaded.lotNumber, 1)
    assertEquals(loaded.inspectionMark, 9)
    assertEquals(loaded.xmlFilename, job.lotInspection.xmlFilename)
    assertEquals(TCLotInspections.loadFromXML(xmlFile, "job.nothing"), nil)
end)
