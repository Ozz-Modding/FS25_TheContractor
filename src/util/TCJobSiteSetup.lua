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
-- brand/vehicle restrictions), and never a joint that would leave an AI
-- implement facing backwards (wouldFaceBackwards: a rear mower on the
-- front linkage). Rear joints are preferred over front, even
-- an occupied rear over a free front. If the chosen joint is occupied by something that isn't part of the
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
-- could go either way, even when something foreign has to come off the
-- rear: most rear implements (a rear mower) don't force their direction,
-- so a free front hitch would take them backwards. A free joint only
-- breaks a tie between joints facing the same way.
local function scoreJoint(attacherJoint, needsDetach)
    local score = needsDetach and 0 or 1
    if attacherJoint.attacherJointDirection == -1 then
        score = score + 2
    end
    return score
end

-- A vehicle's forward in world space, allowing for a root that's modelled
-- facing backwards (yRotationOffset), as vanilla's own AI checks do.
local function getForward(node, yRotationOffset)
    local dirX, dirZ = 0, 1
    if yRotationOffset ~= nil and yRotationOffset ~= 0 then
        dirX, dirZ = MathUtil.getDirectionFromYRotation(yRotationOffset)
    end
    return localDirectionToWorld(node, dirX, 0, dirZ)
end

-- Whether hitching `implement` by `inputJoint` to `attacherJoint` would
-- leave it facing against its attacher: the attachment joint lines the
-- input joint's node up with the joint's transform, so a rear mower on a
-- front linkage ends up facing backwards. Vanilla's AI stops at once on
-- that (AIFieldWorker's "Tool attached incorrectly") for any implement
-- that needs root alignment, and XML rarely says which way a three-point
-- implement goes (forcedAttachingDirection is mostly left unset), so it's
-- worked out from the nodes. Works whatever way the pieces are parked:
-- only directions relative to each vehicle's own root are compared.
-- Also returns what it found, for the dev dialog's trace: { skipped =
-- "noRootAlignment"|"missingNodes" } when it wasn't worked out, else
-- { dot, implementLocal = { x, z } (the implement's forward in its input
-- joint's frame), hitchedForward = { x, z } (where that points once
-- hitched), attacherForward = { x, z } }.
local function wouldFaceBackwards(attacher, attacherJoint, implement, inputJoint)
    if implement.getAINeedsRootAlignment == nil or not implement:getAINeedsRootAlignment() then
        return false, { skipped = "noRootAlignment" }
    end
    if attacherJoint.jointTransform == nil or inputJoint.node == nil or implement.rootNode == nil then
        return false, { skipped = "missingNodes" }
    end
    -- The implement's forward, in its input joint's frame...
    local rx, ry, rz = getForward(implement.rootNode, implement.yRotationOffset)
    local lx, ly, lz = worldDirectionToLocal(inputJoint.node, rx, ry, rz)
    -- ...is where it'll point once that frame is the attacher joint's.
    local wx, _, wz = localDirectionToWorld(attacherJoint.jointTransform, lx, ly, lz)
    local attacherNode = attacher.rootNode
    if attacher.getAIDirectionNode ~= nil then
        attacherNode = attacher:getAIDirectionNode() or attacherNode
    end
    local fx, _, fz = getForward(attacherNode, attacher.yRotationOffset)
    local dot = wx * fx + wz * fz
    return dot < 0, { dot = dot, implementLocal = { lx, lz }, hitchedForward = { wx, wz }, attacherForward = { fx, fz } }
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
--
-- trace (optional, the dev dialog's): a table this attacher's verdict is
-- written into, decided exactly as without it: { attacher, attachRefused,
-- joints, chosen }. Each joint is { jointIndex, direction, jointType,
-- status, occupant, inputs }, its status "claimed" (by an earlier
-- implement in this plan), "blocked", "jobOccupied" (another job machine
-- is on it) or "checked". A checked joint's inputs are { inputIndex,
-- jointType, forcedDirection, typeMatch, compatible, warning, backwards,
-- facing (wouldFaceBackwards'), score (only for a usable pair) }.
local function findJoint(attacher, implement, claimedJoints, isJobVehicle, farmId, trace)
    trace = trace or {}
    trace.attacher = attacher
    trace.joints = {}
    if attacher.getAttacherJoints == nil then
        return nil
    end
    if implement.isAttachAllowed ~= nil and not implement:isAttachAllowed(farmId, attacher) then
        trace.attachRefused = true
        return nil
    end

    local best = nil
    for jointIndex, attacherJoint in ipairs(attacher:getAttacherJoints()) do
        local claimKey = tostring(attacher) .. ":" .. jointIndex
        local jointTrace = { jointIndex = jointIndex, direction = attacherJoint.attacherJointDirection,
            jointType = attacherJoint.jointType, inputs = {} }
        table.insert(trace.joints, jointTrace)
        if claimedJoints[claimKey] then
            jointTrace.status = "claimed"
        elseif attacherJoint.isBlocked then
            jointTrace.status = "blocked"
        else
            local occupantEntry = attacher:getImplementByJointDescIndex(jointIndex)
            local occupant = occupantEntry ~= nil and occupantEntry.object or nil
            jointTrace.occupant = occupant
            if occupant ~= nil and isJobVehicle[occupant] then
                jointTrace.status = "jobOccupied"
            else
                jointTrace.status = "checked"
                for inputIndex, inputJoint in ipairs(implement:getInputAttacherJoints()) do
                    local input = { inputIndex = inputIndex, jointType = inputJoint.jointType,
                        forcedDirection = inputJoint.forcedAttachingDirection,
                        typeMatch = inputJoint.jointType == attacherJoint.jointType }
                    table.insert(jointTrace.inputs, input)
                    if input.typeMatch then
                        input.compatible, input.warning = AttacherJoints.getAttacherJointCompatibility(attacher,
                            attacherJoint, implement, inputJoint)
                        input.compatible = input.compatible == true
                        if input.compatible then
                            input.backwards, input.facing = wouldFaceBackwards(attacher, attacherJoint, implement,
                                inputJoint)
                        end
                    end
                    if input.typeMatch and input.compatible and not input.backwards then
                        local score = scoreJoint(attacherJoint, occupant ~= nil)
                        input.score = score
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
    trace.chosen = best
    return best
end

-- Unhitches `object` from `attacher`. 177: with Attach Implements Manually,
-- a trailer's handbrake goes on, so nothing we leave standing rolls away.
local function unhitch(attacher, object)
    attacher:detachImplementByObject(object)
    TCAttachImplementsManually.onDetached(object)
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
    -- starts; nobody's there to connect them by hand. 177: Attach
    -- Implements Manually leaves them (and the top link) off, and a
    -- trailer's handbrake on.
    TCManualAttach.connectAll(attacher, implement)
    TCAttachImplementsManually.connectAll(attacher, implement)
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
--
-- trace (optional, the dev dialog's, TCJobSiteSetup.explainHitches): a
-- table the planning's written into as it goes, without changing it:
-- { operatingVehicle, order (the implements in the order they're
-- planned), steps }. A step is one implement's turn in one pass:
-- { implement, pass, attempts (findJoint's trace for each attacher it
-- tried, in order), plan (nil if nothing fitted this pass) }.
function TCJobSiteSetup.planHitches(job, trace)
    trace = trace or {}
    trace.steps = {}
    trace.order = {}
    local vehicles, isJobVehicle = getJobVehicles(job)
    local operatingVehicle = pickOperatingVehicle(vehicles)
    trace.operatingVehicle = operatingVehicle
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
    for _, vehicle in ipairs(toHitch) do
        table.insert(trace.order, vehicle)
    end

    -- Already on the operating vehicle: left where it is, never planned.
    trace.alreadyAttached = {}
    local attachers = { operatingVehicle }
    for _, vehicle in ipairs(vehicles) do
        if vehicle ~= operatingVehicle and vehicle.getInputAttacherJoints ~= nil and
            vehicle:getIsAttachedTo(operatingVehicle) then
            table.insert(attachers, vehicle)
            table.insert(trace.alreadyAttached, vehicle)
        end
    end

    local plans = {}
    local claimedJoints = {}
    local remaining = toHitch
    local pass = 0
    while #remaining > 0 do
        pass = pass + 1
        local unplanned = {}
        for _, implement in ipairs(remaining) do
            local plan = nil
            local step = { implement = implement, pass = pass, attempts = {} }
            table.insert(trace.steps, step)
            for _, attacher in ipairs(attachers) do
                local attempt = {}
                table.insert(step.attempts, attempt)
                plan = findJoint(attacher, implement, claimedJoints, isJobVehicle, job.farmId, attempt)
                if plan ~= nil then
                    break
                end
            end
            step.plan = plan
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
            unhitch(plan.attacher, plan.occupant)
            if TCBallast.isWeight(plan.occupant) then
                TCEquipmentVisibility.setVisibleEverywhere({ NetworkUtil.getObjectId(plan.occupant) }, true)
            end
        end
    end
    for _, plan in ipairs(plans) do
        local currentAttacher = plan.implement.getAttacherVehicle ~= nil and plan.implement:getAttacherVehicle() or nil
        if currentAttacher ~= nil then
            unhitch(currentAttacher, plan.implement)
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
                unhitch(vehicle, object)
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
                unhitch(attacher, vehicle)
            end
            if vehicle.getAttachedImplements ~= nil then
                local implements = {}
                for _, implement in ipairs(vehicle:getAttachedImplements()) do
                    if not TCBallast.isWeight(implement.object) then
                        table.insert(implements, implement.object)
                    end
                end
                for _, object in ipairs(implements) do
                    unhitch(vehicle, object)
                end
            end
        end
    end
end
