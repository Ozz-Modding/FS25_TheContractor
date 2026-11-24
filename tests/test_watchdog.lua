-- Stuck watchdog (021): a hired worker's stone picker standing full,
-- waiting to be emptied as vanilla's AI does, isn't stuck.

local function setup()
    local world = stubs.install()
    TCJobProgress = { POLL_INTERVAL_MS = 3000 }
    TheContractorJob = { STATE = { IN_PROGRESS = "in_progress" } }
    world:load("src/business/Watchdog.lua")

    world.jobs = {}
    g_currentMission.TheContractor = {
        Jobs = {
            getJobsByState = function(_, farmId, state)
                local jobs = {}
                for _, job in ipairs(world.jobs) do
                    if job.farmId == farmId and state == TheContractorJob.STATE.IN_PROGRESS then
                        table.insert(jobs, job)
                    end
                end
                return jobs
            end,
        },
    }
    return world
end

local function addJob(world, vehicles)
    local job = {
        id = #world.jobs + 1,
        farmId = 1,
        assignedWorkerId = 1,
        assignedEquipmentIds = {},
        completionPercentage = 40,
        isWaitingForSupplies = function() return false end,
    }
    for _, vehicle in ipairs(vehicles) do
        table.insert(job.assignedEquipmentIds, vehicle.id)
    end
    table.insert(world.jobs, job)
    return job
end

-- A stone picker whose own fill unit (the second here, as a config can
-- set) holds `level`.
local function addStonePicker(world, level)
    local picker = world:addVehicle({ name = "Picker", fillUnits = {
        { capacity = 100, level = 100 },
        { capacity = 4000, level = level },
    } })
    picker.spec_stonePicker = { fillUnitIndex = 2 }
    return picker
end

test("a full stone picker is waiting to be emptied, not one with room", function()
    local world = setup()
    local full = addJob(world, { addStonePicker(world, 4000) })
    local partFull = addJob(world, { addStonePicker(world, 3999) })
    assertTrue(TheContractorWatchdog.isWaitingToBeEmptied(full), "full")
    assertTrue(not TheContractorWatchdog.isWaitingToBeEmptied(partFull), "room left")
end)

test("another machine's full tank isn't waiting to be emptied", function()
    local world = setup()
    local seeder = world:addVehicle({ name = "Seeder", fillUnits = { { capacity = 1000, level = 1000 } } })
    local job = addJob(world, { seeder })
    assertTrue(not TheContractorWatchdog.isWaitingToBeEmptied(job), "topped-up seeder")
end)

test("the watchdog leaves a full stone picker's job alone and starts afresh once it's emptied", function()
    local world = setup()
    local picker = addStonePicker(world, 3000)
    local job = addJob(world, { picker })
    local watchdog = TheContractorWatchdog.new()

    -- No progress for all but the last check before the timeout.
    local checksToTimeout = TheContractorWatchdog.STUCK_TIMEOUT_MINUTES * 60000 /
        TheContractorWatchdog.CHECK_INTERVAL_MS
    for _ = 1, checksToTimeout - 1 do
        watchdog:checkActiveJobs()
    end
    assertTrue(watchdog.trackedByJobId[job.id] ~= nil, "tracked while picking")

    picker.fillUnits[2].level = 4000
    watchdog:checkActiveJobs()
    assertEquals(watchdog.trackedByJobId[job.id], nil, "not tracked while full")

    picker.fillUnits[2].level = 0
    watchdog:checkActiveJobs()
    local entry = watchdog.trackedByJobId[job.id]
    assertEquals(entry.elapsedStuckMs, TheContractorWatchdog.CHECK_INTERVAL_MS, "fresh grace period")
    assertEquals(entry.retryCount, 0, "never reset")
end)

