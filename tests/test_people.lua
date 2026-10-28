-- 111: the People tab's Others view - the list of the farmers and the
-- official, what a farm has done for each (from its logbook entries and
-- invoices), editing one of them, and the customer on logbook entries
-- (kept through a save and the stream, and given to older entries from
-- their fields). The real Farmers and Logbook; the map is faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    TheContractorJobGeneration = {
        JOB_TYPES = { plow = {}, fallenTree = { offField = true } },
    }
    TheContractorFinances = {
        STATUS = { OUTSTANDING = "outstanding", PAID = "paid", OVERDUE = "overdue", WRITTEN_OFF = "writtenOff",
            PURSUING = "pursuing" },
    }

    Enterable = {}
    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/FarmerSplit.lua")
    world:load("src/business/Farmers.lua")
    world:load("src/util/TCIdleStaff.lua")
    world:load("src/util/TCYardFarmers.lua")
    TheContractorLogbook = nil
    world:load("src/business/Logbook.lua")

    TheContractorStaff = {
        NAME_MAX_LENGTH = 30,
        cleanName = function(name)
            name = name ~= nil and string.match(name, "^%s*(.-)%s*$") or nil
            if name == nil or name == "" or string.len(name) > 30 then
                return nil
            end
            return name
        end,
    }
    TheContractorStaff.getEditProblem = function(name, gender, appearance)
        if TheContractorStaff.cleanName(name) == nil then
            return "bad name"
        end
        if appearance == nil or appearance.isBroken then
            return "bad look"
        end
        return nil
    end

    -- Fields 1-3 on farmlands of the same id.
    world.fields = {}
    for id = 1, 3 do
        local farmland = { getId = function() return id end }
        world.fields[id] = { getFarmland = function() return farmland end }
    end
    g_fieldManager = {
        getFieldById = function(_, fieldId) return world.fields[fieldId] end,
    }

    local tc = g_currentMission.TheContractor
    world.companies = { [1] = true }
    tc.Company = {
        hasCompany = function(_, farmId) return world.companies[farmId] == true end,
    }
    world.menuEdits = {}
    tc.MenuContractor = {
        onPersonEdited = function(_, personId) table.insert(world.menuEdits, personId) end,
    }
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    TCEditPersonEvent = {
        new = function(farmId, personId, name, gender, appearance)
            return { farmId = farmId, personId = personId, name = name, gender = gender, appearance = appearance }
        end,
    }

    -- The official (#1, Zed Official) and three farmers: Bob (#2, farmlands
    -- 1 and 2, a yard), Alice (#3, farmland 3) and another Bob (#4, no land).
    local farmers = TheContractorFarmers.new()
    local function add(id, name, farmlandIds, yard, isOfficial)
        farmers.people[id] = {
            id = id, name = name, gender = "male", appearance = { model = "male.xml", configs = {} },
            isOfficial = isOfficial == true, farmlandIds = farmlandIds, yardFarmlandId = yard, targetAcres = 30,
        }
    end
    add(1, "Zed Official", {}, nil, true)
    add(2, "Bob", { 1, 2 }, 2)
    add(3, "Alice", { 3 })
    add(4, "Bob", {})
    farmers.officialId = 1
    farmers.nextId = 5
    farmers.isSetUp = true
    tc.Farmers = farmers
    world.farmers = farmers

    -- farmlandId -> { acres }, as getLand gives it.
    world.land = { [1] = { acres = 20 }, [2] = { acres = 15 }, [3] = { acres = 40 } }

    tc.Logbook = TheContractorLogbook.new()
    world.logbook = tc.Logbook
    return world
end

-- A finished job's logbook entry, as buildJobEntry would make one.
local function entry(def)
    return {
        jobId = def.jobId, farmId = def.farmId or 1, outcome = def.outcome or "completed",
        jobType = def.jobType or "plow", title = def.title or "Plowing", fieldId = def.fieldId or 1,
        location = def.location, customerId = def.customerId, day = def.day or 10,
        completedAt = def.completedAt or def.jobId * 100, price = def.price or 0,
        crew = {}, equipment = {}, supplies = {},
    }
end

test("the list has the official first, then the farmers by name, with their land and yard", function()
    local world = setup()
    local rows = world.farmers:getPeopleRows(world.land)

    local order = {}
    for _, row in ipairs(rows) do
        table.insert(order, row.person.id)
    end
    -- The two Bobs by id.
    assertEquals(table.concat(order, ","), "1,3,2,4")

    assertEquals(rows[1].acres, 0, "the official has no land")
    assertEquals(rows[1].farmlandCount, 0)
    assertEquals(rows[1].hasYard, false)
    assertEquals(rows[2].acres, 40)
    assertEquals(rows[2].hasYard, false)
    assertEquals(rows[3].acres, 35)
    assertEquals(rows[3].farmlandCount, 2)
    assertEquals(rows[3].hasYard, true)
    assertEquals(rows[4].acres, 0, "a farmer with no land stays on the list")
    assertEquals(rows[4].farmlandCount, 0)
end)

test("what a farm has done for someone comes from its own entries and their invoices", function()
    local world = setup()
    local invoices = {
        [1] = { amount = 1000, status = "paid" },
        [2] = { amount = 500, status = "overdue" },
        [3] = { amount = 300, status = "writtenOff" },
        [4] = { amount = 200, status = "pursuing" },
    }
    local entries = {
        entry({ jobId = 6, customerId = 3, outcome = "missed" }),
        entry({ jobId = 5, customerId = 3, price = 250, title = "Mowing" }),
        entry({ jobId = 4, customerId = 3 }),
        entry({ jobId = 3, customerId = 3 }),
        entry({ jobId = 2, customerId = 3 }),
        entry({ jobId = 1, customerId = 3 }),
        entry({ jobId = 7, customerId = 2, price = 999 }),
    }
    local history = TheContractorFarmers.getCustomerHistory(entries, 3, function(e)
        return invoices[e.jobId]
    end)

    assertEquals(history.completed, 5)
    assertEquals(history.missed, 1)
    -- The paid invoice, and job 5 paid on the spot (no invoice). Written off
    -- is neither paid nor owed.
    assertEquals(history.paid, 1250)
    assertEquals(history.owed, 700)
    assertEquals(history.last.jobId, 6, "the newest entry, missed or not")

    local nobody = TheContractorFarmers.getCustomerHistory(entries, 4, function() return nil end)
    assertEquals(nobody.completed, 0)
    assertEquals(nobody.paid, 0)
    assertEquals(nobody.last, nil)
end)

test("a farm with a company can edit someone, for everyone", function()
    local world = setup()
    local bob = world.farmers:getPerson(2)
    bob.playerStyle = { cached = true }
    local look = { model = "female.xml", configs = {} }

    local problem = world.farmers:editPerson(1, 2, "  Roberta  ", "female", look)
    assertEquals(problem, nil)
    assertEquals(bob.name, "Roberta")
    assertEquals(bob.gender, "female")
    assertEquals(bob.appearance.model, "female.xml")
    assertEquals(bob.playerStyle, nil, "the cached look goes")
    assertEquals(table.concat(world.menuEdits, ","), "2")
    assertEquals(#world.events, 1)
    assertEquals(world.events[1].personId, 2)
    assertEquals(world.events[1].name, "Roberta")

    -- A client applying the broadcast.
    world.farmers:applyPersonEdited(1, "Mrs Official", "female", look)
    assertEquals(world.farmers:getOfficial().name, "Mrs Official")
end)

test("a farmer standing in their yard stays there and reloads their new look", function()
    local world = setup()
    local deleted = false
    local spot = { key = "5:1", x = 0, y = 0, z = 0, yaw = 0 }
    TCYardFarmers.figures[2] = { person = { id = 2, stale = true }, spot = spot, isReady = true, isVisible = true,
        graphics = { delete = function() deleted = true end } }
    TCYardFarmers.noStyle[2] = true

    world.farmers:applyPersonEdited(2, "Roberta", "female", { model = "female.xml", configs = {} })

    local figure = TCYardFarmers.figures[2]
    assertTrue(figure ~= nil, "still in the yard")
    assertTrue(deleted, "old model freed")
    assertEquals(figure.graphics, nil, "loads again next update")
    assertEquals(figure.person, world.farmers:getPerson(2))
    assertEquals(TCYardFarmers.noStyle[2], nil, "new look gets a try")
    TCYardFarmers.reset()
end)

test("an edit is refused without a company, with a bad name or look, or for nobody", function()
    local world = setup()
    local alice = world.farmers:getPerson(3)
    local look = { model = "female.xml", configs = {} }

    assertTrue(world.farmers:editPerson(2, 3, "Alicia", "female", look) ~= nil, "farm 2 has no company")
    assertTrue(world.farmers:editPerson(1, 3, "   ", "female", look) ~= nil, "no name")
    assertTrue(world.farmers:editPerson(1, 3, "Alicia", "female", { isBroken = true }) ~= nil, "a look that won't build")
    assertTrue(world.farmers:editPerson(1, 99, "Alicia", "female", look) ~= nil, "nobody")

    assertEquals(alice.name, "Alice")
    assertEquals(#world.events, 0)
    assertEquals(#world.menuEdits, 0)
end)

test("older logbook entries get their customer from their field, workshop ones none", function()
    local world = setup()
    local entries = {
        entry({ jobId = 1, fieldId = 3 }),
        entry({ jobId = 2, fieldId = 1 }),
        entry({ jobId = 3, fieldId = 0, jobType = "fallenTree" }),
        entry({ jobId = 4, fieldId = 0, location = "Tractor at the workshop" }),
        entry({ jobId = 5, fieldId = 3, customerId = 2 }),
    }
    for _, e in ipairs(entries) do
        world.logbook:applyJobEntry(e)
    end

    assertEquals(world.farmers:linkLogbook(), 3)
    assertEquals(entries[1].customerId, 3)
    assertEquals(entries[2].customerId, 2)
    assertEquals(entries[3].customerId, 1, "an offField job is the official's")
    assertEquals(entries[4].customerId, nil, "a workshop job has no customer")
    assertEquals(entries[5].customerId, 2, "a linked entry keeps its customer")
end)

test("a logbook entry's customer survives a save, a load and the stream", function()
    local world = setup()
    world.logbook:applyJobEntry(entry({ jobId = 1, customerId = 3 }))
    world.logbook:applyJobEntry(entry({ jobId = 2, fieldId = 0, location = "Tractor at the workshop" }))

    local xmlFile = {}
    world.logbook:saveToXmlFile(xmlFile)
    local loaded = TheContractorLogbook.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getJobEntry(1, 1).customerId, 3)
    assertEquals(loaded:getJobEntry(1, 2).customerId, nil)

    local stream = world:newStream()
    TheContractorLogbook.writeJobEntry(stream, world.logbook:getJobEntry(1, 1))
    TheContractorLogbook.writeJobEntry(stream, world.logbook:getJobEntry(1, 2))
    assertEquals(TheContractorLogbook.readJobEntry(stream).customerId, 3)
    assertEquals(TheContractorLogbook.readJobEntry(stream).customerId, nil)
end)
