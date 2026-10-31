-- Tipped trailer (105): a job event (074) on harvest & haul jobs (035). As
-- the job completes, the hauler tips their trailer over on the last load,
-- in the field. They get the tractor unhitched (the drawbar's eye swivels,
-- so the tractor stays on its wheels). Both are taken out of the cooldown
-- (023) and left at the scene for the player to turn up to: the trailer
-- laid on its side SPOT_MIN_DISTANCE to SPOT_MAX_DISTANCE from the field's
-- centre in a random direction, all of it and its spill inside the field,
-- and the tractor on its wheels just ahead of it, slewed round a little.
-- The rest of the kit comes home as usual. (105 laid it by a road between
-- the field and the yard; 106 moved it into the field, since the game won't
-- keep a heap on tarmac and the spill came out patchy.)
--
-- Odds are per job, from the hauler's haulage skill alone (getChance):
-- CHANCE_AT_MIN_SKILL at 1 down to CHANCE_AT_MAX_SKILL at 10, no cooldown.
-- A hauler on about 40 harvest & haul jobs in two years tips one about once
-- in that time at skill 1, and about once in 16 years at 10.
--
-- Both machines are damaged (vanilla damage, or an ADS breakdown, as 079's
-- road accidents do it), the hauler's morale drops and the farm loses some
-- reputation. 106: its load goes onto the verge (TheContractorCropSpill),
-- with an urgent job to clear it and deliver it, and the inbox message
-- tells the story and ends with that job. It's left where it lies for the
-- player to push back onto its wheels: walk up to it and press the
-- activate key (TCTippedTrailerActivatable -> TCRightTrailerEvent ->
-- rightTrailer). 106 dropped the recovery firm 105 offered.
--
-- While it's on its side the trailer is frozen (setLying: physics won't keep a vehicle
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
-- tractorRotY), trailerSeverity, tractorSeverity, reputationPenalty, and
-- later spillJobId (106's job, 0 with no spill), messageId (only with no
-- spill: a spill's message goes with its job) and noticeId.

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

TheContractorTippedTrailer.CHECK_INTERVAL_MS = 2000
-- Its up axis at least this far up (cos of about 45 degrees) is upright.
TheContractorTippedTrailer.UPRIGHT_MIN_Y = 0.7

-- Where it can end up: this far from the field's centre (metres), in a
-- random direction, at a random heading, with the trailer, the tractor and
-- the heap's line all inside the field. At most SPOT_TRIES tried.
TheContractorTippedTrailer.SPOT_MIN_DISTANCE = 10
TheContractorTippedTrailer.SPOT_MAX_DISTANCE = 20
TheContractorTippedTrailer.SPOT_TRIES = 30
-- The ground under it can't rise or fall more than this across its
-- footprint. It's set down resting on the highest of it, never dropped (a
-- fall onto one edge rolls it back onto its wheels) and never sunk into the
-- ground (the physics pushing it out does the same), so this is as far as
-- it can settle.
TheContractorTippedTrailer.MAX_GROUND_GAP = 0.3
-- The tractor at the scene: this far ahead of the trailer's front, slewed
-- up to this many degrees either way off its line.
TheContractorTippedTrailer.TRACTOR_GAP = 2.0
TheContractorTippedTrailer.TRACTOR_SLEW_DEGREES = 25
-- Back on its wheels this soon after being put down is the physics
-- righting it, not the player: warned about.
TheContractorTippedTrailer.SELF_RIGHTED_MS = 30000

-- tipped: being put down. atScene: down, waiting to be righted.
TheContractorTippedTrailer.STAGE = {
    TIPPED = "tipped",
    AT_SCENE = "atScene",
}

function TheContractorTippedTrailer.new()
    local self = {}
    setmetatable(self, TheContractorTippedTrailer_mt)

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
        -- 106: whether the next missed spill brings a claim.
        console = {
            outcomes = { "claim", "noClaim" },
            setOutcome = function(outcome)
                g_currentMission.TheContractor.CropSpill:setForcedClaim(outcome == "claim")
                return string.format("The next missed spill will bring %s", outcome == "claim" and "a claim" or
                    "no claim")
            end,
        },
        stages = {
            { key = STAGE.TIPPED, run = function(incident)
                return self:onTipped(incident)
            end },
            { key = STAGE.AT_SCENE, run = function(incident)
                return TheContractorRandomEvents.WAIT
            end },
        },
    })

    -- 106: a spill's message names its job, and goes with it.
    inbox:registerMessageKind(TheContractorTippedTrailer.MESSAGE_KIND, {
        endsWithJob = true,
        category = "job",
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

-- On its side in the field, waiting to be righted.
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

-- Where the trailer goes with its footprint's centre at x, z, facing
-- heading (radians, as MathUtil.getYRotationFromDirection): its origin (the
-- wheels, half its height to one side), the footprint's centre, its facing
-- and the way its top points (sideX/Z). size is vehicle.size.
function TheContractorTippedTrailer.getPlacement(x, z, heading, size)
    local dirX, dirZ = math.sin(heading), math.cos(heading)
    local sideX, sideZ = dirZ, -dirX
    local height = size.height or 3
    return {
        x = x - sideX * height * 0.5,
        z = z - sideZ * height * 0.5,
        centreX = x,
        centreZ = z,
        dirX = dirX,
        dirZ = dirZ,
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

-- On flat enough ground with room for it on its side: trailer height
-- across, its length along, its width up. Engine side, replaced in the
-- tests.
function TheContractorTippedTrailer.isPlacementClear(placement, size)
    local minY, maxY = TheContractorTippedTrailer.getGroundRange(placement, size)
    if maxY - minY > TheContractorTippedTrailer.MAX_GROUND_GAP then
        return false
    end
    local rotY = MathUtil.getYRotationFromDirection(placement.dirX, placement.dirZ)
    return TCParking.isAreaClear(placement.centreX, placement.centreZ, rotY, size.height or 3, size.length or 8,
        size.width or 3)
end

-- Where the tractor stands for a trailer placement: just ahead of the
-- trailer's front (its +z, the way it faces), in line with it, slewed
-- slewRoll (0-1) of the way from -TRACTOR_SLEW_DEGREES to
-- +TRACTOR_SLEW_DEGREES off its line. { x, z, rotY }; sizes are
-- vehicle.size.
function TheContractorTippedTrailer.getTractorPlacement(placement, trailerSize, tractorSize, slewRoll)
    local T = TheContractorTippedTrailer
    local ahead = (trailerSize.length or 8) * 0.5 + T.TRACTOR_GAP + (tractorSize.length or 5) * 0.5
    local slew = math.rad((slewRoll * 2 - 1) * T.TRACTOR_SLEW_DEGREES)
    return {
        x = placement.centreX + placement.dirX * ahead,
        z = placement.centreZ + placement.dirZ * ahead,
        rotY = MathUtil.getYRotationFromDirection(placement.dirX, placement.dirZ) + slew,
    }
end

-- Room for the tractor on its wheels there. Engine side, replaced in the
-- tests.
function TheContractorTippedTrailer.isTractorPlacementClear(tractorPlacement, size)
    return TCParking.isAreaClear(tractorPlacement.x, tractorPlacement.z, tractorPlacement.rotY, size.width or 3,
        size.length or 5, size.height)
end

-- The field's outline, as { { x, z }, ... }. Engine side, replaced in the
-- tests.
function TheContractorTippedTrailer.getFieldBoundary(field)
    return TCJoyriderRuts.getFieldBoundary(field)
end

-- Whether every point is inside the field (a field without an outline
-- takes anything).
function TheContractorTippedTrailer.isInsideField(points, boundary)
    if #boundary == 0 then
        return true
    end
    for _, point in ipairs(points) do
        if not TCJoyriderRuts.isPointInside(point.x, point.z, boundary) then
            return false
        end
    end
    return true
end

-- The trailer lying there, and the heap 106 tips beside it, inside the
-- field.
function TheContractorTippedTrailer.isSpotInsideField(placement, size, boundary)
    local points = TheContractorTippedTrailer.getFootprintPoints(placement, size)
    local plan = TheContractorCropSpill.planSpill(placement, size)
    table.insert(points, { x = plan.heapStartX, z = plan.heapStartZ })
    table.insert(points, { x = plan.heapEndX, z = plan.heapEndZ })
    return TheContractorTippedTrailer.isInsideField(points, boundary)
end

-- A placement for the trailer in the field, and one for the tractor with
-- it if there's a tractor to leave there, or nil. random is for the tests.
function TheContractorTippedTrailer.findPlacement(trailer, tractor, field, random)
    local T = TheContractorTippedTrailer
    local size = trailer.size or {}
    local tractorSize = tractor ~= nil and tractor.size or {}
    local centreX, centreZ = field:getCenterOfFieldWorldPosition()
    local boundary = T.getFieldBoundary(field)
    for _ = 1, T.SPOT_TRIES do
        local angle = random() * 2 * math.pi
        local distance = T.SPOT_MIN_DISTANCE + random() * (T.SPOT_MAX_DISTANCE - T.SPOT_MIN_DISTANCE)
        local placement = T.getPlacement(centreX + math.sin(angle) * distance, centreZ + math.cos(angle) * distance,
            random() * 2 * math.pi, size)
        if T.isSpotInsideField(placement, size, boundary) and T.isPlacementClear(placement, size) then
            if tractor == nil then
                return placement, nil
            end
            local tractorPlacement = T.getTractorPlacement(placement, size, tractorSize, random())
            if T.isInsideField({ tractorPlacement }, boundary) and
                    T.isTractorPlacementClear(tractorPlacement, tractorSize) then
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
-- another job, or no room for it in the field. random is for the tests.
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

    local placement, tractorPlacement = TheContractorTippedTrailer.findPlacement(trailer, tractor, field, random)
    if placement == nil then
        TCLog.info("TheContractor: farm %d job %d: no room in field %d to tip a trailer over", farmId, job.id,
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

-- Facing (dirX, dirZ), rolled a quarter turn so its up axis points
-- (sideX, sideZ). Engine side, replaced in the tests.
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

-- Pushed back onto its wheels: stood up where its body lay, facing the way
-- it did, just above the ground (as the parking queue puts a vehicle
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
    -- the trailer off the tractor and down in the field, the tractor just
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

    -- 106: its load beside it, once both are down (the heap keeps out
    -- from under them).
    local sourceJob = tc.Jobs:getJob(farmId, data.jobId)
    local spillJob = tc.CropSpill:spill(farmId, sourceJob, trailer, data, incident.id)
    data.spillJobId = spillJob ~= nil and spillJob.id or 0
    self:postMessage(incident, spillJob)

    TCLog.info("TheContractor: farm %d incident %d: %s tipped the %s (%.2f) on the way back from field %d at %.0f, %.0f; %s damaged (%.2f), -%d reputation, spill job %d",
        farmId, incident.id, data.workerName, data.vehicleName, data.trailerSeverity, data.fieldId, data.x, data.z,
        data.tractorName, data.tractorSeverity, data.reputationPenalty, data.spillJobId)
    return nil
end

-- The story, with no choice to make. With a spill it says what's to be
-- done and goes with the job; without one it goes once the trailer's
-- righted (cleanUp).
function TheContractorTippedTrailer:postMessage(incident, spillJob)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local hasTractor = data.tractorName ~= ""
    local args = { data.fieldId, data.workerName, data.vehicleName }
    if hasTractor then
        table.insert(args, data.tractorName)
    end

    local bodyKey
    local payload = { incidentId = incident.id }
    if spillJob ~= nil then
        bodyKey = hasTractor and "tc_tippedTrailer_body" or "tc_tippedTrailer_bodyNoTractor"
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(spillJob.spill.fillTypeName)
        table.insert(args, "$volume_" .. math.floor(spillJob.spill.liters))
        table.insert(args, g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or spillJob.spill.fillTypeName)
        table.insert(args, "$volume_" .. math.floor(spillJob.requiredLiters))
        table.insert(args, spillJob.deliveryStationName or "?")
        payload.jobId = spillJob.id
    else
        bodyKey = hasTractor and "tc_tippedTrailer_bodyNoSpill" or "tc_tippedTrailer_bodyNoTractorNoSpill"
    end

    local messageId = tc.Inbox:postMessage(incident.farmId, TheContractorTippedTrailer.MESSAGE_KIND,
        "tc_tippedTrailer_title", bodyKey, args, nil, payload)
    if spillJob == nil then
        data.messageId = messageId
    end
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
