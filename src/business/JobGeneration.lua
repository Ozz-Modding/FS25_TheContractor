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

-- One entry per generatable job type: the store category
-- (TCEquipmentClass.getCategory()) the farm must own at least one of for
-- the job to be flagged as fulfillable, whether it also needs *some*
-- tractor to pull it (self-propelled combines don't), whether the
-- target field must currently carry an active crop (harvest) or must not
-- (cultivate/sow/plow can't sensibly target a field mid-crop), and a
-- rewardPerHa pricing anchor. rewardPerHa values are lifted directly from
-- the vanilla contract system's own per-mission-type defaults (see
-- Reference/FS25_Lua/missions/field/*Mission.lua's loadMapData rewardPerHa
-- fallbacks: plow 2800, cultivate 2300, sow 2000, harvest 2500) rather than
-- invented from scratch, so a job here reads as "the same job vanilla
-- contracts would pay for" instead of pocket change. Equipment/skill
-- balancing beyond that anchor is still a later tuning concern (026).
TheContractorJobGeneration.JOB_TYPES = {
    harvest = { requiredCategory = "COMBINES", requiresTractor = false, cropDependent = true, rewardPerHa = 2500 },
    cultivate = { requiredCategory = "CULTIVATORS", requiresTractor = true, cropDependent = false, rewardPerHa = 2300 },
    sow = { requiredCategory = "SEEDERS", requiresTractor = true, cropDependent = false, rewardPerHa = 2000 },
    plow = { requiredCategory = "PLOWS", requiresTractor = true, cropDependent = false, rewardPerHa = 2800 },
}
TheContractorJobGeneration.JOB_TYPE_KEYS = { "harvest", "cultivate", "sow", "plow" }

-- Placeholder odds — no formula locked yet (ticket's own design decision),
-- just needs to be reputation-driven and land somewhere sane-looking in the
-- meantime. 026 owns the real balance pass.
TheContractorJobGeneration.BASE_HOURLY_CHANCE = 0.05
TheContractorJobGeneration.REPUTATION_CHANCE_BONUS_PER_POINT = 0.0002
TheContractorJobGeneration.MAX_HOURLY_CHANCE = 0.35

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

function TheContractorJobGeneration:onHourChanged()
    for _, farm in ipairs(g_farmManager:getFarms()) do
        local farmId = farm.farmId
        if g_currentMission.TheContractor.Company:hasCompany(farmId) then
            self:rollForFarm(farmId)
        end
    end
end

function TheContractorJobGeneration:rollForFarm(farmId)
    local reputationScore = g_currentMission.TheContractor.Reputation:getReputationScore(farmId)
    local advertisingBonus = g_currentMission.TheContractor.Advertising:getChanceBonus(farmId)

    -- The roll is per hour, but a save's daysPerPeriod setting (how many
    -- real hours a full period/"month" spans) directly multiplies how many
    -- rolls happen per month for the exact same per-hour chance — a 1-day
    -- month gets 24 rolls, a 5-day month gets 120. Dividing by daysPerPeriod
    -- keeps the *expected number of jobs per month* roughly constant across
    -- that setting instead of scaling up with it.
    local daysPerPeriod = g_currentMission.environment.daysPerPeriod
    local chance = math.min(TheContractorJobGeneration.MAX_HOURLY_CHANCE,
        (TheContractorJobGeneration.BASE_HOURLY_CHANCE +
            reputationScore * TheContractorJobGeneration.REPUTATION_CHANCE_BONUS_PER_POINT +
            advertisingBonus) / daysPerPeriod)

    if math.random() <= chance then
        self:tryGenerateJob(farmId)
    end
end

-- Picks a job type + eligible field, works out its target date (crop
-- prediction for harvest jobs, near-term otherwise), tags it with current
-- equipment fulfillment, and creates it. Returns nil (generates nothing)
-- if no eligible field or no predictable target date exists this roll —
-- generation just skips a beat rather than forcing a bad offer out.
function TheContractorJobGeneration:tryGenerateJob(farmId)
    local jobType, jobDef = self:pickJobType()

    local field = self:pickField(farmId, jobDef)
    if field == nil then
        return nil
    end

    local targetPeriod, targetDayInPeriod = self:getTargetDate(field, jobDef)
    if targetPeriod == nil then
        return nil
    end

    local requiredSkillLevel = math.random(TheContractorJobGeneration.MIN_REQUIRED_SKILL_LEVEL,
        TheContractorJobGeneration.MAX_REQUIRED_SKILL_LEVEL)
    local price = self:estimatePrice(field, jobDef, farmId)
    local equipmentAvailable = self:canFulfill(farmId, jobDef)

    return g_currentMission.TheContractor.Jobs:createJob(farmId, jobType, field:getId(), requiredSkillLevel,
        targetPeriod, targetDayInPeriod, price, equipmentAvailable)
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

    if #candidates == 0 then
        return nil
    end

    return candidates[math.random(#candidates)]
end

-- Non-crop-dependent jobs default to "as soon as accepted+allocated" — the
-- current in-game day, since there's no dependency forcing a later date.
-- Crop-dependent (harvest) jobs use the live ready check if the field is
-- already harvestable right now, otherwise fall back to 010's prediction;
-- if even that can't produce a date, the caller skips this roll rather
-- than generating a job with no meaningful target.
function TheContractorJobGeneration:getTargetDate(field, jobDef)
    local environment = g_currentMission.environment

    if not jobDef.cropDependent then
        return environment.currentPeriod, environment.currentDayInPeriod
    end

    local fieldState = field:getFieldState()
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
    if fruitType ~= nil and fruitType:getIsHarvestReady(fieldState.growthState) then
        return environment.currentPeriod, environment.currentDayInPeriod
    end

    local prediction = TCCropPrediction.getEstimatedHarvestReadyDate(field)
    if prediction == nil then
        return nil
    end

    return prediction.period, prediction.dayInPeriod
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
-- equipment able to fulfill a job of this type: at least one vehicle in
-- the required store category, plus a tractor of any size tier if the job
-- needs one to pull it.
function TheContractorJobGeneration:canFulfill(farmId, jobDef)
    local hasRequiredCategory = false
    local hasTractor = not jobDef.requiresTractor

    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() == farmId then
            if TCEquipmentClass.getCategory(vehicle) == jobDef.requiredCategory then
                hasRequiredCategory = true
            end

            if jobDef.requiresTractor and TCEquipmentClass.getSizeTier(vehicle) ~= nil then
                hasTractor = true
            end
        end
    end

    return hasRequiredCategory and hasTractor
end
