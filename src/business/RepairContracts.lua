-- ADS repair contracts (100): customers' machines turn up in the farm's
-- repair zones (PlaceableTCRepairZone) for a repair or a service, each with
-- a job offer. FS25_AdvancedDamageSystem does the vehicle side through
-- TCADSRepairContracts: it ages and breaks the machine, prices the work,
-- says what tools it takes and whether the farm has them, and reports when
-- it's done or tampered with. See tickets/100 and docs/ads-repair-contracts.md.
--
-- Arrivals (server): every day each empty bay of a farm's zones may get a
-- customer (ARRIVAL_CHANCE), queued with its model, kind, severity and seed.
-- A queued arrival is spawned while the player can't see its bay (single
-- player only; multiplayer skips the check), or anyway after
-- PLACE_FALLBACK_MS of waiting. Then ADS
-- prepares it, and the offer goes up with a price of ADS's quote plus a
-- margin. Nothing runs while the queue is empty.
--
-- The job (Jobs, job.workshop): fieldId 0, no crew, offered -> accepted ->
-- completed or missed. It can't be accepted while the farm lacks the tools
-- (getAcceptProblem). It completes when ADS says done (its listener, plus a
-- pass after load and every day, since ADS's listener never fires for a
-- status reached before the save). When it ends the customer takes the
-- machine back: the contract is released and the machine is deleted once
-- its bay is out of view (the same check and fallback as arrivals).
--
-- Tampering is judged once, at the deadline (Jobs:missJob): a machine
-- that's still worse than it arrived means no pay, TAMPER_REPUTATION_MULTIPLIER
-- times a miss's reputation loss, and over TAMPER_CLAIM_THRESHOLD of damage a
-- compensation claim a few days later, never insured (public liability
-- doesn't cover deliberate acts), cut by legal cover (053).
--
-- State (server, saved in TheContractor.xml): the arrivals queue, the
-- machines waiting to be collected, and pending tamper claims. Clients only
-- ever see the jobs.

TheContractorRepairContracts = {}
TheContractorRepairContracts_mt = Class(TheContractorRepairContracts)

-- ADS kind -> our job type (JobGeneration.JOB_TYPES).
TheContractorRepairContracts.JOB_TYPES = {
    repair = "adsRepair",
    maintenance = "adsMaintenance",
}

-- The chance an empty bay gets a customer each day, and what they want.
TheContractorRepairContracts.ARRIVAL_CHANCE = 0.5
TheContractorRepairContracts.KIND_WEIGHTS = { repair = 60, maintenance = 40 }

-- Days an offer stays open, then days to do the work.
TheContractorRepairContracts.OFFER_DAYS = 2
TheContractorRepairContracts.DUE_DAYS = 7

-- The price: ADS's quote plus a margin, rolled per offer.
TheContractorRepairContracts.MARGIN_MIN = 0.15
TheContractorRepairContracts.MARGIN_MAX = 0.25

-- Base reputation for a finished job, by severity (1-3), before quality.
TheContractorRepairContracts.REPUTATION_BY_SEVERITY = { 4, 7, 10 }

-- Placing and collecting: how often the queue is looked at, and how long
-- (real time) one waits for its bay to be out of sight before it's done in
-- sight anyway.
TheContractorRepairContracts.PLACE_CHECK_MS = 2000
TheContractorRepairContracts.PLACE_FALLBACK_MS = 120000
-- An arrival whose bay has no room for this many days is dropped.
TheContractorRepairContracts.ARRIVAL_GIVE_UP_DAYS = 3
-- A model ADS turns down is swapped for another this many times.
TheContractorRepairContracts.PREPARE_RETRIES = 3
-- Footprint clearance (metres) a model needs in its bay.
TheContractorRepairContracts.CLEARANCE = 0.5

-- Tampering.
TheContractorRepairContracts.TAMPER_REPUTATION_MULTIPLIER = 2.0
-- 1x UK, scaleCost.
TheContractorRepairContracts.TAMPER_CLAIM_THRESHOLD = 500
TheContractorRepairContracts.TAMPER_LEGAL_COVER_FACTOR = 0.5
TheContractorRepairContracts.TAMPER_CLAIM_DELAY = { 2, 5 }
-- What a missing battery or filter, or one whose value ADS can't give,
-- counts for (1x UK, scaleCost).
TheContractorRepairContracts.TAMPER_PART_VALUE = 300
TheContractorRepairContracts.CLAIM_CAUSE = "tampering"

TheContractorRepairContracts.MESSAGE_KIND = "repairContract"
TheContractorRepairContracts.NOTICE_MONTHS = 1

-- Store categories a tractor zone takes models from.
TheContractorRepairContracts.TRACTOR_CATEGORIES = { TRACTORSS = true, TRACTORSM = true, TRACTORSL = true }

function TheContractorRepairContracts.new()
    local self = {}
    setmetatable(self, TheContractorRepairContracts_mt)

    -- Server, saved: { farmId, zoneUniqueId, bayIndex, xmlFilename, kind,
    -- severity, seed, queuedDay, attempts, blockedDays, waitMs, isLoading }.
    self.arrivals = {}
    -- Server, saved: machines waiting to be collected: { farmId, vehicleId,
    -- uniqueId, zoneUniqueId, bayIndex, waitMs }.
    self.removals = {}
    -- Server, saved: { farmId, jobId, vehicleName, amount, notifyDay }.
    self.pendingClaims = {}

    -- zoneType -> { model, ... }, built on first use per session.
    self.modelCache = {}
    self.checkMs = 0
    self.isListening = false

    return self
end

-- Every machine, at load.
function TheContractorRepairContracts:register(inbox)
    inbox:registerMessageKind(TheContractorRepairContracts.MESSAGE_KIND, {
        chipKey = "tc_inbox_chipRepair",
        chipTone = "warn",
    })
end

-- Reading (every machine) --------------------------------------------------------------

function TheContractorRepairContracts.isWorkshopJob(job)
    return job ~= nil and job.workshop ~= nil
end

-- vehicleId -> job for every workshop job's machine. A finished job keeps
-- its machine's id until the customer's taken it away; by then the object's
-- gone, so the id matches nothing.
-- Asked once per vehicle by lists of the farm's machines (allocation, the
-- Supplies tab), so the scan is kept for CACHE_MS.
TheContractorRepairContracts.CACHE_MS = 500
local contractVehicleCache = nil
local contractVehicleCacheTime = nil

function TheContractorRepairContracts.getContractVehicleIds()
    if contractVehicleCache ~= nil and g_time ~= nil and contractVehicleCacheTime ~= nil and
            g_time - contractVehicleCacheTime < TheContractorRepairContracts.CACHE_MS and
            g_time >= contractVehicleCacheTime then
        return contractVehicleCache
    end
    local result = {}
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    if tc == nil or tc.Jobs == nil then
        return result
    end
    for _, farmJobs in pairs(tc.Jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            local workshop = job.workshop
            if workshop ~= nil and workshop.vehicleId ~= nil and workshop.vehicleId ~= 0 then
                result[workshop.vehicleId] = job
            end
        end
    end
    contractVehicleCache = result
    contractVehicleCacheTime = g_time
    return result
end

-- Every load, and whenever a workshop job's machine changes.
function TheContractorRepairContracts.clearCache()
    contractVehicleCache = nil
    contractVehicleCacheTime = nil
end

-- A customer's machine (100): ours to work on, not to use.
function TheContractorRepairContracts.isContractVehicle(vehicle)
    if vehicle == nil then
        return false
    end
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    return vehicleId ~= nil and TheContractorRepairContracts.getContractVehicleIds()[vehicleId] ~= nil
end

function TheContractorRepairContracts.getVehicle(job)
    local vehicleId = job.workshop ~= nil and job.workshop.vehicleId or nil
    local vehicle = vehicleId ~= nil and vehicleId ~= 0 and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

-- Why the farm can't take the job on, as text, or nil if it can: the tools
-- ADS says it's missing ("Requires: Lift, Machining"). Read live on every
-- machine, so buying the equipment clears it at once.
function TheContractorRepairContracts.getAcceptProblem(job)
    if not TheContractorRepairContracts.isWorkshopJob(job) then
        return nil
    end
    local vehicle = TheContractorRepairContracts.getVehicle(job)
    if vehicle == nil then
        return g_i18n:getText("tc_repair_problemGone")
    end
    local check = TCADSRepairContracts.checkFarmTools(vehicle, job.farmId)
    if check == nil then
        return g_i18n:getText("tc_repair_problemNoADS")
    end
    if check.canDo then
        return nil
    end
    return string.format(g_i18n:getText("tc_repair_requires"), TCADSRepairContracts.getToolNames(check.missing))
end

-- Zones ---------------------------------------------------------------------------------

function TheContractorRepairContracts.getZones(farmId)
    local zones = {}
    local placeableSystem = g_currentMission.placeableSystem
    if placeableSystem == nil then
        return zones
    end
    for _, placeable in ipairs(placeableSystem.placeables) do
        if PlaceableTCRepairZone.isZone(placeable) and not placeable.isDeleted and not placeable.markedForDeletion and
                placeable:getOwnerFarmId() == farmId then
            table.insert(zones, placeable)
        end
    end
    return zones
end

function TheContractorRepairContracts.getZoneUniqueId(zone)
    return zone.getUniqueId ~= nil and zone:getUniqueId() or nil
end

-- Server: a zone by the uniqueId its arrivals and jobs keep.
function TheContractorRepairContracts.getZoneByUniqueId(uniqueId)
    local placeableSystem = g_currentMission.placeableSystem
    if uniqueId == nil or placeableSystem == nil then
        return nil
    end
    for _, placeable in ipairs(placeableSystem.placeables) do
        if PlaceableTCRepairZone.isZone(placeable) and not placeable.isDeleted and not placeable.markedForDeletion and
                TheContractorRepairContracts.getZoneUniqueId(placeable) == uniqueId then
            return placeable
        end
    end
    return nil
end

-- Server: whether a bay has a customer in it, on the way or still to be
-- collected.
function TheContractorRepairContracts:isBayTaken(zoneUniqueId, bayIndex)
    for _, entry in ipairs(self.arrivals) do
        if entry.zoneUniqueId == zoneUniqueId and entry.bayIndex == bayIndex then
            return true
        end
    end
    for _, entry in ipairs(self.removals) do
        if entry.zoneUniqueId == zoneUniqueId and entry.bayIndex == bayIndex then
            return true
        end
    end
    for _, farmJobs in pairs(g_currentMission.TheContractor.Jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            local workshop = job.workshop
            if workshop ~= nil and not job:isTerminal() and workshop.zoneUniqueId == zoneUniqueId and
                    workshop.bayIndex == bayIndex then
                return true
            end
        end
    end
    return false
end

-- Models -----------------------------------------------------------------------------------
-- A model a zone can get: a store vehicle whose vehicle type has ADS's
-- specialization (the only thing behind prepareVehicle's invalidVehicle, so
-- known before spawning), drivable, a tractor for a vehicle zone or a
-- self-propelled harvester for a harvester zone. Its size comes from its
-- xml (StoreItemUtil.getSizeValues), so one too big for a bay is never
-- spawned. Built once per session per zone type; it loads each candidate's
-- xml twice.

function TheContractorRepairContracts.isCandidateStoreItem(storeItem, zoneType)
    if storeItem.bundleInfo ~= nil or storeItem.showInStore == false or storeItem.xmlFilename == nil then
        return false
    end
    if StoreSpecies ~= nil and storeItem.species ~= nil and storeItem.species ~= StoreSpecies.VEHICLE then
        return false
    end
    if g_storeManager.getIsItemUnlocked ~= nil and not g_storeManager:getIsItemUnlocked(storeItem) then
        return false
    end
    local category = storeItem.categoryName or ""
    if zoneType == PlaceableTCRepairZone.ZONE_TYPE.HARVESTER then
        return string.find(string.upper(category), "HARVEST", 1, true) ~= nil
    end
    return TheContractorRepairContracts.TRACTOR_CATEGORIES[category] == true
end

-- Whether a vehicle type's specializations make it a model for this zone
-- type.
function TheContractorRepairContracts.isTypeForZone(specializationsByName, zoneType)
    if specializationsByName == nil or specializationsByName.AdvancedDamageSystem == nil or
            specializationsByName.drivable == nil then
        return false
    end
    local isHarvester = specializationsByName.combine ~= nil
    return isHarvester == (zoneType == PlaceableTCRepairZone.ZONE_TYPE.HARVESTER)
end

function TheContractorRepairContracts:getEligibleModels(zoneType)
    if self.modelCache[zoneType] ~= nil then
        return self.modelCache[zoneType]
    end

    local models = {}
    for _, storeItem in ipairs(g_storeManager:getItems()) do
        if TheContractorRepairContracts.isCandidateStoreItem(storeItem, zoneType) then
            local vehicleType = g_vehicleTypeManager:getObjectTypeFromXML(storeItem.xmlFilename)
            if vehicleType ~= nil and TheContractorRepairContracts.isTypeForZone(vehicleType.specializationsByName,
                    zoneType) then
                local size = StoreItemUtil.getSizeValues(storeItem.xmlFilename, "vehicle", storeItem.rotation or 0, {})
                table.insert(models, {
                    xmlFilename = storeItem.xmlFilename,
                    categoryName = storeItem.categoryName,
                    name = storeItem.name or storeItem.xmlFilename,
                    width = size.width or 3,
                    length = size.length or 5,
                    height = size.height or TCParking.DEFAULT_HEIGHT,
                    widthOffset = size.widthOffset or 0,
                    lengthOffset = size.lengthOffset or 0,
                })
            end
        end
    end
    table.sort(models, function(a, b)
        return a.xmlFilename < b.xmlFilename
    end)
    Logging.info("TheContractor: %d models for %s repair zones", #models, zoneType)
    self.modelCache[zoneType] = models
    return models
end

function TheContractorRepairContracts.fitsBay(model, bayArea)
    local clearance = TheContractorRepairContracts.CLEARANCE
    return bayArea ~= nil and model.width + clearance <= bayArea.width and model.length + clearance <= bayArea.length
end

-- The models this zone can get now: its type, its filter, its bays' size.
function TheContractorRepairContracts:getModelsForZone(zone)
    local bayArea = PlaceableTCRepairZone.getBayArea(zone, 1)
    local result = {}
    for _, model in ipairs(self:getEligibleModels(PlaceableTCRepairZone.getZoneType(zone))) do
        if TheContractorRepairContracts.fitsBay(model, bayArea) and
                PlaceableTCRepairZone.takesCategory(zone, model.categoryName) then
            table.insert(result, model)
        end
    end
    return result
end

-- The categories a zone's filter can pick from: those of the models that fit
-- it, plus whatever the filter already has. Sorted by title.
function TheContractorRepairContracts:getCategoryChoices(zone, filter)
    local seen, names = {}, {}
    local function add(name)
        if name ~= nil and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    local bayArea = PlaceableTCRepairZone.getBayArea(zone, 1)
    for _, model in ipairs(self:getEligibleModels(PlaceableTCRepairZone.getZoneType(zone))) do
        if TheContractorRepairContracts.fitsBay(model, bayArea) then
            add(model.categoryName)
        end
    end
    for _, name in ipairs(filter ~= nil and filter.categories or {}) do
        add(name)
    end
    table.sort(names, function(a, b)
        return TCParkingSlotFilter.getCategoryTitle(a) < TCParkingSlotFilter.getCategoryTitle(b)
    end)
    return names
end

-- The daily roll (server) -------------------------------------------------------------

function TheContractorRepairContracts:startDailyTick()
    if not g_currentMission:getIsServer() then
        return
    end
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
end

function TheContractorRepairContracts:stopDailyTick()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
end

-- Server, after the save's loaded: ADS calls us on every status change.
function TheContractorRepairContracts:startListening()
    if not g_currentMission:getIsServer() or self.isListening or not TCADSRepairContracts.isActive() then
        return
    end
    self.isListening = TCADSRepairContracts.registerListener(function(vehicle, status)
        self:onStatusChanged(vehicle, status)
    end) == true
end

function TheContractorRepairContracts:stopListening()
    if self.isListening then
        TCADSRepairContracts.unregisterListener()
        self.isListening = false
    end
end

function TheContractorRepairContracts.pickKind(random)
    local weights = TheContractorRepairContracts.KIND_WEIGHTS
    local total = weights.repair + weights.maintenance
    return random() * total < weights.repair and TCADSRepairContracts.KIND.REPAIR or
        TCADSRepairContracts.KIND.MAINTENANCE
end

-- 1-3, rising with the farm's standing (0-1): a new company mostly gets
-- severity 1, a top one mostly 3.
function TheContractorRepairContracts.pickSeverity(standing, random)
    local severity = math.floor(1 + standing * 2 + (random() - 0.5) + 0.5)
    return math.max(1, math.min(3, severity))
end

function TheContractorRepairContracts.rollSeed(random)
    return math.floor(random() * 2147483645) + 1
end

function TheContractorRepairContracts:queueArrival(farmId, zone, bayIndex, kind, severity)
    local models = self:getModelsForZone(zone)
    if #models == 0 then
        return nil
    end
    local model = models[math.random(1, #models)]
    local standing = g_currentMission.TheContractor.Reputation:getStanding(farmId)
    local entry = {
        farmId = farmId,
        zoneUniqueId = TheContractorRepairContracts.getZoneUniqueId(zone),
        bayIndex = bayIndex,
        xmlFilename = model.xmlFilename,
        kind = kind or TheContractorRepairContracts.pickKind(math.random),
        severity = severity or TheContractorRepairContracts.pickSeverity(standing, math.random),
        seed = TheContractorRepairContracts.rollSeed(math.random),
        queuedDay = g_currentMission.environment.currentMonotonicDay,
        attempts = 0,
        blockedDays = 0,
        waitMs = 0,
        isLoading = false,
    }
    table.insert(self.arrivals, entry)
    Logging.info("TheContractor: farm %d repair zone bay %d: %s (%s, severity %d) on its way", farmId, bayIndex,
        model.name, entry.kind, entry.severity)
    return entry
end

-- The first free bay of the farm's zones, or nil: zone, bayIndex.
function TheContractorRepairContracts:findFreeBay(farmId)
    for _, zone in ipairs(TheContractorRepairContracts.getZones(farmId)) do
        local zoneUniqueId = TheContractorRepairContracts.getZoneUniqueId(zone)
        for bayIndex = 1, PlaceableTCRepairZone.getBayCount(zone) do
            if not self:isBayTaken(zoneUniqueId, bayIndex) then
                return zone, bayIndex
            end
        end
    end
    return nil
end

function TheContractorRepairContracts:rollArrivals(farmId)
    for _, zone in ipairs(TheContractorRepairContracts.getZones(farmId)) do
        local zoneUniqueId = TheContractorRepairContracts.getZoneUniqueId(zone)
        if zoneUniqueId ~= nil then
            for bayIndex = 1, PlaceableTCRepairZone.getBayCount(zone) do
                if not self:isBayTaken(zoneUniqueId, bayIndex) and
                        math.random() < TheContractorRepairContracts.ARRIVAL_CHANCE then
                    self:queueArrival(farmId, zone, bayIndex)
                end
            end
        end
    end
end

function TheContractorRepairContracts:onDayChanged()
    local today = g_currentMission.environment.currentMonotonicDay

    -- Arrivals that can't be placed for days are given up.
    local kept = {}
    for _, entry in ipairs(self.arrivals) do
        if entry.blockedDays ~= nil and entry.blockedDays > 0 then
            entry.blockedDays = entry.blockedDays + 1
        end
        if entry.isLoading or (entry.blockedDays or 0) <= TheContractorRepairContracts.ARRIVAL_GIVE_UP_DAYS then
            table.insert(kept, entry)
        else
            Logging.info("TheContractor: farm %d repair zone bay %d had no room for days, arrival dropped",
                entry.farmId, entry.bayIndex)
        end
    end
    self.arrivals = kept

    if TCADSRepairContracts.isActive() then
        local tc = g_currentMission.TheContractor
        for _, farm in ipairs(g_farmManager:getFarms()) do
            if tc.Company:hasCompany(farm.farmId) then
                self:rollArrivals(farm.farmId)
            end
        end
        self:checkAllStatuses()
    end

    local remaining = {}
    for _, claim in ipairs(self.pendingClaims) do
        if claim.notifyDay <= today then
            self:deliverClaim(claim)
        else
            table.insert(remaining, claim)
        end
    end
    self.pendingClaims = remaining
end

-- Placing and collecting (server) ---------------------------------------------------------

-- Whether the player can see a bay, in single player: their camera, within
-- TCIdleStaff's range (a dot product and a projection, no raycasts). In
-- multiplayer there's no check at all (the user's call, to keep it
-- simple): machines arrive and leave whether anyone's looking or not.
function TheContractorRepairContracts.isBaySeen(bayArea)
    local mission = g_currentMission
    local dynamicInfo = mission.missionDynamicInfo
    if dynamicInfo ~= nil and dynamicInfo.isMultiplayer == true then
        return false
    end
    if not mission:getIsClient() or g_cameraManager == nil then
        return false
    end
    local camera = g_cameraManager:getActiveCamera()
    if camera == nil or camera == 0 then
        return false
    end
    local x, z = PlaceableTCRepairZone.getAreaCentre(bayArea)
    local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    local cx, cy, cz = getWorldTranslation(camera)
    return TCIdleStaff.isSeen({ x = x, y = y, z = z }, camera, cx, cy, cz)
end

function TheContractorRepairContracts:update(dt)
    if not g_currentMission:getIsServer() or (#self.arrivals == 0 and #self.removals == 0) then
        return
    end
    self.checkMs = self.checkMs + dt
    if self.checkMs < TheContractorRepairContracts.PLACE_CHECK_MS then
        return
    end
    local elapsed = self.checkMs
    self.checkMs = 0

    for _, entry in ipairs(self:copyList(self.arrivals)) do
        if not entry.isLoading then
            self:tryPlaceArrival(entry, elapsed)
        end
    end
    for _, entry in ipairs(self:copyList(self.removals)) do
        self:tryCollect(entry, elapsed)
    end
end

function TheContractorRepairContracts:copyList(list)
    local copy = {}
    for i, value in ipairs(list) do
        copy[i] = value
    end
    return copy
end

local function removeFrom(list, entry)
    for i, value in ipairs(list) do
        if value == entry then
            table.remove(list, i)
            return true
        end
    end
    return false
end

-- Whether a queued arrival or a collection may go ahead now: its bay unseen,
-- or it's waited long enough.
local function isReady(entry, bayArea, elapsed)
    entry.waitMs = (entry.waitMs or 0) + elapsed
    return entry.waitMs >= TheContractorRepairContracts.PLACE_FALLBACK_MS or
        not TheContractorRepairContracts.isBaySeen(bayArea)
end

function TheContractorRepairContracts:findModel(entry, zone)
    for _, model in ipairs(self:getEligibleModels(PlaceableTCRepairZone.getZoneType(zone))) do
        if model.xmlFilename == entry.xmlFilename then
            return model
        end
    end
    return nil
end

-- The spawn pose for a model in a bay: its origin x, z (the footprint
-- centred in the bay, offsets as in TCParking.findSpot), the bay's centre,
-- and the facing.
function TheContractorRepairContracts.getSpawnPose(model, bayArea)
    local centreX, centreZ = PlaceableTCRepairZone.getAreaCentre(bayArea)
    local rotY = MathUtil.getYRotationFromDirection(bayArea.vX, bayArea.vZ)
    local originX = centreX - bayArea.uX * model.widthOffset - bayArea.vX * model.lengthOffset
    local originZ = centreZ - bayArea.uZ * model.widthOffset - bayArea.vZ * model.lengthOffset
    return originX, originZ, centreX, centreZ, rotY
end

function TheContractorRepairContracts:tryPlaceArrival(entry, elapsed)
    local zone = TheContractorRepairContracts.getZoneByUniqueId(entry.zoneUniqueId)
    local bayArea = zone ~= nil and PlaceableTCRepairZone.getBayArea(zone, entry.bayIndex) or nil
    local model = zone ~= nil and self:findModel(entry, zone) or nil
    local storeItem = model ~= nil and g_storeManager:getItemByXMLFilename(model.xmlFilename) or nil
    if bayArea == nil or storeItem == nil or not TCADSRepairContracts.isActive() then
        -- The zone's been sold or shrunk, or the model's gone.
        removeFrom(self.arrivals, entry)
        return
    end
    if not isReady(entry, bayArea, elapsed) then
        return
    end

    local originX, originZ, centreX, centreZ, rotY = TheContractorRepairContracts.getSpawnPose(model, bayArea)
    local clearance = TheContractorRepairContracts.CLEARANCE
    if not TCParking.isAreaClear(centreX, centreZ, rotY, model.width + clearance, model.length + clearance,
            model.height) then
        -- Something's in the bay: try again tomorrow, then give up.
        entry.blockedDays = math.max(1, entry.blockedDays or 0)
        entry.waitMs = 0
        return
    end
    entry.blockedDays = 0

    local loadingData = VehicleLoadingData.new()
    loadingData:setStoreItem(storeItem)
    loadingData:setIgnoreShopOffset(true)
    loadingData:setPosition(originX, nil, originZ, TCParking.PLACE_HEIGHT_OFFSET)
    loadingData:setRotation(0, rotY, 0)
    loadingData:setPropertyState(VehiclePropertyState.MISSION)
    loadingData:setOwnerFarmId(entry.farmId)
    entry.isLoading = true
    loadingData:load(self.onArrivalLoaded, self, { entry = entry })
end

-- A model ADS turned down: another one, another seed, up to PREPARE_RETRIES.
function TheContractorRepairContracts:retryArrival(entry, zone, reason)
    entry.attempts = (entry.attempts or 0) + 1
    if entry.attempts > TheContractorRepairContracts.PREPARE_RETRIES or zone == nil then
        Logging.info("TheContractor: farm %d repair zone bay %d: arrival dropped (%s)", entry.farmId, entry.bayIndex,
            tostring(reason))
        removeFrom(self.arrivals, entry)
        return
    end
    local models = self:getModelsForZone(zone)
    if #models == 0 then
        removeFrom(self.arrivals, entry)
        return
    end
    entry.xmlFilename = models[math.random(1, #models)].xmlFilename
    entry.seed = TheContractorRepairContracts.rollSeed(math.random)
    -- Straight away next time: the bay was already out of sight.
    entry.waitMs = TheContractorRepairContracts.PLACE_FALLBACK_MS
end

-- VehicleLoadingData's callback.
function TheContractorRepairContracts:onArrivalLoaded(vehicles, loadingState, args)
    local entry = args.entry
    entry.isLoading = false
    local vehicle = vehicles ~= nil and vehicles[1] or nil

    local isQueued = false
    for _, queued in ipairs(self.arrivals) do
        isQueued = isQueued or queued == entry
    end
    local zone = TheContractorRepairContracts.getZoneByUniqueId(entry.zoneUniqueId)
    if not isQueued or zone == nil then
        if vehicle ~= nil then
            vehicle:delete()
        end
        removeFrom(self.arrivals, entry)
        return
    end
    if vehicle == nil or loadingState ~= VehicleLoadingState.OK then
        self:retryArrival(entry, zone, "loadFailed")
        return
    end

    local ok, result = TCADSRepairContracts.prepareVehicle(vehicle, {
        kind = entry.kind,
        severity = entry.severity,
        seed = entry.seed,
        ref = string.format("TheContractor:%d:%d", entry.farmId, entry.seed),
    })
    local quote = ok and TCADSRepairContracts.getQuote(vehicle) or nil
    if not ok or quote == nil or (tonumber(quote.price) or 0) <= 0 then
        if ok then
            TCADSRepairContracts.release(vehicle)
        end
        vehicle:delete()
        self:retryArrival(entry, zone, ok and "noQuote" or result)
        return
    end

    removeFrom(self.arrivals, entry)
    self:createOffer(entry, vehicle, quote)
end

-- The job's base price (without FS25_EconomyScale's factor, as every job
-- stores it): ADS's quote is at the price level of the day it was made, so
-- it's divided back out, then the margin goes on.
function TheContractorRepairContracts.getBasePrice(quotePrice, margin)
    return quotePrice / TCEconomyScale.getFactor() * (1 + margin)
end

function TheContractorRepairContracts:createOffer(entry, vehicle, quote)
    local today = g_currentMission.environment.currentMonotonicDay
    local margin = TheContractorRepairContracts.MARGIN_MIN +
        math.random() * (TheContractorRepairContracts.MARGIN_MAX - TheContractorRepairContracts.MARGIN_MIN)
    local price = math.floor(TheContractorRepairContracts.getBasePrice(quote.price, margin))
    local deadlineDay = today + TheContractorRepairContracts.OFFER_DAYS + TheContractorRepairContracts.DUE_DAYS
    local workshop = {
        vehicleId = NetworkUtil.getObjectId(vehicle),
        vehicleUniqueId = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or nil,
        vehicleName = vehicle:getFullName(),
        zoneUniqueId = entry.zoneUniqueId,
        bayIndex = entry.bayIndex,
        kind = entry.kind,
        severity = entry.severity,
        offerExpiresDay = today + TheContractorRepairContracts.OFFER_DAYS,
        quotePrice = quote.price,
        requiredTools = quote.minTools or {},
        serviceLevel = quote.serviceLevel,
        operatingHours = quote.operatingHours,
    }

    local environment = g_currentMission.environment
    local job = g_currentMission.TheContractor.Jobs:createJob(entry.farmId, TheContractorRepairContracts.JOB_TYPES[entry.kind],
        0, 1, environment:getPeriodFromDay(deadlineDay), environment:getDayInPeriodFromDay(deadlineDay), price, true,
        nil, deadlineDay, false, nil, nil, workshop)
    if job == nil then
        TCADSRepairContracts.release(vehicle)
        vehicle:delete()
        return
    end
    Logging.info("TheContractor: farm %d job %d: %s in for %s, quoted %.0f, offered %.0f", entry.farmId, job.id,
        workshop.vehicleName, entry.kind, quote.price, job:getPrice())
end

-- Server: the customer comes for their machine (an offer turned down or
-- lapsed, or a job finished or missed). The contract comes off now; the
-- machine goes once its bay's out of sight.
function TheContractorRepairContracts:queueCollection(job)
    local workshop = job.workshop
    if workshop == nil then
        return
    end
    local vehicle = TheContractorRepairContracts.getVehicle(job)
    if vehicle ~= nil then
        TCADSRepairContracts.release(vehicle)
    end
    for _, entry in ipairs(self.removals) do
        if entry.vehicleId == workshop.vehicleId then
            return
        end
    end
    table.insert(self.removals, {
        farmId = job.farmId,
        vehicleId = workshop.vehicleId,
        uniqueId = workshop.vehicleUniqueId,
        zoneUniqueId = workshop.zoneUniqueId,
        bayIndex = workshop.bayIndex,
        waitMs = 0,
    })
end

function TheContractorRepairContracts:tryCollect(entry, elapsed)
    local vehicle = entry.vehicleId ~= nil and entry.vehicleId ~= 0 and NetworkUtil.getObject(entry.vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        removeFrom(self.removals, entry)
        return
    end
    -- Not from under someone driving it.
    if vehicle.getIsControlled ~= nil and vehicle:getIsControlled() then
        entry.waitMs = 0
        return
    end
    local zone = TheContractorRepairContracts.getZoneByUniqueId(entry.zoneUniqueId)
    local bayArea = zone ~= nil and PlaceableTCRepairZone.getBayArea(zone, entry.bayIndex) or nil
    if bayArea == nil then
        -- Its zone's gone: judge the machine where it stands.
        local x, _, z = getWorldTranslation(vehicle.rootNode)
        bayArea = { x = x, z = z, uX = 1, uZ = 0, vX = 0, vZ = 1, width = 0, length = 0 }
    end
    if not isReady(entry, bayArea, elapsed) then
        return
    end
    removeFrom(self.removals, entry)
    Logging.info("TheContractor: farm %d: the customer collected %s", entry.farmId, vehicle:getFullName())
    vehicle:delete()
end

-- Completion (server) ------------------------------------------------------------------

function TheContractorRepairContracts:getJobForVehicle(vehicle)
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    local job = vehicleId ~= nil and TheContractorRepairContracts.getContractVehicleIds()[vehicleId] or nil
    if job == nil or job:isTerminal() then
        return nil
    end
    return job
end

-- ADS's listener: an accepted job whose machine is done is completed. An
-- excluded machine (invalid) ends the job with no penalty.
function TheContractorRepairContracts:onStatusChanged(vehicle, status)
    local job = self:getJobForVehicle(vehicle)
    if job == nil or job.state ~= TheContractorJob.STATE.ACCEPTED or status == nil then
        return
    end
    local jobs = g_currentMission.TheContractor.Jobs
    if status.state == TCADSRepairContracts.STATE.DONE then
        jobs:completeJob(job, true)
    elseif status.state == TCADSRepairContracts.STATE.INVALID then
        jobs:missJob(job, true)
    end
end

-- One job against ADS's status now (Jobs:onJobAccepted: work done before
-- the offer was taken counts at once).
function TheContractorRepairContracts:checkJob(job)
    local vehicle = TheContractorRepairContracts.getVehicle(job)
    if vehicle ~= nil then
        self:onStatusChanged(vehicle, TCADSRepairContracts.getStatus(vehicle))
    end
end

-- Every accepted workshop job against ADS's status now: after a load (the
-- listener never fires for a status reached before the save) and daily.
function TheContractorRepairContracts:checkAllStatuses()
    if not TCADSRepairContracts.isActive() then
        return
    end
    local jobs = g_currentMission.TheContractor.Jobs
    for _, farmJobs in pairs(jobs.jobsByFarm) do
        local open = {}
        for _, job in pairs(farmJobs) do
            if job.workshop ~= nil and job.state == TheContractorJob.STATE.ACCEPTED then
                table.insert(open, job)
            end
        end
        for _, job in ipairs(open) do
            local vehicle = TheContractorRepairContracts.getVehicle(job)
            if vehicle ~= nil then
                self:onStatusChanged(vehicle, TCADSRepairContracts.getStatus(vehicle))
            end
        end
    end
end

-- The base reputation reward for a finished workshop job, before quality.
function TheContractorRepairContracts.getBaseReputation(job)
    local bySeverity = TheContractorRepairContracts.REPUTATION_BY_SEVERITY
    local severity = job.workshop ~= nil and job.workshop.severity or 1
    return bySeverity[math.max(1, math.min(#bySeverity, severity))]
end

-- Tampering (server) ------------------------------------------------------------------

-- What a tampered machine lost: each worse component's lost resource at
-- ADS's OEM part price, and TAMPER_PART_VALUE for a weakened battery, a
-- removed part, or a component ADS can't price.
function TheContractorRepairContracts.getTamperValue(vehicle, findings)
    local settings = g_currentMission.TheContractor.Settings
    local partValue = settings:scaleCost(TheContractorRepairContracts.TAMPER_PART_VALUE)
    local total = 0
    for _, finding in ipairs(findings or {}) do
        if finding.kind == "component" then
            local price = TCADSRepairContracts.getPartPrice(vehicle, finding.id)
            local lost = math.max(0, (tonumber(finding.accepted) or 0) - (tonumber(finding.current) or 0))
            total = total + (price ~= nil and price * lost or partValue)
        else
            total = total + partValue
        end
    end
    return total
end

-- From Jobs:missJob, before the penalty's taken: a machine still worse
-- than it arrived means a bigger penalty and maybe a claim. Returns the
-- penalty to take.
function TheContractorRepairContracts:judgeTampering(job, penalty)
    local vehicle = TheContractorRepairContracts.getVehicle(job)
    local status = vehicle ~= nil and TCADSRepairContracts.getStatus(vehicle) or nil
    if status == nil or status.state ~= TCADSRepairContracts.STATE.TAMPERED then
        return penalty
    end

    local _, findings = TCADSRepairContracts.checkTampering(vehicle)
    local value = TheContractorRepairContracts.getTamperValue(vehicle, findings)
    local tc = g_currentMission.TheContractor
    local threshold = tc.Settings:scaleCost(TheContractorRepairContracts.TAMPER_CLAIM_THRESHOLD)
    local claimAmount = 0
    if value >= threshold then
        claimAmount = value
        if tc.Association:hasLegalCover(job.farmId) then
            claimAmount = claimAmount * TheContractorRepairContracts.TAMPER_LEGAL_COVER_FACTOR
        end
        claimAmount = math.floor(claimAmount)
        local delay = TheContractorRepairContracts.TAMPER_CLAIM_DELAY
        table.insert(self.pendingClaims, {
            farmId = job.farmId,
            jobId = job.id,
            vehicleName = job.workshop.vehicleName,
            amount = claimAmount,
            notifyDay = g_currentMission.environment.currentMonotonicDay + math.random(delay[1], delay[2]),
        })
    end

    local tamperPenalty = math.floor(penalty * TheContractorRepairContracts.TAMPER_REPUTATION_MULTIPLIER)
    tc.Inbox:postMessage(job.farmId, TheContractorRepairContracts.MESSAGE_KIND, "tc_repair_tamperedTitle",
        claimAmount > 0 and "tc_repair_tamperedBodyClaim" or "tc_repair_tamperedBody",
        { job.workshop.vehicleName, tamperPenalty }, nil, { jobId = job.id })
    Logging.info("TheContractor: farm %d job %d: %s went back tampered with (%d finding(s), %.0f lost), -%d reputation%s",
        job.farmId, job.id, job.workshop.vehicleName, #(findings or {}), value, tamperPenalty,
        claimAmount > 0 and string.format(", claim of %.0f to come", claimAmount) or "")
    return tamperPenalty
end

function TheContractorRepairContracts:deliverClaim(claim)
    local tc = g_currentMission.TheContractor
    if g_farmManager:getFarmById(claim.farmId) == nil then
        return
    end
    local paid = tc.Claims:chargeClaim(claim.farmId, claim.amount, false)
    tc.Claims:addToJobLog(claim.farmId, claim.jobId, { cause = TheContractorRepairContracts.CLAIM_CAUSE,
        amount = claim.amount, paid = paid, insured = false, reputationPenalty = 0 })
    tc.Inbox:postMessage(claim.farmId, TheContractorRepairContracts.MESSAGE_KIND, "tc_repair_claimTitle",
        tc.Association:hasLegalCover(claim.farmId) and "tc_repair_claimBodyLegal" or "tc_repair_claimBody",
        { claim.vehicleName, "$money_" .. paid }, nil, { jobId = claim.jobId })
    tc.Notices:publish(claim.farmId, string.format(g_i18n:getText("tc_repair_claimNotice"), claim.vehicleName,
        g_i18n:formatMoney(paid, 0, true, true)), TheContractorRepairContracts.NOTICE_MONTHS)
    Logging.info("TheContractor: farm %d tamper claim for job %d: %.0f paid", claim.farmId, claim.jobId, paid)
end

-- Persistence (server) -------------------------------------------------------------------

function TheContractorRepairContracts:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    self.arrivals, self.removals, self.pendingClaims = {}, {}, {}
    local rootKey = TheContractor.SaveKey .. ".repairContracts"

    local index = 0
    while true do
        local key = string.format("%s.arrival(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        table.insert(self.arrivals, {
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            zoneUniqueId = getXMLString(xmlFile, key .. "#zoneUniqueId"),
            bayIndex = getXMLInt(xmlFile, key .. "#bayIndex"),
            xmlFilename = getXMLString(xmlFile, key .. "#xmlFilename"),
            kind = getXMLString(xmlFile, key .. "#kind"),
            severity = Utils.getNoNil(getXMLInt(xmlFile, key .. "#severity"), 1),
            seed = getXMLInt(xmlFile, key .. "#seed"),
            queuedDay = Utils.getNoNil(getXMLInt(xmlFile, key .. "#queuedDay"), 0),
            attempts = Utils.getNoNil(getXMLInt(xmlFile, key .. "#attempts"), 0),
            blockedDays = Utils.getNoNil(getXMLInt(xmlFile, key .. "#blockedDays"), 0),
            waitMs = 0,
            isLoading = false,
        })
        index = index + 1
    end

    index = 0
    while true do
        local key = string.format("%s.collection(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        table.insert(self.removals, {
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            uniqueId = getXMLString(xmlFile, key .. "#uniqueId"),
            zoneUniqueId = getXMLString(xmlFile, key .. "#zoneUniqueId"),
            bayIndex = getXMLInt(xmlFile, key .. "#bayIndex"),
            waitMs = 0,
        })
        index = index + 1
    end

    index = 0
    while true do
        local key = string.format("%s.claim(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        table.insert(self.pendingClaims, {
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            jobId = getXMLInt(xmlFile, key .. "#jobId"),
            vehicleName = Utils.getNoNil(getXMLString(xmlFile, key .. "#vehicleName"), ""),
            amount = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#amount"), 0),
            notifyDay = Utils.getNoNil(getXMLInt(xmlFile, key .. "#notifyDay"), 0),
        })
        index = index + 1
    end
end

function TheContractorRepairContracts:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local rootKey = TheContractor.SaveKey .. ".repairContracts"

    local index = 0
    for _, entry in ipairs(self.arrivals) do
        if entry.zoneUniqueId ~= nil and entry.xmlFilename ~= nil then
            local key = string.format("%s.arrival(%d)", rootKey, index)
            setXMLInt(xmlFile, key .. "#farmId", entry.farmId)
            setXMLString(xmlFile, key .. "#zoneUniqueId", entry.zoneUniqueId)
            setXMLInt(xmlFile, key .. "#bayIndex", entry.bayIndex)
            setXMLString(xmlFile, key .. "#xmlFilename", entry.xmlFilename)
            setXMLString(xmlFile, key .. "#kind", entry.kind)
            setXMLInt(xmlFile, key .. "#severity", entry.severity)
            setXMLInt(xmlFile, key .. "#seed", entry.seed)
            setXMLInt(xmlFile, key .. "#queuedDay", entry.queuedDay)
            setXMLInt(xmlFile, key .. "#attempts", entry.attempts or 0)
            setXMLInt(xmlFile, key .. "#blockedDays", entry.blockedDays or 0)
            index = index + 1
        end
    end

    index = 0
    for _, entry in ipairs(self.removals) do
        local uniqueId = entry.uniqueId
        if uniqueId == nil and entry.vehicleId ~= nil then
            uniqueId = TCVehicleIds.getUniqueId(entry.vehicleId)
        end
        if uniqueId ~= nil then
            local key = string.format("%s.collection(%d)", rootKey, index)
            setXMLInt(xmlFile, key .. "#farmId", entry.farmId)
            setXMLString(xmlFile, key .. "#uniqueId", uniqueId)
            if entry.zoneUniqueId ~= nil then
                setXMLString(xmlFile, key .. "#zoneUniqueId", entry.zoneUniqueId)
            end
            if entry.bayIndex ~= nil then
                setXMLInt(xmlFile, key .. "#bayIndex", entry.bayIndex)
            end
            index = index + 1
        end
    end

    for i, claim in ipairs(self.pendingClaims) do
        local key = string.format("%s.claim(%d)", rootKey, i - 1)
        setXMLInt(xmlFile, key .. "#farmId", claim.farmId)
        setXMLInt(xmlFile, key .. "#jobId", claim.jobId)
        setXMLString(xmlFile, key .. "#vehicleName", claim.vehicleName)
        setXMLFloat(xmlFile, key .. "#amount", claim.amount)
        setXMLInt(xmlFile, key .. "#notifyDay", claim.notifyDay)
    end
end

-- Server, once vehicles exist (TheContractor:resolveSavedVehicles, after
-- Jobs'): machines waiting to be collected get their object ids back, and
-- every open job is checked against ADS (its listener never fires for a
-- status reached before the save).
function TheContractorRepairContracts:resolveSavedVehicles()
    for _, entry in ipairs(self.removals) do
        if entry.vehicleId == nil and entry.uniqueId ~= nil then
            entry.vehicleId = TCVehicleIds.getObjectId(entry.uniqueId)
        end
    end
    self:startListening()
    self:checkAllStatuses()
end

-- Console (tcJob) ------------------------------------------------------------------------

function TheContractorRepairContracts.registerConsoleCommands()
    TCConsole.register("job", "repairArrival", {
        args = "[repair|maintenance] [severity 1-3]",
        description = "Send a customer's machine to your first free repair zone bay now (placed out of sight, or after the usual wait)",
        run = function(farmId, args)
            local kind = args[1] ~= nil and string.lower(args[1]) or nil
            if kind ~= nil and TheContractorRepairContracts.JOB_TYPES[kind] == nil then
                return false
            end
            local severity = tonumber(args[2])
            if args[2] ~= nil and (severity == nil or severity < 1 or severity > 3) then
                return false
            end
            if not TCADSRepairContracts.isActive() then
                return TCADSRepairContracts.describe()
            end
            local repairContracts = g_currentMission.TheContractor.RepairContracts
            local zone, bayIndex = repairContracts:findFreeBay(farmId)
            if zone == nil then
                return string.format("Farm %d has no free repair zone bay.", farmId)
            end
            local entry = repairContracts:queueArrival(farmId, zone, bayIndex, kind, severity and math.floor(severity))
            if entry == nil then
                return "No model fits that zone (check its filter)."
            end
            return string.format("Queued %s (%s, severity %d) for bay %d.", entry.xmlFilename, entry.kind,
                entry.severity, bayIndex)
        end,
    })

    TCConsole.register("job", "repairStatus", {
        args = "",
        description = "Your repair zones, their bays, and machines on the way or waiting to be collected",
        run = function(farmId, args)
            local repairContracts = g_currentMission.TheContractor.RepairContracts
            local lines = { TCADSRepairContracts.describe() }
            for i, zone in ipairs(TheContractorRepairContracts.getZones(farmId)) do
                local filter = PlaceableTCRepairZone.getFilter(zone)
                table.insert(lines, string.format("Zone %d (%s, %d bay(s), %s, %d model(s)):", i,
                    PlaceableTCRepairZone.getZoneType(zone), PlaceableTCRepairZone.getBayCount(zone),
                    #filter.categories > 0 and table.concat(filter.categories, "/") or "any category",
                    #repairContracts:getModelsForZone(zone)))
                local zoneUniqueId = TheContractorRepairContracts.getZoneUniqueId(zone)
                for bayIndex = 1, PlaceableTCRepairZone.getBayCount(zone) do
                    table.insert(lines, string.format("  bay %d: %s", bayIndex,
                        repairContracts:isBayTaken(zoneUniqueId, bayIndex) and "taken" or "free"))
                end
            end
            table.insert(lines, string.format("%d on the way, %d waiting to be collected, %d claim(s) to come",
                #repairContracts.arrivals, #repairContracts.removals, #repairContracts.pendingClaims))
            return table.concat(lines, "\n")
        end,
    })
end
