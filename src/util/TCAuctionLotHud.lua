-- The info box for an auction lot (152, after the first in-game try):
-- looking at a lot's machine (or the header in front of it) shows its box
-- as looking at any vehicle does, with the lot's number and guide price.
--
-- Vanilla's PlayerHUDUpdater:showVehicleInfo skips any vehicle of farm 0
-- (FarmManager.SPECTATOR_FARM_ID), and lots are farm 0's until they're won
-- (135), so a lot gets no box at all. UEY does the same for its yard
-- machines: an appended update draws the object box itself. So does this,
-- for a vehicle in the site's lot set (AuctionSite:isLot, every machine
-- from the synced lots), so a won lot (the farm's own by then) gets
-- vanilla's box again. The vehicle's own lines (vehicle:showInfo: vanilla's
-- damage, fill levels) follow ours, as in vanilla's box; never ADS's
-- condition (099), which isn't among them.

TCAuctionLotHud = {}

-- The public lot whose machine or attachment this vehicle is, or nil.
function TCAuctionLotHud.findLot(vehicle)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    local site = tc ~= nil and tc.AuctionSite or nil
    if vehicle == nil or site == nil or not site:isLot(vehicle) then
        return nil
    end
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    for _, lot in ipairs(site:getLots()) do
        if lot.vehicleId == vehicleId or lot.attachmentId == vehicleId then
            return lot
        end
    end
    return nil
end

-- The lot's lines, { { labelKey, value } }: its number and guide price.
function TCAuctionLotHud.getLines(lot)
    return {
        { "tc_auctionLot_lot", tostring(lot.number) },
        { "tc_auctionLot_guide", g_i18n:formatMoney(lot.guidePrice or 0, 0, true, true) },
    }
end

-- Appended to PlayerHUDUpdater.update (every frame the player's on foot).
function TCAuctionLotHud.onUpdate(updater)
    if Platform == nil or Platform.playerInfo == nil or not Platform.playerInfo.showVehicleInfo or
            not updater.isVehicle or updater.object == nil or updater.objectBox == nil then
        return
    end
    local vehicle = updater.object
    local lot = TCAuctionLotHud.findLot(vehicle)
    if lot == nil then
        return
    end
    local box = updater.objectBox
    box:clear()
    box:setTitle(vehicle:getFullName())
    for _, line in ipairs(TCAuctionLotHud.getLines(lot)) do
        box:addLine(g_i18n:getText(line[1]), line[2])
    end
    if vehicle.showInfo ~= nil then
        vehicle:showInfo(box)
    end
    box:showNextFrame()
end

if PlayerHUDUpdater ~= nil and PlayerHUDUpdater.update ~= nil then
    PlayerHUDUpdater.update = Utils.appendedFunction(PlayerHUDUpdater.update, TCAuctionLotHud.onUpdate)
end
