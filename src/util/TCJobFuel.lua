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
-- use. A player-driven job has no machines of ours, so a machine on no job
-- is charged to a player-driven job whose field it's on (getPlayerJobAt).
--
-- Priced as the base game charges it: diesel's current cost per litre,
-- times 1.5 while the AI is driving with "helper buys fuel" on (the
-- surcharge Motorized itself applies). Counts every consumer the base game
-- counts as fuel usage (so a little DEF, and electric/methane at the diesel
-- price) - close enough for a summary.
--
-- 063: a hired worker's machines run on the farm's own diesel
-- (TCJobSupplies tops their tanks up from stock), so "helper buys fuel" is
-- switched off around updateConsumers for them - they burn their tank, and
-- their fuel is priced without the surcharge. The trip to the field is
-- simulated, so burnTravelFuel takes a short drive's worth out of each
-- machine's tank as the worker sets off. So is a two-worker haulage job's
-- carting (035): burnCartingFuel takes a round trip's worth out of the
-- haulage rig's tank for each load (TCHaulage's auto-empty).
--
-- Hooks installed at source time, same as FS25_RedTape's specialization
-- overrides (e.g. DischargeableExtension), before vehicle types register
-- their functions.

TCJobFuel = {}

TCJobFuel.HELPER_FUEL_PRICE_MULTIPLIER = 1.5

-- 063: the trip there and back, as a drive of TRAVEL_MILES at
-- TRAVEL_SPEED_KMH with Motorized's usage factor at TRAVEL_LOAD (road
-- driving at part load). A 40 l/h tractor burns about 4 l on normal fuel
-- usage.
TCJobFuel.TRAVEL_MILES = 3
TCJobFuel.TRAVEL_SPEED_KMH = 30
TCJobFuel.TRAVEL_LOAD = 0.45
TCJobFuel.METERS_PER_MILE = 1609.344

-- A haulage job's round trip to the selling point and back with each load,
-- driven the same way as the trip out.
TCJobFuel.CARTING_MILES = 3

local currentVehicle = nil

function TCJobFuel.updateConsumers(vehicle, superFunc, dt, accInput)
    currentVehicle = vehicle
    local missionInfo = g_currentMission.missionInfo
    local helperBuyFuel = missionInfo.helperBuyFuel
    if helperBuyFuel and TCJobSupplies.isContractVehicle(vehicle) then
        missionInfo.helperBuyFuel = false
    end
    superFunc(vehicle, dt, accInput)
    missionInfo.helperBuyFuel = helperBuyFuel
    currentVehicle = nil
end

-- Motorized:updateConsumers' factor for the game's fuel usage setting.
local function getFuelUsageFactor()
    local fuelUsage = g_currentMission.missionInfo.fuelUsage
    if fuelUsage == 1 then
        return 1
    elseif fuelUsage == 3 then
        return 2.5
    end
    return 1.5
end

-- Takes a drive of `miles` out of each of these machines' diesel tanks
-- (never more than is in it), counted as the job's fuel. Returns true if a
-- tank ran dry.
local function burnDrive(job, vehicleIds, miles)
    local mission = g_currentMission
    local driveMs = miles * TCJobFuel.METERS_PER_MILE / (TCJobFuel.TRAVEL_SPEED_KMH / 3.6) * 1000
    local factor = getFuelUsageFactor() * TCJobFuel.TRAVEL_LOAD
    local ranDry = false

    for _, vehicleId in ipairs(vehicleIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        local consumer = vehicle ~= nil and TCJobSupplies.getDieselConsumer(vehicle) or nil
        if consumer ~= nil and consumer.permanentConsumption then
            local level = vehicle:getFillUnitFillLevel(consumer.fillUnitIndex)
            local liters = math.min(level, consumer.usage * factor * driveMs)
            if liters > 0 then
                vehicle:addFillUnitFillLevel(job.farmId, consumer.fillUnitIndex, -liters, consumer.fillType,
                    ToolType.UNDEFINED, nil)
                g_farmManager:updateFarmStats(job.farmId, "fuelUsage", liters)
                job.fuelUsedLiters = job.fuelUsedLiters + liters
                job.fuelCost = job.fuelCost + liters * mission.economyManager:getCostPerLiter(consumer.fillType)
            end
            if vehicle:getFillUnitFillLevel(consumer.fillUnitIndex) <= 0.001 then
                ranDry = true
            end
        end
    end

    return ranDry
end

-- Server-only, as a hired worker sets off: the trip's diesel out of every
-- machine on the job, the haulage rig's included. Returns true if a tank
-- ran dry.
function TCJobFuel.burnTravelFuel(job)
    return burnDrive(job, job:getAllEquipmentIds(), TCJobFuel.TRAVEL_MILES)
end

-- Server-only, as a two-worker haulage job's combine is emptied: one load's
-- round trip out of the haulage rig's tank. A tank it empties is refilled,
-- or the job held, by TCJobSupplies' next poll.
function TCJobFuel.burnCartingFuel(job)
    return burnDrive(job, job.haulageEquipmentIds, TCJobFuel.CARTING_MILES)
end

function TCJobFuel.updateFarmStats(farmManager, superFunc, farmId, statName, delta)
    if statName == "fuelUsage" and currentVehicle ~= nil and delta ~= nil and delta > 0 then
        TCJobFuel.recordUsage(currentVehicle, delta)
    end
    return superFunc(farmManager, farmId, statName, delta)
end

-- A player doing a job themselves has none of the job's machines listed on
-- it, so the machine burning the fuel is charged to its farm's
-- player-driven job (no hired worker, work started) whose field it's on -
-- driven by the player or a vanilla helper they started. Off the field
-- (the drive out, carting away) isn't counted, as the job's clock doesn't
-- count the drive out (029). A job with no field gets none.
function TCJobFuel.getPlayerJobAt(vehicle)
    local jobs = g_currentMission.TheContractor.Jobs
    if vehicle.rootNode == nil or vehicle.getOwnerFarmId == nil or jobs.getAllJobs == nil or
        (TheContractorRepairContracts ~= nil and TheContractorRepairContracts.isContractVehicle(vehicle)) then
        return nil
    end

    local x, _, z = getWorldTranslation(vehicle.rootNode)
    for _, job in ipairs(jobs:getAllJobs(vehicle:getOwnerFarmId())) do
        if job.assignedWorkerId == nil and job.workStartedAt ~= nil and
            (job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS) then
            local field = job.fieldId ~= nil and g_fieldManager:getFieldById(job.fieldId) or nil
            if field ~= nil and TCJoyriderRuts.isPointInside(x, z, TCJoyriderRuts.getFieldBoundary(field)) then
                return job
            end
        end
    end
    return nil
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
        job = TCJobFuel.getPlayerJobAt(vehicle)
    end
    if job == nil then
        return
    end

    -- The fuel it burns (FS25_RedDiesel's is cheaper).
    local consumer = TCJobSupplies.getDieselConsumer(vehicle)
    local pricePerLiter = mission.economyManager:getCostPerLiter(consumer ~= nil and consumer.fillType or
        FillType.DIESEL)
    if vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive() and mission.missionInfo.helperBuyFuel then
        pricePerLiter = pricePerLiter * TCJobFuel.HELPER_FUEL_PRICE_MULTIPLIER
    end

    job.fuelUsedLiters = job.fuelUsedLiters + liters
    job.fuelCost = job.fuelCost + liters * pricePerLiter
end

Motorized.updateConsumers = Utils.overwrittenFunction(Motorized.updateConsumers, TCJobFuel.updateConsumers)
FarmManager.updateFarmStats = Utils.overwrittenFunction(FarmManager.updateFarmStats, TCJobFuel.updateFarmStats)
