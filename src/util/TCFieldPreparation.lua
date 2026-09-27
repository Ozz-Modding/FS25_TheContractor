-- Forces a job's field into a state its job can actually be worked from,
-- the moment the job is allocated (018) - whoever's operating. A job we've
-- offered MUST be doable: fields move on between offer and allocation
-- (NPC fieldwork, growth, the player's own changes), and a field that
-- already looks "done" for the job's type would otherwise read as 100%
-- complete on 019's very first progress scan and pay out for nothing.
--
-- Same FieldUpdateTask shapes vanilla's own FieldManager NPC actions use
-- (FieldManager:plowField/cultivateField/sowField), just aimed at the state
-- *before* the job's work rather than after it. Applied immediately
-- (addFieldUpdateTask's `immediate` path), not queued across frames, so
-- there's no window where a progress scan could read the old state.
-- Density-map changes are replicated to clients by the engine itself.

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

-- Server-only. Returns false (and logs) if the field or, for harvest, the
-- job's crop can't be resolved - the caller still allocates, since a
-- best-effort job beats a silently stuck allocation.
function TCFieldPreparation.prepareFieldForJob(job)
    if not g_currentMission:getIsServer() then
        return false
    end

    local field = g_fieldManager:getFieldById(job.fieldId)
    if field == nil then
        Logging.warning("TheContractor: job %d field %d not found, can't prepare it", job.id, job.fieldId)
        return false
    end

    local task = FieldUpdateTask.new()
    task:setField(field)
    task:setWeedState(0)
    task:setGroundAngle(field:getAngle())
    task:clearHeight()

    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef ~= nil and jobDef.cropDependent then
        local fruitTypeIndex = job:getFruitTypeIndex()
        local fruitType = fruitTypeIndex ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex) or nil
        if fruitType == nil then
            Logging.warning("TheContractor: job %d has no resolvable crop, can't prepare field %d for harvest", job.id,
                job.fieldId)
            return false
        end
        task:setFruit(fruitTypeIndex, fruitType:getMinHarvestingGrowthState())
        task:setGroundType(fruitType:getDefaultSowingGroundType())
    else
        local groundType = TCFieldPreparation.GROUND_TYPE_BY_JOB_TYPE[job.jobType]
        if groundType == nil then
            return false
        end
        task:setFruit(FruitType.UNKNOWN, 0)
        task:setStoneLevel(0)
        task:setGroundType(groundType)
    end

    g_fieldManager:addFieldUpdateTask(task, true)

    Logging.info("TheContractor: prepared field %d for job %d (%s)", job.fieldId, job.id, job.jobType)
    return true
end
