-- The show's pens (182): one animal a pen, so the livestock classes are seen
-- on the showground, not just read from the trailers. The pure half;
-- ShowLivestock keeps the pens and decides who's in them, TCShowScene says
-- where each pen is (getPens) and lays out what's in it (layOutPens).
--
-- Who gets a pen (assign), at set-out, once the farmers have entered: 188:
--   the farmers' single show animals only (a player's stays in its
--   trailer, seen only in the ring at its class), a class at a time in
--   turn so most classes are there, one row's worth at most (perRow).
-- What's in a pen: a farmer's look rolled here: { subTypeName, age,
--   variation }. A farmer's entry keeps its pen number (farmerEntry.pen),
--   so its placing reaches the pen. Nothing here holds a farmer's id, so
--   128's retirements don't reach it.
-- A look is a subtype, an age (months, for vanilla's visual by age) and a
--   variation (the coat: RL's animal's own, 1 for vanilla's, as its
--   trailer shows it, a roll for a farmer's), taken modulo the visual's
--   variations wherever it's shown.
-- A player's animal in the ring (188) is still in its trailer (166: it
--   never leaves vanilla's or RL's systems), so a client hides it there
--   while it's in the ring (TCShowPenTrailers, through matchSlots here).
-- Tested in tests/test_showPens.lua.

TCShowPens = {}

-- The highest variation a farmer's animal is rolled (taken modulo the
-- visual's own on each machine).
TCShowPens.MAX_VARIATION = 16

-- The pens (pure). farmerEntries: the farmers' (188: not the breeders');
-- perRow: the pens a row; getClass(classKey): TCShowClasses' class or nil;
-- random(): 0-1. Returns pens (a list, its index the pen's number) and
-- sets each picked farmer's entry's `pen`.
function TCShowPens.assign(farmerEntries, perRow, getClass, random)
    local herdKey = TCShowClasses.HERD_KEY
    -- The farmers' animals by class, the classes in the order they come.
    local byClass, classKeys = {}, {}
    for _, farmerEntry in ipairs(farmerEntries or {}) do
        farmerEntry.pen = nil
        local class = farmerEntry.classKey ~= herdKey and getClass(farmerEntry.classKey) or nil
        if class ~= nil then
            if byClass[farmerEntry.classKey] == nil then
                byClass[farmerEntry.classKey] = {}
                table.insert(classKeys, farmerEntry.classKey)
            end
            table.insert(byClass[farmerEntry.classKey], { farmerEntry = farmerEntry, class = class })
        end
    end
    local farmers = {}
    local round = 1
    while true do
        local added = false
        for _, classKey in ipairs(classKeys) do
            local item = byClass[classKey][round]
            if item ~= nil then
                table.insert(farmers, item)
                added = true
            end
        end
        if not added then
            break
        end
        round = round + 1
    end

    local count = math.min(perRow, #farmers)
    local pens = {}
    for _, item in ipairs(farmers) do
        if #pens >= count then
            break
        end
        local look = TCShowPens.rollLook(item.class, random)
        look.farmer = true
        table.insert(pens, look)
        item.farmerEntry.pen = #pens
    end
    return pens
end

-- A farmer's animal's look (pure): its class's subtype, an age in its
-- band's prime, a coat.
function TCShowPens.rollLook(class, random)
    local band = class.band or {}
    local from = band.primeFrom or band.from or 0
    local to = band.primeTo or from
    if band.to ~= nil then
        to = math.min(to, band.to - 1)
    end
    to = math.max(from, to)
    return {
        subTypeName = class.subTypeName,
        age = from + math.min(to - from, math.floor(random() * (to - from + 1))),
        variation = 1 + math.min(TCShowPens.MAX_VARIATION - 1, math.floor(random() * TCShowPens.MAX_VARIATION)),
    }
end

-- A variation as one of a visual's (pure): 1 to count.
function TCShowPens.getVariationIndex(variation, count)
    if count == nil or count < 1 then
        return 1
    end
    return ((math.max(1, variation or 1) - 1) % count) + 1
end

-- Whether the show's pens are open (pure): the show's day, from the gates
-- opening to their closing.
function TCShowPens.isOpen(eventDay, today, hour, fromHour, toHour)
    return eventDay ~= nil and today == eventDay and hour >= fromHour and hour < toHour
end

-- The trailer's slots (as LivestockTrailer:updateAnimals fills them: each
-- cluster's animals in turn, from 1) holding the penned animals (pure).
-- clusters: the trailer's, each { subTypeName, age, count, key (RL's, or
-- nil) }; pens: those from this trailer (188: a player's animals in the
-- ring), each { subTypeName, age, animalKey }.
-- Returns the slot numbers, each taken once.
function TCShowPens.matchSlots(clusters, pens)
    local slots = {}
    local firstSlot, taken = {}, {}
    local slot = 1
    for i, cluster in ipairs(clusters) do
        firstSlot[i] = slot
        taken[i] = 0
        slot = slot + (cluster.count or 0)
    end
    for _, pen in ipairs(pens) do
        for i, cluster in ipairs(clusters) do
            local matches
            if pen.animalKey ~= nil then
                matches = cluster.key == pen.animalKey
            else
                matches = cluster.key == nil and cluster.subTypeName == pen.subTypeName and cluster.age == pen.age
            end
            if matches and taken[i] < (cluster.count or 0) then
                table.insert(slots, firstSlot[i] + taken[i])
                taken[i] = taken[i] + 1
                break
            end
        end
    end
    return slots
end
