-- Rigs a hired-worker job's allocated equipment (018) and puts it on the
-- job's field, ready for 020's AI dispatch: workers don't drive to the
-- field, the equipment is taken out of the yard (hidden - see
-- TheContractorDispatch:startJobForWorker), hitched together, and
-- teleported to the field's center.
--
--   operating vehicle  the self-propelled piece the AI Helper drives - the
--                      tractor, or a combine for harvest (pickOperatingVehicle)
--   implements         every other allocated piece with an input attacher
--                      joint (plow, header, trailed harvester...), hitched to
--                      the operating vehicle - or to an already-hitched job
--                      implement, e.g. a header on a trailed harvester - at
--                      the first free compatible attacher joint
--
-- Joint matching follows vanilla's own attach-range search
-- (AttacherJoints.updateVehiclesInAttachRange): same jointType, and
-- AttacherJoints.getAttacherJointCompatibility (subtypes, forced direction,
-- brand/vehicle restrictions). Rear joints are preferred over front. If the
-- only compatible joint is occupied by something that isn't part of the
-- job (e.g. a different implement left hitched), that occupant is unhitched
-- and left behind in the yard.
--
-- Teleport uses vanilla's FSBaseMission:teleportVehicle (the map's own
-- vehicle teleport), which carries anything already hitched along with it.
-- Server-only: vehicle positions and VehicleAttachEvent both replicate to
-- clients by themselves.
--
-- Before anything moves, any non-job implement hitched to a job vehicle is
-- unhitched (detachForeignImplements), so nothing that isn't part of the
-- job ever leaves the yard, and the dispatch has each one parked in a free
-- parking slot if there's room, else left where it stood. A ballast weight
-- (TCBallast) is the exception: it stays on unless a job implement needs
-- its hitch (a front mower where the front weight is), and goes out and
-- comes back with its machine.
--
-- Going home: once the job's done, the equipment goes to 062's parking
-- return queue (Parking.lua), which unhitches every piece but its weights
-- (unhitchVehicles) and parks each one in a free parking slot. Nothing is
-- re-hitched.

TCJobSiteSetup = {}

-- Rear hitch (attacherJointDirection -1) beats front for implements that
-- could go either way.
local function scoreJoint(attacherJoint, needsDetach)
    local score = needsDetach and 0 or 2
    if attacherJoint.attacherJointDirection == -1 then
        score = score + 1
    end
    return score
end

local function pickOperatingVehicle(vehicles)
    local fallback = nil
    for _, vehicle in ipairs(vehicles) do
        if vehicle.spec_motorized ~= nil then
            if vehicle.spec_attacherJoints ~= nil then
                return vehicle
            end
            fallback = fallback or vehicle
        end
    end
    return fallback
end

-- Best free (or freeable) joint on `attacher` for `implement`, skipping
-- joints already claimed in this rigging pass. Returns a plan entry or nil.
-- Also asks the implement itself (Attachable:isAttachAllowed), the same
-- gate vanilla's own attach input goes through - it's where e.g.
-- Cutter:isAttachAllowed refuses a header whose crop the harvester's tank
-- can't take.
local function findJoint(attacher, implement, claimedJoints, isJobVehicle, farmId)
    if attacher.getAttacherJoints == nil then
        return nil
    end
    if implement.isAttachAllowed ~= nil and not implement:isAttachAllowed(farmId, attacher) then
        return nil
    end

    local best = nil
    for jointIndex, attacherJoint in ipairs(attacher:getAttacherJoints()) do
        local claimKey = tostring(attacher) .. ":" .. jointIndex
        if not claimedJoints[claimKey] and not attacherJoint.isBlocked then
            local occupantEntry = attacher:getImplementByJointDescIndex(jointIndex)
            local occupant = occupantEntry ~= nil and occupantEntry.object or nil
            if occupant == nil or not isJobVehicle[occupant] then
                for inputIndex, inputJoint in ipairs(implement:getInputAttacherJoints()) do
                    if inputJoint.jointType == attacherJoint.jointType and
                        AttacherJoints.getAttacherJointCompatibility(attacher, attacherJoint, implement, inputJoint) then
                        local score = scoreJoint(attacherJoint, occupant ~= nil)
                        if best == nil or score > best.score then
                            best = {
                                attacher = attacher,
                                jointIndex = jointIndex,
                                inputIndex = inputIndex,
                                occupant = occupant,
                                claimKey = claimKey,
                                score = score,
                            }
                        end
                    end
                end
            end
        end
    end
    return best
end

-- Places `implement` so its input attacher joint sits on the attacher's
-- joint, facing the attacher's heading, then hitches it without vanilla's
-- smooth-attach easing (there's nobody watching - it's still hidden).
local function hitch(plan, implement)
    local attacher = plan.attacher
    local attacherJoint = attacher:getAttacherJoints()[plan.jointIndex]
    local inputJoint = implement:getInputAttacherJoints()[plan.inputIndex]

    local jx, jy, jz = getWorldTranslation(attacherJoint.jointTransform)
    local dirX, _, dirZ = localDirectionToWorld(attacher.rootNode, 0, 0, 1)
    local yRot = MathUtil.getYRotationFromDirection(dirX, dirZ)

    -- Input joint's offset from the vehicle origin setAbsolutePosition
    -- places: its offset from the root component, plus the root
    -- component's own offset from that origin.
    local ox, oy, oz = localToLocal(inputJoint.node, implement.rootNode, 0, 0, 0)
    local rootOffset = implement.components[1].originalTranslation
    ox, oy, oz = ox + rootOffset[1], oy + rootOffset[2], oz + rootOffset[3]

    local sinY, cosY = math.sin(yRot), math.cos(yRot)
    local worldOffsetX = ox * cosY + oz * sinY
    local worldOffsetZ = -ox * sinY + oz * cosY

    implement:removeFromPhysics()
    implement:setAbsolutePosition(jx - worldOffsetX, jy - oy, jz - worldOffsetZ, 0, yRot, 0)
    implement:addToPhysics()

    attacher:attachImplement(implement, plan.inputIndex, plan.jointIndex, false, nil, false, true)
    -- Manual Attach pulls the PTO and hoses off a hitch made before the AI
    -- starts; nobody's there to connect them by hand.
    TCManualAttach.connectAll(attacher, implement)
end

-- 121, server-only: hitches a newly loaded implement to a machine (a
-- farmer's combine and its header), at the best free joint it fits.
-- Returns whether it hitched.
function TCJobSiteSetup.hitchImplement(attacher, implement, farmId)
    if implement.getInputAttacherJoints == nil then
        return false
    end
    local plan = findJoint(attacher, implement, {}, {}, farmId)
    if plan == nil or plan.occupant ~= nil then
        return false
    end
    hitch(plan, implement)
    return true
end

-- The job's equipment that still exists, and a set of it.
local function getJobVehicles(job)
    local vehicles = {}
    local isJobVehicle = {}
    for _, vehicleId in ipairs(job.assignedEquipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil then
            table.insert(vehicles, vehicle)
            isJobVehicle[vehicle] = true
        end
    end
    return vehicles, isJobVehicle
end

-- Plans every hitch of the job's equipment, moving nothing. Returns the
-- plans (each with its implement, and the occupant it would unhitch) and
-- the operating vehicle; or nil plus the reason's l10n key and its args
-- (TCDispatchFailedEvent.REASON_KEYS).
function TCJobSiteSetup.planHitches(job)
    local vehicles, isJobVehicle = getJobVehicles(job)
    local operatingVehicle = pickOperatingVehicle(vehicles)
    if operatingVehicle == nil then
        return nil, "tc_dispatch_noVehicleReady", {}
    end

    -- Multiple passes let a header find a trailed harvester that's itself only
    -- hitched earlier in the same plan.
    -- Seed tanks (a seeder's front hopper, 032) are planned last, so the
    -- seeder gets first pick of the (preferred) rear linkage and the tank
    -- takes what's left - the front.
    local toHitch = {}
    local seedTanks = {}
    for _, vehicle in ipairs(vehicles) do
        if vehicle ~= operatingVehicle and vehicle.getInputAttacherJoints ~= nil and
            not vehicle:getIsAttachedTo(operatingVehicle) then
            table.insert(TCEquipmentClass.isSeedTank(vehicle) and seedTanks or toHitch, vehicle)
        end
    end
    for _, vehicle in ipairs(seedTanks) do
        table.insert(toHitch, vehicle)
    end

    local attachers = { operatingVehicle }
    for _, vehicle in ipairs(vehicles) do
        if vehicle ~= operatingVehicle and vehicle.getInputAttacherJoints ~= nil and
            vehicle:getIsAttachedTo(operatingVehicle) then
            table.insert(attachers, vehicle)
        end
    end

    local plans = {}
    local claimedJoints = {}
    local remaining = toHitch
    while #remaining > 0 do
        local unplanned = {}
        for _, implement in ipairs(remaining) do
            local plan = nil
            for _, attacher in ipairs(attachers) do
                plan = findJoint(attacher, implement, claimedJoints, isJobVehicle, job.farmId)
                if plan ~= nil then
                    break
                end
            end
            if plan ~= nil then
                plan.implement = implement
                claimedJoints[plan.claimKey] = true
                table.insert(plans, plan)
                table.insert(attachers, implement)
            else
                table.insert(unplanned, implement)
            end
        end

        if #unplanned == #remaining then
            local names = {}
            for _, implement in ipairs(unplanned) do
                table.insert(names, implement:getName())
            end
            return nil, "tc_dispatch_noAttachPoint", { table.concat(names, ", "), operatingVehicle:getName() }
        end
        remaining = unplanned
    end
    return plans, operatingVehicle
end

-- Server-only. Returns the operating vehicle on success, or nil plus the
-- reason's l10n key and its args (TCDispatchFailedEvent.REASON_KEYS).
function TCJobSiteSetup.rigAndPlace(job)
    local field = g_fieldManager:getFieldById(job.fieldId)
    if field == nil then
        return nil, "tc_dispatch_noVehicleReady", {}
    end

    -- Plan every hitch before moving anything, so a job that can't be
    -- rigged fails without leaving equipment half-unhitched.
    local plans, operatingVehicle, reasonArgs = TCJobSiteSetup.planHitches(job)
    if plans == nil then
        return nil, operatingVehicle, reasonArgs
    end

    -- Hidden equipment is out of physics; teleporting and hitching both
    -- need it back in (it stays invisible until the dispatch reveals it).
    -- Weights go in after their machines, so their joints are rebuilt.
    local vehicles = getJobVehicles(job)
    for _, vehicle in ipairs(vehicles) do
        vehicle:addToPhysics()
    end
    for _, vehicle in ipairs(vehicles) do
        for _, weight in ipairs(TCBallast.getWeights(vehicle)) do
            weight:addToPhysics()
        end
    end

    -- Unhitch: foreign occupants of joints we need (left in the yard), and
    -- job implements from wherever they're currently hitched. A weight was
    -- only kept on because no plan needed its hitch at dispatch, so this
    -- shouldn't meet one; if it does, it's hidden with its machine, so it's
    -- shown where it's left.
    for _, plan in ipairs(plans) do
        if plan.occupant ~= nil then
            plan.attacher:detachImplementByObject(plan.occupant)
            if TCBallast.isWeight(plan.occupant) then
                TCEquipmentVisibility.setVisibleEverywhere({ NetworkUtil.getObjectId(plan.occupant) }, true)
            end
        end
    end
    for _, plan in ipairs(plans) do
        local currentAttacher = plan.implement.getAttacherVehicle ~= nil and plan.implement:getAttacherVehicle() or nil
        if currentAttacher ~= nil then
            currentAttacher:detachImplementByObject(plan.implement)
        end
    end

    local centerX, centerZ = field:getCenterOfFieldWorldPosition()
    local dirX, _, dirZ = localDirectionToWorld(operatingVehicle.rootNode, 0, 0, 1)
    g_currentMission:teleportVehicle(operatingVehicle, centerX, centerZ, MathUtil.getYRotationFromDirection(dirX, dirZ))

    for _, plan in ipairs(plans) do
        hitch(plan, plan.implement)
    end

    TCLog.info("TheContractor: job %d equipment rigged (%d hitched) and placed on field %d", job.id, #plans,
        job.fieldId)
    return operatingVehicle
end

-- Seed choice ---------------------------------------------------------------

-- Server-only. Sets each of a sow job's sowing machines to the job's crop
-- before the worker sets off: vanilla's AI Helper sows whatever seed the
-- machine was left on, so a planter last used for potatoes would plant
-- potatoes on a parsnip job. setSeedFruitType sends vanilla's own
-- SetSeedIndexEvent to the clients. A machine that can't take the crop
-- (allocation never picks one, TCEquipmentClass.canSowFruit) is left alone.
-- Returns how many machines were changed.
function TCJobSiteSetup.selectJobSeed(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef == nil or jobDef.implementSpec ~= "spec_sowingMachine" then
        return 0
    end
    local fruitTypeIndex = job:getFruitTypeIndex()
    if fruitTypeIndex == nil or fruitTypeIndex == FruitType.UNKNOWN then
        return 0
    end

    local changed = 0
    for _, vehicleId in ipairs(job.assignedEquipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        local spec = vehicle ~= nil and vehicle.spec_sowingMachine or nil
        if spec ~= nil and spec.seeds ~= nil and vehicle.setSeedFruitType ~= nil and
            spec.seeds[spec.currentSeed] ~= fruitTypeIndex and TCEquipmentClass.canSowFruit(vehicle, fruitTypeIndex) then
            vehicle:setSeedFruitType(fruitTypeIndex)
            changed = changed + 1
            TCLog.info("TheContractor: job %d: '%s' set to sow the job's crop (%s)", job.id, vehicle:getName(),
                tostring(job.fruitTypeName))
        end
    end
    return changed
end

-- Leaving and going home ----------------------------------------------------

-- Server-only. Unhitches anything that isn't part of the job from the job's
-- equipment, where it stands - it stays in the yard - except a weight
-- whose hitch no job implement needs (planHitches), which goes along.
-- Returns the ids of what it unhitched, and of anything still hitched to
-- those (a front loader's bucket), for the dispatch to park.
function TCJobSiteSetup.detachForeignImplements(job)
    local vehicles, isJobVehicle = getJobVehicles(job)

    local isNeededHitch = {}
    for _, plan in ipairs(TCJobSiteSetup.planHitches(job) or {}) do
        if plan.occupant ~= nil then
            isNeededHitch[plan.occupant] = true
        end
    end

    local detached = {}
    local function addWithChildren(object)
        table.insert(detached, NetworkUtil.getObjectId(object))
        if object.getAttachedImplements ~= nil then
            for _, implement in ipairs(object:getAttachedImplements()) do
                addWithChildren(implement.object)
            end
        end
    end

    for _, vehicle in ipairs(vehicles) do
        if vehicle.getAttachedImplements ~= nil then
            local foreign = {}
            for _, implement in ipairs(vehicle:getAttachedImplements()) do
                local object = implement.object
                if not isJobVehicle[object] and (isNeededHitch[object] or not TCBallast.isWeight(object)) then
                    table.insert(foreign, object)
                end
            end
            for _, object in ipairs(foreign) do
                vehicle:detachImplementByObject(object)
                addWithChildren(object)
            end
        end
    end
    return detached
end

-- Server-only. Unhitches every vehicle id from whatever it's hitched to,
-- and anything hitched to it, so each piece stands alone and can be parked
-- by itself (062) - except its ballast weights, which stay on and are
-- parked with it. Works on hidden equipment too.
function TCJobSiteSetup.unhitchVehicles(vehicleIds)
    for _, vehicleId in ipairs(vehicleIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil and not vehicle.isDeleted then
            local attacher = vehicle.getAttacherVehicle ~= nil and vehicle:getAttacherVehicle() or nil
            if attacher ~= nil then
                attacher:detachImplementByObject(vehicle)
            end
            if vehicle.getAttachedImplements ~= nil then
                local implements = {}
                for _, implement in ipairs(vehicle:getAttachedImplements()) do
                    if not TCBallast.isWeight(implement.object) then
                        table.insert(implements, implement.object)
                    end
                end
                for _, object in ipairs(implements) do
                    vehicle:detachImplementByObject(object)
                end
            end
        end
    end
end
