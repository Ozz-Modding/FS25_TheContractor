-- Top-level "Contractor" in-game menu page: four sub-tabs (Overview, Inbox,
-- Calendar, Staff) — Inbox/Calendar/Staff are placeholders later tickets
-- fill in. Structure mirrors FS25_RedTape/src/gui/MenuRedTape.lua's own
-- top-level page + subCategory-tab pattern.

MenuContractor = {}
MenuContractor._mt = Class(MenuContractor, TabbedMenuFrameElement)

-- Overview is tab 1 (and so the default tab on first open): it's the only
-- tab reachable before a farm has a company, since that's where "Create
-- Company" lives. Once a company exists it's the central status page —
-- company name, reputation tier/progress, and (012) active advertising
-- state plus the buy-a-level buttons; job history/reputation-over-time
-- land once 008's data is wired up for display here.
MenuContractor.SUB_CATEGORY = {
    OVERVIEW = 1,
    INBOX = 2,
    CALENDAR = 3,
    STAFF = 4,
}

MenuContractor.HEADER_SLICES = {
    [MenuContractor.SUB_CATEGORY.INBOX] = "gui.icon_ingameMenu_contracts",
    [MenuContractor.SUB_CATEGORY.CALENDAR] = "gui.icon_ingameMenu_calendar",
    [MenuContractor.SUB_CATEGORY.STAFF] = "gui.icon_ingameMenu_animals",
    [MenuContractor.SUB_CATEGORY.OVERVIEW] = "gui.icon_ingameMenu_finances",
}

MenuContractor.HEADER_TITLES = {
    [MenuContractor.SUB_CATEGORY.INBOX] = "tc_header_inbox",
    [MenuContractor.SUB_CATEGORY.CALENDAR] = "tc_header_calendar",
    [MenuContractor.SUB_CATEGORY.STAFF] = "tc_header_staff",
    [MenuContractor.SUB_CATEGORY.OVERVIEW] = "tc_header_overview",
}

-- Same period->month convention as FS25_RedTape/src/RedTape.lua's
-- periodToMonth/monthToString (period 1 == March, wrapping 1-12) — there's
-- no other date-formatting precedent in this codebase yet, so this borrows
-- the sibling mod's directly rather than inventing a second convention.
local function periodToMonth(period)
    local month = period + 2
    if month > 12 then
        month = month - 12
    end
    return month
end

local function formatTargetDate(period, dayInPeriod)
    return string.format("%s %d", g_i18n:getText("ui_month" .. periodToMonth(period)), dayInPeriod)
end

-- In-game years are relative ("Year 1", "Year 2", ...), not a real calendar
-- year — environment.currentYear starts at 1 — so label it the same way
-- vanilla's own save/game-info UI would rather than printing the raw number
-- on its own, which reads as a real-world year.
local function formatYear(year)
    return string.format(g_i18n:getText("tc_calendar_yearLabel"), year)
end

-- Calendar-view-only variant that also shows the year — a Job's own
-- targetPeriod/targetDayInPeriod (used by formatTargetDate above, for the
-- Inbox and calendar-day-job lists) deliberately doesn't carry a year (008's
-- Q23 decision: "period N next year" and "period N now" aren't distinguished
-- in the data model). The Calendar tab's own navigation, though, pages
-- forward from environment.currentYear/currentPeriod by a known offset, so
-- the year here is always locally computable — worth showing since paging
-- from December to January was otherwise ambiguous about which year you'd
-- landed on.
local function formatCalendarDate(period, dayInPeriod, year)
    return string.format("%s %d, %s", g_i18n:getText("ui_month" .. periodToMonth(period)), dayInPeriod,
        formatYear(year))
end

-- Staff (017) — compact per-tier rating for the roster/candidate list column
-- (e.g. "S5 M- L8"), as opposed to Staff.lua's own formatTierCapability
-- (used for the verbose details-panel line instead), which spells out each
-- tier name in full and wouldn't fit a table cell.
local TIER_ABBREVIATIONS = { small = "S", medium = "M", large = "L" }
local function formatTierListCell(tierCapability)
    local parts = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = tierCapability[tier]
        table.insert(parts, TIER_ABBREVIATIONS[tier] .. (rating ~= nil and tostring(rating) or "-"))
    end
    return table.concat(parts, " ")
end

-- Calendar (015): jobs whose state means "on the calendar, worth showing
-- against a date" — accepted/allocated/in_progress (still committed to it)
-- plus missed (committed to it and then blew the deadline — worth keeping
-- visible on that day as a clear "Failed" marker, not disappearing once
-- Jobs:missJob flips the state, which would just look like the job's own
-- record of the day silently forgot it ever existed). Declined jobs never
-- reached that commitment; completed jobs are done and no longer
-- forward-looking. A function rather than a module-scope table, since
-- MenuContractor.lua is sourced before Job.lua (see main.lua's source
-- order) — TheContractorJob.STATE wouldn't exist yet if this ran at load
-- time instead of lazily per call.
local function isCalendarVisibleState(state)
    return state == TheContractorJob.STATE.ACCEPTED or state == TheContractorJob.STATE.ALLOCATED or
        state == TheContractorJob.STATE.IN_PROGRESS or state == TheContractorJob.STATE.MISSED
end

function MenuContractor.new(i18n)
    local self = MenuContractor:superClass().new(nil, MenuContractor._mt)
    self.name = "MenuContractor"
    self.i18n = i18n
    self.menuButtonInfo = {}

    return self
end

function MenuContractor:initialize()
    MenuContractor:superClass().initialize(self)

    for i, tab in pairs(self.subCategoryTabs) do
        tab:getDescendantByName("background").getIsSelected = function()
            return i == self.subCategoryPaging:getState()
        end
        function tab.getIsSelected()
            return i == self.subCategoryPaging:getState()
        end
    end

    self.btnBack = {
        inputAction = InputAction.MENU_BACK
    }
    self.btnNextPage = {
        inputAction = InputAction.MENU_PAGE_NEXT,
        text = g_i18n:getText("ui_ingameMenuNext"),
        callback = self.onPageNext
    }
    self.btnPrevPage = {
        inputAction = InputAction.MENU_PAGE_PREV,
        text = g_i18n:getText("ui_ingameMenuPrev"),
        callback = self.onPagePrevious
    }

    self.btnCreateCompany = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_actions_createButton"),
        callback = function()
            self:onClickCreateCompany()
        end
    }

    -- One button per 012 advertising level (see Advertising.lua's LEVELS).
    -- `.disabled` is mutated in place from refreshCompanyState (funds/tier
    -- gating can change at any time) — same pattern as FS25_RedTape's
    -- btnSchemeAction.
    self.btnBuyLocalAd = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_advertising_buyButton_localNewspaper"),
        callback = function()
            self:onClickBuyAdvertising("localNewspaper")
        end
    }
    self.btnBuyRegionalAd = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("tc_advertising_buyButton_regionalNewspaper"),
        callback = function()
            self:onClickBuyAdvertising("regionalNewspaper")
        end
    }
    self.btnBuyTvAd = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("tc_advertising_buyButton_tv"),
        callback = function()
            self:onClickBuyAdvertising("tv")
        end
    }

    -- Inbox (013) accept/decline — same bottom-bar pattern as the
    -- advertising buttons above, only appended while a job row is selected
    -- (see getMenuButtonInfo).
    self.btnAcceptJob = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_inbox_acceptButton"),
        callback = function()
            self:onClickAcceptJob()
        end
    }
    self.btnDeclineJob = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("tc_inbox_declineButton"),
        callback = function()
            self:onClickDeclineJob()
        end
    }

    -- Negotiation (014) — counter-offer a price on the selected job. Same
    -- bottom-bar pattern as accept/decline; available whenever a job is
    -- selected since the Inbox only ever lists offered/negotiating jobs
    -- (see refreshInboxState).
    self.btnCounterOffer = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("tc_inbox_counterButton"),
        callback = function()
            self:onClickCounterOffer()
        end
    }

    self.menuButtonInfoDefault = { self.btnBack, self.btnNextPage, self.btnPrevPage }
    for _, category in pairs(MenuContractor.SUB_CATEGORY) do
        self.menuButtonInfo[category] = self.menuButtonInfoDefault
    end

    -- Overview tab gets the Create Company button appended, but only while
    -- the farm has no company yet (see getMenuButtonInfo) — following
    -- FS25_RedTape/src/gui/MenuRedTape.lua's own bottom-bar action-button
    -- pattern (e.g. its Grants tab), rather than an in-page GUI button.
    self.menuButtonInfoOverviewNoCompany = { self.btnBack, self.btnNextPage, self.btnPrevPage, self.btnCreateCompany }

    -- Once a company exists, the Create Company button is replaced by the
    -- three advertising purchase buttons.
    self.menuButtonInfoOverviewWithCompany = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnBuyTvAd, self.btnBuyRegionalAd, self.btnBuyLocalAd }

    self.menuButtonInfoInboxWithSelection = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnAcceptJob, self.btnDeclineJob, self.btnCounterOffer }

    -- Staff (017) — hire a selected candidate, or release a selected roster
    -- worker. Mutually exclusive: selecting in one of staffTable's two views
    -- (see onClickStaffView) always clears the other view's selection, so
    -- only one of these two button sets is ever relevant at a time (see
    -- getMenuButtonInfo).
    self.btnHireWorker = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_staff_hireButton"),
        callback = function()
            self:onClickHireWorker()
        end
    }
    self.btnReleaseWorker = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_staff_releaseButton"),
        callback = function()
            self:onClickReleaseWorker()
        end
    }
    self.menuButtonInfoStaffWithCandidateSelection = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnHireWorker }
    self.menuButtonInfoStaffWithRosterSelection = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnReleaseWorker }

-- Jumps straight back to the current in-game month regardless of how far
    -- forward the player paged via the in-page "< Month Year >" selector
    -- (see calendarPeriodSelector in MenuContractor.xml, which replaced the
    -- old Prev/Next Period bottom-bar buttons for month navigation) —
    -- disabled (see refreshCalendarState) while already there, same
    -- ".disabled mutated in place, then dirty the button bar" pattern as
    -- everywhere else in this file.
    self.btnCalendarToday = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_calendar_jumpToToday"),
        callback = function()
            self:onClickCalendarToday()
        end
    }

    -- Calendar tab always gets the Jump to Today button (no selection-gated
    -- variant needed — day selection is just a list click, no bottom-bar
    -- action attached to it, unlike Inbox's accept/decline/counter).
    self.menuButtonInfo[MenuContractor.SUB_CATEGORY.CALENDAR] = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnCalendarToday }

    -- Allocation (018) — opens the allocation panel for whichever job is
    -- selected in calendarDayJobsTable, only shown while that job is still
    -- `accepted` (an allocated/in_progress/missed job has nothing left to
    -- allocate). Confirm/Cancel replace the whole button set while the panel
    -- itself is open (see getMenuButtonInfo) — Jump to Today doesn't make
    -- sense mid-flow, so it's dropped rather than kept alongside.
    self.btnAllocateJob = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("tc_allocation_allocateButton"),
        callback = function()
            self:onClickOpenAllocation()
        end
    }
    self.btnAllocateConfirm = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_allocation_confirmButton"),
        callback = function()
            self:onClickConfirmAllocation()
        end
    }
    self.btnAllocateCancel = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("tc_allocation_cancelButton"),
        callback = function()
            self:onClickCancelAllocation()
        end
    }
    -- Selects/deselects the equipment row currently highlighted in
    -- allocationEquipmentTable — one button for both, its label flipped by
    -- updateAllocationEquipmentToggleButton. A bottom-bar action rather
    -- than reacting to list clicks, so it works the same on a gamepad.
    self.btnAllocateToggleEquipment = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("tc_allocation_selectEquipmentButton"),
        callback = function()
            self:onClickToggleAllocationEquipment()
        end
    }
    self.menuButtonInfoCalendarWithAllocatableJob = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnCalendarToday, self.btnAllocateJob }
    -- Same idea for allocationWorkerTable's highlighted row (035): workers
    -- are picked with a button rather than by highlighting, since a
    -- haulage job takes two of them. See onClickToggleAllocationWorker.
    self.btnAllocateToggleWorker = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("tc_allocation_selectWorkerButton"),
        callback = function()
            self:onClickToggleAllocationWorker()
        end
    }
    self.menuButtonInfoCalendarAllocating = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnAllocateConfirm, self.btnAllocateCancel, self.btnAllocateToggleWorker }
    self.menuButtonInfoCalendarAllocatingWithEquipment = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnAllocateConfirm, self.btnAllocateCancel, self.btnAllocateToggleWorker,
        self.btnAllocateToggleEquipment }

    self.calendarPeriodOffset = 0
    self.selectedCalendarDay = nil
    self.calendarDayRows = {}
    self.calendarDayJobs = {}
    self.selectedCalendarDayJobId = nil

    -- Allocation (018): opened via btnAllocateJob against whichever job is
    -- selected in calendarDayJobsTable, closed via confirm/cancel. nil
    -- allocatingJobId means the day-detail panel shows the plain job list
    -- (calendarDayJobsContainer); non-nil swaps it for allocationContainer
    -- (see refreshAllocationState/onClickCancelAllocation). Worker selection
    -- is an ordered list of worker ids (035 - a haulage job takes two), empty
    -- meaning "do it myself" (row 1 of allocationWorkerTable, workerId nil,
    -- matching Job.assignedWorkerId's own nil-means-player convention).
    -- Equipment selection is a set keyed by row key (role:vehicleId - a
    -- tractor can be listed both as a field tractor and as the haulage
    -- tractor), since a job may need more than one piece of equipment (an
    -- implement plus a tractor to pull it) and SmoothList only natively
    -- supports a single highlighted index.
    self.allocatingJobId = nil
    self.allocationWorkerRows = {}
    self.allocationEquipmentRows = {}
    self.allocationSelectedWorkerIds = {}
    self.allocationSelectedEquipmentKeys = {}
    self.allocationHighlightedWorkerIndex = nil
    self.allocationHighlightedEquipmentIndex = nil

    self.inboxJobs = {}
    self.selectedInboxJobId = nil
    -- Client-side-only transcript of negotiation exchanges, keyed by job id —
    -- flavor text derived from each round's outcome, not synced/persisted
    -- (same "not tracked as durable state" treatment 013 gives the HUD's
    -- unread-job tracking). Resets each session.
    self.negotiationHistory = {}

    -- Staff (017): staffTable is reused for both the Roster and Candidates
    -- views (see onClickStaffView/refreshStaffState) rather than two
    -- separate SmoothLists, since only one view is ever visible at a time —
    -- same "one widget, branch on which logical list is active" approach as
    -- calendarDayTable/calendarDayJobsTable already use for two genuinely
    -- simultaneous lists.
    self.staffView = "roster"
    self.rosterWorkers = {}
    self.candidateList = {}
    self.selectedRosterWorkerId = nil
    self.selectedCandidateId = nil

    self.inboxTable:setDataSource(self)
    self.inboxTable:setDelegate(self)

    self.calendarDayTable:setDataSource(self)
    self.calendarDayTable:setDelegate(self)
    self.calendarDayJobsTable:setDataSource(self)
    self.calendarDayJobsTable:setDelegate(self)

    self.allocationWorkerTable:setDataSource(self)
    self.allocationWorkerTable:setDelegate(self)
    self.allocationEquipmentTable:setDataSource(self)
    self.allocationEquipmentTable:setDelegate(self)

    self.staffTable:setDataSource(self)
    self.staffTable:setDelegate(self)
end

function MenuContractor:getMenuButtonInfo()
    local state = self.subCategoryPaging:getState()

    if state == MenuContractor.SUB_CATEGORY.OVERVIEW then
        if not self:hasCompany() then
            return self.menuButtonInfoOverviewNoCompany
        end
        return self.menuButtonInfoOverviewWithCompany
    end

    if state == MenuContractor.SUB_CATEGORY.INBOX and self.selectedInboxJobId ~= nil then
        return self.menuButtonInfoInboxWithSelection
    end

    -- No period-nav buttons while the tab is showing the "locked" prompt
    -- instead of real calendar content (see refreshCompanyState).
    if state == MenuContractor.SUB_CATEGORY.CALENDAR and not self:hasCompany() then
        return self.menuButtonInfoDefault
    end

    if state == MenuContractor.SUB_CATEGORY.CALENDAR and self:hasCompany() then
        if self.allocatingJobId ~= nil then
            if self.allocationEquipmentRows[self.allocationHighlightedEquipmentIndex] ~= nil then
                return self.menuButtonInfoCalendarAllocatingWithEquipment
            end
            return self.menuButtonInfoCalendarAllocating
        end

        local selectedJob = self:getSelectedCalendarDayJob()
        if selectedJob ~= nil and selectedJob.state == TheContractorJob.STATE.ACCEPTED then
            return self.menuButtonInfoCalendarWithAllocatableJob
        end
    end

    if state == MenuContractor.SUB_CATEGORY.STAFF and self:hasCompany() then
        if self.staffView == "candidates" and self.selectedCandidateId ~= nil then
            return self.menuButtonInfoStaffWithCandidateSelection
        end
        if self.staffView == "roster" and self.selectedRosterWorkerId ~= nil then
            return self.menuButtonInfoStaffWithRosterSelection
        end
    end

    return self.menuButtonInfo[state]
end

function MenuContractor:onFrameOpen()
    local texts = {}
    for k, tab in pairs(self.subCategoryTabs) do
        tab:setVisible(true)
        table.insert(texts, tostring(k))
    end
    self.subCategoryBox:invalidateLayout()
    self.subCategoryPaging:setTexts(texts)
    self.subCategoryPaging:setSize(self.subCategoryBox.maxFlowSize + 140 * g_pixelSizeScaledX)

    self:updateContent()
    self:setMenuButtonInfoDirty()
end

function MenuContractor:hasCompany()
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Company == nil then
        return false
    end
    return tc.Company:hasCompany(g_currentMission:getFarmId())
end

-- Inbox/Calendar/Staff stay visible as tabs (see main.lua's note on the
-- always-visible top-level predicate) but their content is gated on the
-- farm having a company, until the real per-tab content lands in later
-- tickets. The Overview tab itself swaps between a "no company yet" prompt
-- and the company name/reputation-rank status once one exists.
function MenuContractor:refreshCompanyState()
    local hasCompany = self:hasCompany()

    self.textNoCompany:setVisible(not hasCompany)
    self.textCompanyName:setVisible(hasCompany)
    self.nextRankText:setVisible(hasCompany)

    if not hasCompany then
        self.inboxListContainer:setVisible(false)
        self.inboxEmptyText:setVisible(false)
        self.inboxDetailsBox:setVisible(false)
        self.selectedInboxJobId = nil

        self.calendarContainer:setVisible(false)
        self.calendarDayDetailsBox:setVisible(false)
        self.selectedCalendarDay = nil
        self.selectedCalendarDayJobId = nil
        self.allocatingJobId = nil

        self.staffViewSelector:setVisible(false)
        self.staffHeaderRow:setVisible(false)
        self.staffEmptyText:setVisible(false)
        self.staffListContainer:setVisible(false)
        self.staffDetailsBox:setVisible(false)
        self.selectedRosterWorkerId = nil
        self.selectedCandidateId = nil
    end

    self.textAdvertisingHeading:setVisible(hasCompany)
    self.textAdvertisingStatus:setVisible(hasCompany)
    self.textJobHistoryPlaceholder:setVisible(hasCompany)
    self.progressBox:setVisible(hasCompany)
    self.textCurrentJobsHeading:setVisible(hasCompany)
    self.textCurrentJobs:setVisible(hasCompany)

    if hasCompany then
        local farmId = g_currentMission:getFarmId()
        local tc = g_currentMission.TheContractor
        local name = tc.Company:getCompanyName(farmId)
        self.textCompanyName:setText(name)

        local progress = tc.Reputation:getProgress(farmId)
        self.rankTierText:setText(g_i18n:getText("tc_reputationTier_" .. progress.tier.key))

        if progress.nextTier ~= nil then
            self.progressText:setText(string.format("%d/%d", progress.score, progress.nextTier.minScore))
            self.nextRankText:setText(string.format(g_i18n:getText("tc_overview_nextRank"),
                g_i18n:getText("tc_reputationTier_" .. progress.nextTier.key)))
        else
            self.progressText:setText(g_i18n:getText("tc_overview_rankMax"))
            self.nextRankText:setText(string.format(g_i18n:getText("tc_overview_nextRank"),
                g_i18n:getText("tc_overview_nextRankNone")))
        end

        local fullWidth = self.progressBarBg.size[1] - self.progressBar.margin[1] * 2
        local minProgressBarWidthRatio = self.progressBar.startSize[1] * 2 / fullWidth
        local progressBarRatio = math.max(progress.progressPercentage, minProgressBarWidthRatio)
        self.progressBar:setSize(fullWidth * math.min(progressBarRatio, 1), nil)

        self:refreshAdvertisingState(farmId, tc.Advertising)
        self:refreshInboxState(farmId, tc.Jobs)
        self:refreshCalendarState(farmId, tc.Jobs)
        self:refreshCurrentJobsState(farmId, tc.Jobs)
        self:refreshStaffState(farmId, tc.Staff, tc.Jobs)
    end

    self.placeholderInbox:setVisible(not hasCompany)
    self.calendarContainer:setVisible(hasCompany)

    local lockedText = g_i18n:getText("tc_placeholder_locked")
    self.placeholderCalendar:setVisible(not hasCompany)
    self.placeholderCalendar:setText(lockedText)
    self.placeholderStaff:setVisible(not hasCompany)
    self.placeholderStaff:setText(lockedText)
end

-- Overview tab's at-a-glance work list, next to the reputation progress
-- panel: allocated/in_progress jobs (accepted-but-unallocated isn't "current
-- work" yet, that's what the Calendar's unallocated-count warning is for),
-- one line each as "Field <n>: <type> - <percent>%". completionPercentage is
-- kept live by TCJobProgress's background poll (019).
function MenuContractor:refreshCurrentJobsState(farmId, jobs)
    local activeJobs = {}
    for _, job in ipairs(jobs:getJobsByState(farmId, TheContractorJob.STATE.ALLOCATED)) do
        table.insert(activeJobs, job)
    end
    for _, job in ipairs(jobs:getJobsByState(farmId, TheContractorJob.STATE.IN_PROGRESS)) do
        table.insert(activeJobs, job)
    end
    table.sort(activeJobs, function(a, b)
        return a.id < b.id
    end)

    if #activeJobs == 0 then
        self.textCurrentJobs:setText(g_i18n:getText("tc_overview_currentJobsEmpty"))
        return
    end

    local lines = {}
    for _, job in ipairs(activeJobs) do
        local field = g_fieldManager:getFieldById(job.fieldId)
        local fieldLabel = field ~= nil and field:getName() or tostring(job.fieldId)
        local line = string.format(g_i18n:getText("tc_overview_currentJobLine"), fieldLabel,
            job:getTypeText(), math.floor(job.completionPercentage))
        -- Player-driven haulage (035): delivery counts towards done too.
        if job:needsPlayerDelivery() and job.requiredLiters > 0 then
            line = line .. string.format(g_i18n:getText("tc_overview_deliveredSuffix"),
                math.floor(100 * job.deliveredLiters / job.requiredLiters))
        end
        table.insert(lines, line)
    end
    self.textCurrentJobs:setText(table.concat(lines, "\n"))
end

-- Staff (017) — rebuilds both the roster and candidate-pool lists (sorted by
-- id, oldest first — a hire/candidate-add order, not particularly meaningful
-- but stable frame to frame, same non-architectural ordering call as
-- refreshInboxState's). Both lists are rebuilt every refresh regardless of
-- which view is currently showing so that switching views via
-- onClickStaffView never shows stale data. staffTable itself only ever
-- displays whichever one staffView currently points at (see
-- getNumberOfItemsInSection/populateCellForItemInSection).
function MenuContractor:refreshStaffState(farmId, staff, jobs)
    self.rosterWorkers = staff:getRoster(farmId)
    table.sort(self.rosterWorkers, function(a, b)
        return a.id < b.id
    end)

    self.candidateList = staff:getCandidatePool()
    table.sort(self.candidateList, function(a, b)
        return a.id < b.id
    end)

    self.staffViewSelector:setTexts({ g_i18n:getText("tc_staff_viewRoster"), g_i18n:getText("tc_staff_viewCandidates") })
    self.staffViewSelector:setState(self.staffView == "candidates" and 2 or 1)
    self.staffViewSelector:setVisible(true)
    self.staffHeaderRow:setVisible(true)

    -- Job column only makes sense for the roster view (candidates were never
    -- assigned anything) — blank it out entirely in the candidates view
    -- rather than showing a column full of "None".
    self.staffHeaderCol4:setText(self.staffView == "candidates" and g_i18n:getText("tc_staff_columnCost") or
        g_i18n:getText("tc_staff_columnStatus"))
    self.staffHeaderCol5:setText(self.staffView == "candidates" and "" or g_i18n:getText("tc_staff_columnJob"))

    local list = self.staffView == "candidates" and self.candidateList or self.rosterWorkers
    local hasItems = #list > 0
    self.staffEmptyText:setText(self.staffView == "candidates" and g_i18n:getText("tc_staff_candidatesEmpty") or
        g_i18n:getText("tc_staff_rosterEmpty"))
    self.staffEmptyText:setVisible(not hasItems)
    self.staffListContainer:setVisible(hasItems)
    self.staffTable:reloadData()

    -- Keep each view's own selection if it's still present (e.g. a refresh
    -- triggered by something unrelated), otherwise drop it — same pattern as
    -- refreshInboxState/refreshCalendarState's selection handling.
    local rosterStillPresent = false
    for _, worker in ipairs(self.rosterWorkers) do
        if worker.id == self.selectedRosterWorkerId then
            rosterStillPresent = true
        end
    end
    if not rosterStillPresent then
        self.selectedRosterWorkerId = nil
    end

    local candidateStillPresent = false
    for _, candidate in ipairs(self.candidateList) do
        if candidate.id == self.selectedCandidateId then
            candidateStillPresent = true
        end
    end
    if not candidateStillPresent then
        self.selectedCandidateId = nil
    end

    self:updateStaffDetails()
end

function MenuContractor:getSelectedRosterWorker()
    for _, worker in ipairs(self.rosterWorkers) do
        if worker.id == self.selectedRosterWorkerId then
            return worker
        end
    end
    return nil
end

function MenuContractor:getSelectedCandidate()
    for _, candidate in ipairs(self.candidateList) do
        if candidate.id == self.selectedCandidateId then
            return candidate
        end
    end
    return nil
end

-- The job a worker is currently committed to, if any (allocated/in_progress
-- — mirrors refreshCurrentJobsState's own "current work" definition),
-- whether operating or hauling (035).
function MenuContractor:getAssignedJobLine(farmId, jobs, workerId)
    for _, job in ipairs(jobs:getAllJobs(farmId)) do
        if (job.assignedWorkerId == workerId or job.haulerWorkerId == workerId) and
            (job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS) then
            local field = g_fieldManager:getFieldById(job.fieldId)
            local fieldLabel = field ~= nil and field:getName() or tostring(job.fieldId)
            return string.format(g_i18n:getText("tc_staff_jobLine"), job:getTypeText(),
                fieldLabel)
        end
    end
    return nil
end

function MenuContractor:populateStaffCell(index, cell)
    if self.staffView == "candidates" then
        local candidate = self.candidateList[index]
        if candidate == nil then
            return
        end

        cell:getAttribute("name"):setText(candidate.name)
        cell:getAttribute("workSpeed"):setText(tostring(candidate.workSpeed))
        cell:getAttribute("tier"):setText(formatTierListCell(candidate.tierCapability))
        cell:getAttribute("col4"):setText(g_i18n:formatMoney(candidate.hireCost, 0, true, true))
        cell:getAttribute("col5"):setText("")
        return
    end

    local worker = self.rosterWorkers[index]
    if worker == nil then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local jobLine = self:getAssignedJobLine(farmId, g_currentMission.TheContractor.Jobs, worker.id)

    cell:getAttribute("name"):setText(worker.name)
    cell:getAttribute("workSpeed"):setText(tostring(worker.workSpeed))
    cell:getAttribute("tier"):setText(formatTierListCell(worker.tierCapability))
    cell:getAttribute("col4"):setText(g_i18n:getText("tc_staff_status_" .. worker.status))
    cell:getAttribute("col5"):setText(jobLine or "")
end

function MenuContractor:updateStaffDetails()
    self:setMenuButtonInfoDirty()

    local worker = self.staffView == "roster" and self:getSelectedRosterWorker() or self:getSelectedCandidate()
    self.staffDetailsBox:setVisible(worker ~= nil)
    if worker == nil then
        return
    end

    self.staffDetailTitle:setText(worker.name)
    self.staffDetailWorkSpeed:setText(string.format(g_i18n:getText("tc_staff_detailWorkSpeed"), worker.workSpeed))
    self.staffDetailTier:setText(string.format(g_i18n:getText("tc_staff_detailTier"),
        TheContractorStaff.formatTierCapability(worker.tierCapability)))

    if self.staffView == "candidates" then
        self.staffDetailStatusOrCost:setText(string.format(g_i18n:getText("tc_staff_detailCost"),
            g_i18n:formatMoney(worker.hireCost, 0, true, true)))
        self.staffDetailJob:setText("")
    else
        self.staffDetailStatusOrCost:setText(string.format(g_i18n:getText("tc_staff_detailStatus"),
            g_i18n:getText("tc_staff_status_" .. worker.status)))

        local farmId = g_currentMission:getFarmId()
        local jobLine = self:getAssignedJobLine(farmId, g_currentMission.TheContractor.Jobs, worker.id)
        self.staffDetailJob:setText(string.format(g_i18n:getText("tc_staff_detailJob"),
            jobLine or g_i18n:getText("tc_staff_detailJobNone")))
    end
end

-- The only way to switch between Roster and Candidates — same "in-page
-- MultiTextOption, not a bottom-bar button" pattern as
-- calendarPeriodSelector. Switching views clears the *other* view's
-- selection's relevance (kept in memory, just no longer driving the details
-- box/button bar) by virtue of updateStaffDetails/getMenuButtonInfo both
-- keying off self.staffView, not by actually discarding
-- selectedRosterWorkerId/selectedCandidateId — so flipping back and forth
-- remembers where you were in each list.
function MenuContractor:onClickStaffView()
    self.staffView = self.staffViewSelector:getState() == 2 and "candidates" or "roster"
    self:refreshStaffState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Staff,
        g_currentMission.TheContractor.Jobs)
end

-- Funds-check-then-confirm pattern (same as onClickBuyAdvertising): the pool
-- is a shared, contested resource (016), so canAffordHire is re-checked here
-- purely as a friendly local pre-check — the server re-validates both
-- funds and pool membership itself regardless (the actual MP race point).
function MenuContractor:onClickHireWorker()
    local candidate = self:getSelectedCandidate()
    if candidate == nil then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local staff = g_currentMission.TheContractor.Staff

    if not staff:canAffordHire(farmId, candidate.hireCost) then
        InfoDialog.show(g_i18n:getText("tc_staff_hireCannotAfford"))
        return
    end

    local dialogPrompt = string.format(g_i18n:getText("tc_staff_hireConfirm"), candidate.name,
        g_i18n:formatMoney(candidate.hireCost, 0, true, true))

    YesNoDialog.show(function(target, clickOk)
        if not clickOk then
            return
        end

        g_client:getServerConnection():sendEvent(TCHireWorkerEvent.new(farmId, candidate.id))

        -- Same "synchronous for host/SP, catches up on next refresh for a
        -- remote client" caveat as respondToSelectedInboxJob/sendCounterOffer.
        target.selectedCandidateId = nil
        target:refreshStaffState(farmId, g_currentMission.TheContractor.Staff, g_currentMission.TheContractor.Jobs)
    end, self, dialogPrompt)
end

function MenuContractor:onClickReleaseWorker()
    local worker = self:getSelectedRosterWorker()
    if worker == nil then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local dialogPrompt = string.format(g_i18n:getText("tc_staff_releaseConfirm"), worker.name)

    YesNoDialog.show(function(target, clickOk)
        if not clickOk then
            return
        end

        g_client:getServerConnection():sendEvent(TCReleaseWorkerEvent.new(farmId, worker.id))

        target.selectedRosterWorkerId = nil
        target:refreshStaffState(farmId, g_currentMission.TheContractor.Staff, g_currentMission.TheContractor.Jobs)
    end, self, dialogPrompt)
end

-- Rebuilds the Inbox job list (offered/negotiating, newest first by job id —
-- the ticket leaves the exact ordering as a non-architectural decision) and
-- refreshes the selected job's detail panel. Called on frame open, tab
-- switch (updateContent), and after accept/decline locally applies.
function MenuContractor:refreshInboxState(farmId, jobs)
    self.inboxJobs = {}
    for _, job in ipairs(jobs:getJobsByState(farmId, TheContractorJob.STATE.OFFERED)) do
        table.insert(self.inboxJobs, job)
    end
    for _, job in ipairs(jobs:getJobsByState(farmId, TheContractorJob.STATE.NEGOTIATING)) do
        table.insert(self.inboxJobs, job)
    end
    table.sort(self.inboxJobs, function(a, b)
        return a.id > b.id
    end)

    local hasJobs = #self.inboxJobs > 0
    self.inboxListContainer:setVisible(hasJobs)
    self.inboxEmptyText:setVisible(not hasJobs)
    self.inboxTable:reloadData()

    -- Keep the current selection if that job is still in the list (e.g. a
    -- refresh triggered by something unrelated), otherwise drop it.
    local stillPresent = false
    for _, job in ipairs(self.inboxJobs) do
        if job.id == self.selectedInboxJobId then
            stillPresent = true
        end
    end
    if not stillPresent then
        self.selectedInboxJobId = nil
    end

    self:updateInboxDetails()
end

function MenuContractor:getSelectedInboxJob()
    for _, job in ipairs(self.inboxJobs) do
        if job.id == self.selectedInboxJobId then
            return job
        end
    end
    return nil
end

function MenuContractor:updateInboxDetails()
    local job = self:getSelectedInboxJob()
    self.inboxDetailsBox:setVisible(job ~= nil)
    self:setMenuButtonInfoDirty()

    if job == nil then
        return
    end

    self.inboxDetailTitle:setText(job:getDisplayTitle())

    local field = g_fieldManager:getFieldById(job.fieldId)
    self.inboxDetailField:setText(string.format(g_i18n:getText("tc_inbox_detailField"),
        field ~= nil and field:getName() or tostring(job.fieldId)))

    self.inboxDetailTargetDate:setText(string.format(g_i18n:getText("tc_inbox_detailTargetDate"),
        formatTargetDate(job.targetPeriod, job.targetDayInPeriod)))

    self.inboxDetailSkill:setText(string.format(g_i18n:getText("tc_inbox_detailSkill"), job.requiredSkillLevel))

    self.inboxDetailPrice:setText(string.format(g_i18n:getText("tc_inbox_detailPrice"),
        g_i18n:formatMoney(job.price, 0, true, true)))

    -- Live against the current fleet rather than job.equipmentAvailable
    -- (a snapshot from generation time), so buying the missing piece shows
    -- up here straight away - and names exactly what's missing.
    local missingOwned = g_currentMission.TheContractor.Allocation:getMissingEquipment(g_currentMission:getFarmId(), job)
    if #missingOwned == 0 then
        self.inboxDetailEquipment:setText(g_i18n:getText("tc_inbox_equipmentAvailable"))
    else
        self.inboxDetailEquipment:setText(string.format(g_i18n:getText("tc_inbox_equipmentMissing"),
            TCEquipmentClass.getMissingEquipmentText(missingOwned, job.jobType, job:getCropTitle())))
    end

    -- Harvest & haul (035): where the crop has to go.
    if job.includesHaulage then
        self.inboxDetailHaulage:setText(string.format(g_i18n:getText("tc_inbox_detailHaulage"),
            job.deliveryStationName or "?"))
    else
        self.inboxDetailHaulage:setText("")
    end

    local history = self.negotiationHistory[job.id]
    local latestMessage = history ~= nil and history[#history] or nil
    self.inboxNegotiationLog:setText(latestMessage or "")
    self.inboxNegotiationLog:setVisible(latestMessage ~= nil)
end

-- SmoothList dataSource/delegate, shared across inboxTable, calendarDayTable,
-- and calendarDayJobsTable (see initialize's setDataSource/setDelegate) —
-- one flat section each, no section headers, same shape as FS25_RedTape's
-- table renderers just implemented directly on the frame since there's only
-- ever the one list per table.
function MenuContractor:getNumberOfSections(list)
    return 1
end

function MenuContractor:getNumberOfItemsInSection(list, section)
    if list == self.calendarDayTable then
        return #self.calendarDayRows
    elseif list == self.calendarDayJobsTable then
        return #self.calendarDayJobs
    elseif list == self.allocationWorkerTable then
        return #self.allocationWorkerRows
    elseif list == self.allocationEquipmentTable then
        return #self.allocationEquipmentRows
    elseif list == self.staffTable then
        return self.staffView == "candidates" and #self.candidateList or #self.rosterWorkers
    end
    return #self.inboxJobs
end

function MenuContractor:populateCellForItemInSection(list, section, index, cell)
    if list == self.calendarDayTable then
        self:populateCalendarDayCell(index, cell)
        return
    elseif list == self.calendarDayJobsTable then
        self:populateCalendarDayJobCell(index, cell)
        return
    elseif list == self.allocationWorkerTable then
        self:populateAllocationWorkerCell(index, cell)
        return
    elseif list == self.allocationEquipmentTable then
        self:populateAllocationEquipmentCell(index, cell)
        return
    elseif list == self.staffTable then
        self:populateStaffCell(index, cell)
        return
    end

    local job = self.inboxJobs[index]
    if job == nil then
        return
    end

    cell:getAttribute("jobType"):setText(job:getDisplayTitle())

    local field = g_fieldManager:getFieldById(job.fieldId)
    cell:getAttribute("field"):setText(field ~= nil and field:getName() or tostring(job.fieldId))

    cell:getAttribute("targetDate"):setText(formatTargetDate(job.targetPeriod, job.targetDayInPeriod))
    cell:getAttribute("price"):setText(g_i18n:formatMoney(job.price, 0, true, true))

    -- Live, same reasoning as updateInboxDetails.
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    local equipmentCell = cell:getAttribute("equipment")
    if jobDef == nil or g_currentMission.TheContractor.JobGeneration:canFulfill(g_currentMission:getFarmId(), jobDef,
            job:getFruitTypeIndex()) then
        equipmentCell:setText(g_i18n:getText("tc_inbox_equipmentYes"))
        equipmentCell:setTextColor(0.6, 1, 0.6, 1)
    else
        equipmentCell:setText(g_i18n:getText("tc_inbox_equipmentNo"))
        equipmentCell:setTextColor(1, 0.45, 0.45, 1)
    end
end

function MenuContractor:onListSelectionChanged(list, section, index)
    if list == self.calendarDayTable then
        local row = self.calendarDayRows[index]
        self.selectedCalendarDay = row ~= nil and row.day or nil
        self:updateCalendarDayDetails()
        return
    end

    if list == self.calendarDayJobsTable then
        local job = self.calendarDayJobs[index]
        self.selectedCalendarDayJobId = job ~= nil and job.id or nil
        self:setMenuButtonInfoDirty()
        return
    end

    -- Allocation (018) worker picker: row 1 is always the synthetic
    -- "Myself" entry (workerId nil). Like the equipment picker below,
    -- moving through the list only tracks the highlighted row - picking is
    -- btnAllocateToggleWorker's job (035), and the same no-reload rule
    -- applies.
    if list == self.allocationWorkerTable then
        self.allocationHighlightedWorkerIndex = index
        self:updateAllocationWorkerToggleButton()
        return
    end

    -- Allocation (018) equipment picker: moving through the list only
    -- tracks which row is highlighted — selecting/deselecting it for the job
    -- is btnAllocateToggleEquipment's job (see
    -- onClickToggleAllocationEquipment). Must stay side-effect free:
    -- SmoothListElement:reloadData re-raises this with the current index,
    -- so reloading from here would recurse until stack overflow.
    if list == self.allocationEquipmentTable then
        self.allocationHighlightedEquipmentIndex = index
        self:updateAllocationEquipmentToggleButton()
        return
    end

    if list == self.staffTable then
        if self.staffView == "candidates" then
            local candidate = self.candidateList[index]
            self.selectedCandidateId = candidate ~= nil and candidate.id or nil
        else
            local worker = self.rosterWorkers[index]
            self.selectedRosterWorkerId = worker ~= nil and worker.id or nil
        end
        self:updateStaffDetails()
        return
    end

    if list ~= self.inboxTable then
        return
    end

    local job = self.inboxJobs[index]
    self.selectedInboxJobId = job ~= nil and job.id or nil
    self:updateInboxDetails()
end

-- Calendar (015) — a real date grid, one period ("month") visible at a
-- time, paged forward/back via the in-page "< Month Year >" selector (see
-- onClickCalendarPeriodSelector). Acceptance and allocation are
-- decoupled (Q25): a day's row shows how many of that day's jobs are still
-- unallocated (accepted but no worker/equipment yet, per 018) so the player
-- notices overbooking before it becomes a problem, without gating anything
-- here — allocation itself is 018's flow.
--
-- Offset is bounded to [0, PERIODS_IN_YEAR - 1]: Job (008) only stores
-- targetPeriod/targetDayInPeriod, not a year, so period N next year is
-- indistinguishable from period N right now in the data we have to render —
-- paging a further year around would just repeat the same view.
function MenuContractor:getCalendarViewPeriod()
    local environment = g_currentMission.environment
    return (environment.currentPeriod - 1 + self.calendarPeriodOffset) % Environment.PERIODS_IN_YEAR + 1
end

-- Companion to getCalendarViewPeriod: whether paging calendarPeriodOffset
-- periods forward from the current one crossed a year boundary (e.g.
-- December -> January), so the two always agree on which "January" is
-- meant. See formatCalendarDate's comment for why this is safe to compute
-- here but not for a stored Job's targetPeriod.
function MenuContractor:getCalendarViewYear()
    local environment = g_currentMission.environment
    local yearsForward = math.floor((environment.currentPeriod - 1 + self.calendarPeriodOffset) / Environment.PERIODS_IN_YEAR)
    return environment.currentYear + yearsForward
end

function MenuContractor:refreshCalendarState(farmId, jobs)
    -- Day/period navigation always drops any in-progress allocation (018) —
    -- the panel is scoped to one specific day's job, so paging away from it
    -- no longer makes sense. onClickConfirmAllocation/onClickCancelAllocation
    -- already set this nil themselves before calling refreshCalendarState, so
    -- this is a harmless re-assignment on that path.
    self.allocatingJobId = nil

    local environment = g_currentMission.environment
    local viewPeriod = self:getCalendarViewPeriod()
    local isCurrentPeriod = self.calendarPeriodOffset == 0

    -- Texts only actually need rebuilding once per frame open (the current
    -- in-game period doesn't change while the menu's open), but rebuilding
    -- them on every refresh is cheap and keeps this correct if that ever
    -- stops being true. setState with no forceEvent just moves the display,
    -- it doesn't re-fire onClickCalendarPeriodSelector.
    local periodTexts = {}
    for offset = 0, Environment.PERIODS_IN_YEAR - 1 do
        local rawPeriod = environment.currentPeriod - 1 + offset
        local period = rawPeriod % Environment.PERIODS_IN_YEAR + 1
        local year = environment.currentYear + math.floor(rawPeriod / Environment.PERIODS_IN_YEAR)
        table.insert(periodTexts, string.format("%s, %s", g_i18n:getText("ui_month" .. periodToMonth(period)),
            formatYear(year)))
    end
    self.calendarPeriodSelector:setTexts(periodTexts)
    self.calendarPeriodSelector:setState(self.calendarPeriodOffset + 1)

    self.calendarDayRows = {}
    for day = 1, environment.daysPerPeriod do
        local dayJobs = {}
        for _, job in ipairs(jobs:getJobsByTargetDate(farmId, viewPeriod, day)) do
            if isCalendarVisibleState(job.state) then
                table.insert(dayJobs, job)
            end
        end

        local unallocatedCount = 0
        local missedCount = 0
        for _, job in ipairs(dayJobs) do
            if job.state == TheContractorJob.STATE.ACCEPTED then
                unallocatedCount = unallocatedCount + 1
            elseif job.state == TheContractorJob.STATE.MISSED then
                missedCount = missedCount + 1
            end
        end

        table.insert(self.calendarDayRows, {
            day = day,
            jobs = dayJobs,
            unallocatedCount = unallocatedCount,
            missedCount = missedCount,
            isToday = isCurrentPeriod and day == environment.currentDayInPeriod,
        })
    end

    self.calendarDayTable:reloadData()

    self.btnCalendarToday.disabled = self.calendarPeriodOffset == 0
    self:setMenuButtonInfoDirty()

    -- Keep the current day selection if it's still in range (e.g. a refresh
    -- triggered by something unrelated), otherwise drop it — same pattern
    -- as refreshInboxState's selection handling.
    local stillValid = false
    for _, row in ipairs(self.calendarDayRows) do
        if row.day == self.selectedCalendarDay then
            stillValid = true
        end
    end
    if not stillValid then
        self.selectedCalendarDay = nil
    end

    self:updateCalendarDayDetails()
end

function MenuContractor:getSelectedCalendarDayRow()
    for _, row in ipairs(self.calendarDayRows) do
        if row.day == self.selectedCalendarDay then
            return row
        end
    end
    return nil
end

function MenuContractor:getSelectedCalendarDayJob()
    for _, job in ipairs(self.calendarDayJobs) do
        if job.id == self.selectedCalendarDayJobId then
            return job
        end
    end
    return nil
end

function MenuContractor:populateCalendarDayCell(index, cell)
    local row = self.calendarDayRows[index]
    if row == nil then
        return
    end

    local dayText = tostring(row.day)
    if row.isToday then
        dayText = string.format(g_i18n:getText("tc_calendar_todayMarker"), dayText)
    end
    cell:getAttribute("day"):setText(dayText)
    cell:getAttribute("jobCount"):setText(tostring(#row.jobs))

    -- Missed takes priority over the unallocated warning — a job that
    -- already blew its deadline is a bigger deal than one still merely
    -- waiting on allocation, and they're mutually exclusive states anyway
    -- (see Job.lua's transition table) so a day is never both at once.
    local statusCell = cell:getAttribute("status")
    if #row.jobs == 0 then
        statusCell:setText("")
    elseif row.missedCount > 0 then
        statusCell:setText(string.format(g_i18n:getText("tc_calendar_missedCount"), row.missedCount))
        statusCell:setTextColor(1, 0.25, 0.25, 1)
    elseif row.unallocatedCount > 0 then
        statusCell:setText(string.format(g_i18n:getText("tc_calendar_unallocatedCount"), row.unallocatedCount))
        statusCell:setTextColor(1, 0.45, 0.45, 1)
    else
        statusCell:setText(g_i18n:getText("tc_calendar_allAllocated"))
        statusCell:setTextColor(0.6, 1, 0.6, 1)
    end
end

function MenuContractor:populateCalendarDayJobCell(index, cell)
    local job = self.calendarDayJobs[index]
    if job == nil then
        return
    end

    cell:getAttribute("jobType"):setText(job:getDisplayTitle())

    local field = g_fieldManager:getFieldById(job.fieldId)
    cell:getAttribute("field"):setText(field ~= nil and field:getName() or tostring(job.fieldId))

    cell:getAttribute("price"):setText(g_i18n:formatMoney(job.price, 0, true, true))

    -- Allocated vs not-yet-allocated (Q25) — selecting a row here just moves
    -- selectedCalendarDayJobId (see onListSelectionChanged); the actual
    -- allocation flow (018) is reached via the Allocate bottom-bar button
    -- that appears whenever the selected job is still `accepted` (see
    -- getMenuButtonInfo/onClickOpenAllocation), not a button in this list.
    -- Missed (024, scoped down — see TheContractorJobs:missJob) is its own
    -- distinct "Failed" label (a darker red than the unallocated warning —
    -- TextElement has no runtime bold setter to lean on instead) rather than
    -- folding into either bucket — it's neither waiting on allocation nor
    -- successfully allocated, it's over and done with. A hired worker's job
    -- then reads Allocated -> Travelling (Dispatch's transport wait) -> In
    -- progress with the same live percentage the Overview's current-jobs
    -- list shows.
    local statusCell = cell:getAttribute("status")
    if job.state == TheContractorJob.STATE.MISSED then
        statusCell:setText(g_i18n:getText("tc_calendar_jobMissed"))
        statusCell:setTextColor(1, 0.25, 0.25, 1)
    elseif job.state == TheContractorJob.STATE.ACCEPTED then
        statusCell:setText(g_i18n:getText("tc_calendar_jobUnallocated"))
        statusCell:setTextColor(1, 0.45, 0.45, 1)
    elseif job.state == TheContractorJob.STATE.IN_PROGRESS then
        statusCell:setText(string.format(g_i18n:getText("tc_calendar_jobInProgress"),
            math.floor(job.completionPercentage)))
        statusCell:setTextColor(0.6, 1, 0.6, 1)
    elseif job.isTravelling then
        statusCell:setText(g_i18n:getText("tc_calendar_jobTravelling"))
        statusCell:setTextColor(1, 0.85, 0.4, 1)
    elseif job:needsPlayerDelivery() and job.requiredLiters > 0 and job.state == TheContractorJob.STATE.ALLOCATED then
        -- Player-driven haulage (035): cut and delivered, both.
        statusCell:setText(string.format(g_i18n:getText("tc_calendar_jobDelivering"),
            math.floor(job.completionPercentage), math.floor(100 * job.deliveredLiters / job.requiredLiters)))
        statusCell:setTextColor(0.6, 1, 0.6, 1)
    else
        statusCell:setText(g_i18n:getText("tc_calendar_jobAllocated"))
        statusCell:setTextColor(0.6, 1, 0.6, 1)
    end
end

-- Allocation flow (018) ---------------------------------------------------
--
-- Opened from the Calendar day view against whichever job is currently
-- selected in calendarDayJobsTable (must still be `accepted` — see
-- getMenuButtonInfo). Swaps calendarDayJobsContainer for allocationContainer
-- inside the same calendarDayDetailsBox rather than opening a separate
-- dialog, following this codebase's own "no custom dialog classes beyond
-- TextInputDialog/YesNoDialog/InfoDialog" precedent.

function MenuContractor:onClickOpenAllocation()
    local job = self:getSelectedCalendarDayJob()
    if job == nil or job.state ~= TheContractorJob.STATE.ACCEPTED then
        return
    end

    self.allocatingJobId = job.id
    self.allocationSelectedWorkerIds = {}
    self.allocationSelectedEquipmentKeys = {}
    self:refreshAllocationState()
end

function MenuContractor:onClickCancelAllocation()
    self.allocatingJobId = nil
    self.allocationContainer:setVisible(false)
    self:updateCalendarDayDetails()
    self:setMenuButtonInfoDirty()
end

-- Rebuilds the worker/equipment picker lists for self.allocatingJobId: row 1
-- of allocationWorkerRows is always the synthetic "Myself" entry (workerId
-- nil, always valid per Q13 — see TheContractorAllocation:previewWorkerCapability),
-- followed by the farm's idle roster workers (a busy worker can't be
-- double-booked, same exclusivity the equipment freedom check enforces).
-- Equipment rows: see rebuildAllocationEquipmentRows.
function MenuContractor:refreshAllocationState()
    local farmId = g_currentMission:getFarmId()
    local jobs = g_currentMission.TheContractor.Jobs
    local job = jobs:getJob(farmId, self.allocatingJobId)

    self.calendarDayJobsContainer:setVisible(false)
    self.allocationContainer:setVisible(job ~= nil)
    self:setMenuButtonInfoDirty()

    if job == nil then
        return
    end

    local staff = g_currentMission.TheContractor.Staff
    self.allocationJobTitle:setText(string.format(g_i18n:getText("tc_allocation_title"), job:getDisplayTitle()))

    self.allocationWorkerRows = { { workerId = nil, label = g_i18n:getText("tc_allocation_myself") } }
    for _, worker in ipairs(staff:getIdleWorkers(farmId)) do
        table.insert(self.allocationWorkerRows, { workerId = worker.id, label = worker.name })
    end
    self.allocationHighlightedWorkerIndex = 1
    self.allocationWorkerTable:reloadData()
    self.allocationWorkerTable:setSelectedIndex(1)

    self.allocationHighlightedEquipmentIndex = nil
    self:rebuildAllocationEquipmentRows(job)

    self:updateAllocationWorkerToggleButton()
    self:updateAllocationWarning()
end

-- Equipment rows are the job's eligible implements/harvesters/headers
-- (labelled by role) followed by eligible tractors, only when something
-- might need pulling — see TheContractorAllocation:getEligibleImplements/
-- jobMayNeedTractor/getEligibleTractors. A haulage job crewed by workers
-- (035) adds the haulage rig's candidates after those (haulTractor/trailer
-- rows - getEligibleHaulageEquipment); they come and go as the crew
-- changes, so this reruns from onClickToggleAllocationWorker, keeping
-- whatever's still listed selected.
function MenuContractor:rebuildAllocationEquipmentRows(job)
    local farmId = g_currentMission:getFarmId()
    local allocation = g_currentMission.TheContractor.Allocation

    local rows = {}
    local function addRow(vehicle, role)
        local vehicleId = NetworkUtil.getObjectId(vehicle)
        table.insert(rows, {
            key = role .. ":" .. tostring(vehicleId),
            vehicleId = vehicleId,
            label = vehicle:getFullName(),
            role = role,
            isHaulage = role == "haulTractor" or role == "trailer",
        })
    end

    for _, entry in ipairs(allocation:getEligibleImplements(farmId, job)) do
        addRow(entry.vehicle, entry.role)
    end
    if allocation:jobMayNeedTractor(farmId, job) then
        for _, vehicle in ipairs(allocation:getEligibleTractors(farmId)) do
            addRow(vehicle, "tractor")
        end
    end
    if job.includesHaulage and #self.allocationSelectedWorkerIds > 0 then
        for _, entry in ipairs(allocation:getEligibleHaulageEquipment(farmId, job)) do
            addRow(entry.vehicle, entry.role)
        end
    end

    local selectedKeys = {}
    for _, row in ipairs(rows) do
        if self.allocationSelectedEquipmentKeys[row.key] then
            selectedKeys[row.key] = true
        end
    end
    self.allocationSelectedEquipmentKeys = selectedKeys
    self.allocationEquipmentRows = rows

    if #rows == 0 then
        self.allocationHighlightedEquipmentIndex = nil
    else
        self.allocationHighlightedEquipmentIndex = math.min(self.allocationHighlightedEquipmentIndex or 1, #rows)
    end
    self.allocationEquipmentTable:reloadData()
    if self.allocationHighlightedEquipmentIndex ~= nil then
        self.allocationEquipmentTable:setSelectedIndex(self.allocationHighlightedEquipmentIndex)
    end
    self:updateAllocationEquipmentToggleButton()
end

function MenuContractor:getAllocatingJob()
    return g_currentMission.TheContractor.Jobs:getJob(g_currentMission:getFarmId(), self.allocatingJobId)
end

-- Picks/unpicks the highlighted worker row (035). "Myself" means the player
-- alone, so picking it drops any workers, and a worker can't be picked
-- alongside it. Otherwise up to the job's worker count
-- (TheContractorAllocation.getRequiredWorkerCount - one, or two for a
-- haulage job) can be picked; picking one more than that replaces the
-- earliest pick. Unpicking the last worker falls back to "Myself".
function MenuContractor:onClickToggleAllocationWorker()
    local job = self:getAllocatingJob()
    local row = self.allocationWorkerRows[self.allocationHighlightedWorkerIndex]
    if job == nil or row == nil then
        return
    end

    local selected = self.allocationSelectedWorkerIds
    if row.workerId == nil then
        selected = {}
    elseif table.hasElement(selected, row.workerId) then
        table.removeElement(selected, row.workerId)
    else
        table.insert(selected, row.workerId)
        if #selected > TheContractorAllocation.getRequiredWorkerCount(job) then
            table.remove(selected, 1)
        end
    end
    self.allocationSelectedWorkerIds = selected

    self.allocationWorkerTable:reloadData()
    self:rebuildAllocationEquipmentRows(job)
    self:updateAllocationWorkerToggleButton()
    self:updateAllocationWarning()
end

function MenuContractor:isAllocationWorkerRowSelected(row)
    if row.workerId == nil then
        return #self.allocationSelectedWorkerIds == 0
    end
    return table.hasElement(self.allocationSelectedWorkerIds, row.workerId)
end

function MenuContractor:updateAllocationWorkerToggleButton()
    local row = self.allocationWorkerRows[self.allocationHighlightedWorkerIndex]
    local isSelected = row ~= nil and row.workerId ~= nil and self:isAllocationWorkerRowSelected(row)
    self.btnAllocateToggleWorker.text = g_i18n:getText(isSelected and "tc_allocation_deselectWorkerButton" or
        "tc_allocation_selectWorkerButton")
    self:setMenuButtonInfoDirty()
end

-- A job can need more than one piece of equipment (e.g. combine + header),
-- so equipment selection is a set (allocationSelectedEquipmentKeys) rather
-- than SmoothList's single highlighted index — this flips the highlighted
-- row's membership and re-renders each row's "[X]/[ ]" prefix via
-- populateAllocationEquipmentCell.
function MenuContractor:onClickToggleAllocationEquipment()
    local row = self.allocationEquipmentRows[self.allocationHighlightedEquipmentIndex]
    if row == nil then
        return
    end

    if self.allocationSelectedEquipmentKeys[row.key] then
        self.allocationSelectedEquipmentKeys[row.key] = nil
    else
        self.allocationSelectedEquipmentKeys[row.key] = true
    end

    self.allocationEquipmentTable:reloadData()
    self:updateAllocationEquipmentToggleButton()
    self:updateAllocationWarning()
end

function MenuContractor:updateAllocationEquipmentToggleButton()
    local row = self.allocationEquipmentRows[self.allocationHighlightedEquipmentIndex]
    local isSelected = row ~= nil and self.allocationSelectedEquipmentKeys[row.key] == true
    self.btnAllocateToggleEquipment.text = g_i18n:getText(isSelected and "tc_allocation_deselectEquipmentButton" or
        "tc_allocation_selectEquipmentButton")
    self:setMenuButtonInfoDirty()
end

function MenuContractor:populateAllocationWorkerCell(index, cell)
    local row = self.allocationWorkerRows[index]
    if row == nil then
        return
    end
    cell:getAttribute("name"):setText((self:isAllocationWorkerRowSelected(row) and "[X] " or "[ ] ") .. row.label)
end

function MenuContractor:populateAllocationEquipmentCell(index, cell)
    local row = self.allocationEquipmentRows[index]
    if row == nil then
        return
    end

    local checked = self.allocationSelectedEquipmentKeys[row.key] == true
    cell:getAttribute("name"):setText((checked and "[X] " or "[ ] ") .. row.label)
    cell:getAttribute("kind"):setText(g_i18n:getText("tc_allocation_role_" .. row.role))
end

-- Selected vehicle ids, field equipment or (isHaulage) the haulage rig.
function MenuContractor:getSelectedAllocationEquipmentIds(isHaulage)
    local ids = {}
    for _, row in ipairs(self.allocationEquipmentRows) do
        if row.isHaulage == (isHaulage == true) and self.allocationSelectedEquipmentKeys[row.key] then
            table.insert(ids, row.vehicleId)
        end
    end
    return ids
end

-- Everything in the current picks that stops the allocation going
-- through, as a single player-facing line, or nil if it's good to go -
-- shared by the live warning and the Confirm pre-check (the server
-- re-validates regardless, see TheContractorAllocation:allocateJob).
-- Returns text, isBlocking (false = just a heads-up, e.g. an
-- under-qualified worker).
function MenuContractor:getAllocationProblem(job)
    local farmId = g_currentMission:getFarmId()
    local allocation = g_currentMission.TheContractor.Allocation
    local workerIds = self.allocationSelectedWorkerIds
    local equipmentIds = self:getSelectedAllocationEquipmentIds(false)
    local haulageIds = self:getSelectedAllocationEquipmentIds(true)
    local cropTitle = job:getCropTitle()
    local needsHaulageRig = job.includesHaulage and #workerIds > 0

    local crewError = TheContractorAllocation.getCrewShapeError(job, workerIds)
    if crewError ~= nil then
        return g_i18n:getText(crewError), true
    end

    local _, _, capability = allocation:assignCrewRoles(farmId, job, workerIds, equipmentIds, haulageIds)
    if capability == TheContractorAllocation.CAPABILITY.BLOCKED then
        return g_i18n:getText("tc_allocation_blockedWarning"), true
    end

    local missing = allocation:getMissingFromSelection(job, equipmentIds)
    if needsHaulageRig then
        for _, key in ipairs(allocation:getMissingHaulageFromSelection(job, haulageIds)) do
            table.insert(missing, key)
        end
    end
    if #missing > 0 then
        return string.format(g_i18n:getText("tc_allocation_selectWarning"),
            TCEquipmentClass.getMissingEquipmentText(missing, job.jobType, cropTitle)), true
    end

    if capability == TheContractorAllocation.CAPABILITY.WARN then
        return g_i18n:getText("tc_allocation_underqualifiedWarning"), false
    end
    return nil, false
end

-- Live capability preview (016 vs. 018's design decision) as the worker/
-- equipment selections change — re-run server-side on actual confirmation
-- too (TheContractorAllocation:allocateJob), this is purely an informational
-- heads-up so the player isn't surprised by the "blocked" outcome only after
-- clicking Confirm.
function MenuContractor:updateAllocationWarning()
    self:setMenuButtonInfoDirty()

    local farmId = g_currentMission:getFarmId()
    local job = g_currentMission.TheContractor.Jobs:getJob(farmId, self.allocatingJobId)
    if job == nil then
        self.allocationWarningText:setText("")
        return
    end

    local allocation = g_currentMission.TheContractor.Allocation
    local cropTitle = job:getCropTitle()

    -- Equipment gaps first, most fundamental first: things the farm doesn't
    -- own at all, then things it owns that are busy elsewhere/in cooldown
    -- (so not listed in the picker), then what's wrong with the picks
    -- themselves (getAllocationProblem). The haulage rig (035) only counts
    -- once workers are picked for a haulage job - the player alone brings
    -- their own.
    local missingOwned, missingFree = allocation:getMissingEquipment(farmId, job)
    if job.includesHaulage and #self.allocationSelectedWorkerIds > 0 then
        local haulageOwned, haulageFree = allocation:getMissingHaulageEquipment(farmId, job)
        for _, key in ipairs(haulageOwned) do
            table.insert(missingOwned, key)
        end
        for _, key in ipairs(haulageFree) do
            table.insert(missingFree, key)
        end
    end
    local missingBusy = {}
    for _, key in ipairs(missingFree) do
        if not table.hasElement(missingOwned, key) then
            table.insert(missingBusy, key)
        end
    end

    local lines = {}
    if #missingOwned > 0 then
        table.insert(lines, string.format(g_i18n:getText("tc_allocation_notOwnedWarning"),
            TCEquipmentClass.getMissingEquipmentText(missingOwned, job.jobType, cropTitle)))
    end
    if #missingBusy > 0 then
        table.insert(lines, string.format(g_i18n:getText("tc_allocation_busyWarning"),
            TCEquipmentClass.getMissingEquipmentText(missingBusy, job.jobType, cropTitle)))
    end
    if #lines > 0 then
        self.allocationWarningText:setText(table.concat(lines, "\n"))
        self.allocationWarningText:setTextColor(1, 0.25, 0.25, 1)
        return
    end

    local problem = self:getAllocationProblem(job)
    if problem ~= nil then
        self.allocationWarningText:setText(problem)
        self.allocationWarningText:setTextColor(1, 0.75, 0.25, 1)
    elseif job.includesHaulage and #self.allocationSelectedWorkerIds == 0 then
        -- Player alone on a haulage job: they're doing the carting.
        self.allocationWarningText:setText(string.format(g_i18n:getText("tc_allocation_haulYourself"),
            job.deliveryStationName or "?"))
        self.allocationWarningText:setTextColor(1, 1, 1, 1)
    else
        self.allocationWarningText:setText("")
    end
end

-- Validates locally (friendly pre-check, same "server re-validates
-- regardless" caveat as onClickHireWorker) that the required equipment
-- categories are covered before sending the request — the server is still
-- the sole authority on freedom/capability (the MP double-booking race
-- point).
function MenuContractor:onClickConfirmAllocation()
    local farmId = g_currentMission:getFarmId()
    local job = g_currentMission.TheContractor.Jobs:getJob(farmId, self.allocatingJobId)
    if job == nil then
        return
    end

    local problem, isBlocking = self:getAllocationProblem(job)
    if problem ~= nil and isBlocking then
        InfoDialog.show(problem)
        return
    end

    local haulageIds = {}
    if job.includesHaulage and #self.allocationSelectedWorkerIds > 0 then
        haulageIds = self:getSelectedAllocationEquipmentIds(true)
    end

    g_client:getServerConnection():sendEvent(TCAllocateJobEvent.new(farmId, job.id, self.allocationSelectedWorkerIds,
        self:getSelectedAllocationEquipmentIds(false), haulageIds))

    self.allocatingJobId = nil
    -- Same "synchronous for host/SP, catches up on next refresh for a remote
    -- client" caveat as respondToSelectedInboxJob/sendCounterOffer.
    self:refreshCalendarState(farmId, g_currentMission.TheContractor.Jobs)
end

function MenuContractor:updateCalendarDayDetails()
    local row = self:getSelectedCalendarDayRow()

    self.calendarDayDetailsBox:setVisible(row ~= nil)

    self.calendarDayJobs = row ~= nil and row.jobs or {}
    self.calendarDayJobsTable:reloadData()

    -- Same shape as refreshInboxState/FS25_RedTape's onSwitchSchemeDisplay:
    -- reload first, then show/hide a plain wrapping container
    -- (calendarDayJobsContainer) rather than the SmoothList itself — never
    -- toggle a SmoothList's own visibility directly, that's what was leaving
    -- it with a stale selected index into a now-empty list and crashing on
    -- the next update()/mouseEvent (base game SmoothListElement bug). When
    -- there's something to show, explicitly reselect index 1, matching
    -- RedTape's own "always re-pick a fresh selection on reload" habit.
    -- Allocation (018) is always closed by the time this runs (see
    -- refreshCalendarState) — this just mirrors that back onto the two
    -- containers that swap places inside calendarDayDetailsBox.
    self.allocationContainer:setVisible(false)

    local hasJobs = row ~= nil and #row.jobs > 0
    self.calendarDayEmptyText:setVisible(row ~= nil and not hasJobs)
    self.calendarDayJobsContainer:setVisible(hasJobs)
    if hasJobs then
        self.calendarDayJobsTable:setSelectedIndex(1)
        self.selectedCalendarDayJobId = self.calendarDayJobs[1].id
    else
        self.selectedCalendarDayJobId = nil
    end
    self:setMenuButtonInfoDirty()

    if row == nil then
        return
    end

    self.calendarDayDetailTitle:setText(string.format(g_i18n:getText("tc_calendar_dayDetailTitle"),
        formatCalendarDate(self:getCalendarViewPeriod(), row.day, self:getCalendarViewYear())))
end

function MenuContractor:onClickCalendarToday()
    if self.calendarPeriodOffset == 0 then
        return
    end

    self.calendarPeriodOffset = 0
    -- Auto-select today's day rather than clearing the selection outright —
    -- landing on "today" and then showing an unselected/empty right-hand
    -- panel just reads as "nothing's due" even when something clearly is
    -- (see the day list's own unallocated count), which was confusing.
    self.selectedCalendarDay = g_currentMission.environment.currentDayInPeriod
    self:refreshCalendarState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Jobs)
end

-- The only way to page months now — see MenuContractor.xml's
-- calendarPeriodSelector, the same fs25_subCategorySelector widget
-- FS25_RedTape uses for its scheme switcher, with wrap="false" so the right
-- arrow stops dead at the last bounded period instead of looping back to
-- the first. The widget already clamps its own state against the texts list
-- set in refreshCalendarState, so getState() - 1 is always a valid offset.
function MenuContractor:onClickCalendarPeriodSelector()
    self.calendarPeriodOffset = self.calendarPeriodSelector:getState() - 1
    self.selectedCalendarDay = nil
    self:refreshCalendarState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Jobs)
end

function MenuContractor:onClickAcceptJob()
    self:respondToSelectedInboxJob(true)
end

function MenuContractor:onClickDeclineJob()
    self:respondToSelectedInboxJob(false)
end

function MenuContractor:respondToSelectedInboxJob(accept)
    local job = self:getSelectedInboxJob()
    if job == nil then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local jobId = job.id
    g_client:getServerConnection():sendEvent(TCRespondToJobOfferEvent.new(farmId, jobId, accept))

    -- Refresh immediately: on the server (incl. single-player, and the host
    -- in a listen server) TheContractorJobs applies the transition
    -- synchronously before sendEvent returns, so this already reflects it.
    -- On a remote client the authoritative change only lands once
    -- TCJobStateChangedEvent's broadcast arrives; this refresh is then a
    -- harmless no-op and the list catches up next time the tab is
    -- reopened/switched, same refresh cadence as the rest of this frame.
    self.selectedInboxJobId = nil
    self:refreshInboxState(farmId, g_currentMission.TheContractor.Jobs)

    if accept then
        local updatedJob = g_currentMission.TheContractor.Jobs:getJob(farmId, jobId)
        if updatedJob ~= nil and updatedJob.state == TheContractorJob.STATE.ACCEPTED then
            self:showJobAcceptedNotification(updatedJob)
        end
    end
end

-- Same "job just landed in accepted" notice whether it got there via a
-- plain accept (above) or a counter offer the NPC agreed to (see
-- sendCounterOffer) — the negotiation transcript line is a client-side
-- flavor-text nicety, this InfoDialog is the actual can't-miss-it
-- confirmation (mirrors FS25_RedTape's InfoDialog.show usage for
-- one-button confirmations).
function MenuContractor:showJobAcceptedNotification(job)
    local field = g_fieldManager:getFieldById(job.fieldId)
    local fieldLabel = field ~= nil and field:getName() or tostring(job.fieldId)

    InfoDialog.show(string.format(g_i18n:getText("tc_inbox_jobAcceptedInfo"),
        job:getTypeText(), fieldLabel, g_i18n:formatMoney(job.price, 0, true, true)))
end

-- Counterpart to showJobAcceptedNotification for the other terminal outcome
-- of a counter offer — the NPC walking away rather than accepting. Same
-- "transcript line is a flavor-text nicety, this InfoDialog is the actual
-- can't-miss-it notice" reasoning; a plain Decline click doesn't get one
-- since that's the player's own deliberate action, not a surprise result.
function MenuContractor:showJobRejectedNotification(job)
    local field = g_fieldManager:getFieldById(job.fieldId)
    local fieldLabel = field ~= nil and field:getName() or tostring(job.fieldId)

    InfoDialog.show(string.format(g_i18n:getText("tc_inbox_jobRejectedInfo"),
        job:getTypeText(), fieldLabel))
end

-- Negotiation (014): prompts for a counter price, then hands off to the
-- server via TCCounterOfferEvent. Reuses TextInputDialog (no numeric-input
-- dialog exists anywhere in this codebase) and parses the entered text as a
-- number rather than inventing a second input widget for one field.
function MenuContractor:onClickCounterOffer()
    local job = self:getSelectedInboxJob()
    if job == nil then
        return
    end

    self:showCounterOfferDialog(job.id, tostring(math.floor(job.price)))
end

-- Reopens with the same (invalid) text on a bad entry rather than just
-- notifying and dropping the player back at the Inbox — an InfoDialog with
-- no follow-up read as "your input vanished, try the whole flow again" one
-- click short of retrying. defaultText carries the previously entered text
-- back into the reopened dialog so a typo is easy to fix in place.
function MenuContractor:showCounterOfferDialog(jobId, defaultText)
    local farmId = g_currentMission:getFarmId()
    local job = g_currentMission.TheContractor.Jobs:getJob(farmId, jobId)
    if job == nil then
        return
    end

    local dialogPrompt = string.format(g_i18n:getText("tc_inbox_counterPrompt"),
        g_i18n:formatMoney(job.price, 0, true, true))

    TextInputDialog.show(function(target, text, clickOk)
        if not clickOk then
            return
        end

        local counterPrice = tonumber(text)
        if counterPrice == nil or counterPrice <= 0 then
            InfoDialog.show(g_i18n:getText("tc_inbox_counterInvalid"), function(dialogTarget)
                dialogTarget:showCounterOfferDialog(jobId, text)
            end, target)
            return
        end

        target:sendCounterOffer(jobId, counterPrice)
    end, self, defaultText, dialogPrompt, dialogPrompt, 10, g_i18n:getText("tc_inbox_counterButton"))
end

-- Sends the counter offer, then diffs the job's price/state before and after
-- to derive a flavor-text response for the transcript (see
-- negotiationHistory) — there's no separate response payload coming back
-- from the server, just the updated job snapshot (TCJobNegotiationUpdatedEvent),
-- so comparing old vs new is how the client infers what happened. Same
-- "synchronous for host/SP, catches up next visit for a remote client"
-- caveat as respondToSelectedInboxJob.
function MenuContractor:sendCounterOffer(jobId, counterPrice)
    local farmId = g_currentMission:getFarmId()
    local jobs = g_currentMission.TheContractor.Jobs

    local previousJob = jobs:getJob(farmId, jobId)
    local previousPrice = previousJob ~= nil and previousJob.price or nil

    g_client:getServerConnection():sendEvent(TCCounterOfferEvent.new(farmId, jobId, counterPrice))

    self:refreshInboxState(farmId, jobs)

    local updatedJob = jobs:getJob(farmId, jobId)
    if updatedJob ~= nil and previousPrice ~= nil then
        local message = self:describeNegotiationOutcome(previousPrice, updatedJob, counterPrice)
        if message ~= nil then
            self.negotiationHistory[jobId] = self.negotiationHistory[jobId] or {}
            table.insert(self.negotiationHistory[jobId], message)
            self:updateInboxDetails()
        end

        if updatedJob.state == TheContractorJob.STATE.ACCEPTED then
            self:showJobAcceptedNotification(updatedJob)
        elseif updatedJob.state == TheContractorJob.STATE.DECLINED then
            self:showJobRejectedNotification(updatedJob)
        end
    end
end

function MenuContractor:describeNegotiationOutcome(previousPrice, job, counterPrice)
    if job.state == TheContractorJob.STATE.ACCEPTED then
        return string.format(g_i18n:getText("tc_inbox_negotiationAccepted"),
            g_i18n:formatMoney(job.price, 0, true, true))
    elseif job.state == TheContractorJob.STATE.DECLINED then
        return g_i18n:getText("tc_inbox_negotiationDeclined")
    elseif job.price ~= previousPrice then
        return string.format(g_i18n:getText("tc_inbox_negotiationCountered"),
            g_i18n:formatMoney(counterPrice, 0, true, true), g_i18n:formatMoney(job.price, 0, true, true))
    end
    return nil
end

-- Active-ad status line, plus the three purchase buttons' disabled state
-- (funds/tier gating can change between frames, e.g. money spent elsewhere
-- or a reputation-tier-up) — same "mutate .disabled in place, then dirty
-- the button bar" pattern as FS25_RedTape's updateSchemeActionButton.
function MenuContractor:refreshAdvertisingState(farmId, advertising)
    local activeLevel = advertising:getActiveLevel(farmId)
    if activeLevel ~= nil then
        self.textAdvertisingStatus:setText(string.format(g_i18n:getText("tc_advertising_active"),
            g_i18n:getText("tc_advertising_" .. activeLevel), advertising:getDaysRemaining(farmId)))
    else
        self.textAdvertisingStatus:setText(g_i18n:getText("tc_advertising_none"))
    end

    self.btnBuyLocalAd.disabled = not advertising:canPurchase(farmId, "localNewspaper")
    self.btnBuyRegionalAd.disabled = not advertising:canPurchase(farmId, "regionalNewspaper")
    self.btnBuyTvAd.disabled = not advertising:canPurchase(farmId, "tv")
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickCreateCompany()
    local farmId = g_currentMission:getFarmId()
    local company = g_currentMission.TheContractor.Company

    if company:hasCompany(farmId) then
        return
    end

    if not company:canCreateCompany(farmId) then
        InfoDialog.show(g_i18n:getText("tc_actions_cannotAfford"))
        return
    end

    local dialogPrompt = string.format(g_i18n:getText("tc_actions_createCompanyPrompt"),
        g_i18n:formatMoney(TheContractorCompany.CREATION_COST, 0, true, true))

    TextInputDialog.show(function(target, text, clickOk)
        if not clickOk then
            return
        end

        local name = text
        if name == nil or name == "" then
            name = g_i18n:getText("tc_actions_defaultCompanyName")
        end

        g_client:getServerConnection():sendEvent(TCCreateCompanyEvent.new(farmId, name))
        target:refreshCompanyState()
        target:setMenuButtonInfoDirty()
    end, self, "", dialogPrompt, dialogPrompt, 30, g_i18n:getText("tc_actions_createButton"))
end

-- Funds-check-then-prompt pattern (same as onClickCreateCompany), except
-- the gate is canPurchase() (funds AND reputation-tier) rather than funds
-- alone, and there's no name to collect so a plain YesNoDialog confirm is
-- enough instead of TextInputDialog.
function MenuContractor:onClickBuyAdvertising(levelKey)
    local farmId = g_currentMission:getFarmId()
    local advertising = g_currentMission.TheContractor.Advertising

    if not advertising:canPurchase(farmId, levelKey) then
        InfoDialog.show(g_i18n:getText("tc_advertising_cannotPurchase"))
        return
    end

    local levelDef = TheContractorAdvertising.LEVELS_BY_KEY[levelKey]
    local dialogPrompt = string.format(g_i18n:getText("tc_advertising_confirmPrompt"),
        g_i18n:getText("tc_advertising_" .. levelKey), g_i18n:formatMoney(levelDef.cost, 0, true, true))

    YesNoDialog.show(function(target, clickOk)
        if not clickOk then
            return
        end

        g_client:getServerConnection():sendEvent(TCPurchaseAdvertisingEvent.new(farmId, levelKey))
        target:refreshCompanyState()
    end, self, dialogPrompt)
end

function MenuContractor:onClickInbox()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.INBOX, true)
    self:setMenuButtonInfoDirty()
end

-- Marks every currently-offered job as seen (clearing the 013 HUD badge)
-- whenever the Inbox tab becomes the visible one — covers both clicking the
-- tab directly and paging into it via subCategoryPaging.
function MenuContractor:markInboxSeen()
    if not self:hasCompany() then
        return
    end

    local tc = g_currentMission.TheContractor
    if tc.InboxHUD ~= nil then
        tc.InboxHUD:markAllSeen(g_currentMission:getFarmId())
    end
end

function MenuContractor:onClickCalendar()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.CALENDAR, true)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickStaff()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.STAFF, true)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickOverview()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.OVERVIEW, true)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:updateSubCategoryPages(subCategoryIndex)
    self:updateContent()
    self:setMenuButtonInfoDirty()
end

function MenuContractor:updateContent()
    local state = self.subCategoryPaging:getState()

    self.categoryHeaderIcon:setImageSlice(nil, MenuContractor.HEADER_SLICES[state])
    self.categoryHeaderText:setText(g_i18n:getText(MenuContractor.HEADER_TITLES[state]))

    for k, v in pairs(self.subCategoryPages) do
        v:setVisible(k == state)
    end

    -- Always land on today's month/day when (re-)entering the Calendar tab —
    -- otherwise it silently reopened wherever the player last paged to,
    -- which reads as "the calendar forgot what day it is" rather than a
    -- deliberate browsing position worth remembering. Auto-selecting today's
    -- day (not just the month) matters too: leaving the right-hand panel
    -- unselected/empty right after accepting a job due today, while the
    -- day list clearly shows it as unallocated, read as a contradiction —
    -- "no jobs due" vs. "1 unallocated" for what's visibly the same day.
    -- This only fires on tab switches (this method), not on every refresh,
    -- so paging around once inside the tab still works normally.
    if state == MenuContractor.SUB_CATEGORY.CALENDAR then
        self.calendarPeriodOffset = 0
        self.selectedCalendarDay = g_currentMission.environment.currentDayInPeriod
    end

    self:refreshCompanyState()

    if state == MenuContractor.SUB_CATEGORY.INBOX then
        self:markInboxSeen()
    end
end

-- Adapted from FS25_RedTape/src/RedTape.lua RedTape.addIngameMenuPage
-- (itself credited there to Courseplay): the public g_inGameMenu API for
-- inserting a new top-level page/icon, since there is no XML/config toggle
-- for adding one declaratively.
--
-- iconImageSize is the actual pixel size of images/menuIcon.dds — GuiUtils.getUVs
-- needs it to normalize `uvs` correctly for a non-1024x1024 icon atlas (see
-- FS25_ImprovedControlsMenu/src/main.lua's addIngameMenuPage, which passes
-- {128, 128} for its own 128x128 icon; RedTape's own 1024x1024 icon gets away
-- with omitting it since that's GuiUtils.getUVs' implicit default).
function MenuContractor.registerInIngameMenu(frame, pageName, uvs, iconImageSize, predicateFunc, insertAfter)
    local targetPosition = 0

    g_inGameMenu.controlIDs[pageName] = nil

    for i = 1, #g_inGameMenu.pagingElement.elements do
        local child = g_inGameMenu.pagingElement.elements[i]
        if child == g_inGameMenu[insertAfter] then
            targetPosition = i + 1
            break
        end
    end

    g_inGameMenu[pageName] = frame
    g_inGameMenu.pagingElement:addElement(g_inGameMenu[pageName])

    g_inGameMenu:exposeControlsAsFields(pageName)

    for i = 1, #g_inGameMenu.pagingElement.elements do
        local child = g_inGameMenu.pagingElement.elements[i]
        if child == g_inGameMenu[pageName] then
            table.remove(g_inGameMenu.pagingElement.elements, i)
            table.insert(g_inGameMenu.pagingElement.elements, targetPosition, child)
            break
        end
    end

    for i = 1, #g_inGameMenu.pagingElement.pages do
        local child = g_inGameMenu.pagingElement.pages[i]
        if child.element == g_inGameMenu[pageName] then
            table.remove(g_inGameMenu.pagingElement.pages, i)
            table.insert(g_inGameMenu.pagingElement.pages, targetPosition, child)
            break
        end
    end

    g_inGameMenu.pagingElement:updateAbsolutePosition()
    g_inGameMenu.pagingElement:updatePageMapping()

    g_inGameMenu:registerPage(g_inGameMenu[pageName], nil, predicateFunc)

    local iconFileName = Utils.getFilename("images/menuIcon.dds", TheContractor.dir)
    g_inGameMenu:addPageTab(g_inGameMenu[pageName], iconFileName, GuiUtils.getUVs(uvs, iconImageSize))

    for i = 1, #g_inGameMenu.pageFrames do
        local child = g_inGameMenu.pageFrames[i]
        if child == g_inGameMenu[pageName] then
            table.remove(g_inGameMenu.pageFrames, i)
            table.insert(g_inGameMenu.pageFrames, targetPosition, child)
            break
        end
    end

    g_inGameMenu:rebuildTabList()
end
