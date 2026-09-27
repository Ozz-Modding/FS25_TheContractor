-- Job generation engine (011): the hourly-tick system that actually
-- creates new Job offers (008), matched to the player's owned equipment
-- (009's TCEquipmentClass) and, where relevant, a predicted future-ready
-- crop (010's TCCropPrediction). Reputation-driven, with 012's advertising
-- state layered in as an additive chance bonus — the exact frequency/size
-- formula (how much either input should actually matter) is a 026
-- balance-pass concern (Q9/Q15 in the ticket only require the generation
-- *mechanism* to be correct: the hourly hook, equipment tagging, and
-- target-date attachment).
--
-- No state of its own to persist — every job it creates goes straight
-- through TheContractorJobs:createJob, which already owns the
-- server-authoritative apply+broadcast (005). So unlike Reputation/Jobs/
-- Staff/Company this isn't added to TCInitialClientStateEvent; there's
-- nothing here a joining client would need replayed to it.

TheContractorJobGeneration = {}
TheContractorJobGeneration_mt = Class(TheContractorJobGeneration)

-- One entry per generatable job type: the vehicle specialization an
-- implement must carry to do the work (implementSpec — harvest has none,
-- its crop-specific header/harvester matching lives in TCEquipmentClass.
-- getMissingEquipment), whether it also needs *some* tractor to pull it
-- (harvest works it out per harvester instead: only a trailed one needs
-- one), whether the
-- target field must currently carry an active crop (harvest) or must not
-- (cultivate/sow/plow can't sensibly target a field mid-crop), and a
-- rewardPerHa pricing anchor. rewardPerHa values are lifted directly from
-- the vanilla contract system's own per-mission-type defaults (see
-- Reference/FS25_Lua/missions/field/*Mission.lua's loadMapData rewardPerHa
-- fallbacks: plow 2800, cultivate 2300, sow 2000, harvest 2500) rather than
-- invented from scratch, so a job here reads as "the same job vanilla
-- contracts would pay for" instead of pocket change. Equipment/skill
-- balancing beyond that anchor is still a later tuning concern (026).
-- reputationPerHa is the completion reputation reward per hectare (see
-- TheContractorJobs:calculateReputationReward): plow anchored at ~10 for a
-- 1.07 ha (2.65 acre) field, the rest scaled from it by the same ratios as
-- rewardPerHa, since those already reflect how slow/laborious each job is.
TheContractorJobGeneration.JOB_TYPES = {
    harvest = { requiresTractor = false, cropDependent = true, rewardPerHa = 2500, reputationPerHa = 8.5 },
    cultivate = { implementSpec = "spec_cultivator", requiresTractor = true, cropDependent = false, rewardPerHa = 2300,
        reputationPerHa = 7.8 },
    sow = { implementSpec = "spec_sowingMachine", requiresTractor = true, cropDependent = false, rewardPerHa = 2000,
        reputationPerHa = 6.8 },
    plow = { implementSpec = "spec_plow", requiresTractor = true, cropDependent = false, rewardPerHa = 2800,
        reputationPerHa = 9.5 },
}
TheContractorJobGeneration.JOB_TYPE_KEYS = { "harvest", "cultivate", "sow", "plow" }

-- Placeholder odds — no formula locked yet (ticket's own design decision),
-- just needs to be reputation-driven and land somewhere sane-looking in the
-- meantime. 026 owns the real balance pass.
TheContractorJobGeneration.BASE_HOURLY_CHANCE = 0.05
TheContractorJobGeneration.REPUTATION_CHANCE_BONUS_PER_POINT = 0.0002
TheContractorJobGeneration.MAX_HOURLY_CHANCE = 0.35

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

-- Pricing: rewardPerHa (above) scaled by the same economicDifficulty curve
-- vanilla's AbstractFieldMission:getReward uses, then scaled again by
-- reputation (a brand new, no-reputation company gets lowballed, a
-- top-tier one gets a premium — see reputationMultiplier below) and a
-- small random spread so offers don't all land on the exact same number
-- for a given field size. 026 owns the real balance pass.
--
-- Reputation scaling is linear from MIN at score 0 up to MAX at
-- REPUTATION_PRICE_CAP_SCORE (TheContractorReputation.TIERS' top tier,
-- prestigiousContractor) and flat thereafter — reaching the top tier is
-- meant to be a long-haul grind (see Reputation.lua), so this deliberately
-- doesn't cap out early.
TheContractorJobGeneration.MIN_REPUTATION_PRICE_MULTIPLIER = 0.75
TheContractorJobGeneration.MAX_REPUTATION_PRICE_MULTIPLIER = 1.25
TheContractorJobGeneration.REPUTATION_PRICE_CAP_SCORE = 5000
TheContractorJobGeneration.MIN_PRICE_VARIANCE = 0.85
TheContractorJobGeneration.MAX_PRICE_VARIANCE = 1.15

-- Harvest & haul (035): the share of harvest offers where the client wants
-- the crop carted to a selling point as well as the field combined - a
-- two-person job, worth more money and reputation than a plain harvest.
-- Only rolled when some selling point takes the crop at all. Placeholder
-- numbers, 026 owns the balance pass.
TheContractorJobGeneration.HAULAGE_CHANCE = 0.4
TheContractorJobGeneration.HAULAGE_PRICE_MULTIPLIER = 1.5
TheContractorJobGeneration.HAULAGE_REPUTATION_MULTIPLIER = 1.5

TheContractorJobGeneration.MIN_REQUIRED_SKILL_LEVEL = 1
TheContractorJobGeneration.MAX_REQUIRED_SKILL_LEVEL = 5

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
    local reputationScore = g_currentMission.TheContractor.Reputation:getReputationScore(farmId)
    local advertisingBonus = g_currentMission.TheContractor.Advertising:getChanceBonus(farmId)
    local daysPerPeriod = g_currentMission.environment.daysPerPeriod

    -- The roll is per hour, but a save's daysPerPeriod setting (how many
    -- real hours a full period/"month" spans) directly multiplies how many
    -- rolls happen per month for the exact same per-hour chance — a 1-day
    -- month gets 24 rolls, a 5-day month gets 120. Dividing by daysPerPeriod
    -- keeps the *expected number of jobs per month* roughly constant across
    -- that setting instead of scaling up with it.
    return math.min(TheContractorJobGeneration.MAX_HOURLY_CHANCE,
        (TheContractorJobGeneration.BASE_HOURLY_CHANCE +
            reputationScore * TheContractorJobGeneration.REPUTATION_CHANCE_BONUS_PER_POINT +
            advertisingBonus) / daysPerPeriod)
end

-- Picks a job type + eligible field, works out its deadline (see
-- getDeadlineDay), tags it with current equipment fulfillment, and creates
-- it. Returns nil (generates nothing) if no eligible field or no workable
-- deadline exists this roll — generation just skips a beat rather than
-- forcing a bad offer out.
function TheContractorJobGeneration:tryGenerateJob(farmId)
    local jobType, jobDef = self:pickJobType()

    local field = self:pickField(farmId, jobDef)
    if field == nil then
        return nil
    end

    local deadlineDay = self:getDeadlineDay(field, jobDef)
    if deadlineDay == nil then
        return nil
    end

    local requiredSkillLevel = math.random(TheContractorJobGeneration.MIN_REQUIRED_SKILL_LEVEL,
        TheContractorJobGeneration.MAX_REQUIRED_SKILL_LEVEL)
    local price = self:estimatePrice(field, jobDef, farmId)
    local fruitTypeName = jobDef.cropDependent and TheContractorJobGeneration.getFieldFruitTypeName(field) or nil
    local fruitTypeIndex = TheContractorJobGeneration.getFruitTypeIndexByName(fruitTypeName)
    local equipmentAvailable = self:canFulfill(farmId, jobDef, fruitTypeIndex)

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
        equipmentAvailable, fruitTypeName, deadlineDay, deliveryStation ~= nil, deliveryStation)
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

function TheContractorJobGeneration.getFruitTypeIndexByName(fruitTypeName)
    if fruitTypeName == nil then
        return nil
    end
    local fruitType = g_fruitTypeManager:getFruitTypeByName(fruitTypeName)
    return fruitType ~= nil and fruitType.index or nil
end

function TheContractorJobGeneration:pickJobType()
    local jobType = TheContractorJobGeneration.JOB_TYPE_KEYS[math.random(#TheContractorJobGeneration.JOB_TYPE_KEYS)]
    return jobType, TheContractorJobGeneration.JOB_TYPES[jobType]
end

-- Candidates are fields the farm *doesn't* own — this is a contracting
-- business, the whole point is getting hired to work land that isn't
-- yours, not your own fields — whose current crop state matches what the
-- job type needs (harvest wants an active crop, everything else wants a
-- clear field). That's deliberately not narrowed to "owned by some other
-- farm": vanilla's own field contract missions only ever target unowned
-- farmland (see Reference/FS25_Lua/missions/field/AbstractFieldMission.lua's
-- validate(), `not self.field:getHasOwner()`), and in a typical save that's
-- the *only* non-player-owned land that exists — excluding it too (as an
-- earlier version of this method did) meant zero eligible fields and no
-- jobs ever generated. Picked fresh each roll against live field state, not
-- cached, so it can't go stale between rolls.
function TheContractorJobGeneration:pickField(farmId, jobDef)
    local candidates = self:getCandidateFields(farmId, jobDef)
    if #candidates == 0 then
        return nil
    end

    return candidates[math.random(#candidates)]
end

function TheContractorJobGeneration:getCandidateFields(farmId, jobDef)
    local candidates = {}

    for _, field in ipairs(g_fieldManager:getFields()) do
        if field:getOwner() ~= farmId then
            local fieldState = field:getFieldState()
            local hasCrop = fieldState ~= nil and fieldState.fruitTypeIndex ~= FruitType.UNKNOWN
            if hasCrop == jobDef.cropDependent then
                table.insert(candidates, field)
            end
        end
    end

    return candidates
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
-- one. Plow/cultivate have no seasonal constraint.
function TheContractorJobGeneration:isDoableOnDay(field, jobDef, day)
    if jobDef.cropDependent then
        return TCCropPrediction.isHarvestReadyOnDay(field, day)
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
-- a reputation-driven bonus (higher standing commands better rates, capped)
-- and a small random spread. Equipment weighting is still 026's concern.
function TheContractorJobGeneration:estimatePrice(field, jobDef, farmId)
    local areaHa = field:getAreaHa() or 1
    local difficultyMultiplier = 1.3 - 0.1 * g_currentMission.missionInfo.economicDifficulty
    local basePrice = jobDef.rewardPerHa * areaHa * difficultyMultiplier

    local reputationScore = g_currentMission.TheContractor.Reputation:getReputationScore(farmId)
    local reputationRatio = math.min(reputationScore / TheContractorJobGeneration.REPUTATION_PRICE_CAP_SCORE, 1)
    local reputationMultiplier = TheContractorJobGeneration.MIN_REPUTATION_PRICE_MULTIPLIER +
        reputationRatio * (TheContractorJobGeneration.MAX_REPUTATION_PRICE_MULTIPLIER -
            TheContractorJobGeneration.MIN_REPUTATION_PRICE_MULTIPLIER)

    local randomMultiplier = TheContractorJobGeneration.MIN_PRICE_VARIANCE +
        math.random() * (TheContractorJobGeneration.MAX_PRICE_VARIANCE - TheContractorJobGeneration.MIN_PRICE_VARIANCE)

    return math.floor(basePrice * reputationMultiplier * randomMultiplier)
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
-- pass pickField's crop-state filter, how many of those also resolve a
-- workable deadline (a roll that lands on a field with none — unpredictable
-- or too-short harvest window, sow crop out of season — is silently skipped), and whether the farm could fulfill it.
-- Drives the tcJobAvailability console command.
function TheContractorJobGeneration:getAvailabilitySnapshot(farmId)
    local snapshot = {}

    for _, jobType in ipairs(TheContractorJobGeneration.JOB_TYPE_KEYS) do
        local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
        local candidates = self:getCandidateFields(farmId, jobDef)

        local datable = 0
        for _, field in ipairs(candidates) do
            if self:getDeadlineDay(field, jobDef) ~= nil then
                datable = datable + 1
            end
        end

        table.insert(snapshot, {
            jobType = jobType,
            candidates = #candidates,
            datable = datable,
            canFulfill = self:canFulfill(farmId, jobDef),
        })
    end

    return snapshot
end
