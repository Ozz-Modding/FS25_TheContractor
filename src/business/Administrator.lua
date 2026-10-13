-- Office administrator (057): credit control. A per-farm role, not a field
-- worker - no roster entry, allocation, skills, growth, sickness or
-- holidays. adminByFarm[farmId] = { name, salary, hiredPeriod, ageAtHire };
-- presence in the table IS "has an administrator".
--
-- Hired and released from the Finances tab (the Overheads view lists the
-- role as its last row). The salary is paid with the period salary run
-- under TC_WAGES (TheContractorStaff:getPayroll), so it carries the 051
-- pension and counts toward employer's liability (getHeadcount). Like a
-- worker, the first period is paid up front at hire. Releasing pays 056's
-- notice and redundancy (TheContractorStaff.getReleaseCost) by service and
-- age, ageAtHire plus the years served, since the role doesn't age itself.
--
-- While one is employed, invoices issued (049, TheContractorFinances:
-- invoiceJob) get shorter payment delays and lower bad-debt and late-payer
-- chances: the rolls happen at issue, so it only affects invoices issued
-- from then on. Without one, 049's own numbers apply.

TheContractorAdministrator = {}
TheContractorAdministrator_mt = Class(TheContractorAdministrator)

TheContractorAdministrator.SALARY = 2000
TheContractorAdministrator.AGE_MIN = 22
TheContractorAdministrator.AGE_MAX = 58

-- Credit control: replaces TheContractorFinances.DELAY_WEIGHTS and its
-- bad-debt chance, and multiplies its late-payer chance.
TheContractorAdministrator.DELAY_WEIGHTS = {
    { periods = 0, weight = 50 },
    { periods = 1, weight = 35 },
    { periods = 2, weight = 12 },
    { periods = 3, weight = 3 },
}
TheContractorAdministrator.BAD_DEBT_CHANCE = 0.025
TheContractorAdministrator.LATE_PAYER_MULTIPLIER = 0.5

TheContractorAdministrator.REQUEST = {
    HIRE = "hire",
    RELEASE = "release",
}

function TheContractorAdministrator.new()
    local self = {}
    setmetatable(self, TheContractorAdministrator_mt)

    self.adminByFarm = {}

    return self
end

-- Query API -----------------------------------------------------------------------

function TheContractorAdministrator:getAdministrator(farmId)
    return self.adminByFarm[farmId]
end

function TheContractorAdministrator:isEmployed(farmId)
    return self.adminByFarm[farmId] ~= nil
end

-- This month's salary (TheContractorStaff.scalePay), 0 without one.
function TheContractorAdministrator:getSalary(farmId)
    local admin = self.adminByFarm[farmId]
    return admin ~= nil and TheContractorStaff.scalePay(admin.salary) or 0
end

function TheContractorAdministrator:getFarmIds()
    local farmIds = {}
    for farmId in pairs(self.adminByFarm) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)
    return farmIds
end

-- 049's invoice rolls for this farm.
function TheContractorAdministrator:getDelayWeights(farmId)
    return self:isEmployed(farmId) and TheContractorAdministrator.DELAY_WEIGHTS or TheContractorFinances.DELAY_WEIGHTS
end

function TheContractorAdministrator:getBadDebtChance(farmId)
    return self:isEmployed(farmId) and TheContractorAdministrator.BAD_DEBT_CHANCE or
        TheContractorFinances.BAD_DEBT_CHANCE
end

function TheContractorAdministrator:getLatePayerChance(farmId)
    local chance = TheContractorFinances.LATE_PAYER_CHANCE
    if self:isEmployed(farmId) then
        chance = chance * TheContractorAdministrator.LATE_PAYER_MULTIPLIER
    end
    return chance
end

-- What releasing them today costs, the same way as a worker (056), on
-- every machine so the confirm dialog shows what the server charges.
function TheContractorAdministrator.getReleaseCost(admin)
    local years = TheContractorStaff.getYearsOfService(admin)
    return TheContractorStaff.getReleaseCost({
        salary = admin.salary,
        hiredPeriod = admin.hiredPeriod,
        age = admin.ageAtHire + years,
        isLeaving = function()
            return false
        end,
    })
end

-- Hiring and releasing (server-only) ------------------------------------------------

-- The first month's salary is paid at hire, so that's what has to be
-- affordable.
function TheContractorAdministrator:canAffordHire(farmId)
    local farm = g_farmManager:getFarmById(farmId)
    return farm ~= nil and farm:getBalance() >= TheContractorStaff.scalePay(TheContractorAdministrator.SALARY)
end

-- Server side of TCAdministratorRequestEvent: re-checks everything.
function TheContractorAdministrator:handleRequest(farmId, request)
    if not g_currentMission:getIsServer() or not g_currentMission.TheContractor.Company:hasCompany(farmId) then
        return
    end

    if request == TheContractorAdministrator.REQUEST.HIRE then
        self:hire(farmId)
    elseif request == TheContractorAdministrator.REQUEST.RELEASE then
        self:release(farmId)
    end
end

function TheContractorAdministrator:hire(farmId)
    if self:isEmployed(farmId) or not self:canAffordHire(farmId) then
        return
    end

    local tc = g_currentMission.TheContractor
    local admin = {
        name = TheContractorStaff.generateName(TCWorkerAppearance.rollGender()),
        salary = TheContractorAdministrator.SALARY,
        hiredPeriod = TCCalendar.getPeriodIndex(),
        ageAtHire = math.random(TheContractorAdministrator.AGE_MIN, TheContractorAdministrator.AGE_MAX),
    }

    local firstPay = TheContractorStaff.scalePay(admin.salary)
    g_currentMission:addMoney(-firstPay, farmId, MoneyType.TC_WAGES, true, true)
    tc.Finances:recordWages(farmId, firstPay)

    self:commit(farmId, admin)

    -- 051: an employee, so employer's liability is required.
    tc.Overheads:ensureRequired(farmId)

    Logging.info("TheContractor: farm %d hired office administrator %s (salary %.0f)", farmId, admin.name,
        admin.salary)
end

-- Notice and redundancy pay, even into the red, since it's owed (056).
function TheContractorAdministrator:release(farmId)
    local admin = self.adminByFarm[farmId]
    if admin == nil then
        return
    end

    local cost = TheContractorAdministrator.getReleaseCost(admin)
    if cost.total > 0 then
        g_currentMission:addMoney(-cost.total, farmId, MoneyType.TC_WAGES, true, true)
        g_currentMission.TheContractor.Finances:recordWages(farmId, cost.total)
    end

    self:commit(farmId, nil)

    Logging.info("TheContractor: farm %d released office administrator %s after %d year(s): %.0f notice, %.0f redundancy",
        farmId, admin.name, cost.years, cost.noticePay, cost.redundancyPay)
end

-- Applies locally, then sends it to the clients.
function TheContractorAdministrator:commit(farmId, admin)
    self:applyAdministrator(farmId, admin)

    if g_server ~= nil then
        g_server:broadcastEvent(TCAdministratorChangedEvent.new(farmId, admin))
    end
end

-- Run on whichever machine is applying it (server, or a client receiving
-- TCAdministratorChangedEvent). Tells the farm's player.
function TheContractorAdministrator:applyAdministrator(farmId, admin)
    local previous = self.adminByFarm[farmId]
    self.adminByFarm[farmId] = admin

    if g_client == nil or g_currentMission:getFarmId() ~= farmId then
        return
    end
    if admin ~= nil and previous == nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_admin_hiredNotification"), admin.name))
    elseif admin == nil and previous ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(g_i18n:getText("tc_admin_releasedNotification"), previous.name))
    end
end

-- Wire serialization ----------------------------------------------------------------
-- admin may be nil (none employed).

function TheContractorAdministrator.writeAdministrator(streamId, admin)
    if streamWriteBool(streamId, admin ~= nil) then
        streamWriteString(streamId, admin.name)
        streamWriteFloat32(streamId, admin.salary)
        streamWriteInt32(streamId, admin.hiredPeriod)
        streamWriteInt32(streamId, admin.ageAtHire)
    end
end

function TheContractorAdministrator.readAdministrator(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    return {
        name = streamReadString(streamId),
        salary = streamReadFloat32(streamId),
        hiredPeriod = streamReadInt32(streamId),
        ageAtHire = streamReadInt32(streamId),
    }
end

-- Persistence ------------------------------------------------------------------------

function TheContractorAdministrator:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.adminByFarm = {}

    local index = 0
    while true do
        local key = string.format("%s.administrators.administrator(%d)", TheContractor.SaveKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        if farmId ~= nil then
            self.adminByFarm[farmId] = {
                name = Utils.getNoNil(getXMLString(xmlFile, key .. "#name"), "?"),
                salary = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#salary"), TheContractorAdministrator.SALARY),
                hiredPeriod = Utils.getNoNil(getXMLInt(xmlFile, key .. "#hiredPeriod"), 0),
                ageAtHire = Utils.getNoNil(getXMLInt(xmlFile, key .. "#ageAtHire"), TheContractorAdministrator.AGE_MIN),
            }
        end

        index = index + 1
    end
end

function TheContractorAdministrator:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    for index, farmId in ipairs(self:getFarmIds()) do
        local admin = self.adminByFarm[farmId]
        local key = string.format("%s.administrators.administrator(%d)", TheContractor.SaveKey, index - 1)
        setXMLInt(xmlFile, key .. "#farmId", farmId)
        setXMLString(xmlFile, key .. "#name", admin.name)
        setXMLFloat(xmlFile, key .. "#salary", admin.salary)
        setXMLInt(xmlFile, key .. "#hiredPeriod", admin.hiredPeriod)
        setXMLInt(xmlFile, key .. "#ageAtHire", admin.ageAtHire)
    end
end

function TheContractorAdministrator:writeInitialClientState(streamId, connection)
    local farmIds = self:getFarmIds()
    streamWriteInt32(streamId, #farmIds)
    for _, farmId in ipairs(farmIds) do
        streamWriteInt32(streamId, farmId)
        TheContractorAdministrator.writeAdministrator(streamId, self.adminByFarm[farmId])
    end
end

function TheContractorAdministrator:readInitialClientState(streamId, connection)
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local farmId = streamReadInt32(streamId)
        self.adminByFarm[farmId] = TheContractorAdministrator.readAdministrator(streamId)
    end
end
