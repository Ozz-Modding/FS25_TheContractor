-- The protest's pure half (151, TCProtestLayout): the farm's base, the
-- roads the groups stand on, where each person stands and what they hold,
-- and the auction clash.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCAuctionScene.lua")
    world:load("src/util/TCProtestLayout.lua")
    return world
end

-- A straight road along x at z, sampled every 20 m from x0 to x1, as
-- spline splineId, heading +x (or -x with reverse).
local function road(samples, splineId, z, x0, x1, reverse)
    local dirX = reverse and -1 or 1
    for x = x0, x1, 20 do
        table.insert(samples, { x = x, y = 0, z = z, dirX = dirX, dirZ = 0, splineId = splineId })
    end
    return samples
end

-- The same along z at x.
local function roadAlongZ(samples, splineId, x, z0, z1)
    for z = z0, z1, 20 do
        table.insert(samples, { x = x, y = 0, z = z, dirX = 0, dirZ = 1, splineId = splineId })
    end
    return samples
end

local function distance(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

test("the base is the farmland with most yard buildings, at their middle", function()
    setup()
    local x, z = TCProtestLayout.findBase({
        -- Farmland 1: a shed and a silo.
        { farmlandId = 1, x = 0, z = 0, isYard = true },
        { farmlandId = 1, x = 20, z = 10, isYard = true },
        { farmlandId = 1, x = 500, z = 500, isYard = false },
        -- Farmland 2: more buildings, but only one yard building.
        { farmlandId = 2, x = 900, z = 900, isYard = true },
        { farmlandId = 2, x = 910, z = 900, isYard = false },
        { farmlandId = 2, x = 920, z = 900, isYard = false },
        { farmlandId = 2, x = 930, z = 900, isYard = false },
    })
    assertNear(x, 10, 0.001, "x: the yard buildings' middle")
    assertNear(z, 5, 0.001, "z")
end)

test("without yard buildings the base is the middle of all the farmland's buildings", function()
    setup()
    local x, z = TCProtestLayout.findBase({
        { farmlandId = 3, x = 0, z = 0, isYard = false },
        { farmlandId = 3, x = 10, z = 30, isYard = false },
    })
    assertNear(x, 5, 0.001, "x")
    assertNear(z, 15, 0.001, "z")
end)

test("a farm with no buildings has no base", function()
    setup()
    local x, z = TCProtestLayout.findBase({})
    assertEquals(x, nil, "x")
    assertEquals(z, nil, "z")
end)

test("spots are the nearest road samples in range, spaced out, a road each first", function()
    setup()
    local samples = {}
    -- Road 1 runs past the base 80 m away, road 2 200 m away.
    road(samples, 1, 80, -400, 400)
    road(samples, 2, -200, -400, 400)
    local spots = TCProtestLayout.pickSpots(samples, 0, 0, 3)
    assertEquals(#spots, 3, "three spots")
    assertEquals(spots[1].splineId, 1, "the nearest road first")
    assertNear(spots[1].x, 0, 0.001, "the nearest point on it")
    assertEquals(spots[2].splineId, 2, "then a road of its own")
    for i = 1, #spots do
        local d = math.sqrt(spots[i].x ^ 2 + spots[i].z ^ 2)
        assertTrue(d >= TCProtestLayout.MIN_DISTANCE and d <= TCProtestLayout.MAX_DISTANCE, "in range " .. i)
        for j = i + 1, #spots do
            assertTrue(distance(spots[i], spots[j]) >= TCProtestLayout.SPACING, "spaced " .. i .. " " .. j)
        end
    end
end)

test("too near and too far are left out", function()
    setup()
    local samples = {}
    road(samples, 1, 30, -20, 20)
    road(samples, 2, 700, -20, 20)
    assertEquals(#TCProtestLayout.pickSpots(samples, 0, 0, 3), 0, "none")
end)

test("a junction is left out, the other lane of the same road isn't", function()
    setup()
    local samples = {}
    -- Road 1 along x at z = 100, crossed by road 2 along z at x = 0.
    road(samples, 1, 100, -100, 100)
    roadAlongZ(samples, 2, 0, 200, 260)
    table.insert(samples, { x = 0, y = 0, z = 100, dirX = 0, dirZ = 1, splineId = 2 })
    -- Road 1's other lane, 3 m over, running the other way.
    road(samples, 3, 103, -100, 100, true)
    local spots = TCProtestLayout.pickSpots(samples, 0, 0, 1)
    assertEquals(#spots, 1, "one")
    -- The nearest point (0, 100) is the crossing: the next along road 1 instead.
    assertEquals(spots[1].splineId, 1, "road 1")
    assertEquals(math.abs(spots[1].x), 20, "the next point along")
    assertTrue(TCProtestLayout.isNearJunction({ x = 0, y = 0, z = 100, dirX = 1, dirZ = 0, splineId = 1 }, samples),
        "the crossing is a junction")
    assertTrue(not TCProtestLayout.isNearJunction({ x = 60, y = 0, z = 100, dirX = 1, dirZ = 0, splineId = 1 },
        samples), "beside the other lane isn't")
end)

test("the engine's say rules a spot out", function()
    setup()
    local samples = road({}, 1, 80, -100, 100)
    local spots = TCProtestLayout.pickSpots(samples, 0, 0, 1, function(sample)
        return sample.x >= 60
    end)
    assertEquals(#spots, 1, "one")
    assertTrue(spots[1].x >= 60, "a usable one")
end)

test("a road with two lanes: the middle is straight across between them", function()
    setup()
    local samples = {}
    -- Lane 1 heading +x at z 100, sampled every 20 m from x -100; lane 2 the
    -- other way at z 104, sampled from x -90 (its points sit 10 m along
    -- from lane 1's, as two splines' samples do).
    road(samples, 1, 100, -100, 100)
    road(samples, 2, 104, -90, 90, true)
    local x, z, paired = TCProtestLayout.getRoadMiddle(samples[6], samples)
    assertTrue(paired, "the other lane's found")
    assertNear(x, samples[6].x, 0.001, "x: straight across, not towards a point along")
    assertNear(z, 102, 0.001, "z halfway")
    local single = road({}, 1, 100, -100, 100)
    local sx, sz, alone = TCProtestLayout.getRoadMiddle(single[3], single)
    assertTrue(not alone, "a lone spline")
    assertEquals(sx, single[3].x, "is the middle: x")
    assertEquals(sz, single[3].z, "z")
end)

test("the other lane can be the same spline, coming back", function()
    setup()
    local samples = {}
    -- One spline: up the lane at z 100, then back down the lane at z 103.5.
    road(samples, 1, 100, -100, 100)
    road(samples, 1, 103.5, -90, 90, true)
    local _, z, paired = TCProtestLayout.getRoadMiddle(samples[6], samples)
    assertTrue(paired, "found")
    assertNear(z, 101.75, 0.001, "halfway")
end)

test("a parallel lane running the same way pairs too", function()
    setup()
    local samples = {}
    road(samples, 1, 100, -100, 100)
    road(samples, 2, 103, -90, 90)
    local _, z, paired = TCProtestLayout.getRoadMiddle(samples[6], samples)
    assertTrue(paired, "found")
    assertNear(z, 101.5, 0.001, "halfway")
end)

test("the nearest lane across wins", function()
    setup()
    local samples = {}
    road(samples, 1, 100, -100, 100)
    road(samples, 2, 106, -100, 100, true)
    road(samples, 3, 103, -100, 100, true)
    local _, z = TCProtestLayout.getRoadMiddle(samples[6], samples)
    assertNear(z, 101.5, 0.001, "halfway to the nearer")
end)

test("a lane too far over is another road, not the other lane", function()
    setup()
    local samples = {}
    road(samples, 1, 100, -100, 100)
    road(samples, 2, 112, -100, 100, true)
    local _, z, paired = TCProtestLayout.getRoadMiddle(samples[6], samples)
    assertTrue(not paired, "not paired")
    assertEquals(z, 100, "the sample's own")
end)

test("the engine's checks are asked about the road's middle", function()
    setup()
    local samples = {}
    road(samples, 1, 100, -100, 100)
    road(samples, 2, 104, -100, 100, true)
    local asked = {}
    TCProtestLayout.pickSpots(samples, 0, 0, 1, function(spot)
        table.insert(asked, spot)
        return true
    end)
    assertTrue(#asked >= 1, "asked")
    assertNear(asked[1].z, 102, 0.001, "between the lanes")
end)

test("a group sits on the road's middle, its way towards the base", function()
    setup()
    local samples = {}
    road(samples, 1, 100, -100, 100)
    road(samples, 2, 104, -100, 100, true)
    -- The base is behind the sample (it heads +x, the base is at -x).
    local group = TCProtestLayout.makeGroup(samples[6], samples, -300, 100, 18)
    assertEquals(group.dirX, -1, "towards the base")
    assertNear(group.z, 102, 0.001, "on the middle")
    assertEquals(group.count, 18, "count")
end)

test("a group's people stand in a circle on the middle, the same on every machine", function()
    setup()
    local group = { x = 10, z = 20, dirX = 0, dirZ = 1, count = 20 }
    local people = TCProtestLayout.layOutGroup(group, 4242, 2)
    local again = TCProtestLayout.layOutGroup(group, 4242, 2)
    local radius = TCProtestLayout.getRadius(20)
    assertEquals(#people, 20, "twenty")
    for i, person in ipairs(people) do
        local r = math.sqrt((person.x - 10) ^ 2 + (person.z - 20) ^ 2)
        assertTrue(r <= radius + 0.001, "in the circle " .. i)
        assertEquals(person.x, again[i].x, "same x " .. i)
        assertEquals(person.yaw, again[i].yaw, "same way " .. i)
        assertEquals(person.slogan, again[i].slogan, "same slogan " .. i)
    end
end)

test("the circle is as big as the crowd needs", function()
    setup()
    local r15, r20 = TCProtestLayout.getRadius(15), TCProtestLayout.getRadius(20)
    assertNear(math.pi * r20 ^ 2 / 20, TCProtestLayout.AREA_PER_PERSON, 0.001, "room each")
    assertTrue(r20 > r15, "more people, bigger")
    assertTrue(r20 < 4.5, "a road's width or so")
end)

test("no two placards in a group say the same", function()
    setup()
    for seed = 1, 20 do
        local people = TCProtestLayout.layOutGroup({ x = 0, z = 0, dirX = 1, dirZ = 0, count = 10 }, seed, 1)
        local seen = {}
        for _, person in ipairs(people) do
            if person.slogan ~= nil then
                assertTrue(person.slogan >= 1 and person.slogan <= TCProtestLayout.SLOGAN_COUNT, "a slogan")
                assertTrue(not seen[person.slogan], "not repeated, seed " .. seed)
                seen[person.slogan] = true
            end
        end
    end
end)

test("everyone has room", function()
    setup()
    for seed = 1, 30 do
        local people = TCProtestLayout.layOutGroup({ x = 0, z = 0, dirX = 0, dirZ = 1, count = 20 }, seed, 1)
        for i, person in ipairs(people) do
            for j = i + 1, #people do
                local d = math.sqrt((person.x - people[j].x) ^ 2 + (person.z - people[j].z) ^ 2)
                -- MIN_GAP is what the scatter aims for; it may fall a little short.
                assertTrue(d >= 0.75, "room between " .. i .. " and " .. j .. ", seed " .. seed)
            end
        end
    end
end)

test("people are spread over the whole circle, not lined up", function()
    setup()
    -- The circle cut into 8 slices round and 2 rings (inner and outer, the
    -- same area): 20 people put down at random hit about 11.5 of the 16.
    local count = 20
    local radius = TCProtestLayout.getRadius(count)
    local total, seeds = 0, 50
    for seed = 1, seeds do
        local cells, hit = {}, 0
        for _, spot in ipairs(TCProtestLayout.scatter(count, seed, 1)) do
            local angle = math.atan2(spot.across, spot.along) + math.pi
            local slice = math.min(7, math.floor(angle / (2 * math.pi) * 8))
            local ring = (spot.along ^ 2 + spot.across ^ 2) > radius ^ 2 / 2 and 1 or 0
            local key = slice * 2 + ring
            if not cells[key] then
                cells[key] = true
                hit = hit + 1
            end
        end
        total = total + hit
    end
    assertTrue(total / seeds >= 10, "spread over the circle: " .. total / seeds .. " cells")
end)

test("everyone faces their own way, most towards the base", function()
    setup()
    -- The base's way is +z (yaw 0).
    local towards, total = 0, 0
    for seed = 1, 20 do
        local people = TCProtestLayout.layOutGroup({ x = 0, z = 0, dirX = 0, dirZ = 1, count = 20 }, seed, 1)
        local yaws = {}
        for _, person in ipairs(people) do
            total = total + 1
            if math.cos(person.yaw) > 0 then
                towards = towards + 1
            end
            yaws[string.format("%.2f", person.yaw)] = true
        end
        local distinct = 0
        for _ in pairs(yaws) do
            distinct = distinct + 1
        end
        assertTrue(distinct >= 15, "each their own way, seed " .. seed)
    end
    assertTrue(towards / total > 0.5 and towards / total < 0.8, "most towards the base: " .. towards / total)
end)

test("the mixed random is spread evenly and the same every time", function()
    setup()
    local bins = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    for seed = 1, 2000 do
        local value = TCProtestLayout.random(seed, 2, 3, 4)
        assertTrue(value >= 0 and value < 1, "a fraction")
        local bin = math.floor(value * 10) + 1
        bins[bin] = bins[bin] + 1
    end
    for i, n in ipairs(bins) do
        assertTrue(n > 150 and n < 250, "tenth " .. i .. ": " .. n)
    end
    assertEquals(TCProtestLayout.random(99, 1, 2, 3), TCProtestLayout.random(99, 1, 2, 3), "same")
end)

test("everyone in a protest, group by group", function()
    setup()
    local people = TCProtestLayout.layOut({
        { x = 0, z = 0, dirX = 1, dirZ = 0, count = 16 },
        { x = 200, z = 0, dirX = 1, dirZ = 0, count = 18 },
    }, 99)
    assertEquals(#people, 34, "everyone")
    assertEquals(people[1].group, 1, "first group")
    assertEquals(people[34].group, 2, "second group")
end)

test("about seven in ten hold a placard", function()
    setup()
    local holders, total = 0, 0
    for seed = 1, 40 do
        for _, person in ipairs(TCProtestLayout.layOutGroup({ x = 0, z = 0, dirX = 1, dirZ = 0,
            count = 10 }, seed, 1)) do
            total = total + 1
            if person.slogan ~= nil then
                holders = holders + 1
            end
        end
    end
    assertNear(holders / total, TCProtestLayout.PLACARD_SHARE, 0.1, "share")
end)

test("about a third of placards are chalkboards, the rest card; nobody without one has a style", function()
    setup()
    local chalk, placards = 0, 0
    for seed = 1, 40 do
        for _, person in ipairs(TCProtestLayout.layOutGroup({ x = 0, z = 0, dirX = 1, dirZ = 0, count = 20 }, seed, 1)) do
            if person.slogan ~= nil then
                placards = placards + 1
                assertTrue(person.style == TCProtestLayout.STYLE.CARD or person.style == TCProtestLayout.STYLE.CHALK,
                    "a style")
                if person.style == TCProtestLayout.STYLE.CHALK then
                    chalk = chalk + 1
                end
            else
                assertEquals(person.style, nil, "no placard, no style")
            end
        end
    end
    assertNear(chalk / placards, TCProtestLayout.CHALK_SHARE, 0.08, "share")
end)

test("groups go into the incident's flat data and back", function()
    setup()
    local groups = {
        { x = 1.5, z = 2.5, dirX = 0, dirZ = 1, count = 6, paired = true },
        { x = 100, z = -40, dirX = 1, dirZ = 0, count = 9, paired = false },
    }
    local data = {}
    TCProtestLayout.setGroups(data, groups)
    for key, value in pairs(data) do
        assertTrue(type(key) == "string" and (type(value) == "number" or type(value) == "boolean"),
            "flat " .. tostring(key))
    end
    local back = TCProtestLayout.getGroups(data)
    assertEquals(#back, 2, "two")
    for i, group in ipairs(groups) do
        for _, key in ipairs(TCProtestLayout.GROUP_KEYS) do
            assertEquals(back[i][key], group[key], key .. " " .. i)
        end
    end
end)
