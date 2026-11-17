-- Ballast weights that stay on their machine. A weight hitched to a job's
-- tractor isn't unhitched at dispatch unless a job implement needs its hitch
-- (TCJobSiteSetup.detachForeignImplements), so it rides along: hidden and
-- revealed with the tractor (TCEquipmentVisibility), kept on when the
-- equipment is split up for parking (TCJobSiteSetup.unhitchVehicles), and
-- parked with it (TCParking.findSpot/placeVehicle).
--
-- Nothing is kept about it: vanilla saves and syncs the attachment, so a
-- weight is found again by looking at what's hitched to the machine.
--
-- Hiding and moving go round the engine's attachments rather than through
-- them: Vehicle:setVisibility only hides the vehicle's own components, a
-- vehicle leaving physics drops its implements' joints without taking them
-- along, and setAbsolutePosition moves only the vehicle itself. Coming back,
-- the machine goes into physics before its weights, so Attachable's
-- addToPhysics rebuilds each weight's joint.

TCBallast = {}

TCBallast.CATEGORY = "WEIGHTS"
TCBallast.TYPE_SUFFIX = "weight"

-- Whether the vehicle is a ballast weight: the store's weights category, or
-- a vehicle type named "weight" (a mod's is "<mod>.weight").
function TCBallast.isWeight(vehicle)
    if vehicle == nil then
        return false
    end
    if TCEquipmentClass.getCategory(vehicle) == TCBallast.CATEGORY then
        return true
    end
    local typeName = vehicle.typeName
    if type(typeName) ~= "string" then
        return false
    end
    typeName = typeName:lower()
    local suffix = TCBallast.TYPE_SUFFIX
    return typeName == suffix or typeName:sub(-(#suffix + 1)) == "." .. suffix
end

-- Whether the vehicle is a weight hitched to something.
function TCBallast.isHitchedWeight(vehicle)
    return TCBallast.isWeight(vehicle) and vehicle.getAttacherVehicle ~= nil and vehicle:getAttacherVehicle() ~= nil
end

-- The weights hitched straight to the vehicle.
function TCBallast.getWeights(vehicle)
    local weights = {}
    if vehicle == nil or vehicle.getAttachedImplements == nil then
        return weights
    end
    for _, implement in ipairs(vehicle:getAttachedImplements()) do
        local object = implement.object
        if object ~= nil and not object.isDeleted and TCBallast.isWeight(object) then
            table.insert(weights, object)
        end
    end
    return weights
end

-- Moving with the machine -----------------------------------------------------

-- Each weight's place relative to the vehicle, before the vehicle's moved.
function TCBallast.captureOffsets(vehicle)
    local captured = {}
    for _, weight in ipairs(TCBallast.getWeights(vehicle)) do
        local x, y, z = getWorldTranslation(weight.rootNode)
        local rx, ry, rz = getWorldRotation(weight.rootNode)
        local ox, oy, oz = worldToLocal(vehicle.rootNode, x, y, z)
        local rox, roy, roz = worldRotationToLocal(vehicle.rootNode, rx, ry, rz)
        table.insert(captured, { weight = weight, offset = { ox, oy, oz }, rotation = { rox, roy, roz } })
    end
    return captured
end

-- Puts each captured weight back in the same place relative to the vehicle,
-- once it's been moved (FSBaseMission:teleportVehicle's way). The weights
-- are left out of physics; revealing them puts them back.
function TCBallast.restoreOffsets(vehicle, captured)
    for _, entry in ipairs(captured) do
        local weight = entry.weight
        if not weight.isDeleted then
            local x, y, z = localToWorld(vehicle.rootNode, unpack(entry.offset))
            local rx, ry, rz = localRotationToWorld(vehicle.rootNode, unpack(entry.rotation))
            weight:removeFromPhysics()
            weight:setAbsolutePosition(x, y, z, rx, ry, rz)
        end
    end
end

-- Footprint --------------------------------------------------------------------

-- A vehicle's size box: its four corners' x (right) and z (forward) in its
-- own frame.
local function getBox(vehicle, defaultWidth, defaultLength)
    local size = vehicle.size or {}
    local halfWidth = (size.width or defaultWidth) * 0.5
    local halfLength = (size.length or defaultLength) * 0.5
    local cx, cz = size.widthOffset or 0, size.lengthOffset or 0
    return cx - halfWidth, cx + halfWidth, cz - halfLength, cz + halfLength
end

-- The vehicle's size with its weights in it, in the vehicle's frame: width,
-- length, widthOffset, lengthOffset (the box's centre from the vehicle's
-- origin, as vehicle.size has them) and height. The defaults stand in for a
-- vehicle with no size.
function TCBallast.getFootprint(vehicle, defaultWidth, defaultLength, defaultHeight)
    local size = vehicle.size or {}
    local minX, maxX, minZ, maxZ = getBox(vehicle, defaultWidth, defaultLength)
    local height = size.height or defaultHeight

    for _, weight in ipairs(TCBallast.getWeights(vehicle)) do
        local wMinX, wMaxX, wMinZ, wMaxZ = getBox(weight, 0, 0)
        for _, corner in ipairs({ { wMinX, wMinZ }, { wMinX, wMaxZ }, { wMaxX, wMinZ }, { wMaxX, wMaxZ } }) do
            local wx, wy, wz = localToWorld(weight.rootNode, corner[1], 0, corner[2])
            local x, _, z = worldToLocal(vehicle.rootNode, wx, wy, wz)
            minX, maxX = math.min(minX, x), math.max(maxX, x)
            minZ, maxZ = math.min(minZ, z), math.max(maxZ, z)
        end
        local weightSize = weight.size or {}
        if weightSize.height ~= nil and weightSize.height > height then
            height = weightSize.height
        end
    end

    return maxX - minX, maxZ - minZ, (minX + maxX) * 0.5, (minZ + maxZ) * 0.5, height
end
