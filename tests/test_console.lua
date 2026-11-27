-- TCConsole's groups, hints and the tcDebug gate, and the discoverability
-- rules over every registration in src/ (read from the source: most
-- modules can't load under the stubs, and the args are literal strings).

local function setup()
    local world = stubs.install()
    world:load("src/util/TCConsole.lua")
    world.commands = {}
    addConsoleCommand = function(name, description, funcName, target)
        world.commands[name] = target
    end
    removeConsoleCommand = function(name)
        world.commands[name] = nil
    end
    TCConsole.settingsDir = "modSettings/FS25_TheContractor/"
    world.files = {}
    fileExists = function(path)
        return world.files[path] == true
    end
    return world
end

-- Source scanning ---------------------------------------------------------------------

local function readFile(path)
    local file = io.open(path, "r")
    assert(file ~= nil, "can't open " .. path)
    local content = file:read("*a")
    file:close()
    return content
end

local function listLuaFiles()
    local isWindows = package.config:sub(1, 1) == "\\"
    local command = isWindows and 'dir /s /b src\\*.lua' or 'find src -name "*.lua"'
    local files = {}
    local pipe = io.popen(command)
    for line in pipe:lines() do
        table.insert(files, line)
    end
    pipe:close()
    assert(#files > 0, "found the sources")
    return files
end

-- Every TCConsole.register call: { group, name, args, hints = { word = true } },
-- and every registerHint's word.
local function scanRegistrations()
    local registrations, globalHints = {}, {}
    for _, path in ipairs(listLuaFiles()) do
        local source = readFile(path)
        for word in source:gmatch('TCConsole%.registerHint%("([%w_]+)"') do
            globalHints[word] = true
        end
        local position = 1
        while true do
            local first, last, group, name = source:find('TCConsole%.register%("(%w+)", "(%w+)", {', position)
            if first == nil then
                break
            end
            -- Not one in a comment (TCConsole.lua's own example).
            local lineStart = source:sub(1, first):match(".*\n()") or 1
            local isComment = source:sub(lineStart, first):match("^%s*%-%-") ~= nil
            -- The entry runs to its run function.
            local runAt = source:find("run = function", last, true) or #source
            local body = source:sub(last, runAt)
            local hints = {}
            local hintsBody = body:match("hints = (%b{})")
            if hintsBody ~= nil then
                for word in hintsBody:gmatch("([%a_][%w_]*) = ") do
                    hints[word] = true
                end
            end
            if not isComment then
                table.insert(registrations, { path = path, group = group, name = name,
                    args = body:match('args = "([^"]*)"') or "", hints = hints })
            end
            position = last
        end
    end
    return registrations, globalHints
end

-- A registration loop (tcFarmer preview and show) registers a variable name.
local LOOP_NAMES = { farmer = { "preview", "show" } }

local function getCommandSet(registrations)
    local commandByGroup = {}
    for _, group in ipairs(TCConsole.GROUPS) do
        commandByGroup[group.key] = group.command
    end
    local set = {}
    for _, registration in ipairs(registrations) do
        set[commandByGroup[registration.group] .. " " .. string.lower(registration.name)] = registration
    end
    for groupKey, names in pairs(LOOP_NAMES) do
        for _, name in ipairs(names) do
            set[commandByGroup[groupKey] .. " " .. name] = true
        end
    end
    return set
end

-- Words that are always an id or a name from somewhere, so need a hint.
local NEEDS_HINT = {
    worker = true, candidate = true, farmer = true, jobType = true, eventType = true, lot = true, prop = true,
    vehicle = true, fillType = true, state = true, details = true, month = true, outcome = true,
}

-- Tests -----------------------------------------------------------------------------------

test("a def's own hint wins over the shared one, and a live hint is read when asked", function()
    setup()
    TCConsole.reset()
    local reads = 0
    TCConsole.registerHint("jobId", "shared")
    TCConsole.registerHint("jobType", function()
        reads = reads + 1
        return "live"
    end)
    local def = { args = "<jobId> <jobType> [count]", hints = { jobId = "own" } }

    assertEquals(TCConsole.getHint("jobId", def), "own")
    assertEquals(TCConsole.getHint("jobId", {}), "shared")
    assertEquals(reads, 0, "not read until asked")
    assertEquals(TCConsole.getHint("jobType", def), "live")
    assertEquals(reads, 1)
    assertEquals(TCConsole.getHint("count", def), nil, "a plain value has none")
    assertEquals(#TCConsole.getHintLines({ def, def }), 2, "each hinted word once")
end)

test("reset drops the last save's hints", function()
    setup()
    TCConsole.reset()
    TCConsole.registerHint("worker", "x")
    TCConsole.reset()
    assertEquals(TCConsole.getHint("worker"), nil)
end)

test("args words are found inside enums and optional parts, once each", function()
    local words = TCConsole.getArgWords("<farmlandId|here> [show [farmlandId]] <value 0-100>")
    assertEquals(table.concat(words, ","), "farmlandId,here,show,value")
end)

test("tcDebug is installed with the other groups, no marker file needed", function()
    local world = setup()
    TheContractorSettings = { getCanConnectionChange = function() return true end }
    TCConsole.reset()
    local runs = 0
    TCConsole.register("debug", "poke", {
        run = function()
            runs = runs + 1
            return "done"
        end,
    })
    TCConsole.install()
    assertTrue(world.commands.tcWorker ~= nil, "the player's groups")
    assertTrue(world.commands.tcDebug ~= nil, "tcDebug too")
    TCConsole.runRequest("debug", { "poke" }, { farmId = 1 }, {})
    assertEquals(runs, 1, "a joined admin's tcDebug request runs on the server")
    TCConsole.uninstall()
    assertEquals(world.commands.tcDebug, nil, "uninstalled")
end)

test("every registration is in a known group, once", function()
    setup()
    local registrations = scanRegistrations()
    local groups, seen = {}, {}
    for _, group in ipairs(TCConsole.GROUPS) do
        groups[group.key] = true
    end
    for _, registration in ipairs(registrations) do
        assertTrue(groups[registration.group], registration.path .. ": unknown group " .. registration.group)
        local key = registration.group .. " " .. string.lower(registration.name)
        assertTrue(not seen[key], "registered twice: " .. key)
        seen[key] = true
    end
end)

test("every id or name an argument takes has a hint saying where to find it", function()
    setup()
    local registrations, globalHints = scanRegistrations()
    for _, registration in ipairs(registrations) do
        for _, word in ipairs(TCConsole.getArgWords(registration.args)) do
            if NEEDS_HINT[word] or word:match("Id$") then
                assertTrue(registration.hints[word] or globalHints[word],
                    string.format("%s %s: <%s> has no hint (%s)", registration.group, registration.name, word,
                        registration.path))
            end
        end
    end
end)

test("every command named in the source's strings exists", function()
    setup()
    local commands = getCommandSet(scanRegistrations())
    for _, path in ipairs(listLuaFiles()) do
        for literal in readFile(path):gmatch('"([^"\n]*)"') do
            for command, name in literal:gmatch("(tc%u%a+) (%a+)") do
                local isGroup = false
                for _, group in ipairs(TCConsole.GROUPS) do
                    isGroup = isGroup or group.command == command
                end
                if isGroup and name ~= "again" then
                    assertTrue(commands[command .. " " .. string.lower(name)] ~= nil,
                        string.format("%s names '%s %s', which doesn't exist", path, command, name))
                end
            end
        end
    end
end)

test("every subcommand is documented, and every documented one exists", function()
    setup()
    local commands = getCommandSet(scanRegistrations())
    local documented = {}
    local docs = { "docs/commands.md" }
    -- tcDebug's docs are in the private dev/ repo: a clone without it skips tcDebug.
    local debugDoc = io.open("dev/docs/debug-commands.md", "r")
    if debugDoc ~= nil then
        debugDoc:close()
        table.insert(docs, "dev/docs/debug-commands.md")
    end
    for _, doc in ipairs(docs) do
        for command, name in readFile(doc):gmatch("\n### `(tc%u%a+) (%a+)") do
            local key = command .. " " .. string.lower(name)
            assertTrue(commands[key] ~= nil, doc .. " documents '" .. key .. "', which doesn't exist")
            documented[key] = true
        end
    end
    for key in pairs(commands) do
        local skipped = debugDoc == nil and string.find(key, "^tcDebug ") ~= nil
        assertTrue(skipped or documented[key], "'" .. key .. "' isn't in docs/commands.md or dev/docs/debug-commands.md")
    end
end)

test("listNames sorts a copy of the names", function()
    setup()
    local names = { "tyre", "bale", "pallet" }
    assertEquals("bale, pallet, tyre", TCConsole.listNames(names))
    assertEquals("tyre", names[1], "the caller's list left alone")
end)

test("every TCConsole function the sources call exists", function()
    setup()
    for _, path in ipairs(listLuaFiles()) do
        local source = readFile(path)
        for name in source:gmatch("TCConsole%.([%a_][%w_]*)%(") do
            assertEquals("function", type(TCConsole[name]),
                string.format("%s calls TCConsole.%s", path, name))
        end
    end
end)
