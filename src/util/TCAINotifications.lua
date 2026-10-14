-- Vanilla AI helper notifications for our workers. Contract jobs run on
-- vanilla AI jobs, which announce themselves as "AI Worker B has finished
-- the job" and the like. For a contract job those notifications are
-- dropped: the mod reports its own jobs. For a staff driver the player
-- started (037) they stay, under the worker's name instead of the helper's.
--
-- Two vanilla paths raise them, on every machine:
-- - AIJob:stop -> AIJob:showNotification, the message text built from
--   AIJob:getHelperName (also the map's list of running helpers).
-- - AIJobVehicle:aiBlock, "blocked by an object", from the vehicle's
--   current helper.
--
-- Who's driving is worked out when the AI job starts (AIJob:start runs on
-- every machine) and kept on the job, since by the time it stops a
-- finished contract job may no longer list the vehicle. A job that wasn't
-- matched then is tried again when it notifies.
--
-- AutoDrive doesn't use AI jobs, so its own messages aren't affected.

TCAINotifications = {}

function TCAINotifications.getVehicle(aiJob)
    local parameter = aiJob.vehicleParameter
    if parameter == nil or parameter.getVehicle == nil then
        return nil
    end
    return parameter:getVehicle()
end

-- Notes the AI job's worker on it, if it has one and it hasn't been noted.
function TCAINotifications.tag(aiJob)
    if aiJob.tcWorkerId ~= nil then
        return
    end
    local vehicle = TCAINotifications.getVehicle(aiJob)
    if vehicle == nil then
        return
    end
    local worker, isContract = TCWorkerAppearance.getWorkerOnVehicle(vehicle)
    if worker == nil then
        return
    end
    aiJob.tcFarmId = worker.farmId
    aiJob.tcWorkerId = worker.id
    aiJob.tcWorkerName = worker.name
    aiJob.tcIsContract = isContract == true
end

-- The worker's name now (they may have been renamed mid-job, 066), or the
-- one noted at the start if they've left since. nil if it isn't ours.
function TCAINotifications.getWorkerName(aiJob)
    if aiJob.tcWorkerId == nil then
        return nil
    end
    local staff = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.Staff or nil
    local worker = staff ~= nil and staff:getWorker(aiJob.tcFarmId, aiJob.tcWorkerId) or nil
    return worker ~= nil and worker.name or aiJob.tcWorkerName
end

-- Hooks -------------------------------------------------------------------------

-- Fresh each start: the player's own AI job object can be started again
-- later with another driver, or none.
function TCAINotifications.onJobStart(aiJob, farmId)
    aiJob.tcFarmId = nil
    aiJob.tcWorkerId = nil
    aiJob.tcWorkerName = nil
    aiJob.tcIsContract = nil
    TCAINotifications.tag(aiJob)
end

function TCAINotifications.getHelperName(aiJob, superFunc)
    return TCAINotifications.getWorkerName(aiJob) or superFunc(aiJob)
end

function TCAINotifications.showNotification(aiJob, superFunc, aiMessage)
    TCAINotifications.tag(aiJob)
    if aiJob.tcIsContract then
        return
    end
    return superFunc(aiJob, aiMessage)
end

-- Vanilla's aiBlock, with the notification dropped for a contract job and
-- under the worker's name for a staff driver. The AI event is raised
-- either way.
function TCAINotifications.aiBlock(vehicle, superFunc)
    local worker, isContract = TCWorkerAppearance.getWorkerOnVehicle(vehicle)
    if worker == nil then
        return superFunc(vehicle)
    end

    if not isContract and vehicle.isClient and g_localPlayer ~= nil and
            g_localPlayer.farmId == vehicle:getAIJobFarmId() then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            string.format(g_i18n:getText("ai_messageErrorBlockedByObject"), worker.name))
    end
    vehicle:raiseAIEvent("onAIJobVehicleBlock", "onAIImplementJobVehicleBlock")
end

-- At module scope, guarded so they can't stack. AIJob subclasses find these
-- through their metatables, and vehicle types pick up AIJobVehicle's
-- functions when they're finalized, after mods' sources run.
if not AIJob.tcNotificationHooksInstalled then
    AIJob.start = Utils.appendedFunction(AIJob.start, TCAINotifications.onJobStart)
    AIJob.getHelperName = Utils.overwrittenFunction(AIJob.getHelperName, TCAINotifications.getHelperName)
    AIJob.showNotification = Utils.overwrittenFunction(AIJob.showNotification, TCAINotifications.showNotification)
    AIJob.tcNotificationHooksInstalled = true
end
if not AIJobVehicle.tcNotificationHooksInstalled then
    AIJobVehicle.aiBlock = Utils.overwrittenFunction(AIJobVehicle.aiBlock, TCAINotifications.aiBlock)
    AIJobVehicle.tcNotificationHooksInstalled = true
end
