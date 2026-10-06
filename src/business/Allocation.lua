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
-- Equipment "freedom" (criterion: not in cooldown, not assigned elsewhere):
-- not currently assigned to another allocated/in_progress job (reads
-- assignedEquipmentIds directly), not sitting in 023's post-completion
-- buffer (TheContractorCooldown:isVehicleInCooldown), and not out with a
-- staff driver under AutoDrive/Courseplay (037).

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
-- allocated/in_progress jobs' equipment (008 - field and haulage equipment
-- alike), and isn't currently sitting in 023's post-completion buffer
-- (still physically hidden).
function TheContractorAllocation:isVehicleFree(farmId, vehicle)
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    if vehicleId == nil then
        return false
    end

    if g_currentMission.TheContractor.Cooldown:isVehicleInCooldown(vehicleId) then
        return false
    end

    -- 037: out driving with a staff member under AutoDrive/Courseplay.
    if g_currentMission.TheContractor.Drivers:hasDriver(vehicle) then
        return false
    end

    local jobs = g_currentMission.TheContractor.Jobs
    for _, job in ipairs(jobs:getAllJobs(farmId)) do
        if job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS then
            for _, id in ipairs(job:getAllEquipmentIds()) do
                if id == vehicleId then
                    return false
                end
            end
        end
    end

    return true
end

-- Farm-owned, free vehicles that can play a non-tractor part in this job
-- (TCEquipmentClass.getJobRole) — the cultivator/seeder/plow, or for
-- harvest the combine/header/combined harvester able to take this crop.
-- Returned as { vehicle, role } pairs so the picker can label them.
function TheContractorAllocation:getEligibleImplements(farmId, job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    local result = {}
    if jobDef == nil then
        return result
    end

    local fruitTypeIndex = job:getFruitTypeIndex()
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if isOwnedByFarm(vehicle, farmId) then
            local role = TCEquipmentClass.getJobRole(vehicle, jobDef, fruitTypeIndex)
            if role ~= nil and role ~= "tractor" and self:isVehicleFree(farmId, vehicle) then
                table.insert(result, { vehicle = vehicle, role = role })
            end
        end
    end

    return result
end

-- Whether the picker should offer tractors at all: only if one of the
-- eligible harvesters/implements has no engine of its own (a trailed
-- harvester, a pulled plow - but not a self-propelled sprayer or mower).
function TheContractorAllocation:jobMayNeedTractor(farmId, job)
    for _, entry in ipairs(self:getEligibleImplements(farmId, job)) do
        if (entry.role == "harvester" or entry.role == "implement") and
            not TCEquipmentClass.isSelfPropelled(entry.vehicle) then
            return true
        end
    end
    return false
end

-- Missing-equipment keys (TCEquipmentClass.getMissingEquipment) for this
-- job against the farm's whole fleet, and against only what's free right
-- now — the difference is equipment the farm owns but that's busy on
-- another job or in cooldown (023), worth telling the player apart from
-- "you don't own one".
function TheContractorAllocation:getMissingEquipment(farmId, job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef == nil then
        return {}, {}
    end

    local owned = TheContractorJobGeneration.getFarmVehicles(farmId)
    local free = {}
    for _, vehicle in ipairs(owned) do
        if self:isVehicleFree(farmId, vehicle) then
            table.insert(free, vehicle)
        end
    end

    local fruitTypeIndex = job:getFruitTypeIndex()
    return TCEquipmentClass.getMissingEquipment(owned, jobDef, fruitTypeIndex),
        TCEquipmentClass.getMissingEquipment(free, jobDef, fruitTypeIndex)
end

-- Missing-equipment keys for a specific chosen set of vehicle ids. On top
-- of getMissingEquipment, a selection can have too many headers
-- ("extraCutter"): a harvester only takes one, and the rigging would fail
-- to find anywhere to hitch the rest.
function TheContractorAllocation:getMissingFromSelection(job, equipmentIds)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef == nil then
        return {}
    end

    local fruitTypeIndex = job:getFruitTypeIndex()
    local vehicles = {}
    local cutterCount = 0
    for _, vehicleId in ipairs(equipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil then
            table.insert(vehicles, vehicle)
            if jobDef.cropDependent and TCEquipmentClass.isStandaloneCutter(vehicle, fruitTypeIndex) then
                cutterCount = cutterCount + 1
            end
        end
    end

    local missing = TCEquipmentClass.getMissingEquipment(vehicles, jobDef, fruitTypeIndex)
    if cutterCount > 1 then
        table.insert(missing, "extraCutter")
    end
    return missing
end

-- Farm-owned, free tractors of any size tier — only relevant for job types
-- that need one to pull the implement (see jobMayNeedTractor).
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

-- 044: the two ratings a worker is judged on for their part of a job -
-- tractor experience for the tractor among equipmentIds (tractorTier nil if
-- there's no tractor, e.g. a self-propelled combine; tractorRating nil if
-- they aren't certified on it), and the operation skill the work uses (the
-- job's own, or haulage for the hauler on a haulage job, 035).
function TheContractorAllocation:getWorkerJobRatings(worker, job, equipmentIds, isHauler)
    local tractorTier = self:getRequiredTier(equipmentIds)
    local operationSkill = isHauler and "haulage" or job:getOperationSkill()
    return {
        tractorTier = tractorTier,
        tractorRating = tractorTier ~= nil and worker:getTierCapability(tractorTier) or nil,
        operationSkill = operationSkill,
        operationRating = operationSkill ~= nil and worker:getSkill(operationSkill) or nil,
    }
end

-- The lower of the ratings that apply (an uncertified tractor counts as 0),
-- and which stat it is (a tier or skill key) - nil, nil if neither applies.
function TheContractorAllocation.getWeakestRating(ratings)
    local rating, stat = nil, nil
    if ratings.tractorTier ~= nil then
        rating, stat = ratings.tractorRating or 0, ratings.tractorTier
    end
    if ratings.operationRating ~= nil and (rating == nil or ratings.operationRating < rating) then
        rating, stat = ratings.operationRating, ratings.operationSkill
    end
    return rating, stat
end

-- getWeakestRating for a worker's part of a job, as a plain number for
-- comparing crews - no worker (or nothing to judge) counts as the best.
function TheContractorAllocation:getWeakestRatingFor(worker, job, equipmentIds, isHauler)
    if worker == nil then
        return TheContractorWorker.MAX_SKILL
    end
    local rating = TheContractorAllocation.getWeakestRating(self:getWorkerJobRatings(worker, job, equipmentIds,
        isHauler))
    return rating or TheContractorWorker.MAX_SKILL
end

-- 054: the certificate the worker's part of the job needs, or nil - the
-- job type's own (herbicide's "spraying"). A hauler (035) carts the crop,
-- so needs none.
function TheContractorAllocation.getRequiredCertification(job, isHauler)
    if isHauler then
        return nil
    end
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    return jobDef ~= nil and jobDef.certification or nil
end

-- 054: the certificate this worker lacks for their part of the job, or nil.
function TheContractorAllocation.getMissingCertification(worker, job, isHauler)
    local cert = TheContractorAllocation.getRequiredCertification(job, isHauler)
    if cert ~= nil and not worker:hasCertification(cert) then
        return cert
    end
    return nil
end

-- Worker capability check (016 vs. 018's design decision): a worker with no
-- rating at all for the equipment's tractor tier is blocked outright, as is
-- one without a certificate the job needs (054); a
-- worker whose tractor rating or operation skill (044) falls short of the
-- job's requiredSkillLevel is merely warned about (still allowed — reduced
-- reputation reward is 022's concern, extra wear 045's, not enforced
-- here). Operation skills never block. No worker at all (the player doing
-- it themselves, always unrestricted per Q13) always comes back "ok".
function TheContractorAllocation:previewWorkerCapability(worker, job, equipmentIds, isHauler)
    if worker == nil then
        return TheContractorAllocation.CAPABILITY.OK
    end

    if TheContractorAllocation.getMissingCertification(worker, job, isHauler) ~= nil then
        return TheContractorAllocation.CAPABILITY.BLOCKED
    end

    local ratings = self:getWorkerJobRatings(worker, job, equipmentIds, isHauler)
    if ratings.tractorTier ~= nil and ratings.tractorRating == nil then
        return TheContractorAllocation.CAPABILITY.BLOCKED
    end

    local rating = TheContractorAllocation.getWeakestRating(ratings)
    if rating ~= nil and rating < job.requiredSkillLevel then
        return TheContractorAllocation.CAPABILITY.WARN
    end

    return TheContractorAllocation.CAPABILITY.OK
end

-- Crew (035) ----------------------------------------------------------------
--
-- A job goes to either the player alone (no workers) or hired workers: one
-- for an ordinary job, exactly two for a haulage job - one on the field
-- equipment, one hauling with the haulage tractor + trailer. The player
-- can't be mixed with a worker: a player-driven haulage job means the
-- player does the carting themselves (TCHaulage's delivery), and there's no
-- way yet to have a worker drive alongside them (a later integration with
-- other AI-driving mods might add one).

local CAPABILITY_RANK = {
    [TheContractorAllocation.CAPABILITY.OK] = 1,
    [TheContractorAllocation.CAPABILITY.WARN] = 2,
    [TheContractorAllocation.CAPABILITY.BLOCKED] = 3,
}

local function worseCapability(a, b)
    return CAPABILITY_RANK[a] >= CAPABILITY_RANK[b] and a or b
end

-- How many workers the job needs if it isn't the player alone.
function TheContractorAllocation.getRequiredWorkerCount(job)
    return job.includesHaulage and 2 or 1
end

-- nil if workerIds is a valid crew shape for the job, else a player-facing
-- l10n key. Empty workerIds = the player alone, always valid.
function TheContractorAllocation.getCrewShapeError(job, workerIds)
    if #workerIds == 0 then
        return nil
    end
    -- 032: work the AI Helper can't do (bale wrapping) is the player's.
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef ~= nil and jobDef.playerOnly then
        return "tc_allocation_playerOnly"
    end
    local required = TheContractorAllocation.getRequiredWorkerCount(job)
    if #workerIds < required then
        return "tc_allocation_needsSecondWorker"
    end
    if #workerIds > required then
        return "tc_allocation_tooManyWorkers"
    end
    return nil
end

-- Which of two workers operates the field equipment and which hauls: each
-- is judged against their own equipment's tier and their own operation
-- skill (previewWorkerCapability - the hauler on haulage, 044),
-- and the pairing whose worse half comes out best wins, so a worker only
-- certified for the haulage tractor's tier ends up hauling. Returns
-- operatorId, haulerId, capability. A one-worker (or no-worker) crew just
-- gets its operator checked.
function TheContractorAllocation:assignCrewRoles(farmId, job, workerIds, equipmentIds, haulageEquipmentIds)
    local staff = g_currentMission.TheContractor.Staff

    if #workerIds < 2 then
        local operatorId = workerIds[1]
        local operator = operatorId ~= nil and staff:getWorker(farmId, operatorId) or nil
        return operatorId, nil, self:previewWorkerCapability(operator, job, equipmentIds, false)
    end

    local best = nil
    for _, pairing in ipairs({ { workerIds[1], workerIds[2] }, { workerIds[2], workerIds[1] } }) do
        local operator = staff:getWorker(farmId, pairing[1])
        local hauler = staff:getWorker(farmId, pairing[2])
        local capability = worseCapability(self:previewWorkerCapability(operator, job, equipmentIds, false),
            self:previewWorkerCapability(hauler, job, haulageEquipmentIds, true))
        -- 044: between two equally capable pairings, the one whose weaker
        -- half is better rated (e.g. the better harvester on the combine).
        local weakest = math.min(self:getWeakestRatingFor(operator, job, equipmentIds, false),
            self:getWeakestRatingFor(hauler, job, haulageEquipmentIds, true))
        if best == nil or CAPABILITY_RANK[capability] < CAPABILITY_RANK[best.capability] or
            (capability == best.capability and weakest > best.weakest) then
            best = { operatorId = pairing[1], haulerId = pairing[2], capability = capability, weakest = weakest }
        end
    end
    return best.operatorId, best.haulerId, best.capability
end

-- Farm-owned, free vehicles for a two-worker haulage rig: any tractor, and
-- trailers that take the job's crop. Returned as { vehicle, role } pairs,
-- role "haulTractor" | "trailer".
function TheContractorAllocation:getEligibleHaulageEquipment(farmId, job)
    local result = {}
    if not job.includesHaulage then
        return result
    end

    local fillTypeIndex = self:getJobFillTypeIndex(job)
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if isOwnedByFarm(vehicle, farmId) and self:isVehicleFree(farmId, vehicle) then
            if TCEquipmentClass.isTractor(vehicle) then
                table.insert(result, { vehicle = vehicle, role = "haulTractor" })
            elseif TCEquipmentClass.isTrailerFor(vehicle, fillTypeIndex) then
                table.insert(result, { vehicle = vehicle, role = "trailer" })
            end
        end
    end
    return result
end

function TheContractorAllocation:getJobFillTypeIndex(job)
    local fruitTypeIndex = job:getFruitTypeIndex()
    return fruitTypeIndex ~= nil and g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(fruitTypeIndex) or nil
end

-- Missing haulage-rig keys (TCEquipmentClass.getMissingHaulageEquipment)
-- against the farm's whole fleet and against only what's free - same
-- owned-vs-busy split as getMissingEquipment.
function TheContractorAllocation:getMissingHaulageEquipment(farmId, job)
    local fillTypeIndex = self:getJobFillTypeIndex(job)
    local owned = TheContractorJobGeneration.getFarmVehicles(farmId)
    local free = {}
    for _, vehicle in ipairs(owned) do
        if self:isVehicleFree(farmId, vehicle) then
            table.insert(free, vehicle)
        end
    end
    return TCEquipmentClass.getMissingHaulageEquipment(owned, fillTypeIndex),
        TCEquipmentClass.getMissingHaulageEquipment(free, fillTypeIndex)
end

function TheContractorAllocation:getMissingHaulageFromSelection(job, haulageEquipmentIds)
    local vehicles = {}
    for _, vehicleId in ipairs(haulageEquipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil then
            table.insert(vehicles, vehicle)
        end
    end
    return TCEquipmentClass.getMissingHaulageEquipment(vehicles, self:getJobFillTypeIndex(job))
end

-- Allocation (server-authoritative) ----------------------------------------

local function checkVehicles(self, farmId, vehicleIds, seen)
    for _, vehicleId in ipairs(vehicleIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle == nil or seen[vehicleId] or not isOwnedByFarm(vehicle, farmId) or
            not self:isVehicleFree(farmId, vehicle) then
            return false
        end
        seen[vehicleId] = true
    end
    return true
end

-- Assigns a crew (workerIds - empty for "do it myself", per Q25's
-- decoupled acceptance/allocation and the player's unrestricted-skill
-- status; see Crew above) plus equipmentIds, and for a two-worker haulage
-- job haulageEquipmentIds, to an `accepted` job, flipping it to
-- `allocated`. Re-validates everything fresh against current server state
-- (the MP double-booking race point between clients on the same farm —
-- first request processed wins, same "re-check membership, no lock needed"
-- shape as TheContractorStaff:hireWorker). Returns true on success.
function TheContractorAllocation:allocateJob(farmId, jobId, workerIds, equipmentIds, haulageEquipmentIds)
    if not g_currentMission:getIsServer() then
        return false
    end

    local jobs = g_currentMission.TheContractor.Jobs
    local job = jobs:getJob(farmId, jobId)
    if job == nil or job.state ~= TheContractorJob.STATE.ACCEPTED then
        return false
    end

    workerIds = workerIds or {}
    haulageEquipmentIds = haulageEquipmentIds or {}
    if equipmentIds == nil or #equipmentIds == 0 then
        return false
    end

    if TheContractorAllocation.getCrewShapeError(job, workerIds) ~= nil then
        return false
    end
    local needsHaulageRig = job.includesHaulage and #workerIds > 0
    if needsHaulageRig ~= (#haulageEquipmentIds > 0) then
        return false
    end

    -- Re-derived server-side rather than trusting the client's UI-level
    -- filtering (TheContractorAllocation:getEligibleImplements/
    -- getEligibleTractors/getEligibleHaulageEquipment already restrict what
    -- a well-behaved client would ever offer, but the server is what
    -- actually enforces it): every submitted id must own/free-check clean
    -- and appear only once, and together they must cover the job's
    -- equipment requirements (TCEquipmentClass.getMissingEquipment/
    -- getMissingHaulageEquipment).
    if TheContractorJobGeneration.JOB_TYPES[job.jobType] == nil then
        return false
    end

    local seen = {}
    if not checkVehicles(self, farmId, equipmentIds, seen) or not checkVehicles(self, farmId, haulageEquipmentIds, seen) then
        return false
    end

    if #self:getMissingFromSelection(job, equipmentIds) > 0 then
        return false
    end
    if needsHaulageRig and #self:getMissingHaulageFromSelection(job, haulageEquipmentIds) > 0 then
        return false
    end

    local staff = g_currentMission.TheContractor.Staff
    for i, workerId in ipairs(workerIds) do
        local worker = staff:getWorker(farmId, workerId)
        if worker == nil or not worker:isIdle() then
            return false
        end
        for j = 1, i - 1 do
            if workerIds[j] == workerId then
                return false
            end
        end
    end

    local operatorId, haulerId, capability = self:assignCrewRoles(farmId, job, workerIds, equipmentIds,
        haulageEquipmentIds)
    if capability == TheContractorAllocation.CAPABILITY.BLOCKED then
        return false
    end

    if not job:canTransitionTo(TheContractorJob.STATE.ALLOCATED) then
        return false
    end

    job.assignedWorkerId = operatorId
    job.haulerWorkerId = haulerId
    job.assignedEquipmentIds = equipmentIds
    job.haulageEquipmentIds = haulageEquipmentIds

    -- The job has to be doable from here, whatever the field has done since
    -- it was offered - and none of its "done" state can count as our work.
    -- After the equipment's recorded: a bale wrap job lays out bales its
    -- wrapper takes.
    TCFieldPreparation.prepareFieldForJob(job)
    TCJobProgress.clearJob(job.id)
    job.completionPercentage = 0

    job:transitionTo(TheContractorJob.STATE.ALLOCATED)
    TCFieldAccess.refresh()

    -- 032: a player-driven job's supplies go straight in, in the yard - the
    -- player drives it all out themselves. A hired worker's are loaded as
    -- they set off (Dispatch).
    if operatorId == nil then
        TCJobSupplies.topUp(job)
    end

    -- Player-driven haulage: they'll be delivering the crop themselves.
    TCHaulage.startDelivery(job)

    Logging.info("TheContractor: farm %d job %d allocated (worker=%s, hauler=%s, equipment=%s, haulage=%s)", farmId,
        jobId, tostring(operatorId), tostring(haulerId), TheContractorJobs.encodeIdList(equipmentIds),
        TheContractorJobs.encodeIdList(haulageEquipmentIds))

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobAllocatedEvent.new(job))
    end

    if operatorId ~= nil then
        for _, workerId in ipairs(job:getWorkerIds()) do
            staff:setWorkerStatus(farmId, workerId, TheContractorWorker.STATUS.ASSIGNED)
        end

        -- 020: only a hired worker's allocation goes through the AI Helper
        -- dispatch system — a player self-allocation (no workers) just
        -- means the player drives it themselves, no AI job involved (Q7).
        g_currentMission.TheContractor.Dispatch:startJobForWorker(job)
    end

    return true
end
