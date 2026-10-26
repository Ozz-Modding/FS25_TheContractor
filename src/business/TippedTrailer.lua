-- Tipped trailer (105): a job event (074) on harvest & haul jobs (035). As
-- the job completes, the hauler tips their trailer over on the way back to
-- the yard. They get the tractor unhitched (the drawbar's eye swivels, so
-- the tractor stays on its wheels). Both are taken out of the cooldown (023)
-- and left at the scene for the player to turn up to: the trailer laid on
-- its side by an AI road spline (the roads vanilla's helpers drive,
-- g_currentMission.aiSystem's getRoadSplines, as RedTape's salt spreading
-- scheme reads them), somewhere between the job's field and the farm's
-- parking slots, and the tractor on its wheels just ahead of it in the same
-- lane, slewed round a little. The rest of the kit comes home as usual.
--
-- Odds are per job, from the hauler's haulage skill alone (getChance):
-- CHANCE_AT_MIN_SKILL at 1 down to CHANCE_AT_MAX_SKILL at 10, no cooldown.
-- A hauler on about 40 harvest & haul jobs in two years tips one about once
-- in that time at skill 1, and about once in 16 years at 10.
--
-- Both machines are damaged (vanilla damage, or an ADS breakdown, as 079's
-- road accidents do it), the hauler's morale drops and the farm loses some
-- reputation. The inbox message offers:
--
--   recover   a recovery firm rights it and brings it and the tractor
--             back: RECOVERY_COST (1x UK, scaleCost) under tcRecovery, and
--             both go to the parking queue, which parks them (upright)
--   diy       "we'll sort it": it's left where it lies for the player to
--             push back onto its wheels: walk up to it and press the
--             activate key (TCTippedTrailerActivatable -> TCRightTrailerEvent
--             -> rightTrailer). If it's still on its side
--             DIY_REOFFER_PERIODS later, the offer comes again
--
-- The prompt's there from the start, whatever's been answered. While it's
-- on its side the trailer is frozen (setLying: physics won't keep a vehicle
-- on its side), and neither it nor the tractor can be allocated
-- (isAtScene, read by Allocation:isVehicleFree on every machine from the
-- synced incident). The tractor can be driven: once the trailer's back on
-- its wheels the player hitches up and drives them home. The
-- server also checks it every CHECK_INTERVAL_MS: back on its wheels another
-- way (vanilla's reset), sold or gone, and the incident closes, taking its
-- message and notice with it.
--
-- No state of its own: everything lives in the incident's data (068, flat,
-- saved and synced): jobId, fieldId, workerId, workerName, vehicleId /
-- vehicleUniqueId / vehicleName (the trailer), tractorId / tractorUniqueId
-- / tractorName (tractorId 0 when it isn't at the scene), the trailer's spot
-- (x, z, dirX, dirZ, sideX, sideZ), the tractor's (tractorX, tractorZ,
-- tractorRotY), trailerSeverity, tractorSeverity, reputationPenalty,
-- recoveryCost, and later messageId and noticeId.

TheContractorTippedTrailer = {}
TheContractorTippedTrailer_mt = Class(TheContractorTippedTrailer)

TheContractorTippedTrailer.EVENT_TYPE = "tippedTrailer"
TheContractorTippedTrailer.MESSAGE_KIND = "tippedTrailer"

TheContractorTippedTrailer.CHANCE_AT_MIN_SKILL = 0.025
TheContractorTippedTrailer.CHANCE_AT_MAX_SKILL = 0.003

-- Damage done (0-1, vanilla), or how far along an ADS breakdown starts.
TheContractorTippedTrailer.TRAILER_DAMAGE_MIN = 0.30
TheContractorTippedTrailer.TRAILER_DAMAGE_MAX = 0.60
TheContractorTippedTrailer.TRACTOR_DAMAGE_MIN = 0.10
TheContractorTippedTrailer.TRACTOR_DAMAGE_MAX = 0.25

-- Reputation lost: this share of what the job earns at 100%, never less
-- than the minimum.
TheContractorTippedTrailer.REPUTATION_PENALTY_MULTIPLIER = 0.5
TheContractorTippedTrailer.MIN_REPUTATION_PENALTY = 5
TheContractorTippedTrailer.MORALE_PENALTY = -5

-- A recovery firm's call-out to right a trailer and bring it back, 1x UK.
TheContractorTippedTrailer.RECOVERY_COST = 750

-- Months.
TheContractorTippedTrailer.DIY_REOFFER_PERIODS = { 0.5, 0.5 }

TheContractorTippedTrailer.CHECK_INTERVAL_MS = 2000
-- Its up axis at least this far up (cos of about 45 degrees) is upright.
TheContractorTippedTrailer.UPRIGHT_MIN_Y = 0.7

-- Where it can end up: road spline points every SAMPLE_STEP metres, at
-- least MIN_FROM_FIELD from the field's centre and MIN_FROM_YARD from the
-- yard, no further than MAX_FROM_FIELD, and within CORRIDOR of the straight
-- line from the field to the yard (beside it, not beyond either end). With
-- no point in that corridor (or no parking slots to call the yard), the
-- FALLBACK_COUNT points nearest the field. At most MAX_TRIES of them are
-- tested for room.
TheContractorTippedTrailer.SAMPLE_STEP = 10
TheContractorTippedTrailer.MIN_FROM_FIELD = 80
TheContractorTippedTrailer.MIN_FROM_YARD = 80
TheContractorTippedTrailer.MAX_FROM_FIELD = 1500
TheContractorTippedTrailer.CORRIDOR = 150
TheContractorTippedTrailer.FALLBACK_COUNT = 20
TheContractorTippedTrailer.MAX_TRIES = 30
-- The trailer's wheels this far from the spline (the road's middle), at its
-- edge, with its body lying back across the road: flat tarmac, where a bank
-- on the verge could have the physics push it back onto its wheels.
TheContractorTippedTrailer.ROAD_EDGE_OFFSET = 3.0
-- Further than this between the spline and the ground is a bridge.
TheContractorTippedTrailer.MAX_ROAD_HEIGHT_GAP = 1.5
-- The ground under it can't rise or fall more than this across its
-- footprint. It's set down resting on the highest of it, never dropped (a
-- fall onto one edge rolls it back onto its wheels) and never sunk into the
-- ground (the physics pushing it out does the same), so this is as far as
-- it can settle.
TheContractorTippedTrailer.MAX_GROUND_GAP = 0.3
-- The tractor at the scene: this far ahead of the trailer's front, its
-- side this far in from the road's edge, slewed up to this many degrees
-- either way off the road's line.
TheContractorTippedTrailer.TRACTOR_GAP = 2.0
TheContractorTippedTrailer.TRACTOR_EDGE_MARGIN = 0.3
TheContractorTippedTrailer.TRACTOR_SLEW_DEGREES = 25
-- Back on its wheels this soon after being put down is the physics
-- righting it, not the player: warned about.
TheContractorTippedTrailer.SELF_RIGHTED_MS = 30000

TheContractorTippedTrailer.ACTION = {
    RECOVER = "recover",
    DIY = "diy",
}

TheContractorTippedTrailer.STAGE = {
    TIPPED = "tipped",
    OFFER = "offer",
    RECOVER = "recover",
    DIY = "diy",
}

table.insert(FinanceStats.statNames, "tcRecovery")
FinanceStats.statNameToIndex["tcRecovery"] = #FinanceStats.statNames

function TheContractorTippedTrailer.new()
    local self = {}
    setmetatable(self, TheContractorTippedTrailer_mt)

    MoneyType.TC_RECOVERY = MoneyType.register("tcRecovery", "tc_moneyType_recovery")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    self.checkMs = 0
    -- Server, not saved: incident id -> g_time it was put down, for the
    -- SELF_RIGHTED_MS warning.
    self.placedAtByIncident = {}

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorTippedTrailer:register(randomEvents, inbox)
    self.randomEvents = randomEvents
    local STAGE = TheContractorTippedTrailer.STAGE

    randomEvents:registerEventType(TheContractorTippedTrailer.EVENT_TYPE, {
        l10nKey = "tc_tippedTrailer_eventName",
        chancePerJob = function(farmId, job)
            return self:getJobChance(farmId, job)
        end,
        canTrigger = function(farmId, job)
            return self:rollTipping(farmId, job, math.random)
        end,
        stages = {
            { key = STAGE.TIPPED, run = function(incident)
                return self:onTipped(incident)
            end },
            { key = STAGE.OFFER, run = function(incident)
                return self:onOffer(incident)
            end },
            { key = STAGE.RECOVER, run = function(incident)
                return self:onRecover(incident)
            end },
            { key = STAGE.DIY, delayPeriods = TheContractorTippedTrailer.DIY_REOFFER_PERIODS,
                run = function(incident)
                    return self:onDiyCheck(incident)
                end },
        },
    })

    inbox:registerMessageKind(TheContractorTippedTrailer.MESSAGE_KIND, {
        onAction = function(farmId, message, actionKey)
            self:onMessageAnswered(message, actionKey)
        end,
        getConfirmText = function(message, actionKey)
            if actionKey ~= TheContractorTippedTrailer.ACTION.RECOVER then
                return nil
            end
            return string.format(g_i18n:getText("tc_tippedTrailer_recoverConfirm"),
                g_i18n:formatMoney(message.payload.recoveryCost or 0, 0, true, true))
        end,
        chipKey = "tc_inbox_chipTippedTrailer",
        chipTone = "bad",
    })
end

-- Odds ------------------------------------------------------------------------------

-- Per job, from the hauler's haulage skill (1-10).
function TheContractorTippedTrailer.getChance(haulageSkill)
    local skill = math.max(TheContractorWorker.MIN_SKILL, math.min(TheContractorWorker.MAX_SKILL, haulageSkill))
    local share = (skill - TheContractorWorker.MIN_SKILL) / (TheContractorWorker.MAX_SKILL -
        TheContractorWorker.MIN_SKILL)
    return TheContractorTippedTrailer.CHANCE_AT_MIN_SKILL + share *
        (TheContractorTippedTrailer.CHANCE_AT_MAX_SKILL - TheContractorTippedTrailer.CHANCE_AT_MIN_SKILL)
end

-- 0 for any job without a hired hauler.
function TheContractorTippedTrailer:getJobChance(farmId, job)
    if job.haulerWorkerId == nil then
        return 0
    end
    local worker = g_currentMission.TheContractor.Staff:getWorker(farmId, job.haulerWorkerId)
    if worker == nil then
        return 0
    end
    return TheContractorTippedTrailer.getChance(worker:getSkill("haulage") or TheContractorWorker.MIN_SKILL)
end

-- Every machine -----------------------------------------------------------------------

function TheContractorTippedTrailer:getIncidentForVehicle(vehicleId)
    if self.randomEvents == nil or vehicleId == nil or vehicleId == 0 then
        return nil
    end
    for _, incident in pairs(self.randomEvents.incidents) do
        if incident.eventType == TheContractorTippedTrailer.EVENT_TYPE and incident.data.vehicleId == vehicleId then
            return incident
        end
    end
    return nil
end

-- On its side by the road, waiting to be righted or recovered.
function TheContractorTippedTrailer:isTipped(vehicleId)
    return self:getIncidentForVehicle(vehicleId) ~= nil
end

-- The tipped trailer, or the tractor left with it: kept out of allocation
-- until it's righted or recovered.
function TheContractorTippedTrailer:isAtScene(vehicleId)
    if self.randomEvents == nil or vehicleId == nil or vehicleId == 0 then
        return false
    end
    for _, incident in pairs(self.randomEvents.incidents) do
        if incident.eventType == TheContractorTippedTrailer.EVENT_TYPE and
                (incident.data.vehicleId == vehicleId or incident.data.tractorId == vehicleId) then
            return true
        end
    end
    return false
end

-- The spot (server) -------------------------------------------------------------------

local function getLiveVehicle(vehicleId)
    local vehicle = vehicleId ~= nil and vehicleId ~= 0 and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

local function distance(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return math.sqrt(dx * dx + dz * dz)
end

-- From a point to the segment a-b, and how far along it the point lies
-- (0 at a, 1 at b, outside that beyond either end).
function TheContractorTippedTrailer.distanceToSegment(x, z, ax, az, bx, bz)
    local abX, abZ = bx - ax, bz - az
    local lengthSq = abX * abX + abZ * abZ
    if lengthSq <= 0 then
        return distance(x, z, ax, az), 0
    end
    local along = ((x - ax) * abX + (z - az) * abZ) / lengthSq
    local t = math.max(0, math.min(1, along))
    return distance(x, z, ax + t * abX, az + t * abZ), along
end

-- The middle of the farm's parking slots, or nil with none.
function TheContractorTippedTrailer.getYardPosition(farmId)
    local slots = TCParking.getSlots(farmId)
    if #slots == 0 then
        return nil
    end
    local sumX, sumZ, count = 0, 0, 0
    for _, slot in ipairs(slots) do
        if slot.rootNode ~= nil then
            local x, _, z = getWorldTranslation(slot.rootNode)
            sumX, sumZ, count = sumX + x, sumZ + z, count + 1
        end
    end
    if count == 0 then
        return nil
    end
    return sumX / count, sumZ / count
end

-- Every road spline point within reach of the field, as { x, y, z, dirX,
-- dirZ } with the direction flat and normalised. Server only (vanilla only
-- keeps the splines there).
function TheContractorTippedTrailer.sampleRoads(fieldX, fieldZ)
    local samples = {}
    local aiSystem = g_currentMission.aiSystem
    if aiSystem == nil or aiSystem.getRoadSplines == nil then
        return samples
    end
    local step = TheContractorTippedTrailer.SAMPLE_STEP
    local reach = TheContractorTippedTrailer.MAX_FROM_FIELD
    for spline in pairs(aiSystem:getRoadSplines()) do
        local length = getSplineLength(spline)
        if length ~= nil and length > 0 then
            local count = math.max(1, math.floor(length / step))
            for i = 0, count do
                local t = i / count
                local x, y, z = getSplinePosition(spline, t)
                if distance(x, z, fieldX, fieldZ) <= reach then
                    local dirX, _, dirZ = getSplineDirection(spline, t)
                    local dirLength = math.sqrt(dirX * dirX + dirZ * dirZ)
                    if dirLength > 0.001 then
                        table.insert(samples, { x = x, y = y, z = z, dirX = dirX / dirLength, dirZ = dirZ / dirLength })
                    end
                end
            end
        end
    end
    return samples
end

-- The samples worth trying, in the order to try them (see the tunables).
-- yardX nil: no yard, so the nearest to the field. random is for the tests.
function TheContractorTippedTrailer.getCandidates(samples, fieldX, fieldZ, yardX, yardZ, random)
    local T = TheContractorTippedTrailer
    local inReach = {}
    local onTheWay = {}
    for _, sample in ipairs(samples) do
        local fromField = distance(sample.x, sample.z, fieldX, fieldZ)
        if fromField >= T.MIN_FROM_FIELD and fromField <= T.MAX_FROM_FIELD then
            sample.fromField = fromField
            table.insert(inReach, sample)
            if yardX ~= nil and distance(sample.x, sample.z, yardX, yardZ) >= T.MIN_FROM_YARD then
                local fromLine, along = T.distanceToSegment(sample.x, sample.z, fieldX, fieldZ, yardX, yardZ)
                if fromLine <= T.CORRIDOR and along > 0 and along < 1 then
                    table.insert(onTheWay, sample)
                end
            end
        end
    end

    local candidates = onTheWay
    if #candidates == 0 then
        table.sort(inReach, function(a, b)
            return a.fromField < b.fromField
        end)
        candidates = {}
        for i = 1, math.min(T.FALLBACK_COUNT, #inReach) do
            candidates[i] = inReach[i]
        end
    end

    for i = #candidates, 2, -1 do
        local j = math.min(i, math.floor(random() * i) + 1)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end
    return candidates
end

-- Where the trailer goes for one sample, at the road's edge on side (+1
-- right of the spline's direction, -1 left): its origin (the wheels), the
-- footprint's centre, its facing, and the way its top points (sideX/Z:
-- back toward the road's middle). size is vehicle.size.
function TheContractorTippedTrailer.getPlacement(sample, side, size)
    local edgeX, edgeZ = sample.dirZ * side, -sample.dirX * side
    local sideX, sideZ = -edgeX, -edgeZ
    local offset = TheContractorTippedTrailer.ROAD_EDGE_OFFSET
    local height = size.height or 3
    local x, z = sample.x + edgeX * offset, sample.z + edgeZ * offset
    return {
        x = x,
        z = z,
        centreX = x + sideX * height * 0.5,
        centreZ = z + sideZ * height * 0.5,
        dirX = sample.dirX,
        dirZ = sample.dirZ,
        sideX = sideX,
        sideZ = sideZ,
    }
end

-- Where the footprint of it lying down meets the ground: its four corners
-- and its middle, as { x, z }.
function TheContractorTippedTrailer.getFootprintPoints(placement, size)
    local halfLength = (size.length or 8) * 0.5
    local height = size.height or 3
    local points = { { x = placement.centreX, z = placement.centreZ } }
    for _, along in ipairs({ -halfLength, halfLength }) do
        for _, across in ipairs({ 0, height }) do
            table.insert(points, {
                x = placement.x + placement.dirX * along + placement.sideX * across,
                z = placement.z + placement.dirZ * along + placement.sideZ * across,
            })
        end
    end
    return points
end

-- The lowest and highest ground under the footprint. Engine side.
function TheContractorTippedTrailer.getGroundRange(placement, size)
    local minY, maxY = math.huge, -math.huge
    for _, point in ipairs(TheContractorTippedTrailer.getFootprintPoints(placement, size)) do
        local y = getTerrainHeightAtWorldPos(g_terrainNode, point.x, 0, point.z)
        minY, maxY = math.min(minY, y), math.max(maxY, y)
    end
    return minY, maxY
end

-- On flat ground (not a bridge, not a bank) with room for it on its side:
-- trailer height across, its length along, its width up. Engine side,
-- replaced in the tests.
function TheContractorTippedTrailer.isPlacementClear(placement, sample, size)
    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, placement.centreX, 0, placement.centreZ)
    if math.abs(terrainY - sample.y) > TheContractorTippedTrailer.MAX_ROAD_HEIGHT_GAP then
        return false
    end
    local minY, maxY = TheContractorTippedTrailer.getGroundRange(placement, size)
    if maxY - minY > TheContractorTippedTrailer.MAX_GROUND_GAP then
        return false
    end
    local rotY = MathUtil.getYRotationFromDirection(placement.dirX, placement.dirZ)
    return TCParking.isAreaClear(placement.centreX, placement.centreZ, rotY, size.height or 3, size.length or 8,
        size.width or 3)
end

-- Where the tractor stands for a trailer placement: just ahead of the
-- trailer's front (its +z, the way it faces), in the same lane with its
-- side TRACTOR_EDGE_MARGIN in from the road's edge, slewed slewRoll (0-1)
-- of the way from -TRACTOR_SLEW_DEGREES to +TRACTOR_SLEW_DEGREES off the
-- road's line. { x, z, rotY }; sizes are vehicle.size.
function TheContractorTippedTrailer.getTractorPlacement(placement, trailerSize, tractorSize, slewRoll)
    local T = TheContractorTippedTrailer
    local ahead = (trailerSize.length or 8) * 0.5 + T.TRACTOR_GAP + (tractorSize.length or 5) * 0.5
    local inward = (tractorSize.width or 3) * 0.5 + T.TRACTOR_EDGE_MARGIN
    local height = trailerSize.height or 3
    -- The trailer's centre is half its height in from the edge, the
    -- tractor's is inward.
    local x = placement.centreX + placement.dirX * ahead + placement.sideX * (inward - height * 0.5)
    local z = placement.centreZ + placement.dirZ * ahead + placement.sideZ * (inward - height * 0.5)
    local slew = math.rad((slewRoll * 2 - 1) * T.TRACTOR_SLEW_DEGREES)
    return { x = x, z = z, rotY = MathUtil.getYRotationFromDirection(placement.dirX, placement.dirZ) + slew }
end

-- Room for the tractor on its wheels there. Engine side, replaced in the
-- tests.
function TheContractorTippedTrailer.isTractorPlacementClear(tractorPlacement, size)
    return TCParking.isAreaClear(tractorPlacement.x, tractorPlacement.z, tractorPlacement.rotY, size.width or 3,
        size.length or 5, size.height)
end

-- A placement for the trailer on the way from the field to the yard, and
-- one for the tractor with it if there's a tractor to leave there, or nil.
function TheContractorTippedTrailer.findPlacement(trailer, tractor, farmId, fieldX, fieldZ, random)
    local T = TheContractorTippedTrailer
    local size = trailer.size or {}
    local tractorSize = tractor ~= nil and tractor.size or {}
    local yardX, yardZ = T.getYardPosition(farmId)
    local candidates = T.getCandidates(T.sampleRoads(fieldX, fieldZ), fieldX, fieldZ, yardX, yardZ, random)
    for i = 1, math.min(T.MAX_TRIES, #candidates) do
        local sample = candidates[i]
        local placement = T.getPlacement(sample, random() < 0.5 and 1 or -1, size)
        if T.isPlacementClear(placement, sample, size) then
            if tractor == nil then
                return placement, nil
            end
            local tractorPlacement = T.getTractorPlacement(placement, size, tractorSize, random())
            if T.isTractorPlacementClear(tractorPlacement, tractorSize) then
                return placement, tractorPlacement
            end
        end
    end
    return nil
end

-- canTrigger (068, 074) -----------------------------------------------------------------

local function randomBetween(random, min, max)
    return min + random() * (max - min)
end

-- The hauler's rig from their equipment: the trailer (the first unit with
-- vanilla's Trailer spec, else the first unit) and the tractor.
function TheContractorTippedTrailer.getHaulRig(job)
    local tractor, units = TheContractorRoadAccident.getRig(job.haulageEquipmentIds)
    local trailer = nil
    for _, unit in ipairs(units) do
        if unit.spec_trailer ~= nil then
            trailer = unit
            break
        end
    end
    return trailer or units[1], tractor
end

-- The incident's starting data, or nil: no hired hauler, no trailer, a
-- trailer that isn't ours to tip (courtesy, stolen, already over), off on
-- another job, or no road to put it on. random is for the tests.
function TheContractorTippedTrailer:rollTipping(farmId, job, random)
    local tc = g_currentMission.TheContractor
    if job.haulerWorkerId == nil then
        return nil
    end
    local worker = tc.Staff:getWorker(farmId, job.haulerWorkerId)
    if worker == nil then
        return nil
    end
    local trailer, tractor = TheContractorTippedTrailer.getHaulRig(job)
    if trailer == nil then
        return nil
    end
    local trailerId = NetworkUtil.getObjectId(trailer)
    if TheContractorRoadAccident.isExcluded(trailerId) or self:isTipped(trailerId) then
        return nil
    end
    -- Still in this job's cooldown, or (forced from the console later) not
    -- out on another one.
    if not tc.Cooldown:isVehicleInCooldown(trailerId) and not tc.Allocation:isVehicleFree(farmId, trailer) then
        return nil
    end

    local field = g_fieldManager:getFieldById(job.fieldId)
    if field == nil then
        return nil
    end
    -- The tractor's left at the scene too if it's ours and (as for the
    -- trailer) in this job's cooldown or free.
    local tractorId = tractor ~= nil and NetworkUtil.getObjectId(tractor) or 0
    if tractor ~= nil and (TheContractorRoadAccident.isExcluded(tractorId) or self:isAtScene(tractorId) or
            (not tc.Cooldown:isVehicleInCooldown(tractorId) and not tc.Allocation:isVehicleFree(farmId, tractor))) then
        tractor, tractorId = nil, 0
    end

    local fieldX, fieldZ = field:getCenterOfFieldWorldPosition()
    local placement, tractorPlacement = TheContractorTippedTrailer.findPlacement(trailer, tractor, farmId, fieldX,
        fieldZ, random)
    if placement == nil then
        TCLog.info("TheContractor: farm %d job %d: no road near field %d to tip a trailer on", farmId, job.id,
            job.fieldId)
        return nil
    end

    tractorPlacement = tractorPlacement or { x = 0, z = 0, rotY = 0 }
    return {
        jobId = job.id,
        fieldId = job.fieldId,
        workerId = worker.id,
        workerName = worker.name,
        vehicleId = trailerId,
        vehicleUniqueId = trailer.getUniqueId ~= nil and trailer:getUniqueId() or "",
        vehicleName = trailer:getFullName(),
        tractorId = tractorId,
        tractorUniqueId = tractor ~= nil and tractor.getUniqueId ~= nil and tractor:getUniqueId() or "",
        tractorName = tractor ~= nil and tractor:getFullName() or "",
        tractorX = tractorPlacement.x,
        tractorZ = tractorPlacement.z,
        tractorRotY = tractorPlacement.rotY,
        x = placement.x,
        z = placement.z,
        dirX = placement.dirX,
        dirZ = placement.dirZ,
        sideX = placement.sideX,
        sideZ = placement.sideZ,
        trailerSeverity = randomBetween(random, TheContractorTippedTrailer.TRAILER_DAMAGE_MIN,
            TheContractorTippedTrailer.TRAILER_DAMAGE_MAX),
        tractorSeverity = randomBetween(random, TheContractorTippedTrailer.TRACTOR_DAMAGE_MIN,
            TheContractorTippedTrailer.TRACTOR_DAMAGE_MAX),
        reputationPenalty = math.floor(math.max(TheContractorTippedTrailer.MIN_REPUTATION_PENALTY,
            TheContractorJobs.getBaseReputationReward(job) * TheContractorTippedTrailer.REPUTATION_PENALTY_MULTIPLIER)),
    }
end

-- Laying it down (server) ------------------------------------------------------------

-- Facing along the road, rolled a quarter turn so its up axis points
-- (sideX, sideZ) back across the road. Engine side, replaced in the tests.
function TheContractorTippedTrailer.getTippedRotation(dirX, dirZ, sideX, sideZ)
    local node = createTransformGroup("tcTippedTrailer")
    setDirection(node, dirX, 0, dirZ, 0, 1, 0)
    rotateAboutLocalAxis(node, math.pi * 0.5, 0, 0, 1)
    local upX, _, upZ = localDirectionToWorld(node, 0, 1, 0)
    if upX * sideX + upZ * sideZ < 0 then
        rotateAboutLocalAxis(node, -math.pi, 0, 0, 1)
    end
    local rotX, rotY, rotZ = getRotation(node)
    delete(node)
    return rotX, rotY, rotZ
end

-- Puts the (hidden) trailer down on its side at the incident's spot and
-- reveals it on every machine. Its position replicates by itself. Returns
-- how far up its up axis points once it's set (about 0 on its side), for
-- the warning if the roll didn't take.
function TheContractorTippedTrailer.placeOnSide(trailer, data)
    local size = trailer.size or {}
    local height = size.height or 3
    local placement = { x = data.x, z = data.z, dirX = data.dirX, dirZ = data.dirZ, sideX = data.sideX,
        sideZ = data.sideZ, centreX = data.x + data.sideX * height * 0.5,
        centreZ = data.z + data.sideZ * height * 0.5 }
    local _, groundY = TheContractorTippedTrailer.getGroundRange(placement, size)
    -- Its side on the ground: half its width below its origin once rolled.
    local y = groundY + (size.width or 3) * 0.5
    local rotX, rotY, rotZ = TheContractorTippedTrailer.getTippedRotation(data.dirX, data.dirZ, data.sideX,
        data.sideZ)
    trailer:removeFromPhysics()
    trailer:setAbsolutePosition(data.x, y, data.z, rotX, rotY, rotZ)
    local upY = TheContractorTippedTrailer.getUpY(trailer)
    TCLog.info("TheContractor: '%s' put down at %.1f, %.1f, %.1f, rotation %.2f, %.2f, %.2f (up axis %.2f)",
        trailer:getFullName(), data.x, y, data.z, rotX, rotY, rotZ, upY)
    -- Frozen before it's revealed: the server's reveal leaves a frozen
    -- vehicle's physics alone (TCEquipmentVisibility.revealVehicle), so it
    -- never builds wheel shapes on it.
    TheContractorTippedTrailer.setLying(trailer, true)
    TCEquipmentVisibility.setVisibleEverywhere({ NetworkUtil.getObjectId(trailer) }, true)
    return upY
end

-- Frozen while it's over. Physics won't keep a vehicle on its side: its
-- wheels push it off the ground, and vehicle XMLs put each component's
-- centre of mass low enough that it swings back upright (a trailer bought
-- in the shop and laid on its side does the same). Switching its wheels'
-- collision off and moving its centre of mass to the grounded side were
-- both tried in game (2026-10-26) and it was still back on its wheels in
-- under 2 s. So each component is made KINEMATIC, as vanilla's Mountable
-- does to a mounted object, and stays exactly where it was put: nothing
-- moves it, a loader included. Righting it yourself is the R prompt by the
-- trailer instead (TCTippedTrailerActivatable, rightTrailer).
--
-- Wheel shapes only live on a dynamic body. Making a body kinematic while
-- it has them deletes them, and the commands vanilla queued for them that
-- frame (setForcePoint, setWidth, ...) then log physics errors (seen in
-- game, one burst per wheel). So the vehicle is taken out of physics first
-- (vanilla's removeFromPhysics, which clears its wheels' shapes), made
-- kinematic, and only its components are put back (the engine's own
-- addToPhysics on each node), for collision. The vehicle stays flagged out
-- of physics (isAddedToPhysics false), and vanilla's wheel code skips any
-- vehicle that is, so it never builds wheel shapes on the frozen body.
-- Unfreezing takes it out again and makes it dynamic, leaving it out of
-- physics for whatever puts it down next (placeUpright, the parking queue,
-- or checkTrailers) to add back properly. Server only: clients' vehicles
-- are kinematic anyway, moved by the server's positions, and have no wheel
-- shapes. Nothing's saved, so a load freezes it again
-- (resolveSavedVehicles). Engine side, replaced in the tests.
function TheContractorTippedTrailer.setLying(vehicle, isLying)
    if isLying and not vehicle.tcFrozen then
        vehicle.tcFrozen = true
        vehicle:removeFromPhysics()
        for _, component in ipairs(vehicle.components or {}) do
            if component.node ~= nil then
                setRigidBodyType(component.node, RigidBodyType.KINEMATIC)
                addToPhysics(component.node)
            end
        end
    elseif not isLying and vehicle.tcFrozen then
        vehicle.tcFrozen = nil
        vehicle:removeFromPhysics()
        for _, component in ipairs(vehicle.components or {}) do
            if component.node ~= nil then
                setRigidBodyType(component.node,
                    component.isDynamic and RigidBodyType.DYNAMIC or RigidBodyType.KINEMATIC)
            end
        end
    end
end

-- How far up (-1 to 1) the vehicle's up axis points. Engine side.
function TheContractorTippedTrailer.getUpY(vehicle)
    if vehicle.rootNode == nil then
        return 1
    end
    local _, upY, _ = localDirectionToWorld(vehicle.rootNode, 0, 1, 0)
    return upY
end

-- Whether it's back on its wheels. Engine side, replaced in the tests.
function TheContractorTippedTrailer.isUpright(vehicle)
    return TheContractorTippedTrailer.getUpY(vehicle) >= TheContractorTippedTrailer.UPRIGHT_MIN_Y
end

-- Pushed back onto its wheels: stood up where its body lay, facing along
-- the road, just above the ground (as the parking queue puts a vehicle
-- down). Already unfrozen (cleanUp). Its position replicates by itself.
-- Engine side, replaced in the tests.
function TheContractorTippedTrailer.placeUpright(trailer, data)
    local height = (trailer.size or {}).height or 3
    local x = data.x + data.sideX * height * 0.5
    local z = data.z + data.sideZ * height * 0.5
    local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + TCParking.PLACE_HEIGHT_OFFSET
    trailer:removeFromPhysics()
    trailer:setAbsolutePosition(x, y, z, 0, MathUtil.getYRotationFromDirection(data.dirX, data.dirZ), 0)
    trailer:addToPhysics()
end

-- The (hidden) tractor stood at its spot by the trailer and revealed on
-- every machine. Engine side, replaced in the tests.
function TheContractorTippedTrailer.placeTractor(tractor, data)
    local y = getTerrainHeightAtWorldPos(g_terrainNode, data.tractorX, 0, data.tractorZ) +
        TCParking.PLACE_HEIGHT_OFFSET
    tractor:removeFromPhysics()
    tractor:setAbsolutePosition(data.tractorX, y, data.tractorZ, 0, data.tractorRotY, 0)
    TCEquipmentVisibility.setVisibleEverywhere({ NetworkUtil.getObjectId(tractor) }, true)
end

-- Stages (server) ------------------------------------------------------------------

-- Takes its message and notice down, and unfreezes the trailer, leaving it
-- out of physics (see setLying) for the caller to put down.
function TheContractorTippedTrailer:cleanUp(incident)
    local tc = g_currentMission.TheContractor
    local trailer = getLiveVehicle(incident.data.vehicleId)
    if trailer ~= nil then
        TheContractorTippedTrailer.setLying(trailer, false)
    end
    if incident.data.messageId ~= nil then
        tc.Inbox:removeMessage(incident.data.messageId)
        incident.data.messageId = nil
    end
    if incident.data.noticeId ~= nil then
        tc.Notices:remove(incident.data.noticeId)
        incident.data.noticeId = nil
    end
end

function TheContractorTippedTrailer:onTipped(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local farmId = incident.farmId
    local trailer = getLiveVehicle(data.vehicleId)
    if trailer == nil then
        return TheContractorRandomEvents.DONE
    end

    -- Both out of the cooldown (and the parking queue, from the console),
    -- the trailer off the tractor and down on the road, the tractor just
    -- ahead of it. The rest of the job's kit comes home as usual.
    local tractor = getLiveVehicle(data.tractorId)
    local sceneIds = { data.vehicleId }
    if tractor ~= nil then
        table.insert(sceneIds, data.tractorId)
    end
    tc.Cooldown:releaseVehicles(sceneIds)
    tc.Parking:removeVehicles(sceneIds)
    TCJobSiteSetup.unhitchVehicles({ data.vehicleId })
    local upY = TheContractorTippedTrailer.placeOnSide(trailer, data)
    if tractor ~= nil then
        TheContractorTippedTrailer.placeTractor(tractor, data)
    end
    if upY ~= nil and upY >= TheContractorTippedTrailer.UPRIGHT_MIN_Y then
        TCLog.warning("TheContractor: incident %d: the %s was put down upright (up axis %.2f), not on its side",
            incident.id, data.vehicleName, upY)
    end
    self.placedAtByIncident[incident.id] = g_time
    TCVehicleLock.refresh()

    TheContractorRoadAccident.damageVehicle(trailer, data.trailerSeverity)
    if tractor ~= nil then
        TheContractorRoadAccident.damageVehicle(tractor, data.tractorSeverity)
    end

    local worker = tc.Staff:getWorker(farmId, data.workerId)
    if worker ~= nil then
        tc.Morale:adjust(farmId, { worker }, TheContractorTippedTrailer.MORALE_PENALTY)
    end
    tc.Reputation:addReputation(farmId, -data.reputationPenalty)

    data.noticeId = tc.Notices:publish(farmId, string.format(g_i18n:getText("tc_tippedTrailer_notice"),
        data.vehicleName, data.fieldId))

    TCLog.info("TheContractor: farm %d incident %d: %s tipped the %s (%.2f) on the way back from field %d at %.0f, %.0f; %s damaged (%.2f), -%d reputation",
        farmId, incident.id, data.workerName, data.vehicleName, data.trailerSeverity, data.fieldId, data.x, data.z,
        data.tractorName, data.tractorSeverity, data.reputationPenalty)
    return nil
end

-- The choice: a recovery firm or the farm itself. Stays up until answered
-- or the trailer's righted.
function TheContractorTippedTrailer:onOffer(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    data.recoveryCost = tc.Settings:scaleCost(TheContractorTippedTrailer.RECOVERY_COST)

    local bodyKey = "tc_tippedTrailer_body"
    local args = { data.fieldId, data.workerName, data.vehicleName, data.tractorName, "$money_" .. data.recoveryCost }
    if data.tractorName == "" then
        bodyKey = "tc_tippedTrailer_bodyNoTractor"
        args = { data.fieldId, data.workerName, data.vehicleName, "$money_" .. data.recoveryCost }
    end
    data.messageId = tc.Inbox:postMessage(incident.farmId, TheContractorTippedTrailer.MESSAGE_KIND,
        "tc_tippedTrailer_title", bodyKey, args,
        {
            { key = TheContractorTippedTrailer.ACTION.RECOVER, textKey = "tc_tippedTrailer_recoverButton" },
            { key = TheContractorTippedTrailer.ACTION.DIY, textKey = "tc_tippedTrailer_diyButton" },
        },
        { incidentId = incident.id, recoveryCost = data.recoveryCost })
    return TheContractorRandomEvents.WAIT
end

-- The message's answer. The inbox takes the message down after this.
function TheContractorTippedTrailer:onMessageAnswered(message, actionKey)
    local incident = self.randomEvents:getIncident(message.payload.incidentId)
    if incident == nil or incident.stage ~= TheContractorTippedTrailer.STAGE.OFFER then
        return
    end
    incident.data.messageId = nil

    local STAGE = TheContractorTippedTrailer.STAGE
    self.randomEvents:goToStage(incident,
        actionKey == TheContractorTippedTrailer.ACTION.RECOVER and STAGE.RECOVER or STAGE.DIY)
end

-- Paid for, and off to the parking queue, which parks it upright.
function TheContractorTippedTrailer:onRecover(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local farmId = incident.farmId
    self:cleanUp(incident)

    local trailer = getLiveVehicle(data.vehicleId)
    if trailer == nil then
        return TheContractorRandomEvents.DONE
    end

    local cost = data.recoveryCost or tc.Settings:scaleCost(TheContractorTippedTrailer.RECOVERY_COST)
    if cost > 0 then
        g_currentMission:addMoney(-cost, farmId, MoneyType.TC_RECOVERY, true, true)
        tc.Finances:recordRecovery(farmId, cost)
    end
    local returning = { data.vehicleId }
    if getLiveVehicle(data.tractorId) ~= nil then
        table.insert(returning, data.tractorId)
    end
    tc.Parking:returnVehicles(farmId, returning)

    TCLog.info("TheContractor: farm %d incident %d: recovery firm called out for the %s (%.0f), %d machine(s) back to the yard",
        farmId, incident.id, data.vehicleName, cost, #returning)
    return TheContractorRandomEvents.DONE
end

-- Left to the farm. Still on its side by now: the offer again.
function TheContractorTippedTrailer:onDiyCheck(incident)
    if getLiveVehicle(incident.data.vehicleId) == nil then
        self:cleanUp(incident)
        return TheContractorRandomEvents.DONE
    end
    return TheContractorTippedTrailer.STAGE.OFFER
end

-- The player pushed it back onto its wheels (TCRightTrailerEvent, from
-- the prompt by it). Server. Ignored for an incident that isn't this
-- farm's open tipped trailer.
function TheContractorTippedTrailer:rightTrailer(farmId, incidentId)
    if not g_currentMission:getIsServer() or self.randomEvents == nil then
        return
    end
    local incident = self.randomEvents:getIncident(incidentId)
    if incident == nil or incident.eventType ~= TheContractorTippedTrailer.EVENT_TYPE or
            incident.farmId ~= farmId or incident.stage == TheContractorTippedTrailer.STAGE.TIPPED then
        return
    end

    self:cleanUp(incident)
    local trailer = getLiveVehicle(incident.data.vehicleId)
    if trailer ~= nil then
        TheContractorTippedTrailer.placeUpright(trailer, incident.data)
    end
    self.placedAtByIncident[incident.id] = nil
    TCLog.info("TheContractor: farm %d incident %d: the %s pushed back onto its wheels", farmId, incident.id,
        incident.data.vehicleName)
    self.randomEvents:closeIncident(incident)
    TCVehicleLock.refresh()
end

-- Server tick: closes any incident whose trailer is back on its wheels,
-- or gone. Waits for the save's vehicles to be resolved.
function TheContractorTippedTrailer:update(dt)
    if not g_currentMission:getIsServer() or self.randomEvents == nil then
        return
    end
    local tc = g_currentMission.TheContractor
    if not tc.hasResolvedSavedVehicles then
        return
    end
    self.checkMs = self.checkMs + dt
    if self.checkMs < TheContractorTippedTrailer.CHECK_INTERVAL_MS then
        return
    end
    self.checkMs = 0
    self:checkTrailers()
end

function TheContractorTippedTrailer:checkTrailers()
    local done = {}
    for _, incident in pairs(self.randomEvents.incidents) do
        if incident.eventType == TheContractorTippedTrailer.EVENT_TYPE and
                incident.stage ~= TheContractorTippedTrailer.STAGE.TIPPED then
            local trailer = getLiveVehicle(incident.data.vehicleId)
            if trailer == nil or TheContractorTippedTrailer.isUpright(trailer) then
                table.insert(done, { incident = incident, isGone = trailer == nil })
            end
        end
    end
    table.sort(done, function(a, b)
        return a.incident.id < b.incident.id
    end)

    for _, entry in ipairs(done) do
        local incident = entry.incident
        local placedAt = self.placedAtByIncident[incident.id]
        self.placedAtByIncident[incident.id] = nil
        if not entry.isGone and placedAt ~= nil and g_time ~= nil and
                g_time - placedAt < TheContractorTippedTrailer.SELF_RIGHTED_MS then
            TCLog.warning("TheContractor: incident %d: the %s was back on its wheels %.1f s after being put down on its side",
                incident.id, incident.data.vehicleName, (g_time - placedAt) / 1000)
        end
        self:cleanUp(incident)
        -- Righted some other way (vanilla's reset): back in physics where
        -- it stands.
        local trailer = getLiveVehicle(incident.data.vehicleId)
        if trailer ~= nil and not trailer.isAddedToPhysics then
            trailer:addToPhysics()
        end
        TCLog.info("TheContractor: farm %d incident %d: the %s is %s", incident.farmId, incident.id,
            incident.data.vehicleName, entry.isGone and "gone" or "back on its wheels")
        self.randomEvents:closeIncident(incident)
        TCVehicleLock.refresh()
    end
end

-- Saved vehicles (server) ---------------------------------------------------------------

-- Once, after the save's vehicles exist: the trailer's object id from its
-- uniqueId. One that's gone is left at 0 and the next check closes it.
function TheContractorTippedTrailer:resolveSavedVehicles()
    if self.randomEvents == nil then
        return
    end
    for _, incident in pairs(self.randomEvents.incidents) do
        if incident.eventType == TheContractorTippedTrailer.EVENT_TYPE then
            local uniqueId = incident.data.vehicleUniqueId
            incident.data.vehicleId = uniqueId ~= nil and uniqueId ~= "" and TCVehicleIds.getObjectId(uniqueId) or 0
            -- The tractor, if it was left at the scene.
            local tractorUniqueId = incident.data.tractorUniqueId
            incident.data.tractorId = incident.data.tractorId ~= 0 and tractorUniqueId ~= nil and
                tractorUniqueId ~= "" and TCVehicleIds.getObjectId(tractorUniqueId) or 0
            -- Loaded on its side with its wheels and balance back: lying
            -- again before they roll it over.
            local trailer = getLiveVehicle(incident.data.vehicleId)
            if trailer ~= nil then
                TheContractorTippedTrailer.setLying(trailer, true)
            end
        end
    end
end

-- Persistence (nothing of its own - see the header) ---------------------------------

function TheContractorTippedTrailer:loadFromXMLFile(xmlFile)
end

function TheContractorTippedTrailer:saveToXmlFile(xmlFile)
end

function TheContractorTippedTrailer:writeInitialClientState(streamId, connection)
end

function TheContractorTippedTrailer:readInitialClientState(streamId, connection)
end
