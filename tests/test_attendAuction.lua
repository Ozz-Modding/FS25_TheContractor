-- 141: the "attend the auction" job. Made, accepted, for company farms only
-- once the sale's month begins (the day tick, the announcement, a company
-- set up mid-month), never twice; done by someone on the site in sale
-- hours, a bid or a win; missed quietly at the day's end; taken away if
-- the auction's called off. The noConsequences flag skips every
-- consequence path (reputation, relationship, quality, invoice, logbook,
-- the missed notification) that an ordinary job goes through, it's never
-- allocated, it doesn't stop its field being the sale's site, and its
-- auction goes to clients and into the save. The real Jobs, Job,
-- JobGeneration, Allocation, Auctions, TCCalendar, TCAuctionAttendance and
-- the job events; the rest of the mod is faked, recording every
-- consequence it's asked for.

local SALE_FIELD = 12
local HOST_ID = 7

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
    world:load("src/business/Allocation.lua")
    world:load("src/util/TCAuctionAttendance.lua")
    world:load("src/business/Auctions.lua")
    world:load("src/events/TCJobCreatedEvent.lua")
    world:load("src/events/TCJobStateChangedEvent.lua")
    world:load("src/events/TCJobCompletedEvent.lua")
    world:load("src/events/TCJobMissedEvent.lua")
    world:load("src/events/TCJobRemovedEvent.lua")
    TCAuctionEvent = { new = function(auction) return { auction = auction } end }
    TheContractorAuctionSite = { CLOSE_HOURS = { 17, 18 } }
    -- Vanilla's month names, for the console's dates.
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    -- Period 1 (spring), day 1 of 10.
    g_currentMission.environment = {
        currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 10, plannedDaysPerPeriod = 10,
        currentMonotonicDay = 1, currentHour = 9, dayTime = 9 * 3600000,
    }

    -- The sale's field (a square, 0-100 each way) and an ordinary one.
    local function addField(id)
        local field = { id = id }
        function field:getId() return self.id end
        function field:getName() return tostring(self.id) end
        function field:getAreaHa() return 2 end
        function field:getPolygonPoints()
            return { { x = 0, z = 0 }, { x = 100, z = 0 }, { x = 100, z = 100 }, { x = 0, z = 100 } }
        end
        return field
    end
    world.fields = { [SALE_FIELD] = addField(SALE_FIELD), [3] = addField(3) }
    g_fieldManager = { getFieldById = function(_, id) return world.fields[id] end }

    -- Players: { farmId, x, z }.
    world.players = {}
    g_currentMission.playerSystem = {
        getPlayerCount = function() return #world.players end,
        getPlayerByIndex = function(_, i)
            local entry = world.players[i]
            return entry ~= nil and {
                farmId = entry.farmId,
                getPosition = function() return entry.x, 0, entry.z end,
            } or nil
        end,
    }

    -- Every consequence a finished job could have, as it's asked for.
    world.consequences = {}
    local function record(name)
        return function() table.insert(world.consequences, name) end
    end
    local tc = g_currentMission.TheContractor
    tc.Jobs = TheContractorJobs.new()
    tc.Allocation = TheContractorAllocation.new()
    tc.Reputation = { addReputation = record("reputation") }
    tc.Relationships = { onJobCompleted = record("relationship"), onJobMissed = record("relationship") }
    tc.Logbook = { recordJobCompleted = record("logbook"), recordJobMissed = record("logbook") }
    tc.Finances = { invoiceJob = record("invoice") }
    tc.Claims = { rollForJob = record("claim") }
    tc.RandomEvents = { onJobCompleted = record("jobEvent"), getCompanyFarmIds = function() return world.companyFarms end }
    tc.Staff = { applyGrowthFromJob = record("growth"), getWorker = function() return nil end }
    tc.Cooldown = { startCooldown = record("cooldown") }
    tc.Dispatch = { stopJob = function() end }
    tc.Association = { getReputationBonus = function() return 0 end }
    tc.Inbox = { messagesById = {}, removeMessagesForJob = function() end }
    tc.Farmers = {
        getCustomerIdForJob = function(_, job) return job.fieldId == SALE_FIELD and HOST_ID or nil end,
        getPerson = function(_, id) return id == HOST_ID and { id = HOST_ID, name = "Tom" } or nil end,
    }
    TCJobProgress = { clearJob = function() end }
    TCHaulage = { stopDelivery = function() end, emptyHarvestersAfterJob = function() end }
    TCFieldPreparation = { clearUpAfterJob = function() end, clearUpAtCompletion = function() end }
    tc.AuctionSite = {
        site = nil,
        fieldId = 0,
        lots = {},
        isFieldInUse = function(self, fieldId) return self.fieldId ~= 0 and self.fieldId == fieldId end,
        getLots = function(self) return self.lots end,
    }
    tc.AuctionSigns = { month = 0, signs = {} }
    tc.hasResolvedSavedVehicles = false
    world.companyFarms = { 1, 2 }

    -- The auction: sale day 25 (period 3, day 5), signs up already.
    tc.Auctions = TheContractorAuctions.new()
    tc.Auctions.auction = {
        id = 4, fieldId = SALE_FIELD, hostFarmerId = HOST_ID, announcedDay = 1, signsDay = 1, saleDay = 25,
        state = TheContractorAuctions.STATE.SIGNS_UP,
    }
    world.auction = tc.Auctions.auction
    return world, tc
end

-- Moves the clock to a day (monotonic, 10 days a month) and hour.
local function setTime(day, hour)
    local environment = g_currentMission.environment
    environment.currentMonotonicDay = day
    environment.currentPeriod = math.floor((day - 1) / 10) + 1
    environment.currentDayInPeriod = (day - 1) % 10 + 1
    environment.currentHour = hour or 9
    environment.dayTime = (hour or 9) * 3600000
end

local function attendJobs(tc, farmId)
    local found = {}
    for _, job in ipairs(tc.Jobs:getAllJobs(farmId)) do
        if job.auctionId ~= nil then
            table.insert(found, job)
        end
    end
    return found
end

-- The sale's month has come (day 21), and the jobs are made.
local function reachSaleMonth(world, tc)
    setTime(21, 0)
    tc.Auctions:onDayChanged()
    return attendJobs(tc, 1)[1]
end

-- Made --------------------------------------------------------------------------------

test("nothing before the sale's month, then one accepted job per company farm", function()
    local world, tc = setup()
    setTime(20, 0)
    tc.Auctions:onDayChanged()
    assertEquals(#attendJobs(tc, 1), 0, "the month before")

    local job = reachSaleMonth(world, tc)
    assertTrue(job ~= nil, "farm 1's")
    assertEquals(#attendJobs(tc, 2), 1, "farm 2's")
    assertEquals(#attendJobs(tc, 3), 0, "farm 3 has no company")
    assertEquals(job.jobType, "attendAuction")
    assertEquals(job.state, TheContractorJob.STATE.ACCEPTED)
    assertEquals(job.auctionId, 4)
    assertEquals(job.fieldId, SALE_FIELD)
    assertEquals(job.readyDay, 25)
    assertEquals(job.deadlineDay, 25)
    assertEquals(job.targetPeriod, 3)
    assertEquals(job.targetDayInPeriod, 5)
    assertEquals(job.customerId, HOST_ID, "the host")
    assertEquals(job:getPrice(), 0)
    assertTrue(not job:isReady(), "listed under Upcoming until the day")
end)

test("never made twice, even once it's done", function()
    local world, tc = setup()
    local job = reachSaleMonth(world, tc)
    TCAuctionAttendance.markAttended(1)
    setTime(22, 0)
    tc.Auctions:onDayChanged()
    assertEquals(#attendJobs(tc, 1), 1)
    assertEquals(attendJobs(tc, 1)[1], job)
end)

test("an announcement in the sale's month makes them at once", function()
    local world, tc = setup()
    tc.Auctions.auction = nil
    tc.Inbox.postMessage = function() end
    tc.AuctionSigns.place = function() end
    TheContractorInbox = { DISMISS_ACTION = { key = "dismiss" } }
    setTime(21, 9)
    local auction = tc.Auctions:announce({ fieldId = SALE_FIELD, hostId = HOST_ID }, 25)
    assertTrue(auction ~= nil)
    assertEquals(#attendJobs(tc, 1), 1)
    assertEquals(#attendJobs(tc, 2), 1)
end)

test("a company set up mid-month gets one, but not once the sale's over", function()
    local world, tc = setup()
    reachSaleMonth(world, tc)
    setTime(23, 10)
    TCAuctionAttendance.onCompanyCreated(3)
    assertEquals(#attendJobs(tc, 3), 1)

    setTime(25, TheContractorAuctions.SALE_END_HOUR)
    TCAuctionAttendance.onCompanyCreated(5)
    assertEquals(#attendJobs(tc, 5), 0, "the last lot's closed")
    tc.Auctions.auction = nil
    TCAuctionAttendance.onCompanyCreated(6)
    assertEquals(#attendJobs(tc, 6), 0, "no auction")
end)

-- Done --------------------------------------------------------------------------------

test("someone from the farm on the site in sale hours completes it, with no consequences", function()
    local world, tc = setup()
    local job = reachSaleMonth(world, tc)
    local other = attendJobs(tc, 2)[1]
    world.players = {
        { farmId = 1, x = 50, z = 50 },
        { farmId = 2, x = 150, z = 50 },
    }

    setTime(25, TheContractorAuctions.SALE_HOUR - 1)
    TCAuctionAttendance.checkAttendance(world.auction)
    assertEquals(job.state, TheContractorJob.STATE.ACCEPTED, "before viewing opens")

    setTime(25, TheContractorAuctions.SALE_HOUR + 2)
    TCAuctionAttendance.checkAttendance(world.auction)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(job.completionPercentage, 100)
    assertTrue(job.completedAt ~= nil)
    assertEquals(other.state, TheContractorJob.STATE.ACCEPTED, "farm 2's player is off the field")

    assertEquals(#world.consequences, 0, "nothing at all")
    assertEquals(job.qualityScore, nil, "no quality score")
    assertEquals(job.paymentAmount, nil, "not invoiced")
    local completed = world.events[#world.events]
    assertEquals(completed.job, job, "the snapshot to clients")
end)

test("the hourly check on the sale day finds them, the last at the close", function()
    local world, tc = setup()
    local job = reachSaleMonth(world, tc)
    tc.Auctions.advance = function() end
    tc.Auctions.catchUpSale = function() end
    world.players = { { farmId = 1, x = 10, z = 90 } }
    setTime(25, TheContractorAuctions.SALE_END_HOUR)
    tc.Auctions:onHourChanged()
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
end)

test("a bid or a win counts as going", function()
    local world, tc = setup()
    reachSaleMonth(world, tc)
    setTime(25, 11)
    TCAuctionAttendance.markAttended(2)
    assertEquals(attendJobs(tc, 2)[1].state, TheContractorJob.STATE.COMPLETED)
    assertEquals(attendJobs(tc, 1)[1].state, TheContractorJob.STATE.ACCEPTED)
    assertEquals(#world.consequences, 0)
end)

-- Missed ----------------------------------------------------------------------------------

test("staying away ends it quietly at the day's end", function()
    local world, tc = setup()
    local job = reachSaleMonth(world, tc)
    world.notifications = {}
    setTime(26, 0)
    tc.Jobs:onDayChanged()
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    assertEquals(#world.consequences, 0, "no reputation, relationship or logbook")
    assertEquals(#world.notifications, 1, "farm 1's word that it's over")
    assertEquals(world.notifications[1].type, FSBaseMission.INGAME_NOTIFICATION_INFO, "not a failure")
end)

test("an ordinary job's miss goes through every consequence (the fakes catch them)", function()
    local world, tc = setup()
    local job = TheContractorJob.new(50, 1, "plow", 3, 1, 1, 1, 1000)
    job.state = TheContractorJob.STATE.ACCEPTED
    tc.Jobs:registerJob(job, false)
    world.notifications = {}
    tc.Jobs:missJob(job)
    assertTrue(#world.consequences >= 3)
    assertEquals(world.notifications[1].type, FSBaseMission.INGAME_NOTIFICATION_CRITICAL)
end)

test("the flag is checked on the type, not the name", function()
    local world, tc = setup()
    local job = reachSaleMonth(world, tc)
    assertTrue(TheContractorJobs.hasNoConsequences(job))
    TheContractorJobGeneration.JOB_TYPES.attendAuction.noConsequences = nil
    assertTrue(not TheContractorJobs.hasNoConsequences(job))
    TheContractorJobGeneration.JOB_TYPES.attendAuction.noConsequences = true
end)

-- Called off ------------------------------------------------------------------------------

test("cancelling the auction takes away the jobs not yet done", function()
    local world, tc = setup()
    local done = reachSaleMonth(world, tc)
    TCAuctionAttendance.markAttended(1)
    local open = attendJobs(tc, 2)[1]
    world.events = {}

    assertTrue(tc.Auctions:cancel(false))
    assertEquals(tc.Jobs:getJob(2, open.id), nil, "farm 2's goes")
    assertEquals(tc.Jobs:getJob(1, done.id), done, "a done one stays in the history")
    local removed = nil
    for _, event in ipairs(world.events) do
        if event.jobId == open.id then
            removed = event
        end
    end
    assertTrue(removed ~= nil, "clients told")
    assertEquals(removed.farmId, 2)

    -- A client drops its copy.
    local clientJobs = TheContractorJobs.new()
    clientJobs:registerJob(open, false)
    tc.Jobs = clientJobs
    removed:run(nil)
    assertEquals(clientJobs:getJob(2, open.id), nil)
end)

test("moving the sale day makes them again for the new day", function()
    local world, tc = setup()
    reachSaleMonth(world, tc)
    tc.Auctions.advance = function() end
    tc.Auctions.postMessages = function() end
    setTime(23, 9)
    tc.Auctions:consoleSaleDay()
    local jobs = attendJobs(tc, 1)
    assertEquals(#jobs, 1)
    assertEquals(jobs[1].deadlineDay, 23)
    assertEquals(jobs[1].readyDay, 23)
end)

-- Never allocated, never in the site's way ----------------------------------------------------

test("it's never allocated", function()
    local world, tc = setup()
    local job = reachSaleMonth(world, tc)
    setTime(25, 9)
    assertTrue(not TheContractorAllocation.isAllocatable(job))
    assertEquals(tc.Allocation:allocateJob(1, job.id, {}, {}, {}, false, "Farmhand"), false)
    assertEquals(job.state, TheContractorJob.STATE.ACCEPTED)

    local plow = TheContractorJob.new(51, 1, "plow", 3, 1, 1, 1, 1000)
    assertTrue(TheContractorAllocation.isAllocatable(plow), "an ordinary job is")
end)

test("it doesn't count as a live job on the sale's field", function()
    local world, tc = setup()
    reachSaleMonth(world, tc)
    assertTrue(not tc.Jobs:hasLiveJob(SALE_FIELD))
    assertTrue(tc.Jobs:isFieldProtected(SALE_FIELD), "the auction still protects it")
end)

test("the lots are counted once they're out on its field", function()
    local world, tc = setup()
    local job = reachSaleMonth(world, tc)
    assertEquals(TCAuctionAttendance.getLotCount(job), nil, "not set out")
    tc.AuctionSite.fieldId = SALE_FIELD
    assertEquals(TCAuctionAttendance.getLotCount(job), nil, "none out yet")
    tc.AuctionSite.lots = { { number = 1 }, { number = 2 }, { number = 3 } }
    assertEquals(TCAuctionAttendance.getLotCount(job), 3)
    tc.AuctionSite.fieldId = 3
    assertEquals(TCAuctionAttendance.getLotCount(job), nil, "another field's")
end)

-- Clients and the save ------------------------------------------------------------------------

test("its auction goes to clients, and an ordinary job has none", function()
    local world, tc = setup()
    local job = reachSaleMonth(world, tc)
    local plow = TheContractorJob.new(52, 1, "plow", 3, 1, 1, 1, 1000)
    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    TheContractorJobs.writeJob(stream, plow)
    assertEquals(TheContractorJobs.readJob(stream).auctionId, 4)
    assertEquals(TheContractorJobs.readJob(stream).auctionId, nil)
end)

test("its auction survives a save", function()
    local world, tc = setup()
    local job = reachSaleMonth(world, tc)
    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local loaded = TheContractorJobs.new()
    loaded:loadFromXMLFile(xmlFile)
    local copy = loaded:getJob(1, job.id)
    assertEquals(copy.auctionId, 4)
    assertEquals(copy.readyDay, 25)
    assertEquals(copy.state, TheContractorJob.STATE.ACCEPTED)
end)
