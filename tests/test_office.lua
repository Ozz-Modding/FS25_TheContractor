-- Office staff (090): the administrator and storekeeper - hiring (the
-- storekeeper only while ADS takes our staff), ids from the worker counter,
-- training and its day tick, payroll, release, save/load (and 057's old
-- administrator saves), the stream, editing, and what ADS is told.

local function setup()
    local world = stubs.install()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    MoneyType = { TC_WAGES = "wages", TC_TRAINING = "training" }
    TheContractor = { SaveKey = "TheContractor" }
    Enterable = {}
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    TheContractorJobGeneration = { JOB_PAY_BASELINE = 0.8 }
    TCCalendar = {
        getPeriodIndex = function()
            return 40
        end,
        formatDay = function(day)
            return "day " .. day
        end,
    }
    TCIdleStaff = {
        reloadLook = function(person)
            world.reloadedLooks = (world.reloadedLooks or 0) + 1
        end,
    }
    TheContractorDrivers = {
        getModEnv = function()
            return nil
        end,
    }

    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/util/TCNames.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/Office.lua")
    world:load("src/business/Training.lua")
    world:load("src/util/TCADSWorkshop.lua")

    -- A look builds unless it's marked broken (see test_editWorker).
    TCWorkerAppearance.rollGender = function()
        return TCWorkerAppearance.GENDER.FEMALE
    end
    TCWorkerAppearance.roll = function(gender)
        return { model = gender .. ".xml", configs = {} }
    end
    TCWorkerAppearance.toPlayerStyle = function(data)
        if data == nil or data.isBroken then
            return nil
        end
        return { builtFrom = data }
    end
    TCWorkerAppearance.isValidLook = function(data, gender)
        return data ~= nil and data.model == gender .. ".xml"
    end

    -- A fake ADS with the staff provider API (0.10.0.6).
    world.adsOn = true
    world.partsStorage = true
    world.refreshes = {}
    world.ads = {
        STAFF_API_VERSION = 1,
        registerStaffProvider = function(id, definition)
            world.provider = { id = id, definition = definition }
            return true
        end,
        refreshStaffProvider = function(farmId)
            table.insert(world.refreshes, farmId)
            return true
        end,
        isContractorStaffEnabled = function()
            return world.adsOn
        end,
        getRecord = function(farmId)
            return { farmId = farmId }
        end,
        hasEquipment = function(record, id)
            return id == "partsStorage" and world.partsStorage
        end,
    }
    world.adsEnv = { ADS_OwnWorkshop = world.ads }
    TCADSWorkshop.getEnv = function()
        return world.adsEnv
    end
    TCADSWorkshop.detect()

    world.balance = 1000000
    world.money = {}
    world.wages = 0
    world.training = 0
    world.broadcasts = {}
    g_farmManager.getFarmById = function(_, farmId)
        return {
            getBalance = function()
                return world.balance
            end,
        }
    end
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        world.balance = world.balance + amount
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end
    g_currentMission.environment = { currentMonotonicDay = 10, daysPerPeriod = 28 }
    g_server = {
        broadcastEvent = function(_, event)
            table.insert(world.broadcasts, event)
        end,
    }
    g_client = {}
    TCOfficeChangedEvent = {
        new = function(farmId, role, member)
            return { kind = "office", farmId = farmId, role = role, member = member }
        end,
    }
    TCWorkerEditedEvent = {
        new = function(farmId, workerId, name)
            return { kind = "edited", farmId = farmId, workerId = workerId, name = name }
        end,
    }

    world.ensureRequired = 0
    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {}, nextWorkerId = 5 }, TheContractorStaff_mt)
    tc.Office = TheContractorOffice.new()
    tc.Company = {
        hasCompany = function()
            return true
        end,
    }
    tc.Finances = {
        recordWages = function(_, farmId, amount)
            world.wages = world.wages + amount
        end,
        recordTraining = function(_, farmId, amount)
            world.training = world.training + amount
        end,
    }
    tc.Overheads = {
        ensureRequired = function()
            world.ensureRequired = world.ensureRequired + 1
        end,
    }
    return world, tc
end

local ADMIN = "administrator"
local STOREKEEPER = "storekeeper"

test("hiring an administrator pays the first month and takes an id from the worker counter", function()
    local world, tc = setup()
    local member = tc.Office:hire(1, ADMIN)

    assertTrue(member ~= nil, "hired")
    assertEquals(member.id, 5, "id from the worker counter")
    assertEquals(tc.Staff.nextWorkerId, 6, "counter moved on")
    assertEquals(member.level, 1, "level")
    assertEquals(member.salary, 2000, "level 1 salary")
    assertEquals(member.gender, "female", "gender")
    assertEquals(member.appearance.model, "female.xml", "rolled a look")
    -- 28 days a month: full pay.
    assertEquals(world.money[1].amount, -2000, "first month paid")
    assertEquals(world.money[1].moneyType, "wages", "as wages")
    assertEquals(world.wages, 2000, "recorded as wages")
    assertEquals(world.ensureRequired, 1, "employer's liability")
    assertEquals(#world.broadcasts, 1, "broadcast")
    assertEquals(world.broadcasts[1].role, ADMIN, "broadcast role")
    assertEquals(world.refreshes[1], 1, "ADS told")
    assertEquals(#world.notifications, 1, "notification")
    assertTrue(tc.Office:hasAdministrator(1), "credit control on")
    assertEquals(tc.Office:getDelayWeights(1), TheContractorOffice.DELAY_WEIGHTS, "credit control weights")

    assertEquals(tc.Office:hire(1, ADMIN), nil, "only one administrator")
end)

test("the storekeeper is only offered and hired while ADS takes our staff", function()
    local world, tc = setup()
    world.adsOn = false
    assertTrue(tc.Office:isRoleShown(1, ADMIN), "administrator always shown")
    assertTrue(not tc.Office:isRoleShown(1, STOREKEEPER), "storekeeper hidden")
    assertEquals(tc.Office:getHireProblem(1, STOREKEEPER), TheContractorOffice.PROBLEM.NEEDS_ADS, "needs ADS")
    assertEquals(tc.Office:hire(1, STOREKEEPER), nil, "refused")

    world.adsOn = true
    assertTrue(tc.Office:isRoleShown(1, STOREKEEPER), "shown with ADS")
    local member = tc.Office:hire(1, STOREKEEPER)
    assertEquals(member.salary, 1900, "storekeeper salary")

    -- ADS switched off later: they stay, and their row with them.
    world.adsOn = false
    assertTrue(tc.Office:isRoleShown(1, STOREKEEPER), "still shown while employed")
end)

test("without ADS's API (or another version of it) nothing is offered", function()
    local world, tc = setup()
    world.ads.STAFF_API_VERSION = 2
    TCADSWorkshop.detect()
    assertTrue(not TCADSWorkshop.isActive(), "not active")
    assertEquals(#world.warnings, 1, "one warning")
    assertTrue(not tc.Office:isRoleShown(1, STOREKEEPER), "no storekeeper")

    world.adsEnv = nil
    TCADSWorkshop.detect()
    assertTrue(not TCADSWorkshop.isAvailable(), "not loaded")
    TCADSWorkshop.register()
    assertEquals(world.provider, nil, "nothing registered")
end)

test("a hire the farm can't afford doesn't happen", function()
    local world, tc = setup()
    world.balance = 100
    assertEquals(tc.Office:hire(1, ADMIN), nil, "refused")
    assertEquals(#world.money, 0, "nothing charged")
end)

test("training charges the scaled cost, takes them away and raises level and salary when it's done", function()
    local world, tc = setup()
    tc.Office:hire(1, ADMIN)
    world.money = {}

    world.adsOn = false
    assertEquals(tc.Office:getTrainProblem(1, ADMIN), TheContractorOffice.PROBLEM.NEEDS_ADS, "only with ADS")
    assertTrue(not tc.Office:train(1, ADMIN), "refused without ADS")
    world.adsOn = true

    assertTrue(tc.Office:train(1, ADMIN), "booked")
    -- 500 at 1x UK, 5x at the default job pay rate.
    assertEquals(world.money[1].amount, -2500, "course cost")
    assertEquals(world.money[1].moneyType, "training", "as training")
    assertEquals(world.training, 2500, "recorded as training")

    local member = tc.Office:getMember(1, ADMIN)
    assertEquals(member.trainingUntilDay, 12, "two days away")
    assertEquals(TheContractorOffice.getStatus(member), TheContractorOffice.STATUS.TRAINING, "training")
    assertEquals(tc.Office:getTrainProblem(1, ADMIN), TheContractorOffice.PROBLEM.TRAINING, "already training")

    g_currentMission.environment.currentMonotonicDay = 11
    tc.Office:onDayChanged()
    assertEquals(tc.Office:getMember(1, ADMIN).level, 1, "not back yet")

    g_currentMission.environment.currentMonotonicDay = 12
    tc.Office:onDayChanged()
    member = tc.Office:getMember(1, ADMIN)
    assertEquals(member.level, 2, "level 2")
    assertEquals(member.salary, 2250, "level 2 salary")
    assertEquals(member.trainingUntilDay, nil, "back")
    assertEquals(world.notifications[#world.notifications].text,
        string.format(g_i18n:getText("tc_office_trainedNotification"), member.name, 2), "told")

    tc.Office:setLevel(1, ADMIN, 3)
    assertEquals(tc.Office:getTrainProblem(1, ADMIN), TheContractorOffice.PROBLEM.MAX_LEVEL, "fully trained")
end)

test("office staff are on the payroll and the headcount", function()
    local world, tc = setup()
    tc.Office:hire(1, ADMIN)
    tc.Office:hire(1, STOREKEEPER)
    tc.Staff.workersByFarm[1] = { [1] = { id = 1, salary = 2600 } }

    assertEquals(tc.Office:getSalary(1), 3900, "office salaries")
    assertEquals(tc.Staff:getPayroll(1), 6500, "payroll")
    assertEquals(tc.Staff:getHeadcount(1), 3, "headcount")
    assertEquals(tc.Office:getFarmIds()[1], 1, "in the salary run")

    -- Short months pay less, as for workers.
    g_currentMission.environment.daysPerPeriod = 1
    assertEquals(tc.Office:getSalary(1), 3900 * 0.6, "scaled")
end)

test("releasing pays notice and empties the role", function()
    local world, tc = setup()
    local member = tc.Office:hire(1, ADMIN)
    member.hiredPeriod = 40 - 3 * 12
    world.money = {}

    tc.Office:release(1, ADMIN)
    assertEquals(tc.Office:getMember(1, ADMIN), nil, "gone")
    assertTrue(world.money[1].amount < 0, "notice paid")
    assertEquals(world.broadcasts[#world.broadcasts].member, nil, "broadcast as released")
    assertTrue(not tc.Office:hasAdministrator(1), "credit control off")
end)

test("a save loads back with its ids, levels, courses and looks", function()
    local world, tc = setup()
    tc.Office:hire(1, ADMIN)
    tc.Office:hire(1, STOREKEEPER)
    tc.Office:setLevel(1, STOREKEEPER, 2)
    tc.Office:train(1, STOREKEEPER)

    local xmlFile = {}
    tc.Office:saveToXmlFile(xmlFile)

    local _, loaded = setup()
    loaded.Office:loadFromXMLFile(xmlFile)
    local admin = loaded.Office:getMember(1, ADMIN)
    local storekeeper = loaded.Office:getMember(1, STOREKEEPER)
    assertEquals(admin.id, 5, "admin id")
    assertEquals(storekeeper.id, 6, "storekeeper id")
    assertEquals(storekeeper.level, 2, "level")
    assertEquals(storekeeper.salary, 2150, "salary")
    assertEquals(storekeeper.trainingUntilDay, 13, "course")
    assertEquals(admin.appearance.model, "female.xml", "look")
    assertEquals(loaded.Staff.nextWorkerId, 7, "counter moved past their ids")
end)

test("057's administrator saves load as a level 1 administrator, given a look at mission start", function()
    local _, tc = setup()
    local xmlFile = {
        ["TheContractor.administrators.administrator(0)#farmId"] = 1,
        ["TheContractor.administrators.administrator(0)#name"] = "James Smith",
        ["TheContractor.administrators.administrator(0)#salary"] = 2000,
        ["TheContractor.administrators.administrator(0)#hiredPeriod"] = 30,
        ["TheContractor.administrators.administrator(0)#ageAtHire"] = 41,
    }
    tc.Office:loadFromXMLFile(xmlFile)

    local admin = tc.Office:getMember(1, ADMIN)
    assertTrue(admin ~= nil, "loaded")
    assertEquals(admin.id, 5, "new id")
    assertEquals(admin.level, 1, "level 1")
    assertEquals(admin.gender, "male", "gender from the name")
    assertEquals(admin.appearance, nil, "no look until mission start")
    tc.Staff:restoreLooks()
    assertEquals(admin.appearance.model, "male.xml", "look rolled")
    assertEquals(admin.hiredPeriod, 30, "service kept")
    assertEquals(admin.ageAtHire, 41, "age kept")
end)

test("a member streams across intact", function()
    local world, tc = setup()
    tc.Office:hire(1, STOREKEEPER)
    tc.Office:train(1, STOREKEEPER)
    local member = tc.Office:getMember(1, STOREKEEPER)

    local stream = world:newStream()
    TheContractorOffice.writeMember(stream, member)
    TheContractorOffice.writeMember(stream, nil)
    local copy = TheContractorOffice.readMember(stream, 1, STOREKEEPER)
    for _, key in ipairs({ "id", "name", "gender", "salary", "level", "hiredPeriod", "ageAtHire", "trainingUntilDay" }) do
        assertEquals(copy[key], member[key], key)
    end
    assertEquals(copy.role, STOREKEEPER, "role")
    assertEquals(copy.appearance.model, member.appearance.model, "look")
    assertEquals(TheContractorOffice.readMember(stream, 1, ADMIN), nil, "vacancy")
end)

test("office staff are edited through the worker edit path", function()
    local world, tc = setup()
    local member = tc.Office:hire(1, ADMIN)
    world.broadcasts = {}

    local problem = tc.Staff:editWorker(1, member.id, "Anna Bell", "male", { model = "male.xml", configs = {} })
    assertEquals(problem, nil, "applied")
    member = tc.Office:getMember(1, ADMIN)
    assertEquals(member.name, "Anna Bell", "name")
    assertEquals(member.gender, "male", "gender")
    assertEquals(member.appearance.model, "male.xml", "look")
    assertEquals(world.broadcasts[1].kind, "edited", "edit broadcast")
    assertEquals(world.reloadedLooks, 1, "standing spot reloaded")
end)

test("ADS is told the receptionist and storekeeper, and training", function()
    local world, tc = setup()
    TCADSWorkshop.register()
    assertEquals(world.provider.id, TCADSWorkshop.PROVIDER_ID, "registered")
    assertEquals(world.provider.definition.version, 1, "API version")

    assertEquals(next(world.provider.definition.getAssignments(1)), nil, "nobody yet")

    local admin = tc.Office:hire(1, ADMIN)
    tc.Office:hire(1, STOREKEEPER)
    tc.Office:setLevel(1, ADMIN, 2)
    tc.Office:train(1, STOREKEEPER)

    local assignments = world.provider.definition.getAssignments(1)
    assertEquals(assignments.receptionist.id, admin.id, "receptionist")
    assertEquals(assignments.receptionist.level, 2, "receptionist level")
    assertEquals(assignments.receptionist.status, "available", "receptionist in")
    assertEquals(assignments.storekeeper.level, 1, "storekeeper level")
    assertEquals(assignments.storekeeper.status, "training", "storekeeper away")
    assertEquals(assignments.mechanic, nil, "no trades yet")

    world.partsStorage = false
    assertEquals(TCADSWorkshop.hasPartsStorage(1), false, "no parts storage")
end)

test("tcCompany office and officeLevel register and run", function()
    local world, tc = setup()
    world:load("src/util/TCConsole.lua")
    TCConsole.reset()
    TheContractorOffice.registerConsoleCommands()
    assertEquals(#world.warnings, 0, "no registration errors")
    local office = TCConsole.groups.company.subcommands.office
    local officeLevel = TCConsole.groups.company.subcommands.officelevel
    assertTrue(office ~= nil and officeLevel ~= nil, "both under tcCompany")

    assertEquals(officeLevel.run(1, { "administrator", "2" }), "Farm 1 has no administrator", "nobody to set")
    local member = tc.Office:hire(1, ADMIN)
    assertEquals(officeLevel.run(1, { "administrator", "2" }),
        string.format("%s is now level 2 (salary 2250/month)", member.name), "set")
    assertEquals(officeLevel.run(1, { "administrator", "4" }), false, "bad level")
    assertEquals(officeLevel.run(1, { "manager", "1" }), false, "bad role")

    local text = office.run(1, {})
    assertTrue(text:find("administrator: #5 " .. member.name .. ", level 2", 1, true) ~= nil, "lists them")
    assertTrue(text:find("storekeeper: none", 1, true) ~= nil, "and the vacancy")
    assertTrue(text:find("ADS workshop: taking our staff", 1, true) ~= nil, "and ADS")
end)
