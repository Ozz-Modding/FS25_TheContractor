-- Courseplay hooks for 037's staff drivers (see TheContractorDrivers).
-- Installed only if FS25_Courseplay is loaded, and the only place this mod
-- touches Courseplay's globals. Against Courseplay 8.1.0.3 (refs/).
--
-- Every CP worker is a vanilla AIJob subclass (CpAIJob), and every way a
-- player starts one - CP's HUD button and keybinds (cpStartStopDriver), its
-- gamepad HUD screen, its course-generator map page, and vanilla's map
-- "Create job" tab with a CP job type picked - ends the same way on the
-- client: AIJobStartRequestEvent sent to the server. That's the same send a
-- vanilla AI Helper start goes through, so CP needs no gate of its own:
-- TheContractorDrivers.onSendEvent (client) and onAISystemStartJob (server)
-- cover both. All that's left here is telling a CP job apart, for logging.

TCCourseplay = {}

TCCourseplay.MOD_NAME = "FS25_Courseplay"

local env = nil

-- Called every loadMap; returns whether Courseplay is loaded.
function TCCourseplay.install()
    env = TheContractorDrivers.getModEnv(TCCourseplay.MOD_NAME)
    if env == nil or env.CpAIJob == nil then
        env = nil
        return false
    end

    Logging.info("TheContractor: Courseplay found")
    return true
end

function TCCourseplay.isCpJob(job)
    local cpAIJob = env ~= nil and env.CpAIJob or nil
    return cpAIJob ~= nil and job ~= nil and job.is_a ~= nil and job:is_a(cpAIJob)
end
