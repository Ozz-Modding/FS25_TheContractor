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
        getSubTypeIndexByName = function(_, name) return byName[name] ~= nil and byName[name].subTypeIndex or nil end,
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
    world:load("src/util/TCShowPens.lua")
    world:load("src/util/TCShowRing.lua")
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
        paintPenGround = function() return 0 end,
        clear = function(self) self.site = nil return "cleared" end,
    }
    TheContractorAuctionSite = { PREFERRED_LOTS = 120, CLOSE_HOURS = { 17, 18 },
        getFieldRefusal = function() return nil end }
    tc.AuctionSite = {
        site = nil, fieldId = 0, walkways = {},
        getWalkways = function(self) return self.walkways end,
        getScene = function(self) return self.site ~= nil and world.scene or nil end,
        startOpen = function(self, fieldId, kind, eventId, options)
            self.site = { fieldId = fieldId }
            self.fieldId = fieldId
            world.scene.pens = options ~= nil and options.pens or nil
        end,
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
    world:register(trailer)
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

-- 188: the hour, the clock (dayTime) with it, and the ring's run on to
-- it (ShowLivestock:update, as the server does every second).
local function setHour(world, hour)
    g_currentMission.environment.currentHour = hour
    g_currentMission.environment.dayTime = hour * 3600000
    world.tc.ShowLivestock:update(TheContractorShowLivestock.PEN_CHECK_MS)
    world.tc.Show:onHourChanged()
end

-- 188: the clock to a minute of the show's day, the ring run on to it.
local function setMinute(world, minute)
    local environment = g_currentMission.environment
    environment.currentHour = math.floor(minute / 60)
    environment.dayTime = minute * 60000
    world.tc.ShowLivestock:update(TheContractorShowLivestock.PEN_CHECK_MS)
end

-- 188: every class through the ring (to 15:30, before the results).
local function runRing(world)
    setMinute(world, TCShowRing.END_MINUTE)
end

-- 188: a class placed: the clock to its slot's placing.
local function placeClass(world, classKey)
    local slot = TCShowRing.findSlot(world.tc.ShowLivestock.timetable, classKey)
    assertTrue(slot ~= nil, classKey .. " in the ring's timetable")
    setMinute(world, slot.judgeAt)
end

-- How many notices a farm's had.
local function noticesFor(world, farmId)
    local count = 0
    for _, id in ipairs(world.notices) do
        if id == farmId then
            count = count + 1
        end
    end
    return count
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

    -- 188: any class until 09:30 on the day; a late entry in a class not
    -- on the ring's timetable adds it, with a few farmers in it.
    runToDay(world, CLOSE_DAY)
    local event = world.tc.Show:getEvent()
    assertEquals(problem(1, "COW_HOLSTEIN:young", barn), nil, "late, its class is in the ring")
    assertEquals(livestock:getWindowProblem(event, TCShowClasses.HERD_KEY), nil)
    local heifers = addHusbandry(world, { clusters = { cluster("BULL_HOLSTEIN", 1, 30, 90) } })
    assertEquals(TCShowRing.findSlot(livestock.timetable, "BULL_HOLSTEIN:adult"), nil, "not running yet")
    assertTrue(enter(world, 1, "BULL_HOLSTEIN:adult", heifers) ~= nil, "a late entry in a new class")
    assertTrue(TCShowRing.findSlot(livestock.timetable, "BULL_HOLSTEIN:adult") ~= nil, "added to the ring")
    local farmers = 0
    for _, farmerEntry in ipairs(livestock.farmerEntries) do
        if farmerEntry.classKey == "BULL_HOLSTEIN:adult" then
            farmers = farmers + 1
        end
    end
    assertTrue(farmers > 0, "farmers in it too")
    assertTrue(enter(world, 1, "COW_HOLSTEIN:young", barn) ~= nil, "a late entry")
    runToDay(world, SHOW_DAY)
    setMinute(world, TheContractorShow.ENTRY_CLOSE_MINUTE - 1)
    assertEquals(livestock:getWindowProblem(event, "COW_HOLSTEIN:young"), nil, "on the morning")
    assertEquals(livestock:getWindowProblem(event, TCShowClasses.HERD_KEY), nil)
    assertEquals(livestock:withdraw(1, livestock:getFarmEntries(1)[1].id), nil, "withdrawn late")
    setMinute(world, TheContractorShow.ENTRY_CLOSE_MINUTE)
    assertEquals(problem(1, "COW_HOLSTEIN:young", barn), P.closed, "entries closed at 09:30")
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

test("188: entering from a livestock trailer, the animals loaded already; a herd entered on the day is read then", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    local P = TheContractorShowLivestock.PROBLEMS
    local barn = addHusbandry(world, { productivity = 1 })
    announce(world)
    runToDay(world, CLOSE_DAY - 1)
    enter(world, 2, "COW_HOLSTEIN:young", addHusbandry(world, { farmId = 2,
        clusters = { cluster("COW_HOLSTEIN", 1, 20, 90) } }))
    runToDay(world, SHOW_DAY)
    setMinute(world, 8 * 60)
    local trailer = addTrailer(world, { cluster("COW_HOLSTEIN", 1, 20, 100) }, { farmId = 1, bay = 1 })
    local sources = TCShowAnimals.getFarmSources(1)
    assertEquals(sources[#sources], trailer, "the farm's trailer after its barns")
    assertEquals(#TCShowAnimals.getFarmSources(3), 0, "only a farm's own")
    local classes = TheContractorShowLivestock.getHusbandryClasses(trailer)
    assertEquals(classes[1].classKey, "COW_HOLSTEIN:young")
    assertEquals((livestock:getEntryProblem(1, { classKey = TCShowClasses.HERD_KEY, husbandry = trailer })),
        P.noHusbandry, "Best Kept Herd from a barn only")
    local entry = world.tc.ShowLivestock:enter(1, "COW_HOLSTEIN:young", trailer.id)
    assertTrue(entry ~= nil, "entered from the trailer")
    assertEquals(entry.husbandryId, nil, "no barn kept")
    assertEquals(select(2, world.tc.ShowLivestock:enter(1, "COW_HOLSTEIN:young", trailer.id)), P.noAnimal,
        "only one heifer in it")
    -- A herd entered on the morning is read as it stands then.
    local herd = enter(world, 1, TCShowClasses.HERD_KEY, barn)
    assertTrue(herd ~= nil and herd.herdReadings ~= nil)
    runRing(world)
    assertEquals(entry.status, TheContractorShowLivestock.STATUS.PLACED, "judged from the trailer in the lines")
    assertTrue(herd.score ~= nil)
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

test("judged in the ring at its class's time from the trailers stopped in the lines: two farms in one class, a no-show, the placings paid at 16:00", function()
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
    assertEquals(livestock.ring, nil)
    -- 188: the heifers first in the ring, at 10:00; Best Kept Herd after.
    local slot = livestock.timetable[1]
    assertEquals(slot.key, "COW_HOLSTEIN:young")
    assertEquals(slot.from, TCShowRing.START_MINUTE)
    assertEquals(livestock.timetable[#livestock.timetable].key, TCShowClasses.HERD_KEY)
    setHour(world, 10)
    local S = TheContractorShowLivestock.STATUS
    assertEquals(other.status, S.NO_SHOW, "a moving trailer isn't in the lines")
    -- The first entry gets the best animal there: judged, not yet placed.
    assertNear(first.score, 100, 0.001)
    assertEquals(first.placing, nil)
    assertEquals(first.status, S.ENTERED)
    assertEquals(livestock.slotStates[1], TCShowRing.STATE.IN_RING)
    -- Farm 1's two heifers in the line, as they're seen in its trailer
    -- (188: never penned), and the two farmers' from their pens; farm 2
    -- told it's a no-show, farm 1 that its class is in.
    assertEquals(livestock.ring.slot, 1)
    assertEquals(#livestock.ring.lineup, 4)
    local looks, fromPens = 0, 0
    for _, item in ipairs(livestock.ring.lineup) do
        if item.look ~= nil then
            looks = looks + 1
            assertEquals(item.look.subTypeName, "COW_HOLSTEIN")
            assertEquals(item.look.trailerId, world.trailers[1].id, "hidden in its trailer meanwhile")
        elseif item.pen ~= nil then
            fromPens = fromPens + 1
        end
    end
    assertEquals(looks, 2)
    assertEquals(fromPens, 2)
    assertEquals(#livestock.pens, 2, "a pen each for the farmers' heifers, none for a player's")
    assertEquals(noticesFor(world, 1), 1)
    assertEquals(noticesFor(world, 2), 1)
    assertTrue(not livestock.judged)

    placeClass(world, "COW_HOLSTEIN:young")
    assertEquals(first.placing, 1)
    assertEquals(first.stats[1].key, "health")
    assertEquals(second.placing, 4, "behind two farmers at 77")
    assertEquals(second.status, S.PLACED)
    assertEquals(#livestock.farmerEntries > 0, true)
    -- The line in placing order, the rosettes' notices as they're placed.
    assertTrue(livestock.ring.placed)
    assertEquals(livestock.ring.lineup[1].entry, first)
    assertEquals(noticesFor(world, 1), 3, "a rosette notice for each placing")
    setMinute(world, slot.to)
    assertEquals(livestock.ring, nil, "back in their pens")
    assertEquals(livestock.slotStates[1], TCShowRing.STATE.OVER)

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
    -- 188: none more at the results: the rosettes' went as they were placed.
    assertEquals(noticesFor(world, 1), 3)
    assertTrue(livestock.judged)
end)

test("188: at 09:00 a farm is told how many entered animals aren't in the drop-off zone, once", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    twoFarmShow(world)
    runToDay(world, SHOW_DAY)
    -- Farm 1 brings one of its two heifers; farm 2 none.
    addTrailer(world, { cluster("COW_HOLSTEIN", 1, 20, 100) }, { farmId = 1, bay = 1 })
    setMinute(world, TheContractorShowLivestock.DROP_OFF_CHECK_MINUTE - 1)
    assertEquals(#world.notices, 0, "not before 09:00")
    local told = {}
    world.tc.Notices.publish = function(_, farmId, text)
        told[farmId] = text
        table.insert(world.notices, farmId)
    end
    world.texts["tc_showEntry_noticeDropOff"] = "missing %d"
    setMinute(world, TheContractorShowLivestock.DROP_OFF_CHECK_MINUTE)
    assertEquals(told[1], "missing 1")
    assertEquals(told[2], "missing 1")
    assertEquals(#world.notices, 2)
    setMinute(world, TheContractorShowLivestock.DROP_OFF_CHECK_MINUTE + 10)
    assertEquals(#world.notices, 2, "once a show")
    local xml = {}
    livestock:saveToXmlFile(xml)
    local loaded = TheContractorShowLivestock.new()
    loaded:loadFromXMLFile(xml)
    assertTrue(loaded.dropOffChecked, "not told again after a load")
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
    placeClass(world, "COW_HOLSTEIN:young")
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
    assertEquals(entry.score, nil, "the herd's slot is the day's last")
    placeClass(world, TCShowClasses.HERD_KEY)
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
    -- 188: judged but not placed yet: no stats go.
    local early = world:newStream()
    local lastLivestock = nil
    for _, event in ipairs(world.events) do
        if getmetatable(event) == getmetatable(TCShowLivestockEvent.emptyNew()) then
            lastLivestock = event
        end
    end
    lastLivestock:writeStream(early)
    local earlyCopy = TCShowLivestockEvent.emptyNew()
    earlyCopy:readStream(early, { getIsServer = function() return false end })
    assertEquals(#earlyCopy.state.entries[1].stats, 0, "no stats before its placing")
    assertEquals(earlyCopy.state.ring.slot, 1, "the ring goes")
    assertEquals(#earlyCopy.state.timetable, #livestock.timetable, "and the timetable")
    runRing(world)
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
    runRing(world)
    local before = livestock:buildPlacings()

    local xmlFile = {}
    livestock:saveToXmlFile(xmlFile)
    local loaded = TheContractorShowLivestock.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded.showId, livestock.showId)
    assertTrue(loaded.judged and loaded.drawn)
    assertEquals(#loaded.timetable, #livestock.timetable, "188: the timetable")
    assertEquals(loaded.slotStates[1], TCShowRing.STATE.OVER)
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

-- 182: the pens ----------------------------------------------------------------------------------

-- The pens given to farmers.
local function farmerPens(livestock)
    local list = {}
    for number, pen in ipairs(livestock.pens) do
        if pen.subTypeName ~= nil then
            table.insert(list, number)
        end
    end
    return list
end

-- 188: the players' animals in the ring's line (their looks).
local function lineLooks(livestock)
    local list = {}
    for _, item in ipairs(livestock.ring ~= nil and livestock.ring.lineup or {}) do
        if item.look ~= nil then
            table.insert(list, item)
        end
    end
    return list
end

test("pens: given out at set-out to the farmers' animals only (188: never a player's), a row at most, the count in the scene", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    twoFarmShow(world)
    runToDay(world, SHOW_DAY - 1)
    assertTrue(not livestock.pensAssigned, "not before the set-out")
    runToDay(world, SHOW_DAY)
    assertTrue(livestock.pensAssigned)
    local farmers = farmerPens(livestock)
    assertTrue(#farmers > 0)
    assertEquals(#farmers, #livestock.pens, "every pen a farmer's")
    assertTrue(#livestock.pens <= TheContractorShowLivestock.getPensPerRow())
    assertEquals(world.scene.pens, #livestock.pens, "the scene lays out that many")
    -- Each pen is a farmer's entry's.
    local held = 0
    for _, farmerEntry in ipairs(livestock.farmerEntries) do
        if farmerEntry.pen ~= nil then
            held = held + 1
            assertEquals(livestock.pens[farmerEntry.pen].subTypeName,
                TCShowClasses.getClass(g_currentMission.animalSystem, farmerEntry.classKey).subTypeName)
        end
    end
    assertEquals(held, #farmers)
end)

test("pens: the farmers' animals are there while the gates are open; a player's stays in its trailer, seen only in the ring", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    local _, _, first = twoFarmShow(world)
    runToDay(world, SHOW_DAY)
    local trailer = addTrailer(world, { cluster("COW_HOLSTEIN", 1, 22, 40), cluster("COW_HOLSTEIN", 1, 20, 100) },
        { farmId = 1, bay = 1 })
    local farmerPen = livestock.pens[farmerPens(livestock)[1]]
    livestock:updatePens()
    assertEquals(farmerPen.present, nil, "not before the gates open")
    local sent = #world.events
    setHour(world, 8)
    assertTrue(farmerPen.present, "the farmers' are there")
    assertTrue(#world.events > sent, "every machine told")
    assertEquals(#lineLooks(livestock), 0, "nobody in the ring yet")

    -- At its class: the player's heifers in the line as their trailer has
    -- them, the best first as the judge takes it; the ring shows them.
    setHour(world, 10)
    local looks = lineLooks(livestock)
    assertEquals(#looks, 2)
    local ages = {}
    for _, item in ipairs(looks) do
        assertEquals(item.look.trailerId, trailer.id)
        assertEquals(item.look.variation, 1, "vanilla's coat, as its trailer shows it")
        assertEquals(item.farmId, 1)
        ages[item.entry.id] = item.look.age
    end
    assertEquals(ages[first.id], 20)
    local display = livestock:getDisplay()
    assertEquals(#display.ring, #livestock.ring.lineup, "the players' and the farmers' in the ring")
    runRing(world)
    assertEquals(first.status, TheContractorShowLivestock.STATUS.PLACED)
    setHour(world, 18)
    assertEquals(farmerPen.present, nil, "the gates closed")
end)

test("the ring: an RL animal by its key with its own coat; a sick one turned away isn't in the line", function()
    local world = setup(true)
    local livestock = world.tc.ShowLivestock
    local daisy = rlAnimal({ uniqueId = "100001", name = "Daisy", age = 20 })
    daisy.variation = 3
    local bess = rlAnimal({ uniqueId = "100002", name = "Bess", age = 20 })
    local barn = addHusbandry(world, { clusters = { daisy, bess } })
    announce(world)
    enter(world, 1, "COW_HOLSTEIN:young", barn, rlKey("100001"))
    enter(world, 1, "COW_HOLSTEIN:young", barn, rlKey("100002"))
    runToDay(world, SHOW_DAY)
    bess.sick = true
    addTrailer(world, { rlAnimal({ uniqueId = "100009", age = 20 }), bess, daisy }, { farmId = 1, bay = 4 })
    setHour(world, 10)
    local looks = lineLooks(livestock)
    assertEquals(#looks, 1)
    assertEquals(looks[1].look.animalKey, rlKey("100001"))
    assertEquals(looks[1].look.variation, 3)
end)

test("pens: once placed, the farmers' pens have their placings; every machine has the pens and the ring's looks", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    TheContractorShowLivestock.FARMER_ONLY_CLASSES = 0
    TheContractorShowLivestock.FARMERS_PER_CLASS = { 2, 2 }
    twoFarmShow(world)
    runToDay(world, SHOW_DAY)
    addTrailer(world, { cluster("COW_HOLSTEIN", 1, 22, 40), cluster("COW_HOLSTEIN", 1, 20, 100) }, { farmId = 1, bay = 1 })
    setHour(world, 10)
    for _, pen in ipairs(livestock.pens) do
        assertEquals(pen.placing, nil, "not till it's placed")
    end
    placeClass(world, "COW_HOLSTEIN:young")
    -- Farm 1's best 1st; two farmers at 77, 2nd and 3rd.
    local placed = {}
    for _, number in ipairs(farmerPens(livestock)) do
        local pen = livestock.pens[number]
        if pen.placing ~= nil then
            table.insert(placed, pen.placing)
        end
    end
    table.sort(placed)
    assertEquals(table.concat(placed, ","), "2,3")

    local stream = world:newStream()
    world.events[#world.events]:writeStream(stream)
    local client = TheContractorShowLivestock.new()
    world.tc.ShowLivestock = client
    local received = TCShowLivestockEvent.emptyNew()
    received:readStream(stream, { getIsServer = function() return true end })
    assertEquals(#client.pens, #livestock.pens)
    assertTrue(client.penVersion > 0)
    for number, pen in ipairs(livestock.pens) do
        local copy = client.pens[number]
        for _, field in ipairs({ "subTypeName", "age", "variation", "present", "placing", "champion" }) do
            assertEquals(copy[field], pen[field], field .. " of pen " .. number)
        end
    end
    assertEquals(#client.ring.lineup, #livestock.ring.lineup)
    for i, item in ipairs(livestock.ring.lineup) do
        local copy = client.ring.lineup[i]
        assertEquals(copy.pen, item.pen)
        assertEquals(copy.farmId, item.farmId)
        if item.look ~= nil then
            for _, field in ipairs({ "subTypeName", "age", "variation", "trailerId", "animalKey" }) do
                assertEquals(copy.look[field], item.look[field], field)
            end
        end
    end
    assertEquals(client.ring.lineup[1].entry, nil, "never the entry itself")
end)

test("the ring: a supreme champion's line is its type's class winners, a player's as its trailer has it", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    TheContractorShowLivestock.FARMER_ONLY_CLASSES = 0
    TheContractorShowLivestock.FARMERS_PER_CLASS = { 2, 2 }
    local barn = addHusbandry(world, { farmId = 1, clusters = {
        cluster("COW_HOLSTEIN", 1, 20, 100), cluster("BULL_HOLSTEIN", 1, 20, 100) } })
    announce(world)
    enter(world, 1, "COW_HOLSTEIN:young", barn)
    enter(world, 1, "BULL_HOLSTEIN:young", barn)
    runToDay(world, SHOW_DAY)
    addTrailer(world, { cluster("COW_HOLSTEIN", 1, 20, 100), cluster("BULL_HOLSTEIN", 1, 20, 100) }, { farmId = 1, bay = 1 })
    setHour(world, 10)
    local championKey = TCShowClasses.getChampionKey("COW")
    local championSlot, championIndex = TCShowRing.findSlot(livestock.timetable, championKey)
    assertTrue(championSlot ~= nil)
    setMinute(world, championSlot.from)
    assertEquals(livestock.ring.slot, championIndex)
    assertEquals(#lineLooks(livestock), 2, "both of farm 1's winners")
    setMinute(world, championSlot.judgeAt)
    local champions = 0
    for _, item in ipairs(livestock.ring.lineup) do
        if item.champion then
            champions = champions + 1
        end
    end
    assertEquals(champions, 1)
end)

test("pens and the ring survive a save and load mid-class; a deleted farm's animals leave the ring", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    local first = twoFarmShow(world)
    runToDay(world, SHOW_DAY)
    addTrailer(world, { cluster("COW_HOLSTEIN", 2, 20, 100) }, { farmId = 1, bay = 1 })
    setHour(world, 10)
    placeClass(world, "COW_HOLSTEIN:young")
    assertTrue(#lineLooks(livestock) > 0)

    local xmlFile = {}
    livestock:saveToXmlFile(xmlFile)
    local loaded = TheContractorShowLivestock.new()
    loaded:loadFromXMLFile(xmlFile)
    assertTrue(loaded.pensAssigned)
    assertEquals(#loaded.pens, #livestock.pens)
    for number, pen in ipairs(livestock.pens) do
        assertEquals(loaded.pens[number].subTypeName, pen.subTypeName)
        assertEquals(loaded.pens[number].age, pen.age)
        assertEquals(loaded.pens[number].variation, pen.variation)
        assertEquals(loaded.pens[number].placing, pen.placing, "placings rebuilt")
    end
    assertEquals(#loaded.ring.lineup, #livestock.ring.lineup)
    local entries = {}
    for _, item in ipairs(loaded.ring.lineup) do
        if item.look ~= nil then
            entries[item.entry ~= nil and item.entry.id or -1] = true
            assertEquals(item.farmId, 1)
        elseif item.pen ~= nil then
            assertTrue(item.farmerEntry ~= nil and item.farmerEntry.pen == item.pen, "a farmer's, from its pen")
        end
    end
    assertTrue(entries[first.id], "the player's entry back in its place in the line")

    loaded:forgetFarm(1)
    assertEquals(#lineLooks(loaded), 0)
end)

test("pens: a load from before 182 on the day gives them out at the first look; a player's pen from before 188 stands empty", function()
    local world = setup(false)
    local livestock = world.tc.ShowLivestock
    twoFarmShow(world)
    runToDay(world, SHOW_DAY)
    livestock.pens, livestock.pensAssigned = {}, false
    setHour(world, 9)
    assertTrue(livestock.pensAssigned)
    assertTrue(#livestock.pens > 0)
    assertEquals(livestock.pens[1].entryId, nil)

    local xmlFile = {}
    livestock:saveToXmlFile(xmlFile)
    local key = TheContractor.SaveKey .. "." .. TheContractorShowLivestock.SAVE_KEY .. ".pen(0)"
    xmlFile[key .. "#subTypeName"] = nil
    xmlFile[key .. "#entryId"] = livestock.entries[1].id
    xmlFile[key .. "#farmId"] = 1
    local loaded = TheContractorShowLivestock.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded.pens[1].subTypeName, nil)
    assertEquals(loaded.pens[1].entryId, nil)
end)

-- 188: the breeders ------------------------------------------------------------------------------

-- RL's API for the breeders' stock (tests/test_breedersPen.lua's, cut
-- down): every animal it makes is healthy and premium.
local function installBreederAPI(world)
    local api = { API_VERSION = 1, REASON = { ANIMAL_NOT_IN_SOURCE = "animalNotInSource" } }
    world.holdings = {}
    world.nextNumber = 1
    function api.isReady() return true end
    function api.createAnimal(options)
        local animal = { subType = options.subType, age = options.age, quality = options.quality,
            number = world.nextNumber }
        world.nextNumber = world.nextNumber + 1
        return animal
    end
    function api.describeAnimal(animal)
        return { id = { type = "T", country = "DE", herd = "1", number = tostring(animal.number) },
            subType = animal.subType, age = animal.age, weight = 400, targetWeight = 400, health = 100,
            gender = "female", diseased = animal.diseased == true,
            genetics = { quality = 1.4, health = 1.4, productivity = 1.4, metabolism = 1, fertility = 1 } }
    end
    function api.getAnimalValue() return 1000 end
    function api.getAnimalsIn(target) return world.holdings[target] or {} end
    function api.addAnimalsTo(target, animals)
        world.holdings[target] = world.holdings[target] or {}
        for _, animal in ipairs(animals) do
            table.insert(world.holdings[target], animal)
        end
        return true
    end
    function api.moveAnimals() return true end
    RealisticLivestockAPI = api
    return api
end

-- The show with its breeders: a roomy showground (160 x 100 m), the real
-- breeders on it (their stand's open in the show's hours) and, withRL,
-- their RL stock in trailers.
local function setupBreeders(withRL)
    local world = setup(withRL)
    RealisticLivestockAPI = nil
    world:load("src/util/TCVehicleIds.lua")
    world:load("src/util/TCBreedersPen.lua")
    world:load("src/business/BreedersPen.lua")
    world:load("src/events/TCBreedersPenEvent.lua")
    local rect = { cx = 100, cz = 50, angle = 0, halfU = 80, halfV = 50 }
    local entrance = { x = rect.cx + rect.halfU + 10, z = rect.cz }
    world.scene = TCAuctionLayout.getScene(TCAuctionLayout.layOutOpenRect(rect, entrance), entrance, 99)
    world.scene.dressing = "show"
    world.plan.showRect = rect
    world.plan.entrance = { x = entrance.x, z = entrance.z, distance = 10 }
    local site = world.tc.AuctionSite
    site.startOpen = function(self, fieldId, kind, eventId, options)
        self.site = { fieldId = fieldId }
        self.fieldId = fieldId
        world.scene.pens = options ~= nil and options.pens or nil
        world.scene.breeders = options ~= nil and options.breeders or nil
    end
    local tc = world.tc
    tc.ShowStands = {
        getScene = function() return site:getScene() end,
        isOpen = function()
            local hour = g_currentMission.environment.currentHour or 0
            return site:getScene() ~= nil and hour >= 8 and hour < 18
        end,
    }
    if withRL then
        installBreederAPI(world)
        FarmManager.MAX_NUM_FARMS = 8
        g_farmManager.getFarmById = function(_, farmId) return farmId <= 2 and { farmId = farmId } or nil end
    end
    local pen = TheContractorBreedersPen.new()
    pen:register(tc.Show)
    pen.random = function(a, b)
        if b ~= nil then
            return a
        end
        return 1
    end
    pen.engine = {
        pickTrailerModel = function() return { xmlFilename = "trailer.xml" }, 8 end,
        spawnTrailer = function(spawner, index, spot, generation)
            local trailer = world:addVehicle({ name = "breeder trailer", farmId = spawner.farmId })
            spawner:onTrailerSpawned(trailer, index, generation)
        end,
        deleteVehicle = function() end,
    }
    tc.BreedersPen = pen
    world.pen = pen
    return world
end

-- A breeder's entries in a class: { farmerEntry, ... }.
local function breederEntriesIn(livestock, classKey)
    local list = {}
    for _, farmerEntry in ipairs(livestock.farmerEntries) do
        if farmerEntry.breeder ~= nil and farmerEntry.classKey == classKey then
            table.insert(list, farmerEntry)
        end
    end
    return list
end

test("188: the breeders enter their own animals in place of the farmers' rolls, and the ring's timetable has their classes", function()
    local world = setupBreeders(false)
    local livestock = world.tc.ShowLivestock
    local barn = addHusbandry(world, { clusters = { cluster("COW_HOLSTEIN", 1, 20, 100) } })
    announce(world)
    enter(world, 1, "COW_HOLSTEIN:young", barn)
    runToDay(world, CLOSE_DAY)
    local breeders = world.pen.breeders
    assertTrue(#breeders > 0, "breeders come")
    for _, breeder in ipairs(breeders) do
        assertTrue(breeder.farmerId ~= HOST_ID)
    end
    -- A breeder's entry is their own animal, in its own class; other
    -- farmers enter Best Kept Herd and (188) single animals for the row of
    -- pens, in the classes running, never a breeder.
    local classes, isBreeder = {}, {}
    for _, breeder in ipairs(breeders) do
        isBreeder[breeder.farmerId] = true
    end
    local rowEntries = {}
    for _, farmerEntry in ipairs(livestock.farmerEntries) do
        if farmerEntry.breeder ~= nil then
            local animal = breeders[farmerEntry.breeder].animals[farmerEntry.animal]
            assertEquals(farmerEntry.classKey, animal.classKey)
            assertEquals(farmerEntry.farmerId, breeders[farmerEntry.breeder].farmerId)
            assertTrue(farmerEntry.score ~= nil, "without RL a premium roll")
            classes[farmerEntry.classKey] = true
        elseif farmerEntry.classKey ~= TCShowClasses.HERD_KEY then
            assertTrue(not isBreeder[farmerEntry.farmerId], "not a breeder")
            assertTrue(farmerEntry.score ~= nil, "a farmer's roll")
            table.insert(rowEntries, farmerEntry)
        end
    end
    local others = 0
    for _, farmer in ipairs(world.tc.Farmers:getFarmers()) do
        if not isBreeder[farmer.id] then
            others = others + 1
        end
    end
    if others > 0 then
        assertTrue(#rowEntries > 0, "the row of pens filled")
    end
    assertTrue(#rowEntries <= TheContractorShowLivestock.getPensPerRow())
    for _, farmerEntry in ipairs(rowEntries) do
        assertTrue(classes[farmerEntry.classKey] or farmerEntry.classKey == "COW_HOLSTEIN:young",
            "in a class running")
    end
    -- The timetable: the players' class, the breeders' classes, the
    -- champions after their types', the herd last, from 10:00.
    local timetable = livestock.timetable
    assertTrue(TCShowRing.findSlot(timetable, "COW_HOLSTEIN:young") ~= nil)
    for classKey in pairs(classes) do
        assertTrue(TCShowRing.findSlot(timetable, classKey) ~= nil, classKey .. " runs")
    end
    assertEquals(timetable[1].from, TCShowRing.START_MINUTE)
    assertEquals(timetable[#timetable].key, TCShowClasses.HERD_KEY)
    assertTrue(#timetable <= TCShowRing.MAX_SLOTS)
    local _, champion = TCShowRing.findSlot(timetable, TCShowClasses.getChampionKey("COW"))
    local _, adult = TCShowRing.findSlot(timetable, "COW_HOLSTEIN:adult")
    assertTrue(champion ~= nil and adult ~= nil and champion > adult, "the champion after its type's classes")
    -- Every machine has which animal's in which class, never a score.
    local stream = world:newStream()
    TheContractorShowLivestock.writeState(stream, livestock)
    local state = TheContractorShowLivestock.readState(stream)
    local count = 0
    for _, farmerEntry in ipairs(livestock.farmerEntries) do
        if farmerEntry.breeder ~= nil then
            count = count + 1
        end
    end
    assertEquals(#state.breederEntries, count)
    assertEquals(state.breederEntries[1].score, nil)
    assertEquals(#state.timetable, #timetable)
end)

test("188: no room for breeders: the farmers enter as 167 had it", function()
    local world = setup(false)
    world:load("src/util/TCVehicleIds.lua")
    world:load("src/util/TCBreedersPen.lua")
    world:load("src/business/BreedersPen.lua")
    world:load("src/events/TCBreedersPenEvent.lua")
    RealisticLivestockAPI = nil
    local pen = TheContractorBreedersPen.new()
    pen:register(world.tc.Show)
    world.tc.BreedersPen = pen
    local barn = addHusbandry(world, { clusters = { cluster("COW_HOLSTEIN", 1, 20, 100) } })
    announce(world)
    enter(world, 1, "COW_HOLSTEIN:young", barn)
    runToDay(world, CLOSE_DAY)
    assertEquals(#pen.breeders, 0, "a 120 x 60 m showground has no room")
    local rolled = 0
    for _, farmerEntry in ipairs(world.tc.ShowLivestock.farmerEntries) do
        assertEquals(farmerEntry.breeder, nil)
        if farmerEntry.classKey == "COW_HOLSTEIN:young" then
            rolled = rolled + 1
        end
    end
    assertTrue(rolled > 0, "farmers in the player's class")
end)

test("188: the ring: a class's breeders' animals in the line with the player's, placed in order, their rosettes on the breeder's pen, held till it's over", function()
    local world = setupBreeders(false)
    local livestock = world.tc.ShowLivestock
    local barn = addHusbandry(world, { clusters = { cluster("COW_HOLSTEIN", 1, 20, 100) } })
    announce(world)
    local heifer = enter(world, 1, "COW_HOLSTEIN:young", barn)
    runToDay(world, SHOW_DAY)
    addTrailer(world, { cluster("COW_HOLSTEIN", 1, 20, 100) }, { farmId = 1, bay = 1 })
    assertTrue(world.scene.breeders ~= nil and #world.scene.breeders == #world.pen.breeders, "their pens laid out")
    setHour(world, 8)
    assertTrue(world.pen.present, "the breeders' animals in their pens with the gates open")
    local display = livestock:getDisplay()
    local shown = 0
    for index, breeder in ipairs(world.pen.breeders) do
        shown = shown + #display.breeders[index].animals
        assertEquals(#display.breeders[index].animals, #breeder.animals)
    end
    assertTrue(shown > 0)

    local breederEntries = breederEntriesIn(livestock, "COW_HOLSTEIN:young")
    assertTrue(#breederEntries > 0)
    local mine = breederEntries[1]
    local slot = TCShowRing.findSlot(livestock.timetable, "COW_HOLSTEIN:young")
    assertEquals(livestock:getHeldUntil(mine.breeder, mine.animal), slot.to, "held till its class is over")

    setHour(world, 10)
    assertEquals(livestock.timetable[livestock.ring.slot].key, "COW_HOLSTEIN:young")
    local fromRow = 0
    for _, farmerEntry in ipairs(livestock.farmerEntries) do
        if farmerEntry.breeder == nil and farmerEntry.pen ~= nil and farmerEntry.classKey == "COW_HOLSTEIN:young" then
            fromRow = fromRow + 1
        end
    end
    assertEquals(#livestock.ring.lineup, 1 + #breederEntries + fromRow, "the player's, the breeders' and the row's")
    display = livestock:getDisplay()
    assertEquals(#display.ring, #livestock.ring.lineup)
    for _, animal in ipairs(display.breeders[mine.breeder].animals) do
        assertTrue(animal.id ~= mine.animal, "a breeder's in the ring isn't in their pen")
    end

    placeClass(world, "COW_HOLSTEIN:young")
    -- The player's healthy heifer in its prime beats the premium rolls.
    assertEquals(heifer.placing, 1)
    assertEquals(mine.placing, 2)
    local first = livestock.ring.lineup[1]
    assertEquals(first.entry, heifer, "the line stood in placing order")
    display = livestock:getDisplay()
    assertEquals(display.breeders[mine.breeder].rosettes[1], TCShowScene.ROSETTE_COLOURS[2])

    setMinute(world, slot.to)
    assertEquals(livestock:getHeldUntil(mine.breeder, mine.animal), nil, "for sale once its class is over")
    display = livestock:getDisplay()
    local back = false
    for _, animal in ipairs(display.breeders[mine.breeder].animals) do
        back = back or animal.id == mine.animal
    end
    assertTrue(back, "back in its pen")

    -- A client has the breeders' placings and the ring, never a score.
    setMinute(world, TCShowRing.findSlot(livestock.timetable, "COW_HOLSTEIN:adult").from)
    local stream = world:newStream()
    TheContractorShowLivestock.writeState(stream, livestock)
    local client = TheContractorShowLivestock.new()
    client:applyState(TheContractorShowLivestock.readState(stream))
    assertTrue(client.ring ~= nil)
    assertEquals(#client.ring.lineup, #livestock.ring.lineup)
    local copy = nil
    for _, entry in ipairs(client.breederEntries) do
        if entry.breeder == mine.breeder and entry.animal == mine.animal then
            copy = entry
        end
    end
    assertEquals(copy.placing, 2)
    assertEquals(copy.score, nil)

    -- Saved mid-class: the ring and the timetable come back.
    local xml = {}
    livestock:saveToXmlFile(xml)
    local loaded = TheContractorShowLivestock.new()
    loaded:loadFromXMLFile(xml)
    assertEquals(#loaded.timetable, #livestock.timetable)
    assertEquals(loaded.ring.slot, livestock.ring.slot)
    assertEquals(#loaded.ring.lineup, #livestock.ring.lineup)
    for i, item in ipairs(loaded.ring.lineup) do
        if item.breeder ~= nil then
            assertTrue(item.farmerEntry ~= nil, "back to its entry, for its placing")
            assertEquals(item.animal, livestock.ring.lineup[i].animal)
        end
    end
    local savedEntry = nil
    for _, farmerEntry in ipairs(loaded.farmerEntries) do
        if farmerEntry.breeder == mine.breeder and farmerEntry.animal == mine.animal then
            savedEntry = farmerEntry
        end
    end
    assertEquals(savedEntry.placing, 2, "placings rebuilt from the saved scores")

    -- At 16:00 the breeders' placings are in the results under their breeds.
    setHour(world, 16)
    local heifers = placingsFor(world, "COW_HOLSTEIN:young")
    assertEquals(heifers[1].farmId, 1)
    assertEquals(heifers[2].farmerId, mine.farmerId)
    assertTrue(heifers[2].entrant ~= "", "named by its breed")
end)

test("188: with RL, a breeder's entry is judged on the real animal in their trailer; one sold or sick before its class is out", function()
    local world = setupBreeders(true)
    local livestock = world.tc.ShowLivestock
    announce(world)
    runToDay(world, CLOSE_DAY)
    for _, farmerEntry in ipairs(livestock.farmerEntries) do
        if farmerEntry.breeder ~= nil then
            assertTrue(farmerEntry.real, "to be judged on the animal")
            assertEquals(farmerEntry.score, nil)
        end
    end
    runToDay(world, SHOW_DAY)
    assertTrue(world.pen:hasSales(), "their stock out in trailers")
    for _, breeder in ipairs(world.pen.breeders) do
        assertEquals(#breeder.trailerIds, 1)
    end
    local first = livestock.timetable[1].key
    local entries = breederEntriesIn(livestock, first)
    assertTrue(#entries >= 1)
    -- One of them sold out of the trailer beforehand (marked sold).
    local soldEntry = entries[1]
    world.pen.breeders[soldEntry.breeder].animals[soldEntry.animal].sold = true
    setHour(world, 10)
    assertTrue(soldEntry.out and soldEntry.score == nil, "sold: out")
    for i = 2, #entries do
        assertTrue(entries[i].score ~= nil, "judged on the animal")
        assertTrue(entries[i].eye ~= nil)
    end
end)
