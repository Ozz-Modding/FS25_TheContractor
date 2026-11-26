-- 173: the show's breeders' pen (RealisticLivestock only). The rules (the
-- spare farm id, the price, the trailer model, the types, ages and
-- breeder), the breeder's stand and bays on the showground, RL's API
-- found or not, the pen set out and stocked through the API, buying (all
-- or nothing: nothing charged unless RL moved it), a farm created on the
-- spare id, and the pen's sync, save and load.
--
-- The real show scene, classes, show animals, RL wrapper and pen; RL's API,
-- the show, its stands, the farmers and the world's vehicles faked.

local SHOW_DAY = 51
local HOST_ID = 7

local SUBTYPES = {
    { name = "COW_HOLSTEIN", typeIndex = 1, reproductionMinAgeMonth = 12 },
    { name = "BULL_HOLSTEIN", typeIndex = 1, reproductionMinAgeMonth = 12 },
    { name = "SHEEP_TEXEL", typeIndex = 2, reproductionMinAgeMonth = 8 },
    { name = "CHICKEN_BROWN", typeIndex = 3, reproductionMinAgeMonth = 4 },
}
local TYPES = {
    { name = "COW", subTypes = { 1, 2 } },
    { name = "SHEEP", subTypes = { 3 } },
    { name = "CHICKEN", subTypes = { 4 } },
}

local function installAnimalSystem()
    local byName = {}
    for index, subType in ipairs(SUBTYPES) do
        subType.subTypeIndex = index
        byName[subType.name] = subType
    end
    g_currentMission.animalSystem = {
        getTypes = function() return TYPES end,
        getTypeByIndex = function(_, index) return TYPES[index] end,
        getSubTypeByIndex = function(_, index) return SUBTYPES[index] end,
        getSubTypeByName = function(_, name) return byName[name] end,
        getSubTypeIndexByName = function(_, name) return byName[name] ~= nil and byName[name].subTypeIndex or nil end,
    }
end

-- RL's API, as its file promises it (scripts/api/RealisticLivestockAPI.lua).
local function installAPI(world)
    local api = {
        API_VERSION = 1,
        REASON = {
            NOT_READY = "notReady", NOT_SERVER = "notServer", INVALID_ANIMAL = "invalidAnimal",
            INVALID_TARGET = "invalidTarget", WRONG_FARM = "wrongFarm", ANIMAL_NOT_SUPPORTED = "animalNotSupported",
            NOT_ENOUGH_SPACE = "notEnoughSpace", ANIMAL_NOT_IN_SOURCE = "animalNotInSource", FAILED = "failed",
        },
    }
    world.holdings = {}
    world.created = {}
    world.adds = {}
    world.moves = {}
    world.sickQueue = {}
    world.nextNumber = 1
    local function typeOf(subTypeName)
        local subType = g_currentMission.animalSystem:getSubTypeByName(subTypeName)
        return TYPES[subType.typeIndex].name
    end
    function api.isReady() return not world.apiNotReady end
    function api.createAnimal(options)
        local animal = { subType = options.subType, age = options.age, quality = options.quality,
            diseased = table.remove(world.sickQueue, 1) == true, number = world.nextNumber }
        world.nextNumber = world.nextNumber + 1
        table.insert(world.created, animal)
        return animal
    end
    function api.describeAnimal(animal)
        return {
            id = { type = typeOf(animal.subType), country = "DE", herd = "214598", number = tostring(animal.number) },
            type = typeOf(animal.subType), subType = animal.subType, age = animal.age, weight = 500, health = 98,
            pregnant = false, lactating = false, castrated = false, diseased = animal.diseased,
            genetics = { quality = 1.4, health = 1.3, fertility = 1.2, metabolism = 1.1 },
        }
    end
    function api.getAnimalValue(animal) return 1000 end
    function api.getAnimalsIn(target)
        local animals = {}
        for _, animal in ipairs(world.holdings[target] or {}) do
            table.insert(animals, animal)
        end
        return animals
    end
    function api.addAnimalsTo(target, animals, farmId)
        table.insert(world.adds, { target = target, animals = animals, farmId = farmId })
        if target:getOwnerFarmId() ~= farmId or farmId < 1 or farmId > 8 then
            return false, api.REASON.WRONG_FARM
        end
        world.holdings[target] = world.holdings[target] or {}
        for _, animal in ipairs(animals) do
            table.insert(world.holdings[target], animal)
        end
        return true
    end
    function api.moveAnimals(source, target, animals, farmId)
        if world.moveRefusal ~= nil then
            return false, world.moveRefusal
        end
        if target:getOwnerFarmId() ~= farmId then
            return false, api.REASON.WRONG_FARM
        end
        local held = world.holdings[source] or {}
        for _, animal in ipairs(animals) do
            local found = nil
            for i, other in ipairs(held) do
                if other == animal then
                    found = i
                end
            end
            if found == nil then
                return false, api.REASON.ANIMAL_NOT_IN_SOURCE
            end
            table.remove(held, found)
            world.holdings[target] = world.holdings[target] or {}
            table.insert(world.holdings[target], animal)
        end
        table.insert(world.moves, { source = source, target = target, animals = animals, farmId = farmId })
        return true
    end
    RealisticLivestockAPI = api
    world.api = api
    return api
end

-- A livestock trailer or a husbandry for the buyer, that takes cows and
-- sheep with free slots, at (x, z).
local function addPlace(world, kind, farmId, x, z, freeSlots)
    local place = world:addVehicle({ name = kind == "husbandry" and "Cow barn" or "Buyer's trailer", farmId = farmId })
    place.rootNode = { x = x, z = z }
    place.freeSlots = freeSlots or 5
    if kind == "husbandry" then
        place.spec_husbandryAnimals = {}
    else
        place.spec_livestockTrailer = {}
    end
    function place:getClusters() return {} end
    function place:getSupportsAnimalSubType(subTypeIndex) return subTypeIndex ~= 4 end
    function place:getNumOfFreeAnimalSlots() return self.freeSlots end
    if kind == "husbandry" then
        table.insert(world.husbandries, place)
    else
        table.insert(g_currentMission.husbandrySystem.livestockTrailers, place)
    end
    return place
end

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    MessageType = { FARM_CREATED = 41 }
    world.subscriptions = {}
    g_messageCenter = {
        subscribe = function(_, messageType, callback, target)
            table.insert(world.subscriptions, { messageType = messageType, callback = callback, target = target })
        end,
        unsubscribeAll = function() end,
    }
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    FarmManager.MAX_NUM_FARMS = 8
    world.existingFarms = { [1] = true, [2] = true }
    world.balance = 100000
    g_farmManager.getFarmById = function(_, farmId)
        if not world.existingFarms[farmId] then
            return nil
        end
        return { farmId = farmId, getBalance = function() return world.balance end }
    end
    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        world.balance = world.balance + amount
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end
    g_currentMission.getHasPlayerPermission = function(_, permission, connection)
        assertEquals(permission, "tradeAnimals")
        return not world.noPermission
    end
    g_currentMission.environment = { currentMonotonicDay = SHOW_DAY, currentHour = 10, dayTime = 10 * 3600000,
        daysPerPeriod = 10 }
    world.husbandries = {}
    g_currentMission.husbandrySystem = {
        livestockTrailers = {},
        getPlaceablesByFarm = function(_, farmId)
            local found = {}
            for _, placeable in ipairs(world.husbandries) do
                if placeable:getOwnerFarmId() == farmId then
                    table.insert(found, placeable)
                end
            end
            return found
        end,
    }
    getWorldTranslation = function(node) return node.x, 0, node.z end
    installAnimalSystem()

    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/util/TCAuctionScene.lua")
    world:load("src/util/TCShowScene.lua")
    world:load("src/util/TCShowClasses.lua")
    world:load("src/util/TCShowAnimals.lua")
    world:load("src/util/TCVehicleIds.lua")
    world:load("src/util/TCRealisticLivestock.lua")
    world:load("src/util/TCBreedersPen.lua")
    world:load("src/business/BreedersPen.lua")
    world:load("src/events/TCBreedersPenEvent.lua")
    TCRealisticLivestock.reset()

    local tc = g_currentMission.TheContractor
    world.costScale = 1
    tc.Settings = { scaleCost = function(_, amount) return amount * world.costScale end }

    -- The showground (tests/test_showStands.lua's).
    local rect = { cx = 100, cz = 50, angle = 0, halfU = 60, halfV = 30 }
    local entrance = { x = rect.cx + rect.halfU + 10, z = rect.cz }
    world.scene = TCAuctionLayout.getScene(TCAuctionLayout.layOutOpenRect(rect, entrance), entrance, 99)
    world.scene.dressing = "show"
    world.open = true
    world.event = { id = 3, day = SHOW_DAY, hostFarmerId = HOST_ID }
    world.competitions = {}
    tc.Show = {
        getEvent = function() return world.event end,
        registerCompetition = function(_, key, def) world.competitions[key] = def end,
    }
    tc.ShowStands = {
        getScene = function() return world.scene end,
        isOpen = function() return world.open end,
        getFarmersAtShow = function() return { HOST_ID, 8, 9 } end,
    }
    world.people = {}
    for id = 7, 12 do
        world.people[id] = { id = id, name = "Farmer " .. id }
    end
    tc.Farmers = {
        getPerson = function(_, id) return world.people[id] end,
        getFarmers = function()
            local farmers = {}
            for id = 7, 12 do
                table.insert(farmers, world.people[id])
            end
            return farmers
        end,
    }

    local pen = TheContractorBreedersPen.new()
    pen:register(tc.Show)
    world.spawned, world.deleted, world.pendingSpawns = {}, {}, {}
    local nextUnique = 1
    pen.engine = {
        pickTrailerModel = function(typeName, count)
            if world.noModels then
                return nil, 0
            end
            return { xmlFilename = typeName .. ".xml" }, 5
        end,
        spawnTrailer = function(spawner, entry, bay, generation)
            local trailer = world:addVehicle({ name = entry.typeName .. " trailer", farmId = spawner.farmId })
            trailer.uniqueId = "breeder" .. nextUnique
            nextUnique = nextUnique + 1
            function trailer:getUniqueId() return self.uniqueId end
            trailer.bay = bay
            table.insert(world.spawned, { trailer = trailer, entry = entry })
            if world.deferSpawns then
                table.insert(world.pendingSpawns, { trailer = trailer, entry = entry, generation = generation })
            else
                spawner:onTrailerSpawned(trailer, entry, generation)
            end
        end,
        deleteVehicle = function(vehicleId)
            table.insert(world.deleted, vehicleId)
        end,
    }
    -- random(n) -> 1, random(a, b) -> a.
    pen.random = function(a, b)
        if b ~= nil then
            return a
        end
        return 1
    end
    tc.BreedersPen = pen
    world.tc = tc
    world.pen = pen
    return world
end

local A = nil

-- The rules (pure) ------------------------------------------------------------------------------------

test("the trailers' farm id is the highest with no farm, 8 then 7, and none when all 8 are taken", function()
    setup()
    A = TCBreedersPen.ANSWER
    local farms = { [1] = true, [2] = true }
    local function exists(id) return farms[id] == true end
    assertEquals(TCBreedersPen.pickFarmId(exists, 8), 8)
    farms[8] = true
    assertEquals(TCBreedersPen.pickFarmId(exists, 8), 7)
    for id = 1, 8 do
        farms[id] = true
    end
    assertEquals(TCBreedersPen.pickFarmId(exists, 8), nil)
end)

test("the breeder asks more than RL pays, so buying here and selling back never makes money", function()
    setup()
    assertTrue(TCBreedersPen.MARKUP > 1, "the markup stays above 1")
    assertTrue(TCBreedersPen.getPrice(1000) > 1000)
    assertEquals(TCBreedersPen.getPrice(1000, 1.3), 1300)
    assertEquals(TCBreedersPen.getPrice(0), 0)
end)

test("a trailer model: the base game's, the fewest slots that take the stock, else the most", function()
    setup()
    local models = {
        { xmlFilename = "modBig.xml", slots = { COW = 4 }, isBaseGame = false },
        { xmlFilename = "big.xml", slots = { COW = 8, SHEEP = 20 }, isBaseGame = true },
        { xmlFilename = "small.xml", slots = { COW = 3 }, isBaseGame = true },
        { xmlFilename = "tiny.xml", slots = { COW = 2 }, isBaseGame = true },
    }
    assertEquals(TCBreedersPen.pickTrailerModel(models, "COW", 3).xmlFilename, "small.xml")
    local model, slots = TCBreedersPen.pickTrailerModel(models, "COW", 10)
    assertEquals(model.xmlFilename, "big.xml", "none fits: the most there are")
    assertEquals(slots, 8)
    assertEquals(TCBreedersPen.pickTrailerModel(models, "SHEEP", 3).xmlFilename, "big.xml")
    assertEquals(TCBreedersPen.pickTrailerModel(models, "PIG", 3), nil, "nothing takes pigs")
    local modOnly = { { xmlFilename = "modBig.xml", slots = { COW = 4 }, isBaseGame = false } }
    assertEquals(TCBreedersPen.pickTrailerModel(modOnly, "COW", 3).xmlFilename, "modBig.xml", "a mod's if that's all")
end)

test("the types come from the show's classes, an age inside a class's band, the breeder from the show", function()
    setup()
    local classes = TCShowClasses.listClasses(g_currentMission.animalSystem)
    local types = TCBreedersPen.pickTypes(classes, 5, function() return 1 end)
    local names = {}
    for _, entry in ipairs(types) do
        names[entry.typeName] = #entry.classes
    end
    assertEquals(names.CHICKEN, nil, "never chickens: no trailer takes them")
    assertTrue(names.COW ~= nil and names.SHEEP ~= nil)
    assertEquals(#TCBreedersPen.pickTypes(classes, 1, function() return 1 end), 1, "no more than asked")

    local band = { from = 6, to = 24 }
    assertEquals(TCBreedersPen.rollAge(band, function(a) return a end), 6)
    assertEquals(TCBreedersPen.rollAge(band, function(_, b) return b end), 23, "inside the band")
    assertEquals(TCBreedersPen.rollAge({ from = 24 }, function(_, b) return b end), 24 + TCBreedersPen.ADULT_SPAN - 1)

    local farmers = { { id = 7 }, { id = 8 }, { id = 9 }, { id = 10 }, { id = 11 } }
    local breeder = TCBreedersPen.pickBreeder(3, farmers, { [7] = true })
    assertTrue(breeder ~= nil and breeder ~= 7, "never one excluded")
    assertEquals(TCBreedersPen.pickBreeder(3, farmers, { [7] = true }), breeder, "the same on every machine")
    assertEquals(TCBreedersPen.pickBreeder(3, { { id = 7 } }, { [7] = true }), nil, "nobody to spare")
end)

test("RL's refusals: gone is sold, no room is no room, anything else failed", function()
    local world = setup()
    local reasons = installAPI(world).REASON
    assertEquals(TCBreedersPen.getAnswerForReason(reasons, reasons.ANIMAL_NOT_IN_SOURCE), A.SOLD)
    assertEquals(TCBreedersPen.getAnswerForReason(reasons, reasons.NOT_ENOUGH_SPACE), A.NO_ROOM)
    assertEquals(TCBreedersPen.getAnswerForReason(reasons, reasons.WRONG_FARM), A.NO_ROOM)
    assertEquals(TCBreedersPen.getAnswerForReason(reasons, reasons.FAILED), A.FAILED)
    assertEquals(TCBreedersPen.getAnswerForReason(reasons, "somethingNew"), A.FAILED)
end)

-- The showground ----------------------------------------------------------------------------------------

test("the breeder's stand is one that isn't a stall, and their bays leave one for the entrants", function()
    local world = setup()
    local stand = TCShowScene.getBreederStand(world.scene)
    assertTrue(stand ~= nil, "a stand for the breeder")
    for _, index in pairs(TCShowScene.getStallStands(#TCShowScene.getAreas(world.scene).stands)) do
        assertTrue(index ~= stand.index, "not a stall's")
    end
    local layout = TCShowScene.layOut(world.scene)
    for _, stall in ipairs(layout.stalls) do
        assertTrue(math.abs(stall.x - stand.x) > 0.5 or math.abs(stall.z - stand.z) > 0.5, "not where a stallholder is")
    end
    local bays = TCShowScene.getBreederBays(world.scene, 20)
    local areas = TCShowScene.getAreas(world.scene)
    assertEquals(#bays, areas.lines.count - 1, "one bay left for the entrants")
    assertEquals(bays[1].bay, areas.lines.count, "from the stands' end")
    for _, bay in ipairs(bays) do
        assertEquals(TCShowScene.findBay(world.scene, bay.x, bay.z), bay.bay, "parked in its bay")
    end
    assertEquals(#TCShowScene.getBreederBays(world.scene, 2), 2)
    assertEquals(TCShowScene.getBreederStand(nil), nil)
end)

-- RL's API -----------------------------------------------------------------------------------------------

test("RL's API is used only when it's there, new enough, complete and ready", function()
    local world = setup()
    RealisticLivestockAPI = nil
    assertEquals(TCRealisticLivestock.getAPI(), nil, "no RL")
    local api = installAPI(world)
    assertTrue(TCRealisticLivestock.getAPI() == api)
    api.API_VERSION = 0
    assertEquals(TCRealisticLivestock.getAPI(), nil, "too old")
    api.API_VERSION = 1
    world.apiNotReady = true
    assertEquals(TCRealisticLivestock.getAPI(), nil, "not ready")
    world.apiNotReady = false
    local moveAnimals = api.moveAnimals
    api.moveAnimals = nil
    local warnings = #world.warnings
    assertEquals(TCRealisticLivestock.getAPI(), nil, "a function gone")
    TCRealisticLivestock.getAPI()
    assertEquals(#world.warnings, warnings + 1, "warned once")
    api.moveAnimals = moveAnimals
    assertEquals(TCRealisticLivestock.getAPIKey({ id = { type = "COW", country = "DE", herd = "1", number = "2" } }),
        "COW DE 1 2")
end)

-- Setting out ----------------------------------------------------------------------------------------------

test("without RL's API there's no pen, and nothing's put out", function()
    local world = setup()
    RealisticLivestockAPI = nil
    assertTrue(world.pen:open(world.event) ~= nil, "a reason why not")
    assertEquals(#world.spawned, 0)
    assertTrue(not world.pen:isOut())
end)

test("set out: trailers on the spare farm id, stocked with RL's premium animals of the show's types", function()
    local world = setup()
    installAPI(world)
    world.competitions.breedersPen.onSetOut(world.event)
    local pen = world.pen
    assertEquals(pen.farmId, 8)
    assertEquals(pen.showId, world.event.id)
    assertEquals(#pen.trailerIds, TCBreedersPen.TYPES, "a trailer a type")
    assertTrue(pen:isOut() and pen:isOpen())
    local typesSeen = {}
    for _, spawn in ipairs(world.spawned) do
        assertEquals(spawn.trailer:getOwnerFarmId(), 8, "the spare farm id's")
        typesSeen[spawn.entry.typeName] = true
    end
    assertTrue(typesSeen.COW and typesSeen.SHEEP and not typesSeen.CHICKEN)
    assertEquals(#world.adds, TCBreedersPen.TYPES)
    for _, add in ipairs(world.adds) do
        assertEquals(add.farmId, 8, "stocked as the spare farm id")
        assertEquals(#add.animals, TCBreedersPen.PER_TRAILER)
    end
    for _, animal in ipairs(world.created) do
        assertEquals(animal.quality, TCBreedersPen.QUALITY)
        assertTrue(animal.age ~= nil and animal.age >= 3, "an age inside a band")
    end
    local breeder = pen:getBreeder()
    assertTrue(breeder ~= nil, "a breeder")
    assertTrue(breeder.id ~= HOST_ID and breeder.id ~= 8 and breeder.id ~= 9, "not the host or a farmer about")
    assertEquals(#pen:getCatalogue(), TCBreedersPen.TYPES * TCBreedersPen.PER_TRAILER)
    assertTrue(world.events[#world.events].pen == pen, "sent to every machine")

    -- Set out again (the console's show day): what's out stays.
    world.competitions.breedersPen.onSetOut(world.event)
    assertEquals(#world.spawned, TCBreedersPen.TYPES)
end)

test("a sick animal's drawn again, and a farm on 8 means the pen's on 7, none spare none", function()
    local world = setup()
    installAPI(world)
    world.sickQueue = { true, true }
    world.existingFarms[8] = true
    world.pen:open(world.event)
    assertEquals(world.pen.farmId, 7)
    for _, entry in ipairs(world.pen:getCatalogue(true)) do
        assertTrue(not entry.info.diseased, "no sick one put out")
    end
    assertEquals(#world.created, TCBreedersPen.TYPES * TCBreedersPen.PER_TRAILER + 2, "two drawn again")

    local full = setup()
    installAPI(full)
    for id = 1, 8 do
        full.existingFarms[id] = true
    end
    assertTrue(full.pen:open(full.event) ~= nil)
    assertEquals(#full.spawned, 0, "no spare id, no pen")
end)

test("a trailer that loads after the pen's closed is taken away", function()
    local world = setup()
    installAPI(world)
    world.deferSpawns = true
    world.pen:open(world.event)
    world.pen:close()
    local pending = world.pendingSpawns[1]
    world.pen:onTrailerSpawned(pending.trailer, pending.entry, pending.generation)
    assertEquals(#world.pen.trailerIds, 0)
    assertEquals(world.deleted[#world.deleted], pending.trailer.id)
end)

-- Buying -----------------------------------------------------------------------------------------------------

local function openPen(world)
    installAPI(world)
    world.pen:open(world.event)
    local stand = TCShowScene.getBreederStand(world.scene)
    world.trailer = addPlace(world, "trailer", 1, stand.x + 5, stand.z)
    world.barn = addPlace(world, "husbandry", 1, 0, 0)
    return world.pen:getCatalogue()
end

test("bought into a trailer at the show: RL moves it, then the farm's charged the price, once", function()
    local world = setup()
    local catalogue = openPen(world)
    local entry = catalogue[1]
    local targets = world.pen:getTargets(1, entry.subTypeIndex)
    assertEquals(#targets, 2, "the trailer at the show and the barn")
    assertEquals(targets[1].object, world.trailer)
    assertEquals(targets[1].fee, 0, "free into a trailer")
    assertEquals(targets[2].fee, TCBreedersPen.DELIVERY_FEE, "the barn's delivered")

    local answer, paid = world.pen:handleBuy(1, entry.key, world.trailer.id, nil)
    assertEquals(answer, A.BOUGHT)
    assertEquals(paid, entry.price)
    assertEquals(#world.moves, 1)
    assertEquals(world.moves[1].target, world.trailer)
    assertEquals(world.moves[1].farmId, 1)
    assertEquals(#world.money, 1)
    assertEquals(world.money[1].amount, -entry.price)
    assertEquals(world.money[1].moneyType, MoneyType.TC_BREEDER_STOCK)
    assertEquals(#world.pen:getCatalogue(), #catalogue - 1, "gone from the stand")

    local again = world.pen:handleBuy(2, entry.key, world.trailer.id, nil)
    assertEquals(again, A.SOLD, "a second buyer finds it gone")
    assertEquals(#world.money, 1, "and pays nothing")
end)

test("delivered to a barn costs the fee on top, scaled as any fixed cost", function()
    local world = setup()
    local entry = openPen(world)[2]
    world.costScale = 2
    local answer, paid = world.pen:handleBuy(1, entry.key, world.barn.id, nil)
    assertEquals(answer, A.BOUGHT)
    assertEquals(paid, entry.price + TCBreedersPen.DELIVERY_FEE * 2)
    assertEquals(world.money[1].amount, -paid)
end)

test("nothing's charged unless RL moved it", function()
    local world = setup()
    local entry = openPen(world)[1]
    world.moveRefusal = world.api.REASON.NOT_ENOUGH_SPACE
    assertEquals(world.pen:handleBuy(1, entry.key, world.trailer.id, nil), A.NO_ROOM)
    world.moveRefusal = world.api.REASON.FAILED
    assertEquals(world.pen:handleBuy(1, entry.key, world.trailer.id, nil), A.FAILED)
    world.moveRefusal = nil
    world.balance = entry.price - 1
    assertEquals(world.pen:handleBuy(1, entry.key, world.trailer.id, nil), A.CANT_AFFORD)
    world.balance = 100000
    world.noPermission = true
    assertEquals(world.pen:handleBuy(1, entry.key, world.trailer.id, nil), A.NO_PERMISSION)
    world.noPermission = false
    assertEquals(#world.money, 0)
    assertEquals(#world.moves, 0)
end)

test("refused: closed, a place not the farm's or not at the show, and one that's fallen sick", function()
    local world = setup()
    local entry = openPen(world)[1]
    world.open = false
    assertEquals(world.pen:handleBuy(1, entry.key, world.trailer.id, nil), A.CLOSED, "the stands are shut")
    world.open = true
    local away = addPlace(world, "trailer", 1, 5000, 5000)
    assertEquals(world.pen:handleBuy(1, entry.key, away.id, nil), A.NO_ROOM, "a trailer left at home")
    local others = addPlace(world, "trailer", 2, world.trailer.rootNode.x, world.trailer.rootNode.z)
    assertEquals(world.pen:handleBuy(1, entry.key, others.id, nil), A.NO_ROOM, "another farm's trailer")
    world.trailer.freeSlots = 0
    assertEquals(world.pen:handleBuy(1, entry.key, world.trailer.id, nil), A.NO_ROOM, "a full trailer")
    world.trailer.freeSlots = 5
    entry.animal.diseased = true
    assertEquals(world.pen:handleBuy(1, entry.key, world.trailer.id, nil), A.SICK)
    assertEquals(world.pen:handleBuy(1, "COW DE 1 999", world.trailer.id, nil), A.SOLD, "never there")
    assertEquals(#world.money, 0)
end)

-- Closing ----------------------------------------------------------------------------------------------------

test("a farm made on the spare id closes the pen at once; another id doesn't", function()
    local world = setup()
    openPen(world)
    local subscription = world.subscriptions[1]
    assertEquals(subscription.messageType, MessageType.FARM_CREATED)
    local trailers = { world.pen.trailerIds[1], world.pen.trailerIds[2] }
    subscription.callback(subscription.target, 3)
    assertTrue(world.pen:isOut(), "farm 3's nothing to do with it")
    subscription.callback(subscription.target, 8)
    assertTrue(not world.pen:isOut())
    assertEquals(world.pen.farmId, 0)
    assertEquals(world.deleted[1], trailers[1])
    assertEquals(world.deleted[2], trailers[2])
end)

test("at the show's end, or called off, the trailers and anything unsold go", function()
    local world = setup()
    openPen(world)
    world.competitions.breedersPen.onFinished(world.event)
    assertEquals(#world.deleted, TCBreedersPen.TYPES)
    assertTrue(not world.pen:isOut())
    openPen(world)
    world.competitions.breedersPen.onCancelled(world.event)
    assertTrue(not world.pen:isOut())
end)

-- Sync, save, people and vehicles ---------------------------------------------------------------------------

test("the pen goes to every machine, and into the save, kept only while its show's on and its farm id spare", function()
    local world = setup()
    openPen(world)
    local pen = world.pen
    local stream = world:newStream()
    TheContractorBreedersPen.writeState(stream, pen)
    local client = TheContractorBreedersPen.new()
    client:applyState(TheContractorBreedersPen.readState(stream))
    assertEquals(client.showId, pen.showId)
    assertEquals(client.farmId, 8)
    assertEquals(client.breederId, pen.breederId)
    assertEquals(#client.trailerIds, #pen.trailerIds)
    assertEquals(client.trailerIds[1], pen.trailerIds[1])

    local xml = {}
    pen:saveToXmlFile(xml)
    local loaded = TheContractorBreedersPen.new()
    loaded.engine = pen.engine
    loaded:loadFromXMLFile(xml)
    loaded:resolveSavedVehicles()
    assertEquals(loaded.farmId, 8)
    assertEquals(#loaded.trailerIds, #pen.trailerIds, "the same trailers, with the same animals in them")
    assertEquals(loaded.trailerIds[1], pen.trailerIds[1])

    world.existingFarms[8] = true
    local taken = TheContractorBreedersPen.new()
    taken.engine = pen.engine
    taken:loadFromXMLFile(xml)
    local deleted = #world.deleted
    taken:resolveSavedVehicles()
    assertEquals(#taken.trailerIds, 0, "farm 8's somebody's now")
    assertEquals(#world.deleted, deleted + #pen.trailerIds)

    world.existingFarms[8] = nil
    g_currentMission.environment.currentMonotonicDay = SHOW_DAY + 1
    local late = TheContractorBreedersPen.new()
    late.engine = pen.engine
    late:loadFromXMLFile(xml)
    late:resolveSavedVehicles()
    assertEquals(#late.trailerIds, 0, "the show's day's past")
end)

test("a retired breeder's successor takes the stand, and a replaced trailer keeps its place", function()
    local world = setup()
    openPen(world)
    local pen = world.pen
    local breederId = pen.breederId
    assertEquals(world.competitions.breedersPen.replacePerson(99, 100), 0)
    assertEquals(world.competitions.breedersPen.replacePerson(breederId, 100), 1)
    assertEquals(pen.breederId, 100)
    local oldId = pen.trailerIds[1]
    pen:remapVehicle(oldId, 777)
    assertEquals(pen.trailerIds[1], 777)
    assertTrue(not pen:isTrailer(world.trailer))
end)
