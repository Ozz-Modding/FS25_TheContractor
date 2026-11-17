-- TCVehicleLock: equipment away on a hired-worker job (travelling, working
-- or on hold), in a cooldown, waiting to be parked or stolen can't be sold.
-- The server refuses the SellVehicleEvent with vanilla's "in use" reply;
-- anything else sells as normal. It also drops out of the Tab cycle without
-- vanilla's saved isTabbable flag changing, and nobody can get in or stay
-- in.

local STATE = { ALLOCATED = "allocated", IN_PROGRESS = "in_progress", COMPLETED = "completed" }

local function setup()
    local world = stubs.install()

    -- Vanilla's server half, reduced to what the hook decides between.
    world.sold, world.replies = {}, {}
    SellVehicleEvent = { SELL_VEHICLE_IN_USE = 1 }
    function SellVehicleEvent.run(event, connection)
        table.insert(world.sold, event.vehicle.id)
    end
    function SellVehicleEvent.newServerToClient(errorCode, sellPrice, isDirectSell, isOwned, ownerFarmId)
        return { errorCode = errorCode, sellPrice = sellPrice, isOwned = isOwned, ownerFarmId = ownerFarmId }
    end
    VehiclePropertyState = { OWNED = 1 }
    TheContractorJob = { STATE = STATE }

    -- Vanilla's enter requests, reduced to recording what got through.
    world.entered, world.warnings = {}, {}
    Player = {}
    function Player:requestToEnterVehicle(vehicle)
        table.insert(world.entered, vehicle.id)
    end
    function Player:requestToEnterVehicleAsPassenger(vehicle, seatIndex)
        table.insert(world.entered, vehicle.id)
    end
    function g_currentMission:showBlinkingWarning(text)
        table.insert(world.warnings, text)
    end
    g_localPlayer = nil

    world.jobs, world.cooldown, world.parking, world.stolen = {}, {}, {}, {}
    local tc = g_currentMission.TheContractor
    tc.Jobs = {
        getAllJobs = function(_, farmId)
            local result = {}
            for _, job in ipairs(world.jobs) do
                if job.farmId == farmId then
                    table.insert(result, job)
                end
            end
            return result
        end,
    }
    tc.Cooldown = { vehicleIdsInCooldown = world.cooldown }
    tc.Parking = { entryByVehicleId = world.parking }
    tc.Theft = {
        getStolenVehicleIds = function()
            return world.stolen
        end,
    }

    world:load("src/util/TCVehicleLock.lua")
    TCVehicleLock.reset()
    return world
end

local function addSellable(world, name)
    local vehicle = world:addVehicle({ name = name })
    vehicle.propertyState = VehiclePropertyState.OWNED
    return vehicle
end

local function addJob(world, state, workerId, vehicles)
    local ids = {}
    for _, vehicle in ipairs(vehicles) do
        table.insert(ids, vehicle.id)
    end
    local job = { farmId = 1, state = state, assignedWorkerId = workerId }
    function job:getAllEquipmentIds() return ids end
    table.insert(world.jobs, job)
    return job
end

-- A client's request: the server runs it with that client's connection.
local function sell(world, vehicle)
    local connection = {}
    function connection:getIsServer() return false end
    function connection:sendEvent(event) table.insert(world.replies, event) end
    SellVehicleEvent.run({ vehicle = vehicle, isDirectSell = false }, connection)
end

local function assertRefused(world, vehicle, label)
    sell(world, vehicle)
    assertEquals(#world.sold, 0, label .. ": not sold")
    assertEquals(#world.replies, 1, label .. ": one reply")
    assertEquals(world.replies[1].errorCode, SellVehicleEvent.SELL_VEHICLE_IN_USE, label .. ": in use")
    assertEquals(world.replies[1].sellPrice, 0, label .. ": nothing paid")
end

test("a travelling job's equipment can't be sold", function()
    local world = setup()
    local tractor = addSellable(world, "Tractor")
    addJob(world, STATE.ALLOCATED, 7, { tractor })

    assertRefused(world, tractor, "allocated")
end)

test("an in-progress job's equipment can't be sold, AI running or not", function()
    local world = setup()
    local plough = addSellable(world, "Plough")
    addJob(world, STATE.IN_PROGRESS, 7, { plough })

    assertRefused(world, plough, "in progress")
end)

-- Worked out live: no refresh has run since the job was allocated.
test("a job allocated since the last refresh already counts", function()
    local world = setup()
    local tractor = addSellable(world, "Tractor")
    TCVehicleLock.refresh()
    addJob(world, STATE.ALLOCATED, 7, { tractor })

    assertRefused(world, tractor, "fresh allocation")
end)

test("cooldown, the parking queue and stolen vehicles can't be sold", function()
    local world = setup()
    local inCooldown = addSellable(world, "Cooldown")
    local queued = addSellable(world, "Queued")
    local stolen = addSellable(world, "Stolen")
    world.cooldown[inCooldown.id] = true
    world.parking[queued.id] = {}
    world.stolen[stolen.id] = true

    assertRefused(world, inCooldown, "cooldown")
    world.replies = {}
    assertRefused(world, queued, "parking queue")
    world.replies = {}
    assertRefused(world, stolen, "stolen")
end)

test("something hitched to a job's machine can't be sold either", function()
    local world = setup()
    local tractor = addSellable(world, "Tractor")
    local trailer = addSellable(world, "Trailer")
    function trailer:getAttacherVehicle() return tractor end
    addJob(world, STATE.IN_PROGRESS, 7, { tractor })

    assertRefused(world, trailer, "hitched")
end)

test("idle equipment, a player's own job and a finished job's sell as normal", function()
    local world = setup()
    local idle = addSellable(world, "Idle")
    local playerJob = addSellable(world, "Player job")
    local finished = addSellable(world, "Finished")
    addJob(world, STATE.IN_PROGRESS, nil, { playerJob })
    addJob(world, STATE.COMPLETED, 7, { finished })

    sell(world, idle)
    sell(world, playerJob)
    sell(world, finished)

    assertEquals(#world.sold, 3, "all sold")
    assertEquals(#world.replies, 0, "vanilla replies itself")
end)

-- Tab cycle ------------------------------------------------------------------

-- A Drivable, Enterable vehicle with vanilla's flag and the xml's default.
local function addEnterable(world, name, def)
    def = def or {}
    local vehicle = world:addVehicle({ name = name, farmId = def.farmId })
    vehicle.spec_drivable = {}
    vehicle.spec_enterable = { isTabbable = def.isTabbable ~= false }
    function vehicle:registerPlayerVehicleControlAllowedFunction() end
    function vehicle:getIsTabbable() return self.spec_enterable.isTabbable end
    function vehicle:setIsTabbable(isTabbable) self.spec_enterable.isTabbable = isTabbable end
    local xmlTabbable = def.xmlTabbable ~= false
    vehicle.xmlFile = { getValue = function(_, key, default) return xmlTabbable end }
    return vehicle
end

test("a hired worker's tractor drops out of Tab without touching the saved flag", function()
    local world = setup()
    local tractor = addEnterable(world, "Tractor")
    local job = addJob(world, STATE.ALLOCATED, 7, { tractor })
    TCVehicleLock.refresh()

    assertEquals(tractor:getIsTabbable(), false, "locked: not tabbable")
    assertEquals(tractor.spec_enterable.isTabbable, true, "vanilla's saved flag untouched")

    job.state = STATE.COMPLETED
    TCVehicleLock.refresh()
    assertEquals(tractor:getIsTabbable(), true, "tabbable again")
end)

test("135: an auction lot is out of Tab and can't be driven, for being a lot", function()
    local world = setup()
    local lot = addEnterable(world, "Lot", { farmId = 0 })
    local control = nil
    function lot:registerPlayerVehicleControlAllowedFunction(_, func) control = func end
    local busy = addEnterable(world, "Busy")
    function busy:registerPlayerVehicleControlAllowedFunction(_, func) busy.control = func end
    addJob(world, STATE.ALLOCATED, 7, { busy })
    local lots = { [lot.id] = true }
    g_currentMission.TheContractor.AuctionSite = { getLotVehicleIds = function() return lots end }
    TCVehicleLock.refresh()

    assertEquals(lot:getIsTabbable(), false, "out of Tab")
    assertEquals(lot.spec_enterable.isTabbable, true, "vanilla's saved flag untouched")
    local allowed, text = control(lot)
    assertEquals(allowed, false)
    assertEquals(text, g_i18n:getText(TCVehicleLock.REASON_AUCTION_LOT), "the lot's own reason")
    local _, busyText = busy.control(busy)
    assertEquals(busyText, g_i18n:getText(TCVehicleLock.REASON_BUSY), "a job's machine keeps its own")

    -- Cleared away: unlocked.
    lots[lot.id] = nil
    TCVehicleLock.refresh()
    assertEquals(lot:getIsTabbable(), true)
    assertEquals(control(lot), true)
end)

test("a player's own job's tractor stays tabbable", function()
    local world = setup()
    local tractor = addEnterable(world, "Tractor")
    addJob(world, STATE.IN_PROGRESS, nil, { tractor })
    TCVehicleLock.refresh()

    assertEquals(tractor:getIsTabbable(), true, "tabbable")
end)

test("a vehicle that's never tabbable stays that way after a lock", function()
    local world = setup()
    local odd = addEnterable(world, "Odd", { isTabbable = false, xmlTabbable = false })
    local job = addJob(world, STATE.ALLOCATED, 7, { odd })
    TCVehicleLock.refresh()
    job.state = STATE.COMPLETED
    TCVehicleLock.refresh()

    assertEquals(odd:getIsTabbable(), false, "still not tabbable")
end)

test("a save from the old lock gets its farm's machines back in Tab", function()
    local world = setup()
    FarmManager = FarmManager or {}
    FarmManager.SPECTATOR_FARM_ID = 15
    local baked = addEnterable(world, "Baked", { isTabbable = false })
    local alwaysOff = addEnterable(world, "Always off", { isTabbable = false, xmlTabbable = false })
    local yard = addEnterable(world, "Yard", { isTabbable = false, farmId = 15 })

    TCVehicleLock.repairSavedTabbable()

    assertEquals(baked.spec_enterable.isTabbable, true, "farm's machine repaired")
    assertEquals(alwaysOff.spec_enterable.isTabbable, false, "xml says never")
    assertEquals(yard.spec_enterable.isTabbable, false, "not the farm's: left alone")
end)

-- The client's half (the server's reply arriving) is vanilla's business.
test("the reply arriving on the client goes straight to vanilla", function()
    local world = setup()
    local tractor = addSellable(world, "Tractor")
    addJob(world, STATE.ALLOCATED, 7, { tractor })

    local connection = {}
    function connection:getIsServer() return true end
    SellVehicleEvent.run({ vehicle = tractor }, connection)

    assertEquals(#world.sold, 1, "passed through")
end)

-- Getting in -------------------------------------------------------------------

-- The local player, sitting in whatever they're put in.
local function addPlayer(world)
    local player = setmetatable({ left = 0 }, { __index = Player })
    function player:getCurrentVehicle() return self.vehicle end
    function player:leaveVehicle()
        self.left = self.left + 1
        self.vehicle = nil
    end
    g_localPlayer = player
    return player
end

test("a hired worker's machine can't be got into, driver's seat or passenger's", function()
    local world = setup()
    local tractor = addEnterable(world, "Tractor")
    addJob(world, STATE.IN_PROGRESS, 7, { tractor })
    TCVehicleLock.refresh()
    local player = addPlayer(world)

    player:requestToEnterVehicle(tractor)
    player:requestToEnterVehicleAsPassenger(tractor, 1)

    assertEquals(#world.entered, 0, "refused")
    assertEquals(#world.warnings, 2, "told why each time")
end)

test("a free machine and a player's own job's get in as normal", function()
    local world = setup()
    local free = addEnterable(world, "Free")
    local own = addEnterable(world, "Own")
    addJob(world, STATE.IN_PROGRESS, nil, { own })
    TCVehicleLock.refresh()
    local player = addPlayer(world)

    player:requestToEnterVehicle(free)
    player:requestToEnterVehicle(own)

    assertEquals(#world.entered, 2, "both entered")
    assertEquals(#world.warnings, 0)
end)

-- The reload case: put back in the machine before the lock knew of it.
test("a player found in a locked machine is put out on the next refresh", function()
    local world = setup()
    local tractor = addEnterable(world, "Tractor")
    local player = addPlayer(world)
    player.vehicle = tractor
    addJob(world, STATE.IN_PROGRESS, 7, { tractor })

    TCVehicleLock.refresh()
    assertEquals(player.left, 1, "put out")
    assertEquals(player.vehicle, nil)

    TCVehicleLock.refresh()
    assertEquals(player.left, 1, "once")
end)

test("a player in a free machine or their own job's stays in it", function()
    local world = setup()
    local own = addEnterable(world, "Own")
    addJob(world, STATE.IN_PROGRESS, nil, { own })
    local player = addPlayer(world)
    player.vehicle = own

    TCVehicleLock.refresh()

    assertEquals(player.left, 0, "left alone")
end)
