-- Ballast weights stay on their machine (TCBallast): a job's tractor keeps
-- its weight unless a job implement needs the hitch, everything else it
-- carries is unhitched for the dispatch to park, and a weight is hidden,
-- revealed, kept on and parked with its machine.

-- Nodes are { x, y, z, ry }: turned about y only, which is all parking does.
local function installTransforms()
    local function toWorld(node, lx, ly, lz)
        local c, s = math.cos(node.ry), math.sin(node.ry)
        return node.x + lx * c + lz * s, node.y + ly, node.z - lx * s + lz * c
    end
    function getWorldTranslation(node) return node.x, node.y, node.z end
    function getWorldRotation(node) return 0, node.ry, 0 end
    function localToWorld(node, lx, ly, lz) return toWorld(node, lx, ly, lz) end
    function worldToLocal(node, wx, wy, wz)
        local c, s = math.cos(node.ry), math.sin(node.ry)
        local dx, dz = wx - node.x, wz - node.z
        return dx * c - dz * s, wy - node.y, dx * s + dz * c
    end
    function localDirectionToWorld(node, lx, ly, lz)
        local c, s = math.cos(node.ry), math.sin(node.ry)
        return lx * c + lz * s, ly, -lx * s + lz * c
    end
    function worldDirectionToLocal(node, dx, dy, dz)
        local c, s = math.cos(node.ry), math.sin(node.ry)
        return dx * c - dz * s, dy, dx * s + dz * c
    end
    function worldRotationToLocal(node, rx, ry, rz) return rx, ry - node.ry, rz end
    function localRotationToWorld(node, rx, ry, rz) return rx, ry + node.ry, rz end
end

local function setup()
    local world = stubs.install()
    installTransforms()
    g_storeManager = {
        getItemByXMLFilename = function(_, fileName)
            return { categoryName = fileName }
        end,
    }
    -- Front-only implements (a front mower) fit only a front hitch.
    AttacherJoints = {
        getAttacherJointCompatibility = function(_, attacherJoint, implement)
            return not implement.frontOnly or attacherJoint.attacherJointDirection == 1
        end,
    }
    TCDispatchFailedEvent = {}
    world:load("src/util/TCEquipmentClass.lua")
    world:load("src/util/TCBallast.lua")
    world:load("src/util/TCEquipmentVisibility.lua")
    -- No hitching mods loaded: their compatibility does nothing.
    TheContractorDrivers = { getModEnv = function() return nil end }
    world:load("src/util/TCManualAttach.lua")
    world:load("src/util/TCAttachImplementsManually.lua")
    world:load("src/util/TCJobSiteSetup.lua")
    TCEquipmentVisibility.reset()
    world.physicsLog = {}
    return world
end

-- def: { name, category, typeName, x, z, ry, width, length, lengthOffset }
local function addMachine(world, def)
    local vehicle = world:addVehicle({ name = def.name })
    vehicle.configFileName = def.category
    vehicle.typeName = def.typeName
    vehicle.rootNode = { x = def.x or 0, y = 0, z = def.z or 0, ry = def.ry or 0 }
    vehicle.size = { width = def.width or 1, length = def.length or 1, lengthOffset = def.lengthOffset or 0 }
    vehicle.isVisible = true
    vehicle.inPhysics = true
    vehicle.attached = {}
    vehicle.joints = {}

    function vehicle:getAttachedImplements() return self.attached end
    function vehicle:getAttacherVehicle() return self.attacher end
    function vehicle:getAttacherJoints() return self.joints end
    function vehicle:getInputAttacherJoints() return { { jointType = "implement" } } end
    function vehicle:getIsAttachedTo(other) return self.attacher == other end
    function vehicle:getImplementByJointDescIndex(index)
        for _, implement in ipairs(self.attached) do
            if implement.jointDescIndex == index then
                return implement
            end
        end
        return nil
    end
    function vehicle:detachImplementByObject(object)
        for i, implement in ipairs(self.attached) do
            if implement.object == object then
                table.remove(self.attached, i)
                object.attacher = nil
                return
            end
        end
    end
    function vehicle:removeFromPhysics()
        self.inPhysics = false
        table.insert(world.physicsLog, self.name .. " out")
    end
    function vehicle:addToPhysics()
        self.inPhysics = true
        table.insert(world.physicsLog, self.name .. " in")
    end
    function vehicle:setVisibility(isVisible) self.isVisible = isVisible end
    function vehicle:setAbsolutePosition(x, y, z, _, ry)
        self.rootNode = { x = x, y = y, z = z, ry = ry }
    end
    return vehicle
end

-- A tractor with a front and a rear three-point hitch and a front loader
-- console.
local FRONT, REAR, LOADER = 1, 2, 3
local function addTractor(world)
    local tractor = addMachine(world, { name = "Tractor", width = 3, length = 5 })
    tractor.spec_motorized = {}
    tractor.spec_attacherJoints = {}
    tractor.joints = {
        [FRONT] = { jointType = "implement", attacherJointDirection = 1 },
        [REAR] = { jointType = "implement", attacherJointDirection = -1 },
        [LOADER] = { jointType = "attachableFrontloader", attacherJointDirection = 1 },
    }
    return tractor
end

local function hitch(attacher, object, jointIndex)
    table.insert(attacher.attached, { object = object, jointDescIndex = jointIndex })
    object.attacher = attacher
end

-- A weight on the tractor's front hitch, 3 m ahead of its middle.
local function addFrontWeight(world, tractor)
    local weight = addMachine(world, { name = "Weight", category = "WEIGHTS", x = tractor.rootNode.x,
        z = tractor.rootNode.z + 3, ry = tractor.rootNode.ry })
    hitch(tractor, weight, FRONT)
    return weight
end

local function addLoader(world, tractor)
    local loader = addMachine(world, { name = "Loader", category = "FRONTLOADERS" })
    function loader:getInputAttacherJoints() return { { jointType = "attachableFrontloader" } } end
    loader.joints = { { jointType = "frontloaderTool", attacherJointDirection = 1 } }
    hitch(tractor, loader, LOADER)
    local bucket = addMachine(world, { name = "Bucket", category = "FRONTLOADERBUCKETS" })
    hitch(loader, bucket, 1)
    return loader, bucket
end

local function jobWith(...)
    local ids = {}
    for _, vehicle in ipairs({ ... }) do
        table.insert(ids, vehicle.id)
    end
    return { id = 1, farmId = 1, assignedEquipmentIds = ids }
end

local function idList(ids)
    local sorted = { unpack(ids) }
    table.sort(sorted)
    return table.concat(sorted, ",")
end

test("a weight is told by its store category or its vehicle type", function()
    local world = setup()
    assertTrue(TCBallast.isWeight(addMachine(world, { category = "WEIGHTS" })), "category")
    assertTrue(TCBallast.isWeight(addMachine(world, { typeName = "weight" })), "vanilla type")
    assertTrue(TCBallast.isWeight(addMachine(world, { typeName = "FS25_SomeMod.weight" })), "a mod's type")
    assertTrue(not TCBallast.isWeight(addMachine(world, { category = "PLOWS", typeName = "plow" })), "plough")
    assertTrue(not TCBallast.isWeight(addMachine(world, { typeName = "frontWeightCarrier" })), "only the whole name")
end)

test("at dispatch a weight nothing needs stays on, and the loader and its bucket come off", function()
    local world = setup()
    local tractor = addTractor(world)
    local weight = addFrontWeight(world, tractor)
    local loader, bucket = addLoader(world, tractor)
    local plough = addMachine(world, { name = "Plough", category = "PLOWS" })

    local detached = TCJobSiteSetup.detachForeignImplements(jobWith(tractor, plough))

    assertEquals(weight.attacher, tractor, "weight kept")
    assertEquals(loader.attacher, nil, "loader off")
    assertEquals(bucket.attacher, loader, "bucket stays on the loader")
    assertEquals(idList(detached), idList({ loader.id, bucket.id }), "both for parking")
end)

test("a weight on the hitch a job implement needs comes off for parking", function()
    local world = setup()
    local tractor = addTractor(world)
    local weight = addFrontWeight(world, tractor)
    local mower = addMachine(world, { name = "Front mower", category = "MOWERS" })
    mower.frontOnly = true

    local detached = TCJobSiteSetup.detachForeignImplements(jobWith(tractor, mower))

    assertEquals(weight.attacher, nil, "weight off")
    assertEquals(idList(detached), tostring(weight.id))
end)

test("a rear implement takes the rear hitch even when something foreign is on it", function()
    local world = setup()
    local tractor = addTractor(world)
    local leftOn = addMachine(world, { name = "Plough", category = "PLOWS" })
    hitch(tractor, leftOn, REAR)
    local mower = addMachine(world, { name = "Rear mower", category = "MOWERS" })

    local plans = TCJobSiteSetup.planHitches(jobWith(tractor, mower))

    assertEquals(#plans, 1)
    assertEquals(plans[1].jointIndex, REAR, "rear, not the free front")
    assertEquals(plans[1].occupant, leftOn, "the plough comes off")
    local detached = TCJobSiteSetup.detachForeignImplements(jobWith(tractor, mower))
    assertEquals(idList(detached), tostring(leftOn.id), "and is parked")
end)

-- Hitches with real frames: the attachment lines the implement's input
-- joint node up with the attacher joint's transform. Here the rear
-- linkage's transform points backwards and the front's forwards, so a rear
-- implement's input node faces back towards the tractor (half a turn from
-- its root) and a front one's faces the same way as its root.
local function addFramedTractor(world)
    local tractor = addTractor(world)
    tractor.joints[FRONT].jointTransform = { x = 0, y = 0, z = 0, ry = 0 }
    tractor.joints[REAR].jointTransform = { x = 0, y = 0, z = 0, ry = math.pi }
    return tractor
end

-- Parked at an angle, to show only each machine's own frame counts.
local function addAIMower(world, name, isFront)
    local mower = addMachine(world, { name = name, category = "MOWERS", ry = 0.7 })
    local inputNode = { x = 0, y = 0, z = 0, ry = mower.rootNode.ry + (isFront and 0 or math.pi) }
    function mower:getInputAttacherJoints() return { { jointType = "implement", node = inputNode } } end
    function mower:getAINeedsRootAlignment() return true end
    return mower
end

test("a front and a rear mower each take the hitch they face forward on, whichever is planned first", function()
    local world = setup()
    local tractor = addFramedTractor(world)
    local frontMower = addAIMower(world, "Front mower", true)
    local rearMower = addAIMower(world, "Rear mower", false)

    local plans = TCJobSiteSetup.planHitches(jobWith(tractor, frontMower, rearMower))

    assertEquals(#plans, 2)
    assertEquals(plans[1].implement, frontMower)
    assertEquals(plans[1].jointIndex, FRONT, "front mower not taken backwards on the rear")
    assertEquals(plans[2].implement, rearMower)
    assertEquals(plans[2].jointIndex, REAR)
end)

test("a rear mower is never put on the front linkage, so a second one can't be rigged", function()
    local world = setup()
    local tractor = addFramedTractor(world)
    local first = addAIMower(world, "Rear mower 1", false)
    local second = addAIMower(world, "Rear mower 2", false)

    local plans, reasonKey = TCJobSiteSetup.planHitches(jobWith(tractor, first, second))

    assertEquals(plans, nil)
    assertEquals(reasonKey, "tc_dispatch_noAttachPoint")
end)

test("split up for parking, a machine keeps its weight", function()
    local world = setup()
    local tractor = addTractor(world)
    local weight = addFrontWeight(world, tractor)
    local plough = addMachine(world, { name = "Plough", category = "PLOWS" })
    hitch(tractor, plough, REAR)

    TCJobSiteSetup.unhitchVehicles({ tractor.id, plough.id })

    assertEquals(weight.attacher, tractor, "weight kept")
    assertEquals(plough.attacher, nil, "plough off")
end)

test("a weight is hidden with its machine and back in physics after it", function()
    local world = setup()
    local tractor = addTractor(world)
    local weight = addFrontWeight(world, tractor)

    TCEquipmentVisibility.hideVehicles({ tractor.id })
    assertEquals(weight.isVisible, false, "hidden")
    assertEquals(weight.inPhysics, false, "out of physics")
    assertTrue(TCEquipmentVisibility.isHidden(weight.id), "in the hidden set for joining clients")

    world.physicsLog = {}
    TCEquipmentVisibility.revealVehicles({ tractor.id })
    assertEquals(weight.isVisible, true, "shown")
    assertEquals(table.concat(world.physicsLog, ","), "Tractor out,Tractor in,Weight out,Weight in",
        "tractor first, so the weight's joint is rebuilt")
    assertTrue(not TCEquipmentVisibility.isHidden(weight.id), "out of the hidden set")
end)

test("the footprint takes in the weight in front", function()
    local world = setup()
    local tractor = addTractor(world)
    addFrontWeight(world, tractor)

    local width, length, widthOffset, lengthOffset, height = TCBallast.getFootprint(tractor, 3, 5, 4)

    assertNear(width, 3, 0.001)
    -- Tractor -2.5..2.5, weight 2.5..3.5.
    assertNear(length, 6, 0.001)
    assertNear(widthOffset, 0, 0.001)
    assertNear(lengthOffset, 0.5, 0.001)
    assertEquals(height, 4)
end)

test("a parked machine takes its weight along, still in front of it", function()
    local world = setup()
    CollisionFlag = { VEHICLE = 1, PLAYER = 2, DYNAMIC_OBJECT = 4, TREE = 8, STATIC_OBJECT = 16, BUILDING = 32 }
    GuiTopDownCursor = { getHitPlaceable = function() return nil end }
    world:load("src/placeables/PlaceableTCParkingSlot.lua")
    world:load("src/util/TCParking.lua")
    local tractor = addTractor(world)
    local weight = addFrontWeight(world, tractor)
    TCEquipmentVisibility.hideVehicles({ tractor.id })

    -- Turned a quarter: the tractor's front now points along +x.
    TCParking.placeVehicle(tractor, 100, 0, 50, math.pi / 2)

    assertNear(weight.rootNode.x, 103, 0.001)
    assertNear(weight.rootNode.z, 50, 0.001)
    assertNear(weight.rootNode.ry, math.pi / 2, 0.001)
    assertEquals(weight.attacher, tractor, "still hitched")
    assertEquals(weight.isVisible, true, "shown with it")
    assertEquals(weight.inPhysics, true, "in physics")
end)
