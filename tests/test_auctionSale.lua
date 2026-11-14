-- 139: auction bids and the sale (TheContractorAuctionSale). The win curve
-- and the room's bid from it, settling a lot (no bid, above and below the
-- room, two farms, a tie, a farm that can't pay), bids left, changed and
-- withdrawn through the server and sent to their own farm only, lots closed
-- at their times and caught up after a skip, the winner paying and getting
-- the machine, the local buyers' lots taken away, a won lot left on the
-- field delivered, and the bids kept through a save. The real site (135)
-- and inbox; the auction, parking, farms and money are faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorRepairContracts = { CLEARANCE = 1 }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    FarmManager.SPECTATOR_FARM_ID = 0
    FSBaseMission.INGAME_NOTIFICATION_INFO = "info"
    MessageType = { MINUTE_CHANGED = 1, PLAYER_FARM_CHANGED = 2 }
    g_messageCenter = { subscribe = function() end, unsubscribeAll = function() end }
    TCMessagePostedEvent = { new = function(message) return { posted = message } end }
    TCMessageRemovedEvent = { new = function(id) return { removed = id } end }
    TheContractorStaff = { scalePay = function(pay) return pay end }
    TheContractorJob = { STATE = { OFFERED = 1, NEGOTIATING = 2 } }
    TheContractorAuctions = { SHOW_ON_MAP_ACTION = { key = "showOnMap", textKey = "tc_auction_showOnMap" } }

    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    world.farmEvents = {}
    g_currentMission.broadcastEventToFarm = function(_, event, farmId)
        table.insert(world.farmEvents, { event = event, farmId = farmId })
    end

    world:load("src/util/TCVehicleIds.lua")
    world:load("src/util/TCAuctionCrowd.lua")
    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/business/FarmerFleet.lua")
    world:load("src/business/Inbox.lua")
    FieldGroundType = {}
    world:load("src/util/TCFieldPreparation.lua")
    world:load("src/business/AuctionSite.lua")
    world:load("src/util/TCAuctionAttendance.lua")
    world:load("src/util/TCADSUsedLots.lua")
    world:load("src/util/TCLotInspections.lua")
    world:load("src/business/AuctionSale.lua")
    world:load("src/events/TCAuctionSiteEvent.lua")
    world:load("src/events/TCAuctionBidEvent.lua")
    world:load("src/events/TCAuctionBidsEvent.lua")

    -- Farms and their money.
    world.balances = { [1] = 1000000, [2] = 1000000, [3] = 1000000 }
    world.money = {}
    g_farmManager.getFarmById = function(_, farmId)
        if world.balances[farmId] == nil then
            return nil
        end
        return { farmId = farmId, getBalance = function() return world.balances[farmId] end }
    end
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
        world.balances[farmId] = world.balances[farmId] + amount
    end

    -- The sale day, 17:30.
    g_currentMission.environment = { currentMonotonicDay = 40, currentHour = 17, currentMinute = 30 }

    -- The auction on field 5, its field a 100 m square.
    world.auction = { id = 3, fieldId = 5, saleDay = 40 }
    local tc = g_currentMission.TheContractor
    tc.Auctions = { getAuction = function() return world.auction end }
    g_fieldManager = { getFieldById = function(_, id) return { id = id } end }
    TCAuctionCrowd.getFieldPolygon = function()
        return { { x = 0, z = 0 }, { x = 100, z = 0 }, { x = 100, z = 100 }, { x = 0, z = 100 } }
    end
    getWorldTranslation = function(node) return node.x or 50, 0, node.z or 50 end

    world.companies = { [1] = true, [2] = true }
    tc.Company = { hasCompany = function(_, farmId) return world.companies[farmId] == true end }
    tc.Settings = { scaleCost = function(_, amount) return amount * 2 end }
    tc.Inbox = TheContractorInbox.new()
    tc.Inbox:registerMessageKind("auctionWon", { category = "job" })
    world.returned = {}
    tc.Parking = {
        returnVehicles = function(_, farmId, vehicleIds)
            table.insert(world.returned, { farmId = farmId, vehicleIds = vehicleIds })
        end,
    }
    -- The farm's parking and the shop: room for what each list allows.
    world.parkingRoom, world.shopRoom = 10, 10
    world.placed, world.unhitched = {}, {}
    TCParking = {
        findSpot = function(vehicle, farmId)
            if world.parkingRoom <= 0 then return nil end
            world.parkingRoom = world.parkingRoom - 1
            return 1000, 0, 1000, 0
        end,
        findShopSpot = function(vehicle)
            if world.shopRoom <= 0 then return nil end
            world.shopRoom = world.shopRoom - 1
            return 2000, 0, 2000, 0
        end,
        placeVehicle = function(vehicle, x, y, z, rotY)
            vehicle.x, vehicle.z = x, z
            table.insert(world.placed, { vehicle = vehicle, x = x })
        end,
    }
    TCJobSiteSetup = {
        unhitchVehicles = function(ids)
            for _, id in ipairs(ids) do
                table.insert(world.unhitched, id)
            end
        end,
    }
    world.storeItems = {}
    g_storeManager = { getItemByXMLFilename = function(_, xml) return world.storeItems[xml] end }

    local site = TheContractorAuctionSite.new()
    tc.AuctionSite = site
    world.site = site
    local sale = TheContractorAuctionSale.new()
    tc.AuctionSale = sale
    world.sale = sale
    return world, sale, site
end

-- A lot's machine, owned by nobody until it's sold.
local function addMachine(world)
    local vehicle = world:addVehicle({ name = "Lot", farmId = 0 })
    vehicle.rootNode = vehicle
    vehicle.x, vehicle.z = 50, 50
    function vehicle:setOwnerFarmId(farmId) self.farmId = farmId end
    function vehicle:delete() self.isDeleted = true end
    function vehicle:getUniqueId() return "u" .. self.id end
    return vehicle
end

-- A site of lots on field 5: guide 10,000 each, closing a minute apart from
-- 17:00, the room's roll given (default 0.5).
local function addLots(world, count, rolls)
    local lots = {}
    for number = 1, count do
        local vehicle = addMachine(world)
        lots[number] = { number = number, role = "smallTractor", xmlFilename = "tractor.xml", hours = 20,
            ageMonths = 1, damage = 0.2, wear = 0.3, guidePrice = 10000, closeMinute = 17 * 60 + number - 1,
            localRoll = rolls ~= nil and rolls[number] or 0.5, vehicleId = vehicle.id, rootX = 50, rootZ = 50,
            yaw = 0 }
    end
    world.site.site = { fieldId = 5, lots = lots, planned = count, unplaced = 0, walkways = {} }
    world.site:sync()
    return lots
end

-- The roll that puts the room's bid at this share of the guide.
local function rollFor(ratio)
    return TheContractorAuctionSale.getWinChance(ratio)
end

local function lastFarmEvent(world, farmId)
    for i = #world.farmEvents, 1, -1 do
        if world.farmEvents[i].farmId == farmId then
            return world.farmEvents[i].event
        end
    end
    return nil
end

-- The curve -----------------------------------------------------------------------------------

test("the win curve: its rows, and between them", function()
    setup()
    local S = TheContractorAuctionSale
    for _, row in ipairs(S.WIN_CURVE) do
        assertNear(S.getWinChance(row[1]), row[2], 0.0001)
    end
    assertNear(S.getWinChance(0.95), 0.65, 0.0001, "halfway between 0.90 and 1.00")
    assertEquals(S.getWinChance(2), 1)
    assertEquals(S.getWinChance(0.1), 0)
    assertNear(S.getWinChance(1), 0.85, 0.0001, "the guide wins about 85% of the time")
end)

test("the room's bid is the curve's inverse: over many rolls, each row's share holds", function()
    setup()
    local S = TheContractorAuctionSale
    for _, row in ipairs(S.WIN_CURVE) do
        assertNear(S.getLocalBidRatio(row[2]), row[1], 0.0001)
    end
    math.randomseed(139)
    local rolls = 20000
    local ratios = {}
    for i = 1, rolls do
        ratios[i] = S.getLocalBidRatio(math.random())
    end
    for _, row in ipairs(S.WIN_CURVE) do
        local beaten = 0
        for _, ratio in ipairs(ratios) do
            if ratio < row[1] then
                beaten = beaten + 1
            end
        end
        assertNear(beaten / rolls, row[2], 0.012, "a bid of " .. row[1] .. " of the guide")
    end
end)

test("the minimum bid", function()
    setup()
    local S = TheContractorAuctionSale
    assertEquals(S.getMinimumBid(10000), 7000)
    assertEquals(S.getMinimumBid(10001), 7001, "rounded up")
    local lot = { guidePrice = 10000, localRoll = rollFor(0.9) }
    assertNear(S.getLocalBid(lot), 9000, 0.01)
end)

test("the card's bid steps: the minimum, then each percent of the guide in round figures", function()
    setup()
    local S = TheContractorAuctionSale
    local steps = S.getBidSteps(227291)
    assertEquals(steps[1].amount, S.getMinimumBid(227291), "the minimum first")
    assertEquals(steps[1].percent, 70)
    assertEquals(steps[#steps].percent, 130)
    for i = 2, #steps do
        assertTrue(steps[i].amount > steps[i - 1].amount, "always up")
        assertEquals(steps[i].amount % 100, 0, "round hundreds for a six-figure guide")
    end
    local atGuide = steps[S.getNearestStep(steps, 227291)]
    assertEquals(atGuide.percent, 100)
    assertEquals(atGuide.amount, 227300)

    local small = S.getBidSteps(850)
    assertEquals(small[1].amount, 595)
    for i = 2, #small do
        assertTrue(small[i].amount > small[i - 1].amount, "no step twice")
    end
end)

-- Settling (pure) -----------------------------------------------------------------------------

local function payAll() return true end

test("settling: no bids, or none above the room, goes to a local buyer", function()
    setup()
    local S = TheContractorAuctionSale
    local winner, price, unpaid = S.settle({}, 9000, payAll)
    assertEquals(winner, nil)
    assertEquals(price, nil)
    assertEquals(#unpaid, 0)
    winner = S.settle({ { farmId = 1, amount = 8000, order = 1 }, { farmId = 2, amount = 9000, order = 2 } }, 9000,
        payAll)
    assertEquals(winner, nil, "level with the room isn't above it")
end)

test("settling: the highest bid above the room wins and pays its own bid; a tie goes to the earlier", function()
    setup()
    local S = TheContractorAuctionSale
    local winner, price = S.settle({ { farmId = 1, amount = 9500, order = 1 }, { farmId = 2, amount = 12000, order = 2 } },
        9000, payAll)
    assertEquals(winner, 2)
    assertEquals(price, 12000, "sealed: what they bid, not one over the next")
    winner = S.settle({ { farmId = 1, amount = 9500, order = 5 }, { farmId = 2, amount = 9500, order = 3 } }, 9000,
        payAll)
    assertEquals(winner, 2, "the earlier bid")
end)

test("settling: a farm that can't pay loses it to the next above the room", function()
    setup()
    local S = TheContractorAuctionSale
    local bids = { { farmId = 1, amount = 12000, order = 1 }, { farmId = 2, amount = 11000, order = 2 },
        { farmId = 3, amount = 8000, order = 3 } }
    local winner, price, unpaid = S.settle(bids, 9000, function(farmId) return farmId ~= 1 end)
    assertEquals(winner, 2)
    assertEquals(price, 11000)
    assertEquals(table.concat(unpaid, ","), "1")
    winner, price, unpaid = S.settle(bids, 9000, function(farmId) return farmId == 3 end)
    assertEquals(winner, nil, "farm 3's bid is under the room")
    assertEquals(table.concat(unpaid, ","), "1,2")
end)

-- Bids through the server ---------------------------------------------------------------------

test("a bid is left, changed and withdrawn until the lot closes, and only its own farm hears", function()
    local world, sale = setup()
    addLots(world, 40)
    local R = TheContractorAuctionSale.REFUSAL

    assertEquals(sale:placeBid(1, 35, 6999), R.BELOW_MINIMUM)
    assertEquals(sale:getFarmBid(35, 1), nil)
    assertEquals(sale:placeBid(1, 35, 0), R.NO_BID)
    assertEquals(sale:placeBid(1, 99, 9000), R.NO_LOT)
    assertEquals(sale:placeBid(1, 2, 9000), R.CLOSED, "lot 2 closed at 17:01")

    assertEquals(sale:placeBid(1, 35, 9000), nil)
    local first = sale:getFarmBid(35, 1)
    assertEquals(first.amount, 9000)
    assertEquals(sale:placeBid(2, 35, 9500), nil)
    assertEquals(sale:placeBid(1, 35, 9800), nil)
    assertEquals(sale:getFarmBid(35, 1).amount, 9800)
    assertTrue(sale:getFarmBid(35, 1).order > sale:getFarmBid(35, 2).order, "a changed bid is a new one for ties")

    -- Farm 1 hears its bids and never farm 2's.
    local event = lastFarmEvent(world, 1)
    assertEquals(event.farmBids[35].amount, 9800)
    local stream = world:newStream()
    event:writeStream(stream)
    for _, value in ipairs(stream.values) do
        assertTrue(value ~= 9500, "farm 2's bid never sent to farm 1")
    end
    for _, entry in ipairs(world.farmEvents) do
        assertTrue(entry.farmId == 1 or entry.farmId == 2)
    end

    assertEquals(sale:placeBid(1, 35, 0), nil)
    assertEquals(sale:getFarmBid(35, 1), nil, "withdrawn")
    assertEquals(sale:getFarmBid(35, 2).amount, 9500)
end)

test("a refusal goes back with the farm's bids; a request for another farm is ignored", function()
    local world, sale = setup()
    addLots(world, 40)
    sale:placeBid(1, 35, 100)
    local event = lastFarmEvent(world, 1)
    assertEquals(event.refusal.key, TheContractorAuctionSale.REFUSAL.BELOW_MINIMUM)

    g_currentMission.connectionsToPlayer = {}
    local fromClient = { getIsServer = function() return false end }
    g_currentMission.connectionsToPlayer[fromClient] = { farmId = 2 }
    TCAuctionBidEvent.new(1, 35, 9000):run(fromClient)
    assertEquals(sale:getFarmBid(35, 1), nil, "a farm-2 player can't bid for farm 1")
    TCAuctionBidEvent.new(2, 35, 9000):run(fromClient)
    assertEquals(sale:getFarmBid(35, 2).amount, 9000)
end)

test("a client keeps its farm's bids and sees each lot as its farm does", function()
    local world, sale, site = setup()
    addLots(world, 40, { [35] = rollFor(0.9), [36] = rollFor(0.9) })
    sale:placeBid(1, 35, 9500)
    sale:placeBid(1, 36, 8000)
    sale:placeBid(2, 36, 9900)

    local client = TheContractorAuctionSale.new()
    local stream = world:newStream()
    lastFarmEvent(world, 1):writeStream(stream)
    local received = TCAuctionBidsEvent.emptyNew()
    g_currentMission.TheContractor.AuctionSale = client
    -- On a client.
    local isServer = g_currentMission.getIsServer
    g_currentMission.getIsServer = function() return false end
    received:readStream(stream, { getIsServer = function() return true end })
    g_currentMission.getIsServer = isServer
    assertEquals(client:getFarmBid(35, 1).amount, 9500)
    assertEquals(client:getFarmBid(36, 2), nil, "never another farm's")

    local D = TheContractorAuctionSale.DISPLAY
    assertEquals(client:getDisplayState(site:getLot(35), 1), D.YOUR_BID)
    assertEquals(client:getDisplayState(site:getLot(37), 1), D.OPEN)
    assertEquals(client:getDisplayState(site:getLot(1), 1), D.CLOSED, "past its time, not settled yet")

    -- The server settles 35 and 36: farm 1 wins one and loses the other.
    g_currentMission.TheContractor.AuctionSale = sale
    g_currentMission.environment.currentMinute = 59
    sale:closeDue()
    g_currentMission.TheContractor.AuctionSale = client
    for _, lotNumber in ipairs({ 35, 36 }) do
        -- The lot's result, as every machine gets it.
        assertEquals(site:getLot(lotNumber).result ~= TheContractorAuctionSite.RESULT.OPEN, true)
    end
    local bidsStream = world:newStream()
    lastFarmEvent(world, 1):writeStream(bidsStream)
    g_currentMission.getIsServer = function() return false end
    TCAuctionBidsEvent.emptyNew():readStream(bidsStream, { getIsServer = function() return true end })
    g_currentMission.getIsServer = isServer
    assertEquals(client:getDisplayState(site:getLot(35), 1), D.WON)
    assertEquals(client:getDisplayState(site:getLot(36), 1), D.OUTBID)
    assertEquals(client:getDisplayState(site:getLot(36), 3), D.SOLD, "a farm that didn't bid sees it sold")
end)

-- The close -----------------------------------------------------------------------------------

test("lots close at their own times; a skip catches every one up", function()
    local world, sale = setup()
    local lots = addLots(world, 60)
    g_currentMission.environment.currentMinute = 10
    sale:closeDue()
    assertEquals(lots[11].soldTo, 0, "17:10's lot")
    assertEquals(lots[12].soldTo, nil, "17:11's still open")

    g_currentMission.environment.currentMonotonicDay = 41
    g_currentMission.environment.currentHour, g_currentMission.environment.currentMinute = 3, 0
    sale:closeDue()
    for _, lot in ipairs(lots) do
        assertTrue(lot.soldTo ~= nil, "lot " .. lot.number .. " closed after the skip")
    end
end)

test("the console's site has no sale: its lots never close", function()
    local world, sale = setup()
    local lots = addLots(world, 3)
    world.auction = nil
    sale:closeDue()
    assertEquals(lots[1].soldTo, nil)
end)

test("the winner pays their bid, gets the machine unlocked, and a company gets the message", function()
    local world, sale, site = setup()
    local lots = addLots(world, 40, { [35] = rollFor(0.9) })
    sale:placeBid(1, 35, 9600)
    sale:placeBid(2, 35, 9400)
    sale:closeLot(lots[35])

    assertEquals(lots[35].soldTo, 1)
    assertEquals(#world.money, 1, "paid once")
    assertEquals(world.money[1].amount, -9600, "what they bid, no premium")
    assertEquals(world.money[1].farmId, 1)
    assertEquals(world.money[1].moneyType, MoneyType.TC_AUCTION_PURCHASE)
    local vehicle = NetworkUtil.getObject(lots[35].vehicleId)
    assertEquals(vehicle.farmId, 1, "the farm's machine now")
    assertTrue(not site:isLot(vehicle), "off the lock")
    assertEquals(site:getLot(35).result, TheContractorAuctionSite.RESULT.FARM, "everyone sees it sold")

    local messages = g_currentMission.TheContractor.Inbox:getMessages(1)
    assertEquals(#messages, 1)
    assertEquals(messages[1].kind, TheContractorAuctionSale.MESSAGE_KIND)
    assertEquals(messages[1].args[3], "$money_9600")
    assertEquals(#g_currentMission.TheContractor.Inbox:getMessages(2), 0)

    local outcome = lastFarmEvent(world, 1).outcomes[1]
    assertEquals(outcome.outcome, TheContractorAuctionSale.OUTCOME.WON)
    assertEquals(lastFarmEvent(world, 2).outcomes[1].outcome, TheContractorAuctionSale.OUTCOME.LOST)
end)

test("a winner without a company is told but gets no message; a bid under the room loses", function()
    local world, sale = setup()
    local lots = addLots(world, 40, { [35] = rollFor(0.9), [36] = rollFor(0.9) })
    world.companies = {}
    sale:placeBid(3, 35, 9100)
    sale:placeBid(3, 36, 8900)
    sale:closeLot(lots[35])
    sale:closeLot(lots[36])
    assertEquals(lots[35].soldTo, 3)
    assertEquals(lots[36].soldTo, 0, "a local buyer")
    assertEquals(#g_currentMission.TheContractor.Inbox:getMessages(3), 0)
    assertEquals(sale:getFarmBid(36, 3).outcome, TheContractorAuctionSale.OUTCOME.LOST)
end)

test("a farm that can't pay loses the lot to the next and pays a fee", function()
    local world, sale = setup()
    local lots = addLots(world, 40, { [35] = rollFor(0.9) })
    world.balances[1] = 5000
    sale:placeBid(1, 35, 12000)
    sale:placeBid(2, 35, 9500)
    sale:closeLot(lots[35])
    assertEquals(lots[35].soldTo, 2)
    assertEquals(sale:getFarmBid(35, 1).outcome, TheContractorAuctionSale.OUTCOME.UNPAID)
    local fee = TheContractorAuctionSale.UNPAID_FEE * 2
    assertEquals(sale:getFarmBid(35, 1).fee, fee, "a fixed business cost, through scaleCost")
    assertEquals(world.balances[1], 5000 - fee)
    assertEquals(world.balances[2], 1000000 - 9500)
end)

-- After the sale ------------------------------------------------------------------------------

test("the local buyers' lots go at the first midnight; won lots stay for collection", function()
    local world, sale, site = setup()
    local lots = addLots(world, 3, { rollFor(0.9), rollFor(0.9), rollFor(0.9) })
    g_currentMission.environment.currentHour = 16
    assertEquals(sale:placeBid(1, 1, 9500), nil)
    sale:closeDue(true)
    local won = NetworkUtil.getObject(lots[1].vehicleId)
    local unsold = NetworkUtil.getObject(lots[2].vehicleId)
    site:removeUnsold()
    assertTrue(unsold.isDeleted)
    assertEquals(lots[2].vehicleId, nil)
    assertTrue(not won.isDeleted)
    assertEquals(#site:getLots(), 3, "still listed, as sold")
    assertEquals(site:getLot(2).vehicleId, nil, "no View lot prompt on a vehicle that's gone")
    assertEquals(site:getLotVehicleIds()[won.id], nil)

    -- The site cleared at the end never deletes a farm's machine.
    site:clear()
    assertTrue(not won.isDeleted)
end)

test("a won lot left on the field goes into the farm's parking at the end, free; one driven away stays put", function()
    local world, sale = setup()
    local lots = addLots(world, 3, { rollFor(0.9), rollFor(0.9), rollFor(0.9) })
    g_currentMission.environment.currentHour = 16
    assertEquals(sale:placeBid(1, 1, 9500), nil)
    sale:placeBid(2, 2, 9500)
    sale:closeDue(true)
    local left = NetworkUtil.getObject(lots[1].vehicleId)
    local driven = NetworkUtil.getObject(lots[2].vehicleId)
    driven.x, driven.z = 500, 500
    world.money = {}
    sale:finish(3)
    assertEquals(#world.placed, 1)
    assertEquals(world.placed[1].vehicle, left)
    assertEquals(world.placed[1].x, 1000, "a parking slot")
    assertEquals(world.unhitched[1], left.id, "unhitched first")
    assertEquals(driven.x, 500, "the one driven away isn't touched")
    assertEquals(#world.returned, 0, "nothing left waiting")
    assertEquals(#world.money, 0, "no charge")
    assertEquals(next(sale.bids), nil, "the bids go with the auction")
    assertEquals(#g_currentMission.TheContractor.Inbox:getMessages(1), 0, "and the won messages")
end)

test("no room in the farm's parking: to the shop; no room there either: it waits to be parked", function()
    local world, sale = setup()
    local lots = addLots(world, 40, { [35] = rollFor(0.9), [36] = rollFor(0.9) })
    local header = addMachine(world)
    lots[36].attachmentId, lots[36].attachmentXml = header.id, "header.xml"
    sale:placeBid(1, 35, 9500)
    sale:placeBid(1, 36, 9500)
    world.parkingRoom = 0
    world.shopRoom = 2
    sale:closeDue(true)
    sale:deliverWon()
    assertEquals(world.placed[1].x, 2000, "the shop")
    assertEquals(lastFarmEvent(world, 1).outcomes[1].outcome, TheContractorAuctionSale.DELIVERED_TO.WAITING,
        "lot 36's combine fitted at the shop, its header didn't")
    assertEquals(#world.returned, 1)
    assertEquals(world.returned[1].vehicleIds[1], header.id)
    local _, where = nil, TheContractorAuctionSale.deliver(1, {})
    assertEquals(where, TheContractorAuctionSale.DELIVERED_TO.PARKING, "nothing to place")
end)

test("calling it off sells nothing more", function()
    local world, sale = setup()
    local lots = addLots(world, 40, { [35] = rollFor(0.9) })
    sale:placeBid(1, 35, 9500)
    sale:finish(3, true)
    assertEquals(lots[35].soldTo, nil)
    assertEquals(#world.money, 0)
end)

-- Keeping -------------------------------------------------------------------------------------

test("bids and results survive a save mid-sale", function()
    local world, sale, site = setup()
    local lots = addLots(world, 40, { [35] = rollFor(0.9), [36] = 0.31 })
    sale:placeBid(1, 35, 9500)
    sale:placeBid(2, 36, 9000)
    sale:closeLot(lots[35])

    local xmlFile = {}
    sale:saveToXmlFile(xmlFile)
    site:saveToXmlFile(xmlFile)

    local loadedSale = TheContractorAuctionSale.new()
    loadedSale:loadFromXMLFile(xmlFile)
    assertEquals(loadedSale:getFarmBid(35, 1).outcome, TheContractorAuctionSale.OUTCOME.WON)
    assertEquals(loadedSale:getFarmBid(35, 1).paid, 9500)
    assertEquals(loadedSale:getFarmBid(36, 2).amount, 9000)
    assertEquals(loadedSale:getFarmBid(36, 2).order, sale:getFarmBid(36, 2).order)
    assertEquals(loadedSale.nextOrder, sale.nextOrder)

    local loadedSite = TheContractorAuctionSite.new()
    g_currentMission.TheContractor.AuctionSite = loadedSite
    loadedSite:loadFromXMLFile(xmlFile)
    loadedSite:resolveSavedVehicles()
    local byNumber = {}
    for _, lot in ipairs(loadedSite.site.lots) do
        byNumber[lot.number] = lot
    end
    assertEquals(byNumber[35].soldTo, 1)
    assertEquals(byNumber[35].salePrice, 9500)
    assertNear(byNumber[36].localRoll, 0.31, 0.0001, "the room's the same after a load")
    assertEquals(loadedSite:getLot(35).result, TheContractorAuctionSite.RESULT.FARM)
end)

test("the server never takes a farm's bids back from its own broadcast", function()
    local world, sale = setup()
    addLots(world, 40)
    sale:placeBid(1, 35, 9000)
    local order = sale:getFarmBid(35, 1).order
    local stream = world:newStream()
    lastFarmEvent(world, 1):writeStream(stream)
    TCAuctionBidsEvent.emptyNew():readStream(stream, { getIsServer = function() return true end })
    assertEquals(sale:getFarmBid(35, 1).order, order, "the tie order kept")
end)

test("a joining player gets their own farm's bids only", function()
    local world, sale = setup()
    addLots(world, 40)
    sale:placeBid(1, 35, 9000)
    sale:placeBid(2, 35, 9500)
    local connection = {}
    g_currentMission.userManager = {
        getUserByConnection = function(_, c) return c == connection and { getId = function() return 7 end } or nil end,
    }
    g_farmManager.getFarmByUserId = function(_, userId) return userId == 7 and { farmId = 2 } or nil end
    local stream = world:newStream()
    sale:writeInitialClientState(stream, connection)
    for _, value in ipairs(stream.values) do
        assertTrue(value ~= 9000, "farm 1's bid isn't sent to a farm-2 player")
    end
    local client = TheContractorAuctionSale.new()
    client:readInitialClientState(stream)
    assertEquals(client:getFarmBid(35, 2).amount, 9500)
    assertEquals(client:getFarmBid(35, 1), nil)
end)

test("a deleted farm's bids go, the others stay", function()
    local world, sale = setup()
    addLots(world, 40)
    sale:placeBid(1, 35, 9000)
    sale:placeBid(2, 35, 9500)
    sale:forgetFarm(1)
    assertEquals(sale:getFarmBid(35, 1), nil)
    assertEquals(sale:getFarmBid(35, 2).amount, 9500)
end)
