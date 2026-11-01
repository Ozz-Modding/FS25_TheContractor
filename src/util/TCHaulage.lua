-- Harvest & haul (035): what happens to the crop on a harvest job, since
-- nobody drives a trailer alongside our AI combine.
--
--   Auto-empty   a job's combine is emptied once its tank passes
--                AUTO_EMPTY_FILL_RATIO - the client's (or, on a two-worker
--                haulage job, our unseen hauler's) carts take it away. Left
--                alone it would fill up and sit waiting for a trailer
--                (AIDriveStrategyCombine never stops the AI job for a full
--                tank), which the stuck watchdog (021) would misread as
--                stuck. Applies to every harvest job except a player-driven
--                haulage job, where the player is the one doing the carting.
--                Each load our hauler takes burns its tractor's diesel
--                (TCJobFuel.burnCartingFuel).
--                A player-driven combine is only emptied while it's on the
--                job's farmland and holding the job's crop, so it's never
--                touched working the player's own fields. While the job's
--                under way it can't unload the job's crop anywhere (the
--                unloading lock below), and whatever's left goes when the
--                job ends: the crop is the customer's, not the player's.
--
--   Delivery     a player-driven haulage job has to get the crop to its
--                selling point (picked at generation, like vanilla's
--                HarvestMission). Same mechanism vanilla uses: a tracker
--                object registered in the station's `missions` table gets
--                the matching deliveries through fillSold instead of them
--                being sold (SellingStation:addFillLevelFromTool). Once
--                requiredLiters is in, the tracker drops out and anything
--                more sells normally - the player keeps the excess.
--                067 delivers straw bales the same way, to a station with
--                a bale trigger (findBaleDeliveryStation): bale & deliver
--                (a bale job with includesHaulage) and straw delivery. A
--                bale tipped into a BaleUnloadTrigger reaches the station's
--                addFillLevelFromTool like any other load. Counted in
--                litres by fill type + farm, like the crop - the farm's own
--                straw sold there counts too. 126 sells a farmer's
--                trailer load the same way.
--
-- Server-only apart from the display state (deliveredLiters/requiredLiters/
-- deliveryStationName), which rides on the job snapshot and
-- TCJobDeliveryEvent. Trackers are live objects, never saved - re-registered
-- on the first update after load (resumeDeliveriesAfterLoad).

TCHaulage = {}

TCHaulage.AUTO_EMPTY_FILL_RATIO = 0.75

-- Share of the field's expected yield that has to be delivered - vanilla
-- HarvestMission's own success factor, allowing for losses and headlands.
TCHaulage.DELIVERY_SUCCESS_FACTOR = 0.93

-- Auto-empty checks and delivery-progress syncing share TCJobProgress's
-- cadence - nothing to gain checking fill levels more often than that.
TCHaulage.POLL_INTERVAL_MS = TCJobProgress.POLL_INTERVAL_MS

-- jobId -> tracker currently registered in a selling station
local trackersByJobId = {}
-- jobId -> true for jobs whose delivery progress changed since last sync
local dirtyJobIds = {}
local accumulatedMs = 0
local hasResumedAfterLoad = false

function TCHaulage.reset()
    trackersByJobId = {}
    dirtyJobIds = {}
    accumulatedMs = 0
    hasResumedAfterLoad = false
end

-- Delivery station ------------------------------------------------------------

-- The selling point paying most for the crop, the same pick vanilla's
-- harvest contracts make. nil if nothing on the map takes it.
function TCHaulage.findDeliveryStation(fillTypeIndex)
    if fillTypeIndex == nil or fillTypeIndex == FillType.UNKNOWN then
        return nil
    end
    local station = HarvestMission.getSellingStationWithHighestPrice(fillTypeIndex)
    return station
end

-- Whether one of a station's unload triggers is a bale trigger that takes
-- bales of this fill type - BaleUnloadTrigger:getIsBaleSupportedByUnloadTrigger's
-- own checks, less the bale itself.
local function hasBaleTriggerFor(station, fillTypeIndex)
    if BaleUnloadTrigger == nil then
        return false
    end
    for _, trigger in ipairs(station.unloadTriggers or {}) do
        if trigger.isa ~= nil and trigger:isa(BaleUnloadTrigger) and
            (trigger.supportedFillTypes == nil or trigger.supportedFillTypes[fillTypeIndex] ~= nil) and
            trigger:getIsFillTypeAllowed(fillTypeIndex) and trigger:getIsFillTypeSupported(fillTypeIndex) and
            trigger:getIsToolTypeAllowed(ToolType.BALE) then
            return true
        end
    end
    return false
end

-- 067: the selling point paying most for the fill type that has a bale
-- trigger taking it - HarvestMission.getSellingStationWithHighestPrice's
-- pick, among the stations bales can actually be tipped into. Bales sold
-- there go through SellingStation:addFillLevelFromTool like any load, so
-- the same tracker counts them. nil if nowhere takes them.
function TCHaulage.findBaleDeliveryStation(fillTypeIndex)
    if fillTypeIndex == nil or fillTypeIndex == FillType.UNKNOWN then
        return nil
    end

    local bestStation, bestPrice = nil, 0
    for _, station in pairs(g_currentMission.storageSystem:getUnloadingStations()) do
        if station.owningPlaceable ~= nil and station.isSellingPoint and station.allowMissions and
            station.acceptedFillTypes ~= nil and station.acceptedFillTypes[fillTypeIndex] and
            hasBaleTriggerFor(station, fillTypeIndex) then
            local price = station:getEffectiveFillTypePrice(fillTypeIndex)
            if price > bestPrice then
                bestStation, bestPrice = station, price
            end
        end
    end
    return bestStation
end

-- What a job delivers: the crop on a harvest job, straw on a bale job
-- (067).
function TCHaulage.getDeliveryFillType(job)
    -- 106: the crop that was spilt. 126: a farmer's load.
    local carried = job.spill or job.yardHaul
    if carried ~= nil then
        return g_fillTypeManager:getFillTypeIndexByName(carried.fillTypeName)
    end
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    local fruitTypeIndex = job:getFruitTypeIndex()
    if jobDef == nil or fruitTypeIndex == nil then
        return nil
    end
    if jobDef.deliversBales then
        return TheContractorJobGeneration.getStrawFillType(fruitTypeIndex)
    end
    return g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(fruitTypeIndex)
end

-- Remembers a station on the job the way vanilla saves one (owning
-- placeable's uniqueId + unloading station index), plus its name for
-- display.
function TCHaulage.setDeliveryStation(job, station)
    local placeable = station.owningPlaceable
    if placeable == nil then
        return
    end
    job.deliveryStationUniqueId = placeable:getUniqueId()
    job.deliveryStationIndex = g_currentMission.storageSystem:getPlaceableUnloadingStationIndex(placeable, station)
    job.deliveryStationName = station:getName()
end

function TCHaulage.resolveDeliveryStation(job)
    if job.deliveryStationUniqueId == nil or job.deliveryStationIndex == nil then
        return nil
    end
    local placeable = g_currentMission.placeableSystem:getPlaceableByUniqueId(job.deliveryStationUniqueId)
    if placeable == nil then
        return nil
    end
    return g_currentMission.storageSystem:getPlaceableUnloadingStation(placeable, job.deliveryStationIndex)
end

-- Expected yield, vanilla HarvestMission:getMaxCutLiters' formula over the
-- whole field area (the field has just been prepared with the job's crop -
-- see TCFieldPreparation - so there's nothing to gain from a density-map
-- scan of what's actually standing).
local function getExpectedLiters(job)
    local field = g_fieldManager:getFieldById(job.fieldId)
    local fruitTypeIndex = job:getFruitTypeIndex()
    if field == nil or fruitTypeIndex == nil then
        return 0
    end

    local multiplier = field:getFieldState():getHarvestScaleMultiplier()
    local pixels = MathUtil.haToSqm(field:getAreaHa() * multiplier) / g_currentMission:getFruitPixelsToSqm()
    return g_fruitTypeManager:getFruitTypeAreaLiters(fruitTypeIndex, pixels, false)
end

-- The straw in a straw delivery's bales (067), as laid out.
local function getSpawnedBaleLiters(job)
    local liters = 0
    for _, uniqueId in ipairs(job.spawnedBaleIds) do
        local bale = g_currentMission.itemSystem:getItemByUniqueId(uniqueId)
        if bale ~= nil then
            liters = liters + bale:getFillLevel()
        end
    end
    return liters
end

-- Litres the job has to deliver, or nil while that isn't known yet: a
-- bale job's straw is the windrow it's baling, a straw delivery's the
-- bales laid out for it, and both are only there once its field's been
-- laid out (TCFieldPreparation, which calls startDelivery again when it
-- has). Harvest's is the field's expected yield. Always less
-- DELIVERY_SUCCESS_FACTOR, for what's lost along the way (headlands, a
-- part-bale left in the baler, a bale that rolled off).
function TCHaulage.getRequiredLiters(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef == nil then
        return nil
    end
    -- 106: a share of the spill, with its own allowance for losses.
    if job.spill ~= nil then
        return TheContractorCropSpill.getRequiredLiters(job)
    end
    -- 126: a farmer's trailer load.
    if job.yardHaul ~= nil then
        return (job.yardHaul.liters or 0) * TCHaulage.DELIVERY_SUCCESS_FACTOR
    end

    local liters
    if jobDef.deliveryOnly then
        if job.workTotal == nil then
            return nil
        end
        liters = getSpawnedBaleLiters(job)
    elseif jobDef.deliversBales then
        liters = job.workTotal
    else
        liters = getExpectedLiters(job)
    end
    if liters == nil then
        return nil
    end
    return liters * TCHaulage.DELIVERY_SUCCESS_FACTOR
end

-- Delivery tracking -----------------------------------------------------------

-- Duck-typed stand-in for a vanilla mission in SellingStation.missions:
-- addFillLevelFromTool matches on fillTypeIndex + farmId, picks the
-- matching entry with the highest getCompletion(), and calls fillSold on
-- it instead of selling; SellingStation:delete calls onDeleteSellingStation.
-- "Highest" starts from 0 and only a completion above it is picked, so a
-- tracker reporting exactly 0 (nothing delivered yet) is never picked and
-- every load sells instead - vanilla's own missions are always past 0 by
-- then, from their field work. Hence MIN_COMPLETION.
local TCDeliveryTracker = {}
local TCDeliveryTracker_mt = { __index = TCDeliveryTracker }

TCHaulage.MIN_COMPLETION = 0.001

function TCDeliveryTracker.new(job, station, fillTypeIndex)
    return setmetatable({
        jobId = job.id,
        farmId = job.farmId,
        fillTypeIndex = fillTypeIndex,
        station = station,
    }, TCDeliveryTracker_mt)
end

function TCDeliveryTracker:getJob()
    return g_currentMission.TheContractor.Jobs:getJobById(self.jobId)
end

function TCDeliveryTracker:getCompletion()
    local job = self:getJob()
    if job == nil or job.requiredLiters <= 0 then
        return 1
    end
    return math.max(TCHaulage.MIN_COMPLETION, job.deliveredLiters / job.requiredLiters)
end

function TCDeliveryTracker:fillSold(fillDelta)
    local job = self:getJob()
    if job == nil then
        return
    end

    local delivered = math.min(job.deliveredLiters + fillDelta, job.requiredLiters)
    g_currentMission.TheContractor.Jobs:applyJobDelivery(job.farmId, job.id, delivered, job.requiredLiters)
    dirtyJobIds[job.id] = true

    -- Terms met - anything more delivered sells as normal.
    if delivered >= job.requiredLiters then
        TCHaulage.stopDelivery(job)
    end
end

function TCDeliveryTracker:onDeleteSellingStation(station)
    TCLog.warning("TheContractor: job %d delivery station was removed - the crop can't be delivered", self.jobId)
    local job = self:getJob()
    if job ~= nil then
        TCHaulage.stopDelivery(job)
    end
end

local function registerTracker(job)
    if trackersByJobId[job.id] ~= nil then
        return true
    end

    local station = TCHaulage.resolveDeliveryStation(job)
    if station == nil then
        TCLog.warning("TheContractor: job %d delivery station '%s' can't be found", job.id,
            tostring(job.deliveryStationName))
        return false
    end

    local fillTypeIndex = TCHaulage.getDeliveryFillType(job)
    if fillTypeIndex == nil then
        return false
    end

    local tracker = TCDeliveryTracker.new(job, station, fillTypeIndex)
    station.missions[tracker] = tracker
    trackersByJobId[job.id] = tracker
    return true
end

-- Server-only. Called on allocating a haulage job to the player: works out
-- how much has to be delivered and starts counting deliveries. For a job
-- whose amount isn't known until its field is laid out (getRequiredLiters),
-- that's left until TCFieldPreparation calls this again - with nothing
-- required, the tracker would count the terms as met at once.
function TCHaulage.startDelivery(job)
    if not g_currentMission:getIsServer() or not job:needsPlayerDelivery() then
        return
    end

    local required = TCHaulage.getRequiredLiters(job)
    if required == nil then
        return
    end
    g_currentMission.TheContractor.Jobs:applyJobDelivery(job.farmId, job.id, 0, required)
    dirtyJobIds[job.id] = true

    if registerTracker(job) then
        TCLog.info("TheContractor: job %d needs %.0f l delivered to %s", job.id, required,
            tostring(job.deliveryStationName))
    end
end

-- Server-only (094). An unallocated job allocated again to a player: what
-- they've delivered so far still counts. If nothing was being counted (a
-- hired crew had it, and carted its own crop away), the player only has to
-- deliver the share of the crop left on the field.
function TCHaulage.resumeDelivery(job)
    if not g_currentMission:getIsServer() or not job:needsPlayerDelivery() then
        return
    end

    if job.requiredLiters <= 0 then
        local required = TCHaulage.getRequiredLiters(job)
        if required == nil then
            return
        end
        local remaining = math.clamp(1 - job.completionPercentage / 100, 0, 1)
        g_currentMission.TheContractor.Jobs:applyJobDelivery(job.farmId, job.id, 0, required * remaining)
        dirtyJobIds[job.id] = true
    end

    if job.deliveredLiters < job.requiredLiters then
        registerTracker(job)
    end
end

-- Server-only. Stops counting deliveries for a job - terms met, or the job
-- is over. Safe to call for any job.
function TCHaulage.stopDelivery(job)
    local tracker = trackersByJobId[job.id]
    if tracker == nil then
        return
    end
    trackersByJobId[job.id] = nil
    if tracker.station.missions ~= nil then
        tracker.station.missions[tracker] = nil
    end
end

local function resumeDeliveriesAfterLoad()
    local jobs = g_currentMission.TheContractor.Jobs
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(jobs:getAllJobs(farm.farmId)) do
            if job:needsPlayerDelivery() and job.deliveredLiters < job.requiredLiters and
                (job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS) then
                registerTracker(job)
            end
        end
    end
end

-- Auto-empty ------------------------------------------------------------------

local function isOnFarmland(vehicle, farmlandId)
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    return g_farmlandManager:getFarmlandIdAtWorldPosition(x, z) == farmlandId
end

-- isFinal: the job's over (emptyHarvestersAfterJob), so whatever's left of
-- its crop goes, however little and wherever the combine is.
local function autoEmptyJobHarvesters(job, isFinal)
    local field = g_fieldManager:getFieldById(job.fieldId)
    local farmland = field ~= nil and field:getFarmland() or nil
    local fruitTypeIndex = job:getFruitTypeIndex()
    if farmland == nil or fruitTypeIndex == nil then
        return
    end
    local fillTypeIndex = g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(fruitTypeIndex)
    local emptyRatio = isFinal and 0 or TCHaulage.AUTO_EMPTY_FILL_RATIO

    for _, vehicleId in ipairs(job.assignedEquipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        local spec = vehicle ~= nil and vehicle.spec_combine or nil
        if spec ~= nil then
            local fillUnitIndex = spec.fillUnitIndex
            local capacity = vehicle:getFillUnitCapacity(fillUnitIndex)
            -- math.huge: a buffer combine (forage harvester) with no tank of
            -- its own to empty.
            if capacity ~= nil and capacity > 0 and capacity ~= math.huge and
                vehicle:getFillUnitFillType(fillUnitIndex) == fillTypeIndex and
                vehicle:getFillUnitFillLevel(fillUnitIndex) >= math.max(capacity * emptyRatio, 0.001) and
                (isFinal or isOnFarmland(vehicle, farmland.id)) then
                local level = vehicle:getFillUnitFillLevel(fillUnitIndex)
                vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), fillUnitIndex, -math.huge, fillTypeIndex,
                    ToolType.UNDEFINED, nil)
                TCLog.info("TheContractor: job %d emptied %.0f l from '%s'", job.id, level, vehicle:getName())
                -- 063: our hauler drove that load away.
                if job.haulerWorkerId ~= nil then
                    TCJobFuel.burnCartingFuel(job)
                end
            end
        end
    end
end

-- Whether a harvest job's crop is the customer's, taken off the combine
-- (auto-empty), rather than the player's to deliver: every harvest job but
-- a player-driven haulage one. A player-driven harvest without haulage
-- included is the customer's crop too - the player only combines it.
function TCHaulage.isCustomerCropJob(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    return jobDef ~= nil and jobDef.cropDependent == true and not job:needsPlayerDelivery()
end

local function isActiveJob(job)
    return job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS
end

local function autoEmptyHarvesters()
    local jobs = g_currentMission.TheContractor.Jobs
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(jobs:getAllJobs(farm.farmId)) do
            if TCHaulage.isCustomerCropJob(job) and isActiveJob(job) then
                autoEmptyJobHarvesters(job)
            end
        end
    end
end

-- A harvest job that's finished (or missed, or unallocated part-way) whose
-- crop is the customer's: the last part-load in the combine goes too, so
-- the machine comes home empty and nobody keeps the customer's crop. Left
-- in, it would also stop the combine being allocated again
-- (TheContractorAllocation.getFilledHarvester). A player-driven haulage
-- job's combine is the player's to empty: that crop is theirs to deliver.
-- Server-only.
function TCHaulage.emptyHarvestersAfterJob(job)
    if TCHaulage.isCustomerCropJob(job) then
        autoEmptyJobHarvesters(job, true)
    end
end

-- Unloading lock ---------------------------------------------------------------
--
-- A combine on a harvest job whose crop is the customer's can't unload the
-- job's crop into anything (a trailer, a silo, a selling point) while the
-- job's under way: auto-empty takes it. Without this a player driving the
-- job themselves could overload it into their own trailer and sell it. A
-- buffer combine (forage harvester) is left alone: it has no tank, so it
-- can't harvest at all without unloading. Every machine: the jobs, their
-- equipment and crop are synced, and clients use the check for the
-- unload action.

-- The allocated or under-way job whose crop this combine mustn't unload,
-- or nil. fillTypeIndex is what it's unloading.
function TCHaulage.getUnloadLockJob(vehicle, fillTypeIndex)
    local spec = vehicle.spec_combine
    local tc = g_currentMission.TheContractor
    if spec == nil or tc == nil or tc.Jobs == nil then
        return nil
    end
    local capacity = vehicle:getFillUnitCapacity(spec.fillUnitIndex)
    if capacity == nil or capacity == math.huge then
        return nil
    end

    local vehicleId = NetworkUtil.getObjectId(vehicle)
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if isActiveJob(job) and TCHaulage.isCustomerCropJob(job) and
                table.hasElement(job.assignedEquipmentIds, vehicleId) and
                TCHaulage.getDeliveryFillType(job) == fillTypeIndex then
                return job
            end
        end
    end
    return nil
end

function TCHaulage.getCanDischargeToObject(vehicle, superFunc, dischargeNode)
    if not superFunc(vehicle, dischargeNode) then
        return false
    end
    if TCHaulage.getUnloadLockJob(vehicle, vehicle:getDischargeFillType(dischargeNode)) == nil then
        return true
    end
    -- Tell the player in the cab why the pipe won't unload.
    if g_client ~= nil and vehicle.getIsActiveForInput ~= nil and vehicle:getIsActiveForInput(true) then
        g_currentMission:showBlinkingWarning(g_i18n:getText("tc_haulage_unloadLocked"), 2000)
    end
    return false
end

-- Patched before vehicle types are finalized, as CropSpill's
-- Dischargeable hook is.
if Dischargeable ~= nil and Dischargeable.getCanDischargeToObject ~= nil and
        not Dischargeable.tcUnloadLockInstalled then
    Dischargeable.getCanDischargeToObject = Utils.overwrittenFunction(Dischargeable.getCanDischargeToObject,
        TCHaulage.getCanDischargeToObject)
    Dischargeable.tcUnloadLockInstalled = true
end

-- Update ----------------------------------------------------------------------

local function syncDeliveryProgress()
    local jobs = g_currentMission.TheContractor.Jobs
    for jobId in pairs(dirtyJobIds) do
        local job = jobs:getJobById(jobId)
        if job ~= nil and g_server ~= nil then
            g_server:broadcastEvent(TCJobDeliveryEvent.new(job.farmId, job.id, job.deliveredLiters,
                job.requiredLiters))
        end
    end
    dirtyJobIds = {}
end

-- Server-only, called every frame from TheContractor:update.
function TCHaulage.update(dt)
    if not g_currentMission:getIsServer() then
        return
    end

    if not hasResumedAfterLoad then
        hasResumedAfterLoad = true
        resumeDeliveriesAfterLoad()
    end

    accumulatedMs = accumulatedMs + dt
    if accumulatedMs < TCHaulage.POLL_INTERVAL_MS then
        return
    end
    accumulatedMs = 0

    autoEmptyHarvesters()
    syncDeliveryProgress()
end
