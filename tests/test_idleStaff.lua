-- Idle staff on standing spots (065): who stands, and the assignment every
-- machine works out for itself - the same answer for the same inputs, a new
-- shuffle each day, and as little moving about as it can manage when
-- someone comes or goes.

local function setup()
    local world = stubs.install()
    dofile("src/business/Worker.lua")
    dofile("src/business/WorkingHours.lua")
    dofile("src/placeables/PlaceableTCParkingSlot.lua")
    dofile("src/placeables/PlaceableTCStandingSpot.lua")
    dofile("src/placeables/PlaceableTCSeatSpot.lua")
    dofile("src/util/TCIdleStaff.lua")
    dofile("src/util/TCShelter.lua")
    dofile("src/util/TCFarmerYardSpots.lua")

    -- Stand nodes are plain tables holding their position and facing.
    entityExists = function() return true end
    getWorldTranslation = function(node) return node.x, 0, node.z end
    localDirectionToWorld = function(node) return 0, 0, 1 end
    MathUtil = { getYRotationFromDirection = function(dx, dz) return math.atan2(dx, dz) end }

    g_currentMission.environment = { currentMonotonicDay = 1, dayTime = 12 * 3600000 }
    g_currentMission.placeableSystem = { placeables = {} }
    g_currentMission.TheContractor.Staff = { workersByFarm = {} }
    return world
end

local function addSpot(farmId, x, z)
    local spot = { farmId = farmId }
    spot[PlaceableTCStandingSpot.KEY] = { standNode = { x = x, z = z } }
    function spot:getOwnerFarmId() return self.farmId end
    table.insert(g_currentMission.placeableSystem.placeables, spot)
    return spot
end

local function addWorker(farmId, id, status)
    local workersByFarm = g_currentMission.TheContractor.Staff.workersByFarm
    workersByFarm[farmId] = workersByFarm[farmId] or {}
    local worker = { id = id, farmId = farmId, name = "Worker " .. id, status = status }
    workersByFarm[farmId][id] = worker
    return worker
end

local function spotKeys(count)
    local keys = {}
    for i = 1, count do
        table.insert(keys, TCIdleStaff.getSpotKey(i * 3, 0))
    end
    return keys
end

local function countAssigned(assignment)
    local count, used = 0, {}
    for _, key in pairs(assignment) do
        assertTrue(not used[key], "two workers on spot " .. key)
        used[key] = true
        count = count + 1
    end
    return count
end

-- The spot this worker scores highest, of those given.
local function topSpot(farmId, day, workerId, keys)
    local best, bestScore = nil, -1
    for _, key in ipairs(keys) do
        local score = TCIdleStaff.getScore(farmId, day, workerId, key)
        if score > bestScore then
            best, bestScore = key, score
        end
    end
    return best
end

test("idle and cooldown workers stand; anyone away or busy doesn't", function()
    setup()
    local STATUS = TheContractorWorker.STATUS
    assertTrue(TCIdleStaff.isStandingStatus(STATUS.IDLE), "idle")
    for _, status in ipairs({ STATUS.COOLDOWN, STATUS.ASSIGNED, STATUS.DRIVING, STATUS.SICK, STATUS.HOLIDAY, STATUS.TRAINING }) do
        assertTrue(not TCIdleStaff.isStandingStatus(status), status)
    end
end)

test("spot keys round to the decimetre, so tiny float differences agree", function()
    setup()
    assertEquals(TCIdleStaff.getSpotKey(12.3401, -4.5599), TCIdleStaff.getSpotKey(12.3399, -4.5601))
    assertTrue(TCIdleStaff.getSpotKey(12.3, 4.5) ~= TCIdleStaff.getSpotKey(12.5, 4.5), "spots 20 cm apart differ")
end)

test("the same inputs give the same assignment, whatever order they come in", function()
    setup()
    local keys = spotKeys(5)
    local first = TCIdleStaff.assign(1, 7, { 1, 2, 3, 4 }, keys)
    local reversedKeys = {}
    for i = #keys, 1, -1 do
        table.insert(reversedKeys, keys[i])
    end
    local second = TCIdleStaff.assign(1, 7, { 4, 3, 2, 1 }, reversedKeys)
    for workerId = 1, 4 do
        assertEquals(second[workerId], first[workerId], "worker " .. workerId)
    end
end)

test("one worker per spot: extra workers left out, spare spots stay empty", function()
    setup()
    assertEquals(countAssigned(TCIdleStaff.assign(1, 1, { 1, 2, 3, 4, 5 }, spotKeys(3))), 3)
    assertEquals(countAssigned(TCIdleStaff.assign(1, 1, { 1, 2 }, spotKeys(5))), 2)
    assertEquals(countAssigned(TCIdleStaff.assign(1, 1, {}, spotKeys(5))), 0)
    assertEquals(countAssigned(TCIdleStaff.assign(1, 1, { 1, 2 }, {})), 0)
end)

test("a new day reshuffles", function()
    setup()
    local workers, keys = { 1, 2, 3, 4 }, spotKeys(4)
    local dayOne = TCIdleStaff.assign(1, 1, workers, keys)
    local changedDays = 0
    for day = 2, 11 do
        local assignment = TCIdleStaff.assign(1, day, workers, keys)
        for _, workerId in ipairs(workers) do
            if assignment[workerId] ~= dayOne[workerId] then
                changedDays = changedDays + 1
                break
            end
        end
    end
    assertTrue(changedDays >= 5, "only " .. changedDays .. " of 10 days moved anyone")
end)

test("a worker coming or going leaves anyone on their favourite spot where they are", function()
    setup()
    local keys = spotKeys(8)
    for day = 1, 20 do
        local before = TCIdleStaff.assign(1, day, { 1, 2, 3, 4, 5 }, keys)
        local after = TCIdleStaff.assign(1, day, { 1, 2, 4, 5 }, keys)
        for _, workerId in ipairs({ 1, 2, 4, 5 }) do
            if before[workerId] == topSpot(1, day, workerId, keys) then
                assertEquals(after[workerId], before[workerId], "day " .. day .. " worker " .. workerId)
            end
        end
    end
end)

test("each farm's idle workers go on that farm's own spots", function()
    setup()
    local STATUS = TheContractorWorker.STATUS
    addSpot(1, 0, 0)
    addSpot(1, 5, 0)
    local farmTwoSpot = addSpot(2, 50, 50)
    addWorker(1, 1, STATUS.IDLE)
    addWorker(1, 2, STATUS.COOLDOWN)
    addWorker(1, 3, STATUS.SICK)
    addWorker(1, 4, STATUS.ASSIGNED)
    addWorker(2, 5, STATUS.IDLE)
    addWorker(3, 6, STATUS.IDLE)

    local wanted = TCIdleStaff.getWanted()
    assertTrue(wanted[1] ~= nil, "farm 1's idle worker stands")
    assertEquals(wanted[2], nil, "in a cooldown, still out with the machines")
    assertEquals(wanted[1].spot.placeable:getOwnerFarmId(), 1)
    assertEquals(wanted[3], nil, "sick")
    assertEquals(wanted[4], nil, "assigned")
    assertEquals(wanted[5].spot.placeable, farmTwoSpot, "farm 2's worker on farm 2's spot")
    assertEquals(wanted[5].worker.id, 5)
    assertEquals(wanted[6], nil, "farm 3 has no spots")
end)

-- 090: office staff stand about too, unless they're away training. A farm
-- with only office staff still gets its spots used.
test("office staff stand on their farm's spots unless training", function()
    setup()
    dofile("src/business/Office.lua")
    addSpot(1, 0, 0)
    addSpot(1, 5, 0)
    addSpot(1, 10, 0)
    addWorker(1, 1, TheContractorWorker.STATUS.IDLE)
    local office = TheContractorOffice.new()
    office.membersByFarm[1] = {
        administrator = { id = 7, role = "administrator", farmId = 1, name = "Ann", level = 1 },
    }
    g_currentMission.TheContractor.Office = office

    local wanted = TCIdleStaff.getWanted()
    assertTrue(wanted[1] ~= nil, "the idle worker")
    assertEquals(wanted[7].worker.name, "Ann", "the administrator")

    g_currentMission.TheContractor.Staff.workersByFarm = {}
    assertTrue(TCIdleStaff.getWanted()[7] ~= nil, "office only")

    office.membersByFarm[1].administrator.trainingUntilDay = 4
    assertEquals(TCIdleStaff.getWanted()[7], nil, "on a course")
end)

test("a sold spot drops out", function()
    setup()
    local spot = addSpot(1, 0, 0)
    addWorker(1, 1, TheContractorWorker.STATUS.IDLE)
    assertTrue(TCIdleStaff.getWanted()[1] ~= nil, "standing while the spot's there")
    spot.markedForDeletion = true
    assertEquals(TCIdleStaff.getWanted()[1], nil)
end)

test("staff are only about during working hours", function()
    setup()
    addSpot(1, 0, 0)
    addWorker(1, 1, TheContractorWorker.STATUS.IDLE)
    local environment = g_currentMission.environment
    local function at(hour, minute)
        environment.dayTime = (hour * 60 + minute) * 60000
        return TCIdleStaff.getWanted()[1] ~= nil
    end
    assertTrue(not at(7, 59), "before 08:00")
    assertTrue(at(8, 0), "from 08:00")
    assertTrue(at(17, 59), "until 18:00")
    assertTrue(not at(18, 0), "gone home at 18:00")
    assertTrue(not at(0, 0), "midnight")
end)

-- 097: after hours, only those kept on (once they're in). The office goes
-- home, and anyone in a job's cooldown is still out with the machines.
test("after hours: staff kept on stand, the rest and the office go home", function()
    setup()
    dofile("src/business/Office.lua")
    for i = 1, 4 do
        addSpot(1, i * 5, 0)
    end
    local day = 1 * 24 * 60
    local staying = addWorker(1, 1, TheContractorWorker.STATUS.IDLE)
    staying.dutyFrom, staying.dutyArrive, staying.dutyUntil = day + 17 * 60, day + 17 * 60, day + 22 * 60
    local comingIn = addWorker(1, 2, TheContractorWorker.STATUS.IDLE)
    comingIn.dutyFrom, comingIn.dutyArrive, comingIn.dutyUntil = day + 19 * 60, day + 19 * 60 + 25, day + 22 * 60
    addWorker(1, 3, TheContractorWorker.STATUS.IDLE)
    addWorker(1, 4, TheContractorWorker.STATUS.COOLDOWN)
    local office = TheContractorOffice.new()
    office.membersByFarm[1] = { administrator = { id = 7, role = "administrator", farmId = 1, name = "Ann", level = 1 } }
    g_currentMission.TheContractor.Office = office

    g_currentMission.environment.dayTime = (19 * 60 + 10) * 60000
    local wanted = TCIdleStaff.getWanted()
    assertTrue(wanted[1] ~= nil, "staying late")
    assertEquals(wanted[2], nil, "not in yet")
    assertEquals(wanted[3], nil, "gone home")
    assertEquals(wanted[4], nil, "still in a cooldown")
    assertEquals(wanted[7], nil, "the office has gone home")

    g_currentMission.environment.dayTime = (19 * 60 + 30) * 60000
    assertTrue(TCIdleStaff.getWanted()[2] ~= nil, "in now")
    g_currentMission.environment.dayTime = 22 * 60 * 60000
    wanted = TCIdleStaff.getWanted()
    assertEquals(wanted[1], nil, "their time's up")
    assertEquals(wanted[2], nil, "theirs too")
end)
