TheContractor = {}
TheContractor.dir = g_currentModDirectory
TheContractor.SaveKey = "TheContractor"

source(TheContractor.dir .. "src/extensions/TCI18NExtension.lua")
source(TheContractor.dir .. "src/util/DisableVanillaContracts.lua")
source(TheContractor.dir .. "src/util/TCEquipmentClass.lua")
source(TheContractor.dir .. "src/util/TCCropPrediction.lua")
source(TheContractor.dir .. "src/util/TCJobProgress.lua")
source(TheContractor.dir .. "src/util/TCEquipmentVisibility.lua")
source(TheContractor.dir .. "src/util/TCFieldPreparation.lua")
source(TheContractor.dir .. "src/util/TCFieldAccess.lua")
source(TheContractor.dir .. "src/util/TCVehicleLock.lua")
source(TheContractor.dir .. "src/util/TCJobSiteSetup.lua")
source(TheContractor.dir .. "src/util/TCHaulage.lua")
source(TheContractor.dir .. "src/gui/MenuContractor.lua")
source(TheContractor.dir .. "src/hud/TCInboxHUD.lua")
source(TheContractor.dir .. "src/business/Reputation.lua")
source(TheContractor.dir .. "src/business/Negotiation.lua")
source(TheContractor.dir .. "src/business/Job.lua")
source(TheContractor.dir .. "src/business/Jobs.lua")
source(TheContractor.dir .. "src/business/JobGeneration.lua")
source(TheContractor.dir .. "src/business/Worker.lua")
source(TheContractor.dir .. "src/business/Staff.lua")
source(TheContractor.dir .. "src/business/Allocation.lua")
source(TheContractor.dir .. "src/business/Dispatch.lua")
source(TheContractor.dir .. "src/business/Watchdog.lua")
source(TheContractor.dir .. "src/business/Cooldown.lua")
source(TheContractor.dir .. "src/business/Company.lua")
source(TheContractor.dir .. "src/business/Advertising.lua")
source(TheContractor.dir .. "src/events/TCInitialClientStateEvent.lua")
source(TheContractor.dir .. "src/events/TCCreateCompanyEvent.lua")
source(TheContractor.dir .. "src/events/TCReputationChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCDebugAddReputationEvent.lua")
source(TheContractor.dir .. "src/events/TCJobCreatedEvent.lua")
source(TheContractor.dir .. "src/events/TCJobStateChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCJobTravellingEvent.lua")
source(TheContractor.dir .. "src/events/TCJobDeliveryEvent.lua")
source(TheContractor.dir .. "src/events/TCJobMissedEvent.lua")
source(TheContractor.dir .. "src/events/TCDebugCreateJobEvent.lua")
source(TheContractor.dir .. "src/events/TCDebugSetJobStateEvent.lua")
source(TheContractor.dir .. "src/events/TCRespondToJobOfferEvent.lua")
source(TheContractor.dir .. "src/events/TCCounterOfferEvent.lua")
source(TheContractor.dir .. "src/events/TCJobNegotiationUpdatedEvent.lua")
source(TheContractor.dir .. "src/events/TCPurchaseAdvertisingEvent.lua")
source(TheContractor.dir .. "src/events/TCAdvertisingStateChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCHireWorkerEvent.lua")
source(TheContractor.dir .. "src/events/TCWorkerHiredEvent.lua")
source(TheContractor.dir .. "src/events/TCStaffCandidateAddedEvent.lua")
source(TheContractor.dir .. "src/events/TCStaffCandidateRemovedEvent.lua")
source(TheContractor.dir .. "src/events/TCReleaseWorkerEvent.lua")
source(TheContractor.dir .. "src/events/TCWorkerReleasedEvent.lua")
source(TheContractor.dir .. "src/events/TCWorkerStatusChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCAllocateJobEvent.lua")
source(TheContractor.dir .. "src/events/TCJobAllocatedEvent.lua")
source(TheContractor.dir .. "src/events/TCJobCompletedEvent.lua")
source(TheContractor.dir .. "src/events/TCDispatchFailedEvent.lua")
source(TheContractor.dir .. "src/events/TCWatchdogInterventionEvent.lua")
source(TheContractor.dir .. "src/events/TCEquipmentCooldownStartedEvent.lua")
source(TheContractor.dir .. "src/events/TCEquipmentCooldownEndedEvent.lua")
source(TheContractor.dir .. "src/events/TCEquipmentVisibilityEvent.lua")

-- The top-level Contractor page itself stays always-visible (see Company.lua
-- and MenuContractor's Overview tab): "Create Company" has to live somewhere
-- reachable before a company exists, so the page can't be gated on having
-- one without a chicken-and-egg problem. Inbox/Calendar/Staff content is
-- what's actually gated on hasCompany(), from within MenuContractor.
function TheContractor:makeIsContractorMenuEnabledPredicate()
    return function()
        return true
    end
end

function TheContractor:loadMap()
    g_currentMission.TheContractor = self

    self.Reputation = TheContractorReputation.new()
    self.Jobs = TheContractorJobs.new()
    self.JobGeneration = TheContractorJobGeneration.new()
    self.Staff = TheContractorStaff.new()
    self.Allocation = TheContractorAllocation.new()
    self.Dispatch = TheContractorDispatch.new()
    self.Watchdog = TheContractorWatchdog.new()
    self.Cooldown = TheContractorCooldown.new()
    self.Company = TheContractorCompany.new()
    self.Advertising = TheContractorAdvertising.new()
    self.InboxHUD = TCInboxHUD.new()

    -- Module-level caches outlive a savegame; start each load clean.
    TCFieldAccess.reset()
    TCVehicleLock.reset()
    TCHaulage.reset()

    TheContractorDisableVanillaContracts.hideContractsTab()

    g_gui:loadProfiles(TheContractor.dir .. "src/gui/guiProfiles.xml")

    local menuContractor = MenuContractor.new(g_i18n)
    g_gui:loadGui(TheContractor.dir .. "src/gui/MenuContractor.xml", "menuContractor", menuContractor, true)

    MenuContractor.registerInIngameMenu(menuContractor, "pageContractor", { 0, 0, 128, 128 }, { 128, 128 },
        self:makeIsContractorMenuEnabledPredicate(), "pageSettings")
    menuContractor:initialize()

    self.MenuContractor = menuContractor

    self:loadFromXMLFile()

    -- Tops the shared staff pool up if it's empty (fresh save, or an
    -- existing save from before the pool existed) — see
    -- TheContractorStaff:ensureInitialPool.
    self.Staff:ensureInitialPool()

    self.JobGeneration:startHourlyTick()
    self.Advertising:startDailyTick()
    self.Jobs:startDailyTick()
    self.Staff:startDailyTick()
    self.Dispatch:startListening()

    -- Cheat-gated, following FS25_RedTape's own rtAddPoints console command
    -- (RedTape.lua's consoleCommandAddPoints): easy manual testing of
    -- reputation-tier progression without waiting for 011/014/022/024 to
    -- exist and actually award/deduct it.
    if g_addCheatCommands and g_currentMission:getIsServer() then
        addConsoleCommand("tcAddReputation",
            "Add or remove reputation points for current farm. Usage: tcAddReputation amount", "consoleCommandAddReputation", self)
        addConsoleCommand("tcCreateTestJob",
            "Create a test job for the current farm. Usage: tcCreateTestJob jobType fieldId requiredSkillLevel price targetPeriod targetDayInPeriod",
            "consoleCommandCreateTestJob", self)
        addConsoleCommand("tcSetJobState",
            "Force a job's state for the current farm. Usage: tcSetJobState jobId state",
            "consoleCommandSetJobState", self)
        addConsoleCommand("tcListStaffPool",
            "List candidates currently available to hire from the shared staff pool. Usage: tcListStaffPool",
            "consoleCommandListStaffPool", self)
        addConsoleCommand("tcHireWorker",
            "Hire a candidate from the staff pool for the current farm. Usage: tcHireWorker candidateId",
            "consoleCommandHireWorker", self)
        addConsoleCommand("tcJobAvailability",
            "Dry-run job generation for the current farm: eligible fields per job type right now (025). Usage: tcJobAvailability",
            "consoleCommandJobAvailability", self)
    end

    Logging.info("TheContractor: loadMap")
end

function TheContractor:consoleCommandAddReputation(amount)
    if not g_currentMission:getIsServer() then return "Server only" end

    local numAmount = tonumber(amount)
    if numAmount == nil then
        return "Usage: tcAddReputation amount (e.g. tcAddReputation 100 or tcAddReputation -50)"
    end

    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil or farm.farmId == 0 then
        return "Error: No farm found for current player"
    end

    g_client:getServerConnection():sendEvent(TCDebugAddReputationEvent.new(farm.farmId, numAmount))
    return string.format("Applied %d reputation to farm %d", numAmount, farm.farmId)
end

function TheContractor:consoleCommandCreateTestJob(jobType, fieldId, requiredSkillLevel, price, targetPeriod,
                                                     targetDayInPeriod)
    if not g_currentMission:getIsServer() then return "Server only" end

    if jobType == nil or tonumber(fieldId) == nil or tonumber(requiredSkillLevel) == nil or tonumber(price) == nil
        or tonumber(targetPeriod) == nil or tonumber(targetDayInPeriod) == nil then
        return "Usage: tcCreateTestJob jobType fieldId requiredSkillLevel price targetPeriod targetDayInPeriod"
    end

    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil or farm.farmId == 0 then
        return "Error: No farm found for current player"
    end

    g_client:getServerConnection():sendEvent(TCDebugCreateJobEvent.new(farm.farmId, jobType, tonumber(fieldId),
        tonumber(requiredSkillLevel), tonumber(targetPeriod), tonumber(targetDayInPeriod), tonumber(price)))
    return string.format("Requested job creation for farm %d", farm.farmId)
end

function TheContractor:consoleCommandSetJobState(jobId, state)
    if not g_currentMission:getIsServer() then return "Server only" end

    local numJobId = tonumber(jobId)
    if numJobId == nil or state == nil then
        return "Usage: tcSetJobState jobId state"
    end

    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil or farm.farmId == 0 then
        return "Error: No farm found for current player"
    end

    g_client:getServerConnection():sendEvent(TCDebugSetJobStateEvent.new(farm.farmId, numJobId, state))
    return string.format("Requested job %d -> %s for farm %d", numJobId, state, farm.farmId)
end

function TheContractor:consoleCommandListStaffPool()
    local staff = g_currentMission.TheContractor.Staff
    local pool = staff:getCandidatePool()
    if #pool == 0 then
        return "Staff pool is empty."
    end

    local lines = {}
    for _, candidate in ipairs(pool) do
        table.insert(lines, string.format("#%d %s - speed %d, cost %.0f, tiers: %s", candidate.id, candidate.name,
            candidate.workSpeed, candidate.hireCost, TheContractorStaff.formatTierCapability(candidate.tierCapability)))
    end
    return table.concat(lines, "\n")
end

function TheContractor:consoleCommandHireWorker(candidateId)
    if not g_currentMission:getIsServer() then return "Server only" end

    local numCandidateId = tonumber(candidateId)
    if numCandidateId == nil then
        return "Usage: tcHireWorker candidateId (see tcListStaffPool)"
    end

    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil or farm.farmId == 0 then
        return "Error: No farm found for current player"
    end

    g_client:getServerConnection():sendEvent(TCHireWorkerEvent.new(farm.farmId, numCandidateId))
    return string.format("Requested hiring candidate %d for farm %d", numCandidateId, farm.farmId)
end

-- 025 investigation aid: what the hourly generator could offer this farm
-- right now, per job type. Read-only, so no event round-trip — server-only
-- because field state and generation both live there.
function TheContractor:consoleCommandJobAvailability()
    if not g_currentMission:getIsServer() then return "Server only" end

    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil or farm.farmId == 0 then
        return "Error: No farm found for current player"
    end

    local jobGeneration = self.JobGeneration
    local environment = g_currentMission.environment
    local hourlyChance = jobGeneration:getHourlyChance(farm.farmId)
    local rollsPerPeriod = 24 * environment.daysPerPeriod

    local lines = {
        string.format("Farm %d, period %d day %d: hourly chance %.4f, ~%.1f generation hits per period (split evenly across %d job types)",
            farm.farmId, environment.currentPeriod, environment.currentDayInPeriod, hourlyChance,
            hourlyChance * rollsPerPeriod, #TheContractorJobGeneration.JOB_TYPE_KEYS),
    }
    for _, entry in ipairs(jobGeneration:getAvailabilitySnapshot(farm.farmId)) do
        table.insert(lines, string.format("  %-9s eligible fields %3d, with target date %3d, equipment %s",
            entry.jobType, entry.candidates, entry.datable, entry.canFulfill and "yes" or "NO"))
    end
    return table.concat(lines, "\n")
end

-- Called as a normal method (self == TheContractor) from loadMap, once the
-- savegame directory is known.
function TheContractor:loadFromXMLFile()
    if not g_currentMission:getIsServer() then return end

    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory
    if savegameFolderPath == nil then
        savegameFolderPath = ('%ssavegame%d'):format(getUserProfileAppPath(),
            g_currentMission.missionInfo.savegameIndex)
    end
    savegameFolderPath = savegameFolderPath .. "/"

    local filePath = savegameFolderPath .. TheContractor.SaveKey .. ".xml"
    if not fileExists(filePath) then
        return
    end

    local xmlFile = loadXMLFile(TheContractor.SaveKey, filePath)

    self.Reputation:loadFromXMLFile(xmlFile)
    self.Jobs:loadFromXMLFile(xmlFile)
    self.Staff:loadFromXMLFile(xmlFile)
    self.Cooldown:loadFromXMLFile(xmlFile)
    self.Company:loadFromXMLFile(xmlFile)
    self.Advertising:loadFromXMLFile(xmlFile)

    delete(xmlFile)

    -- Vehicles always load fully visible/in-physics (base game default, see
    -- Vehicle:onFinishedLoading) - re-hide anything still mid-buffer from a
    -- prior session now that vehicles are actually resolvable (see
    -- TheContractorCooldown:reapplyHidingAfterLoad).
    self.Cooldown:reapplyHidingAfterLoad()
end

-- Appended onto FSBaseMission.saveSavegame (see installSaveHook below), so
-- this runs with `self` bound to the mission instance, not TheContractor —
-- go via g_currentMission.TheContractor instead, same as RedTape does.
function TheContractor:saveToXmlFile()
    if not g_currentMission:getIsServer() then return end

    local tc = g_currentMission.TheContractor
    if tc == nil then return end

    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"

    local xmlFile = createXMLFile(TheContractor.SaveKey, savegameFolderPath .. TheContractor.SaveKey .. ".xml",
        TheContractor.SaveKey)

    tc.Reputation:saveToXmlFile(xmlFile)
    tc.Jobs:saveToXmlFile(xmlFile)
    tc.Staff:saveToXmlFile(xmlFile)
    tc.Cooldown:saveToXmlFile(xmlFile)
    tc.Company:saveToXmlFile(xmlFile)
    tc.Advertising:saveToXmlFile(xmlFile)

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

-- Mission00.saveSavegame is inherited from FSBaseMission via metatable, so it is
-- ALWAYS non-nil even when Mission00 has no override of its own. Checking it directly
-- (without rawget) would make us always shadow Mission00, permanently orphaning any
-- mod that later hooks FSBaseMission.saveSavegame (the standard convention most mods
-- use, e.g. inside FSBaseMission.onStartMission). Only target Mission00 if another mod
-- has already put its own property there — otherwise stay on FSBaseMission so we remain
-- part of the shared chain. (Same reasoning as FS25_RedTape's installSaveHook.)
function TheContractor.installSaveHook()
    if TheContractor.saveHookInstalled then
        return
    end

    local target = FSBaseMission
    if Mission00 ~= nil and rawget(Mission00, "saveSavegame") ~= nil then
        target = Mission00
    end

    target.saveSavegame = Utils.appendedFunction(target.saveSavegame, TheContractor.saveToXmlFile)
    TheContractor.saveHookInstalled = true
end

function TheContractor:sendInitialClientState(connection, user, farm)
    connection:sendEvent(TCInitialClientStateEvent.new())
end

function TheContractor.installInitialClientStateHook()
    if TheContractor.initialClientStateHookInstalled then
        return
    end

    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState,
        TheContractor.sendInitialClientState)
    TheContractor.initialClientStateHookInstalled = true
end

function TheContractor:deleteMap()
    Logging.info("TheContractor: deleteMap")

    if self.JobGeneration ~= nil then
        self.JobGeneration:stopHourlyTick()
    end

    if self.Advertising ~= nil then
        self.Advertising:stopDailyTick()
    end

    if self.Jobs ~= nil then
        self.Jobs:stopDailyTick()
    end

    if self.Staff ~= nil then
        self.Staff:stopDailyTick()
    end

    if self.Dispatch ~= nil then
        self.Dispatch:stopListening()
    end

    if self.InboxHUD ~= nil then
        self.InboxHUD:delete()
    end

    if g_addCheatCommands then
        removeConsoleCommand("tcAddReputation")
        removeConsoleCommand("tcCreateTestJob")
        removeConsoleCommand("tcSetJobState")
        removeConsoleCommand("tcListStaffPool")
        removeConsoleCommand("tcHireWorker")
        removeConsoleCommand("tcJobAvailability")
    end

    if g_currentMission ~= nil and g_currentMission.TheContractor == self then
        g_currentMission.TheContractor = nil
    end
end

function TheContractor:update(dt)
    if self.InboxHUD ~= nil then
        self.InboxHUD:update(dt)
    end

    TCJobProgress.update(dt)
    TCFieldAccess.update(dt)
    TCVehicleLock.update(dt)
    TCHaulage.update(dt)

    if self.Dispatch ~= nil then
        self.Dispatch:update(dt)
    end

    if self.Watchdog ~= nil then
        self.Watchdog:update(dt)
    end

    if self.Jobs ~= nil then
        self.Jobs:update(dt)
    end

    if self.Cooldown ~= nil then
        self.Cooldown:update(dt)
    end
end

function TheContractor:draw()
    if self.InboxHUD ~= nil then
        self.InboxHUD:draw()
    end
end

TheContractor.installSaveHook()
TheContractor.installInitialClientStateHook()

addModEventListener(TheContractor)
