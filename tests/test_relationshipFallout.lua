-- 129: when a relationship goes bad. A complaint (a missed or poor job that
-- leaves the customer poor, once a month each, kept through a save) and
-- word getting round (falling out costs the neighbours and reputation and
-- posts a notice; never the official, never the farmer themselves, no
-- cascade, once per crossing). The real Relationships, Farmers (its
-- neighbours rule), Reputation, Inbox and Job; the map and the calendar are
-- faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TheContractorJobGeneration = { JOB_TYPES = { plow = {} } }
    -- 080's factor, as Jobs has it (0 at 50).
    TheContractorJobs = {
        getQualityReputationFactor = function(qualityScore) return (qualityScore - 50) / 50 end,
    }
    world.period = 30
    TCCalendar = { getPeriodIndex = function() return world.period end }
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    TCRelationshipChangedEvent = {
        new = function(farmId, customerId, score)
            return { kind = "relationship", farmId = farmId, customerId = customerId, score = score }
        end,
    }
    TCReputationChangedEvent = {
        new = function(farmId, score) return { kind = "reputation", farmId = farmId, score = score } end,
    }
    TCMessagePostedEvent = { new = function(message) return { kind = "message", message = message } end }
    g_currentMission.environment = { currentMonotonicDay = 100 }
    g_fieldManager = {
        getFieldById = function(_, fieldId)
            return { getName = function() return "Field " .. fieldId end }
        end,
    }

    world:load("src/business/Job.lua")
    world:load("src/business/Farmers.lua")
    world:load("src/business/Reputation.lua")
    world:load("src/business/Inbox.lua")

    local tc = g_currentMission.TheContractor
    tc.Reputation = TheContractorReputation.new()
    tc.Reputation:applyReputationScore(1, 100)
    tc.Inbox = TheContractorInbox.new()
    local relationships = world:addRelationships()
    relationships:registerMessageKinds(tc.Inbox)

    -- Farmlands along a line (x in metres), and one yard: farmer 3 is 400 m
    -- from farmer 2, farmer 5's yard 424 m, farmer 4 far off. The official
    -- has no land.
    world.land = {
        [1] = { id = 1, x = 0, z = 0 },
        [2] = { id = 2, x = 400, z = 0 },
        [3] = { id = 3, x = 2000, z = 0 },
        [4] = { id = 4, x = 3000, z = 0 },
        [5] = { id = 5, x = 300, z = 300 },
    }
    world.yards = { [5] = { farmlandId = 5, x = 300, z = 300 } }
    TheContractorFarmers.getLand = function() return world.land end
    TheContractorFarmers.getFreeYards = function() return world.yards end
    tc.Farmers = TheContractorFarmers.new()
    tc.Farmers.officialId = 1
    tc.Farmers.people = {
        [1] = { id = 1, name = "Official", isOfficial = true, farmlandIds = {} },
        [2] = { id = 2, name = "Fallen", farmlandIds = { 1 } },
        [3] = { id = 3, name = "Near", farmlandIds = { 2 } },
        [4] = { id = 4, name = "Far", farmlandIds = { 3 } },
        [5] = { id = 5, name = "Yard", farmlandIds = { 4 }, yardFarmlandId = 5 },
    }

    -- A job for customerId on field 4.
    function world:job(id, customerId)
        local job = TheContractorJob.new(id, 1, "plow", 4, 1, 1, 1, 1000)
        job.customerId = customerId
        return job
    end

    function world:messages(kind)
        local list = {}
        for _, message in ipairs(tc.Inbox:getMessages(1)) do
            if message.kind == kind then
                table.insert(list, message)
            end
        end
        return list
    end

    return world, relationships, tc
end

local function complaints(world)
    return world:messages(TheContractorRelationships.COMPLAINT_KIND)
end

local function notices(world)
    return world:messages(TheContractorRelationships.WORD_KIND)
end

-- A complaint ----------------------------------------------------------------------

test("a missed job that leaves a farmer poor brings a complaint from them about the job's place", function()
    local world, relationships, tc = setup()
    relationships:adjust(1, 2, -10)

    relationships:onJobMissed(world:job(1, 2))
    assertEquals(TheContractorRelationships.getBand(relationships:getScore(1, 2)).key, "poor")
    local list = complaints(world)
    assertEquals(#list, 1)
    local message = list[1]
    assertEquals(message.titleKey, "tc_complaint_title")
    assertTrue(string.find(message.bodyKey, "^tc_complaint_body_missed_%d$") ~= nil, message.bodyKey)
    assertEquals(message.args[1], "Field 4")
    assertEquals(message.payload.farmerId, 2)
    assertEquals(#message.actions, 1, "only Dismiss")
    assertEquals(tc.Inbox:getMessageCustomer(message).id, 2, "from the farmer")

    -- The name's worked out live.
    tc.Farmers.people[2].name = "Renamed"
    local args = TheContractorRelationships.getComplaintArgs(message)
    assertEquals(args[1], "Renamed")
    assertEquals(args[2], "Field 4")
end)

test("a missed job that leaves a farmer neutral, or takes them past poor, brings no complaint", function()
    local world, relationships = setup()
    local job = world:job(1, 2)
    job.completionPercentage = 95
    relationships:onJobMissed(job)
    assertEquals(TheContractorRelationships.getBand(relationships:getScore(1, 2)).key, "neutral")
    assertEquals(#complaints(world), 0)

    relationships:adjust(1, 3, -25)
    relationships:onJobMissed(world:job(2, 3))
    assertEquals(TheContractorRelationships.getBand(relationships:getScore(1, 3)).key, "fallenOut")
    assertEquals(#complaints(world), 0, "fallen out: word gets round instead")
end)

test("poor work brings a complaint from a poor customer, decent work doesn't", function()
    local world, relationships = setup()
    relationships:adjust(1, 2, -30)
    relationships:adjust(1, 3, -30)

    local decent = world:job(1, 3)
    decent.qualityScore = TheContractorRelationships.COMPLAINT_QUALITY + 10
    relationships:onJobCompleted(decent)
    assertEquals(TheContractorRelationships.getBand(relationships:getScore(1, 3)).key, "poor")
    assertEquals(#complaints(world), 0)

    local poor = world:job(2, 2)
    poor.qualityScore = TheContractorRelationships.COMPLAINT_QUALITY - 10
    relationships:onJobCompleted(poor)
    local list = complaints(world)
    assertEquals(#list, 1)
    assertTrue(string.find(list[1].bodyKey, "^tc_complaint_body_poorWork_%d$") ~= nil, list[1].bodyKey)
end)

test("a customer complains to a farm once a month at most, and the save keeps it", function()
    local world, relationships, tc = setup()
    -- Half done from -5: -20, poor.
    relationships:adjust(1, 4, -5)
    local job = world:job(2, 4)
    job.completionPercentage = 50
    relationships:onJobMissed(job)
    assertEquals(#complaints(world), 1)

    relationships:adjust(1, 4, 15)
    relationships:onJobMissed(job)
    assertEquals(#complaints(world), 1, "not again this month")
    assertEquals(relationships:getLastComplaintPeriod(1, 4), world.period)

    -- Another farm's customer isn't held back by it.
    relationships:adjust(2, 4, -20)
    local other = world:job(3, 4)
    other.farmId = 2
    relationships:onJobMissed(other)
    assertEquals(#tc.Inbox:getMessages(2), 1)

    local xmlFile = {}
    relationships:saveToXmlFile(xmlFile)
    local loaded = TheContractorRelationships.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getLastComplaintPeriod(1, 4), world.period)
    assertTrue(not loaded:canComplain(1, 4), "still held after a load")
    world.period = world.period + TheContractorRelationships.COMPLAINT_COOLDOWN
    assertTrue(loaded:canComplain(1, 4), "free again next month")
    relationships:adjust(1, 4, 15)
    relationships:onJobMissed(job)
    assertEquals(#complaints(world), 2, "next month")
end)

test("the official complains as a farmer does", function()
    local world, relationships, tc = setup()
    relationships:adjust(1, 1, -10)
    relationships:onJobMissed(world:job(1, 1))
    assertEquals(#complaints(world), 1)
    assertEquals(tc.Inbox:getMessageCustomer(complaints(world)[1]).id, 1)
end)

test("a retirement or a regenerate forgets the old farmer's complaints", function()
    local world, relationships = setup()
    relationships.lastComplaints = { [1] = { [2] = 30, [3] = 30 }, [2] = { [2] = 29 } }
    relationships:inheritScores(2, 9)
    assertEquals(relationships:getLastComplaintPeriod(1, 2), nil)
    assertEquals(relationships:getLastComplaintPeriod(2, 2), nil)
    assertEquals(relationships:getLastComplaintPeriod(1, 9), nil, "the successor hasn't complained")

    relationships:forgetMissing({ [1] = {} })
    assertEquals(relationships:getLastComplaintPeriod(1, 3), nil)

    relationships.lastComplaints = { [1] = { [3] = 30 } }
    relationships:reset(1)
    assertEquals(relationships:getLastComplaintPeriod(1, 3), nil, "a new company")
end)

-- Word gets round --------------------------------------------------------------------

test("the neighbours are farmers whose land or yard is near, never the official or the farmer themselves",
    function()
        local world, _, tc = setup()
        local farmers = tc.Farmers:getFarmers()
        local fallen = tc.Farmers:getPerson(2)
        local ids = {}
        for _, neighbour in ipairs(TheContractorFarmers.getNeighbours(farmers, fallen, world.land, world.yards)) do
            table.insert(ids, neighbour.id)
        end
        assertEquals(table.concat(ids, ","), "3,5")

        -- An official in the list with land right there still isn't one.
        local withOfficial = { { id = 1, isOfficial = true, farmlandIds = { 2 } } }
        assertEquals(#TheContractorFarmers.getNeighbours(withOfficial, fallen, world.land, world.yards), 0)
        -- Nobody near a farmer with nothing on the map.
        assertEquals(#TheContractorFarmers.getNeighbours(farmers, { id = 9, farmlandIds = {} }, world.land,
            world.yards), 0)
    end)

test("falling out costs the neighbours and reputation, and the notice names them", function()
    local world, relationships, tc = setup()
    local R = TheContractorRelationships

    relationships:adjust(1, 2, -60, "console")
    assertEquals(relationships:getScore(1, 2), -60, "the farmer themselves only by the change")
    assertEquals(relationships:getScore(1, 3), -R.WORD_RELATIONSHIP)
    assertEquals(relationships:getScore(1, 5), -R.WORD_RELATIONSHIP, "near by their yard")
    assertEquals(relationships:getScore(1, 4), 0, "too far")
    assertEquals(relationships:getScore(1, 1), 0, "never the official")
    assertEquals(relationships:getScore(2, 3), 0, "only with that farm")
    assertEquals(tc.Reputation:getReputationScore(1), 100 - R.WORD_REPUTATION)

    local list = notices(world)
    assertEquals(#list, 1)
    assertEquals(list[1].titleKey, "tc_wordGetsRound_title")
    assertEquals(list[1].bodyKey, "tc_wordGetsRound_body")
    assertEquals(list[1].args[1], "Fallen")
    assertEquals(list[1].args[2], "Near, Yard")
    assertEquals(#complaints(world), 0, "the console never complains")

    -- The clients hear of every score, the reputation and the notice.
    local seen = {}
    for _, event in ipairs(world.events) do
        if event.kind == "relationship" then
            seen["relationship" .. event.customerId] = event.score
        else
            seen[event.kind] = true
        end
    end
    assertEquals(seen.relationship2, -60)
    assertEquals(seen.relationship3, -R.WORD_RELATIONSHIP)
    assertEquals(seen.relationship5, -R.WORD_RELATIONSHIP)
    assertTrue(seen.reputation)
    assertTrue(seen.message)
end)

test("a neighbour falling out from word getting round doesn't spread it further", function()
    local world, relationships, tc = setup()
    local R = TheContractorRelationships
    relationships:adjust(1, 3, R.REFUSES_BELOW + 2)

    relationships:adjust(1, 2, -60)
    assertTrue(relationships:refuses(1, 3), "the neighbour has fallen out too")
    assertEquals(relationships:getScore(1, 2), -60, "not told back about")
    assertEquals(#notices(world), 1)
    assertEquals(tc.Reputation:getReputationScore(1), 100 - R.WORD_REPUTATION, "one knock")
end)

test("word gets round once each time the line is crossed", function()
    local world, relationships, tc = setup()
    local R = TheContractorRelationships
    relationships:adjust(1, 2, -60)
    relationships:adjust(1, 2, -10)
    assertEquals(#notices(world), 1, "already fallen out")

    relationships:adjust(1, 2, 35)
    assertTrue(not relationships:refuses(1, 2))
    relationships:adjust(1, 2, -10)
    assertEquals(#notices(world), 2, "fell out again")
    assertEquals(tc.Reputation:getReputationScore(1), 100 - 2 * R.WORD_REPUTATION)
end)

test("the official falling out has no neighbours, but word still gets round the trade", function()
    local world, relationships, tc = setup()
    relationships:adjust(1, 1, -50)
    local list = notices(world)
    assertEquals(#list, 1)
    assertEquals(list[1].bodyKey, "tc_wordGetsRound_bodyNoNeighbours")
    assertEquals(tc.Reputation:getReputationScore(1), 100 - TheContractorRelationships.WORD_REPUTATION)
    for id = 2, 5 do
        assertEquals(relationships:getScore(1, id), 0)
    end
end)
