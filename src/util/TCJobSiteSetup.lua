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
-- Going home: before anything moves, recordHome snapshots where every job
-- vehicle stood (job.equipmentHome, persisted with the job), and any
-- non-job implement hitched to one of them is unhitched and left in the
-- yard (detachForeignImplements), so nothing that isn't part of the job
-- ever leaves it. Once the job's done (end of 023's cooldown, or straight
-- away for a job missed with no work done), returnHome unhitches the job's
-- equipment and puts each piece back exactly where it stood. Nothing is
-- re-hitched - whatever it was hitched to before may be gone by then. A
-- later ticket may replace "where it stood" with defined equipment areas.

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

    Logging.info("TheContractor: job %d equipment rigged (%d hitched) and placed on field %d", job.id, #plans,
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

-- Server-only. Snapshots every job vehicle's component world transforms -
-- the same shape Vehicle:setAbsolutePosition's componentPositions takes, so
-- multi-component vehicles go back exactly as they were. Only the first
-- dispatch of a job records: a watchdog retry or post-load resume starts
-- from the field, which isn't home.
function TCJobSiteSetup.recordHome(job)
    if job.equipmentHome ~= nil then
        return
    end

    local home = {}
    for _, vehicle in ipairs(resolveJobVehicles(job)) do
        local components = {}
        for i, component in ipairs(vehicle.components) do
            local x, y, z = getWorldTranslation(component.node)
            local rx, ry, rz = getWorldRotation(component.node)
            components[i] = { { x, y, z }, { rx, ry, rz } }
        end
        table.insert(home, { vehicleId = NetworkUtil.getObjectId(vehicle), components = components })
    end
    job.equipmentHome = home
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

-- Server-only. Unhitches the job's equipment and puts each piece back where
-- recordHome found it. Visibility is left alone - during a cooldown the
-- equipment is still hidden and gets revealed by the cooldown's own end.
function TCJobSiteSetup.returnHome(job)
    local home = job.equipmentHome
    if home == nil then
        return
    end
    job.equipmentHome = nil

    local placements = {}
    for _, entry in ipairs(home) do
        local vehicle = NetworkUtil.getObject(entry.vehicleId)
        if vehicle ~= nil and #entry.components == #vehicle.components then
            table.insert(placements, { vehicle = vehicle, components = entry.components })
        end
    end

    for _, placement in ipairs(placements) do
        local vehicle = placement.vehicle
        local attacher = vehicle.getAttacherVehicle ~= nil and vehicle:getAttacherVehicle() or nil
        if attacher ~= nil then
            attacher:detachImplementByObject(vehicle)
        end
    end

    for _, placement in ipairs(placements) do
        local root = placement.components[1]
        placement.vehicle:removeFromPhysics()
        placement.vehicle:setAbsolutePosition(root[1][1], root[1][2], root[1][3], root[2][1], root[2][2], root[2][3],
            placement.components)
        placement.vehicle:addToPhysics()
    end

    Logging.info("TheContractor: job %d equipment returned home (%d vehicles)", job.id, #placements)
end

-- Persistence, delegated into from TheContractorJobs' own job save/load.

function TCJobSiteSetup.saveHomeToXML(xmlFile, key, home)
    -- Marks home as recorded even if none of its vehicles are left.
    setXMLBool(xmlFile, key .. "#recorded", true)
    local index = 0
    for _, entry in ipairs(home) do
        local uniqueId = TCVehicleIds.getUniqueId(entry.vehicleId)
        if uniqueId ~= nil then
            local vehicleKey = string.format("%s.vehicle(%d)", key, index)
            setXMLString(xmlFile, vehicleKey .. "#uniqueId", uniqueId)
            for j, component in ipairs(entry.components) do
                local componentKey = string.format("%s.component(%d)", vehicleKey, j - 1)
                setXMLFloat(xmlFile, componentKey .. "#x", component[1][1])
                setXMLFloat(xmlFile, componentKey .. "#y", component[1][2])
                setXMLFloat(xmlFile, componentKey .. "#z", component[1][3])
                setXMLFloat(xmlFile, componentKey .. "#rx", component[2][1])
                setXMLFloat(xmlFile, componentKey .. "#ry", component[2][2])
                setXMLFloat(xmlFile, componentKey .. "#rz", component[2][3])
            end
            index = index + 1
        end
    end
end

-- Entries carry the vehicle's uniqueId until resolveSavedHome.
function TCJobSiteSetup.loadHomeFromXML(xmlFile, key)
    if not hasXMLProperty(xmlFile, key) then
        return nil
    end

    local home = {}
    local i = 0
    while true do
        local vehicleKey = string.format("%s.vehicle(%d)", key, i)
        if not hasXMLProperty(xmlFile, vehicleKey) then
            break
        end

        local components = {}
        local j = 0
        while true do
            local componentKey = string.format("%s.component(%d)", vehicleKey, j)
            if not hasXMLProperty(xmlFile, componentKey) then
                break
            end
            table.insert(components, {
                { getXMLFloat(xmlFile, componentKey .. "#x"), getXMLFloat(xmlFile, componentKey .. "#y"),
                    getXMLFloat(xmlFile, componentKey .. "#z") },
                { getXMLFloat(xmlFile, componentKey .. "#rx"), getXMLFloat(xmlFile, componentKey .. "#ry"),
                    getXMLFloat(xmlFile, componentKey .. "#rz") },
            })
            j = j + 1
        end

        table.insert(home, { uniqueId = getXMLString(xmlFile, vehicleKey .. "#uniqueId"), components = components })
        i = i + 1
    end
    return home
end

-- Server, from TheContractorJobs:resolveSavedVehicles once vehicles exist.
function TCJobSiteSetup.resolveSavedHome(job)
    if job.equipmentHome == nil then
        return
    end
    local home = {}
    for _, entry in ipairs(job.equipmentHome) do
        if entry.uniqueId ~= nil then
            local vehicleId = TCVehicleIds.getObjectId(entry.uniqueId)
            if vehicleId ~= nil then
                table.insert(home, { vehicleId = vehicleId, components = entry.components })
            end
        else
            table.insert(home, entry)
        end
    end
    job.equipmentHome = home
end
