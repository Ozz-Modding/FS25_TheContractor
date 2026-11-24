-- The staff's day off for the show (172): the pure half, every machine.
-- TheContractorShowDayOff (src/business/ShowDayOff.lua) asks and books it;
-- TCShowStandsWorld puts the staff on the showground.
--
--   The ask: ASK_MONTHS before the show's day (getAskDay, in days scaled
--     with the month, at least a day before), worked out from the show's
--     day whenever it's needed, so it moves with the day (161).
--   The answer's morale (MORALE): yes a lift for everyone, no a knock
--     smaller than a refused holiday's (089's first).
--   On the showground: the staff at the show take the ringside places left
--     after the farmers (171's mingles), then the ring's spectator spots
--     (whose crowd figures stand aside for them, TCAuctionCrowd.
--     setReservedSpots), each from the show, the slot and their id
--     (assignPlaces), so every machine has them in the same place.
--
-- Tested in tests/test_showDayOff.lua.

TCShowDayOff = {}

-- The ask, this much of a month before the day (about three weeks).
TCShowDayOff.ASK_MONTHS = 0.75

-- Morale (056's points) for everyone on the roster.
TCShowDayOff.MORALE = { yes = 3, no = -3 }

-- A farm's answer for the show (every machine).
TCShowDayOff.ANSWER = {
    ASKED = 1,
    YES = 2,
    NO = 3,
}

-- Salt for the places' hash (171's farmers use 1710 + slot).
local PLACE_SALT = 1720

-- The day the ask goes out, for a show on showDay (pure).
function TCShowDayOff.getAskDay(showDay, daysPerPeriod)
    return showDay - math.max(1, math.floor(TCShowDayOff.ASK_MONTHS * (daysPerPeriod or 1) + 0.5))
end

-- Whether a farm not asked yet should be now (pure): from the ask day
-- until the day before the show.
function TCShowDayOff.isAskDue(today, askDay, showDay)
    return today >= askDay and today < showDay
end

-- The morale change for an answer (pure).
function TCShowDayOff.getMoraleDelta(isYes)
    return isYes and TCShowDayOff.MORALE.yes or TCShowDayOff.MORALE.no
end

local function placeKey(x, z)
    return string.format("%.2f,%.2f", x, z)
end

-- The places the staff can stand on (pure): the mingles no farmer's on,
-- then the ring's spectator spots. layout: TCShowScene.layOut's; taken:
-- the farmers' places (personId -> spot). Each { x, z, yaw, isCrowdSpot }.
function TCShowDayOff.getFreePlaces(layout, taken)
    local used = {}
    for _, spot in pairs(taken or {}) do
        used[placeKey(spot.x, spot.z)] = true
    end
    local places = {}
    for _, spot in ipairs(layout.mingles or {}) do
        if not used[placeKey(spot.x, spot.z)] then
            table.insert(places, { x = spot.x, z = spot.z, yaw = spot.yaw, isCrowdSpot = false })
        end
    end
    local ring = TCShowScene ~= nil and TCShowScene.SPOT.RING or "ring"
    for _, spot in ipairs(layout.spots or {}) do
        if spot.category == ring then
            table.insert(places, { x = spot.x, z = spot.z, yaw = spot.yaw, isCrowdSpot = true })
        end
    end
    return places
end

-- Each of the staff's place in a slot (pure): ids in turn (sorted, so the
-- order they're given in doesn't matter), each on a free place (not a
-- crowd spot) while there are any, else a crowd spot: within those, from
-- the show, the slot and their id, stepping on past a place already taken.
-- Anyone past the places there are gets none. Returns id -> place.
function TCShowDayOff.assignPlaces(showId, slot, ids, places)
    local result = {}
    local tiers = { {}, {} }
    for _, place in ipairs(places) do
        table.insert(tiers[place.isCrowdSpot and 2 or 1], { place = place })
    end
    local sorted = {}
    for i, id in ipairs(ids) do
        sorted[i] = id
    end
    table.sort(sorted)
    for _, id in ipairs(sorted) do
        local pick = TCAuctionScene.hash(showId or 0, PLACE_SALT + (slot or 0), id)
        for _, tier in ipairs(tiers) do
            local count = #tier
            local start = math.floor(pick * count)
            for step = 0, count - 1 do
                local entry = tier[(start + step) % count + 1]
                if not entry.taken then
                    entry.taken = true
                    result[id] = entry.place
                    break
                end
            end
            if result[id] ~= nil then
                break
            end
        end
    end
    return result
end
