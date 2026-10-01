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
--
-- Except (032) for job types marked serverMeasured in JobGeneration's
-- JOB_TYPES: tedder/bale (litres of windrow left, against what was spawned
-- at allocation), weed/hoe (weed area left, against what was there at
-- allocation) and bale wrap (the spawned bales' wrapping) are measured
-- against a baseline only the server has (job.workTotal/spawnedBaleIds),
-- so only the server measures them, and sends the result to clients
-- (TCJobProgressEvent) whenever it moves by a whole percent.

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
--            fieldPercentageDone, isInitialized, ... }
-- Scan state is keyed by job id, not stored on the job itself — Job.lua
-- deliberately only owns plain serializable state (see its header), and
-- DensityMapModifier/Filter objects are neither serializable nor
-- meaningful across a save/load boundary.
local progressStateByJobId = {}

-- Server-only: jobId -> the whole percentage last sent to clients for a
-- serverMeasured job.
local sentPercentageByJobId = {}

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

-- A fruit plane at exactly one growth state.
local function createFruitStateModifier(fruitTypeIndex, growthState)
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil or fruitType.terrainDataPlaneId == nil then
        return nil
    end

    local modifier = DensityMapModifier.new(fruitType.terrainDataPlaneId, fruitType.startStateChannel,
        fruitType.numStateChannels, g_terrainNode)
    local filter = DensityMapFilter.new(modifier)
    filter:setValueCompareParams(DensityValueCompareType.EQUAL, growthState)

    return modifier, filter
end

-- Mirrors SowMission:createModifier, against the fruit locked into `state`
-- by resolveTargetFruitType below. growthState 1 is SowMission's own
-- default (freshly sown, before any real growth tick) — the same value
-- vanilla checks for a completed sow pass.
local function createSowModifier(state)
    return createFruitStateModifier(state.fruitTypeIndex, 1)
end

-- Mirrors MowMission:createModifier — the crop at its cut state.
local function createMowModifier(state)
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(state.fruitTypeIndex)
    if fruitType == nil or fruitType.cutState == nil then
        return nil
    end
    return createFruitStateModifier(state.fruitTypeIndex, fruitType.cutState)
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
        multiModifier:addExecuteGet("done", baseModifier, baseFilter)
    end
    baseFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
    multiModifier:addExecuteGet("totalArea", baseModifier, baseFilter)

    state.matchingPixels = {}
    state.isMulti = true

    return multiModifier, nil
end

-- Mirrors TedderMission/BaleMission:createModifier — the windrow of the
-- job's fill type lying on the height map. What's left is read as litres
-- (see updateFieldPercentageDone's "remainingLiters").
local function createWindrowModifier(state, job)
    local fillTypeIndex = TCFieldPreparation.getJobWindrowFillType(job)
    local heightType = fillTypeIndex ~= nil and
        g_densityMapHeightManager:getDensityMapHeightTypeByFillTypeIndex(fillTypeIndex) or nil
    if heightType == nil then
        return nil
    end

    local modifier = DensityMapModifier.new(DensityMapHeightUtil.terrainDetailHeightId,
        DensityMapHeightUtil.heightFirstChannel, DensityMapHeightUtil.heightNumChannels)
    local filter = DensityMapFilter.new(DensityMapHeightUtil.terrainDetailHeightId,
        DensityMapHeightUtil.typeFirstChannel, DensityMapHeightUtil.typeNumChannels)
    filter:setValueCompareParams(DensityValueCompareType.EQUAL, heightType.index)

    state.minValidLiters = g_densityMapHeightManager:getMinValidLiterValue(fillTypeIndex)
    return modifier, filter
end

-- Mirrors FertilizeMission:createModifier — the spray level one up from
-- where the job started (FertilizeMission.tryGenerateMission's target).
local function createFertilizeModifier(state, job)
    if job.startState == nil then
        return nil
    end
    local mapId, firstChannel, numChannels = g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap
        .SPRAY_LEVEL)
    local modifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
    local filter = DensityMapFilter.new(modifier)
    filter:setValueCompareParams(DensityValueCompareType.EQUAL, job.startState + 1)
    return modifier, filter
end

-- Mirrors HerbicideMission:createModifier — the weed state herbicide turns
-- the starting weeds into (the weed system's herbicide replacements), over
-- all weeded area.
local function createHerbicideModifier(state, job)
    if job.startState == nil then
        return nil
    end
    local replacements = g_currentMission.weedSystem:getHerbicideReplacements().weed.replacements
    local targetState = replacements[job.startState]
    if targetState == nil or targetState == 0 then
        return nil
    end

    local mapId, firstChannel, numChannels = g_currentMission.weedSystem:getDensityMapData()
    local modifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
    local filter = DensityMapFilter.new(modifier)

    local multiModifier = DensityMapMultiModifier.new()
    filter:setValueCompareParams(DensityValueCompareType.EQUAL, targetState)
    multiModifier:addExecuteGet("done", modifier, filter)
    filter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
    multiModifier:addExecuteGet("totalArea", modifier, filter)

    state.matchingPixels = {}
    state.isMulti = true

    return multiModifier, nil
end

-- Mirrors WeedMission/HoeMission:createModifier — weeds still standing.
-- What's left is read against the weed area at the start (see
-- updateFieldPercentageDone's "remainingArea").
local function createWeedModifier()
    local mapId, firstChannel, numChannels = g_currentMission.weedSystem:getDensityMapData()
    local modifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
    local filter = DensityMapFilter.new(modifier)
    filter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
    return modifier, filter
end

-- Mirrors StonePickMission:createModifier — picked stone area within the
-- stone mask, less the unmasked area (StonePickMission:
-- getPartitionCompletion, see getPartitionCompletion below).
local function createStonePickModifier(state)
    local mapId, firstChannel, numChannels = g_currentMission.stoneSystem:getDensityMapData()
    local _, maxValue = g_currentMission.stoneSystem:getMinMaxValues()

    local modifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
    local filter = DensityMapFilter.new(modifier)
    filter:setValueCompareParams(DensityValueCompareType.NOTEQUAL, maxValue)
    local maskedFilter = DensityMapFilter.new(modifier)
    maskedFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)

    local unmaskedModifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
    local unmaskedFilter = DensityMapFilter.new(unmaskedModifier)
    unmaskedFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 0)

    state.maskedFilter = maskedFilter
    state.unmaskedModifier = unmaskedModifier
    state.unmaskedFilter = unmaskedFilter

    return modifier, filter
end

-- Bale wrap (server-only, see file header) — BaleWrapMission:getCompletion:
-- the spawned bales' average wrapping, only counting as done once every
-- one is fully wrapped and back on the ground. A spawned bale that's gone
-- (sold, destroyed) counts as unwrapped, against the number laid out.
local function getBaleWrapCompletion(job)
    if job.workTotal == nil or job.workTotal <= 0 then
        return 0
    end

    local wrapSum = 0
    local allDropped = true
    local count = 0
    for _, uniqueId in ipairs(job.spawnedBaleIds) do
        local bale = g_currentMission.itemSystem:getItemByUniqueId(uniqueId)
        if bale ~= nil then
            count = count + 1
            wrapSum = wrapSum + (bale.wrappingState or 0)
            if bale:getIsMounted() then
                allDropped = false
            end
        end
    end

    local wrapped = wrapSum / job.workTotal
    if wrapped >= 1 and count >= job.workTotal and allDropped then
        return 1
    end
    return math.min(0.99, wrapped * 0.99)
end

-- One entry per generatable job type (JobGeneration.JOB_TYPE_KEYS):
--   createModifier(state, job)  builds the scan's modifier/filter
--   fruitTypeSource  a target fruit type has to be resolved first, and
--                    from where: sow reads the field's planned fruit,
--                    harvest/mow whatever's actually standing there. Job.lua
--                    doesn't carry a fruitTypeIndex of its own for sow, so
--                    this reads the live field instead and locks the result
--                    the first time a given job is scanned — the same "fixed
--                    at creation" behaviour vanilla's SowMission/
--                    HarvestMission get for free by storing fruitTypeIndex
--                    on the mission object.
--   measure          how the scan turns into a fraction done: "area" (the
--                    default - matching area over the field's), or against
--                    job.workTotal, "remainingLiters" (windrow left) or
--                    "remainingArea" (weeds left)
--   getCompletion(job)  a measure that isn't a density-map scan at all
local JOB_TYPE_HANDLERS = {
    cultivate = { createModifier = createCultivateModifier },
    plow = { createModifier = createPlowModifier },
    sow = { createModifier = createSowModifier, fruitTypeSource = "planned" },
    harvest = { createModifier = createHarvestModifier, fruitTypeSource = "current" },
    mow = { createModifier = createMowModifier, fruitTypeSource = "current" },
    tedder = { createModifier = createWindrowModifier, measure = "remainingLiters" },
    bale = { createModifier = createWindrowModifier, measure = "remainingLiters" },
    baleWrap = { getCompletion = getBaleWrapCompletion },
    fertilize = { createModifier = createFertilizeModifier },
    herbicide = { createModifier = createHerbicideModifier },
    weed = { createModifier = createWeedModifier, measure = "remainingArea" },
    hoe = { createModifier = createWeedModifier, measure = "remainingArea" },
    stonePick = { createModifier = createStonePickModifier },
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
-- built yet (unknown job type, missing field, a fruit-dependent job whose
-- target fruit can't be resolved this soon, or a job measured against a
-- baseline its field preparation hasn't set yet) — callers treat that as
-- "0% for now, try again next poll" rather than an error, since e.g. a
-- freshly-offered sow job may not have a planned fruit type set yet.
local function getOrCreateState(job)
    local cached = progressStateByJobId[job.id]
    if cached ~= nil then
        return cached
    end

    local handler = JOB_TYPE_HANDLERS[job.jobType]
    if handler == nil or handler.createModifier == nil then
        return nil
    end
    if handler.measure ~= nil and job.workTotal == nil then
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
        measure = handler.measure or "area",
    }

    if handler.fruitTypeSource ~= nil then
        -- A job's own recorded crop wins over the live field state, which
        -- can lag behind TCFieldPreparation's forced update for a moment.
        local fruitTypeIndex = nil
        if handler.fruitTypeSource == "current" then
            fruitTypeIndex = job:getFruitTypeIndex()
        end
        if fruitTypeIndex == nil then
            fruitTypeIndex = resolveTargetFruitType(field, handler.fruitTypeSource)
        end
        if fruitTypeIndex == nil then
            return nil
        end
        state.fruitTypeIndex = fruitTypeIndex
    end

    local modifier, filter = handler.createModifier(state, job)
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
    if state.unmaskedModifier ~= nil then
        field:getDensityMapPolygon():applyToModifier(state.unmaskedModifier)
    end
    state.partitions = {}

    local minZ, maxZ = state.completionModifier:getPolygonMinMaxZ()
    if minZ == nil then
        table.insert(state.partitions, { wasCalculated = false, sumPixels = 0, area = 0, totalArea = 0 })
        return
    end

    local numPartitions = math.max(1, math.ceil(MathUtil.haToSqm(field:getAreaHa()) / TCJobProgress.SQM_PER_PARTITION))
    local regionPerPartition = (maxZ - minZ) / numPartitions
    local currentMinZ = minZ

    for i = 1, numPartitions do
        local currentMaxZ = i == numPartitions and maxZ or math.min(math.ceil(currentMinZ + regionPerPartition), maxZ)
        table.insert(state.partitions, {
            wasCalculated = false,
            sumPixels = 0,
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
        if state.unmaskedModifier ~= nil then
            state.unmaskedModifier:setPolygonClipRegion(partition.minZ, partition.maxZ)
        end
    end
end

-- Mirrors AbstractFieldMission:getPartitionCompletion, with HarvestMission/
-- HerbicideMission's override folded in for the multi-modifier case and
-- StonePickMission's for the stone mask. Returns sumPixels, area,
-- totalArea.
local function getPartitionCompletion(state, partitionIndex)
    setPartitionRegion(state, partitionIndex)

    if state.isMulti then
        state.completionModifier:resetStats()
        state.completionModifier:execute(nil, state.matchingPixels, nil)
        return 0, state.matchingPixels.done, state.matchingPixels.totalArea
    end

    if state.unmaskedModifier ~= nil then
        local sumPixels, area, totalArea = state.completionModifier:executeGet(state.completionFilter,
            state.maskedFilter)
        local _, unmaskedArea = state.unmaskedModifier:executeGet(state.unmaskedFilter)
        return sumPixels, area, totalArea - unmaskedArea
    end

    return state.completionModifier:executeGet(state.completionFilter)
end

-- Mirrors AbstractFieldMission:updateFieldPercentageDone, plus the
-- overrides for measures read against the job's baseline:
--   remainingLiters  TedderMission/BaleMission:getFieldCompletion - 1 minus
--                    the windrow left (sumPixels, in min-valid-litre steps)
--                    over what was spawned
--   remainingArea    WeedMission/HoeMission:updateFieldPercentageDone - 1
--                    minus the weed area left over what there was
local function updateFieldPercentageDone(state, totalArea, job)
    local sumPixels = 0
    local areaDone = 0
    local areaTotal = 0
    local allCalculated = true

    for _, partition in ipairs(state.partitions) do
        if not partition.wasCalculated then
            allCalculated = false
        end
        sumPixels = sumPixels + partition.sumPixels
        if totalArea > 0 then
            areaDone = areaDone + partition.area
        else
            areaDone = areaDone + partition.totalArea
        end
        areaTotal = areaTotal + partition.totalArea
    end

    if not allCalculated then
        return
    end

    if state.measure == "remainingLiters" then
        state.fieldPercentageDone = job.workTotal > 0 and
            math.clamp(1 - sumPixels * state.minValidLiters / job.workTotal, 0, 1) or 0
    elseif state.measure == "remainingArea" then
        state.fieldPercentageDone = job.workTotal > 0 and math.clamp(1 - areaDone / job.workTotal, 0, 1) or 0
    else
        state.fieldPercentageDone = areaTotal > 0 and (areaDone / areaTotal) or 0
    end
end

-- Public entry point: advances one partition of this job's scan and returns
-- its current completion fraction (0-1). Cheap enough to call on a periodic
-- poll (see update() below) without stalling the frame, since only one
-- partition's worth of density-map reads happens per call. Returns 0 for a
-- job whose scan state can't be built yet (see getOrCreateState).
function TCJobProgress.getCompletion(job)
    local handler = JOB_TYPE_HANDLERS[job.jobType]
    if handler ~= nil and handler.getCompletion ~= nil then
        return handler.getCompletion(job)
    end

    if TCFieldPreparation.isPreparing(job) then
        return 0
    end

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

    local sumPixels, area, totalArea = getPartitionCompletion(state, state.currentPartitionIndex)
    if area ~= nil then
        local partition = state.partitions[state.currentPartitionIndex]
        partition.wasCalculated = true
        partition.sumPixels = sumPixels or 0
        partition.area = area
        partition.totalArea = totalArea
    end

    updateFieldPercentageDone(state, totalArea or 0, job)

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
    sentPercentageByJobId[jobId] = nil
end

local function isServerMeasured(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    return jobDef ~= nil and jobDef.serverMeasured == true
end

-- Keeps one job's completionPercentage current - measured locally, except
-- a serverMeasured job on a client, which waits for the server's reading
-- (TCJobProgressEvent). The server sends that whenever the whole percent
-- changes.
local function refreshJob(job, isServer)
    local serverMeasured = isServerMeasured(job)
    if serverMeasured and not isServer then
        return
    end

    job.completionPercentage = TCJobProgress.getCompletion(job) * 100

    if serverMeasured and g_server ~= nil then
        local whole = math.floor(job.completionPercentage)
        if sentPercentageByJobId[job.id] ~= whole then
            sentPercentageByJobId[job.id] = whole
            g_server:broadcastEvent(TCJobProgressEvent.new(job.farmId, job.id, job.completionPercentage))
        end
    end
end

-- Background tracker: every POLL_INTERVAL_MS, refresh completionPercentage
-- (0-100, matching Job.lua/MenuContractor's existing scale) for every
-- allocated/in_progress job across every farm, on whichever machine this
-- runs on. No server/client gating needed — density-map state is already
-- simulation-replicated, so every machine derives the same answer locally,
-- same as vanilla AbstractFieldMission's own per-machine update() (bar
-- serverMeasured jobs, see refreshJob). Runs for every farm rather than
-- just the local player's, since the server needs accurate
-- completionPercentage for all farms' missed-job checks (Jobs.lua's
-- missJob), not just whichever farm happens to be local on the server
-- machine.
local function refreshActiveJobs()
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Jobs == nil then
        return
    end

    local isServer = g_currentMission:getIsServer()
    local activeJobIds = {}

    for _, farm in ipairs(g_farmManager:getFarms()) do
        local farmId = farm.farmId
        for _, job in ipairs(tc.Jobs:getJobsByState(farmId, TheContractorJob.STATE.ALLOCATED)) do
            activeJobIds[job.id] = true
            refreshJob(job, isServer)
        end
        for _, job in ipairs(tc.Jobs:getJobsByState(farmId, TheContractorJob.STATE.IN_PROGRESS)) do
            activeJobIds[job.id] = true
            refreshJob(job, isServer)
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
    for jobId in pairs(sentPercentageByJobId) do
        if not activeJobIds[jobId] then
            sentPercentageByJobId[jobId] = nil
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
