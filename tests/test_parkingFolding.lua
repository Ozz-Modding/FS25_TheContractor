-- Folding for parking: a returned machine that folds is folded where it may
-- stand folded unhitched (vanilla's detaching, attaching and hitch-point
-- fold ranges), unfolded where only that's allowed, and left be where
-- neither is. The return queue waits for the fold before placing it.

local function setup()
    local world = stubs.install()

    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    TheContractorInbox = { DISMISS_ACTION = { key = "dismiss" } }

    world.freeSpots = 0
    world.placed = {}
    TCParking = {
        findSpot = function()
            if world.freeSpots > 0 then
                world.freeSpots = world.freeSpots - 1
                return 0, 0, 0, 0
            end
            return nil
        end,
        findShopSpot = function() return 0, 0, 0, 0 end,
        placeVehicle = function(vehicle) table.insert(world.placed, vehicle.id) end,
    }
    TCJobSiteSetup = { unhitchVehicles = function() end }
    TCEquipmentVisibility = { setVisibleEverywhere = function() end, isHidden = function() return true end }
    TCVehicleLock = { refresh = function() end }

    local tc = g_currentMission.TheContractor
    tc.Cooldown = { isVehicleInCooldown = function() return false end }
    tc.Notices = { publish = function() return 1 end, remove = function() end }

    dofile("src/events/TCParkingNoticeEvent.lua")
    dofile("src/util/TCFolding.lua")
    dofile("src/business/Parking.lua")

    local parking = TheContractorParking.new()
    world.told = {}
    parking.notify = function(self, farmId, textKey)
        table.insert(world.told, textKey)
    end
    parking:register({
        registerMessageKind = function() end,
        postMessage = function() return 1 end,
        removeMessage = function() end,
    })
    tc.Parking = parking
    return world, parking
end

-- def: { animTime, turnOnFoldDirection (default -1: folded at 1),
-- detaching = { min, max }, attaching = { min, max }, joints = { { min, max } },
-- useParentFoldingState }
local function addFoldable(world, def)
    local vehicle = world:addVehicle({ name = "Cultivator" })
    function vehicle:getFullName() return self.name end
    local detaching = def.detaching or { 0, 1 }
    local attaching = def.attaching or { 0, 1 }
    vehicle.spec_foldable = {
        hasFoldingParts = true,
        isFoldAllowed = true,
        useParentFoldingState = def.useParentFoldingState or false,
        turnOnFoldDirection = def.turnOnFoldDirection or -1,
        foldAnimTime = def.animTime or 0,
        foldMoveDirection = 0,
        moveToMiddle = false,
        detachingMinLimit = detaching[1],
        detachingMaxLimit = detaching[2],
        attachingMinLimit = attaching[1],
        attachingMaxLimit = attaching[2],
    }
    if def.joints ~= nil then
        local joints = {}
        for _, limits in ipairs(def.joints) do
            table.insert(joints, { foldMinLimit = limits[1], foldMaxLimit = limits[2] })
        end
        function vehicle:getInputAttacherJoints() return joints end
    end
    vehicle.foldStates = {}
    function vehicle:setFoldState(direction, moveToMiddle)
        table.insert(self.foldStates, direction)
        self.spec_foldable.foldMoveDirection = direction
        self.spec_foldable.moveToMiddle = moveToMiddle
    end
    return vehicle
end

-- The fold animation reaches its end, as Foldable:onUpdate leaves it.
local function finishFold(vehicle)
    local spec = vehicle.spec_foldable
    spec.foldAnimTime = spec.foldMoveDirection > 0 and 1 or 0
    spec.foldMoveDirection = 0
end

local function pass(parking)
    parking.accumulatedMs = parking.intervalMs
    parking:update(0)
end

test("a machine that may stand folded is parked folded", function()
    local world = setup()
    -- Folded at 1 (turnOnFoldDirection -1), unfolded at 0.
    local vehicle = addFoldable(world, { animTime = 0 })
    assertEquals(TCFolding.getParkingTime(vehicle), 1)
    assertTrue(TCFolding.foldForParking(vehicle), "on its way")
    assertEquals(vehicle.foldStates[1], 1)
end)

test("the folded end follows turnOnFoldDirection", function()
    local world = setup()
    local vehicle = addFoldable(world, { animTime = 1, turnOnFoldDirection = 1 })
    assertEquals(TCFolding.getParkingTime(vehicle), 0)
end)

test("a machine that must be unfolded to detach is parked unfolded", function()
    local world = setup()
    local vehicle = addFoldable(world, { animTime = 1, detaching = { 0, 0.2 } })
    assertEquals(TCFolding.getParkingTime(vehicle), 0)
    assertTrue(TCFolding.foldForParking(vehicle), "unfolding")
    assertEquals(vehicle.foldStates[1], -1)
end)

test("a machine that can't be hitched again folded is parked unfolded", function()
    local world = setup()
    assertEquals(TCFolding.getParkingTime(addFoldable(world, { attaching = { 0, 0.5 } })), 0)
    -- No hitch point works folded.
    assertEquals(TCFolding.getParkingTime(addFoldable(world, { joints = { { 0, 0.3 }, { 0, 0.5 } } })), 0)
end)

test("one hitch point working folded is enough", function()
    local world = setup()
    assertEquals(TCFolding.getParkingTime(addFoldable(world, { joints = { { 0, 0.3 }, { 0.9, 1 } } })), 1)
end)

test("a machine that may stand neither way, or follows its parent, is left as it is", function()
    local world = setup()
    local stuck = addFoldable(world, { animTime = 0.5, detaching = { 0.4, 0.6 } })
    assertEquals(TCFolding.getParkingTime(stuck), nil)
    assertTrue(not TCFolding.foldForParking(stuck), "nothing to wait for")
    assertEquals(#stuck.foldStates, 0)

    local child = addFoldable(world, { useParentFoldingState = true })
    assertEquals(TCFolding.getParkingTime(child), nil)
end)

test("a machine already folded isn't touched", function()
    local world = setup()
    local vehicle = addFoldable(world, { animTime = 1 })
    assertTrue(not TCFolding.foldForParking(vehicle), "already there")
    assertEquals(#vehicle.foldStates, 0)
end)

test("the queue waits for the fold before parking, without calling it stuck", function()
    local world, parking = setup()
    world.freeSpots = 1
    local vehicle = addFoldable(world, { animTime = 0 })
    parking:returnVehicles(1, { vehicle.id })
    assertEquals(vehicle.foldStates[1], 1)

    pass(parking)
    assertEquals(#world.placed, 0)
    assertEquals(#world.told, 0)
    assertEquals(parking.intervalMs, TheContractorParking.FAST_INTERVAL_MS)

    finishFold(vehicle)
    pass(parking)
    assertEquals(world.placed[1], vehicle.id)
    assertEquals(#vehicle.foldStates, 1)
end)

test("a fold that never finishes is placed after the wait runs out", function()
    local world, parking = setup()
    world.freeSpots = 1
    local vehicle = addFoldable(world, { animTime = 0 })
    parking:returnVehicles(1, { vehicle.id })

    for _ = 1, TheContractorParking.FOLD_MAX_WAIT_PASSES do
        pass(parking)
    end
    assertEquals(#world.placed, 0)
    pass(parking)
    assertEquals(world.placed[1], vehicle.id)
end)

test("a machine loaded mid-fold is folded again before it's parked", function()
    local world, parking = setup()
    world.freeSpots = 1
    -- Joined the queue already folded, then a load left it half way.
    local vehicle = addFoldable(world, { animTime = 1 })
    parking:returnVehicles(1, { vehicle.id })
    vehicle.spec_foldable.foldAnimTime = 0.6

    pass(parking)
    assertEquals(#world.placed, 0)
    assertEquals(vehicle.foldStates[1], 1)
    finishFold(vehicle)
    pass(parking)
    assertEquals(world.placed[1], vehicle.id)
end)
