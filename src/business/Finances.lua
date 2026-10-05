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
-- sooner from the Finances tab. Recovering a debt is 053's.
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
}

-- Payment delay in whole periods, weighted toward shorter ones. A random
-- day within the period goes on top, so payments don't all land on a
-- period boundary.
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

-- Settled (paid/written off) invoices are dropped from the save once
-- they're this many periods old - nothing reads them after that.
TheContractorFinances.KEEP_SETTLED_PERIODS = 12

-- The forecast covers this month and the next FORECAST_PERIODS - 1.
TheContractorFinances.FORECAST_PERIODS = 3

TheContractorFinances.YEAR_STAT_KEYS = { "invoiced", "received", "writtenOff", "wages" }

function TheContractorFinances.new()
    local self = {}
    setmetatable(self, TheContractorFinances_mt)

    -- invoicesById[id] = invoice. Ids are unique across all farms.
    self.invoicesById = {}
    self.nextInvoiceId = 1

    -- yearStatsByFarm[farmId] = { year, invoiced, received, writtenOff, wages }
    self.yearStatsByFarm = {}

    return self
end

-- Query API -----------------------------------------------------------------

function TheContractorFinances:getInvoice(invoiceId)
    return self.invoicesById[invoiceId]
end

-- The farm's invoices that haven't been paid (outstanding, overdue and
-- written off), oldest due first.
function TheContractorFinances:getUnpaidInvoices(farmId)
    local result = {}
    for _, invoice in pairs(self.invoicesById) do
        if invoice.farmId == farmId and invoice.status ~= TheContractorFinances.STATUS.PAID then
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

-- This year's totals for the farm; zeros if nothing's happened this year.
function TheContractorFinances:getYearStats(farmId)
    local stats = self.yearStatsByFarm[farmId]
    if stats == nil or stats.year ~= g_currentMission.environment.currentYear then
        return { year = g_currentMission.environment.currentYear, invoiced = 0, received = 0, writtenOff = 0, wages = 0 }
    end
    return stats
end

-- Cash-flow forecast: { periodIndex, income, wages } for this month and
-- the next FORECAST_PERIODS - 1. income is what outstanding invoices are
-- due to bring in that month, by their due day - overdue ones aren't
-- counted, since nobody knows if they'll pay. wages is the current salary
-- bill, charged at the start of each month, so this month's (already paid)
-- is 0.
function TheContractorFinances:getForecast(farmId)
    local firstIndex = TCCalendar.getPeriodIndex()
    local salary = g_currentMission.TheContractor.Staff:getTotalSalary(farmId)

    local rows = {}
    for i = 1, TheContractorFinances.FORECAST_PERIODS do
        table.insert(rows, { periodIndex = firstIndex + i - 1, income = 0, wages = i > 1 and salary or 0 })
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

local function rollDelayPeriods()
    local totalWeight = 0
    for _, entry in ipairs(TheContractorFinances.DELAY_WEIGHTS) do
        totalWeight = totalWeight + entry.weight
    end
    local roll = math.random() * totalWeight
    for _, entry in ipairs(TheContractorFinances.DELAY_WEIGHTS) do
        roll = roll - entry.weight
        if roll < 0 then
            return entry.periods
        end
    end
    return TheContractorFinances.DELAY_WEIGHTS[#TheContractorFinances.DELAY_WEIGHTS].periods
end

-- Called from TheContractorJobs:completeJob with job.paymentAmount set.
-- Either invoices it (setting job.invoiceDueDay) or, with late/unpaid
-- invoices switched off, pays it now.
function TheContractorFinances:invoiceJob(job)
    if not g_currentMission:getIsServer() then
        return
    end

    local amount = job.paymentAmount
    self:addToYearStats(job.farmId, "invoiced", amount)

    if not g_currentMission.TheContractor.Settings:get("lateInvoices") then
        g_currentMission:addMoney(amount, job.farmId, MoneyType.TC_JOB_PAYOUT, true, true)
        self:addToYearStats(job.farmId, "received", amount)
        return
    end

    local environment = g_currentMission.environment
    local today = environment.currentMonotonicDay
    local daysPerPeriod = environment.daysPerPeriod

    -- At least a day, so even a prompt payer pays on a later day tick.
    local delayDays = math.max(1, rollDelayPeriods() * daysPerPeriod + math.random(0, daysPerPeriod - 1))
    local dueDay = today + delayDays

    local isBadDebt = math.random() < TheContractorFinances.BAD_DEBT_CHANCE
    local isLate = not isBadDebt and math.random() < TheContractorFinances.LATE_PAYER_CHANCE
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

    Logging.info("TheContractor: farm %d invoice %d for job %d: %.0f due day %d (%s)", invoice.farmId, invoice.id,
        invoice.jobId, amount, dueDay, isBadDebt and "bad debt" or (isLate and ("late, pays day " .. paymentDay) or "on time"))
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

    self:applyInvoiceStatus(invoice.id, status, settledDay)

    if g_server ~= nil then
        g_server:broadcastEvent(TCInvoiceStatusChangedEvent.new(invoice.id, status, settledDay))
    end
end

-- The actual status change, run on whichever machine (server, or a client
-- receiving TCInvoiceStatusChangedEvent) is applying it. Tells the farm's
-- player when one's paid.
function TheContractorFinances:applyInvoiceStatus(invoiceId, status, settledDay)
    local invoice = self.invoicesById[invoiceId]
    if invoice == nil then
        return
    end

    invoice.status = status
    invoice.settledDay = settledDay

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
    local field = g_fieldManager:getFieldById(job.fieldId)
    return string.format(g_i18n:getText("tc_finances_invoiceTitle"), job:getDisplayTitle(),
        field ~= nil and field:getName() or tostring(job.fieldId))
end

function TheContractorFinances:payInvoice(invoice)
    g_currentMission:addMoney(invoice.amount, invoice.farmId, MoneyType.TC_JOB_PAYOUT, true, true)
    self:addToYearStats(invoice.farmId, "received", invoice.amount)
    self:setInvoiceStatus(invoice, TheContractorFinances.STATUS.PAID)
    Logging.info("TheContractor: farm %d invoice %d paid (%.0f)", invoice.farmId, invoice.id, invoice.amount)
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

    Logging.info("TheContractor: farm %d invoice %d written off (%.0f, %s)", invoice.farmId, invoice.id,
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

-- Pays whatever's due, then marks the unpaid ones overdue, then writes off
-- the ones that have been overdue too long.
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
            invoice.status == TheContractorFinances.STATUS.OVERDUE

        if isUnpaid and invoice.paymentDay ~= nil and invoice.paymentDay <= today then
            self:payInvoice(invoice)
        elseif invoice.status == TheContractorFinances.STATUS.OUTSTANDING and invoice.dueDay <= today then
            self:setInvoiceStatus(invoice, TheContractorFinances.STATUS.OVERDUE)
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

-- Staff's wage charges (036) - per-period salaries and a new hire's first
-- period.
function TheContractorFinances:recordWages(farmId, amount)
    self:addToYearStats(farmId, "wages", amount)
end

-- Wire serialization ---------------------------------------------------------
-- Public fields only - paymentDay/isBadDebt/isLate stay on the server.
-- settledDay -1 = not settled.

function TheContractorFinances.writeInvoice(streamId, invoice)
    streamWriteInt32(streamId, invoice.id)
    streamWriteInt32(streamId, invoice.farmId)
    streamWriteInt32(streamId, invoice.jobId)
    streamWriteFloat32(streamId, invoice.amount)
    streamWriteInt32(streamId, invoice.issuedDay)
    streamWriteInt32(streamId, invoice.dueDay)
    streamWriteString(streamId, invoice.status)
    streamWriteInt32(streamId, invoice.settledDay or -1)
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
    }
    if invoice.settledDay < 0 then
        invoice.settledDay = nil
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
