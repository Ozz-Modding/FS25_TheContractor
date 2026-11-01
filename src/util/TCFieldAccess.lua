-- Grants a farm working access to its own allocated/in_progress jobs'
-- fields. Contractor fields are by definition not owned by the farm working
-- them, and vanilla refuses to work land a farm can't access - the AI
-- Helper stops with "field not owned"/"no field found"
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
-- 076: as strict as a vanilla contract. Access is to the job's field alone
-- (its polygon, not the whole farmland, which can hold other fields), and
-- only for the work the job is for (JOB_TYPES' workAreaTypes, vanilla's
-- AbstractFieldMission:getIsWorkAllowed). A check with no work area type
-- (the AI finding its field, auto-steering) is allowed anywhere on the
-- field, as in vanilla. A player-driven job keeps its access for a short
-- while after it completes (TheContractorJobs.GRACE_PERIOD_MS), so the
-- player can finish the strip the completion threshold left.
--
-- Looked up from a cache rebuilt every REFRESH_INTERVAL_MS rather than
-- walking every job on every call - work areas query this many times per
-- frame - with the cheap farmland lookup first and the polygon test only on
-- a match. Every machine runs its own refresh from its own synced job data,
-- same as TCJobProgress: clients check access too (WorkArea's
-- getTypedNetworkAreas).

TCFieldAccess = {}

TCFieldAccess.REFRESH_INTERVAL_MS = 1000

-- farmId -> { { farmlandId, boundary = { {x, z}, ... }, workAreaTypes = { [type] = true } }, ... }
local sitesByFarm = {}
local accumulatedMs = 0

function TCFieldAccess.reset()
    sitesByFarm = {}
    accumulatedMs = 0
end

-- Allocated, in progress, or completed and still in its grace period.
function TCFieldAccess.isJobWorkable(job)
    local state = job.state
    if state == TheContractorJob.STATE.ALLOCATED or state == TheContractorJob.STATE.IN_PROGRESS then
        return true
    end
    return state == TheContractorJob.STATE.COMPLETED and job.graceRemainingMs ~= nil
end

-- The job type's workAreaTypes as a set of WorkAreaType values. A name the
-- game doesn't have is left out.
function TCFieldAccess.getWorkAreaTypeSet(jobType)
    local set = {}
    local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
    for _, name in ipairs(jobDef ~= nil and jobDef.workAreaTypes or {}) do
        local workAreaType = WorkAreaType[name]
        if workAreaType ~= nil then
            set[workAreaType] = true
        end
    end
    return set
end

function TCFieldAccess.refresh()
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Jobs == nil then
        return
    end

    local result = {}
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if TCFieldAccess.isJobWorkable(job) then
                local field = g_fieldManager:getFieldById(job.fieldId)
                local farmland = field ~= nil and field:getFarmland() or nil
                if farmland ~= nil then
                    result[farm.farmId] = result[farm.farmId] or {}
                    table.insert(result[farm.farmId], {
                        farmlandId = farmland.id,
                        boundary = TCJoyriderRuts.getFieldBoundary(field),
                        workAreaTypes = TCFieldAccess.getWorkAreaTypeSet(job.jobType),
                    })
                end
            end
        end
    end
    sitesByFarm = result
end

function TCFieldAccess.update(dt)
    accumulatedMs = accumulatedMs + dt
    if accumulatedMs < TCFieldAccess.REFRESH_INTERVAL_MS then
        return
    end
    accumulatedMs = 0

    TCFieldAccess.refresh()
end

function TCFieldAccess.isJobSiteAt(farmId, x, z, workAreaType)
    local sites = sitesByFarm[farmId]
    if sites == nil then
        return false
    end

    local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    if farmlandId == nil then
        return false
    end

    for _, site in ipairs(sites) do
        if site.farmlandId == farmlandId and (workAreaType == nil or site.workAreaTypes[workAreaType]) and
            TCJoyriderRuts.isPointInside(x, z, site.boundary) then
            return true
        end
    end
    return false
end

-- Class-level patch, same as DisableVanillaContracts' - MissionManager
-- outlives any one savegame. Installed as the scripts are sourced and again
-- at every mission start (TheContractor:onStartMission), once every mod has
-- loaded: FS25_ContractBoost replaces this method in loadMapFinished without
-- calling the one it replaced, which threw ours away and left the AI with
-- "field not owned". Re-wrapping whatever is there by then puts ours back on
-- top; nothing asks the check anything before the mission starts. Each
-- install is its own closure over the function it wrapped, so a mod that
-- wrapped ours and calls through to it never loops back into itself.
function TCFieldAccess.install()
    local current = MissionManager.getIsMissionWorkAllowed
    if current ~= nil and current == TCFieldAccess.installedCheck then
        return
    end

    local function getIsMissionWorkAllowed(self, farmId, x, z, workAreaType, vehicle)
        if current ~= nil and current(self, farmId, x, z, workAreaType, vehicle) then
            return true
        end
        return TCFieldAccess.isJobSiteAt(farmId, x, z, workAreaType)
    end
    TCFieldAccess.installedCheck = getIsMissionWorkAllowed
    MissionManager.getIsMissionWorkAllowed = getIsMissionWorkAllowed
end

TCFieldAccess.install()
