-- TCLog: the detailed log is off unless switched on; warnings always go out.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCConsole.lua")
    -- The stubs switch it on for every other test; start from the shipped default.
    TCLog.enabled = false
    TCLog.settingsDir = nil
    return world
end

test("info is dropped while the log is off, warnings are not", function()
    local world = setup()
    TCLog.info("TheContractor: %s", "hidden")
    TCLog.warning("TheContractor: %s", "shown")
    assertEquals(#world.logs, 0)
    assertEquals(#world.warnings, 1)
    assertEquals(world.warnings[1], "TheContractor: shown")
end)

test("tcLog toggles it on and off", function()
    local world = setup()
    assertEquals(TCLog.toggle(), "The Contractor's detailed log is on.")
    TCLog.info("TheContractor: %d", 1)
    assertEquals(world.logs[1], "TheContractor: 1")

    assertEquals(TCLog.toggle(), "The Contractor's detailed log is off.")
    TCLog.info("TheContractor: %d", 2)
    assertEquals(#world.logs, 1)
end)

test("tcLog is installed and uninstalled with the groups, and listed in tcHelp", function()
    setup()
    local commands = {}
    addConsoleCommand = function(name, description, funcName, target)
        commands[name] = target
    end
    removeConsoleCommand = function(name)
        commands[name] = nil
    end

    TCConsole.reset()
    TCConsole.install()
    assertTrue(commands.tcLog ~= nil)
    assertEquals(commands.tcLog:run(), "The Contractor's detailed log is on.")
    assertTrue(string.find(TCConsole.getHelpText(), "tcLog", 1, true) ~= nil)

    TCConsole.uninstall()
    assertEquals(commands.tcLog, nil)
end)
