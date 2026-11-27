-- The show's pens (182): one animal a pen, so the livestock classes are seen
-- on the showground, not just read from the trailers. The pure half;
-- ShowLivestock keeps the pens and decides who's in them, TCShowScene says
-- where each pen is (getPens) and lays out what's in it (layOutPens).
--
-- Who gets a pen (assign), at set-out, once the farmers have entered:
--   players' animals first (every entry but Best Kept Herd's, in entry
--   order), then the farmers' fill the rest, a class at a time in turn so
--   most classes are there. One row's worth of pens (perRow) unless the
--   players need more, then as many as they need up to two rows. A player's
--   animal past that (two full rows) has no pen.
-- What's in a pen: { entryId, farmId } for a player's (its look read from
--   the trailer when it comes, ShowLivestock:updatePens), or a farmer's
--   look rolled here: { subTypeName, age, variation }. A farmer's entry
--   keeps its pen number (farmerEntry.pen), so its placing reaches the pen.
--   Nothing here holds a farmer's id, so 128's retirements don't reach it.
-- A look is a subtype, an age (months, for vanilla's visual by age) and a
--   variation (the coat: RL's animal's own, 1 for vanilla's, as its
--   trailer shows it, a roll for a farmer's), taken modulo the visual's
--   variations wherever it's shown.
-- The animal's still in its trailer (166: it never leaves vanilla's or
--   RL's systems), so a client hides it there while it's in its pen
--   (TCShowPenTrailers, through matchSlots here).
-- Tested in tests/test_showPens.lua.

TCShowPens = {}

-- The highest variation a farmer's animal is rolled (taken modulo the
-- visual's own on each machine).
TCShowPens.MAX_VARIATION = 16

-- The pens (pure). entries: the players' (ShowLivestock's, in order);
-- farmerEntries: the farmers'; perRow, rows: the pens a row and rows at
-- most; getClass(classKey): TCShowClasses' class or nil; random(): 0-1.
-- Returns pens (a list, its index the pen's number) and sets each picked
-- farmer's entry's `pen`.
function TCShowPens.assign(entries, farmerEntries, perRow, rows, getClass, random)
    local herdKey = TCShowClasses.HERD_KEY
    local players = {}
    for _, entry in ipairs(entries or {}) do
        if entry.classKey ~= herdKey then
            table.insert(players, entry)
        end
    end
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

    local count
    if #players > perRow then
        count = math.min(#players, perRow * rows)
    else
        count = math.min(perRow, #players + #farmers)
    end
    local pens = {}
    for _, entry in ipairs(players) do
        if #pens >= count then
            break
        end
        table.insert(pens, { entryId = entry.id, farmId = entry.farmId })
    end
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
-- nil) }; pens: those in this trailer, each { subTypeName, age, animalKey }.
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
