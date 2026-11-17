-- TC_DATA_UPDATED (TCDataUpdated): every one of our events publishes it as
-- it's received and as the server broadcasts it, found in vanilla's event
-- registry, where a mod's InitEventClass files each event under
-- "<modName>.<className>". Other mods' events and vanilla's don't.

local function newEventClass()
    local class = {}
    class.readStream = function(self)
        self.wasRead = true
    end
    return class
end

local function setup()
    stubs.install()
    local world = { published = 0 }
    MessageType = MessageType or {}
    MessageType.TC_DATA_UPDATED = "TC_DATA_UPDATED"
    g_messageCenter = {
        publish = function(_, messageType)
            if messageType == MessageType.TC_DATA_UPDATED then
                world.published = world.published + 1
            end
        end,
    }
    world.broadcasts = 0
    Server = {
        broadcastEvent = function()
            world.broadcasts = world.broadcasts + 1
        end,
    }
    world.ours = newEventClass()
    world.otherMod = newEventClass()
    world.vanilla = newEventClass()
    EventIds = {
        eventClasses = {
            ["FS25_TheContractor.TCJobStateChangedEvent"] = world.ours,
            ["FS25_SomeOtherMod.TCSomethingEvent"] = world.otherMod,
            ["SellVehicleEvent"] = world.vanilla,
        },
    }
    g_currentModName = "FS25_TheContractor"
    dofile("src/util/TCDataUpdated.lua")
    TCDataUpdated.install()
    return world
end

test("one of our events publishes as it's received, after it has run", function()
    local world = setup()
    local event = setmetatable({}, { __index = world.ours })
    event:readStream(1, {})
    assertTrue(event.wasRead)
    assertEquals(world.published, 1)
end)

test("another mod's TC event and vanilla's publish nothing", function()
    local world = setup()
    setmetatable({}, { __index = world.otherMod }):readStream(1, {})
    setmetatable({}, { __index = world.vanilla }):readStream(1, {})
    assertEquals(world.published, 0)
end)

test("the server publishes as it broadcasts one of ours, and only ours", function()
    local world = setup()
    Server.broadcastEvent({}, setmetatable({}, { __index = world.ours }))
    assertEquals(world.broadcasts, 1)
    assertEquals(world.published, 1)
    Server.broadcastEvent({}, setmetatable({}, { __index = world.vanilla }))
    assertEquals(world.broadcasts, 2)
    assertEquals(world.published, 1)
end)

test("installing again hooks nothing twice", function()
    local world = setup()
    TCDataUpdated.install()
    setmetatable({}, { __index = world.ours }):readStream(1, {})
    Server.broadcastEvent({}, setmetatable({}, { __index = world.ours }))
    assertEquals(world.published, 2)
end)

test("the mod's name decides, whatever the zip is called", function()
    assertTrue(TCDataUpdated.isOwnEventClass("FS25_TheContractor_v2.TCJobStateChangedEvent", "FS25_TheContractor_v2"))
    assertTrue(not TCDataUpdated.isOwnEventClass("FS25_TheContractor.TCJobStateChangedEvent", "FS25_TheContractor_v2"))
    assertTrue(not TCDataUpdated.isOwnEventClass("TCJobStateChangedEvent", nil))
end)
