-- Hides the vanilla Contracts menu tab and stops MissionManager from ever
-- generating/offering new vanilla missions, so TheContractor is the only
-- source of job offers.

TheContractorDisableVanillaContracts = {}

-- MissionManager is a shared class (not a per-savegame instance recreated on
-- loadMap), so patching the class method once here holds for the whole
-- process. NPC dialogue mission offers read from the same manager, so this
-- also covers those.
function MissionManager:getCanStartNewMissionGeneration()
    return false
end

-- The Contracts tab's enabling predicate is captured as a closure and stored
-- in g_inGameMenu.pageEnablingPredicates the first time the vanilla menu is
-- built (before this mod's source is guaranteed to be loaded), so overriding
-- the factory method alone would not affect an already-registered page.
-- Overwrite the stored predicate directly instead, and call this again from
-- loadMap so it re-applies even if the menu gets rebuilt across save/load.
function TheContractorDisableVanillaContracts.hideContractsTab()
    if g_inGameMenu == nil or g_inGameMenu.pageContracts == nil then
        return
    end

    g_inGameMenu.pageEnablingPredicates[g_inGameMenu.pageContracts] = function()
        return false
    end
end
