-- Real per-job fuel accounting (029): litres burned by a job's own
-- equipment once work has started, and what they cost, for the completion
-- summary.
--
-- Base game Motorized:updateConsumers (server-only, per vehicle per frame)
-- is where fuel is actually used. It batches usage into >1 l steps and
-- reports each step through g_farmManager:updateFarmStats(farmId,
-- "fuelUsage", litres) - but that call doesn't say which vehicle. So
-- updateConsumers is wrapped to remember the vehicle it's running for, and
-- updateFarmStats is wrapped to charge any "fuelUsage" step reported while
-- that's set to the vehicle's job. Reading fill-level deltas instead
-- wouldn't work: a hired helper with "helper buys fuel" on pays cash and
-- never draws the tank down, and refuelling mid-job would read as negative
-- use.
--
-- Priced as the base game charges it: diesel's current cost per litre,
-- times 1.5 while the AI is driving with "helper buys fuel" on (the
-- surcharge Motorized itself applies). Counts every consumer the base game
-- counts as fuel usage (so a little DEF, and electric/methane at the diesel
-- price) - close enough for a summary.
--
-- Hooks installed at source time, same as FS25_RedTape's specialization
-- overrides (e.g. DischargeableExtension), before vehicle types register
-- their functions.

TCJobFuel = {}

TCJobFuel.HELPER_FUEL_PRICE_MULTIPLIER = 1.5

local currentVehicle = nil

function TCJobFuel.updateConsumers(vehicle, superFunc, dt, accInput)
    currentVehicle = vehicle
    superFunc(vehicle, dt, accInput)
    currentVehicle = nil
end

function TCJobFuel.updateFarmStats(farmManager, superFunc, farmId, statName, delta)
    if statName == "fuelUsage" and currentVehicle ~= nil and delta ~= nil and delta > 0 then
        TCJobFuel.recordUsage(currentVehicle, delta)
    end
    return superFunc(farmManager, farmId, statName, delta)
end

function TCJobFuel.recordUsage(vehicle, liters)
    local mission = g_currentMission
    if mission == nil or mission.TheContractor == nil or mission.TheContractor.Jobs == nil or
        not mission:getIsServer() then
        return
    end

    local vehicleId = NetworkUtil.getObjectId(vehicle)
    if vehicleId == nil then
        return
    end

    local job = mission.TheContractor.Jobs:getWorkingJobForVehicle(vehicleId)
    if job == nil then
        return
    end

    local pricePerLiter = mission.economyManager:getCostPerLiter(FillType.DIESEL)
    if vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive() and mission.missionInfo.helperBuyFuel then
        pricePerLiter = pricePerLiter * TCJobFuel.HELPER_FUEL_PRICE_MULTIPLIER
    end

    job.fuelUsedLiters = job.fuelUsedLiters + liters
    job.fuelCost = job.fuelCost + liters * pricePerLiter
end

Motorized.updateConsumers = Utils.overwrittenFunction(Motorized.updateConsumers, TCJobFuel.updateConsumers)
FarmManager.updateFarmStats = Utils.overwrittenFunction(FarmManager.updateFarmStats, TCJobFuel.updateFarmStats)
