-- Job supplies (032): the seed, fertilizer, herbicide and bale net/twine/
-- wrap film a job's equipment uses up. The contractor supplies them, out of
-- the farm's own stock - nothing is conjured up or paid for on the side:
--
--   stock     what the farm owns, wherever it's kept: any storage it owns
--             (silos, storage tanks, silo extensions, husbandry and manure
--             heap storage - everything the storage system knows about),
--             plus its pallets, big bags and liquid tanks (pallet
--             vehicles). The same places FS25_TSStockCheck counts.
--   tanks     the fill units on the job's equipment that the work draws
--             from: a seeder's seed hopper, or the separate seed tank
--             (front hopper) feeding a seeder that has none of its own
--             (TCEquipmentClass.isSeedTank), a sprayer's tank (taking one of
--             the job's products - JOB_TYPES' supplyFillTypeNames), and any
--             consumable holder (Consumable spec - a baler's net/twine, a
--             wrapper's film) on the job's implement.
--
-- Tanks are topped up from stock (topUp): as a hired worker sets off,
-- which adds loading time to their trip (Dispatch's "supplies" transport
-- factor); at allocation for a player-driven job; and while the job's being
-- worked, whenever a tank drops below REFILL_RATIO (a player-driven job's
-- equipment only while it's on the job's farmland, so it's never touched
-- working the player's own fields).
--
-- A job goes on hold (job.supplyStatus, synced) when a tank is empty and
-- the farm has nothing left to fill it from ("noStock"), or a tank holds
-- something that isn't one of the job's products ("wrongFill" - herbicide
-- in the sprayer on a fertilizing job). A hired worker waits - in the yard
-- if they hadn't set off, or stopped on the field if they had - and carries
-- on by themselves once the farm restocks; a player-driven job just shows
-- the status. Server-only apart from that status.

TCJobSupplies = {}

-- Top a tank up once it's below this share of its capacity - well before
-- it runs dry, so the AI Helper never stops for an empty tank while there's
-- stock to fill it from.
TCJobSupplies.REFILL_RATIO = 0.25

-- Loading supplies onto a hired worker's equipment as they set off: a
-- fixed LOAD_MINUTES whenever anything's loaded at all, plus LITERS_PER_
-- MINUTE of filling (a 3000 l seed hopper: 5 + 1.5 minutes).
TCJobSupplies.LOAD_MINUTES = 5
TCJobSupplies.LITERS_PER_MINUTE = 2000

TCJobSupplies.POLL_INTERVAL_MS = TCJobProgress.POLL_INTERVAL_MS

TCJobSupplies.STATUS = {
    NO_STOCK = "noStock",
    WRONG_FILL = "wrongFill",
}

local accumulatedMs = 0

-- vehicle -> true for equipment on an allocated/in_progress hired-worker
-- job (see "The AI Helper buying as it goes" below). Server-only, rebuilt
-- every poll (checkJobs).
local contractVehicles = {}

function TCJobSupplies.reset()
    accumulatedMs = 0
    contractVehicles = {}
end

local function getJobDef(job)
    return TheContractorJobGeneration.JOB_TYPES[job.jobType]
end

local function resolveFillTypeNames(names)
    local result = {}
    for _, name in ipairs(names) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(name)
        if fillTypeIndex ~= nil then
            table.insert(result, fillTypeIndex)
        end
    end
    return result
end

-- The job's product fill types this fill unit takes.
local function getSupportedOf(vehicle, fillUnitIndex, fillTypes)
    local result = {}
    for _, fillTypeIndex in ipairs(fillTypes) do
        if vehicle:getFillUnitSupportsFillType(fillUnitIndex, fillTypeIndex) then
            table.insert(result, fillTypeIndex)
        end
    end
    return result
end

local function addTank(tanks, vehicle, fillUnitIndex, fillTypes, consumableType)
    local capacity = vehicle:getFillUnitCapacity(fillUnitIndex)
    if capacity == nil or capacity <= 0 or #fillTypes == 0 then
        return
    end
    table.insert(tanks, {
        vehicle = vehicle,
        fillUnitIndex = fillUnitIndex,
        fillTypes = fillTypes,
        consumableType = consumableType,
    })
end

-- The tanks (see file header) on `vehicles` for a job of this type.
function TCJobSupplies.getTanks(jobDef, vehicles)
    local tanks = {}
    if jobDef == nil or jobDef.cropDependent then
        return tanks
    end

    local productFillTypes = jobDef.supplyFillTypeNames ~= nil and resolveFillTypeNames(jobDef.supplyFillTypeNames) or
        nil

    for _, vehicle in ipairs(vehicles) do
        -- A separate seed tank (front hopper) feeding a seeder with no
        -- hopper of its own: each of its fill units that takes seed.
        if jobDef.implementSpec == "spec_sowingMachine" and TCEquipmentClass.isSeedTank(vehicle) then
            for fillUnitIndex in pairs(vehicle.spec_fillUnit.fillUnits) do
                addTank(tanks, vehicle, fillUnitIndex,
                    getSupportedOf(vehicle, fillUnitIndex, { TCEquipmentClass.SEED_TANK_FILL_TYPE }))
            end
        end

        if vehicle.getFillUnitCapacity ~= nil and TCEquipmentClass.isJobImplement(vehicle, jobDef) then
            local sowingSpec = vehicle.spec_sowingMachine
            if jobDef.implementSpec == "spec_sowingMachine" and sowingSpec ~= nil then
                addTank(tanks, vehicle, sowingSpec.fillUnitIndex,
                    getSupportedOf(vehicle, sowingSpec.fillUnitIndex, { sowingSpec.seedFillType }))
            end

            if productFillTypes ~= nil and vehicle.spec_sprayer ~= nil then
                local fillUnitIndex = vehicle.spec_sprayer.fillUnitIndex
                addTank(tanks, vehicle, fillUnitIndex, getSupportedOf(vehicle, fillUnitIndex, productFillTypes))
            end

            local consumableSpec = vehicle.spec_consumable
            if consumableSpec ~= nil and consumableSpec.types ~= nil then
                for _, consumableType in ipairs(consumableSpec.types) do
                    local supported = {}
                    for fillTypeIndex, isSupported in pairs(vehicle:getFillUnitSupportedFillTypes(
                        consumableType.fillUnitIndex) or {}) do
                        if isSupported then
                            table.insert(supported, fillTypeIndex)
                        end
                    end
                    addTank(tanks, vehicle, consumableType.fillUnitIndex, supported, consumableType)
                end
            end
        end
    end

    return tanks
end

local function resolveVehicles(ids)
    local vehicles = {}
    for _, vehicleId in ipairs(ids) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil then
            table.insert(vehicles, vehicle)
        end
    end
    return vehicles
end

function TCJobSupplies.getJobTanks(job)
    return TCJobSupplies.getTanks(getJobDef(job), resolveVehicles(job.assignedEquipmentIds))
end

-- Whether the job needs supplies at all, going by what the farm owns that
-- could do it - drives the Inbox's supplies line. Returns the fill types
-- the farm's eligible equipment would draw on (empty if none).
function TCJobSupplies.getRequiredFillTypes(jobDef, vehicles)
    local seen, result = {}, {}
    for _, tank in ipairs(TCJobSupplies.getTanks(jobDef, vehicles)) do
        for _, fillTypeIndex in ipairs(tank.fillTypes) do
            if not seen[fillTypeIndex] then
                seen[fillTypeIndex] = true
                table.insert(result, fillTypeIndex)
            end
        end
    end
    return result
end

-- Stock ---------------------------------------------------------------------

local function isOwnedBy(object, farmId)
    return object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId
end

-- Storages holding this fill type for the farm: { storage, level }...
local function getStorageSources(farmId, fillTypeIndex)
    local sources = {}
    for _, storage in pairs(g_currentMission.storageSystem:getStorages()) do
        if isOwnedBy(storage, farmId) and storage.getIsFillTypeSupported ~= nil and
            storage:getIsFillTypeSupported(fillTypeIndex) then
            local level = storage:getFillLevel(fillTypeIndex) or 0
            if level > 0 then
                table.insert(sources, { storage = storage, level = level })
            end
        end
    end
    return sources
end

-- Pallets/big bags/liquid tanks holding this fill type for the farm:
-- { pallet, fillUnitIndex, level }...
local function getPalletSources(farmId, fillTypeIndex)
    local sources = {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.isPallet and isOwnedBy(vehicle, farmId) and vehicle.getFillUnitFillType ~= nil then
            local fillUnitIndex = vehicle.spec_pallet ~= nil and vehicle.spec_pallet.fillUnitIndex or 1
            if vehicle:getFillUnitFillType(fillUnitIndex) == fillTypeIndex then
                local level = vehicle:getFillUnitFillLevel(fillUnitIndex) or 0
                if level > 0 then
                    table.insert(sources, { pallet = vehicle, fillUnitIndex = fillUnitIndex, level = level })
                end
            end
        end
    end
    return sources
end

-- How much of a fill type the farm has in stock, all sources together.
function TCJobSupplies.getFarmStock(farmId, fillTypeIndex)
    local total = 0
    for _, source in ipairs(getStorageSources(farmId, fillTypeIndex)) do
        total = total + source.level
    end
    for _, source in ipairs(getPalletSources(farmId, fillTypeIndex)) do
        total = total + source.level
    end
    return total
end

-- Server-only. Takes up to `amount` out of the farm's stock - storages
-- first, then pallets - and returns how much it got.
function TCJobSupplies.drawFromStock(farmId, fillTypeIndex, amount)
    local taken = 0

    for _, source in ipairs(getStorageSources(farmId, fillTypeIndex)) do
        if taken >= amount then
            break
        end
        local take = math.min(source.level, amount - taken)
        source.storage:setFillLevel(source.level - take, fillTypeIndex)
        taken = taken + take
    end

    for _, source in ipairs(getPalletSources(farmId, fillTypeIndex)) do
        if taken >= amount then
            break
        end
        local take = math.min(source.level, amount - taken)
        local applied = source.pallet:addFillUnitFillLevel(farmId, source.fillUnitIndex, -take, fillTypeIndex,
            ToolType.UNDEFINED, nil)
        taken = taken + math.abs(applied or 0)
    end

    return taken
end

-- "Seeds 12,400 l" - a fill type's title with an amount in its own unit
-- (pieces for net/twine/film, volume for everything else).
function TCJobSupplies.formatAmount(fillTypeIndex, amount)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    local title = fillType ~= nil and fillType.title or tostring(fillTypeIndex)
    local amountText
    if fillType ~= nil and fillType.unitShort ~= nil and fillType.unitShort ~= "" then
        amountText = string.format("%s %s", g_i18n:formatNumber(math.floor(amount)), fillType.unitShort)
    else
        amountText = g_i18n:formatVolume(amount, 0)
    end
    return string.format("%s %s", title, amountText)
end

-- Tanks ---------------------------------------------------------------------

-- A tank with nothing left to work with. A consumable holder isn't out
-- until the roll it's working through is used up as well.
local function isTankOut(tank)
    if tank.vehicle:getFillUnitFillLevel(tank.fillUnitIndex) > 0.001 then
        return false
    end
    return tank.consumableType == nil or tank.consumableType.consumingFillLevel <= 0
end

local function hasFillType(fillTypes, fillTypeIndex)
    for _, candidate in ipairs(fillTypes) do
        if candidate == fillTypeIndex then
            return true
        end
    end
    return false
end

-- What to fill an empty tank with: whatever was in it last, if that's one
-- of its products and the farm has some, else the product the farm has
-- most of.
local function pickFillType(farmId, tank)
    local lastFillType = tank.vehicle:getFillUnitLastValidFillType(tank.fillUnitIndex)
    if lastFillType ~= nil and hasFillType(tank.fillTypes, lastFillType) and
        TCJobSupplies.getFarmStock(farmId, lastFillType) > 0 then
        return lastFillType
    end

    local best, bestStock = nil, 0
    for _, fillTypeIndex in ipairs(tank.fillTypes) do
        local stock = TCJobSupplies.getFarmStock(farmId, fillTypeIndex)
        if stock > bestStock then
            best, bestStock = fillTypeIndex, stock
        end
    end
    return best
end

-- Returns the amount loaded and its fill type.
local function fillTank(farmId, tank)
    local vehicle, fillUnitIndex = tank.vehicle, tank.fillUnitIndex
    local fillTypeIndex = vehicle:getFillUnitFillLevel(fillUnitIndex) > 0 and
        vehicle:getFillUnitFillType(fillUnitIndex) or pickFillType(farmId, tank)
    if fillTypeIndex == nil then
        return 0
    end

    local free = vehicle:getFillUnitFreeCapacity(fillUnitIndex, fillTypeIndex, farmId) or 0
    if free <= 0 then
        return 0
    end

    local taken = TCJobSupplies.drawFromStock(farmId, fillTypeIndex, free)
    if taken <= 0 then
        return 0
    end
    vehicle:addFillUnitFillLevel(farmId, fillUnitIndex, taken, fillTypeIndex, ToolType.UNDEFINED, nil)
    Logging.info("TheContractor: filled '%s' with %s from farm %d's stock", vehicle:getName(),
        TCJobSupplies.formatAmount(fillTypeIndex, taken), farmId)
    return taken, fillTypeIndex
end

-- Server-only. Tops up the job's tanks from the farm's stock and says
-- whether the job can carry on. Returns amount loaded, then status and
-- fill type name if it's on hold (see file header), else nil.
--   onlyBelowRatio  only tanks under REFILL_RATIO (a top-up mid-job),
--                   rather than filling everything that has room
--   canFill(tank)   optional: whether this tank may be filled right now
--                   (a player's equipment only on the job's farmland) -
--                   tanks it refuses still count towards the status
function TCJobSupplies.topUp(job, onlyBelowRatio, canFill)
    local loaded = 0
    local status, statusFillType = nil, nil

    for _, tank in ipairs(TCJobSupplies.getJobTanks(job)) do
        local vehicle, fillUnitIndex = tank.vehicle, tank.fillUnitIndex
        local level = vehicle:getFillUnitFillLevel(fillUnitIndex)
        local currentFillType = vehicle:getFillUnitFillType(fillUnitIndex)

        if level > 0.001 and not hasFillType(tank.fillTypes, currentFillType) then
            status = TCJobSupplies.STATUS.WRONG_FILL
            statusFillType = currentFillType
        else
            local capacity = vehicle:getFillUnitCapacity(fillUnitIndex)
            local wantsFill = not onlyBelowRatio or level < capacity * TCJobSupplies.REFILL_RATIO
            if wantsFill and (canFill == nil or canFill(tank)) then
                local taken, fillTypeIndex = fillTank(job.farmId, tank)
                loaded = loaded + taken
                -- 060: the job's supplies, for the logbook.
                if taken > 0 then
                    g_currentMission.TheContractor.Logbook:onSuppliesLoaded(job, fillTypeIndex, taken)
                end
            end

            if isTankOut(tank) and status == nil then
                status = TCJobSupplies.STATUS.NO_STOCK
                statusFillType = level > 0 and currentFillType or
                    (vehicle:getFillUnitLastValidFillType(fillUnitIndex) or tank.fillTypes[1])
                if not hasFillType(tank.fillTypes, statusFillType) then
                    statusFillType = tank.fillTypes[1]
                end
            end
        end
    end

    local fillTypeName = statusFillType ~= nil and g_fillTypeManager:getFillTypeNameByIndex(statusFillType) or nil
    return loaded, status, fillTypeName
end

-- Dispatch's "supplies" transport factor: in-game minutes to load `liters`
-- of supplies before setting off.
function TCJobSupplies.getLoadingMinutes(liters)
    if liters == nil or liters <= 0 then
        return 0
    end
    return TCJobSupplies.LOAD_MINUTES + liters / TCJobSupplies.LITERS_PER_MINUTE
end

-- The AI Helper buying as it goes ---------------------------------------------
--
-- Vanilla's "helper buys seeds/fertilizer" game settings (on by default) let
-- an AI Helper leave its tank alone and pay for seed and fertilizer as it
-- works (SowingMachine:onEndWorkAreaProcessing, Sprayer:
-- getIsSprayerExternallyFilled). That would sidestep the farm's stock
-- entirely, so equipment out on a hired worker's contract job always works
-- from its tank, whatever the settings - the player's own vanilla helpers
-- still follow them. Patched at source time, before vehicle types are
-- finalized (they copy specialization functions then); the event listener
-- is looked up when it fires, so that one takes either way.

function TCJobSupplies.isContractVehicle(vehicle)
    return contractVehicles[vehicle] == true
end

-- Runs func with helperBuySeeds off for a contract vehicle, putting the
-- setting back even if func throws.
local function withOwnSeeds(vehicle, func, ...)
    if not contractVehicles[vehicle] then
        return func(...)
    end
    local missionInfo = g_currentMission.missionInfo
    local helperBuySeeds = missionInfo.helperBuySeeds
    missionInfo.helperBuySeeds = false
    local ok, a, b, c = pcall(func, ...)
    missionInfo.helperBuySeeds = helperBuySeeds
    if not ok then
        error(a, 0)
    end
    return a, b, c
end

local originalProcessSowingMachineArea = SowingMachine.processSowingMachineArea
SowingMachine.processSowingMachineArea = function(self, workArea, dt)
    return withOwnSeeds(self, originalProcessSowingMachineArea, self, workArea, dt)
end

local originalOnEndWorkAreaProcessing = SowingMachine.onEndWorkAreaProcessing
SowingMachine.onEndWorkAreaProcessing = function(self, dt, hasProcessed)
    return withOwnSeeds(self, originalOnEndWorkAreaProcessing, self, dt, hasProcessed)
end

Sprayer.getIsSprayerExternallyFilled = Utils.overwrittenFunction(Sprayer.getIsSprayerExternallyFilled,
    function(self, superFunc)
        if contractVehicles[self] then
            return false
        end
        return superFunc(self)
    end)

local function refreshContractVehicles()
    local result = {}
    local tc = g_currentMission.TheContractor
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if job.assignedWorkerId ~= nil and (job.state == TheContractorJob.STATE.ALLOCATED or
                    job.state == TheContractorJob.STATE.IN_PROGRESS) then
                for _, vehicle in ipairs(resolveVehicles(job.assignedEquipmentIds)) do
                    result[vehicle] = true
                end
            end
        end
    end
    contractVehicles = result
end

-- Poll ----------------------------------------------------------------------

local function isOnJobFarmland(job, vehicle)
    local field = g_fieldManager:getFieldById(job.fieldId)
    local farmland = field ~= nil and field:getFarmland() or nil
    if farmland == nil then
        return false
    end
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    return g_farmlandManager:getFarmlandIdAtWorldPosition(x, z) == farmland.id
end

-- A hired worker's job: on hold and not out working -> try setting off
-- again, which re-checks the supplies (Dispatch:startJobForWorker); its AI
-- stopped for an empty tank -> refill and restart it, or put it on hold;
-- out working -> top up, or stop and wait if a tank's run dry with nothing
-- left to fill it.
local function checkWorkerJob(job, jobs, dispatch)
    if job:isWaitingForSupplies() then
        if not dispatch:isJobActive(job) then
            dispatch:startJobForWorker(job, job.state == TheContractorJob.STATE.IN_PROGRESS)
        end
        return
    end

    if dispatch:takeRanOutOfFill(job.id) then
        local loaded, status, fillTypeName = TCJobSupplies.topUp(job)
        if status ~= nil then
            jobs:setJobSupplyStatus(job, status, fillTypeName)
        elseif loaded > 0 then
            dispatch:startJobForWorker(job, true)
        else
            -- Something ran dry that isn't one of the job's supplies (a
            -- seeder's fertilizer tank, say) - restarting would just stop
            -- again, so it's left to the stuck watchdog (021) to retry and
            -- then flag.
            Logging.warning("TheContractor: job %d's AI ran out of something the contractor doesn't supply", job.id)
        end
        return
    end

    if not dispatch:isJobWorking(job) then
        return
    end

    local _, status, fillTypeName = TCJobSupplies.topUp(job, true)
    if status ~= nil then
        jobs:setJobSupplyStatus(job, status, fillTypeName)
        dispatch:pauseForSupplies(job)
    end
end

-- A player-driven job: top up whatever's out on the job's farmland, and
-- keep the status showing what's missing.
local function checkPlayerJob(job, jobs)
    local _, status, fillTypeName = TCJobSupplies.topUp(job, true, function(tank)
        return isOnJobFarmland(job, tank.vehicle)
    end)
    jobs:setJobSupplyStatus(job, status, fillTypeName)
end

local function checkJobs()
    refreshContractVehicles()

    local tc = g_currentMission.TheContractor
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS then
                local jobDef = getJobDef(job)
                if jobDef ~= nil and not jobDef.cropDependent then
                    if job.assignedWorkerId ~= nil then
                        checkWorkerJob(job, tc.Jobs, tc.Dispatch)
                    else
                        checkPlayerJob(job, tc.Jobs)
                    end
                end
            end
        end
    end
end

-- Server-only, called every frame from TheContractor:update.
function TCJobSupplies.update(dt)
    if not g_currentMission:getIsServer() then
        return
    end

    accumulatedMs = accumulatedMs + dt
    if accumulatedMs < TCJobSupplies.POLL_INTERVAL_MS then
        return
    end
    accumulatedMs = 0

    checkJobs()
end
