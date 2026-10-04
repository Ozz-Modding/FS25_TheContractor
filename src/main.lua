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
source(TheContractor.dir .. "src/util/TCHaulage.lua")
source(TheContractor.dir .. "src/util/TCJobSupplies.lua")
source(TheContractor.dir .. "src/util/TCJobConsequences.lua")
source(TheContractor.dir .. "src/util/TCWorkerFieldSpeed.lua")
source(TheContractor.dir .. "src/util/TCAutoDrive.lua")
source(TheContractor.dir .. "src/util/TCCourseplay.lua")
source(TheContractor.dir .. "src/util/TCCalendar.lua")
source(TheContractor.dir .. "src/util/TCWorkerAppearance.lua")
source(TheContractor.dir .. "src/gui/TCWorkerPortrait.lua")
source(TheContractor.dir .. "src/gui/MenuContractor.lua")
source(TheContractor.dir .. "src/gui/TCAdvertisingDialog.lua")
source(TheContractor.dir .. "src/gui/TCDriverPickerDialog.lua")
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
source(TheContractor.dir .. "src/business/Drivers.lua")
source(TheContractor.dir .. "src/business/Notices.lua")
source(TheContractor.dir .. "src/business/Holidays.lua")
source(TheContractor.dir .. "src/events/TCInitialClientStateEvent.lua")
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
    self.Drivers = TheContractorDrivers.new()
    self.Notices = TheContractorNotices.new()
    self.Holidays = TheContractorHolidays.new()
    self.InboxHUD = TCInboxHUD.new()

    -- Module-level caches outlive a savegame; start each load clean.
    TCFieldAccess.reset()
    TCVehicleLock.reset()
    TCHaulage.reset()
    TCFieldPreparation.reset()
    TCJobSupplies.reset()

    TheContractorDisableVanillaContracts.hideContractsTab()

    -- 037: AutoDrive/Courseplay staff-driver hooks, for whichever of the two
    -- is loaded.
    TheContractorDrivers.installHooks()

    g_gui:loadProfiles(TheContractor.dir .. "src/gui/guiProfiles.xml")
    TCAdvertisingDialog.register()
    TCDriverPickerDialog.register()

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
    self.Notices:startPeriodTick()

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
            "Dry-run job generation for the current farm: eligible, datable and fulfillable fields per job type right now (025, 033). Usage: tcJobAvailability",
            "consoleCommandJobAvailability", self)
        addConsoleCommand("tcOfferJob",
            "Offer the current farm a job of the given type right now, through the normal generator. No type lists the types. Usage: tcOfferJob [jobType]",
            "consoleCommandOfferJob", self)
        addConsoleCommand("tcRetireWorker",
            "Make a hired worker on the current farm hand in their retirement notice (039). Usage: tcRetireWorker workerId [noticeMonths, default 6, 0 = now]",
            "consoleCommandRetireWorker", self)
        addConsoleCommand("tcBookHoliday",
            "Book a holiday for a hired worker on the current farm, skipping the notice and allowance rules (040). Usage: tcBookHoliday workerId [daysFromNow, default 0] [days, default 1]",
            "consoleCommandBookHoliday", self)
        addConsoleCommand("tcPublishNotice",
            "Publish a notice to the current farm's Overview board (038). Usage: tcPublishNotice ttlMonths|none text...",
            "consoleCommandPublishNotice", self)
        addConsoleCommand("tcRemoveNotice",
            "Remove a notice from the Overview board by id (038). Usage: tcRemoveNotice noticeId",
            "consoleCommandRemoveNotice", self)
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
        table.insert(lines, string.format("#%d %s - speed %d, salary %.0f, tractors: %s, skills: %s", candidate.id,
            candidate.name, candidate.workSpeed, candidate.salary,
            TheContractorStaff.formatTierCapability(candidate.tierCapability),
            TheContractorStaff.formatSkills(candidate.skills)))
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

    local snapshot = jobGeneration:getAvailabilitySnapshot(farm.farmId)
    local datableTypes, fulfillableTypes = 0, 0
    for _, entry in ipairs(snapshot) do
        if entry.datable > 0 then
            datableTypes = datableTypes + 1
        end
        if entry.fulfillable > 0 then
            fulfillableTypes = fulfillableTypes + 1
        end
    end

    local hitsPerPeriod = hourlyChance * rollsPerPeriod
    local split
    if datableTypes == 0 then
        split = "no job type has a datable field - every hit is wasted"
    elseif fulfillableTypes == 0 then
        split = string.format("nothing fulfillable - split evenly across the %d types with datable fields",
            datableTypes)
    else
        local share = TheContractorJobGeneration.FULFILLABLE_TYPE_SHARE
        split = string.format("%d%% evenly across the %d fulfillable types, %d%% across all %d types with datable fields; ~%.1f fulfillable offers per period",
            math.floor(share * 100 + 0.5), fulfillableTypes, math.floor((1 - share) * 100 + 0.5), datableTypes,
            hitsPerPeriod * (share + (1 - share) * fulfillableTypes / datableTypes))
    end

    local lines = {
        string.format("Farm %d, period %d day %d: hourly chance %.4f, ~%.1f generation hits per period (%s)",
            farm.farmId, environment.currentPeriod, environment.currentDayInPeriod, hourlyChance, hitsPerPeriod,
            split),
    }
    for _, entry in ipairs(snapshot) do
        table.insert(lines, string.format("  %-9s eligible fields %3d, with target date %3d, fulfillable %3d",
            entry.jobType, entry.candidates, entry.datable, entry.fulfillable))
    end
    return table.concat(lines, "\n")
end

-- Forces one generation hit for a single job type (tryGenerateJob's
-- onlyJobType): a real offer on a real field, priced and dated by the same
-- rules as the hourly roll, so it's safe for testing and for scripting a
-- storyline. Acts on the server directly, like tcJobAvailability - Jobs
-- broadcasts the new job itself. Fails only when no field qualifies for the
-- type right now, or none that does has a workable deadline.
function TheContractor:consoleCommandOfferJob(jobTypeName)
    if not g_currentMission:getIsServer() then return "Server only" end

    local typeList = table.concat(TheContractorJobGeneration.JOB_TYPE_KEYS, ", ")
    if jobTypeName == nil then
        return "Usage: tcOfferJob jobType\nJob types: " .. typeList
    end
    local jobType = TheContractorJobGeneration.findJobType(jobTypeName)
    if jobType == nil then
        return string.format("Unknown job type '%s'. Job types: %s", jobTypeName, typeList)
    end

    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil or farm.farmId == 0 then
        return "Error: No farm found for current player"
    end
    if not self.Company:hasCompany(farm.farmId) then
        return string.format("Error: farm %d has no company yet", farm.farmId)
    end

    local job = self.JobGeneration:tryGenerateJob(farm.farmId, jobType)
    if job ~= nil then
        return string.format("Offered %s job %d on field %d to farm %d (%s, due period %d day %d, skill %d%s)",
            jobType, job.id, job.fieldId, farm.farmId, g_i18n:formatMoney(job.price, 0, true, true),
            job.targetPeriod, job.targetDayInPeriod, job.requiredSkillLevel,
            job.equipmentAvailable and "" or ", farm lacks the equipment")
    end

    local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
    if jobDef.requiresWeeds and not TheContractorJobGeneration.getHasWeeds() then
        return string.format("No %s job possible: weeds are off for this save or map", jobType)
    end
    if jobDef.requiresStones and g_currentMission.missionInfo.stonesEnabled == false then
        return string.format("No %s job possible: stones are switched off for this save", jobType)
    end
    local candidates = #self.JobGeneration:getCandidateFields(farm.farmId, jobDef)
    if candidates == 0 then
        return string.format("No %s job possible right now: no field the farm doesn't own qualifies for it", jobType)
    end
    return string.format("No %s job possible right now: %d field(s) qualify, but none has a workable deadline (crop not ready/predictable in time, or out of season)",
        jobType, candidates)
end

-- The retirement/notice commands below act on the server directly, like
-- tcJobAvailability: they're server-only anyway, and the subsystems
-- broadcast their own changes.
function TheContractor:consoleCommandRetireWorker(workerId, noticeMonths)
    if not g_currentMission:getIsServer() then return "Server only" end

    local numWorkerId = tonumber(workerId)
    local numNoticeMonths = tonumber(noticeMonths or TheContractorStaff.RETIREMENT_NOTICE_MONTHS)
    if numWorkerId == nil or numNoticeMonths == nil or numNoticeMonths < 0 then
        return "Usage: tcRetireWorker workerId [noticeMonths]"
    end

    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil or farm.farmId == 0 then
        return "Error: No farm found for current player"
    end

    local worker = self.Staff:getWorker(farm.farmId, numWorkerId)
    if worker == nil then
        return string.format("Error: farm %d has no worker %d", farm.farmId, numWorkerId)
    end
    if worker:isRetiring() then
        return string.format("%s is already retiring (period %d)", worker.name, worker.retiresAtPeriod)
    end

    self.Staff:announceRetirement(farm.farmId, numWorkerId, math.floor(numNoticeMonths))
    return string.format("%s handed in their notice (%d month(s))", worker.name, math.floor(numNoticeMonths))
end

function TheContractor:consoleCommandBookHoliday(workerId, daysFromNow, days)
    if not g_currentMission:getIsServer() then return "Server only" end

    local numWorkerId = tonumber(workerId)
    local numDaysFromNow = tonumber(daysFromNow or 0)
    local numDays = tonumber(days or 1)
    if numWorkerId == nil or numDaysFromNow == nil or numDaysFromNow < 0 or numDays == nil or numDays < 1 then
        return "Usage: tcBookHoliday workerId [daysFromNow] [days]"
    end

    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil or farm.farmId == 0 then
        return "Error: No farm found for current player"
    end

    local worker = self.Staff:getWorker(farm.farmId, numWorkerId)
    if worker == nil then
        return string.format("Error: farm %d has no worker %d", farm.farmId, numWorkerId)
    end
    if worker:hasHolidayBooked() then
        return string.format("%s already has a holiday booked (%s)", worker.name,
            TCCalendar.formatDayRange(worker.holidayStartDay, worker:getHolidayEndDay()))
    end

    local startDay = g_currentMission.environment.currentMonotonicDay + math.floor(numDaysFromNow)
    self.Holidays:bookHoliday(worker, startDay, math.floor(numDays))
    return string.format("%s booked a holiday: %s", worker.name,
        TCCalendar.formatDayRange(worker.holidayStartDay, worker:getHolidayEndDay()))
end

function TheContractor:consoleCommandPublishNotice(ttlMonths, ...)
    if not g_currentMission:getIsServer() then return "Server only" end

    local text = table.concat({ ... }, " ")
    local numTtl = tonumber(ttlMonths)
    if text == "" or (numTtl == nil and ttlMonths ~= "none") then
        return "Usage: tcPublishNotice ttlMonths|none text..."
    end

    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil or farm.farmId == 0 then
        return "Error: No farm found for current player"
    end

    local noticeId = self.Notices:publish(farm.farmId, text, numTtl)
    return string.format("Published notice %d", noticeId)
end

function TheContractor:consoleCommandRemoveNotice(noticeId)
    if not g_currentMission:getIsServer() then return "Server only" end

    local numNoticeId = tonumber(noticeId)
    if numNoticeId == nil or self.Notices:getNotice(numNoticeId) == nil then
        return "Usage: tcRemoveNotice noticeId (no such notice)"
    end

    self.Notices:remove(numNoticeId)
    return string.format("Removed notice %d", numNoticeId)
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
    tc.Drivers:saveToXmlFile(xmlFile)
    tc.Notices:saveToXmlFile(xmlFile)
    tc.Holidays:saveToXmlFile(xmlFile)

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

    if self.Notices ~= nil then
        self.Notices:stopPeriodTick()
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
        removeConsoleCommand("tcOfferJob")
        removeConsoleCommand("tcRetireWorker")
        removeConsoleCommand("tcBookHoliday")
        removeConsoleCommand("tcPublishNotice")
        removeConsoleCommand("tcRemoveNotice")
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

    if self.Drivers ~= nil then
        self.Drivers:update(dt)
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
