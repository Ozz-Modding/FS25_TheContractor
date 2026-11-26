-- 150: FS25_AdvancedDamageSystem's (ADS) AI worker refusal. With its
-- refusal setting on, ADS won't let an AI helper drive a machine whose
-- fluids, filters or grease points are past their limits: it stops the AI
-- job as it starts (a wrapped AIJob:canStartWork) and every few seconds
-- while it works (ADS_AIWorker.updateShift). A hired worker's machine it
-- would refuse can't be allocated, and a job ADS stops for it goes on hold
-- until the machine's serviced (TCJobSupplies' "needsService").
--
-- Read through ADS's own ADS_AIWorker.getRefusalReasons, found by name and
-- nil-checked: an ADS without it refuses nothing. Its consumable state is
-- streamed, so clients (the allocation picker) get the same answer.
--
-- A breakdown is the other half: some of ADS's faults (a burst hydraulic
-- hose, a failed wiring harness, ...) carry an effect marked disableAi, and
-- ADS stops any AI on the machine while one's active, whatever the refusal
-- setting (ADS_VehiclePerformance.syncDisableAiWorkers), with vanilla's
-- AIMessageErrorVehicleBroken. Such a machine is held the same way, as
-- needing a repair ("needsRepair") rather than a service. Read the way
-- ADS reads it itself (its EffectRegistry through resolveEffect), nil-
-- checked; its breakdowns are streamed too.

TCADSWorkerRefusal = {}

TCADSWorkerRefusal.MOD_NAME = "FS25_AdvancedDamageSystem"

-- A reason ADS's self-service (on by default) clears itself before it
-- judges: the worker greases the low points (ADS_AIWorker.runShiftCheck).
TCADSWorkerRefusal.SELF_SERVICED_OPERATION = "lubricate"

-- The ADS mod environment, or nil when it isn't loaded. A function so the
-- tests can swap it.
function TCADSWorkerRefusal.getEnv()
    return TheContractorDrivers.getModEnv(TCADSWorkerRefusal.MOD_NAME)
end

local function getAIWorker()
    local env = TCADSWorkerRefusal.getEnv()
    local aiWorker = env ~= nil and env.ADS_AIWorker or nil
    if type(aiWorker) ~= "table" or type(aiWorker.isRefusalEnabled) ~= "function" or
        type(aiWorker.getRefusalReasons) ~= "function" then
        return nil
    end
    return aiWorker
end

local function isADSVehicle(vehicle)
    return vehicle ~= nil and vehicle.spec_AdvancedDamageSystem ~= nil and
        not (vehicle.getIsADSExcluded ~= nil and vehicle:getIsADSExcluded())
end

-- Whether ADS's consumables refusal would stop a hired worker's AI driving
-- this vehicle until it's serviced.
function TCADSWorkerRefusal.needsService(vehicle)
    local aiWorker = getAIWorker()
    if aiWorker == nil or not isADSVehicle(vehicle) or not aiWorker.isRefusalEnabled() then
        return false
    end
    local selfService = type(aiWorker.isSelfServiceEnabled) == "function" and aiWorker.isSelfServiceEnabled()
    for _, reason in ipairs(aiWorker.getRefusalReasons(vehicle) or {}) do
        if not (selfService and reason.operation == TCADSWorkerRefusal.SELF_SERVICED_OPERATION) then
            return true
        end
    end
    return false
end

-- Whether the vehicle has an ADS breakdown that stops any AI on it until
-- it's repaired.
function TCADSWorkerRefusal.isBrokenDown(vehicle)
    local env = TCADSWorkerRefusal.getEnv()
    local performance = env ~= nil and env.ADS_VehiclePerformance or nil
    if type(performance) ~= "table" or type(performance.EffectRegistry) ~= "table" or
        type(performance.resolveEffect) ~= "function" or not isADSVehicle(vehicle) then
        return false
    end
    for effectId in pairs(performance.EffectRegistry) do
        local effect = performance.resolveEffect(vehicle, effectId)
        if type(effect) == "table" and type(effect.metadata) == "table" and effect.metadata.disableAi then
            return true
        end
    end
    return false
end

-- The hold (TCJobSupplies.STATUS) ADS's state puts a hired worker's job on
-- for this vehicle: "needsRepair" for a breakdown, "needsService" for the
-- consumables refusal, or nil when ADS would let the worker drive it.
function TCADSWorkerRefusal.getHoldStatus(vehicle)
    if TCADSWorkerRefusal.isBrokenDown(vehicle) then
        return TCJobSupplies.STATUS.NEEDS_REPAIR
    end
    if TCADSWorkerRefusal.needsService(vehicle) then
        return TCJobSupplies.STATUS.NEEDS_SERVICE
    end
    return nil
end

-- Whether ADS would stop a hired worker's AI driving this vehicle, for
-- either reason.
function TCADSWorkerRefusal.isRefused(vehicle)
    return TCADSWorkerRefusal.getHoldStatus(vehicle) ~= nil
end

-- Whether a job's supply status is one of these holds.
function TCADSWorkerRefusal.isHoldStatus(status)
    return status ~= nil and
        (status == TCJobSupplies.STATUS.NEEDS_SERVICE or status == TCJobSupplies.STATUS.NEEDS_REPAIR)
end

-- The first of these vehicles (network ids) ADS would refuse and the hold
-- it means, or nil.
function TCADSWorkerRefusal.getRefusedVehicle(vehicleIds)
    for _, vehicleId in ipairs(vehicleIds or {}) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        local status = TCADSWorkerRefusal.getHoldStatus(vehicle)
        if status ~= nil then
            return vehicle, status
        end
    end
    return nil
end

local function isMessageOf(aiMessage, messageClass)
    return messageClass ~= nil and aiMessage ~= nil and aiMessage.isa ~= nil and aiMessage:isa(messageClass) == true
end

-- Whether an AI job's stop message is ADS stopping it for one of these
-- vehicles (network ids): its refusal, or vanilla's "vehicle is broken"
-- while one of them has an AI-stopping breakdown.
function TCADSWorkerRefusal.isRefusalMessage(aiMessage, vehicleIds)
    local env = TCADSWorkerRefusal.getEnv()
    if isMessageOf(aiMessage, env ~= nil and env.ADS_AIMessageErrorPoorMaintenance or nil) then
        return true
    end
    if not isMessageOf(aiMessage, AIMessageErrorVehicleBroken) then
        return false
    end
    for _, vehicleId in ipairs(vehicleIds or {}) do
        if TCADSWorkerRefusal.isBrokenDown(NetworkUtil.getObject(vehicleId)) then
            return true
        end
    end
    return false
end
