-- TCManualAttach: with FS25_manualAttach loaded, a job hitch (made before
-- the worker's AI starts, so Manual Attach has pulled the PTO and hoses
-- off) gets them connected again through Manual Attach's own attach
-- functions; without it nothing happens.
--
-- The fake follows FS25_manualAttach's g_manualAttach:attachPowerTakeOff /
-- attachConnectionHoses(vehicle, object, noEventSend) and its
-- PowerTakeOffExtension.hasPowerTakeOffs/hasAttachedPowerTakeOffs(object,
-- vehicle) and ConnectionHosesExtension.hasConnectionHoses(object, vehicle)
-- / hasAttachedConnectionHoses(object). An implement's `pto`/`hoses` say
-- whether it has them, `ptoOn`/`hosesOn` whether they're connected.

local function newEnv()
    local env = { calls = {} }
    env.g_manualAttach = {
        attachPowerTakeOff = function(_, vehicle, object, noEventSend)
            table.insert(env.calls, { kind = "pto", vehicle = vehicle, object = object, noEventSend = noEventSend })
            object.ptoOn = true
        end,
        attachConnectionHoses = function(_, vehicle, object, noEventSend)
            table.insert(env.calls, { kind = "hoses", vehicle = vehicle, object = object, noEventSend = noEventSend })
            object.hosesOn = true
        end,
    }
    env.PowerTakeOffExtension = {
        hasPowerTakeOffs = function(object, vehicle) return object.pto == true and vehicle ~= nil end,
        hasAttachedPowerTakeOffs = function(object) return object.ptoOn == true end,
    }
    env.ConnectionHosesExtension = {
        hasConnectionHoses = function(object, vehicle) return object.hoses == true and vehicle ~= nil end,
        hasAttachedConnectionHoses = function(object) return object.hosesOn == true end,
    }
    return env
end

local function setup(env)
    local world = stubs.install()
    TheContractorDrivers = {
        getModEnv = function(modName)
            if modName == "FS25_manualAttach" then
                return env
            end
            return nil
        end,
    }
    world:load("src/util/TCManualAttach.lua")
    return world
end

local function implement(fields)
    fields.getName = function() return "implement" end
    return fields
end

test("a hitched cultivator gets its PTO and hoses connected, sending Manual Attach's events", function()
    local env = newEnv()
    setup(env)
    local tractor = {}
    local cultivator = implement({ pto = true, hoses = true })

    assertEquals(2, TCManualAttach.connectAll(tractor, cultivator))
    assertTrue(cultivator.ptoOn)
    assertTrue(cultivator.hosesOn)
    assertEquals(2, #env.calls)
    for _, call in ipairs(env.calls) do
        assertEquals(tractor, call.vehicle)
        assertEquals(cultivator, call.object)
        assertEquals(nil, call.noEventSend)
    end
end)

test("only what the implement has, and isn't connected yet, is connected", function()
    local env = newEnv()
    setup(env)
    local tractor = {}

    assertEquals(1, TCManualAttach.connectAll(tractor, implement({ hoses = true })))
    assertEquals("hoses", env.calls[1].kind)

    env.calls = {}
    assertEquals(0, TCManualAttach.connectAll(tractor, implement({ pto = true, ptoOn = true, hoses = true, hosesOn = true })))
    assertEquals(0, TCManualAttach.connectAll(tractor, implement({})))
    assertEquals(0, #env.calls)
end)

test("without Manual Attach, or a version missing what's needed, nothing happens", function()
    setup(nil)
    assertEquals(0, TCManualAttach.connectAll({}, implement({ pto = true, hoses = true })))

    local env = newEnv()
    env.g_manualAttach.attachConnectionHoses = nil
    setup(env)
    assertEquals(0, TCManualAttach.connectAll({}, implement({ pto = true, hoses = true })))
    assertEquals(0, #env.calls)
end)
