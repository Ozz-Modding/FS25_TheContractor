-- ADS trade training (092): prices (scaleCost and the association
-- discount), what stops a booking, booking through 054's training
-- (charged, scheduled, no assessment), a missed day sliding it back, the
-- level coming on the last day (a new trade too), market value rising while
-- pay doesn't, save/stream of a booking, and tcWorker train <trade>.

local function setup()
    local world = stubs.install()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    MoneyType = { TC_TRAINING = "training" }
    Enterable = {}
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorJobGeneration = { JOB_PAY_BASELINE = 0.8 }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    TCCalendar = {
        getPeriodIndex = function()
            return 40
        end,
        formatDay = function(day)
            return "day " .. day
        end,
        formatDayRange = function(first, last)
            return string.format("days %d-%d", first, last)
        end,
    }
    TheContractorDrivers = {
        getModEnv = function()
            return nil
        end,
    }

    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/Office.lua")
    world:load("src/business/Workshop.lua")
    world:load("src/business/Training.lua")
    world:load("src/business/Holidays.lua")
    world:load("src/business/Morale.lua")
    world:load("src/business/PayReviews.lua")
    world:load("src/util/TCADSWorkshop.lua")
    world:load("src/util/TCConsole.lua")

    world.adsOn = true
    world.adsEnv = {
        ADS_OwnWorkshop = {
            STAFF_API_VERSION = 1,
            registerStaffProvider = function()
                return true
            end,
            refreshStaffProvider = function()
            end,
            isContractorStaffEnabled = function()
                return world.adsOn
            end,
        },
    }
    TCADSWorkshop.getEnv = function()
        return world.adsEnv
    end
    TCADSWorkshop.detect()

    world.balance = 1000000
    world.money = {}
    world.training = 0
    world.broadcasts = {}
    world.notices = {}
    g_farmManager.getFarmById = function()
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
    TCWorkerWorkshopEvent = {
        new = function(farmId, workerId, adsSkills, workshopRole)
            return { kind = "workshop", adsSkills = adsSkills, workshopRole = workshopRole }
        end,
    }
    TCWorkerTrainingChangedEvent = {
        new = function(worker, notify, cert, amount)
            return { kind = "training", notify = notify, cert = cert, amount = amount }
        end,
        showNotification = function(worker, notify, cert, amount)
            table.insert(world.notices, { notify = notify, cert = cert, amount = amount })
        end,
    }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {}, nextWorkerId = 1 }, TheContractorStaff_mt)
    -- Status changes are what's checked, not everything they set off.
    tc.Staff.setWorkerStatus = function(staff, farmId, workerId, status)
        staff:getWorker(farmId, workerId).status = status
    end
    tc.Office = TheContractorOffice.new()
    tc.Training = setmetatable({}, TheContractorTraining_mt)
    world.member = false
    tc.Association = {
        getCertificationDiscount = function()
            return world.member and 0.25 or 0
        end,
    }
    tc.Inbox = {
        getMessages = function()
            return {}
        end,
    }
    tc.Finances = {
        recordTraining = function(_, farmId, amount)
            world.training = world.training + amount
        end,
    }
    return world, tc
end

local function addWorker(tc, id, adsSkills)
    local worker = TheContractorWorker.new(id, 1, "Worker " .. id, 5, { small = 5 }, 2000, 30, 0, 1, 0, {}, 5)
    worker.adsSkills = adsSkills or {}
    worker.status = TheContractorWorker.STATUS.IDLE
    tc.Staff.workersByFarm[1] = tc.Staff.workersByFarm[1] or {}
    tc.Staff.workersByFarm[1][id] = worker
    return worker
end

local MECHANIC = "workshop_mechanic"

-- Runs the server's day tick for `days` days.
local function passDays(tc, days)
    for _ = 1, days do
        g_currentMission.environment.currentMonotonicDay = g_currentMission.environment.currentMonotonicDay + 1
        tc.Training:onDayChanged()
    end
end

test("course keys name a trade, and nothing else", function()
    setup()
    assertEquals(TheContractorWorkshop.getCourseKey("mechanic"), MECHANIC, "key")
    assertEquals(TheContractorWorkshop.getCourseRole(MECHANIC), "mechanic", "role")
    assertEquals(TheContractorWorkshop.getCourseRole("spraying"), nil, "a certificate")
    assertEquals(TheContractorWorkshop.getCourseRole("workshop_receptionist"), nil, "an office role")
    assertEquals(TheContractorWorkshop.getCourseRole(nil), nil, "nothing booked")
    assertTrue(TheContractorTraining.isKnownCourse(MECHANIC), "known: trade")
    assertTrue(TheContractorTraining.isKnownCourse("spraying"), "known: certificate")
    assertTrue(not TheContractorTraining.isKnownCourse("workshop_pilot"), "unknown")
end)

test("prices scale with job pay and take the association discount", function()
    local world, tc = setup()
    local sam = addWorker(tc, 1, {})
    -- 300 at 1x UK, five times that at the default job pay rate.
    assertEquals(TheContractorWorkshop.getCoursePrice(1, sam, "mechanic"), 1500, "learn mechanic")
    assertEquals(TheContractorWorkshop.getCourseDays(sam, "mechanic"), 2, "learn days")
    sam.adsSkills = { mechanic = 2, diagnostician = 1 }
    assertEquals(TheContractorWorkshop.getCoursePrice(1, sam, "mechanic"), 5000, "mechanic 2 -> 3")
    assertEquals(TheContractorWorkshop.getCourseDays(sam, "mechanic"), 3, "level 3 days")
    assertEquals(TheContractorWorkshop.getCoursePrice(1, sam, "diagnostician"), 4000, "diagnostician 1 -> 2")
    world.member = true
    assertEquals(TheContractorWorkshop.getCoursePrice(1, sam, "diagnostician"), 3000, "a member pays 75%")
end)

test("a course needs ADS, room for the trade, nothing booked and nobody leaving", function()
    local world, tc = setup()
    local PROBLEM = TheContractorWorkshop.PROBLEM
    local sam = addWorker(tc, 1, { mechanic = 3, bodyworker = 1 })

    assertEquals(TheContractorWorkshop.getCourseProblem(sam, "mechanic"), PROBLEM.MAX_LEVEL, "at the top")
    assertEquals(TheContractorWorkshop.getCourseProblem(sam, "diagnostician"), PROBLEM.TOO_MANY_SKILLS, "a third")
    assertEquals(TheContractorWorkshop.getCourseProblem(sam, "bodyworker"), nil, "raise one they have")
    assertEquals(TheContractorWorkshop.getCourseProblem(sam, "receptionist"), PROBLEM.UNKNOWN_ROLE, "office role")

    local options = TheContractorWorkshop.getCourseOptions(sam)
    assertEquals(#options, 1, "one course on offer")
    assertEquals(options[1].role, "bodyworker", "bodyworker")
    assertEquals(options[1].level, 2, "to level 2")

    local amy = addWorker(tc, 2, {})
    assertEquals(#TheContractorWorkshop.getCourseOptions(amy), 3, "any trade for someone with none")

    amy.trainingCert = "spraying"
    assertEquals(TheContractorWorkshop.getCourseProblem(amy, "mechanic"), PROBLEM.BOOKED, "spraying booked")
    amy.trainingCert = nil
    amy.leavesAtPeriod = 45
    assertEquals(TheContractorWorkshop.getCourseProblem(amy, "mechanic"), PROBLEM.LEAVING, "handed in notice")
    amy.leavesAtPeriod = nil

    world.adsOn = false
    assertEquals(TheContractorWorkshop.getCourseProblem(amy, "mechanic"), PROBLEM.NEEDS_ADS, "without ADS")
    assertEquals(#TheContractorWorkshop.getCourseOptions(amy), 0, "nothing on offer")
end)

test("booking charges the farm and books course days with no assessment", function()
    local world, tc = setup()
    local sam = addWorker(tc, 1, { mechanic = 1 })
    world.member = true

    assertTrue(tc.Training:requestBooking(1, sam.id, MECHANIC), "booked")
    assertEquals(world.money[1].amount, -2250, "3000 less the discount")
    assertEquals(world.money[1].moneyType, "training", "as training")
    assertEquals(world.training, 2250, "recorded as training")
    assertEquals(sam.trainingCert, MECHANIC, "booked on the course")
    assertEquals(sam.courseDaysLeft, 2, "two course days")
    assertEquals(sam.trainingDay, 11, "from tomorrow")
    assertEquals(sam.assessmentDay, nil, "no assessment")
    assertEquals(sam.status, TheContractorWorker.STATUS.IDLE, "not today")
    assertEquals(world.notices[1].notify, TheContractorTraining.NOTIFY.BOOKED, "told it's booked")

    -- One course at a time, either kind.
    local ok, problem = tc.Training:requestBooking(1, sam.id, "workshop_bodyworker")
    assertTrue(not ok, "second course refused")
    assertEquals(problem, TheContractorWorkshop.PROBLEM.BOOKED, "already booked")
    assertEquals(TheContractorTraining.getBookingProblem(sam, "spraying"), TheContractorTraining.PROBLEM.BOOKED,
        "spraying refused too")
    assertEquals(#world.money, 1, "charged once")
end)

test("a booking it can't pay for, or isn't allowed, charges nothing", function()
    local world, tc = setup()
    local sam = addWorker(tc, 1, { mechanic = 3 })
    local ok, problem = tc.Training:requestBooking(1, sam.id, MECHANIC)
    assertTrue(not ok, "refused at the top")
    assertEquals(problem, TheContractorWorkshop.PROBLEM.MAX_LEVEL, "max level")

    world.balance = 100
    ok, problem = tc.Training:requestBooking(1, sam.id, "workshop_bodyworker")
    assertTrue(not ok, "refused")
    assertEquals(problem, TheContractorTraining.PROBLEM.CANNOT_AFFORD, "can't afford")
    assertEquals(#world.money, 0, "nothing charged")
    assertEquals(sam.trainingCert, nil, "nothing booked")
end)

test("the course runs its days, then the trade goes up a level", function()
    local world, tc = setup()
    local STATUS = TheContractorWorker.STATUS
    local sam = addWorker(tc, 1, { mechanic = 1 })
    sam.workshopRole = "mechanic"
    tc.Training:requestBooking(1, sam.id, MECHANIC)
    assertEquals(sam.status, STATUS.IDLE, "not today")

    passDays(tc, 1)
    assertEquals(sam.status, STATUS.TRAINING, "away training tomorrow")
    assertEquals(TheContractorWorkshop.getADSStatus(sam), "training", "ADS sees them training")

    passDays(tc, 1)
    assertEquals(sam.status, STATUS.TRAINING, "second course day")
    assertEquals(sam.adsSkills.mechanic, 1, "not yet")

    passDays(tc, 1)
    assertEquals(sam.adsSkills.mechanic, 2, "level 2")
    assertEquals(sam.workshopRole, "mechanic", "still ticked")
    assertEquals(sam.trainingCert, nil, "booking done")
    assertEquals(sam.status, STATUS.IDLE, "back")
    local last = world.notices[#world.notices]
    assertEquals(last.notify, TheContractorTraining.NOTIFY.COMPLETED, "told it's done")
    assertEquals(last.amount, 2, "with the new level")
    local workshopBroadcast
    for _, event in ipairs(world.broadcasts) do
        if event.kind == "workshop" then
            workshopBroadcast = event
        end
    end
    assertEquals(workshopBroadcast.adsSkills.mechanic, 2, "the new skills go to clients")
end)

test("learning a new trade adds it at level 1, raising market value but not pay", function()
    local _, tc = setup()
    local sam = addWorker(tc, 1, { bodyworker = 2 })
    local before = TheContractorPayReviews.getMarketValue(sam)

    tc.Training:requestBooking(1, sam.id, "workshop_diagnostician")
    passDays(tc, 3)

    assertEquals(sam.adsSkills.diagnostician, 1, "learnt")
    assertEquals(sam.adsSkills.bodyworker, 2, "kept the other")
    assertEquals(sam.salary, 2000, "pay unchanged")
    -- Their best skill stays bodyworker 2; the new one adds half of level 1.
    assertEquals(TheContractorPayReviews.getMarketValue(sam), before + 75, "market value up")
end)

test("a missed course day moves the course back", function()
    local _, tc = setup()
    local STATUS = TheContractorWorker.STATUS
    local sam = addWorker(tc, 1, {})
    -- Out on a job when it's booked.
    sam.status = STATUS.ASSIGNED
    tc.Training:requestBooking(1, sam.id, MECHANIC)
    assertEquals(sam.status, STATUS.ASSIGNED, "not pulled off the job")

    passDays(tc, 2)
    assertEquals(sam.status, STATUS.ASSIGNED, "still on the job on its first day")
    assertEquals(sam.trainingDay, 12, "moved back a day")
    assertEquals(sam.courseDaysLeft, 2, "still two days to do")

    -- Still out all of day 12, back by the next morning.
    sam.status = STATUS.IDLE
    passDays(tc, 1)
    assertEquals(sam.trainingDay, 13, "moved back again")
    assertEquals(sam.status, STATUS.TRAINING, "in today")
    passDays(tc, 2)
    assertEquals(sam.adsSkills.mechanic, 1, "learnt in the end")
    assertEquals(sam.trainingCert, nil, "done")
end)

test("a skill changed during the course isn't pushed past the limits", function()
    local world, tc = setup()
    local sam = addWorker(tc, 1, { mechanic = 2 })
    tc.Training:requestBooking(1, sam.id, MECHANIC)
    sam.adsSkills = { mechanic = 3 }
    passDays(tc, 4)
    assertEquals(sam.adsSkills.mechanic, 3, "still 3")
    assertEquals(sam.trainingCert, nil, "booking done anyway")
    assertEquals(world.notices[#world.notices].notify, TheContractorTraining.NOTIFY.NONE, "no level to announce")
end)

test("a booked course saves, loads and streams", function()
    local world, tc = setup()
    local sam = addWorker(tc, 1, {})
    tc.Training:requestBooking(1, sam.id, MECHANIC)

    local xmlFile = {}
    TheContractorTraining.writeXML(xmlFile, "w", sam)
    local loaded = addWorker(tc, 2, {})
    TheContractorTraining.readXML(xmlFile, "w", loaded)
    assertEquals(loaded.trainingCert, MECHANIC, "course")
    assertEquals(loaded.courseDaysLeft, 2, "days")
    assertEquals(loaded.trainingDay, 11, "first day")
    assertEquals(loaded.assessmentDay, nil, "no assessment")

    local stream = world:newStream()
    TheContractorTraining.writeState(stream, sam)
    local state = TheContractorTraining.readState(stream)
    assertEquals(state.trainingCert, MECHANIC, "streamed course")
    assertEquals(state.assessmentDay, nil, "streamed: no assessment")
    assertEquals(state.trainingDay, 11, "streamed first day")
end)

test("at one day a month every course takes a day: booked in one month, done by the start of the month after next", function()
    local world, tc = setup()
    local STATUS = TheContractorWorker.STATUS
    g_currentMission.environment.daysPerPeriod = 1

    -- A trade course, even the 3-day one to level 3.
    local sam = addWorker(tc, 1, { mechanic = 2 })
    assertEquals(TheContractorWorkshop.getCourseDays(sam, "mechanic"), 1, "one day")
    tc.Training:requestBooking(1, sam.id, MECHANIC)
    assertEquals(sam.trainingDay, 11, "next month")
    assertEquals(sam.status, STATUS.IDLE, "not this month")
    passDays(tc, 1)
    assertEquals(sam.status, STATUS.TRAINING, "on the course")
    passDays(tc, 1)
    assertEquals(sam.adsSkills.mechanic, 3, "done")
    assertEquals(sam.status, STATUS.IDLE, "back")

    -- Spraying: a day's course and the assessment the day after.
    assertEquals(TheContractorTraining.getCourseDays("spraying"), 1, "spraying course")
    local gapMin, gapMax = TheContractorTraining.getAssessmentGap()
    assertEquals(gapMin, 1, "gap min")
    assertEquals(gapMax, 1, "gap max")
    local amy = addWorker(tc, 2, {})
    tc.Training:bookTraining(amy, "spraying", TheContractorTraining.getFirstBookableDay(amy, "spraying"))
    assertEquals(amy.trainingDay, 13, "tomorrow")
    assertEquals(amy.assessmentDay, 14, "assessment the day after")

    -- Office Train too.
    assertEquals(TheContractorOffice.getTrainDays("administrator", 2), 1, "office course")
end)

test("a holiday only holds a course up if the course would run into it", function()
    local _, tc = setup()
    g_currentMission.environment.daysPerPeriod = 1
    local sam = addWorker(tc, 1, { mechanic = 1 })

    -- A holiday three months away: the one-day course fits before it.
    sam.holidayStartDay = 13
    sam.holidayDays = 1
    assertEquals(TheContractorTraining.getFirstBookableDay(sam, MECHANIC), 11, "tomorrow")
    -- Spraying spans the course and the assessment's wait: still fits.
    assertEquals(TheContractorTraining.getFirstBookableDay(sam, "spraying"), 11, "spraying tomorrow")

    -- A holiday the day after tomorrow: spraying would run into it, the trade course wouldn't.
    sam.holidayStartDay = 12
    assertEquals(TheContractorTraining.getFirstBookableDay(sam, MECHANIC), 11, "trade course tomorrow")
    assertEquals(TheContractorTraining.getFirstBookableDay(sam, "spraying"), 13, "spraying after the holiday")

    -- On holiday until the day after tomorrow: after it.
    sam.holidayStartDay = 9
    sam.holidayDays = 4
    assertEquals(TheContractorTraining.getFirstBookableDay(sam, MECHANIC), 13, "after the holiday")
end)

test("longer months keep the full course and the assessment's wait", function()
    setup()
    g_currentMission.environment.daysPerPeriod = 30
    assertEquals(TheContractorTraining.getCourseDays("spraying"), 2, "spraying course")
    local gapMin, gapMax = TheContractorTraining.getAssessmentGap()
    assertEquals(gapMin, 2, "gap min")
    assertEquals(gapMax, 5, "gap max")
    assertEquals(TheContractorOffice.getTrainDays("administrator", 2), 3, "office course")

    -- In between, the wait shrinks with the month.
    g_currentMission.environment.daysPerPeriod = 12
    gapMin, gapMax = TheContractorTraining.getAssessmentGap()
    assertEquals(gapMin, 2, "12 days: gap min")
    assertEquals(gapMax, 2, "12 days: gap max")
    g_currentMission.environment.daysPerPeriod = 2
    assertEquals(TheContractorTraining.getCourseDays("spraying"), 2, "2 days: the full course still fits")
end)

test("tcWorker train books a trade course for free, even without ADS", function()
    local world, tc = setup()
    TCConsole.reset()
    TheContractorTraining.registerConsoleCommands()
    local train = TCConsole.groups.worker.subcommands.train
    local sam = addWorker(tc, 1, { mechanic = 1 })
    world.adsOn = false

    assertEquals(train.run(1, { "1", "0", "mechanic" }),
        "Worker 1 booked on a level 2 mechanic course: days 10-11", "booked")
    assertEquals(#world.money, 0, "free")
    assertEquals(sam.status, TheContractorWorker.STATUS.TRAINING, "starts today")
    assertEquals(train.run(1, { "1", "0", "bodyworker" }), "Worker 1 already has training booked", "one at a time")

    local amy = addWorker(tc, 2, { mechanic = 3 })
    assertEquals(train.run(1, { "2", "0", "mechanic" }), "Worker 2 can't take a mechanic course: maxLevel", "capped")
    assertEquals(train.run(1, { "2", "0", "pilot" }), false, "bad argument")
    assertEquals(amy.trainingCert, nil, "nothing booked")
end)
