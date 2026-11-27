-- 182: the show's pens, the pure half (TCShowPens): who gets a pen (players
-- first, the farmers' a class at a time, one row unless the players need
-- more), a farmer's animal's look, the pens' hours, and which of a
-- trailer's slots hold the penned animals.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCShowClasses.lua")
    world:load("src/util/TCShowPens.lua")
    return world
end

local BAND = { key = "young", from = 6, to = 24, primeFrom = 12, primeTo = 22 }

local function getClass(classKey)
    if classKey == TCShowClasses.HERD_KEY then
        return nil
    end
    local subTypeName = string.match(classKey, "^([^:]+)")
    return { key = classKey, subTypeName = subTypeName, band = BAND }
end

local function playerEntry(id, farmId, classKey)
    return { id = id, farmId = farmId, classKey = classKey }
end

local function farmerEntry(classKey)
    return { classKey = classKey, farmerId = 8 }
end

local function middle()
    return 0.5
end

test("players' animals first, Best Kept Herd left out, then the farmers' a class at a time", function()
    setup()
    local entries = { playerEntry(1, 1, "COW:young"), playerEntry(2, 1, "herd"), playerEntry(3, 2, "SHEEP:young") }
    local farmers = { farmerEntry("COW:young"), farmerEntry("COW:young"), farmerEntry("COW:young"),
        farmerEntry("PIG:young"), farmerEntry("herd"), farmerEntry("PIG:young") }
    local pens = TCShowPens.assign(entries, farmers, 12, 2, getClass, middle)
    assertEquals(#pens, 2 + 5, "every animal, the herds none")
    assertEquals(pens[1].entryId, 1)
    assertEquals(pens[1].farmId, 1)
    assertEquals(pens[2].entryId, 3)
    -- Round one: a cow and a pig; round two: the same; round three: a cow.
    local order = {}
    for i = 3, #pens do
        table.insert(order, pens[i].subTypeName)
        assertEquals(pens[i].entryId, nil)
    end
    assertEquals(table.concat(order, ","), "COW,PIG,COW,PIG,COW")
    -- Each farmer's entry knows its pen; the herd's has none.
    assertEquals(farmers[1].pen, 3)
    assertEquals(farmers[4].pen, 4)
    assertEquals(farmers[2].pen, 5)
    assertEquals(farmers[5].pen, nil)
end)

test("one row unless the players need more: farmers fill only the first row, players get two at most", function()
    setup()
    local farmers = {}
    for _ = 1, 20 do
        table.insert(farmers, farmerEntry("COW:young"))
    end
    local entries = { playerEntry(1, 1, "COW:young") }
    local pens = TCShowPens.assign(entries, farmers, 12, 2, getClass, middle)
    assertEquals(#pens, 12)
    assertEquals(farmers[11].pen, 12)
    assertEquals(farmers[12].pen, nil, "past the row: no pen")

    entries = {}
    for i = 1, 15 do
        table.insert(entries, playerEntry(i, 1, "COW:young"))
    end
    pens = TCShowPens.assign(entries, farmers, 12, 2, getClass, middle)
    assertEquals(#pens, 15, "the players' 15, no farmers")
    assertEquals(farmers[1].pen, nil, "a pen from an earlier go is dropped")

    entries = {}
    for i = 1, 30 do
        table.insert(entries, playerEntry(i, 1, "COW:young"))
    end
    assertEquals(#TCShowPens.assign(entries, {}, 12, 2, getClass, middle), 24, "two rows at most")
    assertEquals(#TCShowPens.assign({}, {}, 12, 2, getClass, middle), 0)
end)

test("a farmer's animal is in its band's prime, its coat rolled", function()
    setup()
    local low = TCShowPens.rollLook({ subTypeName = "COW", band = BAND }, function() return 0 end)
    assertEquals(low.subTypeName, "COW")
    assertEquals(low.age, BAND.primeFrom)
    assertEquals(low.variation, 1)
    local high = TCShowPens.rollLook({ subTypeName = "COW", band = BAND }, function() return 0.9999 end)
    assertEquals(high.age, BAND.primeTo)
    assertEquals(high.variation, TCShowPens.MAX_VARIATION)
    -- A band with no end and no prime: its start.
    local open = TCShowPens.rollLook({ subTypeName = "HORSE", band = { key = "adult", from = 30 } }, function() return 0.7 end)
    assertEquals(open.age, 30)
    -- A coat past a visual's own wraps round.
    assertEquals(TCShowPens.getVariationIndex(5, 4), 1)
    assertEquals(TCShowPens.getVariationIndex(4, 4), 4)
    assertEquals(TCShowPens.getVariationIndex(3, 0), 1)
end)

test("the pens are open on the show's day from the gates opening to their closing", function()
    setup()
    assertTrue(not TCShowPens.isOpen(51, 51, 7, 8, 18))
    assertTrue(TCShowPens.isOpen(51, 51, 8, 8, 18))
    assertTrue(TCShowPens.isOpen(51, 51, 17, 8, 18))
    assertTrue(not TCShowPens.isOpen(51, 51, 18, 8, 18))
    assertTrue(not TCShowPens.isOpen(51, 50, 10, 8, 18))
    assertTrue(not TCShowPens.isOpen(nil, 51, 10, 8, 18))
end)

test("a trailer's slots: an RL animal by its key, a vanilla one by subtype and age, each slot once", function()
    setup()
    local clusters = {
        { subTypeName = "COW", age = 20, count = 3 },
        { subTypeName = "COW", age = 22, count = 1 },
        { subTypeName = "COW", age = 20, count = 1, key = "2 1 7" },
    }
    -- Two vanilla 20-month cows: the first two slots of the three.
    local slots = TCShowPens.matchSlots(clusters, { { subTypeName = "COW", age = 20 }, { subTypeName = "COW", age = 20 } })
    assertEquals(table.concat(slots, ","), "1,2")
    -- The 22-month one is slot 4; the RL one slot 5, never taken for a
    -- vanilla look.
    slots = TCShowPens.matchSlots(clusters, { { subTypeName = "COW", age = 22 }, { animalKey = "2 1 7" } })
    assertEquals(table.concat(slots, ","), "4,5")
    -- More asked for than are there: only what's there.
    slots = TCShowPens.matchSlots(clusters, { { subTypeName = "COW", age = 22 }, { subTypeName = "COW", age = 22 },
        { animalKey = "nobody" } })
    assertEquals(table.concat(slots, ","), "4")
end)
