-- 188: the show's ring (TCShowRing, pure): the slots for the classes that
-- run (each type's champion after its classes, Best Kept Herd last), the
-- breeders' own classes dropped first when there are too many, the
-- timetable from 10:00 fitted in by 15:30, each slot's state on the day,
-- and the line stood in placing order.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCShowClasses.lua")
    world:load("src/util/TCShowRing.lua")
    return world
end

local TYPE_OF = {
    ["COW_HOLSTEIN:young"] = "COW", ["COW_HOLSTEIN:adult"] = "COW", ["BULL_HOLSTEIN:young"] = "COW",
    ["SHEEP_TEXEL:young"] = "SHEEP", ["PIG_LANDRACE:adult"] = "PIG",
}
local function getTypeName(classKey)
    return TYPE_OF[classKey]
end

test("the slots: each class in order, a type's champion after its classes when two or more run, the herd last", function()
    setup()
    local keys = TCShowRing.getSlotKeys({ "COW_HOLSTEIN:young", "COW_HOLSTEIN:adult", "SHEEP_TEXEL:young",
        "PIG_LANDRACE:adult" }, getTypeName, true)
    assertEquals(table.concat(keys, ","), "COW_HOLSTEIN:young,COW_HOLSTEIN:adult,champion:COW,SHEEP_TEXEL:young," ..
        "PIG_LANDRACE:adult,herd")
    assertEquals(table.concat(TCShowRing.getSlotKeys({ "SHEEP_TEXEL:young" }, getTypeName, false), ","),
        "SHEEP_TEXEL:young", "one class: no champion, no herd")
    assertEquals(#TCShowRing.getSlotKeys({}, getTypeName, false), 0)
end)

test("too many classes: the breeders' own go from the end, a player's always runs", function()
    setup()
    local keys = { "COW_HOLSTEIN:young", "COW_HOLSTEIN:adult", "BULL_HOLSTEIN:young", "SHEEP_TEXEL:young",
        "PIG_LANDRACE:adult" }
    local players = { ["PIG_LANDRACE:adult"] = true, ["COW_HOLSTEIN:young"] = true }
    -- Five classes, a champion and the herd: seven slots. Four at most.
    local kept, dropped = TCShowRing.pickClasses(keys, players, getTypeName, true, 4)
    assertTrue(#TCShowRing.getSlotKeys(kept, getTypeName, true) <= 4)
    for _, key in ipairs(dropped) do
        assertTrue(not players[key], "never a player's")
    end
    local has = {}
    for _, key in ipairs(kept) do
        has[key] = true
    end
    assertTrue(has["PIG_LANDRACE:adult"] and has["COW_HOLSTEIN:young"])
    -- Room for all: nothing dropped.
    local all, none = TCShowRing.pickClasses(keys, players, getTypeName, true, 20)
    assertEquals(#all, #keys)
    assertEquals(#none, 0)
    -- Only players' classes, too many: they all stay.
    local stay = TCShowRing.pickClasses(keys, { ["COW_HOLSTEIN:young"] = true, ["COW_HOLSTEIN:adult"] = true,
        ["BULL_HOLSTEIN:young"] = true, ["SHEEP_TEXEL:young"] = true, ["PIG_LANDRACE:adult"] = true }, getTypeName,
        true, 2)
    assertEquals(#stay, #keys)
end)

test("the timetable: from 10:00, an hour each, shorter to end by 15:30, placed three quarters in", function()
    setup()
    local short = TCShowRing.buildTimetable({ "a", "b", "c" })
    assertEquals(#short, 3)
    assertEquals(short[1].from, TCShowRing.START_MINUTE)
    assertEquals(short[1].to - short[1].from, TCShowRing.SLOT_MINUTES, "an hour each when there's time")
    assertEquals(short[2].from, short[1].to, "one after another")
    assertTrue(short[1].judgeAt > short[1].from and short[1].judgeAt < short[1].to)
    local keys = {}
    for i = 1, TCShowRing.MAX_SLOTS do
        keys[i] = "k" .. i
    end
    local full = TCShowRing.buildTimetable(keys)
    local length = full[1].to - full[1].from
    assertTrue(length >= TCShowRing.MIN_SLOT_MINUTES and length < TCShowRing.SLOT_MINUTES)
    assertEquals(length % TCShowRing.STEP_MINUTES, 0)
    assertTrue(full[#full].to <= TCShowRing.END_MINUTE, "over by 15:30")
    assertEquals(#TCShowRing.buildTimetable({}), 0)
    local slot, index = TCShowRing.findSlot(full, "k3")
    assertEquals(index, 3)
    assertEquals(slot.key, "k3")
    assertEquals(TCShowRing.findSlot(full, "none"), nil)
end)

test("each slot's state on the day, and before and after it", function()
    setup()
    local timetable = TCShowRing.buildTimetable({ "a", "b", "c" })
    local states = TCShowRing.getSlotStates(timetable, 51, 51, timetable[2].from + 1)
    assertEquals(table.concat(states, ","), "done,now,next")
    assertEquals(table.concat(TCShowRing.getSlotStates(timetable, 50, 51, 900), ","), "next,next,next")
    assertEquals(table.concat(TCShowRing.getSlotStates(timetable, 52, 51, 0), ","), "done,done,done")
end)

test("the line in placing order: the champion, then best first, the unplaced as they stood", function()
    setup()
    local line = { { id = 1 }, { id = 2, placing = 3 }, { id = 3, placing = 1 }, { id = 4 }, { id = 5, placing = 2 } }
    local ordered = TCShowRing.orderByPlacing(line)
    local ids = {}
    for i, item in ipairs(ordered) do
        ids[i] = item.id
    end
    assertEquals(table.concat(ids, ","), "3,5,2,1,4")
    local champion = TCShowRing.orderByPlacing({ { id = 1 }, { id = 2, champion = true } })
    assertEquals(champion[1].id, 2)
end)
