-- TCJobProgress's cadence (019): a field scan reads one partition per call,
-- so it moves on every frame, the way vanilla's missions do every tick -
-- a big field's progress shouldn't take minutes to come round. Jobs that
-- count objects instead (bale wrap) are only refreshed on the poll.

local function setup()
    local world = stubs.install()
    TheContractorNegotiation = {
        rollInitialEagerness = function()
            return 1
        end,
    }
    world:load("src/business/Job.lua")
    world:load("src/business/JobGeneration.lua")
    TCFieldPreparation = { isPreparing = function() return false end }
    world:load("src/util/TCJobProgress.lua")

    world.farms = { { farmId = 1 } }
    world.jobs = {}
    g_currentMission.TheContractor.Jobs = {
        getAllJobs = function()
            return world.jobs
        end,
    }

    -- A field split into partitions; every partition is done or not, and
    -- each executeGet reads whichever partition the clip region was set to.
    world.partitionDone = {}
    world.reads = 0
    local modifier = {}
    function modifier:setPolygonClipRegion(minZ) self.partition = minZ + 1 end
    function modifier:getPolygonMinMaxZ() return 0, 40 end
    function modifier:executeGet()
        world.reads = world.reads + 1
        local done = world.partitionDone[self.partition] and 100 or 0
        return done, done, 100
    end
    DensityMapModifier = { new = function() return modifier end }
    DensityMapFilter = { new = function() return { setValueCompareParams = function() end } end }
    DensityValueCompareType = { BETWEEN = 1, EQUAL = 2 }
    FieldGroundType = { getValueByType = function() return 1 end }
    FieldDensityMap = { GROUND_TYPE = 1 }
    g_terrainNode = 1
    g_currentMission.fieldGroundSystem = { getDensityMapData = function() return 1, 0, 4 end }
    AbstractMission = { SUCCESS_FACTOR = 1 }
    MathUtil = MathUtil or {}
    MathUtil.haToSqm = function(ha) return ha * 10000 end
    local field = {
        getDensityMapPolygon = function() return { applyToModifier = function() end } end,
        -- 10 ha: 40 partitions of 2500 m2.
        getAreaHa = function() return 10 end,
    }
    g_fieldManager = { getFieldById = function() return field end }
    return world
end

local function addJob(world, jobType)
    local job = TheContractorJob.new(#world.jobs + 1, 1, jobType, 1, 1, 1, 1, 1000)
    job.state = TheContractorJob.STATE.IN_PROGRESS
    table.insert(world.jobs, job)
    return job
end

test("a field scan goes round a 10 ha field in 40 frames, not 40 polls", function()
    local world = setup()
    local job = addJob(world, "cultivate")
    for i = 1, 40 do
        world.partitionDone[i] = i <= 10
    end

    TCJobProgress.update(TCJobProgress.POLL_INTERVAL_MS)
    for _ = 1, 39 do
        TCJobProgress.update(16)
    end
    assertEquals(world.reads, 40, "one partition per frame")
    assertNear(job.completionPercentage, 25, 1e-9)

    -- From then on each frame's read updates the total straight away.
    for i = 1, 40 do
        world.partitionDone[i] = true
    end
    for _ = 1, 40 do
        TCJobProgress.update(16)
    end
    assertNear(job.completionPercentage, 100, 1e-9)
end)

test("a job that's finished since the last poll isn't scanned any more", function()
    local world = setup()
    local job = addJob(world, "cultivate")
    TCJobProgress.update(TCJobProgress.POLL_INTERVAL_MS)
    local reads = world.reads
    job.state = TheContractorJob.STATE.COMPLETED
    job.completionPercentage = 97
    TCJobProgress.update(16)
    assertEquals(world.reads, reads)
    assertEquals(job.completionPercentage, 97)
end)

test("a job that counts objects is only refreshed on the poll", function()
    local world = setup()
    local job = addJob(world, "baleWrap")
    job.workTotal = 2
    job.spawnedBaleIds = { "a", "b" }
    local lookups = 0
    g_currentMission.itemSystem = {
        getItemByUniqueId = function()
            lookups = lookups + 1
            return { wrappingState = 1, getIsMounted = function() return false end }
        end,
    }
    TCJobProgress.update(TCJobProgress.POLL_INTERVAL_MS)
    assertEquals(lookups, 2)
    assertEquals(job.completionPercentage, 100)
    TCJobProgress.update(16)
    TCJobProgress.update(16)
    assertEquals(lookups, 2, "not every frame")
end)

-- The fieldWorkDone setting: the share of the field that counts as all of
-- it, so a field worked to the setting reads 100%.
local function scanWholeField(world, job)
    TCJobProgress.update(TCJobProgress.POLL_INTERVAL_MS)
    for _ = 1, 39 do
        TCJobProgress.update(16)
    end
    return job.completionPercentage
end

local function installSettings(world, fieldWorkDone)
    -- Settings.lua reads vanilla's on/off texts as it loads.
    local getText = g_i18n.getText
    g_i18n.getText = function(i18n, key)
        if key == "ui_on" or key == "ui_off" then
            return key
        end
        return getText(i18n, key)
    end
    world:load("src/business/Settings.lua")
    g_i18n.getText = getText
    local settings = TheContractorSettings.new()
    if fieldWorkDone ~= nil then
        settings:set("fieldWorkDone", fieldWorkDone)
    end
    g_currentMission.TheContractor.Settings = settings
    return settings
end

test("by default a field counts as done at vanilla's 98%", function()
    local world = setup()
    local settings = installSettings(world)
    assertEquals(settings:get("fieldWorkDone"), 98)
    local job = addJob(world, "cultivate")
    for i = 1, 40 do
        world.partitionDone[i] = i <= 20
    end
    assertNear(scanWholeField(world, job), 50 / 0.98, 1e-6)
end)

test("a lower fieldWorkDone finishes the field sooner", function()
    local world = setup()
    installSettings(world, 80)
    local job = addJob(world, "cultivate")
    for i = 1, 40 do
        world.partitionDone[i] = i <= 32
    end
    assertNear(scanWholeField(world, job), 100, 1e-6)
end)

test("fieldWorkDone never goes past what the options offer", function()
    local world = setup()
    local settings = installSettings(world, 100)
    assertEquals(settings:get("fieldWorkDone"), 98, "100% isn't reachable, so the nearest option")
    settings:set("fieldWorkDone", 50)
    assertEquals(settings:get("fieldWorkDone"), 75)
end)

test("a job that counts objects ignores fieldWorkDone", function()
    local world = setup()
    installSettings(world, 75)
    local job = addJob(world, "baleWrap")
    job.workTotal = 4
    job.spawnedBaleIds = { "a", "b", "c", "d" }
    local states = { a = 1, b = 1, c = 1, d = 0 }
    g_currentMission.itemSystem = {
        getItemByUniqueId = function(_, id)
            return { wrappingState = states[id], getIsMounted = function() return false end }
        end,
    }
    TCJobProgress.update(TCJobProgress.POLL_INTERVAL_MS)
    assertTrue(job.completionPercentage < 100, "three of four bales isn't done")
end)

-- Reported: a fertilize job's progress jumped between 0 and 100% with
-- nothing done, then completed. The field's bands are whole rows, so on a
-- shallow field rounding each one up used the rows up early; the bands
-- after that were empty, and an empty band read the whole field as done.
-- Here a field 30 rows deep is split for 40 bands' worth of area.
local function shallowField(world, rowsDone)
    local modifier = {}
    function modifier:setPolygonClipRegion(minZ, maxZ) self.minZ, self.maxZ = minZ, maxZ end
    function modifier:getPolygonMinMaxZ() return 0, 30 end
    function modifier:executeGet()
        world.reads = world.reads + 1
        local total, done = 0, 0
        for row = self.minZ + 1, self.maxZ do
            total = total + 100
            if row <= rowsDone then
                done = done + 100
            end
        end
        return done, done, total
    end
    DensityMapModifier = { new = function() return modifier end }
end

test("a shallow field never reads as done with nothing done", function()
    local world = setup()
    shallowField(world, 0)
    local job = addJob(world, "fertilize")
    job.startState = 0

    local highest = 0
    TCJobProgress.update(TCJobProgress.POLL_INTERVAL_MS)
    for _ = 1, 80 do
        TCJobProgress.update(16)
        highest = math.max(highest, job.completionPercentage)
    end
    assertEquals(highest, 0)
end)

test("a shallow field's progress is the share of it done", function()
    local world = setup()
    shallowField(world, 15)
    local job = addJob(world, "fertilize")
    job.startState = 0

    TCJobProgress.update(TCJobProgress.POLL_INTERVAL_MS)
    for _ = 1, 80 do
        TCJobProgress.update(16)
    end
    assertNear(job.completionPercentage, 50, 1e-9)
end)
