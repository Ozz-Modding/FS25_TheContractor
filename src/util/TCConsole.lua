-- Console commands. Everything the mod offers in the developer console is
-- a subcommand of one of a few group commands (tcWorker, tcJob, tcFinance,
-- tcCompany), and tcHelp lists the groups. Typing a group on its own (or
-- with "help") lists its subcommands with their arguments, so players can
-- find their way around without the docs. docs/commands.md has the detail.
--
-- Each subsystem registers its own subcommands at load, from a static
-- registerConsoleCommands() called in main.lua's loadMap:
--
--   TCConsole.register("worker", "sick", {
--       args = "<worker> [inspect]",
--       description = "Make a worker fall sick now",
--       serverOnly = true,          -- default true; false for read-only ones
--       run = function(farmId, args) ... end,
--   })
--
-- run gets the current player's farm and the arguments as strings, and
-- returns the text to print, or false for bad arguments (the subcommand's
-- usage is printed instead). Help, usage and "unknown subcommand" messages
-- are all built from these entries.
--
-- Commands aren't cheat-gated: they're there for players to shape their
-- game. Anything that changes state is server-only (single player or the
-- host), since the subsystems broadcast their own changes from there.

TCConsole = {}

TCConsole.HELP_COMMAND = "tcHelp"

-- In tcHelp's order.
TCConsole.GROUPS = {
    { key = "worker", command = "tcWorker", description = "Hire, list and change your staff" },
    { key = "job", command = "tcJob", description = "Offer, create and force jobs" },
    { key = "finance", command = "tcFinance", description = "Invoices, claims and botched jobs" },
    { key = "company", command = "tcCompany", description = "Reputation and Overview notices" },
}

-- groups[key] = { key, command, description, order = { names }, subcommands = { [lowerName] = def } }
TCConsole.groups = {}
TCConsole.installed = false

-- Every loadMap, before the subsystems register: drops the last save's entries.
function TCConsole.reset()
    TCConsole.uninstall()
    TCConsole.groups = {}
    for _, group in ipairs(TCConsole.GROUPS) do
        TCConsole.groups[group.key] = {
            key = group.key,
            command = group.command,
            description = group.description,
            order = {},
            subcommands = {},
        }
    end
end

function TCConsole.register(groupKey, name, def)
    local group = TCConsole.groups[groupKey]
    if group == nil then
        Logging.error("TheContractor: unknown console group '%s' for '%s'", tostring(groupKey), tostring(name))
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

    for _, groupInfo in ipairs(TCConsole.GROUPS) do
        local group = TCConsole.groups[groupInfo.key]
        addConsoleCommand(group.command, group.description .. ". Type it on its own to list subcommands.", "run", {
            run = function(_, ...)
                return TCConsole.dispatch(group, { ... })
            end,
        })
    end

    TCConsole.installed = true
end

function TCConsole.uninstall()
    if not TCConsole.installed then
        return
    end

    removeConsoleCommand(TCConsole.HELP_COMMAND)
    for _, groupInfo in ipairs(TCConsole.GROUPS) do
        removeConsoleCommand(groupInfo.command)
    end
    TCConsole.installed = false
end

-- Help ------------------------------------------------------------------------------

function TCConsole.getHelpText()
    local lines = { "The Contractor console commands:" }
    for _, groupInfo in ipairs(TCConsole.GROUPS) do
        table.insert(lines, string.format("  %-11s %s", groupInfo.command, groupInfo.description))
    end
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

function TCConsole.getGroupHelpText(group)
    local usages, width = {}, 0
    for i, name in ipairs(group.order) do
        usages[i] = TCConsole.getUsage(group, group.subcommands[string.lower(name)])
        width = math.max(width, string.len(usages[i]))
    end

    local lines = { group.command .. ": " .. group.description }
    local takesWorker = false
    for i, name in ipairs(group.order) do
        local def = group.subcommands[string.lower(name)]
        table.insert(lines, string.format("  %-" .. width .. "s  %s", usages[i], def.description))
        takesWorker = takesWorker or string.find(def.args, "<worker>", 1, true) ~= nil
    end
    if takesWorker then
        table.insert(lines, "<worker> is a worker's id or the start of their first or last name (tcWorker list shows both).")
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
        return string.format("%s %s only works on the server (single player or the host).", group.command, def.name)
    end

    local farmId = TCConsole.getFarmId()
    if farmId == nil then
        return "Error: no farm found for the current player"
    end

    local subArgs = {}
    for i = 2, #args do
        if args[i] ~= nil and args[i] ~= "" then
            table.insert(subArgs, args[i])
        end
    end

    local result = def.run(farmId, subArgs)
    if result == false then
        return string.format("Usage: %s\n%s", TCConsole.getUsage(group, def), def.description)
    end
    return result
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
