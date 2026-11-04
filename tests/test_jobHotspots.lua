-- 088: the flashing map marker on the field of every job the local farm has
-- allocated or in progress, or accepted and due this month - which jobs get one, one per field,
-- markers coming and going as jobs move on and the month turns, and
-- nothing for other farms or a spectator.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TheContractorJobGeneration = { JOB_TYPES = {} }
    FarmManager.SPECTATOR_FARM_ID = 0
    world:load("src/business/Job.lua")
    world:load("src/util/TCJobHotspots.lua")
    TCJobHotspots.reset()

    -- Day 22 of a 10-day month on day 5, so the month ends on day 27.
    g_currentMission.environment = { currentMonotonicDay = 22, daysPerPeriod = 10, currentDayInPeriod = 5 }

    world.fields = {}
    g_fieldManager = {
        getFieldById = function(_, fieldId)
            return world.fields[fieldId]
        end,
    }
    for fieldId = 1, 5 do
        world.fields[fieldId] = { id = fieldId }
    end

    -- Vanilla's contract circle, recording the field it was put on.
    world.shown = {}
    AbstractFieldMissionHotspot = {
        new = function()
            local hotspot = {}
            function hotspot:setField(field) self.field = field end
            function hotspot:delete() self.deleted = true end
            return hotspot
        end,
    }
    g_currentMission.hud = {}
    function g_currentMission:addMapHotspot(hotspot)
        world.shown[hotspot] = true
    end
    function g_currentMission:removeMapHotspot(hotspot)
        world.shown[hotspot] = nil
    end

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

    -- def: { fieldId, deadlineDay, state, farmId }
    function world:addJob(def)
        local job = TheContractorJob.new(#self.jobs + 1, def.farmId or 1, "cultivate", def.fieldId or 1, 3, 1, 1, 1000)
        job.state = def.state or TheContractorJob.STATE.ACCEPTED
        job.deadlineDay = def.deadlineDay or 25
        table.insert(self.jobs, job)
        return job
    end

    -- fieldId -> true for every field with a marker on the map.
    function world:markedFields()
        local fieldIds, count = {}, 0
        for hotspot in pairs(self.shown) do
            fieldIds[hotspot.field.id] = true
            count = count + 1
        end
        return fieldIds, count
    end

    return world
end

test("a taken-on job due this month is marked, offers and finished jobs aren't", function()
    local world = setup()
    world:addJob({ fieldId = 1, state = TheContractorJob.STATE.ACCEPTED })
    world:addJob({ fieldId = 2, state = TheContractorJob.STATE.ALLOCATED })
    world:addJob({ fieldId = 3, state = TheContractorJob.STATE.IN_PROGRESS })
    world:addJob({ fieldId = 4, state = TheContractorJob.STATE.OFFERED })
    world:addJob({ fieldId = 5, state = TheContractorJob.STATE.COMPLETED })
    TCJobHotspots.refresh()

    local marked, count = world:markedFields()
    assertTrue(marked[1] and marked[2] and marked[3], "accepted, allocated and in progress")
    assertEquals(count, 3, "markers")
end)

test("an allocated or in-progress job is marked whenever it's due", function()
    local world = setup()
    world:addJob({ fieldId = 1, deadlineDay = 28, state = TheContractorJob.STATE.ALLOCATED })
    world:addJob({ fieldId = 2, deadlineDay = 22 + 120, state = TheContractorJob.STATE.IN_PROGRESS })
    world:addJob({ fieldId = 3, deadlineDay = 28, state = TheContractorJob.STATE.ACCEPTED })
    TCJobHotspots.refresh()

    local marked, count = world:markedFields()
    assertTrue(marked[1] and marked[2], "allocated and in progress, due later")
    assertEquals(count, 2, "markers")
end)

test("an accepted job due on the month's last day is marked, due next month isn't", function()
    local world = setup()
    world:addJob({ fieldId = 1, deadlineDay = 22 })
    world:addJob({ fieldId = 2, deadlineDay = 27 })
    world:addJob({ fieldId = 3, deadlineDay = 28 })
    -- The same month next year (a harvest job taken on early).
    world:addJob({ fieldId = 4, deadlineDay = 22 + 120 })
    TCJobHotspots.refresh()

    local marked, count = world:markedFields()
    assertTrue(marked[1], "due today")
    assertTrue(marked[2], "due on the last day")
    assertEquals(count, 2, "markers")
end)

test("one marker per field, however many jobs are due on it", function()
    local world = setup()
    world:addJob({ fieldId = 1 })
    world:addJob({ fieldId = 1, state = TheContractorJob.STATE.ALLOCATED })
    TCJobHotspots.refresh()

    local _, count = world:markedFields()
    assertEquals(count, 1, "markers")
end)

test("a marker goes when its job is completed or missed", function()
    local world = setup()
    local job = world:addJob({ fieldId = 1 })
    TCJobHotspots.refresh()
    local hotspot = TCJobHotspots.hotspotsByFieldId[1]

    job.state = TheContractorJob.STATE.COMPLETED
    TCJobHotspots.refresh()
    local _, count = world:markedFields()
    assertEquals(count, 0, "markers after completion")
    assertTrue(hotspot.deleted, "the marker was deleted")

    world:addJob({ fieldId = 2 }).state = TheContractorJob.STATE.MISSED
    TCJobHotspots.refresh()
    _, count = world:markedFields()
    assertEquals(count, 0, "a missed job")
end)

test("a job due next month is marked once the month turns", function()
    local world = setup()
    world:addJob({ fieldId = 1, deadlineDay = 30 })
    TCJobHotspots.refresh()
    local _, count = world:markedFields()
    assertEquals(count, 0, "this month")

    g_currentMission.environment.currentMonotonicDay = 28
    g_currentMission.environment.currentDayInPeriod = 1
    TCJobHotspots.refresh()
    _, count = world:markedFields()
    assertEquals(count, 1, "next month")
end)

test("only the local farm's jobs, and nothing for a spectator", function()
    local world = setup()
    world:addJob({ fieldId = 1, farmId = 1 })
    world:addJob({ fieldId = 2, farmId = 2 })
    TCJobHotspots.refresh()
    local marked, count = world:markedFields()
    assertTrue(marked[1] and count == 1, "farm 1's job only")

    function g_currentMission:getFarmId() return 0 end
    TCJobHotspots.refresh()
    _, count = world:markedFields()
    assertEquals(count, 0, "a spectator")
end)

test("a field that can't be found gets no marker", function()
    local world = setup()
    world:addJob({ fieldId = 9 })
    TCJobHotspots.refresh()
    local _, count = world:markedFields()
    assertEquals(count, 0, "markers")
end)

test("refreshed once a second, and reset clears every marker", function()
    local world = setup()
    world:addJob({ fieldId = 1 })
    TCJobHotspots.update(500)
    local _, count = world:markedFields()
    assertEquals(count, 0, "before a second")

    TCJobHotspots.update(500)
    _, count = world:markedFields()
    assertEquals(count, 1, "after a second")

    TCJobHotspots.reset()
    _, count = world:markedFields()
    assertEquals(count, 0, "after reset")
end)

test("106: a spill's job is marked where the spill lies, not on its field", function()
    local world = setup()
    local spillJob = world:addJob({ fieldId = 2, state = TheContractorJob.STATE.ALLOCATED })
    spillJob.spill = { x = 120, z = -40 }
    world:addJob({ fieldId = 3 })

    local markedFields = TCJobHotspots.getMarkedFieldIds(1)
    assertTrue(markedFields[3], "an ordinary job's field")
    assertEquals(markedFields[2], nil, "not the spill's field")

    local positions = TCJobHotspots.getSpotPositions(1)
    assertEquals(positions[spillJob.id].x, 120)
    assertEquals(positions[spillJob.id].z, -40)
    assertEquals(TCJobHotspots.getSpotPositions(2)[spillJob.id], nil, "only the local farm's")

    spillJob.state = TheContractorJob.STATE.COMPLETED
    assertEquals(TCJobHotspots.getSpotPositions(1)[spillJob.id], nil, "gone once it's done")
end)
