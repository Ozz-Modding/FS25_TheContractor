-- 105: a tipped trailer on the real random events framework (068): the
-- odds from the hauler's haulage skill, which rig it's rolled for, where on
-- the road it ends up, the tipping (out of the cooldown, unhitched, put
-- down, both machines damaged, morale and reputation), the recovery firm or
-- doing it yourself, and the incident closing once it's righted or gone.
-- The engine side of the spot (splines, overlap tests, rotations) and the
-- rest of the mod are faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    Environment = { PERIODS_IN_YEAR = 12 }
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 1,
        currentDayInPeriod = 1,
        daysPerPeriod = 10,
        plannedDaysPerPeriod = 10,
        currentMonotonicDay = 1,
    }
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId }
    end
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }

    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end

    TheContractorWorker = { MIN_SKILL = 1, MAX_SKILL = 10 }
    TheContractorJobs = {
        getBaseReputationReward = function(job)
            return job.baseReputation or 20
        end,
    }
    TCVehicleIds = {
        getObjectId = function(uniqueId)
            for id, object in pairs(world.objects) do
                if object.uniqueId == uniqueId and not object.isDeleted then
                    return id
                end
            end
            return nil
        end,
    }
    TCRandomEventIncidentEvent = { new = function() return {} end }

    world.unhitched, world.revealed, world.placed, world.lockRefreshes = {}, {}, {}, 0
    TCJobSiteSetup = {
        unhitchVehicles = function(vehicleIds)
            for _, vehicleId in ipairs(vehicleIds) do
                table.insert(world.unhitched, vehicleId)
            end
        end,
    }
    TCEquipmentVisibility = {
        setVisibleEverywhere = function(vehicleIds, isVisible)
            for _, vehicleId in ipairs(vehicleIds) do
                world.revealed[vehicleId] = isVisible
            end
        end,
    }
    TCVehicleLock = {
        refresh = function()
            world.lockRefreshes = world.lockRefreshes + 1
        end,
    }
    world.slots = {}
    TCParking = {
        getSlots = function()
            return world.slots
        end,
        isAreaClear = function()
            return true
        end,
    }
    getWorldTranslation = function(node)
        return node.x, 0, node.z
    end
    MathUtil = {
        getYRotationFromDirection = function(dirX, dirZ)
            return math.atan2(dirX, dirZ)
        end,
        vector2Length = function(x, z)
            return math.sqrt(x * x + z * z)
        end,
    }
    g_fieldManager = {
        getFieldById = function(_, fieldId)
            if fieldId == 99 then
                return nil
            end
            return { getCenterOfFieldWorldPosition = function() return 0, 0 end }
        end,
    }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/util/TCJobConsequences.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/RoadAccident.lua")
    world:load("src/business/TippedTrailer.lua")

    -- A road running north past the field (at the origin), x = 50, every
    -- 10 m from z = -500 to 1500.
    world.roadSamples = {}
    for z = -500, 1500, 10 do
        table.insert(world.roadSamples, { x = 50, y = 0, z = z, dirX = 0, dirZ = 1 })
    end
    TheContractorTippedTrailer.sampleRoads = function()
        local copy = {}
        for i, sample in ipairs(world.roadSamples) do
            copy[i] = { x = sample.x, y = sample.y, z = sample.z, dirX = sample.dirX, dirZ = sample.dirZ }
        end
        return copy
    end
    world.clear = function() return true end
    TheContractorTippedTrailer.isPlacementClear = function(placement, sample, size)
        return world.clear(placement, sample, size)
    end
    TheContractorTippedTrailer.placeOnSide = function(trailer, data)
        table.insert(world.placed, { vehicleId = trailer.id, x = data.x, z = data.z })
        trailer.isOnSide = true
        TheContractorTippedTrailer.setLying(trailer, true)
        TCEquipmentVisibility.setVisibleEverywhere({ trailer.id }, true)
    end
    TheContractorTippedTrailer.isUpright = function(vehicle)
        return not vehicle.isOnSide
    end
    TheContractorTippedTrailer.setLying = function(vehicle, isLying)
        vehicle.frozen = isLying
    end
    world.tractorClear = function() return true end
    TheContractorTippedTrailer.isTractorPlacementClear = function(tractorPlacement, size)
        return world.tractorClear(tractorPlacement, size)
    end
    world.tractorsPlaced = {}
    TheContractorTippedTrailer.placeTractor = function(tractor, data)
        table.insert(world.tractorsPlaced, { vehicleId = tractor.id, x = data.tractorX, z = data.tractorZ,
            rotY = data.tractorRotY })
        TCEquipmentVisibility.setVisibleEverywhere({ tractor.id }, true)
    end
    TheContractorTippedTrailer.placeUpright = function(trailer, data)
        assertEquals(trailer.frozen, false, "unfrozen before it's stood up")
        trailer.isOnSide = false
        trailer.stoodUp = true
    end

    world.workers, world.messages, world.removedMessages = {}, {}, {}
    world.notices, world.removedNotices = {}, {}
    world.reputation, world.morale, world.returned = {}, {}, {}
    world.inCooldown, world.released, world.busy = {}, {}, {}
    world.recovery = 0

    local tc = g_currentMission.TheContractor
    tc.hasResolvedSavedVehicles = true
    tc.Settings = TheContractorSettings.new()
    tc.Staff = {
        getWorker = function(_, farmId, workerId)
            return world.workers[workerId]
        end,
    }
    tc.Cooldown = {
        isVehicleInCooldown = function(_, vehicleId)
            return world.inCooldown[vehicleId] == true
        end,
        releaseVehicles = function(_, vehicleIds)
            for _, vehicleId in ipairs(vehicleIds) do
                world.inCooldown[vehicleId] = nil
                table.insert(world.released, vehicleId)
            end
        end,
    }
    tc.Allocation = {
        isVehicleFree = function(_, farmId, vehicle)
            return not world.busy[vehicle.id] and not world.inCooldown[vehicle.id] and
                not tc.TippedTrailer:isAtScene(vehicle.id)
        end,
    }
    tc.Parking = {
        removeVehicles = function() end,
        returnVehicles = function(_, farmId, vehicleIds)
            for _, vehicleId in ipairs(vehicleIds) do
                table.insert(world.returned, vehicleId)
            end
        end,
    }
    tc.Finances = {
        recordRecovery = function(_, farmId, amount)
            world.recovery = world.recovery + amount
        end,
    }
    tc.Reputation = {
        addReputation = function(_, farmId, delta)
            table.insert(world.reputation, delta)
        end,
    }
    tc.Morale = {
        adjust = function(_, farmId, workers, delta)
            for _, worker in ipairs(workers) do
                table.insert(world.morale, { workerId = worker.id, delta = delta })
            end
        end,
    }
    tc.CourtesyVehicle = {
        isCourtesy = function()
            return false
        end,
    }
    world.stolen = {}
    tc.Theft = {
        isStolen = function(_, vehicleId)
            return world.stolen[vehicleId] == true
        end,
    }
    tc.Inbox = {
        registerMessageKind = function(_, kind, definition)
            world.messageKind = definition
        end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
            -- Rendered as the client would, so a broken text fails here.
            local resolved = {}
            for i, arg in ipairs(args) do
                if type(arg) == "string" and string.sub(arg, 1, 7) == "$money_" then
                    resolved[i] = g_i18n:formatMoney(tonumber(string.sub(arg, 8)), 0, true, true)
                else
                    resolved[i] = arg
                end
            end
            table.insert(world.messages, {
                kind = kind,
                bodyKey = bodyKey,
                title = string.format(g_i18n:getText(titleKey), unpack(resolved)),
                body = string.format(g_i18n:getText(bodyKey), unpack(resolved)),
                actions = actions,
                payload = payload,
            })
            return #world.messages
        end,
        removeMessage = function(_, messageId)
            table.insert(world.removedMessages, messageId)
        end,
    }
    tc.Notices = {
        publish = function(_, farmId, text)
            table.insert(world.notices, text)
            return #world.notices
        end,
        remove = function(_, noticeId)
            table.insert(world.removedNotices, noticeId)
        end,
    }
    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.TippedTrailer = TheContractorTippedTrailer.new()
    tc.TippedTrailer:register(tc.RandomEvents, tc.Inbox)

    function world:addWorker(id, haulage)
        local worker = { id = id, name = "Worker " .. id, skills = { haulage = haulage } }
        function worker:getSkill(skill)
            return self.skills[skill]
        end
        self.workers[id] = worker
        return worker
    end

    -- def: { name, drivable, trailer (vanilla's Trailer spec), damage, ads }
    function world:addMachine(def)
        local vehicle = self:addVehicle({ name = def.name })
        vehicle.spec_drivable = def.drivable and {} or nil
        vehicle.spec_trailer = def.trailer and {} or nil
        vehicle.uniqueId = "unique" .. vehicle.id
        vehicle.damage = def.damage or 0
        vehicle.size = { width = 3, length = 9, height = 3.5 }
        vehicle.breakdowns = {}
        if def.ads then
            vehicle.spec_AdvancedDamageSystem = {}
            function vehicle:addBreakdown(id, options)
                table.insert(self.breakdowns, options.breakdownProgress)
                return true
            end
        end
        function vehicle:getFullName() return self.name end
        function vehicle:getUniqueId() return self.uniqueId end
        function vehicle:getDamageAmount() return self.damage end
        function vehicle:addDamageAmount(amount) self.damage = self.damage + amount end
        function vehicle:addToPhysics() self.isAddedToPhysics = true end
        return vehicle
    end

    -- A harvest & haul job: worker 1 on the combine, worker 2 hauling with
    -- a tractor and trailer, both in the job's cooldown.
    function world:addHaulJob(def)
        def = def or {}
        self:addWorker(1, 5)
        local hauler = self:addWorker(2, def.haulage or 3)
        local combine = self:addMachine({ name = "Combine", drivable = true })
        local tractor = self:addMachine({ name = "Haul tractor", drivable = true, ads = def.adsTractor })
        local trailer = self:addMachine({ name = "Grain trailer", trailer = true })
        for _, vehicle in ipairs({ combine, tractor, trailer }) do
            self.inCooldown[vehicle.id] = true
        end
        local job = {
            id = 1,
            farmId = 1,
            fieldId = def.fieldId or 12,
            assignedWorkerId = 1,
            assignedEquipmentIds = { combine.id },
            haulerWorkerId = hauler.id,
            haulageEquipmentIds = { tractor.id, trailer.id },
            baseReputation = def.baseReputation,
        }
        if def.noHauler then
            job.haulerWorkerId = nil
        end
        return job, tractor, trailer, hauler
    end

    function world:nextDay()
        local environment = g_currentMission.environment
        environment.currentMonotonicDay = environment.currentMonotonicDay + 1
        tc.RandomEvents:advanceDueIncidents()
    end

    function world:answer(actionKey)
        local message = self.messages[#self.messages]
        world.messageKind.onAction(1, message, actionKey)
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

local function getIncident(tc)
    local _, incident = next(tc.RandomEvents.incidents)
    return incident
end

-- Odds --------------------------------------------------------------------------

test("chance per job: 2.5% at haulage 1 down to 0.3% at 10, never outside that", function()
    setup()
    local f = TheContractorTippedTrailer.getChance
    assertNear(f(1), 0.025, 1e-9)
    assertNear(f(10), 0.003, 1e-9)
    assertNear(f(5.5), 0.014, 1e-9)
    assertNear(f(0), 0.025, 1e-9, "clamped low")
    assertNear(f(14), 0.003, 1e-9, "clamped high")
    -- About 40 harvest & haul jobs in two years at skill 1 is about one.
    assertTrue(40 * f(1) <= 1.0001, "at most about once in two years")
end)

test("the framework reads the hauler's skill, and nothing without a hired hauler", function()
    local world, tc = setup()
    local job = world:addHaulJob({ haulage = 1 })
    local definition = tc.RandomEvents:getEventType(TheContractorTippedTrailer.EVENT_TYPE)
    assertNear(TheContractorRandomEvents.resolveJobChance(definition, 1, job), 0.025, 1e-9)
    world.workers[2].skills.haulage = 10
    assertNear(TheContractorRandomEvents.resolveJobChance(definition, 1, job), 0.003, 1e-9)
    job.haulerWorkerId = nil
    assertEquals(TheContractorRandomEvents.resolveJobChance(definition, 1, job), 0)
    assertEquals(definition.cooldownPeriods, 0, "no cooldown")
end)

-- Who and what --------------------------------------------------------------------

test("rolled for the hauler's trailer, with the tractor named", function()
    local world, tc = setup()
    local job, tractor, trailer = world:addHaulJob()
    local data = tc.TippedTrailer:rollTipping(1, job, rolls({}))
    assertEquals(data.vehicleId, trailer.id)
    assertEquals(data.vehicleName, "Grain trailer")
    assertEquals(data.tractorId, tractor.id)
    assertEquals(data.tractorName, "Haul tractor")
    assertEquals(data.workerName, "Worker 2")
    assertEquals(data.vehicleUniqueId, trailer.uniqueId)
end)

test("never without a hauler, a trailer, a field or a road, or for a stolen or busy trailer", function()
    local world, tc = setup()
    local job, _, trailer = world:addHaulJob({ noHauler = true })
    assertEquals(tc.TippedTrailer:rollTipping(1, job, rolls({})), nil, "no hired hauler")

    job.haulerWorkerId = 2
    world.stolen[trailer.id] = true
    assertEquals(tc.TippedTrailer:rollTipping(1, job, rolls({})), nil, "stolen")
    world.stolen[trailer.id] = nil

    world.inCooldown[trailer.id] = nil
    world.busy[trailer.id] = true
    assertEquals(tc.TippedTrailer:rollTipping(1, job, rolls({})), nil, "out on another job")
    world.busy[trailer.id] = nil
    assertTrue(tc.TippedTrailer:rollTipping(1, job, rolls({})) ~= nil, "parked and free (the console)")

    job.fieldId = 99
    assertEquals(tc.TippedTrailer:rollTipping(1, job, rolls({})), nil, "no field")
    job.fieldId = 12

    world.roadSamples = {}
    assertEquals(tc.TippedTrailer:rollTipping(1, job, rolls({})), nil, "no road")

    job.haulageEquipmentIds = { job.haulageEquipmentIds[1] }
    assertEquals(tc.TippedTrailer:rollTipping(1, job, rolls({})), nil, "no trailer")
end)

-- Where -----------------------------------------------------------------------------

test("on the road between the field and the yard, clear of both", function()
    local world, tc = setup()
    -- The yard 1 km north of the field.
    world.slots = { { rootNode = { x = 0, z = 1000 } } }
    local job = world:addHaulJob()
    for seed = 1, 20 do
        local random = rolls({ seed / 21, (seed * 7 % 20) / 21 })
        local data = tc.TippedTrailer:rollTipping(1, job, random)
        assertTrue(data.z >= 60 and data.z <= 930, "between the two: " .. data.z)
        assertNear(math.abs(data.x - 50), 3.0, 1e-6, "at the road's edge")
        assertNear(data.dirZ, 1, 1e-9, "along the road")
    end
end)

test("the candidates: the corridor first, else the nearest to the field", function()
    setup()
    local samples = {}
    for z = -1000, 1000, 10 do
        table.insert(samples, { x = 50, y = 0, z = z, dirX = 0, dirZ = 1 })
    end
    local candidates = TheContractorTippedTrailer.getCandidates(samples, 0, 0, 0, 1000, rolls({}))
    for _, sample in ipairs(candidates) do
        assertTrue(sample.z > 0, "on the way to the yard, not behind the field")
        local fromYard = math.sqrt(sample.x * sample.x + (sample.z - 1000) * (sample.z - 1000))
        assertTrue(fromYard >= 80, "clear of the yard: " .. fromYard)
    end

    candidates = TheContractorTippedTrailer.getCandidates(samples, 0, 0, nil, nil, rolls({}))
    assertEquals(#candidates, TheContractorTippedTrailer.FALLBACK_COUNT)
    for _, sample in ipairs(candidates) do
        local fromField = math.sqrt(sample.x * sample.x + sample.z * sample.z)
        -- Ten each way along the road: z 70 to 160.
        assertTrue(fromField >= 80 and fromField <= math.sqrt(50 * 50 + 160 * 160) + 1e-6, "near the field: " .. fromField)
    end
end)

test("wheels at the road's edge, body lying back across the road", function()
    setup()
    local sample = { x = 0, y = 0, z = 0, dirX = 0, dirZ = 1 }
    local right = TheContractorTippedTrailer.getPlacement(sample, 1, { height = 4 })
    assertNear(right.x, 3, 1e-9, "wheels at the right-hand edge")
    assertNear(right.centreX, 1, 1e-9, "body back toward the middle")
    assertNear(right.sideX, -1, 1e-9, "its top points to the middle")
    local left = TheContractorTippedTrailer.getPlacement(sample, -1, { height = 4 })
    assertNear(left.x, -3, 1e-9)
    assertNear(left.centreX, -1, 1e-9)
    assertNear(left.sideX, 1, 1e-9)
end)

test("the footprint: four corners and the middle of it lying down", function()
    setup()
    local sample = { x = 0, y = 0, z = 0, dirX = 0, dirZ = 1 }
    local size = { height = 4, length = 10 }
    local points = TheContractorTippedTrailer.getFootprintPoints(
        TheContractorTippedTrailer.getPlacement(sample, 1, size), size)
    assertEquals(#points, 5)
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, point in ipairs(points) do
        minX, maxX = math.min(minX, point.x), math.max(maxX, point.x)
        minZ, maxZ = math.min(minZ, point.z), math.max(maxZ, point.z)
    end
    assertNear(minX, -1, 1e-9)
    assertNear(maxX, 3, 1e-9)
    assertNear(minZ, -5, 1e-9)
    assertNear(maxZ, 5, 1e-9)
end)

test("a spot that isn't clear is skipped; none clear is no event", function()
    local world, tc = setup()
    local job = world:addHaulJob()
    world.clear = function(placement)
        return placement.z > 100
    end
    local data = tc.TippedTrailer:rollTipping(1, job, rolls({}))
    assertTrue(data.z > 100, "a clear spot")
    world.clear = function() return false end
    assertEquals(tc.TippedTrailer:rollTipping(1, job, rolls({})), nil)
end)

-- The tipping -------------------------------------------------------------------------

test("tipping: out of the cooldown, unhitched, put down, both damaged, morale and reputation", function()
    local world, tc = setup()
    local job, tractor, trailer = world:addHaulJob({ baseReputation = 30, adsTractor = true })
    local incident = tc.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job)
    assertTrue(incident ~= nil, "opened")

    assertEquals(world.released[1], trailer.id, "out of the cooldown")
    assertEquals(world.released[2], tractor.id, "the tractor too")
    assertEquals(world.unhitched[1], trailer.id)
    assertEquals(world.placed[1].vehicleId, trailer.id)
    assertEquals(world.revealed[trailer.id], true)
    assertEquals(world.tractorsPlaced[1].vehicleId, tractor.id, "the tractor left at the scene")
    assertEquals(world.revealed[tractor.id], true)
    assertTrue(trailer.damage >= 0.3 and trailer.damage <= 0.6, "trailer damaged: " .. trailer.damage)
    assertEquals(#tractor.breakdowns, 1, "an ADS breakdown on the ADS tractor")
    assertEquals(world.morale[1].workerId, 2)
    assertEquals(world.morale[1].delta, -5)
    assertEquals(world.reputation[1], -15, "half the job's reputation")
    assertEquals(#world.notices, 1)

    local message = world.messages[1]
    assertEquals(message.title, "Trailer on its side after Field 12")
    assertTrue(string.find(message.body, "Worker 2", 1, true) ~= nil, message.body)
    assertTrue(string.find(message.body, "Haul tractor", 1, true) ~= nil, message.body)
    assertEquals(#message.actions, 2)
    assertEquals(getIncident(tc).stage, "offer")
    assertTrue(tc.TippedTrailer:isTipped(trailer.id), "locked out of allocation")
    assertTrue(not tc.Allocation:isVehicleFree(1, trailer))
    assertTrue(not tc.TippedTrailer:isTipped(tractor.id), "the tractor isn't tipped")
    assertTrue(not tc.Allocation:isVehicleFree(1, tractor), "but it's kept at the scene")
end)

test("the tractor stands just ahead of the trailer in its lane, slewed a little", function()
    setup()
    local sample = { x = 0, y = 0, z = 0, dirX = 0, dirZ = 1 }
    local trailerSize = { length = 9, height = 3.5, width = 3 }
    local tractorSize = { length = 5, width = 2.5 }
    -- Wheels at x = 3, its body back across to x = -0.5.
    local placement = TheContractorTippedTrailer.getPlacement(sample, 1, trailerSize)
    local straight = TheContractorTippedTrailer.getTractorPlacement(placement, trailerSize, tractorSize, 0.5)
    assertNear(straight.z, 4.5 + 2 + 2.5, 1e-9, "the trailer's half length, the gap and its own half length ahead")
    assertNear(straight.x, 3 - 1.25 - 0.3, 1e-9, "its side just in from the road's edge")
    assertNear(straight.rotY, 0, 1e-9, "along the road")
    local slewed = TheContractorTippedTrailer.getTractorPlacement(placement, trailerSize, tractorSize, 1)
    assertNear(slewed.rotY, math.rad(25), 1e-9)
    slewed = TheContractorTippedTrailer.getTractorPlacement(placement, trailerSize, tractorSize, 0)
    assertNear(slewed.rotY, -math.rad(25), 1e-9)
end)

test("no room for the tractor is another spot; a tractor that's busy isn't left at the scene", function()
    local world, tc = setup()
    local job, tractor = world:addHaulJob()
    world.tractorClear = function(tractorPlacement)
        return tractorPlacement.z > 120
    end
    local data = tc.TippedTrailer:rollTipping(1, job, rolls({}))
    assertTrue(data.tractorZ > 120, "a spot with room for both")
    assertEquals(data.tractorId, tractor.id)
    assertEquals(data.tractorUniqueId, tractor.uniqueId)

    world.tractorClear = function() return true end
    world.inCooldown[tractor.id] = nil
    world.busy[tractor.id] = true
    data = tc.TippedTrailer:rollTipping(1, job, rolls({}))
    assertEquals(data.tractorId, 0, "not moved off another job")
    assertEquals(data.tractorName, "")
    local incident = tc.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job)
    assertEquals(#world.tractorsPlaced, 0)
    assertEquals(world.messages[1].bodyKey, "tc_tippedTrailer_bodyNoTractor")
    assertTrue(incident ~= nil)
end)

test("a small job still costs the minimum reputation", function()
    local world, tc = setup()
    local job = world:addHaulJob({ baseReputation = 4 })
    tc.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job)
    assertEquals(world.reputation[1], -5)
end)

test("calling recovery: the scaled fee, charged and recorded, and both back to the parking queue", function()
    local world, tc = setup()
    local job, tractor, trailer = world:addHaulJob()
    tc.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job)
    local expected = tc.Settings:scaleCost(TheContractorTippedTrailer.RECOVERY_COST)
    assertTrue(expected > TheContractorTippedTrailer.RECOVERY_COST, "scaled up at the default job pay")

    local message = world.messages[1]
    local confirm = world.messageKind.getConfirmText(message, TheContractorTippedTrailer.ACTION.RECOVER)
    assertTrue(string.find(confirm, g_i18n:formatMoney(expected, 0, true, true), 1, true) ~= nil, confirm)
    assertEquals(world.messageKind.getConfirmText(message, TheContractorTippedTrailer.ACTION.DIY), nil)

    world:answer(TheContractorTippedTrailer.ACTION.RECOVER)
    assertEquals(world.money[1].amount, -expected)
    assertEquals(world.money[1].moneyType, "tcRecovery")
    assertEquals(world.recovery, expected)
    assertEquals(world.returned[1], trailer.id)
    assertEquals(world.returned[2], tractor.id, "the tractor back to the yard too")
    assertEquals(trailer.frozen, false, "unfrozen before it's parked")
    assertEquals(world.removedNotices[1], 1)
    assertEquals(next(tc.RandomEvents.incidents), nil, "closed")
    assertTrue(not tc.TippedTrailer:isTipped(trailer.id))
    assertTrue(not tc.TippedTrailer:isAtScene(tractor.id))
end)

test("doing it yourself: nothing charged, and the offer comes again if it's still over", function()
    local world, tc = setup()
    local job = world:addHaulJob()
    tc.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job)
    world:answer(TheContractorTippedTrailer.ACTION.DIY)
    assertEquals(#world.money, 0)
    assertEquals(getIncident(tc).stage, "diy")

    for _ = 1, 5 do
        world:nextDay()
    end
    assertEquals(#world.messages, 2, "offered again half a month later")
    assertEquals(getIncident(tc).stage, "offer")
end)

test("righted by the player, or sold: the incident closes and takes its message and notice", function()
    local world, tc = setup()
    local job, _, trailer = world:addHaulJob()
    tc.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job)

    tc.TippedTrailer:checkTrailers()
    assertTrue(tc.TippedTrailer:isTipped(trailer.id), "still on its side")

    assertTrue(trailer.frozen, "frozen while it's over")
    trailer.isOnSide = false
    tc.TippedTrailer:update(TheContractorTippedTrailer.CHECK_INTERVAL_MS)
    assertEquals(next(tc.RandomEvents.incidents), nil, "closed")
    assertEquals(trailer.frozen, false, "unfrozen")
    assertEquals(world.removedMessages[1], 1)
    assertEquals(world.removedNotices[1], 1)
    assertTrue(tc.Allocation:isVehicleFree(1, trailer), "free again")

    local world2, tc2 = setup()
    local job2, _, trailer2 = world2:addHaulJob()
    tc2.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job2)
    trailer2.isDeleted = true
    tc2.TippedTrailer:checkTrailers()
    assertEquals(next(tc2.RandomEvents.incidents), nil, "gone")
end)

test("after a load the trailer and tractor are found again by their uniqueIds", function()
    local world, tc = setup()
    local job, tractor, trailer = world:addHaulJob()
    local incident = tc.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job)
    -- Object ids from before the load.
    incident.data.vehicleId = 900
    incident.data.tractorId = 901
    trailer.frozen = false
    tc.TippedTrailer:resolveSavedVehicles()
    assertEquals(incident.data.vehicleId, trailer.id)
    assertEquals(incident.data.tractorId, tractor.id)
    assertTrue(trailer.frozen, "frozen again after the load")
end)

-- Pushing it back by hand ---------------------------------------------------------------

test("pushed back onto its wheels: unfrozen, stood up, message and notice gone, free again", function()
    local world, tc = setup()
    local job, tractor, trailer = world:addHaulJob()
    local incident = tc.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job)

    tc.TippedTrailer:rightTrailer(1, incident.id)

    assertTrue(trailer.stoodUp, "stood up")
    assertEquals(trailer.frozen, false, "unfrozen")
    assertEquals(world.removedMessages[1], 1)
    assertEquals(world.removedNotices[1], 1)
    assertEquals(next(tc.RandomEvents.incidents), nil, "closed")
    assertTrue(tc.Allocation:isVehicleFree(1, trailer), "free again")
    assertTrue(tc.Allocation:isVehicleFree(1, tractor), "the tractor too, wherever it's been driven")
    assertEquals(#world.money, 0, "nothing charged")
end)

test("after choosing to sort it yourself, the push works the same", function()
    local world, tc = setup()
    local job, _, trailer = world:addHaulJob()
    local incident = tc.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job)
    world:answer(TheContractorTippedTrailer.ACTION.DIY)
    tc.TippedTrailer:rightTrailer(1, incident.id)
    assertTrue(trailer.stoodUp)
    assertEquals(next(tc.RandomEvents.incidents), nil, "closed")
end)

test("another farm can't push it, and an unknown incident is ignored", function()
    local world, tc = setup()
    local job, _, trailer = world:addHaulJob()
    local incident = tc.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job)
    tc.TippedTrailer:rightTrailer(2, incident.id)
    tc.TippedTrailer:rightTrailer(1, incident.id + 50)
    assertEquals(trailer.stoodUp, nil)
    assertTrue(tc.TippedTrailer:isTipped(trailer.id), "still over")
end)

test("the prompt: the local farm's nearest tipped trailer within reach, only on foot", function()
    local world, tc = setup()
    world:load("src/util/TCTippedTrailerActivatable.lua")
    local job, _, trailer = world:addHaulJob()
    local incident = tc.RandomEvents:triggerEvent(1, TheContractorTippedTrailer.EVENT_TYPE, job)
    trailer.rootNode = { x = 100, z = 200 }

    local player = { x = 104, z = 200, vehicle = nil }
    function player:getCurrentVehicle() return self.vehicle end
    function player:getPosition() return self.x, 0, self.z end
    g_localPlayer = player

    local activatable = TCTippedTrailerActivatable.new()
    assertEquals(activatable.activateText, "Push the trailer back onto its wheels")
    assertTrue(activatable:getIsActivatable(), "in reach on foot")
    assertEquals(activatable.incidentId, incident.id)
    assertNear(activatable:getDistance(104, 0, 200), 4, 1e-9)

    player.x = 110
    assertTrue(not activatable:getIsActivatable(), "too far")
    player.x = 104
    player.vehicle = {}
    assertTrue(not activatable:getIsActivatable(), "not from a cab")
    player.vehicle = nil

    g_currentMission.getFarmId = function() return 2 end
    assertTrue(not activatable:getIsActivatable(), "another farm's")
    g_currentMission.getFarmId = function() return 1 end

    local sent = {}
    TCRightTrailerEvent = {
        new = function(farmId, incidentId)
            return { farmId = farmId, incidentId = incidentId }
        end,
    }
    g_client = { getServerConnection = function()
        return { sendEvent = function(_, event) table.insert(sent, event) end }
    end }
    assertTrue(activatable:getIsActivatable())
    activatable:run()
    assertEquals(sent[1].farmId, 1)
    assertEquals(sent[1].incidentId, incident.id)
end)
