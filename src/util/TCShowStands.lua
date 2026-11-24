-- The show's stands and the farmers about the showground (171): the pure
-- half, every machine. TheContractorShowStands (src/business/ShowStands.lua)
-- holds who's been where and does what a visit does; TCShowStandsWorld puts
-- the people on the showground and runs the conversations.
--
--   Open: on the show's day, from the gates opening to their closing
--     (isOpen), on a showground laid out with the show's dressing.
--   The stalls: TCShowScene's two stands with a table and a stallholder, the
--     trade association's (an offer to join on the day at a discount on the
--     first term, JOIN_DISCOUNT; a member gets a cup of tea) and the careers
--     stand (CAREERS: a few young candidates kept for the farm for a week).
--   Farmers at the show: the host and up to FARMERS_AT_SHOW others, picked
--     from the show's id (pickFarmers), never one ploughing a plot (169).
--     Each stands at one of the scene's farmers' spots (TCShowScene's
--     mingles), a new one every SLOT_HOURS (assignSpots), from synced state
--     only, so every machine has them in the same place.
--   Talking to one: a line about the show; "any work going?" rolls once a
--     farm per farmer per show (getOfferChance, on the relationship), and
--     a hit is an offer from them as any other.
--   Showing your face: the attend job done is a small lift with the host
--     (HOST_OPINION), and the first talk with each farmer a smaller one
--     (TALK_OPINION), neither letting word get round (129).
--
-- Tested in tests/test_showStands.lua.

TCShowStands = {}

-- Farmers at the show besides the host.
TCShowStands.FARMERS_AT_SHOW = 5
-- Farmers move to another spot every this many hours of the open day.
TCShowStands.SLOT_HOURS = 2
-- Metres from a stallholder or a farmer a player can talk to them.
TCShowStands.STALL_DISTANCE = 3
TCShowStands.TALK_DISTANCE = 2.5

-- "Any work going?": the chance of an offer, BASE at a neutral
-- relationship, SWING more (or less) at the best (or worst), between MIN
-- and MAX. A farmer who's fallen out (113's refuses) never has any.
TCShowStands.OFFER_CHANCE = { base = 0.4, swing = 0.3, min = 0.1, max = 0.7 }

-- Opinion (113's points): the host, for the attend job done; a farmer, the
-- first time a farm talks to them at a show.
TCShowStands.HOST_OPINION = 2
TCShowStands.TALK_OPINION = 1

-- Off the association's first term (053's membership), joined at the show.
TCShowStands.JOIN_DISCOUNT = 0.25

-- The careers stand: candidates kept for the farm (count), for a week
-- (weekMonths of a month, at least a day), each the younger of ageRolls
-- rolls between Staff's MIN_AGE and maxAge.
TCShowStands.CAREERS = { count = 3, weekMonths = 0.25, maxAge = 25, ageRolls = 2 }

-- What a player asks (TCShowTalkEvent).
TCShowStands.REQUEST = {
    TALK = 1,           -- spoke to a farmer (the first time: the opinion lift)
    ASK = 2,            -- "any work going?"
    JOIN_ANNUAL = 3,    -- join the association, paying for the year
    JOIN_MONTHLY = 4,   -- or by the month
    CAREERS = 5,        -- pass the farm's details to the careers stand
}

-- The server's answer.
TCShowStands.ANSWER = {
    OK = 1,             -- TALK done
    OFFER = 2,          -- an offer's on its way (value: the job's id)
    NO_WORK = 3,
    ASKED = 4,          -- this farm's asked them already this show
    REFUSED = 5,        -- fallen out
    NO_COMPANY = 6,
    CLOSED = 7,         -- not open now, or they're not at the show
    JOINED = 8,         -- value: what was paid
    MEMBER = 9,         -- a member already
    CANT_AFFORD = 10,
    SENT = 11,          -- value: candidates added
    VISITED = 12,       -- the careers stand's done for this farm this show
}

-- How many variants each line has (tc_showTalk_<line>_<n>). Text only: a
-- client picks one as it likes.
TCShowStands.LINES = {
    greet = 4,          -- a farmer about the show
    greetHost = 3,      -- the host
    curt = 2,           -- fallen out
    thinking = 2,       -- after "any work going?", before the answer
    offer = 3,
    noWork = 3,
    asked = 2,
    associationOffer = 1,
    associationMember = 2,
    associationJoined = 2,
    associationLater = 2,
    associationCantAfford = 1,
    associationNoCompany = 1,
    careersOffer = 1,
    careersSent = 2,
    careersVisited = 1,
    careersLater = 1,
    careersNoCompany = 1,
    closed = 1,
}

-- Queries (pure) ---------------------------------------------------------------------------------

-- Whether the stands are open: the show's day, in its hours (the hour with
-- minutes as a fraction).
function TCShowStands.isOpen(event, today, hour, fromHour, toHour)
    return event ~= nil and event.day == today and hour >= fromHour and hour < toHour
end

-- Which slot of the open day an hour's in (0 from fromHour), or nil.
function TCShowStands.getSlot(hour, fromHour, toHour)
    if hour < fromHour or hour >= toHour then
        return nil
    end
    return math.floor((hour - fromHour) / TCShowStands.SLOT_HOURS)
end

-- Who's at the show: the host first (if they're a farmer here), then up to
-- count of the others in an order from the show's id, never one in
-- excluded (personId -> true). farmers: { { id } }. Returns their ids.
function TCShowStands.pickFarmers(showId, farmers, hostId, excluded, count)
    excluded = excluded or {}
    count = count or TCShowStands.FARMERS_AT_SHOW
    local ids, others = {}, {}
    for _, person in ipairs(farmers) do
        if person.id == hostId then
            table.insert(ids, 1, person.id)
        elseif not excluded[person.id] then
            table.insert(others, { id = person.id, order = TCAuctionScene.hash(showId or 0, 171, person.id) })
        end
    end
    table.sort(others, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.id < b.id
    end)
    for i = 1, math.min(count, #others) do
        table.insert(ids, others[i].id)
    end
    return ids
end

-- Each farmer's spot (1 to spotCount) in a slot: farmerIds in turn, each
-- from the show, the slot and their id, stepping on past a spot already
-- taken. A farmer past the spots there are gets none. Returns personId ->
-- spot index.
function TCShowStands.assignSpots(showId, slot, farmerIds, spotCount)
    local spots, taken = {}, {}
    if spotCount <= 0 then
        return spots
    end
    for _, id in ipairs(farmerIds) do
        local start = math.floor(TCAuctionScene.hash(showId or 0, 1710 + slot, id) * spotCount)
        for step = 0, spotCount - 1 do
            local index = (start + step) % spotCount + 1
            if not taken[index] then
                taken[index] = true
                spots[id] = index
                break
            end
        end
    end
    return spots
end

-- Where everyone stands on a scene in a slot (pure): personId -> a mingle
-- spot { x, z, yaw } (TCShowScene's; none for a farmer past the spots),
-- and the stalls { role, x, z, yaw }.
function TCShowStands.getPlaces(scene, showId, slot, farmerIds)
    local layout = TCShowScene.layOut(scene)
    local places = {}
    if slot ~= nil then
        for id, index in pairs(TCShowStands.assignSpots(showId, slot, farmerIds, #layout.mingles)) do
            places[id] = layout.mingles[index]
        end
    end
    return places, layout.stalls
end

-- "Any work going?" (score: the farm's relationship with them, -100 to
-- 100): the chance of an offer, 0 for one who refuses.
function TCShowStands.getOfferChance(score, refuses)
    if refuses then
        return 0
    end
    local C = TCShowStands.OFFER_CHANCE
    return math.max(C.min, math.min(C.max, C.base + C.swing * (score or 0) / 100))
end

-- The careers stand's week, in days (at least one).
function TCShowStands.getCareersDays(daysPerPeriod)
    return math.max(1, math.floor(TCShowStands.CAREERS.weekMonths * (daysPerPeriod or 1) + 0.5))
end

-- A careers candidate's age: the younger of ageRolls rolls between minAge
-- and CAREERS.maxAge. random(a, b) as math.random's.
function TCShowStands.rollCareersAge(minAge, random)
    random = random or math.random
    local C = TCShowStands.CAREERS
    local maxAge = math.max(minAge, C.maxAge)
    local age = maxAge
    for _ = 1, C.ageRolls do
        age = math.min(age, random(minAge, maxAge))
    end
    return age
end

-- The line key for a variant: tc_showTalk_<line>_<n>.
function TCShowStands.getLineKey(line, variant)
    local count = TCShowStands.LINES[line] or 1
    return string.format("tc_showTalk_%s_%d", line, math.max(1, math.min(count, variant or 1)))
end

-- The line to say after an answer, by answer (nil: none of its own).
TCShowStands.ANSWER_LINES = {
    [TCShowStands.ANSWER.OFFER] = "offer",
    [TCShowStands.ANSWER.NO_WORK] = "noWork",
    [TCShowStands.ANSWER.ASKED] = "asked",
    [TCShowStands.ANSWER.REFUSED] = "curt",
    [TCShowStands.ANSWER.CLOSED] = "closed",
    [TCShowStands.ANSWER.JOINED] = "associationJoined",
    [TCShowStands.ANSWER.MEMBER] = "associationMember",
    [TCShowStands.ANSWER.CANT_AFFORD] = "associationCantAfford",
    [TCShowStands.ANSWER.SENT] = "careersSent",
    [TCShowStands.ANSWER.VISITED] = "careersVisited",
}

function TCShowStands.getAnswerLine(answer, request)
    if answer == TCShowStands.ANSWER.NO_COMPANY then
        if request == TCShowStands.REQUEST.CAREERS then
            return "careersNoCompany"
        elseif request == TCShowStands.REQUEST.ASK then
            return "noWork"
        end
        return "associationNoCompany"
    end
    return TCShowStands.ANSWER_LINES[answer]
end
