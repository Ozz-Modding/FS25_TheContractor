-- Manual Attach (FS25_manualAttach, Wopster) compatibility, and the only
-- place this mod touches its globals.
--
-- Manual Attach makes a player connect an implement's PTO and hoses by hand:
-- its specializations listen for onPostAttach and pull the PTO and hoses off
-- again straight after any hitch that isn't made with the AI already
-- running. Our job-site rigging (TCJobSiteSetup) hitches before the worker's
-- AI starts, so without this a job's cultivator went out on the hitch with
-- no hoses, and couldn't unfold (Manual Attach refuses folding, lowering and
-- turning on without them).
--
-- After each job hitch the server connects them again through Manual
-- Attach's own attach functions, which send its own events, so every client
-- connects them too (VehicleAttachEvent goes out first on the same
-- connection, so a client's own disconnect has already happened).

TCManualAttach = {}

TCManualAttach.MOD_NAME = "FS25_manualAttach"

-- Manual Attach's environment, or nil when it isn't loaded or isn't the
-- version this was written against.
local function getEnv()
    local env = TheContractorDrivers.getModEnv(TCManualAttach.MOD_NAME)
    if env == nil or env.g_manualAttach == nil or env.ConnectionHosesExtension == nil or
        env.PowerTakeOffExtension == nil then
        return nil
    end
    local manualAttach = env.g_manualAttach
    if manualAttach.attachConnectionHoses == nil or manualAttach.attachPowerTakeOff == nil or
        env.ConnectionHosesExtension.hasConnectionHoses == nil or
        env.ConnectionHosesExtension.hasAttachedConnectionHoses == nil or
        env.PowerTakeOffExtension.hasPowerTakeOffs == nil or
        env.PowerTakeOffExtension.hasAttachedPowerTakeOffs == nil then
        return nil
    end
    return env
end

-- Server-only. Connects the PTO and hoses Manual Attach left off after
-- `attacher` hitched `implement`, as a player would by hand. Does nothing
-- without Manual Attach. Returns how many connections it made (0-2).
function TCManualAttach.connectAll(attacher, implement)
    local env = getEnv()
    if env == nil or attacher == nil or implement == nil then
        return 0
    end
    local manualAttach = env.g_manualAttach
    local hoses = env.ConnectionHosesExtension
    local pto = env.PowerTakeOffExtension

    local connected = 0
    if pto.hasPowerTakeOffs(implement, attacher) and not pto.hasAttachedPowerTakeOffs(implement, attacher) then
        manualAttach:attachPowerTakeOff(attacher, implement)
        connected = connected + 1
    end
    if hoses.hasConnectionHoses(implement, attacher) and not hoses.hasAttachedConnectionHoses(implement) then
        manualAttach:attachConnectionHoses(attacher, implement)
        connected = connected + 1
    end

    if connected > 0 then
        TCLog.info("TheContractor: Manual Attach - connected %d of PTO/hoses on '%s'", connected, implement:getName())
    end
    return connected
end
