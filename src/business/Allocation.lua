-- Job allocation flow (018): assigns a worker (or the player themselves) plus
-- equipment to an `accepted` job, flipping it to `allocated` (008's state
-- machine). Acceptance and allocation are decoupled (Q25) — this is the
-- subsystem that bridges the gap, reached from the Calendar's day view (015).
--
-- No state of its own to persist: every mutation lands on TheContractorJob
-- (via Jobs.lua, already server-authoritative + persisted) or
-- TheContractorWorker (via Staff.lua, same). Like JobGeneration (011), this
-- subsystem isn't wired into save/load or TCInitialClientStateEvent — there's
-- nothing here a joining client needs replayed beyond the already-covered
-- Jobs/Staff state it mutates.
--
-- Equipment "freedom" (criterion: not in cooldown, not assigned elsewhere) is
-- scoped down to "not currently assigned to another allocated/in_progress
-- job" per the ticket's own note — 023 owns real cooldown/hiding once it
-- exists; this reads the same assignedEquipmentIds job field that'll still
-- be the source of truth then.

TheContractorAllocation = {}
TheContractorAllocation_mt = Class(TheContractorAllocation)

TheContractorAllocation.CAPABILITY = {
    OK = "ok",
    WARN = "warn",
    BLOCKED = "blocked",
}

function TheContractorAllocation.new()
    local self = {}
    setmetatable(self, TheContractorAllocation_mt)
    return self
end

-- Eligibility queries -----------------------------------------------------

local function isOwnedByFarm(vehicle, farmId)
    return vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() == farmId
end

-- A vehicle counts as free if it isn't sitting in another of this farm's
-- allocated/in_progress jobs' assignedEquipmentIds (008) — the scoped-down
-- freedom check per the ticket's own design note (023 owns real
-- cooldown/hiding).
function TheContractorAllocation:isVehicleFree(farmId, vehicle)
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    if vehicleId == nil then
        return false
    end

    local jobs = g_currentMission.TheContractor.Jobs
    for _, job in ipairs(jobs:getAllJobs(farmId)) do
        if job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS then
            for _, id in ipairs(job.assignedEquipmentIds) do
                if id == vehicleId then
                    return false
                end
            end
        end
    end

    return true
end

-- Farm-owned, free vehicles in the job type's required store category (009) —
-- the combine for a harvest job, the cultivator/seeder/plow for the others.
function TheContractorAllocation:getEligibleImplements(farmId, job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    local result = {}
    if jobDef == nil then
        return result
    end

    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if isOwnedByFarm(vehicle, farmId) and TCEquipmentClass.getCategory(vehicle) == jobDef.requiredCategory and
            self:isVehicleFree(farmId, vehicle) then
            table.insert(result, vehicle)
        end
    end

    return result
end

-- Farm-owned, free tractors of any size tier — only relevant for job types
-- that need one to pull the implement (see JOB_TYPES.requiresTractor).
function TheContractorAllocation:getEligibleTractors(farmId)
    local result = {}

    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if isOwnedByFarm(vehicle, farmId) and TCEquipmentClass.getSizeTier(vehicle) ~= nil and
            self:isVehicleFree(farmId, vehicle) then
            table.insert(result, vehicle)
        end
    end

    return result
end

-- The size tier (009) a set of chosen equipment ids implies, for the worker
-- capability check below — the first tractor among them, or nil if none of
-- them is one (e.g. a harvest job's self-propelled combine alone), in which
-- case Worker:isCapableOfTier(nil) already treats every worker as qualified.
function TheContractorAllocation:getRequiredTier(equipmentIds)
    for _, vehicleId in ipairs(equipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil then
            local tier = TCEquipmentClass.getSizeTier(vehicle)
            if tier ~= nil then
                return tier
            end
        end
    end
    return nil
end

-- Worker capability check (016 vs. 018's design decision): a worker with no
-- rating at all for the equipment's tier is blocked outright; a worker who's
-- certified but whose rating falls short of the job's requiredSkillLevel is
-- merely warned about (still allowed — reduced reputation reward is 022's
-- concern, not enforced here). No tier requirement (nil, e.g. a
-- self-propelled combine) or no worker at all (the player doing it
-- themselves, always unrestricted per Q13) always comes back "ok".
function TheContractorAllocation:previewWorkerCapability(worker, job, equipmentIds)
    if worker == nil then
        return TheContractorAllocation.CAPABILITY.OK
    end

    local requiredTier = self:getRequiredTier(equipmentIds)
    if requiredTier == nil then
        return TheContractorAllocation.CAPABILITY.OK
    end

    if not worker:isCapableOfTier(requiredTier) then
        return TheContractorAllocation.CAPABILITY.BLOCKED
    end

    if worker:getTierCapability(requiredTier) < job.requiredSkillLevel then
        return TheContractorAllocation.CAPABILITY.WARN
    end

    return TheContractorAllocation.CAPABILITY.OK
end

-- Allocation (server-authoritative) ----------------------------------------

-- Assigns workerId (nil for "do it myself", per Q25's decoupled
-- acceptance/allocation and the player's unrestricted-skill status) plus
-- equipmentIds to an `accepted` job, flipping it to `allocated`. Re-validates
-- everything fresh against current server state (the MP double-booking race
-- point between clients on the same farm — first request processed wins,
-- same "re-check membership, no lock needed" shape as
-- TheContractorStaff:hireWorker). Returns true on success.
function TheContractorAllocation:allocateJob(farmId, jobId, workerId, equipmentIds)
    if not g_currentMission:getIsServer() then
        return false
    end

    local jobs = g_currentMission.TheContractor.Jobs
    local job = jobs:getJob(farmId, jobId)
    if job == nil or job.state ~= TheContractorJob.STATE.ACCEPTED then
        return false
    end

    if equipmentIds == nil or #equipmentIds == 0 then
        return false
    end

    -- Re-derived server-side rather than trusting the client's UI-level
    -- filtering (TheContractorAllocation:getEligibleImplements/
    -- getEligibleTractors already restrict what a well-behaved client would
    -- ever offer, but the server is what actually enforces it): every
    -- submitted id must own/free-check clean, and together they must cover
    -- at least one vehicle in the job type's required store category (009)
    -- plus, if the job type needs one, a tractor of any size tier.
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef == nil then
        return false
    end

    local hasImplement = false
    local hasTractor = false
    for _, vehicleId in ipairs(equipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle == nil or not isOwnedByFarm(vehicle, farmId) or not self:isVehicleFree(farmId, vehicle) then
            return false
        end

        if TCEquipmentClass.getCategory(vehicle) == jobDef.requiredCategory then
            hasImplement = true
        end
        if TCEquipmentClass.getSizeTier(vehicle) ~= nil then
            hasTractor = true
        end
    end

    if not hasImplement or (jobDef.requiresTractor and not hasTractor) then
        return false
    end

    local staff = g_currentMission.TheContractor.Staff
    local worker = nil
    if workerId ~= nil then
        worker = staff:getWorker(farmId, workerId)
        if worker == nil or not worker:isIdle() then
            return false
        end

        if self:previewWorkerCapability(worker, job, equipmentIds) == TheContractorAllocation.CAPABILITY.BLOCKED then
            return false
        end
    end

    job.assignedWorkerId = workerId
    job.assignedEquipmentIds = equipmentIds
    if not job:transitionTo(TheContractorJob.STATE.ALLOCATED) then
        return false
    end

    Logging.info("TheContractor: farm %d job %d allocated (worker=%s, equipment=%s)", farmId, jobId,
        tostring(workerId), TheContractorJobs.encodeIdList(equipmentIds))

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobAllocatedEvent.new(job))
    end

    if worker ~= nil then
        staff:setWorkerStatus(farmId, workerId, TheContractorWorker.STATUS.ASSIGNED)

        -- 020: only a hired worker's allocation goes through the AI Helper
        -- dispatch system — a player self-allocation (workerId == nil) just
        -- means the player drives it themselves, no AI job involved (Q7).
        g_currentMission.TheContractor.Dispatch:startJobForWorker(job, worker)
    end

    return true
end
