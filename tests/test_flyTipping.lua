-- Fly-tipping (075) on the real random events framework (068), jobs and
-- job generation: which fields can be hit, the pile and its job, disposal
-- at a skip (counting, the tipping fee, held pieces), progress, clean-up
-- when the job's over or the offer is turned down, and the job's debris
-- through a save. The pieces themselves are faked: TCDebris.spawn makes
-- plain objects the fake item system can find by uniqueId. 148's roadside
-- piles: the roads are world.roads (FallenTree's samples, faked), the
-- ground world.groundAt, and overlapBox finds world.obstacles.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"

    -- Engine pieces the loaded files touch at load time.
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    PhysicsObject = {}
    InitObjectClass = function() end
    g_currentModName = "FS25_TheContractor"
    g_xmlManager = { addInitSchemaFunction = function() end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TCEquipmentClass = { getMissingEquipment = function() return {} end }
    TCJobConsequences = { saveToXML = function() end, loadFromXML = function() end }
    TCVehicleIds = { saveList = function() end, loadList = function() return {} end }

    Environment = { PERIODS_IN_YEAR = 12 }
    Season = { SPRING = 0, SUMMER = 1, AUTUMN = 2, WINTER = 3 }
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 5,
        currentDayInPeriod = 2,
        currentHour = 0,
        daysPerPeriod = 3,
        plannedDaysPerPeriod = 3,
        currentMonotonicDay = 40,
        getSeasonAtDay = function() return Season.SUMMER end,
        getPeriodFromDay = function() return 5 end,
        getDayInPeriodFromDay = function(_, day) return day % 3 + 1 end,
    }
    g_currentMission.missionInfo.economicDifficulty = 3
    g_farmManager.getFarmById = function(_, farmId) return { farmId = farmId } end

    FarmlandManager = { NO_OWNER_FARM_ID = 0 }
    FruitType = { UNKNOWN = 0, GRASS = 1 }
    -- Fields are in grass (cut at 9) unless a test says otherwise.
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index)
            return index == FruitType.GRASS and { getIsCut = function(_, state) return state == 9 end } or nil
        end,
    }
    FieldGroundType = { STUBBLE_TILLAGE = 2, CULTIVATED = 3, PLOWED = 5 }

    -- Fields: def { id, owner, noBoundary }. A 40 x 40 m square from
    -- (0, -20) to (40, 20), its gate just outside the left edge at (-5, 0),
    -- its middle at (20, 0).
    world.fields, world.protected = {}, {}
    local squareNodes = { { 0, -20 }, { 40, -20 }, { 40, 20 }, { 0, 20 } }
    getWorldTranslation = function(node)
        return node[1], 0, node[2]
    end
    function world:addField(def)
        local field = { id = def.id, owner = def.owner or 0, nodes = def.noBoundary and {} or squareNodes }
        function field:getPolygonPoints() return self.nodes end
        function field:getId() return self.id end
        function field:getOwner() return self.owner end
        function field:getAreaHa() return 2 end
        field.fieldState = { isValid = true, fruitTypeIndex = FruitType.GRASS, growthState = 3 }
        function field:getFieldState() return self.fieldState end
        function field:getPlannedFruitTypeIndex() return nil end
        function field:getTeleportPosition() return -5, 0 end
        function field:getCenterOfFieldWorldPosition() return 20, 0 end
        table.insert(self.fields, field)
        return field
    end
    g_fieldManager = {
        getFields = function() return world.fields end,
        getFieldById = function(_, fieldId)
            for _, field in ipairs(world.fields) do
                if field.id == fieldId then
                    return field
                end
            end
            return nil
        end,
    }

    -- Items by uniqueId (the pile's pieces).
    world.items = {}
    g_currentMission.itemSystem = {
        getItemByUniqueId = function(_, uniqueId) return world.items[uniqueId] end,
    }
    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end
    g_currentMission.getNodeObject = function(_, node) return world.nodeObjects[node] end
    world.nodeObjects = {}
    -- Players' hands: world.held = the node one of them is holding.
    g_currentMission.playerSystem = {
        getPlayerCount = function() return 1 end,
        getPlayerByIndex = function()
            return { hands = { spec_hands = { heldItemNode = world.held } } }
        end,
    }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/Inbox.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCFieldPreparation.lua")
    world:load("src/util/TCJobProgress.lua")
    world:load("src/util/TCDebris.lua")
    world:load("src/util/TCJoyriderRuts.lua")
    world:load("src/business/Joyriders.lua")
    world:load("src/business/FlyTipping.lua")
    world:load("src/placeables/PlaceableTCDisposalSkip.lua")

    -- ADS for the skip's old parts (103): no ADS until a test sets
    -- world.adsEnv and calls TCADSStock.detect again.
    MountableObject = { MOUNT_TYPE_NONE = 0, MOUNT_TYPE_DYNAMIC = 1 }
    TheContractorDrivers = { getModEnv = function() return world.adsEnv end }
    world:load("src/util/TCADSStock.lua")
    TCADSStock.detect()

    -- Pieces: plain objects with a uniqueId, found by the item system
    -- until deleted. world.spawned records where each landed.
    world.spawned = {}
    world.nextUniqueId = 1
    TCDebris.spawn = function(propKey, x, y, z, rx, ry, rz, farmId)
        local debris = { propKey = propKey, x = x, z = z, rx = rx, rz = rz, farmId = farmId,
            uniqueId = "item" .. world.nextUniqueId, nodeId = 1000 + world.nextUniqueId }
        world.nextUniqueId = world.nextUniqueId + 1
        function debris:getUniqueId() return self.uniqueId end
        function debris:getIsFree() return not self.isStrapped end
        function debris:delete()
            self.isDeleted = true
            world.items[self.uniqueId] = nil
            TCDebris.instances[self] = nil
        end
        world.items[debris.uniqueId] = debris
        world.nodeObjects[debris.nodeId] = debris
        TCDebris.instances[debris] = true
        table.insert(world.spawned, debris)
        return debris
    end
    -- The ground: flat at 0, or world.groundAt(x, z).
    getTerrainHeightAtWorldPos = function(_, x, _, z)
        return world.groundAt ~= nil and world.groundAt(x, z) or 0
    end
    g_terrainNode = 1

    -- 148: roads (none unless a test adds them, so a hit goes to a field),
    -- players, and obstacles in the way (walls, hedges: { x, z }).
    world.roads, world.players, world.obstacles = {}, {}, {}
    CollisionFlag = { STATIC_OBJECT = 1, BUILDING = 2, TREE = 4, VEHICLE = 8, DYNAMIC_OBJECT = 16,
        TRAFFIC_VEHICLE = 32, PLAYER = 64 }
    MathUtil = { getYRotationFromDirection = function(dx, dz) return math.atan2(dx, dz) end }
    overlapBox = function(x, y, z, rx, ry, rz, ex, ey, ez, callback, target)
        local sinY, cosY = math.sin(ry), math.cos(ry)
        for i, obstacle in ipairs(world.obstacles) do
            local dx, dz = obstacle.x - x, obstacle.z - z
            if math.abs(dx * sinY + dz * cosY) <= ez and math.abs(dx * cosY - dz * sinY) <= ex then
                if not target[callback](target, 500 + i) then
                    return
                end
            end
        end
    end
    -- FallenTree's road helpers: samples every ROAD_SAMPLE_STEP, and the
    -- nearest field with no live job (by its middle) names the spot.
    TheContractorFallenTree = {
        ROAD_SAMPLE_STEP = 20,
        sampleRoads = function() return world.roads end,
        getPlayerPositions = function() return world.players end,
        findNearestField = function(x, z)
            local best, bestDistanceSq = nil, math.huge
            for _, field in ipairs(world.fields) do
                local fx, fz = field:getCenterOfFieldWorldPosition()
                local distanceSq = (fx - x) ^ 2 + (fz - z) ^ 2
                if not g_currentMission.TheContractor.Jobs:isFieldProtected(field.id) and
                        distanceSq < bestDistanceSq then
                    best, bestDistanceSq = field, distanceSq
                end
            end
            return best
        end,
    }

    -- The dump site's ruts and patch, recorded.
    world.painted = {}
    FSDensityMapUtil = {
        convertToDensityMapAngle = function() return 0 end,
        updateCultivatorArea = function(sx, sz, wx, wz, hx, hz)
            table.insert(world.painted, { x = (wx + hx) / 2, z = (wz + hz) / 2 })
        end,
        clearDecoArea = function() end,
    }
    g_currentMission.fieldGroundSystem = { getGroundAngleMaxValue = function() return 7 end }

    TCRandomEventIncidentEvent = {
        new = function(incident, isClosed) return { incident = incident, isClosed = isClosed } end,
    }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Contracting" } }
    world:addRelationships()
    world.reputation = 0
    tc.Reputation = {
        getStanding = function() return 0.5 end,
        getReputationTier = function() return {} end,
        addReputation = function(_, farmId, amount) world.reputation = world.reputation + amount end,
    }
    world.disposalRecorded = 0
    tc.Finances = {
        recordDisposal = function(_, farmId, amount)
            world.disposalRecorded = world.disposalRecorded + amount
        end,
    }

    tc.Jobs = TheContractorJobs.new()
    tc.Jobs.isFieldProtectedReal = tc.Jobs.isFieldProtected
    tc.Jobs.isFieldProtected = function(self, fieldId)
        return world.protected[fieldId] == true or self:isFieldProtectedReal(fieldId)
    end
    tc.JobGeneration = TheContractorJobGeneration.new()

    -- The real inbox; world.messages records each post's text, rendered as
    -- the client would.
    world.messages = {}
    tc.Inbox = TheContractorInbox.new()
    local postMessage = tc.Inbox.postMessage
    tc.Inbox.postMessage = function(self, farmId, kind, titleKey, bodyKey, args, actions, payload, expiresInDays)
        local message = { farmId = farmId, kind = kind, titleKey = titleKey, bodyKey = bodyKey, args = args,
            payload = payload }
        table.insert(world.messages, { farmId = farmId, kind = kind, titleKey = titleKey, bodyKey = bodyKey,
            args = args, title = TheContractorInbox.getTitle(message), body = TheContractorInbox.getBody(message),
            payload = payload })
        return postMessage(self, farmId, kind, titleKey, bodyKey, args, actions, payload, expiresInDays)
    end

    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.Joyriders = TheContractorJoyriders.new()
    tc.Joyriders:register(tc.RandomEvents, tc.Inbox)
    tc.FlyTipping = TheContractorFlyTipping.new()
    tc.FlyTipping:register(tc.RandomEvents, tc.Inbox)
    return world, tc
end

-- A fly-tipping job on field 12, from the real event. Its pile is 8.
local function dump(world, tc, fieldDef)
    world:addField(fieldDef or { id = 12 })
    local random = math.random
    math.random = function(low, high)
        if low == TheContractorFlyTipping.MIN_PIECES then
            return 8
        elseif low == nil then
            return random()
        elseif high == nil then
            return random(low)
        end
        return high -- the most slack on the deadline
    end
    local incident = tc.RandomEvents:triggerEvent(1, "flyTipping")
    math.random = random
    local job = tc.Jobs:getAllJobs(1)[1]
    return incident, job
end

test("registered as a random event with its own inbox kind", function()
    local world, tc = setup()
    local definition = tc.RandomEvents:getEventType("flyTipping")
    assertTrue(definition ~= nil)
    assertEquals(definition.cooldownPeriods, 4)
    assertNear(definition.ratePerPeriod(1), 0.04, 1e-9)
    assertTrue(tc.Inbox:getKind("flyTipping") ~= nil)
end)

test("only NPC fields with no live job, never the farm's own or another player's", function()
    local world, tc = setup()
    world:addField({ id = 1 })              -- NPC
    world:addField({ id = 2, owner = 1 })   -- ours
    world:addField({ id = 3, owner = 2 })   -- another player's
    world:addField({ id = 4 })              -- NPC, with a job on it
    world.protected[4] = true

    local ids = {}
    for _, field in ipairs(tc.FlyTipping:getEligibleFields(1)) do
        table.insert(ids, field.id)
    end
    assertEquals(table.concat(ids, ","), "1")

    world.fields = { world.fields[2], world.fields[3] }
    local incident = tc.RandomEvents:triggerEvent(1, "flyTipping")
    assertEquals(incident, nil, "nowhere to tip")
end)

test("the pile lands 4-7 m in from the edge by the gate, with ruts in to it, and a job is offered", function()
    local world, tc = setup()
    local incident, job = dump(world, tc)
    assertTrue(incident ~= nil)
    assertEquals(#tc.RandomEvents:getIncidents(1), 0, "done in one stage")

    -- The gate's at (-5, 0): straight in over the left edge at (0, 0).
    local spread = TCDebris.PILE_SPREAD / 2 + 1e-9
    assertEquals(#world.spawned, 8)
    for _, debris in ipairs(world.spawned) do
        assertTrue(debris.x >= 4 - spread and debris.x <= 7 + spread, "4-7 m in from the edge")
        assertTrue(math.abs(debris.z) <= spread, "straight in from the gate")
        assertEquals(debris.farmId, 1)
        assertTrue(TCDebris.PROPS[debris.propKey] ~= nil, "a random prop from the pool")
    end

    assertTrue(job ~= nil)
    assertEquals(job.jobType, "flyTipping")
    assertEquals(job.fieldId, 12)
    assertEquals(#job.debrisIds, 8)
    assertEquals(job.debrisIds[1], world.spawned[1].uniqueId)
    assertEquals(job.workTotal, 8)
    assertEquals(job.debrisDisposed, 0)
    -- Day 40 is the 2nd of 3: due by the month's last day.
    assertEquals(job.deadlineDay, 41)
    assertTrue(TheContractorJobGeneration.isPlayerOnly(job))

    -- The evidence: ruts from the edge in, and the patch under the pile.
    assertTrue(#world.painted >= 3)
    local patch = world.painted[#world.painted]
    assertTrue(patch.x >= 4 and patch.x <= 7 and math.abs(patch.z) < 1e-6, "the patch is on the spot")
    for _, piece in ipairs(world.painted) do
        assertTrue(piece.x >= 0 and piece.x <= 7 + 1e-6, "between the edge and the spot")
    end

    assertEquals(#world.messages, 1)
    assertEquals(world.messages[1].kind, "flyTipping")
    assertEquals(world.messages[1].titleKey, "tc_flyTipping_offerTitle")
    assertEquals(world.messages[1].args[1], 12, "the field")
    assertEquals(world.messages[1].args[2], 8, "the pieces")
    assertEquals(world.messages[1].payload.jobId, job.id)
end)

test("a field without a boundary still gets its pile, in from the gate, and no ruts", function()
    local world, tc = setup()
    dump(world, tc, { id = 12, noBoundary = true })
    assertEquals(#world.painted, 0)
    assertEquals(#world.spawned, 8)
    -- GATE_INSET (6 m) from the gate at (-5, 0) towards the middle at (20, 0).
    for _, debris in ipairs(world.spawned) do
        assertTrue(math.abs(debris.x - 1) <= TCDebris.PILE_SPREAD / 2 + 1e-9)
    end
end)

test("never generated: left out of the job types generation and tcJob use", function()
    for _, jobType in ipairs(TheContractorJobGeneration.JOB_TYPE_KEYS) do
        assertTrue(jobType ~= "flyTipping")
    end
    setup()
    assertEquals(TheContractorJobGeneration.findJobType("flyTipping"), nil)
end)

test("priced per piece, with the usual multipliers on top", function()
    local world, tc = setup()
    local field = world:addField({ id = 5 })
    local generation = TheContractorJobGeneration
    generation.MIN_REPUTATION_PRICE_MULTIPLIER, generation.MAX_REPUTATION_PRICE_MULTIPLIER = 1, 1
    generation.MIN_PRICE_VARIANCE, generation.MAX_PRICE_VARIANCE = 1, 1
    generation.SKILL_PRICE_PREMIUM = 0
    local jobDef = generation.JOB_TYPES.flyTipping
    local payMultiplier = tc.Settings:getJobPayMultiplier()
    -- Difficulty 3: vanilla's 1.3 - 0.3 = 1.
    assertEquals(tc.JobGeneration:estimatePrice(field, jobDef, 1, 1, nil, 10), math.floor(3000 * payMultiplier))
    assertEquals(tc.JobGeneration:estimatePrice(field, jobDef, 1, 1, nil, 5), math.floor(1500 * payMultiplier))
end)

test("reputation is per piece in the pile, not per hectare", function()
    local world, tc = setup()
    local _, job = dump(world, tc)
    assertEquals(TheContractorJobs.getBaseReputationReward(job), 8)
end)

test("a skip takes a job's piece: counted, the tipping fee charged", function()
    local world, tc = setup()
    local _, job = dump(world, tc)
    local piece = world.spawned[3]

    local fee = tc.Settings:scaleCost(TheContractorFlyTipping.TIPPING_FEE)
    assertEquals(fee, 25, "at the default job pay rate")
    assertEquals(tc.FlyTipping:disposeDebris(piece), job)
    assertTrue(piece.isDeleted)
    assertEquals(job.debrisDisposed, 1)
    assertEquals(#job.debrisIds, 7)
    assertEquals(#world.money, 1)
    assertEquals(world.money[1].amount, -fee)
    assertEquals(world.money[1].farmId, 1)
    assertEquals(world.money[1].moneyType, MoneyType.TC_WASTE_DISPOSAL)
    assertEquals(world.disposalRecorded, fee)
end)

test("debris from no job goes free, and a finished job's pieces don't count", function()
    local world, tc = setup()
    local loose = TCDebris.spawn("barrel", 0, 0, 0, 0, 0, 0, 1)
    assertEquals(tc.FlyTipping:disposeDebris(loose), nil)
    assertTrue(loose.isDeleted)
    assertEquals(#world.money, 0)

    local _, job = dump(world, tc)
    job.state = TheContractorJob.STATE.MISSED
    tc.FlyTipping:disposeDebris(world.spawned[2])
    assertEquals(job.debrisDisposed, 0)
    assertEquals(#world.money, 0)
end)

test("progress: taken against taken plus still lying there, vanished pieces dropping out", function()
    local world, tc = setup()
    local _, job = dump(world, tc)
    assertEquals(TCJobProgress.getCompletion(job), 0)

    tc.FlyTipping:disposeDebris(world.spawned[1])
    tc.FlyTipping:disposeDebris(world.spawned[2])
    assertNear(TCJobProgress.getCompletion(job), 2 / 8, 1e-9)

    -- Two vanish some other way (tcCompany debrisClear, say).
    world.spawned[3]:delete()
    world.spawned[4]:delete()
    assertNear(TCJobProgress.getCompletion(job), 2 / 6, 1e-9)

    for i = 5, 8 do
        tc.FlyTipping:disposeDebris(world.spawned[i])
    end
    assertEquals(TCJobProgress.getCompletion(job), 1)
end)

test("the skip disposes of what's been let go, keeps what's held or strapped, drops what's gone", function()
    local world, tc = setup()
    local _, job = dump(world, tc)
    local held, dropped, gone, strapped = world.spawned[1], world.spawned[2], world.spawned[3], world.spawned[4]
    gone:delete()
    world.held = held.nodeId
    strapped.isStrapped = true

    local waiting = { held, dropped, gone, strapped }
    PlaceableTCDisposalSkip.processWaiting(waiting)
    assertEquals(#waiting, 2, "the held and strapped ones wait")
    assertTrue(dropped.isDeleted)
    assertTrue(not held.isDeleted and not strapped.isDeleted)
    assertEquals(job.debrisDisposed, 1)

    world.held = nil
    strapped.isStrapped = false
    PlaceableTCDisposalSkip.processWaiting(waiting)
    assertEquals(#waiting, 0)
    assertEquals(job.debrisDisposed, 3)
end)

-- Old ADS parts (103). The fake ADS knows boxes (`adsBox` state, its
-- isUsed flag, `adsReserved`) and loose packs (`adsPack` state).
local function withADS(world)
    world.adsEnv = {
        ADS_PlayerWorkshop = { STOCK_KINDS = { PACK = "pack" }, collectStockSources = function() end },
        ADS_SparePartsBox = {
            isBox = function(object) return object.adsBox ~= nil end,
            getState = function(object) return object.adsBox end,
            isReserved = function(object) return object.adsReserved == true end,
            isUsed = function(object) return object.adsBox.isUsed == true end,
        },
        ADS_ConsumablePack = {
            isPack = function(object) return object.adsPack ~= nil end,
            isGrippable = function(object) return object.adsPack ~= nil end,
            getPartState = function(object) return object.adsPack end,
        },
    }
    TCADSStock.detect()
end

local function addPart(world, def)
    local part = { nodeId = nil, rootNode = 5000 + world.nextUniqueId, farmId = def.farmId or 1,
        adsBox = def.box, adsPack = def.pack, adsReserved = def.reserved, dynamicMountType = def.mountType }
    world.nextUniqueId = world.nextUniqueId + 1
    function part:getOwnerFarmId() return self.farmId end
    function part:getName() return "Hydraulic pump" end
    function part:delete() self.isDeleted = true end
    world.nodeObjects[part.rootNode] = part
    return part
end

test("the skip takes old ADS parts for the tipping fee, and leaves new ones alone", function()
    local world, tc = setup()
    withADS(world)
    local fee = TheContractorFlyTipping.getTippingFee()
    local oldBox = addPart(world, { box = { isUsed = true }, farmId = 2 })
    local oldBattery = addPart(world, { pack = { health = 0.4 } })
    local newBox = addPart(world, { box = { isUsed = false } })
    local newBattery = addPart(world, { pack = { health = 1, clogging = 0 } })

    assertTrue(PlaceableTCDisposalSkip.isTaken(oldBox), "old box")
    assertTrue(PlaceableTCDisposalSkip.isTaken(oldBattery), "old battery")
    assertTrue(not PlaceableTCDisposalSkip.isTaken(newBox), "new box")
    assertTrue(not PlaceableTCDisposalSkip.isTaken(newBattery), "new battery")

    local waiting = { oldBox, oldBattery }
    PlaceableTCDisposalSkip.processWaiting(waiting)
    assertEquals(#waiting, 0)
    assertTrue(oldBox.isDeleted and oldBattery.isDeleted, "both gone")
    assertEquals(#world.money, 2, "a fee each")
    assertEquals(world.money[1].amount, -fee)
    assertEquals(world.money[1].moneyType, MoneyType.TC_WASTE_DISPOSAL)
    local farms = { [world.money[1].farmId] = true, [world.money[2].farmId] = true }
    assertTrue(farms[1] and farms[2], "each charged to its owner")
    assertEquals(world.disposalRecorded, 2 * fee, "recorded as disposal")
end)

test("the trigger only lists what the skip takes", function()
    local world, tc = setup()
    withADS(world)
    local skip = { [PlaceableTCDisposalSkip.KEY] = { waiting = {} }, raiseActive = function() end }
    local oldBox = addPart(world, { box = { isUsed = true } })
    local newBox = addPart(world, { box = { isUsed = false } })
    local tractor = addPart(world, {})
    for _, object in ipairs({ oldBox, newBox, tractor }) do
        PlaceableTCDisposalSkip.tcDisposalTriggerCallback(skip, 1, object.rootNode, true, false)
    end
    local waiting = skip[PlaceableTCDisposalSkip.KEY].waiting
    assertEquals(#waiting, 1)
    assertEquals(waiting[1], oldBox)
    PlaceableTCDisposalSkip.tcDisposalTriggerCallback(skip, 1, oldBox.rootNode, false, true)
    assertEquals(#waiting, 0, "carried back out")
end)

test("an old part waits while it's held, strapped or on a fork, or reserved by a work order", function()
    local world, tc = setup()
    withADS(world)
    local held = addPart(world, { box = { isUsed = true } })
    local strapped = addPart(world, { box = { isUsed = true }, mountType = MountableObject.MOUNT_TYPE_DYNAMIC })
    local reserved = addPart(world, { box = { isUsed = true }, reserved = true })
    world.held = held.rootNode

    local waiting = { held, strapped, reserved }
    PlaceableTCDisposalSkip.processWaiting(waiting)
    assertEquals(#waiting, 3, "all wait")
    assertEquals(#world.money, 0)

    world.held = nil
    strapped.dynamicMountType = MountableObject.MOUNT_TYPE_NONE
    reserved.adsReserved = false
    PlaceableTCDisposalSkip.processWaiting(waiting)
    assertEquals(#waiting, 0)
    assertEquals(#world.money, 3)
end)

test("without ADS no part is taken, and debris still is", function()
    local world, tc = setup()
    local part = addPart(world, { box = { isUsed = true } })
    assertTrue(not PlaceableTCDisposalSkip.isTaken(part), "no ADS")
    local waiting = { part }
    PlaceableTCDisposalSkip.processWaiting(waiting)
    assertEquals(#waiting, 0, "dropped off")
    assertTrue(not part.isDeleted, "left where it is")
    assertTrue(PlaceableTCDisposalSkip.isTaken(TCDebris.spawn("barrel", 0, 0, 0, 0, 0, 0, 1)), "debris")
end)

test("the field's left alone at allocation", function()
    local world, tc = setup()
    local _, job = dump(world, tc)
    assertEquals(TCFieldPreparation.prepareFieldForJob(job), true)
    assertEquals(job.workTotal, 8, "the pile's size stays")
    assertEquals(#job.debrisIds, 8)
end)

test("turning the offer down, or letting it run out, takes the pile away", function()
    local world, tc = setup()
    local _, job = dump(world, tc)
    assertTrue(tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED))
    assertEquals(#job.debrisIds, 0)
    for _, debris in ipairs(world.spawned) do
        assertTrue(debris.isDeleted)
    end

    -- Expiry goes the same way (Jobs:onDayChanged declines it).
    world.spawned = {}
    world.fields = {}
    local _, second = dump(world, tc)
    g_currentMission.environment.currentMonotonicDay = second.deadlineDay + 1
    tc.Jobs:onDayChanged()
    assertEquals(second.state, TheContractorJob.STATE.DECLINED)
    for _, debris in ipairs(world.spawned) do
        assertTrue(debris.isDeleted)
    end
end)

test("the offer message expires with the job, and goes once the job's taken on or over", function()
    local world, tc = setup()
    local _, job = dump(world, tc)
    local message = tc.Inbox:getMessages(1)[1]
    assertEquals(message.expiresDay, job.deadlineDay + 1, "the day the offer lapses")

    -- Turned down: gone straight away.
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    assertEquals(#tc.Inbox:getMessages(1), 0)

    -- Accepted: the offer's done its job, so it goes too.
    world.fields = {}
    dump(world, tc)
    local second = tc.Jobs:getJob(1, tc.Inbox:getMessages(1)[1].payload.jobId)
    tc.Jobs:transitionJobState(1, second.id, TheContractorJob.STATE.ACCEPTED)
    assertEquals(#tc.Inbox:getMessages(1), 0, "an accepted job's offer goes")
    second.state = TheContractorJob.STATE.COMPLETED

    -- An older save's, from before: no expiry, its job long over. The
    -- daily tick catches it.
    world.fields = {}
    dump(world, tc)
    local old = tc.Inbox:getMessages(1)[1]
    local third = tc.Jobs:getJob(1, old.payload.jobId)
    old.expiresDay = nil
    third.state = TheContractorJob.STATE.DECLINED
    tc.Inbox:onDayChanged()
    assertEquals(#tc.Inbox:getMessages(1), 0)

    -- And one whose job was taken on before accepting cleared it.
    world.fields = {}
    dump(world, tc)
    local taken = tc.Inbox:getMessages(1)[1]
    tc.Jobs:getJob(1, taken.payload.jobId).state = TheContractorJob.STATE.ALLOCATED
    tc.Inbox:onDayChanged()
    assertEquals(#tc.Inbox:getMessages(1), 0)

    -- Other kinds' messages naming a job (052's claims) stay.
    tc.Inbox:registerMessageKind("claim", {})
    tc.Inbox:postMessage(1, "claim", "tc_flyTipping_offerTitle", "tc_flyTipping_offerTitle", { 1 }, nil,
        { jobId = third.id })
    tc.Inbox:onDayChanged()
    tc.Inbox:removeMessagesForJob(1, third.id)
    assertEquals(#tc.Inbox:getMessages(1), 1)
    assertEquals(tc.Inbox:getMessages(1)[1].expiresDay, nil)
end)

test("completing or missing the job clears what's left", function()
    local world, tc = setup()
    local _, job = dump(world, tc)
    tc.FlyTipping:disposeDebris(world.spawned[1])
    TCFieldPreparation.clearUpAfterJob(job)
    assertEquals(#job.debrisIds, 0)
    for i = 2, 8 do
        assertTrue(world.spawned[i].isDeleted)
    end
    assertEquals(job.debrisDisposed, 1, "what was taken still counts")
end)

test("a job that can't be dated takes its pile back", function()
    local world, tc = setup()
    tc.JobGeneration.getDeadlineDay = function() return nil end
    dump(world, tc)
    assertEquals(#tc.Jobs:getAllJobs(1), 0)
    assertTrue(#world.spawned > 0)
    for _, debris in ipairs(world.spawned) do
        assertTrue(debris.isDeleted)
    end
end)

test("the job's pile and count go through a save", function()
    local world, tc = setup()
    local _, job = dump(world, tc)
    tc.FlyTipping:disposeDebris(world.spawned[1])

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local loaded = TheContractorJobs.new()
    loaded:loadFromXMLFile(xmlFile)
    local copy = loaded:getJob(1, job.id)
    assertEquals(#copy.debrisIds, 7)
    assertEquals(copy.debrisIds[1], job.debrisIds[1])
    assertEquals(copy.debrisDisposed, 1)
    assertEquals(copy.workTotal, 8)
end)

test("due this month: a full day in a 1-day month, tomorrow when forced late in the day", function()
    local world, tc = setup()
    local field = world:addField({ id = 3 })
    local environment = g_currentMission.environment
    environment.daysPerPeriod = 1
    environment.getDayInPeriodFromDay = function() return 1 end
    for _, jobType in ipairs({ "flyTipping", "plow" }) do
        local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
        environment.currentHour = 0
        assertEquals(tc.JobGeneration:getDeadlineDay(field, jobDef, true), 40,
            jobType .. ": rolled at the day change, due that day")
        environment.currentHour = 20
        assertEquals(tc.JobGeneration:getDeadlineDay(field, jobDef, true), 41,
            jobType .. ": forced late in the day, due tomorrow")
    end
end)

-- Only the given props, at these weights; every other prop's weight 0.
local function onlyWeights(weights)
    for key, def in pairs(TCDebris.PROPS) do
        def.weight = 0
    end
    for key, weight in pairs(weights) do
        TCDebris.PROPS[key].weight = weight
    end
end

-- How often each prop is picked over n rolls spread evenly across 0..1.
local function sweep(n)
    local random = math.random
    local counts, i = {}, 0
    math.random = function(low, high)
        if low ~= nil then
            return random(low, high)
        end
        i = i + 1
        return (i - 0.5) / n
    end
    for _ = 1, n do
        local key = TCDebris.pickRandomProp()
        counts[key] = (counts[key] or 0) + 1
    end
    math.random = random
    return counts
end

test("a random pile picks each prop in proportion to its weight", function()
    setup()
    onlyWeights({ binBag = 3, barrel = 1 })
    local counts = sweep(400)
    assertEquals(counts.binBag, 300)
    assertEquals(counts.barrel, 100)

    -- A prop with no weight given counts as 1.
    onlyWeights({ barrel = 2 })
    TCDebris.PROPS.pipe.weight = nil
    counts = sweep(300)
    assertEquals(counts.barrel, 200)
    assertEquals(counts.pipe, 100)
end)

test("weight 0 is never picked; with nothing to pick there's no pile and no event", function()
    local world, tc = setup()
    onlyWeights({ barrel = 1 })
    for key, n in pairs(sweep(50)) do
        assertEquals(key, "barrel")
    end

    onlyWeights({})
    assertEquals(TCDebris.pickRandomProp(), nil)
    assertTrue(not TCDebris.hasRandomProps())
    assertEquals(#TCDebris.spawnPileAt(0, 0, 5, 1), 0)
    world:addField({ id = 1 })
    assertEquals(tc.RandomEvents:triggerEvent(1, "flyTipping"), nil)

    -- Still there by name.
    assertEquals(#TCDebris.spawnPileAt(0, 0, 2, 1, "crate"), 2)
end)

test("bin bags are dropped nearly upright; a named prop is only ever that", function()
    local world, tc = setup()
    onlyWeights({ binBag = 1 })
    TCDebris.spawnPileAt(0, 0, 6, 1)
    assertEquals(#world.spawned, 6)
    for _, debris in ipairs(world.spawned) do
        assertEquals(debris.propKey, TCDebris.BIN_BAG)
        assertTrue(math.abs(debris.rx) <= TCDebris.BIN_BAG_TIP and math.abs(debris.rz) <= TCDebris.BIN_BAG_TIP,
            "nearly upright, to land on its bottom")
    end

    world.spawned = {}
    TCDebris.spawnPileAt(0, 0, 3, 1, "barrel")
    for _, debris in ipairs(world.spawned) do
        assertEquals(debris.propKey, "barrel")
    end
end)

-- 148: by the road, for the council --------------------------------------------------

-- A straight road along z (0 unless given) from x = -100 to 100, sampled
-- every 20 m, running +x.
local function addRoad(world, z)
    for x = -100, 100, 20 do
        table.insert(world.roads, { x = x, y = 0, z = z or 0, dirX = 1, dirZ = 0 })
    end
end

-- Triggers the event with every unit roll at roll: under ROADSIDE_SHARE is
-- the road. Its pile is 8.
local function trigger(tc, roll)
    local random = math.random
    math.random = function(low, high)
        if low == TheContractorFlyTipping.MIN_PIECES then
            return 8
        elseif low == nil then
            return roll
        elseif high == nil then
            return random(low)
        end
        return high
    end
    local incident = tc.RandomEvents:triggerEvent(1, "flyTipping")
    math.random = random
    return incident, tc.Jobs:getAllJobs(1)[1]
end

-- The real Farmers: the official (#1), and Tom (#5) holding field 12's
-- farmland.
local function addFarmers(world, tc)
    world:load("src/business/Farmers.lua")
    tc.Farmers = TheContractorFarmers.new()
    tc.Farmers.people = {
        [1] = { id = 1, name = "Official", isOfficial = true, farmlandIds = {} },
        [5] = { id = 5, name = "Tom", farmlandIds = { 7 } },
    }
    tc.Farmers.officialId = 1
    world.fields[1].getFarmland = function() return { getId = function() return 7 end } end
end

test("a road roll puts the pile on the verge, the official's job, named by the nearest field", function()
    local world, tc = setup()
    world:addField({ id = 12 })
    addRoad(world)
    addFarmers(world, tc)
    local incident, job = trigger(tc, 0.2)
    assertTrue(incident ~= nil)
    assertEquals(incident.data.roadside, true)

    local spread = TCDebris.PILE_SPREAD / 2 + 1e-9
    assertEquals(#world.spawned, 8)
    for _, debris in ipairs(world.spawned) do
        assertTrue(math.abs(math.abs(debris.z) - TheContractorFlyTipping.VERGE_OFFSET) <= spread, "on the verge")
        assertEquals(debris.farmId, 1)
    end
    assertEquals(#world.painted, 0, "no ruts by the road")

    assertEquals(job.jobType, "flyTippingRoadside")
    assertEquals(job.fieldId, 12)
    assertEquals(job.customerId, 1, "the official's, not the field's farmer's")
    assertEquals(#job.debrisIds, 8)
    assertEquals(job.workTotal, 8)
    assertEquals(job.deadlineDay, 41, "due this month, as the field's is")
    assertEquals(job:getListFieldText(), "-")
    assertTrue(TheContractorJobGeneration.isPlayerOnly(job))

    assertEquals(world.messages[1].kind, "flyTipping")
    assertEquals(world.messages[1].titleKey, "tc_flyTipping_roadsideOfferTitle")
    assertEquals(world.messages[1].bodyKey, "tc_flyTipping_roadsideOfferBody")
    assertEquals(world.messages[1].args[1], 12)
    assertEquals(world.messages[1].args[2], 8)
    assertEquals(world.messages[1].payload.jobId, job.id)
    local args = tc.Inbox:getKind("flyTipping").getArgs(tc.Inbox:getMessages(1)[1])
    assertEquals(args[3], "Official", "the offer names the official")
end)

test("a field roll gets a field, the field's farmer's job as before", function()
    local world, tc = setup()
    world:addField({ id = 12 })
    addRoad(world)
    addFarmers(world, tc)
    local incident, job = trigger(tc, 0.7)
    assertEquals(incident.data.roadside, nil)
    assertEquals(job.jobType, "flyTipping")
    assertEquals(job.customerId, 5)
    assertEquals(world.messages[1].titleKey, "tc_flyTipping_offerTitle")
end)

test("each falls back to the other when it has nowhere to go", function()
    -- No roads: the road roll gets a field.
    local world, tc = setup()
    world:addField({ id = 12 })
    local _, job = trigger(tc, 0.2)
    assertEquals(job.jobType, "flyTipping")

    -- No NPC field (only ours), but a road: the field roll gets the verge,
    -- named by our own field.
    local world2, tc2 = setup()
    world2:addField({ id = 3, owner = 1 })
    addRoad(world2)
    local _, roadJob = trigger(tc2, 0.7)
    assertEquals(roadJob.jobType, "flyTippingRoadside")
    assertEquals(roadJob.fieldId, 3)

    -- Neither: nothing.
    local world3, tc3 = setup()
    world3:addField({ id = 3, owner = 1 })
    assertEquals(trigger(tc3, 0.2), nil)
end)

test("a verge is skipped for a ditch, a bridge, a slope, something in the way, a player or a junction", function()
    local function spotWith(prepare)
        local world = setup()
        world:addField({ id = 12 })
        addRoad(world)
        prepare(world)
        return TheContractorFlyTipping.findRoadsideSpot(function() return 0.3 end)
    end
    assertTrue(spotWith(function() end) ~= nil, "a plain verge will do")
    -- A ditch along both sides.
    assertEquals(spotWith(function(world)
        world.groundAt = function(x, z) return math.abs(z) > 3 and -2 or 0 end
    end), nil)
    -- A bridge: the road well above the ground.
    assertEquals(spotWith(function(world)
        for _, sample in ipairs(world.roads) do
            sample.y = 5
        end
    end), nil)
    -- A bank rising away from the road under the pile.
    assertEquals(spotWith(function(world)
        world.groundAt = function(x, z) return math.abs(z) > 3 and (math.abs(z) - 6) * 0.5 or 0 end
    end), nil)
    -- A hedge along both verges.
    assertEquals(spotWith(function(world)
        for x = -110, 110 do
            table.insert(world.obstacles, { x = x, z = 6 })
            table.insert(world.obstacles, { x = x, z = -6 })
        end
    end), nil)
    -- A player standing by.
    assertEquals(spotWith(function(world)
        table.insert(world.players, { x = 0, z = 0 })
    end), nil)
    -- A second road 8 m off: the verge between them (z = 2, the side every
    -- try on road 2 takes at a roll of 0.3) is too near it; the other
    -- road's verge (z = -6) will do.
    local spot = spotWith(function(world)
        addRoad(world, 8)
    end)
    assertEquals(spot.z, -6)
    -- No field to name it by.
    local world = setup()
    addRoad(world)
    assertEquals(TheContractorFlyTipping.findRoadsideSpot(function() return 0.3 end), nil)
end)

test("the distance to a road is to each sample's stretch, not just its point", function()
    setup()
    local samples = { { x = 0, z = 0, dirX = 1, dirZ = 0 } }
    assertNear(TheContractorFlyTipping.getRoadDistance(9, 4, samples), 4, 1e-9)
    assertNear(TheContractorFlyTipping.getRoadDistance(13, 4, samples), 5, 1e-9)
end)

test("turning the council down costs reputation and the official's goodwill, and the pile goes", function()
    local world, tc = setup()
    world:addField({ id = 12 })
    addRoad(world)
    addFarmers(world, tc)
    local _, job = trigger(tc, 0.2)
    assertTrue(tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED))
    assertEquals(world.reputation, -3)
    assertTrue(tc.Relationships:getScore(1, 1) < 0)
    for _, debris in ipairs(world.spawned) do
        assertTrue(debris.isDeleted)
    end

    -- A field job turned down costs no reputation, as before.
    local world2, tc2 = setup()
    world2:addField({ id = 12 })
    local _, fieldJob = trigger(tc2, 0.7)
    assertTrue(tc2.Jobs:transitionJobState(1, fieldJob.id, TheContractorJob.STATE.DECLINED))
    assertEquals(world2.reputation, 0)
end)

test("a roadside job's pieces count at the skip, and its progress is measured", function()
    local world, tc = setup()
    world:addField({ id = 12 })
    addRoad(world)
    local _, job = trigger(tc, 0.2)
    tc.FlyTipping:disposeDebris(world.spawned[1])
    assertEquals(job.debrisDisposed, 1)
    assertEquals(#world.money, 1)
    assertNear(TCJobProgress.getCompletion(job), 1 / 8, 1e-9)
end)

test("the console asks for one site only: field or road, with no fallback", function()
    local world, tc = setup()
    world:addField({ id = 12 })
    local console = tc.RandomEvents:getEventType("flyTipping").console
    assertTrue(console.prepareTrigger(1, { "sideways" }, {}) ~= nil)
    assertTrue(console.prepareTrigger(1, { "road", "field" }, {}) ~= nil)

    -- Road asked for with no roads: not the field instead.
    assertEquals(console.prepareTrigger(1, { "Road" }, {}), nil)
    assertEquals(trigger(tc, 0.7), nil)
    console.clearTrigger()

    addRoad(world)
    assertEquals(console.prepareTrigger(1, { "field" }, {}), nil)
    local _, job = trigger(tc, 0.2)
    console.clearTrigger()
    assertEquals(job.jobType, "flyTipping")
end)
