-- Puts a live job's field on vanilla's mission map, as a started vanilla
-- contract puts its own (AbstractFieldMission:updateMissionMap), so the game
-- treats the field the same way while it's being worked:
-- - growth: the mission map is the growth mask (MissionManager:
--   createMissionMap), so crops and weeds on the field don't grow while the
--   job's on. A sow job counts its crop at growth state 1 (TCJobProgress,
--   as vanilla's SowMission does), so a month change mid-job used to move
--   everything sown before it out of the count.
-- - Precision Farming's tramlines: it wipes the crop on a field's tramlines
--   after sowing anywhere the map reads 0 (TramlineMap's updateSowingArea
--   override), and gives every unowned field tramlines, so a sow job could
--   never count its tramlines as sown.
-- - The combine's rain penalty is skipped there too, as on vanilla's
--   contracts.
--
-- Vanilla contracts are disabled (DisableVanillaContracts.lua), so no
-- vanilla contract holds any id. MissionManager:getMissionAtWorldPosition
-- finds no contract for our value and returns nil, so everything that asks
-- for "the contract here" (work access, unloading on mission ground,
-- the wrong-seed warning) behaves as it did before. Only code reading the
-- raw value (the three above) sees our fields.
--
-- Live means what 019 measures and 076 grants access to (allocated, in
-- progress, or completed and in its grace period), plus a job unallocated
-- part-way (094's wasUnallocated), so its finished work doesn't grow on
-- while it waits for a new crew. Not an accepted job that's never been
-- allocated: allocation waits for the job's ready day (132), and a crop
-- frozen before then would never ripen. Only jobs with ground work
-- (JOB_TYPES' workAreaTypes): a yard job, a breakdown or a spill has no
-- field work to protect.
--
-- Server only: growth, sowing and threshing all run there, and
-- wasUnallocated isn't streamed. The map isn't saved (vanilla puts its own
-- contracts back after a load too), so this re-reads the jobs every
-- REFRESH_INTERVAL_MS and paints or clears fields to match, which covers
-- every way a job ends, a load and a farm deletion without hooking each.

TCJobFieldMask = {}

TCJobFieldMask.REFRESH_INTERVAL_MS = 1000

-- fieldId -> true for every field this has painted.
TCJobFieldMask.paintedFieldIds = {}
TCJobFieldMask.accumulatedMs = 0

function TCJobFieldMask.reset()
    TCJobFieldMask.paintedFieldIds = {}
    TCJobFieldMask.accumulatedMs = 0
end

-- The value painted: the map's highest, its channels all set. Any non-zero
-- value masks growth and stops the tramlines.
function TCJobFieldMask.getMapValue()
    local numChannels = g_missionManager.missionMapNumChannels or 4
    return 2 ^ numChannels - 1
end

function TCJobFieldMask.isLive(job)
    if TCFieldAccess.isJobWorkable(job) then
        return true
    end
    return job.state == TheContractorJob.STATE.ACCEPTED and job.wasUnallocated == true
end

function TCJobFieldMask.hasGroundWork(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    return jobDef ~= nil and jobDef.workAreaTypes ~= nil and #jobDef.workAreaTypes > 0
end

-- fieldId -> true for every field with a live job with ground work, any farm.
function TCJobFieldMask.getLiveFieldIds()
    local fieldIds = {}
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Jobs == nil then
        return fieldIds
    end
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if job.fieldId ~= nil and job.fieldId ~= 0 and TCJobFieldMask.hasGroundWork(job) and
                    TCJobFieldMask.isLive(job) then
                fieldIds[job.fieldId] = true
            end
        end
    end
    return fieldIds
end

local function paint(fieldId, value)
    local field = g_fieldManager:getFieldById(fieldId)
    if field == nil or field.getDensityMapPolygon == nil then
        return false
    end
    g_missionManager:setMissionMapActiveMissionId(field:getDensityMapPolygon(), value)
    return true
end

function TCJobFieldMask.refresh()
    -- A map can turn contracts off (map.missions#enabled), and then there's
    -- no mission map to paint.
    if g_server == nil or g_missionManager == nil or g_missionManager.missionMap == nil then
        return
    end

    local live = TCJobFieldMask.getLiveFieldIds()
    local painted = TCJobFieldMask.paintedFieldIds

    for fieldId in pairs(painted) do
        if not live[fieldId] then
            paint(fieldId, 0)
            painted[fieldId] = nil
            TCLog.info("TCJobFieldMask: field %d off the mission map", fieldId)
        end
    end

    local value = TCJobFieldMask.getMapValue()
    for fieldId in pairs(live) do
        if not painted[fieldId] and paint(fieldId, value) then
            painted[fieldId] = true
            TCLog.info("TCJobFieldMask: field %d on the mission map (no growth or tramlines)", fieldId)
        end
    end
end

function TCJobFieldMask.update(dt)
    TCJobFieldMask.accumulatedMs = TCJobFieldMask.accumulatedMs + dt
    if TCJobFieldMask.accumulatedMs < TCJobFieldMask.REFRESH_INTERVAL_MS then
        return
    end
    TCJobFieldMask.accumulatedMs = 0
    TCJobFieldMask.refresh()
end
