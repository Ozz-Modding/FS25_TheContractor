-- 185: with the mod in, no AI helper ever buys anything as it works.
-- Vanilla's game settings "helper buys fuel / seeds / fertilizer" and the
-- slurry and manure sources' "Buy" let a helper pay for its product instead
-- of using its tank, which would sidestep the farm's stock (032, 063). So
-- they're always off, for every helper, job or not (the user's call):
--
-- - FSBaseMission's setters refuse "buy", on every machine, whoever calls
--   them (the settings page, SavegameSettingsEvent, another mod), so a
--   setting can't be switched back on. A slurry or manure source that's
--   one of the farm's own loading stations isn't buying, and stays allowed.
-- - At mission start the server switches off whatever the save had on,
--   through those setters, so clients are told (SavegameSettingsEvent).
-- - The three buy switches are greyed out on the settings page.
--
-- The per-vehicle guards in TCJobSupplies (032) and TCJobFuel (063) stay,
-- in case another mod writes missionInfo directly.

TCNoHelperBuying = {}

-- Vanilla's slurry/manure source values: 1 none, 2 buy, 3+ a loading
-- station (FSBaseMission:setHelperSlurrySource).
TCNoHelperBuying.SOURCE_NONE = 1
TCNoHelperBuying.SOURCE_BUY = 2

local function refuseBuying(mission, superFunc, _, noEventSend)
    return superFunc(mission, false, noEventSend)
end

FSBaseMission.setHelperBuyFuel = Utils.overwrittenFunction(FSBaseMission.setHelperBuyFuel, refuseBuying)
FSBaseMission.setHelperBuySeeds = Utils.overwrittenFunction(FSBaseMission.setHelperBuySeeds, refuseBuying)
FSBaseMission.setHelperBuyFertilizer = Utils.overwrittenFunction(FSBaseMission.setHelperBuyFertilizer, refuseBuying)

-- The settings page shows the source it just picked; put it back to what
-- it really is.
local function showSource(elementName, source)
    local page = g_inGameMenu ~= nil and g_inGameMenu.pageSettings or nil
    local element = page ~= nil and page[elementName] or nil
    if element ~= nil and element.setState ~= nil then
        element:setState(source)
    end
end

function TCNoHelperBuying.getAllowedSource(source)
    if source == TCNoHelperBuying.SOURCE_BUY then
        return TCNoHelperBuying.SOURCE_NONE
    end
    return source
end

FSBaseMission.setHelperSlurrySource = Utils.overwrittenFunction(FSBaseMission.setHelperSlurrySource,
    function(mission, superFunc, source, noEventSend)
        local allowed = TCNoHelperBuying.getAllowedSource(source)
        superFunc(mission, allowed, noEventSend)
        if allowed ~= source then
            showSource("multiHelperRefillSlurry", allowed)
        end
    end)

FSBaseMission.setHelperManureSource = Utils.overwrittenFunction(FSBaseMission.setHelperManureSource,
    function(mission, superFunc, source, noEventSend)
        local allowed = TCNoHelperBuying.getAllowedSource(source)
        superFunc(mission, allowed, noEventSend)
        if allowed ~= source then
            showSource("multiHelperRefillManure", allowed)
        end
    end)

-- Server, at mission start: whatever the save had on goes off.
function TCNoHelperBuying.apply()
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer() or mission.missionInfo == nil then
        return
    end
    local missionInfo = mission.missionInfo
    if missionInfo.helperBuyFuel or missionInfo.helperBuySeeds or missionInfo.helperBuyFertilizer or
        missionInfo.helperSlurrySource == TCNoHelperBuying.SOURCE_BUY or
        missionInfo.helperManureSource == TCNoHelperBuying.SOURCE_BUY then
        TCLog.info("TheContractor: switching off the game's helper buying settings")
    end
    mission:setHelperBuyFuel(false)
    mission:setHelperBuySeeds(false)
    mission:setHelperBuyFertilizer(false)
    mission:setHelperSlurrySource(TCNoHelperBuying.getAllowedSource(missionInfo.helperSlurrySource))
    mission:setHelperManureSource(TCNoHelperBuying.getAllowedSource(missionInfo.helperManureSource))
end

-- The buy switches greyed out (shown off) whenever the page fills them in.
-- Looked up on the class when the page calls self:updateGameSettings().
if InGameMenuSettingsFrame ~= nil and InGameMenuSettingsFrame.updateGameSettings ~= nil then
    InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(InGameMenuSettingsFrame.updateGameSettings,
        function(frame)
            for _, name in ipairs({ "checkHelperRefillFuel", "checkHelperRefillSeed", "checkHelperRefillFertilizer" }) do
                local element = frame[name]
                if element ~= nil and element.setDisabled ~= nil then
                    element:setDisabled(true)
                end
            end
        end)
end
