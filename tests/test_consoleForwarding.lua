-- Server-only console commands typed by an admin on a client go to the
-- server and run there, for the typing player's farm and where they stand.

local function setup()
    local world = stubs.install()
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    world:load("src/util/TCConsole.lua")
    world:load("src/events/TCConsoleEvent.lua")

    g_currentMission.playerUserId = 7
    g_farmManager.getFarmByUserId = function(_, userId)
        return userId == 7 and { farmId = 2 } or nil
    end
    g_localPlayer = {
        getPosition = function() return 100, 5, 200 end,
        getCurrentFacingDirection = function() return 0, 2 end,
        getCurrentVehicle = function() return { id = 42 } end,
    }
    -- Admin checks, as TheContractorSettings has them.
    world.isAdmin = true
    world.isConnectionAdmin = true
    TheContractorSettings = {
        getCanLocalPlayerChange = function() return world.isAdmin end,
        getCanConnectionChange = function() return world.isConnectionAdmin end,
    }

    world.sent = {}
    g_client = {
        getServerConnection = function()
            return { sendEvent = function(_, event) table.insert(world.sent, event) end }
        end,
    }

    TCConsole.reset()
    world.runs = {}
    TCConsole.register("job", "poke", {
        args = "<what>",
        description = "Test command",
        run = function(farmId, args, context)
            table.insert(world.runs, { farmId = farmId, args = args, context = context })
            return args[1] ~= nil and "done" or false
        end,
    })
    TCConsole.register("job", "look", {
        description = "Read-only test command",
        serverOnly = false,
        run = function(farmId, args, context)
            table.insert(world.runs, { farmId = farmId, args = args, context = context })
            return "seen"
        end,
    })
    return world
end

local function onClient()
    g_currentMission.getIsServer = function() return false end
end

test("on the server a command runs at once with the typing player's context", function()
    local world = setup()
    TCConsole.dispatch(TCConsole.groups.job, { "poke", "it" })

    assertEquals(#world.runs, 1, "ran")
    assertEquals(#world.sent, 0, "nothing sent")
    local run = world.runs[1]
    assertEquals(run.farmId, 2, "the player's farm")
    assertEquals(run.args[1], "it", "the subcommand's args")
    assertEquals(run.context.userId, 7, "who typed it")
    assertEquals(run.context.x, 100, "where they stand")
    assertNear(run.context.dirZ, 1, 1e-9, "the way they look, made unit length")
    assertEquals(run.context.vehicleId, 42, "what they're in")
end)

test("an admin on a client sends it to the server instead of running it", function()
    local world = setup()
    onClient()
    TCConsole.dispatch(TCConsole.groups.job, { "poke", "it" })

    assertEquals(#world.runs, 0, "not run here")
    assertEquals(#world.sent, 1, "sent")
    local event = world.sent[1]
    assertEquals(event.groupKey, "job", "group")
    assertEquals(event.args[1], "poke", "subcommand")
    assertEquals(event.context.farmId, 2, "their farm")
end)

test("a player who isn't an admin can't send one, but read-only ones still run here", function()
    local world = setup()
    onClient()
    world.isAdmin = false
    TCConsole.dispatch(TCConsole.groups.job, { "poke", "it" })
    assertEquals(#world.sent, 0, "nothing sent")
    assertEquals(#world.runs, 0, "nothing run")

    TCConsole.dispatch(TCConsole.groups.job, { "look" })
    assertEquals(#world.runs, 1, "the read-only one ran on the client")
end)

test("the server runs a sent command with the sent context and answers that client", function()
    local world = setup()
    local request = TCConsoleEvent.newRequest("job", { "poke", "it" },
        { farmId = 3, userId = 9, x = 1, y = 2, z = 3, dirX = 0, dirZ = 1, vehicleId = 5 })

    -- Over the wire, as the server reads it.
    local stream = world:newStream()
    request:writeStream(stream, nil)
    local received = TCConsoleEvent.emptyNew()
    local answers = {}
    local connection = {
        getIsServer = function() return false end,
        sendEvent = function(_, event) table.insert(answers, event) end,
    }
    received:readStream(stream, connection)

    assertEquals(#world.runs, 1, "ran on the server")
    local run = world.runs[1]
    assertEquals(run.farmId, 3, "the sender's farm, not the server's")
    assertEquals(run.context.userId, 9, "the sender")
    assertEquals(run.context.z, 3, "their position")
    assertEquals(run.context.vehicleId, 5, "their vehicle")
    assertEquals(#answers, 1, "answered")
    assertTrue(answers[1].isResult, "with the result")
end)

test("the server refuses a sent command from someone who isn't an admin", function()
    local world = setup()
    world.isConnectionAdmin = false
    local answers = {}
    local event = TCConsoleEvent.newRequest("job", { "poke", "it" }, { farmId = 3 })
    event:run({ getIsServer = function() return false end,
        sendEvent = function(_, answer) table.insert(answers, answer) end })

    assertEquals(#world.runs, 0, "not run")
    assertEquals(#answers, 1, "told why")
end)

test("a context with no player goes over the wire without a position", function()
    local world = setup()
    local stream = world:newStream()
    TCConsole.writeContext(stream, { farmId = 2, userId = 7 })
    local context = TCConsole.readContext(stream)
    assertEquals(context.farmId, 2)
    assertEquals(context.userId, 7)
    assertTrue(not TCConsole.hasPosition(context), "no position")
    assertEquals(context.vehicleId, nil, "no vehicle")
end)
