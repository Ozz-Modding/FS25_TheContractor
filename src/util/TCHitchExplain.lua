-- The dev dialog's hitch test (TCDevDialog, tcDebug dev): runs the real
-- dispatch planner (TCJobSiteSetup.planHitches) on a tractor and some
-- implements the player picked, moving nothing, and says which joint each
-- one would go on and why: every joint looked at, every input joint tried
-- against it, the compatibility answer, the facing check's numbers and
-- the score. The planner goes through the implements in order, each taking
-- the best joint left, so the order can change the answer: run it both
-- ways to see.
--
-- Read-only, so it runs on whichever machine asks (a client has the
-- vehicles' joints and nodes too). The reasoning goes to the log through
-- TCLog.info; the dialog shows only the outcome.

TCHitchExplain = {}

local function getName(vehicle)
    if vehicle == nil then
        return "nothing"
    end
    local name = vehicle.getFullName ~= nil and vehicle:getFullName() or
        (vehicle.getName ~= nil and vehicle:getName()) or tostring(vehicle)
    return string.format("'%s' (#%s)", tostring(name), tostring(NetworkUtil.getObjectId(vehicle)))
end

-- "front" for attacherJointDirection 1, "rear" for -1.
function TCHitchExplain.getSide(direction)
    if direction == 1 then
        return "front"
    elseif direction == -1 then
        return "rear"
    end
    return "unknown"
end

local function getJointTypeName(jointType)
    if AttacherJoints ~= nil and AttacherJoints.jointTypeNameToInt ~= nil then
        for name, value in pairs(AttacherJoints.jointTypeNameToInt) do
            if value == jointType then
                return name
            end
        end
    end
    return tostring(jointType)
end

local function isOwned(vehicle, farmId)
    if vehicle.getOwnerFarmId == nil or vehicle:getOwnerFarmId() ~= farmId or vehicle.isDeleted then
        return false
    end
    if TheContractorRepairContracts ~= nil and TheContractorRepairContracts.isContractVehicle(vehicle) then
        return false
    end
    local tc = g_currentMission.TheContractor
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    return not (tc ~= nil and tc.Theft ~= nil and vehicleId ~= nil and tc.Theft:isStolen(vehicleId))
end

-- What can pull the implements: anything driven with attacher joints.
function TCHitchExplain.isTractor(vehicle)
    return vehicle.spec_motorized ~= nil and vehicle.spec_attacherJoints ~= nil and
        vehicle.getAttacherJoints ~= nil
end

function TCHitchExplain.isMower(vehicle)
    return vehicle.spec_mower ~= nil and vehicle.getInputAttacherJoints ~= nil and vehicle.spec_motorized == nil
end

-- The farm's tractors and mowers, each by name: { tractors, mowers }.
function TCHitchExplain.getCandidates(farmId)
    local tractors, mowers = {}, {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if isOwned(vehicle, farmId) then
            if TCHitchExplain.isTractor(vehicle) then
                table.insert(tractors, vehicle)
            elseif TCHitchExplain.isMower(vehicle) then
                table.insert(mowers, vehicle)
            end
        end
    end
    local function byName(a, b)
        return a:getFullName() < b:getFullName()
    end
    table.sort(tractors, byName)
    table.sort(mowers, byName)
    return tractors, mowers
end

-- Plans tractor + implements (in that order) as a dispatch would. Returns
-- { tractor, implements, plans (nil if it couldn't), reasonKey, trace,
-- placements }, placements one per implement in the order given:
-- { implement, attacher, jointIndex, side } (attacher nil if unplaced).
function TCHitchExplain.run(tractor, implements, farmId)
    local ids = { NetworkUtil.getObjectId(tractor) }
    for _, implement in ipairs(implements) do
        table.insert(ids, NetworkUtil.getObjectId(implement))
    end
    local job = { id = 0, farmId = farmId, assignedEquipmentIds = ids }

    local trace = {}
    local plans, reasonKey = TCJobSiteSetup.planHitches(job, trace)
    local result = { tractor = tractor, implements = implements, trace = trace, placements = {} }
    if plans ~= nil then
        result.plans = plans
    else
        result.reasonKey = reasonKey
    end

    for _, implement in ipairs(implements) do
        local placement = { implement = implement }
        -- A failed plan returns nothing, but its trace still has what each
        -- implement was given before it gave up.
        for _, step in ipairs(trace.steps) do
            if step.implement == implement and step.plan ~= nil then
                placement.attacher = step.plan.attacher
                placement.jointIndex = step.plan.jointIndex
                local joint = step.plan.attacher:getAttacherJoints()[step.plan.jointIndex]
                placement.side = TCHitchExplain.getSide(joint ~= nil and joint.attacherJointDirection or nil)
            end
        end
        table.insert(result.placements, placement)
    end
    return result
end

-- Log lines ---------------------------------------------------------------------

local function formatVector(vector)
    if vector == nil then
        return "?"
    end
    return string.format("(%.2f, %.2f)", vector[1], vector[2])
end

local function describeVehicle(lines, vehicle, indent)
    local storeItem = g_storeManager ~= nil and g_storeManager:getItemByXMLFilename(vehicle.configFileName) or nil
    table.insert(lines, string.format("%s%s: %s, store category %s", indent, getName(vehicle),
        tostring(vehicle.configFileName), storeItem ~= nil and tostring(storeItem.categoryName) or "?"))
    if vehicle.getAINeedsRootAlignment ~= nil then
        table.insert(lines, string.format("%s  needs root alignment for AI: %s, yRotationOffset %s", indent,
            tostring(vehicle:getAINeedsRootAlignment()), tostring(vehicle.yRotationOffset or 0)))
    end
    local attacher = vehicle.getAttacherVehicle ~= nil and vehicle:getAttacherVehicle() or nil
    if attacher ~= nil then
        table.insert(lines, string.format("%s  currently hitched to %s", indent, getName(attacher)))
    end
    if vehicle.getInputAttacherJoints ~= nil and vehicle.spec_motorized == nil then
        for index, input in ipairs(vehicle:getInputAttacherJoints()) do
            table.insert(lines, string.format("%s  input joint %d: type %s, forcedAttachingDirection %s, " ..
                "subTypes %s, node %s", indent, index, getJointTypeName(input.jointType),
                tostring(input.forcedAttachingDirection), input.subTypes ~= nil and tostring(#input.subTypes) or
                "none", input.node ~= nil and "yes" or "MISSING"))
        end
    end
    if vehicle.getAttacherJoints ~= nil and vehicle.spec_motorized ~= nil then
        for index, joint in ipairs(vehicle:getAttacherJoints()) do
            local occupantEntry = vehicle:getImplementByJointDescIndex(index)
            table.insert(lines, string.format("%s  attacher joint %d: %s, type %s, blocked %s, subTypes %s, " ..
                "jointTransform %s, on it: %s", indent, index, TCHitchExplain.getSide(joint.attacherJointDirection),
                getJointTypeName(joint.jointType), tostring(joint.isBlocked == true),
                joint.subTypes ~= nil and tostring(#joint.subTypes) or "none",
                joint.jointTransform ~= nil and "yes" or "MISSING",
                occupantEntry ~= nil and getName(occupantEntry.object) or "nothing"))
        end
    end
end

local function describeInput(input, jointSide)
    local parts = { string.format("input %d (type %s, forcedAttachingDirection %s)", input.inputIndex,
        getJointTypeName(input.jointType), tostring(input.forcedDirection)) }
    if not input.typeMatch then
        table.insert(parts, "REJECTED: joint types differ")
        return table.concat(parts, ": ")
    end
    if not input.compatible then
        table.insert(parts, "REJECTED: AttacherJoints.getAttacherJointCompatibility said no" ..
            (input.warning ~= nil and (" (" .. tostring(input.warning) .. ")") or "") ..
            " (forced direction, subtypes, brand or vehicle restriction)")
        return table.concat(parts, ": ")
    end
    local facing = input.facing or {}
    if facing.skipped == "noRootAlignment" then
        table.insert(parts, "compatible; facing not checked (implement doesn't need root alignment for AI)")
    elseif facing.skipped == "missingNodes" then
        table.insert(parts, "compatible; facing not checked (a joint transform or input node is missing)")
    else
        table.insert(parts, string.format("compatible; would face %s on the %s (dot %.2f: implement forward in " ..
            "its input frame %s, hitched forward %s, tractor forward %s)",
            input.backwards and "BACKWARDS" or "forwards", jointSide, facing.dot or 0,
            formatVector(facing.implementLocal), formatVector(facing.hitchedForward),
            formatVector(facing.attacherForward)))
    end
    if input.backwards then
        table.insert(parts, "REJECTED: would face backwards")
    elseif input.score ~= nil then
        table.insert(parts, string.format("USABLE, score %d", input.score))
    end
    return table.concat(parts, "; ")
end

local STATUS_TEXT = {
    claimed = "SKIPPED: already claimed by an implement planned before it",
    blocked = "SKIPPED: joint is blocked",
    jobOccupied = "SKIPPED: another job machine is on it",
}

-- The reasoning, line by line, for the log. label says which run it was.
function TCHitchExplain.getLines(result, label)
    local trace = result.trace
    local lines = { string.format("---- Hitch test %s ----", label or "") }
    table.insert(lines, "How it decides: implements are planned one at a time in the order below; each tries " ..
        "the attachers in turn (the tractor, then implements already planned) and takes the best-scoring usable " ..
        "joint on the first attacher that has one. Score: +2 for a rear joint, +1 if nothing foreign has to come " ..
        "off it; on a tie the lower joint index wins. A joint is usable if the joint types match, vanilla's " ..
        "compatibility check passes and the implement wouldn't face backwards on it.")
    table.insert(lines, "Machines:")
    describeVehicle(lines, result.tractor, "  ")
    for _, implement in ipairs(result.implements) do
        describeVehicle(lines, implement, "  ")
    end

    table.insert(lines, string.format("Operating vehicle picked: %s", getName(trace.operatingVehicle)))
    if trace.operatingVehicle ~= result.tractor then
        table.insert(lines, "  NOTE: not the tractor picked (the planner takes the first driven machine with " ..
            "attacher joints)")
    end
    for _, vehicle in ipairs(trace.alreadyAttached or {}) do
        table.insert(lines, string.format("Already on the tractor, so not planned (it stays where it is): %s",
            getName(vehicle)))
    end
    local order = {}
    for index, vehicle in ipairs(trace.order or {}) do
        table.insert(order, string.format("%d. %s", index, getName(vehicle)))
    end
    table.insert(lines, "Planning order: " .. (#order > 0 and table.concat(order, ", ") or "nothing to plan"))

    for _, step in ipairs(trace.steps or {}) do
        table.insert(lines, string.format("Pass %d, %s:", step.pass, getName(step.implement)))
        for _, attempt in ipairs(step.attempts) do
            table.insert(lines, string.format("  on %s:", getName(attempt.attacher)))
            if attempt.attachRefused then
                table.insert(lines, "    REFUSED: the implement's isAttachAllowed said no")
            end
            for _, joint in ipairs(attempt.joints or {}) do
                local side = TCHitchExplain.getSide(joint.direction)
                local header = string.format("    joint %d (%s, type %s)", joint.jointIndex, side,
                    getJointTypeName(joint.jointType))
                if joint.occupant ~= nil then
                    header = header .. string.format(", %s on it (would come off)", getName(joint.occupant))
                end
                if joint.status ~= "checked" then
                    table.insert(lines, header .. ": " .. (STATUS_TEXT[joint.status] or tostring(joint.status)))
                else
                    table.insert(lines, header .. ":")
                    for _, input in ipairs(joint.inputs) do
                        table.insert(lines, "      " .. describeInput(input, side))
                    end
                end
            end
            if attempt.chosen ~= nil then
                local joint = attempt.attacher:getAttacherJoints()[attempt.chosen.jointIndex]
                table.insert(lines, string.format("    -> CHOSEN: joint %d (%s) by input %d, score %d",
                    attempt.chosen.jointIndex, TCHitchExplain.getSide(joint ~= nil and joint.attacherJointDirection),
                    attempt.chosen.inputIndex, attempt.chosen.score))
            else
                table.insert(lines, "    -> no usable joint here")
            end
        end
        if step.plan == nil then
            table.insert(lines, "  -> nothing fitted this pass")
        end
    end

    table.insert(lines, "Result:")
    for _, placement in ipairs(result.placements) do
        if placement.attacher ~= nil then
            table.insert(lines, string.format("  %s -> %s hitch (joint %d on %s)", getName(placement.implement),
                placement.side, placement.jointIndex, getName(placement.attacher)))
        else
            table.insert(lines, string.format("  %s -> NOT PLACED", getName(placement.implement)))
        end
    end
    if result.plans == nil then
        table.insert(lines, string.format("  The plan failed (%s): a dispatch would refuse this job",
            tostring(result.reasonKey)))
    end
    return lines
end

function TCHitchExplain.log(result, label)
    for _, line in ipairs(TCHitchExplain.getLines(result, label)) do
        TCLog.info("TheContractor hitch test: %s", line)
    end
end
