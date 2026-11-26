-- Tanks that work through a tool (TCEquipmentClass.needsTool): a slurry
-- tanker spreads only through the dribble bar on its hitch. A selection
-- with the tank and no tool is missing one, and the rigging puts the bar
-- back on its tank, never on the tractor's free linkage.

local function setup()
    local world = stubs.install()
    AttacherJoints = {
        getAttacherJointCompatibility = function() return true end,
    }
    TCDispatchFailedEvent = {}
    world:load("src/util/TCEquipmentClass.lua")
    world:load("src/util/TCBallast.lua")
    world:load("src/util/TCEquipmentVisibility.lua")
    TheContractorDrivers = { getModEnv = function() return nil end }
    world:load("src/util/TCManualAttach.lua")
    world:load("src/util/TCAttachImplementsManually.lua")
    world:load("src/util/TCJobSiteSetup.lua")
    g_storeManager = { getItemByXMLFilename = function() return { categoryName = "" } end }
    return world
end

local function addMachine(world, name, inputJointType)
    local vehicle = world:addVehicle({ name = name })
    vehicle.rootNode = { x = 0, y = 0, z = 0, ry = 0 }
    vehicle.attached = {}
    vehicle.joints = {}
    function vehicle:getAttachedImplements() return self.attached end
    function vehicle:getAttacherVehicle() return self.attacher end
    function vehicle:getAttacherJoints() return self.joints end
    function vehicle:getInputAttacherJoints() return { { jointType = inputJointType } } end
    function vehicle:getIsAttachedTo(other) return self.attacher == other end
    function vehicle:getImplementByJointDescIndex(index)
        for _, implement in ipairs(self.attached) do
            if implement.jointDescIndex == index then
                return implement
            end
        end
        return nil
    end
    return vehicle
end

local function hitch(attacher, object, jointIndex)
    table.insert(attacher.attached, { object = object, jointDescIndex = jointIndex })
    object.attacher = attacher
end

-- Drawbar for trailed kit, rear three-point the bar would also fit.
local DRAWBAR, REAR = 1, 2
local function addTractor(world)
    local tractor = addMachine(world, "Tractor", "none")
    tractor.spec_motorized = {}
    tractor.spec_attacherJoints = {}
    tractor.isTractor = true
    tractor.joints = {
        [DRAWBAR] = { jointType = "trailer", attacherJointDirection = -1 },
        [REAR] = { jointType = "implement", attacherJointDirection = -1 },
    }
    return tractor
end

-- markers: the tank's own AI markers (a splash plate of its own).
-- flagged: it takes its tool's AI attributes (else it just has no work
-- areas of its own).
local function addTank(world, markers, flagged)
    local tank = addMachine(world, "Slurry tank", "trailer")
    tank.spec_sprayer = {}
    tank.spec_attacherJoints = {}
    tank.spec_aiImplement = { useAttributesOfAttachedImplement = flagged ~= false }
    if markers then
        tank.spec_aiImplement.leftMarker, tank.spec_aiImplement.rightMarker, tank.spec_aiImplement.backMarker = 1, 2, 3
    end
    tank.joints = { { jointType = "implement", attacherJointDirection = -1 } }
    return tank
end

local function addBar(world)
    local bar = addMachine(world, "Dribble bar", "implement")
    bar.spec_sprayer = {}
    bar.spec_aiImplement = { leftMarker = 1, rightMarker = 2, backMarker = 3 }
    return bar
end

local function jobWith(...)
    local ids = {}
    for _, vehicle in ipairs({ ... }) do
        table.insert(ids, vehicle.id)
    end
    return { id = 1, farmId = 1, assignedEquipmentIds = ids }
end

local sprayJob = { implementSpec = "spec_sprayer" }

local function stubTractors()
    TCEquipmentClass.isTractor = function(vehicle) return vehicle.isTractor == true end
end

test("a tank with no markers of its own that takes its tool's needs a tool", function()
    local world = setup()
    assertTrue(TCEquipmentClass.needsTool(addTank(world)), "slurry tank")
    assertTrue(not TCEquipmentClass.needsTool(addTank(world, true)), "tank with its own splash plate")
    assertTrue(not TCEquipmentClass.needsTool(addBar(world)), "the bar")
    assertTrue(not TCEquipmentClass.needsTool({}), "no AI at all")
end)

test("unflagged, a tank needs a tool only while it has no work areas of its own", function()
    local world = setup()
    local tank = addTank(world, false, false)
    assertTrue(TCEquipmentClass.needsTool(tank), "no work areas")
    tank.spec_workArea = { workAreas = { { type = 1 } } }
    assertTrue(not TCEquipmentClass.needsTool(tank), "a sprayer of its own with a hitch")
    tank.spec_workArea = nil
    tank.spec_attacherJoints = nil
    assertTrue(not TCEquipmentClass.needsTool(tank), "nothing can hitch to it")
end)

test("a slurry tank on its own is missing its tool; with the bar it's complete", function()
    local world = setup()
    stubTractors()
    local tractor, tank, bar = addTractor(world), addTank(world), addBar(world)

    local missing = TCEquipmentClass.getMissingEquipment({ tractor, tank }, sprayJob)
    assertEquals(#missing, 1)
    assertEquals(missing[1], "tool")
    assertEquals(#TCEquipmentClass.getMissingEquipment({ tractor, tank, bar }, sprayJob), 0, "with the bar")
    assertEquals(#TCEquipmentClass.getMissingEquipment({ tractor, addTank(world, true) }, sprayJob), 0,
        "a tank that spreads by itself")
    missing = TCEquipmentClass.getMissingEquipment({ tractor }, sprayJob)
    assertEquals(missing[1], "implement", "no tank: the implement, not the tool")
end)

test("the bar left on its tank goes back on the tank, not the tractor's free linkage", function()
    local world = setup()
    local tractor, tank, bar = addTractor(world), addTank(world), addBar(world)
    hitch(tank, bar, 1)

    -- Listed before the tank, so it would be planned first.
    local plans = TCJobSiteSetup.planHitches(jobWith(tractor, bar, tank))

    assertEquals(#plans, 2)
    assertEquals(plans[1].implement, tank)
    assertEquals(plans[1].attacher, tractor)
    assertEquals(plans[1].jointIndex, DRAWBAR)
    assertEquals(plans[2].implement, bar)
    assertEquals(plans[2].attacher, tank)
    assertEquals(plans[2].occupant, nil, "its own joint isn't someone else's to unhitch")
end)

test("a bar parked apart from its tank still goes on the tank", function()
    local world = setup()
    local tractor, tank, bar = addTractor(world), addTank(world), addBar(world)

    local plans = TCJobSiteSetup.planHitches(jobWith(tractor, bar, tank))

    assertEquals(#plans, 2)
    assertEquals(plans[2].implement, bar)
    assertEquals(plans[2].attacher, tank)
end)

test("rigged already (resumed after a load), the bar is planned back onto its tank", function()
    local world = setup()
    local tractor, tank, bar = addTractor(world), addTank(world), addBar(world)
    hitch(tractor, tank, DRAWBAR)
    hitch(tank, bar, 1)

    local plans = TCJobSiteSetup.planHitches(jobWith(tractor, tank, bar))

    assertEquals(#plans, 1, "the tank's left where it is")
    assertEquals(plans[1].implement, bar)
    assertEquals(plans[1].attacher, tank)
end)

test("at dispatch the bar on a job's tank isn't left in the yard", function()
    local world = setup()
    local tractor, tank, bar = addTractor(world), addTank(world), addBar(world)
    hitch(tank, bar, 1)
    assertEquals(#TCJobSiteSetup.detachForeignImplements(jobWith(tractor, tank, bar)), 0)
end)
