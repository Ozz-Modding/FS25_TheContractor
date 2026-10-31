-- Top-level "Contractor" in-game menu page: eight sub-tabs (Overview, Inbox,
-- Calendar, Staff, Finances, Logbook, Supplies, and Workshop while
-- FS25_AdvancedDamageSystem is loaded). Structure mirrors FS25_RedTape/src/gui/MenuRedTape.lua's own
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
    SUPPLIES = 7,
    -- 100: ADS repair contracts being worked on. Kept last: it's hidden
    -- without ADS, which only works for the last tab (onFrameOpen).
    WORKSHOP = 8,
}

MenuContractor.HEADER_SLICES = {
    [MenuContractor.SUB_CATEGORY.INBOX] = "gui.icon_ingameMenu_contracts",
    [MenuContractor.SUB_CATEGORY.CALENDAR] = "gui.icon_ingameMenu_calendar",
    [MenuContractor.SUB_CATEGORY.STAFF] = "gui.icon_ingameMenu_animals",
    [MenuContractor.SUB_CATEGORY.OVERVIEW] = "gui.icon_ingameMenu_finances",
    [MenuContractor.SUB_CATEGORY.FINANCES] = "gui.icon_ingameMenu_prices",
    [MenuContractor.SUB_CATEGORY.LOGBOOK] = "gui.icon_ingameMenu_handToolsOverview",
    [MenuContractor.SUB_CATEGORY.SUPPLIES] = "gui.icon_ingameMenu_productionChains",
    [MenuContractor.SUB_CATEGORY.WORKSHOP] = "gui.icon_ingameMenu_options",
}

MenuContractor.HEADER_TITLES = {
    [MenuContractor.SUB_CATEGORY.INBOX] = "tc_header_inbox",
    [MenuContractor.SUB_CATEGORY.CALENDAR] = "tc_header_calendar",
    [MenuContractor.SUB_CATEGORY.STAFF] = "tc_header_staff",
    [MenuContractor.SUB_CATEGORY.OVERVIEW] = "tc_header_overview",
    [MenuContractor.SUB_CATEGORY.FINANCES] = "tc_header_finances",
    [MenuContractor.SUB_CATEGORY.LOGBOOK] = "tc_header_logbook",
    [MenuContractor.SUB_CATEGORY.SUPPLIES] = "tc_header_supplies",
    [MenuContractor.SUB_CATEGORY.WORKSHOP] = "tc_header_workshop",
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

-- Calendar-view-only variant that also shows the year — a Job's own
-- targetPeriod/targetDayInPeriod (used by formatTargetDate above, for the
-- Inbox and calendar-day-job lists) deliberately doesn't carry a year (008's
-- Q23 decision: "period N next year" and "period N now" aren't distinguished
-- in the data model). The Calendar tab's own navigation, though, pages
-- forward from environment.currentYear/currentPeriod by a known offset, so
-- the year here is always locally computable — worth showing since paging
-- from December to January was otherwise ambiguous about which year you'd
-- landed on. year is the game year (environment.currentYear's count), and
-- TCCalendar.formatYear shows January and February as the next one.
local function formatCalendarDate(period, dayInPeriod, year)
    return string.format("%s %d, %s", g_i18n:getText("ui_month" .. periodToMonth(period)), dayInPeriod,
        TCCalendar.formatYear(year, period))
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
    -- 093: a player-driven job, named for its player, so it can't be taken
    -- for a hired crew waiting to set off.
    player = { 0.30, 0.15, 0.42, 1 },
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
    -- 097: an idle worker's place in the day (TheContractorWorkingHours.
    -- getDisplayStatus).
    atHome = "neutral",
    comingIn = "info",
    stayingLate = "info",
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

-- 049: invoice status chips. Paid ones are only in the invoice history.
local INVOICE_STATUS_TONES = {
    outstanding = "info",
    paid = "good",
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
    elseif qualityScore >= 60 then
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
    -- 102: an ADS repair contract is priced through the Negotiate dialog
    -- (once it's been inspected), never accepted as it stands.
    self.btnNegotiateRepair = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_repair_negotiateButton"),
        callback = function()
            self:onClickNegotiateRepair()
        end
    }
    self.menuButtonInfoInboxWorkshop = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnNegotiateRepair, self.btnDeclineJob }
    -- 116: a farmer's favour is taken on or not, never haggled over.
    self.menuButtonInfoInboxFavour = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnAcceptJob, self.btnDeclineJob }

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
    -- 066: everything else for the highlighted roster worker - edit, a
    -- bonus (056), a pay rise (058), training (054) - is one Manage button
    -- with a list (onClickManageWorker). The bottom bar has a fixed number
    -- of slots (six seen in-game) and silently drops anything past them.
    self.btnManageWorker = {
        inputAction = InputAction.MENU_ACCEPT,
        text = g_i18n:getText("tc_staff_manageButton"),
        callback = function()
            self:onClickManageWorker()
        end
    }
    self.menuButtonInfoStaffWithCandidateSelection = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnHireWorker }
    self.menuButtonInfoStaffWithRosterSelection = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnReleaseWorker, self.btnManageWorker }

    -- 090: an office row in the roster - hire someone into a vacancy, or
    -- release the person there and manage them (edit, train).
    self.btnHireOffice = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_office_hireButton"),
        callback = function()
            self:onClickHireOffice()
        end
    }
    self.btnReleaseOffice = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_staff_releaseButton"),
        callback = function()
            self:onClickReleaseOffice()
        end
    }
    self.btnManageOffice = {
        inputAction = InputAction.MENU_ACCEPT,
        text = g_i18n:getText("tc_staff_manageButton"),
        callback = function()
            self:onClickManageOffice()
        end
    }
    self.menuButtonInfoStaffOfficeVacant = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnHireOffice }
    self.menuButtonInfoStaffOfficeEmployed = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnReleaseOffice, self.btnManageOffice }

    -- 111: the Others view - edit the highlighted farmer or the official.
    self.btnEditPerson = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_people_editButton"),
        callback = function()
            self:onClickEditPerson()
        end
    }
    self.menuButtonInfoStaffPerson = { self.btnBack, self.btnNextPage, self.btnPrevPage, self.btnEditPerson }
    -- 122: and a farmer's machines.
    self.btnPersonMachines = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("tc_fleet_machinesButton"),
        callback = function()
            self:onClickPersonMachines()
        end
    }
    self.menuButtonInfoStaffFarmer = { self.btnBack, self.btnNextPage, self.btnPrevPage, self.btnEditPerson,
        self.btnPersonMachines }

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
    -- 070: an overhead with levels of cover can change level from renewal.
    self.btnChangeOverheadLevel = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("tc_overheads_changeLevelButton"),
        callback = function()
            self:onClickChangeOverheadLevel()
        end
    }
    self.menuButtonInfoOverheadNotTaken = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnEnableOverheadAnnual, self.btnEnableOverheadMonthly }
    self.menuButtonInfoOverheadActive = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnCancelOverhead, self.btnSwitchOverheadBilling }
    self.menuButtonInfoOverheadActiveLevels = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnCancelOverhead, self.btnSwitchOverheadBilling, self.btnChangeOverheadLevel }
    self.menuButtonInfoOverheadMandatory = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnSwitchOverheadBilling }
    self.menuButtonInfoOverheadCancelled = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnKeepOverhead }


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
    -- than reacting to list clicks, so it works the same on a gamepad. It
    -- shares its key with the worker toggle: only the one for the list with
    -- the cursor is shown (getMenuButtonInfo).
    self.btnAllocateToggleEquipment = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("tc_allocation_selectEquipmentButton"),
        callback = function()
            self:onClickToggleAllocationEquipment()
        end
    }
    self.menuButtonInfoCalendarWithAllocatableJob = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnCalendarToday, self.btnAllocateJob }
    -- 093: who's on the highlighted job and how it's going. Shares Allocate's
    -- key: Allocate only shows for an `accepted` job, Job details for any
    -- other on the list (allocated, in progress, missed).
    self.btnJobDetails = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("tc_jobDetails_button"),
        callback = function()
            self:onClickJobDetails()
        end
    }
    self.menuButtonInfoCalendarWithJob = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnCalendarToday, self.btnJobDetails }
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
    self.menuButtonInfoCalendarAllocatingEquipment = { self.btnBack, self.btnNextPage, self.btnPrevPage,
        self.btnAllocateConfirm, self.btnAllocateCancel, self.btnAllocateToggleEquipment }

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
    -- 090: the office rows after the workers in the roster view, { role,
    -- member } (member nil for a vacancy), and the highlighted one's role.
    self.officeRows = {}
    self.selectedOfficeRole = nil
    -- 111: the Others view's rows (TheContractorFarmers:getPeopleRows) and
    -- the highlighted person's id.
    self.personRows = {}
    self.selectedPersonId = nil

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

    -- The two allocation pickers only lead to each other (vanilla's
    -- Production tab does the same). Left to itself FocusManager goes to
    -- whatever lies nearest, which is the day list, and moving onto that
    -- picks a day and closes the panel. Leaving is the Cancel button.
    FocusManager:linkElements(self.allocationWorkerTable, FocusManager.LEFT, nil)
    FocusManager:linkElements(self.allocationWorkerTable, FocusManager.RIGHT, self.allocationEquipmentTable)
    FocusManager:linkElements(self.allocationWorkerTable, FocusManager.TOP, nil)
    FocusManager:linkElements(self.allocationWorkerTable, FocusManager.BOTTOM, nil)
    FocusManager:linkElements(self.allocationEquipmentTable, FocusManager.LEFT, self.allocationWorkerTable)
    FocusManager:linkElements(self.allocationEquipmentTable, FocusManager.RIGHT, nil)
    FocusManager:linkElements(self.allocationEquipmentTable, FocusManager.TOP, nil)
    FocusManager:linkElements(self.allocationEquipmentTable, FocusManager.BOTTOM, nil)

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

    -- Supplies (064): the farm's supplies, or FS25_AdvancedDamageSystem's
    -- consumables/spare parts (suppliesView, from getSuppliesViews), with
    -- one detail list for the highlighted row. Read live, so the tab
    -- refreshes itself while it's showing (see update).
    self.suppliesView = "supplies"
    self.suppliesViews = {}
    self.suppliesRows = {}
    self.selectedSupplyKey = nil
    self.suppliesDetailRows = {}
    self.suppliesRefreshMs = 0

    self.suppliesTable:setDataSource(self)
    self.suppliesTable:setDelegate(self)
    self.suppliesDetailTable:setDataSource(self)
    self.suppliesDetailTable:setDelegate(self)

    -- Workshop (100): the farm's accepted ADS repair contracts, with the
    -- highlighted one's checklist. ADS's progress is live, so the tab
    -- refreshes itself while it's showing (see update). workshopView
    -- (workshopViewSelector) swaps in the last completed ones instead.
    self.workshopView = "current"
    self.workshopJobs = {}
    self.selectedWorkshopJobId = nil
    self.workshopDetailRows = {}

    self.workshopTable:setDataSource(self)
    self.workshopTable:setDelegate(self)
    self.workshopDetailTable:setDataSource(self)
    self.workshopDetailTable:setDelegate(self)
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
        -- 102: a workshop job is priced through its own Negotiate dialog.
        local job = self:getSelectedInboxJob()
        if TheContractorRepairContracts.isFavourJob(job) then
            return self.menuButtonInfoInboxFavour
        elseif TheContractorRepairContracts.isWorkshopJob(job) then
            return self.menuButtonInfoInboxWorkshop
        end
        return self.menuButtonInfoInboxWithSelection
    end

    -- No period-nav buttons while the tab is showing the "locked" prompt
    -- instead of real calendar content (see refreshCompanyState).
    if state == MenuContractor.SUB_CATEGORY.CALENDAR and not self:hasCompany() then
        return self.menuButtonInfoDefault
    end

    if state == MenuContractor.SUB_CATEGORY.CALENDAR and self:hasCompany() then
        if self.allocatingJobId ~= nil then
            if FocusManager:getFocusedElement() == self.allocationEquipmentTable and
                    self.allocationEquipmentRows[self.allocationHighlightedEquipmentIndex] ~= nil then
                return self.menuButtonInfoCalendarAllocatingEquipment
            end
            return self.menuButtonInfoCalendarAllocating
        end

        local selectedJob = self:getSelectedCalendarDayJob()
        -- 100: a workshop job has no crew to allocate, only its details.
        if selectedJob ~= nil and selectedJob.state == TheContractorJob.STATE.ACCEPTED and
                not selectedJob:isWorkshop() then
            return self.menuButtonInfoCalendarWithAllocatableJob
        elseif selectedJob ~= nil then
            return self.menuButtonInfoCalendarWithJob
        end
    end

    if state == MenuContractor.SUB_CATEGORY.STAFF and self:hasCompany() then
        if self.staffView == "candidates" and self.selectedCandidateId ~= nil then
            return self.menuButtonInfoStaffWithCandidateSelection
        end
        if self.staffView == "roster" and self.selectedRosterWorkerId ~= nil then
            return self.menuButtonInfoStaffWithRosterSelection
        end
        local officeRow = self:getSelectedOfficeRow()
        if officeRow ~= nil then
            return officeRow.member ~= nil and self.menuButtonInfoStaffOfficeEmployed or
                self.menuButtonInfoStaffOfficeVacant
        end
        local person = self:getSelectedPerson()
        if person ~= nil then
            if not person.isOfficial and person.machines ~= nil and #person.machines > 0 then
                return self.menuButtonInfoStaffFarmer
            end
            return self.menuButtonInfoStaffPerson
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
    -- 100: the Workshop tab only with ADS. It's the last tab, so leaving it
    -- out of the paging texts keeps every other tab's index.
    local texts = {}
    for k, tab in ipairs(self.subCategoryTabs) do
        local isShown = k ~= MenuContractor.SUB_CATEGORY.WORKSHOP or TCADSRepairContracts.isActive()
        tab:setVisible(isShown)
        if isShown then
            table.insert(texts, tostring(k))
        end
    end
    if self.subCategoryPaging:getState() > #texts then
        self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.OVERVIEW)
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
    for _, tooltip in ipairs(self.pageTooltips or {}) do
        tooltip:hide()
    end
end

function MenuContractor:update(dt)
    MenuContractor:superClass().update(self, dt)

    if self.workerPortrait ~= nil then
        self.workerPortrait:update(dt)
    end

    if self.isFrameOpen then
        for _, tooltip in ipairs(self:getPageTooltips()) do
            tooltip:update(dt)
        end
    end

    -- 097: who's gone home, come in or been sent home changes with the
    -- time, not with an event, so the Staff tab checks every second.
    self.staffHoursRefreshMs = (self.staffHoursRefreshMs or 0) + dt
    if self.staffHoursRefreshMs >= MenuContractor.SUPPLIES_REFRESH_MS then
        self.staffHoursRefreshMs = 0
        if self.isFrameOpen and self.subCategoryPaging:getState() == MenuContractor.SUB_CATEGORY.STAFF and
                self:hasCompany() then
            local signature = self:getStaffHoursSignature(g_currentMission:getFarmId())
            if signature ~= self.staffHoursSignature then
                self.staffHoursSignature = signature
                local tc = g_currentMission.TheContractor
                self:refreshStaffState(g_currentMission:getFarmId(), tc.Staff, tc.Jobs)
            end
        end
    end

    -- 064: stock changes as jobs draw on it, so the Supplies tab keeps
    -- itself up to date while it's the one showing.
    self.suppliesRefreshMs = (self.suppliesRefreshMs or 0) + dt
    if self.suppliesRefreshMs >= MenuContractor.SUPPLIES_REFRESH_MS then
        self.suppliesRefreshMs = 0
        if self.isFrameOpen and self.subCategoryPaging:getState() == MenuContractor.SUB_CATEGORY.SUPPLIES and
                self:hasCompany() then
            self:refreshSuppliesState(g_currentMission:getFarmId())
        end
        -- 100: so is the Workshop tab, as ADS's progress moves.
        if self.isFrameOpen and self.subCategoryPaging:getState() == MenuContractor.SUB_CATEGORY.WORKSHOP and
                self:hasCompany() then
            self:refreshWorkshopState(g_currentMission:getFarmId())
        end
        -- 102: a repair quote's answer reaching a remote client.
        if self.pendingRepairQuoteJobId ~= nil then
            self:checkPendingRepairQuote()
        end
    end
end

-- 097: everyone's place in the day, the office included, in one string.
function MenuContractor:getStaffHoursSignature(farmId)
    local tc = g_currentMission.TheContractor
    local now = TheContractorWorkingHours.getNow()
    local parts = { tostring(TheContractorWorkingHours.isOfficeOpen(now)) }
    for _, worker in ipairs(tc.Staff:getRoster(farmId)) do
        table.insert(parts, worker.id .. "=" .. TheContractorWorkingHours.getDisplayStatus(worker, now))
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

-- 042: shows the highlighted worker's portrait while the Staff tab is the
-- one showing, (112) the highlighted offer's customer on the Inbox tab, and
-- nothing otherwise. The one portrait moves between the two tabs' boxes.
function MenuContractor:updateWorkerPortrait()
    if self.workerPortrait == nil then
        self.workerPortrait = TCWorkerPortrait.new(self.staffPortraitRender)
    end

    -- 066: not while the edit dialog's showing its own - both scenes sit in
    -- the same spot in the world.
    local worker, key = nil, nil
    local state = self.subCategoryPaging:getState()
    if self.isFrameOpen and not self.isEditingWorker and state == MenuContractor.SUB_CATEGORY.INBOX and
            self:hasCompany() then
        local customer = self:getSelectedInboxCustomer()
        if customer ~= nil then
            self.workerPortrait:setRender(self.inboxPortraitRender)
            worker, key = customer, MenuContractor.getPersonPortraitKey(customer.id)
        end
    elseif self.isFrameOpen and not self.isEditingWorker and state == MenuContractor.SUB_CATEGORY.STAFF and
            self:hasCompany() then
        self.workerPortrait:setRender(self.staffPortraitRender)
        worker = self:getSelectedStaffWorker()
        -- 090: or the office member highlighted.
        local officeRow = self:getSelectedOfficeRow()
        if worker == nil and officeRow ~= nil then
            worker = officeRow.member
        end
        -- 111: or a farmer or the official, whose ids are their own.
        local person = self:getSelectedPerson()
        if worker == nil and person ~= nil then
            worker, key = person, MenuContractor.getPersonPortraitKey(person.id)
        end
    end
    self.workerPortrait:setWorker(worker, key)
end

function MenuContractor:hasCompany()
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Company == nil then
        return false
    end
    return tc.Company:hasCompany(g_currentMission:getFarmId())
end

-- The pages' mouse-over help, one popup per page (each its own layer): the
-- company logo says where a logo of the player's own goes, and the rank and
-- every relationship chip say what reputation and relationships are each
-- for. A target hides with its page, so each only shows on its own.
function MenuContractor:getPageTooltips()
    if self.pageTooltips == nil then
        local function newTooltip(prefix)
            return TCTooltip.new({
                box = self[prefix .. "TooltipBox"],
                surface = self[prefix .. "TooltipSurface"],
                title = self[prefix .. "TooltipTitle"],
                divider = self[prefix .. "TooltipDivider"],
                text = self[prefix .. "TooltipText"]
            })
        end

        local overview = newTooltip("overview")
        overview:addTarget(self.companyLogo, TCCompanyLogo.getTooltipContent)
        overview:addTarget(self.progressBox, MenuContractor.getReputationTooltipContent)

        local inbox = newTooltip("inbox")
        inbox:addTarget(self.inboxDetailRelationshipChip, MenuContractor.getReputationTooltipContent)
        inbox:addTarget(self.inboxMessageRelationshipChip, MenuContractor.getReputationTooltipContent)

        local staff = newTooltip("staff")
        staff:addTarget(self.staffPersonRelationshipChip, MenuContractor.getReputationTooltipContent)

        self.pageTooltips = { overview, inbox, staff }
    end
    return self.pageTooltips
end

-- The company's reputation against one customer's relationship, the same
-- on the rank and on a relationship chip.
function MenuContractor.getReputationTooltipContent()
    return g_i18n:getText("tc_reputationTip_title"),
        g_i18n:getText("tc_reputationTip_reputation") .. "\n\n" .. g_i18n:getText("tc_reputationTip_relationship")
end

-- The player's own logo from modSettings if there is one, else ours, the
-- whole image stretched to the 5:2 box. Looked up on every refresh, so a
-- logo dropped in mid-game shows the next time the menu opens.
function MenuContractor:refreshCompanyLogo()
    self.companyLogo:setImageFilename(TCCompanyLogo.getFilename())
    self.companyLogo:setImageUVs(nil, unpack(Overlay.DEFAULT_UVS))
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
        self.inboxPortraitFrame:setVisible(false)
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
        self.staffOfficeDetailsBox:setVisible(false)
        self.staffPersonDetailsBox:setVisible(false)
        self.selectedRosterWorkerId = nil
        self.selectedCandidateId = nil
        self.selectedOfficeRole = nil
        self.selectedPersonId = nil

        self.financesContent:setVisible(false)
        self.selectedInvoiceId = nil
        self.selectedOverheadKey = nil

        self.logbookContent:setVisible(false)
        self.selectedLogbookJobId = nil
        self.selectedLogbookVehicleId = nil

        self.suppliesContent:setVisible(false)
        self.selectedSupplyKey = nil

        self.workshopContent:setVisible(false)
        self.selectedWorkshopJobId = nil
    end

    if hasCompany then
        local farmId = g_currentMission:getFarmId()
        local tc = g_currentMission.TheContractor
        local name = tc.Company:getCompanyName(farmId)
        self.textCompanyName:setText(name)
        self:refreshCompanyLogo()

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
        self:refreshSuppliesState(farmId)
        self:refreshWorkshopState(farmId)

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
    self.placeholderSupplies:setVisible(not hasCompany)
    self.placeholderSupplies:setText(lockedText)
    self.placeholderWorkshop:setVisible(not hasCompany)
    self.placeholderWorkshop:setText(lockedText)
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
    -- 100: a workshop job is never allocated, so it's current work as soon
    -- as it's accepted.
    for _, job in ipairs(jobs:getJobsByState(farmId, TheContractorJob.STATE.ACCEPTED)) do
        if job:isWorkshop() then
            table.insert(activeJobs, job)
        end
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
        if job:isWorkshop() then
            -- "Fendt 942 Vario: Workshop Repair - In the workshop, due June 14".
            table.insert(lines, string.format(g_i18n:getText("tc_repair_overviewLine"), job:getLocationText(),
                job:getTypeText(), (self:getJobStatusChip(job)),
                formatTargetDate(job.targetPeriod, job.targetDayInPeriod)))
        else
            table.insert(lines, self:getCurrentJobLine(job))
        end
    end
    self.textCurrentJobs:setText(table.concat(lines, "\n"))
end

-- One allocated or in-progress field job's Overview line.
function MenuContractor:getCurrentJobLine(job)
    local fieldLabel = job:getLocationText()
    local line = string.format(g_i18n:getText("tc_overview_currentJobLine"), fieldLabel,
        job:getTypeText(), math.floor(job.completionPercentage))
    -- Player-driven haulage (035): delivery counts towards done too.
    if job:needsPlayerDelivery() and job.requiredLiters > 0 then
        line = line .. string.format(g_i18n:getText("tc_overview_deliveredSuffix"),
            math.floor(100 * job.deliveredLiters / job.requiredLiters), job.deliveryStationName or "?")
    end
    -- On hold for supplies (032).
    if job:isWaitingForSupplies() then
        line = line .. string.format(g_i18n:getText("tc_overview_supplySuffix"), job:getSupplyStatusText())
    end
    -- 071: a courtesy vehicle on it goes back to the insurer afterwards.
    local courtesyName = g_currentMission.TheContractor.CourtesyVehicle:getDueOnJob(job)
    if courtesyName ~= nil then
        line = line .. string.format(g_i18n:getText("tc_overview_courtesyDueSuffix"), courtesyName)
    end
    return line
end

-- The People tab's views (111), in staffViewSelector's order: the roster,
-- the candidates and the others (the farmers and the official).
MenuContractor.STAFF_VIEWS = { "roster", "candidates", "others" }
MenuContractor.STAFF_VIEW_STATES = { roster = 1, candidates = 2, others = 3 }
MenuContractor.STAFF_VIEW_TEXTS = { "tc_staff_viewRoster", "tc_staff_viewCandidates", "tc_staff_viewOthers" }
-- Column 2, 4 and 5's headings per view (column 1 is always the name).
MenuContractor.STAFF_HEADERS = {
    roster = { "tc_staff_columnWorkSpeed", "tc_staff_columnStatus", "tc_staff_columnJob" },
    candidates = { "tc_staff_columnWorkSpeed", "tc_staff_columnSalary", "tc_staff_columnBestSkills" },
    others = { "tc_people_columnLand", "tc_people_columnFields", "tc_people_columnYard" },
}
-- Each column's x and width in px, per view: the roster and candidates use
-- staffTable's template as laid out in the XML; Others has short columns,
-- so its names get the room. Header ids by column: staffHeaderCol1, 2, 4, 5.
MenuContractor.STAFF_COLUMNS = {
    staff = { name = { 14, 150 }, workSpeed = { 170, 60 }, col4 = { 236, 100 }, col5 = { 342, 198 } },
    others = { name = { 14, 266 }, workSpeed = { 290, 90 }, col4 = { 390, 80 }, col5 = { 480, 110 } },
}
MenuContractor.STAFF_COLUMN_HEADERS = { name = "staffHeaderCol1", workSpeed = "staffHeaderCol2",
    col4 = "staffHeaderCol4", col5 = "staffHeaderCol5" }

function MenuContractor:getStaffColumns()
    return MenuContractor.STAFF_COLUMNS[self.staffView == "others" and "others" or "staff"]
end

-- Cells are reused across views, so every row is laid out every time.
function MenuContractor:layoutStaffCell(cell)
    for attribute, column in pairs(self:getStaffColumns()) do
        local element = cell:getAttribute(attribute)
        element:setPosition(column[1] * g_pixelSizeScaledX, nil)
        element:setSize(column[2] * g_pixelSizeScaledX, nil)
    end
end

MenuContractor.STAFF_EMPTY_TEXTS = {
    roster = "tc_staff_rosterEmpty",
    candidates = "tc_staff_candidatesEmpty",
    others = "tc_people_empty",
}

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

    -- 090: the office roles, employed or not.
    local office = g_currentMission.TheContractor.Office
    self.officeRows = {}
    for _, role in ipairs(TheContractorOffice.ROLE_ORDER) do
        table.insert(self.officeRows, { role = role, member = office:getMember(farmId, role) })
    end

    -- 111: the farmers and the official.
    self.personRows = g_currentMission.TheContractor.Farmers:getPeopleRows((TheContractorFarmers.getLand()))

    local texts = {}
    for _, key in ipairs(MenuContractor.STAFF_VIEW_TEXTS) do
        table.insert(texts, g_i18n:getText(key))
    end
    self.staffViewSelector:setTexts(texts)
    self.staffViewSelector:setState(MenuContractor.STAFF_VIEW_STATES[self.staffView])
    self.staffViewSelector:setVisible(true)
    self.staffHeaderRow:setVisible(true)

    -- 055: so the player can see why sickness has changed. Only about staff.
    local isOthers = self.staffView == "others"
    local hasHealthSafety = g_currentMission.TheContractor.HealthSafety:isActive(farmId)
    setChip(self.staffHealthSafetyChip, self.staffHealthSafetyChipText, not isOthers and
        g_i18n:getText(hasHealthSafety and "tc_healthSafety_chipActive" or "tc_healthSafety_chipInactive") or nil,
        hasHealthSafety and "good" or "warn")

    -- Job column only makes sense for the roster view (candidates were never
    -- assigned anything) — blank it out entirely in the candidates view
    -- rather than showing a column full of "None". 111: Others has its own.
    local headers = MenuContractor.STAFF_HEADERS[self.staffView]
    self.staffHeaderCol2:setText(g_i18n:getText(headers[1]))
    self.staffHeaderCol4:setText(g_i18n:getText(headers[2]))
    self.staffHeaderCol5:setText(g_i18n:getText(headers[3]))
    for attribute, column in pairs(self:getStaffColumns()) do
        self[MenuContractor.STAFF_COLUMN_HEADERS[attribute]]:setPosition(column[1] * g_pixelSizeScaledX, nil)
    end
    -- 091: only while ADS takes our staff.
    self.staffHeaderCol6:setVisible(not isOthers and TCADSWorkshop.isActive())

    local hasItems = self:getStaffRowCount() > 0
    self.staffEmptyText:setText(g_i18n:getText(MenuContractor.STAFF_EMPTY_TEXTS[self.staffView]))
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
    if self:getSelectedOfficeRow() == nil then
        self.selectedOfficeRole = nil
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

    if self:getSelectedPersonRow() == nil then
        self.selectedPersonId = nil
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

-- 090: rows in the list showing: the roster view has the office rows
-- after the workers.
function MenuContractor:getStaffRowCount()
    if self.staffView == "candidates" then
        return #self.candidateList
    elseif self.staffView == "others" then
        return #self.personRows
    end
    return #self.rosterWorkers + #self.officeRows
end

-- The highlighted office row ({ role, member }), or nil.
function MenuContractor:getSelectedOfficeRow()
    if self.staffView ~= "roster" or self.selectedOfficeRole == nil then
        return nil
    end
    for _, row in ipairs(self.officeRows) do
        if row.role == self.selectedOfficeRole then
            return row
        end
    end
    return nil
end

-- The selection in whichever view is showing. Not `a and b or c`: with no
-- roster selection that would fall through to the selected candidate and
-- show them under the roster.
function MenuContractor:getSelectedStaffWorker()
    if self.staffView == "roster" then
        return self:getSelectedRosterWorker()
    elseif self.staffView == "candidates" then
        return self:getSelectedCandidate()
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
            return string.format(g_i18n:getText("tc_staff_jobLine"), job:getTypeText(),
                job:getLocationText())
        end
    end

    -- 037: out driving under AutoDrive/Courseplay.
    local vehicle = g_currentMission.TheContractor.Drivers:getVehicleDrivenBy(farmId, workerId)
    if vehicle ~= nil then
        return string.format(g_i18n:getText("tc_staff_drivingLine"), vehicle:getFullName())
    end
    return nil
end

-- 091: the list's ADS column - "Yes" for anyone with workshop skills, only
-- while ADS takes our staff. Green once they're ticked into the workshop.
local function setADSChip(cell, worker)
    local text = nil
    if worker ~= nil and TCADSWorkshop.isActive() and TheContractorWorkshop.hasSkills(worker) then
        text = g_i18n:getText("tc_staff_adsYes")
    end
    setChip(cell:getAttribute("adsChip"), cell:getAttribute("adsChipText"), text,
        worker ~= nil and worker.workshopRole ~= nil and "good" or "info")
end

function MenuContractor:populateStaffCell(index, cell)
    self:layoutStaffCell(cell)
    if self.staffView == "others" then
        local row = self.personRows[index]
        if row ~= nil then
            self:populatePersonCell(row, cell)
        end
        return
    end

    if self.staffView == "candidates" then
        local candidate = self.candidateList[index]
        if candidate == nil then
            return
        end

        cell:getAttribute("name"):setText(candidate.name)
        cell:getAttribute("workSpeed"):setText(tostring(candidate.workSpeed))
        cell:getAttribute("col4"):setText(g_i18n:formatMoney(TheContractorStaff.scalePay(candidate.salary), 0, true,
            true))
        cell:getAttribute("col4"):setVisible(true)
        setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"), nil)
        cell:getAttribute("col5"):setText(formatBestSkillsCell(candidate))
        setADSChip(cell, candidate)
        return
    end

    local worker = self.rosterWorkers[index]
    if worker == nil then
        local officeRow = self.officeRows[index - #self.rosterWorkers]
        if officeRow ~= nil then
            self:populateOfficeCell(officeRow, cell)
        end
        return
    end

    local farmId = g_currentMission:getFarmId()
    local jobLine = self:getAssignedJobLine(farmId, g_currentMission.TheContractor.Jobs, worker.id)

    cell:getAttribute("name"):setText(worker.name)
    cell:getAttribute("workSpeed"):setText(tostring(worker.workSpeed))
    -- Roster view: column 4 is the status chip, the salary text is the
    -- candidates view's.
    cell:getAttribute("col4"):setVisible(false)
    -- 097: an idle worker may have gone home.
    local status = TheContractorWorkingHours.getDisplayStatus(worker)
    setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"),
        g_i18n:getText("tc_staff_status_" .. status), getWorkerStatusTone(status))
    cell:getAttribute("col5"):setText(jobLine or "")
    setADSChip(cell, worker)
end

function MenuContractor:updateStaffDetails()
    self:setMenuButtonInfoDirty()

    local worker = self:getSelectedStaffWorker()
    self.staffDetailsBox:setVisible(worker ~= nil)
    -- 090: an office row has its own panel.
    local officeRow = self:getSelectedOfficeRow()
    self.staffOfficeDetailsBox:setVisible(officeRow ~= nil)
    if officeRow ~= nil then
        self:updateOfficeDetails(officeRow)
    end
    -- 111: and the Others view's.
    local personRow = self:getSelectedPersonRow()
    self.staffPersonDetailsBox:setVisible(personRow ~= nil)
    if personRow ~= nil then
        self:updatePersonDetails(personRow)
    end
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
    local salaryText
    if self.staffView == "roster" and TheContractorPayReviews.wantsMore(worker) then
        salaryText = string.format(g_i18n:getText("tc_pay_detailSalaryWants"),
            g_i18n:formatMoney(TheContractorStaff.scalePay(worker.salary), 0, true, true),
            g_i18n:formatMoney(TheContractorStaff.scalePay(worker.expectedSalary), 0, true, true))
    else
        salaryText = string.format(g_i18n:getText("tc_staff_detailSalary"),
            g_i18n:formatMoney(TheContractorStaff.scalePay(worker.salary), 0, true, true))
    end
    -- 097: and the overtime they've done this month.
    if self.staffView == "roster" and (worker.overtimeOwed or 0) >= 1 then
        salaryText = string.format(g_i18n:getText("tc_hours_detailOvertime"), salaryText,
            g_i18n:formatMoney(worker.overtimeOwed, 0, true, true))
    end
    self.staffDetailSalary:setText(salaryText)
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
    self.staffRowHoliday:setVisible(isRoster and (worker:hasHolidayBooked() or
        TheContractorHolidays.findRequest(worker.farmId, worker.id) ~= nil))

    if isRoster then
        local status = TheContractorWorkingHours.getDisplayStatus(worker)
        setChip(self.staffDetailStatusChip, self.staffDetailStatusChipText,
            g_i18n:getText("tc_staff_status_" .. status), getWorkerStatusTone(status))
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
    self:updateWorkshopDetails(worker, isRoster)

    self.staffDetailRows:invalidateLayout()
end

-- 091: ADS workshop skills, one chip per trade ("Mechanic 2", "Bodyworker -"),
-- green for the one they're ticked into, and a chip saying whether they
-- work there. The section (and the taller panel) only while ADS takes our
-- staff.
function MenuContractor:updateWorkshopDetails(worker, isRoster)
    local isActive = TCADSWorkshop.isActive()
    self.staffWorkshopSection:setVisible(isActive)
    self.staffPanelBg:setVisible(not isActive)
    self.staffPanelBgTall:setVisible(isActive)
    if not isActive then
        return
    end

    for i, role in ipairs(TheContractorWorkshop.ROLES) do
        local level = TheContractorWorkshop.getLevel(worker, role)
        local tone = "neutral"
        if worker.workshopRole == role then
            tone = "good"
        elseif level > 0 then
            tone = "info"
        end
        setChip(self["staffWorkshopChip" .. i], self["staffWorkshopChipText" .. i],
            string.format("%s %s", TheContractorWorkshop.getRoleName(role), level > 0 and tostring(level) or "-"), tone)
    end

    -- Roster only, and only with skills (the trade chips already say when
    -- there are none).
    local assigned
    if isRoster and worker.workshopRole ~= nil then
        assigned = "good"
    elseif isRoster and TheContractorWorkshop.hasSkills(worker) then
        assigned = "neutral"
    end
    setChip(self.staffWorkshopAssignedChip, self.staffWorkshopAssignedChipText, assigned ~= nil and
        g_i18n:getText(assigned == "good" and "tc_staff_workshopAssigned" or "tc_staff_workshopNotAssigned") or nil,
        assigned)
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

    -- 092: booked on a trade course, so not bookable for this one now.
    if worker:hasTrainingBooked() then
        return nil
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
-- and the booked holiday, or else the one they've asked for (089), if any
-- (its row is hidden otherwise, see updateStaffDetails).
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
        return
    end

    local request = TheContractorHolidays.findRequest(worker.farmId, worker.id)
    if request ~= nil then
        self.staffDetailHoliday:setText(string.format(g_i18n:getText("tc_staff_detailHolidayRequested"),
            TCCalendar.formatDayRange(request.payload.startDay, TheContractorHolidays.getRequestEndDay(request))))
    end
end

-- The only way to switch between Roster, Candidates and (111) Others —
-- same "in-page MultiTextOption, not a bottom-bar button" pattern as
-- calendarPeriodSelector. Switching views clears the *other* views'
-- selections' relevance (kept in memory, just no longer driving the details
-- box/button bar) by virtue of updateStaffDetails/getMenuButtonInfo both
-- keying off self.staffView, not by actually discarding
-- selectedRosterWorkerId/selectedCandidateId/selectedPersonId — so flipping
-- back and forth remembers where you were in each list.
function MenuContractor:onClickStaffView()
    self.staffView = MenuContractor.STAFF_VIEWS[self.staffViewSelector:getState()] or "roster"
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

    local firstPay = TheContractorStaff.scalePay(candidate.salary)
    if not staff:canAffordHire(farmId, firstPay) then
        InfoDialog.show(g_i18n:getText("tc_staff_hireCannotAfford"))
        return
    end

    local dialogPrompt = string.format(g_i18n:getText("tc_staff_hireConfirm"), candidate.name,
        g_i18n:formatMoney(firstPay, 0, true, true))

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
        table.insert(options, g_i18n:formatMoney(TheContractorMorale.getBonusCost(amount), 0, true, true))
    end

    OptionDialog.show(function(index)
        local amount = amounts[index]
        if amount == nil then
            return
        end

        if not TheContractorMorale.canAfford(farmId, amount) then
            InfoDialog.show(string.format(g_i18n:getText("tc_morale_bonusCannotAfford"),
                g_i18n:formatMoney(TheContractorMorale.getBonusCost(amount), 0, true, true), worker.name))
            return
        end

        g_client:getServerConnection():sendEvent(TCGiveBonusEvent.new(farmId, worker.id, amount))

        -- Same "synchronous for host/SP, catches up on next refresh for a
        -- remote client" caveat as onClickHireWorker.
        self:refreshStaffState(farmId, g_currentMission.TheContractor.Staff, g_currentMission.TheContractor.Jobs)

        -- A blocking confirmation as well as the notification. Worded
        -- without the new morale, which a remote client won't have yet.
        InfoDialog.show(string.format(g_i18n:getText("tc_morale_bonusConfirm"), worker.name,
            g_i18n:formatMoney(TheContractorMorale.getBonusCost(amount), 0, true, true)))
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
    -- Full-month figures, shown at this month's pay.
    local function money(amount)
        return g_i18n:formatMoney(TheContractorStaff.scalePay(amount), 0, true, true)
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

-- 066: the Manage list for the highlighted roster worker. Booking training
-- (054) is only offered while they're ready, uncertified and not booked,
-- and says whether it's the course or a retake. OptionDialog closes before
-- its callback runs, so the chosen action can open its own dialog.
function MenuContractor:onClickManageWorker()
    local worker = self:getSelectedRosterWorker()
    if worker == nil then
        return
    end

    local cert = MenuContractor.TRAINING_CERT
    local actions = {
        { text = g_i18n:getText("tc_editWorker_button"), run = self.onClickEditWorker },
        { text = g_i18n:getText("tc_morale_bonusButton"), run = self.onClickGiveBonus },
        { text = g_i18n:getText("tc_pay_riseButton"), run = self.onClickPayRise },
    }
    -- 097: kept on after hours, or sent home.
    for _, action in ipairs(self:getDutyActions(worker)) do
        table.insert(actions, action)
    end
    if TheContractorTraining.getBookingProblem(worker, cert) == nil then
        table.insert(actions, { text = g_i18n:getText(TheContractorTraining.isRetake(worker, cert) and
            "tc_training_bookRetakeButton" or "tc_training_bookCourseButton"), run = self.onClickBookTraining })
    end
    -- 092: a trade course, while any can be booked.
    if #TheContractorWorkshop.getCourseOptions(worker) > 0 then
        table.insert(actions, { text = g_i18n:getText("tc_workshop_trainingButton"), run = self.onClickWorkshopTraining })
    end
    -- 091: into the ADS workshop in one of their trades, or out of it.
    for _, action in ipairs(self:getWorkshopActions(worker)) do
        table.insert(actions, action)
    end

    local options = {}
    for _, action in ipairs(actions) do
        table.insert(options, action.text)
    end

    local workerId = worker.id
    OptionDialog.show(function(index)
        local action = actions[index]
        -- Still the same worker: the list could have refreshed meanwhile.
        if action == nil or self.selectedRosterWorkerId ~= workerId then
            return
        end
        action.run(self)
    end, string.format(g_i18n:getText("tc_staff_managePrompt"), worker.name), g_i18n:getText("tc_staff_manageTitle"),
        options)
end

-- 097: Manage worker's working hours entries: Stay late (or Stay longer,
-- if they're on already) while they're at work, Call back once they've
-- gone home, and Send home while they're kept on. None while they're away,
-- or when it's too near morning to offer a time.
function MenuContractor:getDutyActions(worker)
    local actions = {}
    local now = TheContractorWorkingHours.getNow()
    local ACTION = TheContractorWorkingHours.ACTION
    local action = TheContractorWorkingHours.getDutyAction(worker, now)
    local hasDuty = TheContractorWorkingHours.hasDuty(worker, now)
    if action ~= nil and #TheContractorWorkingHours.getUntilOptions(worker, now) > 0 then
        local key = "tc_hours_stayLateButton"
        if action == ACTION.CALL then
            key = "tc_hours_callBackButton"
        elseif hasDuty then
            key = "tc_hours_stayLongerButton"
        end
        table.insert(actions, { text = g_i18n:getText(key), run = self.onClickKeepOn })
    end
    if hasDuty then
        table.insert(actions, { text = g_i18n:getText("tc_hours_sendHomeButton"), run = function(target)
            target:sendDuty(worker, ACTION.HOME, nil)
        end })
    end
    return actions
end

-- 097: pick how late (OptionDialog, each time with what it'll cost in
-- overtime), then the server checks it again (WorkingHours:requestDuty).
function MenuContractor:onClickKeepOn()
    local worker = self:getSelectedRosterWorker()
    if worker == nil then
        return
    end
    local now = TheContractorWorkingHours.getNow()
    local action = TheContractorWorkingHours.getDutyAction(worker, now)
    local times = TheContractorWorkingHours.getUntilOptions(worker, now)
    if action == nil or #times == 0 then
        return
    end

    local options = {}
    for _, at in ipairs(times) do
        table.insert(options, string.format(g_i18n:getText("tc_hours_untilOption"),
            TheContractorWorkingHours.formatTime(at),
            g_i18n:formatMoney(TheContractorWorkingHours.getDutyCost(worker, now, at), 0, true, true)))
    end
    local isCall = action == TheContractorWorkingHours.ACTION.CALL
    local prompt = isCall and
        string.format(g_i18n:getText("tc_hours_callBackPrompt"), worker.name, TheContractorWorkingHours.CALL_BACK_MINUTES) or
        string.format(g_i18n:getText("tc_hours_stayLatePrompt"), worker.name,
            string.format("%02d:00", TheContractorWorkingHours.END_HOUR))

    local workerId = worker.id
    OptionDialog.show(function(index)
        local at = times[index]
        if at == nil or self.selectedRosterWorkerId ~= workerId then
            return
        end
        self:sendDuty(worker, action, at)
    end, prompt, g_i18n:getText(isCall and "tc_hours_callBackTitle" or "tc_hours_stayLateTitle"), options)
end

-- Sends the request; the change comes back on every machine (the server
-- included) through TheContractorWorkingHours.applyDuty, which redraws the
-- tab.
function MenuContractor:sendDuty(worker, action, untilMinutes)
    g_client:getServerConnection():sendEvent(TCWorkerDutyEvent.new(worker.farmId, worker.id, action, nil, nil,
        untilMinutes))
end

-- 091: Manage worker's workshop entries: "Work in the workshop as ..." for
-- each trade they have (saying who they'd replace), and "Stop working in
-- the workshop" while they're ticked. None without ADS.
function MenuContractor:getWorkshopActions(worker)
    local actions = {}
    if not TCADSWorkshop.isActive() then
        if worker.workshopRole ~= nil then
            table.insert(actions, { text = g_i18n:getText("tc_staff_workshopStopButton"), run = function(target)
                target:sendWorkshopRole(worker, nil)
            end })
        end
        return actions
    end

    for _, entry in ipairs(TheContractorWorkshop.getSkillList(worker)) do
        if entry.role ~= worker.workshopRole then
            local roleName = string.lower(TheContractorWorkshop.getRoleName(entry.role))
            local holder = TheContractorWorkshop.getRoleHolder(worker.farmId, entry.role)
            local text
            if holder ~= nil then
                text = string.format(g_i18n:getText("tc_staff_workshopReplaceButton"), roleName, holder.name)
            else
                text = string.format(g_i18n:getText("tc_staff_workshopButton"), roleName)
            end
            table.insert(actions, { text = text, run = function(target)
                target:sendWorkshopRole(worker, entry.role)
            end })
        end
    end
    if worker.workshopRole ~= nil then
        table.insert(actions, { text = g_i18n:getText("tc_staff_workshopStopButton"), run = function(target)
            target:sendWorkshopRole(worker, nil)
        end })
    end
    return actions
end

-- Sends the request; the change comes back on every machine (the server
-- included) through TheContractorWorkshop.apply, which redraws the tab.
function MenuContractor:sendWorkshopRole(worker, role)
    g_client:getServerConnection():sendEvent(TCWorkerWorkshopEvent.new(worker.farmId, worker.id, nil, role))
end

-- 066: the dialog sends the edit itself. The People tab's portrait is
-- hidden while it's open (updateWorkerPortrait) and comes back on close.
function MenuContractor:onClickEditWorker()
    local worker = self:getSelectedRosterWorker()
    if worker == nil then
        return
    end
    self:openEditPerson(worker, TCEditPersonDialog.KIND.WORKER)
end

-- 111: the highlighted farmer or the official.
function MenuContractor:onClickEditPerson()
    local person = self:getSelectedPerson()
    if person == nil then
        return
    end
    self:openEditPerson(person, TCEditPersonDialog.KIND.FARMER)
end

-- 122: "Role: model" for one of a farmer's machines.
local function getMachineText(machine)
    return string.format(g_i18n:getText("tc_fleet_machineLine"), TheContractorFarmerFleet.getRoleText(machine.role),
        TheContractorFarmerFleet.getModelName(machine.xmlFilename))
end

-- 122: the highlighted farmer's machines, then the models for the one
-- picked. OptionDialog closes before its callback runs, so the second can
-- open from the first's.
function MenuContractor:onClickPersonMachines()
    local person = self:getSelectedPerson()
    if person == nil or person.isOfficial or person.machines == nil or #person.machines == 0 then
        return
    end
    local machines = TheContractorFarmerFleet.getSorted(person.machines)
    local options = {}
    for _, machine in ipairs(machines) do
        table.insert(options, getMachineText(machine))
    end
    local personId = person.id
    OptionDialog.show(function(index)
        local machine = machines[index]
        if machine == nil or self.selectedPersonId ~= personId then
            return
        end
        self:openMachineModels(person, machine)
    end, string.format(g_i18n:getText("tc_fleet_machinesPrompt"), person.name),
        g_i18n:getText("tc_fleet_machinesTitle"), options)
end

function MenuContractor:openMachineModels(person, machine)
    local models = TheContractorFarmerFleet.getModelChoices(TheContractorFarmerFleet.buildCatalog(), person, machine)
    if #models == 0 then
        InfoDialog.show(string.format(g_i18n:getText("tc_fleet_noModels"),
            string.lower(TheContractorFarmerFleet.getRoleText(machine.role))))
        return
    end
    local options, current = {}, 1
    for index, model in ipairs(models) do
        local name = TheContractorFarmerFleet.getModelName(model.xmlFilename)
        if model.xmlFilename == machine.xmlFilename then
            current = index
            name = string.format(g_i18n:getText("tc_fleet_modelCurrent"), name)
        end
        table.insert(options, name)
    end
    local personId, machineId = person.id, machine.id
    OptionDialog.show(function(index)
        local model = models[index]
        if model == nil or model.xmlFilename == machine.xmlFilename or self.selectedPersonId ~= personId then
            return
        end
        -- Told how it went in onFarmerMachineEdited (synchronous for the
        -- host and single player, once the result arrives for a client).
        self.pendingMachineEdit = { personId = personId, machineId = machineId }
        g_client:getServerConnection():sendEvent(TCEditFarmerMachineEvent.new(g_currentMission:getFarmId(),
            personId, machineId, model.xmlFilename))
    end, string.format(g_i18n:getText("tc_fleet_modelsPrompt"), person.name,
        string.lower(TheContractorFarmerFleet.getRoleText(machine.role))),
        g_i18n:getText("tc_fleet_machinesTitle"), options, current)
end

-- 122: how this farm's edit of a farmer's machine went
-- (TheContractorFarmerFleet.onEditResult). Only the player who asked is
-- told: a refusal and why, or the attachment that had to change with it.
function MenuContractor:onFarmerMachineEdited(personId, machineId, problem, repickedId)
    local pending = self.pendingMachineEdit
    if pending == nil or pending.personId ~= personId or pending.machineId ~= machineId then
        return
    end
    self.pendingMachineEdit = nil
    if problem ~= nil then
        InfoDialog.show(g_i18n:getText("tc_fleet_refused_" .. problem))
        return
    end
    local person = g_currentMission.TheContractor.Farmers:getPerson(personId)
    local machine = TheContractorFarmerFleet.getMachine(person, machineId)
    local attachment = TheContractorFarmerFleet.getMachine(person, repickedId)
    if machine ~= nil and attachment ~= nil then
        InfoDialog.show(string.format(g_i18n:getText("tc_fleet_attachmentRepicked"),
            TheContractorFarmerFleet.getModelName(machine.xmlFilename),
            string.lower(TheContractorFarmerFleet.getRoleText(attachment.role)),
            TheContractorFarmerFleet.getModelName(attachment.xmlFilename)))
    end
end

-- kind: TCEditPersonDialog.KIND. draft: TCEditPersonDialog.show's unsaved
-- edit to carry on with, or nil.
function MenuContractor:openEditPerson(person, kind, draft)
    self.isEditingWorker = true
    self:updateWorkerPortrait()
    TCEditPersonDialog.show(person, kind, function(target)
        target.isEditingWorker = false
        -- Same "synchronous for host/SP, catches up when the edit arrives
        -- for a remote client" as the other Staff actions.
        target:refreshStaffState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Staff,
            g_currentMission.TheContractor.Jobs)
    end, self, draft)
end

-- 077: back from the wardrobe. The menu closed when it opened, so this
-- opens it again on the People tab's view the person is in (the roster, or
-- 111's Others) and puts the edit dialog back with its draft. Someone
-- who's gone meanwhile just isn't reopened.
function MenuContractor:reopenEditPerson(kind, personId, draft)
    if g_gui.currentGuiName ~= "InGameMenu" then
        g_gui:showGui("InGameMenu")
    end
    g_inGameMenu:goToPage(self)

    local isFarmer = kind == TCEditPersonDialog.KIND.FARMER
    local view = isFarmer and "others" or "roster"
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.STAFF, true)
    if self.staffView ~= view then
        self.staffViewSelector:setState(MenuContractor.STAFF_VIEW_STATES[view])
        self:onClickStaffView()
    end
    self:setMenuButtonInfoDirty()
    if not self:hasCompany() then
        return
    end

    local person
    if isFarmer then
        person = g_currentMission.TheContractor.Farmers:getPerson(personId)
        if person ~= nil then
            self:selectPerson(personId)
        end
    else
        -- 090: or one of the office staff.
        person = g_currentMission.TheContractor.Staff:getEditablePerson(g_currentMission:getFarmId(), personId)
    end
    if person == nil then
        return
    end
    self:openEditPerson(person, kind, draft)
end

-- 066: a worker was edited (TheContractorStaff:applyWorkerEdited, every
-- machine). Their portrait loads the new look, and an open Staff tab shows
-- the new name.
function MenuContractor:onWorkerEdited(workerId)
    if self.workerPortrait ~= nil and self.workerPortrait.shownKey == workerId then
        self.workerPortrait:reload()
    end
    if self.isFrameOpen and self:hasCompany() then
        local tc = g_currentMission.TheContractor
        self:refreshStaffState(g_currentMission:getFarmId(), tc.Staff, tc.Jobs)
    end
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

    local firstDay = TheContractorTraining.getFirstBookableDay(worker, cert)
    local dialogPrompt
    if TheContractorTraining.isRetake(worker, cert) then
        dialogPrompt = string.format(g_i18n:getText("tc_training_confirmRetake"), worker.name, certName, priceText,
            TCCalendar.formatDay(firstDay))
    else
        local courseDates = TCCalendar.formatDayRange(firstDay,
            firstDay + TheContractorTraining.getCourseDays(cert) - 1)
        local gapMin, gapMax = TheContractorTraining.getAssessmentGap()
        if gapMin == gapMax then
            dialogPrompt = string.format(g_i18n:getText("tc_training_confirmCourseFixedGap"), worker.name, certName,
                priceText, courseDates, gapMin)
        else
            dialogPrompt = string.format(g_i18n:getText("tc_training_confirmCourse"), worker.name, certName, priceText,
                courseDates, gapMin, gapMax)
        end
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

-- 092: Manage worker's "Workshop training": pick a course (learn a trade,
-- or the next level of one), then funds-check-then-confirm like
-- onClickBookTraining. The server re-checks everything.
function MenuContractor:onClickWorkshopTraining()
    local worker = self:getSelectedRosterWorker()
    if worker == nil then
        return
    end
    local courses = TheContractorWorkshop.getCourseOptions(worker)
    if #courses == 0 then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local options = {}
    for _, course in ipairs(courses) do
        local roleName = TheContractorWorkshop.getRoleName(course.role)
        local price = TheContractorTraining.formatPrice(TheContractorWorkshop.getCoursePrice(farmId, worker, course.role))
        local days = TheContractorWorkshop.getCourseDays(worker, course.role)
        if course.level == 1 then
            table.insert(options, string.format(g_i18n:getText("tc_workshop_courseOptionLearn"), string.lower(roleName),
                price, days))
        else
            table.insert(options, string.format(g_i18n:getText("tc_workshop_courseOptionRaise"), roleName, course.level,
                price, days))
        end
    end

    local workerId = worker.id
    OptionDialog.show(function(index)
        local course = courses[index]
        if course == nil or self.selectedRosterWorkerId ~= workerId then
            return
        end
        self:confirmWorkshopCourse(worker, course.role)
    end, string.format(g_i18n:getText("tc_workshop_coursePrompt"), worker.name),
        g_i18n:getText("tc_workshop_courseTitle"), options)
end

function MenuContractor:confirmWorkshopCourse(worker, role)
    if TheContractorWorkshop.getCourseProblem(worker, role) ~= nil then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local price = TheContractorWorkshop.getCoursePrice(farmId, worker, role)
    local priceText = TheContractorTraining.formatPrice(price)
    local courseName = TheContractorWorkshop.getCourseName(worker, role)

    if not TheContractorTraining.canAfford(farmId, price) then
        InfoDialog.show(string.format(g_i18n:getText("tc_training_cannotAfford"), worker.name, courseName, priceText))
        return
    end

    local firstDay = TheContractorTraining.getFirstBookableDay(worker, TheContractorWorkshop.getCourseKey(role))
    local dialogPrompt = string.format(g_i18n:getText("tc_workshop_courseConfirm"), worker.name, courseName, priceText,
        TCCalendar.formatDayRange(firstDay, firstDay + TheContractorWorkshop.getCourseDays(worker, role) - 1))
    -- 091: a ticked worker's trade waits in ADS while they're away.
    if worker.workshopRole ~= nil then
        dialogPrompt = dialogPrompt .. " " .. string.format(g_i18n:getText("tc_workshop_courseConfirmTicked"),
            string.lower(TheContractorWorkshop.getRoleName(worker.workshopRole)))
    end

    local key = TheContractorWorkshop.getCourseKey(role)
    YesNoDialog.show(function(target, clickOk)
        if not clickOk then
            return
        end

        g_client:getServerConnection():sendEvent(TCBookTrainingEvent.new(farmId, worker.id, key))
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
    -- 112: an offer's customer.
    local customer = inbox:getMessageCustomer(message)
    self.inboxMessageRowFrom:setVisible(customer ~= nil)
    self.inboxMessageFrom:setText(customer ~= nil and MenuContractor.getCustomerText(customer) or "")
    setChip(self.inboxMessageRelationshipChip, self.inboxMessageRelationshipChipText,
        MenuContractor.getRelationshipChip(customer))
    local chipText, chipTone = inbox:getChip(message)
    setChip(self.inboxMessageChip, self.inboxMessageChipText, chipText, chipTone)
    self.inboxMessageReceived:setText(TCCalendar.formatDay(message.createdDay))
    self.inboxMessageRowExpires:setVisible(message.expiresDay ~= nil)
    self.inboxMessageRowPortraitSpacer:setVisible(customer ~= nil and message.expiresDay == nil)
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

    -- A kind can ask for a confirm first (070's Submit claim).
    local definition = g_currentMission.TheContractor.Inbox:getKind(message.kind)
    local confirmText = definition ~= nil and definition.getConfirmText ~= nil and
        definition.getConfirmText(message, action.key) or nil
    if confirmText ~= nil then
        local messageId = message.id
        YesNoDialog.show(function(target, clickOk)
            if clickOk then
                target:sendMessageAction(messageId, action.key)
            end
        end, self, confirmText)
        return
    end
    self:sendMessageAction(message.id, action.key)
end

function MenuContractor:sendMessageAction(messageId, actionKey)
    local farmId = g_currentMission:getFarmId()
    g_client:getServerConnection():sendEvent(TCMessageActionEvent.new(farmId, messageId, actionKey))

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

-- 112: who the highlighted Inbox item is from: a job offer's customer, or
-- that of the job a message offers. nil for anything else, and for an ADS
-- repair contract (no customer, 110).
function MenuContractor:getSelectedInboxCustomer()
    local job = self:getSelectedInboxJob()
    if job ~= nil then
        return job:getCustomer()
    end
    local message = self:getSelectedInboxMessage()
    if message ~= nil then
        return g_currentMission.TheContractor.Inbox:getMessageCustomer(message)
    end
    return nil
end

-- 112: a customer as the From and Customer rows name them.
function MenuContractor.getCustomerText(person)
    if person.isOfficial then
        return string.format(g_i18n:getText("tc_customer_official"), person.name)
    end
    return person.name
end

-- 113: the player's farm's relationship with a person, as chip text and
-- tone (nil for nobody).
function MenuContractor.getRelationshipChip(person)
    if person == nil then
        return nil
    end
    return g_currentMission.TheContractor.Relationships:getChip(g_currentMission:getFarmId(), person.id)
end

function MenuContractor:updateInboxDetails()
    self:updateInboxMessageDetails()

    local job = self:getSelectedInboxJob()
    self.inboxDetailsBox:setVisible(job ~= nil)
    self:setMenuButtonInfoDirty()
    self:updateWorkerPortrait()
    self.inboxPortraitFrame:setVisible(self:getSelectedInboxCustomer() ~= nil)

    if job == nil then
        return
    end

    self.inboxDetailTitle:setText(job:getDisplayTitle())
    local customer = job:getCustomer()
    self.inboxRowCustomer:setVisible(customer ~= nil)
    self.inboxDetailCustomer:setText(customer ~= nil and MenuContractor.getCustomerText(customer) or "")
    setChip(self.inboxDetailRelationshipChip, self.inboxDetailRelationshipChipText,
        MenuContractor.getRelationshipChip(customer))

    -- 100: a customer's machine in a repair zone.
    self.inboxRowSkill:setVisible(not job:isWorkshop())
    if job:isWorkshop() then
        self:updateInboxWorkshopDetails(job)
        return
    end
    self.inboxEquipHeading:setText(g_i18n:getText("tc_inbox_equipmentHeading"))
    self.inboxInspectionHeadingRow:setVisible(false)
    self.inboxInspectionRow:setVisible(false)
    self.inboxLabelField:setText(g_i18n:getText("tc_detail_field"))
    self.inboxLabelCrew:setText(g_i18n:getText("tc_detail_crew"))
    self.inboxLabelDelivery:setText(g_i18n:getText("tc_detail_deliverTo"))

    local field = g_fieldManager:getFieldById(job.fieldId)
    local fieldText = field ~= nil and field:getName() or tostring(job.fieldId)
    if field ~= nil and field:getAreaHa() ~= nil then
        fieldText = string.format(g_i18n:getText("tc_inbox_fieldValue"), fieldText,
            g_i18n:formatArea(field:getAreaHa(), 2))
    end
    -- 124, 126: a farmer's yard (its field only says where it is).
    if job:isYardJob() then
        self.inboxLabelField:setText(g_i18n:getText("tc_jobDetails_place"))
        fieldText = job:getLocationText()
    end
    self.inboxDetailField:setText(fieldText)
    self.inboxDetailTargetDate:setText(formatTargetDate(job.targetPeriod, job.targetDayInPeriod))
    self.inboxDetailPrice:setText(g_i18n:formatMoney(job:getPrice(), 0, true, true))
    self.inboxDetailCrew:setText(self:getJobCrewText(job))
    -- 075: a job type with no operation skill (fly-tipping, carried by
    -- hand) has no level to meet either.
    local skillText = job:getOperationSkillText()
    setChip(self.inboxDetailSkillChip, self.inboxDetailSkillChipText, skillText ~= nil and string.format(
        g_i18n:getText("tc_inbox_skillValue"), skillText, job.requiredSkillLevel) or
        g_i18n:getText("tc_inbox_skillNone"), "info")
    -- Harvest & haul (035): the hauler is judged on haulage, to the same level.
    -- There's no hauler on a job only the player does (067's bales).
    local hasHauler = job.includesHaulage and not TheContractorJobGeneration.isPlayerOnly(job)
    setChip(self.inboxDetailHaulSkillChip, self.inboxDetailHaulSkillChipText, hasHauler and string.format(
        g_i18n:getText("tc_inbox_skillValue"), g_i18n:getText("tc_skill_haulage"), job.requiredSkillLevel) or nil,
        "info")

    -- Harvest & haul (035): where the crop has to go. 124: what the
    -- farmer's asked for.
    self.inboxRowDelivery:setVisible(job.includesHaulage or job.yardDelivery ~= nil)
    self.inboxDetailDelivery:setText(job.deliveryStationName or "?")
    if job.yardDelivery ~= nil then
        self.inboxLabelDelivery:setText(g_i18n:getText("tc_yardBales_detailOrder"))
        self.inboxDetailDelivery:setText(TheContractorYardBales.getDeliveryText(job))
    end
    -- 126: the farmer's load, and where it's sold.
    if job.yardHaul ~= nil then
        self.inboxDetailDelivery:setText(TheContractorYardHaul.getDeliveryText(job))
    end

    self:updateInboxSupplies(job)
    self:updateInboxEquipment(job)

    local history = self.negotiationHistory[job.id]
    local latestMessage = history ~= nil and history[#history] or nil
    self.inboxNegotiationLog:setText(latestMessage or "")
    self.inboxNegotiationBox:setVisible(latestMessage ~= nil)

    self.inboxDetailRows:invalidateLayout()
end

-- 100: a workshop job's panel, in the field job's rows: the machine and
-- its hours, the work, and (102) whether it's been inspected and what the
-- farm's own kit can do (live, so an inspection or new kit shows at once).
-- The price is agreed through Negotiate, so it isn't shown.
function MenuContractor:updateInboxWorkshopDetails(job)
    local workshop = job.workshop
    local isBreakdown = TheContractorRepairContracts.isBreakdownJob(job)
    self.inboxLabelField:setText(g_i18n:getText("tc_repair_detailMachine"))
    self.inboxLabelCrew:setText(g_i18n:getText("tc_repair_detailWork"))

    local machineText = workshop.vehicleName or "?"
    if workshop.operatingHours ~= nil then
        machineText = string.format(g_i18n:getText("tc_repair_machineHours"), machineText,
            math.floor(workshop.operatingHours + 0.5))
    end
    -- 101: and the field it's broken down on. 116, 123: or the farmer's
    -- yard.
    if isBreakdown or TheContractorRepairContracts.isFavourJob(job) then
        local hours = workshop.operatingHours ~= nil and math.floor(workshop.operatingHours + 0.5) or nil
        machineText = job:getLocationText()
        if hours ~= nil then
            machineText = string.format(g_i18n:getText("tc_repair_machineHours"), machineText, hours)
        end
    end
    self.inboxDetailField:setText(machineText)
    self.inboxDetailTargetDate:setText(formatTargetDate(job.targetPeriod, job.targetDayInPeriod))
    self.inboxDetailPrice:setText(MenuContractor.getJobPriceText(job))
    self.inboxDetailCrew:setText(MenuContractor.getWorkshopWorkText(job))
    self.inboxRowDelivery:setVisible(false)
    self.inboxRowSupplies:setVisible(false)

    self.inboxEquipHeading:setText(g_i18n:getText("tc_repair_kitHeading"))
    self:updateInboxWorkshopKit(job)

    local history = self.negotiationHistory[job.id]
    local latestMessage = history ~= nil and history[#history] or nil
    self.inboxNegotiationLog:setText(latestMessage or "")
    self.inboxNegotiationBox:setVisible(latestMessage ~= nil)

    self.inboxDetailRows:invalidateLayout()
end

-- What a workshop job's work is, in a sentence: 116's favour names the part.
function MenuContractor.getWorkshopWorkText(job)
    if TheContractorRepairContracts.isFavourJob(job) then
        return string.format(g_i18n:getText("tc_repair_work_favour"), TheContractorFarmerFavours.getPartText(job))
    end
    return g_i18n:getText("tc_repair_work_" .. TheContractorRepairContracts.getWorkKey(job))
end

-- 102: whether a job's price is still the player's to quote: a workshop
-- offer, but never a favour (116).
function MenuContractor.isPriceToAgree(job)
    return job:isWorkshop() and not TheContractorRepairContracts.isFavourJob(job) and
        (job.state == TheContractorJob.STATE.OFFERED or job.state == TheContractorJob.STATE.NEGOTIATING)
end

-- 102: a workshop offer's price, or "To agree" while it's still an offer
-- (the price is the player's quote, and the stored one would give the
-- hidden faults away).
function MenuContractor.getJobPriceText(job)
    -- 116: a favour's price is the part, known from the start.
    if MenuContractor.isPriceToAgree(job) then
        return g_i18n:getText("tc_repair_priceToAgree")
    end
    return g_i18n:formatMoney(job:getPrice(), 0, true, true)
end

-- 102: a fix's chip: what the farm can do with its own kit.
MenuContractor.FIX_STATUS_CHIPS = {
    available = { key = "tc_repair_chipAvailable", tone = "good" },
    missing = { key = "tc_repair_chipMissing", tone = "bad" },
    notPossible = { key = "tc_repair_chipNotPossible", tone = "info" },
}

-- 102: what a fix the farm can't do lacks, as the own workshop upgrades that
-- bring it: "needs Machine tools". Kit the farm has is never named.
function MenuContractor.getFixKitText(row)
    return string.format(g_i18n:getText("tc_repair_fixNeeds"), TCADSRepairContracts.getUpgradeNames(row.missing))
end

-- 102: the checklist rows for every fault found so far, for the Inbox and
-- the Workshop tab: { fault, row } pairs, a fixed fault with no rows.
function MenuContractor.getFaultChecklistRows(farmPlan)
    local rows = {}
    for _, fault in ipairs(farmPlan ~= nil and farmPlan.faults or {}) do
        if fault.done then
            table.insert(rows, { fault = fault })
        else
            for _, row in ipairs(TCADSRepairContracts.getFaultChecklist(fault)) do
                table.insert(rows, { fault = fault, row = row })
            end
        end
    end
    return rows
end

-- 102: a workshop offer's Inspection section (one row) and its Kit
-- checklist below it: for a field breakdown (101) the kit that can fix it
-- on the spot; for a service, hand tools; for a repair, once it's been
-- inspected, a row per fault and way to fix it ("Turbocharger · Repair ·
-- needs Machine tools" / Missing, "Turbocharger · Replace · Hand tools" /
-- Available, or Not possible where ADS doesn't allow it). Missing kit
-- never blocks the job: a dealer or a hired mobile workshop can do it.
function MenuContractor:updateInboxWorkshopKit(job)
    local vehicle = TheContractorRepairContracts.getVehicle(job)
    local inspected = vehicle ~= nil and TCADSRepairContracts.isInspected(vehicle)
    -- 116: a favour's farmer has said what's wrong, so there's nothing to
    -- find out before taking it on.
    local isFavour = TheContractorRepairContracts.isFavourJob(job)
    self.inboxInspectionHeadingRow:setVisible(not isFavour)
    self.inboxInspectionRow:setVisible(not isFavour)
    self.inboxInspectionName:setText(g_i18n:getText("tc_repair_inspectionRow"))
    setChip(self.inboxInspectionChip, self.inboxInspectionChipText,
        g_i18n:getText(inspected and "tc_repair_chipInspected" or "tc_repair_chipNeedsInspection"),
        inspected and "good" or "warn")

    local rows = {}
    if isFavour then
        -- The part to bring, from stock or bought for it; it's fitted by hand.
        table.insert(rows, { name = string.format(g_i18n:getText("tc_favour_kitRowPart"),
            TheContractorFarmerFavours.getPartText(job)), chip = g_i18n:getText("tc_favour_chipBring"), tone = "info" })
    elseif TheContractorRepairContracts.isBreakdownJob(job) then
        local fieldService = job.workshop.serviceLevel
        local hasKit = TheContractorRepairContracts.hasBreakdownKit(job.farmId, fieldService)
        table.insert(rows, { name = g_i18n:getText("tc_breakdown_kit_" ..
            TheContractorRepairContracts.getBreakdownKitKey(fieldService)),
            chip = g_i18n:getText(hasKit and "tc_repair_chipAvailable" or "tc_repair_chipMissing"),
            tone = hasKit and "good" or "bad" })
    elseif job.workshop.kind == TCADSRepairContracts.KIND.MAINTENANCE then
        table.insert(rows, { name = string.format(g_i18n:getText("tc_repair_kitRowService"),
            g_i18n:getText("tc_repair_handTools")), chip = g_i18n:getText("tc_repair_chipAvailable"), tone = "good" })
    elseif not inspected then
        table.insert(rows, { name = g_i18n:getText("tc_repair_kitRowUnknown"),
            chip = g_i18n:getText("tc_repair_chipUnknown"), tone = "info" })
    else
        local farmPlan = TCADSRepairContracts.getFarmPlan(vehicle, job.farmId)
        for _, entry in ipairs(MenuContractor.getFaultChecklistRows(farmPlan)) do
            local faultName = TCADSRepairContracts.getText(entry.fault.nameKey)
            if entry.row == nil then
                table.insert(rows, { name = faultName, chip = g_i18n:getText("tc_repair_chipFixed"), tone = "good" })
            else
                local status = MenuContractor.FIX_STATUS_CHIPS[entry.row.status]
                local name = string.format(g_i18n:getText("tc_repair_kitRow"), faultName,
                    g_i18n:getText("tc_repair_option_" .. entry.row.operation))
                -- Only kit the farm lacks is named.
                if entry.row.status == "missing" and #entry.row.missing > 0 then
                    name = string.format(g_i18n:getText("tc_repair_kitRowKit"), name,
                        MenuContractor.getFixKitText(entry.row))
                end
                table.insert(rows, { name = name, chip = g_i18n:getText(status.key), tone = status.tone })
            end
        end
    end

    for i = 1, MenuContractor.INBOX_EQUIPMENT_SLOTS do
        local row = rows[i]
        self["inboxEquipRow" .. i]:setVisible(row ~= nil)
        if row ~= nil then
            self["inboxEquipName" .. i]:setText(row.name)
            setChip(self["inboxEquipChip" .. i], self["inboxEquipChipText" .. i], row.chip, row.tone)
        end
    end
end

-- 102: how much of an inspected repair the farm's own kit covers: "full"
-- (every fault its cheapest way, a repair wherever ADS allows one),
-- "partial" (some only by replacing, for want of an upgrade) or "none"
-- (some it can't do at all). nil before the inspection.
function MenuContractor.getKitCoverage(farmPlan)
    if farmPlan == nil or farmPlan.plan == nil then
        return nil
    end
    if not farmPlan.plan.canDo then
        return "none"
    end
    if #(farmPlan.repairNeeds or {}) > 0 then
        return "partial"
    end
    return "full"
end

-- Who can do the job: one worker (or the player), two for harvest & haul
-- (035) unless the player hauls, or the player alone for work the AI
-- helper can't do (032's playerOnly, bale wrapping, and 067's bales to
-- deliver).
function MenuContractor:getJobCrewText(job)
    if TheContractorJobGeneration.isPlayerOnly(job) then
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

    -- 067: a straw delivery needs nothing in particular - whatever the
    -- player moves bales with. One unchecked row says so. 075: fly-tipping
    -- is carried by hand to a skip. 107: a job type can name its own
    -- (equipmentNeed: a fallen tree's chainsaw).
    if jobDef.noEquipment then
        local key = jobDef.equipmentNeed or (jobDef.rewardPerItem ~= nil and "disposalSkip" or "baleTransport")
        table.insert(rows, { key = key, isHaulage = false, isUnchecked = true })
        return rows
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

    if job.includesHaulage and not TheContractorJobGeneration.isPlayerOnly(job) then
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
    if job.includesHaulage and not TheContractorJobGeneration.isPlayerOnly(job) then
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
            if row.isUnchecked then
                setChip(chip, chipText, nil)
            elseif table.hasElement(owned, row.key) then
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
        return self:getStaffRowCount()
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
    elseif list == self.suppliesTable then
        return #self.suppliesRows
    elseif list == self.suppliesDetailTable then
        return #self.suppliesDetailRows
    elseif list == self.workshopTable then
        return #self.workshopJobs
    elseif list == self.workshopDetailTable then
        return #self.workshopDetailRows
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
    elseif list == self.suppliesTable then
        self:populateSupplyCell(index, cell)
        return
    elseif list == self.suppliesDetailTable then
        self:populateSupplyDetailCell(index, cell)
        return
    elseif list == self.workshopTable then
        self:populateWorkshopCell(index, cell)
        return
    elseif list == self.workshopDetailTable then
        self:populateWorkshopDetailCell(index, cell)
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

    cell:getAttribute("jobType"):setText(job:getListTitle())

    cell:getAttribute("field"):setText(job:getListFieldText())

    cell:getAttribute("targetDate"):setText(formatTargetDate(job.targetPeriod, job.targetDayInPeriod))
    cell:getAttribute("price"):setText(MenuContractor.getJobPriceText(job))

    -- Live, same reasoning as updateInboxDetails.
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    local chip, chipText = cell:getAttribute("equipmentChip"), cell:getAttribute("equipmentChipText")
    -- 100: a workshop job needs ADS's tools, not machines of ours. 102: it
    -- has to be inspected first, and missing tools only mean subcontracting.
    local canDo
    if TheContractorRepairContracts.isFavourJob(job) then
        -- 116: nothing to inspect first, and no kit: it's fitted by hand.
        canDo = TheContractorJobs.getAcceptProblem(job) == nil
    elseif job:isWorkshop() then
        local vehicle = TheContractorRepairContracts.getVehicle(job)
        if vehicle ~= nil and not TCADSRepairContracts.isInspected(vehicle) then
            setChip(chip, chipText, g_i18n:getText("tc_repair_chipInspect"), "warn")
            return
        end
        -- Replace-only for want of an upgrade: "Part".
        local coverage = vehicle ~= nil and not TheContractorRepairContracts.isBreakdownJob(job) and
            MenuContractor.getKitCoverage(TCADSRepairContracts.getFarmPlan(vehicle, job.farmId)) or nil
        if coverage == "partial" and TheContractorJobs.getAcceptProblem(job) == nil then
            setChip(chip, chipText, g_i18n:getText("tc_repair_chipPartial"), "warn")
            return
        end
        canDo = TheContractorJobs.getAcceptProblem(job) == nil and TheContractorRepairContracts.getToolsWarning(job) == nil
    else
        canDo = jobDef == nil or g_currentMission.TheContractor.JobGeneration:canFulfill(g_currentMission:getFarmId(),
            jobDef, job:getFruitTypeIndex())
    end
    if canDo then
        setChip(chip, chipText, g_i18n:getText("tc_inbox_equipmentYes"), "good")
    else
        setChip(chip, chipText, g_i18n:getText("tc_inbox_equipmentNo"), "bad")
    end
end

function MenuContractor:onListSelectionChanged(list, section, index)
    if list == self.calendarDayTable then
        local row = self.calendarDayRows[index]
        -- The pickers' focus links keep a gamepad off this list while
        -- allocating, but a mouse can still pick a day. Another day closes
        -- the allocation properly; the same day (a reload re-raising this)
        -- leaves it alone.
        if self.allocatingJobId ~= nil then
            if row ~= nil and row.day == self.selectedCalendarDay then
                return
            end
            self.allocatingJobId = nil
            self.calendarCompletedContainer:setVisible(true)
        end
        self.selectedCalendarDay = row ~= nil and row.day or nil
        self:updateCalendarDayDetails()
        return
    end

    if list == self.calendarDayJobsTable then
        local job = self.calendarDayJobs[index]
        self.selectedCalendarDayJobId = job ~= nil and job.id or nil
        self:updateCalendarDayJobNote()
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
        elseif self.staffView == "others" then
            local row = self.personRows[index]
            self.selectedPersonId = row ~= nil and row.person.id or nil
        else
            local worker = self.rosterWorkers[index]
            self.selectedRosterWorkerId = worker ~= nil and worker.id or nil
            -- 090: past the workers, an office row.
            local officeRow = worker == nil and self.officeRows[index - #self.rosterWorkers] or nil
            self.selectedOfficeRole = officeRow ~= nil and officeRow.role or nil
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

    -- Supplies (064): the list redraws the detail panel; the detail list
    -- is only there to scroll.
    if list == self.suppliesTable then
        local row = self.suppliesRows[index]
        self.selectedSupplyKey = row ~= nil and row.key or nil
        self:updateSupplyDetails()
        return
    end

    if list == self.suppliesDetailTable then
        return
    end

    -- Workshop (100): the same, for the highlighted job.
    if list == self.workshopTable then
        local job = self.workshopJobs[index]
        self.selectedWorkshopJobId = job ~= nil and job.id or nil
        self:updateWorkshopJobDetails()
        return
    end

    if list == self.workshopDetailTable then
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
            TCCalendar.formatYear(year, period)))
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
            if job.state == TheContractorJob.STATE.ACCEPTED and not job:isWorkshop() then
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

    cell:getAttribute("jobType"):setText(job:getListTitle())

    cell:getAttribute("field"):setText(job:getListFieldText())

    cell:getAttribute("completed"):setText(formatCompletedAt(job.completedAt))

    local chip, chipText = cell:getAttribute("qualityChip"), cell:getAttribute("qualityChipText")
    if job.qualityScore ~= nil then
        setChip(chip, chipText, string.format("%d%%", job.qualityScore), getQualityChipTone(job.qualityScore))
    else
        setChip(chip, chipText, "-", "neutral")
    end
end

-- Who did it: the player who took it on (093), or the worker(s) by name.
-- A worker released since is no longer on the roster, so they're shown as
-- a former employee.
function MenuContractor:getCompletedJobCrewText(job)
    local workerIds = job:getWorkerIds()
    if #workerIds == 0 then
        return job:getPlayerName()
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

    cell:getAttribute("jobType"):setText(job:getListTitle())

    -- How many people the job takes: 2 for harvest & haul (035), "Player"
    -- for work only a player can do. getJobCrewText has the long form.
    if TheContractorJobGeneration.isPlayerOnly(job) then
        cell:getAttribute("crew"):setText(g_i18n:getText("tc_calendar_crewPlayer"))
    else
        cell:getAttribute("crew"):setText(tostring(TheContractorAllocation.getRequiredWorkerCount(job)))
    end

    cell:getAttribute("field"):setText(job:getListFieldText())

    cell:getAttribute("price"):setText(g_i18n:formatMoney(job:getPrice(), 0, true, true))

    local chipText, chipTone = self:getJobStatusChip(job)
    setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"), chipText, chipTone)
end

-- 093: longer names would shrink to nothing in a chip.
local CHIP_NAME_MAX_CHARS = 22

local function shortenName(name)
    if utf8Strlen == nil or utf8Substr == nil or utf8Strlen(name) <= CHIP_NAME_MAX_CHARS then
        return name
    end
    return utf8Substr(name, 0, CHIP_NAME_MAX_CHARS - 1) .. "..."
end

-- A calendar job's status chip text and tone (also 093's Job details).
-- Allocated vs not-yet-allocated (Q25) — selecting a row in the day's job
-- list just moves selectedCalendarDayJobId (see onListSelectionChanged);
-- the actual allocation flow (018) is reached via the Allocate bottom-bar
-- button that appears whenever the selected job is still `accepted` (see
-- getMenuButtonInfo/onClickOpenAllocation), not a button in this list.
-- Missed (024, scoped down — see TheContractorJobs:missJob) is its own
-- distinct "Failed" chip rather than folding into either bucket — it's
-- neither waiting on allocation nor successfully allocated, it's over
-- and done with. A hired worker's job then reads Allocated (info) ->
-- Travelling (info, Dispatch's transport wait) -> In progress (good)
-- with the same live percentage the Overview's current-jobs list shows.
-- On hold for supplies (032) beats every other working state: nothing
-- moves until the player restocks (or empties the wrong product out).
-- A player-driven job (never `in_progress`) shows its player's name
-- rather than "Allocated" (093).
function MenuContractor:getJobStatusChip(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if job.state == TheContractorJob.STATE.MISSED then
        return g_i18n:getText("tc_calendar_jobMissed"), "bad"
    elseif job:isWaitingForSupplies() and (job.state == TheContractorJob.STATE.ALLOCATED or
            job.state == TheContractorJob.STATE.IN_PROGRESS) then
        return job:getSupplyStatusText(), "warn"
    elseif job.spill ~= nil and (job.state == TheContractorJob.STATE.ALLOCATED or
            job.state == TheContractorJob.STATE.IN_PROGRESS) then
        -- 106: urgent, and what's left to do.
        return TheContractorCropSpill.getStatusText(job), "bad"
    elseif job.yardDelivery ~= nil and (job.state == TheContractorJob.STATE.ALLOCATED or
            job.state == TheContractorJob.STATE.IN_PROGRESS) then
        -- 124: how much is in the farmer's drop area.
        return TheContractorYardBales.getStatusText(job), "good"
    elseif TheContractorRepairContracts.isFavourJob(job) and (job.state == TheContractorJob.STATE.OFFERED or
            job.state == TheContractorJob.STATE.NEGOTIATING) then
        -- 116: asked, not to be priced.
        return g_i18n:getText("tc_favour_chipAsked"), "info"
    elseif job:isWorkshop() and (job.state == TheContractorJob.STATE.OFFERED or
            job.state == TheContractorJob.STATE.NEGOTIATING) then
        -- 102: an offer's first to be inspected, then priced.
        local vehicle = TheContractorRepairContracts.getVehicle(job)
        if vehicle ~= nil and TCADSRepairContracts.isInspected(vehicle) then
            return g_i18n:getText("tc_repair_chipReadyToQuote"), "good"
        end
        return g_i18n:getText("tc_repair_chipNotInspected"), "warn"
    elseif job.state == TheContractorJob.STATE.ACCEPTED and job:isWorkshop() then
        -- 100: ADS's live view of the customer's machine.
        local vehicle = TheContractorRepairContracts.getVehicle(job)
        local status = vehicle ~= nil and TCADSRepairContracts.getStatus(vehicle) or nil
        if status ~= nil and status.state == TCADSRepairContracts.STATE.TAMPERED then
            return g_i18n:getText("tc_repair_chipTampered"), "bad"
        end
        -- How far it's got ("2 of 5 serviced"), so the Calendar and the
        -- Overview say what's left.
        local progressText = vehicle ~= nil and MenuContractor.getWorkshopProgressText(job, vehicle) or nil
        if progressText ~= nil then
            return progressText, "info"
        end
        -- 101: still out in its field.
        if TheContractorRepairContracts.isBreakdownJob(job) then
            return g_i18n:getText("tc_breakdown_chipBrokenDown"), "info"
        elseif TheContractorRepairContracts.isFavourJob(job) then
            return g_i18n:getText("tc_favour_chipAtFarm"), "info"
        end
        return g_i18n:getText("tc_repair_chipInWorkshop"), "info"
    elseif job.state == TheContractorJob.STATE.ACCEPTED then
        return g_i18n:getText("tc_calendar_jobUnallocated"), "warn"
    elseif job.state == TheContractorJob.STATE.IN_PROGRESS then
        return string.format(g_i18n:getText("tc_calendar_jobInProgress"), math.floor(job.completionPercentage)),
            "good"
    elseif job.isTravelling then
        return g_i18n:getText("tc_calendar_jobTravelling"), "info"
    elseif job:needsPlayerDelivery() and job.requiredLiters > 0 and job.state == TheContractorJob.STATE.ALLOCATED then
        -- Player-driven haulage (035): cut and delivered, both - or for a
        -- straw delivery (067), just delivered.
        local delivered = math.floor(100 * job.deliveredLiters / job.requiredLiters)
        if jobDef ~= nil and jobDef.deliveryOnly then
            return string.format(g_i18n:getText("tc_calendar_jobDeliveringOnly"), delivered), "good"
        end
        local key = jobDef ~= nil and jobDef.deliversBales and "tc_calendar_jobBalingDelivering" or
            "tc_calendar_jobDelivering"
        return string.format(g_i18n:getText(key), math.floor(job.completionPercentage), delivered), "good"
    elseif job:isPlayerDriven() then
        return shortenName(job:getPlayerName()), "player"
    end
    return g_i18n:getText("tc_calendar_jobAllocated"), "info"
end

-- Job details (093) ------------------------------------------------------

-- A hired crew's names, "Tom Smith" or "Tom Smith and Ann Jones".
local function getCrewNames(job)
    local staff = g_currentMission.TheContractor.Staff
    local names = {}
    for _, workerId in ipairs(job:getWorkerIds()) do
        local worker = staff:getWorker(job.farmId, workerId)
        table.insert(names, worker ~= nil and worker.name or g_i18n:getText("tc_calendar_formerWorker"))
    end
    if #names == 2 then
        return string.format(g_i18n:getText("tc_unallocate_crewPair"), names[1], names[2])
    end
    return table.concat(names, ", ")
end

function MenuContractor:onClickJobDetails()
    local job = self:getSelectedCalendarDayJob()
    if job == nil or (job.state == TheContractorJob.STATE.ACCEPTED and not job:isWorkshop()) then
        return
    end
    -- 100: a workshop job still being worked on has its checklist in the
    -- Workshop tab.
    if job.state == TheContractorJob.STATE.ACCEPTED and job:isWorkshop() and TCADSRepairContracts.isActive() then
        self:showWorkshopJob(job.id)
        return
    end
    TCJobDetailsDialog.show(job.farmId, job.id, {
        getRows = function(detailJob)
            return self:getJobDetailRows(detailJob)
        end,
        getUnallocateText = function(detailJob)
            return self:getUnallocateText(detailJob)
        end,
        -- Same "synchronous for host/SP, catches up on the next refresh for
        -- a remote client" caveat as sendAllocation.
        onUnallocated = function()
            self:refreshCalendarState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Jobs)
            self:focusCalendarDayJobs()
        end,
    })
end

-- 094: the Unallocate confirm, saying what taking this crew off will cost,
-- worked out from synced state so it reads the same on a client: nothing
-- for a player; for a hired crew, nothing if they're still in the yard, a
-- trip back for the kit if they're on their way, a cooldown if they've
-- made a start (the same rule as a missed job's release). A new crew
-- always has to travel out. A deadline today or tomorrow adds a warning.
function MenuContractor:getUnallocateText(job)
    local text
    if job:isPlayerDriven() then
        text = string.format(g_i18n:getText("tc_unallocate_confirmPlayer"), job:getPlayerName())
    else
        local crew = getCrewNames(job)
        if job.completionPercentage > 0 then
            local minutes = TheContractorCooldown.getBufferDurationMs(job) / 60000
            text = string.format(g_i18n:getText("tc_unallocate_confirmWorking"), crew,
                math.floor(job.completionPercentage), TheContractorJob.formatMinutes(minutes))
        elseif job.isTravelling or job.state == TheContractorJob.STATE.IN_PROGRESS then
            text = string.format(g_i18n:getText("tc_unallocate_confirmOut"), crew)
        else
            text = string.format(g_i18n:getText("tc_unallocate_confirmYard"), crew)
        end
    end

    local daysLeft = job.deadlineDay ~= nil and job.deadlineDay - g_currentMission.environment.currentMonotonicDay or nil
    if daysLeft ~= nil and daysLeft <= 0 then
        text = text .. " " .. g_i18n:getText("tc_unallocate_dueToday")
    elseif daysLeft == 1 then
        text = text .. " " .. g_i18n:getText("tc_unallocate_dueTomorrow")
    end
    return text
end

local function getVehicleRows(vehicleIds)
    local rows = {}
    for _, vehicleId in ipairs(vehicleIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil then
            local category = TCEquipmentClass.getCategory(vehicle)
            table.insert(rows, {
                label = category ~= nil and TCParkingSlotFilter.getCategoryTitle(category) or "",
                value = vehicle:getFullName(),
            })
        end
    end
    return rows
end

-- The Job details dialog's rows for a job, worked out afresh on each of
-- its refreshes: { section } titles and { label, value, chip?, tone? }
-- pairs (isHeading for a bold label heading the rows under it). Everything
-- here is synced job state, so a client sees the same.
function MenuContractor:getJobDetailRows(job)
    local rows = {}
    local function add(label, value, chip, tone, isHeading)
        table.insert(rows, { label = label, value = value or "", chip = chip, tone = tone, isHeading = isHeading })
    end

    table.insert(rows, { section = g_i18n:getText("tc_jobDetails_sectionJob") })
    add(g_i18n:getText("tc_jobDetails_job"), job:getDisplayTitle())
    local placeKey = job:isWorkshop() and "tc_jobDetails_machine" or "tc_jobDetails_field"
    -- 124, 126: a farmer's yard.
    if job:isYardJob() then
        placeKey = "tc_jobDetails_place"
    end
    add(g_i18n:getText(placeKey), job:getLocationText())
    -- 112: none for an ADS repair contract (110).
    local customer = job:getCustomer()
    if customer ~= nil then
        add(g_i18n:getText("tc_jobDetails_customer"), MenuContractor.getCustomerText(customer))
        -- 113: its own row, since a chip sits where the value would.
        local chipText, chipTone = MenuContractor.getRelationshipChip(customer)
        add(g_i18n:getText("tc_people_detailRelationship"), "", chipText, chipTone)
    end
    add(g_i18n:getText("tc_jobDetails_due"), formatTargetDate(job.targetPeriod, job.targetDayInPeriod))
    if MenuContractor.isPriceToAgree(job) then
        -- 102: no price until the customer's agreed one.
        add(g_i18n:getText("tc_jobDetails_price"), "", g_i18n:getText("tc_repair_priceToAgree"), "warn")
    else
        add(g_i18n:getText("tc_jobDetails_price"), MenuContractor.getJobPriceText(job))
    end
    local chipText, chipTone = self:getJobStatusChip(job)
    add(g_i18n:getText("tc_jobDetails_status"), "", chipText, chipTone)
    -- 100: the customer's machine, not crew and kit. Never its faults by
    -- name (they're found by inspecting it, 099).
    if job:isWorkshop() then
        self:addWorkshopDetailRows(job, add, function(key)
            table.insert(rows, { section = g_i18n:getText(key) })
        end)
        return rows
    end
    add(g_i18n:getText("tc_jobDetails_progress"), string.format("%d%%", math.floor(job.completionPercentage)))
    if job.yardHaul ~= nil then
        -- 126: the farmer's load, where it's sold and how much is in.
        add(g_i18n:getText("tc_jobDetails_delivery"), TheContractorYardHaul.getDeliveryText(job))
    elseif job.includesHaulage and job.deliveryStationName ~= nil then
        local value = job.deliveryStationName
        if job:needsPlayerDelivery() and job.requiredLiters > 0 then
            value = string.format(g_i18n:getText("tc_jobDetails_deliveryProgress"), job.deliveryStationName,
                math.floor(100 * job.deliveredLiters / job.requiredLiters))
        end
        add(g_i18n:getText("tc_jobDetails_delivery"), value)
    end
    -- 124: what the farmer's asked for, and how much is in.
    if job.yardDelivery ~= nil then
        add(g_i18n:getText("tc_jobDetails_delivery"), TheContractorYardBales.getDeliveryText(job))
    end

    table.insert(rows, { section = g_i18n:getText("tc_jobDetails_sectionCrew") })
    if job:isPlayerDriven() then
        add(g_i18n:getText("tc_jobDetails_player"), job:getPlayerName())
    else
        local staff = g_currentMission.TheContractor.Staff
        local function workerName(workerId)
            local worker = staff:getWorker(job.farmId, workerId)
            return worker ~= nil and worker.name or g_i18n:getText("tc_calendar_formerWorker")
        end
        if job.haulerWorkerId ~= nil then
            add(g_i18n:getText("tc_jobDetails_operator"), workerName(job.assignedWorkerId))
            add(g_i18n:getText("tc_jobDetails_hauler"), workerName(job.haulerWorkerId))
        else
            add(g_i18n:getText("tc_jobDetails_worker"), workerName(job.assignedWorkerId))
        end
    end

    local equipmentRows = getVehicleRows(job.assignedEquipmentIds)
    if #equipmentRows > 0 then
        table.insert(rows, { section = g_i18n:getText("tc_jobDetails_sectionEquipment") })
        for _, row in ipairs(equipmentRows) do
            table.insert(rows, row)
        end
    end
    local haulageRows = getVehicleRows(job.haulageEquipmentIds)
    if #haulageRows > 0 then
        table.insert(rows, { section = g_i18n:getText("tc_jobDetails_sectionHaulage") })
        for _, row in ipairs(haulageRows) do
            table.insert(rows, row)
        end
    end

    return rows
end

-- 100: a workshop job's rows in the Workshop tab: the work, what ADS finds
-- worse than it arrived, then the checklist under its own section. 102:
-- then every way to fix each fault found so far against the farm's kit,
-- and once it's all known, the farm's own cheapest plan. What counts as
-- done is the tab's paragraph above the rows (getWorkshopDoneWhenText): too
-- long for a row.
function MenuContractor:addWorkshopDetailRows(job, add, addSection)
    local workshop = job.workshop
    local isBreakdown = TheContractorRepairContracts.isBreakdownJob(job)
    -- 116: a favour's the part, fitted by hand, and nothing to price.
    local isFavour = TheContractorRepairContracts.isFavourJob(job)
    add(g_i18n:getText("tc_repair_detailWork"), "",
        g_i18n:getText("tc_repair_kindChip_" .. TheContractorRepairContracts.getWorkKey(job)), "info")
    if isFavour then
        -- 116: the part as a chip, and the size the machine takes.
        add(g_i18n:getText("tc_favour_detailPart"), TheContractorFarmerFavours.getPartSizeText(job) or "",
            TheContractorFarmerFavours.getPartTitle(job), "info")
    end
    if isBreakdown then
        -- 101: the kit to fix it on the spot, not workshop tools.
        local hasKit = TheContractorRepairContracts.hasBreakdownKit(job.farmId, workshop.serviceLevel)
        add(g_i18n:getText("tc_repair_detailTools"), g_i18n:getText("tc_breakdown_kit_" ..
            TheContractorRepairContracts.getBreakdownKitKey(workshop.serviceLevel)),
            g_i18n:getText(hasKit and "tc_repair_chipAvailable" or "tc_repair_chipMissing"),
            hasKit and "good" or "bad")
    end
    local isService = workshop.kind == "maintenance"

    local vehicle = TheContractorRepairContracts.getVehicle(job)
    if vehicle == nil or job:isTerminal() then
        return
    end
    local problem = TheContractorJobs.getAcceptProblem(job)
    if problem ~= nil then
        add("", problem, g_i18n:getText("tc_inbox_equipmentStatusMissing"), "bad")
    end
    local tampered, findings = TCADSRepairContracts.checkTampering(vehicle)
    if tampered then
        add(g_i18n:getText("tc_repair_detailTampered"), string.format(g_i18n:getText("tc_repair_tamperedValue"),
            #(findings or {})), g_i18n:getText("tc_repair_chipTampered"), "bad")
    end
    local farmPlan = TCADSRepairContracts.getFarmPlan(vehicle, job.farmId)
    addSection("tc_workshop_sectionChecklist")
    self:addWorkshopProgressRows(vehicle, isService, add, farmPlan, isFavour)
    if not isFavour then
        self:addWorkshopPlanRows(job, farmPlan, add, addSection)
    end
end

-- 102: how a fault still to do can be fixed with the farm's own kit, as a
-- chip and (when it's short of something) what for: "Repair or replace",
-- "Repair", "Replace" (with "Repair needs Machine tools" when an upgrade
-- would allow a repair) or "Subcontract" ("needs ..."). nil without ADS's
-- options for it.
function MenuContractor.getFaultMethod(fault)
    if fault == nil then
        return nil
    end
    local rows = TCADSRepairContracts.getFaultChecklist(fault)
    local repair, replace = rows[1], rows[2]
    local canRepair, canReplace = repair.status == "available", replace.status == "available"
    if canRepair and canReplace then
        return g_i18n:getText("tc_repair_methodChip_repairOrReplace"), "good", ""
    elseif canRepair then
        return g_i18n:getText("tc_repair_methodChip_repair"), "good", ""
    elseif canReplace then
        if repair.status == "missing" and #repair.missing > 0 then
            return g_i18n:getText("tc_repair_methodChip_replacement"), "warn",
                string.format(g_i18n:getText("tc_repair_repairNeeds"), TCADSRepairContracts.getUpgradeNames(repair.missing))
        end
        return g_i18n:getText("tc_repair_methodChip_replacement"), "good", ""
    end
    local missing = repair.status == "missing" and repair.missing or replace.missing
    return g_i18n:getText("tc_repair_chipSubcontract"), "bad", #missing > 0 and
        string.format(g_i18n:getText("tc_repair_fixNeeds"), TCADSRepairContracts.getUpgradeNames(missing)) or ""
end

local function formatHours(hours)
    return string.format(g_i18n:getText("tc_repair_hours"), hours or 0)
end

-- 102: for each fault found so far, every way to fix it (an Available /
-- Missing / Not possible chip, then any kit it lacks and its part), then once the
-- job's all known, the farm's cheapest plan: whether a full repair is
-- possible, the parts against the cheapest fix's, and the profit or loss at
-- the usual margin (or the agreed price). ADS's prices, at the day the job
-- came in.
function MenuContractor:addWorkshopPlanRows(job, farmPlan, add, addSection)
    if farmPlan == nil then
        return
    end
    local function money(amount)
        return g_i18n:formatMoney(amount, 0, true, true)
    end

    -- A row per fault, then one per way to fix it: its kit (or what's
    -- missing) and parts, and a chip saying whether the farm can.
    if #farmPlan.faults > 0 then
        addSection("tc_workshop_sectionOptions")
        local lastFault = nil
        for _, entry in ipairs(MenuContractor.getFaultChecklistRows(farmPlan)) do
            if entry.fault ~= lastFault then
                lastFault = entry.fault
                add(TCADSRepairContracts.getText(entry.fault.nameKey), "",
                    entry.fault.done and g_i18n:getText("tc_repair_chipFixed") or nil, entry.fault.done and "good" or nil,
                    true)
            end
            local row = entry.row
            if row ~= nil then
                -- Only what's short is named: kit the farm has goes unsaid.
                local value = ""
                if row.status ~= "notPossible" then
                    local parts = {}
                    if row.status == "missing" and #row.missing > 0 then
                        table.insert(parts, MenuContractor.getFixKitText(row))
                    end
                    if row.partsCost > 0 then
                        table.insert(parts, string.format(g_i18n:getText("tc_repair_optionPart"), money(row.partsCost)))
                    end
                    value = table.concat(parts, ", ")
                end
                local status = MenuContractor.FIX_STATUS_CHIPS[row.status]
                add(g_i18n:getText("tc_repair_option_" .. row.operation), value, g_i18n:getText(status.key),
                    status.tone)
            end
        end
    end

    local plan = farmPlan.plan
    if plan == nil then
        return
    end
    addSection("tc_workshop_sectionPlan")
    local factor = TCEconomyScale.getFactor()
    -- Whether every fault can be repaired rather than replaced (where ADS
    -- allows a repair), and what's stopping it.
    if #farmPlan.faults > 0 then
        local needs = farmPlan.repairNeeds or {}
        if #needs > 0 then
            add(g_i18n:getText("tc_repair_planFullRepair"), string.format(g_i18n:getText("tc_repair_fixNeeds"),
                TCADSRepairContracts.getUpgradeNames(needs)), g_i18n:getText("tc_repair_chipNotPossible"), "bad")
        else
            add(g_i18n:getText("tc_repair_planFullRepair"), "", g_i18n:getText("tc_repair_chipPossible"), "good")
        end
    end
    -- What the farm lacks for the faults it can't fix any way (so they're
    -- subcontracted): a row per upgrade, its name as the chip.
    if not plan.canDo then
        for i, name in ipairs(TCADSRepairContracts.getUpgradeNameList(farmPlan.missing)) do
            add(i == 1 and g_i18n:getText("tc_repair_planMissing") or "", "", name, "bad")
        end
    end
    -- The parts the price is worked out on (the cheapest fix's) against the
    -- farm's own, with a chip when replacing costs it more.
    local cheapestParts = (job.workshop.baseParts or job.workshop.partsCost or 0) * factor
    add(g_i18n:getText("tc_repair_planPartsCheapest"), money(cheapestParts))
    if plan.partsCost > cheapestParts + 0.5 then
        add(g_i18n:getText("tc_repair_planParts"), money(plan.partsCost), g_i18n:getText("tc_repair_chipReplacing"),
            "warn")
    else
        add(g_i18n:getText("tc_repair_planParts"), money(plan.partsCost))
    end
    add(g_i18n:getText("tc_repair_planHours"), formatHours(plan.laborHours))
    if plan.subcontractCost > 0 then
        add(g_i18n:getText("tc_repair_planSubcontract"), money(plan.subcontractCost),
            g_i18n:getText("tc_repair_chipSubcontract"), "warn")
    end

    -- The price, and what's left of it after the plan's parts and
    -- subcontracting: at the usual margin while it's still to price, else
    -- at the agreed price.
    local price, priceLabel, profitLabel
    if job.state == TheContractorJob.STATE.OFFERED or job.state == TheContractorJob.STATE.NEGOTIATING then
        local benchmark = TheContractorRepairContracts.getJobBenchmark(job)
        local percent = math.floor(benchmark * 100 + 0.5)
        add(g_i18n:getText("tc_repair_planCost"), money(TheContractorRepairContracts.getJobBaseCost(job) * factor))
        price = TheContractorRepairContracts.getPriceForMargin(job, benchmark)
        priceLabel = string.format(g_i18n:getText("tc_repair_planBenchmarkPrice"), percent)
        profitLabel = string.format(g_i18n:getText("tc_repair_planBenchmarkProfit"), percent)
    else
        price = job:getPrice()
        priceLabel = g_i18n:getText("tc_repair_planAgreedPrice")
        profitLabel = g_i18n:getText("tc_repair_planAgreedProfit")
    end
    add(priceLabel, money(price))
    local profit = price - plan.partsCost - plan.subcontractCost
    add(profitLabel, money(profit), g_i18n:getText(profit < 0 and "tc_repair_chipLoss" or "tc_repair_chipProfit"),
        profit < 0 and "bad" or "good")
end

-- What a workshop job needs before it's paid, in a sentence or three.
-- 102: an offer's, what to do before it can be priced.
function MenuContractor.getWorkshopDoneWhenText(job)
    if job.state == TheContractorJob.STATE.OFFERED or job.state == TheContractorJob.STATE.NEGOTIATING then
        return MenuContractor.getWorkshopPendingText(job)
    end
    if TheContractorRepairContracts.isFavourJob(job) then
        return string.format(g_i18n:getText("tc_favour_doneWhen"), TheContractorFarmerFavours.getPartText(job),
            job:getCustomerName() or "?")
    elseif TheContractorRepairContracts.isBreakdownJob(job) then
        return g_i18n:getText("tc_repair_doneWhen_breakdown")
    end
    return g_i18n:getText(job.workshop.kind == "maintenance" and "tc_repair_doneWhen_maintenance" or
        "tc_repair_doneWhen_repair")
end

-- A workshop job's progress in a few words, for its status chip: "2 of 5
-- serviced", "1 fixed so far" while a fault may still be hidden, or "Not
-- inspected" before anything's found. nil without ADS's view of it.
function MenuContractor.getWorkshopProgressText(job, vehicle)
    -- 116: a favour's farmer has said what's wrong.
    local progress = TCADSRepairContracts.getProgress(vehicle, TheContractorRepairContracts.isFavourJob(job))
    if progress == nil then
        return nil
    end
    if progress.total ~= nil then
        local key = job.workshop.kind == "maintenance" and "tc_repair_progressServiced" or "tc_repair_progressFixed"
        return string.format(g_i18n:getText(key), progress.fixed, progress.total)
    elseif progress.fixed > 0 then
        return string.format(g_i18n:getText("tc_repair_progressSoFar"), progress.fixed)
    end
    return g_i18n:getText("tc_repair_progressNotInspected")
end

-- The contract's progress, live from ADS: how much is done (no count while
-- a fault is still hidden), then a checklist of every known fault or
-- consumable, what's left first. Nothing for a fault nobody's found (099).
-- 102: each row's chip says what to do: for a fault, how the farm's kit can
-- fix it (getFaultMethod: "Repair or replace", "Replace" with "Repair needs
-- ..."), for a consumable the service it needs; a done one, Fixed or
-- Serviced.
function MenuContractor:addWorkshopProgressRows(vehicle, isService, add, farmPlan, allKnown)
    local progress = TCADSRepairContracts.getProgress(vehicle, allKnown)
    if progress == nil then
        return
    end
    if progress.total ~= nil then
        add(g_i18n:getText("tc_jobDetails_progress"), string.format(g_i18n:getText(isService and
            "tc_repair_progressServiced" or "tc_repair_progressFixed"), progress.fixed, progress.total))
    elseif progress.fixed > 0 then
        add(g_i18n:getText("tc_jobDetails_progress"), string.format(g_i18n:getText("tc_repair_progressSoFar"),
            progress.fixed), g_i18n:getText("tc_repair_chipInspectAgain"), "warn")
    else
        add(g_i18n:getText("tc_jobDetails_progress"), "", g_i18n:getText("tc_repair_chipNotInspected"), "warn")
    end

    local faultsById = {}
    for _, fault in ipairs(farmPlan ~= nil and farmPlan.faults or {}) do
        faultsById[fault.id] = fault
    end
    for _, done in ipairs({ false, true }) do
        for _, item in ipairs(progress.items) do
            if item.done == done then
                local name = TCADSRepairContracts.getText(item.nameKey)
                if done then
                    add(name, "", g_i18n:getText(item.kind == "consumable" and "tc_repair_chipServiced" or
                        "tc_repair_chipFixed"), "good")
                else
                    local chip, tone, value = nil, "info", ""
                    if item.kind == "fault" then
                        chip, tone, value = MenuContractor.getFaultMethod(faultsById[item.id])
                    end
                    if chip == nil then
                        chip, tone, value = g_i18n:getText("tc_repair_methodChip_" .. item.operation), "info", ""
                    end
                    if item.grade ~= nil then
                        value = string.format(g_i18n:getText("tc_favour_partSize"), item.grade)
                    end
                    add(name, value, chip, tone)
                end
            end
        end
    end
end

-- Workshop (100) -----------------------------------------------------------

-- The Workshop list's views, in workshopViewSelector's order.
MenuContractor.WORKSHOP_VIEWS = { "current", "pending", "completed" }
MenuContractor.WORKSHOP_VIEW_TEXTS = {
    current = { view = "tc_workshop_viewCurrent", date = "tc_workshop_columnDue",
        status = "tc_workshop_columnProgress", empty = "tc_workshop_empty" },
    -- 102: offers still to be inspected and priced.
    pending = { view = "tc_workshop_viewPending", date = "tc_workshop_columnDue",
        status = "tc_workshop_columnInspection", empty = "tc_workshop_emptyPending" },
    completed = { view = "tc_workshop_viewCompleted", date = "tc_workshop_columnCompleted",
        status = "tc_workshop_columnProfit", empty = "tc_workshop_emptyCompleted" },
}
-- The farm's ADS repair contracts being worked on (accepted), soonest due
-- first; in the Pending view (102) the offers, to be inspected and priced;
-- or, in the Completed view, the newest finished ones (completed or
-- missed), as many as the save keeps (TheContractorJobs.KEEP_FINISHED_JOBS).
function MenuContractor:buildWorkshopJobs(farmId)
    local workshopJobs = {}
    local jobs = g_currentMission.TheContractor.Jobs
    if self.workshopView == "completed" then
        for _, state in ipairs({ TheContractorJob.STATE.COMPLETED, TheContractorJob.STATE.MISSED }) do
            for _, job in ipairs(jobs:getJobsByState(farmId, state)) do
                if job:isWorkshop() then
                    table.insert(workshopJobs, job)
                end
            end
        end
        TheContractorJobs.sortNewestFinished(workshopJobs)
        for i = #workshopJobs, TheContractorJobs.KEEP_FINISHED_JOBS + 1, -1 do
            workshopJobs[i] = nil
        end
        return workshopJobs
    end

    -- 102: the Pending view is the offers, the Current one what's agreed.
    local states = self.workshopView == "pending" and
        { TheContractorJob.STATE.OFFERED, TheContractorJob.STATE.NEGOTIATING } or { TheContractorJob.STATE.ACCEPTED }
    for _, state in ipairs(states) do
        for _, job in ipairs(jobs:getJobsByState(farmId, state)) do
            if job:isWorkshop() then
                table.insert(workshopJobs, job)
            end
        end
    end
    table.sort(workshopJobs, function(a, b)
        if (a.deadlineDay or 0) ~= (b.deadlineDay or 0) then
            return (a.deadlineDay or 0) < (b.deadlineDay or 0)
        end
        return a.id < b.id
    end)
    return workshopJobs
end

function MenuContractor:refreshWorkshopState(farmId)
    self.workshopContent:setVisible(true)

    local viewIndex = 1
    local viewTexts = {}
    for i, view in ipairs(MenuContractor.WORKSHOP_VIEWS) do
        if view == self.workshopView then
            viewIndex = i
        end
        table.insert(viewTexts, g_i18n:getText(MenuContractor.WORKSHOP_VIEW_TEXTS[view].view))
    end
    self.workshopView = MenuContractor.WORKSHOP_VIEWS[viewIndex]
    self.workshopViewSelector:setTexts(viewTexts)
    self.workshopViewSelector:setState(viewIndex)

    local texts = MenuContractor.WORKSHOP_VIEW_TEXTS[self.workshopView]
    self.workshopColumnDate:setText(g_i18n:getText(texts.date))
    self.workshopColumnStatus:setText(g_i18n:getText(texts.status))
    self.workshopEmptyText:setText(g_i18n:getText(texts.empty))

    -- reloadData re-raises the selection callback with the old index, so
    -- the wanted job is held on to first (as the Supplies tab does).
    local wantedJobId = self.selectedWorkshopJobId
    self.workshopJobs = self:buildWorkshopJobs(farmId)
    self.workshopTable:reloadData()

    local hasJobs = #self.workshopJobs > 0
    self.workshopListContainer:setVisible(hasJobs)
    self.workshopEmptyText:setVisible(not hasJobs)

    if hasJobs then
        local selectedIndex = 1
        for i, job in ipairs(self.workshopJobs) do
            if job.id == wantedJobId then
                selectedIndex = i
            end
        end
        if self.workshopTable:getSelectedIndexInSection() ~= selectedIndex then
            self.workshopTable:setSelectedIndex(selectedIndex)
        end
        self.selectedWorkshopJobId = self.workshopJobs[selectedIndex].id
    else
        self.selectedWorkshopJobId = nil
    end

    self:updateWorkshopJobDetails()
end

function MenuContractor:onClickWorkshopView()
    self.workshopView = MenuContractor.WORKSHOP_VIEWS[self.workshopViewSelector:getState()] or "current"
    self.selectedWorkshopJobId = nil
    self:refreshWorkshopState(g_currentMission:getFarmId())
end

-- From the Calendar's Job details: the Workshop tab with the job picked.
function MenuContractor:showWorkshopJob(jobId)
    self.workshopView = "current"
    self.selectedWorkshopJobId = jobId
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.WORKSHOP, true)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:getSelectedWorkshopJob()
    for _, job in ipairs(self.workshopJobs) do
        if job.id == self.selectedWorkshopJobId then
            return job
        end
    end
    return nil
end

function MenuContractor:populateWorkshopCell(index, cell)
    local job = self.workshopJobs[index]
    if job == nil then
        return
    end
    cell:getAttribute("machine"):setText(job.workshop.vehicleName or job:getLocationText())
    local isCompleted = job.state == TheContractorJob.STATE.COMPLETED
    local profitCell = cell:getAttribute("profit")
    profitCell:setVisible(isCompleted)
    if isCompleted then
        cell:getAttribute("due"):setText(formatCompletedAt(job.completedAt))
        local _, _, profit = MenuContractor.getWorkshopEarnings(job)
        profitCell:setText(profit ~= nil and g_i18n:formatMoney(profit, 0, true, true) or "-")
        setChip(cell:getAttribute("chip"), cell:getAttribute("chipText"), nil)
        return
    elseif job.state == TheContractorJob.STATE.MISSED then
        -- The day it was due, and a Missed chip where the profit would be.
        cell:getAttribute("due"):setText(formatTargetDate(job.targetPeriod, job.targetDayInPeriod))
        setChip(cell:getAttribute("chip"), cell:getAttribute("chipText"), g_i18n:getText("tc_calendar_jobMissed"),
            "bad")
        return
    end
    cell:getAttribute("due"):setText(formatTargetDate(job.targetPeriod, job.targetDayInPeriod))
    local chipText, chipTone = self:getJobStatusChip(job)
    setChip(cell:getAttribute("chip"), cell:getAttribute("chipText"), chipText, chipTone)
end

-- A completed workshop job's money: the parts in ADS's quote (the cost),
-- what the customer was billed (the parts plus our margin) and the
-- difference, plus the cost's label key. Both at the price level of their
-- day, as they were taken. A job from before the parts were kept (its
-- price was the whole quote plus the margin) uses the quote instead, and
-- one with neither has no cost (and so no profit).
function MenuContractor.getWorkshopEarnings(job)
    local billed = job.paymentAmount or job:getPrice()
    local workshop = job.workshop or {}
    if workshop.partsCost ~= nil then
        return workshop.partsCost, billed, billed - workshop.partsCost, "tc_workshop_partsCost"
    end
    local quote = workshop.quotePrice
    if quote == nil or quote <= 0 then
        return nil, billed, nil, "tc_workshop_estimatedCost"
    end
    return quote, billed, billed - quote, "tc_workshop_estimatedCost"
end

-- The Completed view's rows: the job, then its money. A missed job earned
-- nothing, so it shows what the work would have cost and nothing billed.
function MenuContractor:getCompletedWorkshopRows(job)
    local rows = {}
    local function add(label, value, chip, tone)
        table.insert(rows, { label = label, value = value or "", chip = chip, tone = tone })
    end
    local function money(amount)
        return amount ~= nil and g_i18n:formatMoney(amount, 0, true, true) or "-"
    end

    table.insert(rows, { section = g_i18n:getText("tc_jobDetails_sectionJob") })
    add(g_i18n:getText("tc_jobDetails_job"), job:getDisplayTitle())
    add(g_i18n:getText("tc_jobDetails_machine"), job:getLocationText())
    add(g_i18n:getText("tc_repair_detailWork"), "", g_i18n:getText("tc_repair_kindChip_" ..
        TheContractorRepairContracts.getWorkKey(job)), "info")
    if job.state == TheContractorJob.STATE.MISSED then
        add(g_i18n:getText("tc_jobDetails_due"), formatTargetDate(job.targetPeriod, job.targetDayInPeriod))
        table.insert(rows, { section = g_i18n:getText("tc_workshop_sectionEarnings") })
        local cost, _, _, costKey = MenuContractor.getWorkshopEarnings(job)
        add(g_i18n:getText(costKey), money(cost))
        add(g_i18n:getText("tc_workshop_billedAmount"), g_i18n:getText("tc_workshop_billedNothing"))
        return rows
    end
    add(g_i18n:getText("tc_workshop_columnCompleted"), formatCompletedAt(job.completedAt))
    local turnaround = TheContractorRepairContracts.getTurnaroundMinutes(job)
    if turnaround ~= nil then
        local text = string.format(g_i18n:getText("tc_logbook_hours"), turnaround / 60)
        local speedFactor = TheContractorRepairContracts.getSpeedFactor(job)
        if speedFactor > 1.005 then
            text = string.format(g_i18n:getText("tc_workshop_turnaroundBonus"), text, (speedFactor - 1) * 100)
        end
        add(g_i18n:getText("tc_workshop_turnaround"), text)
    end
    -- 102: the margin it was priced at, and what that did to reputation.
    if job.workshop.margin ~= nil then
        local benchmark = TheContractorRepairContracts.getJobBenchmark(job)
        if TheContractorRepairContracts.isJobMinimumCharge(job) then
            add(g_i18n:getText("tc_workshop_margin"), g_i18n:getText("tc_repairQuote_minimumCharge"))
        else
            add(g_i18n:getText("tc_workshop_margin"), string.format(g_i18n:getText("tc_workshop_marginValue"),
                math.floor(job.workshop.margin * 100 + 0.5), math.floor(benchmark * 100 + 0.5),
                g_i18n:getText("tc_repair_reactionShort_" .. TheContractorRepairContracts.getReaction(job.workshop.margin,
                    benchmark))))
        end
        add(g_i18n:getText("tc_workshop_priceReputation"), string.format("x%.2f",
            TheContractorRepairContracts.getMarginFactor(job)))
    end
    if job.workshop.reputationReward ~= nil then
        add(g_i18n:getText("tc_workshop_reputation"), string.format("%+d", job.workshop.reputationReward))
    end

    local cost, billed, profit, costKey = MenuContractor.getWorkshopEarnings(job)
    table.insert(rows, { section = g_i18n:getText("tc_workshop_sectionEarnings") })
    add(g_i18n:getText(costKey), money(cost))
    add(g_i18n:getText("tc_workshop_billedAmount"), money(billed))
    local profitText = money(profit)
    if profit ~= nil and cost > 0 then
        profitText = string.format("%s (%+.0f%%)", profitText, profit / cost * 100)
    end
    add(g_i18n:getText("tc_workshop_profit"), profitText)
    return rows
end

function MenuContractor:updateWorkshopJobDetails()
    local job = self:getSelectedWorkshopJob()
    self.workshopDetailsBox:setVisible(job ~= nil)
    local isCompleted = job ~= nil and job.state == TheContractorJob.STATE.COMPLETED
    local isMissed = job ~= nil and job.state == TheContractorJob.STATE.MISSED
    if job == nil then
        self.workshopDetailRows = {}
    elseif isCompleted or isMissed then
        self.workshopDetailRows = self:getCompletedWorkshopRows(job)
    else
        self.workshopDetailRows = self:getJobDetailRows(job)
    end
    self.workshopDetailTable:reloadData()
    if job == nil then
        return
    end

    self.workshopDetailTitle:setText(job:getDisplayTitle())
    if isCompleted then
        setChip(self.workshopDetailChip, self.workshopDetailChipText, g_i18n:getText("tc_logbook_completed"), "good")
        local noteKey = job.workshop.partsCost ~= nil and "tc_workshop_earningsNote" or "tc_workshop_earningsNoteQuote"
        -- 116: a favour's billed the part, no more.
        if TheContractorRepairContracts.isFavourJob(job) then
            noteKey = "tc_favour_earningsNote"
        end
        self.workshopDoneWhen:setText(g_i18n:getText(noteKey))
    elseif isMissed then
        setChip(self.workshopDetailChip, self.workshopDetailChipText, g_i18n:getText("tc_calendar_jobMissed"), "bad")
        self.workshopDoneWhen:setText(g_i18n:getText("tc_workshop_missedNote"))
    else
        setChip(self.workshopDetailChip, self.workshopDetailChipText, self:getJobStatusChip(job))
        self.workshopDoneWhen:setText(MenuContractor.getWorkshopDoneWhenText(job))
    end
end

-- 102: a pending offer's paragraph: inspect it, then Negotiate from the
-- Inbox.
function MenuContractor.getWorkshopPendingText(job)
    -- 116: a favour's taken on as it stands.
    if TheContractorRepairContracts.isFavourJob(job) then
        return string.format(g_i18n:getText("tc_favour_pending"), job:getCustomerName() or "?",
            TheContractorFarmerFavours.getPartText(job))
    end
    local vehicle = TheContractorRepairContracts.getVehicle(job)
    if vehicle ~= nil and TCADSRepairContracts.isInspected(vehicle) then
        return g_i18n:getText("tc_repair_pendingInspected")
    end
    if TheContractorRepairContracts.isBreakdownJob(job) then
        return g_i18n:getText("tc_repair_pendingInspect_breakdown")
    end
    return g_i18n:getText("tc_repair_pendingInspect")
end

-- Section titles and label/value rows, a chip at the end of the row.
function MenuContractor:populateWorkshopDetailCell(index, cell)
    local row = self.workshopDetailRows[index]
    if row == nil then
        return
    end
    local isSection = row.section ~= nil
    cell:getAttribute("surface"):setVisible(not isSection)
    cell:getAttribute("section"):setVisible(isSection)
    cell:getAttribute("section"):setText(row.section or "")
    cell:getAttribute("label"):setVisible(not isSection)
    cell:getAttribute("label"):setText(row.label or "")
    -- No setter for it: TextElement reads the field as it draws.
    cell:getAttribute("label").textBold = row.isHeading == true
    -- 102: the chip leads the value column, its text after it.
    local hasChip = not isSection and row.chip ~= nil
    cell:getAttribute("value"):setVisible(not isSection and not hasChip)
    cell:getAttribute("value"):setText(row.value or "")
    cell:getAttribute("valueAfterChip"):setVisible(hasChip)
    cell:getAttribute("valueAfterChip"):setText(row.value or "")
    setChip(cell:getAttribute("chip"), cell:getAttribute("chipText"), hasChip and row.chip or nil, row.tone)
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
    -- Focus stays wherever it was (the tab bar, or the job list that's just
    -- been hidden) unless it's moved, so up/down wouldn't reach the pickers.
    FocusManager:setFocus(self.allocationWorkerTable)
end

function MenuContractor:onClickCancelAllocation()
    self.allocatingJobId = nil
    self.allocationContainer:setVisible(false)
    self.calendarCompletedContainer:setVisible(true)
    self:updateCalendarDayDetails()
    self:setMenuButtonInfoDirty()
    self:focusCalendarDayJobs()
end

-- Once allocation closes: back on the day's job list, or the day list if
-- the day has no jobs to show.
function MenuContractor:focusCalendarDayJobs()
    if self.calendarDayJobsContainer:getIsVisible() then
        FocusManager:setFocus(self.calendarDayJobsTable)
    else
        FocusManager:setFocus(self.calendarDayTable)
    end
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
    self.allocationCrewText:setText(string.format(g_i18n:getText("tc_allocation_crew"), self:getJobCrewText(job)))

    self.allocationWorkerRows = { { workerId = nil, label = g_i18n:getText("tc_allocation_myself") } }
    -- 097: not anyone who's gone home.
    for _, worker in ipairs(staff:getAvailableWorkers(farmId)) do
        table.insert(self.allocationWorkerRows, { workerId = worker.id, label = worker.name })
    end
    self.allocationHighlightedWorkerIndex = 1
    self.allocationWorkerTable:reloadData()
    self.allocationWorkerTable:setSelectedIndex(1)

    self.allocationHighlightedEquipmentIndex = nil
    self:rebuildAllocationEquipmentRows(job)

    self:updateAllocationWorkerHeading(job)
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
            sizeTier = TCEquipmentClass.getSizeTier(vehicle),
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
    if self:isHaulageCrewPicked(job) then
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

-- Workers picked for a haulage job a crew can do (035) - the haulage rig
-- comes into it. Not on a job only the player can do (067's bales), where
-- picking a worker just gets the crew warning.
function MenuContractor:isHaulageCrewPicked(job)
    return job.includesHaulage and not TheContractorJobGeneration.isPlayerOnly(job) and
        #self.allocationSelectedWorkerIds > 0
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
    self:updateAllocationWorkerHeading(job)
    self:updateAllocationWorkerToggleButton()
    self:updateAllocationWarning()
end

-- "Workers (1/2)" against the job's worker count, or "Workers (yourself)"
-- while Myself is the pick.
function MenuContractor:updateAllocationWorkerHeading(job)
    local picked = #self.allocationSelectedWorkerIds
    if picked == 0 then
        self.allocationWorkerLabel:setText(g_i18n:getText("tc_allocation_workerHeadingMyself"))
    else
        self.allocationWorkerLabel:setText(string.format(g_i18n:getText("tc_allocation_workerHeadingCount"), picked,
            TheContractorAllocation.getRequiredWorkerCount(job)))
    end
end

function MenuContractor:isAllocationWorkerRowSelected(row)
    if row.workerId == nil then
        return #self.allocationSelectedWorkerIds == 0
    end
    return table.hasElement(self.allocationSelectedWorkerIds, row.workerId)
end

function MenuContractor:updateAllocationWorkerToggleButton()
    local row = self.allocationWorkerRows[self.allocationHighlightedWorkerIndex]
    local key = "tc_allocation_selectWorkerButton"
    if row ~= nil and row.workerId == nil then
        -- Myself drops any picked workers rather than toggling.
        key = "tc_allocation_selectMyselfButton"
    elseif row ~= nil and self:isAllocationWorkerRowSelected(row) then
        key = "tc_allocation_deselectWorkerButton"
    end
    self.btnAllocateToggleWorker.text = g_i18n:getText(key)
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
        -- One tractor, harvester, trailer... per crew: a second pick of
        -- the same role replaces the first.
        if TheContractorAllocation.SINGLE_ROLES[row.role] then
            for _, other in ipairs(self.allocationEquipmentRows) do
                if other.role == row.role then
                    self.allocationSelectedEquipmentKeys[other.key] = nil
                end
            end
        end
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

-- A tractor size against the picked workers: good if any of them is
-- certified on it (assignCrewRoles puts that one on it), bad if none is,
-- plain info while it's the player alone.
function MenuContractor:getAllocationTierTone(tier)
    local workerIds = self.allocationSelectedWorkerIds
    if #workerIds == 0 then
        return "info"
    end
    local staff = g_currentMission.TheContractor.Staff
    local farmId = g_currentMission:getFarmId()
    for _, workerId in ipairs(workerIds) do
        local worker = staff:getWorker(farmId, workerId)
        if worker ~= nil and worker:getTierCapability(tier) ~= nil then
            return "good"
        end
    end
    return "bad"
end

function MenuContractor:populateAllocationEquipmentCell(index, cell)
    local row = self.allocationEquipmentRows[index]
    if row == nil then
        return
    end

    setAllocationCheckBox(cell:getAttribute("checkBox"), self.allocationSelectedEquipmentKeys[row.key] == true)
    cell:getAttribute("name"):setText(row.label)
    cell:getAttribute("kind"):setText(g_i18n:getText("tc_allocation_role_" .. row.role))
    local sizeChip, sizeChipText = cell:getAttribute("sizeChip"), cell:getAttribute("sizeChipText")
    if row.sizeTier == nil then
        setChip(sizeChip, sizeChipText, nil)
    else
        setChip(sizeChip, sizeChipText, g_i18n:getText("tc_allocation_size_" .. row.sizeTier),
            self:getAllocationTierTone(row.sizeTier))
    end
    -- 062: a machine back from a job that hasn't found a parking space yet.
    local isPending = g_currentMission.TheContractor.Parking:isPending(row.vehicleId)
    setChip(cell:getAttribute("parkingChip"), cell:getAttribute("parkingChipText"),
        isPending and g_i18n:getText("tc_allocation_awaitingParking") or nil, "warn")
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

    local filledHarvester, heldFillType = TheContractorAllocation.getFilledHarvester(equipmentIds)
    if filledHarvester ~= nil then
        return string.format(g_i18n:getText("tc_allocation_filledHarvesterWarning"), filledHarvester:getName(),
            g_fillTypeManager:getFillTypeTitleByIndex(heldFillType) or "?"), true
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

-- 091: the allocation warning with the workshop note under it, if any.
local function withWorkshopNote(text, note)
    if note == nil then
        return text
    end
    return text .. "\n" .. note
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
    if self:isHaulageCrewPicked(job) then
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

    -- 091: anyone picked who works in the ADS workshop leaves it for the
    -- job. A note under whatever else is said.
    local workshopNote = self:getAllocationWorkshopNote(farmId)

    local problem = self:getAllocationProblem(job)
    if problem ~= nil then
        self.allocationWarningText:setText(withWorkshopNote(problem, workshopNote))
        self.allocationWarningText:setTextColor(1, 0.75, 0.25, 1)
    elseif #supplyEntries > 0 and not anySupplyInStock then
        self.allocationWarningText:setText(withWorkshopNote(string.format(
            g_i18n:getText("tc_allocation_noSuppliesWarning"), joinSupplyTitles(supplyEntries)), workshopNote))
        self.allocationWarningText:setTextColor(1, 0.75, 0.25, 1)
    elseif job.includesHaulage and #self.allocationSelectedWorkerIds == 0 then
        -- Player alone on a haulage job: they're doing the carting - the
        -- crop, or (067) the straw bales.
        self.allocationWarningText:setText(string.format(g_i18n:getText(self:getHaulYourselfKey(job)),
            job.deliveryStationName or "?"))
        self.allocationWarningText:setTextColor(1, 1, 1, 1)
    elseif workshopNote ~= nil then
        self.allocationWarningText:setText(workshopNote)
        self.allocationWarningText:setTextColor(1, 1, 1, 1)
    else
        self.allocationWarningText:setText("")
    end
end

-- 091: one line per picked worker ticked into the ADS workshop, or nil.
function MenuContractor:getAllocationWorkshopNote(farmId)
    if not TCADSWorkshop.isActive() then
        return nil
    end
    local staff = g_currentMission.TheContractor.Staff
    local lines = {}
    for _, workerId in ipairs(self.allocationSelectedWorkerIds) do
        local worker = staff:getWorker(farmId, workerId)
        if worker ~= nil and worker.workshopRole ~= nil then
            local roleName = string.lower(TheContractorWorkshop.getRoleName(worker.workshopRole))
            table.insert(lines, string.format(g_i18n:getText("tc_allocation_workshopNote"), worker.name, roleName,
                roleName))
        end
    end
    return #lines > 0 and table.concat(lines, "\n") or nil
end

-- What the player is told they'll be carting on a haulage job they do
-- themselves: the crop (035), the straw they bale, or (straw delivery)
-- bales already lying there (067).
function MenuContractor:getHaulYourselfKey(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    -- 126: a farmer's trailer load.
    if job.yardHaul ~= nil then
        return "tc_allocation_sellLoadYourself"
    elseif jobDef ~= nil and jobDef.deliveryOnly then
        return "tc_allocation_deliverStrawYourself"
    elseif jobDef ~= nil and jobDef.deliversBales then
        return "tc_allocation_baleAndDeliverYourself"
    end
    return "tc_allocation_haulYourself"
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

    local workerIds = self.allocationSelectedWorkerIds
    local equipmentIds = self:getSelectedAllocationEquipmentIds(false)
    local haulageIds = {}
    if job.includesHaulage and #workerIds > 0 then
        haulageIds = self:getSelectedAllocationEquipmentIds(true)
    end

    if #workerIds == 2 then
        self:pickCrewRoles(job, workerIds, equipmentIds, haulageIds, function(orderedIds)
            self:sendAllocation(job, orderedIds, equipmentIds, haulageIds, true)
        end)
        return
    end
    self:sendAllocation(job, workerIds, equipmentIds, haulageIds, false)
end

-- Harvest & haul (035): who harvests and who hauls. assignCrewRoles' pick
-- is the default, but the player can swap them round (to bring on a
-- weaker harvester, say) unless the swap leaves someone unable to do their
-- part, in which case there's nothing to ask. The dialog's text follows
-- the highlighted option (as pickOverheadLevel's does), with any
-- under-qualified warning for that way round. onPicked gets the worker ids,
-- operator first; Back leaves the allocation panel open.
function MenuContractor:pickCrewRoles(job, workerIds, equipmentIds, haulageIds, onPicked)
    local farmId = g_currentMission:getFarmId()
    local allocation = g_currentMission.TheContractor.Allocation
    local staff = g_currentMission.TheContractor.Staff

    local operatorId, haulerId = allocation:assignCrewRoles(farmId, job, workerIds, equipmentIds, haulageIds)
    local pairings = { { operatorId, haulerId } }
    local _, _, swappedCapability = allocation:assignCrewRoles(farmId, job, { haulerId, operatorId }, equipmentIds,
        haulageIds, true)
    if swappedCapability ~= TheContractorAllocation.CAPABILITY.BLOCKED then
        table.insert(pairings, { haulerId, operatorId })
    end
    if #pairings == 1 then
        onPicked(pairings[1])
        return
    end

    local options = {}
    local texts = {}
    for i, pairing in ipairs(pairings) do
        local operator = staff:getWorker(farmId, pairing[1])
        local hauler = staff:getWorker(farmId, pairing[2])
        if operator == nil or hauler == nil then
            return
        end
        local label = string.format(g_i18n:getText("tc_allocation_crewRolesOption"), operator.name, hauler.name)
        if i == 1 then
            label = string.format(g_i18n:getText("tc_allocation_crewRolesRecommended"), label)
        end
        options[i] = label
        local detail = self:getCrewWeaknessText(job, pairing[1], pairing[2], equipmentIds, haulageIds) or
            g_i18n:getText("tc_allocation_crewRolesQualified")
        texts[i] = g_i18n:getText("tc_allocation_crewRolesPrompt") .. "\n\n" .. detail
    end

    local dialog = OptionDialog.INSTANCE
    local optionElement = dialog ~= nil and dialog.optionElement or nil
    local previousCallback = optionElement ~= nil and optionElement.onClickCallback or nil
    if optionElement ~= nil then
        optionElement.onClickCallback = function(_, state)
            if texts[state] ~= nil then
                dialog:setText(texts[state])
            end
        end
    end

    local jobId = job.id
    OptionDialog.show(function(index)
        if optionElement ~= nil then
            optionElement.onClickCallback = previousCallback
        end
        -- Still allocating the same job: the panel could have closed meanwhile.
        if pairings[index] == nil or self.allocatingJobId ~= jobId then
            return
        end
        onPicked(pairings[index])
    end, texts[1], g_i18n:getText("tc_allocation_crewRolesTitle"), options)
end

function MenuContractor:sendAllocation(job, workerIds, equipmentIds, haulageIds, fixedRoles)
    local farmId = g_currentMission:getFarmId()
    g_client:getServerConnection():sendEvent(TCAllocateJobEvent.new(farmId, job.id, workerIds, equipmentIds,
        haulageIds, fixedRoles))

    self.allocatingJobId = nil
    -- Same "synchronous for host/SP, catches up on next refresh for a remote
    -- client" caveat as respondToSelectedInboxJob/sendCounterOffer.
    self:refreshCalendarState(farmId, g_currentMission.TheContractor.Jobs)
    self:focusCalendarDayJobs()
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
    self:updateCalendarDayJobNote()
    self:setMenuButtonInfoDirty()

    if row == nil then
        return
    end

    self.calendarDayDetailTitle:setText(string.format(g_i18n:getText("tc_calendar_dayDetailTitle"),
        formatCalendarDate(self:getCalendarViewPeriod(), row.day, self:getCalendarViewYear())))
end

-- Harvest & haul (035): the highlighted job's selling point, with how much
-- has gone in while the player is doing the carting. Blank otherwise.
function MenuContractor:updateCalendarDayJobNote()
    local job = self:getSelectedCalendarDayJob()
    if job == nil or not job.includesHaulage or job.deliveryStationName == nil then
        self.calendarDayJobNote:setText("")
    elseif job:needsPlayerDelivery() and job.requiredLiters > 0 and
            (job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS) then
        self.calendarDayJobNote:setText(string.format(g_i18n:getText("tc_calendar_deliveryProgressNote"),
            job.deliveryStationName, math.floor(100 * job.deliveredLiters / job.requiredLiters)))
    else
        self.calendarDayJobNote:setText(string.format(g_i18n:getText("tc_calendar_deliveryNote"),
            job.deliveryStationName))
    end
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
    -- 100: a workshop job the farm hasn't the tools for.
    local problem = TheContractorJobs.getAcceptProblem(self:getSelectedInboxJob())
    if problem ~= nil then
        InfoDialog.show(problem)
        return
    end
    self:respondToSelectedInboxJob(true)
end

function MenuContractor:onClickDeclineJob()
    self:respondToSelectedInboxJob(false)
end

-- 102: price an ADS repair contract, once its machine's been inspected
-- (the Negotiate dialog). Before then, says what to do first.
function MenuContractor:onClickNegotiateRepair()
    local job = self:getSelectedInboxJob()
    if job == nil then
        return
    end
    local problem = TheContractorJobs.getAcceptProblem(job)
    if problem ~= nil then
        InfoDialog.show(problem)
        return
    end
    if not TheContractorRepairContracts.isReadyToQuote(job) then
        InfoDialog.show(MenuContractor.getWorkshopPendingText(job))
        return
    end
    TCRepairQuoteDialog.show(job.farmId, job.id, function(target, jobId)
        target:onRepairQuoteSent(jobId)
    end, self)
end

-- The customer's answer comes back as the job's state (accepted or
-- declined), at once on the host and a moment later on a remote client, so
-- the menu watches for it (update, checkPendingRepairQuote).
function MenuContractor:onRepairQuoteSent(jobId)
    self.pendingRepairQuoteJobId = jobId
    self.selectedInboxJobId = nil
    self:checkPendingRepairQuote()
    self:refreshInboxState(g_currentMission:getFarmId(), g_currentMission.TheContractor.Jobs)
end

function MenuContractor:checkPendingRepairQuote()
    local jobId = self.pendingRepairQuoteJobId
    if jobId == nil then
        return
    end
    local job = g_currentMission.TheContractor.Jobs:getJob(g_currentMission:getFarmId(), jobId)
    if job == nil then
        self.pendingRepairQuoteJobId = nil
    elseif job.state == TheContractorJob.STATE.ACCEPTED then
        self.pendingRepairQuoteJobId = nil
        self:showJobAcceptedNotification(job)
    elseif job.state == TheContractorJob.STATE.DECLINED then
        self.pendingRepairQuoteJobId = nil
        self:showJobRejectedNotification(job)
    end
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
    -- 100: a workshop job is the machine, not a field.
    if TheContractorRepairContracts.isFavourJob(job) then
        InfoDialog.show(string.format(g_i18n:getText("tc_favour_acceptedInfo"), job:getCustomerName() or "?",
            TheContractorFarmerFavours.getPartText(job), job:getLocationText(),
            g_i18n:formatMoney(job:getPrice(), 0, true, true)))
        return
    elseif TheContractorRepairContracts.isBreakdownJob(job) then
        InfoDialog.show(string.format(g_i18n:getText("tc_breakdown_acceptedInfo"), job:getDisplayTitle(),
            g_i18n:formatMoney(job:getPrice(), 0, true, true), job:getLocationText()))
        return
    end
    if job:isWorkshop() then
        local key = job.workshop.kind == "maintenance" and "tc_repair_acceptedInfo_maintenance" or
            "tc_repair_acceptedInfo"
        InfoDialog.show(string.format(g_i18n:getText(key), job:getDisplayTitle(),
            g_i18n:formatMoney(job:getPrice(), 0, true, true)))
        return
    end
    local fieldLabel = job:getLocationText()

    InfoDialog.show(string.format(g_i18n:getText("tc_inbox_jobAcceptedInfo"),
        job:getTypeText(), fieldLabel, g_i18n:formatMoney(job:getPrice(), 0, true, true)))
end

-- Counterpart to showJobAcceptedNotification for the other terminal outcome
-- of a counter offer — the NPC walking away rather than accepting. Same
-- "transcript line is a flavor-text nicety, this InfoDialog is the actual
-- can't-miss-it notice" reasoning; a plain Decline click doesn't get one
-- since that's the player's own deliberate action, not a surprise result.
function MenuContractor:showJobRejectedNotification(job)
    if job:isWorkshop() then
        InfoDialog.show(string.format(g_i18n:getText("tc_repair_rejectedInfo"), job:getDisplayTitle()))
        return
    end
    local fieldLabel = job:getLocationText()

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
    local problem = TheContractorJobs.getAcceptProblem(job)
    if problem ~= nil then
        InfoDialog.show(problem)
        return
    end

    self:showCounterOfferDialog(job.id, tostring(math.floor(job:getPrice())))
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
        g_i18n:formatMoney(job:getPrice(), 0, true, true))

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
    local previousPrice = previousJob ~= nil and previousJob:getPrice() or nil
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
            g_i18n:formatMoney(job:getPrice(), 0, true, true))
    elseif job.state == TheContractorJob.STATE.DECLINED then
        return g_i18n:getText("tc_inbox_negotiationDeclined")
    elseif job:getPrice() ~= previousPrice then
        return string.format(g_i18n:getText("tc_inbox_negotiationCountered"),
            g_i18n:formatMoney(counterPrice, 0, true, true), g_i18n:formatMoney(job:getPrice(), 0, true, true))
    elseif job.negotiationRounds > previousRounds then
        -- Countered at the price they'd already offered (026's negotiation
        -- never lets their counter drop) - they're holding firm.
        return string.format(g_i18n:getText("tc_inbox_negotiationHolding"),
            g_i18n:formatMoney(job:getPrice(), 0, true, true))
    end
    return nil
end

-- Active-ad status line. Purchase gating lives in TCAdvertisingDialog now
-- (027), so there's no button state to update here.
-- Finances (049) -----------------------------------------------------------

local function formatMoney(amount)
    return g_i18n:formatMoney(amount, 0, true, true)
end

-- The Finances list's views, in financesViewSelector's order.
MenuContractor.FINANCES_VIEWS = { "invoices", "history", "overheads" }
MenuContractor.FINANCES_VIEW_STATES = { invoices = 1, history = 2, overheads = 3 }

-- Rebuilds the invoice list (keeping the highlighted invoice if it's still
-- listed, otherwise picking the first, like refreshCompletedJobsState) and
-- the cash-flow and year-to-date cards.
function MenuContractor:refreshFinancesState(farmId, finances)
    self.financesContent:setVisible(true)

    self.financesViewSelector:setTexts({ g_i18n:getText("tc_finances_viewInvoices"),
        g_i18n:getText("tc_finances_viewHistory"), g_i18n:getText("tc_finances_viewOverheads") })
    self.financesViewSelector:setState(MenuContractor.FINANCES_VIEW_STATES[self.financesView] or 1)

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

    -- The history lists paid and written-off invoices, by when they settled.
    local isHistory = self.financesView == "history"
    self.invoiceList = isHistory and finances:getSettledInvoices(farmId) or finances:getOpenInvoices(farmId)
    self.financesInvoiceDateHeader:setText(g_i18n:getText(isHistory and "tc_finances_columnSettled" or
        "tc_finances_columnDue"))
    self.financesListEmptyText:setText(g_i18n:getText(isHistory and "tc_finances_noInvoiceHistory" or
        "tc_finances_noInvoices"))
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
    self.financesView = MenuContractor.FINANCES_VIEWS[self.financesViewSelector:getState()] or "invoices"
    self.selectedInvoiceId = nil
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
    -- 073: good news refunds share the received row.
    local receivedText = formatMoney(stats.received)
    if (stats.goodNews or 0) > 0 then
        receivedText = string.format(g_i18n:getText("tc_finances_receivedWithGoodNews"), receivedText,
            formatMoney(stats.goodNews))
    end
    self.financesYearReceived:setText(receivedText)
    self.financesYearWrittenOff:setText(formatMoney(stats.writtenOff))
    -- 054: training courses share the wages row, for the same reason as below.
    self.financesYearWages:setText(formatMoney(stats.wages + (stats.training or 0)))
    -- 075: tipping fees share the overheads row.
    self.financesYearOverheads:setText(formatMoney((stats.overheads or 0) + (stats.disposal or 0)))
    -- 053/055: solicitors' fees and H&S fines share the claims row - there's
    -- no room for another.
    -- 070: as is what insurers paid back.
    local claimsText = formatMoney((stats.claims or 0) + (stats.legal or 0) + (stats.fines or 0))
    if (stats.insurancePayouts or 0) > 0 then
        claimsText = string.format(g_i18n:getText("tc_finances_claimsWithPayouts"), claimsText,
            formatMoney(stats.insurancePayouts))
    end
    self.financesYearClaims:setText(claimsText)

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
        fieldText = job:getLocationText()
    end
    cell:getAttribute("job"):setText(job ~= nil and job:getDisplayTitle() or "-")
    cell:getAttribute("field"):setText(fieldText)
    cell:getAttribute("amount"):setText(formatMoney(invoice.amount))
    cell:getAttribute("due"):setText(TCCalendar.formatDayShort(invoice.settledDay or invoice.dueDay))
    setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"),
        g_i18n:getText("tc_finances_status_" .. invoice.status), INVOICE_STATUS_TONES[invoice.status])
end

-- A paid invoice's timeliness chip: on time, or how many months late
-- (part months round up). Nil for anything else.
local function getInvoiceTimeliness(invoice)
    if invoice.status ~= TheContractorFinances.STATUS.PAID or invoice.settledDay == nil then
        return nil
    end
    local daysLate = invoice.settledDay - invoice.dueDay
    if daysLate <= 0 then
        return g_i18n:getText("tc_finances_paidOnTime"), "good"
    end
    local monthsLate = math.ceil(daysLate / g_currentMission.environment.daysPerPeriod)
    if monthsLate == 1 then
        return g_i18n:getText("tc_finances_paidMonthLate"), "warn"
    end
    return string.format(g_i18n:getText("tc_finances_paidMonthsLate"), monthsLate), "warn"
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
    elseif invoice.status == TheContractorFinances.STATUS.PAID then
        return ""
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
    setChip(self.financesInvoiceTimelinessChip, self.financesInvoiceTimelinessChipText, getInvoiceTimeliness(invoice))

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

-- Lists every registered overhead (keeping the highlighted row, otherwise
-- the first) and fills the panel for it. The office administrator (057)
-- moved to the Staff tab with 090.
function MenuContractor:refreshOverheadsState(farmId, overheads)
    self.overheadRows = {}
    for _, definition in ipairs(overheads:getDefinitions()) do
        table.insert(self.overheadRows, definition)
    end
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

-- The Next charge line, with the status note after it when there is one.
local function withOverheadNote(nextText, note)
    if note == nil or note == "" then
        return nextText
    end
    return string.format(g_i18n:getText("tc_overheads_nextChargeWithNote"), nextText, note)
end

function MenuContractor:populateOverheadCell(index, cell)
    local definition = self.overheadRows[index]
    if definition == nil then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local overheads = g_currentMission.TheContractor.Overheads
    local state = overheads:getState(farmId, definition.key)
    local status = getOverheadStatus(farmId, definition, state)

    cell:getAttribute("name"):setText(g_i18n:getText(definition.l10nKey))
    setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"),
        g_i18n:getText("tc_overheads_status_" .. status), OVERHEAD_STATUS_TONES[status])
end

function MenuContractor:updateOverheadDetails()
    self:setMenuButtonInfoDirty()

    local definition, state = self:getSelectedOverhead()
    self.financesOverheadRows:setVisible(definition ~= nil)
    if definition == nil then
        self.financesInvoiceTitle:setText(g_i18n:getText("tc_overheads_heading"))
        return
    end

    local farmId = g_currentMission:getFarmId()
    local overheads = g_currentMission.TheContractor.Overheads
    local _, note = getOverheadStatus(farmId, definition, state)
    local isActive = state ~= nil and state.enabled

    self.financesInvoiceTitle:setText(g_i18n:getText(definition.l10nKey))

    local nextText
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
        -- 070: the level of cover, and any change from renewal.
        local level = TheContractorOverheads.getLevel(definition, state.level)
        if level ~= nil then
            priceText = string.format(g_i18n:getText("tc_overheads_priceLevel"), g_i18n:getText(level.l10nKey),
                priceText)
            if state.pendingLevel ~= nil and not state.cancelled then
                priceText = string.format(g_i18n:getText("tc_overheads_levelSwitching"), priceText,
                    g_i18n:getText(TheContractorOverheads.getLevel(definition, state.pendingLevel).l10nKey))
            end
        end
        self.financesOverheadPrice:setText(priceText)

        local nextPeriod, nextAmount = overheads:getNextCharge(farmId, definition, state)
        nextText = nextPeriod ~= nil and
            string.format(g_i18n:getText("tc_overheads_nextChargeLine"), formatMoney(nextAmount),
                TCCalendar.formatPeriodIndex(nextPeriod)) or g_i18n:getText("tc_overheads_nextChargeNone")
    else
        -- 070: with levels, the cheapest (the first).
        local annualCost = overheads:getAnnualCost(farmId, definition)
        self.financesOverheadBilling:setText("-")
        self.financesOverheadPrice:setText(string.format(g_i18n:getText(definition.levels ~= nil and
            "tc_overheads_priceFrom" or "tc_overheads_priceQuote"),
            formatMoney(TheContractorOverheads.getChargeAmount(annualCost, TheContractorOverheads.BILLING.ANNUAL)),
            formatMoney(TheContractorOverheads.getChargeAmount(annualCost, TheContractorOverheads.BILLING.MONTHLY))))
        nextText = g_i18n:getText("tc_overheads_nextChargeNone")
    end
    -- The status itself is the list row's chip; what happens next goes here.
    self.financesOverheadNext:setText(withOverheadNote(nextText, note))

    local amounts = {}
    for i, amount in ipairs(definition.descriptionAmounts or {}) do
        amounts[i] = formatMoney(g_currentMission.TheContractor.Settings:scaleCost(amount))
    end
    local descriptionKey = definition.getDescriptionKey ~= nil and definition.getDescriptionKey() or
        definition.l10nKey .. "_desc"
    self.financesOverheadAbout:setText(string.format(g_i18n:getText(descriptionKey), unpack(amounts)))
    self.financesOverheadRows:invalidateLayout()
end

-- Bottom bar for the highlighted overhead, or nil for just the defaults.
function MenuContractor:getOverheadButtonInfo()
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
    if definition.mandatory then
        return self.menuButtonInfoOverheadMandatory
    end
    return definition.levels ~= nil and self.menuButtonInfoOverheadActiveLevels or self.menuButtonInfoOverheadActive
end

-- Sends the request, then redraws - same "synchronous for host/SP, catches
-- up on next refresh for a remote client" caveat as onClickHireWorker.
function MenuContractor:sendOverheadRequest(definition, request, billing, levelKey)
    local farmId = g_currentMission:getFarmId()
    g_client:getServerConnection():sendEvent(TCOverheadRequestEvent.new(farmId, definition.key, request, billing,
        levelKey))
    self:refreshFinancesState(farmId, g_currentMission.TheContractor.Finances)
    self:setMenuButtonInfoDirty()
end

-- 070: an OptionDialog of the definition's levels by name, then
-- onPicked(levelKey). The dialog's text shows the prompt and the highlighted
-- level's price at billing and description, updated as the selector moves
-- (vanilla's option has no change callback of its own, so one is set for
-- the dialog's lifetime and put back after). OptionDialog closes before its
-- callback runs, so onPicked can open its own dialog.
function MenuContractor:pickOverheadLevel(definition, billing, prompt, onPicked)
    local farmId = g_currentMission:getFarmId()
    local overheads = g_currentMission.TheContractor.Overheads
    local options = {}
    local texts = {}
    for i, level in ipairs(definition.levels) do
        local name = g_i18n:getText(level.l10nKey)
        local amount = TheContractorOverheads.getChargeAmount(overheads:getAnnualCost(farmId, definition, level.key),
            billing)
        local detail = string.format(g_i18n:getText("tc_overheads_levelDetail_" .. billing), name, formatMoney(amount))
        if level.getDescription ~= nil then
            detail = detail .. " " .. level.getDescription()
        end
        options[i] = name
        texts[i] = prompt .. "\n\n" .. detail
    end

    local dialog = OptionDialog.INSTANCE
    local optionElement = dialog ~= nil and dialog.optionElement or nil
    local previousCallback = optionElement ~= nil and optionElement.onClickCallback or nil
    if optionElement ~= nil then
        optionElement.onClickCallback = function(_, state)
            if texts[state] ~= nil then
                dialog:setText(texts[state])
            end
        end
    end

    local definitionKey = definition.key
    OptionDialog.show(function(index)
        if optionElement ~= nil then
            optionElement.onClickCallback = previousCallback
        end
        local level = definition.levels[index]
        -- Still the same overhead: the list could have refreshed meanwhile.
        if level == nil or self.selectedOverheadKey ~= definitionKey then
            return
        end
        onPicked(level.key)
    end, texts[1], g_i18n:getText("tc_overheads_levelTitle"), options)
end

function MenuContractor:onClickEnableOverhead(billing)
    local definition, state = self:getSelectedOverhead()
    if definition == nil or definition.mandatory or (state ~= nil and state.enabled) then
        return
    end

    if definition.levels ~= nil then
        self:pickOverheadLevel(definition, billing, string.format(g_i18n:getText("tc_overheads_levelPrompt"),
            g_i18n:getText(definition.l10nKey)), function(levelKey)
            self:confirmEnableOverhead(definition, billing, levelKey)
        end)
        return
    end
    self:confirmEnableOverhead(definition, billing, nil)
end

function MenuContractor:confirmEnableOverhead(definition, billing, levelKey)
    local farmId = g_currentMission:getFarmId()
    local overheads = g_currentMission.TheContractor.Overheads
    local amount = TheContractorOverheads.getChargeAmount(overheads:getAnnualCost(farmId, definition, levelKey),
        billing)
    local name = g_i18n:getText(definition.l10nKey)
    local level = TheContractorOverheads.getLevel(definition, levelKey)
    if level ~= nil then
        name = string.format(g_i18n:getText("tc_overheads_nameWithLevel"), name, g_i18n:getText(level.l10nKey))
    end

    if not overheads:canAffordEnable(farmId, definition, billing, levelKey) then
        InfoDialog.show(string.format(g_i18n:getText("tc_overheads_cannotAfford"), name, formatMoney(amount)))
        return
    end

    YesNoDialog.show(function(target, clickOk)
        if clickOk then
            target:sendOverheadRequest(definition, TheContractorOverheads.REQUEST.ENABLE, billing, levelKey)
        end
    end, self, string.format(g_i18n:getText("tc_overheads_enableConfirm_" .. billing), name, formatMoney(amount)))
end

-- 070: no confirm, like switching billing: it only changes the next term.
function MenuContractor:onClickChangeOverheadLevel()
    local definition, state = self:getSelectedOverhead()
    if definition == nil or definition.levels == nil or state == nil or not state.enabled or state.cancelled then
        return
    end

    local current = TheContractorOverheads.getLevel(definition, state.level)
    self:pickOverheadLevel(definition, TheContractorOverheads.getNextBilling(state),
        string.format(g_i18n:getText("tc_overheads_levelChangePrompt"), g_i18n:getText(definition.l10nKey),
            g_i18n:getText(current.l10nKey)), function(levelKey)
            self:sendOverheadRequest(definition, TheContractorOverheads.REQUEST.SET_LEVEL, nil, levelKey)
        end)
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

-- Others: the farmers and the local official (111) ------------------------------

-- The portrait's key for a person: their ids are their own (110), so they
-- mustn't be taken for a worker with the same one.
function MenuContractor.getPersonPortraitKey(personId)
    return "person" .. personId
end

-- The highlighted Others row ({ person, acres, farmlandCount, hasYard }), or
-- nil.
function MenuContractor:getSelectedPersonRow()
    if self.staffView ~= "others" or self.selectedPersonId == nil then
        return nil
    end
    for _, row in ipairs(self.personRows) do
        if row.person.id == self.selectedPersonId then
            return row
        end
    end
    return nil
end

function MenuContractor:getSelectedPerson()
    local row = self:getSelectedPersonRow()
    return row ~= nil and row.person or nil
end

-- Highlights a person in the Others view, if they're listed.
function MenuContractor:selectPerson(personId)
    for i, row in ipairs(self.personRows) do
        if row.person.id == personId then
            self.staffTable:setSelectedIndex(i, true)
            return
        end
    end
end

local function formatAcres(acres)
    return g_i18n:formatArea(acres / TheContractorFarmerSplit.ACRES_PER_HA, 0)
end

-- Name, land, fields (farmland count) and yard. The official has no land, so only a name.
function MenuContractor:populatePersonCell(row, cell)
    local person = row.person
    cell:getAttribute("name"):setText(person.name)
    local land, farmlands, yard = "", "", ""
    if not person.isOfficial then
        land = row.farmlandCount > 0 and formatAcres(row.acres) or "-"
        farmlands = tostring(row.farmlandCount)
        yard = g_i18n:getText(row.hasYard and "tc_people_yes" or "tc_people_no")
    end
    cell:getAttribute("workSpeed"):setText(land)
    cell:getAttribute("col4"):setText(farmlands)
    cell:getAttribute("col4"):setVisible(true)
    setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"), nil)
    cell:getAttribute("col5"):setText(yard)
    setADSChip(cell, nil)
end

-- Their land and yard (a farmer's), and what the player's farm has done
-- for them, from its logbook and invoices.
function MenuContractor:updatePersonDetails(row)
    local person = row.person
    local farmId = g_currentMission:getFarmId()
    local tc = g_currentMission.TheContractor

    self.staffPersonTitle:setText(person.name)
    self.staffPersonRole:setText(g_i18n:getText(person.isOfficial and "tc_people_roleOfficial" or
        "tc_people_roleFarmer"))
    -- 113
    setChip(self.staffPersonRelationshipChip, self.staffPersonRelationshipChipText,
        MenuContractor.getRelationshipChip(person))

    self.staffPersonRowLand:setVisible(not person.isOfficial)
    self.staffPersonRowYard:setVisible(not person.isOfficial)
    if not person.isOfficial then
        local land = g_i18n:getText("tc_people_landNone")
        if row.farmlandCount == 1 then
            land = string.format(g_i18n:getText("tc_people_landOne"), formatAcres(row.acres))
        elseif row.farmlandCount > 1 then
            land = string.format(g_i18n:getText("tc_people_landMany"), formatAcres(row.acres), row.farmlandCount)
        end
        self.staffPersonLand:setText(land)
        self.staffPersonYard:setText(person.yardFarmlandId ~= nil and
            string.format(g_i18n:getText("tc_people_yardOn"), person.yardFarmlandId) or
            g_i18n:getText("tc_people_yardOff"))
    end

    local history = TheContractorFarmers.getCustomerHistory(tc.Logbook:getJobEntries(farmId), person.id,
        TheContractorLogbook.getInvoice)
    local jobs = tostring(history.completed)
    if history.missed > 0 then
        jobs = string.format(g_i18n:getText("tc_people_jobsMissed"), history.completed, history.missed)
    end
    self.staffPersonJobs:setText(jobs)
    local paid = formatMoney(history.paid)
    if history.owed > 0 then
        paid = string.format(g_i18n:getText("tc_people_paidOwed"), paid, formatMoney(history.owed))
    end
    self.staffPersonPaid:setText(paid)
    self.staffPersonLastJob:setText(history.last ~= nil and string.format(g_i18n:getText("tc_people_lastJob"),
        history.last.title or "", TCCalendar.formatDay(history.last.day)) or g_i18n:getText("tc_people_lastJobNone"))

    -- 122: a farmer's machines take the About section's place.
    local machines = TheContractorFarmerFleet.getSorted(person.machines)
    local showMachines = not person.isOfficial
    self.staffPersonSectionTitle:setText(g_i18n:getText(showMachines and "tc_fleet_detailsHeading" or
        "tc_people_aboutHeading"))
    self.staffPersonAbout:setVisible(not showMachines)
    self.staffPersonMachinesLeft:setVisible(showMachines)
    self.staffPersonMachinesRight:setVisible(showMachines)
    if showMachines then
        local left, right = {}, {}
        local half = math.ceil(#machines / 2)
        for index, machine in ipairs(machines) do
            table.insert(index <= half and left or right, getMachineText(machine))
        end
        if #machines == 0 then
            left = { g_i18n:getText("tc_fleet_none") }
        end
        self.staffPersonMachinesLeft:setText(table.concat(left, "\n"))
        self.staffPersonMachinesRight:setText(table.concat(right, "\n"))
    else
        self.staffPersonAbout:setText(g_i18n:getText("tc_people_about_official"))
    end
    local hasNoLand = not person.isOfficial and row.farmlandCount == 0
    local note = ""
    if tc.Relationships:refuses(farmId, person.id) then
        note = g_i18n:getText("tc_people_noteFallenOut")
    elseif hasNoLand then
        note = g_i18n:getText("tc_people_noteNoLand")
    end
    self.staffPersonNote:setText(note)
    self.staffPersonRows:invalidateLayout()
end

-- A farmer or the official was edited (TheContractorFarmers:
-- applyPersonEdited, every machine): their portrait loads the new look.
function MenuContractor:onPersonEdited(personId)
    if self.workerPortrait ~= nil and
            self.workerPortrait.shownKey == MenuContractor.getPersonPortraitKey(personId) then
        self.workerPortrait:reload()
    end
    self:onPeopleChanged()
end

-- The people or their land changed, on any machine.
function MenuContractor:onPeopleChanged()
    if self.isFrameOpen and self:hasCompany() then
        local tc = g_currentMission.TheContractor
        self:refreshStaffState(g_currentMission:getFarmId(), tc.Staff, tc.Jobs)
        -- 112: and the Inbox names offers' customers.
        if self.subCategoryPaging:getState() == MenuContractor.SUB_CATEGORY.INBOX then
            self:refreshInboxState(g_currentMission:getFarmId(), tc.Jobs)
        end
    end
end

-- Office staff (090) -------------------------------------------------------

-- Level chip tones, levels 1-3.
local OFFICE_LEVEL_TONES = { "neutral", "info", "good" }

-- A roster row for an office role: the person (or "Vacant"), their status
-- in the chip and the role where a worker's job goes.
function MenuContractor:populateOfficeCell(row, cell)
    local member = row.member
    cell:getAttribute("name"):setText(member ~= nil and member.name or g_i18n:getText("tc_office_vacant"))
    cell:getAttribute("workSpeed"):setText("")
    cell:getAttribute("col4"):setVisible(false)

    local status, tone = "vacant", "neutral"
    if member ~= nil then
        status = TheContractorOffice.getStatus(member)
        tone = "good"
        if status == TheContractorOffice.STATUS.TRAINING then
            tone = "info"
        elseif status == TheContractorOffice.STATUS.AT_HOME then
            tone = "neutral"
        end
    end
    setChip(cell:getAttribute("statusChip"), cell:getAttribute("statusChipText"),
        g_i18n:getText("tc_office_status_" .. status), tone)
    cell:getAttribute("col5"):setText(TheContractorOffice.getRoleName(row.role))
    setADSChip(cell, nil)
end

function MenuContractor:updateOfficeDetails(row)
    local farmId = g_currentMission:getFarmId()
    local member = row.member
    local roleName = TheContractorOffice.getRoleName(row.role)

    self.staffOfficeTitle:setText(member ~= nil and member.name or
        string.format(g_i18n:getText("tc_office_vacancyTitle"), roleName))
    self.staffOfficeRole:setText(roleName)

    local salary = member ~= nil and member.salary or TheContractorOffice.getLevelSalary(row.role, 1)
    self.staffOfficeSalary:setText(string.format(g_i18n:getText("tc_office_salary"),
        formatMoney(TheContractorStaff.scalePay(salary))))

    self.staffOfficeRowAge:setVisible(member ~= nil)
    self.staffOfficeRowLevel:setVisible(member ~= nil)
    self.staffOfficeRowStatus:setVisible(member ~= nil)
    self.staffOfficeRowSince:setVisible(member ~= nil)
    if member ~= nil then
        self.staffOfficeAge:setText(tostring(member.ageAtHire + TheContractorStaff.getYearsOfService(member)))
        setChip(self.staffOfficeLevelChip, self.staffOfficeLevelChipText,
            string.format(g_i18n:getText("tc_office_level"), member.level), OFFICE_LEVEL_TONES[member.level])
        local status = TheContractorOffice.getStatus(member)
        setChip(self.staffOfficeStatusChip, self.staffOfficeStatusChipText,
            g_i18n:getText("tc_office_status_" .. status),
            status == TheContractorOffice.STATUS.TRAINING and "info" or "good")
        self.staffOfficeSince:setText(TCCalendar.formatPeriodIndex(member.hiredPeriod))
    end

    self.staffOfficeWorkshop:setText(self:getOfficeWorkshopText(row))
    self.staffOfficeAbout:setText(g_i18n:getText("tc_office_about_" .. row.role))
    self.staffOfficeNote:setText(self:getOfficeNote(farmId, row) or "")
    self.staffOfficeRows:invalidateLayout()
end

-- Their role in FS25_AdvancedDamageSystem's own workshop, while it takes
-- our staff.
function MenuContractor:getOfficeWorkshopText(row)
    if not TCADSWorkshop.isActive() then
        return g_i18n:getText("tc_office_workshopNone")
    end
    local adsRoleName = g_i18n:getText("tc_office_adsRole_" .. TheContractorOffice.getDefinition(row.role).adsRole)
    if row.member == nil then
        return adsRoleName
    end
    return string.format(g_i18n:getText("tc_office_workshopRole"), adsRoleName, row.member.level)
end

-- The one note under the role's description: what they're doing, or why
-- they can't do much, or what training costs.
function MenuContractor:getOfficeNote(farmId, row)
    local member = row.member
    if member == nil then
        return g_i18n:getText("tc_office_noteVacant")
    end
    if TheContractorOffice.isTraining(member) then
        return string.format(g_i18n:getText("tc_office_noteTraining"), member.level + 1,
            TCCalendar.formatDay(member.trainingUntilDay))
    end
    if not TCADSWorkshop.isActive() then
        return nil
    end
    if member.level >= TheContractorOffice.MAX_LEVEL then
        return g_i18n:getText("tc_office_noteFullyTrained")
    end
    return string.format(g_i18n:getText("tc_office_noteCanTrain"), member.level + 1,
        formatMoney(TheContractorOffice.getTrainCost(row.role, member.level)),
        TheContractorOffice.getTrainDays(row.role, member.level))
end

-- Sends the request, then redraws: synchronous for host/SP, catches up
-- when the change arrives for a remote client (onOfficeChanged).
function MenuContractor:sendOfficeRequest(role, request)
    local farmId = g_currentMission:getFarmId()
    g_client:getServerConnection():sendEvent(TCOfficeRequestEvent.new(farmId, role, request))
    self:refreshStaffState(farmId, g_currentMission.TheContractor.Staff, g_currentMission.TheContractor.Jobs)
end

-- An office member was hired, released, trained or edited, on any machine.
function MenuContractor:onOfficeChanged()
    if self.isFrameOpen and self:hasCompany() then
        local tc = g_currentMission.TheContractor
        self:refreshStaffState(g_currentMission:getFarmId(), tc.Staff, tc.Jobs)
    end
end

function MenuContractor:onClickHireOffice()
    local row = self:getSelectedOfficeRow()
    if row == nil or row.member ~= nil then
        return
    end
    local farmId = g_currentMission:getFarmId()
    if g_currentMission.TheContractor.Office:getHireProblem(farmId, row.role) ~= nil then
        return
    end

    local firstPay = TheContractorOffice.getFirstPay(row.role)
    if not TheContractorOffice.canAfford(farmId, firstPay) then
        InfoDialog.show(string.format(g_i18n:getText("tc_office_cannotAfford"),
            g_i18n:getText("tc_office_roleNoun_" .. row.role), formatMoney(firstPay)))
        return
    end

    local role = row.role
    YesNoDialog.show(function(target, clickOk)
        if clickOk then
            target:sendOfficeRequest(role, TheContractorOffice.REQUEST.HIRE)
        end
    end, self, string.format(g_i18n:getText("tc_office_hireConfirm_" .. role), formatMoney(firstPay)))
end

-- The cost is worked out like a worker's (056).
function MenuContractor:onClickReleaseOffice()
    local row = self:getSelectedOfficeRow()
    local member = row ~= nil and row.member or nil
    if member == nil then
        return
    end

    local noun = g_i18n:getText("tc_office_roleNoun_" .. row.role)
    local cost = TheContractorOffice.getReleaseCost(member)
    local prompt
    if cost.redundancyPay > 0 then
        prompt = string.format(g_i18n:getText("tc_office_releaseConfirmRedundancy"), member.name, noun, cost.years,
            formatMoney(cost.total), formatMoney(cost.noticePay), formatWeeks(cost.noticeWeeks),
            formatMoney(cost.redundancyPay))
    else
        prompt = string.format(g_i18n:getText("tc_office_releaseConfirmNotice"), member.name, noun, cost.years,
            formatMoney(cost.total), formatWeeks(cost.noticeWeeks))
    end

    local role = row.role
    YesNoDialog.show(function(target, clickOk)
        if clickOk then
            target:sendOfficeRequest(role, TheContractorOffice.REQUEST.RELEASE)
        end
    end, self, prompt)
end

-- Edit (066/077) and, when offered, Train. OptionDialog closes before its
-- callback runs, so the chosen action can open its own dialog.
function MenuContractor:onClickManageOffice()
    local row = self:getSelectedOfficeRow()
    local member = row ~= nil and row.member or nil
    if member == nil then
        return
    end

    local farmId = g_currentMission:getFarmId()
    local role = row.role
    local actions = {
        { text = g_i18n:getText("tc_editWorker_button"), run = function()
            self:openEditPerson(member, TCEditPersonDialog.KIND.WORKER)
        end },
    }
    if g_currentMission.TheContractor.Office:getTrainProblem(farmId, role) == nil then
        table.insert(actions, { text = string.format(g_i18n:getText("tc_office_trainButton"), member.level + 1),
            run = function()
                self:onClickTrainOffice(role)
            end })
    end

    local options = {}
    for _, action in ipairs(actions) do
        table.insert(options, action.text)
    end

    OptionDialog.show(function(index)
        local action = actions[index]
        -- Still the same person: the list could have refreshed meanwhile.
        local current = self:getSelectedOfficeRow()
        if action == nil or current == nil or current.member == nil or current.member.id ~= member.id then
            return
        end
        action.run()
    end, string.format(g_i18n:getText("tc_staff_managePrompt"), member.name), g_i18n:getText("tc_staff_manageTitle"),
        options)
end

-- Funds-check-then-confirm, like onClickBookTraining. The server re-checks.
function MenuContractor:onClickTrainOffice(role)
    local farmId = g_currentMission:getFarmId()
    local office = g_currentMission.TheContractor.Office
    local member = office:getMember(farmId, role)
    if member == nil or office:getTrainProblem(farmId, role) ~= nil then
        return
    end

    local cost = TheContractorOffice.getTrainCost(role, member.level)
    if not TheContractorOffice.canAfford(farmId, cost) then
        InfoDialog.show(string.format(g_i18n:getText("tc_office_trainCannotAfford"), formatMoney(cost)))
        return
    end

    YesNoDialog.show(function(target, clickOk)
        if clickOk then
            target:sendOfficeRequest(role, TheContractorOffice.REQUEST.TRAIN)
        end
    end, self, string.format(g_i18n:getText("tc_office_trainConfirm"), member.name, member.level + 1,
        formatMoney(cost), TheContractorOffice.getTrainDays(role, member.level)))
end

-- 090: FS25_AdvancedDamageSystem's workshop card (TCADSWorkshop.
-- openStaffMenu): the Staff tab's roster, on that office role's row if
-- there is one.
function MenuContractor:openOfficeRow(role, workerId)
    if g_gui.currentGuiName ~= "InGameMenu" then
        g_gui:showGui("InGameMenu")
    end
    g_inGameMenu:goToPage(self)

    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.STAFF, true)
    if self.staffView ~= "roster" then
        self.staffViewSelector:setState(1)
        self:onClickStaffView()
    end
    if role ~= nil and self:hasCompany() then
        for i, row in ipairs(self.officeRows) do
            if row.role == role then
                self.staffTable:setSelectedIndex(#self.rosterWorkers + i, true)
            end
        end
    end
    -- 091: a trade's worker.
    if workerId ~= nil and self:hasCompany() then
        for i, worker in ipairs(self.rosterWorkers) do
            if worker.id == workerId then
                self.staffTable:setSelectedIndex(i, true)
            end
        end
    end
    self:setMenuButtonInfoDirty()
end

-- Logbook (060) ------------------------------------------------------------

-- Vehicles view sort orders, cycled by btnLogbookSort.
MenuContractor.LOGBOOK_VEHICLE_SORTS = { "lastUsed", "hours", "faults", "name" }

local function getFieldName(fieldId)
    local field = g_fieldManager:getFieldById(fieldId)
    return field ~= nil and field:getName() or tostring(fieldId)
end

-- 100: a workshop job's entry - no field, crew or travel to speak of.
local function isWorkshopEntry(entry)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[entry.jobType or ""]
    return jobDef ~= nil and jobDef.workshopJob == true
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

-- The jobs list's crew column: just how many (the details name them).
local function getCrewText(entry)
    return #entry.crew > 0 and tostring(#entry.crew) or "-"
end

-- Who a vehicle history entry was: the driver, "Stolen" for a theft (069),
-- or "A player".
local function getVehicleEntryWho(entry)
    if entry.kind == TheContractorLogbook.KIND.THEFT then
        return g_i18n:getText("tc_logbook_stolen")
    end
    return entry.who or g_i18n:getText("tc_logbook_aPlayer")
end

-- The margin chip: money, or "Missed".
local function getMarginChip(entry)
    if entry.outcome == TheContractorLogbook.OUTCOME.MISSED then
        return g_i18n:getText("tc_logbook_missed"), "bad"
    end
    return formatMoney(TheContractorLogbook.getMargin(entry)), TheContractorLogbook.getMarginTone(entry)
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
        -- 100: not a customer's machine in a repair zone.
        if vehicleId ~= nil and vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() == farmId and
                not vehicle.isPallet and vehicle.spec_wearable ~= nil and not vehicle.isDeleted and
                not TheContractorRepairContracts.isContractVehicle(vehicle) then
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
    -- 100: a workshop job's row, like a live job's (getListTitle,
    -- getListFieldText): just its type, and a breakdown's field or "-".
    if isWorkshopEntry(entry) then
        cell:getAttribute("title"):setText(g_i18n:getText("tc_jobType_" .. entry.jobType))
        cell:getAttribute("field"):setText(entry.workshopFieldId ~= nil and getFieldName(entry.workshopFieldId) or
            "-")
    else
        cell:getAttribute("title"):setText(entry.title or "-")
        cell:getAttribute("field"):setText(entry.location or getFieldName(entry.fieldId))
    end
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
    local lastWho = last ~= nil and (last.kind == TheContractorLogbook.KIND.THEFT and getVehicleEntryWho(last) or
        last.who or "-") or g_i18n:getText("tc_logbook_neverUsed")
    cell:getAttribute("lastUsedBy"):setText(lastWho)
    cell:getAttribute("lastUsed"):setText(last ~= nil and TCCalendar.formatDayShort(last.day) or "-")

    -- 069: a stolen vehicle's condition isn't known, just that it's gone.
    if g_currentMission.TheContractor.Theft:isStolen(row.id) then
        setChip(cell:getAttribute("conditionChip"), cell:getAttribute("conditionChipText"),
            g_i18n:getText("tc_logbook_stolen"), "bad")
    else
        local snapshot = TCVehicleCondition.capture(row.vehicle)
        setChip(cell:getAttribute("conditionChip"), cell:getAttribute("conditionChipText"),
            TCVehicleCondition.getHeadline(snapshot) or "-", TCVehicleCondition.getTone(snapshot))
    end

    -- A fault found while it was in use this year.
    setChip(cell:getAttribute("faultChip"), cell:getAttribute("faultChipText"),
        row.summary.faults > 0 and g_i18n:getText("tc_logbook_faultChip") or nil, "bad")
end

function MenuContractor:populateLogbookDetailCell(index, cell)
    local row = self.logbookDetailRows[index]
    if row == nil then
        return
    end
    -- Kinds of row: a section title, a label/value pair, or a vehicle
    -- history line (four columns - their headings when isHeader).
    local isSection = row.section ~= nil
    local isHistory = row.history ~= nil
    local isPair = not isSection and not isHistory
    cell:getAttribute("surface"):setVisible(not isSection and not row.isHeader)
    cell:getAttribute("section"):setVisible(isSection)
    cell:getAttribute("section"):setText(row.section or "")
    cell:getAttribute("label"):setVisible(isPair)
    cell:getAttribute("label"):setText(row.label or "")
    cell:getAttribute("value"):setVisible(isPair)
    cell:getAttribute("value"):setText(row.value or "")
    for i = 1, 4 do
        local heading = cell:getAttribute("historyHeading" .. i)
        local value = cell:getAttribute("history" .. i)
        heading:setVisible(isHistory and row.isHeader == true)
        heading:setText(isHistory and row.history[i] or "")
        value:setVisible(isHistory and not row.isHeader)
        value:setText(isHistory and row.history[i] or "")
    end
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
    local isWorkshop = isWorkshopEntry(entry)

    section("tc_logbook_sectionJob")
    row(text(isMissed and "tc_logbook_missedOn" or "tc_logbook_completedOn"), TCCalendar.formatDay(entry.day),
        text(isMissed and "tc_logbook_missed" or "tc_logbook_completed"), isMissed and "bad" or "good")
    local placeKey = entry.location ~= nil and "tc_logbook_machine" or "tc_logbook_field"
    -- 124: a farmer's yard.
    if entry.delivery ~= nil then
        placeKey = "tc_jobDetails_place"
    end
    row(text(placeKey), entry.location or getFieldName(entry.fieldId))
    if isMissed then
        row(text("tc_logbook_progress"), string.format("%d%%", math.floor(entry.completionPercentage or 0)))
    elseif entry.qualityScore ~= nil then
        row(text("tc_logbook_quality"), string.format("%d%%", entry.qualityScore),
            string.format("%d%%", entry.qualityScore), getQualityChipTone(entry.qualityScore))
    end
    if (entry.stuckInterventions or 0) > 0 then
        row(text("tc_logbook_interventions"), tostring(entry.stuckInterventions), nil, nil)
    end

    -- 100: the player works a workshop job, with no crew and no trip.
    if not isWorkshop then
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
            row(text("tc_logbook_role_" .. (member.role or TheContractorLogbook.ROLE.OPERATOR)), getCrewName(member),
                chip, tone)
        end
        -- 094: whoever had it before it was unallocated.
        if entry.earlierCrew ~= nil then
            row(text("tc_logbook_earlierCrew"), entry.earlierCrew)
        end
    end

    if #entry.equipment > 0 then
        section("tc_logbook_sectionEquipment")
        for _, machine in ipairs(entry.equipment) do
            local chip, tone = nil, nil
            if TheContractorLogbook.hasFoundFault(machine) then
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
            if TCVehicleCondition.hasWearCost(machine.startSnapshot, machine.endSnapshot) then
                row(text("tc_logbook_wearCost"), formatMoney(machine.wearCost), nil, nil, machine.vehicleId)
            end
        end
    end

    if not isWorkshop then
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

    -- 124: the bales a farmer asked for, what went in and what was over.
    if entry.delivery ~= nil then
        local delivery = entry.delivery
        section("tc_logbook_sectionDelivery")
        row(text("tc_logbook_askedFor"), g_i18n:formatVolume(delivery.requiredLiters or 0, 0))
        row(text("tc_logbook_delivered"), g_i18n:formatVolume(delivery.deliveredLiters or 0, 0))
        -- 126: where a farmer's load went.
        if delivery.stationName ~= nil then
            row(text("tc_logbook_soldAt"), delivery.stationName)
        end
        if (delivery.excessLiters or 0) > 0 then
            row(text("tc_logbook_excess"), string.format(text("tc_logbook_excessValue"),
                g_i18n:formatVolume(delivery.excessLiters, 0), formatMoney(delivery.excessPay or 0)))
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
    -- ADS machines' wear has no cost (TCVehicleCondition.hasWearCost), so
    -- the row goes when every machine is one, and the margin says so.
    local pricedWear, unpricedWear = TheContractorLogbook.countWearCosts(entry)
    if pricedWear > 0 or unpricedWear == 0 then
        row(text("tc_logbook_machineWear"), entry.wearCost ~= nil and formatMoney(entry.wearCost) or
            text("tc_logbook_notRecorded"))
    end

    if entry.claim ~= nil then
        local cause = entry.claim.cause ~= nil and g_i18n:getText("tc_claims_cause_" .. entry.claim.cause) or "-"
        cause = (string.gsub(cause, "^%l", string.upper))
        row(text("tc_logbook_claim"), cause, text(entry.claim.insured and "tc_logbook_insured" or
            "tc_logbook_uninsured"), entry.claim.insured and "info" or "bad")
        row(text("tc_logbook_claimPaid"), string.format(text("tc_logbook_claimPaidValue"),
            formatMoney(entry.claim.paid), formatMoney(entry.claim.amount)))
    end

    local marginChip, marginTone = getMarginChip(entry)
    row(text(unpricedWear > 0 and "tc_logbook_marginNoAdsWear" or "tc_logbook_margin"),
        formatMoney(TheContractorLogbook.getMargin(entry)), marginChip, marginTone)

    if entry.reputation ~= nil then
        row(text("tc_logbook_reputation"), string.format("%+d", entry.reputation), nil, nil)
    end
    if entry.claim ~= nil and (entry.claim.reputationPenalty or 0) > 0 then
        row(text("tc_logbook_claimReputation"), string.format("%+d", -entry.claim.reputationPenalty), nil, nil)
    end

    return rows
end

-- "+3%" for a vehicle getting worse by a fraction, "-" for no change (or
-- better, after a repair) or nothing to compare.
local function formatWorse(delta)
    local points = delta ~= nil and math.floor(delta * 100 + 0.5) or 0
    if points <= 0 then
        return "-"
    end
    return string.format("+%d%%", points)
end

-- How long a vehicle history entry had the machine out, in in-game minutes:
-- the entry's own time, else its engine hours.
local function getEntryMinutes(entry)
    if entry.minutes ~= nil then
        return entry.minutes
    end
    local hours = TCVehicleCondition.getHoursBetween(entry.startSnapshot, entry.endSnapshot)
    return hours ~= nil and hours * 60 or 0
end

-- "62% (248 l)" for a vehicle's diesel tank, or nil if it hasn't one.
local function getFuelText(vehicle)
    local consumer = vehicle ~= nil and TCJobSupplies.getDieselConsumer(vehicle) or nil
    if consumer == nil then
        return nil
    end
    local capacity = vehicle:getFillUnitCapacity(consumer.fillUnitIndex) or 0
    local level = vehicle:getFillUnitFillLevel(consumer.fillUnitIndex) or 0
    if capacity <= 0 then
        return nil
    end
    return string.format(g_i18n:getText("tc_logbook_fuelLevel"), math.floor(100 * level / capacity + 0.5),
        g_i18n:formatVolume(level, 0))
end

-- The detail rows for a vehicle: how it is now, this year's summary, then
-- its history, one row a use (anything under MIN_SESSION_MINUTES left
-- out) under a row of column headings. History rows carry their jobId for
-- the Job log button.
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
    -- 069: missing while the police look for it.
    if g_currentMission.TheContractor.Theft:isStolen(vehicleRow.id) then
        row(text("tc_logbook_status"), text("tc_logbook_stolen"), text("tc_logbook_stolen"), "bad")
    else
        row(text("tc_logbook_status"), text("tc_logbook_inFleet"), TCVehicleCondition.getHeadline(snapshot),
            TCVehicleCondition.getTone(snapshot))
    end
    for _, state in ipairs(TCVehicleCondition.getStateRows(snapshot)) do
        row(state.label, state.value, state.tone ~= nil and text("tc_logbook_faultShort") or nil, state.tone)
    end
    local fuel = getFuelText(vehicleRow.vehicle)
    if fuel ~= nil then
        row(text("tc_logbook_fuel"), fuel)
    end

    -- 099: an ADS vehicle's known faults, one row each, so a long list
    -- isn't cut off.
    local faultNames = TCVehicleCondition.getKnownFaultNames(snapshot)
    if faultNames ~= nil then
        section("tc_logbook_activeFaults")
        for _, name in ipairs(faultNames) do
            row(name, "", text("tc_logbook_faultShort"), "bad")
        end
        if #faultNames == 0 then
            row(text("tc_logbook_none"), "")
        end
    end

    section("tc_logbook_sectionYear")
    row(text("tc_logbook_jobs"), tostring(summary.jobs))
    row(text("tc_logbook_engineHours"), formatHours(summary.hours))
    row(text("tc_logbook_faultsFound"), tostring(summary.faults), summary.faults > 0 and
        text("tc_logbook_faultChip") or nil, "bad")
    if TCVehicleCondition.hasWearCost(snapshot) then
        row(text("tc_logbook_wearCost"), formatMoney(summary.wearCost))
    end

    section("tc_logbook_sectionHistory")
    local entries = {}
    if vehicleRow.record ~= nil then
        for _, entry in ipairs(TheContractorLogbook.getVehicleEntries(vehicleRow.record, farmId)) do
            if getEntryMinutes(entry) >= TheContractorLogbook.MIN_SESSION_MINUTES then
                table.insert(entries, entry)
            end
        end
    end
    if #entries == 0 then
        row("-", text("tc_logbook_noHistory"))
        return rows
    end

    table.insert(rows, { history = { text("tc_logbook_columnMonth"), text("tc_logbook_columnDriver"),
        text("tc_logbook_columnDamage"), text("tc_logbook_columnWear") }, isHeader = true })
    for _, entry in ipairs(entries) do
        local damage, wear = TCVehicleCondition.getDeltas(entry.startSnapshot, entry.endSnapshot)
        local chip, tone = nil, nil
        if entry.outcome == TheContractorLogbook.OUTCOME.MISSED then
            chip, tone = text("tc_logbook_missed"), "bad"
        elseif entry.kind == TheContractorLogbook.KIND.THEFT then
            chip, tone = text("tc_logbook_recoveredChip"), "warn"
        elseif TheContractorLogbook.hasFoundFault(entry) then
            chip, tone = text("tc_logbook_faultChip"), "bad"
        elseif entry.wash == TCJobConsequences.WASH.UNWASHED then
            chip, tone = text("tc_logbook_dirtyChip"), "warn"
        end
        table.insert(rows, {
            history = { TCCalendar.formatDayShort(entry.day), getVehicleEntryWho(entry),
                formatWorse(damage), formatWorse(wear) },
            chip = chip,
            tone = tone,
            jobId = entry.jobId,
        })
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

-- Supplies (064) -----------------------------------------------------------

-- How often the Supplies tab re-reads stock while it's showing.
MenuContractor.SUPPLIES_REFRESH_MS = 1000

-- Bar fills: the menu's green, or red when stock is low or jobs are held
-- for it (vanilla's production storage list does the same).
MenuContractor.BAR_COLORS = {
    normal = { 0.30, 0.62, 0.06, 1 },
    danger = { 0.75, 0.15, 0.08, 1 },
}

local function formatPercent(ratio)
    return string.format("%d%%", math.floor((ratio or 0) * 100 + 0.5))
end

-- A stock bar (tc_rowBarTrack + tc_rowBarFill): the fill's width is its
-- share of the track's. Hidden for a nil ratio. The fill only has a
-- default colour, so setting .color covers selected rows too.
local function setBar(track, fill, ratio, isDanger)
    local visible = ratio ~= nil
    track:setVisible(visible)
    fill:setVisible(visible and ratio > 0)
    if not visible or ratio <= 0 then
        return
    end
    local fullWidth = track.size[1]
    fill:setSize(math.max(fullWidth * math.min(ratio, 1), track.size[2]), nil)
    fill.color = isDanger and MenuContractor.BAR_COLORS.danger or MenuContractor.BAR_COLORS.normal
end

-- The views on offer: the farm's supplies always, then ADS's consumables
-- and spare parts each only if TCADSStock can read them.
function MenuContractor:getSuppliesViews()
    local views = { "supplies" }
    if TCADSStock.hasConsumables() then
        table.insert(views, "adsConsumables")
    end
    if TCADSStock.hasPartsBoxes() then
        table.insert(views, "adsParts")
    end
    return views
end

local function getHeldJobsChip(supply)
    if #supply.heldJobs > 0 then
        return string.format(g_i18n:getText("tc_supplies_chipHeld"), #supply.heldJobs), "bad"
    end
    return nil, nil
end

-- A list row: { key, name, amountText, ratio, isDanger, chip, tone,
-- source } - a bar for a ratio, else the chip if there is one.
local function buildSupplyRow(supply)
    local row = {
        key = "supply:" .. tostring(supply.fillTypeName),
        name = supply.title,
        amountText = TCJobSupplies.formatQuantity(supply.fillTypeIndex, supply.amount),
        isDanger = supply.isLow or #supply.heldJobs > 0,
        supply = supply,
    }
    if supply.ratio ~= nil then
        row.ratio = supply.ratio
    else
        row.chip, row.tone = getHeldJobsChip(supply)
        if row.chip == nil then
            if supply.amount <= 0 then
                row.chip, row.tone = g_i18n:getText("tc_supplies_chipNone"), "warn"
            else
                row.chip, row.tone = g_i18n:getText("tc_supplies_chipPallets"), "neutral"
            end
        end
    end
    return row
end

local function formatADSAmount(item)
    if item.fillTypeIndex ~= nil then
        return TCJobSupplies.formatQuantity(item.fillTypeIndex, item.amount)
    end
    return string.format(g_i18n:getText("tc_supplies_pieces"), g_i18n:formatNumber(math.floor(item.amount)))
end

local function buildADSConsumableRow(item)
    local row = {
        key = "ads:" .. item.key,
        name = item.name,
        amountText = formatADSAmount(item),
        adsConsumable = item,
    }
    if item.capacity ~= nil then
        row.ratio = item.amount / item.capacity
        row.isDanger = row.ratio < TCSupplyStock.LOW_RATIO
    elseif item.isUsed then
        row.chip, row.tone = g_i18n:getText("tc_supplies_chipUsed"), "warn"
    end
    return row
end

-- A part's new/used row in its details, for packs and boxes alike.
local function addPartConditionRow(add, item)
    if item.isUsed then
        add.row(g_i18n:getText("tc_supplies_condition"), "",
            { chip = g_i18n:getText("tc_supplies_chipUsed"), tone = "warn" })
    else
        add.row(g_i18n:getText("tc_supplies_condition"), "",
            { chip = g_i18n:getText("tc_supplies_chipNew"), tone = "good" })
    end
end

local function getPartBoxName(item)
    if item.tierText == "" then
        return item.name
    end
    return string.format(g_i18n:getText("tc_supplies_partTier"), item.name, item.tierText)
end

local function buildADSPartRow(item)
    local row = {
        key = "part:" .. item.key,
        name = getPartBoxName(item),
        amountText = string.format(g_i18n:getText("tc_supplies_boxes"), item.count),
        adsPart = item,
    }
    if item.reserved ~= nil and item.reserved > 0 then
        row.chip, row.tone = string.format(g_i18n:getText("tc_supplies_chipReserved"), item.reserved), "info"
    elseif item.isUsed then
        row.chip, row.tone = g_i18n:getText("tc_supplies_chipUsed"), "warn"
    end
    return row
end

function MenuContractor:buildSuppliesRows(farmId)
    local rows = {}
    if self.suppliesView == "adsConsumables" then
        for _, item in ipairs(TCADSStock.getConsumableRows(farmId)) do
            table.insert(rows, buildADSConsumableRow(item))
        end
    elseif self.suppliesView == "adsParts" then
        for _, item in ipairs(TCADSStock.getPartBoxRows(farmId)) do
            table.insert(rows, buildADSPartRow(item))
        end
    else
        for _, supply in ipairs(TCSupplyStock.getSupplies(farmId)) do
            table.insert(rows, buildSupplyRow(supply))
        end
    end
    return rows
end

MenuContractor.SUPPLIES_VIEW_TEXTS = {
    supplies = { view = "tc_supplies_viewSupplies", name = "tc_supplies_columnSupply",
        amount = "tc_supplies_columnStock", level = "tc_supplies_columnLevel", empty = "tc_supplies_empty" },
    adsConsumables = { view = "tc_supplies_viewAdsConsumables", name = "tc_supplies_columnItem",
        amount = "tc_supplies_columnStock", level = "tc_supplies_columnLevel", empty = "tc_supplies_emptyAdsConsumables" },
    adsParts = { view = "tc_supplies_viewAdsParts", name = "tc_supplies_columnPart",
        amount = "tc_supplies_columnStock", level = "tc_supplies_columnStatus", empty = "tc_supplies_emptyAdsParts" },
}

function MenuContractor:refreshSuppliesState(farmId)
    self.suppliesContent:setVisible(true)

    -- A view whose ADS functions went missing isn't offered; fall back to
    -- the farm's supplies.
    self.suppliesViews = self:getSuppliesViews()
    local viewIndex = 1
    local viewTexts = {}
    for i, view in ipairs(self.suppliesViews) do
        if view == self.suppliesView then
            viewIndex = i
        end
        table.insert(viewTexts, g_i18n:getText(MenuContractor.SUPPLIES_VIEW_TEXTS[view].view))
    end
    self.suppliesView = self.suppliesViews[viewIndex]
    self.suppliesViewSelector:setTexts(viewTexts)
    self.suppliesViewSelector:setState(viewIndex)

    local texts = MenuContractor.SUPPLIES_VIEW_TEXTS[self.suppliesView]
    self.suppliesColumnName:setText(g_i18n:getText(texts.name))
    self.suppliesColumnAmount:setText(g_i18n:getText(texts.amount))
    self.suppliesColumnLevel:setText(g_i18n:getText(texts.level))
    self.suppliesEmptyText:setText(g_i18n:getText(texts.empty))

    -- reloadData re-raises the selection callback with the old index, which
    -- would overwrite the row that was highlighted if the list has moved.
    local wantedKey = self.selectedSupplyKey
    self.suppliesRows = self:buildSuppliesRows(farmId)
    self.suppliesTable:reloadData()

    local hasItems = #self.suppliesRows > 0
    self.suppliesListContainer:setVisible(hasItems)
    self.suppliesEmptyText:setVisible(not hasItems)

    if hasItems then
        local selectedIndex = 1
        for i, row in ipairs(self.suppliesRows) do
            if row.key == wantedKey then
                selectedIndex = i
            end
        end
        if self.suppliesTable:getSelectedIndexInSection() ~= selectedIndex then
            self.suppliesTable:setSelectedIndex(selectedIndex)
        end
        self.selectedSupplyKey = self.suppliesRows[selectedIndex].key
    else
        self.selectedSupplyKey = nil
    end

    self:updateSupplyDetails()
end

function MenuContractor:onClickSuppliesView()
    self.suppliesView = self.suppliesViews[self.suppliesViewSelector:getState()] or "supplies"
    self.selectedSupplyKey = nil
    self:refreshSuppliesState(g_currentMission:getFarmId())
end

function MenuContractor:getSelectedSupplyRow()
    for _, row in ipairs(self.suppliesRows) do
        if row.key == self.selectedSupplyKey then
            return row
        end
    end
    return nil
end

function MenuContractor:populateSupplyCell(index, cell)
    local row = self.suppliesRows[index]
    if row == nil then
        return
    end
    cell:getAttribute("name"):setText(row.name)
    cell:getAttribute("amount"):setText(row.amountText)
    setBar(cell:getAttribute("barTrack"), cell:getAttribute("barFill"), row.ratio, row.isDanger)
    cell:getAttribute("percent"):setVisible(row.ratio ~= nil)
    cell:getAttribute("percent"):setText(row.ratio ~= nil and formatPercent(row.ratio) or "")
    setChip(cell:getAttribute("chip"), cell:getAttribute("chipText"), row.ratio == nil and row.chip or nil, row.tone)
end

function MenuContractor:populateSupplyDetailCell(index, cell)
    local row = self.suppliesDetailRows[index]
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
    local ratio = not isSection and row.ratio or nil
    setBar(cell:getAttribute("barTrack"), cell:getAttribute("barFill"), ratio, row.isDanger)
    cell:getAttribute("percent"):setVisible(ratio ~= nil)
    cell:getAttribute("percent"):setText(ratio ~= nil and formatPercent(ratio) or "")
    setChip(cell:getAttribute("chip"), cell:getAttribute("chipText"),
        not isSection and ratio == nil and row.chip or nil, row.tone)
end

-- "1,200 / 5,000 l": stored against capacity, in the fill type's unit.
local function formatStoredOf(fillTypeIndex, amount, capacity)
    return string.format(g_i18n:getText("tc_supplies_storedOf"), g_i18n:formatNumber(math.floor(amount)),
        TCJobSupplies.formatQuantity(fillTypeIndex, capacity))
end

-- Section titles and label/value rows, as in the Logbook's detail list,
-- plus an optional bar (ratio) per row.
local function newDetailRows()
    local rows = {}
    local builder = {}
    function builder.section(key)
        table.insert(rows, { section = g_i18n:getText(key) })
    end
    function builder.row(label, value, extra)
        local row = extra or {}
        row.label, row.value = label, value
        table.insert(rows, row)
    end
    return rows, builder
end

function MenuContractor:getSupplyDetailRows(supply)
    local rows, add = newDetailRows()
    local fillTypeIndex = supply.fillTypeIndex
    local text = function(key)
        return g_i18n:getText(key)
    end

    add.section("tc_supplies_sectionStock")
    add.row(text("tc_supplies_inStock"), TCJobSupplies.formatQuantity(fillTypeIndex, supply.amount))
    if supply.capacity ~= nil then
        add.row(text("tc_supplies_inStorage"), TCJobSupplies.formatQuantity(fillTypeIndex, supply.storedAmount))
        add.row(text("tc_supplies_capacity"), TCJobSupplies.formatQuantity(fillTypeIndex, supply.capacity))
        add.row(text("tc_supplies_freeSpace"),
            TCJobSupplies.formatQuantity(fillTypeIndex, math.max(supply.capacity - supply.storedAmount, 0)))
        add.row(text("tc_supplies_fillLevel"), formatPercent(supply.ratio), { ratio = supply.ratio or 0,
            isDanger = supply.isLow or #supply.heldJobs > 0 })
    else
        add.row(text("tc_supplies_capacity"), text("tc_supplies_noStorage"))
    end

    if #supply.storages > 0 then
        add.section("tc_supplies_sectionStorage")
        -- Each storage's bar is just how full it is: Low is judged on the
        -- whole supply (TCSupplyStock.getLowAmount), not one storage.
        for _, storage in ipairs(supply.storages) do
            local ratio = storage.capacity > 0 and storage.amount / storage.capacity or 0
            add.row(storage.name, formatStoredOf(fillTypeIndex, storage.amount, storage.capacity),
                { ratio = ratio, isDanger = false })
        end
    end

    if #supply.pallets > 0 then
        add.section("tc_supplies_sectionPallets")
        for _, group in ipairs(supply.pallets) do
            local labelKey = group.isStored and "tc_supplies_storedPalletGroup" or "tc_supplies_palletGroup"
            add.row(string.format(text(labelKey), group.name, group.count),
                TCJobSupplies.formatQuantity(fillTypeIndex, group.amount))
        end
    end

    if #supply.heldJobs > 0 then
        add.section("tc_supplies_sectionHeld")
        for _, job in ipairs(supply.heldJobs) do
            add.row(job:getLocationText(), job:getTypeText(),
                { chip = text("tc_supplies_chipWaiting"), tone = "bad" })
        end
    end

    return rows
end

function MenuContractor:getADSConsumableDetailRows(item)
    local rows, add = newDetailRows()
    local text = function(key)
        return g_i18n:getText(key)
    end

    add.section("tc_supplies_sectionStock")
    add.row(text("tc_supplies_inStock"), formatADSAmount(item))
    if item.tierText ~= "" then
        add.row(text("tc_supplies_quality"), item.tierText)
    end
    if item.kind == "pack" then
        addPartConditionRow(add, item)
    end
    if item.capacity ~= nil then
        local ratio = item.amount / item.capacity
        add.row(text("tc_supplies_capacity"), TCJobSupplies.formatQuantity(item.fillTypeIndex, item.capacity))
        add.row(text("tc_supplies_fillLevel"), formatPercent(ratio),
            { ratio = ratio, isDanger = ratio < TCSupplyStock.LOW_RATIO })
    end

    add.section("tc_supplies_sectionKept")
    for _, source in ipairs(item.sources) do
        if source.capacity ~= nil and source.capacity > 0 then
            local ratio = source.amount / source.capacity
            add.row(source.name, formatStoredOf(item.fillTypeIndex, source.amount, source.capacity),
                { ratio = ratio, isDanger = ratio < TCSupplyStock.LOW_RATIO })
        else
            local amount = { fillTypeIndex = item.fillTypeIndex, amount = source.amount }
            add.row(source.name, formatADSAmount(amount))
        end
    end

    return rows
end

function MenuContractor:getADSPartDetailRows(item)
    local rows, add = newDetailRows()
    local text = function(key)
        return g_i18n:getText(key)
    end

    add.section("tc_supplies_sectionStock")
    add.row(text("tc_supplies_boxCount"), string.format(text("tc_supplies_boxes"), item.count))
    if item.tierText ~= "" then
        add.row(text("tc_supplies_quality"), item.tierText)
    end
    addPartConditionRow(add, item)
    -- Without ADS's isReserved there's no telling free from reserved.
    if item.reserved ~= nil then
        add.row(text("tc_supplies_free"), string.format(text("tc_supplies_boxes"), item.count - item.reserved))
        add.row(text("tc_supplies_reserved"), string.format(text("tc_supplies_boxes"), item.reserved),
            item.reserved > 0 and { chip = text("tc_supplies_chipWorkOrder"), tone = "info" } or nil)
    end

    add.section("tc_supplies_sectionFits")
    for _, fit in ipairs(item.fits) do
        add.row(fit.vehicleName, string.format(text("tc_supplies_boxes"), fit.count))
    end

    return rows
end

-- The header chip for a supply: held jobs first, then how much is left.
local function getSupplyStatusChip(supply)
    local chip, tone = getHeldJobsChip(supply)
    if chip ~= nil then
        return chip, tone
    elseif supply.amount <= 0 then
        return g_i18n:getText("tc_supplies_chipOut"), "bad"
    elseif supply.isLow then
        return g_i18n:getText("tc_supplies_chipLow"), "warn"
    end
    return g_i18n:getText("tc_supplies_chipInStock"), "good"
end

-- Fills the detail panel for the highlighted row.
function MenuContractor:updateSupplyDetails()
    local row = self:getSelectedSupplyRow()
    local rows, chipText, chipTone = nil, nil, nil
    if row ~= nil then
        if row.supply ~= nil then
            rows = self:getSupplyDetailRows(row.supply)
            chipText, chipTone = getSupplyStatusChip(row.supply)
        elseif row.adsConsumable ~= nil then
            rows = self:getADSConsumableDetailRows(row.adsConsumable)
            if row.isDanger then
                chipText, chipTone = g_i18n:getText("tc_supplies_chipLow"), "warn"
            elseif row.adsConsumable.isUsed then
                chipText, chipTone = g_i18n:getText("tc_supplies_chipUsed"), "warn"
            end
        elseif row.adsPart ~= nil then
            rows = self:getADSPartDetailRows(row.adsPart)
            if row.adsPart.isUsed then
                chipText, chipTone = g_i18n:getText("tc_supplies_chipUsed"), "warn"
            end
        end
    end

    self.suppliesDetailsBox:setVisible(rows ~= nil)
    self.suppliesDetailRows = rows or {}
    self.suppliesDetailTable:reloadData()
    if rows == nil then
        return
    end

    self.suppliesDetailTitle:setText(row.name)
    setChip(self.suppliesDetailChip, self.suppliesDetailChipText, chipText, chipTone)
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
        g_i18n:formatMoney(TheContractorCompany.getCreationCost(), 0, true, true))

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
        target:showCompanyWelcome(name)
    end, self, "", dialogPrompt, dialogPrompt, 30, g_i18n:getText("tc_actions_createButton"))
end

-- Getting-started tips shown once the company's been named, as paragraphs of
-- running prose: each inner list is one paragraph, its tips joined by spaces.
-- Each tip is its own l10n key so they can be reworded or regrouped without
-- touching layout.
MenuContractor.WELCOME_PARAGRAPHS = {
    { "tc_actions_welcomeTip_staff", "tc_actions_welcomeTip_supplies" },
    { "tc_actions_welcomeTip_overheads", "tc_actions_welcomeTip_advertising" },
    { "tc_actions_welcomeTip_jobs" },
}

function MenuContractor:showCompanyWelcome(name)
    local paragraphs = { string.format(g_i18n:getText("tc_actions_welcomeIntro"), name) }
    for _, keys in ipairs(MenuContractor.WELCOME_PARAGRAPHS) do
        local sentences = {}
        for _, key in ipairs(keys) do
            table.insert(sentences, g_i18n:getText(key))
        end
        table.insert(paragraphs, table.concat(sentences, " "))
    end

    InfoDialog.show(table.concat(paragraphs, "\n\n"))
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

function MenuContractor:onClickSupplies()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.SUPPLIES, true)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickWorkshop()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.WORKSHOP, true)
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
