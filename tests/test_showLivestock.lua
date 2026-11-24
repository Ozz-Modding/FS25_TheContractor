-- 167: the show's livestock classes. Class assignment (TCShowClasses),
-- scoring with and without RealisticLivestock and Best Kept Herd
-- (TCShowJudging), entering and its limits, farmers' entries, judging from
-- the trailers in the lines (no-shows, a sick animal, two farms in one
-- class), and the placings through the real Show (prizes, reputation, the
-- host's opinion, rosette notices, supreme champions), the sync, the save,
-- a deleted farm and a retired farmer.
--
-- The real Show, EventDay, PublicEvents, Inbox, calendar, show scene and
-- trailer reading; 164's and 135's sites, the signs, the crowd, the farmers,
-- the company and the rewards are faked, as tests/test_show.lua has them.
-- Husbandries and trailers follow vanilla's PlaceableHusbandry* and
-- LivestockTrailer (getClusters); an RL animal is RL's Animal, as
-- tests/test_showAnimals.lua has it.

local RL = "FS25_RealisticLivestockRM"
local SHOW_FIELD = 5
local HOST_ID = 7
local SHOW_DAY = 51
local CLOSE_DAY = 48

-- The map's animals: cattle (Holstein cows and bulls, Angus cows), sheep,
-- horses and chickens.
local SUBTYPES = {
    { name = "COW_HOLSTEIN", type = 1, title = "Holstein" },
    { name = "BULL_HOLSTEIN", type = 1, title = "Holstein bull" },
    { name = "COW_ANGUS", type = 1, title = "Angus" },
    { name = "SHEEP_LANDRACE", type = 2, title = "Landrace" },
    { name = "HORSE_GRAY", type = 3, title = "Grey", reproductionMinAgeMonth = 30 },
    { name = "CHICKEN", type = 4, title = "Hen" },
}
local SUB = {}
for i, def in ipairs(SUBTYPES) do
    SUB[def.name] = i
end

local function installAnimalSystem(world)
    local types = {
        { name = "COW", typeIndex = 1, groupTitle = "Cattle", subTypes = {} },
        { name = "SHEEP", typeIndex = 2, groupTitle = "Sheep", subTypes = {} },
        { name = "HORSE", typeIndex = 3, groupTitle = "Horses", subTypes = {} },
        { name = "CHICKEN", typeIndex = 4, groupTitle = "Chickens", subTypes = {} },
    }
    local subTypes, byName = {}, {}
    for i, def in ipairs(SUBTYPES) do
        local subType = { name = def.name, subTypeIndex = i, typeIndex = def.type,
            fillTypeIndex = world:addFillType(def.name, def.title),
            reproductionMinAgeMonth = def.reproductionMinAgeMonth }
        subTypes[i] = subType
        byName[def.name] = subType
        table.insert(types[def.type].subTypes, i)
    end
    g_currentMission.animalSystem = {
        getSubTypeByIndex = function(_, index) return subTypes[index] end,
        getSubTypeByName = function(_, name) return byName[name] end,
        getTypeByIndex = function(_, index) return types[index] end,
        getTypeByName = function(_, name)
            for _, animalType in ipairs(types) do
                if animalType.name == name then
                    return animalType
                end
            end
            return nil
        end,
        getTypes = function() return types end,
    }
end

local function setup(withRL)
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    MessageType = { DAY_CHANGED = 1, HOUR_CHANGED = 2, FARMLAND_OWNER_CHANGED = 3 }
    g_messageCenter = { subscribe = function() end, unsubscribeAll = function() end }
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    TCMessagePostedEvent = { new = function(message) return { posted = message } end }
    TCMessageRemovedEvent = { new = function(id) return { removed = id } end }
    TheContractorStaff = { scalePay = function(pay) return pay end }
    TheContractorJob = { STATE = { OFFERED = 1, NEGOTIATING = 2 } }
    TheContractorJobGeneration = { JOB_TYPES = {} }
    world.rlEnv = withRL and { Animal = { getHasAnyDisease = function(self) return self.sick == true end } } or nil
    TheContractorDrivers = { getModEnv = function(modName) return modName == RL and world.rlEnv or nil end }

    world:load("src/util/TCCalendar.lua")
    world:load("src/business/Inbox.lua")
    world:load("src/util/TCAuctionAttendance.lua")
    world:load("src/util/TCADSUsedLots.lua")
    world:load("src/util/TCLotInspections.lua")
    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/util/TCAuctionScene.lua")
    world:load("src/util/TCShowSite.lua")
    world:load("src/util/TCShowScene.lua")
    world:load("src/util/TCRealisticLivestock.lua")
    world:load("src/util/TCShowAnimals.lua")
    world:load("src/util/TCShowClasses.lua")
    world:load("src/util/TCShowJudging.lua")
    world:load("src/business/PublicEvents.lua")
    world:load("src/business/EventDay.lua")
    world:load("src/business/Show.lua")
    world:load("src/business/ShowLivestock.lua")
    world:load("src/events/TCShowEvent.lua")
    world:load("src/events/TCShowEntryEvent.lua")
    world:load("src/events/TCShowLivestockEvent.lua")
    TCRealisticLivestock.reset()
    TCRealisticLivestock.detect()
    installAnimalSystem(world)

    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end
    g_currentMission.environment = {
        currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 10,
        plannedDaysPerPeriod = 10, currentMonotonicDay = 1, currentHour = 0,
        daylight = { latitude = 55 },
    }
    world.fields = {}
    g_fieldManager = { getFieldById = function(_, id) return world.fields[id] end }
    local field = { id = SHOW_FIELD, owner = 0 }
    function field:getId() return self.id end
    function field:getOwner() return self.owner end
    function field:getName() return tostring(self.id) end
    function field:getFarmland() return { getId = function() return field.id end } end
    function field:getIndicatorPosition() return 100, 200 end
    world.fields[SHOW_FIELD] = field

    local tc = g_currentMission.TheContractor
    tc.hasResolvedSavedVehicles = true
    world.people = {
        [7] = { id = 7, name = "Tom" }, [8] = { id = 8, name = "Ann" },
        [9] = { id = 9, name = "Bob" }, [10] = { id = 10, name = "Sue" },
    }
    tc.Farmers = {
        getHolder = function() return world.people[HOST_ID] end,
        getPerson = function(_, id) return world.people[id] end,
        getFarmers = function()
            local farmers = {}
            for _, id in ipairs({ 7, 8, 9, 10 }) do
                if world.people[id] ~= nil then
                    table.insert(farmers, world.people[id])
                end
            end
            return farmers
        end,
    }
    world.companies = { [1] = true, [2] = true }
    tc.Company = { hasCompany = function(_, farmId) return world.companies[farmId] == true end }
    tc.RandomEvents = { incidents = {}, getCompanyFarmIds = function() return { 1, 2 } end }
    tc.Inbox = TheContractorInbox.new()

    -- 164's site and 135's: the showground laid out as the real scene, so
    -- the trailer lines are where TCShowScene puts them.
    local rect = { cx = 100, cz = 50, angle = 0, halfU = 60, halfV = 30 }
    local entrance = { x = rect.cx + rect.halfU + 10, z = rect.cz }
    world.scene = TCAuctionLayout.getScene(TCAuctionLayout.layOutOpenRect(rect, entrance), entrance, 99)
    world.scene.dressing = "show"
    world.plan = { mode = "single", showFieldId = SHOW_FIELD, ploughFieldId = SHOW_FIELD, showRect = rect,
        ploughRect = rect, plots = {}, entrance = { x = entrance.x, z = entrance.z, distance = 10 } }
    tc.ShowSite = {
        site = nil,
        pickBest = function() return { plan = world.plan, problems = {} } end,
        planOn = function() return { plan = world.plan, problems = {} } end,
        setPlan = function(self, plan) self.site = { plan = plan, dressed = false } end,
        dress = function(self) self.site.dressed = true return "dressed" end,
        clear = function(self) self.site = nil return "cleared" end,
    }
    TheContractorAuctionSite = { PREFERRED_LOTS = 120, CLOSE_HOURS = { 17, 18 },
        getFieldRefusal = function() return nil end }
    tc.AuctionSite = {
        site = nil, fieldId = 0, walkways = {},
        getWalkways = function(self) return self.walkways end,
        getScene = function(self) return self.site ~= nil and world.scene or nil end,
        startOpen = function(self, fieldId) self.site = { fieldId = fieldId } self.fieldId = fieldId end,
        clear = function(self) self.site, self.fieldId = nil, 0 end,
    }
    tc.AuctionSigns = {
        month = 0, signs = {}, face = nil,
        place = function(self, month, face) self.month, self.signs, self.face = month, { {} }, face end,
        clear = function(self) self.month, self.signs, self.face = 0, {}, nil end,
        describe = function() return "" end,
    }
    TCAuctionCrowd = {
        DEFAULT_PEOPLE = 60, active = nil,
        getUnavailableReason = function() return "none in tests" end,
        getFieldPolygon = function() return {} end,
        getAuctionPeople = function(lotCount) return lotCount end,
        stop = function() end,
    }
    TheContractorFallenTree = { sampleRoads = function() return {} end }

    -- The rewards, as they're asked for.
    world.money, world.reputation, world.opinions, world.notices = {}, {}, {}, {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end
    tc.Settings = { scaleCost = function(_, amount) return amount * 2 end }
    TCEconomyScale = { scale = function(amount) return amount * 3 end }
    TheContractorGoodNews = { getReputationReward = function(farmId, jobs) return jobs * 10 end }
    tc.Reputation = { addReputation = function(_, farmId, delta)
        table.insert(world.reputation, { farmId = farmId, delta = delta })
    end }
    tc.Relationships = { adjust = function(_, farmId, customerId, delta, reason)
        table.insert(world.opinions, { farmId = farmId, customerId = customerId, delta = delta, reason = reason })
    end }
    tc.Notices = { publish = function(_, farmId, text) table.insert(world.notices, farmId) end }

    -- Husbandries and the trailers vanilla keeps.
    world.husbandries, world.trailers = {}, {}
    g_currentMission.husbandrySystem = {
        livestockTrailers = world.trailers,
        getPlaceablesByFarm = function(_, farmId)
            local list = {}
            for _, husbandry in ipairs(world.husbandries) do
                if husbandry:getOwnerFarmId() == farmId then
                    table.insert(list, husbandry)
                end
            end
            return list
        end,
    }
    g_currentMission.placeableSystem = { placeables = world.husbandries }

    tc.PublicEvents = TheContractorPublicEvents.new()
    tc.Show = TheContractorShow.new()
    tc.Show:register(tc.Inbox)
    tc.PublicEvents:registerKind(tc.Show)
    tc.ShowLivestock = TheContractorShowLivestock.new()
    tc.ShowLivestock:register(tc.Show)
    -- Every roll in the middle: no eye, no stockman, three farmers a class.
    tc.ShowLivestock.random = function() return 0.5 end
    world.tc = tc
    return world
end

-- Fakes ------------------------------------------------------------------------------------------

local function cluster(subTypeName, numAnimals, age, health)
    return { subTypeIndex = SUB[subTypeName], numAnimals = numAnimals, age = age, health = health, reproduction = 0 }
end

-- RL's Animal (see tests/test_showAnimals.lua).
local function rlAnimal(def)
    return {
        isIndividual = true, numAnimals = 1, subTypeIndex = SUB[def.subType or "COW_HOLSTEIN"],
        uniqueId = def.uniqueId, farmId = "482913", birthday = { country = 2 },
        name = def.name, gender = def.gender or "female", age = def.age or 20, health = def.health or 100,
        reproduction = 0, weight = def.weight or 400, targetWeight = def.targetWeight or 400,
        genetics = def.genetics or { quality = 1, health = 1, productivity = 1, metabolism = 1, fertility = 1 },
        isPregnant = def.isPregnant, isLactating = def.isLactating, isCastrated = def.isCastrated, sick = def.sick,
    }
end

local function rlKey(uniqueId)
    return "2 482913 " .. uniqueId
end

-- A husbandry as vanilla's: its clusters, productivity, food, straw, water
-- and manure. def: { farmId, name, clusters, productivity, food (0-1),
-- groups (stocked of 3), straw, manure, slurry }.
local function addHusbandry(world, def)
    local levels = { straw = def.straw or 1, manure = def.manure or 0, slurry = def.slurry or 0 }
    local husbandry = {
        farmId = def.farmId or 1, name = def.name or "Barn", clusters = def.clusters or {},
        productivity = def.productivity or 1,
        spec_husbandryAnimals = {},
        spec_husbandryFood = {},
        spec_husbandryStraw = { inputFillType = "straw", outputFillType = "manure" },
        spec_husbandryWater = { automaticWaterSupply = true },
        spec_husbandryLiquidManure = { fillType = "slurry" },
        uniqueId = "husbandry" .. (#world.husbandries + 1),
    }
    function husbandry:getClusters() return self.clusters end
    function husbandry:getOwnerFarmId() return self.farmId end
    function husbandry:getName() return self.name end
    function husbandry:getUniqueId() return self.uniqueId end
    function husbandry:getGlobalProductionFactor() return 1 end
    function husbandry:getProductionFactor() return self.productivity end
    function husbandry:getTotalFood() return (def.food or 1) * 1000 end
    function husbandry:getFoodCapacity() return 1000 end
    function husbandry:getFoodInfos()
        local infos = {}
        for i = 1, 3 do
            table.insert(infos, { value = i <= (def.groups or 3) and 100 or 0 })
        end
        return infos
    end
    function husbandry:getHusbandryFillLevel(fillType) return levels[fillType] * 100 end
    function husbandry:getHusbandryCapacity() return 100 end
    husbandry.levels = levels
    world:register(husbandry)
    table.insert(world.husbandries, husbandry)
    return husbandry
end

-- A bay's middle in world space (as tests/test_showAnimals.lua).
local function bayMiddle(scene, bay)
    local lines = TCShowScene.getAreas(scene).lines
    local d = (lines.dFrom + lines.dTo) * 0.5
    local v = lines.vFrom + (bay - 0.5) * lines.bayWidth
    local u = scene.nearEdge - scene.nearSign * d
    return scene.cx + u * math.cos(scene.angle) - v * math.sin(scene.angle),
        scene.cz + u * math.sin(scene.angle) + v * math.cos(scene.angle)
end

-- A livestock trailer: def { farmId, bay (nil: far away), speed }.
local function addTrailer(world, clusters, def)
    local x, z = 900, 900
    if def.bay ~= nil then
        x, z = bayMiddle(world.scene, def.bay)
    end
    local trailer = {
        spec_livestockTrailer = {},
        rootNode = { x = x, z = z },
        getClusters = function() return clusters end,
        getOwnerFarmId = function() return def.farmId or 1 end,
        getLastSpeed = function() return def.speed or 0 end,
        getAttacherVehicle = function() return nil end,
    }
    table.insert(world.trailers, trailer)
    return trailer
end

-- The calendar (year 1, ten days a month), as tests/test_show.lua.
local function setDay(day)
    local environment = g_currentMission.environment
    environment.currentMonotonicDay = day
    environment.currentHour = 0
    environment.currentPeriod = math.floor((day - 1) / 10) + 1
    environment.currentDayInPeriod = (day - 1) % 10 + 1
end

local function runToDay(world, day)
    while g_currentMission.environment.currentMonotonicDay < day do
        setDay(g_currentMission.environment.currentMonotonicDay + 1)
        world.tc.Show:onDayChanged()
    end
end

local function setHour(world, hour)
    g_currentMission.environment.currentHour = hour
    world.tc.Show:onHourChanged()
end

local function announce(world)
    getWorldTranslation = function(node) return node.x, 0, node.z end
    setDay(21)
    return world.tc.Show:announce(nil, SHOW_DAY, function() return 0 end)
end

local function enter(world, farmId, classKey, husbandry, animalKey)
    return world.tc.ShowLivestock:enter(farmId, classKey, husbandry.id, animalKey)
end

-- The placings given for a class (titleArg), in order.
local function placingsFor(world, classKey)
    local list = {}
    for _, placing in ipairs(world.tc.Show:getResults().placings) do
        if placing.titleArg == classKey then
            table.insert(list, placing)
        end
    end
    return list
end

-- Classes -------------------------------------------------------------------------------------------

test("classes: a subtype and its type's age band, nothing too young, castrated or a chicken", function()
    setup(false)
    local animalSystem = g_currentMission.animalSystem
    local function classOf(subType, age, animal)
        local class = TCShowClasses.getClassFor(animalSystem, { subTypeName = subType, age = age, animal = animal })
        return class ~= nil and class.key or nil
    end
    assertEquals(classOf("COW_HOLSTEIN", 20), "COW_HOLSTEIN:young")
    assertEquals(classOf("COW_HOLSTEIN", 30), "COW_HOLSTEIN:adult")
    assertEquals(classOf("BULL_HOLSTEIN", 20), "BULL_HOLSTEIN:young", "its own subtype")
    assertEquals(classOf("SHEEP_LANDRACE", 15), "SHEEP_LANDRACE:yearling")
    assertEquals(classOf("COW_HOLSTEIN", 4), nil, "too young to show")
    assertEquals(classOf("HORSE_GRAY", 20), "HORSE_GRAY:young", "its own breeding age")
    assertEquals(classOf("HORSE_GRAY", 30), "HORSE_GRAY:adult")
    assertEquals(classOf("CHICKEN", 12), nil, "no trailer takes them")
    assertEquals(classOf("BULL_HOLSTEIN", 20, { gender = "male", isCastrated = true }), nil)
    local class = TCShowClasses.getClass(animalSystem, "BULL_HOLSTEIN:adult")
    assertEquals(class.typeName, "COW")
    assertEquals(class.band.from, 24)
    assertEquals(TCShowClasses.getClass(animalSystem, "COW_HOLSTEIN:yearling"), nil, "not a cattle band")
    assertEquals(TCShowClasses.getClass(animalSystem, "COW_JERSEY:adult"), nil, "not on the map")
    assertEquals(TCShowClasses.getClass(animalSystem, TCShowClasses.HERD_KEY), nil)

    local keys = {}
    for _, listed in ipairs(TCShowClasses.listClasses(animalSystem)) do
        table.insert(keys, listed.key)
    end
    assertEquals(table.concat(keys, ","), "COW_HOLSTEIN:young,COW_HOLSTEIN:adult,BULL_HOLSTEIN:young,"
        .. "BULL_HOLSTEIN:adult,COW_ANGUS:young,COW_ANGUS:adult,SHEEP_LANDRACE:young,SHEEP_LANDRACE:yearling,"
        .. "SHEEP_LANDRACE:adult,HORSE_GRAY:young,HORSE_GRAY:adult")
end)

test("a vanilla entry's age band takes a month's birthday; age in its prime scores best", function()
    setup(false)
    local bands = TCShowClasses.getBands("COW")
    assertEquals(TCShowClasses.findBand(bands, 24, "young"), nil)
    assertEquals(TCShowClasses.findBand(bands, 24, "young", 1).key, "young")
    local young = bands[1]
    assertEquals(TCShowClasses.getAgeFactor(young, 20), 1)
    assertNear(TCShowClasses.getAgeFactor(young, 6), 0.75, 0.001)
    assertEquals(TCShowClasses.getAgeFactor(bands[2], 200), 0.3, "never below")
end)

-- Scoring ---------------------------------------------------------------------------------------------

test("vanilla scoring: health most, then age, then the husbandry's productivity", function()
    setup(false)
    local class = TCShowClasses.getClass(g_currentMission.animalSystem, "COW_HOLSTEIN:young")
    local score, model, stats = TCShowJudging.scoreAnimal(class, { age = 20, health = 100 }, 1)
    assertEquals(model, "vanilla")
    assertNear(score, 100, 0.001)
    assertEquals(stats[1].key .. "," .. stats[2].key .. "," .. stats[3].key, "health,age,productivity")
    assertNear(TCShowJudging.scoreAnimal(class, { age = 20, health = 0 }, 1), 40, 0.001, "an animal at 0 health")
    assertNear(TCShowJudging.scoreAnimal(class, { age = 20, health = 100 }, 0), 85, 0.001)
    -- No husbandry to read: the rest weighted up.
    local unread, _, unreadStats = TCShowJudging.scoreAnimal(class, { age = 20, health = 50 }, nil)
    assertNear(unread, 100 * (0.6 * 0.5 + 0.25) / 0.85, 0.001)
    assertEquals(#unreadStats, 2)
end)

test("RL scoring: genetics first, weight by how near its target (heavier isn't better), a pregnancy where a judge counts it", function()
    setup(true)
    local animalSystem = g_currentMission.animalSystem
    local heifer = TCShowClasses.getClass(animalSystem, "COW_HOLSTEIN:young")
    local cow = TCShowClasses.getClass(animalSystem, "COW_HOLSTEIN:adult")
    local function read(def)
        local animal = rlAnimal(def)
        return { age = animal.age, health = animal.health,
            animal = TCRealisticLivestock.readAnimal(animal) }
    end
    local average, model, stats = TCShowJudging.scoreAnimal(heifer, read({ uniqueId = "1" }))
    assertEquals(model, "rl")
    assertEquals(stats[1].key, "quality")
    assertEquals(stats[2].key, "geneticHealth")
    assertEquals(stats[3].key, "weight")
    assertEquals(stats[3].target, 400)
    local better = TCShowJudging.scoreAnimal(heifer, read({ uniqueId = "2",
        genetics = { quality = 1.4, health = 1.4, productivity = 1.4 } }))
    assertTrue(better > average, "better genetics")
    local heavy = TCShowJudging.scoreAnimal(heifer, read({ uniqueId = "3", weight = 520 }))
    local light = TCShowJudging.scoreAnimal(heifer, read({ uniqueId = "4", weight = 280 }))
    assertTrue(heavy < average, "over its target")
    assertNear(heavy, light, 0.001, "as far over as under")
    -- In calf counts for a heifer; in milk only for a cow.
    local inCalf = TCShowJudging.scoreAnimal(heifer, read({ uniqueId = "5", isPregnant = true }))
    assertNear(inCalf - average, TCShowJudging.BREEDING_BONUS.young, 0.001)
    local milking = TCShowJudging.scoreAnimal(heifer, read({ uniqueId = "6", isLactating = true }))
    assertNear(milking, average, 0.001)
    local cowRead = read({ uniqueId = "7", age = 40, isLactating = true })
    local _, _, cowStats = TCShowJudging.scoreAnimal(cow, cowRead)
    assertEquals(cowStats[#cowStats].key, "breeding")
    -- No productivity gene (a beef animal): left out, the rest weighted up
    -- (average genetics score half, the rest full marks).
    assertNear(average, 72.5, 0.001)
    local beef = read({ uniqueId = "8", genetics = { quality = 1, health = 1 } })
    assertNear(TCShowJudging.scoreAnimal(heifer, beef), 100 * (0.25 * 0.5 + 0.2 * 0.5 + 0.45) / 0.9, 0.001)
end)

test("Best Kept Herd: productivity first, a side it hasn't left out, manure counting against it", function()
    setup(false)
    local full = { productivity = 1, foodLevel = 1, foodVariety = 1, straw = 1, water = 1, cleanliness = 1 }
    local score, stats = TCShowJudging.scoreHerd(full)
    assertNear(score, 100, 0.001)
    assertEquals(stats[1].key, "productivity")
    assertEquals(#stats, 6)
    local noStraw = { productivity = 1, foodLevel = 1, foodVariety = 1, water = 1, cleanliness = 0 }
    local noStrawScore, noStrawStats = TCShowJudging.scoreHerd(noStraw)
    assertNear(noStrawScore, 100 * 0.7 / 0.85, 0.001)
    assertEquals(#noStrawStats, 5)

    -- Read from a husbandry: two food groups of three, half-full manure.
    local world = setup(false)
    local barn = addHusbandry(world, { groups = 2, food = 0.5, straw = 0.8, manure = 0.5, slurry = 0.25 })
    local readings = TCShowAnimals.readHerd(barn)
    assertNear(readings.foodVariety, 2 / 3, 0.001)
    assertEquals(readings.foodLevel, 0.5)
    assertEquals(readings.straw, 0.8)
    assertEquals(readings.water, 1, "an automatic supply")
    assertEquals(readings.cleanliness, 0.5, "the fuller store")
end)

test("ranking: best first, ties to the earlier, four placings; farmers' rolls by model and trait", function()
    setup(false)
    local a, b, c, d, e = { score = 50 }, { score = 80 }, { score = 50 }, { score = 90 }, { score = 10 }
    local ranked = TCShowJudging.rank({ a, b, c, d, e })
    assertTrue(ranked[1] == d and ranked[2] == b and ranked[3] == a and ranked[4] == c and ranked[5] == e)
    assertEquals(c.placing, 4, "highly commended")
    assertEquals(e.placing, nil)
    local function fixed(value) return function() return value end end
    assertEquals(TCShowJudging.rollFarmerScore("vanilla", 0, fixed(0)), 62)
    assertEquals(TCShowJudging.rollFarmerScore("rl", 1, fixed(0)), 50, "a good stockman")
    assertEquals(TCShowJudging.rollFarmerScore("herd", -1, fixed(0)), 37)
    assertEquals(TCShowJudging.rollEye(fixed(0)), -TCShowJudging.EYE_POINTS)
    assertEquals(TCShowJudging.rollEye(fixed(0.5)), 0)
end)

-- Entering -----------------------------------------------------------------------------------------------

test("entering: open, a company's, a class its animals show in, two a class and one herd, withdrawn while open", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    local barn = addHusbandry(world, { clusters = { cluster("COW_HOLSTEIN", 2, 20, 90), cluster("COW_HOLSTEIN", 1, 40, 90) } })
    local P = TheContractorShowLivestock.PROBLEMS
    local function problem(farmId, classKey, husbandry)
        return (livestock:getEntryProblem(farmId, { classKey = classKey, husbandry = husbandry }))
    end
    assertEquals(problem(1, "COW_HOLSTEIN:young", barn), P.noShow)
    announce(world)
    assertEquals(problem(3, "COW_HOLSTEIN:young", barn), P.noCompany)
    assertEquals(problem(2, "COW_HOLSTEIN:young", barn), P.noHusbandry, "not theirs")
    assertEquals(problem(1, "COW_JERSEY:adult", barn), P.noClass)
    assertEquals(problem(1, "BULL_HOLSTEIN:adult", barn), P.noAnimal, "none of them")

    local classes = TheContractorShowLivestock.getHusbandryClasses(barn)
    assertEquals(#classes, 2)
    assertEquals(classes[1].classKey, "COW_HOLSTEIN:young")
    assertEquals(classes[1].count, 2)

    assertTrue(enter(world, 1, "COW_HOLSTEIN:young", barn) ~= nil)
    assertTrue(enter(world, 1, "COW_HOLSTEIN:young", barn) ~= nil, "both heifers")
    assertEquals(problem(1, "COW_HOLSTEIN:young", barn), P.limit)
    assertTrue(enter(world, 1, "COW_HOLSTEIN:adult", barn) ~= nil)
    assertEquals(select(2, enter(world, 1, "COW_HOLSTEIN:adult", barn)), P.noAnimal, "only one cow")
    assertTrue(enter(world, 1, TCShowClasses.HERD_KEY, barn) ~= nil)
    assertEquals(problem(1, TCShowClasses.HERD_KEY, barn), P.limit)
    assertEquals(#livestock:getFarmEntries(1), 4)
    assertEquals(livestock.showId, world.tc.Show:getEvent().id)

    local entry = livestock:getFarmEntries(1)[1]
    assertEquals(livestock:withdraw(2, entry.id), P.notYours)
    assertEquals(livestock:withdraw(1, entry.id), nil)
    assertEquals(#livestock:getFarmEntries(1), 3)

    runToDay(world, CLOSE_DAY)
    assertEquals(problem(1, "COW_HOLSTEIN:young", barn), P.closed)
    assertEquals(livestock:withdraw(1, livestock:getFarmEntries(1)[1].id), P.closed)
end)

test("entering with RL: the animal by its key, in its own class, not sick, not twice", function()
    local world = setup(true)
    local livestock = world.tc.ShowLivestock
    local barn = addHusbandry(world, { clusters = {
        rlAnimal({ uniqueId = "100001", name = "Daisy", age = 20 }),
        rlAnimal({ uniqueId = "100002", age = 20, sick = true }),
        rlAnimal({ uniqueId = "100003", age = 40 }),
    } })
    local P = TheContractorShowLivestock.PROBLEMS
    announce(world)
    local function problem(classKey, animalKey)
        return (livestock:getEntryProblem(1, { classKey = classKey, husbandry = barn, animalKey = animalKey }))
    end
    assertEquals(problem("COW_HOLSTEIN:young", nil), P.noAnimal, "RL's animals go by name")
    assertEquals(problem("COW_HOLSTEIN:young", rlKey("100002")), P.sick)
    assertEquals(problem("COW_HOLSTEIN:young", rlKey("100003")), P.wrongClass)
    assertEquals(problem("COW_HOLSTEIN:young", rlKey("999")), P.noAnimal)
    local entry = enter(world, 1, "COW_HOLSTEIN:young", barn, rlKey("100001"))
    assertEquals(entry.name, "Daisy")
    assertEquals(problem("COW_HOLSTEIN:young", rlKey("100001")), P.alreadyEntered)
    -- The sick one isn't offered.
    local classes = TheContractorShowLivestock.getHusbandryClasses(barn)
    assertEquals(classes[1].count, 1)
end)

-- Farmers ---------------------------------------------------------------------------------------------------

test("when entries close farmers fill the players' classes, a few of their own and Best Kept Herd", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    local barn = addHusbandry(world, { clusters = { cluster("COW_HOLSTEIN", 1, 20, 90) } })
    announce(world)
    enter(world, 1, "COW_HOLSTEIN:young", barn)
    runToDay(world, CLOSE_DAY - 1)
    assertEquals(#livestock.farmerEntries, 0, "not before")
    runToDay(world, CLOSE_DAY)
    local byClass, order = {}, {}
    for _, farmerEntry in ipairs(livestock.farmerEntries) do
        if byClass[farmerEntry.classKey] == nil then
            byClass[farmerEntry.classKey] = 0
            table.insert(order, farmerEntry.classKey)
        end
        byClass[farmerEntry.classKey] = byClass[farmerEntry.classKey] + 1
        assertEquals(farmerEntry.score, farmerEntry.classKey == TCShowClasses.HERD_KEY and 65 or 77, "the middle roll")
    end
    assertEquals(order[1], "COW_HOLSTEIN:young")
    assertEquals(byClass["COW_HOLSTEIN:young"], 3)
    assertEquals(#order, 1 + TheContractorShowLivestock.FARMER_ONLY_CLASSES + 1)
    assertEquals(order[#order], TCShowClasses.HERD_KEY)
    -- Each farmer who entered has a trait, rolled once and kept.
    local entrants, traits = {}, 0
    for _, farmerEntry in ipairs(livestock.farmerEntries) do
        entrants[farmerEntry.farmerId] = true
    end
    for farmerId in pairs(livestock.stockman) do
        assertTrue(entrants[farmerId], "only entrants")
        traits = traits + 1
    end
    assertTrue(traits > 0)
    livestock.stockman[8] = 0.75
    assertEquals(livestock:getStockman(8), 0.75)
    -- Not drawn again.
    local count = #livestock.farmerEntries
    livestock:drawFarmerEntries(world.tc.Show:getEvent())
    assertEquals(#livestock.farmerEntries, count)
end)

-- Judging and results ---------------------------------------------------------------------------------------

-- Farm 1's barn of heifers and farm 2's: one show, entries, farmers. Every
-- farmer's heifer scores 77 (the middle roll).
local function twoFarmShow(world)
    local barn1 = addHusbandry(world, { farmId = 1, name = "Low Barn", clusters = {
        cluster("COW_HOLSTEIN", 2, 20, 100), cluster("COW_HOLSTEIN", 1, 22, 40) } })
    local barn2 = addHusbandry(world, { farmId = 2, name = "High Barn", clusters = {
        cluster("COW_HOLSTEIN", 1, 20, 90) } })
    announce(world)
    local first = enter(world, 1, "COW_HOLSTEIN:young", barn1)
    local second = enter(world, 1, "COW_HOLSTEIN:young", barn1)
    local other = enter(world, 2, "COW_HOLSTEIN:young", barn2)
    return barn1, barn2, first, second, other
end

test("judged at 10:00 from the trailers stopped in the lines: two farms in one class, a no-show, the placings paid at 16:00", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    -- Two farmers a class, so farm 1's second heifer comes 4th, and no classes
    -- of their own (no supreme champion: that's its own test).
    TheContractorShowLivestock.FARMER_ONLY_CLASSES = 0
    TheContractorShowLivestock.FARMERS_PER_CLASS = { 2, 2 }
    local _, _, first, second, other = twoFarmShow(world)
    runToDay(world, SHOW_DAY)
    -- Farm 1 brings its best heifer and its poorer one in one trailer;
    -- farm 2's trailer is still moving.
    addTrailer(world, { cluster("COW_HOLSTEIN", 1, 22, 40), cluster("COW_HOLSTEIN", 1, 20, 100) }, { farmId = 1, bay = 1 })
    addTrailer(world, { cluster("COW_HOLSTEIN", 1, 20, 90) }, { farmId = 2, bay = 2, speed = 8 })
    -- Another farm's trailer doesn't count for farm 1.
    addTrailer(world, { cluster("COW_HOLSTEIN", 5, 20, 100) }, { farmId = 3, bay = 3 })
    setHour(world, 9)
    assertTrue(not livestock.judged, "not before 10:00")
    setHour(world, 10)
    assertTrue(livestock.judged)
    local S = TheContractorShowLivestock.STATUS
    assertEquals(other.status, S.NO_SHOW, "a moving trailer isn't in the lines")
    -- The first entry gets the best animal there.
    assertNear(first.score, 100, 0.001)
    assertEquals(first.placing, 1)
    assertEquals(first.stats[1].key, "health")
    assertEquals(second.placing, 4, "behind two farmers at 77")
    assertEquals(second.status, S.PLACED)
    assertEquals(#livestock.farmerEntries > 0, true)

    setHour(world, 16)
    local heifers = placingsFor(world, "COW_HOLSTEIN:young")
    assertEquals(#heifers, 4)
    assertEquals(heifers[1].farmId, 1)
    assertEquals(heifers[1].titleKey, TheContractorShowLivestock.TITLE_KEY)
    assertEquals(heifers[2].farmerId > 0, true)
    assertEquals(heifers[4].farmId, 1)
    -- Paid: 1st's class prize scaled (x2 settings, x3 EconomyScale), the
    -- highly commended nothing.
    assertEquals(heifers[1].paid, 20 * 6)
    assertEquals(heifers[4].paid, 0)
    local paid = {}
    for _, money in ipairs(world.money) do
        table.insert(paid, money.farmId .. ":" .. money.amount)
    end
    assertEquals(table.concat(paid, ","), "1:120")
    assertEquals(world.reputation[1].delta, TheContractorShowLivestock.CLASS_REPUTATION[1] * 10)
    assertEquals(#world.reputation, 1, "nothing for highly commended")
    assertEquals(world.opinions[1].customerId, HOST_ID)
    assertEquals(world.opinions[1].delta, TheContractorShowLivestock.CLASS_OPINION[1])
    -- A rosette notice for each placing a farm won.
    assertEquals(table.concat(world.notices, ","), "1,1")
end)

test("a no-show costs nothing, an empty class doesn't run, and the farmers' classes give their placings", function()
    local world = setup(false)
    twoFarmShow(world)
    runToDay(world, SHOW_DAY)
    setHour(world, 16)
    for _, money in ipairs(world.money) do
        assertTrue(money.farmId ~= 1 and money.farmId ~= 2, "no player paid")
    end
    assertEquals(#world.reputation, 0)
    local S = TheContractorShowLivestock.STATUS
    for _, entry in ipairs(world.tc.ShowLivestock.entries) do
        assertEquals(entry.status, S.NO_SHOW)
    end
    -- Every class given has its farmers in it; none with nobody.
    local entered = {}
    for _, farmerEntry in ipairs(world.tc.ShowLivestock.farmerEntries) do
        entered[farmerEntry.classKey] = true
    end
    for _, placing in ipairs(world.tc.Show:getResults().placings) do
        assertTrue(entered[placing.titleArg] or TCShowClasses.isChampionKey(placing.titleArg), placing.titleArg)
    end
    assertEquals(#placingsFor(world, "COW_HOLSTEIN:young"), 3, "three farmers only")
end)

test("RL: the entered animal found by its key in the trailer, a sick one turned away by the vet", function()
    local world = setup(true)
    local livestock = world.tc.ShowLivestock
    local daisy = rlAnimal({ uniqueId = "100001", name = "Daisy", age = 20,
        genetics = { quality = 1.5, health = 1.5, productivity = 1.5 } })
    local bess = rlAnimal({ uniqueId = "100002", name = "Bess", age = 20 })
    local barn = addHusbandry(world, { clusters = { daisy, bess } })
    announce(world)
    local daisyEntry = enter(world, 1, "COW_HOLSTEIN:young", barn, rlKey("100001"))
    local bessEntry = enter(world, 1, "COW_HOLSTEIN:young", barn, rlKey("100002"))
    runToDay(world, SHOW_DAY)
    bess.sick = true
    -- Another heifer of the same breed doesn't stand in for Daisy.
    addTrailer(world, { rlAnimal({ uniqueId = "100009", age = 20 }), bess, daisy }, { farmId = 1, bay = 4 })
    setHour(world, 10)
    assertEquals(bessEntry.status, TheContractorShowLivestock.STATUS.SICK)
    assertEquals(daisyEntry.placing, 1)
    assertEquals(daisyEntry.stats[1].key, "quality")
    assertEquals(daisyEntry.stats[1].value, 1.5)
    assertEquals(livestock.farmerEntries[1].model, "rl")
    setHour(world, 16)
    assertEquals(placingsFor(world, "COW_HOLSTEIN:young")[1].entrant, "Daisy")
end)

test("supreme champion: the best class winner of a type with two classes run, paid the most", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    local barn = addHusbandry(world, { clusters = { cluster("COW_HOLSTEIN", 1, 20, 100), cluster("COW_HOLSTEIN", 1, 40, 60) } })
    announce(world)
    local heifer = enter(world, 1, "COW_HOLSTEIN:young", barn)
    local cow = enter(world, 1, "COW_HOLSTEIN:adult", barn)
    runToDay(world, SHOW_DAY)
    addTrailer(world, { cluster("COW_HOLSTEIN", 1, 20, 100), cluster("COW_HOLSTEIN", 1, 40, 60) }, { farmId = 1, bay = 1 })
    setHour(world, 16)
    assertTrue(heifer.champion, "the heifer's the best winner")
    assertTrue(not cow.champion)
    local champions = placingsFor(world, TCShowClasses.getChampionKey("COW"))
    assertEquals(#champions, 1)
    assertEquals(champions[1].farmId, 1)
    assertEquals(champions[1].paid, TheContractorShowLivestock.CHAMPION_PRIZE * 6)
    local most = 0
    for _, reputation in ipairs(world.reputation) do
        most = math.max(most, reputation.delta)
    end
    assertEquals(most, TheContractorShowLivestock.CHAMPION_REPUTATION * 10)
    -- The results keep each class together, the champion after its type's.
    local args = {}
    for _, placing in ipairs(world.tc.Show:getResults().placings) do
        if args[#args] ~= placing.titleArg then
            table.insert(args, placing.titleArg)
        end
    end
    local seen = {}
    for _, arg in ipairs(args) do
        assertTrue(not seen[arg], "one run of " .. arg)
        seen[arg] = true
    end
    assertEquals(args[#args], TCShowClasses.HERD_KEY, "Best Kept Herd last")
    assertEquals(livestock:getEntry(heifer.id), heifer)
end)

test("Best Kept Herd is judged on the husbandry as it was the day before", function()
    local world = setup(false)
    local barn = addHusbandry(world, { productivity = 1 })
    announce(world)
    local entry = enter(world, 1, TCShowClasses.HERD_KEY, barn)
    assertEquals(entry.entrant, "Barn")
    runToDay(world, SHOW_DAY)
    -- Set out at midnight: read then. The barn runs out of straw that morning.
    barn.levels.straw = 0
    setHour(world, 10)
    assertNear(entry.score, 100, 0.001)
    assertEquals(entry.placing, 1)
    setHour(world, 16)
    local herd = placingsFor(world, TCShowClasses.HERD_KEY)
    assertEquals(herd[1].farmId, 1)
    assertEquals(herd[1].paid, TheContractorShow.PRIZES[1] * 6, "the show's own prize")
end)

-- Sync, save, farms and farmers ------------------------------------------------------------------------------

test("every machine gets the entries, placings and stats, never a score, the eye or a farmer's entry", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    local first = twoFarmShow(world)
    runToDay(world, SHOW_DAY)
    addTrailer(world, { cluster("COW_HOLSTEIN", 2, 20, 100) }, { farmId = 1, bay = 1 })
    setHour(world, 10)
    local sent = world.events[#world.events]
    assertEquals(getmetatable(sent), getmetatable(TCShowLivestockEvent.emptyNew()))
    local stream = world:newStream()
    sent:writeStream(stream)

    local client = TheContractorShowLivestock.new()
    world.tc.ShowLivestock = client
    local received = TCShowLivestockEvent.emptyNew()
    received:readStream(stream, { getIsServer = function() return false end })
    assertEquals(#client.entries, 0, "not from a client")
    received:run({ getIsServer = function() return true end })
    assertEquals(#client.entries, 3)
    assertTrue(client.judged)
    local copy = client:getFarmEntries(1)[1]
    assertEquals(copy.placing, 1)
    assertEquals(copy.status, TheContractorShowLivestock.STATUS.PLACED)
    assertEquals(copy.stats[1].key, "health")
    assertEquals(copy.stats[1].value, 100)
    assertEquals(copy.score, nil)
    assertEquals(copy.eye, nil)
    assertEquals(#client.farmerEntries, 0)

    -- A client's entry request is the server's to apply, for its own farm.
    world.tc.ShowLivestock = livestock
    local request = TCShowEntryEvent.newWithdraw(1, first.id)
    local requestStream = world:newStream()
    request:writeStream(requestStream)
    local count = #livestock.entries
    local connection = { getIsServer = function() return false end }
    g_currentMission.connectionsToPlayer = { [connection] = { farmId = 2 } }
    local fromClient = TCShowEntryEvent.emptyNew()
    fromClient:readStream(requestStream, connection)
    assertEquals(#livestock.entries, count, "farm 2's player can't withdraw farm 1's")
end)

test("entries, farmers' entries, traits and scores survive a save and load, placings rebuilt the same", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    local barn1 = twoFarmShow(world)
    runToDay(world, SHOW_DAY)
    addTrailer(world, { cluster("COW_HOLSTEIN", 2, 20, 100) }, { farmId = 1, bay = 1 })
    setHour(world, 10)
    local before = livestock:buildPlacings()

    local xmlFile = {}
    livestock:saveToXmlFile(xmlFile)
    local loaded = TheContractorShowLivestock.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded.showId, livestock.showId)
    assertTrue(loaded.judged and loaded.drawn)
    assertEquals(#loaded.entries, 3)
    assertEquals(#loaded.farmerEntries, #livestock.farmerEntries)
    assertEquals(loaded.stockman[8], livestock.stockman[8])
    assertEquals(loaded.nextEntryId, livestock.nextEntryId)
    local entry = loaded:getFarmEntries(1)[1]
    assertEquals(entry.husbandryId, nil, "until placeables exist")
    loaded:resolveSavedVehicles()
    assertEquals(entry.husbandryId, barn1.id)
    assertEquals(entry.placing, 1)
    assertEquals(entry.stats[1].key, "health")
    local after = loaded:buildPlacings()
    assertEquals(#after, #before)
    for i, placing in ipairs(before) do
        assertEquals(after[i].titleArg, placing.titleArg)
        assertEquals(after[i].farmId, placing.farmId)
        assertEquals(after[i].farmerId, placing.farmerId)
    end

    -- A joining client.
    local stream = world:newStream()
    loaded:writeInitialClientState(stream)
    local client = TheContractorShowLivestock.new()
    client:readInitialClientState(stream)
    assertEquals(#client.entries, 3)
    assertEquals(client:getFarmEntries(2)[1].status, TheContractorShowLivestock.STATUS.NO_SHOW)
end)

test("a deleted farm's entries go; a retired farmer's entries pass to their successor, without the trait", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    twoFarmShow(world)
    runToDay(world, CLOSE_DAY)
    livestock:forgetFarm(1)
    assertEquals(#livestock:getFarmEntries(1), 0)
    assertEquals(#livestock:getFarmEntries(2), 1)

    local held = 0
    for _, farmerEntry in ipairs(livestock.farmerEntries) do
        if farmerEntry.farmerId == 8 then
            held = held + 1
        end
    end
    assertTrue(held > 0, "farmer 8 entered something")
    world.tc.PublicEvents:replaceHost(8, 20)
    for _, farmerEntry in ipairs(livestock.farmerEntries) do
        assertTrue(farmerEntry.farmerId ~= 8)
    end
    assertEquals(livestock.stockman[8], nil)
end)

test("a new show starts the entries again, and a cancelled one drops them", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    twoFarmShow(world)
    assertEquals(#livestock.entries, 3)
    world.tc.Show:cancel(false)
    assertEquals(#livestock.entries, 0)
    assertEquals(livestock.showId, nil)
end)
