-- Office staff (090): the office administrator (057) and the storekeeper.
-- Per-farm roles, not field workers - no roster entry, allocation, skills,
-- growth, morale, sickness, holidays, pay reviews or poaching. But they are
-- people: each has a name, gender and look (041), shown in the Staff tab's
-- roster with their portrait, edited like a worker (066/077, through
-- TheContractorStaff:editWorker) and standing on standing spots (065).
--
-- membersByFarm[farmId][role] = { id, role, farmId, name, gender,
-- appearance, salary, level, hiredPeriod, ageAtHire, trainingUntilDay };
-- presence IS "employed". Ids come from Staff's worker id counter, so they
-- never clash with a worker's and fit every worker-id path (the edit
-- events, the portrait, TCIdleStaff).
--
-- Hired, released and trained from the Staff tab. The salary is paid with
-- the period salary run under TC_WAGES (TheContractorStaff:getPayroll), so
-- it carries the 051 pension and counts toward employer's liability
-- (getHeadcount). Like a worker, the first month is paid up front at hire.
-- Releasing pays 056's notice and redundancy (TheContractorStaff.
-- getReleaseCost) by service and age, ageAtHire plus the years served,
-- since office staff don't age themselves.
--
-- The administrator does credit control: while one is employed, invoices
-- issued (049, TheContractorFinances:invoiceJob) get shorter payment delays
-- and lower bad-debt and late-payer chances. The rolls happen at issue, so
-- it only affects invoices issued from then on.
--
-- With FS25_AdvancedDamageSystem handing its own-workshop staff to us
-- (TCADSWorkshop), the administrator is its receptionist and the
-- storekeeper its storekeeper, at their level (1-3). The storekeeper can
-- only be hired then. Train raises a level: a fixed cost (1x UK, scaleCost)
-- and a few days away (reported to ADS as training), then the salary steps
-- up to that level's figure. Pay is a fixed salary per level; there are no
-- pay reviews or market value.

TheContractorOffice = {}
TheContractorOffice_mt = Class(TheContractorOffice)

TheContractorOffice.ROLE = {
    ADMINISTRATOR = "administrator",
    STOREKEEPER = "storekeeper",
}

-- Display order.
TheContractorOffice.ROLE_ORDER = { "administrator", "storekeeper" }

TheContractorOffice.MAX_LEVEL = 3

-- salaries: full-month pay at levels 1-3 (1x UK, scalePay'd like a
-- worker's). trainCosts/trainDays: the course to level 2, then to level 3
-- (costs 1x UK, through scaleCost). adsRole: their role in ADS's own
-- workshop. requiresADS: only hired while ADS hands its staff to us.
TheContractorOffice.ROLES = {
    administrator = {
        salaries = { 2000, 2250, 2500 },
        trainCosts = { 500, 900 },
        trainDays = { 2, 3 },
        adsRole = "receptionist",
    },
    storekeeper = {
        salaries = { 1900, 2150, 2400 },
        trainCosts = { 400, 800 },
        trainDays = { 2, 3 },
        adsRole = "storekeeper",
        requiresADS = true,
    },
}

TheContractorOffice.AGE_MIN = 20
TheContractorOffice.AGE_MAX = 30

-- Credit control: replaces TheContractorFinances.DELAY_WEIGHTS and its
-- bad-debt chance, and multiplies its late-payer chance.
TheContractorOffice.DELAY_WEIGHTS = {
    { periods = 0, weight = 50 },
    { periods = 1, weight = 35 },
    { periods = 2, weight = 12 },
    { periods = 3, weight = 3 },
}
TheContractorOffice.BAD_DEBT_CHANCE = 0.025
TheContractorOffice.LATE_PAYER_MULTIPLIER = 0.5

TheContractorOffice.REQUEST = {
    HIRE = "hire",
    RELEASE = "release",
    TRAIN = "train",
}

TheContractorOffice.STATUS = {
    AVAILABLE = "available",
    TRAINING = "training",
}

-- Why a hire or a course can't go ahead (getHireProblem/getTrainProblem).
TheContractorOffice.PROBLEM = {
    UNKNOWN_ROLE = "unknownRole",
    EMPLOYED = "employed",
    NOT_EMPLOYED = "notEmployed",
    NEEDS_ADS = "needsADS",
    MAX_LEVEL = "maxLevel",
    TRAINING = "training",
}

function TheContractorOffice.new()
    local self = {}
    setmetatable(self, TheContractorOffice_mt)

    self.membersByFarm = {}

    return self
end

-- Query API -----------------------------------------------------------------------

function TheContractorOffice.getDefinition(role)
    return TheContractorOffice.ROLES[role]
end

function TheContractorOffice.getRoleName(role)
    return g_i18n:getText("tc_office_role_" .. role)
end

function TheContractorOffice.isTraining(member)
    return member.trainingUntilDay ~= nil
end

function TheContractorOffice.getStatus(member)
    return TheContractorOffice.isTraining(member) and TheContractorOffice.STATUS.TRAINING or
        TheContractorOffice.STATUS.AVAILABLE
end

-- Full-month pay at a level (unscaled, like a worker's salary).
function TheContractorOffice.getLevelSalary(role, level)
    local definition = TheContractorOffice.ROLES[role]
    return definition.salaries[math.max(1, math.min(level, #definition.salaries))]
end

function TheContractorOffice:getMember(farmId, role)
    local members = self.membersByFarm[farmId]
    return members ~= nil and members[role] or nil
end

-- The farm's office staff in ROLE_ORDER.
function TheContractorOffice:getMembers(farmId)
    local result = {}
    for _, role in ipairs(TheContractorOffice.ROLE_ORDER) do
        local member = self:getMember(farmId, role)
        if member ~= nil then
            table.insert(result, member)
        end
    end
    return result
end

function TheContractorOffice:getMemberById(farmId, id)
    for _, member in ipairs(self:getMembers(farmId)) do
        if member.id == id then
            return member
        end
    end
    return nil
end

function TheContractorOffice:isEmployed(farmId, role)
    return self:getMember(farmId, role) ~= nil
end

function TheContractorOffice:hasAdministrator(farmId)
    return self:isEmployed(farmId, TheContractorOffice.ROLE.ADMINISTRATOR)
end

-- This month's office salaries (TheContractorStaff.scalePay), 0 with none.
function TheContractorOffice:getSalary(farmId)
    local total = 0
    for _, member in ipairs(self:getMembers(farmId)) do
        total = total + member.salary
    end
    return TheContractorStaff.scalePay(total)
end

function TheContractorOffice:getHeadcount(farmId)
    return #self:getMembers(farmId)
end

-- Farms with anyone in the office, sorted.
function TheContractorOffice:getFarmIds()
    local farmIds = {}
    for farmId, members in pairs(self.membersByFarm) do
        if next(members) ~= nil then
            table.insert(farmIds, farmId)
        end
    end
    table.sort(farmIds)
    return farmIds
end

-- 049's invoice rolls for this farm.
function TheContractorOffice:getDelayWeights(farmId)
    return self:hasAdministrator(farmId) and TheContractorOffice.DELAY_WEIGHTS or TheContractorFinances.DELAY_WEIGHTS
end

function TheContractorOffice:getBadDebtChance(farmId)
    return self:hasAdministrator(farmId) and TheContractorOffice.BAD_DEBT_CHANCE or
        TheContractorFinances.BAD_DEBT_CHANCE
end

function TheContractorOffice:getLatePayerChance(farmId)
    local chance = TheContractorFinances.LATE_PAYER_CHANCE
    if self:hasAdministrator(farmId) then
        chance = chance * TheContractorOffice.LATE_PAYER_MULTIPLIER
    end
    return chance
end

-- What releasing them today costs, the same way as a worker (056), on
-- every machine so the confirm dialog shows what the server charges.
function TheContractorOffice.getReleaseCost(member)
    local years = TheContractorStaff.getYearsOfService(member)
    return TheContractorStaff.getReleaseCost({
        salary = member.salary,
        hiredPeriod = member.hiredPeriod,
        age = member.ageAtHire + years,
        isLeaving = function()
            return false
        end,
    })
end

-- Hiring ---------------------------------------------------------------------------

-- Whether the role's row is offered at all: always for the administrator,
-- the storekeeper only while employed or while ADS hands its staff to us.
function TheContractorOffice:isRoleShown(farmId, role)
    local definition = TheContractorOffice.ROLES[role]
    return definition ~= nil and
        (not definition.requiresADS or self:isEmployed(farmId, role) or TCADSWorkshop.isActive())
end

-- Why `role` can't be hired now, or nil. Same on every machine.
function TheContractorOffice:getHireProblem(farmId, role)
    local definition = TheContractorOffice.ROLES[role]
    if definition == nil then
        return TheContractorOffice.PROBLEM.UNKNOWN_ROLE
    end
    if self:isEmployed(farmId, role) then
        return TheContractorOffice.PROBLEM.EMPLOYED
    end
    if definition.requiresADS and not TCADSWorkshop.isActive() then
        return TheContractorOffice.PROBLEM.NEEDS_ADS
    end
    return nil
end

-- The first month's salary (scaled), paid at hire.
function TheContractorOffice.getFirstPay(role)
    return TheContractorStaff.scalePay(TheContractorOffice.getLevelSalary(role, 1))
end

function TheContractorOffice.canAfford(farmId, amount)
    local farm = g_farmManager:getFarmById(farmId)
    return farm ~= nil and farm:getBalance() >= amount
end

-- Training -------------------------------------------------------------------------

-- The course from `level` to the next: its cost (scaled) and days.
function TheContractorOffice.getTrainCost(role, level)
    local definition = TheContractorOffice.ROLES[role]
    local cost = definition.trainCosts[level]
    if cost == nil then
        return nil
    end
    return math.floor(g_currentMission.TheContractor.Settings:scaleCost(cost) + 0.5)
end

function TheContractorOffice.getTrainDays(role, level)
    -- Never longer than a month (054's scaleDays).
    return TheContractorTraining.scaleDays(TheContractorOffice.ROLES[role].trainDays[level])
end

-- Why `role` can't go on a course now, or nil. Same on every machine.
-- Training only matters to ADS's workshop, so it's only offered then.
function TheContractorOffice:getTrainProblem(farmId, role)
    local member = self:getMember(farmId, role)
    if member == nil then
        return TheContractorOffice.PROBLEM.NOT_EMPLOYED
    end
    if not TCADSWorkshop.isActive() then
        return TheContractorOffice.PROBLEM.NEEDS_ADS
    end
    if member.level >= TheContractorOffice.MAX_LEVEL then
        return TheContractorOffice.PROBLEM.MAX_LEVEL
    end
    if TheContractorOffice.isTraining(member) then
        return TheContractorOffice.PROBLEM.TRAINING
    end
    return nil
end

-- Requests (server-only) ------------------------------------------------------------

-- Server side of TCOfficeRequestEvent: re-checks everything.
function TheContractorOffice:handleRequest(farmId, role, request)
    if not g_currentMission:getIsServer() or not g_currentMission.TheContractor.Company:hasCompany(farmId) then
        return
    end

    if request == TheContractorOffice.REQUEST.HIRE then
        self:hire(farmId, role)
    elseif request == TheContractorOffice.REQUEST.RELEASE then
        self:release(farmId, role)
    elseif request == TheContractorOffice.REQUEST.TRAIN then
        self:train(farmId, role)
    end
end

-- Returns the new member, or nil.
function TheContractorOffice:hire(farmId, role)
    local problem = self:getHireProblem(farmId, role)
    if problem ~= nil then
        Logging.info("TheContractor: farm %d can't hire a %s: %s", farmId, tostring(role), problem)
        return nil
    end
    local firstPay = TheContractorOffice.getFirstPay(role)
    if not TheContractorOffice.canAfford(farmId, firstPay) then
        return nil
    end

    local tc = g_currentMission.TheContractor
    local gender = TCWorkerAppearance.rollGender()
    local member = {
        id = tc.Staff:takeWorkerId(),
        role = role,
        farmId = farmId,
        name = TheContractorStaff.generateName(gender),
        gender = gender,
        appearance = TCWorkerAppearance.roll(gender),
        salary = TheContractorOffice.getLevelSalary(role, 1),
        level = 1,
        hiredPeriod = TCCalendar.getPeriodIndex(),
        ageAtHire = math.random(TheContractorOffice.AGE_MIN, TheContractorOffice.AGE_MAX),
    }

    g_currentMission:addMoney(-firstPay, farmId, MoneyType.TC_WAGES, true, true)
    tc.Finances:recordWages(farmId, firstPay)

    self:commit(farmId, role, member)

    -- 051: an employee, so employer's liability is required.
    tc.Overheads:ensureRequired(farmId)

    Logging.info("TheContractor: farm %d hired %s as its %s (salary %.0f)", farmId, member.name, role,
        member.salary)
    return member
end

-- Notice and redundancy pay, even into the red, since it's owed (056).
function TheContractorOffice:release(farmId, role)
    local member = self:getMember(farmId, role)
    if member == nil then
        return
    end

    local cost = TheContractorOffice.getReleaseCost(member)
    if cost.total > 0 then
        g_currentMission:addMoney(-cost.total, farmId, MoneyType.TC_WAGES, true, true)
        g_currentMission.TheContractor.Finances:recordWages(farmId, cost.total)
    end

    self:commit(farmId, role, nil)

    Logging.info("TheContractor: farm %d released its %s %s after %d year(s): %.0f notice, %.0f redundancy",
        farmId, role, member.name, cost.years, cost.noticePay, cost.redundancyPay)
end

-- Books the course to the next level, paid up front. Returns true if booked.
function TheContractorOffice:train(farmId, role)
    local problem = self:getTrainProblem(farmId, role)
    if problem ~= nil then
        Logging.info("TheContractor: farm %d's %s can't train: %s", farmId, tostring(role), problem)
        return false
    end
    local member = self:getMember(farmId, role)
    local cost = TheContractorOffice.getTrainCost(role, member.level)
    if not TheContractorOffice.canAfford(farmId, cost) then
        return false
    end

    g_currentMission:addMoney(-cost, farmId, MoneyType.TC_TRAINING, true, true)
    g_currentMission.TheContractor.Finances:recordTraining(farmId, cost)

    local updated = TheContractorOffice.copyMember(member)
    updated.trainingUntilDay = g_currentMission.environment.currentMonotonicDay +
        TheContractorOffice.getTrainDays(role, member.level)
    self:commit(farmId, role, updated)

    Logging.info("TheContractor: farm %d's %s %s is training to level %d until day %d (%.0f)", farmId, role,
        member.name, member.level + 1, updated.trainingUntilDay, cost)
    return true
end

-- Daily tick (server-only, from Staff:onDayChanged): finished courses.
function TheContractorOffice:onDayChanged()
    local today = g_currentMission.environment.currentMonotonicDay
    for _, farmId in ipairs(self:getFarmIds()) do
        for _, member in ipairs(self:getMembers(farmId)) do
            if member.trainingUntilDay ~= nil and today >= member.trainingUntilDay then
                self:setLevel(farmId, member.role, member.level + 1)
            end
        end
    end
end

-- Sets the level and its salary, ending any course. Also the console's way
-- in. Returns the updated member, or nil.
function TheContractorOffice:setLevel(farmId, role, level)
    local member = self:getMember(farmId, role)
    if member == nil then
        return nil
    end

    local updated = TheContractorOffice.copyMember(member)
    updated.level = math.max(1, math.min(level, TheContractorOffice.MAX_LEVEL))
    updated.salary = TheContractorOffice.getLevelSalary(role, updated.level)
    updated.trainingUntilDay = nil
    self:commit(farmId, role, updated)

    Logging.info("TheContractor: farm %d's %s %s is now level %d (salary %.0f)", farmId, role, member.name,
        updated.level, updated.salary)
    return updated
end

-- A fresh table, so a change never alters the member another machine (or
-- the menu) is still holding.
function TheContractorOffice.copyMember(member)
    local copy = {}
    for key, value in pairs(member) do
        copy[key] = value
    end
    copy.playerStyle = nil
    return copy
end

-- Applies locally, then sends it to the clients and tells ADS.
function TheContractorOffice:commit(farmId, role, member)
    self:applyMember(farmId, role, member)

    if g_server ~= nil then
        g_server:broadcastEvent(TCOfficeChangedEvent.new(farmId, role, member))
    end
    TCADSWorkshop.refresh(farmId)
end

-- Run on whichever machine is applying it (server, or a client receiving
-- TCOfficeChangedEvent). Tells the farm's player what changed.
function TheContractorOffice:applyMember(farmId, role, member)
    local members = self.membersByFarm[farmId]
    if members == nil then
        members = {}
        self.membersByFarm[farmId] = members
    end
    local previous = members[role]
    if member ~= nil then
        -- The look is the same person's unless it was edited (066), which
        -- goes through Staff:applyWorkerEdited instead.
        member.playerStyle = previous ~= nil and previous.id == member.id and previous.playerStyle or nil
    end
    members[role] = member

    local menu = g_currentMission.TheContractor.MenuContractor
    if menu ~= nil and menu.onOfficeChanged ~= nil then
        menu:onOfficeChanged()
    end

    if g_client == nil or g_currentMission:getFarmId() ~= farmId then
        return
    end
    local roleName = g_i18n:getText("tc_office_roleNoun_" .. role)
    if member ~= nil and previous == nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_office_hiredNotification"), member.name, roleName))
    elseif member == nil and previous ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(g_i18n:getText("tc_office_releasedNotification"), previous.name, roleName))
    elseif member ~= nil and previous ~= nil and member.level > previous.level then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_office_trainedNotification"), member.name, member.level))
    end
end

-- 066: their name, gender and look, from Staff:applyWorkerEdited. Every
-- machine.
function TheContractorOffice:applyEdited(member, name, gender, appearance)
    member.name = name
    member.gender = gender
    member.appearance = appearance
    member.playerStyle = nil
end

-- Wire serialization ----------------------------------------------------------------
-- member may be nil (none employed). Self-contained apart from farm and role.

function TheContractorOffice.writeMember(streamId, member)
    if streamWriteBool(streamId, member ~= nil) then
        streamWriteInt32(streamId, member.id)
        streamWriteString(streamId, member.name)
        streamWriteString(streamId, member.gender)
        TCWorkerAppearance.writeStream(streamId, member.appearance)
        streamWriteFloat32(streamId, member.salary)
        streamWriteUInt8(streamId, member.level)
        streamWriteInt32(streamId, member.hiredPeriod)
        streamWriteInt32(streamId, member.ageAtHire)
        -- 0 = not training (monotonic days start at 1).
        streamWriteInt32(streamId, member.trainingUntilDay or 0)
    end
end

function TheContractorOffice.readMember(streamId, farmId, role)
    if not streamReadBool(streamId) then
        return nil
    end
    local member = {
        id = streamReadInt32(streamId),
        role = role,
        farmId = farmId,
        name = streamReadString(streamId),
        gender = streamReadString(streamId),
        appearance = TCWorkerAppearance.readStream(streamId),
        salary = streamReadFloat32(streamId),
        level = streamReadUInt8(streamId),
        hiredPeriod = streamReadInt32(streamId),
        ageAtHire = streamReadInt32(streamId),
    }
    local trainingUntilDay = streamReadInt32(streamId)
    member.trainingUntilDay = trainingUntilDay > 0 and trainingUntilDay or nil
    return member
end

-- Persistence ------------------------------------------------------------------------

-- After Staff, whose worker id counter office ids come from.
function TheContractorOffice:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.membersByFarm = {}
    local staff = g_currentMission.TheContractor.Staff

    local index = 0
    while true do
        local key = string.format("%s.office.member(%d)", TheContractor.SaveKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        local role = getXMLString(xmlFile, key .. "#role")
        if farmId ~= nil and TheContractorOffice.ROLES[role] ~= nil then
            local name = Utils.getNoNil(getXMLString(xmlFile, key .. "#name"), "?")
            local level = math.max(1, math.min(Utils.getNoNil(getXMLInt(xmlFile, key .. "#level"), 1),
                TheContractorOffice.MAX_LEVEL))
            local id = getXMLInt(xmlFile, key .. "#id")
            if id == nil then
                id = staff:takeWorkerId()
            else
                staff:reserveWorkerId(id)
            end
            local member = {
                id = id,
                role = role,
                farmId = farmId,
                name = name,
                gender = getXMLString(xmlFile, key .. "#gender") or TheContractorStaff.guessGender(name),
                appearance = TCWorkerAppearance.readXML(xmlFile, key .. ".appearance"),
                salary = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#salary"),
                    TheContractorOffice.getLevelSalary(role, level)),
                level = level,
                hiredPeriod = Utils.getNoNil(getXMLInt(xmlFile, key .. "#hiredPeriod"), 0),
                ageAtHire = Utils.getNoNil(getXMLInt(xmlFile, key .. "#ageAtHire"), TheContractorOffice.AGE_MIN),
                trainingUntilDay = getXMLInt(xmlFile, key .. "#trainingUntilDay"),
            }
            self:addLoadedMember(member)
        end

        index = index + 1
    end

    -- 057's saves: the administrator on its own, with no look or level.
    index = 0
    while true do
        local key = string.format("%s.administrators.administrator(%d)", TheContractor.SaveKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        if farmId ~= nil and self:getMember(farmId, TheContractorOffice.ROLE.ADMINISTRATOR) == nil then
            local name = Utils.getNoNil(getXMLString(xmlFile, key .. "#name"), "?")
            self:addLoadedMember({
                id = staff:takeWorkerId(),
                role = TheContractorOffice.ROLE.ADMINISTRATOR,
                farmId = farmId,
                name = name,
                gender = TheContractorStaff.guessGender(name),
                salary = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#salary"),
                    TheContractorOffice.getLevelSalary(TheContractorOffice.ROLE.ADMINISTRATOR, 1)),
                level = 1,
                hiredPeriod = Utils.getNoNil(getXMLInt(xmlFile, key .. "#hiredPeriod"), 0),
                ageAtHire = Utils.getNoNil(getXMLInt(xmlFile, key .. "#ageAtHire"), TheContractorOffice.AGE_MIN),
            })
        end

        index = index + 1
    end
end

-- A loaded member with no look, or one that can't be rebuilt, gets a new
-- one, as a worker does (041).
function TheContractorOffice:addLoadedMember(member)
    if TCWorkerAppearance.needsReroll(member) then
        member.appearance = TCWorkerAppearance.roll(member.gender)
        member.playerStyle = nil
    end
    self.membersByFarm[member.farmId] = self.membersByFarm[member.farmId] or {}
    self.membersByFarm[member.farmId][member.role] = member
end

function TheContractorOffice:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local index = 0
    for _, farmId in ipairs(self:getFarmIds()) do
        for _, member in ipairs(self:getMembers(farmId)) do
            local key = string.format("%s.office.member(%d)", TheContractor.SaveKey, index)
            setXMLInt(xmlFile, key .. "#farmId", farmId)
            setXMLString(xmlFile, key .. "#role", member.role)
            setXMLInt(xmlFile, key .. "#id", member.id)
            setXMLString(xmlFile, key .. "#name", member.name)
            setXMLString(xmlFile, key .. "#gender", member.gender)
            setXMLFloat(xmlFile, key .. "#salary", member.salary)
            setXMLInt(xmlFile, key .. "#level", member.level)
            setXMLInt(xmlFile, key .. "#hiredPeriod", member.hiredPeriod)
            setXMLInt(xmlFile, key .. "#ageAtHire", member.ageAtHire)
            if member.trainingUntilDay ~= nil then
                setXMLInt(xmlFile, key .. "#trainingUntilDay", member.trainingUntilDay)
            end
            TCWorkerAppearance.writeXML(xmlFile, key .. ".appearance", member.appearance)
            index = index + 1
        end
    end
end

function TheContractorOffice:writeInitialClientState(streamId, connection)
    local entries = {}
    for _, farmId in ipairs(self:getFarmIds()) do
        for _, member in ipairs(self:getMembers(farmId)) do
            table.insert(entries, member)
        end
    end
    streamWriteInt32(streamId, #entries)
    for _, member in ipairs(entries) do
        streamWriteInt32(streamId, member.farmId)
        streamWriteString(streamId, member.role)
        TheContractorOffice.writeMember(streamId, member)
    end
end

function TheContractorOffice:readInitialClientState(streamId, connection)
    self.membersByFarm = {}
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local farmId = streamReadInt32(streamId)
        local role = streamReadString(streamId)
        local member = TheContractorOffice.readMember(streamId, farmId, role)
        if member ~= nil then
            self.membersByFarm[farmId] = self.membersByFarm[farmId] or {}
            self.membersByFarm[farmId][role] = member
        end
    end
end

-- Console ------------------------------------------------------------------------------

function TheContractorOffice.registerConsoleCommands()
    TCConsole.register("company", "office", {
        args = "",
        description = "List the farm's office staff",
        serverOnly = false,
        run = function(farmId)
            local office = g_currentMission.TheContractor.Office
            local lines = {}
            for _, role in ipairs(TheContractorOffice.ROLE_ORDER) do
                local member = office:getMember(farmId, role)
                if member == nil then
                    table.insert(lines, string.format("%s: none", role))
                else
                    local status = TheContractorOffice.getStatus(member)
                    if member.trainingUntilDay ~= nil then
                        status = string.format("%s until day %d", status, member.trainingUntilDay)
                    end
                    table.insert(lines, string.format("%s: #%d %s, level %d, %s, salary %.0f/month", role, member.id,
                        member.name, member.level, status, member.salary))
                end
            end
            table.insert(lines, TCADSWorkshop.describe(farmId))
            return table.concat(lines, "\n")
        end,
    })

    TCConsole.register("company", "officeLevel", {
        args = "<administrator|storekeeper> <1-3>",
        description = "Set an office role's level (and salary) now, ending any course",
        run = function(farmId, args)
            local role = args[1]
            local level = tonumber(args[2])
            if TheContractorOffice.ROLES[role] == nil or level == nil or level ~= math.floor(level) or level < 1 or
                    level > TheContractorOffice.MAX_LEVEL then
                return false
            end
            local member = g_currentMission.TheContractor.Office:setLevel(farmId, role, level)
            if member == nil then
                return string.format("Farm %d has no %s", farmId, role)
            end
            return string.format("%s is now level %d (salary %.0f/month)", member.name, member.level, member.salary)
        end,
    })
end
