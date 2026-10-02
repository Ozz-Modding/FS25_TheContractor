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
--                    standalone bale wrapper.
--   rewardPerHa      the pricing anchor, vanilla's own per-mission-type
--                    loadMapData default (plow 2800, cultivate 2300, sow
--                    2000, harvest 2500, mow 2500, tedder 1500, bale 2200,
--                    fertilize 1500, herbicide 1500, weed 2000, hoe 1500,
--                    stone pick 2200), so a job here reads as "the same job
--                    vanilla contracts would pay for". Bale wrap is paid per
--                    bale in vanilla (rewardPerBale 300), turned into a
--                    per-hectare figure by getRewardPerHa. estimatePrice
--                    layers reputation and skill on top (026).
-- reputationPerHa is the completion reputation reward per hectare (see
-- TheContractorJobs:calculateReputationReward): plow anchored at ~10 for a
-- 1.07 ha (2.65 acre) field, the rest scaled from it by the same ratios as
-- rewardPerHa (REPUTATION_PER_REWARD), since those already reflect how
-- slow/laborious each job is.
TheContractorJobGeneration.JOB_TYPES = {
    harvest = { cropDependent = true, recordsCrop = true, rewardPerHa = 2500, reputationPerHa = 8.5 },
    cultivate = { implementSpec = "spec_cultivator", vanillaMission = CultivateMission, rewardPerHa = 2300,
        reputationPerHa = 7.8 },
    sow = { implementSpec = "spec_sowingMachine", vanillaMission = SowMission, rewardPerHa = 2000,
        reputationPerHa = 6.8 },
    plow = { implementSpec = "spec_plow", vanillaMission = PlowMission, rewardPerHa = 2800, reputationPerHa = 9.5 },
    mow = { implementSpec = "spec_mower", vanillaMission = MowMission, recordsCrop = true,
        seasonRule = "noWinterOrEarlySpring", rewardPerHa = 2500, reputationPerHa = 8.5 },
    tedder = { implementSpec = "spec_tedder", vanillaMission = TedderMission, seasonRule = "noWinterOrEarlySpring",
        serverMeasured = true, rewardPerHa = 1500, reputationPerHa = 5.1 },
    bale = { implementSpec = "spec_baler", vanillaMission = BaleMission, recordsCrop = true, seasonRule = "noWinter",
        serverMeasured = true, rewardPerHa = 2200, reputationPerHa = 7.5 },
    baleWrap = { implementSpec = "spec_baleWrapper", vanillaMission = BaleWrapMission, seasonRule = "noWinter",
        serverMeasured = true, playerOnly = true, rewardPerBale = 300 },
    fertilize = { implementSpec = "spec_sprayer", vanillaMission = FertilizeMission, startState = "sprayLevel",
        supplyFillTypeNames = { "FERTILIZER", "LIQUIDFERTILIZER", "MANURE", "LIQUIDMANURE" }, seasonRule = "noWinter",
        rewardPerHa = 1500, reputationPerHa = 5.1 },
    herbicide = { implementSpec = "spec_sprayer", vanillaMission = HerbicideMission, startState = "weedState",
        supplyFillTypeNames = { "HERBICIDE" }, seasonRule = "noWinter", requiresWeeds = true, rewardPerHa = 1500,
        reputationPerHa = 5.1 },
    weed = { implementSpec = "spec_weeder", weederType = "weed", vanillaMission = WeedMission,
        startState = "weedState", seasonRule = "noWinter", requiresWeeds = true, serverMeasured = true,
        rewardPerHa = 2000, reputationPerHa = 6.8 },
    hoe = { implementSpec = "spec_weeder", weederType = "hoe", vanillaMission = HoeMission, startState = "weedState",
        seasonRule = "noWinter", requiresWeeds = true, serverMeasured = true, rewardPerHa = 1500,
        reputationPerHa = 5.1 },
    stonePick = { implementSpec = "spec_stonePicker", vanillaMission = StonePickMission, seasonRule = "noWinter",
        requiresStones = true, rewardPerHa = 2200, reputationPerHa = 7.5 },
}
TheContractorJobGeneration.JOB_TYPE_KEYS = { "harvest", "cultivate", "sow", "plow", "mow", "tedder", "bale",
    "baleWrap", "fertilize", "herbicide", "weed", "hoe", "stonePick" }

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

-- Harvest & haul (035): the share of harvest offers where the client wants
-- the crop carted to a selling point as well as the field combined - a
-- two-person job, worth more money and reputation than a plain harvest.
-- Only rolled when some selling point takes the crop at all. Reviewed in
-- 026 and kept: it needs a second worker and a tractor+trailer, and 1.5x
-- roughly pays for that second operator.
TheContractorJobGeneration.HAULAGE_CHANCE = 0.4
TheContractorJobGeneration.HAULAGE_PRICE_MULTIPLIER = 1.5
TheContractorJobGeneration.HAULAGE_REPUTATION_MULTIPLIER = 1.5

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
        self:tryGenerateJob(farmId)
    end
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
-- onlyJobType (the tcOfferJob console command) restricts the roll to that
-- one type and always prefers a field the farm can fulfill, falling back
-- to any of the type's fields - same rules otherwise, so a forced offer is
-- still one the generator could have made on its own.
function TheContractorJobGeneration:tryGenerateJob(farmId, onlyJobType)
    local options = self:getJobTypeOptions(farmId, onlyJobType)
    local preferFulfillable = onlyJobType ~= nil or
        math.random() < TheContractorJobGeneration.FULFILLABLE_TYPE_SHARE
    local field, deadlineDay, option
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
            deadlineDay = self:getDeadlineDay(field, option.jobDef)
            if deadlineDay == nil then
                TheContractorJobGeneration.removeCandidate(option, field)
            end
        end
    end

    local jobType, jobDef = option.jobType, option.jobDef
    local requiredSkillLevel = self:rollRequiredSkillLevel(farmId)
    local price = self:estimatePrice(field, jobDef, farmId, requiredSkillLevel)
    local fruitTypeName = jobDef.recordsCrop and TheContractorJobGeneration.getFieldFruitTypeName(field) or nil
    local fruitTypeIndex = TheContractorJobGeneration.getFruitTypeIndexByName(fruitTypeName)
    local equipmentAvailable = table.hasElement(option.fulfillable, field)

    local deliveryStation = nil
    if jobDef.cropDependent and fruitTypeIndex ~= nil and math.random() < TheContractorJobGeneration.HAULAGE_CHANCE then
        deliveryStation = TCHaulage.findDeliveryStation(g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(
            fruitTypeIndex))
        if deliveryStation ~= nil then
            price = math.floor(price * TheContractorJobGeneration.HAULAGE_PRICE_MULTIPLIER)
        end
    end

    local environment = g_currentMission.environment
    return g_currentMission.TheContractor.Jobs:createJob(farmId, jobType, field:getId(), requiredSkillLevel,
        environment:getPeriodFromDay(deadlineDay), environment:getDayInPeriodFromDay(deadlineDay), price,
        equipmentAvailable, fruitTypeName, deadlineDay, deliveryStation ~= nil, deliveryStation,
        TheContractorJobGeneration.getFieldStartState(field, jobDef))
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

function TheContractorJobGeneration.getFruitTypeIndexByName(fruitTypeName)
    if fruitTypeName == nil then
        return nil
    end
    local fruitType = g_fruitTypeManager:getFruitTypeByName(fruitTypeName)
    return fruitType ~= nil and fruitType.index or nil
end

-- The job types some field qualifies for right now (032), one option each:
--   candidates   the type's eligible fields (getCandidateFields)
--   fulfillable  the ones the farm owns the equipment for (033) - all or
--                none of them, except for harvest, where it's crop by crop
-- With thirteen types, most of which only fit a field at certain points in
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
-- by size (026).
function TheContractorJobGeneration:pickField(farmId, candidates)
    if #candidates == 0 then
        return nil
    end

    -- Job size (026): fields over the farm's tier's size are rarer, not
    -- ruled out - see OVERSIZE_FIELD_WEIGHT.
    local maxPreferredHa = g_currentMission.TheContractor.Reputation:getReputationTier(farmId).maxPreferredFieldHa
    local weights, totalWeight = {}, 0
    for i, field in ipairs(candidates) do
        local weight = 1
        if maxPreferredHa ~= nil and (field:getAreaHa() or 0) > maxPreferredHa then
            weight = TheContractorJobGeneration.OVERSIZE_FIELD_WEIGHT
        end
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
-- rolls.
function TheContractorJobGeneration:getCandidateFields(farmId, jobDef)
    local candidates = {}
    if jobDef.requiresWeeds and not TheContractorJobGeneration.getHasWeeds() then
        return candidates
    end
    if jobDef.requiresStones and g_currentMission.missionInfo.stonesEnabled == false then
        return candidates
    end

    for _, field in ipairs(g_fieldManager:getFields()) do
        if field:getOwner() ~= farmId and TheContractorJobGeneration.isFieldEligible(field, jobDef) then
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
-- mission type.
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

-- Vanilla mission code isn't written to be called from outside its own
-- generation loop, so an error in it (an odd map, another mod) costs that
-- field its eligibility rather than breaking the hourly tick.
local loggedVanillaErrors = {}

function TheContractorJobGeneration.isVanillaAvailable(field, jobDef)
    TheContractorJobGeneration.getMowMissionData()
    local ok, result = pcall(jobDef.vanillaMission.isAvailableForField, field, nil)
    if not ok then
        if not loggedVanillaErrors[jobDef.vanillaMission] then
            loggedVanillaErrors[jobDef.vanillaMission] = true
            Logging.warning("TheContractor: vanilla eligibility check failed for field %s: %s",
                tostring(field:getId()), tostring(result))
        end
        return false
    end
    return result == true
end

-- The job's deadline as an absolute (monotonic) day — it's due by the end
-- of that day (024's miss check). Work can start as soon as the job's
-- accepted and allocated, or for a not-yet-ready harvest once the crop's
-- predicted ready date (010) arrives.
--
--   earliest  today, or tomorrow if fewer than MIN_HOURS_LEFT_TODAY hours
--             remain; for a future harvest, its predicted ready day
--   desired   earliest + 0..MAX_EXTRA_DAYS random slack
--   deadline  the last day from the start of the work window up to
--             `desired` on which the job is still doable, walking forward
--             and stopping at the first day it isn't (isDoableOnDay)
--
-- Returns nil if the job isn't doable through `earliest` — better no offer
-- than one that expires a few hours after it arrives.
function TheContractorJobGeneration:getDeadlineDay(field, jobDef)
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
    return lastDoable
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
-- constants above).
function TheContractorJobGeneration:estimatePrice(field, jobDef, farmId, requiredSkillLevel)
    local areaHa = field:getAreaHa() or 1
    local difficultyMultiplier = 1.3 - 0.1 * g_currentMission.missionInfo.economicDifficulty
    local basePrice = TheContractorJobGeneration.getRewardPerHa(jobDef) * areaHa * difficultyMultiplier

    local standing = g_currentMission.TheContractor.Reputation:getStanding(farmId)
    local reputationMultiplier = TheContractorJobGeneration.MIN_REPUTATION_PRICE_MULTIPLIER +
        standing * (TheContractorJobGeneration.MAX_REPUTATION_PRICE_MULTIPLIER -
            TheContractorJobGeneration.MIN_REPUTATION_PRICE_MULTIPLIER)

    local skillMultiplier = 1 + (requiredSkillLevel - 1) * TheContractorJobGeneration.SKILL_PRICE_PREMIUM

    local randomMultiplier = TheContractorJobGeneration.MIN_PRICE_VARIANCE +
        math.random() * (TheContractorJobGeneration.MAX_PRICE_VARIANCE - TheContractorJobGeneration.MIN_PRICE_VARIANCE)

    return math.floor(basePrice * reputationMultiplier * skillMultiplier * randomMultiplier)
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
        if vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() == farmId then
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
-- with a fulfillable datable one. Drives the tcJobAvailability console
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
