-- 135: the auction site's engine half (TheContractorAuctionSite): a lot's
-- condition on its vehicle, its guide price from vanilla's sell price, ADS's
-- history for it (TCADSUsedLots), and the site kept through a save, sent to
-- clients and cleared away.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorRepairContracts = { CLEARANCE = 1 }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    VehicleLoadingState = { OK = 1, ERROR = 2 }
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    world.time = 100
    getTimeSec = function() return world.time end
    world:load("src/util/TCVehicleIds.lua")
    world:load("src/util/TCAuctionCrowd.lua")
    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/business/FarmerFleet.lua")
    world:load("src/util/TCADSUsedLots.lua")
    FieldGroundType = {}
    world:load("src/util/TCFieldPreparation.lua")
    world:load("src/business/AuctionSite.lua")
    world:load("src/events/TCAuctionSiteEvent.lua")
    world:load("src/util/TCAuctionLotActivatable.lua")

    -- ADS, when a test gives it one.
    world.adsEnv = nil
    TheContractorDrivers = { getModEnv = function() return world.adsEnv end }
    TCADSUsedLots.detect()

    -- Vanilla's prices, reduced to recording what they were asked.
    world.sellPriceCalls = {}
    Wearable = {
        calculateRepairPrice = function(price, damage) return price * damage * 0.1 end,
        calculateRepaintPrice = function(price, wear) return price * wear * 0.01 end,
    }
    Vehicle = {
        calculateSellPrice = function(storeItem, age, operatingTime, price, repairPrice, repaintPrice)
            table.insert(world.sellPriceCalls, { age = age, operatingTime = operatingTime, price = price,
                repairPrice = repairPrice, repaintPrice = repaintPrice })
            return price / 2 - repairPrice - repaintPrice
        end,
    }
    world.storeItems = {}
    g_storeManager = {
        getItemByXMLFilename = function(_, xml) return world.storeItems[xml] end,
    }

    local site = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = site
    world.site = site
    return world
end

-- A lot's vehicle with what a lot's condition touches, and a diesel tank.
local function addLotVehicle(world, def)
    def = def or {}
    local vehicle = world:addVehicle({ name = def.name or "Lot", farmId = 0, dieselUsagePerHour = 10,
        dieselCapacity = 400, dieselLevel = 400 })
    vehicle.configFileName = def.xml or "tractor.xml"
    vehicle.price = def.price or 100000
    vehicle.wear, vehicle.damage, vehicle.dirt = 0, 0, 0
    vehicle.spec_wearable = { dirtyFlag = 4 }
    vehicle.clearedFlags = {}
    function vehicle:addWearAmount(amount) self.wear = self.wear + amount end
    function vehicle:setDamageAmount(amount) self.damage = amount end
    function vehicle:clearDirtyFlags(flag) table.insert(self.clearedFlags, flag) end
    function vehicle:setOperatingTime(time, isLoading)
        self.operatingTime, self.operatingTimeLoading = time, isLoading
    end
    function vehicle:setDirtAmount(amount) self.dirt = amount end
    function vehicle:getConsumerFillUnitIndex(fillType)
        return fillType == FillType.DIESEL and #self.fillUnits or nil
    end
    function vehicle:getPrice() return self.price end
    function vehicle:getFullName() return self.name end
    function vehicle:getUniqueId() return self.uniqueId end
    function vehicle:delete() self.isDeleted = true end
    vehicle.uniqueId = def.uniqueId or ("vehicle" .. vehicle.id)
    world.storeItems[vehicle.configFileName] = { xmlFilename = vehicle.configFileName, price = vehicle.price }
    return vehicle
end

local function makeLot(number)
    return { number = number, role = "smallTractor", xmlFilename = "tractor.xml", hours = 20, damage = 0.3,
        wear = 0.4, ageMonths = 1, dirt = 0.1, fuel = 0.15, rootX = 10 * number, rootZ = 5, yaw = 0.5 }
end

-- A site with lots out, as start() leaves one once they're spawned.
local function addSite(world, fieldId, lots)
    world.site.site = { fieldId = fieldId, lots = lots, planned = #lots, unplaced = 2, isSpawning = false,
        entrance = { x = 1, z = 2, edgeX = 3, edgeZ = 4, distance = 12 },
        walkways = { { x1 = 1, z1 = 2, x2 = 101, z2 = 2, halfWidth = 5 },
            { x1 = 1, z1 = 30, x2 = 101, z2 = 30, halfWidth = 5 } } }
    world.site:sync()
end

local function assertWalkways(walkways)
    assertEquals(#walkways, 2)
    assertEquals(walkways[2].z1, 30)
    assertEquals(walkways[2].x2, 101)
    assertEquals(walkways[1].halfWidth, 5)
end

-- Condition, price, ADS --------------------------------------------------------------------

test("a lot's condition goes on its vehicle: wear, damage, hours as loading, age, dirt, a low tank", function()
    local world = setup()
    local vehicle = addLotVehicle(world)
    local lot = makeLot(1)
    TheContractorAuctionSite.applyCondition(vehicle, lot)
    assertNear(vehicle.wear, 0.4, 0.0001)
    assertNear(vehicle.damage, 0.3, 0.0001)
    assertEquals(vehicle.clearedFlags[1], 4, "the wear's dirty flag cleared, as UEY does")
    assertEquals(vehicle.operatingTime, 20 * 3600000)
    assertEquals(vehicle.operatingTimeLoading, true, "written as loading, so ADS lets it through")
    assertEquals(vehicle.age, 1)
    assertNear(vehicle.dirt, 0.1, 0.0001)
    assertNear(vehicle:getFillUnitFillLevel(#vehicle.fillUnits), 400 * 0.15, 0.001)
end)

test("the guide price is vanilla's sell price for the lot's age, hours, damage and wear", function()
    local world = setup()
    local vehicle = addLotVehicle(world, { price = 80000 })
    local price = TheContractorAuctionSite.getGuidePrice(vehicle, makeLot(1))
    local call = world.sellPriceCalls[1]
    assertEquals(call.age, 1)
    assertEquals(call.operatingTime, 20 * 3600000)
    assertEquals(call.price, 80000, "the configured price, as vanilla gives it")
    assertNear(call.repairPrice, 80000 * 0.3 * 0.1, 0.001)
    assertNear(call.repaintPrice, 80000 * 0.4 * 0.01, 0.001)
    assertNear(price, 40000 - call.repairPrice - call.repaintPrice, 0.001)
end)

local function addADS(world, holderName)
    world.reinitialised = {}
    local holder = {
        reinitializeVehicle = function(vehicle)
            table.insert(world.reinitialised, { vehicle = vehicle, hours = vehicle.operatingTime,
                damage = vehicle.damage })
            if vehicle.adsBusy then
                return false, nil, "BUSY"
            end
            return true, 0.7, nil
        end,
    }
    world.adsEnv = { [holderName or "AdvancedDamageSystem"] = holder }
    TCADSUsedLots.detect()
end

local function makeADSVehicle(world, def)
    local vehicle = addLotVehicle(world, def)
    vehicle.spec_AdvancedDamageSystem = {}
    function vehicle:getIsADSExcluded() return self.adsExcluded == true end
    return vehicle
end

test("with ADS, a lot's history is built after its hours and damage are on it", function()
    local world = setup()
    addADS(world)
    assertTrue(TCADSUsedLots.isActive())
    local vehicle = makeADSVehicle(world)
    local lot = makeLot(1)
    lot.loadStarted = 99
    addSite(world, 7, { lot })
    world.site.loading = lot
    TheContractorAuctionSite.applyCondition(vehicle, lot)
    world.site:finishLot(lot, vehicle, nil)

    assertEquals(#world.reinitialised, 1)
    assertEquals(world.reinitialised[1].hours, 20 * 3600000, "the hours were on it first")
    assertNear(world.reinitialised[1].damage, 0.3, 0.0001, "and the damage")
    assertEquals(lot.adsResult, "ok")
    assertTrue(lot.guidePrice > 0)
    assertNear(lot.loadMs, 1000, 0.001)
    assertEquals(world.site.loading, nil, "ready for the next lot")
end)

test("ADS's reasons are kept: excluded, busy, and a vehicle ADS doesn't look after", function()
    local world = setup()
    addADS(world)
    local excluded = makeADSVehicle(world)
    excluded.adsExcluded = true
    local busy = makeADSVehicle(world)
    busy.adsBusy = true
    local plain = addLotVehicle(world)
    assertEquals(select(2, TCADSUsedLots.initialiseLot(excluded)), "notADS")
    assertEquals(select(2, TCADSUsedLots.initialiseLot(busy)), "BUSY")
    assertEquals(select(2, TCADSUsedLots.initialiseLot(plain)), "notADS")
    assertEquals(#world.reinitialised, 1, "only the one ADS looks after was asked")
end)

test("without ADS a lot keeps vanilla's condition; ADS_UsedVehicles' own name is found too", function()
    local world = setup()
    assertTrue(not TCADSUsedLots.isActive())
    assertEquals(select(2, TCADSUsedLots.initialiseLot(makeADSVehicle(world))), "noADS")

    addADS(world, "ADS_UsedVehicles")
    assertTrue(TCADSUsedLots.isActive())
    assertEquals(TCADSUsedLots.initialiseLot(makeADSVehicle(world)), true)

    world.adsEnv = { AdvancedDamageSystem = {} }
    TCADSUsedLots.detect()
    assertTrue(not TCADSUsedLots.isActive(), "an ADS without the function")
    assertEquals(#world.warnings, 1)
end)

-- The site on every machine -------------------------------------------------------------------

test("the site's field is protected and its lots are sent to every machine", function()
    local world = setup()
    local tractor = addLotVehicle(world)
    local combine = addLotVehicle(world)
    local header = addLotVehicle(world)
    local lots = { makeLot(1), makeLot(2) }
    lots[1].vehicleId = tractor.id
    lots[2].vehicleId, lots[2].attachmentId = combine.id, header.id
    addSite(world, 7, lots)

    local site = world.site
    assertTrue(site:isFieldInUse(7))
    assertTrue(not site:isFieldInUse(8))
    assertTrue(site:isLot(header))
    assertTrue(site:getLotVehicleIds()[tractor.id])
    local event = world.events[#world.events]
    assertEquals(event.fieldId, 7)
    assertEquals(#event.lots, 2, "two lots, three vehicles")
    assertWalkways(event.walkways)

    -- A client hears it from the server only.
    local client = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = client
    local fromClient = { getIsServer = function() return false end }
    local fromServer = { getIsServer = function() return true end }
    event:run(fromClient)
    assertTrue(not client:isFieldInUse(7))
    event:run(fromServer)
    assertTrue(client:isFieldInUse(7))
    assertTrue(client:isLot(combine))
    assertWalkways(client:getWalkways())

    -- Over the wire.
    local stream = world:newStream()
    event:writeStream(stream)
    local received = TCAuctionSiteEvent.emptyNew()
    client.walkways = {}
    received:readStream(stream, fromServer)
    assertWalkways(client:getWalkways())
end)

test("a joining client gets the site in its initial state", function()
    local world = setup()
    local tractor = addLotVehicle(world)
    local lot = makeLot(1)
    lot.vehicleId = tractor.id
    addSite(world, 4, { lot })
    local stream = world:newStream()
    world.site:writeInitialClientState(stream)
    local client = TheContractorAuctionSite.new()
    client:readInitialClientState(stream)
    assertTrue(client:isFieldInUse(4))
    assertTrue(client:isLot(tractor))
    assertWalkways(client:getWalkways())
end)

test("the site survives a save: rolls, prices and vehicles by uniqueId; a lot whose vehicle's gone drops out", function()
    local world = setup()
    local tractor = addLotVehicle(world, { uniqueId = "u-tractor" })
    local combine = addLotVehicle(world, { uniqueId = "u-combine" })
    local header = addLotVehicle(world, { uniqueId = "u-header" })
    local sold = addLotVehicle(world, { uniqueId = "u-gone" })
    local lots = { makeLot(1), makeLot(2), makeLot(3), makeLot(4) }
    lots[1].vehicleId, lots[1].guidePrice, lots[1].adsResult = tractor.id, 12345, "ok"
    lots[2].vehicleId, lots[2].attachmentId, lots[2].attachmentXml = combine.id, header.id, "header.xml"
    lots[2].role = "combine"
    lots[3].vehicleId = sold.id
    lots[4].failed = "something in the way"
    addSite(world, 9, lots)

    local xmlFile = {}
    world.site:saveToXmlFile(xmlFile)
    assertEquals(xmlFile["TheContractor.auctionSite.lot(0)#uniqueId"], "u-tractor")
    assertEquals(xmlFile["TheContractor.auctionSite.lot(3)#uniqueId"], nil, "a failed lot isn't saved")

    -- The next load: object ids are handed out again, and one lot's gone.
    for i, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle == sold then
            table.remove(g_currentMission.vehicleSystem.vehicles, i)
        end
    end
    local loaded = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = loaded
    loaded:loadFromXMLFile(xmlFile)
    assertTrue(loaded:isFieldInUse(9), "protected before the vehicles are back")
    assertWalkways(loaded:getWalkways())
    assertTrue(not loaded:isLot(tractor), "no vehicles until they're resolved")

    loaded:resolveSavedVehicles()
    local site = loaded.site
    assertEquals(#site.lots, 2)
    assertEquals(site.lots[1].vehicleId, tractor.id)
    assertEquals(site.lots[1].guidePrice, 12345)
    assertEquals(site.lots[1].adsResult, "ok")
    assertNear(site.lots[1].hours, 20, 0.0001)
    assertEquals(site.lots[1].ageMonths, 1)
    assertEquals(site.lots[2].role, "combine")
    assertEquals(site.lots[2].attachmentId, header.id)
    assertEquals(site.lots[2].attachmentXml, "header.xml")
    assertEquals(site.entrance.distance, 12)
    assertEquals(site.unplaced, 2)
    assertTrue(loaded:isLot(header))
    assertTrue(not loaded:isLot(sold))
    assertEquals(world.events[#world.events].fieldId, 9, "clients told")
end)

test("no site, nothing saved; clearing deletes every lot and frees the field", function()
    local world = setup()
    local xmlFile = {}
    world.site:saveToXmlFile(xmlFile)
    assertEquals(next(xmlFile), nil)

    local combine = addLotVehicle(world)
    local header = addLotVehicle(world)
    local lot = makeLot(1)
    lot.vehicleId, lot.attachmentId = combine.id, header.id
    local tractor = addLotVehicle(world)
    local plain = makeLot(2)
    plain.vehicleId = tractor.id
    addSite(world, 3, { lot, plain })
    world.site:clear()
    assertTrue(combine.isDeleted and header.isDeleted)
    assertTrue(tractor.isDeleted, "a lot with no attachment too")
    assertTrue(not world.site:isFieldInUse(3))
    assertEquals(#world.site:getWalkways(), 0)
    assertEquals(world.site.site, nil)
    assertEquals(world.events[#world.events].fieldId, 0)
    assertEquals(#world.events[#world.events].lots, 0)
end)

test("a lot that finishes loading after the site's cleared is deleted, not kept", function()
    local world = setup()
    addSite(world, 3, { makeLot(1) })
    local oldSite = world.site.site
    world.site:clear()
    local late = addLotVehicle(world)
    world.site:onLotLoaded({ late }, VehicleLoadingState.OK,
        { lot = oldSite.lots[1], site = oldSite })
    assertTrue(late.isDeleted)
    assertEquals(world.site.site, nil)
end)

-- Tipping over ------------------------------------------------------------------------------

-- A lot's vehicle that can tip: its up vector's height is world.upY[vehicle].
local function addTippable(world, def)
    local vehicle = addLotVehicle(world, def)
    vehicle.rootNode = vehicle
    vehicle.tilt = 0
    world.placed = world.placed or {}
    localDirectionToWorld = function(node, x, y, z)
        return 0, math.cos(math.rad(node.tilt)), 0
    end
    getWorldTranslation = function(node) return 10, 2, 20 end
    getWorldRotation = function(node) return 0.05, 1.2, 0 end
    function vehicle:removeFromPhysics() self.outOfPhysics = true end
    function vehicle:addToPhysics() self.outOfPhysics = false end
    function vehicle:setAbsolutePosition(x, y, z, rx, ry, rz)
        table.insert(world.placed, { vehicle = self, pose = { x, y, z, rx, ry, rz }, outOfPhysics = self.outOfPhysics })
        self.tilt = 0
    end
    return vehicle
end

test("what to do about a tilt: leave it, stand it up once, then report it", function()
    setup()
    local limit = TheContractorAuctionSite.TIP_DEGREES
    assertEquals(TheContractorAuctionSite.getUprightAction(limit, 0), "ok")
    assertEquals(TheContractorAuctionSite.getUprightAction(limit + 1, 0), "right")
    assertEquals(TheContractorAuctionSite.getUprightAction(limit + 1, TheContractorAuctionSite.UPRIGHT_ATTEMPTS),
        "tipped")
end)

test("a lot that tips over is stood back up as it was set down, and reported if it tips again", function()
    local world = setup()
    local mower = addTippable(world)
    local lot = makeLot(1)
    lot.loadStarted = 99
    addSite(world, 7, { lot })
    world.site.loading = lot
    world.site:onLotLoaded({ mower }, VehicleLoadingState.OK, { lot = lot, site = world.site.site })
    assertEquals(lot.pose[5], 1.2, "the pose it was set down in, the shop's offset with it")

    -- Upright at the first check: nothing done.
    world.site:update(TheContractorAuctionSite.UPRIGHT_CHECK_MS)
    assertEquals(#world.placed, 0)

    -- Tipped: stood back up, out of physics while it's moved, the full pose.
    world.site.uprightChecks = { { lot = lot, dueMs = 0 } }
    mower.tilt = 80
    world.site:update(1)
    assertEquals(#world.placed, 1)
    assertTrue(world.placed[1].outOfPhysics)
    assertTrue(not mower.outOfPhysics, "back in physics")
    assertEquals(world.placed[1].pose[4], 0.05)
    assertEquals(lot.uprightAttempts, 1)

    -- Tips again: taken away, listed as failed, clients told.
    mower.tilt = 80
    world.site:update(TheContractorAuctionSite.UPRIGHT_CHECK_MS)
    assertEquals(#world.placed, 1)
    assertTrue(mower.isDeleted)
    assertEquals(lot.failed, "tipped over")
    assertTrue(not world.site:isLot(mower))
    assertEquals(#world.events[#world.events].lots, 0)
end)

test("a lot with its header hitched on is never moved: tipped, it goes with its header", function()
    local world = setup()
    local combine = addTippable(world)
    local header = addLotVehicle(world)
    local lot = makeLot(1)
    lot.vehicleId, lot.attachmentId, lot.pose = combine.id, header.id, { 1, 2, 3, 0, 0, 0 }
    addSite(world, 7, { lot })
    combine.tilt = 60
    world.site:checkUpright(lot)
    assertEquals(#world.placed, 0)
    assertTrue(combine.isDeleted and header.isDeleted)
    assertEquals(lot.failed, "tipped over")
end)

-- Sizing a sale ----------------------------------------------------------------------------

-- planLots and measureField swapped for a field that holds `capacity` lots
-- (less `shortfall` more on each plan after the first, as a different mix
-- of roles packs differently). Records the plans' sizes.
local function fakeField(world, capacity, shortfall)
    world.plans = {}
    local measured = 0
    TheContractorAuctionSite.planLots = function(count)
        table.insert(world.plans, count)
        local lots = {}
        for i = 1, count do
            lots[i] = { role = "smallTractor" }
        end
        return lots
    end
    TheContractorAuctionSite.measureField = function(_, lots)
        measured = measured + 1
        local fits = capacity - (measured > 1 and (shortfall or 0) or 0)
        return { fitted = math.min(#lots, fits), of = #lots }
    end
end

test("a sale takes as many lots as its field fits, the mix drawn again for that size", function()
    local world = setup()
    fakeField(world, 70)
    local lots, candidate = TheContractorAuctionSite.sizeSale({}, 120, {}, math.random)
    assertEquals(table.concat(world.plans, ","), "120,70")
    assertEquals(#lots, 70)
    assertEquals(candidate.fitted, 70)
end)

test("a field that fits the preferred size is planned once", function()
    local world = setup()
    fakeField(world, 300)
    local lots = TheContractorAuctionSite.sizeSale({}, 120, {}, math.random)
    assertEquals(table.concat(world.plans, ","), "120")
    assertEquals(#lots, 120)
end)

test("sizing stops after its attempts, keeping the plan that placed the most", function()
    local world = setup()
    fakeField(world, 70, 2)
    local _, candidate = TheContractorAuctionSite.sizeSale({}, 120, {}, math.random)
    -- 120 fits 70; 70 fits 68; 68 fits 68.
    assertEquals(table.concat(world.plans, ","), "120,70,68")
    assertEquals(candidate.fitted, 70, "the first plan placed the most")
end)

test("a lot's footprint is its store size with a margin round it, centred on it", function()
    setup()
    TheContractorFarmerFleet.getSizeModel = function(xml)
        if xml == "combine.xml" then
            return { xmlFilename = xml, width = 3.5, length = 9, height = 4, widthOffset = 0.1, lengthOffset = 0.5 }
        elseif xml == "header.xml" then
            return { xmlFilename = xml, width = 7.5, length = 2, height = 1.5 }
        end
        return nil
    end
    local margin = TheContractorAuctionSite.FOOTPRINT_MARGIN
    local lot = { xmlFilename = "combine.xml" }
    assertTrue(TheContractorAuctionSite.setFootprint(lot))
    assertNear(lot.width, 3.5 + margin.width, 0.0001)
    assertNear(lot.length, 9 + margin.length, 0.0001)
    assertNear(lot.lengthOffset, 0.5, 0.0001, "the margin's on both ends")

    local fitted = { xmlFilename = "combine.xml", attachmentXml = "header.xml" }
    TheContractorAuctionSite.setFootprint(fitted)
    local gap = TheContractorRepairContracts.CLEARANCE
    assertNear(fitted.width, 7.5 + margin.width, 0.0001, "as wide as the header")
    assertNear(fitted.length, 9 + 2 + gap + margin.length, 0.0001, "the header and its gap in front")

    assertEquals(TheContractorAuctionSite.setFootprint({ xmlFilename = "gone.xml" }), false)
end)

-- Which fields can be a site (137) -------------------------------------------------------------

-- A field for getFieldRefusal, and the live jobs and auction it's checked against.
local function refusalWorld(world)
    world.liveJobs = {}
    world.auction = nil
    local tc = g_currentMission.TheContractor
    tc.Jobs = { hasLiveJob = function(_, fieldId) return world.liveJobs[fieldId] == true end }
    tc.Auctions = { getAuction = function() return world.auction end }
    local function field(id, owner)
        return { getId = function() return id end, getOwner = function() return owner or 0 end }
    end
    return field
end

test("a field with any live job can't be a site, whatever its dates, nor one a farm owns", function()
    local world = setup()
    local field = refusalWorld(world)
    assertEquals(TheContractorAuctionSite.getFieldRefusal(field(4)), nil)
    world.liveJobs[4] = true
    assertTrue(TheContractorAuctionSite.getFieldRefusal(field(4)) ~= nil, "a job on offer or taken on")
    assertTrue(TheContractorAuctionSite.getFieldRefusal(field(5, 1)) ~= nil, "farm 1's")
end)

test("an auction's field is its own site, and no other's", function()
    local world = setup()
    local field = refusalWorld(world)
    world.auction = { id = 3, fieldId = 4 }
    assertEquals(TheContractorAuctionSite.getFieldRefusal(field(4), 3), nil)
    assertTrue(TheContractorAuctionSite.getFieldRefusal(field(4)) ~= nil, "the console's spike")
    assertTrue(TheContractorAuctionSite.getFieldRefusal(field(4), 2) ~= nil)
    assertEquals(TheContractorAuctionSite.getFieldRefusal(field(6)), nil)
end)

-- 138: the lots as everyone sees them ------------------------------------------------------------

-- Whether any value written to a stream is this one.
local function streamHas(stream, value)
    for _, written in ipairs(stream.values) do
        if written == value then
            return true
        end
    end
    return false
end

local PUBLIC_FIELDS = { number = true, xmlFilename = true, attachmentXml = true, hours = true, ageMonths = true,
    guidePrice = true, closeMinute = true, result = true, vehicleId = true, attachmentId = true }

-- A lot carrying everything the server keeps on one, 139's hidden bid too.
local function secretLot(world, number)
    local vehicle = addLotVehicle(world, { uniqueId = "secret-unique" })
    local lot = makeLot(number)
    lot.vehicleId = vehicle.id
    lot.guidePrice, lot.closeMinute = 54321, 17 * 60 + 24
    lot.damage, lot.wear, lot.adsResult = 0.371, 0.583, "ADS-SECRET"
    lot.hiddenBid = 98765
    -- 139: the room's roll, the hidden bid's source.
    lot.localRoll = 0.4242
    return lot, vehicle
end

local function assertNothingSecret(stream)
    for _, secret in ipairs({ 98765, 0.371, 0.583, 0.4242, "ADS-SECRET", "secret-unique", "smallTractor" }) do
        assertTrue(not streamHas(stream, secret), "never streamed: " .. tostring(secret))
    end
end

local function assertOnlyPublic(lot)
    for key in pairs(lot) do
        assertTrue(PUBLIC_FIELDS[key], "a client's lot has only what everyone may know: " .. key)
    end
end

test("only what everyone may know of a lot goes on the wire: no hidden bid, rolls or ADS", function()
    local world = setup()
    local lot = secretLot(world, 12)
    addSite(world, 7, { lot })

    local event = world.events[#world.events]
    local stream = world:newStream()
    event:writeStream(stream)
    assertNothingSecret(stream)
    assertTrue(streamHas(stream, 54321), "the guide price is")

    local client = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = client
    TCAuctionSiteEvent.emptyNew():readStream(stream, { getIsServer = function() return true end })
    local seen = client:getLot(12)
    assertOnlyPublic(seen)
    assertEquals(seen.guidePrice, 54321)
    assertEquals(seen.closeMinute, 17 * 60 + 24)
    assertNear(seen.hours, 20, 0.0001)
    assertEquals(seen.ageMonths, 1)
    assertEquals(seen.xmlFilename, "tractor.xml")
    assertEquals(seen.attachmentXml, nil)
    assertEquals(lot.hiddenBid, 98765, "still on the server's own lot")

    -- A joining client's initial state too.
    local initial = world:newStream()
    world.site:writeInitialClientState(initial)
    assertNothingSecret(initial)
    local joiner = TheContractorAuctionSite.new()
    joiner:readInitialClientState(initial)
    assertOnlyPublic(joiner:getLot(12))
    assertEquals(joiner:getLot(12).guidePrice, 54321)
end)

test("a lot that comes out is added on every machine without sending the whole site", function()
    local world = setup()
    addSite(world, 7, {})
    local client = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = client
    local fromServer = { getIsServer = function() return true end }
    local stream = world:newStream()
    world.events[#world.events]:writeStream(stream)
    TCAuctionSiteEvent.emptyNew():readStream(stream, fromServer)
    assertTrue(client:isFieldInUse(7))
    assertWalkways(client:getWalkways())

    -- Lot 2 comes out first, then lot 1 with its header.
    g_currentMission.TheContractor.AuctionSite = world.site
    local site = world.site
    local second, secondVehicle = secretLot(world, 2)
    local combine, header = addLotVehicle(world), addLotVehicle(world)
    local first = makeLot(1)
    first.attachmentXml, first.closeMinute, first.vehicleId = "header.xml", 1020, combine.id
    site.site.lots = { first, second }
    for _, entry in ipairs({ { second, secondVehicle }, { first, combine, header } }) do
        local lot = entry[1]
        lot.loadStarted = 99
        site.loading = lot
        site:finishLot(lot, entry[2], entry[3])
        local event = world.events[#world.events]
        assertEquals(event.lots, nil, "one lot, not the site")
        local lotStream = world:newStream()
        event:writeStream(lotStream)
        assertNothingSecret(lotStream)
        g_currentMission.TheContractor.AuctionSite = client
        TCAuctionSiteEvent.emptyNew():readStream(lotStream, fromServer)
        g_currentMission.TheContractor.AuctionSite = site
    end

    local lots = client:getLots()
    assertEquals(#lots, 2)
    assertEquals(lots[1].number, 1, "by number, whatever order they came out in")
    assertEquals(lots[2].number, 2)
    assertEquals(lots[1].attachmentXml, "header.xml")
    assertTrue(client:isLot(header), "the header's locked too")
    assertTrue(client:isLot(secondVehicle))
    assertWalkways(client:getWalkways())
    assertEquals(#site:getLots(), 2, "the server sees the same")
    assertEquals(site:getLot(1).guidePrice, first.guidePrice)
end)

test("bidding closes lot by lot from 17:00 to 18:00, in lot order", function()
    setup()
    local A = TheContractorAuctionSite
    assertEquals(A.getCloseMinute(1, 120), 17 * 60)
    assertEquals(A.getCloseMinute(120, 120), 18 * 60, "the last at 18:00 (139)")
    assertEquals(A.getCloseMinute(1, 1), 17 * 60, "a one-lot sale")
    local last = -1
    for number = 1, 120 do
        local minute = A.getCloseMinute(number, 120)
        assertTrue(minute >= last, "never earlier than the lot before")
        last = minute
    end
    -- A small sale has a lot every few minutes.
    assertEquals(A.getCloseMinute(2, 30) - A.getCloseMinute(1, 30), 2)
    assertEquals(A.getCloseMinute(30, 30), 18 * 60)
end)

test("a lot's bidding is open until its time on the sale day, then closed", function()
    setup()
    local A = TheContractorAuctionSite
    local S = A.LOT_STATE
    local lot = { closeMinute = 17 * 60 + 24 }
    assertEquals(A.getLotState(lot, 40, 39, 18 * 60), S.OPEN, "the day before")
    assertEquals(A.getLotState(lot, 40, 40, 17 * 60 + 23), S.OPEN)
    assertEquals(A.getLotState(lot, 40, 40, 17 * 60 + 24), S.CLOSED, "at its time")
    assertEquals(A.getLotState(lot, 40, 41, 0), S.CLOSED, "the day after")
    assertEquals(A.getLotState(lot, nil, 40, 23 * 60), S.OPEN, "the console's site has no sale")
end)

test("the auction on the site's own field sets the state now", function()
    local world = setup()
    local lot = secretLot(world, 1)
    addSite(world, 7, { lot })
    local environment = g_currentMission.environment or {}
    g_currentMission.environment = environment
    environment.currentMonotonicDay, environment.currentHour, environment.currentMinute = 40, 17, 30
    local site = world.site
    local S = TheContractorAuctionSite.LOT_STATE
    g_currentMission.TheContractor.Auctions = { getAuction = function() return world.auction end }
    world.auction = nil
    assertEquals(site:getLotStateNow(site:getLot(1)), S.OPEN, "no auction: the console's site")
    world.auction = { fieldId = 7, saleDay = 40 }
    assertEquals(site:getLotStateNow(site:getLot(1)), S.CLOSED, "past 17:24 on the day")
    world.auction = { fieldId = 8, saleDay = 40 }
    assertEquals(site:getLotStateNow(site:getLot(1)), S.OPEN, "another field's auction")
end)

test("closing times survive a save; a save from before them gets them spread in lot order", function()
    local world = setup()
    local lot = secretLot(world, 3)
    addSite(world, 9, { lot })
    local xmlFile = {}
    world.site:saveToXmlFile(xmlFile)
    local loaded = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = loaded
    loaded:loadFromXMLFile(xmlFile)
    loaded:resolveSavedVehicles()
    assertEquals(loaded.site.lots[1].closeMinute, 17 * 60 + 24)
    assertEquals(loaded:getLot(3).closeMinute, 17 * 60 + 24, "and sent to clients")

    xmlFile["TheContractor.auctionSite.lot(0)#closeMinute"] = nil
    xmlFile["TheContractor.auctionSite#planned"] = 30
    local old = TheContractorAuctionSite.new()
    old:loadFromXMLFile(xmlFile)
    assertEquals(old.site.lots[1].closeMinute, TheContractorAuctionSite.getCloseMinute(3, 30))
end)

test("the View lot prompt reaches a machine from beside it, measured from its size box", function()
    setup()
    local size = { width = 3, length = 8, widthOffset = 0, lengthOffset = 1 }
    local distance = TCAuctionLotActivatable.getBoxDistance
    assertEquals(distance(0, 1, size), 0, "inside")
    assertNear(distance(3.5, 1, size), 2, 0.0001, "2 m off its side")
    assertNear(distance(0, 1 + 4 + 3, size), 3, 0.0001, "3 m off its front, the offset counted")
    assertNear(distance(1.5 + 3, 5 + 4, size), 5, 0.0001, "off a corner")
    assertTrue(distance(0, 8, size) <= TCAuctionLotActivatable.ACTIVATE_DISTANCE)
    assertTrue(distance(5.5, 1, size) > TCAuctionLotActivatable.ACTIVATE_DISTANCE)
end)

-- 140: the scene ------------------------------------------------------------------------------

local function makeScene()
    return {
        seed = 4242, cx = 150, cz = 80, angle = 0.25, halfV = 70, nearSign = -1, nearEdge = -120, farEdge = 130,
        aisleWidth = 10, endAisle = 8, gateV = 3.5,
        reserve = { uFrom = -150, uTo = -120, vFrom = -30, vTo = 28 },
        rows = {
            { vFrom = -30, vTo = -25, frontV = -25, facing = 1, used = 120, lotFrom = 1, lotTo = 3,
                slots = { -118.5, -112, -104.25 } },
            { vFrom = -15, vTo = -7, frontV = -15, facing = -1, used = 60, lotFrom = 4, lotTo = 5,
                slots = { -118.7, -110 } },
        },
    }
end

local function assertScene(scene)
    assertTrue(scene ~= nil, "a scene")
    local expected = makeScene()
    assertEquals(scene.seed, 4242)
    assertEquals(scene.nearSign, -1)
    for _, key in ipairs({ "cx", "cz", "angle", "halfV", "nearEdge", "farEdge", "aisleWidth", "endAisle", "gateV" }) do
        assertNear(scene[key], expected[key], 0.001, key)
    end
    assertNear(scene.reserve.vTo, 28, 0.001)
    assertEquals(#scene.rows, 2)
    assertEquals(scene.rows[2].facing, -1)
    assertEquals(scene.rows[2].lotFrom, 4)
    assertEquals(scene.rows[2].lotTo, 5)
    assertEquals(#scene.rows[1].slots, 3)
    assertNear(scene.rows[1].slots[3], -104.25, 0.001)
end

test("140: the site's scene goes to every machine, a joining client and the save", function()
    local world = setup()
    local tractor = addLotVehicle(world)
    local lot = makeLot(1)
    lot.vehicleId = tractor.id
    world.site.site = { fieldId = 6, lots = { lot }, planned = 1, unplaced = 0, isSpawning = false, walkways = {},
        scene = makeScene() }
    world.site:sync()
    assertScene(world.site:getScene())
    local event = world.events[#world.events]
    local fromServer = { getIsServer = function() return true end }

    -- Over the wire.
    local stream = world:newStream()
    event:writeStream(stream)
    local client = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = client
    TCAuctionSiteEvent.emptyNew():readStream(stream, fromServer)
    assertScene(client:getScene())

    -- A joining client.
    local initial = world:newStream()
    world.site:writeInitialClientState(initial)
    local joining = TheContractorAuctionSite.new()
    joining:readInitialClientState(initial)
    assertScene(joining:getScene())

    -- The save.
    local xmlFile = {}
    world.site:saveToXmlFile(xmlFile)
    local loaded = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = loaded
    loaded:loadFromXMLFile(xmlFile)
    assertScene(loaded.site.scene)
    assertScene(loaded:getScene())

    -- Cleared: no scene anywhere.
    world.site.site = nil
    g_currentMission.TheContractor.AuctionSite = world.site
    world.site:sync()
    assertEquals(world.site:getScene(), nil)
end)

test("140: a site saved before the scene loads without one", function()
    local world = setup()
    local tractor = addLotVehicle(world)
    local lot = makeLot(1)
    lot.vehicleId = tractor.id
    addSite(world, 9, { lot })
    local xmlFile = {}
    world.site:saveToXmlFile(xmlFile)
    local loaded = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = loaded
    loaded:loadFromXMLFile(xmlFile)
    assertTrue(loaded:isFieldInUse(9))
    assertEquals(loaded:getScene(), nil)
end)
