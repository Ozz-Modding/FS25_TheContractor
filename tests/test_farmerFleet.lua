-- 121: farmer fleets. The real FarmerFleet and Farmers (for acres and the
-- live-map wrapper) against a faked store: its items, their vehicle types'
-- specializations and their shop combinations.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorRepairContracts = {
        rollSeed = function(random) return math.floor(random() * 1000000) + 1 end,
    }
    world:load("src/business/Farmers.lua")
    world:load("src/business/FarmerFleet.lua")

    -- The store: { xml, category, specs, combinations (xmls or { category }) }.
    world.items = {}
    function world:addItem(xml, category, specs, combinations)
        local item = { xmlFilename = xml, categoryName = category, categoryNames = { category }, name = xml,
            specs = { combinations = {} }, specializations = specs }
        for _, combination in ipairs(combinations or {}) do
            if type(combination) == "table" then
                table.insert(item.specs.combinations, { filterCategories = combination })
            else
                table.insert(item.specs.combinations, { xmlFilename = combination })
            end
        end
        table.insert(self.items, item)
        return item
    end
    local function findItem(xml)
        for _, item in ipairs(world.items) do
            if item.xmlFilename == xml then
                return item
            end
        end
        return nil
    end
    g_storeManager = {
        getItems = function() return world.items end,
        getItemByXMLFilename = function(_, xml) return findItem(xml) end,
        getItemsByCombinationData = function(_, data)
            local found = {}
            if data.xmlFilename ~= nil then
                table.insert(found, { storeItem = findItem(data.xmlFilename) })
            else
                for _, item in ipairs(world.items) do
                    for _, category in ipairs(data.filterCategories) do
                        if item.categoryName == category then
                            table.insert(found, { storeItem = item })
                        end
                    end
                end
            end
            return found
        end,
    }
    g_vehicleTypeManager = {
        getObjectTypeFromXML = function(_, xml)
            local item = findItem(xml)
            return item ~= nil and { specializationsByName = item.specializations } or nil
        end,
    }
    StoreItemUtil = { loadSpecsFromXML = function() end }
    TheContractorFarmerFleet.clearCatalog()

    -- The farmers' land: farmland id -> acres.
    world.land = {}
    function world:addFarmer(id, acres, yardFarmlandId, machines)
        self.land[id] = { id = id, acres = acres, ownerFarmId = 0 }
        return { id = id, name = "Farmer " .. id, isOfficial = false, farmlandIds = { id },
            yardFarmlandId = yardFarmlandId, machines = machines }
    end
    return world
end

local DRIVES = { drivable = true }

-- A store with one of everything, and some that mustn't be picked.
local function addStore(world)
    world:addItem("small.xml", "TRACTORSS", DRIVES)
    world:addItem("medium.xml", "TRACTORSM", DRIVES)
    world:addItem("large.xml", "TRACTORSL", DRIVES)
    world:addItem("teli.xml", "TELELOADERVEHICLES", DRIVES, { { "TELELOADERTOOLS" } })
    world:addItem("telehandlerBaleFork.xml", "TELELOADERTOOLS", { dynamicMountAttacher = true })
    world:addItem("telehandlerFork.xml", "TELELOADERTOOLS", { dynamicMountAttacher = true })
    world:addItem("telehandlerShovel.xml", "TELELOADERTOOLS", { shovel = true, dynamicMountAttacher = true })
    world:addItem("combine.xml", "HARVESTERS", { drivable = true, combine = true },
        { "grainHeader.xml", "cornHeader.xml", "headerTrailer.xml" })
    world:addItem("bareCombine.xml", "HARVESTERS", { drivable = true, combine = true })
    world:addItem("grainHeader.xml", "CUTTERS", { cutter = true })
    world:addItem("cornHeader.xml", "CORNHEADERS", { cutter = true })
    world:addItem("headerTrailer.xml", "CUTTERTRAILERS", { trailer = true })
    world:addItem("forager.xml", "HARVESTERS", { drivable = true })
    world:addItem("tipper.xml", "TRAILERS", { trailer = true })
end

local function countRoles(farmer)
    local counts = {}
    for _, machine in ipairs(farmer.machines) do
        counts[machine.role] = (counts[machine.role] or 0) + 1
    end
    return counts
end

local function always(value)
    return function() return value end
end

-- The store ---------------------------------------------------------------------------------

test("the store's models by role, and only what fits a combine or telehandler goes on it", function()
    local world = setup()
    addStore(world)
    local catalog = TheContractorFarmerFleet.buildCatalog()
    local function xmls(models)
        local list = {}
        for _, model in ipairs(models) do
            table.insert(list, model.xmlFilename)
        end
        return table.concat(list, ",")
    end
    assertEquals(xmls(catalog.byRole.smallTractor), "small.xml")
    assertEquals(xmls(catalog.byRole.mediumTractor), "medium.xml")
    assertEquals(xmls(catalog.byRole.largeTractor), "large.xml")
    assertEquals(xmls(catalog.byRole.telehandler), "teli.xml")
    assertEquals(xmls(catalog.byRole.combine), "bareCombine.xml,combine.xml", "not the forager")
    assertEquals(xmls(catalog.byRole.trailer), "tipper.xml", "not the header trailer")
    assertEquals(xmls(catalog.attachments["combine.xml"]), "grainHeader.xml", "a grain header over a corn one")
    assertEquals(xmls(catalog.attachments["bareCombine.xml"]), "")
    assertEquals(xmls(catalog.attachments["teli.xml"]), "telehandlerBaleFork.xml",
        "not the pallet fork or the shovel")

    -- A combine is one with a header that fits, while there is one.
    assertEquals(TheContractorFarmerFleet.pickModel(catalog, "combine", always(0)).xmlFilename, "combine.xml")
end)

test("a bale grab is a bale fork, and a corn header does when there's no grain header", function()
    local world = setup()
    world:addItem("teli.xml", "TELELOADERVEHICLES", DRIVES, { "grab.xml" })
    world:addItem("grab.xml", "TELELOADERTOOLS", { baleGrab = true })
    world:addItem("combine.xml", "HARVESTERS", { drivable = true, combine = true }, { "cornHeader.xml" })
    world:addItem("cornHeader.xml", "CORNHEADERS", { cutter = true })
    local catalog = TheContractorFarmerFleet.buildCatalog()
    assertEquals(catalog.attachments["teli.xml"][1].xmlFilename, "grab.xml")
    assertEquals(catalog.attachments["combine.xml"][1].xmlFilename, "cornHeader.xml")
end)

-- The recipe ---------------------------------------------------------------------------------

test("every farmer: a small and a medium tractor, a combine with its header and a trailer", function()
    local world = setup()
    addStore(world)
    local farmer = world:addFarmer(1, 40)
    local added = TheContractorFarmerFleet.ensureFleets({ farmer }, world.land, TheContractorFarmerFleet.buildCatalog(),
        always(0.9))
    assertEquals(added, 5)
    local counts = countRoles(farmer)
    assertEquals(counts.smallTractor, 1)
    assertEquals(counts.mediumTractor, 1)
    assertEquals(counts.combine, 1)
    assertEquals(counts.header, 1)
    assertEquals(counts.trailer, 1)
    assertEquals(counts.telehandler, nil, "no yard")
    assertEquals(counts.largeTractor, nil, "not over 50 acres")

    local combine = TheContractorFarmerFleet.getMachinesByRole(farmer, "combine")[1]
    local header = TheContractorFarmerFleet.getAttachment(farmer, combine)
    assertEquals(header.role, "header")
    assertEquals(header.xmlFilename, "grainHeader.xml")
    assertEquals(header.hoursPerMonth, 0, "it doesn't drive")
    assertTrue(combine.hoursPerMonth > 0)
    assertTrue(combine.seed ~= nil)

    assertEquals(TheContractorFarmerFleet.ensureFleets({ farmer }, world.land, TheContractorFarmerFleet.buildCatalog(),
        always(0.1)), 0, "made once")
end)

test("about half get a second small tractor, rolled with the first", function()
    local world = setup()
    addStore(world)
    local catalog = TheContractorFarmerFleet.buildCatalog()
    local lucky = world:addFarmer(1, 40)
    TheContractorFarmerFleet.ensureFleets({ lucky }, world.land, catalog, always(0.1))
    assertEquals(countRoles(lucky).smallTractor, 2)

    -- One small tractor already (116's): never a second later.
    local old = world:addFarmer(2, 40, nil, { { id = 1, xmlFilename = "small.xml", seed = 5, fitted = {} } })
    TheContractorFarmerFleet.ensureFleets({ old }, world.land, catalog, always(0.1))
    assertEquals(countRoles(old).smallTractor, 1)
end)

test("a farmer with a yard has a telehandler and a bale fork, and gets them when they gain one", function()
    local world = setup()
    addStore(world)
    local catalog = TheContractorFarmerFleet.buildCatalog()
    local farmer = world:addFarmer(1, 40, 77)
    TheContractorFarmerFleet.ensureFleets({ farmer }, world.land, catalog, always(0.9))
    local telehandler = TheContractorFarmerFleet.getMachinesByRole(farmer, "telehandler")[1]
    assertEquals(telehandler.xmlFilename, "teli.xml")
    assertEquals(TheContractorFarmerFleet.getAttachment(farmer, telehandler).xmlFilename, "telehandlerBaleFork.xml")

    local later = world:addFarmer(2, 40)
    TheContractorFarmerFleet.ensureFleets({ later }, world.land, catalog, always(0.9))
    local before = #later.machines
    later.yardFarmlandId = 78
    assertEquals(TheContractorFarmerFleet.ensureFleets({ later }, world.land, catalog, always(0.9)), 2)
    assertEquals(#later.machines, before + 2)

    -- Losing the yard takes nothing away.
    later.yardFarmlandId = nil
    assertEquals(TheContractorFarmerFleet.ensureFleets({ later }, world.land, catalog, always(0.9)), 0)
    assertEquals(#later.machines, before + 2)
end)

test("a large tractor only over 50 acres and in the top 10% of farmers by land", function()
    local world = setup()
    local farmers = {}
    for id, acres in ipairs({ 60, 55, 45, 40 }) do
        table.insert(farmers, world:addFarmer(id, acres))
    end
    local ids = TheContractorFarmerFleet.getLargeTractorFarmerIds(farmers, world.land)
    assertTrue(ids[1] == true)
    assertTrue(ids[2] == nil, "over 50 but not in the top 10%")

    -- Eleven farmers: the top two.
    for id = 5, 11 do
        table.insert(farmers, world:addFarmer(id, 30))
    end
    ids = TheContractorFarmerFleet.getLargeTractorFarmerIds(farmers, world.land)
    assertTrue(ids[1] and ids[2])
    assertTrue(ids[3] == nil)

    -- Nobody over 50: nobody.
    world.land[1].acres, world.land[2].acres = 50, 48
    ids = TheContractorFarmerFleet.getLargeTractorFarmerIds(farmers, world.land)
    assertEquals(next(ids), nil)

    -- As well as the medium one.
    addStore(world)
    world.land[1].acres = 70
    TheContractorFarmerFleet.ensureFleets(farmers, world.land, TheContractorFarmerFleet.buildCatalog(), always(0.9))
    local counts = countRoles(farmers[1])
    assertEquals(counts.largeTractor, 1)
    assertEquals(counts.mediumTractor, 1)
    assertEquals(countRoles(farmers[2]).largeTractor, nil)
end)

test("116's machines get a role from their category, keep everything, and new ones never reuse an id", function()
    local world = setup()
    addStore(world)
    local farmer = world:addFarmer(1, 40, nil, {
        { id = 1, xmlFilename = "small.xml", seed = 5, hours = 2000, hoursDay = 3, hoursPerMonth = 30,
            fitted = { battery = 4 } },
        { id = 5, xmlFilename = "large.xml", seed = 6, fitted = {} },
        { id = 3, xmlFilename = "gone.xml", seed = 7, fitted = {} },
    })
    TheContractorFarmerFleet.ensureFleets({ farmer }, world.land, TheContractorFarmerFleet.buildCatalog(), always(0.9))
    local small = TheContractorFarmerFleet.getMachine(farmer, 1)
    assertEquals(small.role, "smallTractor")
    assertEquals(small.hours, 2000)
    assertEquals(small.fitted.battery, 4)
    assertEquals(TheContractorFarmerFleet.getMachine(farmer, 5).role, "largeTractor", "kept though not top 10%")
    assertEquals(TheContractorFarmerFleet.getMachine(farmer, 3).role, "mediumTractor", "a model that's gone")
    -- So the medium's there already: a combine, its header and a trailer.
    assertEquals(#farmer.machines, 6)
    local seen = {}
    for _, machine in ipairs(farmer.machines) do
        assertTrue(not seen[machine.id], "ids are unique")
        seen[machine.id] = true
        if machine.role == "combine" or machine.role == "header" or machine.role == "trailer" then
            assertTrue(machine.id > 5, "after the highest")
        end
    end
end)

test("nothing in the store for a role: left out, and a combine with nothing that fits has no header", function()
    local world = setup()
    world:addItem("small.xml", "TRACTORSS", DRIVES)
    world:addItem("bareCombine.xml", "HARVESTERS", { drivable = true, combine = true })
    local farmer = world:addFarmer(1, 40)
    TheContractorFarmerFleet.ensureFleets({ farmer }, world.land, TheContractorFarmerFleet.buildCatalog(), always(0.9))
    local counts = countRoles(farmer)
    assertEquals(counts.smallTractor, 1)
    assertEquals(counts.combine, 1)
    assertEquals(counts.header, nil)
    assertEquals(counts.mediumTractor, nil)
end)

test("on the live map, everyone's fleet at once, server only", function()
    local world = setup()
    addStore(world)
    world:load("src/business/FarmerSplit.lua")
    local farmers = TheContractorFarmers.new()
    farmers.officialId = 99
    farmers.people[99] = { id = 99, name = "The Official", isOfficial = true, farmlandIds = {} }
    farmers.people[1] = world:addFarmer(1, 60, 77)
    farmers.people[2] = world:addFarmer(2, 40)
    g_currentMission.TheContractor.Farmers = farmers
    TheContractorFarmerSplit.getFieldFarmlands = function()
        return { world.land[1], world.land[2] }
    end

    g_currentMission.getIsServer = function() return false end
    assertEquals(TheContractorFarmerFleet.ensureAll(), 0)
    g_currentMission.getIsServer = function() return true end
    assertTrue(TheContractorFarmerFleet.ensureAll() > 0)
    assertEquals(countRoles(farmers.people[1]).largeTractor, 1, "the biggest of two, over 50")
    assertEquals(countRoles(farmers.people[1]).telehandler, 1)
    assertEquals(farmers.people[99].machines, nil, "never the official")
end)

-- Hours and footprint ---------------------------------------------------------------------

test("a machine's hours: none until ADS ages it, then a month's work for every month", function()
    setup()
    local machine = { hoursPerMonth = 40 }
    assertEquals(TheContractorFarmerFleet.getHours(machine, 10, 2), nil)
    machine.hours, machine.hoursDay = 2400, 10
    assertNear(TheContractorFarmerFleet.getHours(machine, 10, 2), 2400, 0.001)
    assertNear(TheContractorFarmerFleet.getHours(machine, 16, 2), 2520, 0.001, "three months at 2 days each")
end)

test("a machine and its attachment take the ground of both, its centre moved forward", function()
    setup()
    local model = { xmlFilename = "combine.xml", width = 4, length = 9, height = 4, widthOffset = 0, lengthOffset = 0.5 }
    assertEquals(TheContractorFarmerFleet.getFootprint(model, nil), model)
    local footprint = TheContractorFarmerFleet.getFootprint(model, { width = 9, length = 2, height = 2 })
    assertEquals(footprint.width, 9)
    assertEquals(footprint.length, 11)
    assertEquals(footprint.height, 4)
    assertNear(footprint.lengthOffset, 1.5, 0.001)
    assertEquals(footprint.xmlFilename, "combine.xml")
    assertEquals(model.length, 9, "the model's untouched")
end)

-- Editing (122) ------------------------------------------------------------------------------

-- A store to edit in: two combines a grain header fits, one that only takes
-- its own header, one with none, two small tractors of other brands, and a
-- telehandler with its fork.
local function addEditStore(world)
    world:addItem("small.xml", "TRACTORSS", DRIVES).brandIndex = 2
    world:addItem("small2.xml", "TRACTORSS", DRIVES).brandIndex = 1
    world:addItem("medium.xml", "TRACTORSM", DRIVES)
    world:addItem("tipper.xml", "TRAILERS", { trailer = true })
    world:addItem("combine.xml", "HARVESTERS", { drivable = true, combine = true }, { "grainHeader.xml" })
    world:addItem("combine2.xml", "HARVESTERS", { drivable = true, combine = true },
        { "grainHeader.xml", "wideHeader.xml" })
    world:addItem("combine3.xml", "HARVESTERS", { drivable = true, combine = true }, { "ownHeader.xml" })
    world:addItem("bareCombine.xml", "HARVESTERS", { drivable = true, combine = true })
    world:addItem("grainHeader.xml", "CUTTERS", { cutter = true })
    world:addItem("wideHeader.xml", "CUTTERS", { cutter = true })
    world:addItem("ownHeader.xml", "CUTTERS", { cutter = true })
    world:addItem("teli.xml", "TELELOADERVEHICLES", DRIVES, { "baleGrab.xml" })
    world:addItem("baleGrab.xml", "TELELOADERTOOLS", { baleGrab = true })
    g_brandManager = {
        getBrandByIndex = function(_, index) return ({ { title = "Alpha" }, { title = "Zulu" } })[index] end,
    }
end

-- Farmer 1 with a fleet (always the first model of each), the official,
-- a company for farm 1 and nothing out. The real events.
local function setupEdit()
    local world = setup()
    addEditStore(world)
    local tc = g_currentMission.TheContractor
    local farmers = TheContractorFarmers.new()
    farmers.officialId = 99
    farmers.people[99] = { id = 99, name = "The Official", gender = "female", isOfficial = true, farmlandIds = {},
        targetAcres = 0 }
    local farmer = world:addFarmer(1, 40)
    farmer.gender, farmer.targetAcres = "male", 40
    farmers.people[1] = farmer
    Enterable = {}
    world:load("src/util/TCWorkerAppearance.lua")
    TheContractorFarmerFleet.ensureFleets({ farmer }, world.land, TheContractorFarmerFleet.buildCatalog(), always(0))
    tc.Farmers = farmers
    world.companies = { [1] = true }
    tc.Company = { hasCompany = function(_, farmId) return world.companies[farmId] == true end }
    tc.RepairContracts = { arrivals = {}, removals = {} }
    world.fleetChanges, world.results = {}, {}
    TheContractorFarmers.onFleetChanged = function(_, personId) table.insert(world.fleetChanges, personId) end
    tc.MenuContractor = {
        onFarmerMachineEdited = function(_, personId, machineId, problem, repickedId)
            table.insert(world.results, { personId = personId, machineId = machineId, problem = problem,
                repickedId = repickedId })
        end,
    }
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    world:load("src/events/TCFarmerFleetEvent.lua")
    world:load("src/events/TCEditFarmerMachineEvent.lua")
    world.farmer = farmer
    world.combine = TheContractorFarmerFleet.getMachinesByRole(farmer, "combine")[1]
    world.header = TheContractorFarmerFleet.getAttachment(farmer, world.combine)
    world.small = TheContractorFarmerFleet.getMachinesByRole(farmer, "smallTractor")[1]
    return world
end

local function xmlList(models)
    local list = {}
    for _, model in ipairs(models) do
        table.insert(list, model.xmlFilename)
    end
    return table.concat(list, ",")
end

test("122: the models a machine may be: its role's by brand then name, an attachment only what fits", function()
    local world = setupEdit()
    local catalog = TheContractorFarmerFleet.buildCatalog()
    assertEquals(world.combine.xmlFilename, "combine.xml")
    assertEquals(xmlList(TheContractorFarmerFleet.getModelChoices(catalog, world.farmer, world.small)),
        "small2.xml,small.xml", "Alpha before Zulu")
    assertEquals(xmlList(TheContractorFarmerFleet.getModelChoices(catalog, world.farmer, world.combine)),
        "combine.xml,combine2.xml,combine3.xml", "not the combine nothing fits")
    assertEquals(xmlList(TheContractorFarmerFleet.getModelChoices(catalog, world.farmer, world.header)),
        "grainHeader.xml")
    world.combine.xmlFilename = "combine2.xml"
    assertEquals(xmlList(TheContractorFarmerFleet.getModelChoices(catalog, world.farmer, world.header)),
        "grainHeader.xml,wideHeader.xml")
end)

test("122: the server refuses an edit without a company, for the official, of no machine, a wrong model, or out", function()
    local world = setupEdit()
    local F = TheContractorFarmerFleet
    local P = F.EDIT_PROBLEM
    local catalog = F.buildCatalog()
    local official = g_currentMission.TheContractor.Farmers:getOfficial()
    assertEquals(F.getEditProblem(2, world.farmer, world.small.id, "small2.xml", catalog), P.NO_COMPANY)
    assertEquals(F.getEditProblem(1, official, world.small.id, "small2.xml", catalog), P.NOT_FARMER)
    assertEquals(F.getEditProblem(1, nil, world.small.id, "small2.xml", catalog), P.NOT_FARMER)
    assertEquals(F.getEditProblem(1, world.farmer, 99, "small2.xml", catalog), P.NO_MACHINE)
    assertEquals(F.getEditProblem(1, world.farmer, world.small.id, "medium.xml", catalog), P.BAD_MODEL,
        "another role's model")
    assertEquals(F.getEditProblem(1, world.farmer, world.combine.id, "bareCombine.xml", catalog), P.BAD_MODEL,
        "nothing fits it")
    assertEquals(F.getEditProblem(1, world.farmer, world.header.id, "ownHeader.xml", catalog), P.BAD_MODEL,
        "doesn't fit the combine")
    assertEquals(F.getEditProblem(1, world.farmer, world.small.id, "small2.xml", catalog), nil)

    -- Out: the machine itself, or the combine its header goes on.
    local repairContracts = g_currentMission.TheContractor.RepairContracts
    table.insert(repairContracts.arrivals, { farmerId = 1, machineId = world.combine.id })
    assertEquals(F.getEditProblem(1, world.farmer, world.combine.id, "combine2.xml", catalog), P.OUT)
    assertEquals(F.getEditProblem(1, world.farmer, world.header.id, "grainHeader.xml", catalog), P.OUT)
    assertEquals(F.getEditProblem(1, world.farmer, world.small.id, "small2.xml", catalog), nil)
    -- Arrived and collected: allowed again.
    table.remove(repairContracts.arrivals)
    assertEquals(F.getEditProblem(1, world.farmer, world.combine.id, "combine2.xml", catalog), nil)

    -- On a live workshop job; then done, but its header still to collect.
    local job = { workshop = { farmerId = 1, machineId = world.combine.id }, isTerminal = function() return false end }
    g_currentMission.TheContractor.Jobs = { jobsByFarm = { [1] = { job } } }
    assertEquals(F.getEditProblem(1, world.farmer, world.combine.id, "combine2.xml", catalog), P.OUT)
    job.isTerminal = function() return true end
    table.insert(repairContracts.removals, { farmerId = 1, machineId = world.header.id })
    assertEquals(F.getEditProblem(1, world.farmer, world.combine.id, "combine2.xml", catalog), P.OUT)
    table.remove(repairContracts.removals)
    assertEquals(F.getEditProblem(1, world.farmer, world.combine.id, "combine2.xml", catalog), nil)
end)

test("122: a changed machine is a new one under the same id; a header that still fits is kept", function()
    local world = setupEdit()
    local F = TheContractorFarmerFleet
    local small = world.small
    small.hours, small.hoursDay, small.fitted = 2000, 4, { battery = 3 }
    local id, seed, hoursPerMonth = small.id, small.seed, small.hoursPerMonth
    local count = #world.farmer.machines
    math.randomseed(7)

    assertEquals(F.editMachine(1, 1, id, "small2.xml"), nil)
    assertEquals(small.xmlFilename, "small2.xml")
    assertEquals(small.id, id)
    assertTrue(small.seed ~= seed, "a new seed")
    assertEquals(small.hours, nil, "no age: ADS ages it next time it's out")
    assertEquals(small.hoursDay, nil)
    assertEquals(next(small.fitted), nil, "nothing fitted")
    assertEquals(small.hoursPerMonth, hoursPerMonth)
    assertEquals(#world.farmer.machines, count, "nothing added or taken away")
    assertEquals(table.concat(world.fleetChanges, ","), "1")
    assertEquals(#world.results, 1)
    assertEquals(world.results[1].problem, nil)
    assertEquals(world.results[1].repickedId, nil)
    -- Everyone's told: the fleet, then how it went.
    assertEquals(#world.events, 2)
    assertEquals(world.events[1].personId, 1)
    assertEquals(world.events[2].isResult, true)

    -- A combine the grain header still fits keeps it as it was.
    local header = world.header
    header.seed, header.hours = 77, 500
    assertEquals(F.editMachine(1, 1, world.combine.id, "combine2.xml"), nil)
    assertEquals(world.combine.xmlFilename, "combine2.xml")
    assertEquals(header.xmlFilename, "grainHeader.xml")
    assertEquals(header.seed, 77)
    assertEquals(header.hours, 500)
    assertEquals(world.results[2].repickedId, nil)

    -- The same model again changes nothing.
    world.events = {}
    seed = small.seed
    assertEquals(F.editMachine(1, 1, id, "small2.xml"), nil)
    assertEquals(small.seed, seed)
    assertEquals(#world.events, 0)
end)

test("122: a combine its header doesn't fit gets a new header, and the player's told", function()
    local world = setupEdit()
    local F = TheContractorFarmerFleet
    local header = world.header
    header.seed, header.hours, header.fitted = 77, 500, { knife = 2 }
    local headerId = header.id

    assertEquals(F.editMachine(1, 1, world.combine.id, "combine3.xml"), nil)
    assertEquals(header.id, headerId)
    assertEquals(header.attachedTo, world.combine.id)
    assertEquals(header.xmlFilename, "ownHeader.xml")
    assertTrue(header.seed ~= 77)
    assertEquals(header.hours, nil)
    assertEquals(next(header.fitted), nil)
    assertEquals(world.results[1].repickedId, headerId)
    assertEquals(world.events[2].repickedId, headerId)
end)

test("122: a refused edit changes nothing and tells the farm why", function()
    local world = setupEdit()
    local F = TheContractorFarmerFleet
    local before = world.small.xmlFilename
    assertEquals(F.editMachine(1, 1, world.small.id, "medium.xml"), F.EDIT_PROBLEM.BAD_MODEL)
    assertEquals(world.small.xmlFilename, before)
    assertEquals(#world.fleetChanges, 0)
    assertEquals(world.results[1].problem, F.EDIT_PROBLEM.BAD_MODEL)
    assertEquals(#world.events, 1, "only the result")
    assertEquals(world.events[1].problem, F.EDIT_PROBLEM.BAD_MODEL)

    -- Another farm's result isn't this player's to hear.
    assertEquals(F.editMachine(2, 1, world.small.id, "small2.xml"), F.EDIT_PROBLEM.NO_COMPANY)
    assertEquals(#world.results, 1)
end)

test("122: a client's request, the fleet and the result over the wire", function()
    local world = setupEdit()
    local F = TheContractorFarmerFleet
    local toServer = { getIsServer = function() return false end }
    local fromServer = { getIsServer = function() return true end }

    -- The request runs the server's edit.
    local stream = world:newStream()
    TCEditFarmerMachineEvent.new(1, 1, world.combine.id, "combine3.xml"):writeStream(stream, toServer)
    TCEditFarmerMachineEvent.emptyNew():readStream(stream, toServer)
    assertEquals(world.combine.xmlFilename, "combine3.xml")
    assertEquals(#world.events, 2)

    -- A client applying what the server sent: only id, role, model and
    -- attachedTo.
    local server = g_currentMission.TheContractor.Farmers
    local client = TheContractorFarmers.new()
    client.people[1] = { id = 1, name = "Farmer 1", farmlandIds = { 1 } }
    g_currentMission.TheContractor.Farmers = client
    g_currentMission.getIsServer = function() return false end
    world.results = {}
    for _, event in ipairs(world.events) do
        stream = world:newStream()
        event:writeStream(stream, fromServer)
        getmetatable(event).__index.emptyNew():readStream(stream, fromServer)
    end
    local person = client:getPerson(1)
    assertEquals(#person.machines, #server:getPerson(1).machines)
    local combine = F.getMachine(person, world.combine.id)
    assertEquals(combine.xmlFilename, "combine3.xml")
    assertEquals(combine.role, "combine")
    assertEquals(combine.seed, nil, "the seed stays on the server")
    assertEquals(combine.fitted, nil)
    local header = F.getAttachment(person, combine)
    assertEquals(header.id, world.header.id)
    assertEquals(header.xmlFilename, "ownHeader.xml")
    assertEquals(table.concat(world.fleetChanges, ","), "1,1", "the server's, then the client's")
    assertEquals(#world.results, 1)
    assertEquals(world.results[1].repickedId, world.header.id)
end)

test("122: an edited machine survives a save, and a joining client gets the fleet", function()
    local world = setupEdit()
    TheContractorFarmerFleet.editMachine(1, 1, world.small.id, "small2.xml")
    local farmers = g_currentMission.TheContractor.Farmers

    local xmlFile = {}
    farmers:saveToXmlFile(xmlFile)
    local loaded = TheContractorFarmers.new()
    loaded:loadFromXMLFile(xmlFile)
    local small = TheContractorFarmerFleet.getMachine(loaded:getPerson(1), world.small.id)
    assertEquals(small.xmlFilename, "small2.xml")
    assertEquals(small.seed, world.small.seed)
    assertEquals(small.hours, nil)

    local stream = world:newStream()
    farmers:writeInitialClientState(stream)
    local client = TheContractorFarmers.new()
    client:readInitialClientState(stream)
    local person = client:getPerson(1)
    assertEquals(#person.machines, #world.farmer.machines)
    assertEquals(TheContractorFarmerFleet.getMachine(person, world.small.id).xmlFilename, "small2.xml")
    assertEquals(TheContractorFarmerFleet.getMachine(person, world.header.id).attachedTo, world.combine.id)
    assertEquals(client:getOfficial().machines, nil)
end)

test("122: a fleet that grows on the live map goes to the clients", function()
    local world = setupEdit()
    world:load("src/business/FarmerSplit.lua")
    TheContractorFarmerSplit.getFieldFarmlands = function()
        return { world.land[1] }
    end
    world.farmer.yardFarmlandId = 77
    assertEquals(TheContractorFarmerFleet.ensureAll(), 2, "a telehandler and its fork")
    assertEquals(#world.events, 1)
    assertEquals(world.events[1].personId, 1)
    assertEquals(#world.events[1].machines, #world.farmer.machines)
end)
