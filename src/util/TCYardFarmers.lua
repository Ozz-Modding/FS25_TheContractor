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

-- personId -> { person, spot } for every farmer who should be in their
-- yard now.
function TCYardFarmers.getWanted()
    local wanted = {}
    local mission = g_currentMission
    local tc = mission.TheContractor
    if tc == nil or tc.Farmers == nil or tc.Yards == nil or mission.environment == nil then
        return wanted
    end
    local slot = TCYardFarmers.getSlot(TheContractorWorkingHours.getNow())
    if slot == nil then
        return wanted
    end
    local day = mission.environment.currentMonotonicDay or 0
    for _, person in ipairs(tc.Farmers:getFarmers()) do
        if TCYardFarmers.getReason(person, tc.Yards) == nil then
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
        local text
        if reason ~= nil then
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
