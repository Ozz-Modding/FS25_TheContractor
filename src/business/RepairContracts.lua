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
-- up. Nothing runs while the queue is empty. Of the arrivals, KIND_WEIGHTS'
-- share are a parts service: ADS's service kind with 116's targets (the
-- battery and/or the air filter, entry.stockParts), otherwise an ordinary
-- service job, inspected, negotiated and charged for its labour.
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
-- 121: a breakdown on a farmer's field is one of that farmer's own machines
-- (TheContractorFarmerFleet) when they have one ADS can take: its model,
-- seed and age, the farmer as the customer (entry/workshop farmerId and
-- machineId, as a favour's). 123: now and then it's in their yard instead
-- (entry/workshop yardFarmlandId, no fieldId), so a breakdown is told by its
-- kind, never by having a field.
--
-- 121: a farmer's machine that has an attachment (a combine's header, a
-- telehandler's bale fork) brings it: the spot is found for both
-- (TheContractorFarmerFleet.getFootprint), and once ADS has prepared the
-- machine the attachment's loaded in front of it and hitched on
-- (TCJobSiteSetup.hitchImplement) before the offer goes up. One that won't
-- load or hitch is left out. It's the customer's too (workshop.attachmentId,
-- a contract vehicle, but not one a workshop works on), and the customer
-- takes it away with the machine, wherever it's been left.
--
-- Farmer favours (116, TheContractorFarmerFavours) use it too: a farmer's
-- own machine at a spot in their yard or on their field (entry.favour), with
-- one stock part worn (a service of only that, prepareVehicle's targets),
-- picked here once it's loaded (prepareFavour). The job (adsFavour,
-- isFavourJob) has the farmer as its customer, is accepted or declined with
-- no quote, and pays the part back (createFavourOffer). The part's fitted by
-- hand, so it needs no kit.
--
-- 124: a farmer's machine lent to a job (TheContractorYardBales' telehandler
-- and bale fork) comes out the same way (entry.loan): no ADS and no offer of
-- its own, handed to its job once it's hitched up, and collected as a
-- customer's machine is once the job's over. It's never saved: the job sends
-- for it again after a load.
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
-- "parts" is a service of only ADS's stock parts (the battery and/or the
-- air filter, as 116's favours are), but an ordinary service job otherwise:
-- inspected to find which, negotiated, labour charged. Without ADS's
-- targets or stock parts its share goes to the other two.
TheContractorRepairContracts.PARTS_KIND = "parts"
TheContractorRepairContracts.KIND_WEIGHTS = { repair = 50, maintenance = 30, parts = 20 }
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

-- 116: a farmer's own machine, to fit a part to as a favour (JOB_TYPES'
-- favour flag).
function TheContractorRepairContracts.isFavourJob(job)
    local jobDef = job ~= nil and job.workshop ~= nil and TheContractorJobGeneration.JOB_TYPES[job.jobType] or nil
    return jobDef ~= nil and jobDef.favour == true
end

-- 101: a customer's machine broken down on a field.
function TheContractorRepairContracts.isBreakdownJob(job)
    return job ~= nil and job.workshop ~= nil and job.workshop.kind == TCADSRepairContracts.KIND.BREAKDOWN
end

-- 116: what the Inbox and the Workshop tab call a job's work: "favour", or
-- ADS's kind ("repair", "maintenance", "breakdown"), for the l10n keys
-- tc_repair_work_<key> and tc_repair_kindChip_<key>.
function TheContractorRepairContracts.getWorkKey(job)
    if TheContractorRepairContracts.isFavourJob(job) then
        return "favour"
    end
    return job.workshop ~= nil and job.workshop.kind or "repair"
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
            -- 121: the machine's attachment is the customer's too.
            if workshop ~= nil and workshop.attachmentId ~= nil and workshop.attachmentId ~= 0 then
                result[workshop.attachmentId] = job
            end
            -- 124: a farmer's telehandler and fork lent to a yard bale job.
            if job.yardDelivery ~= nil and TheContractorYardBales ~= nil then
                for _, vehicleId in ipairs(TheContractorYardBales.getKitIds(job.yardDelivery)) do
                    result[vehicleId] = job
                end
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
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    local job = TheContractorRepairContracts.getContractVehicleIds()[vehicleId]
    -- 121: never its attachment, which ADS has nothing to do with. 124: nor
    -- a farmer's kit lent to a job.
    return job ~= nil and job.workshop ~= nil and not job:isTerminal() and job.workshop.vehicleId == vehicleId and
        vehicle:getOwnerFarmId() == farmId
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
    -- 116: a favour's part is fitted by hand.
    if TheContractorRepairContracts.isFavourJob(job) then
        return nil
    end
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
    TCLog.info("TheContractor: %d models for %s repair zones", #models, zoneType)
    self.modelCache[zoneType] = models
    return models
end

-- 101: a model of either zone type, by its xml (a field arrival's). 121: or
-- any other store vehicle ADS can take that drives (a farmer's telehandler,
-- which no zone gets), or nil.
function TheContractorRepairContracts:findModelByXml(xmlFilename)
    for _, zoneType in pairs(PlaceableTCRepairZone.ZONE_TYPE) do
        for _, model in ipairs(self:getEligibleModels(zoneType)) do
            if model.xmlFilename == xmlFilename then
                return model
            end
        end
    end
    self.modelCache.byXml = self.modelCache.byXml or {}
    local cached = self.modelCache.byXml[xmlFilename]
    if cached == nil then
        cached = TheContractorRepairContracts.makeModel(xmlFilename) or false
        self.modelCache.byXml[xmlFilename] = cached
    end
    return cached or nil
end

-- 121: a model for any store vehicle ADS can take that drives, or nil.
function TheContractorRepairContracts.makeModel(xmlFilename)
    local storeItem = xmlFilename ~= nil and g_storeManager:getItemByXMLFilename(xmlFilename) or nil
    local vehicleType = storeItem ~= nil and g_vehicleTypeManager:getObjectTypeFromXML(xmlFilename) or nil
    local specs = vehicleType ~= nil and vehicleType.specializationsByName or nil
    if specs == nil or specs.AdvancedDamageSystem == nil or specs.drivable == nil then
        return nil
    end
    local size = StoreItemUtil.getSizeValues(xmlFilename, "vehicle", storeItem.rotation or 0, {})
    return {
        xmlFilename = xmlFilename,
        categoryName = storeItem.categoryName,
        name = storeItem.name or xmlFilename,
        width = size.width or 3,
        length = size.length or 5,
        height = size.height or TCParking.DEFAULT_HEIGHT,
        widthOffset = size.widthOffset or 0,
        lengthOffset = size.lengthOffset or 0,
    }
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

-- "repair", "maintenance" or PARTS_KIND (only with hasParts), by
-- KIND_WEIGHTS.
function TheContractorRepairContracts.pickKind(random, hasParts)
    local weights = TheContractorRepairContracts.KIND_WEIGHTS
    local parts = hasParts and weights.parts or 0
    local roll = random() * (weights.repair + weights.maintenance + parts)
    if roll < weights.repair then
        return TCADSRepairContracts.KIND.REPAIR
    elseif roll < weights.repair + weights.maintenance then
        return TCADSRepairContracts.KIND.MAINTENANCE
    end
    return TheContractorRepairContracts.PARTS_KIND
end

-- Whether ADS can prepare a service of only the stock parts.
function TheContractorRepairContracts.canServiceParts()
    return TCADSRepairContracts.hasTargets() and #TCADSRepairContracts.getStockParts() > 0
end

-- The targets to try for a parts service, in order: a random one or more of
-- the stock parts ({ id, nameKey }), then each stock part on its own (ADS
-- refuses the lot if the machine lacks one). Each a list of ADS targets.
function TheContractorRepairContracts.getPartTargetSets(parts, random)
    local shuffled = {}
    for i, part in ipairs(parts) do
        shuffled[i] = part
    end
    for i = #shuffled, 2, -1 do
        local j = math.min(math.floor(random() * i) + 1, i)
        shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end
    if #shuffled == 0 then
        return {}
    end
    local count = math.min(math.floor(random() * #shuffled) + 1, #shuffled)
    local first = {}
    for i = 1, count do
        table.insert(first, { consumable = shuffled[i].id })
    end
    local sets = { first }
    for i = 1, #shuffled do
        if count > 1 or i > 1 then
            table.insert(sets, { { consumable = shuffled[i].id } })
        end
    end
    return sets
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
    kind = kind or TheContractorRepairContracts.pickKind(math.random, TheContractorRepairContracts.canServiceParts())
    local isParts = kind == TheContractorRepairContracts.PARTS_KIND
    local entry = {
        farmId = farmId,
        zoneUniqueId = TheContractorRepairContracts.getZoneUniqueId(zone),
        bayIndex = bayIndex,
        xmlFilename = model.xmlFilename,
        kind = isParts and TCADSRepairContracts.KIND.MAINTENANCE or kind,
        -- A service of only the stock parts (PARTS_KIND).
        stockParts = isParts or nil,
        severity = severity or TheContractorRepairContracts.pickSeverity(math.random),
        seed = TheContractorRepairContracts.rollSeed(math.random),
        queuedDay = g_currentMission.environment.currentMonotonicDay,
        attempts = 0,
        blockedDays = 0,
        isLoading = false,
    }
    table.insert(self.arrivals, entry)
    TCLog.info("TheContractor: farm %d repair zone bay %d: %s (%s, severity %d) on its way", farmId, bayIndex,
        model.name, isParts and "parts service" or entry.kind, entry.severity)
    return entry
end

-- 101: a customer's machine to break down on a field, at a spot
-- TheContractorFieldBreakdowns picked for its model ({ x, z, rotY, fieldId
-- or, 123, yardFarmlandId }): placed like any arrival, prepared as ADS's
-- breakdown kind, offered due today. 121: owned is { farmer, machine,
-- attachment } when it's a farmer's own machine (its seed and age, and its
-- attachment's getAttachmentArrival), else nil.
function TheContractorRepairContracts:queueBreakdownArrival(farmId, spot, model, fieldService, severity, owned)
    local environment = g_currentMission.environment
    local entry = {
        farmId = farmId,
        fieldId = spot.fieldId,
        yardFarmlandId = spot.yardFarmlandId,
        x = spot.x,
        z = spot.z,
        rotY = spot.rotY,
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
    if owned ~= nil then
        entry.farmerId = owned.farmer.id
        entry.machineId = owned.machine.id
        entry.seed = owned.machine.seed
        entry.operatingHours = TheContractorFarmerFleet.getHours(owned.machine, environment.currentMonotonicDay,
            environment.daysPerPeriod)
        entry.attachment = owned.attachment
    end
    table.insert(self.arrivals, entry)
    TCLog.info("TheContractor: farm %d %s: %s (breakdown, %s, severity %d%s) on its way", farmId,
        TheContractorRepairContracts.describeSpot(entry), model.name, tostring(fieldService), severity,
        owned ~= nil and string.format(", farmer #%d's", owned.farmer.id) or "")
    return entry
end

-- 116: a farmer's own machine to a spot in their yard or on their field
-- (TheContractorFarmerFavours.pickSpot's), for a favour: the machine's own
-- model, seed and age. What's wrong with it is picked once it's loaded.
-- 121: attachment is its getAttachmentArrival, or nil.
function TheContractorRepairContracts:queueFavourArrival(farmId, farmer, machine, model, spot, attachment)
    local environment = g_currentMission.environment
    local entry = {
        farmId = farmId,
        favour = true,
        farmerId = farmer.id,
        machineId = machine.id,
        yardFarmlandId = spot.yardFarmlandId,
        fieldId = spot.fieldId,
        x = spot.x,
        z = spot.z,
        rotY = spot.rotY,
        xmlFilename = model.xmlFilename,
        severity = TheContractorFarmerFavours.SEVERITY,
        seed = machine.seed,
        operatingHours = TheContractorFarmerFleet.getHours(machine, environment.currentMonotonicDay,
            environment.daysPerPeriod),
        attachment = attachment,
        queuedDay = environment.currentMonotonicDay,
        attempts = 0,
        blockedDays = 0,
        isLoading = false,
    }
    table.insert(self.arrivals, entry)
    TCLog.info("TheContractor: farm %d favour for farmer #%d: %s to %s on its way", farmId, farmer.id, model.name,
        TheContractorRepairContracts.describeSpot(entry))
    return entry
end

-- 124: a farmer's machine lent to a job (TheContractorYardBales' telehandler
-- and bale fork) to a spot in their yard: a loan. No ADS, no offer of its
-- own: once it's loaded (and its attachment hitched) it's handed to the job
-- (onLoanArrived), and it waits for its spot as long as the job wants it
-- (isLoanWanted). Not saved: after a load the job sends for it again.
function TheContractorRepairContracts:queueLoanArrival(farmId, jobId, farmer, machine, model, spot, attachment)
    local entry = {
        farmId = farmId,
        loan = true,
        jobId = jobId,
        farmerId = farmer.id,
        machineId = machine.id,
        yardFarmlandId = spot.yardFarmlandId,
        x = spot.x,
        z = spot.z,
        rotY = spot.rotY,
        xmlFilename = model.xmlFilename,
        attachment = attachment,
        queuedDay = g_currentMission.environment.currentMonotonicDay,
        attempts = 0,
        blockedDays = 0,
        isLoading = false,
    }
    table.insert(self.arrivals, entry)
    TCLog.info("TheContractor: farm %d job %d: farmer #%d's %s to %s on its way", farmId, jobId, farmer.id,
        tostring(model.name), TheContractorRepairContracts.describeSpot(entry))
    return entry
end

-- 124: whether a loan arrival's job still wants it.
function TheContractorRepairContracts.isLoanWanted(entry)
    local yardBales = g_currentMission.TheContractor.YardBales
    return yardBales ~= nil and yardBales:isLoanWanted(entry)
end

-- 101, 116: an arrival with a spot of its own (a breakdown or a favour, or
-- 124's loan) rather than a repair zone's bay.
function TheContractorRepairContracts.isSpotArrival(entry)
    return entry.kind == TCADSRepairContracts.KIND.BREAKDOWN or entry.favour == true or entry.loan == true
end

-- For the log: "yard 5" or "field 3".
function TheContractorRepairContracts.describeSpot(entry)
    if entry.yardFarmlandId ~= nil then
        return "yard " .. entry.yardFarmlandId
    end
    return "field " .. tostring(entry.fieldId)
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
        -- 124: a loan waits for as long as its job wants it.
        if TheContractorRepairContracts.isSpotArrival(entry) and not entry.loan and not entry.isLoading and
                entry.queuedDay < today then
            -- 101: a breakdown not placed by midnight would be due yesterday.
            -- 116: and a favour has found someone else.
            TCLog.info("TheContractor: farm %d %s never placed, dropped", entry.farmId,
                entry.favour and "favour" or ("breakdown on " .. TheContractorRepairContracts.describeSpot(entry)))
        elseif entry.isLoading or (entry.blockedDays or 0) <= TheContractorRepairContracts.ARRIVAL_GIVE_UP_DAYS then
            table.insert(kept, entry)
        else
            TCLog.info("TheContractor: farm %d repair zone bay %d had no room for days, arrival dropped",
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

-- An arrival's machine on its own: one ADS can take, or (124) for a loan
-- any model, by its size.
function TheContractorRepairContracts:getArrivalMachineModel(entry)
    if entry.loan then
        return TheContractorFarmerFleet.getSizeModel(entry.xmlFilename)
    end
    return self:findModelByXml(entry.xmlFilename)
end

-- 101, 116: a spot arrival's model, and with an attachment (121) the
-- ground they take together; nil if the model's gone.
function TheContractorRepairContracts:getArrivalModel(entry)
    local model = self:getArrivalMachineModel(entry)
    return model ~= nil and TheContractorFarmerFleet.getFootprint(model, entry.attachment) or nil
end

-- Where a queued arrival goes and what it is: area, model (nil if its
-- zone's been sold or shrunk, or the model's gone).
function TheContractorRepairContracts:getArrivalPlace(entry)
    if TheContractorRepairContracts.isSpotArrival(entry) then
        local model = self:getArrivalModel(entry)
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
    -- 124: a loan needs no ADS, only its job.
    local isWanted = TCADSRepairContracts.isActive()
    if entry.loan then
        isWanted = TheContractorRepairContracts.isLoanWanted(entry)
    end
    if bayArea == nil or storeItem == nil or not isWanted then
        -- The zone's been sold or shrunk, or the model's gone.
        removeFrom(self.arrivals, entry)
        return
    end

    local originX, originZ, centreX, centreZ, rotY = TheContractorRepairContracts.getSpawnPose(model, bayArea)
    local clearance = TheContractorRepairContracts.CLEARANCE
    if not TCParking.isAreaClear(centreX, centreZ, rotY, model.width + clearance, model.length + clearance,
            model.height) then
        if entry.loan then
            -- 124: its spot is beside the job's area; it waits for it to
            -- clear.
            return
        elseif entry.favour then
            -- 116: somewhere else on their yard or fields.
            self:retryFavourSpot(entry, model)
            return
        elseif entry.kind == TCADSRepairContracts.KIND.BREAKDOWN then
            -- 101: something's on that spot: another spot on the field
            -- (123: or in the yard).
            self:retryBreakdownSpot(entry, model)
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

-- 101: a breakdown's spot was taken: another spot for the same model on
-- the same field (123: or in the same yard), up to PREPARE_RETRIES.
function TheContractorRepairContracts:retryBreakdownSpot(entry, model)
    entry.attempts = (entry.attempts or 0) + 1
    local x, z, rotY = nil, nil, nil
    if entry.attempts <= TheContractorRepairContracts.PREPARE_RETRIES then
        if entry.yardFarmlandId ~= nil then
            x, z, rotY = TheContractorFieldBreakdowns.pickYardSpot(entry.yardFarmlandId, model, math.random)
        else
            x, z, rotY = TheContractorFieldBreakdowns.pickSpot(entry.fieldId, model, math.random)
        end
    end
    if x == nil then
        TCLog.info("TheContractor: farm %d breakdown on %s: no room, dropped", entry.farmId,
            TheContractorRepairContracts.describeSpot(entry))
        removeFrom(self.arrivals, entry)
        return
    end
    entry.x, entry.z, entry.rotY = x, z, rotY
end

-- 116: a favour's spot was taken: another of the farmer's, up to
-- PREPARE_RETRIES. The machine stays the same.
function TheContractorRepairContracts:retryFavourSpot(entry, model)
    entry.attempts = (entry.attempts or 0) + 1
    local farmer = g_currentMission.TheContractor.Farmers:getPerson(entry.farmerId)
    local spot = nil
    if farmer ~= nil and entry.attempts <= TheContractorRepairContracts.PREPARE_RETRIES then
        spot = TheContractorFarmerFavours.pickSpot(farmer, model, math.random)
    end
    if spot == nil then
        TCLog.info("TheContractor: farm %d favour for farmer #%s: no room, dropped", entry.farmId,
            tostring(entry.farmerId))
        removeFrom(self.arrivals, entry)
        return
    end
    entry.x, entry.z, entry.rotY = spot.x, spot.z, spot.rotY
    entry.yardFarmlandId, entry.fieldId = spot.yardFarmlandId, spot.fieldId
end

-- A model ADS turned down: another one, another seed, up to PREPARE_RETRIES.
function TheContractorRepairContracts:retryArrival(entry, zone, reason)
    entry.attempts = (entry.attempts or 0) + 1
    if entry.loan then
        -- 124: the farmer's own machine or nothing.
        if entry.attempts > TheContractorRepairContracts.PREPARE_RETRIES then
            TCLog.info("TheContractor: farm %d job %d: farmer #%s's machine wouldn't load, dropped (%s)",
                entry.farmId, entry.jobId, tostring(entry.farmerId), tostring(reason))
            removeFrom(self.arrivals, entry)
        end
        return
    end
    if entry.favour then
        -- 116: the farmer's own machine or nothing: it's loaded again.
        if entry.attempts > TheContractorRepairContracts.PREPARE_RETRIES then
            TCLog.info("TheContractor: farm %d favour for farmer #%s: arrival dropped (%s)", entry.farmId,
                tostring(entry.farmerId), tostring(reason))
            removeFrom(self.arrivals, entry)
        end
        return
    end
    local isBreakdown = entry.kind == TCADSRepairContracts.KIND.BREAKDOWN
    if isBreakdown and entry.machineId ~= nil then
        -- 121: a farmer's own machine or nothing, as a favour's.
        if entry.attempts > TheContractorRepairContracts.PREPARE_RETRIES then
            TCLog.info("TheContractor: farm %d breakdown on %s: farmer #%s's machine dropped (%s)",
                entry.farmId, TheContractorRepairContracts.describeSpot(entry), tostring(entry.farmerId),
                tostring(reason))
            removeFrom(self.arrivals, entry)
        end
        return
    end
    if isBreakdown then
        -- 101: another model for the field, somewhere on it that it fits
        -- (only a farmer's own machine is ever in a yard, 123).
        local model = entry.attempts <= TheContractorRepairContracts.PREPARE_RETRIES and
            TheContractorFieldBreakdowns.pickModel(self, math.random) or nil
        local x, z, rotY = nil, nil, nil
        if model ~= nil then
            x, z, rotY = TheContractorFieldBreakdowns.pickSpot(entry.fieldId, model, math.random)
        end
        if x == nil then
            TCLog.info("TheContractor: farm %d breakdown on field %d: arrival dropped (%s)", entry.farmId,
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
        TCLog.info("TheContractor: farm %d repair zone bay %d: arrival dropped (%s)", entry.farmId, entry.bayIndex,
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
    if not isQueued or (zone == nil and not TheContractorRepairContracts.isSpotArrival(entry)) then
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
    if entry.loan then
        -- 124: hitched up and handed to its job, nothing for ADS to do.
        self:loadAttachment(entry, vehicle, function(attachment)
            removeFrom(self.arrivals, entry)
            local yardBales = g_currentMission.TheContractor.YardBales
            if yardBales ~= nil then
                yardBales:onLoanArrived(entry, vehicle, attachment)
            else
                TheContractorRepairContracts.deleteVehicle(vehicle)
                TheContractorRepairContracts.deleteVehicle(attachment)
            end
        end)
        return
    end
    if entry.favour then
        self:prepareFavour(entry, vehicle)
        return
    end

    -- A parts service tries its target sets, then falls back to an ordinary
    -- service (false: no targets) if the machine takes none of them.
    local targetSets = {}
    if entry.stockParts then
        targetSets = TheContractorRepairContracts.getPartTargetSets(TCADSRepairContracts.getStockParts(), math.random)
    end
    table.insert(targetSets, false)

    local ok, result, quote = false, nil, nil
    for _, targets in ipairs(targetSets) do
        ok, result = TCADSRepairContracts.prepareVehicle(vehicle, {
            kind = entry.kind,
            severity = entry.severity,
            -- 101: a breakdown's field service level (nil for the rest).
            fieldService = entry.fieldService,
            seed = entry.seed,
            -- 121: a farmer's own machine's age (nil the first time out).
            operatingHours = entry.operatingHours,
            ref = string.format("TheContractor:%d:%d", entry.farmId, entry.seed),
            targets = targets or nil,
        })
        quote = ok and TCADSRepairContracts.getQuote(vehicle) or nil
        if ok and quote ~= nil and (tonumber(quote.price) or 0) > 0 then
            if entry.stockParts then
                local ids = {}
                for _, target in ipairs(targets or {}) do
                    table.insert(ids, target.consumable)
                end
                TCLog.info("TheContractor: farm %d parts service on %s: %s", entry.farmId, vehicle:getFullName(),
                    #ids > 0 and table.concat(ids, ", ") or "none fit, an ordinary service")
            end
            break
        end
        if ok then
            TCADSRepairContracts.release(vehicle)
            ok, result = false, "noQuote"
        end
        quote = nil
    end
    if not ok then
        vehicle:delete()
        self:retryArrival(entry, zone, result)
        return
    end

    self:loadAttachment(entry, vehicle, function(attachment)
        removeFrom(self.arrivals, entry)
        if entry.fieldId ~= nil then
            -- 101: only now the spot's final, so a retry leaves no ruts behind.
            TheContractorFieldBreakdowns.clearSpot(entry, self:getArrivalModel(entry))
        end
        self:createOffer(entry, vehicle, quote, attachment)
    end)
end

-- 121: a farmer's machine's attachment, loaded in front of it and hitched
-- on; then done(attachment), or done(nil) without one, or when it won't
-- load or hitch. The arrival stays queued (and loading) meanwhile.
function TheContractorRepairContracts:loadAttachment(entry, vehicle, done)
    local attachment = entry.attachment
    local storeItem = attachment ~= nil and g_storeManager:getItemByXMLFilename(attachment.xmlFilename) or nil
    local model = storeItem ~= nil and self:getArrivalMachineModel(entry) or nil
    if model == nil or vehicle.rootNode == nil then
        done(nil)
        return
    end
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    local dirX, _, dirZ = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    local ahead = (model.lengthOffset or 0) + model.length * 0.5 + attachment.length * 0.5 +
        TheContractorRepairContracts.CLEARANCE
    local loadingData = VehicleLoadingData.new()
    loadingData:setStoreItem(storeItem)
    loadingData:setIgnoreShopOffset(true)
    loadingData:setPosition(x + dirX * ahead, nil, z + dirZ * ahead, TCParking.PLACE_HEIGHT_OFFSET)
    loadingData:setRotation(0, MathUtil.getYRotationFromDirection(dirX, dirZ), 0)
    loadingData:setPropertyState(VehiclePropertyState.MISSION)
    loadingData:setOwnerFarmId(entry.farmId)
    entry.isLoading = true
    loadingData:load(self.onAttachmentLoaded, self, { entry = entry, vehicle = vehicle, done = done })
end

-- VehicleLoadingData's callback for loadAttachment.
function TheContractorRepairContracts:onAttachmentLoaded(vehicles, loadingState, args)
    local entry = args.entry
    entry.isLoading = false
    local attachment = vehicles ~= nil and vehicles[1] or nil
    if attachment ~= nil and (loadingState ~= VehicleLoadingState.OK or args.vehicle.isDeleted or
            not TCJobSiteSetup.hitchImplement(args.vehicle, attachment, entry.farmId)) then
        TCLog.info("TheContractor: farm %d: %s couldn't be hitched to %s, left out", entry.farmId,
            attachment:getFullName(), args.vehicle:getFullName())
        attachment:delete()
        attachment = nil
    end
    args.done(attachment)
end

-- 116: a favour's machine is loaded: one of the stock parts
-- (TheContractorFarmerFavours.getTargets), in random order, and ADS prepares
-- the machine as a service of only that. One it hasn't got, or with no
-- price (nothing to pay back), gives way to the next. If none takes, the
-- machine goes and so does the favour.
function TheContractorRepairContracts:prepareFavour(entry, vehicle)
    local tc = g_currentMission.TheContractor
    local environment = g_currentMission.environment
    local farmer = tc.Farmers:getPerson(entry.farmerId)
    local machine = TheContractorFarmerFleet.getMachine(farmer, entry.machineId)
    local targets = TheContractorFarmerFavours.getTargets(TCADSRepairContracts.getStockParts(),
        machine ~= nil and machine.fitted or nil, environment.currentMonotonicDay, environment.daysPerPeriod)
    for i = #targets, 2, -1 do
        local j = math.random(1, i)
        targets[i], targets[j] = targets[j], targets[i]
    end

    local reason = "noTargets"
    for _, target in ipairs(targets) do
        local ok, result = TCADSRepairContracts.prepareVehicle(vehicle, {
            kind = TCADSRepairContracts.KIND.MAINTENANCE,
            severity = entry.severity,
            seed = entry.seed,
            operatingHours = entry.operatingHours,
            ref = string.format("TheContractor:%d:favour:%d", entry.farmId, entry.farmerId),
            targets = { target.request },
        })
        local quote = ok and TCADSRepairContracts.getQuote(vehicle) or nil
        if quote ~= nil and (tonumber(quote.partsCost) or 0) > 0 then
            self:loadAttachment(entry, vehicle, function(attachment)
                removeFrom(self.arrivals, entry)
                if entry.fieldId ~= nil then
                    TheContractorFieldBreakdowns.clearSpot(entry, self:getArrivalModel(entry))
                end
                self:createFavourOffer(entry, vehicle, quote, target, attachment)
            end)
            return
        end
        if ok then
            TCADSRepairContracts.release(vehicle)
        end
        reason = ok and "noPrice" or result
    end

    TCLog.info("TheContractor: farm %d favour for farmer #%s: nothing to fit on %s (%s), dropped", entry.farmId,
        tostring(entry.farmerId), vehicle:getFullName(), tostring(reason))
    vehicle:delete()
    removeFrom(self.arrivals, entry)
end

-- 116: a favour's offer: due today, as a field breakdown is, its price the part at
-- ADS's list price (the quote's parts, without EconomyScale's factor), with
-- the farmer as the customer. Accepted or declined as it stands.
function TheContractorRepairContracts:createFavourOffer(entry, vehicle, quote, target, attachment)
    local environment = g_currentMission.environment
    local today = environment.currentMonotonicDay
    local partsCost = math.max(tonumber(quote.partsCost) or 0, 0)
    local baseParts = partsCost / TCEconomyScale.getADSFactor()
    local deadlineDay = today
    local workshop = {
        vehicleId = NetworkUtil.getObjectId(vehicle),
        vehicleUniqueId = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or nil,
        vehicleName = vehicle:getFullName(),
        kind = TCADSRepairContracts.KIND.MAINTENANCE,
        severity = entry.severity,
        offerExpiresDay = today,
        quotePrice = quote.price,
        partsCost = partsCost,
        requiredTools = quote.minTools or {},
        operatingHours = quote.operatingHours,
        fieldId = entry.fieldId,
        yardFarmlandId = entry.yardFarmlandId,
        baseParts = baseParts,
        baseLabour = 0,
        laborHours = tonumber(quote.laborHours) or 0,
        farmerId = entry.farmerId,
        machineId = entry.machineId,
        targetId = target.id,
        targetNameKey = target.nameKey,
        -- The size this machine takes, so the player brings the right one.
        partGrade = TCADSRepairContracts.getPartGrade(vehicle, target.id),
    }
    TheContractorRepairContracts.setAttachment(workshop, entry, attachment)
    local job = g_currentMission.TheContractor.Jobs:createJob(entry.farmId, TheContractorFarmerFavours.JOB_TYPE, 0, 1,
        environment:getPeriodFromDay(deadlineDay), environment:getDayInPeriodFromDay(deadlineDay),
        math.floor(baseParts + 0.5), true, nil, deadlineDay, false, nil, nil, workshop)
    if job == nil then
        TCADSRepairContracts.release(vehicle)
        vehicle:delete()
        TheContractorRepairContracts.deleteVehicle(attachment)
        return
    end
    TheContractorFarmerFleet.onOffered(job, quote)
    TCLog.info("TheContractor: farm %d job %d: farmer #%d's %s needs a new %s, %.0f to pay back", entry.farmId,
        job.id, entry.farmerId, workshop.vehicleName, tostring(target.id), job:getPrice())
end

-- 121: the attachment on the job's record (its machine id on the farmer's
-- too).
function TheContractorRepairContracts.setAttachment(workshop, entry, attachment)
    if attachment == nil then
        return
    end
    workshop.attachmentId = NetworkUtil.getObjectId(attachment)
    workshop.attachmentUniqueId = attachment.getUniqueId ~= nil and attachment:getUniqueId() or nil
    workshop.attachmentMachineId = entry.attachment ~= nil and entry.attachment.machineId or nil
end

function TheContractorRepairContracts.deleteVehicle(vehicle)
    if vehicle ~= nil and not vehicle.isDeleted then
        vehicle:delete()
    end
end

-- Pricing (102) ---------------------------------------------------------------------

-- The cheapest fix's cost as base amounts (without FS25_EconomyScale's
-- factor, as every job stores its price): ADS's parts cost carries the
-- factor of the day it was quoted only if EconomyScale scales ADS
-- (TCEconomyScale.getADSFactor), so that's what's divided back out; the
-- labour is its hours at LABOUR_RATE (scaleCost, which always applies the
-- factor, so getFactor is divided out of that). Returns parts, labour.
function TheContractorRepairContracts.getBaseCost(partsCost, laborHours)
    local factor = TCEconomyScale.getFactor()
    local rate = g_currentMission.TheContractor.Settings:scaleCost(TheContractorRepairContracts.LABOUR_RATE)
    return math.max(tonumber(partsCost) or 0, 0) / TCEconomyScale.getADSFactor(),
        math.max(tonumber(laborHours) or 0, 0) * rate / factor
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

function TheContractorRepairContracts:createOffer(entry, vehicle, quote, attachment)
    local today = g_currentMission.environment.currentMonotonicDay
    local partsCost = math.max(tonumber(quote.partsCost) or 0, 0)
    -- 102: the price isn't agreed yet. The job holds the benchmark price
    -- until the player's quote is accepted; it's never shown before then.
    local baseParts, baseLabour = TheContractorRepairContracts.getBaseCost(partsCost, quote.laborHours)
    local isBreakdown = entry.kind == TCADSRepairContracts.KIND.BREAKDOWN
    local benchmark = TheContractorRepairContracts.getBenchmarkMargin(isBreakdown)
    local price = math.floor(TheContractorRepairContracts.getBasePrice(baseParts + baseLabour, benchmark))
    local dueDays = TheContractorRepairContracts.getDueDays(g_currentMission.environment.daysPerPeriod)
    local deadlineDay = today + dueDays
    local offerExpiresDay = deadlineDay - 1
    -- 101: a breakdown is today's or nobody's, and its level is ADS's field
    -- service (who can fix it on the spot), not the workshop's.
    local serviceLevel = quote.serviceLevel
    if isBreakdown then
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
        -- 123: a breakdown in the farmer's yard.
        yardFarmlandId = entry.yardFarmlandId,
        -- 102: the cheapest fix's cost (base), the benchmark margin, and the
        -- customer's ceiling (server only, never streamed).
        baseParts = baseParts,
        baseLabour = baseLabour,
        laborHours = tonumber(quote.laborHours) or 0,
        benchmarkMargin = benchmark,
        refusalMargin = TheContractorRepairContracts.rollRefusalMargin(benchmark),
        -- 121: a farmer's own machine (the farmer's the customer).
        farmerId = entry.farmerId,
        machineId = entry.machineId,
    }
    TheContractorRepairContracts.setAttachment(workshop, entry, attachment)

    local environment = g_currentMission.environment
    local job = g_currentMission.TheContractor.Jobs:createJob(entry.farmId, TheContractorRepairContracts.JOB_TYPES[entry.kind],
        0, 1, environment:getPeriodFromDay(deadlineDay), environment:getDayInPeriodFromDay(deadlineDay), price, true,
        nil, deadlineDay, false, nil, nil, workshop)
    if job == nil then
        TCADSRepairContracts.release(vehicle)
        vehicle:delete()
        TheContractorRepairContracts.deleteVehicle(attachment)
        return
    end
    TheContractorFarmerFleet.onOffered(job, quote)
    TCLog.info("TheContractor: farm %d job %d: %s in for %s, quoted %.0f (parts %.0f, %.1f h), %.0f at the %.0f%% benchmark, ceiling %.0f%%",
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
    TCLog.info("TheContractor: farm %d job %d: quoted at a %.0f%% margin (benchmark %.0f%%, ceiling %.0f%%) - %s",
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
    -- 116: a favour has no margin, only a grateful farmer.
    if TheContractorRepairContracts.isFavourJob(job) then
        TheContractorFarmerFavours.onCompleted(job)
        return
    end
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
    TCLog.info("TheContractor: farm %d job %d finished at a %.0f%% margin: known for overcharging until day %d",
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
        TCLog.info("TheContractor: farm %d no longer known for overcharging", farmId)
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
        -- 121: a farmer's machine is theirs again once it's gone.
        farmerId = workshop.farmerId,
        machineId = workshop.machineId,
    })
    -- 121: and its attachment, wherever it's been left.
    if workshop.attachmentId ~= nil and workshop.attachmentId ~= 0 then
        table.insert(self.removals, {
            farmId = job.farmId,
            vehicleId = workshop.attachmentId,
            uniqueId = workshop.attachmentUniqueId,
            farmerId = workshop.farmerId,
            machineId = workshop.attachmentMachineId,
        })
    end
end

-- 124: a farmer's machine lent to a job goes home once the job's over,
-- wherever it's been left (tryCollect, as a customer's machine).
function TheContractorRepairContracts:queueLoanCollection(farmId, farmerId, vehicleId, uniqueId, machineId)
    for _, entry in ipairs(self.removals) do
        if entry.vehicleId == vehicleId then
            return
        end
    end
    table.insert(self.removals, {
        farmId = farmId,
        vehicleId = vehicleId,
        uniqueId = uniqueId,
        farmerId = farmerId,
        machineId = machineId,
    })
end

function TheContractorRepairContracts:tryCollect(entry)
    local vehicle = entry.vehicleId ~= nil and entry.vehicleId ~= 0 and NetworkUtil.getObject(entry.vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        removeFrom(self.removals, entry)
        return
    end
    -- Not from under someone driving it (121: or the machine it's hitched to).
    local rootVehicle = vehicle.rootVehicle or vehicle
    if rootVehicle.getIsControlled ~= nil and rootVehicle:getIsControlled() then
        return
    end
    removeFrom(self.removals, entry)
    TCLog.info("TheContractor: farm %d: the customer collected %s", entry.farmId, vehicle:getFullName())
    vehicle:delete()
end

-- Completion (server) ------------------------------------------------------------------

function TheContractorRepairContracts:getJobForVehicle(vehicle)
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    local job = vehicleId ~= nil and TheContractorRepairContracts.getContractVehicleIds()[vehicleId] or nil
    -- 124: a farmer's kit lent to a job is a contract vehicle, not a
    -- workshop job's machine.
    if job == nil or job.workshop == nil or job:isTerminal() then
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
    -- 116: word of a favour gets round, a little.
    if TheContractorRepairContracts.isFavourJob(job) then
        return TheContractorFarmerFavours.REPUTATION
    end
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
    -- 116: a favour's done when it's done.
    local maxFactor = job.workshop ~= nil and not TheContractorRepairContracts.isFavourJob(job) and
        TheContractorRepairContracts.SPEED_MAX_FACTOR[job.workshop.kind] or nil
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
-- removed part, or a component ADS can't price. ADS's list price is vanilla
-- whatever EconomyScale does (it scales ADS's quotes and parts shop, never
-- this one), so it's put on today's price level here, like the threshold.
function TheContractorRepairContracts.getTamperValue(vehicle, findings)
    local settings = g_currentMission.TheContractor.Settings
    local partValue = settings:scaleCost(TheContractorRepairContracts.TAMPER_PART_VALUE)
    local total = 0
    for _, finding in ipairs(findings or {}) do
        if finding.kind == "component" then
            local price = TCADSRepairContracts.getPartPrice(vehicle, finding.id)
            if price ~= nil then
                price = price * TCEconomyScale.getFactor()
            end
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
    TCLog.info("TheContractor: farm %d job %d: %s went back tampered with (%d finding(s), %.0f lost), -%d reputation%s",
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
    TCLog.info("TheContractor: farm %d tamper claim for job %d: %.0f paid", claim.farmId, claim.jobId, paid)
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
            stockParts = getXMLBool(xmlFile, key .. "#stockParts") == true or nil,
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
            -- 116: a favour's farmer, machine and yard.
            favour = getXMLBool(xmlFile, key .. "#favour") == true or nil,
            farmerId = getXMLInt(xmlFile, key .. "#farmerId"),
            machineId = getXMLInt(xmlFile, key .. "#machineId"),
            yardFarmlandId = getXMLInt(xmlFile, key .. "#yard"),
            operatingHours = getXMLFloat(xmlFile, key .. "#operatingHours"),
            -- 121.
            attachment = TheContractorRepairContracts.loadArrivalAttachment(xmlFile, key),
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
            -- 121.
            farmerId = getXMLInt(xmlFile, key .. "#farmerId"),
            machineId = getXMLInt(xmlFile, key .. "#machineId"),
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
        -- 124: a loan isn't saved; its job sends for it again after a load.
        if (entry.zoneUniqueId ~= nil or TheContractorRepairContracts.isSpotArrival(entry)) and not entry.loan and
                entry.xmlFilename ~= nil then
            local key = string.format("%s.arrival(%d)", rootKey, index)
            setXMLInt(xmlFile, key .. "#farmId", entry.farmId)
            if entry.favour then
                -- 116: its spot (a field's, or a yard's), farmer and machine.
                setXMLBool(xmlFile, key .. "#favour", true)
                setXMLInt(xmlFile, key .. "#farmerId", entry.farmerId)
                setXMLInt(xmlFile, key .. "#machineId", entry.machineId)
                if entry.fieldId ~= nil then
                    setXMLInt(xmlFile, key .. "#fieldId", entry.fieldId)
                end
                if entry.yardFarmlandId ~= nil then
                    setXMLInt(xmlFile, key .. "#yard", entry.yardFarmlandId)
                end
                if entry.operatingHours ~= nil then
                    setXMLFloat(xmlFile, key .. "#operatingHours", entry.operatingHours)
                end
                setXMLFloat(xmlFile, key .. "#x", entry.x)
                setXMLFloat(xmlFile, key .. "#z", entry.z)
                setXMLFloat(xmlFile, key .. "#rotY", entry.rotY or 0)
            elseif entry.kind == TCADSRepairContracts.KIND.BREAKDOWN then
                -- 101: its spot, on a field or (123) in a yard.
                if entry.fieldId ~= nil then
                    setXMLInt(xmlFile, key .. "#fieldId", entry.fieldId)
                end
                if entry.yardFarmlandId ~= nil then
                    setXMLInt(xmlFile, key .. "#yard", entry.yardFarmlandId)
                end
                setXMLFloat(xmlFile, key .. "#x", entry.x)
                setXMLFloat(xmlFile, key .. "#z", entry.z)
                setXMLFloat(xmlFile, key .. "#rotY", entry.rotY or 0)
                if entry.fieldService ~= nil then
                    setXMLString(xmlFile, key .. "#fieldService", entry.fieldService)
                end
                -- 121: a farmer's own machine.
                if entry.machineId ~= nil then
                    setXMLInt(xmlFile, key .. "#farmerId", entry.farmerId)
                    setXMLInt(xmlFile, key .. "#machineId", entry.machineId)
                    if entry.operatingHours ~= nil then
                        setXMLFloat(xmlFile, key .. "#operatingHours", entry.operatingHours)
                    end
                end
            else
                setXMLString(xmlFile, key .. "#zoneUniqueId", entry.zoneUniqueId)
                setXMLInt(xmlFile, key .. "#bayIndex", entry.bayIndex)
            end
            setXMLString(xmlFile, key .. "#xmlFilename", entry.xmlFilename)
            -- A favour's kind is only picked once it's loaded.
            if entry.kind ~= nil then
                setXMLString(xmlFile, key .. "#kind", entry.kind)
            end
            if entry.stockParts then
                setXMLBool(xmlFile, key .. "#stockParts", true)
            end
            setXMLInt(xmlFile, key .. "#severity", entry.severity)
            setXMLInt(xmlFile, key .. "#seed", entry.seed)
            setXMLInt(xmlFile, key .. "#queuedDay", entry.queuedDay)
            setXMLInt(xmlFile, key .. "#attempts", entry.attempts or 0)
            setXMLInt(xmlFile, key .. "#blockedDays", entry.blockedDays or 0)
            TheContractorRepairContracts.saveArrivalAttachment(xmlFile, key, entry.attachment)
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
            if entry.machineId ~= nil then
                setXMLInt(xmlFile, key .. "#farmerId", entry.farmerId)
                setXMLInt(xmlFile, key .. "#machineId", entry.machineId)
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

-- 121: an arrival's attachment ({ machineId, xmlFilename, width, length,
-- height }), or nil.
function TheContractorRepairContracts.loadArrivalAttachment(xmlFile, key)
    local machineId = getXMLInt(xmlFile, key .. ".attachment#machineId")
    local xmlFilename = getXMLString(xmlFile, key .. ".attachment#xmlFilename")
    if machineId == nil or xmlFilename == nil then
        return nil
    end
    return {
        machineId = machineId,
        xmlFilename = xmlFilename,
        width = getXMLFloat(xmlFile, key .. ".attachment#width") or 3,
        length = getXMLFloat(xmlFile, key .. ".attachment#length") or 3,
        height = getXMLFloat(xmlFile, key .. ".attachment#height") or 3,
    }
end

function TheContractorRepairContracts.saveArrivalAttachment(xmlFile, key, attachment)
    if attachment == nil then
        return
    end
    setXMLInt(xmlFile, key .. ".attachment#machineId", attachment.machineId)
    setXMLString(xmlFile, key .. ".attachment#xmlFilename", attachment.xmlFilename)
    setXMLFloat(xmlFile, key .. ".attachment#width", attachment.width)
    setXMLFloat(xmlFile, key .. ".attachment#length", attachment.length)
    setXMLFloat(xmlFile, key .. ".attachment#height", attachment.height or 3)
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
        TCLog.info("TheContractor: farm %d job %d: %s can't be worked after loading (%s), ended without penalty",
            job.farmId, job.id, job.workshop.vehicleName or "?",
            not TCADSRepairContracts.isActive() and "no ADS" or
            TheContractorRepairContracts.getVehicle(job) == nil and "machine gone" or "no contract")
        jobs:missJob(job, true)
    end
end

-- Console (tcJob) ------------------------------------------------------------------------

-- The bay kinds `tcJob offer` takes (JobGeneration's command hands them to
-- consoleOffer): field breakdowns come from `tcCompany event` instead.
TheContractorRepairContracts.CONSOLE_OFFER_KINDS = { "repair", "maintenance", "parts" }

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

-- `tcJob offer repair|maintenance|parts [severity]`: a customer's machine
-- sent to the farm's first free repair zone bay, queued like a normal
-- arrival.
function TheContractorRepairContracts.consoleOffer(farmId, kind, severityArg)
    local severity = tonumber(severityArg)
    if severityArg ~= nil and (severity == nil or severity < 1 or severity > 3) then
        return string.format("Usage: tcJob offer %s [severity 1-3]", kind)
    end
    if not TCADSRepairContracts.isActive() then
        return TCADSRepairContracts.describe()
    end
    if kind == TheContractorRepairContracts.PARTS_KIND and not TheContractorRepairContracts.canServiceParts() then
        return "This version of ADS can't do a service of only the stock parts (no targets or stock parts)."
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
    return string.format("Queued %s (%s, severity %d) for bay %d.", entry.xmlFilename,
        entry.stockParts and "parts service" or entry.kind, entry.severity, bayIndex)
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
