TheContractor = {}
TheContractor.dir = g_currentModDirectory
TheContractor.SaveKey = "TheContractor"

source(TheContractor.dir .. "src/extensions/TCI18NExtension.lua")
source(TheContractor.dir .. "src/util/DisableVanillaContracts.lua")
source(TheContractor.dir .. "src/util/TCFreezeNPCFieldwork.lua")
source(TheContractor.dir .. "src/util/TCEquipmentClass.lua")
source(TheContractor.dir .. "src/util/TCCropPrediction.lua")
source(TheContractor.dir .. "src/util/TCJobProgress.lua")
source(TheContractor.dir .. "src/util/TCJobFuel.lua")
source(TheContractor.dir .. "src/util/TCEquipmentVisibility.lua")
source(TheContractor.dir .. "src/util/TCFieldPreparation.lua")
source(TheContractor.dir .. "src/util/TCFieldAccess.lua")
source(TheContractor.dir .. "src/util/TCVehicleLock.lua")
source(TheContractor.dir .. "src/util/TCJobSiteSetup.lua")
source(TheContractor.dir .. "src/util/TCParking.lua")
source(TheContractor.dir .. "src/util/TCHaulage.lua")
source(TheContractor.dir .. "src/util/TCJobSupplies.lua")
source(TheContractor.dir .. "src/util/TCSupplyStock.lua")
source(TheContractor.dir .. "src/util/TCADSStock.lua")
source(TheContractor.dir .. "src/util/TCJobConsequences.lua")
source(TheContractor.dir .. "src/util/TCVehicleCondition.lua")
source(TheContractor.dir .. "src/util/TCVehicleIds.lua")
source(TheContractor.dir .. "src/util/TCWorkerFieldSpeed.lua")
source(TheContractor.dir .. "src/util/TCAutoDrive.lua")
source(TheContractor.dir .. "src/util/TCCourseplay.lua")
source(TheContractor.dir .. "src/util/TCEconomyScale.lua")
source(TheContractor.dir .. "src/util/TCCalendar.lua")
source(TheContractor.dir .. "src/util/TCCompanyLogo.lua")
source(TheContractor.dir .. "src/util/TCConsole.lua")
source(TheContractor.dir .. "src/util/TCWorkerAppearance.lua")
source(TheContractor.dir .. "src/util/TCAINotifications.lua")
source(TheContractor.dir .. "src/util/TCAIRestart.lua")
source(TheContractor.dir .. "src/util/TCIdleStaff.lua")
source(TheContractor.dir .. "src/util/TCJoyriderRuts.lua")
source(TheContractor.dir .. "src/gui/TCWorkerPortrait.lua")
source(TheContractor.dir .. "src/gui/MenuContractor.lua")
source(TheContractor.dir .. "src/gui/TCSettingsMenu.lua")
source(TheContractor.dir .. "src/gui/TCAdvertisingDialog.lua")
source(TheContractor.dir .. "src/gui/TCDriverPickerDialog.lua")
source(TheContractor.dir .. "src/gui/TCEditWorkerDialog.lua")
source(TheContractor.dir .. "src/hud/TCInboxHUD.lua")
source(TheContractor.dir .. "src/business/Settings.lua")
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
source(TheContractor.dir .. "src/business/Drivers.lua")
source(TheContractor.dir .. "src/business/Notices.lua")
source(TheContractor.dir .. "src/business/Holidays.lua")
source(TheContractor.dir .. "src/business/Finances.lua")
source(TheContractor.dir .. "src/business/Inbox.lua")
source(TheContractor.dir .. "src/business/Overheads.lua")
source(TheContractor.dir .. "src/business/Claims.lua")
source(TheContractor.dir .. "src/business/Association.lua")
source(TheContractor.dir .. "src/business/HealthSafety.lua")
source(TheContractor.dir .. "src/business/Training.lua")
source(TheContractor.dir .. "src/business/Morale.lua")
source(TheContractor.dir .. "src/business/PayReviews.lua")
source(TheContractor.dir .. "src/business/Administrator.lua")
source(TheContractor.dir .. "src/business/Logbook.lua")
source(TheContractor.dir .. "src/business/Parking.lua")
source(TheContractor.dir .. "src/business/RandomEvents.lua")
source(TheContractor.dir .. "src/business/MachineryInsurance.lua")
source(TheContractor.dir .. "src/business/Theft.lua")
source(TheContractor.dir .. "src/business/Joyriders.lua")
source(TheContractor.dir .. "src/business/GoodNews.lua")
source(TheContractor.dir .. "src/business/JobNews.lua")
source(TheContractor.dir .. "src/business/CourtesyVehicle.lua")
source(TheContractor.dir .. "src/events/TCInitialClientStateEvent.lua")
source(TheContractor.dir .. "src/events/TCSettingsEvent.lua")
source(TheContractor.dir .. "src/events/TCCreateCompanyEvent.lua")
source(TheContractor.dir .. "src/events/TCReputationChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCDebugAddReputationEvent.lua")
source(TheContractor.dir .. "src/events/TCJobCreatedEvent.lua")
source(TheContractor.dir .. "src/events/TCJobStateChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCJobTravellingEvent.lua")
source(TheContractor.dir .. "src/events/TCJobDeliveryEvent.lua")
source(TheContractor.dir .. "src/events/TCJobProgressEvent.lua")
source(TheContractor.dir .. "src/events/TCJobSupplyStatusEvent.lua")
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
source(TheContractor.dir .. "src/events/TCWorkerGrewEvent.lua")
source(TheContractor.dir .. "src/events/TCWorkersAgedEvent.lua")
source(TheContractor.dir .. "src/events/TCAllocateJobEvent.lua")
source(TheContractor.dir .. "src/events/TCJobAllocatedEvent.lua")
source(TheContractor.dir .. "src/events/TCJobCompletedEvent.lua")
source(TheContractor.dir .. "src/events/TCDispatchFailedEvent.lua")
source(TheContractor.dir .. "src/events/TCWatchdogInterventionEvent.lua")
source(TheContractor.dir .. "src/events/TCEquipmentCooldownStartedEvent.lua")
source(TheContractor.dir .. "src/events/TCEquipmentCooldownEndedEvent.lua")
source(TheContractor.dir .. "src/events/TCEquipmentVisibilityEvent.lua")
source(TheContractor.dir .. "src/events/TCAssignDriverEvent.lua")
source(TheContractor.dir .. "src/events/TCDriverBindingEvent.lua")
source(TheContractor.dir .. "src/events/TCDriverNoticeEvent.lua")
source(TheContractor.dir .. "src/events/TCNoticePublishedEvent.lua")
source(TheContractor.dir .. "src/events/TCNoticeRemovedEvent.lua")
source(TheContractor.dir .. "src/events/TCWorkerRetirementAnnouncedEvent.lua")
source(TheContractor.dir .. "src/events/TCWorkerRetiredEvent.lua")
source(TheContractor.dir .. "src/events/TCWorkerHolidayChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCInvoiceIssuedEvent.lua")
source(TheContractor.dir .. "src/events/TCInvoiceStatusChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCWriteOffInvoiceEvent.lua")
source(TheContractor.dir .. "src/events/TCFinanceYearStatsEvent.lua")
source(TheContractor.dir .. "src/events/TCMessagePostedEvent.lua")
source(TheContractor.dir .. "src/events/TCMessageRemovedEvent.lua")
source(TheContractor.dir .. "src/events/TCMessageActionEvent.lua")
source(TheContractor.dir .. "src/events/TCOverheadStateEvent.lua")
source(TheContractor.dir .. "src/events/TCOverheadRequestEvent.lua")
source(TheContractor.dir .. "src/events/TCClaimRecordedEvent.lua")
source(TheContractor.dir .. "src/events/TCInsuranceClaimRecordedEvent.lua")
source(TheContractor.dir .. "src/events/TCPursueInvoiceEvent.lua")
source(TheContractor.dir .. "src/events/TCWorkerTrainingChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCBookTrainingEvent.lua")
source(TheContractor.dir .. "src/events/TCWorkerMoraleChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCGiveBonusEvent.lua")
source(TheContractor.dir .. "src/events/TCWorkerPayChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCPayRiseEvent.lua")
source(TheContractor.dir .. "src/events/TCEditWorkerEvent.lua")
source(TheContractor.dir .. "src/events/TCWorkerEditedEvent.lua")
source(TheContractor.dir .. "src/events/TCAdministratorRequestEvent.lua")
source(TheContractor.dir .. "src/events/TCAdministratorChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCLogJobRecordedEvent.lua")
source(TheContractor.dir .. "src/events/TCLogVehicleEntryEvent.lua")
source(TheContractor.dir .. "src/events/TCLogClaimEvent.lua")
source(TheContractor.dir .. "src/events/TCParkingQueuedEvent.lua")
source(TheContractor.dir .. "src/events/TCParkingRemovedEvent.lua")
source(TheContractor.dir .. "src/events/TCParkingNoticeEvent.lua")
source(TheContractor.dir .. "src/events/TCRandomEventIncidentEvent.lua")

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
    self.hasResolvedSavedVehicles = false

    TCCompanyLogo.createSettingsFolder()

    self.Settings = TheContractorSettings.new()
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
    self.Drivers = TheContractorDrivers.new()
    self.Notices = TheContractorNotices.new()
    self.Holidays = TheContractorHolidays.new()
    self.Finances = TheContractorFinances.new()
    self.Inbox = TheContractorInbox.new()
    self.Overheads = TheContractorOverheads.new()
    self.Overheads:registerMessageKinds(self.Inbox)
    self.Claims = TheContractorClaims.new()
    self.Claims:register(self.Overheads, self.Inbox)
    self.Association = TheContractorAssociation.new()
    self.Association:register(self.Overheads, self.Inbox)
    self.HealthSafety = TheContractorHealthSafety.new()
    self.HealthSafety:register(self.Overheads)
    self.Training = TheContractorTraining.new()
    self.Training:register(self.Inbox)
    self.Morale = TheContractorMorale.new()
    self.Morale:register(self.Inbox)
    self.PayReviews = TheContractorPayReviews.new()
    self.PayReviews:register(self.Inbox)
    self.Administrator = TheContractorAdministrator.new()
    self.Logbook = TheContractorLogbook.new()
    self.Parking = TheContractorParking.new()
    self.Parking:register(self.Inbox)
    -- 068: event types (069 on) register with it before the save loads, so
    -- their saved incidents find their stages.
    self.RandomEvents = TheContractorRandomEvents.new()
    self.Theft = TheContractorTheft.new()
    -- 070: before Theft, which puts its claim stages in its own.
    self.MachineryInsurance = TheContractorMachineryInsurance.new()
    self.MachineryInsurance:register(self.Overheads, self.Inbox, self.RandomEvents)
    -- 071: before Theft too, for its return stages.
    self.CourtesyVehicle = TheContractorCourtesyVehicle.new()
    self.CourtesyVehicle:register(self.RandomEvents, self.Inbox)
    self.Theft:register(self.RandomEvents, self.Inbox, self.MachineryInsurance, self.CourtesyVehicle)
    self.Joyriders = TheContractorJoyriders.new()
    self.Joyriders:register(self.RandomEvents, self.Inbox)
    self.GoodNews = TheContractorGoodNews.new()
    self.GoodNews:register(self.RandomEvents, self.Inbox)
    -- 074: after GoodNews, whose inbox kind its messages use.
    self.JobNews = TheContractorJobNews.new()
    self.JobNews:register(self.RandomEvents)
    self.InboxHUD = TCInboxHUD.new()

    -- Module-level caches outlive a savegame; start each load clean.
    TCFieldAccess.reset()
    TCEquipmentVisibility.reset()
    TCVehicleLock.reset()
    TCHaulage.reset()
    TCFieldPreparation.reset()
    TCJobSupplies.reset()
    TCIdleStaff.reset()

    -- 064: which parts of FS25_AdvancedDamageSystem's stock the Supplies
    -- tab can show (none without the mod).
    TCADSStock.detect()

    TheContractorDisableVanillaContracts.hideContractsTab()

    -- 062: parking slots only show in the construction menu.
    TCParking.installConstructionScreenHook()

    -- 037: staff-driver hooks - vanilla AI Helper starts always, plus
    -- AutoDrive/Courseplay for whichever of the two is loaded.
    TheContractorDrivers.installHooks()

    g_gui:loadProfiles(TheContractor.dir .. "src/gui/guiProfiles.xml")
    TCAdvertisingDialog.register()
    TCDriverPickerDialog.register()
    TCEditWorkerDialog.register()

    local menuContractor = MenuContractor.new(g_i18n)
    g_gui:loadGui(TheContractor.dir .. "src/gui/MenuContractor.xml", "menuContractor", menuContractor, true)

    MenuContractor.registerInIngameMenu(menuContractor, "pageContractor", { 0, 0, 128, 128 }, { 128, 128 },
        self:makeIsContractorMenuEnabledPredicate(), "pageSettings")
    menuContractor:initialize()

    self.MenuContractor = menuContractor

    self:loadFromXMLFile()

    -- 048: after loading, so the controls start on the saved values.
    TCSettingsMenu.inject()

    -- Tops the shared staff pool up if it's empty (fresh save, or an
    -- existing save from before the pool existed) — see
    -- TheContractorStaff:ensureInitialPool.
    self.Staff:ensureInitialPool()

    self.JobGeneration:startHourlyTick()
    self.Advertising:startDailyTick()
    self.Jobs:startDailyTick()
    self.Staff:startDailyTick()
    self.Dispatch:startListening()
    self.Notices:startPeriodTick()
    self.Finances:startDailyTick()
    self.Inbox:startDailyTick()
    self.Overheads:startTicks()
    self.Claims:startDailyTick()
    -- 060: every machine prunes its own copy.
    self.Logbook:startDailyTick()
    self.RandomEvents:startDailyTick()

    -- Console commands: each subsystem registers its own (see TCConsole).
    TCConsole.reset()
    TheContractorStaff.registerConsoleCommands()
    TheContractorHolidays.registerConsoleCommands()
    TheContractorTraining.registerConsoleCommands()
    TheContractorMorale.registerConsoleCommands()
    TheContractorPayReviews.registerConsoleCommands()
    TheContractorJobGeneration.registerConsoleCommands()
    TheContractorJobs.registerConsoleCommands()
    TheContractorFinances.registerConsoleCommands()
    TheContractorClaims.registerConsoleCommands()
    TheContractorReputation.registerConsoleCommands()
    TheContractorNotices.registerConsoleCommands()
    TheContractorLogbook.registerConsoleCommands()
    TheContractorParking.registerConsoleCommands()
    TheContractorRandomEvents.registerConsoleCommands()
    TheContractorTheft.registerConsoleCommands()
    TheContractorMachineryInsurance.registerConsoleCommands()
    TheContractorGoodNews.registerConsoleCommands()
    TCSupplyStock.registerConsoleCommands()
    TCIdleStaff.registerConsoleCommands()
    TCConsole.install()

    Logging.info("TheContractor: loadMap")
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

    self.Settings:loadFromXMLFile(xmlFile)
    self.Reputation:loadFromXMLFile(xmlFile)
    -- Before Staff/Drivers: loading can retire a worker (039), which takes
    -- their notice down.
    self.Notices:loadFromXMLFile(xmlFile)
    self.Jobs:loadFromXMLFile(xmlFile)
    self.Staff:loadFromXMLFile(xmlFile)
    self.Cooldown:loadFromXMLFile(xmlFile)
    self.Company:loadFromXMLFile(xmlFile)
    self.Advertising:loadFromXMLFile(xmlFile)
    self.Drivers:loadFromXMLFile(xmlFile)
    -- After Notices, so it can drop notice ids no longer on the board.
    self.Holidays:loadFromXMLFile(xmlFile)
    self.Finances:loadFromXMLFile(xmlFile)
    self.Inbox:loadFromXMLFile(xmlFile)
    self.Overheads:loadFromXMLFile(xmlFile)
    self.Claims:loadFromXMLFile(xmlFile)
    self.Association:loadFromXMLFile(xmlFile)
    self.HealthSafety:loadFromXMLFile(xmlFile)
    self.Training:loadFromXMLFile(xmlFile)
    self.Morale:loadFromXMLFile(xmlFile)
    self.PayReviews:loadFromXMLFile(xmlFile)
    self.Administrator:loadFromXMLFile(xmlFile)
    self.Logbook:loadFromXMLFile(xmlFile)
    self.Parking:loadFromXMLFile(xmlFile)
    self.RandomEvents:loadFromXMLFile(xmlFile)
    self.MachineryInsurance:loadFromXMLFile(xmlFile)
    self.GoodNews:loadFromXMLFile(xmlFile)

    delete(xmlFile)
end

-- Server, once: turns the vehicle uniqueIds the save stored back into
-- network object ids (see TCVehicleIds). Vehicles load after loadMap, so
-- this waits for whichever comes first of the first update, a client
-- joining (a paused dedicated server has no updates) or a save.
function TheContractor:resolveSavedVehicles()
    if self.hasResolvedSavedVehicles or not g_currentMission:getIsServer() then
        return
    end
    self.hasResolvedSavedVehicles = true

    self.Jobs:resolveSavedVehicles()
    self.Cooldown:resolveSavedVehicles()
    self.Logbook:resolveSavedVehicles()
    self.Parking:resolveSavedVehicles()
    self.Theft:resolveSavedVehicles()
    self.CourtesyVehicle:resolveSavedVehicles()
end

-- Appended onto FSBaseMission.saveSavegame (see installSaveHook below), so
-- this runs with `self` bound to the mission instance, not TheContractor —
-- go via g_currentMission.TheContractor instead, same as RedTape does.
function TheContractor:saveToXmlFile()
    if not g_currentMission:getIsServer() then return end

    local tc = g_currentMission.TheContractor
    if tc == nil then return end

    tc:resolveSavedVehicles()

    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"

    local xmlFile = createXMLFile(TheContractor.SaveKey, savegameFolderPath .. TheContractor.SaveKey .. ".xml",
        TheContractor.SaveKey)

    tc.Settings:saveToXmlFile(xmlFile)
    tc.Reputation:saveToXmlFile(xmlFile)
    tc.Jobs:saveToXmlFile(xmlFile)
    tc.Staff:saveToXmlFile(xmlFile)
    tc.Cooldown:saveToXmlFile(xmlFile)
    tc.Company:saveToXmlFile(xmlFile)
    tc.Advertising:saveToXmlFile(xmlFile)
    tc.Drivers:saveToXmlFile(xmlFile)
    tc.Notices:saveToXmlFile(xmlFile)
    tc.Holidays:saveToXmlFile(xmlFile)
    tc.Finances:saveToXmlFile(xmlFile)
    tc.Inbox:saveToXmlFile(xmlFile)
    tc.Overheads:saveToXmlFile(xmlFile)
    tc.Claims:saveToXmlFile(xmlFile)
    tc.Association:saveToXmlFile(xmlFile)
    tc.HealthSafety:saveToXmlFile(xmlFile)
    tc.Training:saveToXmlFile(xmlFile)
    tc.Morale:saveToXmlFile(xmlFile)
    tc.PayReviews:saveToXmlFile(xmlFile)
    tc.Administrator:saveToXmlFile(xmlFile)
    tc.Logbook:saveToXmlFile(xmlFile)
    tc.Parking:saveToXmlFile(xmlFile)
    tc.RandomEvents:saveToXmlFile(xmlFile)
    tc.MachineryInsurance:saveToXmlFile(xmlFile)
    tc.GoodNews:saveToXmlFile(xmlFile)

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
    -- self is the mission here (appended onto FSBaseMission).
    g_currentMission.TheContractor:resolveSavedVehicles()
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

    if self.Notices ~= nil then
        self.Notices:stopPeriodTick()
    end

    if self.Finances ~= nil then
        self.Finances:stopDailyTick()
    end

    if self.Inbox ~= nil then
        self.Inbox:stopDailyTick()
    end

    if self.Overheads ~= nil then
        self.Overheads:stopTicks()
    end

    if self.Claims ~= nil then
        self.Claims:stopDailyTick()
    end

    if self.Logbook ~= nil then
        self.Logbook:stopDailyTick()
    end

    if self.RandomEvents ~= nil then
        self.RandomEvents:stopDailyTick()
    end

    if self.InboxHUD ~= nil then
        self.InboxHUD:delete()
    end

    -- 065: frees the standing workers' models.
    TCIdleStaff.reset()

    TCConsole.uninstall()

    if g_currentMission ~= nil and g_currentMission.TheContractor == self then
        g_currentMission.TheContractor = nil
    end
end

function TheContractor:update(dt)
    -- Before anything that touches job equipment.
    self:resolveSavedVehicles()

    if self.InboxHUD ~= nil then
        self.InboxHUD:update(dt)
    end

    TCJobProgress.update(dt)
    TCEquipmentVisibility.update(dt)
    TCFieldAccess.update(dt)
    TCVehicleLock.update(dt)
    TCHaulage.update(dt)
    TCFieldPreparation.update(dt)
    TCJobSupplies.update(dt)

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

    if self.Parking ~= nil then
        self.Parking:update(dt)
    end

    if self.Drivers ~= nil then
        self.Drivers:update(dt)
    end

    -- After Drivers: its first update relinks saved bindings, which the
    -- logbook's driver sessions follow.
    if self.Logbook ~= nil then
        self.Logbook:update(dt)
    end

    -- 065: idle staff on standing spots (clients only).
    TCIdleStaff.update(dt)
end

function TheContractor:draw()
    if self.InboxHUD ~= nil then
        self.InboxHUD:draw()
    end
end

TheContractor.installSaveHook()
TheContractor.installInitialClientStateHook()

addModEventListener(TheContractor)
