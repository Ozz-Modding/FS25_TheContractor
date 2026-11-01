-- TCAutoDrive gates ADInputManager:onInputCall. AutoDrive 3.0.1.4 added a
-- uniqueUserId argument before sendEvent; the old wrapper shifted it, so
-- the server's rerun (sendEvent == false) became another send, which in
-- single player loops straight back in until the stack overflows. AD is
-- cut down to the input path (refs/FS25_AutoDrive, refs/FS25_AutoDrive3014).

local function setup(version)
    local world = stubs.install()

    world.calls = {}
    world.sent = 0
    world.gated = {}
    world.gate = nil

    local ADInputManager = {}
    -- AD's own routing: a send (sendEvent nil/true) runs the event, which on
    -- the server (single player) calls onInputCall again with sendEvent false.
    if version == "3014" then
        function ADInputManager:onInputCall(vehicle, input, farmId, uniqueUserId, sendEvent)
            if sendEvent == nil or sendEvent == true then
                world.sent = world.sent + 1
                assertTrue(world.sent < 10, "send loop")
                ADInputManager:onInputCall(vehicle, input, farmId or 1, "user1", false)
                return
            end
            table.insert(world.calls, { input = input, farmId = farmId, uniqueUserId = uniqueUserId })
        end
    else
        function ADInputManager:onInputCall(vehicle, input, farmId, sendEvent)
            if sendEvent == nil or sendEvent == true then
                world.sent = world.sent + 1
                assertTrue(world.sent < 10, "send loop")
                ADInputManager:onInputCall(vehicle, input, farmId or 1, false)
                return
            end
            table.insert(world.calls, { input = input, farmId = farmId })
        end
    end

    world.adEnv = {
        AutoDrive = {
            onUpdateTick = function() end,
            getSetting = function() return 1 end,
        },
        ADInputManager = ADInputManager,
    }

    TheContractorDrivers = {
        getModEnv = function(modName)
            return modName == "FS25_AutoDrive" and world.adEnv or nil
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

    world:load("src/util/TCAutoDrive.lua")
    assertTrue(TCAutoDrive.install())
    return world, ADInputManager
end

local function newVehicle()
    return {
        ad = {
            stateModule = {
                isActive = function() return false end,
                getFirstMarker = function() return {} end,
            },
        },
    }
end

for _, version in ipairs({ "3012", "3014" }) do
    test(version .. ": a start that needs no driver runs once on the server", function()
        local world, ADInputManager = setup(version)

        ADInputManager:onInputCall(newVehicle(), "input_start_stop")

        assertEquals(world.sent, 1)
        assertEquals(#world.calls, 1)
        assertEquals(world.calls[1].input, "input_start_stop")
        if version == "3014" then
            assertEquals(world.calls[1].uniqueUserId, "user1", "uniqueUserId passed through")
        end
    end)

    test(version .. ": a start that needs a driver waits for the picker, then runs once", function()
        local world, ADInputManager = setup(version)
        world.gate = "picker"

        ADInputManager:onInputCall(newVehicle(), "input_start_stop")

        assertEquals(world.sent, 0, "held back")
        assertEquals(#world.gated, 1)

        world.gate = nil
        world.gated[1].startFunc()
        assertEquals(world.sent, 1)
        assertEquals(#world.calls, 1)
        assertEquals(#world.gated, 1, "the server's rerun isn't gated again")
    end)

    test(version .. ": the server's rerun of a client's input skips the gate", function()
        local world, ADInputManager = setup(version)
        world.gate = "picker"

        if version == "3014" then
            ADInputManager:onInputCall(newVehicle(), "input_start_stop", 1, "user2", false)
        else
            ADInputManager:onInputCall(newVehicle(), "input_start_stop", 1, false)
        end

        assertEquals(#world.gated, 0)
        assertEquals(#world.calls, 1)
    end)
end

test("installing again on another load doesn't wrap twice", function()
    local world, ADInputManager = setup("3014")
    TCAutoDrive.install()
    world.gate = "picker"

    ADInputManager:onInputCall(newVehicle(), "input_start_stop")

    assertEquals(#world.gated, 1)
end)
