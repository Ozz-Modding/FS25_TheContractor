-- Short months pay less (TheContractorStaff.getPayFactor): SHORT_MONTH_PAY
-- of a full month's pay at 1 day per period, rising evenly to full pay at
-- FULL_PAY_DAYS, read live from the save's daysPerPeriod.

local function setup(daysPerPeriod)
    local world = stubs.install()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    TCCalendar = {
        getPeriodIndex = function()
            return 40
        end,
    }
    world:load("src/business/Staff.lua")
    world:load("src/business/Administrator.lua")

    g_currentMission.environment = { daysPerPeriod = daysPerPeriod }
    local staff = setmetatable({ workersByFarm = {} }, TheContractorStaff_mt)
    local administrator = setmetatable({ adminByFarm = {} }, TheContractorAdministrator_mt)
    g_currentMission.TheContractor = { Staff = staff, Administrator = administrator }
    return staff, administrator
end

local function addWorker(staff, salary, hiredPeriod)
    local worker = {
        id = #(staff.workersByFarm[1] or {}) + 1,
        salary = salary,
        hiredPeriod = hiredPeriod or 40,
        age = 40,
        isLeaving = function()
            return false
        end,
    }
    staff.workersByFarm[1] = staff.workersByFarm[1] or {}
    staff.workersByFarm[1][worker.id] = worker
    return worker
end

test("pay is 60% at 1 day, 100% at 5 and evenly between", function()
    setup(1)
    assertNear(TheContractorStaff.getPayFactor(1), 0.6, 0.0001, "1 day")
    assertNear(TheContractorStaff.getPayFactor(2), 0.7, 0.0001, "2 days")
    assertNear(TheContractorStaff.getPayFactor(3), 0.8, 0.0001, "3 days")
    assertNear(TheContractorStaff.getPayFactor(4), 0.9, 0.0001, "4 days")
    assertNear(TheContractorStaff.getPayFactor(5), 1, 0.0001, "5 days")
end)

test("longer months than 5 days stay at full pay", function()
    setup(1)
    assertNear(TheContractorStaff.getPayFactor(28), 1, 0.0001, "28 days")
end)

test("the salary run follows the setting as it changes", function()
    local staff = setup(1)
    addWorker(staff, 2000)
    addWorker(staff, 3000)
    assertEquals(staff:getTotalSalary(1), 3000, "1 day")

    g_currentMission.environment.daysPerPeriod = 3
    assertEquals(staff:getTotalSalary(1), 4000, "3 days")

    g_currentMission.environment.daysPerPeriod = 5
    assertEquals(staff:getTotalSalary(1), 5000, "5 days")
end)

test("the administrator and pension are scaled too", function()
    local staff, administrator = setup(1)
    addWorker(staff, 2000)
    administrator.adminByFarm[1] = { name = "Ann", salary = 2000, hiredPeriod = 40, ageAtHire = 30 }
    assertEquals(administrator:getSalary(1), 1200, "administrator")
    assertEquals(staff:getPayroll(1), 2400, "payroll")
    assertNear(staff:getWageBill(1), 2400 * (1 + TheContractorStaff.PENSION_RATE), 0.0001, "wage bill")
end)

test("notice pay comes from the scaled pay", function()
    local staff = setup(1)
    local worker = addWorker(staff, 2600, 40 - 3 * 12)
    local cost = TheContractorStaff.getReleaseCost(worker)
    -- 3 years' service: 3 weeks' notice of 2600 x 0.6 x 12 / 52 = 360.
    assertEquals(cost.noticePay, 1080, "notice pay")
end)
