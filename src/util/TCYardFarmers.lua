-- Farmers in their yards (114). A farmer with a yard (108, 110) is shown
-- standing in it in daylight (VISIBLE_FROM to VISIBLE_TO, game time), in
-- their own look, on one of the yard's open spots, while no player owns
-- the yard's farmland.
--
-- Like the idle staff on standing spots (065, TCIdleStaff), it's only
-- visual, local to each machine with a client, with no state, events or
-- saving of its own. Every machine picks the same spot from synced state
-- only: the day, the time of day, the farmer's id and the yard's spot
-- list, which is the server's (TheContractorYards:getSpots), since a client
-- can't work the same list out for itself. Daylight is split into slots of
-- SLOT_HOURS, with a spot for each, from our own hash, never math.random.
-- In a yard with a farmhouse, a slot is spent near it (a spot marked
-- nearHouse) NEAR_HOUSE_PERCENT of the time, and on any spot otherwise. A
-- farmer faces the yard's middle and turns to a local player who walks up.
-- A farmer with a favour open (116), or one of their machines broken down
-- (101, 123) or run dry (127), waits by the machine instead, yard or field,
-- day or night (getMachineSpot).
--
-- Showing them is TCIdleStaff's: a HumanGraphicsComponent from their look,
-- loaded within LOAD_DISTANCE and freed beyond UNLOAD_DISTANCE, so a map
-- with many farmers only holds the ones near the player, and nobody
-- appears, leaves or moves while the player can see the spot. There's no
-- blocker: a yard spot isn't a placeable, so a player can walk through a
-- farmer.

TCYardFarmers = {}

-- Hours of the game day a farmer is about: from VISIBLE_FROM up to
-- VISIBLE_TO.
TCYardFarmers.VISIBLE_FROM = 7
TCYardFarmers.VISIBLE_TO = 19
-- A farmer may move (out of view) every this many hours.
TCYardFarmers.SLOT_HOURS = 3
-- The chance (percent) a slot is spent near the farmhouse, if the yard has
-- spots near one.
TCYardFarmers.NEAR_HOUSE_PERCENT = 50
-- How often (ms) who-should-stand-where is worked out again.
TCYardFarmers.RECHECK_MS = 2000
-- A spot nearer the yard's middle than this (metres) faces north rather
-- than towards it.
TCYardFarmers.MIDDLE_DISTANCE = 0.5

local MINUTES_PER_DAY = 24 * 60

-- Who stands where (pure, every machine) --------------------------------------

function TCYardFarmers.isVisibleTime(minutes)
    local minute = minutes % MINUTES_PER_DAY
    return minute >= TCYardFarmers.VISIBLE_FROM * 60 and minute < TCYardFarmers.VISIBLE_TO * 60
end

-- Which slot of daylight it is (0 at VISIBLE_FROM), or nil outside it.
function TCYardFarmers.getSlot(minutes)
    if not TCYardFarmers.isVisibleTime(minutes) then
        return nil
    end
    return math.floor((minutes % MINUTES_PER_DAY - TCYardFarmers.VISIBLE_FROM * 60) / (TCYardFarmers.SLOT_HOURS * 60))
end

-- Which of a yard's spots (1-based) a farmer stands on in a day's slot, or
-- nil with none.
function TCYardFarmers.pickSpot(day, slot, personId, spots)
    if #spots == 0 then
        return nil
    end
    local nearHouse = {}
    for index, spot in ipairs(spots) do
        if spot.nearHouse then
            table.insert(nearHouse, index)
        end
    end
    local roll = TCYardFarmers.hashSpot(day, slot, personId, "house") % 100
    local pick = TCYardFarmers.hashSpot(day, slot, personId, "spot")
    if #nearHouse > 0 and roll < TCYardFarmers.NEAR_HOUSE_PERCENT then
        return nearHouse[pick % #nearHouse + 1]
    end
    return pick % #spots + 1
end

-- TCIdleStaff.hash is affine in each character, so from one slot to the
-- next it moves by the same amount, and its remainder by a small spot count
-- hardly changes. Squaring (in a modulus small enough for doubles to hold
-- the square exactly) breaks that up.
local MIX_MODULUS = 65521
function TCYardFarmers.hashSpot(day, slot, personId, purpose)
    local h = TCIdleStaff.hash(string.format("yard|%s|%d|%d|%d", purpose, day, slot, personId)) % MIX_MODULUS
    for round = 1, 3 do
        h = (h * h + round * 7919) % MIX_MODULUS
    end
    return h
end

-- Why a farmer can't stand in their yard (at any time of day), or nil if
-- they can. yards: tc.Yards.
function TCYardFarmers.getReason(person, yards)
    if person.isOfficial or person.yardFarmlandId == nil then
        return "no yard on the map"
    end
    local farmlandId = person.yardFarmlandId
    if g_farmlandManager:getFarmlandOwner(farmlandId) ~= FarmlandManager.NO_OWNER_FARM_ID then
        return string.format("yard %d is owned by a player", farmlandId)
    end
    local entry = yards:getSpots(farmlandId)
    if entry == nil or #entry.spots == 0 then
        return string.format("yard %d has no open spots", farmlandId)
    end
    return nil
end

-- The spot a farmer stands on in a day's slot: { key, x, y, z, yaw,
-- nearHouse }.
function TCYardFarmers.getSpot(person, entry, day, slot)
    local index = TCYardFarmers.pickSpot(day, slot, person.id, entry.spots)
    local point = entry.spots[index]
    local y = getTerrainHeightAtWorldPos(g_terrainNode, point.x, 0, point.z)
    local dx, dz = entry.x - point.x, entry.z - point.z
    local distance = math.sqrt(dx * dx + dz * dz)
    local yaw = 0
    if distance > TCYardFarmers.MIDDLE_DISTANCE then
        yaw = MathUtil.getYRotationFromDirection(dx / distance, dz / distance)
    end
    return {
        key = string.format("%d:%d", person.yardFarmlandId, index),
        x = point.x,
        y = y,
        z = point.z,
        yaw = yaw,
        nearHouse = point.nearHouse,
    }
end

-- 116: a farmer who's asked a favour waits by their machine instead, at any
-- time of day, while the favour's on offer or taken on and the machine's on
-- this machine's map: beside it, FAVOUR_GAP out from its side and
-- FAVOUR_FORWARD of its length ahead of its middle, facing its middle. In a
-- yard they stand on the side nearer the yard's middle (the open side,
-- away from walls); on a field, a side by our hash. The machine's synced,
-- so every machine has the same spot. Its key has the machine's position
-- (to FAVOUR_KEY_GRID metres), so a moved machine moves them, out of view.
-- 123: the same for a breakdown (101) of one of their machines, in the yard
-- or on the field. 127: and for a refuel, once its machine's out on the
-- field (it's only brought out as the job's taken on), until the job's
-- over. With two open at once, the lower job id's, so every machine picks
-- the same one.
TCYardFarmers.FAVOUR_GAP = 1
TCYardFarmers.FAVOUR_FORWARD = 0.25
TCYardFarmers.FAVOUR_KEY_GRID = 2

local function isMachineJobOpen(job)
    local state = job.state
    -- 127: taken on (the machine's only out from then).
    if job.refuel ~= nil then
        return state == TheContractorJob.STATE.ACCEPTED or state == TheContractorJob.STATE.ALLOCATED or
            state == TheContractorJob.STATE.IN_PROGRESS
    end
    return (TheContractorRepairContracts.isFavourJob(job) or TheContractorRepairContracts.isBreakdownJob(job)) and
        (state == TheContractorJob.STATE.OFFERED or state == TheContractorJob.STATE.NEGOTIATING or
        state == TheContractorJob.STATE.ACCEPTED)
end

-- A machine job's machine, if it's on this machine's map.
local function getJobMachine(job)
    if job.refuel ~= nil then
        return TheContractorEmergencyRefuel.getMachine(job.refuel)
    end
    return TheContractorRepairContracts.getVehicle(job)
end

-- The open favour this farmer asked, or breakdown of their machine (123)
-- or refuel (127), with its machine, or nil. The farmer's the job's
-- customer (workshop.farmerId stays on the server).
function TCYardFarmers.getMachineJob(person, jobs)
    if TheContractorRepairContracts == nil or jobs == nil then
        return nil
    end
    local found, foundVehicle = nil, nil
    for _, farmJobs in pairs(jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.customerId == person.id and isMachineJobOpen(job) and (found == nil or job.id < found.id) then
                local vehicle = getJobMachine(job)
                if vehicle ~= nil and vehicle.rootNode ~= nil then
                    found, foundVehicle = job, vehicle
                end
            end
        end
    end
    return found, foundVehicle
end

-- Where to stand beside a machine at (x, z) heading (dirX, dirZ), width by
-- length: x, z and the yaw facing its middle. side is 1 or -1; with
-- (towardX, towardZ) given, the side nearer that point instead.
function TCYardFarmers.getBesideSpot(x, z, dirX, dirZ, width, length, side, towardX, towardZ)
    local sideX, sideZ = dirZ, -dirX
    if towardX ~= nil then
        side = (towardX - x) * sideX + (towardZ - z) * sideZ >= 0 and 1 or -1
    end
    local out = width * 0.5 + TCYardFarmers.FAVOUR_GAP
    local ahead = length * TCYardFarmers.FAVOUR_FORWARD
    local px = x + sideX * out * side + dirX * ahead
    local pz = z + sideZ * out * side + dirZ * ahead
    return px, pz, MathUtil.getYRotationFromDirection(x - px, z - pz)
end

-- The spot by a favour's, breakdown's or refuel's machine, in getSpot's
-- shape.
function TCYardFarmers.getMachineSpot(person, job, vehicle, yards)
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    local dirX, _, dirZ = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    local length = math.sqrt(dirX * dirX + dirZ * dirZ)
    if length < 0.001 then
        dirX, dirZ, length = 0, 1, 1
    end
    dirX, dirZ = dirX / length, dirZ / length
    local size = vehicle.size or {}
    local towardX, towardZ = nil, nil
    local yardFarmlandId = job.workshop ~= nil and job.workshop.yardFarmlandId or nil
    local entry = yardFarmlandId ~= nil and yards ~= nil and yards:getSpots(yardFarmlandId) or nil
    if entry ~= nil then
        towardX, towardZ = entry.x, entry.z
    end
    local side = TCYardFarmers.hashSpot(job.id, 0, person.id, "favour") % 2 == 0 and 1 or -1
    local px, pz, yaw = TCYardFarmers.getBesideSpot(x, z, dirX, dirZ, size.width or 3, size.length or 5, side,
        towardX, towardZ)
    local grid = TCYardFarmers.FAVOUR_KEY_GRID
    return {
        key = string.format("favour:%d:%d:%d", job.id, math.floor(x / grid + 0.5), math.floor(z / grid + 0.5)),
        x = px,
        y = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz),
        z = pz,
        yaw = yaw,
        jobId = job.id,
    }
end

-- personId -> { person, spot } for every farmer who should be in their
-- yard (or by their favour's or broken-down machine) now.
function TCYardFarmers.getWanted()
    local wanted = {}
    local mission = g_currentMission
    local tc = mission.TheContractor
    if tc == nil or tc.Farmers == nil or tc.Yards == nil or mission.environment == nil then
        return wanted
    end
    local slot = TCYardFarmers.getSlot(TheContractorWorkingHours.getNow())
    local day = mission.environment.currentMonotonicDay or 0
    for _, person in ipairs(tc.Farmers:getFarmers()) do
        local job, vehicle = TCYardFarmers.getMachineJob(person, tc.Jobs)
        if job ~= nil then
            wanted[person.id] = { person = person, spot = TCYardFarmers.getMachineSpot(person, job, vehicle, tc.Yards) }
        elseif slot ~= nil and TCYardFarmers.getReason(person, tc.Yards) == nil then
            wanted[person.id] = {
                person = person,
                spot = TCYardFarmers.getSpot(person, tc.Yards:getSpots(person.yardFarmlandId), day, slot),
            }
        end
    end
    return wanted
end

-- Showing them (clients) ------------------------------------------------------

-- figures[personId]: a TCIdleStaff figure, only while they're in their
-- yard. noStyle[personId]: their look couldn't be built. Farmers' ids are
-- their own, so none of this is shared with TCIdleStaff's.
TCYardFarmers.figures = {}
TCYardFarmers.noStyle = {}
TCYardFarmers.wanted = {}
TCYardFarmers.recheckMs = 0

-- loadMap and deleteMap: frees every model.
function TCYardFarmers.reset()
    for _, figure in pairs(TCYardFarmers.figures) do
        TCIdleStaff.freeModel(figure)
    end
    TCYardFarmers.figures = {}
    TCYardFarmers.noStyle = {}
    TCYardFarmers.wanted = {}
    TCYardFarmers.recheckMs = 0
end

-- A farmer's look changed (111): they stay where they are and the next
-- update loads the new model, if they're close enough to need one.
function TCYardFarmers.reloadLook(person)
    TCYardFarmers.noStyle[person.id] = nil
    local figure = TCYardFarmers.figures[person.id]
    if figure ~= nil then
        figure.person = person
        TCIdleStaff.freeModel(figure)
    end
end

function TCYardFarmers.updatePerson(personId, entry, dt, camera, cx, cy, cz)
    local figure = TCYardFarmers.figures[personId]

    -- Off their spot once they're not wanted on it and nobody can see it.
    if figure ~= nil and (entry == nil or entry.spot.key ~= figure.spot.key) and
            not TCIdleStaff.isSeen(figure.spot, camera, cx, cy, cz) then
        TCIdleStaff.freeModel(figure)
        TCYardFarmers.figures[personId] = nil
        figure = nil
    end

    -- Onto the spot they're wanted on once nobody can see it.
    if figure == nil and entry ~= nil and not TCIdleStaff.isSeen(entry.spot, camera, cx, cy, cz) then
        figure = { person = entry.person, spot = entry.spot, yaw = entry.spot.yaw, graphics = nil, isReady = false,
            isVisible = false }
        TCYardFarmers.figures[personId] = figure
    end

    if figure ~= nil then
        TCIdleStaff.updateModel(personId, figure, TCYardFarmers.noStyle, dt, cx, cy, cz)
    end
end

function TCYardFarmers.update(dt)
    local mission = g_currentMission
    if mission == nil or not mission:getIsClient() then
        return
    end

    TCYardFarmers.recheckMs = TCYardFarmers.recheckMs - dt
    if TCYardFarmers.recheckMs <= 0 then
        TCYardFarmers.recheckMs = TCYardFarmers.RECHECK_MS
        TCYardFarmers.wanted = TCYardFarmers.getWanted()
    end

    local camera = TCIdleStaff.getCamera()
    if camera == nil then
        return
    end
    local cx, cy, cz = getWorldTranslation(camera)

    local personIds = {}
    for personId in pairs(TCYardFarmers.figures) do
        personIds[personId] = true
    end
    for personId in pairs(TCYardFarmers.wanted) do
        personIds[personId] = true
    end
    for personId in pairs(personIds) do
        TCYardFarmers.updatePerson(personId, TCYardFarmers.wanted[personId], dt, camera, cx, cy, cz)
    end
end

-- Console ---------------------------------------------------------------------

-- tcCompany farmers standing: where each farmer is now, and why anyone
-- isn't in their yard.
function TCYardFarmers.describe()
    local mission = g_currentMission
    local tc = mission.TheContractor
    local now = TheContractorWorkingHours.getNow()
    local day = mission.environment.currentMonotonicDay or 0
    local slot = TCYardFarmers.getSlot(now)
    local lines = {}
    if slot == nil then
        table.insert(lines, string.format("Farmers in their yards, day %d: outside daylight (%02d:00-%02d:00), " ..
            "nobody's about", day, TCYardFarmers.VISIBLE_FROM, TCYardFarmers.VISIBLE_TO))
    else
        local slotStart = TCYardFarmers.VISIBLE_FROM + slot * TCYardFarmers.SLOT_HOURS
        table.insert(lines, string.format("Farmers in their yards, day %d, %02d:00-%02d:00:", day, slotStart,
            math.min(slotStart + TCYardFarmers.SLOT_HOURS, TCYardFarmers.VISIBLE_TO)))
    end

    local camera = TCIdleStaff.getCamera()
    local cx, cy, cz = 0, 0, 0
    if camera ~= nil then
        cx, cy, cz = getWorldTranslation(camera)
    end
    for _, person in ipairs(tc.Farmers:getFarmers()) do
        local reason = TCYardFarmers.getReason(person, tc.Yards)
        local figure = TCYardFarmers.figures[person.id]
        local machineJob, machineVehicle = TCYardFarmers.getMachineJob(person, tc.Jobs)
        local text
        if machineJob ~= nil then
            local spot = TCYardFarmers.getMachineSpot(person, machineJob, machineVehicle, tc.Yards)
            local what = "broken-down"
            if machineJob.refuel ~= nil then
                what = "empty"
            elseif TheContractorRepairContracts.isFavourJob(machineJob) then
                what = "favour's"
            end
            text = string.format("by their %s machine (job %d) at %.0f, %.0f, %.0f m away", what, machineJob.id,
                spot.x, spot.z, MathUtil.vector3Length(spot.x - cx, spot.y - cy, spot.z - cz))
            if figure == nil then
                text = text .. ", not there yet"
            elseif figure.spot.key ~= spot.key then
                text = text .. string.format(", still on spot %s until you look away", figure.spot.key)
            end
        elseif reason ~= nil then
            text = reason
        elseif slot == nil then
            text = string.format("yard %d", person.yardFarmlandId)
            if figure ~= nil then
                text = text .. string.format(", still on spot %s until you look away", figure.spot.key)
            end
        else
            local entry = tc.Yards:getSpots(person.yardFarmlandId)
            local nearCount = 0
            for _, point in ipairs(entry.spots) do
                nearCount = nearCount + (point.nearHouse and 1 or 0)
            end
            local spot = TCYardFarmers.getSpot(person, entry, day, slot)
            text = string.format("yard %d, spot %s of %d (%d near the farmhouse)%s at %.0f, %.0f, %.0f m away",
                person.yardFarmlandId, spot.key, #entry.spots, nearCount, spot.nearHouse and ", by the house" or "",
                spot.x, spot.z, MathUtil.vector3Length(spot.x - cx, spot.y - cy, spot.z - cz))
            if figure == nil then
                text = text .. ", not there yet"
            elseif figure.spot.key ~= spot.key then
                text = text .. string.format(", still on spot %s until you look away", figure.spot.key)
            elseif TCYardFarmers.noStyle[person.id] then
                text = text .. ", there, but their look couldn't be loaded"
            elseif figure.graphics == nil then
                text = text .. string.format(", there, model not loaded (loads within %d m)", TCIdleStaff.LOAD_DISTANCE)
            elseif not figure.isReady then
                text = text .. ", there, model loading"
            elseif figure.isVisible then
                text = text .. ", there, shown"
            else
                text = text .. ", there, hidden (too far)"
            end
        end
        table.insert(lines, string.format("  #%d %s - %s", person.id, person.name, text))
    end
    return table.concat(lines, "\n")
end
