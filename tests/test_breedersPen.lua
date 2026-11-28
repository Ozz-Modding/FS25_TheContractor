-- 173, 188: the show's breeders. The rules (the spare farm id, the price,
-- the trailer model, the breeders' plan: their types, stock, pens and
-- entries), RL's API found or not, the breeders planned for the room the
-- showground has, set out with their trailers behind their pens and
-- stocked through the API, buying (all or nothing: nothing charged unless
-- RL moved it; an entered animal held till its class is over), a farm
-- created on the spare id, and the breeders' sync, save and load.
--
-- The real show scene, classes, show animals, RL wrapper and breeders;
-- RL's API, the show, its site, stands and livestock, the farmers and the
-- world's vehicles faked.

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

-- A showground of 164's (halfU, halfV), its entrance at the +u end, as
-- its plan and as the scene laid out on it (with the breeders' pens).
local function makeShowground(world, halfU, halfV)
    local rect = { cx = 100, cz = 50, angle = 0, halfU = halfU, halfV = halfV }
    local entrance = { x = rect.cx + rect.halfU + 10, z = rect.cz }
    world.plan = { showRect = rect, entrance = entrance }
    world.scene = TCAuctionLayout.getScene(TCAuctionLayout.layOutOpenRect(rect, entrance), entrance, 99)
    world.scene.dressing = "show"
    world.scene.pens = 0
end

local function setup(halfU, halfV)
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
    world:load("src/util/TCShowPens.lua")
    world:load("src/util/TCShowRing.lua")
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

    -- 164's showground: 160 x 100 m, room for every breeder.
    makeShowground(world, halfU or 80, halfV or 50)
    world.open = true
    world.event = { id = 3, day = SHOW_DAY, hostFarmerId = HOST_ID }
    world.competitions = {}
    tc.Show = {
        getEvent = function() return world.event end,
        registerCompetition = function(_, key, def) world.competitions[key] = def end,
    }
    tc.ShowSite = { site = { plan = world.plan } }
    tc.ShowStands = {
        getScene = function() return world.scene end,
        isOpen = function() return world.open end,
    }
    -- The livestock: which animals are held for their classes.
    world.held = {}
    world.away = 0
    tc.ShowLivestock = {
        getHeldUntil = function(_, breeder, animal) return world.held[breeder .. ":" .. animal] end,
        getBreederEntryClass = function() return nil end,
        onBreedersAway = function() world.away = world.away + 1 end,
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
            if world.noModels or (world.noModelFor ~= nil and world.noModelFor[typeName]) then
                return nil, 0
            end
            return { xmlFilename = typeName .. ".xml" }, world.trailerSlots or 5
        end,
        spawnTrailer = function(spawner, index, spot, generation)
            local trailer = world:addVehicle({ name = "breeder trailer", farmId = spawner.farmId })
            trailer.uniqueId = "breeder" .. nextUnique
            nextUnique = nextUnique + 1
            function trailer:getUniqueId() return self.uniqueId end
            trailer.spot = spot
            table.insert(world.spawned, { trailer = trailer, index = index })
            if world.deferSpawns then
                table.insert(world.pendingSpawns, { trailer = trailer, index = index, generation = generation })
            else
                spawner:onTrailerSpawned(trailer, index, generation)
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

-- The breeders planned (as entries close) and laid out on the scene, as the
-- show's set-out does.
local function plan(world)
    world.pen:plan(world.event, 0)
    world.scene.breeders = world.competitions.breedersPen.getBreeders(world.event)
    return world.pen.breeders
end

local function setOut(world)
    plan(world)
    world.competitions.breedersPen.onSetOut(world.event)
    world.pen:setPresent(true)
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

test("188: the breeders' plan: the types by their weights, never chickens, a pen and stock each, their animals in their classes' prime, some of each class entered", function()
    setup()
    local classes = TCShowClasses.listClasses(g_currentMission.animalSystem)
    local farmers = { { id = 8 }, { id = 9 }, { id = 10 }, { id = 11 }, { id = 12 } }
    local first = function(a, b)
        if b ~= nil then
            return a
        end
        return 1
    end
    local breeders = TCBreedersPen.planBreeders(classes, farmers, 6, first)
    assertEquals(#breeders, 5, "as many as there are farmers to come")
    local types = {}
    for i, breeder in ipairs(breeders) do
        assertTrue(breeder.typeName ~= "CHICKEN")
        types[i] = breeder.typeName
        local stock = TCBreedersPen.getStock(breeder.typeName)
        assertEquals(breeder.pen.length, stock.length)
        assertEquals(breeder.pen.depth, stock.depth)
        assertTrue(#breeder.animals >= stock.min and #breeder.animals <= stock.max)
        local entered = {}
        for _, id in ipairs(breeder.entries) do
            entered[id] = true
        end
        local classesEntered, classesHeld = {}, {}
        for id, animal in ipairs(breeder.animals) do
            assertEquals(animal.id, id)
            local class = TCShowClasses.getClass(g_currentMission.animalSystem, animal.classKey)
            assertEquals(class.subTypeName, animal.subTypeName)
            assertEquals(class.typeName, breeder.typeName, "of the breeder's own type")
            assertEquals(animal.age, class.band.primeFrom, "in its band's prime")
            classesHeld[animal.classKey] = true
            if entered[id] then
                classesEntered[animal.classKey] = (classesEntered[animal.classKey] or 0) + 1
            end
        end
        for classKey in pairs(classesHeld) do
            local count = classesEntered[classKey] or 0
            assertTrue(count >= TCBreedersPen.ENTRIES_PER_CLASS[1] and count <= TCBreedersPen.ENTRIES_PER_CLASS[2],
                "some of each class it has stock for entered")
        end
    end
    -- Five breeders: one full round of draws, each type its weight's times.
    local counts = {}
    for _, typeName in ipairs(types) do
        counts[typeName] = (counts[typeName] or 0) + 1
    end
    assertEquals(counts.COW, TCBreedersPen.TYPE_WEIGHTS.COW)
    assertEquals(counts.SHEEP, TCBreedersPen.TYPE_WEIGHTS.SHEEP)
    -- Breeders of a type share its breeds, so they compete.
    local firstOf = {}
    for _, breeder in ipairs(breeders) do
        local key = breeder.animals[1].classKey
        firstOf[breeder.typeName] = firstOf[breeder.typeName] or key
        assertEquals(TCShowClasses.getClass(g_currentMission.animalSystem, key).subTypeName,
            TCShowClasses.getClass(g_currentMission.animalSystem, firstOf[breeder.typeName]).subTypeName)
    end
    -- Not every sheep entered: some for sale all day.
    for _, breeder in ipairs(breeders) do
        if breeder.typeName == "SHEEP" then
            assertTrue(#breeder.entries < #breeder.animals)
        end
    end

    -- An excluded breed (water buffalo) is never brought: a type with only
    -- that breed has no breeder.
    local buffalo = {}
    for _, class in ipairs(classes) do
        if class.typeName == "COW" then
            local copy = {}
            for k, v in pairs(class) do
                copy[k] = v
            end
            copy.subTypeName = "COW_WATERBUFFALO"
            table.insert(buffalo, copy)
        elseif class.typeName == "SHEEP" then
            table.insert(buffalo, class)
        end
    end
    for _, breeder in ipairs(TCBreedersPen.planBreeders(buffalo, farmers, 6, first)) do
        assertEquals(breeder.typeName, "SHEEP")
    end

    -- A trailer takes fewer: that many come. A type with no trailer
    -- (capacity 0) doesn't come at all.
    local capped = TCBreedersPen.planBreeders(classes, farmers, 6, first, function(typeName)
        return typeName == "SHEEP" and 0 or 2
    end)
    for _, breeder in ipairs(capped) do
        assertEquals(breeder.typeName, "COW")
        assertEquals(#breeder.animals, 2)
    end
    assertEquals(#TCBreedersPen.planBreeders(classes, {}, 6, first), 0, "no farmers, no breeders")
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
    -- 188: what the judge reads of one, from its description.
    local read = TCRealisticLivestock.readDescribed(api.describeAnimal({ subType = "COW_HOLSTEIN", age = 14,
        number = 3 }))
    assertEquals(read.subTypeName, "COW_HOLSTEIN")
    assertEquals(read.age, 14)
    assertEquals(read.health, 98)
    assertEquals(read.animal.weight, 500)
    assertEquals(read.animal.genetics.quality, 1.4)
    assertEquals(read.animal.key, "COW DE 214598 3")
end)

-- Planning ------------------------------------------------------------------------------------------------

test("188: planned once for the show, never the host, as many as the showground has room for", function()
    local world = setup()
    RealisticLivestockAPI = nil
    local breeders = plan(world)
    assertEquals(#breeders, 5, "room for all")
    for _, breeder in ipairs(breeders) do
        assertTrue(breeder.farmerId ~= HOST_ID)
        assertTrue(not breeder.hasTrailer, "without RL nothing comes in a trailer")
    end
    assertEquals(world.pen.farmId, 0)
    assertTrue(world.pen:isOut())
    assertTrue(world.pen:isBreeder(breeders[1].farmerId))
    assertTrue(not world.pen:isBreeder(HOST_ID))
    assertTrue(world.events[#world.events].pen == world.pen, "sent to every machine")
    local again = world.pen:plan(world.event, 0)
    assertEquals(again, breeders, "planned once")
    local pens = TCShowScene.getBreederPens(world.scene)
    assertEquals(#pens, #breeders)
    for _, pen in ipairs(pens) do
        assertTrue(pen.placed)
        assertEquals(pen.trailer, nil, "no trailer to park")
    end

    -- A small showground (120 x 60 m) has room for none; a longer one
    -- (130 m) for some, past the trailer lines.
    local small = setup(60, 30)
    RealisticLivestockAPI = nil
    assertEquals(#plan(small), 0)
    local longer = setup(65, 30)
    RealisticLivestockAPI = nil
    local some = #plan(longer)
    assertTrue(some > 0 and some < 5, "some")
    assertEquals(TCShowScene.countBreederPens(longer.scene), some)
end)

-- Setting out ----------------------------------------------------------------------------------------------

test("set out with RL: each breeder's trailer behind their pen on the spare farm id, stocked as planned with premium animals", function()
    local world = setup()
    installAPI(world)
    setOut(world)
    local pen = world.pen
    assertEquals(pen.farmId, 8)
    assertEquals(pen.showId, world.event.id)
    assertTrue(pen:isOut() and pen:isOpen() and pen:hasSales())
    local pens = TCShowScene.getBreederPens(world.scene)
    assertEquals(#world.spawned, #pen.breeders, "a trailer a breeder")
    for _, spawn in ipairs(world.spawned) do
        assertEquals(spawn.trailer:getOwnerFarmId(), 8, "the spare farm id's")
        local spot = pens[spawn.index].trailer
        assertNear(spawn.trailer.spot.x, spot.x, 0.001, "behind its breeder's pen")
        assertNear(spawn.trailer.spot.z, spot.z, 0.001)
    end
    for _, add in ipairs(world.adds) do
        assertEquals(add.farmId, 8, "stocked as the spare farm id")
    end
    local made = 0
    for _, breeder in ipairs(pen.breeders) do
        assertEquals(#breeder.trailerIds, 1)
        for _, animal in ipairs(breeder.animals) do
            made = made + 1
            assertTrue(animal.key ~= nil, "its RL key")
            assertTrue(not animal.missing)
        end
    end
    assertEquals(#world.created, made, "one made an animal")
    for i, animal in ipairs(world.created) do
        assertEquals(animal.quality, TCBreedersPen.QUALITY, "premium only")
        assertTrue(animal.age ~= nil)
    end
    -- What RL made is what was planned.
    local first = pen.breeders[1].animals[1]
    assertEquals(world.created[1].subType, first.subTypeName)
    assertEquals(world.created[1].age, first.age)
    assertEquals(#pen:getCatalogue(), made)
    assertEquals(#pen:getCatalogue(false, 2), #pen.breeders[2].animals, "one breeder's")

    -- Set out again (the console's show day): what's out stays.
    world.competitions.breedersPen.onSetOut(world.event)
    assertEquals(#world.spawned, #pen.breeders)
end)

test("a sick animal's drawn again, a farm on 8 puts them on 7; with no spare id or no RL they come with nothing to sell", function()
    local world = setup()
    installAPI(world)
    world.sickQueue = { true, true }
    world.existingFarms[8] = true
    setOut(world)
    assertEquals(world.pen.farmId, 7)
    for _, entry in ipairs(world.pen:getCatalogue(true)) do
        assertTrue(not entry.info.diseased, "no sick one put out")
    end
    local made = 0
    for _, breeder in ipairs(world.pen.breeders) do
        made = made + #breeder.animals
    end
    assertEquals(#world.created, made + 2, "two drawn again")

    local full = setup()
    installAPI(full)
    for id = 1, 8 do
        full.existingFarms[id] = true
    end
    setOut(full)
    assertEquals(#full.spawned, 0, "no spare id, no trailers")
    assertTrue(full.pen:isOut(), "the breeders still come")
    assertTrue(not full.pen:hasSales())

    local plain = setup()
    RealisticLivestockAPI = nil
    setOut(plain)
    assertEquals(#plain.spawned, 0)
    assertTrue(plain.pen:isOpen() and not plain.pen:hasSales())
end)

test("188: a breeder the real showground has no room for stays away, and the livestock's told", function()
    local world = setup()
    RealisticLivestockAPI = nil
    plan(world)
    local count = #world.pen.breeders
    -- The scene laid out smaller than planned.
    makeShowground(world, 65, 30)
    world.scene.breeders = world.competitions.breedersPen.getBreeders(world.event)
    world.competitions.breedersPen.onSetOut(world.event)
    local away = 0
    for _, breeder in ipairs(world.pen.breeders) do
        if breeder.absent then
            away = away + 1
        end
    end
    assertTrue(away > 0 and away < count)
    assertEquals(#world.pen:getBreeders(), count - away)
    assertEquals(world.away, 1)
end)

test("a trailer that loads after the show's cleared is taken away", function()
    local world = setup()
    installAPI(world)
    world.deferSpawns = true
    setOut(world)
    world.competitions.breedersPen.onFinished(world.event)
    local pending = world.pendingSpawns[1]
    world.pen:onTrailerSpawned(pending.trailer, pending.index, pending.generation)
    assertEquals(#world.pen:getTrailerIds(), 0)
    assertEquals(world.deleted[#world.deleted], pending.trailer.id)
end)

-- Buying -----------------------------------------------------------------------------------------------------

local function openPens(world)
    installAPI(world)
    setOut(world)
    local pen = TCShowScene.getBreederPens(world.scene)[1]
    world.trailer = addPlace(world, "trailer", 1, pen.x + 5, pen.z)
    world.barn = addPlace(world, "husbandry", 1, 0, 0)
    return world.pen:getCatalogue(false, 1)
end

test("bought into a trailer at the show: RL moves it, then the farm's charged the price, once, and it's gone from the pen", function()
    local world = setup()
    local catalogue = openPens(world)
    local entry = catalogue[1]
    assertEquals(entry.breeder, 1)
    assertTrue(entry.record ~= nil, "our record of it")
    local targets = world.pen:getTargets(1, entry.subTypeIndex, 1)
    assertEquals(#targets, 2, "the trailer by the pen and the barn")
    assertEquals(targets[1].object, world.trailer)
    assertEquals(targets[1].fee, 0, "free into a trailer")
    assertEquals(targets[2].fee, TCBreedersPen.DELIVERY_FEE, "the barn's delivered")

    local version = world.pen.version
    local answer, paid = world.pen:handleBuy(1, entry.key, world.trailer.id, nil)
    assertEquals(answer, A.BOUGHT)
    assertEquals(paid, entry.price)
    assertEquals(#world.moves, 1)
    assertEquals(world.moves[1].target, world.trailer)
    assertEquals(world.moves[1].farmId, 1)
    assertEquals(#world.money, 1)
    assertEquals(world.money[1].amount, -entry.price)
    assertEquals(world.money[1].moneyType, MoneyType.TC_BREEDER_STOCK)
    assertEquals(#world.pen:getCatalogue(false, 1), #catalogue - 1, "gone from the breeder")
    assertTrue(entry.record.sold, "and from their pen")
    assertTrue(world.pen.version > version)

    local again = world.pen:handleBuy(2, entry.key, world.trailer.id, nil)
    assertEquals(again, A.SOLD, "a second buyer finds it gone")
    assertEquals(#world.money, 1, "and pays nothing")
end)

test("188: an entered animal isn't sold till its class is over", function()
    local world = setup()
    local entry = openPens(world)[1]
    world.held["1:" .. entry.record.id] = 11 * 60
    assertEquals(world.pen:handleBuy(1, entry.key, world.trailer.id, nil), A.ENTERED)
    assertEquals(#world.moves, 0)
    assertEquals(#world.money, 0)
    world.held["1:" .. entry.record.id] = nil
    assertEquals(world.pen:handleBuy(1, entry.key, world.trailer.id, nil), A.BOUGHT, "after its class")
end)

test("delivered to a barn costs the fee on top, scaled as any fixed cost", function()
    local world = setup()
    local entry = openPens(world)[2]
    world.costScale = 2
    local answer, paid = world.pen:handleBuy(1, entry.key, world.barn.id, nil)
    assertEquals(answer, A.BOUGHT)
    assertEquals(paid, entry.price + TCBreedersPen.DELIVERY_FEE * 2)
    assertEquals(world.money[1].amount, -paid)
end)

test("nothing's charged unless RL moved it", function()
    local world = setup()
    local entry = openPens(world)[1]
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
    assertTrue(not entry.record.sold)
end)

test("refused: closed, a place not the farm's or not at the show, and one that's fallen sick", function()
    local world = setup()
    local entry = openPens(world)[1]
    world.open = false
    assertEquals(world.pen:handleBuy(1, entry.key, world.trailer.id, nil), A.CLOSED, "the stands are shut")
    world.open = true
    world.pen:setPresent(false)
    assertEquals(world.pen:handleBuy(1, entry.key, world.trailer.id, nil), A.CLOSED, "the gates are shut")
    world.pen:setPresent(true)
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

test("a farm made on the spare id has the trailers taken away at once (the breeders stay, nothing to sell); another id doesn't", function()
    local world = setup()
    openPens(world)
    local subscription = world.subscriptions[1]
    assertEquals(subscription.messageType, MessageType.FARM_CREATED)
    local trailers = world.pen:getTrailerIds()
    subscription.callback(subscription.target, 3)
    assertTrue(world.pen:hasSales(), "farm 3's nothing to do with it")
    subscription.callback(subscription.target, 8)
    assertTrue(not world.pen:hasSales())
    assertEquals(world.pen.farmId, 0)
    assertEquals(#world.deleted, #trailers)
    assertEquals(world.deleted[1], trailers[1])
    assertTrue(world.pen:isOut(), "the breeders are still there")
    assertTrue(world.pen.breeders[1].animals[1].missing, "their RL stock gone with the trailers")
end)

test("at the show's end, or called off, the trailers and anything unsold go, and the breeders", function()
    local world = setup()
    openPens(world)
    local trailers = #world.pen:getTrailerIds()
    world.competitions.breedersPen.onFinished(world.event)
    assertEquals(#world.deleted, trailers)
    assertTrue(not world.pen:isOut())
    assertEquals(#world.pen.breeders, 0)
    openPens(world)
    world.competitions.breedersPen.onCancelled(world.event)
    assertTrue(not world.pen:isOut())
    -- A new show's announced: the last one's gone.
    plan(world)
    world.competitions.breedersPen.onAnnounced({ id = 4 })
    assertEquals(#world.pen.breeders, 0)
    assertEquals(world.pen.showId, 4)
end)

-- Sync, save, people and vehicles ---------------------------------------------------------------------------

test("the breeders go to every machine, and into the save, their trailers kept only while the show's on and the farm id spare", function()
    local world = setup()
    openPens(world)
    local pen = world.pen
    pen.breeders[2].animals[1].sold = true
    local stream = world:newStream()
    TheContractorBreedersPen.writeState(stream, pen)
    local client = TheContractorBreedersPen.new()
    client:applyState(TheContractorBreedersPen.readState(stream))
    assertEquals(client.showId, pen.showId)
    assertEquals(client.farmId, 8)
    assertTrue(client.present)
    assertEquals(#client.breeders, #pen.breeders)
    for i, breeder in ipairs(pen.breeders) do
        local copy = client.breeders[i]
        assertEquals(copy.farmerId, breeder.farmerId)
        assertEquals(copy.typeName, breeder.typeName)
        assertEquals(copy.pen.length, breeder.pen.length)
        assertTrue(copy.hasTrailer)
        assertEquals(copy.trailerIds[1], breeder.trailerIds[1])
        assertEquals(#copy.animals, #breeder.animals)
        for j, animal in ipairs(breeder.animals) do
            for _, field in ipairs({ "id", "classKey", "subTypeName", "age", "variation", "key" }) do
                assertEquals(copy.animals[j][field], animal[field], field)
            end
        end
    end
    assertTrue(client.breeders[2].animals[1].sold)
    assertEquals(client.breeders[1].entries, nil, "the plan's entries are the livestock's to send")

    local xml = {}
    pen:saveToXmlFile(xml)
    local loaded = TheContractorBreedersPen.new()
    loaded.engine = pen.engine
    loaded:loadFromXMLFile(xml)
    loaded:resolveSavedVehicles()
    assertEquals(loaded.farmId, 8)
    assertEquals(#loaded.breeders, #pen.breeders)
    assertEquals(#loaded:getTrailerIds(), #pen:getTrailerIds(), "the same trailers, with the same animals in them")
    assertEquals(loaded.breeders[1].trailerIds[1], pen.breeders[1].trailerIds[1])
    assertEquals(loaded.breeders[1].animals[1].key, pen.breeders[1].animals[1].key)
    assertTrue(loaded.breeders[2].animals[1].sold)
    assertEquals(loaded.breeders[1].model.xmlFilename, pen.breeders[1].model.xmlFilename)

    world.existingFarms[8] = true
    local taken = TheContractorBreedersPen.new()
    taken.engine = pen.engine
    taken:loadFromXMLFile(xml)
    local deleted = #world.deleted
    taken:resolveSavedVehicles()
    assertEquals(#taken:getTrailerIds(), 0, "farm 8's somebody's now")
    assertEquals(#world.deleted, deleted + #pen:getTrailerIds())
    assertEquals(#taken.breeders, #pen.breeders, "the breeders stay")

    world.existingFarms[8] = nil
    g_currentMission.environment.currentMonotonicDay = SHOW_DAY + 1
    local late = TheContractorBreedersPen.new()
    late.engine = pen.engine
    late:loadFromXMLFile(xml)
    late:resolveSavedVehicles()
    assertEquals(#late:getTrailerIds(), 0, "the show's day's past")
    assertEquals(#late.breeders, 0)
end)

test("trailers the save lost track of go: 173's under the pen, and any stray on the spare id", function()
    local world = setup()
    openPens(world)
    local pen = world.pen
    VehiclePropertyState = { OWNED = 1, MISSION = 4 }
    for _, trailerId in ipairs(pen:getTrailerIds()) do
        NetworkUtil.getObject(trailerId).propertyState = VehiclePropertyState.MISSION
    end
    -- 173's save: one trailer under the pen itself.
    local old = world:addVehicle({ name = "old breeder trailer", farmId = 8 })
    old.uniqueId = "old173"
    function old:getUniqueId() return self.uniqueId end
    -- One nothing saved, on the spare id; a player's own, and a lent one
    -- of a real farm's, stay.
    local stray = world:addVehicle({ name = "stray", farmId = 7 })
    local mine = world:addVehicle({ name = "mine", farmId = 1 })
    local lent = world:addVehicle({ name = "lent", farmId = 1 })
    for _, vehicle in ipairs({ old, stray, mine, lent }) do
        vehicle.spec_livestockTrailer = {}
        vehicle.propertyState = VehiclePropertyState.MISSION
    end
    mine.propertyState = VehiclePropertyState.OWNED
    local xml = {}
    pen:saveToXmlFile(xml)
    xml[TheContractor.SaveKey .. "." .. TheContractorBreedersPen.SAVE_KEY .. ".trailer(0)#uniqueId"] = "old173"
    local loaded = TheContractorBreedersPen.new()
    loaded.engine = pen.engine
    loaded:loadFromXMLFile(xml)
    local deleted = #world.deleted
    loaded:resolveSavedVehicles()
    local gone = {}
    for k = deleted + 1, #world.deleted do
        gone[world.deleted[k]] = true
    end
    assertTrue(gone[NetworkUtil.getObjectId(old)], "173's")
    assertTrue(gone[NetworkUtil.getObjectId(stray)], "the stray")
    assertTrue(not gone[NetworkUtil.getObjectId(mine)] and not gone[NetworkUtil.getObjectId(lent)])
    assertEquals(#loaded:getTrailerIds(), #pen:getTrailerIds(), "the breeders' own stay")
    for _, trailerId in ipairs(pen:getTrailerIds()) do
        assertTrue(not gone[trailerId])
    end
    VehiclePropertyState = nil
end)

test("a retired breeder's successor brings their stock, and a replaced trailer keeps its place", function()
    local world = setup()
    openPens(world)
    local pen = world.pen
    local breederId = pen.breeders[1].farmerId
    assertEquals(world.competitions.breedersPen.replacePerson(99, 100), 0)
    assertEquals(world.competitions.breedersPen.replacePerson(breederId, 100), 1)
    assertEquals(pen.breeders[1].farmerId, 100)
    local oldId = pen.breeders[1].trailerIds[1]
    pen:remapVehicle(oldId, 777)
    assertEquals(pen.breeders[1].trailerIds[1], 777)
    assertTrue(not pen:isTrailer(world.trailer))
end)
