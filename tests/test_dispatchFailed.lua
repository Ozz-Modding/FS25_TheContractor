-- A dispatch failure's reason goes over the wire as its l10n key's index
-- and plain args, so each machine puts it in its own language.

local function setup()
    local world = stubs.install()
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    -- Vanilla's own texts, which aren't in our l10n file.
    world.texts.ai_validationErrorNoVehicle = "No vehicle"
    world.texts.ai_validationErrorVehicleDoesNotExistAnymore = "Vehicle gone"
    world.texts.ai_validationErrorVehicleDoesNotSupportAI = "No AI"
    world.texts.ai_startStateLimitReached = "Limit reached"
    world.texts.ai_startStateVehicleDeleted = "Deleted"
    world.texts.ai_startStateNoPermission = "No permission"
    world.texts.ai_startStateVehicleInUse = "In use"
    world:load("src/events/TCDispatchFailedEvent.lua")
    return world
end

-- Writes the event and reads it back as a client would, returning what it read.
local function roundTrip(world, event)
    local stream = world:newStream()
    event:writeStream(stream, nil)
    local received = TCDispatchFailedEvent.emptyNew()
    received.run = function() end
    received:readStream(stream, nil)
    return received, stream
end

test("a reason with a key goes as its index, with its args", function()
    local world = setup()
    local received, stream = roundTrip(world,
        TCDispatchFailedEvent.new(1, "plough", 12, "tc_dispatch_noAttachPoint", { "Plough", "Tractor" }))

    assertEquals(stream.values[4], TCDispatchFailedEvent.REASON_INDEX.tc_dispatch_noAttachPoint, "sent as an int")
    assertEquals(received.reasonKey, "tc_dispatch_noAttachPoint", "key on the client")
    assertEquals(#received.reasonArgs, 2, "args")
    assertEquals(received.reasonArgs[2], "Tractor", "in order")
    assertEquals(received.fieldId, 12, "field")
end)

test("a reason with no key goes as index 0 with its text as the one arg", function()
    local world = setup()
    local received, stream = roundTrip(world, TCDispatchFailedEvent.new(1, "plough", 12, nil, { "Something else" }))

    assertEquals(stream.values[4], 0, "no index")
    assertEquals(received.reasonKey, nil, "no key")
    assertEquals(received.reasonArgs[1], "Something else", "the text as it came")
end)

test("vanilla's validation text is matched back to its key", function()
    setup()
    assertEquals(TCDispatchFailedEvent.findReasonKey("Vehicle gone"), "ai_validationErrorVehicleDoesNotExistAnymore")
    assertEquals(TCDispatchFailedEvent.findReasonKey("Some other mod's reason"), nil, "unknown text has none")
end)

test("every reason key is unique and indexed", function()
    setup()
    for index, key in ipairs(TCDispatchFailedEvent.REASON_KEYS) do
        assertEquals(TCDispatchFailedEvent.REASON_INDEX[key], index, key)
    end
end)
