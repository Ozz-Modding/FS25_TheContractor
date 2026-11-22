-- TCAttachImplementsManually (177): with FS25_attachImplementsManually
-- loaded, a job hitch (made with nobody there, so the mod leaves hoses, PTO
-- and top link off and a trailer's handbrake as it was) gets them connected
-- and the brake and chocks released, through the mod's own server-side
-- functions and events. An unhitch of ours puts the handbrake on. Without
-- the mod nothing happens.
--
-- The fakes follow the mod's signatures: on the attacher,
-- processHoseAttachRequest(attached, hoseKey, jointDescIndex,
-- inputJointDescIndex, state, manualHandbrake, group), setPTOAttachState and
-- setTopLinkAttachState(attached, jointDescIndex, inputJointDescIndex, state),
-- with spec_attachPowerTakeOffsManually.attachedPTOs and
-- spec_attachTopLinksManually.attachedTopLinks keyed by joint; in the env,
-- PowerTakeOffUtil.getHasInputPTO(vehicle, inputJointDescIndex) /
-- getHasOutputPTO(vehicle, jointDescIndex),
-- AttacherJointUtil.getHasTopLink(attacher, jointDescIndex, attached,
-- inputJointDescIndex) and the toggle events' sendEvent(vehicle, attached,
-- jointDescIndex, inputJointDescIndex, state, noEventSend); on a trailer,
-- getHasHandbrake/getIsHandbrakeEngaged/requestHandbrakeState/
-- setHandbrakeState(state, noEventSend) and getAreWheelChocksPlaced/
-- setWheelChockState(state, noEventSend).

local JOINT, INPUT = 3, 2

local function newEnv()
    local env = { events = {} }
    local function event(kind)
        return {
            sendEvent = function(vehicle, attached, jointDescIndex, inputJointDescIndex, state, noEventSend)
                table.insert(env.events, { kind = kind, vehicle = vehicle, attached = attached,
                    joint = jointDescIndex, input = inputJointDescIndex, state = state, noEventSend = noEventSend })
            end,
        }
    end
    env.TogglePTOAttachStateEvent = event("pto")
    env.ToggleTopLinkAttachStateEvent = event("topLink")
    env.PowerTakeOffUtil = {
        getHasInputPTO = function(vehicle, inputJointDescIndex)
            return vehicle.pto == true and inputJointDescIndex == INPUT
        end,
        getHasOutputPTO = function(vehicle, jointDescIndex)
            return vehicle.ptoOut == true and jointDescIndex == JOINT
        end,
    }
    env.AttacherJointUtil = {
        getHasTopLink = function(_, jointDescIndex, attached, inputJointDescIndex)
            return attached.topLink == true and jointDescIndex == JOINT and inputJointDescIndex == INPUT
        end,
    }
    return env
end

local function setup(env)
    local world = stubs.install()
    TheContractorDrivers = {
        getModEnv = function(modName)
            if modName == "FS25_attachImplementsManually" then
                return env
            end
            return nil
        end,
    }
    world:load("src/util/TCAttachImplementsManually.lua")
    return world
end

-- A tractor with the mod's specializations; `implement` is hitched at JOINT.
local function tractor(implement)
    local vehicle = {
        ptoOut = true,
        hoseCalls = {},
        spec_attachConnectionHosesManually = {},
        spec_attachPowerTakeOffsManually = { attachedPTOs = {} },
        spec_attachTopLinksManually = { attachedTopLinks = {} },
    }
    function vehicle:getImplementIndexByObject(object)
        return object == implement and 1 or nil
    end
    function vehicle:getAttacherJointIndexFromImplementIndex(index)
        return index == 1 and JOINT or nil
    end
    function vehicle:processHoseAttachRequest(attached, hoseKey, jointDescIndex, inputJointDescIndex, state,
                                              manualHandbrake, group)
        table.insert(self.hoseCalls, { attached = attached, hoseKey = hoseKey, joint = jointDescIndex,
            input = inputJointDescIndex, state = state, manualHandbrake = manualHandbrake, group = group })
        if not attached.hoses or attached.hosesOn then
            return false, false
        end
        attached.hosesOn = true
        return true, false
    end
    function vehicle:setPTOAttachState(_, jointDescIndex, _, state)
        self.spec_attachPowerTakeOffsManually.attachedPTOs[jointDescIndex] = state or nil
    end
    function vehicle:setTopLinkAttachState(_, jointDescIndex, _, state)
        self.spec_attachTopLinksManually.attachedTopLinks[jointDescIndex] = state or nil
    end
    return vehicle
end

-- fields: pto, hoses, topLink, handbrake (has one), braked, chocks,
-- airless (a spring brake the server won't open).
local function implement(fields)
    fields.spec_attachable = { inputAttacherJointDescIndex = INPUT }
    fields.brakeCalls = {}
    function fields:getName() return "implement" end
    function fields:getHasHandbrake() return self.handbrake == true end
    function fields:getIsHandbrakeEngaged() return self.braked == true end
    function fields:requestHandbrakeState(state)
        table.insert(self.brakeCalls, { kind = "request", state = state })
        if state or not self.airless then
            self.braked = state
        end
    end
    function fields:setHandbrakeState(state, noEventSend)
        table.insert(self.brakeCalls, { kind = "set", state = state, noEventSend = noEventSend })
        self.braked = state
    end
    function fields:getAreWheelChocksPlaced() return self.chocks == true end
    function fields:setWheelChockState(state, noEventSend)
        self.chockCall = { state = state, noEventSend = noEventSend }
        self.chocks = state
    end
    return fields
end

test("a hitched implement gets hoses, PTO and top link, through the mod's own functions and events", function()
    local env = newEnv()
    setup(env)
    local cultivator = implement({ pto = true, hoses = true, topLink = true })
    local vehicle = tractor(cultivator)

    assertEquals(TCAttachImplementsManually.connectAll(vehicle, cultivator), 3)

    assertTrue(cultivator.hosesOn, "hoses")
    local call = vehicle.hoseCalls[1]
    assertEquals(call.attached, cultivator)
    assertEquals(call.hoseKey, nil, "every hose, not one")
    assertEquals(call.joint, JOINT)
    assertEquals(call.input, INPUT)
    assertEquals(call.state, true)
    assertEquals(call.manualHandbrake, false, "the spring brake opens with the red line")

    assertTrue(vehicle.spec_attachPowerTakeOffsManually.attachedPTOs[JOINT], "PTO")
    assertTrue(vehicle.spec_attachTopLinksManually.attachedTopLinks[JOINT], "top link")
    assertEquals(#env.events, 2)
    for _, event in ipairs(env.events) do
        assertEquals(event.vehicle, vehicle)
        assertEquals(event.attached, cultivator)
        assertEquals(event.joint, JOINT)
        assertEquals(event.input, INPUT)
        assertEquals(event.state, true)
        assertEquals(event.noEventSend, false, "sent to clients")
    end
end)

test("a trailer's chocks come away and its handbrake comes off", function()
    local env = newEnv()
    setup(env)
    local trailer = implement({ hoses = true, handbrake = true, braked = true, chocks = true })
    local vehicle = tractor(trailer)

    assertEquals(TCAttachImplementsManually.connectAll(vehicle, trailer), 3)

    assertEquals(trailer.chocks, false)
    assertEquals(trailer.chockCall.noEventSend, false, "chocks sent to clients")
    assertEquals(trailer.braked, false)
    assertEquals(trailer.brakeCalls[1].kind, "request", "through the server's own check")
end)

test("a spring brake with no air to open it stays on, and isn't counted", function()
    local env = newEnv()
    local world = setup(env)
    local trailer = implement({ handbrake = true, braked = true, airless = true })

    assertEquals(TCAttachImplementsManually.connectAll(tractor(trailer), trailer), 0)
    assertEquals(trailer.braked, true)
    assertEquals(#world.warnings, 1)
end)

test("what's already connected, or not there, is left alone", function()
    local env = newEnv()
    setup(env)
    local bare = implement({})
    local vehicle = tractor(bare)
    assertEquals(TCAttachImplementsManually.connectAll(vehicle, bare), 0)

    local done = implement({ pto = true, hoses = true, hosesOn = true, topLink = true })
    vehicle = tractor(done)
    vehicle.spec_attachPowerTakeOffsManually.attachedPTOs[JOINT] = true
    vehicle.spec_attachTopLinksManually.attachedTopLinks[JOINT] = true
    assertEquals(TCAttachImplementsManually.connectAll(vehicle, done), 0)
    assertEquals(#env.events, 0)
end)

test("an implement that isn't hitched to the attacher gets nothing", function()
    local env = newEnv()
    setup(env)
    local cultivator = implement({ pto = true, hoses = true })
    local vehicle = tractor(implement({}))

    assertEquals(TCAttachImplementsManually.connectAll(vehicle, cultivator), 0)
    assertEquals(#vehicle.hoseCalls, 0)
end)

test("without the mod nothing happens; a version missing a function skips only that", function()
    setup(nil)
    local cultivator = implement({ pto = true, hoses = true, topLink = true })
    assertEquals(TCAttachImplementsManually.connectAll(tractor(cultivator), cultivator), 0)

    local env = newEnv()
    env.ToggleTopLinkAttachStateEvent = nil
    setup(env)
    cultivator = implement({ pto = true, hoses = true, topLink = true })
    local vehicle = tractor(cultivator)
    assertEquals(TCAttachImplementsManually.connectAll(vehicle, cultivator), 2)
    assertEquals(vehicle.spec_attachTopLinksManually.attachedTopLinks[JOINT], nil, "no top link")
end)

test("after we unhitch a trailer its handbrake goes on, sent to clients", function()
    local env = newEnv()
    setup(env)
    local trailer = implement({ handbrake = true })

    assertTrue(TCAttachImplementsManually.onDetached(trailer))
    assertEquals(trailer.braked, true)
    assertEquals(trailer.brakeCalls[1].kind, "set")
    assertEquals(trailer.brakeCalls[1].noEventSend, false)

    assertEquals(TCAttachImplementsManually.onDetached(trailer), false, "already on")
    assertEquals(TCAttachImplementsManually.onDetached(implement({})), false, "no handbrake")

    setup(nil)
    assertEquals(TCAttachImplementsManually.onDetached(implement({ handbrake = true })), false, "no mod")
end)
