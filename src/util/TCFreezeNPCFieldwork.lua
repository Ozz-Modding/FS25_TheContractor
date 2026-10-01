-- Keeps vanilla's NPC fieldwork off fields with a live contractor job (034).
-- Once per period FieldManager queues every unowned field and runs
-- updateField on each, which may harvest, cultivate, plow, sow, fertilize
-- or weed it via queued FieldUpdateTasks. The only fields it leaves alone
-- are ones with a started vanilla mission, which our jobs never are - so
-- left unpatched an NPC could clear a contract field before the contractor
-- gets there. Live means any non-terminal job, offers included, for any
-- farm (see TheContractorJobs:isFieldProtected); once the job ends the
-- field is back in the next period's NPC pass.
--
-- Two class-level hooks (FieldManager is a shared class, same as
-- DisableVanillaContracts.lua's MissionManager patch):
-- - updateField: skips the NPC decision itself, so nothing gets queued.
-- - update: drops NPC tasks queued before the job existed (e.g. earlier in
--   the same period's pass) before vanilla starts them. Our own field
--   preparation (TCFieldPreparation) applies its tasks immediately, so it
--   never sits in this queue.
-- Both only matter on the server - vanilla's FieldManager:update already
-- only runs NPC work when g_server ~= nil.

TCFreezeNPCFieldwork = {}

local function isProtected(field)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    if tc == nil or tc.Jobs == nil or field == nil then
        return false
    end

    local fieldId = field:getId()
    return fieldId ~= nil and tc.Jobs:isFieldProtected(fieldId)
end

function TCFreezeNPCFieldwork.updateField(fieldManager, superFunc, field)
    if isProtected(field) then
        fieldManager:logNPCAction("TheContractor: Skipped NPC update for field '%s' (contractor job)",
            field:getName())
        return
    end

    return superFunc(fieldManager, field)
end

function TCFreezeNPCFieldwork.update(fieldManager, superFunc, dt)
    if g_server ~= nil and fieldManager.currentUpdateTask == nil and fieldManager.updateTasks ~= nil then
        while #fieldManager.updateTasks > 0 do
            local task = fieldManager.updateTasks[1]
            local field = task.getField ~= nil and task:getField() or nil
            if not isProtected(field) then
                break
            end

            table.remove(fieldManager.updateTasks, 1)
            -- Keeps vanilla's per-field pending-task count straight, same as
            -- its own setPendingFieldUpdates does when it drops a task.
            fieldManager:onFinishFieldUpdateTask(task)
            fieldManager:logNPCAction("TheContractor: Dropped queued NPC task for field '%s' (contractor job)",
                field:getName())
        end
    end

    return superFunc(fieldManager, dt)
end

FieldManager.updateField = Utils.overwrittenFunction(FieldManager.updateField, TCFreezeNPCFieldwork.updateField)
FieldManager.update = Utils.overwrittenFunction(FieldManager.update, TCFreezeNPCFieldwork.update)
