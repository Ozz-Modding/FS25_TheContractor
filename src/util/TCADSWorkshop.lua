-- FS25_AdvancedDamageSystem's own-workshop staff (090). With its "Own
-- Workshop: Staff via Contractor" setting on, ADS pauses its own workshop
-- roster and takes the people in each role from us, through its staff
-- provider API (ADS_OwnWorkshop.registerStaffProvider, API version 1).
--
-- We register on every machine each loadMap (ADS drops the provider at
-- mission end). ADS calls getAssignments on the server only: once at
-- registration, every second per farm, and whenever we call refresh. It
-- syncs the result to clients itself and never saves it. Each role holds
-- one person, and each person at most one role; only "available" counts as
-- present. The office administrator (TheContractorOffice) is the
-- receptionist, and workers ticked into the workshop (091,
-- TheContractorWorkshop) fill the trades: mechanic, diagnostician,
-- bodyworker and storekeeper (098).
--
-- The entry points are looked up once per loadMap (detect), the
-- TCADSStock way: anything missing or a different API version leaves us
-- disconnected, with one warning. Checked against FS25_AdvancedDamageSystem
-- 0.10.0.6 (commit 2901e04). getStaffActivity (whether a trade is busy on a
-- job now) came later, so it's optional: without it nobody shows as in the
-- workshop.

TCADSWorkshop = {}

TCADSWorkshop.MOD_NAME = "FS25_AdvancedDamageSystem"
TCADSWorkshop.PROVIDER_ID = "theContractor"
TCADSWorkshop.API_VERSION = 1

-- ADS's equipment a storekeeper needs (its REQUIRES_EQUIPMENT).
TCADSWorkshop.PARTS_STORAGE = "partsStorage"

-- ADS_OwnWorkshop, while it has everything we need; nil otherwise.
local api = nil
local warned = {}

local function warnOnce(key, text, ...)
    if not warned[key] then
        warned[key] = true
        TCLog.warning("TheContractor: " .. text, ...)
    end
end

-- The ADS mod environment, or nil when it isn't loaded. A function so the
-- tests can swap it.
function TCADSWorkshop.getEnv()
    return TheContractorDrivers.getModEnv(TCADSWorkshop.MOD_NAME)
end

-- Called every loadMap.
function TCADSWorkshop.detect()
    api = nil

    local env = TCADSWorkshop.getEnv()
    if env == nil then
        return
    end

    local workshop = env.ADS_OwnWorkshop
    if type(workshop) ~= "table" or type(workshop.registerStaffProvider) ~= "function" or
            type(workshop.refreshStaffProvider) ~= "function" or
            type(workshop.isContractorStaffEnabled) ~= "function" then
        warnOnce("missing", "%s has no workshop staff provider API - its own workshop can't use our staff",
            TCADSWorkshop.MOD_NAME)
        return
    end
    if workshop.STAFF_API_VERSION ~= TCADSWorkshop.API_VERSION then
        warnOnce("version", "%s's workshop staff API is version %s, we know version %d - its own workshop can't use our staff",
            TCADSWorkshop.MOD_NAME, tostring(workshop.STAFF_API_VERSION), TCADSWorkshop.API_VERSION)
        return
    end
    api = workshop
end

-- ADS is loaded with an API we can use.
function TCADSWorkshop.isAvailable()
    return api ~= nil
end

-- ADS is taking its workshop staff from us: its setting is on (read live,
-- ADS syncs it).
function TCADSWorkshop.isActive()
    return api ~= nil and api.isContractorStaffEnabled() == true
end

-- Whether a worker ticked into a trade is busy on an ADS workshop job right
-- now (in the building or out with the mobile workshop). ADS syncs it, so
-- it's the same on every machine.
function TCADSWorkshop.isWorking(worker)
    if worker.workshopRole == nil or worker.farmId == nil or not TCADSWorkshop.isActive() or
            type(api.getStaffActivity) ~= "function" then
        return false
    end
    return api.getStaffActivity(worker.farmId, worker.workshopRole) ~= nil
end

-- Every machine, after our save has loaded.
function TCADSWorkshop.register()
    if api == nil then
        return
    end
    local ok, reason = api.registerStaffProvider(TCADSWorkshop.PROVIDER_ID, {
        version = TCADSWorkshop.API_VERSION,
        getAssignments = TCADSWorkshop.getAssignments,
        openStaffMenu = TCADSWorkshop.openStaffMenu,
    })
    if not ok then
        TCLog.warning("TheContractor: %s refused our workshop staff: %s", TCADSWorkshop.MOD_NAME, tostring(reason))
    end
end

-- Server: have ADS read a farm again now, rather than on its next poll.
function TCADSWorkshop.refresh(farmId)
    if api == nil or g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    api.refreshStaffProvider(farmId)
end

-- The roster ADS asks for (server). Pure apart from reading our state.
function TCADSWorkshop.getAssignments(farmId)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    if tc == nil or tc.Office == nil then
        return nil
    end
    local workers = tc.Staff ~= nil and tc.Staff:getRoster(farmId) or {}
    return TCADSWorkshop.buildAssignments(tc.Office:getMembers(farmId), workers)
end

-- { [ADS role] = { id, name, level, status } } for the given office staff
-- and roster workers (091: those ticked into a trade they have; the lowest
-- id wins should two ever claim one role).
function TCADSWorkshop.buildAssignments(members, workers)
    local assignments = {}
    local ticked = {}
    for _, worker in ipairs(workers or {}) do
        if worker.workshopRole ~= nil and TheContractorWorkshop.getLevel(worker, worker.workshopRole) > 0 then
            table.insert(ticked, worker)
        end
    end
    table.sort(ticked, function(a, b)
        return a.id < b.id
    end)
    for _, worker in ipairs(ticked) do
        if assignments[worker.workshopRole] == nil then
            assignments[worker.workshopRole] = {
                id = worker.id,
                name = worker.name,
                level = TheContractorWorkshop.getLevel(worker, worker.workshopRole),
                status = TheContractorWorkshop.getADSStatus(worker),
            }
        end
    end
    for _, member in ipairs(members) do
        local definition = TheContractorOffice.getDefinition(member.role)
        if definition ~= nil and definition.adsRole ~= nil then
            -- 097: ADS has no "at home"; it's away all the same.
            local status = TheContractorOffice.getStatus(member)
            -- 172: nor the show's day off.
            if status == TheContractorOffice.STATUS.AT_HOME or status == TheContractorOffice.STATUS.SHOW then
                status = TheContractorWorkshop.ADS_STATUS.UNAVAILABLE
            end
            assignments[definition.adsRole] = {
                id = member.id,
                name = member.name,
                level = member.level,
                status = status,
            }
        end
    end
    return assignments
end

-- ADS's workshop card's "Hire"/"Manage employee" (local client): the
-- Staff tab, on that role's row. Its management summary's "Contractor
-- staff" button passes no role or worker: the roster, nothing selected.
function TCADSWorkshop.openStaffMenu(farmId, adsRole, workerId)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    local menu = tc ~= nil and tc.MenuContractor or nil
    if menu == nil then
        return false
    end
    for role, definition in pairs(TheContractorOffice.ROLES) do
        if definition.adsRole == adsRole then
            menu:openOfficeRow(role)
            return true
        end
    end
    -- 091: a trade - the worker in it, if anyone.
    menu:openOfficeRow(nil, tonumber(workerId))
    return true
end

-- Whether the farm's ADS workshop has the parts storage a storekeeper
-- needs, or nil if ADS can't tell us.
function TCADSWorkshop.hasPartsStorage(farmId)
    if api == nil or type(api.getRecord) ~= "function" or type(api.hasEquipment) ~= "function" then
        return nil
    end
    local record = api.getRecord(farmId)
    if record == nil then
        return nil
    end
    return api.hasEquipment(record, TCADSWorkshop.PARTS_STORAGE) == true
end

-- One line for tcCompany office.
function TCADSWorkshop.describe(farmId)
    if TCADSWorkshop.getEnv() == nil then
        return "ADS workshop: not loaded"
    end
    if api == nil then
        return "ADS workshop: no usable staff provider API"
    end
    if not TCADSWorkshop.isActive() then
        return "ADS workshop: its Staff via Contractor setting is off"
    end
    local state = "?"
    if type(api.getStaffProviderInfo) == "function" then
        local info = api.getStaffProviderInfo(farmId)
        state = info ~= nil and tostring(info.providerId) .. " " .. tostring(info.state) or state
    end
    return "ADS workshop: taking our staff (" .. state .. ")"
end
