-- Grants a farm working access to the land under its own allocated/
-- in_progress jobs' fields. Contractor fields are by definition not owned by
-- the farm working them, and vanilla refuses to work land a farm can't
-- access - the AI Helper stops with "field not owned"/"no field found"
-- (FieldCourse.findClosestField), and implements' work areas simply don't
-- change the ground (WorkArea:getIsAccessibleAtWorldPosition).
--
-- Every one of those vanilla checks already ORs in
-- MissionManager:getIsMissionWorkAllowed - the bypass vanilla contracts use
-- for exactly this - so extending that one method covers the AI, a player
-- driving the job themselves, and AI auto-steering alike. Vanilla contracts
-- are disabled (DisableVanillaContracts.lua), so nothing else competes for
-- it.
--
-- Access is per farmland (the vanilla ownership unit), looked up from a
-- cache rebuilt every REFRESH_INTERVAL_MS rather than walking every job on
-- every call - work areas query this many times per frame. Every machine
-- runs its own refresh from its own synced job data, same as TCJobProgress.

TCFieldAccess = {}

TCFieldAccess.REFRESH_INTERVAL_MS = 1000

-- farmId -> { farmlandId -> true }
local farmlandsByFarm = {}
local accumulatedMs = 0

function TCFieldAccess.reset()
    farmlandsByFarm = {}
    accumulatedMs = 0
end

function TCFieldAccess.refresh()
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Jobs == nil then
        return
    end

    local result = {}
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS then
                local field = g_fieldManager:getFieldById(job.fieldId)
                local farmland = field ~= nil and field:getFarmland() or nil
                if farmland ~= nil then
                    result[farm.farmId] = result[farm.farmId] or {}
                    result[farm.farmId][farmland.id] = true
                end
            end
        end
    end
    farmlandsByFarm = result
end

function TCFieldAccess.update(dt)
    accumulatedMs = accumulatedMs + dt
    if accumulatedMs < TCFieldAccess.REFRESH_INTERVAL_MS then
        return
    end
    accumulatedMs = 0

    TCFieldAccess.refresh()
end

function TCFieldAccess.isJobSiteAt(farmId, x, z)
    local farmlands = farmlandsByFarm[farmId]
    if farmlands == nil then
        return false
    end

    local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    return farmlandId ~= nil and farmlands[farmlandId] == true
end

-- Class-level patch, same as DisableVanillaContracts' - MissionManager
-- outlives any one savegame, so guard against wrapping it twice.
if MissionManager.tcOriginalGetIsMissionWorkAllowed == nil then
    MissionManager.tcOriginalGetIsMissionWorkAllowed = MissionManager.getIsMissionWorkAllowed

    function MissionManager:getIsMissionWorkAllowed(farmId, x, z, workAreaType, vehicle)
        if MissionManager.tcOriginalGetIsMissionWorkAllowed(self, farmId, x, z, workAreaType, vehicle) then
            return true
        end
        return TCFieldAccess.isJobSiteAt(farmId, x, z)
    end
end
