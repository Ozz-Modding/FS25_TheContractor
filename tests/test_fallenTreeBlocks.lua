-- Fallen tree (107, issue 19): TCFallenTreeBlocks' traffic blocks against
-- fake nodes. One on the road of each tree that isn't clear, turned along
-- it; a tree's goes once its road's clear, the rest with the incident, and
-- one follows its tree when they're renumbered once down.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor", dir = "" }

    world.inPhysics, world.deleted, world.loads = {}, {}, 0
    getRootNode = function() return "root" end
    getChildAt = function(node, index) return node.children[index + 1] end
    clone = function(node) return { name = node.name, children = {} } end
    link = function(parent, node) node.parent = parent end
    setTranslation = function(node, x, y, z) node.x, node.y, node.z = x, y, z end
    setRotation = function(node, rx, ry, rz) node.rx, node.ry, node.rz = rx, ry, rz end
    addToPhysics = function(node) world.inPhysics[node] = true end
    removeFromPhysics = function(node) world.inPhysics[node] = nil end
    entityExists = function(node) return not world.deleted[node] end
    delete = function(node) world.deleted[node] = true end
    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function() return 12 end
    g_i3DManager = {
        loadSharedI3DFileAsync = function(_, filename, _, _, callback, target, args)
            world.loads = world.loads + 1
            callback(target, { children = { { name = filename, children = {} } } }, nil, args)
            return 1
        end,
        releaseSharedI3DFile = function() end,
    }

    world:load("src/business/FallenTree.lua")
    world:load("src/util/TCFallenTreeBlocks.lua")
    TCFallenTreeBlocks.reset()

    world.incidents = {}
    g_currentMission.TheContractor.RandomEvents = { incidents = world.incidents }
    function world:addIncident(id, trees)
        local data = { stage = "open" }
        TheContractorFallenTree.setTrees(data, trees)
        local incident = { id = id, farmId = 1, eventType = TheContractorFallenTree.EVENT_TYPE, stage = "open",
            data = data }
        self.incidents[id] = incident
        return incident
    end
    return world
end

local function tree(roadX, roadZ, isClear)
    return { x = roadX + 6, z = roadZ, dirX = -1, dirZ = 0, roadX = roadX, roadZ = roadZ, roadDirX = 0, roadDirZ = 1,
        isClear = isClear }
end

local function blocksInPhysics(world)
    local nodes = {}
    for node in pairs(world.inPhysics) do
        table.insert(nodes, node)
    end
    table.sort(nodes, function(a, b) return a.x < b.x end)
    return nodes
end

test("a block goes down on each tree's road, along the road, not on a clear one", function()
    local world = setup()
    world:addIncident(4, { tree(100, 50), tree(300, 80), tree(500, 20, true) })
    TCFallenTreeBlocks.update(TCFallenTreeBlocks.INTERVAL_MS)

    local nodes = blocksInPhysics(world)
    assertEquals(2, #nodes)
    assertEquals(100, nodes[1].x)
    assertEquals(12, nodes[1].y)
    assertEquals(50, nodes[1].z)
    assertNear(0, nodes[1].ry, 1e-6)
    assertEquals("root", nodes[1].parent)
    assertEquals(300, nodes[2].x)
    assertEquals(1, world.loads)
end)

test("nothing's checked between intervals, and no model loads without a tree", function()
    local world = setup()
    TCFallenTreeBlocks.update(TCFallenTreeBlocks.INTERVAL_MS)
    assertEquals(0, world.loads)
    world:addIncident(4, { tree(100, 50) })
    TCFallenTreeBlocks.update(TCFallenTreeBlocks.INTERVAL_MS - 1)
    assertEquals(0, #blocksInPhysics(world))
    TCFallenTreeBlocks.update(1)
    assertEquals(1, #blocksInPhysics(world))
end)

test("a tree's block goes once its road's clear, the rest stay", function()
    local world = setup()
    local incident = world:addIncident(4, { tree(100, 50), tree(300, 80) })
    TCFallenTreeBlocks.refresh(world.incidents)
    local first = blocksInPhysics(world)[1]

    TheContractorFallenTree.setTreeValue(incident.data, 1, "isClear", true)
    TCFallenTreeBlocks.refresh(world.incidents)
    local nodes = blocksInPhysics(world)
    assertEquals(1, #nodes)
    assertEquals(300, nodes[1].x)
    assertTrue(world.deleted[first])
end)

test("every block goes with the incident when the job's over", function()
    local world = setup()
    world:addIncident(4, { tree(100, 50), tree(300, 80) })
    world:addIncident(7, { tree(900, 10) })
    TCFallenTreeBlocks.refresh(world.incidents)
    assertEquals(3, TCFallenTreeBlocks.count())

    world.incidents[4] = nil
    TCFallenTreeBlocks.refresh(world.incidents)
    local nodes = blocksInPhysics(world)
    assertEquals(1, #nodes)
    assertEquals(900, nodes[1].x)
end)

test("a block follows its tree when they're renumbered once down", function()
    local world = setup()
    local incident = world:addIncident(4, { tree(100, 50), tree(300, 80) })
    TCFallenTreeBlocks.refresh(world.incidents)

    -- The first didn't come down: the second's now tree 1.
    TheContractorFallenTree.setTrees(incident.data, { tree(300, 80) })
    TCFallenTreeBlocks.refresh(world.incidents)
    local nodes = blocksInPhysics(world)
    assertEquals(1, #nodes)
    assertEquals(300, nodes[1].x)
    assertEquals(1, TCFallenTreeBlocks.count())
end)

test("another event's incidents get none, and a reset takes every block away", function()
    local world = setup()
    world.incidents[2] = { id = 2, farmId = 1, eventType = "protest", stage = "out", data = {} }
    world:addIncident(4, { tree(100, 50) })
    TCFallenTreeBlocks.refresh(world.incidents)
    assertEquals(1, TCFallenTreeBlocks.count())

    TCFallenTreeBlocks.reset()
    assertEquals(0, #blocksInPhysics(world))
    assertEquals(0, TCFallenTreeBlocks.count())
end)
