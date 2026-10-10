-- Top-level "Contractor" in-game menu page: six sub-tabs (Overview, Inbox,
-- Calendar, Staff, Finances, Logbook). Structure mirrors FS25_RedTape/src/gui/MenuRedTape.lua's own
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
    FINANCES = 5,
    LOGBOOK = 6,
}

MenuContractor.HEADER_SLICES = {
    [MenuContractor.SUB_CATEGORY.INBOX] = "gui.icon_ingameMenu_contracts",
    [MenuContractor.SUB_CATEGORY.CALENDAR] = "gui.icon_ingameMenu_calendar",
    [MenuContractor.SUB_CATEGORY.STAFF] = "gui.icon_ingameMenu_animals",
    [MenuContractor.SUB_CATEGORY.OVERVIEW] = "gui.icon_ingameMenu_finances",
    [MenuContractor.SUB_CATEGORY.FINANCES] = "gui.icon_ingameMenu_prices",
    [MenuContractor.SUB_CATEGORY.LOGBOOK] = "gui.icon_ingameMenu_handToolsOverview",
}

MenuContractor.HEADER_TITLES = {
    [MenuContractor.SUB_CATEGORY.INBOX] = "tc_header_inbox",
    [MenuContractor.SUB_CATEGORY.CALENDAR] = "tc_header_calendar",
    [MenuContractor.SUB_CATEGORY.STAFF] = "tc_header_staff",
    [MenuContractor.SUB_CATEGORY.OVERVIEW] = "tc_header_overview",
    [MenuContractor.SUB_CATEGORY.FINANCES] = "tc_header_finances",
    [MenuContractor.SUB_CATEGORY.LOGBOOK] = "tc_header_logbook",
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

-- Compact per-tier tractor rating for a list cell (e.g. "S5 M- L8"), as
-- opposed to Staff.lua's own formatTierCapability (console/log), which
-- spells out each tier name in full. The Staff tab's own list dropped this
-- column (044 follow-up) - the details panel's tractor chips show it.
local TIER_ABBREVIATIONS = { small = "S", medium = "M", large = "L" }
local function formatTierListCell(tierCapability)
    local parts = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = tierCapability[tier]
        table.insert(parts, TIER_ABBREVIATIONS[tier] .. (rating ~= nil and tostring(rating) or "-"))
    end
    return table.concat(parts, " ")
end
-- Also used by TCDriverPickerDialog's worker list (037).
MenuContractor.formatTierListCell = formatTierListCell

-- 044: "Planting 6" - one operation skill and its rating.
local function formatSkill(skill, rating)
    return string.format("%s %d", g_i18n:getText("tc_skill_" .. skill), rating)
end
MenuContractor.formatSkill = formatSkill

-- 044: a worker's best operation skill for a list cell, e.g. "Baling 9" -
-- the column only has room for one; the whole set is in the details panel.
local LIST_SKILL_COUNT = 1
local function formatBestSkillsCell(worker)
    local parts = {}
    for i, entry in ipairs(worker:getSkillsByRating()) do
        if i > LIST_SKILL_COUNT then
            break
        end
        table.insert(parts, formatSkill(entry.skill, entry.rating))
    end
    return table.concat(parts, ", ")
end

-- Status chips (043): the fill for each tone. Deep, muted fills under a
-- white label, after FS25_AdvancedDamageSystem's value badges — they replace
-- the old coloured status text, which read poorly on the grey rows.
MenuContractor.CHIP_COLORS = {
    good = { 0.12, 0.36, 0.08, 1 },
    info = { 0.08, 0.24, 0.40, 1 },
    warn = { 0.45, 0.30, 0.03, 1 },
    bad = { 0.45, 0.09, 0.06, 1 },
    neutral = { 0.17, 0.17, 0.18, 1 },
}

-- Shows text on a chip (a RoundCorner plus the Text over it) in the given
-- tone, or hides the chip for nil/"". The chip profiles have no per-state
-- colours, so setting .color covers selected/highlighted rows too.
local function setChip(chip, chipText, text, tone)
    local visible = text ~= nil and text ~= ""
    chip:setVisible(visible)
    chipText:setVisible(visible)
    if visible then
        chip.color = MenuContractor.CHIP_COLORS[tone] or MenuContractor.CHIP_COLORS.neutral
        chipText:setText(text)
    end
end

-- Allocation pickers' tick box (replaces the old "[X] " / "[ ] " prefix):
-- bright green when picked, an empty grey square when not.
local CHECKBOX_ON_COLOR = { 0.30, 0.62, 0.06, 1 }
local CHECKBOX_OFF_COLOR = { 0.22, 0.22, 0.23, 1 }
local function setAllocationCheckBox(checkBox, checked)
    checkBox.color = checked and CHECKBOX_ON_COLOR or CHECKBOX_OFF_COLOR
end

local STATUS_CHIP_TONES = {
    idle = "neutral",
    assigned = "good",
    driving = "info",
    cooldown = "neutral",
    sick = "bad",
    holiday = "info",
    training = "info",
}

local function getWorkerStatusTone(status)
    return STATUS_CHIP_TONES[status] or "neutral"
end

-- Tier ratings are 1-10, nil when the worker can't do that size at all.
local function getTierChipTone(rating)
    if rating == nil then
        return "neutral"
    elseif rating >= 7 then
        return "good"
    elseif rating >= 4 then
        return "info"
    end
    return "warn"
end

-- 049: invoice status chips. Paid invoices aren't listed.
local INVOICE_STATUS_TONES = {
    outstanding = "info",
    overdue = "warn",
    writtenOff = "bad",
    pursuing = "info",
}

-- 051: overhead status chips (see getOverheadStatus).
local OVERHEAD_STATUS_TONES = {
    active = "good",
    mandatory = "info",
    cancelled = "warn",
    lapsing = "warn",
    notNeeded = "neutral",
    notTaken = "neutral",
}

local function getQualityChipTone(qualityScore)
    if qualityScore >= 80 then
        return "good"
    elseif qualityScore >= 50 then
        return "warn"
    end
    return "bad"
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
-- Inbox message (050) action buttons, in the order of the message's
-- actions - TheContractorInbox.MAX_ACTIONS of them.
MenuContractor.MESSAGE_ACTION_INPUTS = {
    InputAction.MENU_ACTIVATE,
    InputAction.MENU_EXTRA_1,
    InputAction.MENU_EXTRA_2,
}

-- 054: the certificate the Staff tab shows and books - the only one so far.
MenuContractor.TRAINING_CERT = "spraying"

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

    -- Opens the advertising purchase dialog (027), where level and duration
    -- are picked. Always enabled once a company exists: the dialog itself
    -- explains why a given choice can't be bought (tier lock, funds).
    self.btnBuyAdvertising = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_advertising_buyButton"),
        callback = function()
            self:onClickBuyAdvertising()
        end
    }

    -- Inbox (013) accept/decline — same bottom-bar pattern as the
    -- advertising button above, only appended while a job row is selected
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
    -- Buy Advertising button.
    self.menuButtonInfoOverviewWithCompany = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnBuyAdvertising }

    self.menuButtonInfoInboxWithSelection = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnAcceptJob, self.btnDeclineJob, self.btnCounterOffer }

    -- Inbox messages (050): one button per action of the highlighted
    -- message, labelled and listed by updateInboxMessageDetails.
    self.btnMessageActions = {}
    for i, inputAction in ipairs(MenuContractor.MESSAGE_ACTION_INPUTS) do
        self.btnMessageActions[i] = {
            inputAction = inputAction,
            text = "",
            callback = function()
                self:onClickMessageAction(i)
            end
        }
    end
    self.menuButtonInfoInboxMessage = self.menuButtonInfoDefault

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
    -- 056: a one-off bonus for the highlighted roster worker.
    self.btnGiveBonus = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("tc_morale_bonusButton"),
        callback = function()
            self:onClickGiveBonus()
        end
    }
    -- 058: a pay rise for the highlighted roster worker.
    self.btnPayRise = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("tc_pay_riseButton"),
        callback = function()
            self:onClickPayRise()
        end
    }
    self.menuButtonInfoStaffWithCandidateSelection = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnHireWorker }
    self.menuButtonInfoStaffWithRosterSelection = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnReleaseWorker, self.btnGiveBonus, self.btnPayRise }

    -- 054: book the highlighted worker on the spraying course (or its
    -- retake), only while they're ready, uncertified and not booked - see
    -- getMenuButtonInfo. The label says which (updateStaffDetails).
    self.btnBookTraining = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("tc_training_bookCourseButton"),
        callback = function()
            self:onClickBookTraining()
        end
    }
    self.menuButtonInfoStaffWithTrainableWorker = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnReleaseWorker, self.btnBookTraining, self.btnGiveBonus, self.btnPayRise }

    -- Finances (049) - write off the highlighted invoice, only while it's
    -- overdue (see getMenuButtonInfo).
    self.btnWriteOffInvoice = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_finances_writeOffButton"),
        callback = function()
            self:onClickWriteOffInvoice()
        end
    }
    -- 053: or pursue it, with legal cover or a solicitor.
    self.btnPursueInvoice = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("tc_legal_pursueButton"),
        callback = function()
            self:onClickPursueInvoice()
        end
    }
    self.menuButtonInfoFinancesWithOverdue = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnWriteOffInvoice, self.btnPursueInvoice }

    -- Overheads (051), acting on the highlighted overhead: take one out
    -- (annual or monthly), cancel it, undo a cancel, or switch its billing
    -- from the next renewal. Which ones show depends on its state (see
    -- getMenuButtonInfo); the switch button's label says which way.
    self.btnEnableOverheadAnnual = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_overheads_enableAnnualButton"),
        callback = function()
            self:onClickEnableOverhead(TheContractorOverheads.BILLING.ANNUAL)
        end
    }
    self.btnEnableOverheadMonthly = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("tc_overheads_enableMonthlyButton"),
        callback = function()
            self:onClickEnableOverhead(TheContractorOverheads.BILLING.MONTHLY)
        end
    }
    self.btnCancelOverhead = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_overheads_cancelButton"),
        callback = function()
            self:onClickCancelOverhead()
        end
    }
    self.btnKeepOverhead = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_overheads_keepButton"),
        callback = function()
            self:onClickKeepOverhead()
        end
    }
    self.btnSwitchOverheadBilling = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = "",
        callback = function()
            self:onClickSwitchOverheadBilling()
        end
    }
    self.menuButtonInfoOverheadNotTaken = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnEnableOverheadAnnual, self.btnEnableOverheadMonthly }
    self.menuButtonInfoOverheadActive = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnCancelOverhead, self.btnSwitchOverheadBilling }
    self.menuButtonInfoOverheadMandatory = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnSwitchOverheadBilling }
    self.menuButtonInfoOverheadCancelled = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnKeepOverhead }

    -- 057: the office administrator's row in the same list - hire one, or
    -- release the one employed.
    self.btnHireAdministrator = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_admin_hireButton"),
        callback = function()
            self:onClickHireAdministrator()
        end
    }
    self.btnReleaseAdministrator = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_admin_releaseButton"),
        callback = function()
            self:onClickReleaseAdministrator()
        end
    }
    self.menuButtonInfoAdministratorVacant = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnHireAdministrator }
    self.menuButtonInfoAdministratorEmployed = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnReleaseAdministrator }

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

    -- Completed-jobs history under the day panel (029 follow-up): every
    -- completed job, most recent first. The highlighted row's report shows
    -- straight away (no button), so moving through the list on a gamepad is
    -- all it takes.
    self.completedJobs = {}
    self.selectedCompletedJobId = nil

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
    -- 050: messages head the list, above the job offers.
    self.inboxMessages = {}
    self.selectedInboxMessageId = nil
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
    self.calendarCompletedTable:setDataSource(self)
    self.calendarCompletedTable:setDelegate(self)

    self.allocationWorkerTable:setDataSource(self)
    self.allocationWorkerTable:setDelegate(self)
    self.allocationEquipmentTable:setDataSource(self)
    self.allocationEquipmentTable:setDelegate(self)

    self.staffTable:setDataSource(self)
    self.staffTable:setDelegate(self)

    -- Finances (049): the farm's unpaid invoices, oldest due first.
    self.invoiceList = {}
    self.selectedInvoiceId = nil

    self.financesInvoiceTable:setDataSource(self)
    self.financesInvoiceTable:setDelegate(self)

    -- 051: the Finances list shows invoices or overheads (financesView,
    -- switched by financesViewSelector), like the Staff tab's two views.
    -- overheadRows is every registered overhead, in registration order.
    self.financesView = "invoices"
    self.overheadRows = {}
    self.selectedOverheadKey = nil

    self.financesOverheadTable:setDataSource(self)
    self.financesOverheadTable:setDelegate(self)

    -- Logbook (060): Jobs or Vehicles (logbookView, switched by
    -- logbookViewSelector), each with its own list, and one detail list for
    -- whichever's highlighted. Jobs can be filtered and vehicles sorted from
    -- the bottom bar, and each view jumps to the matching entry in the
    -- other (see getLogbookButtonInfo).
    self.logbookView = "jobs"
    self.logbookJobs = {}
    self.selectedLogbookJobId = nil
    self.logbookJobFilterIndex = 1
    self.logbookJobFilters = {}
    self.logbookVehicleRows = {}
    self.selectedLogbookVehicleId = nil
    self.logbookVehicleSortIndex = 1
    self.logbookDetailRows = {}
    self.logbookDetailIndex = nil

    self.btnLogbookFilter = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = "",
        callback = function()
            self:onClickLogbookFilter()
        end
    }
    self.btnLogbookSort = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = "",
        callback = function()
            self:onClickLogbookSort()
        end
    }
    self.btnLogbookOpenVehicle = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_logbook_openVehicleButton"),
        callback = function()
            self:onClickLogbookOpenVehicle()
        end
    }
    self.btnLogbookOpenJob = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_logbook_openJobButton"),
        callback = function()
            self:onClickLogbookOpenJob()
        end
    }

    self.logbookJobTable:setDataSource(self)
    self.logbookJobTable:setDelegate(self)
    self.logbookVehicleTable:setDataSource(self)
    self.logbookVehicleTable:setDelegate(self)
    self.logbookDetailTable:setDataSource(self)
    self.logbookDetailTable:setDelegate(self)
end

function MenuContractor:getMenuButtonInfo()
    local state = self.subCategoryPaging:getState()

    if state == MenuContractor.SUB_CATEGORY.OVERVIEW then
        if not self:hasCompany() then
            return self.menuButtonInfoOverviewNoCompany
        end
        return self.menuButtonInfoOverviewWithCompany
    end

    if state == MenuContractor.SUB_CATEGORY.INBOX and self.selectedInboxMessageId ~= nil then
        return self.menuButtonInfoInboxMessage
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
            local worker = self:getSelectedRosterWorker()
            if worker ~= nil and
                    TheContractorTraining.getBookingProblem(worker, MenuContractor.TRAINING_CERT) == nil then
                return self.menuButtonInfoStaffWithTrainableWorker
            end
            return self.menuButtonInfoStaffWithRosterSelection
        end
    end

    if state == MenuContractor.SUB_CATEGORY.FINANCES and self:hasCompany() then
        if self.financesView == "overheads" then
            local buttons = self:getOverheadButtonInfo()
            if buttons ~= nil then
                return buttons
            end
        else
            local invoice = self:getSelectedInvoice()
            if invoice ~= nil and invoice.status == TheContractorFinances.STATUS.OVERDUE then
                return self.menuButtonInfoFinancesWithOverdue
            end
        end
    end

    if state == MenuContractor.SUB_CATEGORY.LOGBOOK and self:hasCompany() then
        return self:getLogbookButtonInfo()
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

    self.isFrameOpen = true
    self:updateContent()
    self:setMenuButtonInfoDirty()
end

-- 042: the portrait's scene and character only live while the menu's open.
function MenuContractor:onFrameClose()
    MenuContractor:superClass().onFrameClose(self)

    self.isFrameOpen = false
    if self.workerPortrait ~= nil then
        self.workerPortrait:destroy()
    end
end

function MenuContractor:update(dt)
    MenuContractor:superClass().update(self, dt)

    if self.workerPortrait ~= nil then
        self.workerPortrait:update(dt)
    end
end

-- 042: shows the highlighted worker's portrait while the Staff tab is the
-- one showing, nothing otherwise.
function MenuContractor:updateWorkerPortrait()
    if self.workerPortrait == nil then
        self.workerPortrait = TCWorkerPortrait.new(self.staffPortraitRender)
    end

    local worker = nil
    if self.isFrameOpen and self.subCategoryPaging:getState() == MenuContractor.SUB_CATEGORY.STAFF and
            self:hasCompany() then
        worker = self.staffView == "roster" and self:getSelectedRosterWorker() or self:getSelectedCandidate()
    end
    self.workerPortrait:setWorker(worker)
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
    self.overviewContent:setVisible(hasCompany)

    if not hasCompany then
        self.inboxListContainer:setVisible(false)
        self.inboxEmptyText:setVisible(false)
        self.inboxDetailsBox:setVisible(false)
        self.inboxMessageBox:setVisible(false)
        self.selectedInboxJobId = nil
        self.selectedInboxMessageId = nil

        self.calendarContainer:setVisible(false)
        self.calendarDayDetailsBox:setVisible(false)
        self.calendarCompletedContainer:setVisible(false)
        self.selectedCompletedJobId = nil
        self.selectedCalendarDay = nil
        self.selectedCalendarDayJobId = nil
        self.allocatingJobId = nil

        self.staffViewSelector:setVisible(false)
        setChip(self.staffHealthSafetyChip, self.staffHealthSafetyChipText, nil)
        self.staffHeaderRow:setVisible(false)
        self.staffEmptyText:setVisible(false)
        self.staffListContainer:setVisible(false)
        self.staffDetailsBox:setVisible(false)
        self.selectedRosterWorkerId = nil
        self.selectedCandidateId = nil

        self.financesContent:setVisible(false)
        self.selectedInvoiceId = nil
        self.selectedOverheadKey = nil

        self.logbookContent:setVisible(false)
        self.selectedLogbookJobId = nil
        self.selectedLogbookVehicleId = nil
    end

    if hasCompany then
        local farmId = g_currentMission:getFarmId()
        local tc = g_currentMission.TheContractor
        local name = tc.Company:getCompanyName(farmId)
        self.textCompanyName:setText(name)

        local progress = tc.Reputation:getProgress(farmId)
        self.rankTierText:setText(g_i18n:getText("tc_reputationTier_" .. progress.tier.key))

        if progress.nextTier ~= nil then
            self.progressText:setText(string.format("%d/%d", progress.score, progress.nextTier.minScore))
            self.nextRankText:setText(g_i18n:getText("tc_reputationTier_" .. progress.nextTier.key))
        else
            self.progressText:setText(g_i18n:getText("tc_overview_rankMax"))
            self.nextRankText:setText(g_i18n:getText("tc_overview_nextRankNone"))
        end

        local fullWidth = self.progressBarBg.size[1] - self.progressBar.margin[1] * 2
        local minProgressBarWidthRatio = self.progressBar.startSize[1] * 2 / fullWidth
        local progressBarRatio = math.max(progress.progressPercentage, minProgressBarWidthRatio)
        self.progressBar:setSize(fullWidth * math.min(progressBarRatio, 1), nil)

        self:refreshAdvertisingState(farmId, tc.Advertising)
        self:refreshInboxState(farmId, tc.Jobs)
        self:refreshCalendarState(farmId, tc.Jobs)
        self:refreshCurrentJobsState(farmId, tc.Jobs)
        self:refreshLastCompletedJobState(farmId, tc.Jobs)
        self:refreshSalaryBillState(farmId, tc.Staff)
        self:refreshNoticesState(farmId, tc.Notices)
        self:refreshStaffState(farmId, tc.Staff, tc.Jobs)
        self:refreshFinancesState(farmId, tc.Finances)
        self:refreshLogbookState(farmId, tc.Logbook)

        -- The row BoxLayouts only place their rows when told to: the
        -- layout run at GUI setup leaves them unplaced (seen in-game, 043).
        self.overviewCompanyRows:invalidateLayout()
        self.overviewBusinessRows:invalidateLayout()
    end

    self.placeholderInbox:setVisible(not hasCompany)
    self.calendarContainer:setVisible(hasCompany)

    local lockedText = g_i18n:getText("tc_placeholder_locked")
    self.placeholderCalendar:setVisible(not hasCompany)
    self.placeholderCalendar:setText(lockedText)
    self.placeholderStaff:setVisible(not hasCompany)
    self.placeholderStaff:setText(lockedText)
    self.placeholderFinances:setVisible(not hasCompany)
    self.placeholderFinances:setText(lockedText)
    self.placeholderLogbook:setVisible(not hasCompany)
    self.placeholderLogbook:setText(lockedText)
end

-- Overview tab's last-job line (029): the most recent completion summary,
-- so one missed notification can still be looked up.
function MenuContractor:refreshLastCompletedJobState(farmId, jobs)
    local job = jobs:getLastCompletedJob(farmId)
    if job == nil then
        self.textLastCompletedJob:setText(g_i18n:getText("tc_overview_noCompletedJobs"))
    else
        self.textLastCompletedJob:setText(job:getSummaryText())
    end
end

-- Overview tab's salary line (036): what the roster costs every period.
function MenuContractor:refreshSalaryBillState(farmId, staff)
    self.textSalaryBill:setText(string.format(g_i18n:getText("tc_staff_salaryBill"),
        g_i18n:formatMoney(staff:getTotalSalary(farmId), 0, true, true), #staff:getRoster(farmId)))
end

-- Overview tab's important-notices panel (038): whatever's been published
-- to the farm's board, newest first.
function MenuContractor:refreshNoticesState(farmId, notices)
    local farmNotices = notices:getNotices(farmId)
    if #farmNotices == 0 then
        self.textNotices:setText(g_i18n:getText("tc_overview_noticesEmpty"))
        return
    end

    local lines = {}
    for _, notice in ipairs(farmNotices) do
        table.insert(lines, string.format(g_i18n:getText("tc_overview_noticeLine"), notice.text))
    end
    self.textNotices:setText(table.concat(lines, "\n"))
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
        -- On hold for supplies (032).
        if job:isWaitingForSupplies() then
            line = line .. string.format(g_i18n:getText("tc_overview_supplySuffix"), job:getSupplyStatusText())
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

    -- 055: so the player can see why sickness has changed.
    local hasHealthSafety = g_currentMission.TheContractor.HealthSafety:isActive(farmId)
    setChip(self.staffHealthSafetyChip, self.staffHealthSafetyChipText,
        g_i18n:getText(hasHealthSafety and "tc_healthSafety_chipActive" or "tc_healthSafety_chipInactive"),
        hasHealthSafety and "good" or "warn")

    -- Job column only makes sense for the roster view (candidates were never
    -- assigned anything) — blank it out entirely in the candidates view
    -- rather than showing a column full of "None".
    self.staffHeaderCol4:setText(self.staffView == "candidates" and g_i18n:getText("tc_staff_columnSalary") or
        g_i18n:getText("tc_staff_columnStatus"))
    self.staffHeaderCol5:setText(self.staffView == "candidates" and g_i18n:getText("tc_staff_columnBestSkills") or
        g_i18n:getText("tc_staff_columnJob"))

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

    -- 037: out driving under AutoDrive/Courseplay.
    local vehicle = g_currentMission.TheContractor.Drivers:getVehicleDrivenBy(farmId, workerId)
    if vehicle ~= nil then
        return string.format(g_i18n:getText("tc_staff_drivingLine"), vehicle:getFullName())
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
        cell:getAttribute("col4"):setText(g_i18n:formatMoney(candidate.salary, 0, true, true))
        cell:getAttribute("col4"):setVisible(true)
        setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"), nil)
        cell:getAttribute("col5"):setText(formatBestSkillsCell(candidate))
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
    -- Roster view: column 4 is the status chip, the salary text is the
    -- candidates view's.
    cell:getAttribute("col4"):setVisible(false)
    setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"),
        g_i18n:getText("tc_staff_status_" .. worker.status), getWorkerStatusTone(worker.status))
    cell:getAttribute("col5"):setText(jobLine or "")
end

function MenuContractor:updateStaffDetails()
    self:setMenuButtonInfoDirty()

    local worker = self.staffView == "roster" and self:getSelectedRosterWorker() or self:getSelectedCandidate()
    self.staffDetailsBox:setVisible(worker ~= nil)
    self:updateWorkerPortrait()
    if worker == nil then
        return
    end

    self.staffDetailTitle:setText(worker.name)
    self.staffDetailAge:setText(tostring(worker.age))
    -- Chips are plain numbers - every rating is out of 10.
    setChip(self.staffDetailWorkSpeedChip, self.staffDetailWorkSpeedChipText, tostring(worker.workSpeed),
        getTierChipTone(worker.workSpeed))
    -- 058: and, for a roster worker who wants more, what they want.
    if self.staffView == "roster" and TheContractorPayReviews.wantsMore(worker) then
        self.staffDetailSalary:setText(string.format(g_i18n:getText("tc_pay_detailSalaryWants"),
            g_i18n:formatMoney(worker.salary, 0, true, true), g_i18n:formatMoney(worker.expectedSalary, 0, true, true)))
    else
        self.staffDetailSalary:setText(string.format(g_i18n:getText("tc_staff_detailSalary"),
            g_i18n:formatMoney(worker.salary, 0, true, true)))
    end
    -- 045: a chip, same tones as the skills.
    setChip(self.staffDetailCleanlinessChip, self.staffDetailCleanlinessChipText,
        tostring(worker.cleanliness),
        getTierChipTone(worker.cleanliness))

    -- One chip per tier: "Small 7", "Medium -", ...
    for i, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = worker.tierCapability[tier]
        setChip(self["staffDetailTierChip" .. i], self["staffDetailTierChipText" .. i],
            string.format("%s %s", g_i18n:getText("tc_staff_tier_" .. tier), rating ~= nil and tostring(rating) or "-"),
            getTierChipTone(rating))
    end

    -- 044: one chip per operation skill: "Harvesting 3", "Baling 8", ...
    for i, skill in ipairs(TheContractorWorker.SKILLS) do
        local rating = worker:getSkill(skill)
        setChip(self["staffDetailSkillChip" .. i], self["staffDetailSkillChipText" .. i], formatSkill(skill, rating),
            getTierChipTone(rating))
    end

    -- Roster-only rows; the BoxLayout closes up around the hidden ones.
    -- Holiday left is hidden for a worker who's leaving (there's only room
    -- for ten rows, and they won't use it).
    local isRoster = self.staffView == "roster"
    local leavingText = isRoster and self:getLeavingLine(worker) or nil
    self.staffRowStatus:setVisible(isRoster)
    self.staffRowMorale:setVisible(isRoster)
    self.staffRowJob:setVisible(isRoster)
    self.staffRowRetirement:setVisible(leavingText ~= nil)
    self.staffRowHolidayLeft:setVisible(isRoster and leavingText == nil)
    self.staffRowHoliday:setVisible(isRoster and worker:hasHolidayBooked())

    if isRoster then
        setChip(self.staffDetailStatusChip, self.staffDetailStatusChipText,
            g_i18n:getText("tc_staff_status_" .. worker.status), getWorkerStatusTone(worker.status))
        -- 056.
        local moraleText, moraleTone = TheContractorMorale.getChip(worker.morale)
        setChip(self.staffDetailMoraleChip, self.staffDetailMoraleChipText, moraleText, moraleTone)

        local farmId = g_currentMission:getFarmId()
        local jobLine = self:getAssignedJobLine(farmId, g_currentMission.TheContractor.Jobs, worker.id)
        self.staffDetailJob:setText(jobLine or g_i18n:getText("tc_staff_detailJobNone"))
        self.staffDetailRetirementLabel:setText(g_i18n:getText(worker.isQuitting and "tc_detail_quitting" or
            "tc_detail_retiring"))
        self.staffDetailRetirement:setText(leavingText or "")
        self:updateHolidayDetails(worker)
    end

    self:updateCertificationDetails(worker, isRoster)

    self.staffDetailRows:invalidateLayout()
end

-- 054: the spraying certificate's chip - certified, in training or not -
-- and, on the roster, a note on where they stand: the booked dates, or
-- whether they're ready to train and what it costs.
function MenuContractor:updateCertificationDetails(worker, isRoster)
    local cert = MenuContractor.TRAINING_CERT
    local certName = TheContractorTraining.getCertName(cert)

    local chipKey, tone = "tc_training_chipNotCertified", "neutral"
    if worker:hasCertification(cert) then
        chipKey, tone = "tc_training_chipCertified", "good"
    elseif worker.trainingCert == cert then
        chipKey, tone = "tc_training_chipInTraining", "info"
    end
    setChip(self.staffDetailCertChip, self.staffDetailCertChipText, string.format(g_i18n:getText(chipKey), certName),
        tone)

    local note = ""
    if isRoster then
        note = self:getCertificationNote(worker, cert) or ""
    end
    self.staffDetailCertNote:setText(note)

    -- The bottom-bar button says whether it's the course or a retake.
    self.btnBookTraining.text = g_i18n:getText(TheContractorTraining.isRetake(worker, cert) and
        "tc_training_bookRetakeButton" or "tc_training_bookCourseButton")
end

function MenuContractor:getCertificationNote(worker, cert)
    local definition = TheContractorTraining.getDefinition(cert)

    if worker:hasCertification(cert) then
        return nil
    end

    if worker.trainingCert == cert then
        local courseDates = TheContractorTraining.formatCourseDates(worker)
        local assessment = TCCalendar.formatDay(worker.assessmentDay)
        if courseDates ~= nil then
            return string.format(g_i18n:getText("tc_training_noteCourse"), courseDates, assessment)
        end
        return string.format(g_i18n:getText("tc_training_noteAssessment"), assessment)
    end

    if not TheContractorTraining.isReady(worker, cert) then
        return string.format(g_i18n:getText("tc_training_noteNotReady"), g_i18n:getText("tc_skill_" .. definition.skill),
            definition.readySkill, worker:getSkill(definition.skill))
    end

    local price = TheContractorTraining.formatPrice(TheContractorTraining.getPrice(g_currentMission:getFarmId(),
        worker, cert))
    if TheContractorTraining.isRetake(worker, cert) then
        return string.format(g_i18n:getText("tc_training_noteRetake"), price)
    end
    return string.format(g_i18n:getText("tc_training_noteReady"), price)
end

-- 039: when a worker who's handed in their notice (retiring, or 056
-- quitting) leaves, counted from today. nil if they aren't leaving.
function MenuContractor:getLeavingLine(worker)
    if not worker:isLeaving() then
        return nil
    end
    if worker:isLeaveDue() then
        return g_i18n:getText("tc_staff_detailRetiringDue")
    end

    local monthsLeft = worker.leavesAtPeriod - TCCalendar.getPeriodIndex()
    local date = TCCalendar.formatPeriodIndex(worker.leavesAtPeriod)
    if monthsLeft == 1 then
        return string.format(g_i18n:getText("tc_staff_detailRetiringNextMonth"), date)
    end
    return string.format(g_i18n:getText("tc_staff_detailRetiring"), date, monthsLeft)
end

-- 040: holiday days left this year at the days per period in force now,
-- and the booked holiday, if any (its row is hidden otherwise, see
-- updateStaffDetails).
function MenuContractor:updateHolidayDetails(worker)
    local environment = g_currentMission.environment
    self.staffDetailHolidayLeft:setText(string.format(g_i18n:getText("tc_staff_detailHolidayLeft"),
        TheContractorHolidays.getAllowanceDays(worker.holidayAllowance, environment.daysPerPeriod)))

    if worker:hasHolidayBooked() then
        local dates = TCCalendar.formatDayRange(math.max(worker.holidayStartDay, environment.currentMonotonicDay),
            worker:getHolidayEndDay())
        local key = worker.status == TheContractorWorker.STATUS.HOLIDAY and "tc_staff_detailHolidayNow" or
            "tc_staff_detailHolidayBooked"
        self.staffDetailHoliday:setText(string.format(g_i18n:getText(key), dates))
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

    if not staff:canAffordHire(farmId, candidate.salary) then
        InfoDialog.show(g_i18n:getText("tc_staff_hireCannotAfford"))
        return
    end

    local dialogPrompt = string.format(g_i18n:getText("tc_staff_hireConfirm"), candidate.name,
        g_i18n:formatMoney(candidate.salary, 0, true, true))

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

    -- 037: the server refuses it too (TheContractorStaff:releaseWorker).
    if worker.status == TheContractorWorker.STATUS.DRIVING then
        InfoDialog.show(string.format(g_i18n:getText("tc_staff_releaseDriving"), worker.name))
        return
    end

    local farmId = g_currentMission:getFarmId()

    YesNoDialog.show(function(target, clickOk)
        if not clickOk then
            return
        end

        g_client:getServerConnection():sendEvent(TCReleaseWorkerEvent.new(farmId, worker.id))

        target.selectedRosterWorkerId = nil
        target:refreshStaffState(farmId, g_currentMission.TheContractor.Staff, g_currentMission.TheContractor.Jobs)
    end, self, MenuContractor.getReleasePrompt(worker))
end

-- 056: "4" or "4.3" weeks.
local function formatWeeks(weeks)
    if math.abs(weeks - math.floor(weeks + 0.5)) < 0.05 then
        return string.format("%d", math.floor(weeks + 0.5))
    end
    return string.format("%.1f", weeks)
end

-- 056: the release confirmation, with what it costs (the same sum the
-- server charges - TheContractorStaff.getReleaseCost).
function MenuContractor.getReleasePrompt(worker)
    local cost = TheContractorStaff.getReleaseCost(worker)
    local function money(amount)
        return g_i18n:formatMoney(amount, 0, true, true)
    end

    if worker:isLeaving() then
        if cost.total <= 0 then
            return string.format(g_i18n:getText("tc_staff_releaseConfirmLeavingNow"), worker.name)
        end
        return string.format(g_i18n:getText("tc_staff_releaseConfirmLeaving"), worker.name, money(cost.total),
            formatWeeks(cost.noticeWeeks))
    end
    if cost.redundancyPay > 0 then
        return string.format(g_i18n:getText("tc_staff_releaseConfirmRedundancy"), worker.name, cost.years,
            money(cost.total), money(cost.noticePay), formatWeeks(cost.noticeWeeks), money(cost.redundancyPay))
    end
    return string.format(g_i18n:getText("tc_staff_releaseConfirmNotice"), worker.name, cost.years,
        money(cost.total), formatWeeks(cost.noticeWeeks))
end

-- 056: pick an amount (OptionDialog - a gamepad-friendly option picker),
-- then funds-check like onClickBookTraining. The server re-checks.
function MenuContractor:onClickGiveBonus()
    local worker = self:getSelectedRosterWorker()
    if worker == nil then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local amounts = TheContractorMorale.BONUS_AMOUNTS
    local options = {}
    for _, amount in ipairs(amounts) do
        table.insert(options, g_i18n:formatMoney(amount, 0, true, true))
    end

    OptionDialog.show(function(index)
        local amount = amounts[index]
        if amount == nil then
            return
        end

        if not TheContractorMorale.canAfford(farmId, amount) then
            InfoDialog.show(string.format(g_i18n:getText("tc_morale_bonusCannotAfford"),
                g_i18n:formatMoney(amount, 0, true, true), worker.name))
            return
        end

        g_client:getServerConnection():sendEvent(TCGiveBonusEvent.new(farmId, worker.id, amount))

        -- Same "synchronous for host/SP, catches up on next refresh for a
        -- remote client" caveat as onClickHireWorker.
        self:refreshStaffState(farmId, g_currentMission.TheContractor.Staff, g_currentMission.TheContractor.Jobs)
    end, string.format(g_i18n:getText("tc_morale_bonusPrompt"), worker.name), g_i18n:getText("tc_morale_bonusTitle"),
        options)
end

-- 058: pick a rise (OptionDialog, like onClickGiveBonus). No funds check:
-- nothing's paid now, it starts with the next salary run. The server works
-- the option out again.
function MenuContractor:onClickPayRise()
    local worker = self:getSelectedRosterWorker()
    if worker == nil then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local function money(amount)
        return g_i18n:formatMoney(amount, 0, true, true)
    end

    local riseOptions = TheContractorPayReviews.getRiseOptions(worker)
    local options = {}
    for _, option in ipairs(riseOptions) do
        if option.key == TheContractorPayReviews.OPTION_EXPECTED then
            table.insert(options, string.format(g_i18n:getText("tc_pay_optionExpected"), money(option.salary)))
        else
            table.insert(options, string.format(g_i18n:getText("tc_pay_optionPercent"), option.percent,
                money(option.salary)))
        end
    end

    local prompt
    if TheContractorPayReviews.wantsMore(worker) then
        prompt = string.format(g_i18n:getText("tc_pay_risePromptWants"), worker.name, money(worker.salary),
            money(worker.expectedSalary))
    else
        prompt = string.format(g_i18n:getText("tc_pay_risePrompt"), worker.name, money(worker.salary))
    end

    OptionDialog.show(function(index)
        local option = riseOptions[index]
        if option == nil then
            return
        end

        g_client:getServerConnection():sendEvent(TCPayRiseEvent.new(farmId, worker.id, option.key))

        -- Same "synchronous for host/SP, catches up on next refresh for a
        -- remote client" caveat as onClickHireWorker.
        self:refreshStaffState(farmId, g_currentMission.TheContractor.Staff, g_currentMission.TheContractor.Jobs)
    end, prompt, g_i18n:getText("tc_pay_riseTitle"), options)
end

-- 054: funds-check-then-confirm, like onClickHireWorker. The dates shown
-- are the ones the server will book (getFirstBookableDay works the same on
-- every machine), except the assessment's exact day, rolled when booked.
function MenuContractor:onClickBookTraining()
    local worker = self:getSelectedRosterWorker()
    local cert = MenuContractor.TRAINING_CERT
    if worker == nil or TheContractorTraining.getBookingProblem(worker, cert) ~= nil then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local price = TheContractorTraining.getPrice(farmId, worker, cert)
    local priceText = TheContractorTraining.formatPrice(price)
    local certName = TheContractorTraining.getCertName(cert)

    if not TheContractorTraining.canAfford(farmId, price) then
        InfoDialog.show(string.format(g_i18n:getText("tc_training_cannotAfford"), worker.name, certName, priceText))
        return
    end

    local definition = TheContractorTraining.getDefinition(cert)
    local firstDay = TheContractorTraining.getFirstBookableDay(worker)
    local dialogPrompt
    if TheContractorTraining.isRetake(worker, cert) then
        dialogPrompt = string.format(g_i18n:getText("tc_training_confirmRetake"), worker.name, certName, priceText,
            TCCalendar.formatDay(firstDay))
    else
        dialogPrompt = string.format(g_i18n:getText("tc_training_confirmCourse"), worker.name, certName, priceText,
            TCCalendar.formatDayRange(firstDay, firstDay + definition.courseDays - 1),
            TheContractorTraining.ASSESSMENT_GAP_MIN, TheContractorTraining.ASSESSMENT_GAP_MAX)
    end

    YesNoDialog.show(function(target, clickOk)
        if not clickOk then
            return
        end

        g_client:getServerConnection():sendEvent(TCBookTrainingEvent.new(farmId, worker.id, cert))

        -- Same "synchronous for host/SP, catches up on next refresh for a
        -- remote client" caveat as onClickHireWorker.
        target:refreshStaffState(farmId, g_currentMission.TheContractor.Staff, g_currentMission.TheContractor.Jobs)
    end, self, dialogPrompt)
end

-- Rebuilds the Inbox job list (offered/negotiating, newest first by job id —
-- the ticket leaves the exact ordering as a non-architectural decision) and
-- refreshes the selected job's detail panel. Called on frame open, tab
-- switch (updateContent), and after accept/decline locally applies.
-- Inbox messages (050) go above the jobs, newest first.
function MenuContractor:refreshInboxState(farmId, jobs)
    local inbox = g_currentMission.TheContractor.Inbox
    self.inboxMessages = inbox:getMessages(farmId)

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

    local hasItems = #self.inboxJobs + #self.inboxMessages > 0
    self.inboxListContainer:setVisible(hasItems)
    self.inboxEmptyText:setVisible(not hasItems)
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

    if self.selectedInboxMessageId ~= nil and inbox:getMessage(self.selectedInboxMessageId) == nil then
        self.selectedInboxMessageId = nil
    end

    self:updateInboxDetails()
end

function MenuContractor:getSelectedInboxMessage()
    for _, message in ipairs(self.inboxMessages) do
        if message.id == self.selectedInboxMessageId then
            return message
        end
    end
    return nil
end

-- 050: the highlighted message's panel, and its actions on the bottom bar.
function MenuContractor:updateInboxMessageDetails()
    local message = self:getSelectedInboxMessage()
    self.inboxMessageBox:setVisible(message ~= nil)

    if message == nil then
        self.menuButtonInfoInboxMessage = self.menuButtonInfoDefault
        return
    end

    local inbox = g_currentMission.TheContractor.Inbox
    self.inboxMessageTitle:setText(TheContractorInbox.getTitle(message))
    local chipText, chipTone = inbox:getChip(message)
    setChip(self.inboxMessageChip, self.inboxMessageChipText, chipText, chipTone)
    self.inboxMessageReceived:setText(TCCalendar.formatDay(message.createdDay))
    self.inboxMessageRowExpires:setVisible(message.expiresDay ~= nil)
    if message.expiresDay ~= nil then
        self.inboxMessageExpires:setText(TCCalendar.formatDay(message.expiresDay))
    end
    self.inboxMessageBody:setText(TheContractorInbox.getBody(message))
    self.inboxMessageRows:invalidateLayout()

    self.menuButtonInfoInboxMessage = { self.btnBack, self.btnNextPage, self.btnPrevPage }
    for i, action in ipairs(message.actions) do
        local button = self.btnMessageActions[i]
        if button ~= nil then
            button.text = g_i18n:getText(action.textKey)
            table.insert(self.menuButtonInfoInboxMessage, button)
        end
    end
end

function MenuContractor:onClickMessageAction(index)
    local message = self:getSelectedInboxMessage()
    local action = message ~= nil and message.actions[index] or nil
    if action == nil then
        return
    end

    local farmId = g_currentMission:getFarmId()
    g_client:getServerConnection():sendEvent(TCMessageActionEvent.new(farmId, message.id, action.key))

    -- Same "already applied on the server, catches up next visit on a
    -- remote client" caveat as respondToSelectedInboxJob.
    self.selectedInboxMessageId = nil
    self:refreshInboxState(farmId, g_currentMission.TheContractor.Jobs)
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
    self:updateInboxMessageDetails()

    local job = self:getSelectedInboxJob()
    self.inboxDetailsBox:setVisible(job ~= nil)
    self:setMenuButtonInfoDirty()

    if job == nil then
        return
    end

    self.inboxDetailTitle:setText(job:getDisplayTitle())

    local field = g_fieldManager:getFieldById(job.fieldId)
    local fieldText = field ~= nil and field:getName() or tostring(job.fieldId)
    if field ~= nil and field:getAreaHa() ~= nil then
        fieldText = string.format(g_i18n:getText("tc_inbox_fieldValue"), fieldText,
            g_i18n:formatArea(field:getAreaHa(), 2))
    end
    self.inboxDetailField:setText(fieldText)
    self.inboxDetailTargetDate:setText(formatTargetDate(job.targetPeriod, job.targetDayInPeriod))
    self.inboxDetailPrice:setText(g_i18n:formatMoney(job.price, 0, true, true))
    self.inboxDetailCrew:setText(self:getInboxCrewText(job))
    self.inboxDetailSkill:setText(string.format(g_i18n:getText("tc_inbox_skillValue"),
        job:getOperationSkillText() or "-", job.requiredSkillLevel))

    -- Harvest & haul (035): where the crop has to go.
    self.inboxRowDelivery:setVisible(job.includesHaulage)
    self.inboxDetailDelivery:setText(job.deliveryStationName or "?")

    self:updateInboxSupplies(job)
    self:updateInboxEquipment(job)

    local history = self.negotiationHistory[job.id]
    local latestMessage = history ~= nil and history[#history] or nil
    self.inboxNegotiationLog:setText(latestMessage or "")
    self.inboxNegotiationBox:setVisible(latestMessage ~= nil)

    self.inboxDetailRows:invalidateLayout()
end

-- Who can do the job: one worker (or the player), two for harvest & haul
-- (035) unless the player hauls, or the player alone for work the AI
-- helper can't do (032's playerOnly, bale wrapping).
function MenuContractor:getInboxCrewText(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef ~= nil and jobDef.playerOnly then
        return g_i18n:getText("tc_inbox_crewPlayerOnly")
    end
    if TheContractorAllocation.getRequiredWorkerCount(job) > 1 then
        return g_i18n:getText("tc_inbox_crewHaul")
    end
    return g_i18n:getText("tc_inbox_crewOne")
end

-- Supplies (032): the products a job would draw from the farm's stock
-- with this equipment, and whether the farm has any of them.
local function getSupplyStock(job, vehicles)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    local farmId = g_currentMission:getFarmId()
    local entries, anyInStock = {}, false
    for _, fillTypeIndex in ipairs(TCJobSupplies.getRequiredFillTypes(jobDef, vehicles)) do
        local stock = TCJobSupplies.getFarmStock(farmId, fillTypeIndex)
        table.insert(entries, { fillTypeIndex = fillTypeIndex, stock = stock })
        if stock > 0 then
            anyInStock = true
        end
    end
    return entries, anyInStock
end

local function joinSupplyTitles(entries)
    local titles = {}
    for _, entry in ipairs(entries) do
        table.insert(titles, g_fillTypeManager:getFillTypeTitleByIndex(entry.fillTypeIndex))
    end
    return table.concat(titles, g_i18n:getText("tc_supplies_or"))
end

-- The Inbox's supplies row: what the farm's equipment for the job would
-- use and how much of it's in stock; hidden for a job that uses nothing.
function MenuContractor:updateInboxSupplies(job)
    local entries, anyInStock = getSupplyStock(job,
        TheContractorJobGeneration.getFarmVehicles(g_currentMission:getFarmId()))
    self.inboxRowSupplies:setVisible(#entries > 0)
    if #entries == 0 then
        return
    end

    if not anyInStock then
        setChip(self.inboxDetailSuppliesChip, self.inboxDetailSuppliesChipText,
            g_i18n:getText("tc_inbox_suppliesNone"), "warn")
        self.inboxDetailSupplies:setText(string.format(g_i18n:getText("tc_inbox_suppliesNeeded"),
            joinSupplyTitles(entries)))
        return
    end

    local parts = {}
    for _, entry in ipairs(entries) do
        table.insert(parts, TCJobSupplies.formatAmount(entry.fillTypeIndex, entry.stock))
    end
    setChip(self.inboxDetailSuppliesChip, self.inboxDetailSuppliesChipText,
        g_i18n:getText("tc_inbox_suppliesInStock"), "good")
    self.inboxDetailSupplies:setText(table.concat(parts, ", "))
end

-- inboxEquipRow1..N in MenuContractor.xml.
MenuContractor.INBOX_EQUIPMENT_SLOTS = 6

-- The equipment a job needs, as { key, isHaulage } in display order, keyed
-- like TCEquipmentClass.getMissingEquipment/getMissingHaulageEquipment so
-- each row can be checked off against those. The core pieces always show;
-- the conditional ones (a tractor, a seed tank, a matching header, a
-- trailer that hitches) only when they're actually needed - the missing
-- lists name them when they're a problem, jobMayNeedTractor when the
-- farm's own kit has to be towed.
function MenuContractor:getInboxEquipmentRows(job, missingFree, haulageMissingFree)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    local rows = {}
    if jobDef == nil then
        return rows
    end

    local function add(key, isHaulage)
        for _, row in ipairs(rows) do
            if row.key == key and row.isHaulage == isHaulage then
                return
            end
        end
        table.insert(rows, { key = key, isHaulage = isHaulage })
    end

    if jobDef.cropDependent then
        add("cutter", false)
        add("harvester", false)
    else
        add("implement", false)
    end
    for _, key in ipairs(missingFree) do
        add(key, false)
    end
    if g_currentMission.TheContractor.Allocation:jobMayNeedTractor(g_currentMission:getFarmId(), job) then
        add("tractor", false)
    end

    if job.includesHaulage then
        add("haulTractor", true)
        add("trailer", true)
        for _, key in ipairs(haulageMissingFree) do
            add(key, true)
        end
    end
    return rows
end

-- Player-facing name of one equipment row, e.g. "Header or harvester for
-- Canola", "Plow", "Trailer that takes Wheat (if a worker hauls)".
local function getEquipmentNeedText(key, isHaulage, job)
    local text
    if key == "implement" then
        text = g_i18n:getText("tc_equipment_need_implement_" .. job.jobType)
    elseif key == "cutter" or key == "cutterMismatch" or key == "trailer" then
        text = string.format(g_i18n:getText("tc_equipment_need_" .. key),
            job:getCropTitle() or g_i18n:getText("tc_equipment_anyCrop"))
    else
        text = g_i18n:getText("tc_equipment_need_" .. key)
    end
    if isHaulage then
        text = string.format(g_i18n:getText("tc_equipment_need_haulageSuffix"), text)
    end
    return text
end

-- One row per piece of equipment with an Owned / Busy (owned, but out on
-- another job or in cooldown) / Missing chip - live against the current
-- fleet rather than job.equipmentAvailable (a snapshot from generation
-- time), so buying the missing piece shows up here straight away.
function MenuContractor:updateInboxEquipment(job)
    local farmId = g_currentMission:getFarmId()
    local allocation = g_currentMission.TheContractor.Allocation
    local missingOwned, missingFree = allocation:getMissingEquipment(farmId, job)
    local haulageOwned, haulageFree = {}, {}
    if job.includesHaulage then
        haulageOwned, haulageFree = allocation:getMissingHaulageEquipment(farmId, job)
    end

    local rows = self:getInboxEquipmentRows(job, missingFree, haulageFree)
    for i = 1, MenuContractor.INBOX_EQUIPMENT_SLOTS do
        local row = rows[i]
        self["inboxEquipRow" .. i]:setVisible(row ~= nil)
        if row ~= nil then
            local owned = row.isHaulage and haulageOwned or missingOwned
            local free = row.isHaulage and haulageFree or missingFree
            local chip, chipText = self["inboxEquipChip" .. i], self["inboxEquipChipText" .. i]
            if table.hasElement(owned, row.key) then
                setChip(chip, chipText, g_i18n:getText("tc_inbox_equipmentStatusMissing"), "bad")
            elseif table.hasElement(free, row.key) then
                setChip(chip, chipText, g_i18n:getText("tc_inbox_equipmentStatusBusy"), "warn")
            else
                setChip(chip, chipText, g_i18n:getText("tc_inbox_equipmentStatusOwned"), "good")
            end
            self["inboxEquipName" .. i]:setText(getEquipmentNeedText(row.key, row.isHaulage, job))
        end
    end
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
    elseif list == self.calendarCompletedTable then
        return #self.completedJobs
    elseif list == self.allocationWorkerTable then
        return #self.allocationWorkerRows
    elseif list == self.allocationEquipmentTable then
        return #self.allocationEquipmentRows
    elseif list == self.staffTable then
        return self.staffView == "candidates" and #self.candidateList or #self.rosterWorkers
    elseif list == self.financesInvoiceTable then
        return #self.invoiceList
    elseif list == self.financesOverheadTable then
        return #self.overheadRows
    elseif list == self.logbookJobTable then
        return #self.logbookJobs
    elseif list == self.logbookVehicleTable then
        return #self.logbookVehicleRows
    elseif list == self.logbookDetailTable then
        return #self.logbookDetailRows
    end
    return #self.inboxMessages + #self.inboxJobs
end

function MenuContractor:populateCellForItemInSection(list, section, index, cell)
    if list == self.calendarDayTable then
        self:populateCalendarDayCell(index, cell)
        return
    elseif list == self.calendarDayJobsTable then
        self:populateCalendarDayJobCell(index, cell)
        return
    elseif list == self.calendarCompletedTable then
        self:populateCompletedJobCell(index, cell)
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
    elseif list == self.financesInvoiceTable then
        self:populateInvoiceCell(index, cell)
        return
    elseif list == self.financesOverheadTable then
        self:populateOverheadCell(index, cell)
        return
    elseif list == self.logbookJobTable then
        self:populateLogbookJobCell(index, cell)
        return
    elseif list == self.logbookVehicleTable then
        self:populateLogbookVehicleCell(index, cell)
        return
    elseif list == self.logbookDetailTable then
        self:populateLogbookDetailCell(index, cell)
        return
    end

    -- 050: message rows first, then job rows. Cells are reused, so each
    -- kind of row shows its own cells and hides the other's.
    local message = self.inboxMessages[index]
    local isMessage = message ~= nil
    for _, name in ipairs({ "jobType", "field", "targetDate", "price" }) do
        cell:getAttribute(name):setVisible(not isMessage)
    end
    cell:getAttribute("messageTitle"):setVisible(isMessage)
    if isMessage then
        local chipText, chipTone = g_currentMission.TheContractor.Inbox:getChip(message)
        setChip(cell:getAttribute("kindChip"), cell:getAttribute("kindChipText"), chipText, chipTone)
        cell:getAttribute("messageTitle"):setText(TheContractorInbox.getTitle(message))
        setChip(cell:getAttribute("equipmentChip"), cell:getAttribute("equipmentChipText"), nil)
        return
    end
    setChip(cell:getAttribute("kindChip"), cell:getAttribute("kindChipText"), nil)

    local job = self.inboxJobs[index - #self.inboxMessages]
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
    local chip, chipText = cell:getAttribute("equipmentChip"), cell:getAttribute("equipmentChipText")
    if jobDef == nil or g_currentMission.TheContractor.JobGeneration:canFulfill(g_currentMission:getFarmId(), jobDef,
            job:getFruitTypeIndex()) then
        setChip(chip, chipText, g_i18n:getText("tc_inbox_equipmentYes"), "good")
    else
        setChip(chip, chipText, g_i18n:getText("tc_inbox_equipmentNo"), "bad")
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

    -- Just tracks the highlight and redraws the report text - must not
    -- reload the list (reloadData re-raises this, see the equipment picker
    -- note below).
    if list == self.calendarCompletedTable then
        local job = self.completedJobs[index]
        self.selectedCompletedJobId = job ~= nil and job.id or nil
        self:updateCompletedJobReport()
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

    -- Like the completed-jobs list: just tracks the highlight, no reload.
    if list == self.financesInvoiceTable then
        local invoice = self.invoiceList[index]
        self.selectedInvoiceId = invoice ~= nil and invoice.id or nil
        self:updateInvoiceDetails()
        return
    end

    if list == self.financesOverheadTable then
        local definition = self.overheadRows[index]
        self.selectedOverheadKey = definition ~= nil and definition.key or nil
        self:updateOverheadDetails()
        return
    end

    -- Logbook (060): the two left-hand lists redraw the detail list; the
    -- detail list only tracks its highlight, for the bottom-bar jumps.
    -- None of them reload their own list from here.
    if list == self.logbookJobTable then
        local entry = self.logbookJobs[index]
        self.selectedLogbookJobId = entry ~= nil and entry.jobId or nil
        self:updateLogbookDetails()
        return
    end

    if list == self.logbookVehicleTable then
        local row = self.logbookVehicleRows[index]
        self.selectedLogbookVehicleId = row ~= nil and row.id or nil
        self:updateLogbookDetails()
        return
    end

    if list == self.logbookDetailTable then
        self.logbookDetailIndex = index
        self:setMenuButtonInfoDirty()
        return
    end

    if list ~= self.inboxTable then
        return
    end

    local message = self.inboxMessages[index]
    local job = self.inboxJobs[index - #self.inboxMessages]
    self.selectedInboxMessageId = message ~= nil and message.id or nil
    self.selectedInboxJobId = message == nil and job ~= nil and job.id or nil
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
    self:refreshCompletedJobsState(farmId, jobs)
end

-- Completed jobs (029 follow-up) -----------------------------------------

-- The absolute (monotonic) day a completed job finished on, as a calendar
-- period/day/year, counted back from today. Assumes daysPerPeriod hasn't
-- changed since, which is all we can do without storing the date itself.
local function monotonicDayToCalendar(monotonicDay)
    local environment = g_currentMission.environment
    local daysPerPeriod = environment.daysPerPeriod
    local yearLength = daysPerPeriod * Environment.PERIODS_IN_YEAR
    local todayIndex = (environment.currentPeriod - 1) * daysPerPeriod + environment.currentDayInPeriod - 1
    local index = todayIndex - (environment.currentMonotonicDay - monotonicDay)
    local yearOffset = math.floor(index / yearLength)
    local indexInYear = index - yearOffset * yearLength
    return math.floor(indexInYear / daysPerPeriod) + 1, indexInYear % daysPerPeriod + 1,
        environment.currentYear + yearOffset
end

local function formatCompletedAt(completedAt)
    if completedAt == nil then
        return "-"
    end
    local period, dayInPeriod, year = monotonicDayToCalendar(math.floor(completedAt / (24 * 60)))
    return formatCalendarDate(period, dayInPeriod, year)
end

-- Same reload-then-show-the-wrapping-container shape as
-- updateCalendarDayDetails (never toggle the SmoothList itself). Keeps the
-- highlighted job if it's still listed, otherwise re-picks the newest.
function MenuContractor:refreshCompletedJobsState(farmId, jobs)
    self.completedJobs = jobs:getJobsByState(farmId, TheContractorJob.STATE.COMPLETED)
    table.sort(self.completedJobs, function(a, b)
        if (a.completedAt or -1) ~= (b.completedAt or -1) then
            return (a.completedAt or -1) > (b.completedAt or -1)
        end
        return a.id > b.id
    end)

    self.calendarCompletedTable:reloadData()

    local hasJobs = #self.completedJobs > 0
    self.calendarCompletedContainer:setVisible(self.allocatingJobId == nil)
    self.calendarCompletedEmptyText:setVisible(not hasJobs)
    self.calendarCompletedListContainer:setVisible(hasJobs)

    local selectedIndex = nil
    for i, job in ipairs(self.completedJobs) do
        if job.id == self.selectedCompletedJobId then
            selectedIndex = i
        end
    end
    if hasJobs then
        selectedIndex = selectedIndex or 1
        self.calendarCompletedTable:setSelectedIndex(selectedIndex)
        self.selectedCompletedJobId = self.completedJobs[selectedIndex].id
    else
        self.selectedCompletedJobId = nil
    end

    self:updateCompletedJobReport()
end

function MenuContractor:populateCompletedJobCell(index, cell)
    local job = self.completedJobs[index]
    if job == nil then
        return
    end

    cell:getAttribute("jobType"):setText(job:getDisplayTitle())

    local field = g_fieldManager:getFieldById(job.fieldId)
    cell:getAttribute("field"):setText(field ~= nil and field:getName() or tostring(job.fieldId))

    cell:getAttribute("completed"):setText(formatCompletedAt(job.completedAt))

    local chip, chipText = cell:getAttribute("qualityChip"), cell:getAttribute("qualityChipText")
    if job.qualityScore ~= nil then
        setChip(chip, chipText, string.format("%d%%", job.qualityScore), getQualityChipTone(job.qualityScore))
    else
        setChip(chip, chipText, "-", "neutral")
    end
end

-- Who did it: "You", or the worker(s) by name. A worker released since
-- is no longer on the roster, so they're shown as a former employee.
function MenuContractor:getCompletedJobCrewText(job)
    local workerIds = job:getWorkerIds()
    if #workerIds == 0 then
        return g_i18n:getText("tc_allocation_myself")
    end

    local staff = g_currentMission.TheContractor.Staff
    local names = {}
    for _, workerId in ipairs(workerIds) do
        local worker = staff:getWorker(job.farmId, workerId)
        table.insert(names, worker ~= nil and worker.name or g_i18n:getText("tc_calendar_formerWorker"))
    end
    return table.concat(names, ", ")
end

function MenuContractor:updateCompletedJobReport()
    local job = nil
    for _, candidate in ipairs(self.completedJobs) do
        if candidate.id == self.selectedCompletedJobId then
            job = candidate
        end
    end

    if job == nil then
        self.calendarCompletedReport:setText("")
        return
    end

    self.calendarCompletedReport:setText(string.format(g_i18n:getText("tc_calendar_completedReport"),
        self:getCompletedJobCrewText(job),
        job:getPaymentText(),
        TheContractorJob.formatMinutes(job:getTimeTakenMinutes()),
        g_i18n:formatMoney(job.fuelCost, 0, true, true), job.fuelUsedLiters,
        job.qualityScore ~= nil and string.format("%d%%", job.qualityScore) or "-",
        job.stuckInterventions))
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
    local chip, chipText = cell:getAttribute("statusChip"), cell:getAttribute("statusChipText")
    if #row.jobs == 0 then
        setChip(chip, chipText, nil)
    elseif row.missedCount > 0 then
        setChip(chip, chipText, string.format(g_i18n:getText("tc_calendar_missedCount"), row.missedCount), "bad")
    elseif row.unallocatedCount > 0 then
        setChip(chip, chipText, string.format(g_i18n:getText("tc_calendar_unallocatedCount"), row.unallocatedCount),
            "warn")
    else
        setChip(chip, chipText, g_i18n:getText("tc_calendar_allAllocated"), "good")
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
    -- distinct "Failed" chip rather than folding into either bucket — it's
    -- neither waiting on allocation nor successfully allocated, it's over
    -- and done with. A hired worker's job then reads Allocated (info) ->
    -- Travelling (info, Dispatch's transport wait) -> In progress (good)
    -- with the same live percentage the Overview's current-jobs list shows.
    -- On hold for supplies (032) beats every other working state: nothing
    -- moves until the player restocks (or empties the wrong product out).
    local chip, chipText = cell:getAttribute("statusChip"), cell:getAttribute("statusChipText")
    if job.state == TheContractorJob.STATE.MISSED then
        setChip(chip, chipText, g_i18n:getText("tc_calendar_jobMissed"), "bad")
    elseif job:isWaitingForSupplies() and (job.state == TheContractorJob.STATE.ALLOCATED or
            job.state == TheContractorJob.STATE.IN_PROGRESS) then
        setChip(chip, chipText, job:getSupplyStatusText(), "warn")
    elseif job.state == TheContractorJob.STATE.ACCEPTED then
        setChip(chip, chipText, g_i18n:getText("tc_calendar_jobUnallocated"), "warn")
    elseif job.state == TheContractorJob.STATE.IN_PROGRESS then
        setChip(chip, chipText, string.format(g_i18n:getText("tc_calendar_jobInProgress"),
            math.floor(job.completionPercentage)), "good")
    elseif job.isTravelling then
        setChip(chip, chipText, g_i18n:getText("tc_calendar_jobTravelling"), "info")
    elseif job:needsPlayerDelivery() and job.requiredLiters > 0 and job.state == TheContractorJob.STATE.ALLOCATED then
        -- Player-driven haulage (035): cut and delivered, both.
        setChip(chip, chipText, string.format(g_i18n:getText("tc_calendar_jobDelivering"),
            math.floor(job.completionPercentage), math.floor(100 * job.deliveredLiters / job.requiredLiters)), "good")
    else
        setChip(chip, chipText, g_i18n:getText("tc_calendar_jobAllocated"), "info")
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
    self.calendarCompletedContainer:setVisible(true)
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
    -- The allocation panel runs down over the completed-jobs section.
    self.calendarCompletedContainer:setVisible(false)
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
    setAllocationCheckBox(cell:getAttribute("checkBox"), self:isAllocationWorkerRowSelected(row))
    cell:getAttribute("name"):setText(row.label)
end

function MenuContractor:populateAllocationEquipmentCell(index, cell)
    local row = self.allocationEquipmentRows[index]
    if row == nil then
        return
    end

    setAllocationCheckBox(cell:getAttribute("checkBox"), self.allocationSelectedEquipmentKeys[row.key] == true)
    cell:getAttribute("name"):setText(row.label)
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

    local operatorId, haulerId, capability = allocation:assignCrewRoles(farmId, job, workerIds, equipmentIds,
        haulageIds)
    if capability == TheContractorAllocation.CAPABILITY.BLOCKED then
        return self:getCrewWeaknessText(job, operatorId, haulerId, equipmentIds, haulageIds), true
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
        return self:getCrewWeaknessText(job, operatorId, haulerId, equipmentIds, haulageIds), false
    end
    return nil, false
end

-- 044: the allocation warning for a crew that's blocked or under-qualified,
-- naming who and what - an uncertified tractor size first ("Amy Hall isn't
-- certified on large tractors."), else the weakest rating that falls short
-- ("Amy Hall: Planting 3, the job needs 6 - ...").
function MenuContractor:getCrewWeaknessText(job, operatorId, haulerId, equipmentIds, haulageIds)
    local farmId = g_currentMission:getFarmId()
    local staff = g_currentMission.TheContractor.Staff
    local allocation = g_currentMission.TheContractor.Allocation

    local crew = { { workerId = operatorId, equipmentIds = equipmentIds, isHauler = false } }
    if haulerId ~= nil then
        table.insert(crew, { workerId = haulerId, equipmentIds = haulageIds, isHauler = true })
    end

    local weakest = nil
    for _, member in ipairs(crew) do
        local worker = member.workerId ~= nil and staff:getWorker(farmId, member.workerId) or nil
        if worker ~= nil then
            -- 054: a missing certificate blocks before anything else.
            local missingCert = TheContractorAllocation.getMissingCertification(worker, job, member.isHauler)
            if missingCert ~= nil then
                return string.format(g_i18n:getText("tc_allocation_notCertifiedWarning"), worker.name,
                    TheContractorTraining.getCertName(missingCert))
            end
            local ratings = allocation:getWorkerJobRatings(worker, job, member.equipmentIds, member.isHauler)
            if ratings.tractorTier ~= nil and ratings.tractorRating == nil then
                return string.format(g_i18n:getText("tc_allocation_blockedWarning"), worker.name,
                    g_i18n:getText("tc_growth_stat_" .. ratings.tractorTier))
            end
            local rating, stat = TheContractorAllocation.getWeakestRating(ratings)
            if rating ~= nil and (weakest == nil or rating < weakest.rating) then
                weakest = { worker = worker, rating = rating, stat = stat }
            end
        end
    end

    if weakest == nil or weakest.rating >= job.requiredSkillLevel then
        return nil
    end

    local statText = TheContractorWorker.IS_SKILL[weakest.stat] and g_i18n:getText("tc_skill_" .. weakest.stat) or
        g_i18n:getText("tc_staff_tierTractor_" .. weakest.stat)
    return string.format(g_i18n:getText("tc_allocation_underqualifiedWarning"), weakest.worker.name, statText,
        weakest.rating, job.requiredSkillLevel)
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

    -- Supplies (032): the picked equipment needs something the farm has
    -- none of - allowed (stock may arrive before the job starts), but the
    -- job will sit on hold until it does.
    local selectedVehicles = {}
    for _, vehicleId in ipairs(self:getSelectedAllocationEquipmentIds(false)) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil then
            table.insert(selectedVehicles, vehicle)
        end
    end
    local supplyEntries, anySupplyInStock = getSupplyStock(job, selectedVehicles)

    local problem = self:getAllocationProblem(job)
    if problem ~= nil then
        self.allocationWarningText:setText(problem)
        self.allocationWarningText:setTextColor(1, 0.75, 0.25, 1)
    elseif #supplyEntries > 0 and not anySupplyInStock then
        self.allocationWarningText:setText(string.format(g_i18n:getText("tc_allocation_noSuppliesWarning"),
            joinSupplyTitles(supplyEntries)))
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
    local previousRounds = previousJob ~= nil and previousJob.negotiationRounds or nil

    g_client:getServerConnection():sendEvent(TCCounterOfferEvent.new(farmId, jobId, counterPrice))

    self:refreshInboxState(farmId, jobs)

    local updatedJob = jobs:getJob(farmId, jobId)
    if updatedJob ~= nil and previousPrice ~= nil then
        local message = self:describeNegotiationOutcome(previousPrice, previousRounds, updatedJob, counterPrice)
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

function MenuContractor:describeNegotiationOutcome(previousPrice, previousRounds, job, counterPrice)
    if job.state == TheContractorJob.STATE.ACCEPTED then
        return string.format(g_i18n:getText("tc_inbox_negotiationAccepted"),
            g_i18n:formatMoney(job.price, 0, true, true))
    elseif job.state == TheContractorJob.STATE.DECLINED then
        return g_i18n:getText("tc_inbox_negotiationDeclined")
    elseif job.price ~= previousPrice then
        return string.format(g_i18n:getText("tc_inbox_negotiationCountered"),
            g_i18n:formatMoney(counterPrice, 0, true, true), g_i18n:formatMoney(job.price, 0, true, true))
    elseif job.negotiationRounds > previousRounds then
        -- Countered at the price they'd already offered (026's negotiation
        -- never lets their counter drop) - they're holding firm.
        return string.format(g_i18n:getText("tc_inbox_negotiationHolding"),
            g_i18n:formatMoney(job.price, 0, true, true))
    end
    return nil
end

-- Active-ad status line. Purchase gating lives in TCAdvertisingDialog now
-- (027), so there's no button state to update here.
-- Finances (049) -----------------------------------------------------------

local function formatMoney(amount)
    return g_i18n:formatMoney(amount, 0, true, true)
end

-- Rebuilds the invoice list (keeping the highlighted invoice if it's still
-- listed, otherwise picking the first, like refreshCompletedJobsState) and
-- the cash-flow and year-to-date cards.
function MenuContractor:refreshFinancesState(farmId, finances)
    self.financesContent:setVisible(true)

    self.financesViewSelector:setTexts({ g_i18n:getText("tc_finances_viewInvoices"),
        g_i18n:getText("tc_finances_viewOverheads") })
    self.financesViewSelector:setState(self.financesView == "overheads" and 2 or 1)

    self:refreshCashFlowState(farmId, finances)
    self:refreshFinanceYearState(farmId, finances)

    -- 051: the list and the top-right panel follow the view.
    if self.financesView == "overheads" then
        self.financesListContainer:setVisible(false)
        self.financesListEmptyText:setVisible(false)
        self.financesInvoiceRows:setVisible(false)
        self.financesInvoiceEmptyText:setVisible(false)
        self:refreshOverheadsState(farmId, g_currentMission.TheContractor.Overheads)
        return
    end
    self.financesOverheadContainer:setVisible(false)
    self.financesOverheadRows:setVisible(false)

    self.invoiceList = finances:getUnpaidInvoices(farmId)
    self.financesInvoiceTable:reloadData()

    local hasInvoices = #self.invoiceList > 0
    self.financesListContainer:setVisible(hasInvoices)
    self.financesListEmptyText:setVisible(not hasInvoices)

    local selectedIndex = nil
    for i, invoice in ipairs(self.invoiceList) do
        if invoice.id == self.selectedInvoiceId then
            selectedIndex = i
        end
    end
    if hasInvoices then
        selectedIndex = selectedIndex or 1
        self.financesInvoiceTable:setSelectedIndex(selectedIndex)
        self.selectedInvoiceId = self.invoiceList[selectedIndex].id
    else
        self.selectedInvoiceId = nil
    end
    self:updateInvoiceDetails()
end

function MenuContractor:onClickFinancesView()
    self.financesView = self.financesViewSelector:getState() == 2 and "overheads" or "invoices"
    self:refreshFinancesState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Finances)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:refreshCashFlowState(farmId, finances)
    local farm = g_farmManager:getFarmById(farmId)
    self.financesBalance:setText(farm ~= nil and formatMoney(farm:getBalance()) or "-")
    self.financesOutstanding:setText(formatMoney(finances:getTotal(farmId, TheContractorFinances.STATUS.OUTSTANDING)))
    -- 053: an invoice being pursued is still overdue.
    self.financesOverdue:setText(formatMoney(finances:getTotal(farmId, TheContractorFinances.STATUS.OVERDUE) +
        finances:getTotal(farmId, TheContractorFinances.STATUS.PURSUING)))
    local staff = g_currentMission.TheContractor.Staff
    self.financesSalaryBill:setText(string.format(g_i18n:getText("tc_finances_salaryBillWithPension"),
        formatMoney(staff:getWageBill(farmId)), formatMoney(staff:getPensionCost(farmId))))

    for i, row in ipairs(finances:getForecast(farmId)) do
        local month = TCCalendar.formatMonth(row.periodIndex)
        self["financesForecastLabel" .. i]:setText(i == 1 and
            string.format(g_i18n:getText("tc_finances_forecastThisMonth"), month) or month)
        self["financesForecastValue" .. i]:setText(string.format(g_i18n:getText("tc_finances_forecastLine"),
            formatMoney(row.income), formatMoney(row.wages), formatMoney(row.overheads),
            formatMoney(row.income - row.wages - row.overheads)))
    end

    self.financesCashFlowRows:invalidateLayout()
end

function MenuContractor:refreshFinanceYearState(farmId, finances)
    local stats = finances:getYearStats(farmId)
    self.financesYearTitle:setText(string.format(g_i18n:getText("tc_finances_yearHeading"), stats.year))
    self.financesYearInvoiced:setText(formatMoney(stats.invoiced))
    self.financesYearReceived:setText(formatMoney(stats.received))
    self.financesYearWrittenOff:setText(formatMoney(stats.writtenOff))
    -- 054: training courses share the wages row, for the same reason as below.
    self.financesYearWages:setText(formatMoney(stats.wages + (stats.training or 0)))
    self.financesYearOverheads:setText(formatMoney(stats.overheads or 0))
    -- 053/055: solicitors' fees and H&S fines share the claims row - there's
    -- no room for another.
    self.financesYearClaims:setText(formatMoney((stats.claims or 0) + (stats.legal or 0) + (stats.fines or 0)))

    self.financesYearRows:invalidateLayout()
end

function MenuContractor:getSelectedInvoice()
    for _, invoice in ipairs(self.invoiceList) do
        if invoice.id == self.selectedInvoiceId then
            return invoice
        end
    end
    return nil
end

function MenuContractor:populateInvoiceCell(index, cell)
    local invoice = self.invoiceList[index]
    if invoice == nil then
        return
    end

    local job = g_currentMission.TheContractor.Jobs:getJob(invoice.farmId, invoice.jobId)
    local fieldText = "-"
    if job ~= nil then
        local field = g_fieldManager:getFieldById(job.fieldId)
        fieldText = field ~= nil and field:getName() or tostring(job.fieldId)
    end
    cell:getAttribute("job"):setText(job ~= nil and job:getDisplayTitle() or "-")
    cell:getAttribute("field"):setText(fieldText)
    cell:getAttribute("amount"):setText(formatMoney(invoice.amount))
    cell:getAttribute("due"):setText(TCCalendar.formatDayShort(invoice.dueDay))
    setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"),
        g_i18n:getText("tc_finances_status_" .. invoice.status), INVOICE_STATUS_TONES[invoice.status])
end

-- What the status means for this invoice: how long until it's due, how late
-- it is, when it was written off, or since when it's been pursued (053).
local function getInvoiceStatusNote(invoice)
    local today = g_currentMission.environment.currentMonotonicDay
    if invoice.status == TheContractorFinances.STATUS.PURSUING then
        local since = TCCalendar.formatDayShort(invoice.pursuitStartDay)
        if (invoice.pursuitFee or 0) == 0 then
            return string.format(g_i18n:getText("tc_legal_pursuingCovered"), since)
        end
        return string.format(g_i18n:getText("tc_legal_pursuingSolicitor"), since, formatMoney(invoice.pursuitFee))
    elseif invoice.status == TheContractorFinances.STATUS.OVERDUE then
        return string.format(g_i18n:getText("tc_finances_overdueDays"), today - invoice.dueDay)
    elseif invoice.status == TheContractorFinances.STATUS.WRITTEN_OFF then
        return invoice.settledDay ~= nil and
            string.format(g_i18n:getText("tc_finances_writtenOffOn"), TCCalendar.formatDay(invoice.settledDay)) or ""
    end
    local daysLeft = invoice.dueDay - today
    if daysLeft <= 0 then
        return g_i18n:getText("tc_finances_dueToday")
    end
    return string.format(g_i18n:getText("tc_finances_dueInDays"), daysLeft)
end

function MenuContractor:updateInvoiceDetails()
    self:setMenuButtonInfoDirty()

    local invoice = self:getSelectedInvoice()
    self.financesInvoiceRows:setVisible(invoice ~= nil)
    self.financesInvoiceEmptyText:setVisible(invoice == nil)
    if invoice == nil then
        self.financesInvoiceTitle:setText(g_i18n:getText("tc_finances_invoiceHeading"))
        return
    end

    local finances = g_currentMission.TheContractor.Finances
    self.financesInvoiceTitle:setText(finances:getInvoiceTitle(invoice))
    self.financesInvoiceAmount:setText(formatMoney(invoice.amount))
    self.financesInvoiceIssued:setText(TCCalendar.formatDay(invoice.issuedDay))
    self.financesInvoiceDue:setText(TCCalendar.formatDay(invoice.dueDay))
    setChip(self.financesInvoiceStatusChip, self.financesInvoiceStatusChipText,
        g_i18n:getText("tc_finances_status_" .. invoice.status), INVOICE_STATUS_TONES[invoice.status])
    self.financesInvoiceStatusNote:setText(getInvoiceStatusNote(invoice))

    local job = g_currentMission.TheContractor.Jobs:getJob(invoice.farmId, invoice.jobId)
    self.financesInvoiceJob:setText(job ~= nil and job:getSummaryText() or "-")

    self.financesInvoiceRows:invalidateLayout()
end

-- Confirm, then ask the server; it re-checks the invoice is still overdue.
function MenuContractor:onClickWriteOffInvoice()
    local invoice = self:getSelectedInvoice()
    if invoice == nil or invoice.status ~= TheContractorFinances.STATUS.OVERDUE then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local finances = g_currentMission.TheContractor.Finances
    local dialogPrompt = string.format(g_i18n:getText("tc_finances_writeOffConfirm"), finances:getInvoiceTitle(invoice),
        formatMoney(invoice.amount))

    YesNoDialog.show(function(target, clickOk)
        if not clickOk then
            return
        end

        g_client:getServerConnection():sendEvent(TCWriteOffInvoiceEvent.new(farmId, invoice.id))

        -- Same "synchronous for host/SP, catches up on next refresh for a
        -- remote client" caveat as onClickHireWorker.
        target:refreshFinancesState(farmId, g_currentMission.TheContractor.Finances)
    end, self, dialogPrompt)
end

-- 053: free with legal cover; otherwise the solicitor's fee is paid now, so
-- it has to be affordable. Confirm either way, then ask the server, which
-- re-checks both.
function MenuContractor:onClickPursueInvoice()
    local invoice = self:getSelectedInvoice()
    if invoice == nil or invoice.status ~= TheContractorFinances.STATUS.OVERDUE then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local tc = g_currentMission.TheContractor
    local title = tc.Finances:getInvoiceTitle(invoice)
    local fee = tc.Association:getPursuitFee(farmId, invoice)

    local dialogPrompt
    if fee == 0 then
        dialogPrompt = string.format(g_i18n:getText("tc_legal_pursueConfirmCovered"), title, formatMoney(invoice.amount))
    else
        local farm = g_farmManager:getFarmById(farmId)
        if farm == nil or farm:getBalance() < fee then
            InfoDialog.show(string.format(g_i18n:getText("tc_legal_cannotAfford"), formatMoney(fee)))
            return
        end
        dialogPrompt = string.format(g_i18n:getText("tc_legal_pursueConfirmSolicitor"), title,
            formatMoney(invoice.amount), formatMoney(fee))
    end

    YesNoDialog.show(function(target, clickOk)
        if not clickOk then
            return
        end

        g_client:getServerConnection():sendEvent(TCPursueInvoiceEvent.new(farmId, invoice.id))

        -- Same "synchronous for host/SP, catches up on next refresh for a
        -- remote client" caveat as onClickHireWorker.
        target:refreshFinancesState(farmId, g_currentMission.TheContractor.Finances)
    end, self, dialogPrompt)
end

-- Overheads (051) -----------------------------------------------------------

-- 057: the office administrator is listed after the overheads, as a row
-- with this key. It's a salary, not a policy, so it has its own panel and
-- buttons (updateAdministratorDetails, getOverheadButtonInfo).
MenuContractor.ADMINISTRATOR_ROW_KEY = "officeAdministrator"

-- Lists every registered overhead, then the office administrator (keeping
-- the highlighted row, otherwise the first) and fills the panel for it.
function MenuContractor:refreshOverheadsState(farmId, overheads)
    self.overheadRows = {}
    for _, definition in ipairs(overheads:getDefinitions()) do
        table.insert(self.overheadRows, definition)
    end
    table.insert(self.overheadRows, { key = MenuContractor.ADMINISTRATOR_ROW_KEY, isAdministrator = true })
    self.financesOverheadTable:reloadData()
    self.financesOverheadContainer:setVisible(true)

    local selectedIndex = 1
    for i, definition in ipairs(self.overheadRows) do
        if definition.key == self.selectedOverheadKey then
            selectedIndex = i
        end
    end
    if #self.overheadRows > 0 then
        self.financesOverheadTable:setSelectedIndex(selectedIndex)
        self.selectedOverheadKey = self.overheadRows[selectedIndex].key
    else
        self.selectedOverheadKey = nil
    end
    self:updateOverheadDetails()
end

function MenuContractor:getSelectedOverhead()
    if self.selectedOverheadKey == nil then
        return nil, nil
    end
    local overheads = g_currentMission.TheContractor.Overheads
    local definition = overheads:getDefinition(self.selectedOverheadKey)
    if definition == nil then
        return nil, nil
    end
    return definition, overheads:getState(g_currentMission:getFarmId(), definition.key)
end

-- The status chip's key ("tc_overheads_status_<key>") and a note on what
-- happens next.
local function getOverheadStatus(farmId, definition, state)
    local overheads = g_currentMission.TheContractor.Overheads
    if state == nil or not state.enabled then
        if definition.mandatory then
            return "notNeeded", g_i18n:getText("tc_overheads_noteNotNeeded")
        end
        return "notTaken", ""
    end

    local endText = string.format(g_i18n:getText("tc_overheads_noteEnds"),
        TCCalendar.formatPeriodIndex(state.cancelled and state.paidUntil or state.renewalPeriod))
    if state.cancelled then
        return "cancelled", endText
    end
    if not overheads:willRenew(farmId, definition, state) then
        return "lapsing", endText
    end
    local renewText = string.format(g_i18n:getText("tc_overheads_noteRenews"),
        TCCalendar.formatPeriodIndex(state.renewalPeriod))
    return definition.mandatory and "mandatory" or "active", renewText
end

function MenuContractor:populateOverheadCell(index, cell)
    local definition = self.overheadRows[index]
    if definition == nil then
        return
    end
    if definition.isAdministrator then
        self:populateAdministratorCell(cell)
        return
    end

    local farmId = g_currentMission:getFarmId()
    local overheads = g_currentMission.TheContractor.Overheads
    local state = overheads:getState(farmId, definition.key)
    local status = getOverheadStatus(farmId, definition, state)

    cell:getAttribute("name"):setText(g_i18n:getText(definition.l10nKey))
    setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"),
        g_i18n:getText("tc_overheads_status_" .. status), OVERHEAD_STATUS_TONES[status])

    if state == nil or not state.enabled then
        cell:getAttribute("billing"):setText("-")
        cell:getAttribute("cost"):setText("-")
        cell:getAttribute("next"):setText("-")
        return
    end

    local amount = TheContractorOverheads.getChargeAmount(state.termCost, state.billing)
    cell:getAttribute("billing"):setText(g_i18n:getText("tc_overheads_billing_" .. state.billing))
    cell:getAttribute("cost"):setText(string.format(g_i18n:getText("tc_overheads_per_" .. state.billing),
        formatMoney(amount)))

    local nextPeriod = overheads:getNextCharge(farmId, definition, state)
    cell:getAttribute("next"):setText(nextPeriod ~= nil and TCCalendar.formatMonth(nextPeriod) or "-")
end

function MenuContractor:updateOverheadDetails()
    self:setMenuButtonInfoDirty()

    if self.selectedOverheadKey == MenuContractor.ADMINISTRATOR_ROW_KEY then
        self:updateAdministratorDetails()
        return
    end

    local definition, state = self:getSelectedOverhead()
    self.financesOverheadRows:setVisible(definition ~= nil)
    if definition == nil then
        self.financesInvoiceTitle:setText(g_i18n:getText("tc_overheads_heading"))
        return
    end

    local farmId = g_currentMission:getFarmId()
    local overheads = g_currentMission.TheContractor.Overheads
    local status, note = getOverheadStatus(farmId, definition, state)
    local isActive = state ~= nil and state.enabled

    self.financesInvoiceTitle:setText(g_i18n:getText(definition.l10nKey))
    setChip(self.financesOverheadStatusChip, self.financesOverheadStatusChipText,
        g_i18n:getText("tc_overheads_status_" .. status), OVERHEAD_STATUS_TONES[status])
    self.financesOverheadStatusNote:setText(note)

    if isActive then
        local billingText = g_i18n:getText("tc_overheads_billingDetail_" .. state.billing)
        if state.pendingBilling ~= nil and not state.cancelled then
            billingText = string.format(g_i18n:getText("tc_overheads_billingSwitching"), billingText,
                g_i18n:getText("tc_overheads_billing_" .. state.pendingBilling))
        end
        self.financesOverheadBilling:setText(billingText)

        local priceText = string.format(g_i18n:getText("tc_overheads_priceThisTerm"), formatMoney(state.termCost))
        if state.quotedCost ~= nil and not state.cancelled then
            priceText = string.format(g_i18n:getText("tc_overheads_priceQuoted"), priceText,
                formatMoney(state.quotedCost))
        end
        self.financesOverheadPrice:setText(priceText)

        local nextPeriod, nextAmount = overheads:getNextCharge(farmId, definition, state)
        self.financesOverheadNext:setText(nextPeriod ~= nil and
            string.format(g_i18n:getText("tc_overheads_nextChargeLine"), formatMoney(nextAmount),
                TCCalendar.formatPeriodIndex(nextPeriod)) or g_i18n:getText("tc_overheads_nextChargeNone"))
    else
        local annualCost = overheads:getAnnualCost(farmId, definition)
        self.financesOverheadBilling:setText("-")
        self.financesOverheadPrice:setText(string.format(g_i18n:getText("tc_overheads_priceQuote"),
            formatMoney(TheContractorOverheads.getChargeAmount(annualCost, TheContractorOverheads.BILLING.ANNUAL)),
            formatMoney(TheContractorOverheads.getChargeAmount(annualCost, TheContractorOverheads.BILLING.MONTHLY))))
        self.financesOverheadNext:setText(g_i18n:getText("tc_overheads_nextChargeNone"))
    end

    self.financesOverheadAbout:setText(g_i18n:getText(definition.l10nKey .. "_desc"))
    self.financesOverheadRows:invalidateLayout()
end

-- Bottom bar for the highlighted overhead, or nil for just the defaults.
function MenuContractor:getOverheadButtonInfo()
    if self.selectedOverheadKey == MenuContractor.ADMINISTRATOR_ROW_KEY then
        return g_currentMission.TheContractor.Administrator:isEmployed(g_currentMission:getFarmId()) and
            self.menuButtonInfoAdministratorEmployed or self.menuButtonInfoAdministratorVacant
    end

    local definition, state = self:getSelectedOverhead()
    if definition == nil then
        return nil
    end

    if state == nil or not state.enabled then
        return not definition.mandatory and self.menuButtonInfoOverheadNotTaken or nil
    end
    if state.cancelled then
        return self.menuButtonInfoOverheadCancelled
    end

    local switchTo = TheContractorOverheads.getNextBilling(state) == TheContractorOverheads.BILLING.ANNUAL and
        TheContractorOverheads.BILLING.MONTHLY or TheContractorOverheads.BILLING.ANNUAL
    self.btnSwitchOverheadBilling.text = g_i18n:getText("tc_overheads_switchTo_" .. switchTo)
    return definition.mandatory and self.menuButtonInfoOverheadMandatory or self.menuButtonInfoOverheadActive
end

-- Sends the request, then redraws - same "synchronous for host/SP, catches
-- up on next refresh for a remote client" caveat as onClickHireWorker.
function MenuContractor:sendOverheadRequest(definition, request, billing)
    local farmId = g_currentMission:getFarmId()
    g_client:getServerConnection():sendEvent(TCOverheadRequestEvent.new(farmId, definition.key, request, billing))
    self:refreshFinancesState(farmId, g_currentMission.TheContractor.Finances)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickEnableOverhead(billing)
    local definition, state = self:getSelectedOverhead()
    if definition == nil or definition.mandatory or (state ~= nil and state.enabled) then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local overheads = g_currentMission.TheContractor.Overheads
    local amount = TheContractorOverheads.getChargeAmount(overheads:getAnnualCost(farmId, definition), billing)
    local name = g_i18n:getText(definition.l10nKey)

    if not overheads:canAffordEnable(farmId, definition, billing) then
        InfoDialog.show(string.format(g_i18n:getText("tc_overheads_cannotAfford"), name, formatMoney(amount)))
        return
    end

    YesNoDialog.show(function(target, clickOk)
        if clickOk then
            target:sendOverheadRequest(definition, TheContractorOverheads.REQUEST.ENABLE, billing)
        end
    end, self, string.format(g_i18n:getText("tc_overheads_enableConfirm_" .. billing), name, formatMoney(amount)))
end

function MenuContractor:onClickCancelOverhead()
    local definition, state = self:getSelectedOverhead()
    if definition == nil or definition.mandatory or state == nil or not state.enabled or state.cancelled then
        return
    end

    local endPeriod = state.billing == TheContractorOverheads.BILLING.ANNUAL and state.paidUntil or
        TCCalendar.getPeriodIndex() + 1
    YesNoDialog.show(function(target, clickOk)
        if clickOk then
            target:sendOverheadRequest(definition, TheContractorOverheads.REQUEST.CANCEL)
        end
    end, self, string.format(g_i18n:getText("tc_overheads_cancelConfirm"), g_i18n:getText(definition.l10nKey),
        TCCalendar.formatPeriodIndex(endPeriod)))
end

function MenuContractor:onClickKeepOverhead()
    local definition, state = self:getSelectedOverhead()
    if definition == nil or state == nil or not state.enabled or not state.cancelled then
        return
    end
    self:sendOverheadRequest(definition, TheContractorOverheads.REQUEST.KEEP)
end

-- No confirm: it only changes the next term, and can be switched back.
function MenuContractor:onClickSwitchOverheadBilling()
    local definition, state = self:getSelectedOverhead()
    if definition == nil or state == nil or not state.enabled or state.cancelled then
        return
    end
    self:sendOverheadRequest(definition, TheContractorOverheads.REQUEST.SWITCH_BILLING)
end

-- Office administrator (057) -----------------------------------------------

function MenuContractor:populateAdministratorCell(cell)
    local admin = g_currentMission.TheContractor.Administrator:getAdministrator(g_currentMission:getFarmId())

    cell:getAttribute("name"):setText(g_i18n:getText("tc_admin_title"))
    setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"),
        g_i18n:getText(admin ~= nil and "tc_admin_status_employed" or "tc_admin_status_vacant"),
        admin ~= nil and "good" or "neutral")

    if admin == nil then
        cell:getAttribute("billing"):setText("-")
        cell:getAttribute("cost"):setText("-")
        cell:getAttribute("next"):setText("-")
        return
    end

    cell:getAttribute("billing"):setText(g_i18n:getText("tc_admin_billingShort"))
    cell:getAttribute("cost"):setText(string.format(g_i18n:getText("tc_overheads_per_monthly"),
        formatMoney(admin.salary)))
    cell:getAttribute("next"):setText(TCCalendar.formatMonth(TCCalendar.getPeriodIndex() + 1))
end

-- Fills the overhead panel's rows for the administrator.
function MenuContractor:updateAdministratorDetails()
    local admin = g_currentMission.TheContractor.Administrator:getAdministrator(g_currentMission:getFarmId())
    local salary = admin ~= nil and admin.salary or TheContractorAdministrator.SALARY
    local pension = salary * TheContractorStaff.PENSION_RATE

    self.financesOverheadRows:setVisible(true)
    self.financesInvoiceTitle:setText(g_i18n:getText("tc_admin_title"))

    if admin ~= nil then
        setChip(self.financesOverheadStatusChip, self.financesOverheadStatusChipText,
            g_i18n:getText("tc_admin_status_employed"), "good")
        self.financesOverheadStatusNote:setText(string.format(g_i18n:getText("tc_admin_noteEmployed"), admin.name,
            TCCalendar.formatPeriodIndex(admin.hiredPeriod)))
        self.financesOverheadNext:setText(string.format(g_i18n:getText("tc_overheads_nextChargeLine"),
            formatMoney(salary + pension), TCCalendar.formatPeriodIndex(TCCalendar.getPeriodIndex() + 1)))
    else
        setChip(self.financesOverheadStatusChip, self.financesOverheadStatusChipText,
            g_i18n:getText("tc_admin_status_vacant"), "neutral")
        self.financesOverheadStatusNote:setText(g_i18n:getText("tc_admin_noteVacant"))
        self.financesOverheadNext:setText(g_i18n:getText("tc_overheads_nextChargeNone"))
    end

    self.financesOverheadBilling:setText(g_i18n:getText("tc_admin_billing"))
    self.financesOverheadPrice:setText(string.format(g_i18n:getText("tc_admin_price"), formatMoney(salary),
        formatMoney(pension)))
    self.financesOverheadAbout:setText(g_i18n:getText("tc_admin_desc"))
    self.financesOverheadRows:invalidateLayout()
end

-- Sends the request, then redraws - same caveat as sendOverheadRequest.
function MenuContractor:sendAdministratorRequest(request)
    local farmId = g_currentMission:getFarmId()
    g_client:getServerConnection():sendEvent(TCAdministratorRequestEvent.new(farmId, request))
    self:refreshFinancesState(farmId, g_currentMission.TheContractor.Finances)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickHireAdministrator()
    local farmId = g_currentMission:getFarmId()
    local administrator = g_currentMission.TheContractor.Administrator
    if administrator:isEmployed(farmId) then
        return
    end

    local salary = formatMoney(TheContractorAdministrator.SALARY)
    if not administrator:canAffordHire(farmId) then
        InfoDialog.show(string.format(g_i18n:getText("tc_admin_cannotAfford"), salary))
        return
    end

    YesNoDialog.show(function(target, clickOk)
        if clickOk then
            target:sendAdministratorRequest(TheContractorAdministrator.REQUEST.HIRE)
        end
    end, self, string.format(g_i18n:getText("tc_admin_hireConfirm"), salary))
end

-- The cost is worked out like a worker's (056).
function MenuContractor:onClickReleaseAdministrator()
    local admin = g_currentMission.TheContractor.Administrator:getAdministrator(g_currentMission:getFarmId())
    if admin == nil then
        return
    end

    local cost = TheContractorAdministrator.getReleaseCost(admin)
    local prompt
    if cost.redundancyPay > 0 then
        prompt = string.format(g_i18n:getText("tc_admin_releaseConfirmRedundancy"), admin.name, cost.years,
            formatMoney(cost.total), formatMoney(cost.noticePay), formatWeeks(cost.noticeWeeks),
            formatMoney(cost.redundancyPay))
    else
        prompt = string.format(g_i18n:getText("tc_admin_releaseConfirmNotice"), admin.name, cost.years,
            formatMoney(cost.total), formatWeeks(cost.noticeWeeks))
    end

    YesNoDialog.show(function(target, clickOk)
        if clickOk then
            target:sendAdministratorRequest(TheContractorAdministrator.REQUEST.RELEASE)
        end
    end, self, prompt)
end

-- Logbook (060) ------------------------------------------------------------

-- Vehicles view sort orders, cycled by btnLogbookSort.
MenuContractor.LOGBOOK_VEHICLE_SORTS = { "lastUsed", "hours", "faults", "name" }

local function getFieldName(fieldId)
    local field = g_fieldManager:getFieldById(fieldId)
    return field ~= nil and field:getName() or tostring(fieldId)
end

local function formatHours(hours)
    return string.format(g_i18n:getText("tc_logbook_hours"), hours or 0)
end

-- Who a crew member was: their name, "A player" for a player-driven job
-- nobody was seen driving, or a former employee.
local function getCrewName(member)
    if member.name ~= nil then
        return member.name
    end
    if member.role == TheContractorLogbook.ROLE.PLAYER then
        return g_i18n:getText("tc_logbook_aPlayer")
    end
    return g_i18n:getText("tc_calendar_formerWorker")
end

local function getCrewText(entry)
    local names = {}
    for _, member in ipairs(entry.crew) do
        table.insert(names, getCrewName(member))
    end
    return #names > 0 and table.concat(names, ", ") or "-"
end

-- The margin chip: money, or "Missed".
local function getMarginChip(entry)
    if entry.outcome == TheContractorLogbook.OUTCOME.MISSED then
        return g_i18n:getText("tc_logbook_missed"), "bad"
    end
    return formatMoney(TheContractorLogbook.getMargin(entry)), TheContractorLogbook.getMarginTone(entry)
end

-- "Damage 12% > 19%, Paint 30% > 34%" - a history row's condition on one line.
local function getCompactChange(before, after)
    local parts = {}
    for _, row in ipairs(TCVehicleCondition.getChangeRows(before, after)) do
        table.insert(parts, row.label .. " " .. row.value)
    end
    return table.concat(parts, ", ")
end

-- Filters: everything, completed, missed, then one per person in the log.
function MenuContractor:buildLogbookJobFilters(entries)
    local filters = {
        { key = "all", text = g_i18n:getText("tc_logbook_filterAll") },
        { key = "completed", text = g_i18n:getText("tc_logbook_filterCompleted") },
        { key = "missed", text = g_i18n:getText("tc_logbook_filterMissed") },
    }
    local names, seen = {}, {}
    for _, entry in ipairs(entries) do
        for _, member in ipairs(entry.crew) do
            local name = getCrewName(member)
            if not seen[name] then
                seen[name] = true
                table.insert(names, name)
            end
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        table.insert(filters, { key = "person", name = name, text = name })
    end
    return filters
end

local function matchesFilter(entry, filter)
    if filter.key == "completed" then
        return entry.outcome == TheContractorLogbook.OUTCOME.COMPLETED
    elseif filter.key == "missed" then
        return entry.outcome == TheContractorLogbook.OUTCOME.MISSED
    elseif filter.key == "person" then
        for _, member in ipairs(entry.crew) do
            if getCrewName(member) == filter.name then
                return true
            end
        end
        return false
    end
    return true
end

-- Every vehicle the farm owns that wears (no pallets or big bags). Each
-- row: { id (the vehicle's object id), record (nil if never logged),
-- vehicle, name, summary }.
function MenuContractor:buildLogbookVehicleRows(farmId, logbook)
    local rows = {}

    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        local vehicleId = NetworkUtil.getObjectId(vehicle)
        if vehicleId ~= nil and vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() == farmId and
                not vehicle.isPallet and vehicle.spec_wearable ~= nil and not vehicle.isDeleted then
            table.insert(rows, {
                id = vehicleId,
                record = logbook:getRecordForVehicle(vehicle),
                vehicle = vehicle,
                name = vehicle:getFullName(),
            })
        end
    end

    for _, row in ipairs(rows) do
        row.summary = row.record ~= nil and TheContractorLogbook.getVehicleSummary(row.record, farmId) or
            { jobs = 0, hours = 0, people = {}, faults = 0, wearCost = 0 }
    end

    local sort = MenuContractor.LOGBOOK_VEHICLE_SORTS[self.logbookVehicleSortIndex]
    local function lastUsed(row)
        local last = row.summary.last
        return last ~= nil and (last.endedAt or last.day * 1440) or -1
    end
    table.sort(rows, function(a, b)
        if sort == "hours" and a.summary.hours ~= b.summary.hours then
            return a.summary.hours > b.summary.hours
        elseif sort == "faults" and a.summary.faults ~= b.summary.faults then
            return a.summary.faults > b.summary.faults
        elseif sort ~= "name" and lastUsed(a) ~= lastUsed(b) then
            return lastUsed(a) > lastUsed(b)
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.id < b.id
    end)
    return rows
end

-- Rebuilds whichever view's showing (keeping its highlight if it's still
-- listed, else the first row, like refreshCompletedJobsState) and its
-- details.
function MenuContractor:refreshLogbookState(farmId, logbook)
    self.logbookContent:setVisible(true)
    self.logbookViewSelector:setTexts({ g_i18n:getText("tc_logbook_viewJobs"),
        g_i18n:getText("tc_logbook_viewVehicles") })
    self.logbookViewSelector:setState(self.logbookView == "vehicles" and 2 or 1)

    local isJobs = self.logbookView ~= "vehicles"
    local count, selectedIndex = 0, nil
    -- reloadData re-raises the selection callback with the old index, which
    -- would overwrite the row asked for (e.g. a jump from the other view).
    local wantedJobId, wantedVehicleId = self.selectedLogbookJobId, self.selectedLogbookVehicleId

    if isJobs then
        local entries = logbook:getJobEntries(farmId)
        self.logbookJobFilters = self:buildLogbookJobFilters(entries)
        if self.logbookJobFilters[self.logbookJobFilterIndex] == nil then
            self.logbookJobFilterIndex = 1
        end
        local filter = self.logbookJobFilters[self.logbookJobFilterIndex]

        self.logbookJobs = {}
        for _, entry in ipairs(entries) do
            if matchesFilter(entry, filter) then
                table.insert(self.logbookJobs, entry)
            end
        end
        self.logbookJobTable:reloadData()

        count = #self.logbookJobs
        for i, entry in ipairs(self.logbookJobs) do
            if entry.jobId == wantedJobId then
                selectedIndex = i
            end
        end
        self.logbookListNote:setText(string.format(g_i18n:getText("tc_logbook_showing"), filter.text))
        self.btnLogbookFilter.text = string.format(g_i18n:getText("tc_logbook_filterButton"), filter.text)
        self.logbookEmptyText:setText(g_i18n:getText(#entries == 0 and "tc_logbook_noJobs" or "tc_logbook_noMatches"))
    else
        self.logbookVehicleRows = self:buildLogbookVehicleRows(farmId, logbook)
        self.logbookVehicleTable:reloadData()

        count = #self.logbookVehicleRows
        for i, row in ipairs(self.logbookVehicleRows) do
            if row.id == wantedVehicleId then
                selectedIndex = i
            end
        end
        local sortText = g_i18n:getText("tc_logbook_sort_" ..
            MenuContractor.LOGBOOK_VEHICLE_SORTS[self.logbookVehicleSortIndex])
        self.logbookListNote:setText(string.format(g_i18n:getText("tc_logbook_sortedBy"), sortText))
        self.btnLogbookSort.text = string.format(g_i18n:getText("tc_logbook_sortButton"), sortText)
        self.logbookEmptyText:setText(g_i18n:getText("tc_logbook_noVehicles"))
    end

    local hasItems = count > 0
    self.logbookJobsContainer:setVisible(isJobs and hasItems)
    self.logbookVehiclesContainer:setVisible(not isJobs and hasItems)
    self.logbookEmptyText:setVisible(not hasItems)

    if hasItems then
        selectedIndex = selectedIndex or 1
        if isJobs then
            self.logbookJobTable:setSelectedIndex(selectedIndex)
            self.selectedLogbookJobId = self.logbookJobs[selectedIndex].jobId
        else
            self.logbookVehicleTable:setSelectedIndex(selectedIndex)
            self.selectedLogbookVehicleId = self.logbookVehicleRows[selectedIndex].id
        end
    elseif isJobs then
        self.selectedLogbookJobId = nil
    else
        self.selectedLogbookVehicleId = nil
    end

    self:updateLogbookDetails()
end

function MenuContractor:onClickLogbookView()
    self.logbookView = self.logbookViewSelector:getState() == 2 and "vehicles" or "jobs"
    self:refreshLogbookState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Logbook)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickLogbookFilter()
    self.logbookJobFilterIndex = self.logbookJobFilterIndex % math.max(1, #self.logbookJobFilters) + 1
    self:refreshLogbookState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Logbook)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickLogbookSort()
    self.logbookVehicleSortIndex = self.logbookVehicleSortIndex % #MenuContractor.LOGBOOK_VEHICLE_SORTS + 1
    self:refreshLogbookState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Logbook)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:getSelectedLogbookJob()
    for _, entry in ipairs(self.logbookJobs) do
        if entry.jobId == self.selectedLogbookJobId then
            return entry
        end
    end
    return nil
end

function MenuContractor:getSelectedLogbookVehicleRow()
    for _, row in ipairs(self.logbookVehicleRows) do
        if row.id == self.selectedLogbookVehicleId then
            return row
        end
    end
    return nil
end

function MenuContractor:populateLogbookJobCell(index, cell)
    local entry = self.logbookJobs[index]
    if entry == nil then
        return
    end
    cell:getAttribute("date"):setText(TCCalendar.formatDayShort(entry.day))
    cell:getAttribute("title"):setText(entry.title or "-")
    cell:getAttribute("field"):setText(getFieldName(entry.fieldId))
    cell:getAttribute("crew"):setText(getCrewText(entry))
    local chipText, tone = getMarginChip(entry)
    setChip(cell:getAttribute("marginChip"), cell:getAttribute("marginChipText"), chipText, tone)
end

function MenuContractor:populateLogbookVehicleCell(index, cell)
    local row = self.logbookVehicleRows[index]
    if row == nil then
        return
    end
    local last = row.summary.last
    cell:getAttribute("name"):setText(row.name)
    cell:getAttribute("lastUsedBy"):setText(last ~= nil and (last.who or "-") or g_i18n:getText("tc_logbook_neverUsed"))
    cell:getAttribute("lastUsed"):setText(last ~= nil and TCCalendar.formatDayShort(last.day) or "-")

    local snapshot = TCVehicleCondition.capture(row.vehicle)
    setChip(cell:getAttribute("conditionChip"), cell:getAttribute("conditionChipText"),
        TCVehicleCondition.getHeadline(snapshot) or "-", TCVehicleCondition.getTone(snapshot))

    -- A fault one of our people caused on it this year.
    setChip(cell:getAttribute("faultChip"), cell:getAttribute("faultChipText"),
        row.summary.faults > 0 and g_i18n:getText("tc_logbook_faultChip") or nil, "bad")
end

function MenuContractor:populateLogbookDetailCell(index, cell)
    local row = self.logbookDetailRows[index]
    if row == nil then
        return
    end
    local isSection = row.section ~= nil
    cell:getAttribute("surface"):setVisible(not isSection)
    cell:getAttribute("section"):setVisible(isSection)
    cell:getAttribute("section"):setText(row.section or "")
    cell:getAttribute("label"):setVisible(not isSection)
    cell:getAttribute("label"):setText(row.label or "")
    cell:getAttribute("value"):setVisible(not isSection)
    cell:getAttribute("value"):setText(row.value or "")
    setChip(cell:getAttribute("chip"), cell:getAttribute("chipText"), not isSection and row.chip or nil, row.tone)
end

-- Fills the detail panel for the highlighted job or vehicle.
function MenuContractor:updateLogbookDetails()
    self:setMenuButtonInfoDirty()

    local title, chipText, chipTone = nil, nil, nil
    local rows = nil
    if self.logbookView == "vehicles" then
        local row = self:getSelectedLogbookVehicleRow()
        if row ~= nil then
            title = row.name
            rows = self:getLogbookVehicleRows(row)
        end
    else
        local entry = self:getSelectedLogbookJob()
        if entry ~= nil then
            title = entry.title
            chipText, chipTone = getMarginChip(entry)
            rows = self:getLogbookJobRows(entry)
        end
    end

    self.logbookDetailsBox:setVisible(rows ~= nil)
    self.logbookDetailRows = rows or {}
    self.logbookDetailIndex = nil
    self.logbookDetailTable:reloadData()
    if rows == nil then
        return
    end

    self.logbookDetailTitle:setText(title or "-")
    setChip(self.logbookDetailChip, self.logbookDetailChipText, chipText, chipTone)
    if #self.logbookDetailRows > 0 then
        self.logbookDetailTable:setSelectedIndex(1)
    end
end

-- The detail rows for a job entry: sections, then label/value rows with an
-- optional chip. Rows about a machine carry its vehicleId, for the
-- Vehicle log button.
function MenuContractor:getLogbookJobRows(entry)
    local rows = {}
    local function section(key)
        table.insert(rows, { section = g_i18n:getText(key) })
    end
    local function row(label, value, chip, tone, vehicleId)
        table.insert(rows, { label = label, value = value, chip = chip, tone = tone, vehicleId = vehicleId })
    end
    local function text(key)
        return g_i18n:getText(key)
    end

    local isMissed = entry.outcome == TheContractorLogbook.OUTCOME.MISSED

    section("tc_logbook_sectionJob")
    row(text(isMissed and "tc_logbook_missedOn" or "tc_logbook_completedOn"), TCCalendar.formatDay(entry.day),
        text(isMissed and "tc_logbook_missed" or "tc_logbook_completed"), isMissed and "bad" or "good")
    row(text("tc_logbook_field"), getFieldName(entry.fieldId))
    if isMissed then
        row(text("tc_logbook_progress"), string.format("%d%%", math.floor(entry.completionPercentage or 0)))
    elseif entry.qualityScore ~= nil then
        row(text("tc_logbook_quality"), string.format("%d%%", entry.qualityScore),
            string.format("%d%%", entry.qualityScore), getQualityChipTone(entry.qualityScore))
    end
    if (entry.stuckInterventions or 0) > 0 then
        row(text("tc_logbook_interventions"), tostring(entry.stuckInterventions), nil, nil)
    end

    section("tc_logbook_sectionCrew")
    if #entry.crew == 0 then
        row("-", text("tc_logbook_notAllocated"))
    end
    for _, member in ipairs(entry.crew) do
        local chip, tone = nil, nil
        if member.rating ~= nil and entry.requiredSkillLevel ~= nil then
            chip = string.format(text("tc_logbook_ratingChip"), member.rating, entry.requiredSkillLevel)
            tone = member.rating >= entry.requiredSkillLevel and "good" or "warn"
        end
        row(text("tc_logbook_role_" .. (member.role or TheContractorLogbook.ROLE.OPERATOR)), getCrewName(member), chip,
            tone)
    end

    if #entry.equipment > 0 then
        section("tc_logbook_sectionEquipment")
        for _, machine in ipairs(entry.equipment) do
            local chip, tone = nil, nil
            if machine.faultCaused then
                chip, tone = text("tc_logbook_faultChip"), "bad"
            elseif machine.extraWear ~= nil then
                chip, tone = string.format(text("tc_logbook_extraWearChip"), machine.extraWear), "warn"
            end
            row(text("tc_logbook_machine"), machine.name or "?", chip, tone, machine.vehicleId)
            if machine.workerName ~= nil then
                row(text("tc_logbook_usedBy"), machine.workerName, nil, nil, machine.vehicleId)
            end
            for _, change in ipairs(TCVehicleCondition.getChangeRows(machine.startSnapshot, machine.endSnapshot)) do
                row(change.label, change.value, change.tone ~= nil and text("tc_logbook_faultShort") or nil, change.tone,
                    machine.vehicleId)
            end
            local hours = TCVehicleCondition.getHoursBetween(machine.startSnapshot, machine.endSnapshot)
            if hours ~= nil then
                row(text("tc_logbook_engineHours"), formatHours(hours), nil, nil, machine.vehicleId)
            end
            if machine.wash == TCJobConsequences.WASH.WASHED then
                row(text("tc_logbook_washed"), text("tc_logbook_yes"), nil, nil, machine.vehicleId)
            elseif machine.wash == TCJobConsequences.WASH.UNWASHED then
                row(text("tc_logbook_washed"), text("tc_logbook_no"), text("tc_logbook_dirtyChip"), "warn",
                    machine.vehicleId)
            end
            row(text("tc_logbook_wearCost"), formatMoney(machine.wearCost), nil, nil, machine.vehicleId)
        end
    end

    section("tc_logbook_sectionTime")
    local function minutes(value)
        return value ~= nil and TheContractorJob.formatMinutes(value) or text("tc_logbook_notRecorded")
    end
    row(text("tc_logbook_travelOut"), minutes(entry.travelMinutes))
    row(text("tc_logbook_fieldwork"), minutes(entry.fieldMinutes))
    row(text("tc_logbook_returnWash"), minutes(entry.returnMinutes))
    if entry.travelMinutes ~= nil or entry.fieldMinutes ~= nil or entry.returnMinutes ~= nil then
        row(text("tc_logbook_total"), TheContractorJob.formatMinutes((entry.travelMinutes or 0) +
            (entry.fieldMinutes or 0) + (entry.returnMinutes or 0)))
    end

    if #entry.supplies > 0 then
        section("tc_logbook_sectionSupplies")
        for _, supply in ipairs(entry.supplies) do
            local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(supply.fillTypeName)
            row(text("tc_logbook_loaded"), fillTypeIndex ~= nil and
                TCJobSupplies.formatAmount(fillTypeIndex, supply.liters) or
                string.format("%s %.0f", supply.fillTypeName, supply.liters))
        end
    end

    section("tc_logbook_sectionMoney")
    local agreed = formatMoney(entry.agreedPrice or entry.price)
    if entry.offeredPrice ~= nil and entry.agreedPrice ~= nil and math.floor(entry.offeredPrice + 0.5) ~=
            math.floor(entry.agreedPrice + 0.5) then
        agreed = string.format(text("tc_logbook_agreedFromOffered"), agreed, formatMoney(entry.offeredPrice))
    end
    row(text("tc_logbook_agreedPrice"), agreed)

    if isMissed then
        row(text("tc_logbook_invoice"), text("tc_logbook_notInvoiced"))
    else
        local invoice = TheContractorLogbook.getInvoice(entry)
        if invoice ~= nil then
            row(text("tc_logbook_invoice"), formatMoney(invoice.amount),
                g_i18n:getText("tc_finances_status_" .. invoice.status), INVOICE_STATUS_TONES[invoice.status] or "good")
        else
            row(text("tc_logbook_invoice"), formatMoney(entry.price), text("tc_finances_status_paid"), "good")
        end
    end

    row(text("tc_logbook_fuel"), string.format(text("tc_logbook_fuelValue"), formatMoney(entry.fuelCost),
        entry.fuelLiters or 0))
    row(text("tc_logbook_labour"), entry.labourCost ~= nil and formatMoney(entry.labourCost) or
        text("tc_logbook_none"))
    row(text("tc_logbook_machineWear"), entry.wearCost ~= nil and formatMoney(entry.wearCost) or
        text("tc_logbook_notRecorded"))

    if entry.claim ~= nil then
        local cause = entry.claim.cause ~= nil and g_i18n:getText("tc_claims_cause_" .. entry.claim.cause) or "-"
        cause = (string.gsub(cause, "^%l", string.upper))
        row(text("tc_logbook_claim"), cause, text(entry.claim.insured and "tc_logbook_insured" or
            "tc_logbook_uninsured"), entry.claim.insured and "info" or "bad")
        row(text("tc_logbook_claimPaid"), string.format(text("tc_logbook_claimPaidValue"),
            formatMoney(entry.claim.paid), formatMoney(entry.claim.amount)))
    end

    local marginChip, marginTone = getMarginChip(entry)
    row(text("tc_logbook_margin"), formatMoney(TheContractorLogbook.getMargin(entry)), marginChip, marginTone)

    if entry.reputation ~= nil then
        row(text("tc_logbook_reputation"), string.format("%+d", entry.reputation), nil, nil)
    end
    if entry.claim ~= nil and (entry.claim.reputationPenalty or 0) > 0 then
        row(text("tc_logbook_claimReputation"), string.format("%+d", -entry.claim.reputationPenalty), nil, nil)
    end

    return rows
end

local SOURCE_KEYS = {
    autodrive = "tc_logbook_source_autodrive",
    courseplay = "tc_logbook_source_courseplay",
    ai = "tc_logbook_source_ai",
}

-- "Cultivate (field 12)", "Staff driver: AutoDrive", "Player use".
local function getVehicleEntryTitle(entry)
    if entry.kind == TheContractorLogbook.KIND.JOB then
        return entry.jobTitle or g_i18n:getText("tc_logbook_kind_job")
    elseif entry.kind == TheContractorLogbook.KIND.DRIVER then
        local sources = {}
        for source in string.gmatch(entry.source or "", "([^,]+)") do
            table.insert(sources, g_i18n:getText(SOURCE_KEYS[source] or "tc_logbook_source_ai"))
        end
        if #sources == 0 then
            return g_i18n:getText("tc_logbook_kind_driver")
        end
        return string.format(g_i18n:getText("tc_logbook_driverVia"), table.concat(sources, ", "))
    end
    return g_i18n:getText("tc_logbook_kind_player")
end

-- The detail rows for a vehicle: this year's summary, then its history,
-- two rows an entry. History rows carry their jobId for the Job log button.
function MenuContractor:getLogbookVehicleRows(vehicleRow)
    local rows = {}
    local function section(key)
        table.insert(rows, { section = g_i18n:getText(key) })
    end
    local function row(label, value, chip, tone, jobId)
        table.insert(rows, { label = label, value = value, chip = chip, tone = tone, jobId = jobId })
    end
    local function text(key)
        return g_i18n:getText(key)
    end

    local farmId = g_currentMission:getFarmId()
    local summary = vehicleRow.summary

    section("tc_logbook_sectionNow")
    local snapshot = TCVehicleCondition.capture(vehicleRow.vehicle)
    row(text("tc_logbook_status"), text("tc_logbook_inFleet"), TCVehicleCondition.getHeadline(snapshot),
        TCVehicleCondition.getTone(snapshot))
    for _, state in ipairs(TCVehicleCondition.getStateRows(snapshot)) do
        row(state.label, state.value, state.tone ~= nil and text("tc_logbook_faultShort") or nil, state.tone)
    end

    section("tc_logbook_sectionYear")
    row(text("tc_logbook_jobs"), tostring(summary.jobs))
    row(text("tc_logbook_engineHours"), formatHours(summary.hours))
    row(text("tc_logbook_drivenBy"), #summary.people > 0 and table.concat(summary.people, ", ") or "-")
    row(text("tc_logbook_faultsCaused"), tostring(summary.faults), summary.faults > 0 and
        text("tc_logbook_faultChip") or nil, "bad")
    row(text("tc_logbook_wearCost"), formatMoney(summary.wearCost))

    section("tc_logbook_sectionHistory")
    local entries = vehicleRow.record ~= nil and TheContractorLogbook.getVehicleEntries(vehicleRow.record, farmId) or {}
    if #entries == 0 then
        row("-", text("tc_logbook_noHistory"))
    end
    for _, entry in ipairs(entries) do
        local kindChip, kindTone = text("tc_logbook_kindChip_" .. entry.kind), "info"
        if entry.kind == TheContractorLogbook.KIND.PLAYER then
            kindTone = "neutral"
        elseif entry.outcome == TheContractorLogbook.OUTCOME.MISSED then
            kindChip, kindTone = text("tc_logbook_missed"), "bad"
        end
        row(TCCalendar.formatDayShort(entry.day), string.format(text("tc_logbook_historyLine"),
            getVehicleEntryTitle(entry), entry.who or text("tc_logbook_aPlayer")), kindChip, kindTone, entry.jobId)

        local change = getCompactChange(entry.startSnapshot, entry.endSnapshot)
        local hours = TCVehicleCondition.getHoursBetween(entry.startSnapshot, entry.endSnapshot)
        local duration = entry.minutes ~= nil and TheContractorJob.formatMinutes(entry.minutes) or "-"
        local chip, tone = nil, nil
        if entry.faultCaused then
            chip, tone = text("tc_logbook_faultChip"), "bad"
        elseif entry.wash == TCJobConsequences.WASH.UNWASHED then
            chip, tone = text("tc_logbook_dirtyChip"), "warn"
        end
        row(duration, (hours ~= nil and formatHours(hours) .. "  " or "") .. (change ~= "" and change or "-"), chip,
            tone, entry.jobId)
    end

    return rows
end

-- Bottom bar: the filter or sort, plus the jump to the other view when
-- there's somewhere to jump to.
function MenuContractor:getLogbookButtonInfo()
    local buttons = { self.btnBack, self.btnNextPage, self.btnPrevPage }
    if self.logbookView == "vehicles" then
        table.insert(buttons, self.btnLogbookSort)
        if self:getLogbookJumpJobId() ~= nil then
            table.insert(buttons, self.btnLogbookOpenJob)
        end
    else
        table.insert(buttons, self.btnLogbookFilter)
        if self:getLogbookJumpVehicleId() ~= nil then
            table.insert(buttons, self.btnLogbookOpenVehicle)
        end
    end
    return buttons
end

-- Jobs view: the machine of the highlighted detail row, else the job's
-- first machine - as long as it's still on the farm.
function MenuContractor:getLogbookJumpVehicleId()
    local function isOnFarm(vehicleId)
        local vehicle = vehicleId ~= nil and NetworkUtil.getObject(vehicleId) or nil
        return vehicle ~= nil and not vehicle.isDeleted and vehicle.getOwnerFarmId ~= nil and
            vehicle:getOwnerFarmId() == g_currentMission:getFarmId()
    end

    local detail = self.logbookDetailRows[self.logbookDetailIndex or 0]
    if detail ~= nil and isOnFarm(detail.vehicleId) then
        return detail.vehicleId
    end
    local entry = self:getSelectedLogbookJob()
    for _, machine in ipairs(entry ~= nil and entry.equipment or {}) do
        if isOnFarm(machine.vehicleId) then
            return machine.vehicleId
        end
    end
    return nil
end

-- Vehicles view: the job of the highlighted history row, else the latest
-- job the vehicle was on - if it's still in the job log.
function MenuContractor:getLogbookJumpJobId()
    local logbook = g_currentMission.TheContractor.Logbook
    local farmId = g_currentMission:getFarmId()
    local detail = self.logbookDetailRows[self.logbookDetailIndex or 0]
    if detail ~= nil and detail.jobId ~= nil and logbook:getJobEntry(farmId, detail.jobId) ~= nil then
        return detail.jobId
    end
    local row = self:getSelectedLogbookVehicleRow()
    if row == nil or row.record == nil then
        return nil
    end
    for _, entry in ipairs(TheContractorLogbook.getVehicleEntries(row.record, farmId)) do
        if entry.jobId ~= nil and logbook:getJobEntry(farmId, entry.jobId) ~= nil then
            return entry.jobId
        end
    end
    return nil
end

function MenuContractor:onClickLogbookOpenVehicle()
    local vehicleId = self:getLogbookJumpVehicleId()
    if vehicleId == nil then
        return
    end
    self.logbookView = "vehicles"
    self.selectedLogbookVehicleId = vehicleId
    self:refreshLogbookState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Logbook)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickLogbookOpenJob()
    local jobId = self:getLogbookJumpJobId()
    if jobId == nil then
        return
    end
    self.logbookView = "jobs"
    -- Unfiltered, so the job's sure to be listed.
    self.logbookJobFilterIndex = 1
    self.selectedLogbookJobId = jobId
    self:refreshLogbookState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Logbook)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:refreshAdvertisingState(farmId, advertising)
    local activeLevel = advertising:getActiveLevel(farmId)
    if activeLevel ~= nil then
        self.textAdvertisingStatus:setText(string.format(g_i18n:getText("tc_advertising_active"),
            g_i18n:getText("tc_advertising_" .. activeLevel), advertising:getDaysRemaining(farmId)))
    else
        self.textAdvertisingStatus:setText(g_i18n:getText("tc_advertising_none"))
    end
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

-- Level/duration choice, cost preview and the funds/tier checks all live in
-- TCAdvertisingDialog (027), which sends the purchase event itself.
function MenuContractor:onClickBuyAdvertising()
    TCAdvertisingDialog.show(g_currentMission:getFarmId(), function(target)
        target:refreshCompanyState()
    end, self)
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

function MenuContractor:onClickFinances()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.FINANCES, true)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickLogbook()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.LOGBOOK, true)
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
    self:updateWorkerPortrait()

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
