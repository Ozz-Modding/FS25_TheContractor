-- 076: field access as strict as a vanilla contract (the job's own field,
-- the job's own kind of work), and the grace period after a player-driven
-- job completes: who gets one, the field staying workable through it, the
-- bale clear-up waiting for its end, the countdown on server and client,
-- and the remaining time through the stream and a save.

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
        applyOnCompletion = function() end,
    }
    TCVehicleIds = { saveList = function() end, loadList = function() return {} end }
    WorkAreaType = { CULTIVATOR = 1, SOWINGMACHINE = 2, PLOW = 3, BALER = 4 }
    MissionManager = { getIsMissionWorkAllowed = function() return false end }
    g_currentMission.environment = { currentMonotonicDay = 10, dayTime = 0 }

    -- Field 7: a 100 x 100 m square on farmland 5. Farmland 5 runs on to
    -- x = 200, where there's no field of the job's.
    getWorldTranslation = function(node)
        return node[1], 0, node[2]
    end
    local field = { nodes = { { 0, 0 }, { 100, 0 }, { 100, 100 }, { 0, 100 } } }
    function field:getPolygonPoints() return self.nodes end
    function field:getFarmland() return { id = 5 } end
    g_fieldManager = {
        getFieldById = function(_, fieldId)
            return fieldId == 7 and field or nil
        end,
    }
    g_farmlandManager = {
        getFarmlandIdAtWorldPosition = function(_, x, z)
            return x < 200 and 5 or 6
        end,
    }

    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/util/TCLotInspections.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCJoyriderRuts.lua")
    world:load("src/util/TCSiteClearance.lua")
    world:load("src/util/TCFieldAccess.lua")

    world.clearedUp = {}
    world.clearedAtCompletion = {}
    TCFieldPreparation = {
        clearUpAfterJob = function(job)
            table.insert(world.clearedUp, job.id)
        end,
        clearUpAtCompletion = function(job)
            table.insert(world.clearedAtCompletion, job.id)
        end,
    }

    local tc = g_currentMission.TheContractor
    tc.Jobs = TheContractorJobs.new()
    return world, tc
end

local function addJob(tc, def)
    local job = TheContractorJob.new(def.id or 1, def.farmId or 1, def.jobType or "cultivate", 7, 1, 1, 1, 1000)
    job.state = def.state or TheContractorJob.STATE.ALLOCATED
    job.assignedWorkerId = def.workerId
    job.operationSkill = "tillage"
    tc.Jobs:registerJob(job, false)
    return job
end

-- Through the patched vanilla check, as a work area would ask.
local function canWork(farmId, x, z, workAreaType)
    return MissionManager.getIsMissionWorkAllowed({}, farmId, x, z, workAreaType)
end

-- Access ----------------------------------------------------------------------

test("a job's field can be worked with its own kind of work only", function()
    local world, tc = setup()
    addJob(tc, { jobType = "cultivate" })
    TCFieldAccess.refresh()

    assertTrue(canWork(1, 50, 50, WorkAreaType.CULTIVATOR), "cultivating the field")
    assertTrue(not canWork(1, 50, 50, WorkAreaType.SOWINGMACHINE), "sowing it")
    assertTrue(not canWork(1, 50, 50, WorkAreaType.PLOW), "plowing it")
    assertTrue(canWork(1, 50, 50, nil), "a check with no work type (the AI finding its field)")
end)

test("only the job's field, not the rest of its farmland, and only for its farm", function()
    local world, tc = setup()
    addJob(tc, { jobType = "cultivate" })
    TCFieldAccess.refresh()

    assertTrue(not canWork(1, 150, 50, WorkAreaType.CULTIVATOR), "same farmland, off the field")
    assertTrue(not canWork(1, 250, 50, WorkAreaType.CULTIVATOR), "another farmland")
    assertTrue(not canWork(2, 50, 50, WorkAreaType.CULTIVATOR), "another farm")
end)

test("a job with no ground work allows none, and an offer allows nothing", function()
    local world, tc = setup()
    addJob(tc, { id = 1, jobType = "baleWrap" })
    TCFieldAccess.refresh()
    assertTrue(not canWork(1, 50, 50, WorkAreaType.CULTIVATOR), "bale wrap")

    local _, tc2 = setup()
    addJob(tc2, { id = 1, jobType = "cultivate", state = TheContractorJob.STATE.ACCEPTED })
    TCFieldAccess.refresh()
    assertTrue(not canWork(1, 50, 50, WorkAreaType.CULTIVATOR), "accepted but not allocated")
end)

test("a completed job's field is workable only while it's in its grace period", function()
    local world, tc = setup()
    local job = addJob(tc, { jobType = "cultivate", state = TheContractorJob.STATE.COMPLETED })
    TCFieldAccess.refresh()
    assertTrue(not canWork(1, 50, 50, WorkAreaType.CULTIVATOR), "no grace period")

    job.graceRemainingMs = 1000
    TCFieldAccess.refresh()
    assertTrue(canWork(1, 50, 50, WorkAreaType.CULTIVATOR), "in its grace period")
    assertTrue(not canWork(1, 50, 50, WorkAreaType.SOWINGMACHINE), "still its own work only")
end)

-- Other mods patching the same check ----------------------------------------

test("a mod that replaces the check without calling ours is wrapped again at mission start", function()
    local world, tc = setup()
    addJob(tc, { jobType = "cultivate" })
    TCFieldAccess.refresh()

    -- FS25_ContractBoost's overwrite, which never calls the function it replaced.
    MissionManager.getIsMissionWorkAllowed = function() return false end
    assertTrue(not canWork(1, 50, 50, WorkAreaType.CULTIVATOR), "ours thrown away")

    TCFieldAccess.install()
    assertTrue(canWork(1, 50, 50, WorkAreaType.CULTIVATOR), "ours back on top")
    assertTrue(not canWork(1, 50, 50, WorkAreaType.SOWINGMACHINE), "still its own work only")
end)

test("installing again over a mod that calls through to ours neither loops nor stacks", function()
    local world, tc = setup()
    addJob(tc, { jobType = "cultivate" })
    TCFieldAccess.refresh()

    local calls = 0
    local ours = MissionManager.getIsMissionWorkAllowed
    MissionManager.getIsMissionWorkAllowed = function(...)
        calls = calls + 1
        return ours(...)
    end
    TCFieldAccess.install()
    local installed = MissionManager.getIsMissionWorkAllowed
    TCFieldAccess.install()
    assertEquals(MissionManager.getIsMissionWorkAllowed, installed, "a second install with ours on top is a no-op")

    assertTrue(canWork(1, 50, 50, WorkAreaType.CULTIVATOR))
    assertEquals(calls, 1)
end)

-- Who gets one --------------------------------------------------------------

test("only a player-driven job with equipment gets a grace period", function()
    local world, tc = setup()
    assertTrue(TheContractorJobs.getsGracePeriod(addJob(tc, { id = 1, jobType = "cultivate" })), "player cultivate")
    assertTrue(TheContractorJobs.getsGracePeriod(addJob(tc, { id = 2, jobType = "bale" })), "player bale")
    assertTrue(not TheContractorJobs.getsGracePeriod(addJob(tc, { id = 3, jobType = "cultivate", workerId = 4 })),
        "hired worker")
    assertTrue(not TheContractorJobs.getsGracePeriod(addJob(tc, { id = 4, jobType = "strawDelivery" })),
        "straw delivery")
    assertTrue(not TheContractorJobs.getsGracePeriod(addJob(tc, { id = 5, jobType = "flyTipping" })), "fly-tipping")
end)

-- Completion ----------------------------------------------------------------

-- completeJob with everything it calls out to faked, apart from the grace
-- period and the clear-up.
local function fakeCompletion(world, tc)
    tc.Finances = { invoiceJob = function() end }
    tc.Reputation = { addReputation = function() end }
    world:addRelationships()
    tc.Claims = { rollForJob = function() end }
    tc.Inbox = { removeMessagesForJob = function() end }
    tc.Dispatch = { stopJob = function() end }
    tc.Cooldown = { startCooldown = function() end }
    tc.Logbook = { recordJobCompleted = function() end }
    tc.Staff = { applyGrowthFromJob = function() end }
    tc.RandomEvents = { onJobCompleted = function() end }
    TCJobProgress = { clearJob = function() end }
    TCHaulage = { stopDelivery = function() end, emptyHarvestersAfterJob = function() end }
    TCJobCompletedEvent = { showNotification = function() end }
    AIMessageSuccessFinishedJob = { new = function() return {} end }
    tc.Jobs.calculateReputationReward = function() return 1 end
    tc.Jobs.calculateQualityScore = function() return 100 end
end

test("a player-driven job's bales go at completion and again when its grace period ends", function()
    local world, tc = setup()
    fakeCompletion(world, tc)
    local job = addJob(tc, { jobType = "bale" })
    job.completionPercentage = 100

    tc.Jobs:completeJob(job)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(job.graceRemainingMs, TheContractorJobs.GRACE_PERIOD_MS)
    assertEquals(world.clearedAtCompletion[1], job.id, "the bales so far, at completion")
    assertEquals(#world.clearedUp, 0, "the full clear-up waits")

    tc.Jobs:updateGracePeriods(TheContractorJobs.GRACE_PERIOD_MS - 1)
    assertEquals(#world.clearedUp, 0, "a moment left")
    assertTrue(job.graceRemainingMs ~= nil)

    tc.Jobs:updateGracePeriods(1)
    assertEquals(job.graceRemainingMs, nil, "over")
    assertEquals(#world.clearedUp, 1, "cleared up once")
    assertEquals(world.clearedUp[1], job.id)

    tc.Jobs:updateGracePeriods(1000)
    assertEquals(#world.clearedUp, 1, "and only once")
end)

test("a hired worker's job is cleared up straight away, with no grace period", function()
    local world, tc = setup()
    fakeCompletion(world, tc)
    local job = addJob(tc, { jobType = "bale", workerId = 3, state = TheContractorJob.STATE.IN_PROGRESS })
    job.completionPercentage = 100

    tc.Jobs:completeJob(job)
    assertEquals(job.graceRemainingMs, nil)
    assertEquals(#world.clearedUp, 1)
    assertEquals(#world.clearedAtCompletion, 0, "the full clear-up covers it")
end)

test("a client counts down its own copy but never clears up", function()
    local world, tc = setup()
    g_currentMission.getIsServer = function() return false end
    local job = addJob(tc, { jobType = "cultivate", state = TheContractorJob.STATE.COMPLETED })
    job.graceRemainingMs = 500
    tc.Jobs:registerJob(job, false)

    tc.Jobs:update(600)
    assertEquals(job.graceRemainingMs, nil)
    assertEquals(#world.clearedUp, 0)
end)

-- Stream and save -----------------------------------------------------------

test("the time left goes to clients, and a snapshot without one clears it", function()
    local world, tc = setup()
    local job = addJob(tc, { jobType = "cultivate", state = TheContractorJob.STATE.COMPLETED })
    job.graceRemainingMs = 1234

    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    local copy = TheContractorJobs.readJob(stream)
    assertEquals(copy.graceRemainingMs, 1234)

    tc.Jobs:registerJob(copy, false)
    assertEquals(tc.Jobs.graceJobs[job.id], copy, "the countdown follows the new copy")

    job.graceRemainingMs = nil
    stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    local cleared = TheContractorJobs.readJob(stream)
    assertEquals(cleared.graceRemainingMs, nil)
    tc.Jobs:registerJob(cleared, false)
    assertEquals(tc.Jobs.graceJobs[job.id], nil)
end)

test("the time left survives a save and keeps counting after loading", function()
    local world, tc = setup()
    local job = addJob(tc, { jobType = "bale", state = TheContractorJob.STATE.COMPLETED })
    job.graceRemainingMs = 4000
    addJob(tc, { id = 2, jobType = "cultivate", state = TheContractorJob.STATE.COMPLETED })

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)

    local loaded = TheContractorJobs.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getJob(1, 1).graceRemainingMs, 4000)
    assertEquals(loaded:getJob(1, 2).graceRemainingMs, nil)

    loaded:updateGracePeriods(4000)
    assertEquals(loaded:getJob(1, 1).graceRemainingMs, nil)
    assertEquals(#world.clearedUp, 1)
end)
