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
-- Going home: before anything moves, any non-job implement hitched to a
-- job vehicle is unhitched and left in the yard (detachForeignImplements),
-- so nothing that isn't part of the job ever leaves it. Once the job's
-- done, the equipment goes to 062's parking return queue (Parking.lua),
-- which unhitches every piece (unhitchVehicles) and parks each one in a
-- free parking slot. Nothing is re-hitched.

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
end

-- Server-only. Returns the operating vehicle on success, or nil plus a
-- player-facing reason.
function TCJobSiteSetup.rigAndPlace(job)
    local field = g_fieldManager:getFieldById(job.fieldId)
    if field == nil then
        return nil, g_i18n:getText("tc_dispatch_noVehicleReady")
    end

    local vehicles = {}
    local isJobVehicle = {}
    for _, vehicleId in ipairs(job.assignedEquipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil then
            table.insert(vehicles, vehicle)
            isJobVehicle[vehicle] = true
        end
    end

    local operatingVehicle = pickOperatingVehicle(vehicles)
    if operatingVehicle == nil then
        return nil, g_i18n:getText("tc_dispatch_noVehicleReady")
    end

    -- Hidden equipment is out of physics; teleporting and hitching both
    -- need it back in (it stays invisible until the dispatch reveals it).
    for _, vehicle in ipairs(vehicles) do
        vehicle:addToPhysics()
    end

    -- Plan every hitch before moving anything, so a job that can't be
    -- rigged fails without leaving equipment half-unhitched. Multiple
    -- passes let a header find a trailed harvester that's itself only
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
            return nil, string.format(g_i18n:getText("tc_dispatch_noAttachPoint"), table.concat(names, ", "),
                operatingVehicle:getName())
        end
        remaining = unplanned
    end

    -- Unhitch: foreign occupants of joints we need (left in the yard), and
    -- job implements from wherever they're currently hitched.
    for _, plan in ipairs(plans) do
        if plan.occupant ~= nil then
            plan.attacher:detachImplementByObject(plan.occupant)
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

-- Going home ----------------------------------------------------------------

local function resolveJobVehicles(job)
    local vehicles = {}
    for _, vehicleId in ipairs(job.assignedEquipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil then
            table.insert(vehicles, vehicle)
        end
    end
    return vehicles
end

-- Server-only. Unhitches anything that isn't part of the job from the job's
-- equipment, where it stands - it stays in the yard.
function TCJobSiteSetup.detachForeignImplements(job)
    local vehicles = resolveJobVehicles(job)
    local isJobVehicle = {}
    for _, vehicle in ipairs(vehicles) do
        isJobVehicle[vehicle] = true
    end

    for _, vehicle in ipairs(vehicles) do
        if vehicle.getAttachedImplements ~= nil then
            local foreign = {}
            for _, implement in ipairs(vehicle:getAttachedImplements()) do
                if not isJobVehicle[implement.object] then
                    table.insert(foreign, implement.object)
                end
            end
            for _, object in ipairs(foreign) do
                vehicle:detachImplementByObject(object)
            end
        end
    end
end

-- Server-only. Unhitches every vehicle id from whatever it's hitched to,
-- and anything hitched to it, so each piece stands alone and can be parked
-- by itself (062). Works on hidden equipment too.
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
                    table.insert(implements, implement.object)
                end
                for _, object in ipairs(implements) do
                    vehicle:detachImplementByObject(object)
                end
            end
        end
    end
end
