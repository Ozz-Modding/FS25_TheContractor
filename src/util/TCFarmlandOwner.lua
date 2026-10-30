-- Field info's "Owned by" names our farmer (110), not the map's NPC.
--
-- Vanilla's field info box (PlayerHUDUpdater:fieldAddFarmland), the map's
-- field panel (InGameMenuMapFrame:updateFieldInfoBox) and Precision
-- Farming's copy of it all name land nobody owns with
-- farmland:getNPC().title. So getNPC answers, for land one of our farmers
-- holds, with a stand-in that has the farmer's name as its title and the
-- NPC's everything else. Land no farmer holds (or before the farmers are
-- made) keeps the NPC.
--
-- The stand-in isn't the NPC itself, so anything comparing NPCs by
-- identity would miss it; the only such callers are vanilla's contracts,
-- which the mod disables. Farmers are on every machine (TCFarmerLandEvent,
-- renames through TCEditPersonEvent), so the name is right on clients.

TCFarmlandOwner = {}

-- Stands in for the NPC of land the map gave none.
TCFarmlandOwner.NO_NPC = {}

-- npc -> name -> stand-in. One NPC can own land several farmers hold, and
-- the HUD asks every frame, so they're kept rather than made each time.
TCFarmlandOwner.standIns = setmetatable({}, { __mode = "k" })

function TCFarmlandOwner.getStandIn(npc, name)
    local byName = TCFarmlandOwner.standIns[npc]
    if byName == nil then
        byName = {}
        TCFarmlandOwner.standIns[npc] = byName
    end
    if byName[name] == nil then
        byName[name] = setmetatable({ title = name }, { __index = npc })
    end
    return byName[name]
end

function TCFarmlandOwner.getNPC(farmland, superFunc)
    local npc = superFunc(farmland)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    if tc == nil or tc.Farmers == nil then
        return npc
    end

    local holder = tc.Farmers:getHolder(farmland:getId())
    if holder == nil or holder.name == nil or holder.name == "" then
        return npc
    end
    -- Land the map gave no NPC would say "Unknown": the name alone will do.
    return TCFarmlandOwner.getStandIn(npc or TCFarmlandOwner.NO_NPC, holder.name)
end

Farmland.getNPC = Utils.overwrittenFunction(Farmland.getNPC, TCFarmlandOwner.getNPC)
