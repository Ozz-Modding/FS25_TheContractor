-- Forces a job's field into a state its job can actually be worked from,
-- the moment the job is allocated (018) - whoever's operating. A job we've
-- offered MUST be doable: fields move on between offer and allocation
-- (NPC fieldwork, growth, the player's own changes), and a field that
-- already looks "done" for the job's type would otherwise read as 100%
-- complete on 019's very first progress scan and pay out for nothing.
--
-- Same FieldUpdateTask shapes vanilla's own FieldManager NPC actions and
-- field missions use (FieldManager:plowField/cultivateField/sowField,
-- AbstractFieldMission:getFieldPreparingTask and each mission type's
-- override), just aimed at the state *before* the job's work rather than
-- after it. Applied immediately (addFieldUpdateTask's `immediate` path),
-- not queued across frames, so there's no window where a progress scan
-- could read the old state. Density-map changes are replicated to clients
-- by the engine itself.
--
-- Some job types (032) need more than a field state to work on, and get it
-- the way vanilla's own missions do: tedding and baling need a cut crop
-- lying in windrows (TedderMission/BaleMission spawn one along a field
-- course), bale wrapping needs bales (BaleWrapMission spawns them), and so
-- does a straw delivery (067), straw ones. That spawning runs over several
-- frames (FieldCourseIterator), so those jobs' baseline (job.workTotal -
-- what TCJobProgress measures them against) is
-- only set once it's finished; a save that lands mid-spawn prepares the
-- field again on the next load (resumeAfterLoad).

TCFieldPreparation = {}

-- Ground state a job type's work starts from - chosen so none of them
-- already satisfy TCJobProgress's "done" filter for that job type:
--   plow       harvested stubble (not PLOWED)
--   cultivate  plowed (outside STUBBLE_TILLAGE..SEEDBED)
--   sow        cultivated, nothing growing
TCFieldPreparation.GROUND_TYPE_BY_JOB_TYPE = {
    plow = FieldGroundType.STUBBLE_TILLAGE,
    cultivate = FieldGroundType.PLOWED,
    sow = FieldGroundType.CULTIVATED,
}

-- Stone pick: StonePickMission's own stoneValue for the stones it lays.
TCFieldPreparation.STONE_LEVEL = 3

-- Windrow/bale layout along the field course - BaleMission's (9 m, or 12 m
-- over 6 ha, 2 headlands) and BaleWrapMission's (8 m, 2 headlands).
TCFieldPreparation.WINDROW_COURSE_WIDTH = 9
TCFieldPreparation.WINDROW_COURSE_WIDTH_LARGE = 12
TCFieldPreparation.WINDROW_COURSE_LARGE_FIELD_HA = 6
TCFieldPreparation.BALE_COURSE_WIDTH = 8
TCFieldPreparation.COURSE_HEADLANDS = 2

-- Bale wrap: the bale vanilla falls back to when the job's wrapper tells
-- us nothing (BaleWrapMission.tryGenerateMission's round option).
TCFieldPreparation.DEFAULT_WRAP_BALE = { isRoundbale = true, width = 1.2, height = 0, length = 0, diameter = 1.5 }

-- Straw delivery (067): the straw bale it lays out - the same round size,
-- else any round straw bale the map has, else any square one.
TCFieldPreparation.STRAW_BALE = { isRoundbale = true, width = 1.2, diameter = 1.5 }

-- jobId -> token of the spawn running for that job (see startSpawn)
local spawningJobIds = {}
local hasResumedAfterLoad = false
-- Server-only: bale -> baler for a job's bales that were still inside a
-- baler when its crop was cleared up, deleted as soon as the baler drops
-- them (removeBaledCrop). Not saved: a bale held through a save and a
-- load is the player's.
local balesToDeleteOnDrop = {}

function TCFieldPreparation.reset()
    spawningJobIds = {}
    hasResumedAfterLoad = false
    balesToDeleteOnDrop = {}
end

local function getJobDef(job)
    return TheContractorJobGeneration.JOB_TYPES[job.jobType]
end

-- The whole field's state, as vanilla missions change it: edit the field's
-- own FieldState, then write all of it back over the field.
local function applyFieldState(field, fieldState)
    local task = fieldState:createFieldUpdateTask()
    task:setField(field)
    task:setGroundAngle(field:getAngle())
    task:clearHeight()
    g_fieldManager:addFieldUpdateTask(task, true)
end

-- A standing crop at its first harvestable state (harvest, mow).
local function prepareStandingCrop(job, field)
    local fruitTypeIndex = job:getFruitTypeIndex()
    local fruitType = fruitTypeIndex ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex) or nil
    if fruitType == nil then
        TCLog.warning("TheContractor: job %d has no resolvable crop, can't prepare field %d", job.id, job.fieldId)
        return false
    end

    local task = FieldUpdateTask.new()
    task:setField(field)
    task:setWeedState(0)
    task:setGroundAngle(field:getAngle())
    task:clearHeight()
    task:setFruit(fruitTypeIndex, fruitType:getMinHarvestingGrowthState())
    task:setGroundType(fruitType:getDefaultSowingGroundType())
    g_fieldManager:addFieldUpdateTask(task, true)
    return true
end

-- Bare ground (plow, cultivate, sow).
local function prepareGround(job, field)
    local groundType = TCFieldPreparation.GROUND_TYPE_BY_JOB_TYPE[job.jobType]

    local task = FieldUpdateTask.new()
    task:setField(field)
    task:setWeedState(0)
    task:setGroundAngle(field:getAngle())
    task:clearHeight()
    task:setFruit(FruitType.UNKNOWN, 0)
    task:setStoneLevel(0)
    task:setGroundType(groundType)
    g_fieldManager:addFieldUpdateTask(task, true)
    return true
end

-- A crop just cut and left lying (tedder, bale, bale wrap) - what
-- TedderMission/BaleMission/BaleWrapMission's preparing tasks set.
local function prepareCutCrop(field, fruitTypeIndex)
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    local fieldState = field:getFieldState()
    fieldState.fruitTypeIndex = fruitTypeIndex
    fieldState.growthState = fruitType.cutState
    fieldState.weedState = 0
    if fruitType.harvestGroundType ~= nil then
        fieldState.groundType = fruitType.harvestGroundType
    end
    applyFieldState(field, fieldState)
end

-- 135: a grass field cut short for an auction's lots: its own crop at its
-- cut state, as prepareCutCrop leaves a field, with nothing lying. Server.
-- Returns whether it was cut (false for a field with no crop that's cut).
function TCFieldPreparation.cutGrass(field)
    local fieldState = field ~= nil and field:getFieldState() or nil
    if fieldState == nil or not fieldState.isValid or fieldState.fruitTypeIndex == nil then
        return false
    end
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
    if fruitType == nil or fruitType.cutState == nil then
        return false
    end
    prepareCutCrop(field, fieldState.fruitTypeIndex)
    return true
end

-- Weed area on the field right now, in density-map pixels - WeedMission/
-- HoeMission's totalWeedArea (finishedPreparing).
local function measureWeedArea(field)
    local mapId, firstChannel, numChannels = g_currentMission.weedSystem:getDensityMapData()
    local modifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
    local filter = DensityMapFilter.new(modifier)
    filter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
    field:getDensityMapPolygon():applyToModifier(modifier)
    local _, area = modifier:executeGet(filter)
    return area or 0
end

-- The weed state a weed/hoe job lays its field out at. Vanilla's weed
-- missions take any state the tool clears to nothing, including the
-- just-germinated ones that aren't drawn or on the map (maps_weed.xml's
-- "invisible" states, which have no map colour) - a job that progresses on
-- a field that looks clean. So an invisible state is raised to the first
-- visible one at or above it that the tool still clears (any visible one
-- if none is above it); nil if there's no such state (keep the field's).
function TCFieldPreparation.getVisibleWeedState(weedSystem, weedState, isHoe)
    local visible = {}
    for _, entry in ipairs(weedSystem:getColors()) do
        for _, state in ipairs(entry.states) do
            visible[state] = true
        end
    end
    if visible[weedState] then
        return weedState
    end

    local replacements = weedSystem:getWeederReplacements(isHoe).weed.replacements
    local best, lowest = nil, nil
    for state in pairs(visible) do
        if replacements[state] == 0 then
            if state >= weedState and (best == nil or state < best) then
                best = state
            end
            if lowest == nil or state < lowest then
                lowest = state
            end
        end
    end
    return best or lowest
end

-- Windrow the job's crop leaves once cut: straw, or for grass hay-to-be
-- (DRYGRASS_WINDROW) - BaleMission:setFruitType. Tedding works fresh grass.
function TCFieldPreparation.getJobWindrowFillType(job)
    if job.jobType == "tedder" then
        return FillType.GRASS_WINDROW
    end
    local fruitTypeIndex = job:getFruitTypeIndex()
    if fruitTypeIndex == nil then
        return nil
    end
    if fruitTypeIndex == FruitType.GRASS then
        return FillType.DRYGRASS_WINDROW
    end
    return g_fruitTypeManager:getWindrowFillTypeIndexByFruitTypeIndex(fruitTypeIndex)
end

local function deleteSpawnedBales(job)
    for _, uniqueId in ipairs(job.spawnedBaleIds) do
        local bale = g_currentMission.itemSystem:getItemByUniqueId(uniqueId)
        if bale ~= nil then
            bale:delete()
        end
    end
    job.spawnedBaleIds = {}
end

-- 075: whatever's left of a fly-tipping job's pile.
local function deleteDebris(job)
    if job.debrisIds == nil or #job.debrisIds == 0 then
        return
    end
    for _, uniqueId in ipairs(job.debrisIds) do
        local debris = g_currentMission.itemSystem:getItemByUniqueId(uniqueId)
        if debris ~= nil then
            debris:delete()
        end
    end
    job.debrisIds = {}
end

local function getJobFruitTypeIndex(job)
    if job.jobType == "tedder" or job.jobType == "baleWrap" then
        return FruitType.GRASS
    end
    return job:getFruitTypeIndex()
end

-- A spawn in progress is identified by a token, so one that's been
-- superseded (the field prepared again) or called off (the job's over,
-- clearUpAfterJob) stops adding to the field and never sets a baseline.
local function startSpawn(job)
    local token = {}
    spawningJobIds[job.id] = token
    return token
end

local function finishSpawn(job, total, what)
    spawningJobIds[job.id] = nil
    job.workTotal = total
    TCJobProgress.clearJob(job.id)
    if total <= 0 then
        TCLog.warning("TheContractor: job %d field %d - no %s could be laid out", job.id, job.fieldId, what)
    else
        TCLog.info("TheContractor: job %d field %d - laid out %.0f %s", job.id, job.fieldId, total, what)
    end
    -- 067: what a player delivering the straw has to take in is only known
    -- now.
    TCHaulage.startDelivery(job)
end

-- A windrow along the field course, the way BaleMission:update lays one:
-- the field's worth of cut crop (area * windrowLiterPerSqm) spread evenly
-- over the course's length, tipped along each segment.
local function spawnWindrow(job, field, fruitTypeIndex, fillTypeIndex)
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    local litersPerSqm = fruitType.windrowLiterPerSqm or fruitType.literPerSqm
    local areaHa = field:getAreaHa()
    local totalLiters = MathUtil.haToSqm(areaHa) * litersPerSqm

    local settings = FieldCourseSettings.new()
    settings.implementWidth = areaHa > TCFieldPreparation.WINDROW_COURSE_LARGE_FIELD_HA and
        TCFieldPreparation.WINDROW_COURSE_WIDTH_LARGE or TCFieldPreparation.WINDROW_COURSE_WIDTH
    settings.numHeadlands = TCFieldPreparation.COURSE_HEADLANDS

    local spawnedLiters = 0
    local x, z = field:getCenterOfFieldWorldPosition()
    local token = startSpawn(job)
    FieldCourseIterator.new(x, z, settings, function(sx, sz, ex, ez, _, _, _, courseLength)
        if spawningJobIds[job.id] ~= token or courseLength == nil or courseLength <= 0 then
            return
        end
        local liters = MathUtil.vector2Length(ex - sx, ez - sz) * totalLiters / courseLength
        local dropped = DensityMapHeightUtil.tipToGroundAroundLine(nil, liters, fillTypeIndex, sx, 0, sz, ex, 0, ez,
            0.5, 0.5, 0, false, nil, false, true)
        spawnedLiters = spawnedLiters + (dropped or 0)
    end, function()
        if spawningJobIds[job.id] == token then
            finishSpawn(job, spawnedLiters, "litres of windrow")
        end
    end)
end

-- Which bale to lay for a bale wrap job: one the job's wrapper actually
-- takes (BaleWrapper's allowedBaleTypes, round preferred - the same sizes
-- getIsBaleWrappable matches bales against), else vanilla's default.
local function getWrapBaleIndex(job)
    for _, vehicleId in ipairs(job.assignedEquipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        local spec = vehicle ~= nil and vehicle.spec_baleWrapper or nil
        if spec ~= nil then
            for _, baleType in ipairs(spec.roundBaleWrapper.allowedBaleTypes or {}) do
                if not baleType.skipWrapping then
                    local baleIndex = g_baleManager:getBaleIndex(FillType.GRASS_WINDROW, true, baleType.width, 0, 0,
                        baleType.diameter)
                    if baleIndex ~= nil then
                        return baleIndex
                    end
                end
            end
            for _, baleType in ipairs(spec.squareBaleWrapper.allowedBaleTypes or {}) do
                if not baleType.skipWrapping then
                    local baleIndex = g_baleManager:getBaleIndex(FillType.GRASS_WINDROW, false, baleType.width,
                        baleType.height, baleType.length, 0)
                    if baleIndex ~= nil then
                        return baleIndex
                    end
                end
            end
        end
    end

    local bale = TCFieldPreparation.DEFAULT_WRAP_BALE
    return g_baleManager:getBaleIndex(FillType.GRASS_WINDROW, bale.isRoundbale, bale.width, bale.height, bale.length,
        bale.diameter)
end

-- The straw bale a straw delivery lays out (STRAW_BALE), or nil if the map
-- has no straw bale at all.
function TCFieldPreparation.getStrawBaleIndex()
    local bale = TCFieldPreparation.STRAW_BALE
    return g_baleManager:getBaleIndex(FillType.STRAW, bale.isRoundbale, bale.width, nil, nil, bale.diameter) or
        g_baleManager:getBaleIndex(FillType.STRAW, true) or g_baleManager:getBaleIndex(FillType.STRAW, false)
end

-- Bales along the field course, the way BaleWrapMission:prepareField lays
-- them: a field's worth of the crop (area * windrowLiterPerSqm) in full
-- bales of fillTypeIndex, one dropped each time a bale's worth of course
-- has gone by (a part-bale's worth left over at the end makes no bale, as
-- in vanilla). A bale wrap job's are owned like vanilla's, by the field's
-- owner (no one, for the unowned land contracts go to), so our wrapper can
-- work them but nobody can sell them. A straw delivery's (067) are the
-- job's farm's: its player has to be able to load them (in MP too), and
-- the delivery tracker counts what the bale's owner sells.
local function spawnBales(job, field, baleIndex, fruitTypeIndex, fillTypeIndex, ownerFarmId)
    if baleIndex == nil then
        finishSpawn(job, 0, "bales")
        return
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    local totalLiters = MathUtil.haToSqm(field:getAreaHa()) * (fruitType.windrowLiterPerSqm or fruitType.literPerSqm)
    local xmlFilename = g_baleManager:getBaleXMLFilenameByIndex(baleIndex)
    local capacity = g_baleManager:getBaleCapacityByBaleIndex(baleIndex, fillTypeIndex)
    local baleDesc = g_baleManager:getBaleDescByIndex(baleIndex)
    local isRoundbale = g_baleManager:getIsRoundBale(baleIndex)
    if capacity == nil or capacity <= 0 then
        finishSpawn(job, 0, "bales")
        return
    end

    local function spawnBale(sx, sz, ex, ez, length, fraction)
        local dirX, dirZ = MathUtil.vector2Normalize(ex - sx, ez - sz)
        local x = sx + dirX * length * fraction
        local z = sz + dirZ * length * fraction
        local rotY = MathUtil.getYRotationFromDirection(dirX, dirZ) + math.pi * 0.5
        local size = baleDesc.diameter
        if not isRoundbale then
            rotY = rotY + math.pi * 0.5
            size = baleDesc.height
        end
        local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + size * 0.5

        local bale = Bale.new(true, g_client ~= nil)
        if bale:loadFromConfigXML(xmlFilename, x, y, z, 0, rotY, 0) then
            bale:setFillType(fillTypeIndex)
            bale:setFillLevel(capacity)
            bale:setOwnerFarmId(ownerFarmId, true)
            bale:register()
            table.insert(job.spawnedBaleIds, bale:getUniqueId())
        end
    end

    local settings = FieldCourseSettings.new()
    settings.implementWidth = TCFieldPreparation.BALE_COURSE_WIDTH
    settings.numHeadlands = TCFieldPreparation.COURSE_HEADLANDS

    local untilNextBale = capacity
    local x, z = field:getCenterOfFieldWorldPosition()
    local token = startSpawn(job)
    FieldCourseIterator.new(x, z, settings, function(sx, sz, ex, ez, _, _, _, courseLength)
        if spawningJobIds[job.id] ~= token or courseLength == nil or courseLength <= 0 then
            return
        end
        local length = MathUtil.vector2Length(ex - sx, ez - sz)
        local segmentLiters = length * totalLiters / courseLength
        local remaining = segmentLiters
        while remaining > 0 do
            if remaining <= untilNextBale then
                untilNextBale = untilNextBale - remaining
                remaining = 0
            else
                remaining = remaining - untilNextBale
                untilNextBale = capacity
                spawnBale(sx, sz, ex, ez, length, 1 - remaining / segmentLiters)
            end
        end
    end, function()
        if spawningJobIds[job.id] == token then
            finishSpawn(job, #job.spawnedBaleIds, "bales")
        end
    end)
end

-- Server-only. Returns false (and logs) if the field or a crop it needs
-- can't be resolved - the caller still allocates, since a best-effort job
-- beats a silently stuck allocation.
function TCFieldPreparation.prepareFieldForJob(job)
    if not g_currentMission:getIsServer() then
        return false
    end

    local field = g_fieldManager:getFieldById(job.fieldId)
    local jobDef = getJobDef(job)
    if field == nil or jobDef == nil then
        TCLog.warning("TheContractor: job %d field %d not found, can't prepare it", job.id, job.fieldId)
        return false
    end

    -- 075: a fly-tipping job is the pile already lying there, nothing to
    -- do to the field (and its workTotal is the pile's size, set at
    -- creation). 106: a spill lies on the road, not the field. 107: an
    -- offField job's field only says where it is.
    if jobDef.rewardPerItem ~= nil or jobDef.spill or jobDef.offField then
        return true
    end

    -- Anything left from an earlier go (a re-prepare after a load mid-spawn).
    deleteSpawnedBales(job)
    job.workTotal = nil

    -- 072: a joyrider plow job is the damage, so the field stays as it is -
    -- unless someone's dealt with the grass since (then the usual stubble,
    -- or the job could count their work as ours).
    if job.keepFieldState and TheContractorJoyriders.isGrassField(field) then
        TCLog.info("TheContractor: left field %d as it is for job %d (%s)", job.fieldId, job.id, job.jobType)
        return true
    end

    local jobType = job.jobType
    local fieldState = field:getFieldState()
    local ok = true

    if jobType == "harvest" or jobType == "mow" then
        ok = prepareStandingCrop(job, field)
    elseif TCFieldPreparation.GROUND_TYPE_BY_JOB_TYPE[jobType] ~= nil then
        ok = prepareGround(job, field)
    elseif jobType == "tedder" or jobType == "bale" then
        local fruitTypeIndex = getJobFruitTypeIndex(job)
        local fillTypeIndex = TCFieldPreparation.getJobWindrowFillType(job)
        if fruitTypeIndex == nil or fillTypeIndex == nil then
            TCLog.warning("TheContractor: job %d has no resolvable crop/windrow, can't prepare field %d", job.id,
                job.fieldId)
            return false
        end
        prepareCutCrop(field, fruitTypeIndex)
        spawnWindrow(job, field, fruitTypeIndex, fillTypeIndex)
    elseif jobType == "baleWrap" then
        prepareCutCrop(field, FruitType.GRASS)
        spawnBales(job, field, getWrapBaleIndex(job), FruitType.GRASS, FillType.GRASS_WINDROW, field:getOwner())
    elseif jobType == "strawDelivery" then
        local fruitTypeIndex = job:getFruitTypeIndex()
        if TheContractorJobGeneration.getStrawFillType(fruitTypeIndex) == nil then
            TCLog.warning("TheContractor: job %d has no straw crop, can't prepare field %d", job.id, job.fieldId)
            return false
        end
        prepareCutCrop(field, fruitTypeIndex)
        spawnBales(job, field, TCFieldPreparation.getStrawBaleIndex(), fruitTypeIndex, FillType.STRAW, job.farmId)
    elseif jobType == "fertilize" then
        fieldState.sprayType = FieldSprayType.NONE
        fieldState.sprayLevel = job.startState or fieldState.sprayLevel
        applyFieldState(field, fieldState)
    elseif jobType == "herbicide" then
        fieldState.weedState = job.startState or fieldState.weedState
        applyFieldState(field, fieldState)
    elseif jobType == "weed" or jobType == "hoe" then
        if job.startState ~= nil and job.startState > 0 then
            fieldState.weedState = TCFieldPreparation.getVisibleWeedState(g_currentMission.weedSystem,
                job.startState, jobType == "hoe") or job.startState
        end
        applyFieldState(field, fieldState)
        job.workTotal = measureWeedArea(field)
    elseif jobType == "stonePick" then
        fieldState.fruitTypeIndex = FruitType.UNKNOWN
        fieldState.growthState = 0
        fieldState.groundType = FieldGroundType.PLOWED
        fieldState.stoneLevel = TCFieldPreparation.STONE_LEVEL
        applyFieldState(field, fieldState)
    else
        return false
    end

    TCLog.info("TheContractor: prepared field %d for job %d (%s)", job.fieldId, job.id, jobType)
    return ok
end

-- Whether a job's field is still being laid out (windrow/bale spawning) -
-- its progress can't be measured yet.
function TCFieldPreparation.isPreparing(job)
    return spawningJobIds[job.id] ~= nil
end

-- Server-only. What vanilla's missions clear away once they're done
-- (BaleMission/BaleWrapMission:finishField): the bales. Spawned bales for a
-- bale wrap job or a straw delivery (whatever of a delivery's wasn't
-- delivered, wherever it is); for a baling job, the bales our baler left
-- on the field - ours, of the job's crop, lying on the job's farmland. The
-- client keeps the crop, the same way harvest jobs' grain is carted away
-- (TCHaulage). Called on completion and on a miss alike, and (075) when an
-- offer is declined or runs out, which takes a fly-tipped pile away again.
function TCFieldPreparation.clearUpAfterJob(job)
    if not g_currentMission:getIsServer() then
        return
    end

    spawningJobIds[job.id] = nil
    deleteSpawnedBales(job)
    deleteDebris(job)
    if job.jobType == "bale" then
        TCFieldPreparation.removeBaledCrop(job)
    end
end

-- bale -> baler for every finished bale a baler still holds (a square
-- baler's chute, a round baler's chamber), wherever the baler is. A square
-- one's is on a joint, not mounted, so it would otherwise pass for a bale
-- on the ground, and deleting it under the baler breaks the baler.
function TCFieldPreparation.getBalesInBalers()
    local held = {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        local spec = vehicle.spec_baler
        if spec ~= nil and spec.bales ~= nil then
            for _, entry in ipairs(spec.bales) do
                if entry.baleObject ~= nil then
                    held[entry.baleObject] = vehicle
                end
            end
        end
    end
    return held
end

local function isInBaler(baler, bale)
    local spec = baler.spec_baler
    if baler.isDeleted or spec == nil or spec.bales == nil then
        return false
    end
    for _, entry in ipairs(spec.bales) do
        if entry.baleObject == bale then
            return true
        end
    end
    return false
end

-- Server-only: the job's bales held in our farm's balers on its farmland
-- are left in place, so the baler keeps working, and deleted once dropped.
local function markHeldBales(job, farmland, fillTypeIndex, held)
    local count = 0
    for bale, baler in pairs(held) do
        if baler.rootNode ~= nil and baler:getOwnerFarmId() == job.farmId and
                bale:getFillType() == fillTypeIndex then
            local x, _, z = getWorldTranslation(baler.rootNode)
            if g_farmlandManager:getFarmlandIdAtWorldPosition(x, z) == farmland.id then
                balesToDeleteOnDrop[bale] = baler
                count = count + 1
            end
        end
    end
    return count
end

-- Server-only, every frame: deletes each marked bale its baler has let go.
local function deleteDroppedBales()
    for bale, baler in pairs(balesToDeleteOnDrop) do
        if not isInBaler(baler, bale) then
            balesToDeleteOnDrop[bale] = nil
            if not bale.isDeleted then
                bale:delete()
            end
        end
    end
end

-- Server-only. Run when a bale job completes and again when it's cleared
-- up (the end of a player's grace period, 076), so bales baled during the
-- grace period go at its end. The player can still bale what's left on
-- the ground in between, and those bales go when the grace period ends.
function TCFieldPreparation.removeBaledCrop(job)
    local field = g_fieldManager:getFieldById(job.fieldId)
    local farmland = field ~= nil and field:getFarmland() or nil
    local fillTypeIndex = TCFieldPreparation.getJobWindrowFillType(job)
    if farmland == nil or fillTypeIndex == nil then
        return
    end

    local held = TCFieldPreparation.getBalesInBalers()
    local heldCount = markHeldBales(job, farmland, fillTypeIndex, held)

    local toDelete = {}
    for _, entry in pairs(g_currentMission.itemSystem.itemsToSave) do
        local bale = entry.item
        if held[bale] == nil and bale.isa ~= nil and bale:isa(Bale) and bale:getOwnerFarmId() == job.farmId and
            bale:getFillType() == fillTypeIndex and not bale:getIsMounted() then
            local x, _, z = getWorldTranslation(bale.nodeId)
            if g_farmlandManager:getFarmlandIdAtWorldPosition(x, z) == farmland.id then
                table.insert(toDelete, bale)
            end
        end
    end
    for _, bale in ipairs(toDelete) do
        bale:delete()
    end
    if #toDelete > 0 or heldCount > 0 then
        TCLog.info("TheContractor: job %d handed over %d bales on field %d, and %d still in a baler", job.id,
            #toDelete, job.fieldId, heldCount)
    end
end

-- Server-only. 076: a player-driven job's grace period is starting. A bale
-- job's bales so far go now, the rest at the end (clearUpAfterJob).
function TCFieldPreparation.clearUpAtCompletion(job)
    if not g_currentMission:getIsServer() then
        return
    end
    if job.jobType == "bale" then
        TCFieldPreparation.removeBaledCrop(job)
    end
end

-- Server-only, first update after a load: a field whose windrow/bales were
-- still being laid out when the game was saved gets laid out again.
local function resumeAfterLoad()
    local tc = g_currentMission.TheContractor
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            local jobDef = getJobDef(job)
            if jobDef ~= nil and (job.jobType == "tedder" or job.jobType == "bale" or job.jobType == "baleWrap" or
                    job.jobType == "strawDelivery") and
                job.workTotal == nil and (job.state == TheContractorJob.STATE.ALLOCATED or
                    job.state == TheContractorJob.STATE.IN_PROGRESS) then
                TCLog.info("TheContractor: job %d field %d wasn't finished being laid out, preparing it again",
                    job.id, job.fieldId)
                TCFieldPreparation.prepareFieldForJob(job)
            end
        end
    end
end

-- Server-only, called every frame from TheContractor:update.
function TCFieldPreparation.update(dt)
    if not g_currentMission:getIsServer() then
        return
    end
    deleteDroppedBales()
    if hasResumedAfterLoad then
        return
    end
    hasResumedAfterLoad = true
    resumeAfterLoad()
end
