-- 107: trees down across roads after bad weather, on the real random
-- events framework (068), Jobs, Allocation, JobGeneration and the job map
-- markers. The engine's trees are faked: g_treePlantManager plants a shape
-- and keeps vanilla's loadTreeTrunkDatas queue, world:runVanillaCut does
-- what updateTrees does with an entry, overlapBox finds the fake shapes and
-- obstacles inside its rotated box, and the road splines are straight
-- lines. Checks where they come down (2-4, apart, round the first), the
-- fall and the job offer (priced per tree), accepting (allocated to the
-- players), a marker on each tree, cutting on the sites, the roads
-- clearing, declining, lapsing and missing (the council clears them), and
-- a load mid-fall.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    FarmManager.SPECTATOR_FARM_ID = 0
    Environment = { PERIODS_IN_YEAR = 12 }
    g_currentMission.environment = {
        currentYear = 1, currentPeriod = 3, currentDayInPeriod = 4, daysPerPeriod = 10, plannedDaysPerPeriod = 10,
        currentMonotonicDay = 24, currentHour = 8, dayTime = 8 * 3600000,
        getPeriodFromDay = function(_, day) return 3 end,
        getDayInPeriodFromDay = function(_, day) return 4 + day - 24 end,
    }
    g_farmManager.getFarmById = function(_, farmId) return { farmId = farmId } end
    g_farmManager.getFarmByUserId = function() return { farmId = 1 } end
    world.farms = { { farmId = 1 } }
    g_currentMission.playerNickname = "Sam"
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TCJobConsequences = {
        saveToXML = function() end,
        loadFromXML = function() end,
        writeReports = function() end,
        readReports = function() return {} end,
        applyOnCompletion = function() end,
    }
    TCVehicleIds = { saveList = function() end, loadList = function() return {} end }
    math.clamp = math.clamp or function(value, low, high)
        return math.max(low, math.min(high, value))
    end
    table.hasElement = table.hasElement or function(list, value)
        for _, element in ipairs(list) do
            if element == value then
                return true
            end
        end
        return false
    end

    -- Engine: shapes are { split, rigid, x, z }; obstacles (walls, standing
    -- trees, vehicles) are static things in the way, { x, z }. Both by id.
    world.shapes = {}
    world.obstacles = {}
    world.nextId = 100
    function world:addShape(def)
        local id = self.nextId
        self.nextId = self.nextId + 1
        self.shapes[id] = { split = def.split ~= false, rigid = def.rigid or "dynamic", x = def.x or 0, z = def.z or 0 }
        return id
    end
    function world:addObstacle(x, z)
        local id = self.nextId
        self.nextId = self.nextId + 1
        self.obstacles[id] = { x = x, z = z }
        return id
    end
    ClassIds = { MESH_SPLIT_SHAPE = "splitShape" }
    RigidBodyType = { STATIC = "static", DYNAMIC = "dynamic", KINEMATIC = "kinematic" }
    CollisionFlag = { STATIC_OBJECT = 1, BUILDING = 2, TREE = 4, VEHICLE = 8, DYNAMIC_OBJECT = 16,
        TRAFFIC_VEHICLE = 32, PLAYER = 64 }
    WeatherType = { SUN = 1, PARTIALLY_CLOUDY = 2, CLOUDY = 3, RAIN = 4 }
    entityExists = function(id)
        return world.shapes[id] ~= nil
    end
    getHasClassId = function(id, classId)
        return classId == ClassIds.MESH_SPLIT_SHAPE and world.shapes[id] ~= nil
    end
    getIsSplitShapeSplit = function(id)
        return world.shapes[id].split
    end
    getRigidBodyType = function(id)
        return world.shapes[id].rigid
    end
    world.deleted = {}
    delete = function(id)
        world.shapes[id] = nil
        table.insert(world.deleted, id)
    end
    g_terrainNode = 1
    -- The ground: flat at 50, or world.groundAt(x, z).
    getTerrainHeightAtWorldPos = function(_, x, _, z)
        return world.groundAt ~= nil and world.groundAt(x, z) or 50
    end
    MathUtil = {
        getYRotationFromDirection = function(dx, dz)
            return math.atan2(dx, dz)
        end,
    }
    world.overlaps = {}
    overlapBox = function(x, y, z, rx, ry, rz, ex, ey, ez, callback, target, mask, dynamics, kinematics, statics)
        table.insert(world.overlaps, { mask = mask, statics = statics })
        local sinY, cosY = math.sin(ry), math.cos(ry)
        local function inside(point)
            local dx, dz = point.x - x, point.z - z
            return math.abs(dx * sinY + dz * cosY) <= ez and math.abs(dx * cosY - dz * sinY) <= ex
        end
        local ids = {}
        for id, shape in pairs(world.shapes) do
            if shape.rigid ~= "static" or statics then
                table.insert(ids, id)
            end
        end
        if statics then
            for id in pairs(world.obstacles) do
                table.insert(ids, id)
            end
        end
        table.sort(ids)
        for _, id in ipairs(ids) do
            if inside(world.shapes[id] or world.obstacles[id]) then
                if not target[callback](target, id) then
                    return
                end
            end
        end
    end
    getSaveableSplitShapeId = function(id)
        return id * 10, 7, 9
    end
    world.dirtied = 0
    g_densityMapHeightManager = { setCollisionMapAreaDirty = function() world.dirtied = world.dirtied + 1 end }
    g_currentMission.aiSystem = {
        setAreaDirty = function() end,
        getRoadSplines = function()
            local splines = {}
            for _, spline in ipairs(world.splines) do
                splines[spline] = true
            end
            return splines
        end,
    }
    world.hasCutPermission = true
    g_currentMission.getHasPlayerPermission = function(_, permission)
        return permission == "cutTrees" and world.hasCutPermission
    end

    -- Road splines: straight lines { x1, z1, x2, z2, y }.
    world.splines = {}
    getSplineLength = function(spline)
        return math.sqrt((spline.x2 - spline.x1) ^ 2 + (spline.z2 - spline.z1) ^ 2)
    end
    getSplinePosition = function(spline, t)
        return spline.x1 + (spline.x2 - spline.x1) * t, spline.y or 50, spline.z1 + (spline.z2 - spline.z1) * t
    end
    getSplineDirection = function(spline)
        local length = getSplineLength(spline)
        return (spline.x2 - spline.x1) / length, 0, (spline.z2 - spline.z1) / length
    end

    -- Players: none about unless added.
    world.players = {}
    g_currentMission.playerSystem = {
        getPlayerCount = function() return #world.players end,
        getPlayerByIndex = function(_, i)
            local point = world.players[i]
            return { getPosition = function() return point.x, 50, point.z end }
        end,
    }

    -- Vanilla's trees: a node is a shape's id + 1000.
    SplitShapeUtil = {
        getSplitShapeId = function(node)
            return node - 1000
        end,
    }
    TreePlantManager = { cutTreeTrunkCallback = function() end }
    world.canPlant = true
    world.planted = {}
    g_treePlantManager = {
        loadTreeTrunkDatas = {},
        nameToTreeType = {
            BEECH = { index = 1, name = "BEECH", stages = { { {} }, { {}, {} }, { {}, {} } } },
        },
        getTreeTypeDescFromName = function(self, name)
            return name ~= nil and self.nameToTreeType[string.upper(name)] or nil
        end,
        canPlantTree = function()
            return world.canPlant
        end,
        plantTree = function(_, typeIndex, x, y, z, rx, ry, rz, stage, variation, isGrowing)
            local shape = world:addShape({ split = false, rigid = "static", x = x, z = z })
            table.insert(world.planted, { typeIndex = typeIndex, x = x, y = y, z = z, stage = stage,
                variation = variation, isGrowing = isGrowing, shape = shape })
            return shape + 1000
        end,
    }
    -- What updateTrees does with an entry: the stump goes, and the rest (a
    -- new shape) lies along the fall, its middle 15 m out.
    function world:runVanillaCut(entry, noTrunk)
        for i, queued in ipairs(g_treePlantManager.loadTreeTrunkDatas) do
            if queued == entry then
                table.remove(g_treePlantManager.loadTreeTrunkDatas, i)
                break
            end
        end
        self.shapes[entry.shape] = nil
        entry.parts = {}
        if noTrunk then
            return nil
        end
        local trunk = self:addShape({ x = entry.x + entry.dirX * 6, z = entry.z + entry.dirZ * 6 })
        table.insert(entry.parts, { shape = trunk, isBelow = false })
        return trunk
    end

    -- Vanilla's cut check, before ours: no on land the farm can't use.
    world.vanillaCutAllowed = false
    SplitShapeManager = {
        getIsShapeCutAllowed = function()
            return world.vanillaCutAllowed
        end,
    }

    g_time = 0
    g_localPlayer = {
        getPosition = function() return 0, 50, 0 end,
        getCurrentFacingDirection = function() return 0, 1 end,
    }

    -- Fields, by id: { x, z } centres.
    world.fields = {}
    function world:addField(id, x, z)
        self.fields[id] = { getId = function() return id end, getName = function() return tostring(id) end,
            getCenterOfFieldWorldPosition = function() return x, z end, getAreaHa = function() return 1 end,
            getFieldState = function() return {} end }
    end
    g_fieldManager = {
        getFieldById = function(_, fieldId) return world.fields[fieldId] end,
        getFields = function()
            local result = {}
            for _, field in pairs(world.fields) do
                table.insert(result, field)
            end
            table.sort(result, function(a, b) return a:getId() < b:getId() end)
            return result
        end,
    }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCEquipmentClass.lua")
    world:load("src/business/Allocation.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/FallenTree.lua")
    TCJobProgress = { POLL_INTERVAL_MS = 3000, clearJob = function() end }
    world:load("src/util/TCHaulage.lua")

    world.prepared = {}
    TCFieldPreparation = {
        prepareFieldForJob = function(job) table.insert(world.prepared, job.id) end,
        clearUpAfterJob = function() end,
    }
    TCFieldAccess = { refresh = function() end }
    TCJobSupplies = { topUp = function() end }
    TCJobAllocatedEvent = { new = function(job) return { job = job } end }
    TCHaulage.emptyHarvestersAfterJob = function() end
    TCRandomEventIncidentEvent = {
        new = function(incident, isClosed) return { incident = incident, isClosed = isClosed } end,
    }
    world.broadcasts = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.broadcasts, event) end }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Contracting" } }
    tc.Jobs = TheContractorJobs.new()
    tc.Allocation = TheContractorAllocation.new()
    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.Staff = { getWorker = function() return nil end, applyGrowthFromJob = function() end }
    tc.Dispatch = {
        isJobActive = function() return false end,
        stopJob = function() end,
        takeRanOutOfFill = function() end,
    }
    tc.Cooldown = { startCooldown = function() end }
    tc.Parking = { returnVehicles = function() end, returnHiddenVehicles = function() end,
        isPending = function() return false end, sendToShop = function() return {} end }
    world.reputation = {}
    world:addRelationships()
    tc.Reputation = {
        addReputation = function(_, farmId, delta) table.insert(world.reputation, delta) end,
        getStanding = function() return 0.5 end,
    }
    world.invoiced = {}
    tc.Finances = { invoiceJob = function(_, job) table.insert(world.invoiced, job.paymentAmount) end }
    tc.Association = { getReputationBonus = function() return 0 end }
    tc.Claims = { rollForJob = function() end }
    tc.Logbook = {
        recordJobCompleted = function() end,
        recordJobMissed = function() end,
        onCrewChanged = function() end,
    }
    world.messages = {}
    tc.Inbox = {
        registerMessageKind = function(_, kind, definition) world.messageKind = definition end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
            table.insert(world.messages, { kind = kind, titleKey = titleKey, bodyKey = bodyKey, args = args,
                payload = payload })
            return #world.messages
        end,
        removeMessagesForJob = function() end,
    }
    TCJobMissedEvent = { showNotification = function() end, new = function() return {} end }
    TCJobCompletedEvent = { showNotification = function() end, new = function() return {} end }
    TCJobStateChangedEvent = { new = function() return {} end }
    TCJobCreatedEvent = { new = function() return {} end }
    AIMessageSuccessFinishedJob = { new = function() return {} end }
    AIMessageSuccessStoppedByUser = { new = function() return {} end }

    tc.FallenTree = TheContractorFallenTree.new()
    tc.FallenTree:register(tc.RandomEvents, tc.Inbox)
    -- Three trees every time (the console rolls with math.random), unless a
    -- test puts the real range back.
    world.treeRange = { TheContractorFallenTree.TREES_MIN, TheContractorFallenTree.TREES_MAX }
    TheContractorFallenTree.TREES_MIN = 3
    TheContractorFallenTree.TREES_MAX = 3

    TCConsole.reset()
    TheContractorRandomEvents.registerConsoleCommands()
    function world:console(...)
        return TCConsole.dispatch(TCConsole.groups.event, { "trigger", "fallenTree", ... })
    end

    -- Three roads running north from z = -100 to 100, along x = 0, 400 and
    -- 800, each with a field to its east: 12, 20 and 30.
    table.insert(world.splines, { x1 = 0, z1 = -100, x2 = 0, z2 = 100 })
    table.insert(world.splines, { x1 = 400, z1 = -100, x2 = 400, z2 = 100 })
    table.insert(world.splines, { x1 = 800, z1 = -100, x2 = 800, z2 = 100 })
    world:addField(12, 60, 0)
    world:addField(20, 460, 0)
    world:addField(30, 860, 0)

    function world:getIncident()
        for _, incident in pairs(tc.RandomEvents.incidents) do
            return incident
        end
        return nil
    end

    -- Moves the game clock on and runs the tree's update.
    function world:tick(ms)
        g_time = g_time + ms
        tc.FallenTree:update(ms)
    end

    return world, tc
end

local function rolls(values)
    local i = 0
    return function()
        i = i + 1
        return values[i] or 0.5
    end
end

-- Down and offered: triggered from the console, planted, cut by vanilla.
-- The incident, each tree's trunk (by its number) and the job.
local function fellTrees(world, tc, ...)
    world:console(...)
    local incident = world:getIncident()
    assertTrue(incident ~= nil, "opened")
    world:tick(TheContractorFallenTree.CUT_DELAY_MS)
    local trunks = {}
    for i, treeFall in pairs(tc.FallenTree.pendingFalls[incident.id].trees) do
        trunks[i] = world:runVanillaCut(treeFall.entry)
    end
    world:tick(16)
    return incident, trunks, tc.Jobs:getJob(1, incident.data.jobId)
end

local function accept(tc, job)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED, "Sam")
end

local function distance(a, b)
    return math.sqrt((a.roadX - b.roadX) ^ 2 + (a.roadZ - b.roadZ) ^ 2)
end

-- Where ---------------------------------------------------------------------------------

test("the tree's base is on the verge and it falls across the road", function()
    setup()
    -- Heading north, on the right (east): the base 6 m east, falling west.
    local placement = TheContractorFallenTree.getPlacement(0, 0, 0, 1, 1)
    assertNear(placement.x, 6, 1e-9)
    assertNear(placement.z, 0, 1e-9)
    assertNear(placement.dirX, -1, 1e-9)
    assertNear(placement.dirZ, 0, 1e-9)
    placement = TheContractorFallenTree.getPlacement(0, 0, 0, 1, -1)
    assertNear(placement.x, -6, 1e-9, "the left")
    assertNear(placement.dirX, 1, 1e-9)

    -- Here: the player's view is the road, 8 m ahead.
    placement = TheContractorFallenTree.getHerePlacement(0, 0, 0, 2)
    assertNear(placement.roadX, 0, 1e-9)
    assertNear(placement.roadZ, 8, 1e-9)
    assertNear(placement.x, -6, 1e-9, "from their left")
    assertNear(placement.dirX, 1, 1e-9)
end)

test("a road spot needs room, flat ground, no bridge, nobody about and a field nearby", function()
    local world, tc = setup()
    world.splines = { world.splines[1] }
    local function find()
        return tc.FallenTree:findRoadSpots(rolls({}), 1)[1]
    end
    local spot = find()
    assertTrue(spot ~= nil, "the road's fine")
    assertEquals(spot.fieldId, 12)
    assertEquals(math.abs(spot.x), 6)

    world.splines[1].y = 55
    assertEquals(find(), nil, "a bridge: the road 5 m over the ground")
    world.splines[1].y = 50

    world.players = { { x = 100, z = 0 } }
    assertEquals(find(), nil, "a player within 150 m of all of it")
    world.players = { { x = 400, z = 0 } }
    assertTrue(find() ~= nil)

    -- Rising ground on both sides of the road.
    world.groundAt = function(x, z)
        return math.abs(x) < 7 and 50 or 51
    end
    assertEquals(find(), nil, "the ground rises along the fall")
    world.groundAt = nil

    -- A wall along both verges, 10 m out.
    for z = -100, 100, 2 do
        world:addObstacle(10, z)
        world:addObstacle(-10, z)
    end
    assertEquals(find(), nil, "something in the trunk's way")
    world.obstacles = {}

    world.fields = {}
    world:addField(40, 3000, 0)
    assertEquals(find(), nil, "no field within 2 km to name it by")
end)

test("2 to 4 trees, each on its own stretch of road, round the first", function()
    local world, tc = setup()
    TheContractorFallenTree.TREES_MIN, TheContractorFallenTree.TREES_MAX = world.treeRange[1], world.treeRange[2]
    -- Four roads 250 m apart: room for four trees, all within 1 km.
    world.splines = {}
    for x = 0, 750, 250 do
        table.insert(world.splines, { x1 = x, z1 = -100, x2 = x, z2 = 100 })
    end
    for roll, wanted in pairs({ [0] = 2, [0.5] = 3, [0.99] = 4 }) do
        local data = tc.FallenTree:pickSpot(1, rolls({ roll }))
        assertEquals(data.treeCount, wanted, "roll " .. roll)
        local trees = TheContractorFallenTree.getTrees(data)
        for i = 1, #trees do
            for j = i + 1, #trees do
                assertTrue(distance(trees[i], trees[j]) >= TheContractorFallenTree.TREE_SEPARATION,
                    string.format("trees %d and %d %.0f m apart", i, j, distance(trees[i], trees[j])))
            end
        end
    end

    -- Nowhere near the first, so none.
    local far = { roadX = 5000, roadZ = 0 }
    assertEquals(#tc.FallenTree:findRoadSpots(rolls({}), 3, { far }), 0, "all over 1 km from the first")

    -- Only one stretch of road free: not enough for the event.
    world.splines = { { x1 = 0, z1 = -50, x2 = 0, z2 = 50 } }
    assertEquals(tc.FallenTree:pickSpot(1, rolls({})), nil, "one tree's too few")
end)

test("the spot's data: fully grown beeches, their roads, the fields", function()
    local world, tc = setup()
    local data = tc.FallenTree:pickSpot(1, rolls({}))
    assertEquals(data.treeType, "BEECH")
    assertEquals(data.stage, 3, "fully grown")
    assertEquals(data.treeCount, 3)
    assertEquals(data.jobId, 0)
    local fields = {}
    for _, tree in ipairs(TheContractorFallenTree.getTrees(data)) do
        assertTrue(tree.variation >= 1 and tree.variation <= 2)
        assertNear(tree.y, 51, 1e-9, "the ground plus SPAWN_HEIGHT")
        assertEquals(tree.isClear, false)
        assertEquals(tree.shapeId1, 0)
        fields[tree.fieldId] = true
        assertEquals(data[string.format("tree%d_roadX", tree.index)], tree.roadX, "flat in the data")
    end
    assertEquals(data.fieldId, data.tree1_fieldId, "the job's field is the first tree's")
    assertTrue(fields[12] and fields[20] and fields[30], "one by each field")

    -- One at a time per farm.
    world:console()
    assertEquals(tc.FallenTree:pickSpot(1, rolls({})), nil)
end)

test("the console: on the roads, or the first here in front of the player, and nothing else", function()
    local world, tc = setup()
    world:console("there")
    assertEquals(world:getIncident(), nil, "only 'here' is taken")
    world:console("here")
    local data = world:getIncident().data
    assertNear(data.tree1_roadZ, 8, 1e-9, "8 m ahead")
    assertTrue(data.treeCount >= 2, "the rest elsewhere")
    assertEquals(tc.FallenTree.consoleHere, false, "cleared")
end)

-- Coming down ------------------------------------------------------------------------------

test("planted, then cut a few seconds later so every client has the trees first", function()
    local world, tc = setup()
    world:console()
    local incident = world:getIncident()
    assertEquals(incident.stage, "falling")
    assertEquals(#world.planted, incident.data.treeCount)
    local planted = world.planted[2]
    assertEquals(planted.stage, 3)
    assertEquals(planted.isGrowing, false)
    assertNear(planted.x, incident.data.tree2_x, 1e-9)

    world:tick(TheContractorFallenTree.CUT_DELAY_MS - 1)
    assertEquals(#g_treePlantManager.loadTreeTrunkDatas, 0, "not yet")
    world:tick(1)
    assertEquals(#g_treePlantManager.loadTreeTrunkDatas, incident.data.treeCount, "one cut each")
    local entry = g_treePlantManager.loadTreeTrunkDatas[2]
    assertEquals(entry.shape, planted.shape)
    assertEquals(entry.delimb, false, "crown kept")
    assertEquals(entry.length, TheContractorFallenTree.TRUNK_LENGTH)
    assertNear(entry.dirX, incident.data.tree2_dirX, 1e-9)
    assertEquals(entry.cutTreeTrunkCallback, TreePlantManager.cutTreeTrunkCallback)

    world:runVanillaCut(g_treePlantManager.loadTreeTrunkDatas[1])
    world:tick(16)
    assertEquals(incident.stage, "falling", "still waiting for vanilla's other cuts")
end)

test("down: one job for them all, due today, at the council's price per tree", function()
    local world, tc = setup()
    local incident, trunks, job = fellTrees(world, tc)
    assertEquals(incident.stage, "open")
    assertEquals(incident.data.treeCount, 3)
    assertEquals(incident.data.tree1_shapeId1, trunks[1] * 10)
    assertEquals(incident.data.tree3_shapeId1, trunks[3] * 10)
    assertEquals(job.jobType, "fallenTree")
    assertEquals(job.state, TheContractorJob.STATE.OFFERED)
    assertEquals(job.fieldId, incident.data.tree1_fieldId)
    assertEquals(job.deadlineDay, 24, "today")
    assertTrue(job:getPrice() >= 3750 and job:getPrice() <= 5250, tostring(job:getPrice()))
    local fieldName = tostring(job.fieldId)
    assertEquals(job:getListFieldText(), "-", "a list's Field column")

    local message = world.messages[1]
    assertEquals(message.kind, "fallenTree")
    assertEquals(message.args[1], fieldName)
    assertEquals(message.args[2], "3")
    assertEquals(message.args[3], TheContractorFallenTree.getFieldNames(incident.data))
    assertEquals(message.args[4], "$money_" .. math.floor(job:getPrice()))
    assertEquals(message.payload.jobId, job.id)
    assertEquals(world.messageKind.endsWithJob, true)
    assertTrue(world.dirtied > 0, "their whole lengths marked")
end)

test("the price: 2,500-3,500 for two trees at the default pay rate, the same again per tree, and the pay rate setting scales it", function()
    local world, tc = setup()
    assertEquals(TheContractorFallenTree.getBasePrice(0, 2), 2500)
    assertEquals(TheContractorFallenTree.getBasePrice(1, 2), 3500)
    assertEquals(TheContractorFallenTree.getBasePrice(0, 3), 3750)
    assertEquals(TheContractorFallenTree.getBasePrice(1, 4), 7000)
    tc.Settings.values.jobPayRate = 200
    assertEquals(TheContractorFallenTree.getBasePrice(0, 2), 5000)
    assertEquals(TheContractorFallenTree.getBasePrice(1, 2), 7000)
end)

test("the field names: each once, in the trees' order", function()
    setup()
    local data = {}
    TheContractorFallenTree.setTrees(data, { { fieldId = 20 }, { fieldId = 12 }, { fieldId = 20 } })
    assertEquals(TheContractorFallenTree.getFieldNames(data), "20, 12")
    TheContractorFallenTree.setTrees(data, { { fieldId = 30 } })
    assertEquals(data.treeCount, 1)
    assertEquals(data.tree2_fieldId, nil, "the old ones gone")
end)

test("a tree that leaves no trunk is dropped and the rest renumbered, priced for what came down", function()
    local world, tc = setup()
    world:console()
    local incident = world:getIncident()
    local thirdRoadX = incident.data.tree3_roadX
    world:tick(TheContractorFallenTree.CUT_DELAY_MS)
    local trees = tc.FallenTree.pendingFalls[incident.id].trees
    world:runVanillaCut(trees[1].entry)
    world:runVanillaCut(trees[2].entry, true)
    world:runVanillaCut(trees[3].entry)
    world:tick(16)
    assertEquals(incident.data.treeCount, 2)
    assertEquals(incident.data.tree2_roadX, thirdRoadX, "the third is now the second")
    assertEquals(incident.data.tree3_roadX, nil)
    local job = tc.Jobs:getJob(1, incident.data.jobId)
    assertTrue(job:getPrice() >= 2500 and job:getPrice() <= 3500, tostring(job:getPrice()))
    assertEquals(world.messages[1].args[2], "2")
end)

test("cuts that leave no trunk at all, or a full map, end it with nothing offered", function()
    local world, tc = setup()
    world:console()
    local incident = world:getIncident()
    world:tick(TheContractorFallenTree.CUT_DELAY_MS)
    for _, treeFall in pairs(tc.FallenTree.pendingFalls[incident.id].trees) do
        world:runVanillaCut(treeFall.entry, true)
    end
    world:tick(16)
    assertEquals(world:getIncident(), nil)
    assertEquals(#world.messages, 0)

    world.canPlant = false
    world:console()
    assertEquals(world:getIncident(), nil)
end)

-- Taken on -----------------------------------------------------------------------------

test("accepting allocates it to the players at once, under who accepted it", function()
    local world, tc = setup()
    local _, _, job = fellTrees(world, tc)
    accept(tc, job)
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED)
    assertEquals(job:getPlayerName(), "Sam")
    assertEquals(#world.prepared, 1, "prepared as any allocation is (the real one leaves an offField job alone)")
end)

test("each tree can be cut off the farm's land only once the job's taken on", function()
    local world, tc = setup()
    local incident, trunks, job = fellTrees(world, tc)
    local manager = setmetatable({}, { __index = SplitShapeManager })
    local first = TheContractorFallenTree.getTree(incident.data, 1)
    local third = TheContractorFallenTree.getTree(incident.data, 3)
    local x, z = first.x + first.dirX * 10, first.z + first.dirZ * 10
    local x3, z3 = third.x + third.dirX * 10, third.z + third.dirZ * 10

    TheContractorFallenTree.refreshSites()
    assertEquals(manager:getIsShapeCutAllowed(x, z, trunks[1], 1), false, "only offered")

    accept(tc, job)
    TheContractorFallenTree.refreshSites()
    assertEquals(manager:getIsShapeCutAllowed(x, z, trunks[1], 1), true)
    assertEquals(manager:getIsShapeCutAllowed(x3, z3, trunks[3], 1), true, "the third tree's site too")
    assertEquals(manager:getIsShapeCutAllowed(x, z, trunks[1], 2), false, "another farm's")
    local standing = world:addShape({ x = x, z = z, split = false, rigid = "static" })
    assertEquals(manager:getIsShapeCutAllowed(x, z, standing, 1), false, "a standing map tree")
    world.hasCutPermission = false
    assertEquals(manager:getIsShapeCutAllowed(x, z, trunks[1], 1), false, "no cutTrees permission")
    world.hasCutPermission = true
    assertEquals(manager:getIsShapeCutAllowed(first.x + first.dirX * 60, z, trunks[1], 1), false, "off the site")
end)

test("a marker on each tree's road once it's taken on, gone as that road clears", function()
    local world, tc = setup()
    world:load("src/util/TCJobHotspots.lua")
    world.shownSpots = {}
    AbstractFieldMissionHotspot = {
        new = function()
            local hotspot = {}
            function hotspot:setWorldRadius() end
            function hotspot:setWorldPosition(x, z) self.x, self.z = x, z end
            function hotspot:delete() end
            return hotspot
        end,
    }
    g_currentMission.hud = {}
    g_currentMission.getFarmId = function() return 1 end
    g_currentMission.addMapHotspot = function(_, hotspot) world.shownSpots[hotspot] = true end
    g_currentMission.removeMapHotspot = function(_, hotspot) world.shownSpots[hotspot] = nil end
    local function shown()
        local list = {}
        for hotspot in pairs(world.shownSpots) do
            table.insert(list, hotspot)
        end
        return list
    end

    local incident, trunks, job = fellTrees(world, tc)
    TCJobHotspots.refresh()
    assertEquals(#shown(), 0, "only offered")
    assertEquals(#TheContractorFallenTree.getJobSpots({ jobType = "plow", id = job.id }), 0, "another job type")

    accept(tc, job)
    TCJobHotspots.refresh()
    assertEquals(#shown(), 3, "one per tree")
    local positions = TCJobHotspots.getSpotPositions(1)
    for _, tree in ipairs(TheContractorFallenTree.getTrees(incident.data)) do
        local position = positions[job.id .. "_" .. tree.index]
        assertEquals(position.x, tree.roadX)
        assertEquals(position.z, tree.roadZ)
    end

    -- The second road cleared: its marker goes, the others stay put.
    world.shapes[trunks[2]] = nil
    local interval = TheContractorFallenTree.CHECK_INTERVAL_MS
    world:tick(interval)
    world:tick(interval)
    assertEquals(incident.data.tree2_isClear, true)
    TCJobHotspots.refresh()
    assertEquals(#shown(), 2)
    positions = TCJobHotspots.getSpotPositions(1)
    assertEquals(positions[job.id .. "_2"], nil)
    assertEquals(positions[job.id .. "_3"].x, incident.data.tree3_roadX)
end)

test("every road clear for two checks is the job done, and the wood stays", function()
    local world, tc = setup()
    local incident, trunks, job = fellTrees(world, tc)
    accept(tc, job)
    local interval = TheContractorFallenTree.CHECK_INTERVAL_MS
    local data = incident.data

    world:tick(interval)
    world:tick(interval)
    assertEquals(TheContractorFallenTree.countClear(data), 0, "the trunks are across the roads")
    assertEquals(TheContractorFallenTree.getJobCompletion(job), 0)

    -- The first cut up and stacked on the verge, 6 m off the road's middle.
    world.shapes[trunks[1]] = nil
    local log1 = world:addShape({ x = data.tree1_x, z = data.tree1_z + 2 })
    world:addShape({ x = data.tree1_x, z = data.tree1_z - 2 })
    world:tick(interval)
    assertEquals(data.tree1_isClear, false, "one check isn't enough")
    world:tick(interval)
    assertEquals(data.tree1_isClear, true)
    assertEquals(data.tree2_isClear, false)
    assertNear(TheContractorFallenTree.getJobCompletion(job), 1 / 3, 1e-9, "a third of the way")

    world.shapes[trunks[2]] = nil
    world.shapes[trunks[3]] = nil
    world:tick(interval)
    world:tick(interval)
    assertEquals(TheContractorFallenTree.getJobCompletion(job), 1)

    job.completionPercentage = 100
    tc.Jobs:completeJob(job)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(world.invoiced[1], job:getPrice())
    assertEquals(world.reputation[#world.reputation], 10)

    world:tick(interval)
    assertEquals(world:getIncident(), nil, "closed")
    assertTrue(world.shapes[log1] ~= nil, "the wood's still theirs")
end)

test("turned down: a little reputation lost, and the council clears them all", function()
    local world, tc = setup()
    local incident, trunks, job = fellTrees(world, tc)
    local away = world:addShape({ x = 500, z = 500 })
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    world:tick(TheContractorFallenTree.CHECK_INTERVAL_MS)
    assertEquals(world.reputation[1], -3)
    for i = 1, 3 do
        assertEquals(world.shapes[trunks[i]], nil, "tree " .. i .. " gone")
    end
    assertTrue(world.shapes[away] ~= nil, "a log somewhere else is left alone")
    assertEquals(world:getIncident(), nil)
end)

test("left to lapse at the day change: the same as turning it down", function()
    local world, tc = setup()
    local _, trunks, job = fellTrees(world, tc)
    g_currentMission.environment.currentMonotonicDay = 25
    tc.Jobs:onDayChanged()
    assertEquals(job.state, TheContractorJob.STATE.DECLINED)
    world:tick(TheContractorFallenTree.CHECK_INTERVAL_MS)
    assertEquals(world.reputation[1], -3)
    assertEquals(world.shapes[trunks[1]], nil)
end)

test("taken on and missed: the missed job penalty, and the council clears them", function()
    local world, tc = setup()
    local _, trunks, job = fellTrees(world, tc)
    accept(tc, job)
    g_currentMission.environment.currentMonotonicDay = 25
    tc.Jobs:onDayChanged()
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    world:tick(TheContractorFallenTree.CHECK_INTERVAL_MS)
    assertEquals(world.reputation[1], -15, "1.5 times its 10 reputation")
    assertEquals(world.shapes[trunks[3]], nil)
    assertEquals(world:getIncident(), nil)
end)

test("saved mid-fall: closed, with nothing offered", function()
    local world, tc = setup()
    world:console()
    local incident = world:getIncident()
    tc.FallenTree = TheContractorFallenTree.new()
    tc.FallenTree:register(tc.RandomEvents, tc.Inbox)
    world:tick(16)
    assertEquals(world:getIncident(), nil)
    assertEquals(#world.messages, 0)
end)

-- After bad weather -----------------------------------------------------------------------

test("a spell of bad weather ending rolls it, found the next hour in the morning", function()
    local world, tc = setup()
    local weather = { forecastItems = { {} }, type = WeatherType.RAIN }
    function weather:getCurrentWeatherType() return self.type end
    g_currentMission.environment.weather = weather

    tc.RandomEvents:checkWeather()
    assertEquals(#tc.RandomEvents.pendingTriggers, 0, "still raining")
    weather.type = WeatherType.CLOUDY
    math.randomseed(1)
    local hits = 0
    for _ = 1, 200 do
        tc.RandomEvents.pendingTriggers = {}
        tc.RandomEvents.wasBadWeather = true
        tc.RandomEvents:checkWeather()
        hits = hits + #tc.RandomEvents.pendingTriggers
    end
    assertTrue(hits > 10 and hits < 55, "about 15% of 200: " .. hits)

    tc.RandomEvents.pendingTriggers = {}
    tc.RandomEvents:onBadWeatherEnded(rolls({ 0.1 }))
    local pending = tc.RandomEvents.pendingTriggers[1]
    assertEquals(pending.eventType, "fallenTree")
    assertEquals(pending.day, 24)
    assertEquals(pending.hour, 9, "it cleared at 08:00")
end)
