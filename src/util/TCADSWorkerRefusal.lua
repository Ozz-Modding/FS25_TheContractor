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

-- Whether ADS would refuse to let a hired worker's AI drive this vehicle.
function TCADSWorkerRefusal.isRefused(vehicle)
    local aiWorker = getAIWorker()
    if aiWorker == nil or vehicle == nil or vehicle.spec_AdvancedDamageSystem == nil or
        not aiWorker.isRefusalEnabled() then
        return false
    end
    if vehicle.getIsADSExcluded ~= nil and vehicle:getIsADSExcluded() then
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

-- The first of these vehicles (network ids) ADS would refuse, or nil.
function TCADSWorkerRefusal.getRefusedVehicle(vehicleIds)
    for _, vehicleId in ipairs(vehicleIds or {}) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if TCADSWorkerRefusal.isRefused(vehicle) then
            return vehicle
        end
    end
    return nil
end

-- Whether an AI job's stop message is ADS's refusal.
function TCADSWorkerRefusal.isRefusalMessage(aiMessage)
    local env = TCADSWorkerRefusal.getEnv()
    local messageClass = env ~= nil and env.ADS_AIMessageErrorPoorMaintenance or nil
    return messageClass ~= nil and aiMessage ~= nil and aiMessage.isa ~= nil and aiMessage:isa(messageClass) == true
end
