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
-- staff driver under AutoDrive/Courseplay (037). A machine still waiting
-- for a parking space (062) is free: a hired worker's dispatch takes it
-- straight from the queue, and a player self-allocation puts it at the
-- shop first (see allocateJob).

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

-- 100: a customer's machine in a repair zone is the farm's for ADS's sake,
-- but never job equipment.
local function isOwnedByFarm(vehicle, farmId)
    return vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() == farmId and
        not (TheContractorRepairContracts ~= nil and TheContractorRepairContracts.isContractVehicle(vehicle))
end

-- A vehicle counts as free if it isn't sitting in another of this farm's
-- allocated/in_progress jobs' equipment (008 - field and haulage equipment
-- alike), and isn't currently sitting in 023's post-completion buffer
-- (still physically hidden), stolen (069) or at a tipped trailer's scene
-- (105: the trailer on its side, or the tractor left with it).
-- Waiting to be parked (062) doesn't stop it.
function TheContractorAllocation:isVehicleFree(farmId, vehicle)
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    if vehicleId == nil then
        return false
    end

    if g_currentMission.TheContractor.Cooldown:isVehicleInCooldown(vehicleId) then
        return false
    end

    -- 069: stolen, waiting on the police.
    if g_currentMission.TheContractor.Theft:isStolen(vehicleId) then
        return false
    end

    -- 105: a tipped trailer and its tractor, until it's righted or recovered.
    local tippedTrailer = g_currentMission.TheContractor.TippedTrailer
    if tippedTrailer ~= nil and tippedTrailer:isAtScene(vehicleId) then
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

-- How many workers the job needs if it isn't the player alone - 2 for
-- harvest & haul. (A player-only job never gets this far.)
function TheContractorAllocation.getRequiredWorkerCount(job)
    if TheContractorJobGeneration.isPlayerOnly(job) then
        return 1
    end
    return job.includesHaulage and 2 or 1
end

-- nil if workerIds is a valid crew shape for the job, else a player-facing
-- l10n key. Empty workerIds = the player alone, always valid.
function TheContractorAllocation.getCrewShapeError(job, workerIds)
    if #workerIds == 0 then
        return nil
    end
    -- 032: work the AI Helper can't do (bale wrapping) is the player's, and
    -- so (067) is anything with bales to deliver.
    if TheContractorJobGeneration.isPlayerOnly(job) then
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

-- Equipment roles a crew takes one of: one worker drives one tractor, one
-- harvester, one header, and the hauler one tractor and one trailer. In
-- the allocation panel a second pick of one of these replaces the first.
TheContractorAllocation.SINGLE_ROLES = {
    tractor = true,
    harvester = true,
    header = true,
    seedTank = true,
    haulTractor = true,
    trailer = true,
}

-- The server's version of SINGLE_ROLES, from the vehicles themselves: true
-- if the field equipment has two tractors or two harvesters, or the haulage
-- rig two tractors or two trailers.
function TheContractorAllocation.hasDoubledMachines(equipmentVehicles, haulageVehicles, fillTypeIndex)
    local function count(vehicles, predicate)
        local n = 0
        for _, vehicle in ipairs(vehicles) do
            if predicate(vehicle) then
                n = n + 1
            end
        end
        return n
    end
    local function isTrailer(vehicle)
        return TCEquipmentClass.isTrailerFor(vehicle, fillTypeIndex)
    end

    return count(equipmentVehicles, TCEquipmentClass.isTractor) > 1 or
        count(equipmentVehicles, TCEquipmentClass.isHarvester) > 1 or
        count(haulageVehicles, TCEquipmentClass.isTractor) > 1 or
        count(haulageVehicles, isTrailer) > 1
end

-- Which of two workers operates the field equipment and which hauls, each
-- judged against their own equipment's tier and their own operation skill
-- (the hauler on haulage, 044). A pairing where either can't do their part
-- (an uncertified tractor size, a missing certificate) loses to one where
-- both can, so a worker only certified for the haul tractor's size ends up
-- hauling. Otherwise the field work decides: the better-rated operator for
-- it (the better harvester on the combine), then the better hauler. Returns
-- operatorId, haulerId, capability. A one-worker (or no-worker) crew just
-- gets its operator checked. With fixedRoles the player has chosen the
-- roles themselves (to bring a weaker worker on, say): workerIds[1]
-- operates and workerIds[2] hauls, and only that pairing is checked.
function TheContractorAllocation:assignCrewRoles(farmId, job, workerIds, equipmentIds, haulageEquipmentIds, fixedRoles)
    local staff = g_currentMission.TheContractor.Staff

    if #workerIds < 2 then
        local operatorId = workerIds[1]
        local operator = operatorId ~= nil and staff:getWorker(farmId, operatorId) or nil
        return operatorId, nil, self:previewWorkerCapability(operator, job, equipmentIds, false)
    end

    local pairings = { { workerIds[1], workerIds[2] } }
    if not fixedRoles then
        table.insert(pairings, { workerIds[2], workerIds[1] })
    end

    local BLOCKED = TheContractorAllocation.CAPABILITY.BLOCKED
    local best = nil
    for _, pairing in ipairs(pairings) do
        local operator = staff:getWorker(farmId, pairing[1])
        local hauler = staff:getWorker(farmId, pairing[2])
        local candidate = {
            operatorId = pairing[1],
            haulerId = pairing[2],
            capability = worseCapability(self:previewWorkerCapability(operator, job, equipmentIds, false),
                self:previewWorkerCapability(hauler, job, haulageEquipmentIds, true)),
            operatorRating = self:getWeakestRatingFor(operator, job, equipmentIds, false),
            haulerRating = self:getWeakestRatingFor(hauler, job, haulageEquipmentIds, true),
        }

        local isBetter
        if best == nil then
            isBetter = true
        elseif (candidate.capability == BLOCKED) ~= (best.capability == BLOCKED) then
            isBetter = best.capability == BLOCKED
        elseif candidate.operatorRating ~= best.operatorRating then
            isBetter = candidate.operatorRating > best.operatorRating
        else
            isBetter = candidate.haulerRating > best.haulerRating
        end
        if isBetter then
            best = candidate
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

-- A combine among equipmentIds with crop in its tank, and that fill type,
-- or nil. The allocation's refused until it's emptied: a different crop
-- would stop the AI Helper straight away (it can't harvest on top of it,
-- and blames the field), and even the job's own crop is the farm's to sell,
-- which would be lost with the job's harvest (TCHaulage carts that away).
-- A forage harvester has no tank to check (capacity math.huge, as in
-- TCHaulage's auto-empty).
function TheContractorAllocation.getFilledHarvester(equipmentIds)
    for _, vehicleId in ipairs(equipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        local spec = vehicle ~= nil and vehicle.spec_combine or nil
        if spec ~= nil then
            local capacity = vehicle:getFillUnitCapacity(spec.fillUnitIndex)
            if capacity ~= nil and capacity > 0 and capacity ~= math.huge and
                vehicle:getFillUnitFillLevel(spec.fillUnitIndex) > 0.001 then
                return vehicle, vehicle:getFillUnitFillType(spec.fillUnitIndex)
            end
        end
    end
    return nil
end

-- Allocation (server-authoritative) ----------------------------------------

-- 093: the nickname of the player on the other end of an event's
-- connection, or the local player's own (single player and the host, whose
-- requests run on a local connection that may have no user of its own).
function TheContractorAllocation.getConnectionPlayerName(connection)
    local userManager = g_currentMission.userManager
    local user = userManager ~= nil and connection ~= nil and userManager:getUserByConnection(connection) or nil
    if user ~= nil then
        local nickname = user:getNickname()
        if nickname ~= nil and nickname ~= "" then
            return nickname
        end
    end
    local nickname = g_currentMission.playerNickname
    if nickname ~= nil and nickname ~= "" then
        return nickname
    end
    return nil
end

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
-- shape as TheContractorStaff:hireWorker). fixedRoles: the player chose who
-- operates and who hauls (workerIds in that order, see assignCrewRoles).
-- playerName (093): who asked, kept on a player-driven job so the menu can
-- say who's doing it. Returns true on success.
function TheContractorAllocation:allocateJob(farmId, jobId, workerIds, equipmentIds, haulageEquipmentIds, fixedRoles,
                                             playerName)
    if not g_currentMission:getIsServer() then
        return false
    end

    local jobs = g_currentMission.TheContractor.Jobs
    local job = jobs:getJob(farmId, jobId)
    -- 100: a workshop job has no crew or kit to allocate.
    if job == nil or job.state ~= TheContractorJob.STATE.ACCEPTED or job.workshop ~= nil then
        return false
    end

    workerIds = workerIds or {}
    equipmentIds = equipmentIds or {}
    haulageEquipmentIds = haulageEquipmentIds or {}
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef == nil then
        return false
    end
    -- 067: a job that needs no equipment takes none (there'd be nothing to
    -- hand back for it), and every other job needs some.
    if (#equipmentIds == 0) ~= (jobDef.noEquipment == true) then
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
    local seen = {}
    if not checkVehicles(self, farmId, equipmentIds, seen) or not checkVehicles(self, farmId, haulageEquipmentIds, seen) then
        return false
    end

    local function toVehicles(vehicleIds)
        local vehicles = {}
        for _, vehicleId in ipairs(vehicleIds) do
            table.insert(vehicles, NetworkUtil.getObject(vehicleId))
        end
        return vehicles
    end
    if TheContractorAllocation.hasDoubledMachines(toVehicles(equipmentIds), toVehicles(haulageEquipmentIds),
            self:getJobFillTypeIndex(job)) then
        return false
    end

    if #self:getMissingFromSelection(job, equipmentIds) > 0 then
        return false
    end
    if needsHaulageRig and #self:getMissingHaulageFromSelection(job, haulageEquipmentIds) > 0 then
        return false
    end
    if TheContractorAllocation.getFilledHarvester(equipmentIds) ~= nil then
        return false
    end

    local staff = g_currentMission.TheContractor.Staff
    for i, workerId in ipairs(workerIds) do
        local worker = staff:getWorker(farmId, workerId)
        -- 097: and not gone home.
        if worker == nil or not TheContractorWorkingHours.isAvailable(worker) then
            return false
        end
        for j = 1, i - 1 do
            if workerIds[j] == workerId then
                return false
            end
        end
    end

    local operatorId, haulerId, capability = self:assignCrewRoles(farmId, job, workerIds, equipmentIds,
        haulageEquipmentIds, fixedRoles)
    if capability == TheContractorAllocation.CAPABILITY.BLOCKED then
        return false
    end

    if not job:canTransitionTo(TheContractorJob.STATE.ALLOCATED) then
        return false
    end

    -- 062: the player has to drive it, so a machine still waiting for a
    -- parking space goes to the shop first. With no room there either, the
    -- allocation's refused. (A hired worker's dispatch takes it straight
    -- from the queue - Dispatch:startJobForWorker.)
    if operatorId == nil then
        local parking = g_currentMission.TheContractor.Parking
        local pendingIds = {}
        for _, vehicleId in ipairs(equipmentIds) do
            if parking:isPending(vehicleId) then
                table.insert(pendingIds, vehicleId)
            end
        end
        local failedNames = parking:sendToShop(pendingIds)
        if #failedNames > 0 then
            parking:notify(farmId, "tc_parking_allocationRefusedNotification", table.concat(failedNames, ", "))
            return false
        end
    end

    job.assignedWorkerId = operatorId
    job.haulerWorkerId = haulerId
    job.assignedEquipmentIds = equipmentIds
    job.haulageEquipmentIds = haulageEquipmentIds
    job.allocatedPlayerName = operatorId == nil and playerName or nil

    -- The job has to be doable from here, whatever the field has done since
    -- it was offered - and none of its "done" state can count as our work.
    -- After the equipment's recorded: a bale wrap job lays out bales its
    -- wrapper takes. Not for a job that's been unallocated (094): its field
    -- was prepared then, and the work done since is ours (its field is
    -- protected from NPC fieldwork while the job's open, 034).
    local isResuming = job.wasUnallocated
    job.wasUnallocated = false
    if not isResuming then
        TCFieldPreparation.prepareFieldForJob(job)
        job.completionPercentage = 0
    end
    TCJobProgress.clearJob(job.id)

    job:transitionTo(TheContractorJob.STATE.ALLOCATED)
    TCFieldAccess.refresh()

    -- 032: a player-driven job's supplies go straight in, in the yard - the
    -- player drives it all out themselves. A hired worker's are loaded as
    -- they set off (Dispatch).
    if operatorId == nil then
        TCJobSupplies.topUp(job)
    end

    -- Player-driven haulage: they'll be delivering the crop themselves.
    if isResuming then
        TCHaulage.resumeDelivery(job)
    else
        TCHaulage.startDelivery(job)
    end

    TCLog.info("TheContractor: farm %d job %d allocated (worker=%s, hauler=%s, equipment=%s, haulage=%s)", farmId,
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
