-- Follow Me's Initiate action (right ctrl + F) starts its AI job straight
-- through aiSystem:startJob, so TCFollowMe gates it on each vehicle type's
-- copy of FollowVehicle:initiateFollowVehicle. Follow Me and the vehicle
-- types are cut down to what the hook touches (refs/FS25_FollowMe 1.2.0.0).

local function setup()
    local world = stubs.install()

    world.started = {}
    world.gated = {}
    -- What Drivers:gateClientStart would decide: nil goes ahead, "picker"
    -- holds the start until a driver's picked.
    world.gate = nil

    local AIJobFollowVehicle = {}
    world.followMeEnv = { AIJobFollowVehicle = AIJobFollowVehicle }
    world.initiate = function(vehicle, vehicleToFollow)
        table.insert(world.started, { vehicle = vehicle, vehicleToFollow = vehicleToFollow })
    end

    world.types = {
        tractor = { functions = { initiateFollowVehicle = world.initiate } },
        trailer = { functions = {} },
    }
    g_vehicleTypeManager = {
        getTypes = function()
            return world.types
        end,
    }

    TheContractorDrivers = {
        getModEnv = function(modName)
            return modName == "FS25_FollowMe" and world.followMeEnv or nil
        end,
        getInstance = function()
            return world.drivers
        end,
    }
    world.drivers = {
        gateClientStart = function(_, vehicle, startFunc)
            if world.gate == nil then
                return false
            end
            table.insert(world.gated, { vehicle = vehicle, startFunc = startFunc })
            return true
        end,
    }

    world:load("src/util/TCFollowMe.lua")
    return world
end

-- A vehicle as Vehicle.new builds it: the type's functions copied in.
local function newVehicle(typeDef)
    local vehicle = {}
    for name, func in pairs(typeDef.functions) do
        vehicle[name] = func
    end
    return vehicle
end

test("without Follow Me nothing is wrapped", function()
    local world = setup()
    world.followMeEnv = nil

    assertEquals(TCFollowMe.install(), false)
    assertEquals(world.types.tractor.functions.initiateFollowVehicle, world.initiate)
end)

test("a vehicle that needs no driver starts following as before", function()
    local world = setup()
    TCFollowMe.install()
    local vehicle = newVehicle(world.types.tractor)
    local leader = {}

    vehicle:initiateFollowVehicle(leader)

    assertEquals(#world.started, 1)
    assertEquals(world.started[1].vehicle, vehicle)
    assertEquals(world.started[1].vehicleToFollow, leader)
end)

test("a vehicle that needs a driver waits for the picker", function()
    local world = setup()
    TCFollowMe.install()
    local vehicle = newVehicle(world.types.tractor)
    local leader = {}
    world.gate = "picker"

    vehicle:initiateFollowVehicle(leader)

    assertEquals(#world.started, 0, "held back")
    assertEquals(#world.gated, 1)
    assertEquals(world.gated[1].vehicle, vehicle)

    world.gated[1].startFunc()
    assertEquals(#world.started, 1, "starts once a driver's picked")
    assertEquals(world.started[1].vehicleToFollow, leader)
end)

test("installing again on another load doesn't wrap twice", function()
    local world = setup()
    TCFollowMe.install()
    TCFollowMe.install()
    local vehicle = newVehicle(world.types.tractor)
    world.gate = "picker"

    vehicle:initiateFollowVehicle({})

    assertEquals(#world.gated, 1)
    assertEquals(world.types.trailer.functions.initiateFollowVehicle, nil, "types without Follow Me left alone")
end)

test("Follow Me jobs are told apart", function()
    local world = setup()
    TCFollowMe.install()
    local followJob = { isa = function(_, class) return class == world.followMeEnv.AIJobFollowVehicle end }
    local otherJob = { isa = function() return false end }

    assertTrue(TCFollowMe.isFollowMeJob(followJob))
    assertTrue(not TCFollowMe.isFollowMeJob(otherJob))
    assertTrue(not TCFollowMe.isFollowMeJob(nil))
end)
