-- Folding equipment for parking. A machine that folds comes back from a job
-- however the job left it, usually unfolded, and parking unhitches it
-- without vanilla's detach checks. So it's folded first, the way a driver
-- would leave it, but only where the machine itself says it may stand
-- folded: vanilla's Foldable gives each machine the fold range it may be
-- detached in (detachingMinLimit/MaxLimit, what Foldable:isDetachAllowed
-- checks), the range it may be hitched in again (attachingMinLimit/
-- MaxLimit) and, per hitch point, the range that point works in
-- (foldMinLimit/MaxLimit on its input attacher joints). A machine that
-- needs to stand unfolded is unfolded instead; one that may stand neither
-- way is left as it is.
--
-- Server only. Folding goes through vanilla's setFoldState, which plays the
-- animation and sends FoldableSetFoldDirectionEvent to the clients.

TCFolding = {}

local function getSpec(vehicle)
    local spec = vehicle ~= nil and vehicle.spec_foldable or nil
    -- A part that follows its parent's fold (useParentFoldingState) isn't
    -- folded by itself.
    if spec == nil or not spec.hasFoldingParts or spec.useParentFoldingState or spec.isFoldAllowed == false or
        vehicle.setFoldState == nil then
        return nil
    end
    return spec
end

local function isWithin(animTime, minLimit, maxLimit)
    return animTime >= (minLimit or 0) and animTime <= (maxLimit or 1)
end

-- The fold time (0 or 1) the machine is folded up at: the end away from
-- where it works (turnOnFoldDirection, as Foldable:getIsUnfolded reads it).
function TCFolding.getFoldedTime(spec)
    return spec.turnOnFoldDirection == -1 and 1 or 0
end

-- Whether the machine may stand unhitched at animTime and be hitched again:
-- inside its detaching and attaching ranges, with at least one of its hitch
-- points working there.
function TCFolding.isStandingTime(vehicle, spec, animTime)
    if not isWithin(animTime, spec.detachingMinLimit, spec.detachingMaxLimit) or
        not isWithin(animTime, spec.attachingMinLimit, spec.attachingMaxLimit) then
        return false
    end
    local joints = vehicle.getInputAttacherJoints ~= nil and vehicle:getInputAttacherJoints() or nil
    if joints == nil or #joints == 0 then
        return true
    end
    for _, joint in ipairs(joints) do
        if joint.foldMinLimit == nil or joint.foldMaxLimit == nil or
            isWithin(animTime, joint.foldMinLimit, joint.foldMaxLimit) then
            return true
        end
    end
    return false
end

-- The fold time the machine should be parked at: folded if it may stand
-- folded, else unfolded if it may stand that way, else nil (leave it).
function TCFolding.getParkingTime(vehicle)
    local spec = getSpec(vehicle)
    if spec == nil then
        return nil
    end
    local folded = TCFolding.getFoldedTime(spec)
    if TCFolding.isStandingTime(vehicle, spec, folded) then
        return folded
    end
    local unfolded = 1 - folded
    if TCFolding.isStandingTime(vehicle, spec, unfolded) then
        return unfolded
    end
    return nil
end

-- Server. Starts the machine folding (or unfolding) to its parking time if
-- it isn't there. Safe to call again while it moves. Returns whether it's
-- still on its way, so parking can wait for it.
function TCFolding.foldForParking(vehicle)
    local target = TCFolding.getParkingTime(vehicle)
    if target == nil then
        return false
    end
    local spec = vehicle.spec_foldable
    local isMoving = math.abs(spec.foldMoveDirection or 0) > 0.1
    if spec.foldAnimTime == target and not isMoving then
        return false
    end
    local direction = target == 1 and 1 or -1
    if spec.foldMoveDirection ~= direction or spec.moveToMiddle then
        vehicle:setFoldState(direction, false)
        TCLog.info("TheContractor: '%s' %s for parking", vehicle:getFullName(),
            target == TCFolding.getFoldedTime(spec) and "folded" or "unfolded")
    end
    return true
end
