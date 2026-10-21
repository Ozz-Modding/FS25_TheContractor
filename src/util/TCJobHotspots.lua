-- Job map markers (088): the field of every job the local player's farm
-- has taken on and that's due this month gets vanilla's flashing contract
-- circle on the map, as an accepted vanilla contract does. "Taken on" is
-- accepted, allocated or in progress; "due this month" is a deadlineDay
-- (absolute, so a job due in the same month next year doesn't count) no
-- later than the month's last day. Anything past its deadline has already
-- been missed at the day change, so that's everything due between today
-- and the end of the month.
--
-- The marker is vanilla's own AbstractFieldMissionHotspot (a 50 m red
-- circle at the field's name indicator, pulsing with the map's blink
-- alpha), which nothing else uses with vanilla contracts disabled.
--
-- Client-side and visual only: every machine works its markers out from
-- the job state it already has (deadlineDay is streamed with the job), so
-- there's no saving and no events. Job state changes along many paths
-- (negotiation, allocation, completion, missing, a client's snapshots), so
-- rather than hooking each one this re-reads the jobs every
-- CHECK_INTERVAL_MS and adds or removes markers to match. One marker per
-- field, however many jobs are due on it.

TCJobHotspots = {}

TCJobHotspots.CHECK_INTERVAL_MS = 1000

TCJobHotspots.hotspotsByFieldId = {}
TCJobHotspots.accumulatedMs = 0

local function isTakenOn(state)
    return state == TheContractorJob.STATE.ACCEPTED or state == TheContractorJob.STATE.ALLOCATED or
        state == TheContractorJob.STATE.IN_PROGRESS
end

-- The absolute (monotonic) day of the current month's last day.
function TCJobHotspots.getLastDayOfMonth()
    local environment = g_currentMission.environment
    return environment.currentMonotonicDay + environment.daysPerPeriod - environment.currentDayInPeriod
end

function TCJobHotspots.isMarked(job, lastDayOfMonth)
    return isTakenOn(job.state) and job.deadlineDay ~= nil and job.deadlineDay <= lastDayOfMonth
end

-- fieldId -> true for every field with a marked job of the farm's.
function TCJobHotspots.getMarkedFieldIds(farmId)
    local fieldIds = {}
    local tc = g_currentMission.TheContractor
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID or tc == nil or tc.Jobs == nil or
        g_currentMission.environment == nil then
        return fieldIds
    end

    local lastDayOfMonth = TCJobHotspots.getLastDayOfMonth()
    for _, job in ipairs(tc.Jobs:getAllJobs(farmId)) do
        if job.fieldId ~= nil and TCJobHotspots.isMarked(job, lastDayOfMonth) then
            fieldIds[job.fieldId] = true
        end
    end
    return fieldIds
end

function TCJobHotspots.update(dt)
    TCJobHotspots.accumulatedMs = TCJobHotspots.accumulatedMs + dt
    if TCJobHotspots.accumulatedMs < TCJobHotspots.CHECK_INTERVAL_MS then
        return
    end
    TCJobHotspots.accumulatedMs = 0
    TCJobHotspots.refresh()
end

-- Adds and removes markers to match the local farm's jobs now.
function TCJobHotspots.refresh()
    if AbstractFieldMissionHotspot == nil or g_currentMission.addMapHotspot == nil then
        return
    end

    local wanted = TCJobHotspots.getMarkedFieldIds(g_currentMission:getFarmId())

    for fieldId in pairs(TCJobHotspots.hotspotsByFieldId) do
        if not wanted[fieldId] then
            TCJobHotspots.removeHotspot(fieldId)
        end
    end

    for fieldId in pairs(wanted) do
        if TCJobHotspots.hotspotsByFieldId[fieldId] == nil then
            local field = g_fieldManager:getFieldById(fieldId)
            if field ~= nil then
                local hotspot = AbstractFieldMissionHotspot.new()
                hotspot:setField(field)
                g_currentMission:addMapHotspot(hotspot)
                TCJobHotspots.hotspotsByFieldId[fieldId] = hotspot
            end
        end
    end
end

function TCJobHotspots.removeHotspot(fieldId)
    local hotspot = TCJobHotspots.hotspotsByFieldId[fieldId]
    if hotspot == nil then
        return
    end
    TCJobHotspots.hotspotsByFieldId[fieldId] = nil
    if g_currentMission ~= nil and g_currentMission.removeMapHotspot ~= nil and g_currentMission.hud ~= nil then
        g_currentMission:removeMapHotspot(hotspot)
    end
    hotspot:delete()
end

-- loadMap and deleteMap: no markers carried between savegames.
function TCJobHotspots.reset()
    for fieldId in pairs(TCJobHotspots.hotspotsByFieldId) do
        TCJobHotspots.removeHotspot(fieldId)
    end
    TCJobHotspots.hotspotsByFieldId = {}
    TCJobHotspots.accumulatedMs = 0
end
