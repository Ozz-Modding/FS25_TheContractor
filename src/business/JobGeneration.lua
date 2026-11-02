-- Job generation engine (011): the hourly-tick system that actually
-- creates new Job offers (008), matched to the player's owned equipment
-- (009's TCEquipmentClass) and, where relevant, a predicted future-ready
-- crop (010's TCCropPrediction). Reputation-driven, with 012's advertising
-- state layered in as an additive chance bonus. 026 set the numbers: see
-- getHourlyChance (frequency), pickField (job size) and estimatePrice (pay).
-- Advertising only ever adds frequency - job size and pay follow
-- reputation alone, so a new company buying ads gets more small, low-paid
-- work, not bigger jobs.
--
-- No state of its own to persist — every job it creates goes straight
-- through TheContractorJobs:createJob, which already owns the
-- server-authoritative apply+broadcast (005). So unlike Reputation/Jobs/
-- Staff/Company this isn't added to TCInitialClientStateEvent; there's
-- nothing here a joining client would need replayed to it.

TheContractorJobGeneration = {}
TheContractorJobGeneration_mt = Class(TheContractorJobGeneration)

-- One entry per generatable job type, one per vanilla field mission type
-- (032, Reference/FS25_Lua/missions/field/):
--   implementSpec    the vehicle specialization an implement must carry to
--                    do the work (harvest has none - its crop-specific
--                    header/harvester matching lives in TCEquipmentClass.
--                    getMissingEquipment). weederType/supplyFillTypeNames
--                    narrow it further (TCEquipmentClass.isJobImplement).
--                    excludedSpecs rules out an implement that carries the
--                    spec but does other work: a plow with a packer has
--                    spec_cultivator (vanilla's PlowPacker needs it), but
--                    it plows, so it's no use on a cultivate job.
--                    Whether a tractor is needed too is worked out from the
--                    equipment itself: only when nothing chosen is
--                    self-propelled.
--   vanillaMission   the vanilla mission class whose static
--                    isAvailableForField(field, nil) decides which fields
--                    qualify (getCandidateFields) - vanilla's own rules, not
--                    re-derived. Harvest keeps its own predicate instead,
--                    since it also offers future-dated work (010).
--   cropDependent    harvest only: the header/harvester matching, 010's
--                    ready-date prediction, 035's haulage and auto-empty.
--   recordsCrop      the field's crop is recorded on the job at generation
--                    (fruitTypeName) - "Mow (Grass)", "Bale (Barley)".
--   recordsPlannedCrop  sow: the crop to sow (the field's planned crop) is
--                    recorded instead - "Sow (Wheat)". Clients only ever
--                    learn it from the job, since vanilla keeps the plan on
--                    the server.
--   startState       which field state the job starts from, recorded at
--                    generation (job.startState) and put back at allocation
--                    (TCFieldPreparation) - fertilize's spray level and
--                    herbicide's weed state set the target, weed/hoe just
--                    need the weeds back if an NPC dealt with them since.
--   seasonRule       vanilla's own seasonal cut-off (isAvailableForField's
--                    environment block), applied to future days too
--                    (isDoableOnDay): "noWinter", or "noWinterOrEarlySpring".
--   requiresWeeds    only when the save has weeds switched on (vanilla's
--                    weed missions' canRun). requiresStones likewise for
--                    stones.
--   serverMeasured   progress is measured against something only the server
--                    knows (spawned windrow, the field's weeds at the start,
--                    spawned bales) - see TCJobProgress.
--   playerOnly       no hired worker can do it: the AI Helper can't drive a
--                    standalone bale wrapper, or a bale loader.
--   deliversBales    067: the job's crop can have to go to a selling point
--                    as bales (straw only, see getStrawFillType) - a bale
--                    job rolls it like harvest's haulage, and with it
--                    becomes player-only (isPlayerOnly).
--   deliveryOnly     067: the job is the delivery and nothing else - always
--                    includesHaulage, no field work to measure (progress is
--                    what's been delivered) and nothing to equip
--                    (noEquipment: we can't tell how the player will move
--                    the bales). Priced per bale and by distance
--                    (getStrawDeliveryReward), not per hectare.
--   skill            the worker operation skill the work uses (044, see
--                    TheContractorWorker.SKILLS). Sow says "seeding", but
--                    is split by crop - see getOperationSkill.
--   certification    a certificate the hired worker doing it must hold (054,
--                    TheContractorTraining.CERTIFICATIONS) - herbicide needs
--                    "spraying" (PA1/PA2). The player is assumed certified.
--   rewardPerHa      the pricing anchor, vanilla's own per-mission-type
--                    loadMapData default (plow 2800, cultivate 2300, sow
--                    2000, harvest 2500, mow 2500, tedder 1500, bale 2200,
--                    fertilize 1500, herbicide 1500, weed 2000, hoe 1500,
--                    stone pick 2200), so a job here reads as "the same job
--                    vanilla contracts would pay for". Bale wrap is paid per
--                    bale in vanilla (rewardPerBale 300), turned into a
--                    per-hectare figure by getRewardPerHa. estimatePrice
--                    layers reputation and skill on top (026).
--   rewardPerItem    075: paid per piece rather than per hectare (fly-tipping,
--                    see estimatePrice's itemCount), with reputationPerItem
--                    in place of reputationPerHa.
--   spill            106: a tipped trailer's spilt crop to clear off the road
--                    and deliver (TheContractorCropSpill), on the harvest
--                    job's field. Also deliveryOnly, and:
--   noReward         106: no reputation for doing it (or pay: its price is 0)
--   noJobEvents      106: no job events (074) roll on it as it completes
--   workAreaTypes    076: the WorkAreaType names the job's field can be
--                    worked with (TCFieldAccess), copied from the vanilla
--                    mission's own workAreaTypes, so a cultivate job lets
--                    you cultivate the field and nothing else (harvest's
--                    TEDDER is the one vanilla adds for onions). Names, not
--                    the WorkAreaType values, since those are looked up
--                    when the map loads. None at all for a job with no
--                    ground work (bale wrap, deliveries, fly-tipping).
--   favour           116: a workshop job on a farmer's own machine, a part
--                    to fit as a favour (TheContractorFarmerFavours):
--                    accepted as it stands, never negotiated, the farmer
--                    its customer.
--   yardDelivery     a job in a farmer's yard, the farmer its customer: 124's
--                    bales taken there and put down in a marked area
--                    (job.yardDelivery, TheContractorYardBales), or 126's
--                    load of theirs sold from it (job.yardHaul,
--                    TheContractorYardHaul). Its missed notification is
--                    its own (tc_<type>_missedNotification).
-- A type left out of JOB_TYPE_KEYS (flyTipping, spillRecovery) is never
-- generated, shown by the availability snapshot or created by tcJob: only
-- its random event makes one (075 with createJobOnField, 106 with
-- createJob).
-- reputationPerHa is the completion reputation reward per hectare for a
-- 100% job (see TheContractorJobs:calculateReputationReward, 080): plow anchored at ~10 for a
-- 1.07 ha (2.65 acre) field, the rest scaled from it by the same ratios as
-- rewardPerHa (REPUTATION_PER_REWARD), since those already reflect how
-- slow/laborious each job is.
TheContractorJobGeneration.JOB_TYPES = {
    harvest = { cropDependent = true, recordsCrop = true, rewardPerHa = 2500, reputationPerHa = 8.5,
        skill = "harvesting",
        workAreaTypes = { "CUTTER", "COMBINECHOPPER", "COMBINESWATH", "FRUITPREPARER", "TEDDER" } },
    cultivate = { implementSpec = "spec_cultivator", excludedSpecs = { "spec_plow" }, vanillaMission = CultivateMission,
        rewardPerHa = 2300, reputationPerHa = 7.8, skill = "tillage",
        workAreaTypes = { "CULTIVATOR" } },
    sow = { implementSpec = "spec_sowingMachine", vanillaMission = SowMission, recordsPlannedCrop = true,
        rewardPerHa = 2000,
        reputationPerHa = 6.8, skill = "seeding",
        workAreaTypes = { "SOWINGMACHINE", "RIDGEMARKER" } },
    plow = { implementSpec = "spec_plow", vanillaMission = PlowMission, rewardPerHa = 2800, reputationPerHa = 9.5,
        skill = "tillage",
        workAreaTypes = { "PLOW" } },
    mow = { implementSpec = "spec_mower", vanillaMission = MowMission, recordsCrop = true,
        seasonRule = "noWinterOrEarlySpring", rewardPerHa = 2500, reputationPerHa = 8.5, skill = "grassland",
        workAreaTypes = { "MOWER" } },
    tedder = { implementSpec = "spec_tedder", vanillaMission = TedderMission, seasonRule = "noWinterOrEarlySpring",
        serverMeasured = true, rewardPerHa = 1500, reputationPerHa = 5.1, skill = "grassland",
        workAreaTypes = { "TEDDER" } },
    bale = { implementSpec = "spec_baler", vanillaMission = BaleMission, recordsCrop = true, seasonRule = "noWinter",
        serverMeasured = true, deliversBales = true, rewardPerHa = 2200, reputationPerHa = 7.5, skill = "baling",
        workAreaTypes = { "BALER" } },
    baleWrap = { implementSpec = "spec_baleWrapper", vanillaMission = BaleWrapMission, seasonRule = "noWinter",
        serverMeasured = true, playerOnly = true, rewardPerBale = 300, skill = "baling" },
    strawDelivery = { vanillaMission = BaleMission, recordsCrop = true, seasonRule = "noWinter", serverMeasured = true,
        playerOnly = true, noEquipment = true, deliversBales = true, deliveryOnly = true, reputationPerHa = 5.1,
        skill = "haulage" },
    fertilize = { implementSpec = "spec_sprayer", vanillaMission = FertilizeMission, startState = "sprayLevel",
        supplyFillTypeNames = { "FERTILIZER", "LIQUIDFERTILIZER", "MANURE", "LIQUIDMANURE" }, seasonRule = "noWinter",
        rewardPerHa = 1500, reputationPerHa = 5.1, skill = "cropCare",
        workAreaTypes = { "SPRAYER" } },
    herbicide = { implementSpec = "spec_sprayer", vanillaMission = HerbicideMission, startState = "weedState",
        supplyFillTypeNames = { "HERBICIDE" }, seasonRule = "noWinter", requiresWeeds = true, rewardPerHa = 1500,
        reputationPerHa = 5.1, skill = "cropCare", certification = "spraying",
        workAreaTypes = { "SPRAYER" } },
    weed = { implementSpec = "spec_weeder", weederType = "weed", vanillaMission = WeedMission,
        startState = "weedState", seasonRule = "noWinter", requiresWeeds = true, serverMeasured = true,
        rewardPerHa = 2000, reputationPerHa = 6.8, skill = "cropCare",
        workAreaTypes = { "WEEDER" } },
    hoe = { implementSpec = "spec_weeder", weederType = "hoe", vanillaMission = HoeMission, startState = "weedState",
        seasonRule = "noWinter", requiresWeeds = true, serverMeasured = true, rewardPerHa = 1500,
        reputationPerHa = 5.1, skill = "cropCare",
        workAreaTypes = { "WEEDER" } },
    stonePick = { implementSpec = "spec_stonePicker", vanillaMission = StonePickMission, seasonRule = "noWinter",
        requiresStones = true, rewardPerHa = 2200, reputationPerHa = 7.5, skill = "tillage",
        workAreaTypes = { "STONEPICKER" } },
    -- 075: clearing a fly-tipped pile by hand. A piece pays what a bale
    -- wrap's bale does, and earns about the reputation that pay would on
    -- a plow job (REPUTATION_PER_REWARD).
    flyTipping = { serverMeasured = true, playerOnly = true, noEquipment = true, rewardPerItem = 300,
        reputationPerItem = 1 },
    -- 106: a tipped trailer's load off the road and to the customer's
    -- selling point, by the end of tomorrow, for nothing.
    spillRecovery = { serverMeasured = true, playerOnly = true, noEquipment = true, deliveryOnly = true,
        spill = true, noReward = true, noJobEvents = true, skill = "haulage" },
    -- 107: trees down across roads after bad weather, for the council
    -- (TheContractorFallenTree). Its field is only the one nearest the
    -- first tree, to say where they are (offField: nothing's done to it,
    -- the markers are on the trees). Taken on means allocated to the farm's
    -- players at once (allocateOnAccept), since it's due the same day. A
    -- fixed reward and price (the event's own), done once every road is
    -- clear.
    fallenTree = { serverMeasured = true, playerOnly = true, noEquipment = true, offField = true,
        allocateOnAccept = true, noJobEvents = true, reputationReward = 10, locationKey = "tc_fallenTree_location",
        equipmentNeed = "chainsaw" },
    -- 100: a customer's machine in a repair zone, for a repair or a
    -- service with FS25_AdvancedDamageSystem (TheContractorRepairContracts).
    -- No field (fieldId 0), crew or kit of ours: priced from ADS's quote,
    -- rewarded by severity, done when ADS says so.
    adsRepair = { workshopJob = true, playerOnly = true, noEquipment = true },
    adsMaintenance = { workshopJob = true, playerOnly = true, noEquipment = true },
    -- 101: a customer's machine broken down on a field, fixed on the spot
    -- (TheContractorFieldBreakdowns), otherwise as 100's.
    adsBreakdown = { workshopJob = true, playerOnly = true, noEquipment = true },
    -- 116: a farmer's own machine needing a new part, fitted as a favour.
    adsFavour = { workshopJob = true, playerOnly = true, noEquipment = true, favour = true },
    -- 124: the farm's own bales to a farmer's yard (TheContractorYardBales).
    -- Its field is only the farmer's nearest one (offField: the marker's on
    -- the drop area), it's the player's as soon as it's accepted
    -- (allocateOnAccept), and it earns per bale asked for (job.workTotal).
    yardBales = { serverMeasured = true, playerOnly = true, noEquipment = true, offField = true,
        allocateOnAccept = true, yardDelivery = true, reputationPerItem = 1, skill = "haulage" },
    -- 126: a farmer's own trailer, full, from their yard to a selling point
    -- (TheContractorYardHaul): 035's haulage and nothing else (deliveryOnly),
    -- offField and allocateOnAccept as 124's, and a straw delivery's sort of
    -- reward for its one load.
    yardHaul = { serverMeasured = true, playerOnly = true, noEquipment = true, offField = true,
        allocateOnAccept = true, yardDelivery = true, deliveryOnly = true, reputationReward = 10, skill = "haulage",
        equipmentNeed = "trailerTractor" },
    -- 127: a farmer's machine run dry on their field, filled from the farm's
    -- own diesel (TheContractorEmergencyRefuel). Its field only says where
    -- the machine is (offField: the marker's on the machine), it's due the
    -- same day (allocateOnAccept), and like a favour (116) it earns a little
    -- reputation and more of the farmer's goodwill.
    emergencyRefuel = { serverMeasured = true, playerOnly = true, noEquipment = true, offField = true,
        allocateOnAccept = true, noJobEvents = true, reputationReward = 2, equipmentNeed = "diesel" },
}
TheContractorJobGeneration.JOB_TYPE_KEYS = { "harvest", "cultivate", "sow", "plow", "mow", "tedder", "bale",
    "baleWrap", "strawDelivery", "fertilize", "herbicide", "weed", "hoe", "stonePick" }

-- Reputation per unit of rewardPerHa, from plow's anchor above - for job
-- types without a fixed reputationPerHa (bale wrap, whose rewardPerHa is
-- worked out rather than fixed).
TheContractorJobGeneration.REPUTATION_PER_REWARD = 9.5 / 2800

-- Bale wrap (032): vanilla sizes its jobs in bales of this type (its round
-- option), so pricing does too - see getRewardPerHa.
TheContractorJobGeneration.BALE_WRAP_PRICING_BALE = { isRoundbale = true, width = 1.2, diameter = 1.5 }

-- Offer frequency (026), before the daysPerPeriod division in
-- getHourlyChance. Expected generation hits per period are 24x the chance:
-- BASE (standing 0) is ~2 per period, REPUTATION_MAX (standing 1) ~8.4,
-- linear on Reputation:getStanding between them. Advertising's chanceBonus
-- (already scaled down by reputation, 027) adds on top, and MAX caps the total at ~12 per period so the biggest ad
-- on the top tier can't flood the inbox. A hit only fails to become an
-- offer when no job type has an eligible field with a workable deadline
-- (see tryGenerateJob).
TheContractorJobGeneration.BASE_HOURLY_CHANCE = 0.08
TheContractorJobGeneration.REPUTATION_MAX_HOURLY_CHANCE = 0.35
TheContractorJobGeneration.MAX_HOURLY_CHANCE = 0.5

-- Fleet weighting (033): the share of generation hits that draw from the
-- work the farm owns the equipment for (see pickJobType). The rest draw
-- from every job type with work going, so there's still a reason to buy
-- kit for work the farm can't take on yet (011's Q15). Placeholder split.
TheContractorJobGeneration.FULFILLABLE_TYPE_SHARE = 0.7

-- Job size (026): a field bigger than the farm's tier's maxPreferredFieldHa
-- (Reputation.TIERS) is this much less likely to be picked than one within
-- it. Weighted rather than excluded, so a map short on small fields still
-- produces work.
TheContractorJobGeneration.OVERSIZE_FIELD_WEIGHT = 0.1

-- Relative likelihood of an offer arriving in each in-game hour (index =
-- hour 0-23): farmers mostly ring round in the morning, a steady trickle
-- through the afternoon, little in the evening, almost nothing overnight.
-- Normalised at load (HOUR_WEIGHT_SCALE) so the weights average 1 — they
-- shift *when* offers arrive, not how many arrive per day.
TheContractorJobGeneration.HOUR_WEIGHTS = {
    [0] = 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, -- 00-05
    0.5, 0.5, -- 06-07
    3, 3, 3, 3, -- 08-11
    1, 1, 1, 1, 1, 1, -- 12-17
    0.5, 0.5, -- 18-19
    0.1, 0.1, 0.1, 0.1, -- 20-23
}
do
    local total = 0
    for hour = 0, 23 do
        total = total + TheContractorJobGeneration.HOUR_WEIGHTS[hour]
    end
    TheContractorJobGeneration.HOUR_WEIGHT_SCALE = 24 / total
end

-- Daily floor: the hourly rolls average under one offer a day for a new
-- company on longer months (~0.6 a day on 3-day months), and some days
-- they all miss. So if a farm has had no offer from the roll by
-- FLOOR_HOURS' first hour, one may be forced then (FLOOR_FIRST_HOUR_CHANCE,
-- so they don't all land on the hour), and is forced at its last hour if
-- there's still none. It still goes through tryGenerateJob, so a day with
-- no work to offer stays a day with no offer.
TheContractorJobGeneration.FLOOR_FIRST_HOUR = 8
TheContractorJobGeneration.FLOOR_LAST_HOUR = 9
TheContractorJobGeneration.FLOOR_FIRST_HOUR_CHANCE = 0.5

-- Deadlines (see getDeadlineDay). An offer arriving with fewer than
-- MIN_HOURS_LEFT_TODAY hours of the day left can't be due today — it's due
-- tomorrow at the earliest. On top of that earliest day, up to
-- MAX_EXTRA_DAYS of random slack, trimmed back to the last day the job is
-- still actually doable (crop still plantable/harvest-ready). Measured in
-- days, not periods, so it means the same thing at any daysPerPeriod
-- setting — on 1-day months a day of slack is a whole month of calendar.
TheContractorJobGeneration.MIN_HOURS_LEFT_TODAY = 8
TheContractorJobGeneration.MAX_EXTRA_DAYS = 2

-- Pricing (026): rewardPerHa (above) scaled by the same economicDifficulty
-- curve vanilla's AbstractFieldMission:getReward uses, then by reputation
-- (linear on Reputation:getStanding: a brand new company gets lowballed at
-- MIN, a prestigious one gets a premium at MAX), then by a premium for the
-- job's required skill level (SKILL_PRICE_PREMIUM per level above 1 - a
-- job that needs a better operator pays for one), then a small random
-- spread so offers don't all land on the exact same number for a given
-- field size.
TheContractorJobGeneration.MIN_REPUTATION_PRICE_MULTIPLIER = 0.75
TheContractorJobGeneration.MAX_REPUTATION_PRICE_MULTIPLIER = 1.25
TheContractorJobGeneration.SKILL_PRICE_PREMIUM = 0.04
TheContractorJobGeneration.MIN_PRICE_VARIANCE = 0.9
TheContractorJobGeneration.MAX_PRICE_VARIANCE = 1.1

-- Job pay rate (048): the whole price is then scaled by the "Job pay rate"
-- setting (TheContractorSettings, 50-500%), where 100% is JOB_PAY_BASELINE
-- of the vanilla-scale price above. Vanilla mission pay is roughly 20-35x
-- real UK contractor rates, and wages are 1x UK since 047; the right level
-- is still being found in play - retune this once it is. Reputation isn't
-- scaled (reputationPerHa / REPUTATION_PER_REWARD use rewardPerHa).
TheContractorJobGeneration.JOB_PAY_BASELINE = 0.8

-- Harvest & haul (035): the share of harvest offers where the client wants
-- the crop carted to a selling point as well as the field combined - a
-- two-person job, worth more money and reputation than a plain harvest.
-- Only rolled when some selling point takes the crop at all. Reviewed in
-- 026 and kept: it needs a second worker and a tractor+trailer, and 1.5x
-- roughly pays for that second operator.
TheContractorJobGeneration.HAULAGE_CHANCE = 0.4
TheContractorJobGeneration.HAULAGE_PRICE_MULTIPLIER = 1.5
TheContractorJobGeneration.HAULAGE_REPUTATION_MULTIPLIER = 1.5

-- Straw delivery (067), the shape of vanilla TransportMission.calculateReward:
-- so much per bale, plus so much per metre (field to selling point, as the
-- crow flies) for every load of BALES_PER_LOAD - before the same
-- difficulty, reputation, skill, spread and pay-rate layers as any other
-- job (estimatePrice). Both rates are 70% of vanilla's (350 a bale, 0.5 a
-- metre), cut after the first in-game test. Bale & deliver (a straw bale
-- job with delivery) is priced like harvest & haul, by
-- HAULAGE_PRICE_MULTIPLIER.
TheContractorJobGeneration.STRAW_DELIVERY_REWARD_PER_BALE = 245
TheContractorJobGeneration.STRAW_DELIVERY_REWARD_PER_METER = 0.35
TheContractorJobGeneration.STRAW_DELIVERY_BALES_PER_LOAD = 5

-- Required operator skill (026) rises with standing: the top of the range
-- runs from MAX_REQUIRED_SKILL_LEVEL_AT_START (standing 0) to
-- MAX_REQUIRED_SKILL_LEVEL (standing 1), and the range reaches
-- REQUIRED_SKILL_SPREAD levels below that, floored at
-- MIN_REQUIRED_SKILL_LEVEL. A new company's clients ask little of its
-- operators; a prestigious one's expect the best.
TheContractorJobGeneration.MIN_REQUIRED_SKILL_LEVEL = 1
TheContractorJobGeneration.MAX_REQUIRED_SKILL_LEVEL_AT_START = 3
TheContractorJobGeneration.MAX_REQUIRED_SKILL_LEVEL = 10
TheContractorJobGeneration.REQUIRED_SKILL_SPREAD = 4

function TheContractorJobGeneration.new()
    local self = {}
    setmetatable(self, TheContractorJobGeneration_mt)
    -- Server-only, not saved: the monotonic day each farm last had an offer
    -- from the hourly roll, for the daily floor.
    self.lastOfferDayByFarm = {}
    return self
end

-- Server-only (Q9/MP requirement): clients never roll for or create jobs
-- themselves, they just receive TCJobCreatedEvent broadcasts like any other
-- client-side Jobs consumer.
function TheContractorJobGeneration:startHourlyTick()
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
end

function TheContractorJobGeneration:stopHourlyTick()
    g_messageCenter:unsubscribe(MessageType.HOUR_CHANGED, self)
end

function TheContractorJobGeneration:onHourChanged(hour)
    hour = hour or g_currentMission.environment.currentHour
    for _, farm in ipairs(g_farmManager:getFarms()) do
        local farmId = farm.farmId
        if g_currentMission.TheContractor.Company:hasCompany(farmId) then
            self:rollForFarm(farmId, hour)
        end
    end
end

function TheContractorJobGeneration:rollForFarm(farmId, hour)
    local hourWeight = (TheContractorJobGeneration.HOUR_WEIGHTS[hour] or 1) * TheContractorJobGeneration.HOUR_WEIGHT_SCALE
    if math.random() <= self:getHourlyChance(farmId) * hourWeight then
        self:generateForFarm(farmId)
    end

    if self:isFloorDue(farmId, hour) then
        self:generateForFarm(farmId)
    end
end

function TheContractorJobGeneration:generateForFarm(farmId)
    local job = self:tryGenerateJob(farmId)
    if job ~= nil then
        self.lastOfferDayByFarm[farmId] = g_currentMission.environment.currentMonotonicDay
    end
    return job
end

-- See FLOOR_FIRST_HOUR.
function TheContractorJobGeneration:isFloorDue(farmId, hour)
    if self.lastOfferDayByFarm[farmId] == g_currentMission.environment.currentMonotonicDay then
        return false
    end
    if hour == TheContractorJobGeneration.FLOOR_LAST_HOUR then
        return true
    end
    return hour == TheContractorJobGeneration.FLOOR_FIRST_HOUR and
        math.random() < TheContractorJobGeneration.FLOOR_FIRST_HOUR_CHANCE
end

function TheContractorJobGeneration:getHourlyChance(farmId)
    local standing = g_currentMission.TheContractor.Reputation:getStanding(farmId)
    local advertisingBonus = g_currentMission.TheContractor.Advertising:getChanceBonus(farmId)
    local daysPerPeriod = g_currentMission.environment.daysPerPeriod

    -- The roll is per hour, but a save's daysPerPeriod setting (how many
    -- real hours a full period/"month" spans) directly multiplies how many
    -- rolls happen per month for the exact same per-hour chance — a 1-day
    -- month gets 24 rolls, a 5-day month gets 120. Dividing by daysPerPeriod
    -- keeps the *expected number of jobs per month* roughly constant across
    -- that setting instead of scaling up with it.
    local chance = TheContractorJobGeneration.BASE_HOURLY_CHANCE + standing *
        (TheContractorJobGeneration.REPUTATION_MAX_HOURLY_CHANCE - TheContractorJobGeneration.BASE_HOURLY_CHANCE) +
        advertisingBonus
    return math.min(TheContractorJobGeneration.MAX_HOURLY_CHANCE, chance) / daysPerPeriod
end

-- Picks a job type + eligible field (pickJobType/pickField), works out its
-- deadline (see getDeadlineDay), tags it with current equipment
-- fulfillment, and creates it. A field with no workable deadline is
-- dropped and the type re-picked (033), so a roll only generates nothing
-- when no type has an eligible field with a workable deadline — and then
-- generation just skips a beat rather than forcing a bad offer out.
--
-- onlyJobType (the tcJob offer console command) restricts the roll to that
-- one type and always prefers a field the farm can fulfill, falling back
-- to any of the type's fields - same rules otherwise, so a forced offer is
-- still one the generator could have made on its own.
function TheContractorJobGeneration:tryGenerateJob(farmId, onlyJobType)
    local options = self:getJobTypeOptions(farmId, onlyJobType)
    local preferFulfillable = onlyJobType ~= nil or
        math.random() < TheContractorJobGeneration.FULFILLABLE_TYPE_SHARE
    local field, deadlineDay, readyDay, option
    while deadlineDay == nil do
        local candidates
        option, candidates = self:pickJobType(options, preferFulfillable)
        if option == nil then
            return nil
        end

        -- Exhaust this type's fields before re-picking the type, so a type
        -- with many undatable fields is as likely as any other.
        while deadlineDay == nil and #candidates > 0 do
            field = self:pickField(farmId, candidates)
            deadlineDay, readyDay = self:getDeadlineDay(field, option.jobDef)
            if deadlineDay == nil then
                TheContractorJobGeneration.removeCandidate(option, field)
            end
        end
    end

    local jobType, jobDef = option.jobType, option.jobDef
    local requiredSkillLevel = self:rollRequiredSkillLevel(farmId)
    local fruitTypeName = TheContractorJobGeneration.getRecordedFruitTypeName(field, jobDef)
    local fruitTypeIndex = TheContractorJobGeneration.getFruitTypeIndexByName(fruitTypeName)
    local equipmentAvailable = table.hasElement(option.fulfillable, field)

    -- 067: a straw delivery always has somewhere to go (getCandidateFields
    -- only offers it when somewhere takes straw bales), and its price
    -- depends on how far that is.
    local deliveryStation = nil
    if jobDef.deliveryOnly then
        deliveryStation = TCHaulage.findBaleDeliveryStation(TheContractorJobGeneration.getStrawFillType(fruitTypeIndex))
        if deliveryStation == nil then
            return nil
        end
    end
    local price = self:estimatePrice(field, jobDef, farmId, requiredSkillLevel, deliveryStation)

    if not jobDef.deliveryOnly and fruitTypeIndex ~= nil and
        math.random() < TheContractorJobGeneration.HAULAGE_CHANCE then
        if jobDef.cropDependent then
            deliveryStation = TCHaulage.findDeliveryStation(g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(
                fruitTypeIndex))
        elseif jobDef.deliversBales then
            deliveryStation = TCHaulage.findBaleDeliveryStation(TheContractorJobGeneration.getStrawFillType(
                fruitTypeIndex))
        end
        if deliveryStation ~= nil then
            price = math.floor(price * TheContractorJobGeneration.HAULAGE_PRICE_MULTIPLIER)
        end
    end

    local settings = g_currentMission.TheContractor.Settings
    TCLog.info("TheContractor: priced %s on field %d at %.0f (%.2f/ha, job pay rate %d%% = %.2fx vanilla)",
        jobType, field:getId(), price, price / math.max(field:getAreaHa() or 1, 0.01), settings:get("jobPayRate"),
        settings:getJobPayMultiplier())

    local environment = g_currentMission.environment
    return g_currentMission.TheContractor.Jobs:createJob(farmId, jobType, field:getId(), requiredSkillLevel,
        environment:getPeriodFromDay(deadlineDay), environment:getDayInPeriodFromDay(deadlineDay), price,
        equipmentAvailable, fruitTypeName, deadlineDay, deliveryStation ~= nil, deliveryStation,
        TheContractorJobGeneration.getFieldStartState(field, jobDef), nil, nil, nil, nil, nil, readyDay)
end

-- 072: a job of this type on this field, offered now, for work something
-- else has caused (a random event's damage, a follow-on job) rather than
-- the hourly roll. The field's eligibility isn't checked - the caller knows
-- why it needs the work (vanilla's plow rules turn down standing grass,
-- say) - but it's dated, priced and flagged like any offer. No haulage.
-- sameMonth keeps the deadline in the current month (see getDeadlineDay).
-- itemCount prices a job paid per piece (075's rewardPerItem).
-- Returns the job, or nil if it can't be dated (getDeadlineDay).
function TheContractorJobGeneration:createJobOnField(farmId, jobType, field, sameMonth, itemCount)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
    if jobDef == nil or field == nil then
        return nil
    end
    local deadlineDay, readyDay = self:getDeadlineDay(field, jobDef, sameMonth)
    if deadlineDay == nil then
        return nil
    end

    local requiredSkillLevel = self:rollRequiredSkillLevel(farmId)
    local fruitTypeName = TheContractorJobGeneration.getRecordedFruitTypeName(field, jobDef)
    local equipmentAvailable = self:canFulfill(farmId, jobDef,
        TheContractorJobGeneration.getFruitTypeIndexByName(fruitTypeName))
    local price = self:estimatePrice(field, jobDef, farmId, requiredSkillLevel, nil, itemCount)

    local environment = g_currentMission.environment
    return g_currentMission.TheContractor.Jobs:createJob(farmId, jobType, field:getId(), requiredSkillLevel,
        environment:getPeriodFromDay(deadlineDay), environment:getDayInPeriodFromDay(deadlineDay), price,
        equipmentAvailable, fruitTypeName, deadlineDay, false, nil,
        TheContractorJobGeneration.getFieldStartState(field, jobDef), nil, nil, nil, nil, nil, readyDay)
end

-- The field state a job starts from (see JOB_TYPES' startState), or nil
-- for job types that don't record one.
function TheContractorJobGeneration.getFieldStartState(field, jobDef)
    if jobDef.startState == nil or field == nil then
        return nil
    end
    local fieldState = field:getFieldState()
    if fieldState == nil then
        return nil
    end
    return fieldState[jobDef.startState]
end

-- The crop currently on the field, by name (stable across saves and mod
-- load order, unlike the numeric index) — captured onto harvest jobs at
-- creation so "harvest what?" has an answer even after the field changes.
function TheContractorJobGeneration.getFieldFruitTypeName(field)
    local fieldState = field ~= nil and field:getFieldState() or nil
    if fieldState == nil or fieldState.fruitTypeIndex == FruitType.UNKNOWN then
        return nil
    end
    return g_fruitTypeManager:getFruitTypeNameByIndex(fieldState.fruitTypeIndex)
end

-- The crop the field's owner plans to sow next (vanilla's NPC plan, what
-- SowMission sows), by name, or nil if none. Server only: vanilla never
-- streams the plan.
function TheContractorJobGeneration.getFieldPlannedFruitTypeName(field)
    local plannedFruitTypeIndex = field ~= nil and field:getPlannedFruitTypeIndex() or nil
    if plannedFruitTypeIndex == nil or plannedFruitTypeIndex == FruitType.UNKNOWN then
        return nil
    end
    return g_fruitTypeManager:getFruitTypeNameByIndex(plannedFruitTypeIndex)
end

-- The crop a new job of this type records (fruitTypeName): the one on the
-- field for recordsCrop, the one to sow for recordsPlannedCrop.
function TheContractorJobGeneration.getRecordedFruitTypeName(field, jobDef)
    if jobDef.recordsCrop then
        return TheContractorJobGeneration.getFieldFruitTypeName(field)
    elseif jobDef.recordsPlannedCrop then
        return TheContractorJobGeneration.getFieldPlannedFruitTypeName(field)
    end
    return nil
end

-- The JOB_TYPE_KEYS entry matching `name`, case-insensitively (console
-- input), or nil.
function TheContractorJobGeneration.findJobType(name)
    if name == nil then
        return nil
    end
    for _, jobType in ipairs(TheContractorJobGeneration.JOB_TYPE_KEYS) do
        if jobType:lower() == name:lower() then
            return jobType
        end
    end
    return nil
end

-- 044: sowing is two skills - drilling (wheat, barley, canola, ...) is
-- seeding, row crops put in with a planter (maize, sunflower, beet,
-- potatoes, ...) are planting. Decided by the map's own fruit type category
-- for planters (PLANTER_FRUIT_TYPE_CATEGORY - what planters list in their
-- seedFruitTypeCategories, so mod crops come along for free), plus a
-- fallback list of crops vanilla plants with dedicated machines that may
-- sit outside that category (potatoes, sugarcane, poplar).
TheContractorJobGeneration.PLANTER_FRUIT_TYPE_CATEGORY = "PLANTER"
TheContractorJobGeneration.PLANTING_FRUIT_TYPE_NAMES = { "MAIZE", "SUNFLOWER", "SOYBEAN", "SUGARBEET", "POTATO",
    "SUGARCANE", "COTTON", "POPLAR" }

function TheContractorJobGeneration.isPlantingFruitType(fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex == FruitType.UNKNOWN then
        return false
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil then
        return false
    end
    for _, name in ipairs(TheContractorJobGeneration.PLANTING_FRUIT_TYPE_NAMES) do
        if fruitType.name == name then
            return true
        end
    end

    -- No warning argument, so a map without the category stays quiet.
    if g_fruitTypeManager.categories[TheContractorJobGeneration.PLANTER_FRUIT_TYPE_CATEGORY] ~= nil then
        for _, index in ipairs(g_fruitTypeManager:getFruitTypeIndicesByCategoryNames(
            TheContractorJobGeneration.PLANTER_FRUIT_TYPE_CATEGORY)) do
            if index == fruitTypeIndex then
                return true
            end
        end
    end
    return false
end

-- 044: the worker operation skill a job of this type on this field uses -
-- JOB_TYPES' skill, except that sow is planting when the field's planned
-- crop (what vanilla's SowMission sows) is a planted one. Worked out once,
-- at creation (TheContractorJobs:createJob), and kept on the job.
function TheContractorJobGeneration.getOperationSkill(jobType, fieldId)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
    if jobDef == nil then
        return nil
    end

    if jobDef.implementSpec == "spec_sowingMachine" then
        local field = fieldId ~= nil and g_fieldManager:getFieldById(fieldId) or nil
        if field ~= nil and TheContractorJobGeneration.isPlantingFruitType(field:getPlannedFruitTypeIndex()) then
            return "planting"
        end
    end
    return jobDef.skill
end

function TheContractorJobGeneration.getFruitTypeIndexByName(fruitTypeName)
    if fruitTypeName == nil then
        return nil
    end
    local fruitType = g_fruitTypeManager:getFruitTypeByName(fruitTypeName)
    return fruitType ~= nil and fruitType.index or nil
end

-- 067: FillType.STRAW if the crop leaves straw once cut, else nil - grass
-- (hay) never gets delivered, nor does anything else baled.
function TheContractorJobGeneration.getStrawFillType(fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex == FruitType.GRASS then
        return nil
    end
    if g_fruitTypeManager:getWindrowFillTypeIndexByFruitTypeIndex(fruitTypeIndex) ~= FillType.STRAW then
        return nil
    end
    return FillType.STRAW
end

-- Whether only the player can do the job: a job type the AI Helper can't
-- do at all (bale wrapping, delivering straw), or a bale job that includes
-- delivery (067) - the bales have to be loaded and carted, and a worker
-- can't bale while the player hauls (035 never mixes the two).
function TheContractorJobGeneration.isPlayerOnly(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef == nil then
        return false
    end
    return jobDef.playerOnly == true or (job.includesHaulage and jobDef.deliversBales == true)
end

-- The job types some field qualifies for right now (032), one option each:
--   candidates   the type's eligible fields (getCandidateFields)
--   fulfillable  the ones the farm owns the equipment for (033) - all or
--                none of them, except for harvest, where it's crop by crop
-- With fourteen types, most of which only fit a field at certain points in
-- its year (and weeding not at all on a save with weeds off), drawing from
-- every type would waste most rolls on types with nothing to offer and cut
-- the offer rate to a fraction of 026's tuning. onlyJobType limits it to
-- that one type (see tryGenerateJob).
function TheContractorJobGeneration:getJobTypeOptions(farmId, onlyJobType)
    local vehicles = TheContractorJobGeneration.getFarmVehicles(farmId)
    local options = {}
    for _, jobType in ipairs(TheContractorJobGeneration.JOB_TYPE_KEYS) do
        local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
        local candidates = (onlyJobType == nil or onlyJobType == jobType) and
            self:getCandidateFields(farmId, jobDef) or {}
        if #candidates > 0 then
            table.insert(options, {
                jobType = jobType,
                jobDef = jobDef,
                candidates = candidates,
                fulfillable = TheContractorJobGeneration.getFulfillableFields(vehicles, jobDef, candidates),
            })
        end
    end
    return options
end

-- Which of `fields` the farm's `vehicles` could do a job of this type on
-- (getMissingEquipment, ownership only). Only harvest's answer depends on
-- the field (its crop), so it's worked out once per crop, not per field.
function TheContractorJobGeneration.getFulfillableFields(vehicles, jobDef, fields)
    local result = {}
    local byFruitType = {}
    for _, field in ipairs(fields) do
        local fruitTypeIndex = jobDef.cropDependent and field:getFieldState().fruitTypeIndex or nil
        local key = fruitTypeIndex or 0
        if byFruitType[key] == nil then
            byFruitType[key] = #TCEquipmentClass.getMissingEquipment(vehicles, jobDef, fruitTypeIndex) == 0
        end
        if byFruitType[key] then
            table.insert(result, field)
        end
    end
    return result
end

-- Fleet-weighted (033): with preferFulfillable (rolled once per hit by
-- tryGenerateJob, FULFILLABLE_TYPE_SHARE of the time, so re-picks don't
-- dilute the share), evenly among the options with fulfillable fields left,
-- and only from those fields - so a wheat-only combine owner's fulfillable
-- harvest offer is wheat. Otherwise, or once nothing fulfillable is left,
-- evenly among every option, from all its fields. Returns the option and
-- the fields to pick from, or nil once no option has any fields left.
function TheContractorJobGeneration:pickJobType(options, preferFulfillable)
    local fulfillableOptions, anyOptions = {}, {}
    for _, option in ipairs(options) do
        if #option.candidates > 0 then
            table.insert(anyOptions, option)
        end
        if #option.fulfillable > 0 then
            table.insert(fulfillableOptions, option)
        end
    end

    if preferFulfillable and #fulfillableOptions > 0 then
        local option = fulfillableOptions[math.random(#fulfillableOptions)]
        return option, option.fulfillable
    end
    if #anyOptions == 0 then
        return nil
    end
    local option = anyOptions[math.random(#anyOptions)]
    return option, option.candidates
end

-- Drops a field with no workable deadline from an option (033), so the
-- next pick doesn't land on it again.
function TheContractorJobGeneration.removeCandidate(option, field)
    table.removeElement(option.candidates, field)
    table.removeElement(option.fulfillable, field)
end

-- Picks one of a job type's candidate fields (getCandidateFields), weighted
-- by size (026) and by the farm's relationship with the field's customer
-- (113, Relationships:getOfferWeight).
function TheContractorJobGeneration:pickField(farmId, candidates)
    if #candidates == 0 then
        return nil
    end

    -- Job size (026): fields over the farm's tier's size are rarer, not
    -- ruled out - see OVERSIZE_FIELD_WEIGHT.
    local tc = g_currentMission.TheContractor
    local maxPreferredHa = tc.Reputation:getReputationTier(farmId).maxPreferredFieldHa
    local weights, totalWeight = {}, 0
    for i, field in ipairs(candidates) do
        local weight = 1
        if maxPreferredHa ~= nil and (field:getAreaHa() or 0) > maxPreferredHa then
            weight = TheContractorJobGeneration.OVERSIZE_FIELD_WEIGHT
        end
        weight = weight * tc.Relationships:getOfferWeight(farmId, tc.Farmers:getCustomerIdForField(field:getId()))
        weights[i] = weight
        totalWeight = totalWeight + weight
    end

    local roll = math.random() * totalWeight
    for i, field in ipairs(candidates) do
        roll = roll - weights[i]
        if roll <= 0 then
            return field
        end
    end
    return candidates[#candidates]
end

-- See MAX_REQUIRED_SKILL_LEVEL_AT_START/MAX_REQUIRED_SKILL_LEVEL.
function TheContractorJobGeneration:rollRequiredSkillLevel(farmId)
    local standing = g_currentMission.TheContractor.Reputation:getStanding(farmId)
    local maxLevel = math.floor(TheContractorJobGeneration.MAX_REQUIRED_SKILL_LEVEL_AT_START + standing *
        (TheContractorJobGeneration.MAX_REQUIRED_SKILL_LEVEL - TheContractorJobGeneration.MAX_REQUIRED_SKILL_LEVEL_AT_START)
        + 0.5)
    local minLevel = math.max(TheContractorJobGeneration.MIN_REQUIRED_SKILL_LEVEL,
        maxLevel - TheContractorJobGeneration.REQUIRED_SKILL_SPREAD)
    return math.random(minLevel, maxLevel)
end

-- Candidates are fields the farm *doesn't* own — this is a contracting
-- business, the whole point is getting hired to work land that isn't
-- yours, not your own fields — that qualify for the job type right now
-- (isFieldEligible). That's deliberately not narrowed to "owned by some
-- other farm": vanilla's own field contract missions only ever target
-- unowned farmland (see Reference/FS25_Lua/missions/field/
-- AbstractFieldMission.lua's validate(), `not self.field:getHasOwner()`),
-- and in a typical save that's the *only* non-player-owned land that
-- exists — excluding it too (as an earlier version of this method did)
-- meant zero eligible fields and no jobs ever generated. Picked fresh each
-- roll against live field state, not cached, so it can't go stale between
-- rolls. A field with a live job on it (any farm's, offers included) is
-- left out: the job freezes vanilla's NPC fieldwork there (034), so the
-- field still qualifies for the same work and would otherwise be offered
-- again, a month later, as a second job on top of the first. 113: so is a
-- field whose customer has fallen out with the farm (Relationships:refuses).
function TheContractorJobGeneration:getCandidateFields(farmId, jobDef)
    local candidates = {}
    if jobDef.requiresWeeds and not TheContractorJobGeneration.getHasWeeds() then
        return candidates
    end
    if jobDef.requiresStones and g_currentMission.missionInfo.stonesEnabled == false then
        return candidates
    end
    -- 067: nowhere on the map takes straw bales, so nowhere to deliver to.
    if jobDef.deliveryOnly and TCHaulage.findBaleDeliveryStation(FillType.STRAW) == nil then
        return candidates
    end

    local tc = g_currentMission.TheContractor
    local jobs = tc.Jobs
    for _, field in ipairs(g_fieldManager:getFields()) do
        if field:getOwner() ~= farmId and not jobs:isFieldProtected(field:getId()) and
            TheContractorJobGeneration.isFieldEligible(field, jobDef) and
            not tc.Relationships:refuses(farmId, tc.Farmers:getCustomerIdForField(field:getId())) then
            table.insert(candidates, field)
        end
    end

    return candidates
end

-- Vanilla's weed missions only run with weeds switched on for the save and
-- present on the map (WeedMission.canRun and friends).
function TheContractorJobGeneration.getHasWeeds()
    local mission = g_currentMission
    return mission.missionInfo.weedsEnabled == true and mission.weedSystem ~= nil and
        mission.weedSystem:getMapHasWeed() == true
end

-- Harvest: any crop that isn't grass (that's mowing/baling work, 032) or a
-- catch crop (nothing to combine - vanilla's HarvestMission skips those
-- too). It doesn't have to be ready yet - a future-dated offer is fine,
-- see getDeadlineDay. Everything else: vanilla's own rules for the matching
-- mission type - narrowed to straw crops for a straw delivery (067), whose
-- bales lie where a bale job's would.
function TheContractorJobGeneration.isFieldEligible(field, jobDef)
    local fieldState = field:getFieldState()
    if fieldState == nil or not fieldState.isValid then
        return false
    end

    if jobDef.cropDependent then
        local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
        return fruitType ~= nil and not fruitType:getIsCatchCrop() and
            not TheContractorJobGeneration.isGrass(fruitType.index)
    end

    if jobDef.deliveryOnly and TheContractorJobGeneration.getStrawFillType(fieldState.fruitTypeIndex) == nil then
        return false
    end
    return TheContractorJobGeneration.isVanillaAvailable(field, jobDef)
end

-- Grass by vanilla's own definition: what its mow contracts cut (grass),
-- plus meadow.
function TheContractorJobGeneration.isGrass(fruitTypeIndex)
    if fruitTypeIndex == FruitType.MEADOW and FruitType.MEADOW ~= nil then
        return true
    end
    local mowData = TheContractorJobGeneration.getMowMissionData()
    return mowData ~= nil and mowData.fruitTypeIndices[fruitTypeIndex] == true
end

-- MowMission.isAvailableForField reads the mow fruit list its loadMapData
-- fills in - which never runs on a map with vanilla missions switched off
-- (map.missions#enabled). Filled in with loadMapData's own default then.
function TheContractorJobGeneration.getMowMissionData()
    local data = g_missionManager:getMissionTypeDataByName(MowMission.NAME)
    if data ~= nil and data.fruitTypeIndices == nil then
        data.fruitTypeIndices = {}
        if FruitType.GRASS ~= nil then
            data.fruitTypeIndices[FruitType.GRASS] = true
        end
    end
    return data
end

function TheContractorJobGeneration.isVanillaAvailable(field, jobDef)
    TheContractorJobGeneration.getMowMissionData()
    return jobDef.vanillaMission.isAvailableForField(field, nil) == true
end

-- The job's deadline as an absolute (monotonic) day — it's due by the end
-- of that day (024's miss check) — and, second, its ready day (132): the
-- first day work can start, which is when allocation's allowed. That's
-- today, or for a not-yet-ready harvest the crop's predicted ready date
-- (010).
--
--   earliest  today, or tomorrow if fewer than MIN_HOURS_LEFT_TODAY hours
--             remain; for a future harvest, its predicted ready day
--   desired   earliest + 0..MAX_EXTRA_DAYS random slack; with sameMonth
--             (072's urgent jobs) no later than the current month's last
--             day, unless earliest is already past it (too late on the
--             month's last day)
--   deadline  the last day from the start of the work window up to
--             `desired` on which the job is still doable, walking forward
--             and stopping at the first day it isn't (isDoableOnDay)
--
-- Returns nil if the job isn't doable through `earliest` — better no offer
-- than one that expires a few hours after it arrives. The ready day is the
-- start of the work window, not `earliest`: that's only the offer's
-- courtesy of a full day, not a limit on when work can begin.
function TheContractorJobGeneration:getDeadlineDay(field, jobDef, sameMonth)
    local environment = g_currentMission.environment
    local today = environment.currentMonotonicDay

    local workStartDay = today
    local earliest = today
    if 24 - environment.currentHour < TheContractorJobGeneration.MIN_HOURS_LEFT_TODAY then
        earliest = today + 1
    end

    if jobDef.cropDependent then
        local fieldState = field:getFieldState()
        local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
        if fruitType == nil or not fruitType:getIsHarvestReady(fieldState.growthState) then
            local prediction = TCCropPrediction.getEstimatedHarvestReadyDate(field)
            if prediction == nil then
                return nil
            end
            workStartDay = prediction.absoluteDay
            earliest = math.max(earliest, workStartDay)
        end
    end

    local desired = earliest + math.random(0, TheContractorJobGeneration.MAX_EXTRA_DAYS)
    if sameMonth then
        local monthEnd = today + environment.daysPerPeriod - environment:getDayInPeriodFromDay(today)
        desired = math.max(earliest, math.min(desired, monthEnd))
    end

    local lastDoable = nil
    for day = workStartDay, desired do
        if not self:isDoableOnDay(field, jobDef, day) then
            break
        end
        lastDoable = day
    end

    if lastDoable == nil or lastDoable < earliest then
        return nil
    end
    return lastDoable, workStartDay
end

-- Whether the job could still be carried out on a given absolute day, as
-- far as we can predict from here: harvest needs the crop harvest-ready
-- that day (010's growth walk — not withered or regrown past it); sow
-- needs the field's planned crop (vanilla's NPC plan, same thing
-- SowMission checks) still plantable in that day's period, when there is
-- one; everything else has vanilla's seasonal cut-off (seasonRule) applied
-- to that day's season/period. Plow/cultivate have no seasonal constraint.
function TheContractorJobGeneration:isDoableOnDay(field, jobDef, day)
    if jobDef.cropDependent then
        return TCCropPrediction.isHarvestReadyOnDay(field, day)
    end

    if jobDef.seasonRule ~= nil then
        local environment = g_currentMission.environment
        if environment:getSeasonAtDay(day) == Season.WINTER then
            return false
        end
        local period = environment:getPeriodFromDay(day)
        if jobDef.seasonRule == "noWinterOrEarlySpring" and
            (period == SeasonPeriod.EARLY_SPRING or period == SeasonPeriod.MID_SPRING) then
            return false
        end
    end

    if jobDef.implementSpec == "spec_sowingMachine" then
        local plannedFruitTypeIndex = field:getPlannedFruitTypeIndex()
        if plannedFruitTypeIndex ~= nil and plannedFruitTypeIndex ~= FruitType.UNKNOWN then
            local fruitType = g_fruitTypeManager:getFruitTypeByIndex(plannedFruitTypeIndex)
            if fruitType ~= nil then
                return fruitType:getIsPlantableInPeriod(g_currentMission.missionInfo.growthMode,
                    g_currentMission.environment:getPeriodFromDay(day))
            end
        end
    end

    return true
end

-- Base price follows vanilla's own AbstractFieldMission:getReward formula
-- (rewardPerHa * areaHa * (1.3 - 0.1 * economicDifficulty)), then layers in
-- reputation, required skill and a small random spread (see the pricing
-- constants above). A straw delivery (067) swaps rewardPerHa * areaHa for
-- getStrawDeliveryReward to its deliveryStation, and a job paid per piece
-- (075's rewardPerItem) rewardPerItem * itemCount.
function TheContractorJobGeneration:estimatePrice(field, jobDef, farmId, requiredSkillLevel, deliveryStation,
                                                  itemCount)
    local difficultyMultiplier = 1.3 - 0.1 * g_currentMission.missionInfo.economicDifficulty
    local reward
    if jobDef.rewardPerItem ~= nil then
        reward = jobDef.rewardPerItem * (itemCount or 0)
    elseif jobDef.deliveryOnly then
        reward = TheContractorJobGeneration.getStrawDeliveryReward(field, deliveryStation)
    else
        reward = TheContractorJobGeneration.getRewardPerHa(jobDef) * (field:getAreaHa() or 1)
    end
    local basePrice = reward * difficultyMultiplier

    local standing = g_currentMission.TheContractor.Reputation:getStanding(farmId)
    local reputationMultiplier = TheContractorJobGeneration.MIN_REPUTATION_PRICE_MULTIPLIER +
        standing * (TheContractorJobGeneration.MAX_REPUTATION_PRICE_MULTIPLIER -
            TheContractorJobGeneration.MIN_REPUTATION_PRICE_MULTIPLIER)

    local skillMultiplier = 1 + (requiredSkillLevel - 1) * TheContractorJobGeneration.SKILL_PRICE_PREMIUM

    local randomMultiplier = TheContractorJobGeneration.MIN_PRICE_VARIANCE +
        math.random() * (TheContractorJobGeneration.MAX_PRICE_VARIANCE - TheContractorJobGeneration.MIN_PRICE_VARIANCE)

    local payMultiplier = g_currentMission.TheContractor.Settings:getJobPayMultiplier()

    return math.floor(basePrice * reputationMultiplier * skillMultiplier * randomMultiplier * payMultiplier)
end

-- The job type's rewardPerHa, or for bale wrap (paid per bale in vanilla,
-- BaleWrapMission:getReward) vanilla's 1/ha base plus rewardPerBale times
-- the bales a hectare of grass makes (BaleWrapMission.tryGenerateMission's
-- own bale count) in BALE_WRAP_PRICING_BALE-sized bales.
function TheContractorJobGeneration.getRewardPerHa(jobDef)
    if jobDef.rewardPerBale == nil then
        return jobDef.rewardPerHa
    end

    local bale = TheContractorJobGeneration.BALE_WRAP_PRICING_BALE
    local grass = g_fruitTypeManager:getFruitTypeByIndex(FruitType.GRASS)
    local baleIndex = g_baleManager:getBaleIndex(FillType.GRASS_WINDROW, bale.isRoundbale, bale.width, 0, 0,
        bale.diameter)
    local capacity = baleIndex ~= nil and g_baleManager:getBaleCapacityByBaleIndex(baleIndex, FillType.GRASS_WINDROW)
        or nil
    if grass == nil or capacity == nil or capacity <= 0 then
        return jobDef.rewardPerBale
    end
    return 1 + jobDef.rewardPerBale * MathUtil.haToSqm(1) * grass.literPerSqm / capacity
end

-- How many straw bales the field's crop makes, in the bales a straw
-- delivery lays out (TCFieldPreparation.getStrawBaleIndex) - the same
-- whole-bales sum the spawn does. 0 if there's no such bale.
function TheContractorJobGeneration.estimateStrawBales(field)
    local fieldState = field:getFieldState()
    local fruitType = fieldState ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex) or nil
    local baleIndex = TCFieldPreparation.getStrawBaleIndex()
    local capacity = baleIndex ~= nil and g_baleManager:getBaleCapacityByBaleIndex(baleIndex, FillType.STRAW) or 0
    if fruitType == nil or capacity <= 0 then
        return 0
    end
    local liters = MathUtil.haToSqm(field:getAreaHa() or 0) * (fruitType.windrowLiterPerSqm or fruitType.literPerSqm)
    return math.floor(liters / capacity)
end

-- 067: TransportMission.calculateReward's shape - see the STRAW_DELIVERY_*
-- constants. Distance is field centre to the station.
function TheContractorJobGeneration.getStrawDeliveryReward(field, deliveryStation)
    local bales = TheContractorJobGeneration.estimateStrawBales(field)
    local distance = 0
    if deliveryStation ~= nil and deliveryStation.rootNode ~= nil then
        local fieldX, fieldZ = field:getCenterOfFieldWorldPosition()
        local stationX, _, stationZ = getWorldTranslation(deliveryStation.rootNode)
        distance = MathUtil.vector2Length(stationX - fieldX, stationZ - fieldZ)
    end
    local loads = math.ceil(bales / TheContractorJobGeneration.STRAW_DELIVERY_BALES_PER_LOAD)
    return bales * TheContractorJobGeneration.STRAW_DELIVERY_REWARD_PER_BALE +
        loads * distance * TheContractorJobGeneration.STRAW_DELIVERY_REWARD_PER_METER
end

-- Completion reputation per hectare (see JOB_TYPES' reputationPerHa).
function TheContractorJobGeneration.getReputationPerHa(jobDef)
    return jobDef.reputationPerHa or
        TheContractorJobGeneration.getRewardPerHa(jobDef) * TheContractorJobGeneration.REPUTATION_PER_REWARD
end

-- Flags (doesn't filter, per Q15) whether the farm currently owns
-- equipment able to fulfill a job of this type (and, for harvest, this
-- crop) — see TCEquipmentClass.getMissingEquipment. Ownership only, not
-- whether it's free right now: that's allocation's (018) concern.
function TheContractorJobGeneration:canFulfill(farmId, jobDef, fruitTypeIndex)
    return #TCEquipmentClass.getMissingEquipment(TheContractorJobGeneration.getFarmVehicles(farmId), jobDef,
        fruitTypeIndex) == 0
end

function TheContractorJobGeneration.getFarmVehicles(farmId)
    local result = {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        -- 100: not a customer's machine in a repair zone.
        if vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() == farmId and
                not (TheContractorRepairContracts ~= nil and TheContractorRepairContracts.isContractVehicle(vehicle)) then
            table.insert(result, vehicle)
        end
    end
    return result
end

-- 025 investigation aid (not a smoothing mechanism): a dry run of what
-- tryGenerateJob would see for each job type right now — how many fields
-- qualify (getCandidateFields), how many of those also resolve a workable
-- deadline (the rest — unpredictable or too-short harvest window, sow crop
-- out of season — are dropped and re-picked past, 033), and how many of
-- those the farm could fulfill (getFulfillableFields). A type is offered
-- only with a datable field; it's in pickJobType's fulfillable share only
-- with a fulfillable datable one. Drives the tcJob availability console
-- command.
function TheContractorJobGeneration:getAvailabilitySnapshot(farmId)
    local snapshot = {}
    local vehicles = TheContractorJobGeneration.getFarmVehicles(farmId)

    for _, jobType in ipairs(TheContractorJobGeneration.JOB_TYPE_KEYS) do
        local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
        local candidates = self:getCandidateFields(farmId, jobDef)

        local datableFields = {}
        for _, field in ipairs(candidates) do
            if self:getDeadlineDay(field, jobDef) ~= nil then
                table.insert(datableFields, field)
            end
        end

        table.insert(snapshot, {
            jobType = jobType,
            candidates = #candidates,
            datable = #datableFields,
            fulfillable = #TheContractorJobGeneration.getFulfillableFields(vehicles, jobDef, datableFields),
        })
    end

    return snapshot
end

-- Console commands (tcJob - see TCConsole) ---------------------------------------------

function TheContractorJobGeneration.registerConsoleCommands()
    -- Forces one generation hit for a single job type (tryGenerateJob's
    -- onlyJobType): a real offer on a real field, priced and dated by the
    -- same rules as the hourly roll, so it's safe for testing and for
    -- scripting a storyline. Jobs broadcasts the new job itself. Fails only
    -- when no field qualifies for the type right now, or none that does has
    -- a workable deadline.
    -- `repair`, `maintenance` and `parts` (100) go to RepairContracts
    -- instead: a customer's machine sent to a repair zone bay, with an
    -- optional severity.
    TCConsole.register("job", "offer", {
        args = "<jobType> [severity]",
        description = "Offer your farm a real job of that type now (no type lists the types; repair/maintenance/parts take a severity 1-3)",
        run = function(farmId, args)
            local tc = g_currentMission.TheContractor
            local typeList = table.concat(TheContractorJobGeneration.JOB_TYPE_KEYS, ", ")
                .. ", " .. table.concat(TheContractorRepairContracts.CONSOLE_OFFER_KINDS, ", ") .. " (ADS)"
            if args[1] == nil then
                return "Usage: tcJob offer <jobType> [severity]\nJob types: " .. typeList
            end
            local repairKind = TheContractorRepairContracts.findConsoleOfferKind(args[1])
            local jobType = TheContractorJobGeneration.findJobType(args[1])
            if jobType == nil and repairKind == nil then
                return string.format("Unknown job type '%s'. Job types: %s", args[1], typeList)
            end
            if not tc.Company:hasCompany(farmId) then
                return string.format("Error: farm %d has no company yet", farmId)
            end
            if repairKind ~= nil then
                return TheContractorRepairContracts.consoleOffer(farmId, repairKind, args[2])
            end

            local job = tc.JobGeneration:tryGenerateJob(farmId, jobType)
            if job ~= nil then
                return string.format("Offered %s job %d on field %d to farm %d (%s, due period %d day %d, skill %d%s)",
                    jobType, job.id, job.fieldId, farmId, g_i18n:formatMoney(job:getPrice(), 0, true, true),
                    job.targetPeriod, job.targetDayInPeriod, job.requiredSkillLevel,
                    job.equipmentAvailable and "" or ", farm lacks the equipment")
            end

            local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
            if jobDef.requiresWeeds and not TheContractorJobGeneration.getHasWeeds() then
                return string.format("No %s job possible: weeds are off for this save or map", jobType)
            end
            if jobDef.requiresStones and g_currentMission.missionInfo.stonesEnabled == false then
                return string.format("No %s job possible: stones are switched off for this save", jobType)
            end
            if jobDef.deliveryOnly and TCHaulage.findBaleDeliveryStation(FillType.STRAW) == nil then
                return string.format("No %s job possible: no selling point on this map takes straw bales", jobType)
            end
            local candidates = #tc.JobGeneration:getCandidateFields(farmId, jobDef)
            if candidates == 0 then
                return string.format("No %s job possible right now: no field the farm doesn't own qualifies for it",
                    jobType)
            end
            return string.format("No %s job possible right now: %d field(s) qualify, but none has a workable deadline (crop not ready/predictable in time, or out of season)",
                jobType, candidates)
        end,
    })

    -- 025 investigation aid: what the hourly generator could offer this farm
    -- right now, per job type. Read-only, but server-only because field
    -- state and generation both live there.
    TCConsole.register("job", "availability", {
        description = "Dry run: which job types have fields and dates available right now",
        run = function(farmId, args)
            local jobGeneration = g_currentMission.TheContractor.JobGeneration
            local environment = g_currentMission.environment
            local hourlyChance = jobGeneration:getHourlyChance(farmId)
            local rollsPerPeriod = 24 * environment.daysPerPeriod

            local snapshot = jobGeneration:getAvailabilitySnapshot(farmId)
            local datableTypes, fulfillableTypes = 0, 0
            for _, entry in ipairs(snapshot) do
                if entry.datable > 0 then
                    datableTypes = datableTypes + 1
                end
                if entry.fulfillable > 0 then
                    fulfillableTypes = fulfillableTypes + 1
                end
            end

            local hitsPerPeriod = hourlyChance * rollsPerPeriod
            local split
            if datableTypes == 0 then
                split = "no job type has a datable field - every hit is wasted"
            elseif fulfillableTypes == 0 then
                split = string.format("nothing fulfillable - split evenly across the %d types with datable fields",
                    datableTypes)
            else
                local share = TheContractorJobGeneration.FULFILLABLE_TYPE_SHARE
                split = string.format("%d%% evenly across the %d fulfillable types, %d%% across all %d types with datable fields; ~%.1f fulfillable offers per period",
                    math.floor(share * 100 + 0.5), fulfillableTypes, math.floor((1 - share) * 100 + 0.5), datableTypes,
                    hitsPerPeriod * (share + (1 - share) * fulfillableTypes / datableTypes))
            end

            local lines = {
                string.format("Farm %d, period %d day %d: hourly chance %.4f, ~%.1f generation hits per period (%s)",
                    farmId, environment.currentPeriod, environment.currentDayInPeriod, hourlyChance, hitsPerPeriod,
                    split),
            }
            for _, entry in ipairs(snapshot) do
                table.insert(lines, string.format("  %-13s eligible fields %3d, with target date %3d, fulfillable %3d",
                    entry.jobType, entry.candidates, entry.datable, entry.fulfillable))
            end
            return table.concat(lines, "\n")
        end,
    })
end
