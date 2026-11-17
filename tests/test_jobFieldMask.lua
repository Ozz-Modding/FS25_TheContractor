-- A live job's field goes on vanilla's mission map, as a started vanilla
-- contract's does, so crops don't grow and Precision Farming leaves no
-- tramlines there while it's worked: which jobs count, one paint per field,
-- cleared when the job's over, and nothing on a client or a map with
-- contracts off.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TheContractorJobGeneration = {
        JOB_TYPES = {
            sow = { workAreaTypes = { "SOWINGMACHINE" } },
            spillRecovery = {},
        },
    }
    world:load("src/business/Job.lua")
    MissionManager = {}
    world:load("src/util/TCFieldAccess.lua")
    world:load("src/util/TCJobFieldMask.lua")
    TCJobFieldMask.reset()
    g_server = {}

    world.farms = { { farmId = 1 }, { farmId = 2 } }

    world.fields = {}
    g_fieldManager = {
        getFieldById = function(_, fieldId)
            return world.fields[fieldId]
        end,
    }
    for fieldId = 1, 5 do
        world.fields[fieldId] = {
            getDensityMapPolygon = function()
                return { fieldId = fieldId }
            end,
        }
    end

    -- fieldId -> the value last painted, and every paint in order.
    world.mapValues = {}
    world.paints = {}
    g_missionManager = {
        missionMap = {},
        missionMapNumChannels = 4,
        setMissionMapActiveMissionId = function(_, polygon, value)
            world.mapValues[polygon.fieldId] = value
            table.insert(world.paints, { fieldId = polygon.fieldId, value = value })
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

    -- def: { fieldId, state, farmId, jobType }
    function world:addJob(def)
        local job = TheContractorJob.new(#self.jobs + 1, def.farmId or 1, def.jobType or "sow", def.fieldId or 1, 3,
            1, 1, 1000)
        job.state = def.state or TheContractorJob.STATE.ALLOCATED
        table.insert(self.jobs, job)
        return job
    end

    -- fieldId -> true for every field the map holds a non-zero value on.
    function world:maskedFields()
        local fieldIds, count = {}, 0
        for fieldId, value in pairs(self.mapValues) do
            if value ~= 0 then
                fieldIds[fieldId] = true
                count = count + 1
            end
        end
        return fieldIds, count
    end

    return world
end

test("allocated, in progress and in its grace period are masked; offers, accepted and finished aren't", function()
    local world = setup()
    world:addJob({ fieldId = 1, state = TheContractorJob.STATE.ALLOCATED })
    world:addJob({ fieldId = 2, state = TheContractorJob.STATE.IN_PROGRESS })
    world:addJob({ fieldId = 3, state = TheContractorJob.STATE.COMPLETED }).graceRemainingMs = 1000
    world:addJob({ fieldId = 4, state = TheContractorJob.STATE.ACCEPTED })
    world:addJob({ fieldId = 5, state = TheContractorJob.STATE.OFFERED })
    TCJobFieldMask.refresh()

    local masked, count = world:maskedFields()
    assertTrue(masked[1] and masked[2] and masked[3], "allocated, in progress, grace")
    assertEquals(count, 3, "masked fields")
end)

test("the painted value is non-zero and fits the map's channels", function()
    local world = setup()
    world:addJob({ fieldId = 1 })
    TCJobFieldMask.refresh()
    assertEquals(world.mapValues[1], 15, "value")
end)

test("a job unallocated part-way stays masked while it waits", function()
    local world = setup()
    local job = world:addJob({ fieldId = 1 })
    TCJobFieldMask.refresh()

    job.state = TheContractorJob.STATE.ACCEPTED
    job.wasUnallocated = true
    TCJobFieldMask.refresh()
    local masked = world:maskedFields()
    assertTrue(masked[1], "still masked")
end)

test("the field is cleared when its job ends, whichever way", function()
    local world = setup()
    local completed = world:addJob({ fieldId = 1 })
    local missed = world:addJob({ fieldId = 2 })
    world:addJob({ fieldId = 3 })
    TCJobFieldMask.refresh()

    completed.state = TheContractorJob.STATE.COMPLETED
    missed.state = TheContractorJob.STATE.MISSED
    table.remove(world.jobs, 3)
    TCJobFieldMask.refresh()

    local _, count = world:maskedFields()
    assertEquals(count, 0, "masked fields")
    assertEquals(world.mapValues[1], 0, "completed")
    assertEquals(world.mapValues[2], 0, "missed")
    assertEquals(world.mapValues[3], 0, "removed")
end)

test("a field with two live jobs is painted once and kept while either is live", function()
    local world = setup()
    local first = world:addJob({ fieldId = 1, farmId = 1 })
    world:addJob({ fieldId = 1, farmId = 2 })
    TCJobFieldMask.refresh()
    TCJobFieldMask.refresh()
    assertEquals(#world.paints, 1, "paints")

    first.state = TheContractorJob.STATE.COMPLETED
    TCJobFieldMask.refresh()
    local masked = world:maskedFields()
    assertTrue(masked[1], "the other farm's job still holds it")
    assertEquals(#world.paints, 1, "no repaint")
end)

test("a job with no ground work, or no field, isn't masked", function()
    local world = setup()
    world:addJob({ fieldId = 1, jobType = "spillRecovery" })
    world:addJob({ fieldId = 0 })
    world:addJob({ fieldId = 9 })
    TCJobFieldMask.refresh()

    local _, count = world:maskedFields()
    assertEquals(count, 0, "masked fields")
end)

test("nothing on a client, or on a map with contracts off", function()
    local world = setup()
    world:addJob({ fieldId = 1 })
    g_server = nil
    TCJobFieldMask.refresh()
    assertEquals(#world.paints, 0, "client")

    g_server = {}
    g_missionManager.missionMap = nil
    TCJobFieldMask.refresh()
    assertEquals(#world.paints, 0, "no mission map")
end)

test("refreshed once a second, and painted again after a reset (a load)", function()
    local world = setup()
    world:addJob({ fieldId = 1 })
    TCJobFieldMask.update(500)
    assertEquals(#world.paints, 0, "before a second")

    TCJobFieldMask.update(500)
    assertEquals(#world.paints, 1, "after a second")

    TCJobFieldMask.reset()
    TCJobFieldMask.refresh()
    assertEquals(#world.paints, 2, "painted again")
end)
