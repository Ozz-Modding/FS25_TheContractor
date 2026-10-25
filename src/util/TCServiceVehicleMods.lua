-- Service vehicle mods' workshops and customers' machines (100, 101).
-- Like vanilla's workshop, these only list a vehicle that shows in the
-- vehicles overview, and a customer's machine is MISSION, so it never does
-- (TheContractorRepairContracts.isWorkableVehicle). The only place this mod
-- touches their globals; each hook is nil-checked, so a mod that's changed
-- shape is just left alone.
--   - GtX's ServiceVehicle specialization (FS25_FST99Service, checked
--     against refs/): ServiceVehicleWorkshop:determineCurrentVehicles, the
--     machines in its trigger.
--   - Rockstar's FS25_mobileWorkshop (refs/): MobileWorkshop:getIsValidVehicle,
--     the machine the player's looking at.
-- Both open vanilla's WorkshopScreen as a mobile workshop, which ADS reads as
-- its own MOBILE type. They're found by their globals in every loaded mod's
-- environment, not by mod name, so a renamed zip or another pack with the
-- same script is covered too.

TCServiceVehicleMods = {}

-- Called every loadMap; the hooks are flagged on the table they wrap, so
-- each goes on once per game session.
function TCServiceVehicleMods.install()
    if g_modIsLoaded == nil then
        return
    end
    for modName, isLoaded in pairs(g_modIsLoaded) do
        local env = isLoaded and getfenv(0)[modName] or nil
        if type(env) == "table" then
            TCServiceVehicleMods.installServiceVehicle(env.ServiceVehicleWorkshop, modName)
            TCServiceVehicleMods.installMobileWorkshop(env.MobileWorkshop, modName)
        end
    end
end

function TCServiceVehicleMods.installServiceVehicle(workshopClass, modName)
    if type(workshopClass) ~= "table" or workshopClass.determineCurrentVehicles == nil or
            workshopClass.tcHookInstalled then
        return
    end
    workshopClass.determineCurrentVehicles = Utils.overwrittenFunction(
        workshopClass.determineCurrentVehicles, TCServiceVehicleMods.determineCurrentVehicles)
    workshopClass.tcHookInstalled = true
    Logging.info("TheContractor: service vehicle workshop found in %s", modName)
end

function TCServiceVehicleMods.installMobileWorkshop(mobileWorkshop, modName)
    if type(mobileWorkshop) ~= "table" or mobileWorkshop.getIsValidVehicle == nil or
            mobileWorkshop.tcHookInstalled then
        return
    end
    mobileWorkshop.getIsValidVehicle = Utils.overwrittenFunction(
        mobileWorkshop.getIsValidVehicle, TCServiceVehicleMods.getIsValidVehicle)
    mobileWorkshop.tcHookInstalled = true
    Logging.info("TheContractor: mobile workshop found in %s", modName)
end

-- The service vehicle's list is also its currentVehicles (shown on its info
-- board), and the empty list it built has already turned its info board and
-- trigger markers off, so those go back on if a customer's machine is all
-- that's there.
function TCServiceVehicleMods.determineCurrentVehicles(workshop, superFunc)
    local vehicles = superFunc(workshop)
    local hadVehicles = #vehicles > 0
    if TheContractorRepairContracts.addWorkableVehiclesInRange(vehicles, workshop.vehicleShapesInRange,
            g_currentMission:getFarmId()) then
        workshop.currentVehicles = vehicles
        if not hadVehicles then
            if workshop.infoTextsNode ~= nil then
                setVisibility(workshop.infoTextsNode, true)
            end
            if workshop.updateTriggerMarkers ~= nil then
                workshop:updateTriggerMarkers(true)
            end
        end
    end
    return vehicles
end

function TCServiceVehicleMods.getIsValidVehicle(mobileWorkshop, superFunc, vehicle, farmId)
    return superFunc(mobileWorkshop, vehicle, farmId) or
        TheContractorRepairContracts.isWorkableVehicle(vehicle, farmId)
end
