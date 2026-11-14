-- The info box for an auction lot: vanilla skips farm 0's vehicles, so
-- looking at a lot's machine (or its header) draws the box itself: the
-- lot's number and guide price, then the vehicle's own lines. Nothing for
-- a vehicle that isn't a lot, a lot that's been won, or with vehicle info
-- turned off. The real TCAuctionLotHud; the site, the HUD box and vanilla's
-- updater faked.

local function setup()
    local world = stubs.install()
    -- Vanilla's updater, before our hook's appended at load.
    world.vanillaUpdates = 0
    PlayerHUDUpdater = { update = function() world.vanillaUpdates = world.vanillaUpdates + 1 end }
    Platform = { playerInfo = { showVehicleInfo = true } }
    world:load("src/util/TCAuctionLotHud.lua")

    world.lots = {}
    g_currentMission.TheContractor.AuctionSite = {
        getLots = function() return world.lots end,
        isLot = function(_, vehicle)
            local id = NetworkUtil.getObjectId(vehicle)
            for _, lot in ipairs(world.lots) do
                if lot.result ~= 2 and (lot.vehicleId == id or lot.attachmentId == id) then
                    return true
                end
            end
            return false
        end,
    }

    world.box = { lines = {} }
    function world.box:clear() self.lines, self.title, self.shown = {}, nil, false end
    function world.box:setTitle(title) self.title = title end
    function world.box:addLine(label, value) table.insert(self.lines, { label = label, value = value }) end
    function world.box:showNextFrame() self.shown = true end
    world.updater = { isVehicle = true, objectBox = world.box }
    return world
end

local function addVehicle(world, name)
    local vehicle = world:addVehicle({ name = name, farmId = 0 })
    function vehicle:getFullName() return self.name end
    function vehicle:showInfo(box) box:addLine("own", "line") end
    return vehicle
end

local function look(world, vehicle)
    world.updater.object = vehicle
    world.box:clear()
    PlayerHUDUpdater.update(world.updater, 16)
end

test("a lot's machine shows its box: the lot and guide price, then the vehicle's own lines", function()
    local world = setup()
    local tractor = addVehicle(world, "Fendt 724")
    table.insert(world.lots, { number = 12, vehicleId = tractor.id, guidePrice = 45000 })

    look(world, tractor)
    assertEquals(world.vanillaUpdates, 1, "vanilla's update still runs first")
    assertTrue(world.box.shown)
    assertEquals(world.box.title, "Fendt 724")
    assertEquals(#world.box.lines, 3)
    assertEquals(world.box.lines[1].value, "12")
    assertEquals(world.box.lines[3].value, "line", "the vehicle's own lines last")

    local lines = TCAuctionLotHud.getLines(world.lots[1])
    assertEquals(lines[1][1], "tc_auctionLot_lot")
    assertEquals(lines[1][2], "12")
    assertEquals(lines[2][1], "tc_auctionLot_guide")
end)

test("a combine's header finds its lot", function()
    local world = setup()
    local combine = addVehicle(world, "Combine")
    local header = addVehicle(world, "Header")
    table.insert(world.lots, { number = 3, vehicleId = combine.id, attachmentId = header.id, guidePrice = 90000 })
    look(world, header)
    assertTrue(world.box.shown)
    assertEquals(world.box.lines[1].value, "3")
end)

test("nothing for a vehicle that isn't a lot, a won lot, or with vehicle info off", function()
    local world = setup()
    local other = addVehicle(world, "Other")
    look(world, other)
    assertTrue(not world.box.shown, "not a lot")

    local won = addVehicle(world, "Won")
    table.insert(world.lots, { number = 4, vehicleId = won.id, guidePrice = 1000, result = 2 })
    look(world, won)
    assertTrue(not world.box.shown, "won: the farm's own, vanilla's box again")

    local lot = addVehicle(world, "Lot")
    table.insert(world.lots, { number = 5, vehicleId = lot.id, guidePrice = 1000 })
    Platform.playerInfo.showVehicleInfo = false
    look(world, lot)
    assertTrue(not world.box.shown, "vehicle info off")
    Platform.playerInfo.showVehicleInfo = true
    world.updater.isVehicle = false
    look(world, lot)
    assertTrue(not world.box.shown, "not looking at a vehicle")
end)
