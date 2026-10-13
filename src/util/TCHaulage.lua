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
--                touched working the player's own fields.
--
--   Delivery     a player-driven haulage job has to get the crop to its
--                selling point (picked at generation, like vanilla's
--                HarvestMission). Same mechanism vanilla uses: a tracker
--                object registered in the station's `missions` table gets
--                the matching deliveries through fillSold instead of them
--                being sold (SellingStation:addFillLevelFromTool). Once
--                requiredLiters is in, the tracker drops out and anything
--                more sells normally - the player keeps the excess.
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

-- Delivery tracking -----------------------------------------------------------

-- Duck-typed stand-in for a vanilla mission in SellingStation.missions:
-- addFillLevelFromTool matches on fillTypeIndex + farmId, picks the
-- matching entry with the highest getCompletion(), and calls fillSold on
-- it instead of selling; SellingStation:delete calls onDeleteSellingStation.
local TCDeliveryTracker = {}
local TCDeliveryTracker_mt = { __index = TCDeliveryTracker }

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
    return job.deliveredLiters / job.requiredLiters
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
    Logging.warning("TheContractor: job %d delivery station was removed - the crop can't be delivered", self.jobId)
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
        Logging.warning("TheContractor: job %d delivery station '%s' can't be found", job.id,
            tostring(job.deliveryStationName))
        return false
    end

    local fruitTypeIndex = job:getFruitTypeIndex()
    local fillTypeIndex = fruitTypeIndex ~= nil and g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(fruitTypeIndex)
        or nil
    if fillTypeIndex == nil then
        return false
    end

    local tracker = TCDeliveryTracker.new(job, station, fillTypeIndex)
    station.missions[tracker] = tracker
    trackersByJobId[job.id] = tracker
    return true
end

-- Server-only. Called on allocating a haulage job to the player: works out
-- how much has to be delivered and starts counting deliveries.
function TCHaulage.startDelivery(job)
    if not g_currentMission:getIsServer() or not job:needsPlayerDelivery() then
        return
    end

    local required = getExpectedLiters(job) * TCHaulage.DELIVERY_SUCCESS_FACTOR
    g_currentMission.TheContractor.Jobs:applyJobDelivery(job.farmId, job.id, 0, required)
    dirtyJobIds[job.id] = true

    if registerTracker(job) then
        Logging.info("TheContractor: job %d needs %.0f l delivered to %s", job.id, required,
            tostring(job.deliveryStationName))
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

local function autoEmptyJobHarvesters(job)
    local field = g_fieldManager:getFieldById(job.fieldId)
    local farmland = field ~= nil and field:getFarmland() or nil
    local fruitTypeIndex = job:getFruitTypeIndex()
    if farmland == nil or fruitTypeIndex == nil then
        return
    end
    local fillTypeIndex = g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(fruitTypeIndex)

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
                vehicle:getFillUnitFillLevel(fillUnitIndex) >= capacity * TCHaulage.AUTO_EMPTY_FILL_RATIO and
                isOnFarmland(vehicle, farmland.id) then
                local level = vehicle:getFillUnitFillLevel(fillUnitIndex)
                vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), fillUnitIndex, -math.huge, fillTypeIndex,
                    ToolType.UNDEFINED, nil)
                Logging.info("TheContractor: job %d emptied %.0f l from '%s'", job.id, level, vehicle:getName())
                -- 063: our hauler drove that load away.
                if job.haulerWorkerId ~= nil then
                    TCJobFuel.burnCartingFuel(job)
                end
            end
        end
    end
end

local function autoEmptyHarvesters()
    local jobs = g_currentMission.TheContractor.Jobs
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(jobs:getAllJobs(farm.farmId)) do
            local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
            if jobDef ~= nil and jobDef.cropDependent and not job:needsPlayerDelivery() and
                (job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS) then
                autoEmptyJobHarvesters(job)
            end
        end
    end
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
