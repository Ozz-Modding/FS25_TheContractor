-- Job progress tracking (019): the single source of truth for "how much of
-- this job's field work is actually done," read straight from density-map
-- state the same way vanilla's AbstractFieldMission/*Mission subclasses do
-- (see Reference/FS25_Lua/missions/field/) — replicated here rather than
-- reusing Mission itself, since our jobs aren't vanilla missions. Decoupled
-- from operator identity by construction: a density-map scan doesn't know or
-- care whether the pixels changed because the player drove the tractor or
-- 020's AI dispatch did.
--
-- Stateless util, not a src/business/ subsystem — nothing here is
-- farm-scoped state that needs persisting; it's a live re-derivable view
-- over field + job data that's already persisted elsewhere (Job.lua's
-- completionPercentage is the field that gets written to, this module is
-- just what keeps it current). Every machine (server and every client)
-- computes it independently and locally from its own synced density-map
-- state, same as vanilla missions do — no event/broadcast needed for the
-- percentage itself.

TCJobProgress = {}

-- Mirrors AbstractFieldMission.SQM_PER_PARTITION: large fields get split
-- into partitions and round-robin one partition's worth of scanning per
-- call, so a single poll never stalls the frame on a big field.
TCJobProgress.SQM_PER_PARTITION = 2500

-- Placeholder cadence for the background tracker below — no watchdog
-- interval exists yet to inherit from (021 isn't built), so this is its own
-- reasonable-looking number per the ticket's Q18 "configurable" call.
-- 021 can either reuse this constant or replace the tracker entirely once
-- its own interval is decided.
TCJobProgress.POLL_INTERVAL_MS = 3000

-- jobId -> { completionModifier, completionFilter, isMulti, matchingPixels,
--            fruitTypeIndex, partitions, currentPartitionIndex,
--            fieldPercentageDone, isInitialized }
-- Scan state is keyed by job id, not stored on the job itself — Job.lua
-- deliberately only owns plain serializable state (see its header), and
-- DensityMapModifier/Filter objects are neither serializable nor
-- meaningful across a save/load boundary.
local progressStateByJobId = {}

local accumulatedMs = 0

-- Ground-type modifier (cultivate/plow): filters FieldDensityMap.GROUND_TYPE
-- between/at the given value(s). maxValue == nil means an EQUAL filter
-- instead of BETWEEN.
local function createGroundTypeModifier(minValue, maxValue)
    local mapId, firstChannel, numChannels = g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap
        .GROUND_TYPE)
    local modifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
    local filter = DensityMapFilter.new(modifier)

    if maxValue ~= nil then
        filter:setValueCompareParams(DensityValueCompareType.BETWEEN, minValue, maxValue)
    else
        filter:setValueCompareParams(DensityValueCompareType.EQUAL, minValue)
    end

    return modifier, filter
end

-- Mirrors CultivateMission:createModifier — ground type between
-- STUBBLE_TILLAGE and SEEDBED counts as cultivated.
local function createCultivateModifier()
    local minValue = FieldGroundType.getValueByType(FieldGroundType.STUBBLE_TILLAGE)
    local maxValue = FieldGroundType.getValueByType(FieldGroundType.SEEDBED)
    return createGroundTypeModifier(minValue, maxValue)
end

-- Mirrors PlowMission:createModifier — ground type at exactly PLOWED.
local function createPlowModifier()
    local plowedValue = FieldGroundType.getValueByType(FieldGroundType.PLOWED)
    return createGroundTypeModifier(plowedValue, nil)
end

-- Mirrors SowMission:createModifier, against the fruit locked into `state`
-- by resolveTargetFruitType below. growthState 1 is SowMission's own
-- default (freshly sown, before any real growth tick) — the same value
-- vanilla checks for a completed sow pass.
local function createSowModifier(state)
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(state.fruitTypeIndex)
    if fruitType == nil or fruitType.terrainDataPlaneId == nil then
        return nil
    end

    local modifier = DensityMapModifier.new(fruitType.terrainDataPlaneId, fruitType.startStateChannel,
        fruitType.numStateChannels, g_terrainNode)
    local filter = DensityMapFilter.new(modifier)
    filter:setValueCompareParams(DensityValueCompareType.EQUAL, 1)

    return modifier, filter
end

-- Mirrors HarvestMission:createModifier — a DensityMapMultiModifier summing
-- every one of the fruit type's "cut" growth states as done pixels, plus a
-- totalArea pass (growth state > 0) as the denominator. Deliberately not
-- pulling in HarvestMission:getCompletion's liters-deposited blend: that
-- half depends on a selling station and vehicle fill levels, machinery this
-- ticket doesn't own (job payout is 022's concern) — this only answers "how
-- much of the field has been cut," which is what 021/022/024 actually need
-- to know a worker is stuck or a field is done.
local function createHarvestModifier(state)
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(state.fruitTypeIndex)
    if fruitType == nil or fruitType.terrainDataPlaneId == nil then
        return nil
    end

    local baseModifier = DensityMapModifier.new(fruitType.terrainDataPlaneId, fruitType.startStateChannel,
        fruitType.numStateChannels, g_terrainNode)
    local baseFilter = DensityMapFilter.new(baseModifier)

    local multiModifier = DensityMapMultiModifier.new()
    for cutState, _ in pairs(fruitType.cutStates) do
        baseFilter:setValueCompareParams(DensityValueCompareType.EQUAL, cutState)
        multiModifier:addExecuteGet("cutState", baseModifier, baseFilter)
    end
    baseFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
    multiModifier:addExecuteGet("totalArea", baseModifier, baseFilter)

    state.matchingPixels = {}
    state.isMulti = true

    return multiModifier, nil
end

-- One entry per generatable job type (JobGeneration.JOB_TYPE_KEYS) — the
-- modifier factory, and whether it needs a target fruit type resolved
-- first (and from where: sow reads the field's planned fruit, harvest
-- reads whatever fruit is actually standing there). Job.lua doesn't carry
-- a fruitTypeIndex of its own (008 never added one, since it's not needed
-- for anything except this scan), so this reads the live field instead and
-- locks the result the first time a given job is scanned — the same "fixed
-- at creation" behaviour vanilla's SowMission/HarvestMission get for free
-- by storing fruitTypeIndex on the mission object.
local JOB_TYPE_HANDLERS = {
    cultivate = { createModifier = createCultivateModifier },
    plow = { createModifier = createPlowModifier },
    sow = { createModifier = createSowModifier, fruitTypeSource = "planned" },
    harvest = { createModifier = createHarvestModifier, fruitTypeSource = "current" },
}

local function resolveTargetFruitType(field, source)
    if source == "planned" then
        local plannedFruitTypeIndex = field:getPlannedFruitTypeIndex()
        if plannedFruitTypeIndex == nil or plannedFruitTypeIndex == 0 then
            return nil
        end
        return plannedFruitTypeIndex
    end

    local fieldState = field:getFieldState()
    if fieldState == nil or fieldState.fruitTypeIndex == FruitType.UNKNOWN then
        return nil
    end
    return fieldState.fruitTypeIndex
end

-- Builds (and caches) this job's scan state. Returns nil if it can't be
-- built yet (unknown job type, missing field, or a fruit-dependent job
-- whose target fruit can't be resolved this soon) — callers treat that as
-- "0% for now, try again next poll" rather than an error, since e.g. a
-- freshly-offered sow job may not have a planned fruit type set yet.
local function getOrCreateState(job)
    local cached = progressStateByJobId[job.id]
    if cached ~= nil then
        return cached
    end

    local handler = JOB_TYPE_HANDLERS[job.jobType]
    if handler == nil then
        return nil
    end

    local field = g_fieldManager:getFieldById(job.fieldId)
    if field == nil then
        return nil
    end

    local state = {
        fieldPercentageDone = 0,
        currentPartitionIndex = 1,
        isInitialized = false,
    }

    if handler.fruitTypeSource ~= nil then
        local fruitTypeIndex = resolveTargetFruitType(field, handler.fruitTypeSource)
        if fruitTypeIndex == nil then
            return nil
        end
        state.fruitTypeIndex = fruitTypeIndex
    end

    local modifier, filter = handler.createModifier(state)
    if modifier == nil then
        return nil
    end

    state.completionModifier = modifier
    state.completionFilter = filter

    progressStateByJobId[job.id] = state
    return state
end

-- Mirrors AbstractFieldMission:initializeModifier — splits the field's
-- polygon-clipped Z range into SQM_PER_PARTITION-sized bands so
-- getPartitionCompletion can scan one band at a time.
local function initializePartitions(state, field)
    field:getDensityMapPolygon():applyToModifier(state.completionModifier)
    state.partitions = {}

    local minZ, maxZ = state.completionModifier:getPolygonMinMaxZ()
    if minZ == nil then
        table.insert(state.partitions, { wasCalculated = false, area = 0, totalArea = 0 })
        return
    end

    local numPartitions = math.max(1, math.ceil(MathUtil.haToSqm(field:getAreaHa()) / TCJobProgress.SQM_PER_PARTITION))
    local regionPerPartition = (maxZ - minZ) / numPartitions
    local currentMinZ = minZ

    for i = 1, numPartitions do
        local currentMaxZ = i == numPartitions and maxZ or math.min(math.ceil(currentMinZ + regionPerPartition), maxZ)
        table.insert(state.partitions, {
            wasCalculated = false,
            area = 0,
            totalArea = 0,
            minZ = currentMinZ,
            maxZ = currentMaxZ,
        })
        currentMinZ = currentMaxZ
    end
end

local function setPartitionRegion(state, partitionIndex)
    if #state.partitions ~= 1 then
        local partition = state.partitions[partitionIndex]
        state.completionModifier:setPolygonClipRegion(partition.minZ, partition.maxZ)
    end
end

-- Mirrors AbstractFieldMission:getPartitionCompletion, with HarvestMission's
-- override folded in for the multi-modifier (cut-state) case.
local function getPartitionCompletion(state, partitionIndex)
    setPartitionRegion(state, partitionIndex)

    if state.isMulti then
        state.completionModifier:resetStats()
        state.completionModifier:execute(nil, state.matchingPixels, nil)
        return 0, state.matchingPixels.cutState, state.matchingPixels.totalArea
    end

    return state.completionModifier:executeGet(state.completionFilter)
end

-- Mirrors AbstractFieldMission:updateFieldPercentageDone.
local function updateFieldPercentageDone(state, totalArea)
    local areaDone = 0
    local areaTotal = 0
    local allCalculated = true

    for _, partition in ipairs(state.partitions) do
        if not partition.wasCalculated then
            allCalculated = false
        end
        if totalArea > 0 then
            areaDone = areaDone + partition.area
        else
            areaDone = areaDone + partition.totalArea
        end
        areaTotal = areaTotal + partition.totalArea
    end

    if allCalculated then
        state.fieldPercentageDone = areaTotal > 0 and (areaDone / areaTotal) or 0
    end
end

-- Public entry point: advances one partition of this job's scan and returns
-- its current completion fraction (0-1). Cheap enough to call on a periodic
-- poll (see update() below) without stalling the frame, since only one
-- partition's worth of density-map reads happens per call. Returns 0 for a
-- job whose scan state can't be built yet (see getOrCreateState).
function TCJobProgress.getCompletion(job)
    local state = getOrCreateState(job)
    if state == nil then
        return 0
    end

    if not state.isInitialized then
        local field = g_fieldManager:getFieldById(job.fieldId)
        if field == nil then
            return 0
        end
        initializePartitions(state, field)
        state.isInitialized = true
    end

    local _, area, totalArea = getPartitionCompletion(state, state.currentPartitionIndex)
    if area ~= nil then
        local partition = state.partitions[state.currentPartitionIndex]
        partition.wasCalculated = true
        partition.area = area
        partition.totalArea = totalArea
    end

    updateFieldPercentageDone(state, totalArea)

    state.currentPartitionIndex = state.currentPartitionIndex + 1
    if state.currentPartitionIndex > #state.partitions then
        state.currentPartitionIndex = 1
    end

    -- Same SUCCESS_FACTOR headroom AbstractFieldMission:getCompletion applies
    -- (100% coverage is never actually reachable pixel-for-pixel) clamped so
    -- a job can't report over 100% once it clears that bar.
    return math.min(1, state.fieldPercentageDone / AbstractMission.SUCCESS_FACTOR)
end

-- Drops cached scan state for a job. Callers don't have to call this
-- themselves for the normal allocated/in_progress -> terminal path — see
-- update() below, which purges anything no longer in that pair of states
-- every poll — but it's exposed for anything (022/024, or a job being
-- deleted outright) that wants a job's scan state gone immediately.
function TCJobProgress.clearJob(jobId)
    progressStateByJobId[jobId] = nil
end

-- Background tracker: every POLL_INTERVAL_MS, refresh completionPercentage
-- (0-100, matching Job.lua/MenuContractor's existing scale) for every
-- allocated/in_progress job across every farm, on whichever machine this
-- runs on. No server/client gating needed — density-map state is already
-- simulation-replicated, so every machine derives the same answer locally,
-- same as vanilla AbstractFieldMission's own per-machine update(). Runs for
-- every farm rather than just the local player's, since the server needs
-- accurate completionPercentage for all farms' missed-job checks (Jobs.lua's
-- missJob), not just whichever farm happens to be local on the server
-- machine.
local function refreshActiveJobs()
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Jobs == nil then
        return
    end

    local activeJobIds = {}

    for _, farm in ipairs(g_farmManager:getFarms()) do
        local farmId = farm.farmId
        for _, job in ipairs(tc.Jobs:getJobsByState(farmId, TheContractorJob.STATE.ALLOCATED)) do
            activeJobIds[job.id] = true
            job.completionPercentage = TCJobProgress.getCompletion(job) * 100
        end
        for _, job in ipairs(tc.Jobs:getJobsByState(farmId, TheContractorJob.STATE.IN_PROGRESS)) do
            activeJobIds[job.id] = true
            job.completionPercentage = TCJobProgress.getCompletion(job) * 100
        end
    end

    -- Purge scan state for anything that's no longer being tracked (job
    -- completed/declined/missed, or an id that simply stopped showing up)
    -- so a long save doesn't accumulate DensityMapModifier objects forever.
    for jobId in pairs(progressStateByJobId) do
        if not activeJobIds[jobId] then
            progressStateByJobId[jobId] = nil
        end
    end
end

-- Called from TheContractor:update(dt) every frame; only actually does
-- anything once accumulatedMs crosses POLL_INTERVAL_MS.
function TCJobProgress.update(dt)
    accumulatedMs = accumulatedMs + dt
    if accumulatedMs < TCJobProgress.POLL_INTERVAL_MS then
        return
    end
    accumulatedMs = 0

    refreshActiveJobs()
end
