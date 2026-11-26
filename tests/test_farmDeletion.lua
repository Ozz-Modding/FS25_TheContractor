-- A farm deleted in multiplayer (TCFarmDeletion): everything kept for it
-- goes on every machine, everything for other farms stays, and the server
-- tells the clients once it's done.

-- Each subsystem with just its own farm-scoped state, built round the real
-- class (its forgetFarm is what's tested).
local function make(className, state)
    return setmetatable(state, _G[className .. "_mt"])
end

-- The real modules whose forgetFarm is tested (Job for Jobs).
local SUBSYSTEM_FILES = {
    "Company", "Reputation", "Advertising", "JobGeneration", "Job", "Jobs", "Staff", "Cooldown", "Drivers",
    "Notices", "Holidays", "Finances", "Inbox", "Overheads", "Claims", "Office", "Logbook",
    "MachineryInsurance", "GoodNews", "Parking", "RandomEvents", "Relationships", "RepairContracts",
    "Dispatch", "Watchdog", "AuctionSale", "EventDay", "Show", "ShowLivestock", "PloughingMatch",
    "ShowWorker", "ShowStands", "ShowDayOff",
}

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    FarmManager = { SPECTATOR_FARM_ID = 0 }
    g_messageCenter = { subscribe = function() end, unsubscribeAll = function() end }
    -- What the modules reach for as they're loaded.
    TCEquipmentVisibility = {}
    TCJobProgress = { POLL_INTERVAL_MS = 3000 }
    Environment = { tcHolidayHookInstalled = true }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end

    -- 167's class keys, as ShowLivestock loads; 169's plot states.
    world:load("src/util/TCShowClasses.lua")
    world:load("src/util/TCPloughMatch.lua")
    world:load("src/util/TCShowWorker.lua")
    world:load("src/util/TCShowStands.lua")
    world:load("src/util/TCShowDayOff.lua")
    for _, name in ipairs(SUBSYSTEM_FILES) do
        world:load("src/business/" .. name .. ".lua")
    end
    world:load("src/util/TCFarmDeletion.lua")
    world:load("src/events/TCFarmDeletedEvent.lua")

    world.cleared = { progress = {}, deliveries = {}, fields = {} }
    TCJobProgress = { clearJob = function(jobId) table.insert(world.cleared.progress, jobId) end }
    TCHaulage = { stopDelivery = function(job) table.insert(world.cleared.deliveries, job.id) end }
    TCFieldPreparation = { clearUpAfterJob = function(job) table.insert(world.cleared.fields, job.id) end }
    TheContractorRepairContracts.clearCache = function() end

    local function aiJob(name)
        return { name = name }
    end
    world.aiJobs = { a = aiJob("a"), b = aiJob("b") }

    local tc = {
        Company = make("TheContractorCompany", { companyNames = { [1] = "Old Co", [2] = "Other Co" } }),
        Reputation = make("TheContractorReputation", { scores = { [1] = 40, [2] = 10 } }),
        Advertising = make("TheContractorAdvertising", {
            campaigns = { [1] = { localNewspaper = 20 }, [2] = { localNewspaper = 30 } },
        }),
        JobGeneration = make("TheContractorJobGeneration", { lastOfferDayByFarm = { [1] = 5, [2] = 6 } }),
        Jobs = make("TheContractorJobs", {
            jobsByFarm = {
                [1] = { [11] = { id = 11, farmId = 1 }, [12] = { id = 12, farmId = 1 } },
                [2] = { [21] = { id = 21, farmId = 2 } },
            },
            graceJobs = { [12] = true, [21] = true },
        }),
        -- 171: a candidate kept for each farm by the show's careers stand,
        -- and one any farm can hire.
        Staff = make("TheContractorStaff", { workersByFarm = { [1] = { [1] = {} }, [2] = { [2] = {} } },
            candidatePool = { [31] = { id = 31, keptForFarmId = 1, keptUntilDay = 9 },
                [32] = { id = 32, keptForFarmId = 2, keptUntilDay = 9 }, [33] = { id = 33 } } }),
        Cooldown = make("TheContractorCooldown", {
            entriesByFarm = { [1] = { [1] = { vehicleIds = { 101, 102 } } }, [2] = { [2] = { vehicleIds = { 201 } } } },
            vehicleIdsInCooldown = { [101] = true, [102] = true, [201] = true },
        }),
        Drivers = make("TheContractorDrivers", {
            bindingsByVehicleId = { [103] = { farmId = 1 }, [203] = { farmId = 2 } },
        }),
        Notices = make("TheContractorNotices", { noticesById = { [1] = { farmId = 1 }, [2] = { farmId = 2 } } }),
        Holidays = make("TheContractorHolidays", { noticeIdsByFarm = { [1] = { 1 }, [2] = { 2 } } }),
        Finances = make("TheContractorFinances", {
            invoicesById = { [1] = { farmId = 1 }, [2] = { farmId = 2 } },
            yearStatsByFarm = { [1] = {}, [2] = {} },
        }),
        Inbox = make("TheContractorInbox", { messagesById = { [1] = { farmId = 1 }, [2] = { farmId = 2 } } }),
        Overheads = make("TheContractorOverheads", { statesByFarm = { [1] = {}, [2] = {} } }),
        Claims = make("TheContractorClaims", {
            historyByFarm = { [1] = {}, [2] = {} },
            pendingClaims = { { farmId = 1 }, { farmId = 2 } },
        }),
        Office = make("TheContractorOffice", { membersByFarm = { [1] = {}, [2] = {} } }),
        Logbook = make("TheContractorLogbook", {
            jobEntriesByFarm = { [1] = {}, [2] = {} },
            pendingByJobId = { [11] = {}, [21] = {} },
            driverSessions = { [103] = { farmId = 1 }, [203] = { farmId = 2 } },
            playerSessions = { [104] = { farmId = 1 }, [204] = { farmId = 2 } },
        }),
        MachineryInsurance = make("TheContractorMachineryInsurance", { historyByFarm = { [1] = {}, [2] = {} } }),
        GoodNews = make("TheContractorGoodNews", { lastStoryByFarm = { [1] = "a", [2] = "b" } }),
        Parking = make("TheContractorParking", {
            queue = { { vehicleId = 105, farmId = 1, batchId = 1 }, { vehicleId = 205, farmId = 2, batchId = 2 } },
            entryByVehicleId = { [105] = {}, [205] = {} },
            parkedByBatch = { [1] = { farmId = 1 }, [2] = { farmId = 2 } },
            messageIdByBatch = { [1] = 7, [2] = 8 },
            noticeByFarm = { [1] = {}, [2] = {} },
            parkAllByFarm = { [1] = {}, [2] = {} },
        }),
        RandomEvents = make("TheContractorRandomEvents", {
            incidents = { [1] = { farmId = 1 }, [2] = { farmId = 2 } },
            lastPeriodByFarm = { [1] = {}, [2] = {} },
            pendingTriggers = { { farmId = 1 }, { farmId = 2 } },
        }),
        Relationships = make("TheContractorRelationships", {
            scores = { [1] = {}, [2] = {} },
            lastComplaints = { [1] = {}, [2] = {} },
        }),
        RepairContracts = make("TheContractorRepairContracts", {
            arrivals = { { farmId = 1 }, { farmId = 2 } },
            removals = { { farmId = 1 }, { farmId = 2 } },
            pendingClaims = { { farmId = 1 }, { farmId = 2 } },
            pendingDiscoveries = { { farmId = 1 }, { farmId = 2 } },
            overcharged = { [1] = {}, [2] = {} },
        }),
        Dispatch = make("TheContractorDispatch", {
            pendingByJobId = { [11] = {}, [21] = {} },
            aiJobByOurJobId = { [12] = world.aiJobs.a, [21] = world.aiJobs.b },
            ourJobIdByAIJob = { [world.aiJobs.a] = 12, [world.aiJobs.b] = 21 },
            ourJobIdByAISystemJobId = { [1] = 12, [2] = 21 },
            ranOutOfFillJobIds = { [11] = true, [21] = true },
            serviceClearedAtByJobId = { [11] = 5, [21] = 5 },
        }),
        Watchdog = make("TheContractorWatchdog", { trackedByJobId = { [11] = {}, [21] = {} } }),
        -- 139: bids on lots, by lot then farm.
        AuctionSale = make("TheContractorAuctionSale", { bids = { [4] = { [1] = { amount = 100 }, [2] = { amount = 90 } },
            [5] = { [1] = { amount = 50 } } } }),
        -- 165: the show's results, by placing.
        Show = make("TheContractorShow", { results = { showId = 1, day = 10, placings = {
            { placing = 1, farmId = 1, farmerId = 0 }, { placing = 2, farmId = 0, farmerId = 7 },
            { placing = 3, farmId = 2, farmerId = 0 } } } }),
        -- 167: the show's livestock entries, by farm.
        ShowLivestock = make("TheContractorShowLivestock", { entries = {
            { id = 1, farmId = 1, classKey = "herd" }, { id = 2, farmId = 2, classKey = "herd" } } }),
        -- 169: the ploughing plots and each farm's best.
        PloughingMatch = make("TheContractorPloughingMatch", { over = false, runs = {}, plots = {
            { number = 1, state = "taken", farmId = 1, farmerId = 0, workerId = 3 },
            { number = 2, state = "taken", farmId = 2, farmerId = 0 } },
            best = { [1] = { bestScore = 80, wins = 1, matches = 1 }, [2] = { bestScore = 70, wins = 0, matches = 1 } } }),
        -- 170: the workers entered in the ploughing, by farm.
        ShowWorker = make("TheContractorShowWorker", { showId = 1, entries = {
            { farmId = 1, workerId = 3, name = "Amy" }, { farmId = 2, workerId = 4, name = "Ben" } } }),
        -- 171: each farm's visit to the show's stands.
        ShowStands = make("TheContractorShowStands", { showId = 1, visits = {
            [1] = { attended = true, joined = false, careers = true, talked = { [7] = true }, asked = {} },
            [2] = { attended = true, joined = true, careers = false, talked = {}, asked = { [8] = true } } } }),
        -- 172: each farm's answer about the show's staff day off.
        ShowDayOff = make("TheContractorShowDayOff", { showId = 1, answers = { [1] = 2, [2] = 3 } }),
    }
    g_currentMission.TheContractor = tc
    return world, tc
end

local function count(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

test("every subsystem in the list can forget a farm", function()
    local _, tc = setup()
    for _, key in ipairs(TCFarmDeletion.SUBSYSTEMS) do
        assertTrue(tc[key] ~= nil and tc[key].forgetFarm ~= nil, key .. " has forgetFarm")
    end
end)

test("the deleted farm's state goes and the other farm's stays", function()
    local world, tc = setup()
    TCFarmDeletion.forgetFarm(1)

    assertEquals(tc.Company.companyNames[1], nil, "company")
    assertEquals(tc.Company.companyNames[2], "Other Co", "other company")
    assertEquals(tc.Reputation.scores[1], nil, "reputation")
    assertEquals(tc.Reputation.scores[2], 10, "other reputation")
    assertEquals(tc.Advertising.campaigns[1], nil, "advert")
    assertEquals(tc.Advertising.campaigns[2].localNewspaper, 30, "other advert")
    assertEquals(tc.JobGeneration.lastOfferDayByFarm[1], nil, "offer day")

    assertEquals(tc.Jobs.jobsByFarm[1], nil, "jobs")
    assertTrue(tc.Jobs.jobsByFarm[2][21] ~= nil, "other jobs")
    assertEquals(tc.Jobs.graceJobs[12], nil, "grace")
    assertEquals(tc.Jobs.graceJobs[21], true, "other grace")
    assertEquals(#world.cleared.progress, 2, "both jobs' progress scans dropped")

    assertEquals(tc.Staff.workersByFarm[1], nil, "staff")
    assertTrue(tc.Staff.workersByFarm[2] ~= nil, "other staff")
    assertEquals(tc.Cooldown.entriesByFarm[1], nil, "cooldowns")
    assertEquals(tc.Cooldown.vehicleIdsInCooldown[101], nil, "cooldown vehicles")
    assertEquals(tc.Cooldown.vehicleIdsInCooldown[201], true, "other cooldown vehicles")
    assertEquals(tc.Drivers.bindingsByVehicleId[103], nil, "driver")
    assertTrue(tc.Drivers.bindingsByVehicleId[203] ~= nil, "other driver")

    assertEquals(count(tc.Notices.noticesById), 1, "notices")
    assertEquals(tc.Holidays.noticeIdsByFarm[1], nil, "holiday notices")
    assertEquals(count(tc.Finances.invoicesById), 1, "invoices")
    assertEquals(tc.Finances.invoicesById[2].farmId, 2, "the other farm's invoice kept")
    assertEquals(tc.Finances.yearStatsByFarm[1], nil, "year stats")
    assertEquals(count(tc.Inbox.messagesById), 1, "messages")
    assertEquals(tc.Overheads.statesByFarm[1], nil, "policies")
    assertEquals(tc.Claims.historyByFarm[1], nil, "claim history")
    assertEquals(#tc.Claims.pendingClaims, 1, "pending claims")
    assertEquals(tc.Office.membersByFarm[1], nil, "office")

    assertEquals(tc.Logbook.jobEntriesByFarm[1], nil, "logbook")
    assertTrue(tc.Logbook.jobEntriesByFarm[2] ~= nil, "other logbook")
    assertEquals(tc.Logbook.pendingByJobId[11], nil, "logbook pending")
    assertTrue(tc.Logbook.pendingByJobId[21] ~= nil, "other logbook pending")
    assertEquals(tc.Logbook.driverSessions[103], nil, "driver session")
    assertEquals(tc.Logbook.playerSessions[104], nil, "player session")
    assertTrue(tc.Logbook.playerSessions[204] ~= nil, "other player session")

    assertEquals(tc.MachineryInsurance.historyByFarm[1], nil, "insurance history")
    assertEquals(tc.GoodNews.lastStoryByFarm[1], nil, "good news")
    assertEquals(#tc.Parking.queue, 1, "parking queue")
    assertEquals(tc.Parking.queue[1].farmId, 2, "other parking kept")
    assertEquals(tc.Parking.entryByVehicleId[105], nil, "parking lookup")
    assertEquals(tc.Parking.parkedByBatch[1], nil, "parked batch")
    assertEquals(tc.Parking.messageIdByBatch[1], nil, "batch message")
    assertEquals(tc.Parking.messageIdByBatch[2], 8, "other batch message")
    assertEquals(tc.Parking.noticeByFarm[1], nil, "parking notice")
    assertEquals(tc.Parking.parkAllByFarm[1], nil, "park all run")
    assertTrue(tc.Parking.parkAllByFarm[2] ~= nil, "other park all run")

    assertEquals(tc.AuctionSale.bids[4][1], nil, "auction bids")
    assertEquals(tc.AuctionSale.bids[5][1], nil, "every lot's")
    assertEquals(tc.AuctionSale.bids[4][2].amount, 90, "the other farm's bid kept")

    assertEquals(#tc.Show.results.placings, 2, "show placings")
    assertEquals(tc.Show.results.placings[1].farmerId, 7, "a farmer's placing kept")
    assertEquals(tc.Show.results.placings[2].farmId, 2, "the other farm's placing kept")
    assertEquals(#tc.ShowLivestock.entries, 1, "show entries")
    assertEquals(tc.ShowLivestock.entries[1].farmId, 2, "the other farm's entry kept")
    assertEquals(tc.PloughingMatch.plots[1].farmId, 0, "ploughing plot freed")
    assertEquals(tc.PloughingMatch.plots[1].state, "open", "ploughing plot open again")
    assertEquals(tc.PloughingMatch.plots[1].workerId, 0, "its worker gone")
    assertEquals(#tc.ShowWorker.entries, 1, "the ploughing worker's entry")
    assertEquals(tc.ShowWorker.entries[1].farmId, 2, "the other farm's entry kept")
    assertEquals(tc.ShowStands.visits[1], nil, "the show visit")
    assertTrue(tc.ShowStands.visits[2].joined, "the other farm's visit kept")
    assertEquals(tc.ShowDayOff:getAnswer(1), nil, "the show day off's answer")
    assertEquals(tc.ShowDayOff:getAnswer(2), TCShowDayOff.ANSWER.NO, "the other farm's answer kept")
    assertEquals(tc.Staff.candidatePool[31], nil, "the candidate kept for the farm")
    assertTrue(tc.Staff.candidatePool[32] ~= nil and tc.Staff.candidatePool[33] ~= nil, "the others kept")
    assertEquals(tc.PloughingMatch.plots[2].farmId, 2, "the other farm's plot kept")
    assertEquals(tc.PloughingMatch.best[1], nil, "ploughing best")
    assertEquals(tc.PloughingMatch.best[2].bestScore, 70, "the other farm's best kept")

    assertEquals(count(tc.RandomEvents.incidents), 1, "incidents")
    assertEquals(tc.RandomEvents.lastPeriodByFarm[1], nil, "event cooldowns")
    assertEquals(#tc.RandomEvents.pendingTriggers, 1, "pending triggers")
    assertEquals(tc.Relationships.scores[1], nil, "relationships")
    assertEquals(tc.Relationships.lastComplaints[1], nil, "complaints")

    assertEquals(#tc.RepairContracts.arrivals, 1, "arrivals")
    assertEquals(#tc.RepairContracts.removals, 2, "collections still go ahead")
    assertEquals(#tc.RepairContracts.pendingClaims, 1, "repair claims")
    assertEquals(#tc.RepairContracts.pendingDiscoveries, 1, "substandard parts to be found")
    assertEquals(tc.RepairContracts.overcharged[1], nil, "overcharging")

    assertEquals(tc.Dispatch.pendingByJobId[11], nil, "staging")
    assertEquals(tc.Dispatch.aiJobByOurJobId[12], nil, "AI job")
    assertEquals(tc.Dispatch.ourJobIdByAIJob[world.aiJobs.a], nil, "AI job lookup")
    assertEquals(tc.Dispatch.ourJobIdByAIJob[world.aiJobs.b], 21, "other AI job")
    assertEquals(tc.Dispatch.ourJobIdByAISystemJobId[1], nil, "AI system job")
    assertEquals(tc.Dispatch.ourJobIdByAISystemJobId[2], 21, "other AI system job")
    assertEquals(tc.Dispatch.serviceClearedAtByJobId[11], nil, "service wait")
    assertEquals(tc.Dispatch.serviceClearedAtByJobId[21], 5, "other service wait")
    assertEquals(tc.Dispatch.ranOutOfFillJobIds[11], nil, "ran out of fill")
    assertEquals(tc.Watchdog.trackedByJobId[11], nil, "watchdog")
    assertTrue(tc.Watchdog.trackedByJobId[21] ~= nil, "other watchdog")
end)

test("the server stops the farm's live work, forgets it and tells the clients", function()
    local world, tc = setup()
    world.broadcasts = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.broadcasts, event) end }

    TCFarmDeletion:onFarmDeleted(1)

    assertEquals(#world.cleared.deliveries, 2, "deliveries stopped")
    assertEquals(#world.cleared.fields, 2, "fields cleared up")
    assertEquals(tc.Company.companyNames[1], nil, "forgotten on the server")
    assertEquals(#world.broadcasts, 1, "one event")
    assertEquals(world.broadcasts[1].farmId, 1, "for the farm")
end)

test("nothing happens for the spectator farm or on a client", function()
    local world, tc = setup()
    world.broadcasts = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.broadcasts, event) end }

    TCFarmDeletion:onFarmDeleted(0)
    g_currentMission.getIsServer = function() return false end
    TCFarmDeletion:onFarmDeleted(1)

    assertEquals(#world.broadcasts, 0, "nothing sent")
    assertEquals(tc.Company.companyNames[1], "Old Co", "nothing forgotten")
end)

test("a client forgets the farm when the server's event arrives, and only then", function()
    local _, tc = setup()
    local event = TCFarmDeletedEvent.new(1)

    event:run({ getIsServer = function() return false end })
    assertEquals(tc.Company.companyNames[1], "Old Co", "ignored from a client")

    event:run({ getIsServer = function() return true end })
    assertEquals(tc.Company.companyNames[1], nil, "forgotten from the server")
end)
