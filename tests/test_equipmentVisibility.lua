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
