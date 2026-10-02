-- AutoDrive & Courseplay staff drivers (037). While a farm has a company,
-- every vehicle driven by AutoDrive (AD) or Courseplay (CP) needs one of the
-- farm's staff behind the wheel: starting either one opens a picker
-- (TCDriverPickerDialog) for an idle worker, and a start that skips the
-- picker is stopped/refused here on the server. Without a company nothing
-- is intercepted - both mods behave exactly as they do without this one.
--
-- The driver belongs to the vehicle, not to an AD or CP session: a binding
-- is rootVehicle -> worker, and any AD/CP/AI start on a vehicle that
-- already has one just carries on with them, which is what keeps the same
-- driver through AD -> CP and CP -> AD -> CP hand-offs. It's only released
-- once the vehicle has had nothing driving it for RELEASE_GRACE_MS (real
-- time), long enough to cover the gap between one mod stopping and the
-- other starting in either order.
--
-- Staff already draw a salary (036), so a staff-driven vehicle pays no
-- AD/AI per-tick wage: TCAutoDrive zeroes AD's, and the AISystem:startJob
-- hook below gives CP's (and any AI job AD hands over to) the same
-- getPricePerMs override Dispatch's contract jobs use. Driving time adds up
-- across the whole chain and buys one small growth roll (030) on release.
--
-- Everything mod-specific lives in TCAutoDrive/TCCourseplay, each
-- installed only if its mod is loaded; this subsystem owns the bindings,
-- the release tick, growth, save/load and initial client state. Bindings
-- are server-authoritative and keyed by the root vehicle's network object
-- id on every machine (TCDriverBindingEvent keeps clients in step - the
-- client gates need to know whether a vehicle already has a driver).

TheContractorDrivers = {}
TheContractorDrivers_mt = Class(TheContractorDrivers)

TheContractorDrivers.RELEASE_GRACE_MS = 5000
-- A binding restored from a save gets longer before it's freed: AD's own
-- autostartHelpers (single-player) restarts saved drivers some time after
-- the game's up.
TheContractorDrivers.LOAD_RELEASE_GRACE_MS = 60000

-- One growth roll per stint, on release: chance DRIVER_GROWTH_CHANCE_PER_HOUR
-- x in-game hours driven, capped at DRIVER_GROWTH_MAX_CHANCE (a contract
-- job's roll is ~0.3), against the tier of the vehicle driven. Stints under
-- DRIVER_GROWTH_MIN_MINUTES in-game minutes don't roll.
TheContractorDrivers.DRIVER_GROWTH_CHANCE_PER_HOUR = 0.03
TheContractorDrivers.DRIVER_GROWTH_MAX_CHANCE = 0.15
TheContractorDrivers.DRIVER_GROWTH_MIN_MINUTES = 5

TheContractorDrivers.START = {
    ALLOWED = "allowed",
    NEEDS_DRIVER = "needsDriver",
    CONTRACTOR_EQUIPMENT = "contractorEquipment",
}

function TheContractorDrivers.new()
    local self = {}
    setmetatable(self, TheContractorDrivers_mt)

    -- vehicleId (root vehicle's network object id) -> { vehicleId, farmId,
    -- workerId, activeMs, idleMs, graceMs }. The timers are server-only.
    self.bindingsByVehicleId = {}
    -- Server: bindings read from the save, by vehicle uniqueId, waiting for
    -- vehicles to exist (see resolveLoadedBindings). Set to nil once done.
    self.loadedBindings = {}

    return self
end

function TheContractorDrivers.getInstance()
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    return tc ~= nil and tc.Drivers or nil
end

-- Hooks ---------------------------------------------------------------------

-- A loaded mod's own global environment (mods' globals live there, not in
-- ours - same way Courseplay reaches AutoDrive through FS25_AutoDrive), or
-- nil if it isn't loaded.
function TheContractorDrivers.getModEnv(modName)
    if g_modIsLoaded == nil or not g_modIsLoaded[modName] then
        return nil
    end
    return getfenv(0)[modName]
end

-- Called every loadMap. The hooks wrap other code's globals, so each is
-- flagged on the table it wraps and goes on once per game session; they
-- look the live subsystem up through getInstance.
function TheContractorDrivers.installHooks()
    local hasAutoDrive = TCAutoDrive.install()
    local hasCourseplay = TCCourseplay.install()

    if (hasAutoDrive or hasCourseplay) and not AISystem.tcDriverHookInstalled then
        AISystem.startJob = Utils.overwrittenFunction(AISystem.startJob, function(...)
            return TheContractorDrivers.onAISystemStartJob(...)
        end)
        AISystem.tcDriverHookInstalled = true
    end
end

-- Server, every AI job start: CP's own jobs, any vanilla AI job AD hands a
-- vehicle over to, and our own contract jobs (left alone). A CP job on a
-- vehicle that mustn't be driven is refused - the client gate should have
-- caught it, but anything that skips the picker ends up here. A job on a
-- vehicle with a staff driver pays no wage (and so never stops itself for
-- want of money, see AIJob:updateCost).
function TheContractorDrivers.onAISystemStartJob(aiSystem, superFunc, job, startFarmId)
    local drivers = TheContractorDrivers.getInstance()
    local vehicle = TheContractorDrivers.getAIJobVehicle(job)

    if drivers ~= nil and vehicle ~= nil and not g_currentMission.TheContractor.Dispatch:isOurAIJob(job) then
        if TCCourseplay.isCpJob(job) then
            local refusal = drivers:getServerStartRefusal(vehicle)
            if refusal ~= nil then
                Logging.info("TheContractor: refused Courseplay start on '%s' (%s)", vehicle:getFullName(), refusal)
                drivers:notify(vehicle:getOwnerFarmId(), refusal, vehicle)
                return
            end
        end

        if drivers:hasDriver(vehicle) then
            job.getPricePerMs = TheContractorDispatch.getNoWagePricePerMs
        end
    end

    return superFunc(aiSystem, job, startFarmId)
end

function TheContractorDrivers.getAIJobVehicle(job)
    if job == nil then
        return nil
    end
    if job.getVehicle ~= nil then
        local vehicle = job:getVehicle()
        if vehicle ~= nil then
            return vehicle
        end
    end
    if job.vehicleParameter ~= nil then
        return job.vehicleParameter:getVehicle()
    end
    return nil
end

-- Vehicles ------------------------------------------------------------------

local function getRootVehicle(vehicle)
    if vehicle ~= nil and vehicle.getRootVehicle ~= nil then
        return vehicle:getRootVehicle() or vehicle
    end
    return vehicle
end

-- The root vehicle and everything attached to it.
local function getVehicleChain(vehicle)
    local root = getRootVehicle(vehicle)
    if root.getChildVehicles ~= nil and root:getChildVehicles() ~= nil then
        return root:getChildVehicles()
    end
    return { root }
end

function TheContractorDrivers.getVehicleKey(vehicle)
    local root = getRootVehicle(vehicle)
    return root ~= nil and NetworkUtil.getObjectId(root) or nil
end

-- Whether anything is driving the vehicle: AD, or an AI job (CP's or
-- vanilla's).
function TheContractorDrivers.isVehicleDriven(vehicle)
    if TCAutoDrive.isDriving(vehicle) then
        return true
    end
    return vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive()
end

-- Out on a hired-worker contract job, or in its cooldown (TCVehicleLock):
-- hidden or locked, so never AD's or CP's, company or not.
function TheContractorDrivers.isContractorEquipment(vehicle)
    for _, chainVehicle in pairs(getVehicleChain(vehicle)) do
        if TCVehicleLock.isLocked(chainVehicle) then
            return true
        end
    end
    return false
end

-- The farm owning the vehicle runs a company, so AD/CP on it needs a
-- driver.
function TheContractorDrivers.isDriverRequired(vehicle)
    local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil
    return farmId ~= nil and g_currentMission.TheContractor.Company:hasCompany(farmId)
end

-- Size tier (009) of what was driven: the first tiered vehicle in the chain
-- (normally the tractor), nil if none is.
function TheContractorDrivers.getVehicleTier(vehicle)
    for _, chainVehicle in pairs(getVehicleChain(vehicle)) do
        local tier = TCEquipmentClass.getSizeTier(chainVehicle)
        if tier ~= nil then
            return tier
        end
    end
    return nil
end

-- Query API (every machine) ---------------------------------------------------

function TheContractorDrivers:getBinding(vehicle)
    self:resolveLoadedBindings()

    local vehicleId = vehicle ~= nil and TheContractorDrivers.getVehicleKey(vehicle) or nil
    if vehicleId == nil then
        return nil
    end
    return self.bindingsByVehicleId[vehicleId]
end

function TheContractorDrivers:hasDriver(vehicle)
    return self:getBinding(vehicle) ~= nil
end

-- The vehicle a DRIVING worker is out in, or nil.
function TheContractorDrivers:getVehicleDrivenBy(farmId, workerId)
    local worker = g_currentMission.TheContractor.Staff:getWorker(farmId, workerId)
    if worker == nil or worker.drivingVehicleId == nil then
        return nil
    end
    return NetworkUtil.getObject(worker.drivingVehicleId)
end

-- Whether AD/CP may start on this vehicle as things stand.
function TheContractorDrivers:getStartCheck(vehicle)
    if TheContractorDrivers.isContractorEquipment(vehicle) then
        return TheContractorDrivers.START.CONTRACTOR_EQUIPMENT
    end
    if TheContractorDrivers.isDriverRequired(vehicle) and not self:hasDriver(vehicle) then
        return TheContractorDrivers.START.NEEDS_DRIVER
    end
    return TheContractorDrivers.START.ALLOWED
end

-- l10n key to stop/refuse an AD/CP start with on the server, or nil if
-- it's fine.
function TheContractorDrivers:getServerStartRefusal(vehicle)
    local check = self:getStartCheck(vehicle)
    if check == TheContractorDrivers.START.CONTRACTOR_EQUIPMENT then
        return "tc_drivers_contractorEquipment"
    elseif check == TheContractorDrivers.START.NEEDS_DRIVER then
        return "tc_drivers_stoppedNoDriver"
    end
    return nil
end

-- Client gate, shared by every player start path (TCAutoDrive,
-- TCCourseplay). startFunc runs the original start. Returns true if it took
-- the start over - the picker runs startFunc once a driver's chosen (or
-- never, if cancelled) - and false if the caller should just go ahead.
function TheContractorDrivers:gateClientStart(vehicle, startFunc)
    local check = self:getStartCheck(vehicle)
    if check == TheContractorDrivers.START.ALLOWED then
        return false
    end

    if check == TheContractorDrivers.START.CONTRACTOR_EQUIPMENT then
        InfoDialog.show(g_i18n:getText("tc_drivers_contractorEquipmentDialog"))
        return true
    end

    TCDriverPickerDialog.show(getRootVehicle(vehicle), startFunc)
    return true
end

-- Assigning (server-authoritative) ------------------------------------------

-- nil if workerId can drive vehicle for farmId, else an l10n key.
function TheContractorDrivers:getAssignError(farmId, workerId, vehicle)
    if vehicle == nil or vehicle.getOwnerFarmId == nil or vehicle:getOwnerFarmId() ~= farmId then
        return "tc_drivers_notYourVehicle"
    end
    if not g_currentMission.TheContractor.Company:hasCompany(farmId) then
        return "tc_drivers_noCompany"
    end
    if TheContractorDrivers.isContractorEquipment(vehicle) then
        return "tc_drivers_contractorEquipment"
    end
    if self:hasDriver(vehicle) then
        return "tc_drivers_alreadyHasDriver"
    end
    local worker = g_currentMission.TheContractor.Staff:getWorker(farmId, workerId)
    if worker == nil or not worker:isIdle() then
        return "tc_drivers_workerUnavailable"
    end
    return nil
end

-- From TCAssignDriverEvent. The start the player asked for follows straight
-- behind it on the same connection, so the binding gets the usual grace to
-- see it arrive (and is freed if it never does, e.g. AD had nowhere to go).
function TheContractorDrivers:assignDriver(farmId, workerId, vehicle)
    if not g_currentMission:getIsServer() then
        return false
    end

    local errorKey = self:getAssignError(farmId, workerId, vehicle)
    if errorKey ~= nil then
        Logging.info("TheContractor: farm %d couldn't assign worker %d as a driver (%s)", farmId, workerId, errorKey)
        self:notify(farmId, errorKey, vehicle)
        return false
    end

    self:bindDriver(TheContractorDrivers.getVehicleKey(vehicle), farmId, workerId, 0,
        TheContractorDrivers.RELEASE_GRACE_MS)
    return true
end

function TheContractorDrivers:bindDriver(vehicleId, farmId, workerId, activeMs, graceMs)
    local binding = self:applyBindingSet(vehicleId, farmId, workerId)
    binding.activeMs = activeMs
    binding.idleMs = 0
    binding.graceMs = graceMs

    g_currentMission.TheContractor.Staff:setWorkerStatus(farmId, workerId, TheContractorWorker.STATUS.DRIVING)

    local vehicle = NetworkUtil.getObject(vehicleId)
    Logging.info("TheContractor: farm %d worker %d now driving '%s'", farmId, workerId,
        vehicle ~= nil and vehicle:getFullName() or tostring(vehicleId))

    if g_server ~= nil then
        g_server:broadcastEvent(TCDriverBindingEvent.new(vehicleId, farmId, workerId, true))
    end
end

-- Frees a vehicle's driver: back to idle (or off sick, if they fell ill on
-- the way - see TheContractorStaff:setWorkerStatus), after a growth roll
-- unless the vehicle's gone (sold/deleted, vehicle nil).
function TheContractorDrivers:releaseDriver(vehicleId, vehicle)
    local binding = self:applyBindingCleared(vehicleId)
    if binding == nil then
        return
    end

    if vehicle ~= nil then
        self:rollDrivingGrowth(binding, vehicle)
    end

    g_currentMission.TheContractor.Staff:setWorkerStatus(binding.farmId, binding.workerId,
        TheContractorWorker.STATUS.IDLE)

    Logging.info("TheContractor: farm %d worker %d finished driving (%.0f in-game min)", binding.farmId,
        binding.workerId, binding.activeMs / 60000)

    if g_server ~= nil then
        g_server:broadcastEvent(TCDriverBindingEvent.new(vehicleId, binding.farmId, binding.workerId, false))
    end
end

-- The actual state flips, run on whichever machine (server, or a client
-- receiving TCDriverBindingEvent/initial client state) is applying them.

function TheContractorDrivers:applyBindingSet(vehicleId, farmId, workerId)
    local binding = {
        vehicleId = vehicleId,
        farmId = farmId,
        workerId = workerId,
        activeMs = 0,
        idleMs = 0,
        graceMs = TheContractorDrivers.RELEASE_GRACE_MS,
    }
    self.bindingsByVehicleId[vehicleId] = binding

    local worker = g_currentMission.TheContractor.Staff:getWorker(farmId, workerId)
    if worker ~= nil then
        worker.drivingVehicleId = vehicleId
    end

    return binding
end

-- Returns the removed binding, or nil if there wasn't one.
function TheContractorDrivers:applyBindingCleared(vehicleId)
    local binding = self.bindingsByVehicleId[vehicleId]
    if binding == nil then
        return nil
    end

    self.bindingsByVehicleId[vehicleId] = nil

    local worker = g_currentMission.TheContractor.Staff:getWorker(binding.farmId, binding.workerId)
    if worker ~= nil and worker.drivingVehicleId == vehicleId then
        worker.drivingVehicleId = nil
    end

    return binding
end

-- Release tick (server) -----------------------------------------------------

-- Every frame from TheContractor:update. Driving time counts in game time
-- (it's what growth is measured in); the idle grace in real time (it only
-- has to cover a hand-off between two mods).
function TheContractorDrivers:update(dt)
    if not g_currentMission:getIsServer() then
        return
    end

    self:resolveLoadedBindings()

    if next(self.bindingsByVehicleId) == nil then
        return
    end

    local gameDt = dt * g_currentMission:getEffectiveTimeScale()
    local toRelease = {}
    for vehicleId, binding in pairs(self.bindingsByVehicleId) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle == nil or vehicle.isDeleted or vehicle.isDeleting then
            table.insert(toRelease, { vehicleId = vehicleId })
        elseif TheContractorDrivers.isVehicleDriven(vehicle) then
            binding.activeMs = binding.activeMs + gameDt
            binding.idleMs = 0
            binding.graceMs = TheContractorDrivers.RELEASE_GRACE_MS
        else
            binding.idleMs = binding.idleMs + dt
            if binding.idleMs >= binding.graceMs then
                table.insert(toRelease, { vehicleId = vehicleId, vehicle = vehicle })
            end
        end
    end

    for _, entry in ipairs(toRelease) do
        self:releaseDriver(entry.vehicleId, entry.vehicle)
    end
end

function TheContractorDrivers:rollDrivingGrowth(binding, vehicle)
    local minutes = binding.activeMs / 60000
    if minutes < TheContractorDrivers.DRIVER_GROWTH_MIN_MINUTES then
        return
    end

    local chance = math.min(TheContractorDrivers.DRIVER_GROWTH_MAX_CHANCE,
        TheContractorDrivers.DRIVER_GROWTH_CHANCE_PER_HOUR * minutes / 60)
    if math.random() >= chance then
        return
    end

    g_currentMission.TheContractor.Staff:growWorker(binding.farmId, binding.workerId,
        TheContractorDrivers.getVehicleTier(vehicle))
end

-- Notifications --------------------------------------------------------------

-- Tells the farm why a start was stopped/refused. Shown here for the
-- host (the broadcast doesn't loop back to it - see src/events/README.md).
function TheContractorDrivers:notify(farmId, textKey, vehicle)
    local vehicleName = vehicle ~= nil and vehicle.getFullName ~= nil and vehicle:getFullName() or ""

    TCDriverNoticeEvent.showNotification(farmId, textKey, vehicleName)

    if g_server ~= nil then
        g_server:broadcastEvent(TCDriverNoticeEvent.new(farmId, textKey, vehicleName))
    end
end

-- Persistence ------------------------------------------------------------------
--
-- Saved by vehicle uniqueId (network object ids don't survive a reload)
-- and relinked on the first update/hook after load, once vehicles exist. If
-- AD's autostartHelpers resumes the vehicle, the driver stays; otherwise
-- (CP/AI jobs don't survive a save) the release tick frees them after
-- LOAD_RELEASE_GRACE_MS.

function TheContractorDrivers:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.bindingsByVehicleId = {}
    self.loadedBindings = {}

    local rootKey = string.format("%s.drivers", TheContractor.SaveKey)
    local index = 0
    while true do
        local key = string.format("%s.binding(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        table.insert(self.loadedBindings, {
            uniqueId = getXMLString(xmlFile, key .. "#vehicleUniqueId"),
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            workerId = getXMLInt(xmlFile, key .. "#workerId"),
            activeMs = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#activeMs"), 0),
        })

        index = index + 1
    end
end

local function writeBindingXML(xmlFile, key, uniqueId, farmId, workerId, activeMs)
    setXMLString(xmlFile, key .. "#vehicleUniqueId", uniqueId)
    setXMLInt(xmlFile, key .. "#farmId", farmId)
    setXMLInt(xmlFile, key .. "#workerId", workerId)
    setXMLFloat(xmlFile, key .. "#activeMs", activeMs)
end

function TheContractorDrivers:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.drivers", TheContractor.SaveKey)
    local index = 0

    for vehicleId, binding in pairs(self.bindingsByVehicleId) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil and vehicle.getUniqueId ~= nil then
            writeBindingXML(xmlFile, string.format("%s.binding(%d)", rootKey, index), vehicle:getUniqueId(),
                binding.farmId, binding.workerId, binding.activeMs)
            index = index + 1
        end
    end

    -- Saved again before anything got round to relinking them.
    for _, entry in ipairs(self.loadedBindings or {}) do
        if entry.uniqueId ~= nil then
            writeBindingXML(xmlFile, string.format("%s.binding(%d)", rootKey, index), entry.uniqueId,
                entry.farmId, entry.workerId, entry.activeMs)
            index = index + 1
        end
    end
end

-- Server, once: relinks saved bindings to the now-loaded vehicles, then
-- frees anyone saved as DRIVING who didn't get one back (vehicle sold or
-- gone). Runs from the first update, or earlier if a hook asks first (AD
-- can tick a resumed driver before our first update).
function TheContractorDrivers:resolveLoadedBindings()
    if self.loadedBindings == nil then
        return
    end
    if not g_currentMission:getIsServer() then
        self.loadedBindings = nil
        return
    end

    local loaded = self.loadedBindings
    self.loadedBindings = nil

    local staff = g_currentMission.TheContractor.Staff
    for _, entry in ipairs(loaded) do
        local vehicle = entry.uniqueId ~= nil and
            g_currentMission.vehicleSystem:getVehicleByUniqueId(entry.uniqueId) or nil
        local vehicleId = vehicle ~= nil and TheContractorDrivers.getVehicleKey(vehicle) or nil
        local worker = staff:getWorker(entry.farmId, entry.workerId)

        if vehicleId ~= nil and worker ~= nil and self.bindingsByVehicleId[vehicleId] == nil then
            self:bindDriver(vehicleId, entry.farmId, entry.workerId, entry.activeMs,
                TheContractorDrivers.LOAD_RELEASE_GRACE_MS)
        end
    end

    for farmId, farmWorkers in pairs(staff.workersByFarm) do
        for workerId, worker in pairs(farmWorkers) do
            if worker.status == TheContractorWorker.STATUS.DRIVING and worker.drivingVehicleId == nil then
                staff:setWorkerStatus(farmId, workerId, TheContractorWorker.STATUS.IDLE)
            end
        end
    end
end

-- Ids only, never resolved here - a joining client may not have the
-- vehicles yet (src/events/README.md gotcha #3); every lookup resolves
-- lazily through NetworkUtil.getObject.
function TheContractorDrivers:writeInitialClientState(streamId, connection)
    local bindings = {}
    for _, binding in pairs(self.bindingsByVehicleId) do
        table.insert(bindings, binding)
    end

    streamWriteInt32(streamId, #bindings)
    for _, binding in ipairs(bindings) do
        streamWriteInt32(streamId, binding.vehicleId)
        streamWriteInt32(streamId, binding.farmId)
        streamWriteInt32(streamId, binding.workerId)
    end
end

function TheContractorDrivers:readInitialClientState(streamId, connection)
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local vehicleId = streamReadInt32(streamId)
        local farmId = streamReadInt32(streamId)
        local workerId = streamReadInt32(streamId)
        self:applyBindingSet(vehicleId, farmId, workerId)
    end
end
