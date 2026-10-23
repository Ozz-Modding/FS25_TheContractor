-- Follow Me hooks for 037's staff drivers (see TheContractorDrivers).
-- Installed only if FS25_FollowMe is loaded, and the only place this mod
-- touches Follow Me's globals. Against Follow Me 1.2.0.0 (refs/), which is
-- single-player only.
--
-- A follower is a vanilla AIJob subclass (AIJobFollowVehicle) on the
-- following vehicle, so the server side is already covered:
-- TheContractorDrivers.onAISystemStartJob refuses a start with no driver
-- and takes the wage off one that has. Follow Me starts it two ways:
--   - its H key/map "Create job" paths (getStartableAIJob) send
--     AIJobStartRequestEvent, gated by TheContractorDrivers.onSendEvent;
--   - its own "Initiate" action (right ctrl + F) picks a vehicle to follow,
--     then calls FollowVehicle:initiateFollowVehicle, which calls
--     g_currentMission.aiSystem:startJob directly. That's the client gate
--     wrapped here. It's a specialization function, copied from each
--     vehicle type's `functions` into every vehicle as it loads, so the
--     wrap goes on the types (vehicles load after loadMap), not the class.
-- The picker's assign event runs at once on single-player's local
-- connection, so the driver is bound before the held-back start goes on.

TCFollowMe = {}

TCFollowMe.MOD_NAME = "FS25_FollowMe"

local env = nil

-- Called every loadMap; returns whether Follow Me is loaded. Each vehicle
-- type is flagged once wrapped, so this can run on every load.
function TCFollowMe.install()
    env = TheContractorDrivers.getModEnv(TCFollowMe.MOD_NAME)
    if env == nil or env.AIJobFollowVehicle == nil or g_vehicleTypeManager == nil then
        env = nil
        return false
    end

    local count = 0
    for _, typeDef in pairs(g_vehicleTypeManager:getTypes()) do
        local functions = typeDef.functions
        if functions ~= nil and functions.initiateFollowVehicle ~= nil and not typeDef.tcFollowMeHookInstalled then
            local superFunc = functions.initiateFollowVehicle
            functions.initiateFollowVehicle = function(vehicle, ...)
                return TCFollowMe.onInitiate(vehicle, superFunc, ...)
            end
            typeDef.tcFollowMeHookInstalled = true
            count = count + 1
        end
    end

    Logging.info("TheContractor: Follow Me found - staff driver hooks installed on %d vehicle types", count)
    return true
end

function TCFollowMe.isFollowMeJob(job)
    local jobClass = env ~= nil and env.AIJobFollowVehicle or nil
    return jobClass ~= nil and job ~= nil and job.isa ~= nil and job:isa(jobClass)
end

-- Client gate for the Initiate action.
function TCFollowMe.onInitiate(vehicle, superFunc, vehicleToFollow, ...)
    local drivers = TheContractorDrivers.getInstance()
    if drivers ~= nil then
        local args = { ... }
        local handled = drivers:gateClientStart(vehicle, function()
            superFunc(vehicle, vehicleToFollow, unpack(args))
        end)
        if handled then
            return
        end
    end

    return superFunc(vehicle, vehicleToFollow, ...)
end
