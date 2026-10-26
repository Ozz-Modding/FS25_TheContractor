-- TCEquipmentVisibility: hiding a vehicle puts the local player out of it
-- first.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCEquipmentVisibility.lua")
    TCEquipmentVisibility.reset()
    return world
end

local function addHideableVehicle(world)
    local vehicle = world:addVehicle({ name = "Tractor" })
    vehicle.isVisible = true
    function vehicle:removeFromPhysics() end
    function vehicle:setVisibility(isVisible) self.isVisible = isVisible end
    return vehicle
end

local function makePlayer(vehicle)
    local player = { vehicle = vehicle, leaves = 0 }
    function player:getCurrentVehicle() return self.vehicle end
    function player:leaveVehicle()
        self.leaves = self.leaves + 1
        self.vehicle = nil
    end
    return player
end

test("a player sitting in a vehicle that's hidden is put out of it", function()
    local world = setup()
    local tractor = addHideableVehicle(world)
    g_localPlayer = makePlayer(tractor)

    TCEquipmentVisibility.hideVehicles({ tractor.id })

    assertEquals(g_localPlayer.leaves, 1, "left the vehicle")
    assertEquals(tractor.isVisible, false, "hidden")
end)

test("a player in some other vehicle, or on foot, is left alone", function()
    local world = setup()
    local tractor = addHideableVehicle(world)
    local other = addHideableVehicle(world)
    g_localPlayer = makePlayer(other)

    TCEquipmentVisibility.hideVehicles({ tractor.id })
    assertEquals(g_localPlayer.leaves, 0, "in another vehicle")

    g_localPlayer = makePlayer(nil)
    TCEquipmentVisibility.hideVehicles({ tractor.id })
    assertEquals(g_localPlayer.leaves, 0, "on foot")
end)

test("no local player (a dedicated server) is fine", function()
    local world = setup()
    local tractor = addHideableVehicle(world)
    g_localPlayer = nil

    TCEquipmentVisibility.hideVehicles({ tractor.id })

    assertEquals(tractor.isVisible, false, "hidden")
end)

-- Its map hotspot goes while it's hidden and comes back with it: the flag
-- is what vanilla's every-update check reads, and the hotspot is updated
-- straight away as well.
test("a hidden vehicle's map hotspot is hidden, and back when it is", function()
    local world = setup()
    local tractor = addHideableVehicle(world)
    function tractor:addToPhysics() end
    function tractor:getIsMapHotspotVisible()
        return TCEquipmentVisibility.getIsMapHotspotVisible(self, Vehicle.getIsMapHotspotVisible)
    end
    function tractor:updateMapHotspot()
        self.hotspotVisible = self:getIsMapHotspotVisible()
    end
    local bystander = addHideableVehicle(world)
    function bystander:getIsMapHotspotVisible()
        return TCEquipmentVisibility.getIsMapHotspotVisible(self, Vehicle.getIsMapHotspotVisible)
    end

    TCEquipmentVisibility.hideVehicles({ tractor.id })
    assertEquals(tractor.hotspotVisible, false, "hidden at once")
    assertEquals(tractor:getIsMapHotspotVisible(), false, "and on every update")
    assertEquals(bystander:getIsMapHotspotVisible(), true, "other vehicles keep theirs")

    TCEquipmentVisibility.revealVehicles({ tractor.id })
    assertEquals(tractor.hotspotVisible, true, "back at once")
    assertEquals(tractor:getIsMapHotspotVisible(), true)
end)

-- 105: a tipped trailer's frozen body is in physics without its wheels;
-- revealing it mustn't re-add it (that builds wheel shapes on it).
test("a frozen vehicle is shown without its physics being touched", function()
    local world = setup()
    local trailer = addHideableVehicle(world)
    trailer.isVisible = false
    trailer.tcFrozen = true
    trailer.physicsCalls = 0
    function trailer:removeFromPhysics() self.physicsCalls = self.physicsCalls + 1 end
    function trailer:addToPhysics() self.physicsCalls = self.physicsCalls + 1 end

    TCEquipmentVisibility.revealVehicles({ trailer.id })

    assertEquals(trailer.isVisible, true, "shown")
    assertEquals(trailer.physicsCalls, 0, "physics left alone")
    assertEquals(trailer.tcIsHotspotHidden, nil, "on the map")
end)
