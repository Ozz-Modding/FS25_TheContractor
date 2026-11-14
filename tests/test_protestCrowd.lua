-- The protest's engine half (151, TCProtestCrowd) against fake nodes:
-- collision blocks for the people and one round each group for traffic
-- (held back while something's in the way), map markers for the protest's own farm, everything gone when the
-- incident is, and a placard handed to a loaded person as vanilla hands a
-- tool over. The people's models aren't loaded here (no camera): that's
-- TCFigures', seen in game.

local function setup(options)
    options = options or {}
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor", dir = "" }

    -- Nodes: plain tables; world.inPhysics and world.deleted record them.
    world.inPhysics, world.deleted = {}, {}
    getRootNode = function() return "root" end
    getChildAt = function(node, index) return node.children[index + 1] end
    getNumOfChildren = function(node) return #node.children end
    setVisibility = function(node, isVisible) node.isVisible = isVisible end
    -- A copy with copies of its children (each block's shapes its own).
    local function copy(node)
        local children = {}
        for i, child in ipairs(node.children or {}) do
            children[i] = copy(child)
        end
        return { name = node.name, children = children, isClone = true }
    end
    clone = function(node) return copy(node) end
    link = function(parent, node) node.parent = parent end
    setTranslation = function(node, x, y, z) node.x, node.y, node.z = x, y, z end
    setRotation = function(node, rx, ry, rz) node.rx, node.ry, node.rz = rx, ry, rz end
    HandToolUtil = {
        transformRelativeToParent = function(root, child, parent)
            table.insert(world.grips, { root = root, child = child, parent = parent })
        end,
    }
    world.grips = {}
    addToPhysics = function(node) world.inPhysics[node] = true end
    removeFromPhysics = function(node) world.inPhysics[node] = nil end
    entityExists = function(node) return not world.deleted[node] end
    delete = function(node) world.deleted[node] = true end
    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function() return 0 end
    -- world.blocked(x, z): something that moves is there. With
    -- world.seeOwn, every shape of ours in physics is reported too, as the
    -- engine would (the crowd block is flagged as a player).
    overlapBox = function(x, y, z, rx, ry, rz, ex, ey, ez, callback, target)
        if world.seeOwn then
            for node in pairs(world.inPhysics) do
                for _, child in ipairs(node.children or {}) do
                    if not target[callback](target, child) then
                        return
                    end
                end
            end
        end
        if world.blocked ~= nil and world.blocked(x, z) then
            target[callback](target, 99)
        end
    end
    CollisionFlag = { VEHICLE = 1, PLAYER = 2, TRAFFIC_VEHICLE = 4, DYNAMIC_OBJECT = 8 }
    g_i3DManager = {
        loadSharedI3DFileAsync = function(_, filename, _, _, callback, target, args)
            -- The placard: visuals (pole, boards, faces) and handNode.
            local boards = { children = { { name = "board_card" }, { name = "board_chalk" } } }
            local faces = { children = {} }
            for i = 1, 34 do
                faces.children[i] = { name = "face" .. i }
            end
            local model = { name = filename, children = { { children = { {}, boards, faces } }, { name = "handNode" } } }
            if not string.find(filename, "Placard", 1, true) then
                -- A block: its root holding one collision shape.
                model = { name = filename, children = { { name = "col", children = {} } } }
            end
            callback(target, { children = { model } }, nil, args)
            return 1
        end,
        releaseSharedI3DFile = function() end,
    }

    -- This machine: a dedicated server, or a client of farm options.farmId.
    g_dedicatedServer = nil
    if not options.isClient then
        g_dedicatedServer = {}
    end
    g_currentMission.getIsClient = function() return options.isClient == true end
    g_currentMission.getFarmId = function() return options.farmId or 1 end
    g_cameraManager = nil
    world.hotspots = {}
    PlaceableHotspot = { TYPE = { EXCLAMATION_MARK = 1 } }
    function PlaceableHotspot.new()
        local hotspot = {}
        function hotspot:setName() end
        function hotspot:createIcon() end
        function hotspot:setPlaceableType() end
        function hotspot:setWorldPosition(x, z) self.x, self.z = x, z end
        function hotspot:delete() self.isDeleted = true end
        return hotspot
    end
    g_currentMission.hud = {}
    g_currentMission.addMapHotspot = function(_, hotspot) world.hotspots[hotspot] = true end
    g_currentMission.removeMapHotspot = function(_, hotspot) world.hotspots[hotspot] = nil end
    g_currentMission.environment = { dayTime = 10 * 3600000 }

    world:load("src/util/TCAuctionScene.lua")
    world:load("src/util/TCProtestLayout.lua")
    world:load("src/util/TCFigures.lua")
    world:load("src/util/TCProtestCrowd.lua")
    TCFigures.readTemplates = function() return {} end
    TheContractorProtest = {
        STAGE = { NOTICE = "notice", OUT = "out" },
        getIncidents = function() return world.incidents end,
        isOut = function(incident) return incident.stage == "out" end,
    }
    g_currentMission.TheContractor.RandomEvents = {}
    TCProtestCrowd.reset()

    world.incidents = {}
    function world:addIncident(stage, forced)
        local data = { day = 41, seed = 777, forced = forced == true }
        TCProtestLayout.setGroups(data, {
            { x = 0, z = 100, dirX = 0, dirZ = -1, count = 6 },
            { x = 200, z = 0, dirX = -1, dirZ = 0, count = 5 },
        })
        local incident = { id = 3, farmId = 1, eventType = "protest", stage = stage, data = data }
        table.insert(self.incidents, incident)
        return incident
    end
    return world
end

local function countBlocks(world)
    local count = 0
    for _ in pairs(world.inPhysics) do
        count = count + 1
    end
    return count
end

local function countHotspots(world)
    local count = 0
    for _ in pairs(world.hotspots) do
        count = count + 1
    end
    return count
end

local function tick()
    TCProtestCrowd.update(TCProtestCrowd.BLOCK_INTERVAL_MS)
end

test("a block for everyone, whatever the hour, on a server with nobody to see them", function()
    local world = setup()
    world:addIncident("out")
    g_currentMission.environment.dayTime = 18.9 * 3600000
    tick()
    assertEquals(countBlocks(world), 11 + 2, "everyone, late on too, and a crowd block a group")
    assertEquals(countHotspots(world), 0, "no markers on a dedicated server")
end)

test("no blocks before they're out", function()
    local world = setup()
    world:addIncident("notice")
    tick()
    assertEquals(countBlocks(world), 0, "none the evening before")
end)

test("no block where a vehicle is, until it's moved", function()
    local world = setup()
    world:addIncident("out")
    world.blocked = function(x, z) return x > 150 end
    tick()
    assertEquals(countBlocks(world), 6 + 2, "the second group's people wait; both crowd blocks go down regardless")
    world.blocked = nil
    tick()
    assertEquals(countBlocks(world), 11 + 2, "in once it's clear")
end)

test("our own blocks don't hold each other back", function()
    local world = setup()
    world.seeOwn = true
    world:addIncident("out")
    tick()
    assertEquals(countBlocks(world), 11 + 2, "all down")
end)

test("the crowd block is round the biggest group's circle", function()
    setup()
    assertTrue(TCProtestCrowd.CROWD_BLOCK_HALF >= TCProtestLayout.getRadius(TCProtestLayout.PEOPLE_MAX) + 0.3,
        "room for the biggest crowd")
end)

test("markers for the protest's own farm from the warning, and everything goes with it", function()
    local world = setup({ isClient = true, farmId = 1 })
    world:addIncident("notice")
    tick()
    assertEquals(countHotspots(world), 2, "a marker a group")
    world.incidents[1].stage = "out"
    tick()
    assertEquals(countBlocks(world), 11 + 2, "blocks on a client too")
    world.incidents = {}
    tick()
    assertEquals(countHotspots(world), 0, "markers gone")
    assertEquals(countBlocks(world), 0, "blocks gone")
end)

test("another farm's players get no markers", function()
    local world = setup({ isClient = true, farmId = 2 })
    world:addIncident("notice")
    tick()
    assertEquals(countHotspots(world), 0, "none")
end)

test("a placard is handed to a loaded person once, its handNode on their hand", function()
    local world = setup({ isClient = true })
    local hand = { name = "rightHand" }
    local figure = { slogan = 3, style = TCProtestLayout.STYLE.CHALK,
        graphics = { model = { thirdPersonRightHandNode = hand } } }
    assertTrue(TCProtestCrowd.attachPlacard(figure), "held")
    local placard = figure.placard
    assertTrue(placard ~= nil and placard.isClone, "a copy of the model")
    assertEquals(placard.parent, hand, "linked under the hand")
    assertEquals(#world.grips, 1, "lined up once")
    assertEquals(world.grips[1].root, placard, "the placard")
    assertEquals(world.grips[1].child.name, "handNode", "by its handNode")
    assertEquals(world.grips[1].parent, hand, "to the hand")
    -- The chalkboard, and its third slogan (after the 17 card ones).
    local boards = getChildAt(getChildAt(placard, 0), TCProtestCrowd.BOARDS_INDEX)
    assertEquals(boards.children[1].isVisible, false, "not the card")
    assertEquals(boards.children[2].isVisible, true, "the chalkboard")
    local faces = getChildAt(getChildAt(placard, 0), TCProtestCrowd.FACES_INDEX)
    for i = 1, 34 do
        assertEquals(faces.children[i].isVisible, i == TCProtestLayout.SLOGAN_COUNT + 3, "face " .. i)
    end

    assertTrue(TCProtestCrowd.attachPlacard(figure), "already held")
    assertEquals(#world.grips, 1, "not again")
    assertEquals(TCProtestCrowd.attachPlacard({ graphics = figure.graphics }), true, "nobody without a slogan gets one")
end)

test("a person still loading waits for their placard", function()
    setup({ isClient = true })
    local figure = { slogan = 1, graphics = { model = {} } }
    assertEquals(TCProtestCrowd.attachPlacard(figure), false, "no hand yet")
    assertEquals(figure.placard, nil, "none")
end)
