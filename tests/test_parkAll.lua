-- Park all (159): the Logbook's button parks every free machine of the farm
-- that isn't already in a slot, one a pass, biggest first. Busy machines,
-- and any combination with a busy machine in it, are left alone, and a
-- machine with no room stays where it is (never hidden).

local function setup()
    local world = stubs.install()

    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    TheContractorInbox = { DISMISS_ACTION = { key = "dismiss" } }
    VehiclePropertyState = { OWNED = 1, LEASED = 2, MISSION = 3 }

    -- The spot finder hands out world.freeSpots places, then nothing.
    world.freeSpots = 0
    world.placed = {}
    world.unhitched = {}
    world.hiddenAny = false
    TCParking = {
        findSpot = function()
            if world.freeSpots > 0 then
                world.freeSpots = world.freeSpots - 1
                return 0, 0, 0, 0
            end
            return nil
        end,
        isParked = function(vehicle)
            return vehicle.inSlot == true
        end,
        placeVehicle = function(vehicle)
            table.insert(world.placed, vehicle.id)
            vehicle.inSlot = true
        end,
    }
    TCJobSiteSetup = {
        unhitchVehicles = function(ids)
            for _, id in ipairs(ids) do
                table.insert(world.unhitched, id)
            end
        end,
    }
    TCEquipmentVisibility = {
        setVisibleEverywhere = function(_, isVisible)
            if not isVisible then
                world.hiddenAny = true
            end
        end,
        isHidden = function() return false end,
    }
    TCVehicleLock = {
        refresh = function() end,
        isLocked = function(vehicle) return vehicle.locked == true end,
    }
    TheContractorDrivers = {
        isVehicleDriven = function(vehicle) return vehicle:getIsAIActive() end,
    }
    TheContractorRepairContracts = { isContractVehicle = function() return false end }

    local tc = g_currentMission.TheContractor
    tc.Cooldown = { isVehicleInCooldown = function() return false end }
    tc.Notices = { publish = function() return 1 end, remove = function() end }
    tc.Drivers = { hasDriver = function(_, vehicle) return vehicle.hasStaffDriver == true end }
    tc.Theft = { isStolen = function() return false end }

    dofile("src/events/TCParkingNoticeEvent.lua")
    dofile("src/util/TCFolding.lua")
    dofile("src/business/Parking.lua")

    local parking = TheContractorParking.new()
    -- What the farm was told: { farmId, key, arg, isGood }.
    world.told = {}
    parking.notify = function(self, farmId, textKey, arg, isGood)
        table.insert(world.told, { farmId = farmId, key = textKey, arg = arg, isGood = isGood })
    end
    parking:register({
        registerMessageKind = function() end,
        postMessage = function() return 1 end,
        removeMessage = function() end,
    })
    tc.Parking = parking
    return world, parking
end

-- def: { name, farmId, width, length, isPallet, isAIActive, propertyState,
-- inSlot, locked }
local function addMachine(world, def)
    local vehicle = world:addVehicle(def)
    vehicle.size = { width = def.width or 3, length = def.length or 5 }
    vehicle.spec_wearable = {}
    vehicle.propertyState = def.propertyState or VehiclePropertyState.OWNED
    vehicle.inSlot = def.inSlot
    vehicle.locked = def.locked
    function vehicle:getFullName() return self.name end
    return vehicle
end

-- Hitches implement to tractor for the chain checks.
local function hitch(tractor, implement)
    local chain = { tractor, implement }
    function tractor:getRootVehicle() return tractor end
    function implement:getRootVehicle() return tractor end
    function tractor:getChildVehicles() return chain end
end

local function runAll(parking)
    for _ = 1, 50 do
        parking.parkAllAccumulatedMs = TheContractorParking.PARK_ALL_INTERVAL_MS
        parking:update(0)
    end
end

local function toldKeys(world)
    local keys = {}
    for _, told in ipairs(world.told) do
        table.insert(keys, told.key)
    end
    return table.concat(keys, ",")
end

test("parks the farm's free machines, biggest first, and says how many", function()
    local world, parking = setup()
    world.freeSpots = 10
    local small = addMachine(world, { name = "Roller", width = 3, length = 3 })
    local big = addMachine(world, { name = "Combine", width = 4, length = 10 })
    local middle = addMachine(world, { name = "Tractor", width = 3, length = 5 })

    assertEquals(parking:parkAll(1), 3)
    runAll(parking)

    assertEquals(table.concat(world.placed, ","), table.concat({ big.id, middle.id, small.id }, ","))
    assertEquals(toldKeys(world), "tc_parking_parkAllParked")
    assertEquals(world.told[1].arg, "3")
    assertTrue(world.told[1].isGood, "good news")
end)

test("leaves alone what's parked, busy, someone else's or not a machine", function()
    local world, parking = setup()
    world.freeSpots = 10
    local free = addMachine(world, { name = "Tractor" })
    addMachine(world, { name = "Parked", inSlot = true })
    addMachine(world, { name = "On a job", locked = true })
    addMachine(world, { name = "Helper", isAIActive = true })
    addMachine(world, { name = "Pallet", isPallet = true })
    addMachine(world, { name = "Courtesy", propertyState = VehiclePropertyState.MISSION })
    addMachine(world, { name = "Neighbour's", farmId = 2 })
    addMachine(world, { name = "Staff driven" }).hasStaffDriver = true

    assertEquals(parking:parkAll(1), 1)
    runAll(parking)

    assertEquals(table.concat(world.placed, ","), tostring(free.id))
end)

test("an implement on a busy tractor stays hitched where it is", function()
    local world, parking = setup()
    world.freeSpots = 10
    local tractor = addMachine(world, { name = "Tractor", isAIActive = true })
    local plough = addMachine(world, { name = "Plough" })
    hitch(tractor, plough)

    assertEquals(parking:parkAll(1), 0)
    assertEquals(#world.unhitched, 0)
    assertEquals(toldKeys(world), "tc_parking_parkAllNothing")
end)

test("a free combination is split up and each piece parked", function()
    local world, parking = setup()
    world.freeSpots = 10
    local tractor = addMachine(world, { name = "Tractor", length = 5 })
    local plough = addMachine(world, { name = "Plough", length = 3 })
    hitch(tractor, plough)

    parking:parkAll(1)
    runAll(parking)

    assertEquals(table.concat(world.unhitched, ","), table.concat({ tractor.id, plough.id }, ","))
    assertEquals(#world.placed, 2)
end)

test("a machine with no room is left where it is and named", function()
    local world, parking = setup()
    world.freeSpots = 1
    addMachine(world, { name = "Combine", width = 4, length = 10 })
    local trailer = addMachine(world, { name = "Trailer" })

    parking:parkAll(1)
    runAll(parking)

    assertEquals(#world.placed, 1)
    assertTrue(not world.hiddenAny, "nothing hidden")
    assertEquals(#world.unhitched, 1, "only what's placed is unhitched")
    assertTrue(not trailer.inSlot, "trailer stays put")
    assertEquals(toldKeys(world), "tc_parking_parkAllParked,tc_parking_parkAllNoRoom")
    assertEquals(world.told[2].arg, "Trailer")
end)

test("one run at a time, and a machine taken into use mid-run is skipped", function()
    local world, parking = setup()
    world.freeSpots = 10
    addMachine(world, { name = "Combine", width = 4, length = 10 })
    local tractor = addMachine(world, { name = "Tractor" })

    assertEquals(parking:parkAll(1), 2)
    assertEquals(parking:parkAll(1), 0, "second request while running")

    parking.parkAllAccumulatedMs = TheContractorParking.PARK_ALL_INTERVAL_MS
    parking:update(0)
    tractor.isAIActive = true
    runAll(parking)

    assertEquals(#world.placed, 1)
    assertTrue(not tractor.inSlot, "tractor left with its helper")
    assertEquals(toldKeys(world), "tc_parking_parkAllParked")
    tractor.isAIActive = false
    assertEquals(parking:parkAll(1), 1, "a new run once done")
end)

test("a deleted farm's run is dropped", function()
    local world, parking = setup()
    world.freeSpots = 10
    addMachine(world, { name = "Tractor" })

    parking:parkAll(1)
    parking:forgetFarm(1)
    runAll(parking)

    assertEquals(#world.placed, 0)
    assertEquals(#world.told, 0)
end)

test("a machine that folds is folded once it's put down", function()
    local world, parking = setup()
    world.freeSpots = 1
    local cultivator = addMachine(world, { name = "Cultivator" })
    cultivator.spec_foldable = {
        hasFoldingParts = true, turnOnFoldDirection = -1, foldAnimTime = 0, foldMoveDirection = 0,
        detachingMinLimit = 0, detachingMaxLimit = 1, attachingMinLimit = 0, attachingMaxLimit = 1,
    }
    function cultivator:setFoldState(direction)
        self.foldDirection = direction
        self.foldedAfterPlacing = #world.placed == 1
    end

    parking:parkAll(1)
    runAll(parking)

    assertEquals(cultivator.foldDirection, 1)
    assertTrue(cultivator.foldedAfterPlacing, "folded where it was put")
end)
