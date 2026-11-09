-- Invoices and bad debt (049). A completed job is billed rather than paid
-- (TheContractorJobs:completeJob -> invoiceJob): the customer pays some
-- time later, sometimes late, sometimes never. Payment lands under
-- MoneyType.TC_JOB_PAYOUT on the daily tick. The Finances tab plans cash
-- flow around it, and this file also keeps the farm's year-to-date totals
-- (invoiced, received, written off, wages) for that tab.
--
-- Invoice: { id, farmId, jobId, amount, issuedDay, dueDay, status,
-- settledDay } - days are monotonic. dueDay is what the player is told.
-- Server-only, never streamed (so nobody can peek): paymentDay, the day it
-- will actually be paid (nil for a bad debt), and the isBadDebt/isLate
-- flags behind it. They're saved in the XML.
--
-- An overdue invoice could be a late payer or a bad debt - the player
-- can't tell which. One overdue for WRITE_OFF_AFTER_PERIODS is written off
-- automatically, with an Overview notice; the player can write one off
-- sooner from the Finances tab.
--
-- 053: or pursue it (requestPursuit) - free with legal cover, a solicitor's
-- fee without (see TheContractorAssociation). The invoice goes to
-- `pursuing` and isn't written off automatically. PURSUIT_MIN-MAX_PERIODS
-- later it resolves: a late payer always pays, a bad debt pays with
-- RECOVERY_CHANCE_COVERED/_SOLICITOR, otherwise it's written off. A late
-- payer whose own payment day comes first just pays then. Public pursuit
-- fields: pursuitStartDay, pursuitFee (0 under legal cover); the day it
-- resolves, pursuitResolveDay, stays on the server like paymentDay.
--
-- 057: an office administrator (TheContractorOffice, 090) swaps in
-- shorter delays and lower bad-debt and late-payer chances for the
-- invoices issued while they're employed.
--
-- 113: the customer's pay habit (TheContractorFarmers.PAY_HABITS, hidden
-- from the player) scales those two chances, so some farmers tend to pay
-- late. Pursuing an invoice costs the customer's relationship.
--
-- With the lateInvoices setting off, invoiceJob pays on the spot (the
-- pre-049 behaviour) and no invoice is kept. Invoices already issued still
-- run their course.

TheContractorFinances = {}
TheContractorFinances_mt = Class(TheContractorFinances)

TheContractorFinances.STATUS = {
    OUTSTANDING = "outstanding",
    PAID = "paid",
    OVERDUE = "overdue",
    WRITTEN_OFF = "writtenOff",
    PURSUING = "pursuing",
}

-- Payment delay in whole periods, weighted toward shorter ones. A random
-- day within the period goes on top, so payments don't all land on a
-- period boundary. These and the two chances below are the numbers without
-- an office administrator (057).
TheContractorFinances.DELAY_WEIGHTS = {
    { periods = 0, weight = 35 },
    { periods = 1, weight = 35 },
    { periods = 2, weight = 20 },
    { periods = 3, weight = 10 },
}

-- Rolled at issue, hidden. A bad debt is never paid; a late payer (only
-- from the good debts) pays 1-2 periods after the due day.
TheContractorFinances.BAD_DEBT_CHANCE = 0.05
TheContractorFinances.LATE_PAYER_CHANCE = 0.15
TheContractorFinances.LATE_MIN_PERIODS = 1
TheContractorFinances.LATE_MAX_PERIODS = 2

-- Periods past its due day before an overdue invoice is written off.
TheContractorFinances.WRITE_OFF_AFTER_PERIODS = 6
-- How long the write-off notice stays on the Overview board.
TheContractorFinances.WRITE_OFF_NOTICE_MONTHS = 3

-- Pursuing an overdue invoice (053): how long it takes, and how likely a
-- bad debt is to pay up in the end, with legal cover or a solicitor.
TheContractorFinances.PURSUIT_MIN_PERIODS = 1
TheContractorFinances.PURSUIT_MAX_PERIODS = 2
TheContractorFinances.RECOVERY_CHANCE_COVERED = 0.8
TheContractorFinances.RECOVERY_CHANCE_SOLICITOR = 0.65

-- Settled (paid/written off) invoices are dropped from the save once
-- they're this many periods old. The Finances tab's invoice history lists
-- the same span (two years).
TheContractorFinances.KEEP_SETTLED_PERIODS = 24

-- The forecast covers this month and the next FORECAST_PERIODS - 1.
TheContractorFinances.FORECAST_PERIODS = 3

TheContractorFinances.YEAR_STAT_KEYS = { "invoiced", "received", "writtenOff", "wages", "overheads", "claims",
    "legal", "training", "fines", "insurancePayouts", "goodNews", "disposal" }

function TheContractorFinances.new()
    local self = {}
    setmetatable(self, TheContractorFinances_mt)

    -- invoicesById[id] = invoice. Ids are unique across all farms.
    self.invoicesById = {}
    self.nextInvoiceId = 1

    -- yearStatsByFarm[farmId] = { year, invoiced, received, writtenOff, wages,
    -- overheads, claims, legal, training, fines, insurancePayouts, goodNews,
    -- disposal }
    self.yearStatsByFarm = {}

    return self
end

-- Query API -----------------------------------------------------------------

function TheContractorFinances:getInvoice(invoiceId)
    return self.invoicesById[invoiceId]
end

-- The farm's open invoices (outstanding, overdue and pursuing), oldest due
-- first.
function TheContractorFinances:getOpenInvoices(farmId)
    local result = {}
    for _, invoice in pairs(self.invoicesById) do
        if invoice.farmId == farmId and invoice.status ~= TheContractorFinances.STATUS.PAID and
            invoice.status ~= TheContractorFinances.STATUS.WRITTEN_OFF then
            table.insert(result, invoice)
        end
    end
    table.sort(result, function(a, b)
        if a.dueDay ~= b.dueDay then
            return a.dueDay < b.dueDay
        end
        return a.id < b.id
    end)
    return result
end

-- The farm's settled invoices (paid and written off) from the last
-- KEEP_SETTLED_PERIODS, latest settled first. Older ones are only dropped
-- at the next save, so they're left out here too.
function TheContractorFinances:getSettledInvoices(farmId)
    local environment = g_currentMission.environment
    local keepAfterDay = environment.currentMonotonicDay -
        TheContractorFinances.KEEP_SETTLED_PERIODS * environment.daysPerPeriod

    local result = {}
    for _, invoice in pairs(self.invoicesById) do
        if invoice.farmId == farmId and invoice.settledDay ~= nil and invoice.settledDay >= keepAfterDay then
            table.insert(result, invoice)
        end
    end
    table.sort(result, function(a, b)
        if a.settledDay ~= b.settledDay then
            return a.settledDay > b.settledDay
        end
        return a.id > b.id
    end)
    return result
end

-- The invoice for one of the farm's jobs, or nil (none kept with the
-- lateInvoices setting off, or dropped from the save once settled).
function TheContractorFinances:getInvoiceForJob(farmId, jobId)
    for _, invoice in pairs(self.invoicesById) do
        if invoice.farmId == farmId and invoice.jobId == jobId then
            return invoice
        end
    end
    return nil
end

-- Total of the farm's invoices with this status.
function TheContractorFinances:getTotal(farmId, status)
    local total = 0
    for _, invoice in pairs(self.invoicesById) do
        if invoice.farmId == farmId and invoice.status == status then
            total = total + invoice.amount
        end
    end
    return total
end

-- This calendar year's totals for the farm; zeros if nothing's happened
-- this year. Keyed by the display year (TCCalendar.getDisplayYear), so they
-- run January to December, not the game's March to February.
function TheContractorFinances:getYearStats(farmId)
    local environment = g_currentMission.environment
    local year = TCCalendar.getDisplayYear(environment.currentYear, environment.currentPeriod)
    local stats = self.yearStatsByFarm[farmId]
    if stats == nil or stats.year ~= year then
        return { year = year, invoiced = 0, received = 0, writtenOff = 0, wages = 0,
            overheads = 0, claims = 0, legal = 0, training = 0, fines = 0, insurancePayouts = 0,
            goodNews = 0, disposal = 0 }
    end
    return stats
end

-- Cash-flow forecast: { periodIndex, income, wages, overheads } for this
-- month and the next FORECAST_PERIODS - 1. income is what outstanding
-- invoices are due to bring in that month, by their due day - overdue ones
-- aren't counted, since nobody knows if they'll pay. wages is the current
-- salary bill plus pension (051), charged at the start of each month, so
-- this month's (already paid) is 0. overheads (051) are the policy charges
-- falling in that month, also charged at its start.
function TheContractorFinances:getForecast(farmId)
    local tc = g_currentMission.TheContractor
    local firstIndex = TCCalendar.getPeriodIndex()
    local wageBill = tc.Staff:getWageBill(farmId)

    local rows = {}
    for i = 1, TheContractorFinances.FORECAST_PERIODS do
        local periodIndex = firstIndex + i - 1
        table.insert(rows, {
            periodIndex = periodIndex,
            income = 0,
            wages = i > 1 and wageBill or 0,
            overheads = i > 1 and tc.Overheads:getForecastForPeriod(farmId, periodIndex) or 0,
        })
    end

    for _, invoice in pairs(self.invoicesById) do
        if invoice.farmId == farmId and invoice.status == TheContractorFinances.STATUS.OUTSTANDING then
            local periodIndex = TCCalendar.getDayInfo(invoice.dueDay)
            local row = rows[periodIndex - firstIndex + 1]
            if row ~= nil then
                row.income = row.income + invoice.amount
            end
        end
    end
    return rows
end

-- Invoicing (server-only) -------------------------------------------------

local function rollDelayPeriods(weights)
    local totalWeight = 0
    for _, entry in ipairs(weights) do
        totalWeight = totalWeight + entry.weight
    end
    local roll = math.random() * totalWeight
    for _, entry in ipairs(weights) do
        roll = roll - entry.weight
        if roll < 0 then
            return entry.periods
        end
    end
    return weights[#weights].periods
end

-- Called from TheContractorJobs:completeJob with job.paymentAmount set.
-- Either invoices it (setting job.invoiceDueDay) or, with late/unpaid
-- invoices switched off, pays it now.
function TheContractorFinances:invoiceJob(job)
    if not g_currentMission:getIsServer() then
        return
    end

    local amount = job.paymentAmount
    -- 106: nothing to bill for a job done for nothing.
    if amount == nil or amount <= 0 then
        return
    end
    self:addToYearStats(job.farmId, "invoiced", amount)

    if not g_currentMission.TheContractor.Settings:get("lateInvoices") then
        g_currentMission:addMoney(amount, job.farmId, MoneyType.TC_JOB_PAYOUT, true, true)
        self:addToYearStats(job.farmId, "received", amount)
        return
    end

    local environment = g_currentMission.environment
    local today = environment.currentMonotonicDay
    local daysPerPeriod = environment.daysPerPeriod
    -- 057: credit control, if they employ an office administrator.
    local administrator = g_currentMission.TheContractor.Office

    -- At least a day, so even a prompt payer pays on a later day tick.
    local delayDays = math.max(1, rollDelayPeriods(administrator:getDelayWeights(job.farmId)) * daysPerPeriod +
        math.random(0, daysPerPeriod - 1))
    local dueDay = today + delayDays

    local habit = g_currentMission.TheContractor.Farmers:getPayHabit(job.customerId)
    local isBadDebt = math.random() < administrator:getBadDebtChance(job.farmId) * habit.badDebtMultiplier
    local isLate = not isBadDebt and
        math.random() < administrator:getLatePayerChance(job.farmId) * habit.latePayerMultiplier
    local paymentDay = nil
    if isLate then
        paymentDay = dueDay + math.random(TheContractorFinances.LATE_MIN_PERIODS * daysPerPeriod,
            TheContractorFinances.LATE_MAX_PERIODS * daysPerPeriod)
    elseif not isBadDebt then
        paymentDay = dueDay
    end

    local invoice = {
        id = self.nextInvoiceId,
        farmId = job.farmId,
        jobId = job.id,
        amount = amount,
        issuedDay = today,
        dueDay = dueDay,
        status = TheContractorFinances.STATUS.OUTSTANDING,
        settledDay = nil,
        paymentDay = paymentDay,
        isBadDebt = isBadDebt,
        isLate = isLate,
    }
    self:applyInvoiceIssued(invoice)
    job.invoiceDueDay = dueDay

    if g_server ~= nil then
        g_server:broadcastEvent(TCInvoiceIssuedEvent.new(invoice))
    end

    TCLog.info("TheContractor: farm %d invoice %d for job %d: %.0f due day %d (%s, a %s payer)", invoice.farmId,
        invoice.id, invoice.jobId, amount, dueDay,
        isBadDebt and "bad debt" or (isLate and ("late, pays day " .. paymentDay) or "on time"), habit.key)
end

function TheContractorFinances:applyInvoiceIssued(invoice)
    self.invoicesById[invoice.id] = invoice

    if invoice.id >= self.nextInvoiceId then
        self.nextInvoiceId = invoice.id + 1
    end
end

-- Server-only: moves an invoice on, applies locally, then broadcasts.
function TheContractorFinances:setInvoiceStatus(invoice, status)
    local settledDay = nil
    if status == TheContractorFinances.STATUS.PAID or status == TheContractorFinances.STATUS.WRITTEN_OFF then
        settledDay = g_currentMission.environment.currentMonotonicDay
    end

    self:applyInvoiceStatus(invoice.id, status, settledDay, invoice.pursuitStartDay, invoice.pursuitFee)

    if g_server ~= nil then
        g_server:broadcastEvent(TCInvoiceStatusChangedEvent.new(invoice.id, status, settledDay,
            invoice.pursuitStartDay, invoice.pursuitFee))
    end
end

-- The actual status change, run on whichever machine (server, or a client
-- receiving TCInvoiceStatusChangedEvent) is applying it. Tells the farm's
-- player when one's paid. pursuitStartDay/pursuitFee (053) are nil for an
-- invoice that was never pursued.
function TheContractorFinances:applyInvoiceStatus(invoiceId, status, settledDay, pursuitStartDay, pursuitFee)
    local invoice = self.invoicesById[invoiceId]
    if invoice == nil then
        return
    end

    invoice.status = status
    invoice.settledDay = settledDay
    invoice.pursuitStartDay = pursuitStartDay
    invoice.pursuitFee = pursuitFee

    if status == TheContractorFinances.STATUS.PAID and g_client ~= nil and
        g_currentMission:getFarmId() == invoice.farmId then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_finances_paidNotification"), self:getInvoiceTitle(invoice),
                g_i18n:formatMoney(invoice.amount, 0, true, true)))
    end
end

-- "Plowing on Field 12", from the invoice's job.
function TheContractorFinances:getInvoiceTitle(invoice)
    local job = g_currentMission.TheContractor.Jobs:getJob(invoice.farmId, invoice.jobId)
    if job == nil then
        return string.format(g_i18n:getText("tc_finances_unknownJob"), invoice.jobId)
    end
    -- 100: a workshop job's title already names the machine.
    if job:isWorkshop() then
        return job:getDisplayTitle()
    end
    return string.format(g_i18n:getText("tc_finances_invoiceTitle"), job:getDisplayTitle(), job:getLocationText())
end

function TheContractorFinances:payInvoice(invoice)
    local wasPursued = invoice.status == TheContractorFinances.STATUS.PURSUING

    g_currentMission:addMoney(invoice.amount, invoice.farmId, MoneyType.TC_JOB_PAYOUT, true, true)
    self:addToYearStats(invoice.farmId, "received", invoice.amount)
    self:setInvoiceStatus(invoice, TheContractorFinances.STATUS.PAID)
    TCLog.info("TheContractor: farm %d invoice %d paid (%.0f)", invoice.farmId, invoice.id, invoice.amount)

    -- 053: whether the pursuit did it or they'd have paid anyway, it's over.
    if wasPursued then
        g_currentMission.TheContractor.Inbox:postMessage(invoice.farmId, TheContractorAssociation.MESSAGE_KIND,
            "tc_legal_recoveredTitle", "tc_legal_recoveredBody", self:getPursuitMessageArgs(invoice), nil,
            { invoiceId = invoice.id })
    end
end

-- Server-only. isAutomatic: written off by the daily tick rather than by
-- the player, which puts a notice on the Overview board.
function TheContractorFinances:writeOffInvoice(invoice, isAutomatic)
    self:addToYearStats(invoice.farmId, "writtenOff", invoice.amount)
    self:setInvoiceStatus(invoice, TheContractorFinances.STATUS.WRITTEN_OFF)

    if isAutomatic then
        g_currentMission.TheContractor.Notices:publish(invoice.farmId,
            string.format(g_i18n:getText("tc_finances_writtenOffNotice"), self:getInvoiceTitle(invoice),
                g_i18n:formatMoney(invoice.amount, 0, true, true)),
            TheContractorFinances.WRITE_OFF_NOTICE_MONTHS)
    end

    TCLog.info("TheContractor: farm %d invoice %d written off (%.0f, %s)", invoice.farmId, invoice.id,
        invoice.amount, isAutomatic and "automatic" or "by the player")
end

-- Server side of TCWriteOffInvoiceEvent: only the farm's own overdue
-- invoices can be written off.
function TheContractorFinances:requestWriteOff(farmId, invoiceId)
    if not g_currentMission:getIsServer() then
        return
    end

    local invoice = self.invoicesById[invoiceId]
    if invoice == nil or invoice.farmId ~= farmId or invoice.status ~= TheContractorFinances.STATUS.OVERDUE then
        return
    end

    self:writeOffInvoice(invoice, false)
end

-- Pursuing overdue invoices (053, server-only) ------------------------------

-- Server side of TCPursueInvoiceEvent: the farm's own overdue invoice, and
-- the solicitor's fee has to be affordable (nothing to pay with legal cover).
function TheContractorFinances:requestPursuit(farmId, invoiceId)
    if not g_currentMission:getIsServer() then
        return
    end

    local tc = g_currentMission.TheContractor
    local invoice = self.invoicesById[invoiceId]
    if invoice == nil or invoice.farmId ~= farmId or invoice.status ~= TheContractorFinances.STATUS.OVERDUE or
        not tc.Company:hasCompany(farmId) then
        return
    end

    local fee = tc.Association:getPursuitFee(farmId, invoice)
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm:getBalance() < fee then
        return
    end

    if fee > 0 then
        g_currentMission:addMoney(-fee, farmId, MoneyType.TC_LEGAL, true, true)
        self:addToYearStats(farmId, "legal", fee)
    end

    local environment = g_currentMission.environment
    local today = environment.currentMonotonicDay
    invoice.pursuitStartDay = today
    invoice.pursuitFee = fee
    invoice.pursuitResolveDay = today + math.random(TheContractorFinances.PURSUIT_MIN_PERIODS * environment.daysPerPeriod,
        TheContractorFinances.PURSUIT_MAX_PERIODS * environment.daysPerPeriod)
    self:setInvoiceStatus(invoice, TheContractorFinances.STATUS.PURSUING)
    -- 113: the customer won't thank you for the solicitor's letter.
    tc.Relationships:onInvoicePursued(farmId, tc.Jobs:getJob(farmId, invoice.jobId))

    TCLog.info("TheContractor: farm %d pursuing invoice %d (%s, fee %.0f), resolves day %d", farmId, invoice.id,
        fee == 0 and "legal cover" or "solicitor", fee, invoice.pursuitResolveDay)
end

-- Inbox args for a pursuit's outcome: job type, field, amount, fee.
function TheContractorFinances:getPursuitMessageArgs(invoice)
    local job = g_currentMission.TheContractor.Jobs:getJob(invoice.farmId, invoice.jobId)
    return {
        job ~= nil and ("$l10n_tc_jobType_" .. job:getTypeLabel()) or "$l10n_tc_legal_unknownJob",
        job ~= nil and job:getLocationText() or "?",
        "$money_" .. invoice.amount,
        "$money_" .. (invoice.pursuitFee or 0),
    }
end

-- Its resolve day has come: a late payer pays, a bad debt rolls - paid, or
-- written off with a message and a notice.
function TheContractorFinances:resolvePursuit(invoice)
    local isCovered = (invoice.pursuitFee or 0) == 0
    local chance = isCovered and TheContractorFinances.RECOVERY_CHANCE_COVERED or
        TheContractorFinances.RECOVERY_CHANCE_SOLICITOR
    local roll = math.random()

    TCLog.info("TheContractor: farm %d invoice %d pursuit resolved: %s", invoice.farmId, invoice.id,
        invoice.isBadDebt and string.format("bad debt, roll %.3f vs %.2f", roll, chance) or "late payer, pays")

    if not invoice.isBadDebt or roll < chance then
        self:payInvoice(invoice)
        return
    end

    self:writeOffInvoice(invoice, false)

    local tc = g_currentMission.TheContractor
    tc.Inbox:postMessage(invoice.farmId, TheContractorAssociation.MESSAGE_KIND, "tc_legal_failedTitle",
        isCovered and "tc_legal_failedBodyCovered" or "tc_legal_failedBodySolicitor",
        self:getPursuitMessageArgs(invoice), nil, { invoiceId = invoice.id })
    tc.Notices:publish(invoice.farmId, string.format(g_i18n:getText("tc_legal_failedNotice"),
        self:getInvoiceTitle(invoice), g_i18n:formatMoney(invoice.amount, 0, true, true)),
        TheContractorFinances.WRITE_OFF_NOTICE_MONTHS)
end

-- Daily tick (server-only) --------------------------------------------------

function TheContractorFinances:startDailyTick()
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
end

function TheContractorFinances:stopDailyTick()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
end

-- Pays whatever's due, then marks the unpaid ones overdue, then resolves
-- pursuits (053) and writes off the ones that have been overdue too long
-- (never one being pursued).
function TheContractorFinances:onDayChanged()
    local environment = g_currentMission.environment
    local today = environment.currentMonotonicDay
    local writeOffDays = TheContractorFinances.WRITE_OFF_AFTER_PERIODS * environment.daysPerPeriod

    local invoices = {}
    for _, invoice in pairs(self.invoicesById) do
        table.insert(invoices, invoice)
    end
    table.sort(invoices, function(a, b)
        return a.id < b.id
    end)

    for _, invoice in ipairs(invoices) do
        local isUnpaid = invoice.status == TheContractorFinances.STATUS.OUTSTANDING or
            invoice.status == TheContractorFinances.STATUS.OVERDUE or
            invoice.status == TheContractorFinances.STATUS.PURSUING

        if isUnpaid and invoice.paymentDay ~= nil and invoice.paymentDay <= today then
            self:payInvoice(invoice)
        elseif invoice.status == TheContractorFinances.STATUS.OUTSTANDING and invoice.dueDay <= today then
            self:setInvoiceStatus(invoice, TheContractorFinances.STATUS.OVERDUE)
        elseif invoice.status == TheContractorFinances.STATUS.PURSUING and
            (invoice.pursuitResolveDay == nil or invoice.pursuitResolveDay <= today) then
            self:resolvePursuit(invoice)
        elseif invoice.status == TheContractorFinances.STATUS.OVERDUE and today - invoice.dueDay >= writeOffDays then
            self:writeOffInvoice(invoice, true)
        end
    end
end

-- Year-to-date totals ------------------------------------------------------

-- Server-only: adds to one of this year's totals (starting the year afresh
-- if it's moved on) and sends the farm's totals to the clients.
function TheContractorFinances:addToYearStats(farmId, key, amount)
    if not g_currentMission:getIsServer() or amount == 0 then
        return
    end

    local stats = self:getYearStats(farmId)
    stats[key] = stats[key] + amount
    self:applyYearStats(farmId, stats)

    if g_server ~= nil then
        g_server:broadcastEvent(TCFinanceYearStatsEvent.new(farmId, stats))
    end
end

function TheContractorFinances:applyYearStats(farmId, stats)
    self.yearStatsByFarm[farmId] = stats
end

-- Staff's wage charges (036) - per-period salaries (with pension, 051) and
-- a new hire's first period.
function TheContractorFinances:recordWages(farmId, amount)
    self:addToYearStats(farmId, "wages", amount)
end

-- Overhead charges (051).
function TheContractorFinances:recordOverheads(farmId, amount)
    self:addToYearStats(farmId, "overheads", amount)
end

-- Compensation claims paid (052): the excess, or the lot if uninsured.
function TheContractorFinances:recordClaims(farmId, amount)
    self:addToYearStats(farmId, "claims", amount)
end

-- Certification courses and retakes (054).
function TheContractorFinances:recordTraining(farmId, amount)
    self:addToYearStats(farmId, "training", amount)
end

-- Health and safety inspection fines (055).
function TheContractorFinances:recordFines(farmId, amount)
    self:addToYearStats(farmId, "fines", amount)
end

-- Machinery insurance claims paid out to the farm (070).
function TheContractorFinances:recordInsurancePayout(farmId, amount)
    self:addToYearStats(farmId, "insurancePayouts", amount)
end

-- Refunds and rebates from good news stories (073).
function TheContractorFinances:recordGoodNews(farmId, amount)
    self:addToYearStats(farmId, "goodNews", amount)
end

-- Tipping fees for fly-tipped debris taken to a skip (075).
function TheContractorFinances:recordDisposal(farmId, amount)
    self:addToYearStats(farmId, "disposal", amount)
end

-- Wire serialization ---------------------------------------------------------
-- Public fields only - paymentDay/isBadDebt/isLate/pursuitResolveDay stay
-- on the server. settledDay/pursuitStartDay -1 = not settled/not pursued.

function TheContractorFinances.writeInvoice(streamId, invoice)
    streamWriteInt32(streamId, invoice.id)
    streamWriteInt32(streamId, invoice.farmId)
    streamWriteInt32(streamId, invoice.jobId)
    streamWriteFloat32(streamId, invoice.amount)
    streamWriteInt32(streamId, invoice.issuedDay)
    streamWriteInt32(streamId, invoice.dueDay)
    streamWriteString(streamId, invoice.status)
    streamWriteInt32(streamId, invoice.settledDay or -1)
    streamWriteInt32(streamId, invoice.pursuitStartDay or -1)
    streamWriteFloat32(streamId, invoice.pursuitFee or 0)
end

function TheContractorFinances.readInvoice(streamId)
    local invoice = {
        id = streamReadInt32(streamId),
        farmId = streamReadInt32(streamId),
        jobId = streamReadInt32(streamId),
        amount = streamReadFloat32(streamId),
        issuedDay = streamReadInt32(streamId),
        dueDay = streamReadInt32(streamId),
        status = streamReadString(streamId),
        settledDay = streamReadInt32(streamId),
        pursuitStartDay = streamReadInt32(streamId),
        pursuitFee = streamReadFloat32(streamId),
    }
    if invoice.settledDay < 0 then
        invoice.settledDay = nil
    end
    if invoice.pursuitStartDay < 0 then
        invoice.pursuitStartDay = nil
        invoice.pursuitFee = nil
    end
    return invoice
end

function TheContractorFinances.writeYearStats(streamId, stats)
    streamWriteInt32(streamId, stats.year)
    for _, key in ipairs(TheContractorFinances.YEAR_STAT_KEYS) do
        streamWriteFloat32(streamId, stats[key])
    end
end

function TheContractorFinances.readYearStats(streamId)
    local stats = { year = streamReadInt32(streamId) }
    for _, key in ipairs(TheContractorFinances.YEAR_STAT_KEYS) do
        stats[key] = streamReadFloat32(streamId)
    end
    return stats
end

-- Persistence ------------------------------------------------------------------

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorFinances:forgetFarm(farmId)
    for id, invoice in pairs(self.invoicesById) do
        if invoice.farmId == farmId then
            self.invoicesById[id] = nil
        end
    end
    self.yearStatsByFarm[farmId] = nil
end

function TheContractorFinances:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.invoicesById = {}
    self.yearStatsByFarm = {}

    local rootKey = string.format("%s.finances", TheContractor.SaveKey)
    self.nextInvoiceId = Utils.getNoNil(getXMLInt(xmlFile, rootKey .. "#nextInvoiceId"), 1)

    local index = 0
    while true do
        local key = string.format("%s.invoice(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        self:applyInvoiceIssued({
            id = getXMLInt(xmlFile, key .. "#id"),
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            jobId = getXMLInt(xmlFile, key .. "#jobId"),
            amount = getXMLFloat(xmlFile, key .. "#amount"),
            issuedDay = getXMLInt(xmlFile, key .. "#issuedDay"),
            dueDay = getXMLInt(xmlFile, key .. "#dueDay"),
            status = Utils.getNoNil(getXMLString(xmlFile, key .. "#status"), TheContractorFinances.STATUS.OUTSTANDING),
            settledDay = getXMLInt(xmlFile, key .. "#settledDay"),
            paymentDay = getXMLInt(xmlFile, key .. "#paymentDay"),
            isBadDebt = Utils.getNoNil(getXMLBool(xmlFile, key .. "#isBadDebt"), false),
            isLate = Utils.getNoNil(getXMLBool(xmlFile, key .. "#isLate"), false),
            pursuitStartDay = getXMLInt(xmlFile, key .. "#pursuitStartDay"),
            pursuitFee = getXMLFloat(xmlFile, key .. "#pursuitFee"),
            pursuitResolveDay = getXMLInt(xmlFile, key .. "#pursuitResolveDay"),
        })

        index = index + 1
    end

    index = 0
    while true do
        local key = string.format("%s.yearStats(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        local stats = { year = Utils.getNoNil(getXMLInt(xmlFile, key .. "#year"), 1) }
        for _, statKey in ipairs(TheContractorFinances.YEAR_STAT_KEYS) do
            stats[statKey] = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#" .. statKey), 0)
        end
        self.yearStatsByFarm[getXMLInt(xmlFile, key .. "#farmId")] = stats

        index = index + 1
    end
end

-- Drops long-settled invoices here rather than at load, when the
-- environment's day is certainly the savegame's. Clients keep their copies
-- until they next join, which does no harm.
function TheContractorFinances:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local environment = g_currentMission.environment
    local keepAfterDay = environment.currentMonotonicDay -
        TheContractorFinances.KEEP_SETTLED_PERIODS * environment.daysPerPeriod

    local rootKey = string.format("%s.finances", TheContractor.SaveKey)
    setXMLInt(xmlFile, rootKey .. "#nextInvoiceId", self.nextInvoiceId)

    local index = 0
    for _, invoice in pairs(self.invoicesById) do
        if invoice.settledDay == nil or invoice.settledDay >= keepAfterDay then
            local key = string.format("%s.invoice(%d)", rootKey, index)
            setXMLInt(xmlFile, key .. "#id", invoice.id)
            setXMLInt(xmlFile, key .. "#farmId", invoice.farmId)
            setXMLInt(xmlFile, key .. "#jobId", invoice.jobId)
            setXMLFloat(xmlFile, key .. "#amount", invoice.amount)
            setXMLInt(xmlFile, key .. "#issuedDay", invoice.issuedDay)
            setXMLInt(xmlFile, key .. "#dueDay", invoice.dueDay)
            setXMLString(xmlFile, key .. "#status", invoice.status)
            if invoice.settledDay ~= nil then
                setXMLInt(xmlFile, key .. "#settledDay", invoice.settledDay)
            end
            if invoice.paymentDay ~= nil then
                setXMLInt(xmlFile, key .. "#paymentDay", invoice.paymentDay)
            end
            setXMLBool(xmlFile, key .. "#isBadDebt", invoice.isBadDebt)
            setXMLBool(xmlFile, key .. "#isLate", invoice.isLate)
            if invoice.pursuitStartDay ~= nil then
                setXMLInt(xmlFile, key .. "#pursuitStartDay", invoice.pursuitStartDay)
                setXMLFloat(xmlFile, key .. "#pursuitFee", invoice.pursuitFee or 0)
            end
            if invoice.pursuitResolveDay ~= nil then
                setXMLInt(xmlFile, key .. "#pursuitResolveDay", invoice.pursuitResolveDay)
            end
            index = index + 1
        end
    end

    index = 0
    for farmId, stats in pairs(self.yearStatsByFarm) do
        local key = string.format("%s.yearStats(%d)", rootKey, index)
        setXMLInt(xmlFile, key .. "#farmId", farmId)
        setXMLInt(xmlFile, key .. "#year", stats.year)
        for _, statKey in ipairs(TheContractorFinances.YEAR_STAT_KEYS) do
            setXMLFloat(xmlFile, key .. "#" .. statKey, stats[statKey])
        end
        index = index + 1
    end
end

function TheContractorFinances:writeInitialClientState(streamId, connection)
    local invoices = {}
    for _, invoice in pairs(self.invoicesById) do
        table.insert(invoices, invoice)
    end

    streamWriteInt32(streamId, #invoices)
    for _, invoice in ipairs(invoices) do
        TheContractorFinances.writeInvoice(streamId, invoice)
    end

    local farmIds = {}
    for farmId in pairs(self.yearStatsByFarm) do
        table.insert(farmIds, farmId)
    end

    streamWriteInt32(streamId, #farmIds)
    for _, farmId in ipairs(farmIds) do
        streamWriteInt32(streamId, farmId)
        TheContractorFinances.writeYearStats(streamId, self.yearStatsByFarm[farmId])
    end
end

function TheContractorFinances:readInitialClientState(streamId, connection)
    local invoiceCount = streamReadInt32(streamId)
    for _ = 1, invoiceCount do
        self:applyInvoiceIssued(TheContractorFinances.readInvoice(streamId))
    end

    local farmCount = streamReadInt32(streamId)
    for _ = 1, farmCount do
        local farmId = streamReadInt32(streamId)
        self:applyYearStats(farmId, TheContractorFinances.readYearStats(streamId))
    end
end

-- Console commands (tcDebug - see TCConsole) -----------------------------------------

function TheContractorFinances.registerConsoleCommands()
    -- Server-only, since it shows what clients never get: when (or whether)
    -- each invoice will really be paid.
    TCConsole.register("debug", "invoices", {
        description = "Your invoices, with the hidden late/bad-debt rolls and pursuit details",
        run = function(farmId, args)
            local lines = { string.format("Farm %d invoices (today is day %d):", farmId,
                g_currentMission.environment.currentMonotonicDay) }
            for _, invoice in pairs(g_currentMission.TheContractor.Finances.invoicesById) do
                if invoice.farmId == farmId then
                    local outcome = "pays on time"
                    if invoice.isBadDebt then
                        outcome = "bad debt, never pays"
                    elseif invoice.isLate then
                        outcome = string.format("late, pays day %d", invoice.paymentDay)
                    end
                    if invoice.status == TheContractorFinances.STATUS.PURSUING then
                        outcome = string.format("%s; pursued since day %d (%s), resolves day %d", outcome,
                            invoice.pursuitStartDay or -1, (invoice.pursuitFee or 0) == 0 and "legal cover" or
                            string.format("solicitor, fee %.0f", invoice.pursuitFee), invoice.pursuitResolveDay or -1)
                    end
                    table.insert(lines, string.format("#%d job %d: %.0f, issued day %d, due day %d, %s (%s)", invoice.id,
                        invoice.jobId, invoice.amount, invoice.issuedDay, invoice.dueDay, invoice.status, outcome))
                end
            end
            return table.concat(lines, "\n")
        end,
    })
end
