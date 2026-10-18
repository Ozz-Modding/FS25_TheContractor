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
