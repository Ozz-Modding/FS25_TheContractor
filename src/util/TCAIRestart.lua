-- Vanilla restarts AI helpers after a load: AIFieldWorker saves #isActive,
-- and the vehicle's first onUpdate on the server builds a fresh fieldwork
-- job and sends an AIJobStartRequestEvent through the local client
-- connection, just as if the player had pressed the AI button.
--
-- For a contract job's vehicle that restart is unwanted. Dispatch's
-- resumeJobsAfterLoad brings the job back itself (staging, then its own AI
-- job), and the request would otherwise reach the staff-driver gate (037)
-- looking like a player start on an undriven vehicle, opening the driver
-- picker with no idle staff to offer (the job's worker isn't idle). So it's
-- dropped here. A staff driver's helper restarts as vanilla does: its saved
-- binding resolves in Drivers:getBinding and the gate lets it through.

TCAIRestart = {}

function TCAIRestart.onFieldWorkerUpdate(vehicle, superFunc, ...)
    local spec = vehicle.spec_aiFieldWorker
    if vehicle.isServer and spec ~= nil and spec.pendingAIFieldWorkerStart then
        -- getBinding resolves everything saved by uniqueId first, so the
        -- jobs' equipment ids are good on this first frame.
        local worker, isContract = TCWorkerAppearance.getWorkerOnVehicle(vehicle)
        if worker ~= nil and isContract then
            spec.pendingAIFieldWorkerStart = false
            TCLog.info("TheContractor: skipped vanilla's AI restart on '%s', its contract job resumes itself",
                vehicle:getFullName())
        end
    end
    return superFunc(vehicle, ...)
end

-- At module scope, guarded so it can't stack. Specialization event
-- listeners are looked up by name on the spec table each time they're
-- raised, so wrapping AIFieldWorker.onUpdate reaches every vehicle.
if not AIFieldWorker.tcRestartHookInstalled then
    AIFieldWorker.onUpdate = Utils.overwrittenFunction(AIFieldWorker.onUpdate, TCAIRestart.onFieldWorkerUpdate)
    AIFieldWorker.tcRestartHookInstalled = true
end
