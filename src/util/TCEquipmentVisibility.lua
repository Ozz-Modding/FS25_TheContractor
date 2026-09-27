-- Physically hiding/revealing farm equipment that's "away" on contractor
-- work - shared by 023's post-completion buffer (Cooldown.lua) and 020's
-- dispatch staging (Dispatch.lua: hidden while it's rigged up and moved to
-- the job field).
--
-- Technique from the user's FS25_UsedEquipmentYards mod
-- (YardInventory:hideVehicle/placeVehicleInYard): vehicle:removeFromPhysics()
-- + vehicle:setVisibility(false) to hide, the reverse to bring it back.
-- Deliberately skips UEY's detachVehicle step - our equipment stays
-- farm-owned and attached as-is.
--
-- Hiding/revealing is local rendering/physics state the base game never
-- networks on its own (unlike a vehicle's position), so every machine has
-- to apply it itself - see setVisibleEverywhere and
-- TCEquipmentVisibilityEvent.

TCEquipmentVisibility = {}

function TCEquipmentVisibility.hideVehicle(vehicle)
    if vehicle.stopMotor ~= nil then
        vehicle:stopMotor()
    end
    vehicle:removeFromPhysics()
    vehicle:setVisibility(false)
end

function TCEquipmentVisibility.revealVehicle(vehicle)
    vehicle:removeFromPhysics()
    vehicle:setVisibility(true)
    vehicle:addToPhysics()
end

-- Resolves and hides/reveals every vehicle id that's still resolvable (a
-- vehicle sold/deleted in the meantime is silently skipped - nothing to
-- hide or reveal for it either way).
function TCEquipmentVisibility.hideVehicles(vehicleIds)
    for _, vehicleId in ipairs(vehicleIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil then
            TCEquipmentVisibility.hideVehicle(vehicle)
        end
    end
end

function TCEquipmentVisibility.revealVehicles(vehicleIds)
    for _, vehicleId in ipairs(vehicleIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil then
            TCEquipmentVisibility.revealVehicle(vehicle)
        end
    end
end

-- Server-side: applies locally, then broadcasts to every client (no SP
-- loopback - see src/events/README.md).
function TCEquipmentVisibility.setVisibleEverywhere(vehicleIds, isVisible)
    if isVisible then
        TCEquipmentVisibility.revealVehicles(vehicleIds)
    else
        TCEquipmentVisibility.hideVehicles(vehicleIds)
    end

    if g_server ~= nil then
        g_server:broadcastEvent(TCEquipmentVisibilityEvent.new(vehicleIds, isVisible))
    end
end
