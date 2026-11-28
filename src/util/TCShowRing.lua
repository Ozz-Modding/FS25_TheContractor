-- The show's ring (188): the livestock classes judged in turn through the
-- day, one at a time, their entrants brought into the ring. The pure half;
-- TheContractorShowLivestock runs it on the server and every machine
-- shows it (TCShowScene's ring line, the Show tab's timetable).
--
--   The timetable (buildTimetable): a slot for each class that runs, in
--     the show's class order (type, breed, band), each type's supreme
--     champion straight after its classes when two or more of them run,
--     Best Kept Herd last. From START_MINUTE, SLOT_MINUTES each, shortened
--     (in STEP_MINUTES, to MIN_SLOT_MINUTES at least) so they all end by
--     END_MINUTE. Past MAX_SLOTS (pickClasses) the classes no player's in
--     are dropped from the end first, so a player's class always runs.
--   A slot: its entrants in the ring from `from`, placed (the line stood
--     in placing order, the placings given) at judgeAt (PLACING_SHARE of
--     the way through), and back in their pens at `to`.
--
-- Times are minutes past midnight on the show's day. Tested in
-- tests/test_showRing.lua.

TCShowRing = {}

TCShowRing.START_MINUTE = 10 * 60
TCShowRing.END_MINUTE = 15 * 60 + 30
TCShowRing.SLOT_MINUTES = 60
TCShowRing.MIN_SLOT_MINUTES = 30
TCShowRing.STEP_MINUTES = 5
TCShowRing.PLACING_SHARE = 0.75
TCShowRing.MAX_SLOTS = math.floor((TCShowRing.END_MINUTE - TCShowRing.START_MINUTE) / TCShowRing.MIN_SLOT_MINUTES)

-- A slot's state on the server (saved, and sent to every machine).
TCShowRing.STATE = {
    WAITING = 0,
    IN_RING = 1,    -- the entrants in the ring, judged
    PLACED = 2,     -- the line in placing order, the placings given
    OVER = 3,       -- back in their pens
}

-- The slots' keys for the classes that run (pure): classKeys in show
-- order (no herd or champion keys), each type's champion after its classes
-- when two or more of them run, the herd last if hasHerd. getTypeName
-- (classKey) -> the class's type.
function TCShowRing.getSlotKeys(classKeys, getTypeName, hasHerd)
    local keys = {}
    local lastType, run = nil, 0
    local function closeType()
        if lastType ~= nil and run >= 2 then
            table.insert(keys, TCShowClasses.getChampionKey(lastType))
        end
    end
    for _, classKey in ipairs(classKeys) do
        local typeName = getTypeName(classKey)
        if typeName ~= lastType then
            closeType()
            lastType, run = typeName, 0
        end
        table.insert(keys, classKey)
        run = run + 1
    end
    closeType()
    if hasHerd then
        table.insert(keys, TCShowClasses.HERD_KEY)
    end
    return keys
end

-- The classes kept (pure): classKeys in show order, playerClasses[key]
-- true for those a player's in. While their slots (getSlotKeys') are more
-- than maxSlots, the last class no player's in goes. Returns the kept keys
-- and those dropped.
function TCShowRing.pickClasses(classKeys, playerClasses, getTypeName, hasHerd, maxSlots)
    maxSlots = maxSlots or TCShowRing.MAX_SLOTS
    local kept = {}
    for i, key in ipairs(classKeys) do
        kept[i] = key
    end
    local dropped = {}
    while #TCShowRing.getSlotKeys(kept, getTypeName, hasHerd) > maxSlots do
        local removed = false
        for i = #kept, 1, -1 do
            if not playerClasses[kept[i]] then
                table.insert(dropped, table.remove(kept, i))
                removed = true
                break
            end
        end
        if not removed then
            break
        end
    end
    return kept, dropped
end

-- The timetable (pure): { { key, from, judgeAt, to } } for slot keys.
function TCShowRing.buildTimetable(slotKeys)
    local slots = {}
    local count = #slotKeys
    if count == 0 then
        return slots
    end
    local step = TCShowRing.STEP_MINUTES
    local window = TCShowRing.END_MINUTE - TCShowRing.START_MINUTE
    local length = math.floor(window / count / step) * step
    length = math.min(TCShowRing.SLOT_MINUTES, math.max(step, length))
    for i, key in ipairs(slotKeys) do
        local from = TCShowRing.START_MINUTE + (i - 1) * length
        table.insert(slots, { key = key, from = from, judgeAt = from + math.floor(length * TCShowRing.PLACING_SHARE),
            to = from + length })
    end
    return slots
end

-- Each slot's state for the Show tab on a day at a minute (pure): "done",
-- "now" or "next" (before the day all "next", after it all "done").
function TCShowRing.getSlotStates(timetable, today, day, minute)
    local states = {}
    for i, slot in ipairs(timetable or {}) do
        local state = "next"
        if day == nil or today > day then
            state = day ~= nil and "done" or "next"
        elseif today == day then
            if minute >= slot.to then
                state = "done"
            elseif minute >= slot.from then
                state = "now"
            end
        end
        states[i] = state
    end
    return states
end

-- The slot a class is judged in, and its index, or nil.
function TCShowRing.findSlot(timetable, key)
    for i, slot in ipairs(timetable or {}) do
        if slot.key == key then
            return slot, i
        end
    end
    return nil
end

-- A minute as "HH:MM".
function TCShowRing.formatMinute(minute)
    minute = math.max(0, math.floor(minute or 0))
    return string.format("%02d:%02d", math.floor(minute / 60) % 24, minute % 60)
end

-- The line in placing order (pure): competitors { placing (or nil) } as
-- they came in; the placed first, best first, then the rest as they were.
-- Returns a new list.
function TCShowRing.orderByPlacing(line)
    local ordered = {}
    for i, item in ipairs(line) do
        ordered[i] = { item = item, index = i }
    end
    table.sort(ordered, function(a, b)
        local pa, pb = a.item.placing or math.huge, b.item.placing or math.huge
        if a.item.champion ~= b.item.champion then
            return a.item.champion == true
        end
        if pa ~= pb then
            return pa < pb
        end
        return a.index < b.index
    end)
    local list = {}
    for i, entry in ipairs(ordered) do
        list[i] = entry.item
    end
    return list
end
