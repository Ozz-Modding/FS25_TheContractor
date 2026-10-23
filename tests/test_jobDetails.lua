-- 093: a player-driven job keeps the nickname of the player who allocated
-- it (from the request's connection, or the host's own name), a hired
-- crew's job keeps none, and the name goes to clients and into the save.
-- An older job with no name reads as "A player".

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

    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/business/Allocation.lua")

    -- allocateJob's calls out, apart from the job itself.
    TCFieldPreparation = { prepareFieldForJob = function() end }
    TCJobProgress = { clearJob = function() end }
    TCFieldAccess = { refresh = function() end }
    TCJobSupplies = { topUp = function() end }
    TCHaulage = { startDelivery = function() end }
    TCJobAllocatedEvent = { new = function() return {} end }
    TheContractorWorker = { STATUS = { ASSIGNED = "assigned" }, MAX_SKILL = 10 }
    TCEquipmentClass = {
        isTractor = function() return true end,
        isHarvester = function() return false end,
        isTrailerFor = function() return false end,
    }

    local tc = g_currentMission.TheContractor
    tc.Jobs = TheContractorJobs.new()
    tc.Allocation = TheContractorAllocation.new()
    tc.Allocation.getMissingFromSelection = function() return {} end
    tc.Allocation.isVehicleFree = function() return true end
    tc.Allocation.previewWorkerCapability = function() return TheContractorAllocation.CAPABILITY.CAPABLE end
    tc.Parking = { isPending = function() return false end, sendToShop = function() return {} end }
    world.workers = {}
    tc.Staff = {
        getWorker = function(_, farmId, workerId)
            return world.workers[workerId]
        end,
        setWorkerStatus = function() end,
    }
    tc.Dispatch = { startJobForWorker = function() end }
    return world, tc
end

local function addJob(tc, id)
    local job = TheContractorJob.new(id or 1, 1, "cultivate", 7, 1, 1, 1, 1000)
    job.state = TheContractorJob.STATE.ACCEPTED
    tc.Jobs:registerJob(job, false)
    return job
end

local function addTractor(world)
    return world:addVehicle({ name = "Tractor" })
end

-- A connection with a user behind it, as the server sees a client's.
local function addUser(nickname)
    local connection = {}
    local user = { connection = connection }
    function user:getNickname() return nickname end
    g_currentMission.userManager = g_currentMission.userManager or { users = {} }
    table.insert(g_currentMission.userManager.users, user)
    g_currentMission.userManager.getUserByConnection = function(self, wanted)
        for _, candidate in ipairs(self.users) do
            if candidate.connection == wanted then
                return candidate
            end
        end
        return nil
    end
    return connection
end

-- Who asked ------------------------------------------------------------------

test("the name comes from the requesting connection's user", function()
    setup()
    g_currentMission.playerNickname = "Host"
    local connection = addUser("Farmhand")
    assertEquals(TheContractorAllocation.getConnectionPlayerName(connection), "Farmhand")
end)

test("with no user on the connection, it's the local player's own name", function()
    setup()
    g_currentMission.playerNickname = "Host"
    addUser("Farmhand")
    assertEquals(TheContractorAllocation.getConnectionPlayerName({}), "Host")
    g_currentMission.userManager = nil
    assertEquals(TheContractorAllocation.getConnectionPlayerName(nil), "Host")
end)

test("with no name anywhere, there's none", function()
    setup()
    g_currentMission.playerNickname = ""
    assertEquals(TheContractorAllocation.getConnectionPlayerName(nil), nil)
end)

-- Allocation -------------------------------------------------------------------

test("a player-driven job keeps the name of whoever allocated it", function()
    local world, tc = setup()
    local job = addJob(tc)
    local tractor = addTractor(world)

    assertTrue(tc.Allocation:allocateJob(1, job.id, {}, { tractor.id }, {}, false, "Farmhand"))
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED)
    assertTrue(job:isPlayerDriven())
    assertEquals(job.allocatedPlayerName, "Farmhand")
    assertEquals(job:getPlayerName(), "Farmhand")
end)

test("a hired worker's job keeps no player name", function()
    local world, tc = setup()
    world.workers[4] = { id = 4, isIdle = function() return true end }
    local job = addJob(tc)
    local tractor = addTractor(world)

    assertTrue(tc.Allocation:allocateJob(1, job.id, { 4 }, { tractor.id }, {}, false, "Farmhand"))
    assertEquals(job.assignedWorkerId, 4)
    assertTrue(not job:isPlayerDriven())
    assertEquals(job.allocatedPlayerName, nil)
end)

test("a job with no name recorded reads as a player", function()
    local _, tc = setup()
    local job = addJob(tc)
    assertEquals(job:getPlayerName(), "A player")
    job.allocatedPlayerName = ""
    assertEquals(job:getPlayerName(), "A player")
end)

-- Stream and save ----------------------------------------------------------------

test("the name goes to clients, and no name stays none", function()
    local world, tc = setup()
    local job = addJob(tc, 1)
    job.state = TheContractorJob.STATE.ALLOCATED
    job.allocatedPlayerName = "Farmhand"
    local other = addJob(tc, 2)

    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    TheContractorJobs.writeJob(stream, other)
    assertEquals(TheContractorJobs.readJob(stream).allocatedPlayerName, "Farmhand")
    assertEquals(TheContractorJobs.readJob(stream).allocatedPlayerName, nil)
end)

test("the name survives a save", function()
    local _, tc = setup()
    local job = addJob(tc, 1)
    job.state = TheContractorJob.STATE.ALLOCATED
    job.allocatedPlayerName = "Farmhand"
    addJob(tc, 2)

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local loaded = TheContractorJobs.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getJob(1, 1).allocatedPlayerName, "Farmhand")
    assertEquals(loaded:getJob(1, 2).allocatedPlayerName, nil)
end)
