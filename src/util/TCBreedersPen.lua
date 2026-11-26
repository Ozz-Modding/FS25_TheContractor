-- The breeders' pen at the show (173): the pure half, every machine.
-- TheContractorBreedersPen (src/business/BreedersPen.lua) puts the
-- breeder's trailers out, stocks them and sells from them on the server;
-- TCBreedersPenWorld talks to the player at the stand.
--
--   With RealisticLivestock only (its RealisticLivestockAPI, through
--     TCRealisticLivestock.getAPI): a base-game animal of a subtype is like
--     any other, so there'd be nothing to sell.
--   The stock: up to TYPES of the map's showable animal types (TCShowClasses'
--     classes), PER_TRAILER animals of each in a livestock trailer of the
--     breeder's, made by RL at its "premium" quality (QUALITY), each at an
--     age inside one of its classes' bands. One that comes out sick is
--     drawn again, up to TRIES times.
--   The trailers belong to a spare farm id (pickFarmId: the highest with no
--     farm, 8 then 7 ...), because RL's API only stocks a trailer a real
--     farm id owns. No spare id, no pen at that show.
--   The price: RL's own value for the animal (what it pays a seller) times
--     MARKUP, which stays above 1, or buying here and selling straight back
--     would make money. RL's value is a game price: never scaled.
--   Delivery: into one of the buyer's livestock trailers at the show (in
--     the trailer lines, or within REACH of the stand), free; or straight
--     to one of their husbandries with room, for DELIVERY_FEE (a haulier's
--     local run at a real UK rate, through Settings:scaleCost and
--     EconomyScale).
--
-- Tested in tests/test_breedersPen.lua.

TCBreedersPen = {}

-- RL's own premium dealer's markup (RLDealerQualityModel's "premium" preset):
-- the breeder's a premium dealer for the day, the stock's what's hard to get.
TCBreedersPen.MARKUP = 1.30
TCBreedersPen.QUALITY = "premium"
TCBreedersPen.TYPES = 2
TCBreedersPen.PER_TRAILER = 3
TCBreedersPen.TRIES = 4
-- Months past the start of a band with no end (an adult's) a breeder's
-- animal can be.
TCBreedersPen.ADULT_SPAN = 24
-- Unscaled pounds.
TCBreedersPen.DELIVERY_FEE = 40
-- Metres from the breeder's stand a buyer's trailer counts as at the show.
TCBreedersPen.REACH = 40

-- What a player asks (TCBreederBuyEvent): to buy one animal.
TCBreedersPen.REQUEST = {
    BUY = 1,
}

-- The server's answer.
TCBreedersPen.ANSWER = {
    BOUGHT = 1,         -- value: what was paid
    SOLD = 2,           -- gone already (someone else's, or never there)
    CANT_AFFORD = 3,
    NO_ROOM = 4,        -- the place picked won't take it
    CLOSED = 5,         -- the pen isn't open now
    NO_PERMISSION = 6,  -- the player mayn't trade animals for their farm
    SICK = 7,           -- it's fallen sick since it was shown
    FAILED = 8,         -- RL couldn't move it
}

-- How many variants each line has (tc_breeder_<line>_<n>).
TCBreedersPen.LINES = {
    greet = 2,
    soldOut = 1,
    noRoom = 1,
    thinking = 1,
    bought = 2,
    sold = 1,
    cantAfford = 1,
    closed = 1,
    noPermission = 1,
    sick = 1,
    failed = 1,
    later = 2,
}

TCBreedersPen.ANSWER_LINES = {
    [TCBreedersPen.ANSWER.BOUGHT] = "bought",
    [TCBreedersPen.ANSWER.SOLD] = "sold",
    [TCBreedersPen.ANSWER.CANT_AFFORD] = "cantAfford",
    [TCBreedersPen.ANSWER.NO_ROOM] = "noRoom",
    [TCBreedersPen.ANSWER.CLOSED] = "closed",
    [TCBreedersPen.ANSWER.NO_PERMISSION] = "noPermission",
    [TCBreedersPen.ANSWER.SICK] = "sick",
    [TCBreedersPen.ANSWER.FAILED] = "failed",
}

-- The genetics shown at the stand, in order (productivity only where the
-- animal has it).
TCBreedersPen.GENETICS = { "quality", "health", "fertility", "metabolism", "productivity" }

function TCBreedersPen.getLineKey(line, variant)
    local count = TCBreedersPen.LINES[line] or 1
    return string.format("tc_breeder_%s_%d", line, math.max(1, math.min(count, variant or 1)))
end

-- The spare farm id for the breeder's trailers: the highest from maxFarms
-- down with no farm (farmExists(id) false), or nil when every one's taken.
function TCBreedersPen.pickFarmId(farmExists, maxFarms)
    for id = maxFarms or 8, 1, -1 do
        if not farmExists(id) then
            return id
        end
    end
    return nil
end

-- What the breeder asks for an animal RL values at value.
function TCBreedersPen.getPrice(value, markup)
    return math.floor((value or 0) * (markup or TCBreedersPen.MARKUP) + 0.5)
end

-- The classes by animal type, and up to count of the types in an order
-- from random (random(n) -> 1..n, as math.random's): { { typeName,
-- classes } }.
function TCBreedersPen.pickTypes(classes, count, random)
    random = random or math.random
    local byType, order = {}, {}
    for _, class in ipairs(classes or {}) do
        if class.typeName ~= nil and class.band ~= nil then
            if byType[class.typeName] == nil then
                byType[class.typeName] = {}
                table.insert(order, class.typeName)
            end
            table.insert(byType[class.typeName], class)
        end
    end
    table.sort(order)
    local picked = {}
    while #order > 0 and #picked < (count or TCBreedersPen.TYPES) do
        local typeName = table.remove(order, random(#order))
        table.insert(picked, { typeName = typeName, classes = byType[typeName] })
    end
    return picked
end

-- An age inside a band (months): from its start to the month before its
-- end, or ADULT_SPAN months on for a band with no end.
function TCBreedersPen.rollAge(band, random)
    random = random or math.random
    local from = band.from or 0
    local to = band.to ~= nil and band.to - 1 or from + TCBreedersPen.ADULT_SPAN - 1
    if to < from then
        to = from
    end
    return random(from, to)
end

-- The trailer model for a type: models { { xmlFilename, slots = { TYPE ->
-- count }, isBaseGame } }. The base game's first; of those, the fewest
-- slots that still take count animals, else the most there are. nil when
-- none takes the type.
function TCBreedersPen.pickTrailerModel(models, typeName, count)
    local best = nil
    local function better(model, slots)
        if best == nil then
            return true
        end
        if model.isBaseGame ~= best.model.isBaseGame then
            return model.isBaseGame == true
        end
        local fits, bestFits = slots >= count, best.slots >= count
        if fits ~= bestFits then
            return fits
        end
        if fits then
            return slots < best.slots
        end
        return slots > best.slots
    end
    for _, model in ipairs(models or {}) do
        local slots = model.slots ~= nil and model.slots[typeName] or nil
        if slots ~= nil and slots > 0 and better(model, slots) then
            best = { model = model, slots = slots }
        end
    end
    if best == nil then
        return nil, 0
    end
    return best.model, best.slots
end

-- The breeder: a farmer at the show who isn't anyone else there (excluded:
-- personId -> true), picked from the show's id so it's the same on every
-- machine. farmers: { { id } }. nil when there's nobody left.
function TCBreedersPen.pickBreeder(showId, farmers, excluded)
    excluded = excluded or {}
    local best, bestOrder = nil, nil
    for _, person in ipairs(farmers or {}) do
        if not excluded[person.id] then
            local order = TCAuctionScene.hash(showId or 0, 173, person.id)
            if best == nil or order < bestOrder or (order == bestOrder and person.id < best) then
                best, bestOrder = person.id, order
            end
        end
    end
    return best
end

-- The answer for a refusal from RL's API (its REASON strings, compared
-- through the api's own table).
function TCBreedersPen.getAnswerForReason(reasons, reason)
    reasons = reasons or {}
    if reason == reasons.ANIMAL_NOT_IN_SOURCE or reason == reasons.INVALID_ANIMAL then
        return TCBreedersPen.ANSWER.SOLD
    elseif reason == reasons.NOT_ENOUGH_SPACE or reason == reasons.ANIMAL_NOT_SUPPORTED or
            reason == reasons.WRONG_FARM or reason == reasons.INVALID_TARGET then
        return TCBreedersPen.ANSWER.NO_ROOM
    elseif reason == reasons.NOT_READY or reason == reasons.NOT_SERVER then
        return TCBreedersPen.ANSWER.CLOSED
    end
    return TCBreedersPen.ANSWER.FAILED
end

function TCBreedersPen.getAnswerLine(answer)
    return TCBreedersPen.ANSWER_LINES[answer]
end
