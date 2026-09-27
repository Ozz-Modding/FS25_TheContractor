-- Crop maturity prediction (010). Pure calculation, no farm-scoped state of
-- its own, so it lives here as a stateless util rather than under
-- src/business/ — nothing to persist, nothing to broadcast.
--
-- The base game only ever checks *current* growth state
-- (FruitTypeDesc:getIsHarvestReady(field:getFieldState().growthState)) —
-- there's no vanilla API for "when will this field be ready." Growth under
-- seasonal rules advances once per MessageType.PERIOD_CHANGED, deterministically,
-- via each fruit's per-period growthMapping table (growth/GrowthSystem.lua
-- setMonthEngineState: the period that just ended applies its own
-- growthMapping right as the new period begins) — so walking that table
-- forward from the field's live growth state is a legitimate estimate. But
-- it is only an estimate: player action (mowing, destruction, weeds) or a
-- mid-game daysPerPeriod change between now and the target date can
-- invalidate it. Callers (011) must re-validate against live field state at
-- job generation time, and again at allocation time, not just cache this
-- result.

TCCropPrediction = {}

-- Safety cap on the forward walk. If a crop doesn't reach a harvest-ready
-- state within two in-game years of periods, treat it as unpredictable
-- rather than looping (e.g. a fruit type with a growthMapping that never
-- reaches its harvest-ready range from the current state).
TCCropPrediction.MAX_PERIODS_TO_WALK = 24

-- Returns { period, dayInPeriod, absoluteDay } estimating when `field`'s
-- current crop will become harvest ready, or nil if that can't be
-- predicted: no active crop, already harvest ready now, growth isn't
-- running under seasonal rules (GrowthMode.DAILY/DISABLED have no
-- per-period mapping table to walk), or the walk hits
-- MAX_PERIODS_TO_WALK without reaching a harvest-ready state.
function TCCropPrediction.getEstimatedHarvestReadyDate(field)
    if field == nil then
        return nil
    end

    if g_currentMission.missionInfo.growthMode ~= GrowthMode.SEASONAL then
        return nil
    end

    local fieldState = field:getFieldState()
    if fieldState == nil or fieldState.fruitTypeIndex == FruitType.UNKNOWN then
        return nil
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
    if fruitType == nil then
        return nil
    end

    local growthData = fruitType:getSeasonalGrowthData()
    if growthData == nil then
        return nil
    end

    if fruitType:getIsHarvestReady(fieldState.growthState) then
        return nil
    end

    local environment = g_currentMission.environment
    local daysUntilPeriodBoundary = environment.daysPerPeriod - environment.currentDayInPeriod + 1

    local walkPeriod = environment.currentPeriod
    local state = fieldState.growthState

    for periodsWalked = 1, TCCropPrediction.MAX_PERIODS_TO_WALK do
        local periodInfo = growthData.periods[walkPeriod]
        if periodInfo == nil or periodInfo.growthMapping == nil then
            return nil
        end

        local nextState = periodInfo.growthMapping[state]
        if nextState == nil then
            return nil
        end

        state = nextState
        walkPeriod = walkPeriod % Environment.PERIODS_IN_YEAR + 1

        if fruitType:getIsHarvestReady(state) then
            local daysFromNow = daysUntilPeriodBoundary + (periodsWalked - 1) * environment.daysPerPeriod
            local absoluteDay = environment.currentMonotonicDay + daysFromNow

            return {
                period = environment:getPeriodFromDay(absoluteDay),
                dayInPeriod = environment:getDayInPeriodFromDay(absoluteDay),
                absoluteDay = absoluteDay,
            }
        end
    end

    return nil
end

-- Whether the field's current crop will be harvest-ready on a given
-- absolute (monotonic) day — used to check a job's deadline doesn't land
-- after its crop has moved on (withered, or regrown past ready). Same
-- growth-mapping walk as getEstimatedHarvestReadyDate, stepped day by day
-- so period boundaries land exactly where the base game applies them (on
-- the first day of each new period, using the mapping of the period that
-- just ended). Conservative: anything it can't predict comes back false.
function TCCropPrediction.isHarvestReadyOnDay(field, absoluteDay)
    local fieldState = field ~= nil and field:getFieldState() or nil
    if fieldState == nil or fieldState.fruitTypeIndex == FruitType.UNKNOWN then
        return false
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
    if fruitType == nil then
        return false
    end

    local environment = g_currentMission.environment
    local today = environment.currentMonotonicDay
    local state = fieldState.growthState

    if absoluteDay <= today then
        return fruitType:getIsHarvestReady(state)
    end

    local growthMode = g_currentMission.missionInfo.growthMode
    if growthMode == GrowthMode.DISABLED then
        return fruitType:getIsHarvestReady(state)
    elseif growthMode ~= GrowthMode.SEASONAL then
        return false
    end

    local growthData = fruitType:getSeasonalGrowthData()
    if growthData == nil then
        return false
    end

    for day = today + 1, absoluteDay do
        if environment:getDayInPeriodFromDay(day) == 1 then
            local periodInfo = growthData.periods[environment:getPeriodFromDay(day - 1)]
            local nextState = periodInfo ~= nil and periodInfo.growthMapping ~= nil and periodInfo.growthMapping[state] or nil
            if nextState == nil then
                return false
            end
            state = nextState
        end
    end

    return fruitType:getIsHarvestReady(state)
end
