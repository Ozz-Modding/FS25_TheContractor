-- Console commands. Everything the mod offers in the developer console is
-- a subcommand of a group command (GROUPS below: tcWorker, tcJob, tcEvent,
-- ...), and tcHelp lists the groups. tcLog, which toggles TCLog's detailed
-- log, is the one other top-level command. Typing a group on its own (or
-- with "help") lists its subcommands with their arguments, so players can
-- find their way around without the docs. docs/commands.md has the detail
-- (dev/docs/debug-commands.md for tcDebug).
--
-- Each subsystem registers its own subcommands at load, from a static
-- registerConsoleCommands() called in main.lua's loadMap:
--
--   TCConsole.register("worker", "duty", {
--       args = "<worker> <hour|home>",
--       description = "Keep a worker on until an hour, or send them home",
--       serverOnly = true,          -- default true; false for read-only ones
--       hints = { ... },            -- optional, overrides HINTS for this one
--       run = function(farmId, args, context) ... end,
--   })
--
-- run(farmId, args, context) gets the typing player's farm, the arguments
-- as strings and the context (below), and returns the text to print, or
-- false for bad arguments (the subcommand's usage is printed instead). Help,
-- usage and "unknown subcommand" messages are all built from these entries.
--
-- Discoverability: nothing a command takes should need the docs to find.
-- An argument that's an id or a name from a list (<worker>, <jobId>,
-- <farmer>) has a hint naming the list command that shows them, and one
-- that's a set of names lists them: a short set inline in args (<on|off>),
-- a long or live one (<jobType>, <eventType>) as a hint that lists it.
-- Hints are registered with registerHint (or a def's own hints), keyed by
-- the word in args, and printed under the usage and the group's help.
-- tests/test_console.lua checks every id-like argument has one.
--
-- tcDebug is the testing group: spikes, forced rolls and readouts of what
-- players never see. It's only installed on a machine with DEBUG_FILENAME
-- in its modSettings folder (and a joined admin's request runs only if the
-- server has it too), so a release never shows it.
--
-- Commands aren't cheat-gated: they're there for players to shape their
-- game. Anything that changes state is server-only, since the subsystems
-- broadcast their own changes from there. Typed on the server (single
-- player, the host) it runs there and then. Typed by an admin on a client
-- (a dedicated server has nobody at its own console) it's sent to the
-- server (TCConsoleEvent), run there, and the answer comes back to print.
-- Either way run is on the server, so it calls the subsystems directly,
-- never sends an event of its own.
--
-- The context is the typing player, taken where they typed it:
--   { farmId, userId, x, y, z, dirX, dirZ, vehicleId }
-- x/y/z where they stand, dirX/dirZ the way they're looking (both nil with
-- no player in the game), vehicleId the vehicle they're in (nil on foot).
-- So a command about "here" or "this vehicle" reads the context, never
-- g_localPlayer, which on the server isn't the admin who typed it. Its
-- helpers: TCConsole.hasPosition, getVehicle, getPlayer.

TCConsole = {}

TCConsole.HELP_COMMAND = "tcHelp"
TCConsole.LOG_COMMAND = "tcLog"
TCConsole.LOG_DESCRIPTION = "Toggle the mod's detailed log on this machine (on by default)"

-- The marker file that unlocks tcDebug, in this machine's modSettings folder.
TCConsole.DEBUG_FILENAME = "tcDebug.txt"
TCConsole.settingsDir = g_currentModSettingsDirectory

-- In tcHelp's order.
TCConsole.GROUPS = {
    { key = "worker", command = "tcWorker", description = "Hire, list and manage your staff" },
    { key = "job", command = "tcJob", description = "List, offer, create and force jobs" },
    { key = "finance", command = "tcFinance", description = "Your claims and machinery insurance" },
    { key = "company", command = "tcCompany", description = "Reputation, notices, the office, storages and vehicle history" },
    { key = "event", command = "tcEvent", description = "Random events: their odds, and making one happen" },
    { key = "farmer", command = "tcFarmer", description = "The map's farmers: who they are, their machines, your relationships, a new land split" },
    { key = "yard", command = "tcYard", description = "Farm yards: list them, check a farmland, mark them on the map, override detection" },
    { key = "auction", command = "tcAuction", description = "The machinery auction: see it, announce one, call it off" },
    { key = "show", command = "tcShow", description = "The agricultural show: see it, announce one, call it off" },
    { key = "debug", command = "tcDebug", description = "Testing tools: spikes, forced rolls and hidden state", debugOnly = true },
}

-- groups[key] = { key, command, description, debugOnly, order = { names }, subcommands = { [lowerName] = def } }
TCConsole.groups = {}
-- hints[word] = text, or a function returning it (for a live list).
TCConsole.hints = {}
TCConsole.installed = false
TCConsole.debugEnabled = false
-- function(text), or nil: told each answer the server sends back to a
-- command this client sent (onRemoteResult), as well as printing it. The
-- dev dialog sets it while it's open (TCDevDialog).
TCConsole.resultListener = nil

-- Client: the server's answer to a command sent from here (TCConsoleEvent).
function TCConsole.onRemoteResult(text)
    local listener = TCConsole.resultListener
    if listener ~= nil then
        listener(text)
    end
end

-- Every loadMap, before the subsystems register: drops the last save's entries.
function TCConsole.reset()
    TCConsole.uninstall()
    TCConsole.groups = {}
    TCConsole.hints = {}
    for _, group in ipairs(TCConsole.GROUPS) do
        TCConsole.groups[group.key] = {
            key = group.key,
            command = group.command,
            description = group.description,
            debugOnly = group.debugOnly == true,
            order = {},
            subcommands = {},
        }
    end
    TCConsole.debugEnabled = TCConsole.readDebugEnabled()
end

function TCConsole.readDebugEnabled()
    local dir = TCConsole.settingsDir
    return dir ~= nil and fileExists ~= nil and fileExists(dir .. TCConsole.DEBUG_FILENAME) == true
end

-- Whether this machine has a group: tcDebug only with its marker file.
function TCConsole.isGroupEnabled(group)
    return not group.debugOnly or TCConsole.debugEnabled
end

function TCConsole.register(groupKey, name, def)
    local group = TCConsole.groups[groupKey]
    if group == nil then
        TCLog.error("TheContractor: unknown console group '%s' for '%s'", tostring(groupKey), tostring(name))
        return
    end
    def.name = name
    def.args = def.args or ""
    if def.serverOnly == nil then
        def.serverOnly = true
    end
    table.insert(group.order, name)
    group.subcommands[string.lower(name)] = def
end

-- Where to find what an argument word takes (see the header). text is a
-- string, or a function returning one for a list that's only known live.
function TCConsole.registerHint(word, text)
    TCConsole.hints[word] = text
end

-- Installing --------------------------------------------------------------------

function TCConsole.install()
    if TCConsole.installed then
        return
    end

    addConsoleCommand(TCConsole.HELP_COMMAND, "List The Contractor's console commands", "run", {
        run = function()
            return TCConsole.getHelpText()
        end,
    })
    addConsoleCommand(TCConsole.LOG_COMMAND, TCConsole.LOG_DESCRIPTION, "run", {
        run = function()
            return TCLog.toggle()
        end,
    })

    for _, groupInfo in ipairs(TCConsole.GROUPS) do
        local group = TCConsole.groups[groupInfo.key]
        if TCConsole.isGroupEnabled(group) then
            addConsoleCommand(group.command, group.description .. ". Type it on its own to list subcommands.", "run", {
                run = function(_, ...)
                    return TCConsole.dispatch(group, { ... })
                end,
            })
            group.installed = true
        end
    end

    TCConsole.installed = true
end

function TCConsole.uninstall()
    if not TCConsole.installed then
        return
    end

    removeConsoleCommand(TCConsole.HELP_COMMAND)
    removeConsoleCommand(TCConsole.LOG_COMMAND)
    for _, groupInfo in ipairs(TCConsole.GROUPS) do
        local group = TCConsole.groups[groupInfo.key]
        if group ~= nil and group.installed then
            removeConsoleCommand(groupInfo.command)
            group.installed = false
        end
    end
    TCConsole.installed = false
end

-- Help ------------------------------------------------------------------------------

function TCConsole.getHelpText()
    local lines = { "The Contractor console commands:" }
    for _, groupInfo in ipairs(TCConsole.GROUPS) do
        local group = TCConsole.groups[groupInfo.key]
        if group == nil or TCConsole.isGroupEnabled(group) then
            table.insert(lines, string.format("  %-11s %s", groupInfo.command, groupInfo.description))
        end
    end
    table.insert(lines, string.format("  %-11s %s", TCConsole.LOG_COMMAND, TCConsole.LOG_DESCRIPTION))
    table.insert(lines, "Type a command on its own to see what it can do, e.g. tcWorker")
    return table.concat(lines, "\n")
end

function TCConsole.getUsage(group, def)
    local usage = group.command .. " " .. def.name
    if def.args ~= "" then
        usage = usage .. " " .. def.args
    end
    return usage
end

-- The words in an args string, in order, each once (the hints' keys).
function TCConsole.getArgWords(args)
    local words, seen = {}, {}
    for word in string.gmatch(args or "", "%a[%w_]*") do
        if not seen[word] then
            seen[word] = true
            table.insert(words, word)
        end
    end
    return words
end

-- A word's hint for def (its own hints first), or nil.
function TCConsole.getHint(word, def)
    local hint = def ~= nil and def.hints ~= nil and def.hints[word] or nil
    if hint == nil then
        hint = TCConsole.hints[word]
    end
    if type(hint) == "function" then
        hint = hint()
    end
    return hint
end

-- "  word: hint" lines for defs' args, each word once.
function TCConsole.getHintLines(defs)
    local lines, seen = {}, {}
    for _, def in ipairs(defs) do
        for _, word in ipairs(TCConsole.getArgWords(def.args)) do
            local hint = not seen[word] and TCConsole.getHint(word, def) or nil
            if hint ~= nil then
                seen[word] = true
                table.insert(lines, string.format("  %s: %s", word, hint))
            end
        end
    end
    return lines
end

function TCConsole.getGroupHelpText(group)
    local usages, defs, width = {}, {}, 0
    for i, name in ipairs(group.order) do
        defs[i] = group.subcommands[string.lower(name)]
        usages[i] = TCConsole.getUsage(group, defs[i])
        width = math.max(width, string.len(usages[i]))
    end

    local lines = { group.command .. ": " .. group.description }
    for i, def in ipairs(defs) do
        table.insert(lines, string.format("  %-" .. width .. "s  %s", usages[i], def.description))
    end
    local hintLines = TCConsole.getHintLines(defs)
    if #hintLines > 0 then
        table.insert(lines, "What they take:")
        for _, line in ipairs(hintLines) do
            table.insert(lines, line)
        end
    end
    return table.concat(lines, "\n")
end

-- A subcommand's usage, description and hints: printed when its arguments
-- are wrong or missing.
function TCConsole.getUsageText(group, def)
    local lines = { "Usage: " .. TCConsole.getUsage(group, def), def.description }
    for _, line in ipairs(TCConsole.getHintLines({ def })) do
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end

-- Running ---------------------------------------------------------------------------

function TCConsole.dispatch(group, args)
    local name = args[1]
    if name == nil or name == "" or string.lower(name) == "help" then
        return TCConsole.getGroupHelpText(group)
    end

    local def = group.subcommands[string.lower(name)]
    if def == nil then
        return string.format("Unknown subcommand '%s'.\n%s", name, TCConsole.getGroupHelpText(group))
    end

    if def.serverOnly and not g_currentMission:getIsServer() then
        if not TheContractorSettings.getCanLocalPlayerChange() then
            return string.format("%s %s changes the game, so only the host or an admin can use it.", group.command,
                def.name)
        end
        g_client:getServerConnection():sendEvent(TCConsoleEvent.newRequest(group.key, args,
            TCConsole.getLocalContext()))
        return nil
    end

    return TCConsole.execute(group, def, args, TCConsole.getLocalContext())
end

-- Runs a subcommand (args[1] its name) for the context's player, wherever
-- the dispatch decided it runs. Returns the text to print.
function TCConsole.execute(group, def, args, context)
    if context.farmId == nil then
        return "Error: no farm found for the current player"
    end

    local subArgs = {}
    for i = 2, #args do
        if args[i] ~= nil and args[i] ~= "" then
            table.insert(subArgs, args[i])
        end
    end

    local result = def.run(context.farmId, subArgs, context)
    if result == false then
        return TCConsole.getUsageText(group, def)
    end
    return result
end

-- Server: a command an admin typed on a client (TCConsoleEvent). Returns
-- the text to send back.
function TCConsole.runRequest(groupKey, args, context, connection)
    local group = TCConsole.groups[groupKey]
    local name = args[1]
    local def = group ~= nil and name ~= nil and group.subcommands[string.lower(name)] or nil
    if def == nil or not TCConsole.isGroupEnabled(group) then
        return "Error: the server doesn't know that command"
    end
    if not TheContractorSettings.getCanConnectionChange(connection) then
        TCLog.warning("TheContractor: refused %s %s from a player who isn't an admin", group.command, def.name)
        return string.format("%s %s changes the game, so only the host or an admin can use it.", group.command,
            def.name)
    end
    TCLog.info("TheContractor: running %s %s for an admin", group.command, table.concat(args, " "))
    return TCConsole.execute(group, def, args, context)
end

-- Context ---------------------------------------------------------------------------

-- The player typing on this machine (see the header).
function TCConsole.getLocalContext()
    local context = { farmId = TCConsole.getFarmId(), userId = g_currentMission.playerUserId }
    local player = g_localPlayer
    if player == nil or player.getPosition == nil then
        return context
    end

    context.x, context.y, context.z = player:getPosition()
    local dirX, dirZ
    local camera = g_cameraManager ~= nil and g_cameraManager:getActiveCamera() or nil
    if camera ~= nil and camera ~= 0 then
        local dx, _, dz = localDirectionToWorld(camera, 0, 0, -1)
        dirX, dirZ = dx, dz
    elseif player.getCurrentFacingDirection ~= nil then
        dirX, dirZ = player:getCurrentFacingDirection()
    end
    local length = dirX ~= nil and math.sqrt(dirX * dirX + dirZ * dirZ) or 0
    if length > 0.001 then
        context.dirX, context.dirZ = dirX / length, dirZ / length
    else
        context.dirX, context.dirZ = 0, 1
    end

    local vehicle = player.getCurrentVehicle ~= nil and player:getCurrentVehicle() or nil
    if vehicle ~= nil then
        context.vehicleId = NetworkUtil.getObjectId(vehicle)
    end
    return context
end

function TCConsole.hasPosition(context)
    return context ~= nil and context.x ~= nil and context.z ~= nil
end

-- The vehicle the typing player is in, or nil.
function TCConsole.getVehicle(context)
    if context == nil or context.vehicleId == nil then
        return nil
    end
    return NetworkUtil.getObject(context.vehicleId)
end

-- The typing player (on the server, as it knows them), or nil.
function TCConsole.getPlayer(context)
    local playerSystem = g_currentMission.playerSystem
    if context == nil or context.userId == nil or playerSystem == nil then
        return nil
    end
    return playerSystem:getPlayerByUserId(context.userId)
end

-- Wire (TCConsoleEvent).
function TCConsole.writeContext(streamId, context)
    streamWriteInt32(streamId, context.farmId or 0)
    streamWriteInt32(streamId, context.userId or -1)
    if streamWriteBool(streamId, TCConsole.hasPosition(context)) then
        streamWriteFloat32(streamId, context.x)
        streamWriteFloat32(streamId, context.y or 0)
        streamWriteFloat32(streamId, context.z)
        streamWriteFloat32(streamId, context.dirX or 0)
        streamWriteFloat32(streamId, context.dirZ or 1)
    end
    streamWriteInt32(streamId, context.vehicleId or 0)
end

function TCConsole.readContext(streamId)
    local context = {}
    local farmId = streamReadInt32(streamId)
    context.farmId = farmId ~= 0 and farmId or nil
    local userId = streamReadInt32(streamId)
    context.userId = userId >= 0 and userId or nil
    if streamReadBool(streamId) then
        context.x = streamReadFloat32(streamId)
        context.y = streamReadFloat32(streamId)
        context.z = streamReadFloat32(streamId)
        context.dirX = streamReadFloat32(streamId)
        context.dirZ = streamReadFloat32(streamId)
    end
    local vehicleId = streamReadInt32(streamId)
    context.vehicleId = vehicleId ~= 0 and vehicleId or nil
    return context
end

function TCConsole.getFarmId()
    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil or farm.farmId == 0 then
        return nil
    end
    return farm.farmId
end

-- Argument helpers ----------------------------------------------------------------

-- Finds one of list's people by id or by the start of their first or last
-- name, case-insensitive. Returns it, or nil and the problem (nil for a
-- missing argument, so the caller can return false for its usage).
function TCConsole.findPerson(list, text, what)
    if text == nil then
        return nil, nil
    end

    local id = tonumber(text)
    if id ~= nil then
        for _, person in ipairs(list) do
            if person.id == id then
                return person, nil
            end
        end
        return nil, string.format("Error: no %s with id %d", what, id)
    end

    local wanted = string.lower(text)
    local matches = {}
    for _, person in ipairs(list) do
        local name = string.lower(person.name or "")
        local matched = string.sub(name, 1, string.len(wanted)) == wanted
        for word in string.gmatch(name, "%S+") do
            if string.sub(word, 1, string.len(wanted)) == wanted then
                matched = true
            end
        end
        if matched then
            table.insert(matches, person)
        end
    end

    if #matches == 1 then
        return matches[1], nil
    elseif #matches == 0 then
        return nil, string.format("Error: no %s called '%s'", what, text)
    end

    local names = {}
    for _, person in ipairs(matches) do
        table.insert(names, string.format("%s (#%d)", person.name, person.id))
    end
    return nil, string.format("'%s' matches more than one %s: %s. Use the id.", text, what,
        table.concat(names, ", "))
end

-- A hired worker on the farm, by id or name.
function TCConsole.findWorker(farmId, text)
    return TCConsole.findPerson(g_currentMission.TheContractor.Staff:getRoster(farmId), text, "worker")
end

-- Non-negative whole number, or default when the argument's missing; nil if
-- it's given but not a number of that kind.
function TCConsole.toCount(text, default)
    if text == nil then
        return default
    end
    local number = tonumber(text)
    if number == nil or number < 0 then
        return nil
    end
    return math.floor(number)
end

-- Names as a sorted, comma-separated list (for a hint, or a wrong one's
-- reply). Leaves names as it was.
function TCConsole.listNames(names)
    local sorted = {}
    for _, name in ipairs(names) do
        table.insert(sorted, tostring(name))
    end
    table.sort(sorted)
    return table.concat(sorted, ", ")
end
