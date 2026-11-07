-- HUD progress bars for jobs: which jobs get one (allocated or in progress,
-- never a workshop job; by default to a player only, all jobs or none by
-- the local jobProgressBars setting), the progress they show, bars coming
-- and going as jobs move on, marked for drawing every frame, and nothing
-- for other farms or a spectator.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TheContractorJobGeneration = {
        JOB_TYPES = { cultivate = {}, harvest = {}, strawDelivery = { deliveryOnly = true } },
        getTypeLabel = function(jobType) return jobType end,
        getFruitTypeIndexByName = function() return nil end,
    }
    FarmManager.SPECTATOR_FARM_ID = 0
    math.clamp = math.clamp or function(value, low, high)
        return math.min(math.max(value, low), high)
    end
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    g_currentModSettingsDirectory = nil
    world:load("src/business/Job.lua")
    world:load("src/util/TCJobHud.lua")
    world:load("src/business/Settings.lua")
    g_currentMission.TheContractor.Settings = TheContractorSettings.new()

    g_fieldManager = {
        getFieldById = function(_, fieldId)
            return { getName = function() return tostring(fieldId) end }
        end,
    }

    -- Vanilla's side notification progress bars, as SideNotification keeps
    -- them.
    world.bars = {}
    world.marked = {}
    g_currentMission.hud = {
        addSideNotificationProgressBar = function(_, title, text, progress)
            local bar = { title = title, text = text, progress = progress }
            table.insert(world.bars, bar)
            return bar
        end,
        removeSideNotificationProgressBar = function(_, bar)
            for i, shown in ipairs(world.bars) do
                if shown == bar then
                    table.remove(world.bars, i)
                    return
                end
            end
        end,
        markSideNotificationProgressBarForDrawing = function(_, bar)
            world.marked[bar] = true
        end,
    }

    world.jobs = {}
    g_currentMission.TheContractor.Jobs = {
        getAllJobs = function(_, farmId)
            local result = {}
            for _, job in ipairs(world.jobs) do
                if job.farmId == farmId then
                    table.insert(result, job)
                end
            end
            return result
        end,
    }

    -- def: { jobType, state, farmId, workerId }
    function world:addJob(def)
        local job = TheContractorJob.new(#self.jobs + 1, def.farmId or 1, def.jobType or "cultivate", 1, 3, 1, 1, 1000)
        job.state = def.state or TheContractorJob.STATE.ALLOCATED
        job.assignedWorkerId = def.workerId
        table.insert(self.jobs, job)
        return job
    end

    TCJobHud.reset()
    return world
end

local function barJobIds()
    local ids = {}
    for jobId in pairs(TCJobHud.barsByJobId) do
        table.insert(ids, jobId)
    end
    table.sort(ids)
    return ids
end

test("an allocated or in-progress player job gets a bar, a hired crew's doesn't", function()
    local world = setup()
    world:addJob({ state = TheContractorJob.STATE.ALLOCATED })
    world:addJob({ state = TheContractorJob.STATE.IN_PROGRESS })
    world:addJob({ state = TheContractorJob.STATE.ALLOCATED, workerId = 7 })
    world:addJob({ state = TheContractorJob.STATE.ACCEPTED })
    world:addJob({ state = TheContractorJob.STATE.COMPLETED })
    TCJobHud.refresh()

    local ids = barJobIds()
    assertEquals(#ids, 2, "bars")
    assertEquals(ids[1], 1)
    assertEquals(ids[2], 2)
    assertEquals(#world.bars, 2, "bars on the HUD")
end)

test("a two-worker haulage job's player half doesn't count as a player job", function()
    local world = setup()
    local job = world:addJob({})
    job.haulerWorkerId = 4
    TCJobHud.refresh()
    assertEquals(#world.bars, 0, "bars")
end)

test("a workshop job never gets one", function()
    local world = setup()
    world:addJob({}).workshop = { vehicleName = "Tractor" }
    TCJobHud.refresh()
    assertEquals(#world.bars, 0, "bars")
end)

test("the bar follows the job's completion, and is marked for drawing every frame", function()
    local world = setup()
    local job = world:addJob({})
    job.completionPercentage = 25
    TCJobHud.update(TCJobHud.CHECK_INTERVAL_MS)
    local bar = world.bars[1]
    assertNear(bar.progress, 0.25, 1e-9, "progress")
    assertTrue(world.marked[bar], "marked")

    world.marked = {}
    job.completionPercentage = 60
    TCJobHud.update(16)
    assertNear(bar.progress, 0.6, 1e-9, "progress next frame")
    assertTrue(world.marked[bar], "marked next frame")
end)

test("player haulage counts the delivery as half; a delivery-only job is its completion", function()
    local world = setup()
    local haul = world:addJob({ jobType = "harvest" })
    haul.includesHaulage = true
    haul.requiredLiters = 1000
    haul.deliveredLiters = 500
    haul.completionPercentage = 100
    assertNear(TCJobHud.getProgress(haul), 0.75, 1e-9, "cut, half delivered")

    haul.deliveredLiters = 1000
    assertNear(TCJobHud.getProgress(haul), 1, 1e-9, "cut and delivered")

    local straw = world:addJob({ jobType = "strawDelivery" })
    straw.includesHaulage = true
    straw.requiredLiters = 1000
    straw.deliveredLiters = 400
    straw.completionPercentage = 40
    assertNear(TCJobHud.getProgress(straw), 0.4, 1e-9, "delivery only")
end)

test("the bar goes when the job's completed, missed or handed to a worker", function()
    local world = setup()
    local job = world:addJob({})
    local other = world:addJob({})
    local third = world:addJob({})
    TCJobHud.refresh()
    assertEquals(#world.bars, 3, "bars")

    job.state = TheContractorJob.STATE.COMPLETED
    other.state = TheContractorJob.STATE.MISSED
    third.assignedWorkerId = 5
    TCJobHud.refresh()
    assertEquals(#world.bars, 0, "bars after")
    assertEquals(#barJobIds(), 0, "tracked after")
end)

test("only the local farm's jobs, and nothing for a spectator", function()
    local world = setup()
    world:addJob({ farmId = 1 })
    world:addJob({ farmId = 2 })
    TCJobHud.refresh()
    local ids = barJobIds()
    assertEquals(#ids, 1, "bars")
    assertEquals(ids[1], 1, "farm 1's job")

    function g_currentMission:getFarmId() return 0 end
    TCJobHud.refresh()
    assertEquals(#world.bars, 0, "a spectator")
end)

test("refreshed once a second, and reset clears every bar", function()
    local world = setup()
    world:addJob({})
    TCJobHud.update(500)
    assertEquals(#world.bars, 0, "before a second")

    TCJobHud.update(500)
    assertEquals(#world.bars, 1, "after a second")

    TCJobHud.reset()
    assertEquals(#world.bars, 0, "after reset")
end)

local function setMode(key)
    g_currentMission.TheContractor.Settings:setLocal("jobProgressBars", TheContractorSettings.JOB_PROGRESS_BARS[key])
end

test("the setting defaults to player only", function()
    setup()
    assertEquals(TCJobHud.getMode(), TheContractorSettings.JOB_PROGRESS_BARS.PLAYER_ONLY)
    assertTrue(TheContractorSettings.isLocalItem("jobProgressBars"), "a local item")
end)

test("all shows a hired crew's allocated and started jobs too, never a workshop job", function()
    local world = setup()
    world:addJob({ state = TheContractorJob.STATE.ALLOCATED })
    world:addJob({ state = TheContractorJob.STATE.ALLOCATED, workerId = 7 })
    world:addJob({ state = TheContractorJob.STATE.IN_PROGRESS, workerId = 8 })
    world:addJob({ state = TheContractorJob.STATE.ACCEPTED })
    world:addJob({ state = TheContractorJob.STATE.COMPLETED, workerId = 9 })
    world:addJob({}).workshop = { vehicleName = "Tractor" }
    setMode("ALL")

    local ids = barJobIds()
    assertEquals(#ids, 3, "bars")
    assertEquals(ids[1], 1)
    assertEquals(ids[2], 2)
    assertEquals(ids[3], 3)
end)

test("none shows no bars, and changing the setting adds and removes them at once", function()
    local world = setup()
    world:addJob({})
    world:addJob({ workerId = 7 })
    TCJobHud.refresh()
    assertEquals(#world.bars, 1, "player only")

    setMode("NONE")
    assertEquals(#world.bars, 0, "none")

    setMode("ALL")
    assertEquals(#world.bars, 2, "all")

    setMode("PLAYER_ONLY")
    assertEquals(#world.bars, 1, "player only again")
end)
