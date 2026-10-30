-- The map's farmer yard button (117): a farmland's box on the in-game map
-- gets "Set as farmer yard", or "Unset as farmer yard" when it's a yard
-- (detected or declared), so a player who's edited the map can put right
-- what 108's detection found without the console.
--
-- Like FieldRename (refs/) it's one more entry in the map frame's
-- contextActions, added once the frame has its actions and switched on in
-- setMapInputContext, which vanilla calls every time a hotspot is picked
-- (and only sets selectedFarmland for a farmland's). It's a list in the
-- box, so a gamepad reaches it as it does Buy and Sell.
--
-- Overrides are server-wide (farmers are shared), so only the host or an
-- admin sees it, as with the settings (048). It isn't shown on land a
-- player owns, which is never a farmer's yard. A click asks the server
-- (TCYardOverrideEvent), which sets the override tcCompany yard would:
-- only where it differs from detection (TheContractorYards.getModeFor).
-- The button's text follows when the change comes back (refresh, from
-- TheContractorYards:applyOverride).

TCYardMapAction = {}

-- The live map frame and our entry in its contextActions.
TCYardMapAction.frame = nil
TCYardMapAction.action = nil

local function getYards()
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    return tc ~= nil and tc.Yards or nil
end

-- Switches the action on for a picked farmland the local player may
-- change, with the text for which way it would turn it.
function TCYardMapAction.update(frame)
    local action = TCYardMapAction.action
    if action == nil or frame ~= TCYardMapAction.frame then
        return
    end
    local yards = getYards()
    local farmland = frame.selectedFarmland
    action.isActive = false
    if yards == nil or farmland == nil or not TheContractorSettings.getCanLocalPlayerChange() then
        return
    end
    -- Land a player owns is never a farmer's yard (TheContractorFarmerSplit.getFreeYards).
    if g_farmlandManager:getFarmlandOwner(farmland.id) ~= FarmlandManager.NO_OWNER_FARM_ID then
        return
    end
    local isYard = yards:getToggle(farmland.id)
    action.title = g_i18n:getText(isYard and "tc_yard_mapUnset" or "tc_yard_mapSet")
    action.isActive = true
end

function TCYardMapAction.onClick(frame)
    local yards = getYards()
    local farmland = frame ~= nil and frame.selectedFarmland or nil
    if yards == nil or farmland == nil then
        return true
    end
    local _, mode = yards:getToggle(farmland.id)
    TCYardMapAction.request(farmland.id, mode)
    return true
end

-- Asks the server to set a farmland's override.
function TCYardMapAction.request(farmlandId, mode)
    TCLog.info("TheContractor: asking for farmland %d's yard override %s", farmlandId,
        TheContractorYards.MODE_NAMES[mode] or "?")
    TCYardOverrideEvent.sendRequest(farmlandId, mode)
end

-- An override changed (any machine): the open farmland box shows the new
-- text.
function TCYardMapAction.refresh()
    local frame = TCYardMapAction.frame
    if frame == nil or frame.selectedFarmland == nil or frame.contextButtonListFarmland == nil then
        return
    end
    TCYardMapAction.update(frame)
    frame.contextButtonListFarmland:reloadData()
end

function TCYardMapAction.onLoadMapFinished(frame)
    if frame.contextActions == nil then
        return
    end
    local action = {
        title = g_i18n:getText("tc_yard_mapSet"),
        callback = TCYardMapAction.onClick,
        isActive = false,
    }
    table.insert(frame.contextActions, action)
    TCYardMapAction.frame = frame
    TCYardMapAction.action = action
end

InGameMenuMapFrame.onLoadMapFinished = Utils.appendedFunction(InGameMenuMapFrame.onLoadMapFinished,
    TCYardMapAction.onLoadMapFinished)
InGameMenuMapFrame.setMapInputContext = Utils.appendedFunction(InGameMenuMapFrame.setMapInputContext,
    TCYardMapAction.update)
