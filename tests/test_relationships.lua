-- 113: each farm's relationship with each customer (110's farmers and the
-- official) - what moves it through the real Jobs (declined, lapsed, walked
-- away in negotiation, completed by quality, missed), pursuing an invoice,
-- the monthly drift, the clamp, the save and the stream; what it changes
-- (014's tolerance, 011's field weights and refusals); and a customer's
-- hidden pay habit on the real Finances' invoices.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TheContractorJobGeneration = { JOB_TYPES = { plow = {} }, getOperationSkill = function() return nil end }
    TheContractorRepairContracts = { isWorkshopJob = function(job) return job.workshop ~= nil end }
    TCFieldPreparation = { clearUpAfterJob = function() end }
    TCJobStateChangedEvent = { new = function() return {} end }
    TCJobNegotiationUpdatedEvent = { new = function() return {} end }
    TCRelationshipChangedEvent = {
        new = function(farmId, customerId, score)
            return { farmId = farmId, customerId = customerId, score = score }
        end,
    }
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    Environment = { PERIODS_IN_YEAR = 12 }
    g_currentMission.environment = { currentMonotonicDay = 10, daysPerPeriod = 1, plannedDaysPerPeriod = 1,
        currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1 }

    world:load("src/business/Negotiation.lua")
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")

    local tc = g_currentMission.TheContractor
    world.standing = 0
    tc.Reputation = { getStanding = function() return world.standing end }
    -- 129: a miss can leave the customer poor, so they complain.
    TCCalendar.getPeriodIndex = function() return 1 end
    g_fieldManager = { getFieldById = function() return nil end }
    tc.Inbox = { removeMessagesForJob = function() end, postMessage = function() end }
    tc.Jobs = TheContractorJobs.new()
    local relationships = world:addRelationships()

    -- An offer from customer 5 (or customerId, 0 for nobody) on field 4,
    -- due on day 12.
    function world:addOffer(id, customerId)
        local job = TheContractorJob.new(id, 1, "plow", 4, 1, 1, 1, 1000)
        customerId = customerId or 5
        job.customerId = customerId ~= 0 and customerId or nil
        job.deadlineDay = 12
        job.eagerness = 100
        tc.Jobs.jobsByFarm[1] = tc.Jobs.jobsByFarm[1] or {}
        tc.Jobs.jobsByFarm[1][id] = job
        return job
    end

    return world, relationships, tc
end

test("declining, letting an offer lapse and walking away in negotiation cost different amounts", function()
    local world, relationships, tc = setup()
    local R = TheContractorRelationships

    world:addOffer(1)
    tc.Jobs:transitionJobState(1, 1, TheContractorJob.STATE.DECLINED)
    assertEquals(relationships:getScore(1, 5), -R.DECLINED_LOSS, "declined by the player")

    world:addOffer(2)
    g_currentMission.environment.currentMonotonicDay = 13
    tc.Jobs:onDayChanged()
    assertEquals(relationships:getScore(1, 5), -R.DECLINED_LOSS - R.LAPSED_LOSS, "left to lapse")

    world:addOffer(3)
    local outcome = tc.Jobs:proposeCounterOffer(1, 3, 5000)
    assertEquals(outcome, TheContractorNegotiation.OUTCOME.REJECTED)
    assertEquals(relationships:getScore(1, 5), -R.DECLINED_LOSS - R.LAPSED_LOSS - R.WALKED_AWAY_LOSS,
        "they walked away")
    assertEquals(relationships:getScore(2, 5), 0, "another farm's is untouched")
end)

test("a job with no customer moves nothing", function()
    local world, relationships, tc = setup()
    world:addOffer(1, 0)

    tc.Jobs:transitionJobState(1, 1, TheContractorJob.STATE.DECLINED)
    assertEquals(next(relationships.scores), nil)
    for _, event in ipairs(world.events) do
        assertEquals(event.customerId, nil, "no relationship event")
    end
end)

test("a completed job raises it by its quality, and poor work lowers it", function()
    local world, relationships = setup()
    local job = world:addOffer(1)

    job.qualityScore = 100
    relationships:onJobCompleted(job)
    assertEquals(relationships:getScore(1, 5), TheContractorRelationships.COMPLETED_GAIN)

    job.qualityScore = 75
    relationships:onJobCompleted(job)
    assertEquals(relationships:getScore(1, 5), TheContractorRelationships.COMPLETED_GAIN * 1.5, "half as much")

    job.qualityScore = 30
    relationships:onJobCompleted(job)
    assertTrue(relationships:getScore(1, 5) < TheContractorRelationships.COMPLETED_GAIN * 1.5, "poor work costs it")
end)

test("a missed job costs less the more of it was done, but never less than the minimum", function()
    local world, relationships = setup()
    local R = TheContractorRelationships
    local job = world:addOffer(1)

    relationships:onJobMissed(job)
    assertEquals(relationships:getScore(1, 5), -R.MISSED_LOSS)

    job.customerId = 6
    job.completionPercentage = 50
    relationships:onJobMissed(job)
    assertEquals(relationships:getScore(1, 6), -R.MISSED_LOSS / 2)

    job.customerId = 7
    job.completionPercentage = 95
    relationships:onJobMissed(job)
    assertEquals(relationships:getScore(1, 7), -R.MIN_MISSED_LOSS)
end)

test("pursuing an invoice costs the job's customer", function()
    local world, relationships = setup()
    local job = world:addOffer(1)

    relationships:onInvoicePursued(1, job)
    assertEquals(relationships:getScore(1, 5), -TheContractorRelationships.PURSUED_LOSS)
    relationships:onInvoicePursued(1, nil)
    assertEquals(relationships:getScore(1, 5), -TheContractorRelationships.PURSUED_LOSS, "a job that's gone")
end)

test("scores are clamped, and the clients get the absolute score", function()
    local world, relationships = setup()

    relationships:adjust(1, 5, 250)
    assertEquals(relationships:getScore(1, 5), TheContractorRelationships.MAX_SCORE)
    relationships:adjust(1, 5, -500)
    assertEquals(relationships:getScore(1, 5), TheContractorRelationships.MIN_SCORE)
    local event = world.events[#world.events]
    assertEquals(event.score, TheContractorRelationships.MIN_SCORE)
    assertEquals(event.customerId, 5)

    local count = #world.events
    relationships:adjust(1, 5, -1)
    assertEquals(#world.events, count, "nothing sent when nothing changes")
end)

test("every month both good and bad drift back towards neutral, and stop there", function()
    local world, relationships = setup()
    local step = TheContractorRelationships.DRIFT_PER_MONTH
    relationships:adjust(1, 5, 20)
    relationships:adjust(1, 6, -20)
    relationships:adjust(2, 5, step - 2)

    relationships:drift()
    assertEquals(relationships:getScore(1, 5), 20 - step)
    assertEquals(relationships:getScore(1, 6), -20 + step)
    assertEquals(relationships:getScore(2, 5), 0, "not past neutral")
    assertEquals(relationships.scores[2][5], nil, "a neutral score isn't kept")
end)

test("a customer who has fallen out offers no work until the drift brings them back", function()
    local world, relationships = setup()
    local R = TheContractorRelationships
    relationships:adjust(1, 5, R.REFUSES_BELOW - 1)
    assertTrue(relationships:refuses(1, 5))
    assertEquals(relationships:getOfferWeight(1, 5), 0)
    assertEquals(R.getBand(relationships:getScore(1, 5)).key, "fallenOut")
    assertTrue(not relationships:refuses(2, 5), "only with that farm")
    assertTrue(not relationships:refuses(1, nil), "nobody never refuses")

    relationships:drift()
    assertTrue(not relationships:refuses(1, 5))
    assertTrue(relationships:getOfferWeight(1, 5) > 0)
end)

test("good relationships weigh a customer's fields up, poor ones down", function()
    local world, relationships = setup()
    relationships:adjust(1, 5, 60)
    relationships:adjust(1, 6, -30)

    assertEquals(relationships:getOfferWeight(1, 7), 1, "neutral")
    assertTrue(relationships:getOfferWeight(1, 5) > 1)
    assertTrue(relationships:getOfferWeight(1, 6) < 1)
    assertNear(relationships:getOfferWeight(1, 5), 1 + 0.6 * (TheContractorRelationships.MAX_OFFER_WEIGHT - 1),
        0.0001)
end)

test("a good relationship leaves more room for a counter-offer, a poor one less", function()
    local world, relationships = setup()
    -- Standing 0, full eagerness: +5% on the 1000 offer when neutral.
    local neutral = world:addOffer(1, 5)
    local good = world:addOffer(2, 6)
    local poor = world:addOffer(3, 7)
    relationships:adjust(1, 6, 100)
    relationships:adjust(1, 7, -100)

    local OUTCOME = TheContractorNegotiation.OUTCOME
    assertEquals((TheContractorNegotiation.resolveCounterOffer(neutral, 1070)), OUTCOME.COUNTERED)
    assertEquals((TheContractorNegotiation.resolveCounterOffer(good, 1070)), OUTCOME.ACCEPTED)
    assertEquals((TheContractorNegotiation.resolveCounterOffer(poor, 1070)), OUTCOME.REJECTED)
end)

test("relationships survive a save and a client join, and a new company starts afresh", function()
    local world, relationships = setup()
    relationships:adjust(1, 5, 30)
    relationships:adjust(1, 6, -45)
    relationships:adjust(2, 5, 12)

    local xmlFile = {}
    relationships:saveToXmlFile(xmlFile)
    local loaded = TheContractorRelationships.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getScore(1, 5), 30)
    assertEquals(loaded:getScore(1, 6), -45)
    assertEquals(loaded:getScore(2, 5), 12)

    local stream = world:newStream()
    relationships:writeInitialClientState(stream)
    local client = TheContractorRelationships.new()
    client:readInitialClientState(stream)
    assertEquals(client:getScore(1, 6), -45)
    assertEquals(client:getScore(2, 5), 12)

    client:reset(1)
    assertEquals(client:getScore(1, 5), 0)
    assertEquals(client:getScore(2, 5), 12, "only that farm's")
end)

test("generation leaves out a field whose customer has fallen out", function()
    local world, relationships = setup()
    local tc = g_currentMission.TheContractor
    TheContractorJobGeneration = nil
    world:load("src/business/JobGeneration.lua")
    TheContractorJobGeneration.isFieldEligible = function() return true end
    local function field(id)
        return { getId = function() return id end, getOwner = function() return 0 end }
    end
    g_fieldManager = { getFields = function() return { field(1), field(2) } end }
    tc.Farmers = {
        getCustomerIdForField = function(_, fieldId) return fieldId == 1 and 5 or 6 end,
        getPerson = function() return nil end,
    }
    tc.Jobs.isFieldProtected = function() return false end

    relationships:adjust(1, 5, TheContractorRelationships.REFUSES_BELOW - 1)
    local candidates = TheContractorJobGeneration:getCandidateFields(1, {})
    assertEquals(#candidates, 1)
    assertEquals(candidates[1]:getId(), 2)
    assertEquals(#TheContractorJobGeneration:getCandidateFields(2, {}), 2, "another farm still gets both")
end)

-- A customer's pay habit (Farmers) on the real Finances' invoices ---------------

local function setupInvoices()
    local world, relationships, tc = setup()
    world:load("src/business/Finances.lua")
    world:load("src/business/Farmers.lua")
    TCInvoiceIssuedEvent = { new = function() return {} end }
    TCFinanceYearStatsEvent = { new = function() return {} end }
    TCCalendar.getDisplayYear = function() return 1 end
    tc.Settings = { get = function() return true end }
    tc.Office = {
        getDelayWeights = function() return TheContractorFinances.DELAY_WEIGHTS end,
        getBadDebtChance = function() return TheContractorFinances.BAD_DEBT_CHANCE end,
        getLatePayerChance = function() return TheContractorFinances.LATE_PAYER_CHANCE end,
    }
    tc.Finances = TheContractorFinances.new()
    tc.Farmers = TheContractorFarmers.new()
    tc.Farmers.people = {
        [1] = { id = 1, name = "Official", isOfficial = true, payHabit = "slow" },
        [5] = { id = 5, name = "Prompt", payHabit = "prompt" },
        [6] = { id = 6, name = "Average", payHabit = "average" },
        [7] = { id = 7, name = "Slow", payHabit = "slow" },
    }
    -- Every unit roll is world.roll; a range roll its low end.
    world.roll = 0
    math.random = function(low, high)
        if low ~= nil then
            return low
        end
        return world.roll
    end

    function world:invoice(id, customerId)
        local job = self:addOffer(id, customerId)
        job.paymentAmount = 1000
        tc.Finances:invoiceJob(job)
        return tc.Finances:getInvoice(tc.Finances.nextInvoiceId - 1)
    end
    return world, tc
end

test("a slow payer is late on a roll an average one pays on time, and a prompt one rarely is", function()
    local world = setupInvoices()
    -- Above the 15% late-payer chance; under it three times over.
    world.roll = 0.2
    assertTrue(not world:invoice(1, 6).isLate, "average pays on time")
    assertTrue(world:invoice(2, 7).isLate, "slow is late")
    assertTrue(not world:invoice(3, 1).isLate, "the official pays as average, whatever's stored")
    assertTrue(not world:invoice(4, 0).isLate, "nobody pays as average")

    world.roll = 0.1
    assertTrue(world:invoice(5, 6).isLate, "average is late on a low roll")
    assertTrue(not world:invoice(6, 5).isLate, "prompt isn't")
end)

test("a slow payer is likelier to be a bad debt", function()
    local world = setupInvoices()
    -- Over the 5% bad-debt chance, under half as much again.
    world.roll = 0.06
    assertTrue(not world:invoice(1, 6).isBadDebt)
    assertTrue(world:invoice(2, 7).isBadDebt)
end)
