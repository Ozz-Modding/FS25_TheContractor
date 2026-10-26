-- AutoDrive hooks for 037's staff drivers (see TheContractorDrivers).
-- Installed only if FS25_AutoDrive is loaded, and the only place this mod
-- touches AutoDrive's globals. Against AutoDrive 3.0.1.2 (refs/).
--
-- AD has no "hire a driver" dialog: its HUD button, keybind and the HUD
-- drawn over the map all go through ADInputManager:onInputCall on the
-- client, which sends AutoDriveInputEventEvent to the server to actually
-- start. That's the client gate - a table method, so wrapping it reaches
-- every caller. Spec event listeners (AutoDrive.onUpdateTick) are looked up
-- on every raiseEvent, so wrapping that works too: it's the server safety
-- net (stops AD on a vehicle that mustn't be driven - autostartHelpers with
-- no saved driver, the external StartDriving API, anything else that skips
-- the picker) and where the wage is skipped for a staff driver, by making
-- AutoDrive.getSetting("driverWages") read 0 for the length of that one
-- vehicle's tick. AD's own setting is never changed.

TCAutoDrive = {}

TCAutoDrive.MOD_NAME = "FS25_AutoDrive"

-- Inputs that start AD driving the vehicle (each ends in input_start_stop
-- on the server). input_start_stop on an active vehicle is a stop - see
-- isStartingInput.
TCAutoDrive.STARTING_INPUTS = {
    input_start_stop = true,
    input_parkVehicle = true,
    input_refuelVehicle = true,
    input_repairVehicle = true,
}

local env = nil
-- True only while AutoDrive.onUpdateTick runs for a staff-driven vehicle.
local suppressWage = false

-- Called every loadMap; returns whether AutoDrive is loaded. The wraps are
-- flagged on AutoDrive's own table, so they go on once however many times
-- this runs, and call through to whatever TCAutoDrive is current.
function TCAutoDrive.install()
    env = TheContractorDrivers.getModEnv(TCAutoDrive.MOD_NAME)
    if env == nil or env.AutoDrive == nil or env.ADInputManager == nil then
        env = nil
        return false
    end

    local AutoDrive, ADInputManager = env.AutoDrive, env.ADInputManager
    if not AutoDrive.tcDriverHooksInstalled then
        ADInputManager.onInputCall = Utils.overwrittenFunction(ADInputManager.onInputCall, function(...)
            return TCAutoDrive.onInputCall(...)
        end)
        AutoDrive.onUpdateTick = Utils.overwrittenFunction(AutoDrive.onUpdateTick, function(...)
            return TCAutoDrive.onUpdateTick(...)
        end)
        AutoDrive.getSetting = Utils.overwrittenFunction(AutoDrive.getSetting, function(...)
            return TCAutoDrive.getSetting(...)
        end)
        AutoDrive.tcDriverHooksInstalled = true
    end

    TCLog.info("TheContractor: AutoDrive found - staff driver hooks installed")
    return true
end

function TCAutoDrive.isDriving(vehicle)
    return vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule:isActive()
end

-- Mirrors input_start_stop's own early-out (nothing recorded on the map,
-- or no destination picked), so the picker doesn't open for a start AD
-- would ignore anyway.
function TCAutoDrive.isStartingInput(vehicle, input)
    if not TCAutoDrive.STARTING_INPUTS[input] or vehicle.ad == nil or vehicle.ad.stateModule == nil then
        return false
    end

    if input == "input_start_stop" then
        if vehicle.ad.stateModule:isActive() then
            return false
        end
        if env.ADGraphManager ~= nil and env.ADGraphManager:getWayPointById(1) == nil then
            return false
        end
        if vehicle.ad.stateModule:getFirstMarker() == nil then
            return false
        end
    end

    return true
end

-- Client gate. sendEvent == false is the server running an input a client
-- already sent - that client's gate has been and gone.
function TCAutoDrive.onInputCall(manager, superFunc, vehicle, input, farmId, sendEvent)
    local drivers = TheContractorDrivers.getInstance()
    if drivers ~= nil and sendEvent ~= false and vehicle ~= nil and TCAutoDrive.isStartingInput(vehicle, input) then
        local handled = drivers:gateClientStart(vehicle, function()
            superFunc(manager, vehicle, input, farmId, sendEvent)
        end)
        if handled then
            return
        end
    end

    return superFunc(manager, vehicle, input, farmId, sendEvent)
end

-- Server safety net + wage skip, per vehicle per tick.
function TCAutoDrive.onUpdateTick(vehicle, superFunc, dt, ...)
    local drivers = TheContractorDrivers.getInstance()
    if drivers == nil or not vehicle.isServer or not TCAutoDrive.isDriving(vehicle) then
        return superFunc(vehicle, dt, ...)
    end

    local refusal = drivers:getServerStartRefusal(vehicle)
    if refusal ~= nil then
        TCLog.info("TheContractor: stopped AutoDrive on '%s' (%s)", vehicle:getFullName(), refusal)
        vehicle.ad.isStoppingWithError = true
        vehicle:stopAutoDrive()
        drivers:notify(vehicle:getOwnerFarmId(), refusal, vehicle)
        return superFunc(vehicle, dt, ...)
    end

    suppressWage = drivers:hasDriver(vehicle)
    superFunc(vehicle, dt, ...)
    suppressWage = false
end

function TCAutoDrive.getSetting(settingName, superFunc, vehicle)
    if suppressWage and settingName == "driverWages" then
        return 0
    end
    return superFunc(settingName, vehicle)
end
