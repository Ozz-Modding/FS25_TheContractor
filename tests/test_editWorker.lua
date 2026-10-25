-- Editing a hired worker (066): the server's checks on a new name, gender
-- and look, applying it (cached look dropped, standing-spot model reloaded,
-- the menu told), the broadcast, and tcWorker rename.

local function setup()
    local world = stubs.install()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    Enterable = {}
    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/placeables/PlaceableTCParkingSlot.lua")
    world:load("src/placeables/PlaceableTCStandingSpot.lua")
    world:load("src/util/TCIdleStaff.lua")
    world:load("src/util/TCConsole.lua")

    -- Two wardrobe models, one per gender. Building a look is the engine's
    -- business: here a look builds unless it's marked broken.
    local maleStyle = { isConfigurationLoaded = true }
    local femaleStyle = { isConfigurationLoaded = true }
    PlayerSystem = {
        PLAYER_STYLES = {
            { filename = "male.xml", gender = "male", style = maleStyle },
            { filename = "female.xml", gender = "female", style = femaleStyle },
        },
        PLAYER_STYLES_BY_FILENAME = {},
    }
    for _, entry in ipairs(PlayerSystem.PLAYER_STYLES) do
        PlayerSystem.PLAYER_STYLES_BY_FILENAME[entry.filename] = entry
    end
    TCWorkerAppearance.toPlayerStyle = function(data)
        if data == nil or data.isBroken then
            return nil
        end
        return { builtFrom = data }
    end

    local staff = setmetatable({ workersByFarm = {}, candidatePool = {} }, TheContractorStaff_mt)
    world.menuEdits = {}
    g_currentMission.TheContractor = {
        Staff = staff,
        MenuContractor = {
            onWorkerEdited = function(_, workerId)
                table.insert(world.menuEdits, workerId)
            end,
        },
    }

    world.broadcasts = {}
    g_server = {
        broadcastEvent = function(_, event)
            table.insert(world.broadcasts, event)
        end,
    }
    TCWorkerEditedEvent = {
        new = function(farmId, workerId, name, gender, appearance)
            return { farmId = farmId, workerId = workerId, name = name, gender = gender, appearance = appearance }
        end,
    }

    TCConsole.reset()
    TheContractorStaff.registerConsoleCommands()
    return world, staff
end

local function look(model)
    return { model = model, configs = {} }
end

local function addWorker(staff, farmId, id)
    local worker = TheContractorWorker.new(id, farmId, "John White", 3, { small = 5 }, 1725, 34, 5)
    worker.gender = "male"
    worker.appearance = look("male.xml")
    worker.playerStyle = { cached = true }
    staff.workersByFarm[farmId] = staff.workersByFarm[farmId] or {}
    staff.workersByFarm[farmId][id] = worker
    return worker
end

test("names are trimmed, and empty or over-long ones refused", function()
    setup()
    assertEquals(TheContractorStaff.cleanName("  Jane Smith  "), "Jane Smith")
    assertEquals(TheContractorStaff.cleanName("   "), nil, "only spaces")
    assertEquals(TheContractorStaff.cleanName(""), nil, "empty")
    assertEquals(TheContractorStaff.cleanName(nil), nil, "missing")
    local longest = string.rep("a", TheContractorStaff.NAME_MAX_LENGTH)
    assertEquals(TheContractorStaff.cleanName(longest), longest, "at the limit")
    assertEquals(TheContractorStaff.cleanName(longest .. "a"), nil, "over the limit")
end)

test("a look must build and be on a model of the worker's gender", function()
    setup()
    assertTrue(TCWorkerAppearance.isValidLook(look("female.xml"), "female"), "female look, female worker")
    assertTrue(not TCWorkerAppearance.isValidLook(look("male.xml"), "female"), "male model, female worker")
    assertTrue(not TCWorkerAppearance.isValidLook(look("missing.xml"), "male"), "model not installed")
    local broken = look("male.xml")
    broken.isBroken = true
    assertTrue(not TCWorkerAppearance.isValidLook(broken, "male"), "doesn't build")
    assertTrue(not TCWorkerAppearance.isValidLook(nil, "male"), "no look")

    -- With no model of a gender at all, any model will do (as rolling does).
    PlayerSystem.PLAYER_STYLES[2].style.isConfigurationLoaded = false
    assertTrue(TCWorkerAppearance.isValidLook(look("male.xml"), "female"), "no female model to be had")
end)

test("an edit is applied, the cached look dropped, and it's broadcast", function()
    local world, staff = setup()
    local worker = addWorker(staff, 1, 7)

    local newLook = look("female.xml")
    local problem = staff:editWorker(1, 7, "  Jane Smith ", "female", newLook)

    assertEquals(problem, nil)
    assertEquals(worker.name, "Jane Smith")
    assertEquals(worker.gender, "female")
    assertEquals(worker.appearance, newLook)
    assertEquals(worker.playerStyle, nil, "cached look dropped")
    assertEquals(TCWorkerAppearance.getPlayerStyle(worker).builtFrom, newLook, "rebuilt from the new look")
    assertEquals(world.menuEdits[1], 7, "menu told")

    assertEquals(#world.broadcasts, 1)
    local event = world.broadcasts[1]
    assertEquals(event.farmId, 1)
    assertEquals(event.workerId, 7)
    assertEquals(event.name, "Jane Smith", "the cleaned name goes out")
    assertEquals(event.gender, "female")
    assertEquals(event.appearance, newLook)
end)

test("changing gender keeps the name", function()
    local _, staff = setup()
    local worker = addWorker(staff, 1, 7)

    assertEquals(staff:editWorker(1, 7, worker.name, "female", look("female.xml")), nil)
    assertEquals(worker.name, "John White")
    assertEquals(worker.gender, "female")
end)

test("a bad edit changes nothing and isn't broadcast", function()
    local world, staff = setup()
    local worker = addWorker(staff, 1, 7)
    local oldLook = worker.appearance

    local cases = {
        { "", "male", look("male.xml"), "empty name" },
        { "Jane", "other", look("male.xml"), "unknown gender" },
        { "Jane", "female", look("male.xml"), "look for the other gender" },
        { "Jane", "male", nil, "no look" },
    }
    for _, case in ipairs(cases) do
        assertTrue(staff:editWorker(1, 7, case[1], case[2], case[3]) ~= nil, case[4])
    end
    assertTrue(staff:editWorker(2, 7, "Jane", "male", look("male.xml")) ~= nil, "another farm's worker")
    assertTrue(staff:editWorker(1, 99, "Jane", "male", look("male.xml")) ~= nil, "no such worker")

    assertEquals(worker.name, "John White")
    assertEquals(worker.gender, "male")
    assertEquals(worker.appearance, oldLook)
    assertTrue(worker.playerStyle ~= nil, "cached look kept")
    assertEquals(#world.broadcasts, 0)
    assertEquals(#world.menuEdits, 0)
end)

test("a worker on a standing spot reloads their model but stays put", function()
    local _, staff = setup()
    local worker = addWorker(staff, 1, 7)
    local deleted = false
    local spot = { key = "3|0" }
    TCIdleStaff.figures[7] = { worker = { id = 7, stale = true }, spot = spot, isReady = true, isVisible = true,
        graphics = { delete = function() deleted = true end } }
    TCIdleStaff.occupied[spot.key] = 7
    TCIdleStaff.noStyle[7] = true

    staff:applyWorkerEdited(1, 7, "Jane Smith", "female", look("female.xml"))

    local figure = TCIdleStaff.figures[7]
    assertTrue(figure ~= nil, "still on the spot")
    assertEquals(TCIdleStaff.occupied[spot.key], 7)
    assertTrue(deleted, "old model freed")
    assertEquals(figure.graphics, nil, "loads again next update")
    assertEquals(figure.isReady, false)
    assertEquals(figure.worker, worker, "with the edited worker")
    assertEquals(TCIdleStaff.noStyle[7], nil, "new look gets a try")
end)

test("looks are rebuilt at mission start, after other mods' loadMap", function()
    local _, staff = setup()
    TCWorkerAppearance.roll = function(gender)
        return look(gender .. ".xml")
    end
    -- Built while the save loaded, before a wardrobe mod added its clothes.
    local worker = addWorker(staff, 1, 7)
    local savedLook = worker.appearance
    local broken = addWorker(staff, 1, 8)
    broken.appearance = look("gone.xml")
    broken.appearance.isBroken = true
    local candidate = TheContractorWorker.new(9, nil, "Jane Smith", 3, { small = 5 }, 1725, 34, 5)
    candidate.gender = "female"
    staff.candidatePool[9] = candidate
    local admin = { id = 10, gender = "female", appearance = look("gone.xml") }
    admin.appearance.isBroken = true
    g_currentMission.TheContractor.Office = { membersByFarm = { [1] = { administrator = admin } } }

    staff:restoreLooks()

    assertEquals(worker.appearance, savedLook, "a look that builds is kept")
    assertEquals(TCWorkerAppearance.getPlayerStyle(worker).builtFrom, savedLook, "early style rebuilt")
    assertEquals(broken.appearance.model, "male.xml", "a look that can't be rebuilt is rerolled")
    assertEquals(candidate.appearance.model, "female.xml", "a candidate with no look gets one")
    assertEquals(admin.appearance.model, "female.xml", "office staff are restored too")
end)

test("tcWorker rename renames and keeps the look", function()
    local world, staff = setup()
    local worker = addWorker(staff, 1, 7)
    local oldLook = worker.appearance
    local rename = TCConsole.groups.worker.subcommands.rename

    local result = rename.run(1, { "7", "Jane", "Smith" })
    assertEquals(result, "John White (#7) is now Jane Smith")
    assertEquals(worker.name, "Jane Smith")
    assertEquals(worker.gender, "male")
    assertEquals(worker.appearance, oldLook)
    assertEquals(#world.broadcasts, 1)

    assertEquals(rename.run(1, { "7" }), false, "no name")
    local tooLong = rename.run(1, { "7", string.rep("a", TheContractorStaff.NAME_MAX_LENGTH + 1) })
    assertTrue(string.find(tooLong, "^Error") ~= nil, "too long")
    assertEquals(worker.name, "Jane Smith")
end)
