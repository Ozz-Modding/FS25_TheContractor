-- The Finances tab's two invoice views: open invoices (outstanding, overdue,
-- pursuing), oldest due first, and the history (paid, written off) from the
-- last two years, latest settled first.

local function setup()
    local world = stubs.install()
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 1,
        currentDayInPeriod = 1,
        daysPerPeriod = 2,
        plannedDaysPerPeriod = 2,
        currentMonotonicDay = 100,
    }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TheContractor = { SaveKey = "TheContractor" }
    world:load("src/business/Finances.lua")
    return TheContractorFinances.new()
end

local function addInvoice(finances, id, farmId, status, dueDay, settledDay)
    finances:applyInvoiceIssued({ id = id, farmId = farmId, jobId = id, amount = 100, issuedDay = 1, dueDay = dueDay,
        status = status, settledDay = settledDay })
end

local function ids(invoices)
    local result = {}
    for _, invoice in ipairs(invoices) do
        table.insert(result, invoice.id)
    end
    return table.concat(result, ",")
end

test("open invoices leave out paid and written-off ones", function()
    local finances = setup()
    local STATUS = TheContractorFinances.STATUS
    addInvoice(finances, 1, 1, STATUS.OUTSTANDING, 90)
    addInvoice(finances, 2, 1, STATUS.OVERDUE, 50)
    addInvoice(finances, 3, 1, STATUS.PURSUING, 70)
    addInvoice(finances, 4, 1, STATUS.PAID, 40, 60)
    addInvoice(finances, 5, 1, STATUS.WRITTEN_OFF, 30, 80)
    addInvoice(finances, 6, 2, STATUS.OUTSTANDING, 10)

    assertEquals(ids(finances:getOpenInvoices(1)), "2,3,1", "oldest due first, this farm only")
end)

test("the history keeps two years of settled invoices, latest first", function()
    local finances = setup()
    local STATUS = TheContractorFinances.STATUS
    -- Two years at 2 days a period is 48 days, so day 52 is the oldest kept.
    addInvoice(finances, 1, 1, STATUS.PAID, 40, 60)
    addInvoice(finances, 2, 1, STATUS.WRITTEN_OFF, 30, 90)
    addInvoice(finances, 3, 1, STATUS.PAID, 20, 52)
    addInvoice(finances, 4, 1, STATUS.PAID, 10, 51)
    addInvoice(finances, 5, 1, STATUS.OUTSTANDING, 95)
    addInvoice(finances, 6, 2, STATUS.PAID, 40, 99)

    assertEquals(ids(finances:getSettledInvoices(1)), "2,1,3")
end)
