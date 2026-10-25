-- ADS repair contracts (100): customers' machines turn up in the farm's
-- repair zones (PlaceableTCRepairZone) for a repair or a service, each with
-- a job offer. FS25_AdvancedDamageSystem does the vehicle side through
-- TCADSRepairContracts: it ages and breaks the machine, prices the work,
-- says what tools it takes and whether the farm has them, and reports when
-- it's done or tampered with. See tickets/100 and docs/ads-repair-contracts.md.
--
-- Arrivals (server): every day each empty bay of a farm's zones may get a
-- customer (ARRIVAL_CHANCE), queued with its model, kind, severity and seed.
-- A queued arrival is spawned on the next look at the queue
-- (PLACE_CHECK_MS), seen or not. Then ADS prepares it and the offer goes
-- up. Nothing runs while the queue is empty.
--
-- 102: inspect, negotiate, then accept. ADS keeps the machine in its
-- inspection stage (inspections only) until we authorize it. Once it's
-- been inspected (TCADSRepairContracts.isInspected) the player picks a
-- margin in the Negotiate dialog: the price is the cheapest fix's cost
-- (ADS's parts plus its labour hours at LABOUR_RATE, getBaseCost) plus the
-- margin, never under MIN_PRICE (every margin that comes to MIN_PRICE is
-- one "minimum charge" option, which the customer always accepts and which
-- never costs reputation or counts as overcharging). The customer answers
-- once (proposeQuote): at or under their ceiling (rolled per offer) the
-- job's accepted at that price and ADS authorizes the work; over it they
-- take the machine away.
-- The margin against the setting (the benchmark) scales the completion
-- reputation (getMarginFactor), and finishing one far over it marks the
-- farm as overcharging for OVERCHARGE_MONTHS, which slows its workshop
-- arrivals. Missing tools never block anything: the dealer can always do
-- the work, at a price.
--
-- The job (Jobs, job.workshop): fieldId 0 (a breakdown's field is
-- workshop.fieldId), no crew, offered -> accepted (through proposeQuote
-- only) -> completed or missed. It completes when ADS says done (its listener, plus a
-- pass after load and every day, since ADS's listener never fires for a
-- status reached before the save). An accepted job that can't be worked
-- after a load (machine gone, no ADS, no contract) ends then with no
-- penalty (endUnworkableJobs). When it ends the customer takes the
-- machine back: the contract is released and the machine is deleted on the
-- next look at the queue (unless someone's driving it).
--
-- Tampering is judged once, at the deadline (Jobs:missJob): a machine
-- that's still worse than it arrived means no pay, TAMPER_REPUTATION_MULTIPLIER
-- times a miss's reputation loss, and over TAMPER_CLAIM_THRESHOLD of damage a
-- compensation claim a few days later, never insured (public liability
-- doesn't cover deliberate acts), cut by legal cover (053).
--
-- Field breakdowns (101, TheContractorFieldBreakdowns) use the same queue
-- with a spot on a field instead of a bay (entry.fieldId), ADS's breakdown
-- kind, and an offer due the same day. What they need is the kit that can
-- work in a field (getBreakdownProblem, a warning), not the workshop's tools.
--
-- State (server, saved in TheContractor.xml): the arrivals queue, the
-- machines waiting to be collected, pending tamper claims and which farms
-- are known for overcharging. Clients only ever see the jobs (and the
-- overcharging notice).

TheContractorRepairContracts = {}
TheContractorRepairContracts_mt = Class(TheContractorRepairContracts)

-- ADS kind -> our job type (JobGeneration.JOB_TYPES).
TheContractorRepairContracts.JOB_TYPES = {
    repair = "adsRepair",
    maintenance = "adsMaintenance",
    breakdown = "adsBreakdown",
}

-- The chance an empty bay gets a customer each day, and what they want.
TheContractorRepairContracts.ARRIVAL_CHANCE = 0.5
TheContractorRepairContracts.KIND_WEIGHTS = { repair = 65, maintenance = 35 }
-- How likely each severity (1-3) is, whatever the farm's reputation.
TheContractorRepairContracts.SEVERITY_WEIGHTS = { 20, 30, 50 }

-- Days after today the work is due by (the end of): MIN_DUE_DAYS at 1-2
-- days per period, rising to MAX_DUE_DAYS at FULL_DUE_DAYS_PER_PERIOD or
-- more. The offer stays open until the day before.
TheContractorRepairContracts.MIN_DUE_DAYS = 2
TheContractorRepairContracts.MAX_DUE_DAYS = 4
TheContractorRepairContracts.FULL_DUE_DAYS_PER_PERIOD = 5

-- 102: the price. The cost is the cheapest fix's, the one ADS's quote
-- prices (a repair wherever one's allowed): its parts and materials, plus
-- its labour hours at LABOUR_RATE (1x UK, scaleCost), since a repair in ADS
-- is labour only. The player adds a margin from 0 to MARGIN_MAX in
-- MARGIN_STEP steps, starting at the adsWorkshopMargin setting or
-- adsFieldMargin for a field breakdown (the benchmark). The quote itself
-- (the dealer's whole bill) is never shown.
TheContractorRepairContracts.LABOUR_RATE = 60
TheContractorRepairContracts.MARGIN_MAX = 2.0
TheContractorRepairContracts.MARGIN_STEP = 0.05
-- The least a job pays (base, before FS25_EconomyScale's factor): an
-- inspection alone takes a couple of hours, however few the parts.
TheContractorRepairContracts.MIN_PRICE = 750
-- The customer's ceiling, rolled per offer and never shown: this range
-- times the benchmark margin (80-120% at a 40% benchmark).
TheContractorRepairContracts.REFUSAL_FACTOR = { 2.0, 3.0 }
-- Reputation by margin (getMarginFactor): { margin as a multiple of the
-- benchmark, reputation factor }, straight lines between, flat past the
-- last. Below 0 the job costs that share of its base reputation.
TheContractorRepairContracts.MARGIN_FACTOR_POINTS = { { 0, 1.25 }, { 1, 1.0 }, { 2, 0 }, { 3, -0.5 } }
-- The least the benchmark counts as, so a 0% setting still has a curve.
TheContractorRepairContracts.MIN_BENCHMARK = 0.05
-- What the Negotiate dialog calls a margin: fair up to the benchmark,
-- steep up to OVERCHARGE_MARGIN_FACTOR times it, a rip-off beyond.
-- Overcharging: a job finished at or over OVERCHARGE_MARGIN_FACTOR times
-- the benchmark marks the farm for OVERCHARGE_MONTHS (restarted by each
-- one), and while it lasts the farm's workshop arrivals (repair zones and
-- 101's breakdowns) come OVERCHARGE_ARRIVAL_FACTOR as often.
TheContractorRepairContracts.OVERCHARGE_MARGIN_FACTOR = 1.75
TheContractorRepairContracts.OVERCHARGE_MONTHS = 3
TheContractorRepairContracts.OVERCHARGE_ARRIVAL_FACTOR = 0.5
-- tcJob quoteOutcome's forced answers.
TheContractorRepairContracts.QUOTE_OUTCOME = { ACCEPTED = "accepted", REFUSED = "refused" }

-- Base reputation for a finished job, by kind and severity (1-3), before
-- quality and speed: a service is routine, a repair more, and a field
-- breakdown (101) most, a customer stuck mid-job. A missed job's penalty
-- is worked out from this too (never with the speed factor).
TheContractorRepairContracts.REPUTATION_BY_KIND = {
    maintenance = { 1, 2, 3 },
    repair = { 3, 5, 7 },
    breakdown = { 5, 8, 12 },
}
-- Speed: a repair or breakdown finished within SPEED_FAST_SHARE of the time
-- it had (from acceptance to the end of its due day) earns its kind's
-- SPEED_MAX_FACTOR times the reputation, one using SPEED_SLOW_SHARE or more
-- earns the plain amount, and in between is on a straight line. A share of
-- the time, not hours, so it follows the due days (and so days per period).
-- A service has no entry: nobody's waiting on it.
TheContractorRepairContracts.SPEED_MAX_FACTOR = { repair = 1.5, breakdown = 1.5 }
TheContractorRepairContracts.SPEED_FAST_SHARE = 0.25
TheContractorRepairContracts.SPEED_SLOW_SHARE = 0.75

-- Placing and collecting: how often the queue is looked at.
TheContractorRepairContracts.PLACE_CHECK_MS = 2000
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
    -- severity, seed, queuedDay, attempts, blockedDays, isLoading }.
    self.arrivals = {}
    -- Server, saved: machines waiting to be collected: { farmId, vehicleId,
    -- uniqueId, zoneUniqueId, bayIndex }.
    self.removals = {}
    -- Server, saved: { farmId, jobId, vehicleName, amount, notifyDay }.
    self.pendingClaims = {}
    -- 102, server, saved: farmId -> { untilDay, noticeId } while the farm's
    -- known for overcharging.
    self.overcharged = {}
    -- 102, server: tcJob quoteOutcome's answer for the next quote, or nil.
    self.forcedQuoteOutcome = nil

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

-- 101: a customer's machine broken down on a field.
function TheContractorRepairContracts.isBreakdownJob(job)
    return job ~= nil and job.workshop ~= nil and job.workshop.kind == TCADSRepairContracts.KIND.BREAKDOWN
end

-- 101: the farm's places that can fix a breakdown on the spot: the tool box
-- or the farm's own mobile workshop for a "player" one, only the van for a
-- "mobile" one (ADS's field service level).
function TheContractorRepairContracts.getBreakdownPlaces(fieldService)
    local place = TCADSRepairContracts.PLACE
    if fieldService == TCADSRepairContracts.FIELD_SERVICE.MOBILE then
        return { place.OWN_MOBILE }
    end
    return { place.PLAYER, place.OWN_MOBILE }
end

function TheContractorRepairContracts.hasBreakdownKit(farmId, fieldService)
    local places = TCADSRepairContracts.getFarmPlaces(farmId)
    for _, placeId in ipairs(TheContractorRepairContracts.getBreakdownPlaces(fieldService)) do
        if places[placeId] then
            return true
        end
    end
    return false
end

-- The l10n suffix for what a breakdown needs: "toolBox" (a tool box or a
-- van) or "mobile" (a van).
function TheContractorRepairContracts.getBreakdownKitKey(fieldService)
    return fieldService == TCADSRepairContracts.FIELD_SERVICE.MOBILE and "mobile" or "toolBox"
end

-- "Without an ADS tool box or a mobile workshop of your own, ...", or nil.
-- 102: a warning, not a block: a hired mobile workshop can always go out.
function TheContractorRepairContracts.getBreakdownProblem(job)
    local fieldService = job.workshop.serviceLevel
    if TheContractorRepairContracts.hasBreakdownKit(job.farmId, fieldService) then
        return nil
    end
    return string.format(g_i18n:getText("tc_breakdown_noKitWarning"),
        g_i18n:getText("tc_breakdown_kit_" .. TheContractorRepairContracts.getBreakdownKitKey(fieldService)))
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

-- Whether a machine is a customer's the farm can work on now: its job still
-- open, and the machine with that farm. Workshops (vanilla's and service
-- vehicle mods') only list vehicles that show in the vehicles overview, and
-- that's OWNED or LEASED, never MISSION, so each is told about these.
function TheContractorRepairContracts.isWorkableVehicle(vehicle, farmId)
    if vehicle == nil or farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        return false
    end
    local job = TheContractorRepairContracts.getContractVehicleIds()[NetworkUtil.getObjectId(vehicle)]
    return job ~= nil and not job:isTerminal() and vehicle:getOwnerFarmId() == farmId
end

-- Adds the workable customer's machines among a workshop trigger's shapes
-- (shapeId -> true) to its list, sorted by root node as vanilla does.
-- Returns whether any were added.
function TheContractorRepairContracts.addWorkableVehiclesInRange(vehicles, shapesInRange, farmId)
    if shapesInRange == nil or farmId == FarmManager.SPECTATOR_FARM_ID or
            next(TheContractorRepairContracts.getContractVehicleIds()) == nil then
        return false
    end
    local added = false
    for shapeId, inRange in pairs(shapesInRange) do
        local object = inRange and entityExists(shapeId) and g_currentMission.nodeToObject[shapeId] or nil
        if object ~= nil and object.rootVehicle ~= nil then
            for _, vehicle in ipairs(object.rootVehicle:getChildVehicles()) do
                if TheContractorRepairContracts.isWorkableVehicle(vehicle, farmId) and
                        not table.hasElement(vehicles, vehicle) then
                    table.insert(vehicles, vehicle)
                    added = true
                end
            end
        end
    end
    if added then
        table.sort(vehicles, function(a, b)
            return a.rootNode < b.rootNode
        end)
    end
    return added
end

-- Vanilla's workshop (VehicleSellingPoint:determineCurrentVehicles, which
-- ADS's workshop window reads too): a customer's machine standing in it is
-- added back. Service vehicle mods' workshops are TCServiceVehicleMods'.
function TheContractorRepairContracts.determineCurrentVehicles(sellingPoint, superFunc)
    local vehicles = superFunc(sellingPoint)
    TheContractorRepairContracts.addWorkableVehiclesInRange(vehicles, sellingPoint.vehicleShapesInRange,
        g_currentMission:getFarmId())
    return vehicles
end

if VehicleSellingPoint ~= nil and not VehicleSellingPoint.tcRepairContractsHookInstalled and
        VehicleSellingPoint.determineCurrentVehicles ~= nil then
    VehicleSellingPoint.determineCurrentVehicles = Utils.overwrittenFunction(
        VehicleSellingPoint.determineCurrentVehicles, TheContractorRepairContracts.determineCurrentVehicles)
    VehicleSellingPoint.tcRepairContractsHookInstalled = true
end

function TheContractorRepairContracts.getVehicle(job)
    local vehicleId = job.workshop ~= nil and job.workshop.vehicleId or nil
    local vehicle = vehicleId ~= nil and vehicleId ~= 0 and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

-- Why the job can't be taken on at all, as text, or nil: the machine's
-- gone, or ADS is. 102: missing tools are only a warning
-- (getToolsWarning), since the dealer can always do the work. Read live on
-- every machine.
function TheContractorRepairContracts.getAcceptProblem(job)
    if not TheContractorRepairContracts.isWorkshopJob(job) then
        return nil
    end
    local vehicle = TheContractorRepairContracts.getVehicle(job)
    if vehicle == nil then
        return g_i18n:getText("tc_repair_problemGone")
    end
    if TCADSRepairContracts.getStatus(vehicle) == nil then
        return g_i18n:getText("tc_repair_problemNoADS")
    end
    return nil
end

-- 102: what the farm hasn't the kit for, as text, or nil: a breakdown's
-- field kit (101); for a workshop job, once it's been inspected (before
-- then it would give the hidden faults away), the upgrades without which
-- some of it can't be done at all, or else those without which some of it
-- can only be replaced, not repaired. Upgrades by name (ADS's own workshop
-- equipment). Read live on every machine.
function TheContractorRepairContracts.getToolsWarning(job)
    if TheContractorRepairContracts.isBreakdownJob(job) then
        return TheContractorRepairContracts.getBreakdownProblem(job)
    end
    local vehicle = TheContractorRepairContracts.getVehicle(job)
    local plan = vehicle ~= nil and TCADSRepairContracts.getFarmPlan(vehicle, job.farmId) or nil
    if plan == nil or plan.plan == nil then
        return nil
    end
    if not plan.plan.canDo then
        return string.format(g_i18n:getText("tc_repair_subcontractWarning"),
            TCADSRepairContracts.getUpgradeNames(plan.missing))
    end
    if #(plan.repairNeeds or {}) > 0 then
        return string.format(g_i18n:getText("tc_repair_replaceOnlyWarning"),
            TCADSRepairContracts.getUpgradeNames(plan.repairNeeds))
    end
    return nil
end

-- 102: getToolsWarning's facts for the quote dialog's Missing kit row, or
-- nil when nothing's missing: { names (one per upgrade, a chip each),
-- noteKey (what going without means) }.
function TheContractorRepairContracts.getMissingKit(job)
    if TheContractorRepairContracts.isBreakdownJob(job) then
        local fieldService = job.workshop.serviceLevel
        if TheContractorRepairContracts.hasBreakdownKit(job.farmId, fieldService) then
            return nil
        end
        local key = TheContractorRepairContracts.getBreakdownKitKey(fieldService)
        local names = { g_i18n:getText("tc_breakdown_kit_mobile") }
        if key == "toolBox" then
            table.insert(names, 1, g_i18n:getText("tc_breakdown_kitName_toolBox"))
        end
        return { names = names, noteKey = "tc_repairQuote_kitNote_breakdown_" .. key }
    end
    local vehicle = TheContractorRepairContracts.getVehicle(job)
    local plan = vehicle ~= nil and TCADSRepairContracts.getFarmPlan(vehicle, job.farmId) or nil
    if plan == nil or plan.plan == nil then
        return nil
    end
    if not plan.plan.canDo then
        return { names = TCADSRepairContracts.getUpgradeNameList(plan.missing),
            noteKey = "tc_repairQuote_kitNote_subcontract" }
    end
    if #(plan.repairNeeds or {}) > 0 then
        return { names = TCADSRepairContracts.getUpgradeNameList(plan.repairNeeds),
            noteKey = "tc_repairQuote_kitNote_replaceOnly" }
    end
    return nil
end

-- 102: whether the job's ready to be priced: an offer whose machine's been
-- inspected. Any machine.
function TheContractorRepairContracts.isReadyToQuote(job)
    if not TheContractorRepairContracts.isWorkshopJob(job) or (job.state ~= TheContractorJob.STATE.OFFERED and
            job.state ~= TheContractorJob.STATE.NEGOTIATING) then
        return false
    end
    local vehicle = TheContractorRepairContracts.getVehicle(job)
    return vehicle ~= nil and TCADSRepairContracts.isInspected(vehicle)
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

-- 101: a model of either zone type, by its xml (a field arrival's).
function TheContractorRepairContracts:findModelByXml(xmlFilename)
    for _, zoneType in pairs(PlaceableTCRepairZone.ZONE_TYPE) do
        for _, model in ipairs(self:getEligibleModels(zoneType)) do
            if model.xmlFilename == xmlFilename then
                return model
            end
        end
    end
    return nil
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

-- 1-3, weighted by SEVERITY_WEIGHTS.
function TheContractorRepairContracts.pickSeverity(random)
    local weights = TheContractorRepairContracts.SEVERITY_WEIGHTS
    local total = 0
    for _, weight in ipairs(weights) do
        total = total + weight
    end
    local roll = random() * total
    for severity, weight in ipairs(weights) do
        if roll < weight then
            return severity
        end
        roll = roll - weight
    end
    return #weights
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
    local entry = {
        farmId = farmId,
        zoneUniqueId = TheContractorRepairContracts.getZoneUniqueId(zone),
        bayIndex = bayIndex,
        xmlFilename = model.xmlFilename,
        kind = kind or TheContractorRepairContracts.pickKind(math.random),
        severity = severity or TheContractorRepairContracts.pickSeverity(math.random),
        seed = TheContractorRepairContracts.rollSeed(math.random),
        queuedDay = g_currentMission.environment.currentMonotonicDay,
        attempts = 0,
        blockedDays = 0,
        isLoading = false,
    }
    table.insert(self.arrivals, entry)
    Logging.info("TheContractor: farm %d repair zone bay %d: %s (%s, severity %d) on its way", farmId, bayIndex,
        model.name, entry.kind, entry.severity)
    return entry
end

-- 101: a customer's machine to break down on a field, at a spot
-- TheContractorFieldBreakdowns picked for its model: placed like any
-- arrival, prepared as ADS's breakdown kind, offered due today.
function TheContractorRepairContracts:queueFieldArrival(farmId, fieldId, model, x, z, rotY, fieldService, severity)
    local entry = {
        farmId = farmId,
        fieldId = fieldId,
        x = x,
        z = z,
        rotY = rotY,
        xmlFilename = model.xmlFilename,
        kind = TCADSRepairContracts.KIND.BREAKDOWN,
        fieldService = fieldService,
        severity = severity,
        seed = TheContractorRepairContracts.rollSeed(math.random),
        queuedDay = g_currentMission.environment.currentMonotonicDay,
        attempts = 0,
        blockedDays = 0,
        isLoading = false,
    }
    table.insert(self.arrivals, entry)
    Logging.info("TheContractor: farm %d field %d: %s (breakdown, %s, severity %d) on its way", farmId, fieldId,
        model.name, tostring(fieldService), severity)
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
    local chance = TheContractorRepairContracts.ARRIVAL_CHANCE * self:getArrivalFactor(farmId)
    for _, zone in ipairs(TheContractorRepairContracts.getZones(farmId)) do
        local zoneUniqueId = TheContractorRepairContracts.getZoneUniqueId(zone)
        if zoneUniqueId ~= nil then
            for bayIndex = 1, PlaceableTCRepairZone.getBayCount(zone) do
                if not self:isBayTaken(zoneUniqueId, bayIndex) and math.random() < chance then
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
        if entry.fieldId ~= nil and not entry.isLoading and entry.queuedDay < today then
            -- 101: a breakdown not placed by midnight would be due yesterday.
            Logging.info("TheContractor: farm %d breakdown on field %d never placed, dropped", entry.farmId,
                entry.fieldId)
        elseif entry.isLoading or (entry.blockedDays or 0) <= TheContractorRepairContracts.ARRIVAL_GIVE_UP_DAYS then
            table.insert(kept, entry)
        else
            Logging.info("TheContractor: farm %d repair zone bay %d had no room for days, arrival dropped",
                entry.farmId, entry.bayIndex)
        end
    end
    self.arrivals = kept

    self:expireOvercharging(today)

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

function TheContractorRepairContracts:update(dt)
    if not g_currentMission:getIsServer() or (#self.arrivals == 0 and #self.removals == 0) then
        return
    end
    self.checkMs = self.checkMs + dt
    if self.checkMs < TheContractorRepairContracts.PLACE_CHECK_MS then
        return
    end
    self.checkMs = 0

    for _, entry in ipairs(self:copyList(self.arrivals)) do
        if not entry.isLoading then
            self:tryPlaceArrival(entry)
        end
    end
    for _, entry in ipairs(self:copyList(self.removals)) do
        self:tryCollect(entry)
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

-- 101: the rectangle a model takes at a field arrival's spot (its centre
-- and heading), in a bay's shape, clearance included.
function TheContractorRepairContracts.getSpotArea(entry, model)
    local clearance = TheContractorRepairContracts.CLEARANCE
    local width, length = model.width + clearance, model.length + clearance
    local vX, vZ = math.sin(entry.rotY or 0), math.cos(entry.rotY or 0)
    local uX, uZ = vZ, -vX
    return {
        x = entry.x - (uX * width + vX * length) * 0.5,
        z = entry.z - (uZ * width + vZ * length) * 0.5,
        uX = uX,
        uZ = uZ,
        vX = vX,
        vZ = vZ,
        width = width,
        length = length,
    }
end

-- Where a queued arrival goes and what it is: area, model (nil if its
-- zone's been sold or shrunk, or the model's gone).
function TheContractorRepairContracts:getArrivalPlace(entry)
    if entry.fieldId ~= nil then
        local model = self:findModelByXml(entry.xmlFilename)
        if model == nil or entry.x == nil or entry.z == nil then
            return nil, nil
        end
        return TheContractorRepairContracts.getSpotArea(entry, model), model
    end
    local zone = TheContractorRepairContracts.getZoneByUniqueId(entry.zoneUniqueId)
    local bayArea = zone ~= nil and PlaceableTCRepairZone.getBayArea(zone, entry.bayIndex) or nil
    local model = zone ~= nil and self:findModel(entry, zone) or nil
    return bayArea, model
end

function TheContractorRepairContracts:tryPlaceArrival(entry)
    local bayArea, model = self:getArrivalPlace(entry)
    local storeItem = model ~= nil and g_storeManager:getItemByXMLFilename(model.xmlFilename) or nil
    if bayArea == nil or storeItem == nil or not TCADSRepairContracts.isActive() then
        -- The zone's been sold or shrunk, or the model's gone.
        removeFrom(self.arrivals, entry)
        return
    end

    local originX, originZ, centreX, centreZ, rotY = TheContractorRepairContracts.getSpawnPose(model, bayArea)
    local clearance = TheContractorRepairContracts.CLEARANCE
    if not TCParking.isAreaClear(centreX, centreZ, rotY, model.width + clearance, model.length + clearance,
            model.height) then
        if entry.fieldId ~= nil then
            -- 101: something's on that spot: another spot on the field.
            self:retryFieldSpot(entry, model)
            return
        end
        -- Something's in the bay: try again tomorrow, then give up.
        entry.blockedDays = math.max(1, entry.blockedDays or 0)
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

-- 101: a field arrival's spot was taken: another spot for the same model,
-- up to PREPARE_RETRIES.
function TheContractorRepairContracts:retryFieldSpot(entry, model)
    entry.attempts = (entry.attempts or 0) + 1
    local x, z, rotY = nil, nil, nil
    if entry.attempts <= TheContractorRepairContracts.PREPARE_RETRIES then
        x, z, rotY = TheContractorFieldBreakdowns.pickSpot(entry.fieldId, model, math.random)
    end
    if x == nil then
        Logging.info("TheContractor: farm %d breakdown on field %d: no room, dropped", entry.farmId, entry.fieldId)
        removeFrom(self.arrivals, entry)
        return
    end
    entry.x, entry.z, entry.rotY = x, z, rotY
end

-- A model ADS turned down: another one, another seed, up to PREPARE_RETRIES.
function TheContractorRepairContracts:retryArrival(entry, zone, reason)
    entry.attempts = (entry.attempts or 0) + 1
    if entry.fieldId ~= nil then
        -- 101: another model for the field, somewhere on it that it fits.
        local model = entry.attempts <= TheContractorRepairContracts.PREPARE_RETRIES and
            TheContractorFieldBreakdowns.pickModel(self, math.random) or nil
        local x, z, rotY = nil, nil, nil
        if model ~= nil then
            x, z, rotY = TheContractorFieldBreakdowns.pickSpot(entry.fieldId, model, math.random)
        end
        if x == nil then
            Logging.info("TheContractor: farm %d breakdown on field %d: arrival dropped (%s)", entry.farmId,
                entry.fieldId, tostring(reason))
            removeFrom(self.arrivals, entry)
            return
        end
        entry.xmlFilename = model.xmlFilename
        entry.x, entry.z, entry.rotY = x, z, rotY
        entry.seed = TheContractorRepairContracts.rollSeed(math.random)
        return
    end
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
    if not isQueued or (zone == nil and entry.fieldId == nil) then
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
        -- 101: a breakdown's field service level (nil for the rest).
        fieldService = entry.fieldService,
        seed = entry.seed,
        ref =string.format("TheContractor:%d:%d", entry.farmId, entry.seed),
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
    if entry.fieldId ~= nil then
        -- 101: only now the spot's final, so a retry leaves no ruts behind.
        TheContractorFieldBreakdowns.clearSpot(entry, self:findModelByXml(entry.xmlFilename))
    end
    self:createOffer(entry, vehicle, quote)
end

-- Pricing (102) ---------------------------------------------------------------------

-- The cheapest fix's cost as base amounts (without FS25_EconomyScale's
-- factor, as every job stores its price): ADS's parts cost is at the price
-- level of the day it was quoted, so it's divided back out, and the labour
-- is its hours at LABOUR_RATE (scaleCost, which applies the factor, so
-- that's divided out too). Returns parts, labour.
function TheContractorRepairContracts.getBaseCost(partsCost, laborHours)
    local factor = TCEconomyScale.getFactor()
    local rate = g_currentMission.TheContractor.Settings:scaleCost(TheContractorRepairContracts.LABOUR_RATE)
    return math.max(tonumber(partsCost) or 0, 0) / factor, math.max(tonumber(laborHours) or 0, 0) * rate / factor
end

-- A job's cost (base): its parts and labour. One offered before 102 kept
-- only the parts, at the price level of its day.
function TheContractorRepairContracts.getJobBaseCost(job)
    local workshop = job.workshop or {}
    return (workshop.baseParts or workshop.partsCost or 0) + (workshop.baseLabour or 0)
end

-- The job's base price at a margin: the cost plus the margin, never under
-- MIN_PRICE.
function TheContractorRepairContracts.getBasePrice(baseCost, margin)
    return math.max(baseCost * (1 + margin), TheContractorRepairContracts.MIN_PRICE)
end

-- The price at a margin as it's shown and charged now (the factor applied).
function TheContractorRepairContracts.getPriceForMargin(job, margin)
    return TCEconomyScale.scale(TheContractorRepairContracts.getBasePrice(
        TheContractorRepairContracts.getJobBaseCost(job), margin))
end

-- The benchmark margin for a new offer: the repair zone setting, or a field
-- breakdown's (101).
function TheContractorRepairContracts.getBenchmarkMargin(isFieldBreakdown)
    return g_currentMission.TheContractor.Settings:getADSMargin(isFieldBreakdown)
end

function TheContractorRepairContracts.getJobBenchmark(job)
    local benchmark = job.workshop ~= nil and job.workshop.benchmarkMargin or nil
    if benchmark == nil then
        benchmark = TheContractorRepairContracts.getBenchmarkMargin(TheContractorRepairContracts.isBreakdownJob(job))
    end
    return math.max(benchmark, TheContractorRepairContracts.MIN_BENCHMARK)
end

-- The customer's ceiling for a new offer, as a margin.
function TheContractorRepairContracts.rollRefusalMargin(benchmark, random)
    local range = TheContractorRepairContracts.REFUSAL_FACTOR
    local factor = range[1] + (random or math.random)() * (range[2] - range[1])
    return math.max(benchmark, TheContractorRepairContracts.MIN_BENCHMARK) * factor
end

-- The stepper's margins: 0, MARGIN_STEP, ... MARGIN_MAX.
function TheContractorRepairContracts.getMarginSteps()
    local steps = {}
    local count = math.floor(TheContractorRepairContracts.MARGIN_MAX / TheContractorRepairContracts.MARGIN_STEP + 0.5)
    for i = 0, count do
        table.insert(steps, i * TheContractorRepairContracts.MARGIN_STEP)
    end
    return steps
end

-- Whether a margin on this cost (base) comes to MIN_PRICE anyway: the
-- minimum charge, which the customer always takes and never holds against
-- the farm, however steep a margin it works out at.
function TheContractorRepairContracts.isMinimumCharge(baseCost, margin)
    return baseCost * (1 + margin) <= TheContractorRepairContracts.MIN_PRICE + 0.01
end

-- The same for a job, at a margin or its agreed one (false without either).
function TheContractorRepairContracts.isJobMinimumCharge(job, margin)
    margin = margin or (job.workshop ~= nil and job.workshop.margin or nil)
    if margin == nil then
        return false
    end
    return TheContractorRepairContracts.isMinimumCharge(TheContractorRepairContracts.getJobBaseCost(job), margin)
end

-- The Negotiate dialog's options for a cost (base): every step that comes
-- to MIN_PRICE folded into one minimum charge (at the highest of them),
-- then each step over it. { margin, isMinimum } each.
function TheContractorRepairContracts.getQuoteOptions(baseCost)
    local options = {}
    for _, margin in ipairs(TheContractorRepairContracts.getMarginSteps()) do
        if TheContractorRepairContracts.isMinimumCharge(baseCost, margin) then
            if options[1] == nil then
                options[1] = { margin = margin, isMinimum = true }
            else
                options[1].margin = margin
            end
        else
            table.insert(options, { margin = margin, isMinimum = false })
        end
    end
    return options
end

-- The reputation factor for a margin against a benchmark
-- (MARGIN_FACTOR_POINTS).
function TheContractorRepairContracts.getMarginFactorFor(margin, benchmark)
    local ratio = margin / math.max(benchmark, TheContractorRepairContracts.MIN_BENCHMARK)
    local points = TheContractorRepairContracts.MARGIN_FACTOR_POINTS
    if ratio <= points[1][1] then
        return points[1][2]
    end
    for i = 2, #points do
        local low, high = points[i - 1], points[i]
        if ratio <= high[1] then
            return low[2] + (high[2] - low[2]) * (ratio - low[1]) / (high[1] - low[1])
        end
    end
    return points[#points][2]
end

-- A workshop job's reputation factor for its agreed margin: 1 without one
-- (agreed before 102, or forced through the console). A minimum charge is
-- never less than 1.
function TheContractorRepairContracts.getMarginFactor(job)
    local margin = job.workshop ~= nil and job.workshop.margin or nil
    if margin == nil then
        return 1
    end
    local factor = TheContractorRepairContracts.getMarginFactorFor(margin, TheContractorRepairContracts.getJobBenchmark(job))
    if TheContractorRepairContracts.isJobMinimumCharge(job, margin) then
        return math.max(factor, 1)
    end
    return factor
end

-- How a customer will see a margin: "fair" up to the benchmark, "steep" up
-- to OVERCHARGE_MARGIN_FACTOR times it, "ripOff" past that. Never from the
-- customer's hidden ceiling.
function TheContractorRepairContracts.getReaction(margin, benchmark)
    local ratio = margin / math.max(benchmark, TheContractorRepairContracts.MIN_BENCHMARK)
    if ratio <= 1 + 1e-6 then
        return "fair"
    elseif ratio < TheContractorRepairContracts.OVERCHARGE_MARGIN_FACTOR - 1e-6 then
        return "steep"
    end
    return "ripOff"
end

function TheContractorRepairContracts.isOverchargeMargin(margin, benchmark)
    return TheContractorRepairContracts.getReaction(margin, benchmark) == "ripOff"
end

-- A job's reaction at a margin (or its agreed one): "minimum" for a
-- minimum charge, else getReaction's.
function TheContractorRepairContracts.getJobReaction(job, margin)
    margin = margin or job.workshop.margin
    if TheContractorRepairContracts.isJobMinimumCharge(job, margin) then
        return "minimum"
    end
    return TheContractorRepairContracts.getReaction(margin, TheContractorRepairContracts.getJobBenchmark(job))
end

-- MIN_DUE_DAYS at 1 day per period, rising evenly to MAX_DUE_DAYS at
-- FULL_DUE_DAYS_PER_PERIOD or more.
function TheContractorRepairContracts.getDueDays(daysPerPeriod)
    local minDays = TheContractorRepairContracts.MIN_DUE_DAYS
    local maxDays = TheContractorRepairContracts.MAX_DUE_DAYS
    local full = TheContractorRepairContracts.FULL_DUE_DAYS_PER_PERIOD
    local days = minDays + math.floor(((daysPerPeriod or 1) - 1) * (maxDays - minDays) / (full - 1))
    return math.max(minDays, math.min(maxDays, days))
end

function TheContractorRepairContracts:createOffer(entry, vehicle, quote)
    local today = g_currentMission.environment.currentMonotonicDay
    local partsCost = math.max(tonumber(quote.partsCost) or 0, 0)
    -- 102: the price isn't agreed yet. The job holds the benchmark price
    -- until the player's quote is accepted; it's never shown before then.
    local baseParts, baseLabour = TheContractorRepairContracts.getBaseCost(partsCost, quote.laborHours)
    local benchmark = TheContractorRepairContracts.getBenchmarkMargin(entry.fieldId ~= nil)
    local price = math.floor(TheContractorRepairContracts.getBasePrice(baseParts + baseLabour, benchmark))
    local dueDays = TheContractorRepairContracts.getDueDays(g_currentMission.environment.daysPerPeriod)
    local deadlineDay = today + dueDays
    local offerExpiresDay = deadlineDay - 1
    -- 101: a breakdown is today's or nobody's, and its level is ADS's field
    -- service (who can fix it on the spot), not the workshop's.
    local serviceLevel = quote.serviceLevel
    if entry.fieldId ~= nil then
        deadlineDay, offerExpiresDay = today, today
        serviceLevel = quote.fieldService or entry.fieldService
    end
    local workshop = {
        vehicleId = NetworkUtil.getObjectId(vehicle),
        vehicleUniqueId = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or nil,
        vehicleName = vehicle:getFullName(),
        zoneUniqueId = entry.zoneUniqueId,
        bayIndex = entry.bayIndex,
        kind = entry.kind,
        severity = entry.severity,
        offerExpiresDay = offerExpiresDay,
        quotePrice = quote.price,
        partsCost = partsCost,
        requiredTools = quote.minTools or {},
        serviceLevel = serviceLevel,
        operatingHours = quote.operatingHours,
        fieldId = entry.fieldId,
        -- 102: the cheapest fix's cost (base), the benchmark margin, and the
        -- customer's ceiling (server only, never streamed).
        baseParts = baseParts,
        baseLabour = baseLabour,
        laborHours = tonumber(quote.laborHours) or 0,
        benchmarkMargin = benchmark,
        refusalMargin = TheContractorRepairContracts.rollRefusalMargin(benchmark),
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
    Logging.info("TheContractor: farm %d job %d: %s in for %s, quoted %.0f (parts %.0f, %.1f h), %.0f at the %.0f%% benchmark, ceiling %.0f%%",
        entry.farmId, job.id, workshop.vehicleName, entry.kind, quote.price, partsCost, workshop.laborHours,
        job:getPrice(), benchmark * 100, workshop.refusalMargin * 100)
end

-- 102, server: the player's quote on an inspected offer, at a margin over
-- the cheapest fix's cost. The customer answers once: at or under their
-- ceiling the job's accepted at that price and ADS lets the work start;
-- over it they take the machine elsewhere. Returns the outcome
-- (QUOTE_OUTCOME), or nil if the quote was refused out of hand (not an
-- inspected offer of the farm's, or a margin out of range).
function TheContractorRepairContracts:proposeQuote(farmId, jobId, margin)
    if not g_currentMission:getIsServer() then
        return nil
    end
    local jobs = g_currentMission.TheContractor.Jobs
    local job = jobs:getJob(farmId, jobId)
    margin = tonumber(margin)
    if job == nil or job.farmId ~= farmId or margin == nil or margin < -1e-6 or
            margin > TheContractorRepairContracts.MARGIN_MAX + 1e-6 or
            not TheContractorRepairContracts.isReadyToQuote(job) or TheContractorJobs.getAcceptProblem(job) ~= nil then
        return nil
    end
    margin = math.max(0, margin)

    local workshop = job.workshop
    local benchmark = TheContractorRepairContracts.getJobBenchmark(job)
    local ceiling = workshop.refusalMargin
    if ceiling == nil then
        ceiling = TheContractorRepairContracts.rollRefusalMargin(benchmark)
        workshop.refusalMargin = ceiling
    end
    local isAcceptable = margin <= ceiling + 1e-6 or TheContractorRepairContracts.isJobMinimumCharge(job, margin)
    local outcome = isAcceptable and TheContractorRepairContracts.QUOTE_OUTCOME.ACCEPTED or
        TheContractorRepairContracts.QUOTE_OUTCOME.REFUSED
    if self.forcedQuoteOutcome ~= nil then
        outcome = self.forcedQuoteOutcome
        self.forcedQuoteOutcome = nil
    end

    local vehicle = TheContractorRepairContracts.getVehicle(job)
    if outcome == TheContractorRepairContracts.QUOTE_OUTCOME.ACCEPTED then
        workshop.margin = margin
        job:setPrice(TheContractorRepairContracts.getPriceForMargin(job, margin))
        if g_server ~= nil then
            g_server:broadcastEvent(TCJobNegotiationUpdatedEvent.new(job))
        end
        TCADSRepairContracts.authorize(vehicle)
        jobs:transitionJobState(farmId, jobId, TheContractorJob.STATE.ACCEPTED)
    else
        jobs:transitionJobState(farmId, jobId, TheContractorJob.STATE.DECLINED)
    end
    Logging.info("TheContractor: farm %d job %d: quoted at a %.0f%% margin (benchmark %.0f%%, ceiling %.0f%%) - %s",
        farmId, jobId, margin * 100, benchmark * 100, ceiling * 100, outcome)
    return outcome
end

-- Overcharging (102, server) -------------------------------------------------------------

function TheContractorRepairContracts:isOvercharging(farmId)
    return self.overcharged[farmId] ~= nil
end

-- How often the farm's workshop customers come, against normal.
function TheContractorRepairContracts:getArrivalFactor(farmId)
    if self:isOvercharging(farmId) then
        return TheContractorRepairContracts.OVERCHARGE_ARRIVAL_FACTOR
    end
    return 1
end

-- Jobs:completeWorkshopJob: a job finished far over the benchmark marks the
-- farm (again) for OVERCHARGE_MONTHS, with an Overview notice until then.
function TheContractorRepairContracts:onJobCompleted(job)
    local margin = job.workshop ~= nil and job.workshop.margin or nil
    if margin == nil or TheContractorRepairContracts.getJobReaction(job, margin) ~= "ripOff" then
        return
    end
    local environment = g_currentMission.environment
    local untilDay = environment.currentMonotonicDay +
        TheContractorRepairContracts.OVERCHARGE_MONTHS * math.max(environment.daysPerPeriod or 1, 1)
    local notices = g_currentMission.TheContractor.Notices
    local previous = self.overcharged[job.farmId]
    if previous ~= nil and previous.noticeId ~= nil then
        notices:remove(previous.noticeId)
    end
    local noticeId = notices:publish(job.farmId, string.format(g_i18n:getText("tc_repair_overchargingNotice"),
        TheContractorRepairContracts.OVERCHARGE_MONTHS))
    self.overcharged[job.farmId] = { untilDay = untilDay, noticeId = noticeId }
    Logging.info("TheContractor: farm %d job %d finished at a %.0f%% margin: known for overcharging until day %d",
        job.farmId, job.id, margin * 100, untilDay)
end

-- Daily: overcharging that's run its course ends, and its notice goes.
function TheContractorRepairContracts:expireOvercharging(today)
    local ended = {}
    for farmId, entry in pairs(self.overcharged) do
        if today >= entry.untilDay then
            table.insert(ended, farmId)
        end
    end
    for _, farmId in ipairs(ended) do
        local entry = self.overcharged[farmId]
        if entry.noticeId ~= nil then
            g_currentMission.TheContractor.Notices:remove(entry.noticeId)
        end
        self.overcharged[farmId] = nil
        Logging.info("TheContractor: farm %d no longer known for overcharging", farmId)
    end
end

-- Server: the customer comes for their machine (an offer turned down or
-- lapsed, or a job finished or missed). The contract comes off now; the
-- machine goes on the next look at the queue.
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
    })
end

function TheContractorRepairContracts:tryCollect(entry)
    local vehicle = entry.vehicleId ~= nil and entry.vehicleId ~= 0 and NetworkUtil.getObject(entry.vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        removeFrom(self.removals, entry)
        return
    end
    -- Not from under someone driving it.
    if vehicle.getIsControlled ~= nil and vehicle:getIsControlled() then
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

-- The base reputation reward for a finished workshop job, before quality
-- and speed.
function TheContractorRepairContracts.getBaseReputation(job)
    local workshop = job.workshop or {}
    local bySeverity = TheContractorRepairContracts.REPUTATION_BY_KIND[workshop.kind]
        or TheContractorRepairContracts.REPUTATION_BY_KIND.repair
    local severity = workshop.severity or 1
    return bySeverity[math.max(1, math.min(#bySeverity, severity))]
end

-- Game minutes from acceptance to completion, or nil (not finished, or
-- accepted before acceptedAt was kept).
function TheContractorRepairContracts.getTurnaroundMinutes(job)
    local acceptedAt = job.workshop ~= nil and job.workshop.acceptedAt or nil
    if acceptedAt == nil or job.completedAt == nil then
        return nil
    end
    return math.max(job.completedAt - acceptedAt, 0)
end

-- The reputation multiplier for how quickly a finished job was done (see
-- SPEED_MAX_FACTOR): 1 for a service, or without a turnaround or deadline.
function TheContractorRepairContracts.getSpeedFactor(job)
    local maxFactor = job.workshop ~= nil and TheContractorRepairContracts.SPEED_MAX_FACTOR[job.workshop.kind] or nil
    local turnaround = TheContractorRepairContracts.getTurnaroundMinutes(job)
    if maxFactor == nil or turnaround == nil or job.deadlineDay == nil then
        return 1
    end
    local available = (job.deadlineDay + 1) * 24 * 60 - job.workshop.acceptedAt
    if available <= 0 then
        return 1
    end
    local fast = TheContractorRepairContracts.SPEED_FAST_SHARE
    local slow = TheContractorRepairContracts.SPEED_SLOW_SHARE
    local t = math.max(0, math.min(1, (turnaround / available - fast) / (slow - fast)))
    return maxFactor + (1 - maxFactor) * t
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
    self.arrivals, self.removals, self.pendingClaims, self.overcharged = {}, {}, {}, {}
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
            -- 101: a field arrival's spot.
            fieldId = getXMLInt(xmlFile, key .. "#fieldId"),
            x = getXMLFloat(xmlFile, key .. "#x"),
            z = getXMLFloat(xmlFile, key .. "#z"),
            rotY = getXMLFloat(xmlFile, key .. "#rotY"),
            fieldService = getXMLString(xmlFile, key .. "#fieldService"),
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

    -- 102.
    index = 0
    while true do
        local key = string.format("%s.overcharging(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        local untilDay = getXMLInt(xmlFile, key .. "#untilDay")
        if farmId ~= nil and untilDay ~= nil then
            self.overcharged[farmId] = { untilDay = untilDay, noticeId = getXMLInt(xmlFile, key .. "#noticeId") }
        end
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
        if (entry.zoneUniqueId ~= nil or entry.fieldId ~= nil) and entry.xmlFilename ~= nil then
            local key = string.format("%s.arrival(%d)", rootKey, index)
            setXMLInt(xmlFile, key .. "#farmId", entry.farmId)
            if entry.fieldId ~= nil then
                setXMLInt(xmlFile, key .. "#fieldId", entry.fieldId)
                setXMLFloat(xmlFile, key .. "#x", entry.x)
                setXMLFloat(xmlFile, key .. "#z", entry.z)
                setXMLFloat(xmlFile, key .. "#rotY", entry.rotY or 0)
                if entry.fieldService ~= nil then
                    setXMLString(xmlFile, key .. "#fieldService", entry.fieldService)
                end
            else
                setXMLString(xmlFile, key .. "#zoneUniqueId", entry.zoneUniqueId)
                setXMLInt(xmlFile, key .. "#bayIndex", entry.bayIndex)
            end
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

    -- 102: in farm order, so the save doesn't shuffle.
    local farmIds = {}
    for farmId in pairs(self.overcharged) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)
    for i, farmId in ipairs(farmIds) do
        local entry = self.overcharged[farmId]
        local key = string.format("%s.overcharging(%d)", rootKey, i - 1)
        setXMLInt(xmlFile, key .. "#farmId", farmId)
        setXMLInt(xmlFile, key .. "#untilDay", entry.untilDay)
        if entry.noticeId ~= nil then
            setXMLInt(xmlFile, key .. "#noticeId", entry.noticeId)
        end
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
    self:endUnworkableJobs()
end

-- Server, after a load: an accepted job that can never complete (its machine
-- didn't load, ADS is gone or its contract is) ends now with nothing lost,
-- as an excluded machine's does, rather than costing reputation at its
-- deadline for something the player couldn't help. Offers lapse anyway.
function TheContractorRepairContracts:endUnworkableJobs()
    local jobs = g_currentMission.TheContractor.Jobs
    local unworkable = {}
    for _, farmJobs in pairs(jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.workshop ~= nil and job.state == TheContractorJob.STATE.ACCEPTED then
                local vehicle = TheContractorRepairContracts.getVehicle(job)
                local status = vehicle ~= nil and TCADSRepairContracts.getStatus(vehicle) or nil
                if status == nil then
                    table.insert(unworkable, job)
                end
            end
        end
    end
    for _, job in ipairs(unworkable) do
        Logging.info("TheContractor: farm %d job %d: %s can't be worked after loading (%s), ended without penalty",
            job.farmId, job.id, job.workshop.vehicleName or "?",
            not TCADSRepairContracts.isActive() and "no ADS" or
            TheContractorRepairContracts.getVehicle(job) == nil and "machine gone" or "no contract")
        jobs:missJob(job, true)
    end
end

-- Console (tcJob) ------------------------------------------------------------------------

-- The bay kinds `tcJob offer` takes (JobGeneration's command hands them to
-- consoleOffer): field breakdowns come from `tcCompany event` instead.
TheContractorRepairContracts.CONSOLE_OFFER_KINDS = { "repair", "maintenance" }

function TheContractorRepairContracts.findConsoleOfferKind(name)
    if name == nil then
        return nil
    end
    for _, kind in ipairs(TheContractorRepairContracts.CONSOLE_OFFER_KINDS) do
        if kind == string.lower(name) then
            return kind
        end
    end
    return nil
end

-- `tcJob offer repair|maintenance [severity]`: a customer's machine sent to
-- the farm's first free repair zone bay, queued like a normal arrival.
function TheContractorRepairContracts.consoleOffer(farmId, kind, severityArg)
    local severity = tonumber(severityArg)
    if severityArg ~= nil and (severity == nil or severity < 1 or severity > 3) then
        return string.format("Usage: tcJob offer %s [severity 1-3]", kind)
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
end

function TheContractorRepairContracts.registerConsoleCommands()
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
            -- 102: each open job's ADS stage and whether it's been inspected.
            for _, job in ipairs(g_currentMission.TheContractor.Jobs:getAllJobs(farmId)) do
                if job.workshop ~= nil and not job:isTerminal() then
                    local vehicle = TheContractorRepairContracts.getVehicle(job)
                    table.insert(lines, string.format("Job %d (%s, %s): %s, %s, %s", job.id,
                        job.workshop.vehicleName or "?", job.state,
                        vehicle ~= nil and tostring(TCADSRepairContracts.getStage(vehicle)) or "no machine",
                        vehicle ~= nil and TCADSRepairContracts.isInspected(vehicle) and "inspected" or "not inspected",
                        job.workshop.margin ~= nil and string.format("agreed at a %.0f%% margin",
                            job.workshop.margin * 100) or "no price agreed"))
                end
            end
            local overcharged = repairContracts.overcharged[farmId]
            if overcharged ~= nil then
                table.insert(lines, string.format("Known for overcharging until day %d", overcharged.untilDay))
            end
            if repairContracts.forcedQuoteOutcome ~= nil then
                table.insert(lines, "The next quote will be " .. repairContracts.forcedQuoteOutcome)
            end
            return table.concat(lines, "\n")
        end,
    })

    TCConsole.register("job", "quoteOutcome", {
        args = "<accepted|refused|clear>",
        description = "Force the customer's answer to the next repair quote (Negotiate), or clear it",
        run = function(farmId, args)
            local repairContracts = g_currentMission.TheContractor.RepairContracts
            local name = args[1] ~= nil and string.lower(args[1]) or nil
            if name == "clear" then
                repairContracts.forcedQuoteOutcome = nil
                return "The next quote will be judged as usual."
            end
            for _, outcome in pairs(TheContractorRepairContracts.QUOTE_OUTCOME) do
                if outcome == name then
                    repairContracts.forcedQuoteOutcome = outcome
                    return string.format("The next repair quote will be %s, whatever the margin.", outcome)
                end
            end
            return false
        end,
    })
end
