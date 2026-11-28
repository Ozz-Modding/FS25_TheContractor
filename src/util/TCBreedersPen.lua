-- The breeders at the show (173, 188): the pure half, every machine.
-- TheContractorBreedersPen (src/business/BreedersPen.lua) has the
-- breeders, puts their trailers out, stocks them and sells from them on
-- the server; TCBreedersPenWorld talks to the player at their pens.
--
--   188: the breeders (planBreeders): farmers who bring their stock to the
--     show, each in their own pen (TCShowScene's), up to MAX_BREEDERS, as
--     many as the showground holds. Each keeps one of the map's showable
--     animal types (TCShowClasses' classes, never chickens, and never
--     EXCLUDED_SUBTYPES' breeds), drawn by TYPE_WEIGHTS (more cattle and
--     sheep breeders than others, the user's call; every type once in each
--     round of draws, so a type may get none at a small show), and that
--     type's breeds picked for the show (SUBTYPES_PER_TYPE, two when the map
--     has few types), so breeders
--     of a type compete. Their stock: STOCK's count for the type (premium
--     only, the user's call), spread over the classes those breeds show in,
--     each animal in its band's prime; its pen STOCK's size. They enter
--     ENTRIES_PER_CLASS of their animals in each class they have stock for.
--   Selling with RealisticLivestock only (its RealisticLivestockAPI, through
--     TCRealisticLivestock.getAPI): a base-game animal of a subtype is like
--     any other, so there'd be nothing to sell. Without it the breeders
--     still come, their animals looks only.
--   RL's stock: each breeder's in a livestock trailer of theirs behind
--     their pen, made by RL at its "premium" quality (QUALITY) at the
--     planned subtype and age. One that comes out sick is drawn again, up
--     to TRIES times.
--   The trailers belong to a spare farm id (pickFarmId: the highest with no
--     farm, 8 then 7 ...), because RL's API only stocks a trailer a real
--     farm id owns. No spare id, nothing to sell at that show: the
--     breeders bring their animals as they do without RL.
--   The price: RL's own value for the animal (what it pays a seller) times
--     MARKUP, which stays above 1, or buying here and selling straight back
--     would make money. RL's value is a game price: never scaled.
--   Delivery: into one of the buyer's livestock trailers at the show (in
--     the trailer lines, or within REACH of the breeder's pen), free; or straight
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
TCBreedersPen.TRIES = 4
-- 188: the breeders at a show at most, and each type's breeds picked for
-- it (FEW_TYPES_SUBTYPES when the map has FEW_TYPES types or fewer).
TCBreedersPen.MAX_BREEDERS = 6
TCBreedersPen.SUBTYPES_PER_TYPE = 1
TCBreedersPen.FEW_TYPES = 2
TCBreedersPen.FEW_TYPES_SUBTYPES = 2
-- 188: breeds no breeder brings (the user's call): they still show in the
-- players' classes.
TCBreedersPen.EXCLUDED_SUBTYPES = {
    COW_WATERBUFFALO = true,
    BULL_WATERBUFFALO = true,
}
-- 188: how often a type's drawn for a breeder against the others (any
-- type not here DEFAULT_TYPE_WEIGHT's).
TCBreedersPen.TYPE_WEIGHTS = {
    COW = 3,
    SHEEP = 2,
}
TCBreedersPen.DEFAULT_TYPE_WEIGHT = 1
-- 188: a breeder's stock by type: their pen (length along its front, depth,
-- in hurdles, TCShowScene.PENS.size each) and how many animals (min to
-- max, never more than their pen and their trailer take); any other type
-- DEFAULT_STOCK's.
TCBreedersPen.STOCK = {
    COW = { length = 4, depth = 2, min = 4, max = 6 },
    HORSE = { length = 3, depth = 2, min = 3, max = 4 },
    SHEEP = { length = 2, depth = 2, min = 5, max = 8 },
    GOAT = { length = 2, depth = 2, min = 5, max = 8 },
    PIG = { length = 2, depth = 2, min = 4, max = 6 },
}
TCBreedersPen.DEFAULT_STOCK = { length = 3, depth = 2, min = 4, max = 6 }
-- 188: a breeder's entries in each class they have stock for (min to max).
TCBreedersPen.ENTRIES_PER_CLASS = { 1, 2 }
-- Unscaled pounds.
TCBreedersPen.DELIVERY_FEE = 40
-- Metres from a breeder's pen a buyer's trailer counts as at the show.
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
    ENTERED = 9,        -- 188: entered in a class not yet over
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
    -- 188.
    greetNoSale = 2,
    entered = 1,
    enteredHeld = 1,
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
    [TCBreedersPen.ANSWER.ENTERED] = "enteredHeld",
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

-- 188: an age in a band's prime (months), random(a, b) as math.random's:
-- from its primeFrom to its primeTo, inside the band.
function TCBreedersPen.rollPrimeAge(band, random)
    random = random or math.random
    local from = band.primeFrom or band.from or 0
    local to = band.primeTo or from
    if band.to ~= nil then
        to = math.min(to, band.to - 1)
    end
    from = math.max(from, band.from or from)
    if to < from then
        to = from
    end
    return random(from, to)
end

-- 188: a type's stock (STOCK's, or DEFAULT_STOCK).
function TCBreedersPen.getStock(typeName)
    return TCBreedersPen.STOCK[typeName or ""] or TCBreedersPen.DEFAULT_STOCK
end

-- Up to n of a list at random, in a random order (a copy); random(n) as
-- math.random's.
local function pickSome(list, n, random)
    local pool = {}
    for i, item in ipairs(list) do
        pool[i] = item
    end
    local picked = {}
    while #picked < n and #pool > 0 do
        table.insert(picked, table.remove(pool, random(#pool)))
    end
    return picked
end

-- 188: the show's breeders (pure; see the header). classes: TCShowClasses.
-- listClasses'; farmers: { { id } } who could come (the host and anyone
-- busy that day left out already); count: at most; random(n) and
-- random(a, b) as math.random's; capacity(typeName, count) (optional): how
-- many of a type its breeder can bring (their trailer's room), 0 when the
-- type can't be brought at all. Returns { { farmerId, typeName, pen = {
-- length, depth }, animals = { { id, classKey, subTypeName, age,
-- variation } }, entries = { animal id, ... } } }, the types drawn by
-- TYPE_WEIGHTS.
function TCBreedersPen.planBreeders(classes, farmers, count, random, capacity)
    random = random or math.random
    local byType, typeNames = {}, {}
    for _, class in ipairs(classes or {}) do
        if class.typeName ~= nil and class.band ~= nil and not TCShowClasses.EXCLUDED_TYPES[class.typeName] and
            not TCBreedersPen.EXCLUDED_SUBTYPES[class.subTypeName or ""] then
            local entry = byType[class.typeName]
            if entry == nil then
                entry = { classes = {}, subTypes = {}, seen = {} }
                byType[class.typeName] = entry
                table.insert(typeNames, class.typeName)
            end
            table.insert(entry.classes, class)
            if not entry.seen[class.subTypeName] then
                entry.seen[class.subTypeName] = true
                table.insert(entry.subTypes, class.subTypeName)
            end
        end
    end
    table.sort(typeNames)
    local usable = {}
    for _, typeName in ipairs(typeNames) do
        if capacity == nil or (capacity(typeName, TCBreedersPen.getStock(typeName).max) or 0) > 0 then
            table.insert(usable, typeName)
        end
    end
    local types = pickSome(usable, #usable, random)
    if #types == 0 then
        return {}
    end
    local perType = #types <= TCBreedersPen.FEW_TYPES and TCBreedersPen.FEW_TYPES_SUBTYPES or
        TCBreedersPen.SUBTYPES_PER_TYPE
    -- Each type's breeds for this show, and the classes they show in.
    local typeClasses = {}
    for _, typeName in ipairs(types) do
        local entry = byType[typeName]
        local picked = {}
        for _, subTypeName in ipairs(pickSome(entry.subTypes, perType, random)) do
            picked[subTypeName] = true
        end
        local list = {}
        for _, class in ipairs(entry.classes) do
            if picked[class.subTypeName] then
                table.insert(list, class)
            end
        end
        typeClasses[typeName] = list
    end
    -- The breeders' types: drawn from a bag with each type in it its
    -- weight's times, filled again once it's empty.
    local bag = {}
    local function drawType()
        if #bag == 0 then
            for _, typeName in ipairs(types) do
                local weight = TCBreedersPen.TYPE_WEIGHTS[typeName] or TCBreedersPen.DEFAULT_TYPE_WEIGHT
                for _ = 1, weight do
                    table.insert(bag, typeName)
                end
            end
        end
        return table.remove(bag, random(#bag))
    end
    local pool = pickSome(farmers or {}, #(farmers or {}), random)
    local breeders = {}
    for _ = 1, count or TCBreedersPen.MAX_BREEDERS do
        local farmer = table.remove(pool, 1)
        if farmer == nil then
            break
        end
        local typeName = drawType()
        local stock = TCBreedersPen.getStock(typeName)
        local n = random(stock.min, stock.max)
        if capacity ~= nil then
            n = math.min(n, capacity(typeName, n) or n)
        end
        local classesOf = pickSome(typeClasses[typeName], #typeClasses[typeName], random)
        local breeder = { farmerId = farmer.id, typeName = typeName, pen = { length = stock.length, depth = stock.depth },
            animals = {}, entries = {} }
        local byClass, classOrder = {}, {}
        for id = 1, n do
            local class = classesOf[(id - 1) % #classesOf + 1]
            local animal = { id = id, classKey = class.key, subTypeName = class.subTypeName,
                age = TCBreedersPen.rollPrimeAge(class.band, random), variation = random(1, TCShowPens.MAX_VARIATION) }
            table.insert(breeder.animals, animal)
            if byClass[class.key] == nil then
                byClass[class.key] = {}
                table.insert(classOrder, class.key)
            end
            table.insert(byClass[class.key], animal)
        end
        local E = TCBreedersPen.ENTRIES_PER_CLASS
        for _, classKey in ipairs(classOrder) do
            local group = byClass[classKey]
            for _, animal in ipairs(pickSome(group, math.min(#group, random(E[1], E[2])), random)) do
                table.insert(breeder.entries, animal.id)
            end
        end
        table.sort(breeder.entries)
        table.insert(breeders, breeder)
    end
    return breeders
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
