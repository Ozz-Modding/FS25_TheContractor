-- Courseplay hooks for 037's staff drivers (see TheContractorDrivers).
-- Installed only if FS25_Courseplay is loaded, and the only place this mod
-- touches Courseplay's globals. Against Courseplay 8.1.0.3 (refs/).
--
-- Every CP worker is a vanilla AIJob subclass (CpAIJob), and every way a
-- player starts one - CP's HUD button and keybinds (cpStartStopDriver), its
-- gamepad HUD screen, its course-generator map page, and vanilla's map
-- "Create job" tab with a CP job type picked - ends the same way on the
-- client: AIJobStartRequestEvent sent to the server. So the client gate
-- sits there, on the one send, instead of on each of those paths (several
-- are spec functions copied into vehicle types at registration, which
-- can't simply be wrapped). Only CpAIJob starts are gated; vanilla AI
-- Helper starts are out of scope. The server side (refusal, wage) is
-- TheContractorDrivers.onAISystemStartJob, shared with AutoDrive's
-- hand-offs to vanilla AI jobs.

TCCourseplay = {}

TCCourseplay.MOD_NAME = "FS25_Courseplay"

local env = nil

-- Called every loadMap; returns whether Courseplay is loaded. The wrap
-- goes on a base-game class, so it's flagged there (not here) and installed
-- once per game session, calling through to whatever TCCourseplay is
-- current.
function TCCourseplay.install()
    env = TheContractorDrivers.getModEnv(TCCourseplay.MOD_NAME)
    if env == nil or env.CpAIJob == nil then
        env = nil
        return false
    end

    if not Connection.tcDriverHookInstalled then
        Connection.sendEvent = Utils.overwrittenFunction(Connection.sendEvent, function(...)
            return TCCourseplay.onSendEvent(...)
        end)
        Connection.tcDriverHookInstalled = true
    end

    Logging.info("TheContractor: Courseplay found - staff driver hooks installed")
    return true
end

function TCCourseplay.isCpJob(job)
    local cpAIJob = env ~= nil and env.CpAIJob or nil
    return cpAIJob ~= nil and job ~= nil and job.is_a ~= nil and job:is_a(cpAIJob)
end

local function isCpStartRequest(connection, event)
    return event ~= nil and event.job ~= nil and g_client ~= nil and connection == g_client:getServerConnection() and
        event.isa ~= nil and event:isa(AIJobStartRequestEvent) and TCCourseplay.isCpJob(event.job)
end

-- Client gate: holds a CP start request back until a driver's picked, then
-- sends it as it was.
function TCCourseplay.onSendEvent(connection, superFunc, event, deleteEvent, force)
    if isCpStartRequest(connection, event) then
        local drivers = TheContractorDrivers.getInstance()
        local vehicle = TheContractorDrivers.getAIJobVehicle(event.job)
        if drivers ~= nil and vehicle ~= nil then
            local handled = drivers:gateClientStart(vehicle, function()
                superFunc(connection, event, deleteEvent, force)
            end)
            if handled then
                return
            end
        end
    end

    return superFunc(connection, event, deleteEvent, force)
end
