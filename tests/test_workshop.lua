-- ADS workshop trades (091): rolling skills, the pay they add (only while
-- ADS takes our staff), the tick (one worker per role, moving the old one
-- out), ADS's status for a ticked worker, what ADS is told, save/stream and
-- tcWorker adsSkill.

local function setup()
    local world = stubs.install()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    Enterable = {}
    TheContractor = { SaveKey = "TheContractor" }
    TCCalendar = {
        getPeriodIndex = function()
            return 40
        end,
    }
    TheContractorDrivers = {
        getModEnv = function()
            return nil
        end,
    }

    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/Office.lua")
    world:load("src/business/Workshop.lua")
    world:load("src/util/TCADSWorkshop.lua")
    world:load("src/util/TCConsole.lua")

    world.adsOn = true
    world.refreshes = {}
    world.adsEnv = {
        ADS_OwnWorkshop = {
            STAFF_API_VERSION = 1,
            registerStaffProvider = function()
                return true
            end,
            refreshStaffProvider = function(farmId)
                table.insert(world.refreshes, farmId)
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

    world.broadcasts = {}
    g_server = {
        broadcastEvent = function(_, event)
            table.insert(world.broadcasts, event)
        end,
    }
    TCWorkerWorkshopEvent = {
        new = function(farmId, workerId, adsSkills, workshopRole)
            return { farmId = farmId, workerId = workerId, adsSkills = adsSkills, workshopRole = workshopRole }
        end,
    }

    local tc = g_currentMission.TheContractor
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {}, nextWorkerId = 1 }, TheContractorStaff_mt)
    tc.Office = TheContractorOffice.new()
    world.menuRefreshes = 0
    tc.MenuContractor = {
        onOfficeChanged = function()
            world.menuRefreshes = world.menuRefreshes + 1
        end,
    }
    return world, tc
end

local function addWorker(tc, id, adsSkills, status)
    local worker = TheContractorWorker.new(id, 1, "Worker " .. id, 5, { small = 5 }, 2000, 30, 0, 1, 0, {}, 5)
    worker.adsSkills = adsSkills or {}
    worker.status = status or TheContractorWorker.STATUS.IDLE
    tc.Staff.workersByFarm[1] = tc.Staff.workersByFarm[1] or {}
    tc.Staff.workersByFarm[1][id] = worker
    return worker
end

test("about a quarter of candidates have a skill, a few two, mostly level 1", function()
    setup()
    math.randomseed(91)
    local rolls = 20000
    local withAny, withTwo = 0, 0
    local levels = { 0, 0, 0 }
    for _ = 1, rolls do
        local skills = TheContractorWorkshop.rollSkills()
        local count = 0
        for role, level in pairs(skills) do
            assertTrue(TheContractorWorkshop.IS_ROLE[role], "a trade: " .. tostring(role))
            assertTrue(level >= 1 and level <= 3, "level 1-3")
            levels[level] = levels[level] + 1
            count = count + 1
        end
        assertTrue(count <= TheContractorWorkshop.MAX_SKILLS, "at most two")
        if count >= 1 then
            withAny = withAny + 1
        end
        if count == 2 then
            withTwo = withTwo + 1
        end
    end
    assertNear(withAny / rolls, 0.25, 0.015, "one or more")
    assertNear(withTwo / rolls, 0.07, 0.01, "two")
    local total = levels[1] + levels[2] + levels[3]
    assertNear(levels[1] / total, 0.6, 0.02, "level 1")
    assertNear(levels[2] / total, 0.3, 0.02, "level 2")
    assertNear(levels[3] / total, 0.1, 0.02, "level 3")
end)

test("skills add to market value, used by the workshop or not", function()
    local world = setup()
    world:load("src/business/PayReviews.lua")
    assertEquals(TheContractorWorkshop.getSalaryPremium({}), 0, "none")
    assertEquals(TheContractorWorkshop.getSalaryPremium({ mechanic = 2 }), 350, "one at level 2")
    -- The best in full, the other at half.
    assertEquals(TheContractorWorkshop.getSalaryPremium({ mechanic = 1, bodyworker = 3 }), 675, "two")

    local base = TheContractorStaff.getSalary(5, { small = 5 }, {})
    assertEquals(TheContractorStaff.getSalary(5, { small = 5 }, {}, { diagnostician = 3 }), base + 600, "skilled")

    local worker = TheContractorWorker.new(1, 1, "Sam", 5, { small = 5 }, base, 30, 0, 1, 0, {}, 5)
    worker.adsSkills = { diagnostician = 3 }
    assertEquals(TheContractorPayReviews.getMarketValue(worker), base + 600, "market value with ADS")
    -- ADS's setting off (or the mod gone): still a skilled worker.
    world.adsOn = false
    assertEquals(TheContractorPayReviews.getMarketValue(worker), base + 600, "market value without ADS")
end)

test("only an idle worker is there; cooldown counts as working", function()
    local _, tc = setup()
    local STATUS = TheContractorWorker.STATUS
    local expected = {
        [STATUS.IDLE] = "available",
        [STATUS.ASSIGNED] = "working",
        [STATUS.DRIVING] = "working",
        [STATUS.COOLDOWN] = "working",
        [STATUS.SICK] = "sick",
        [STATUS.HOLIDAY] = "holiday",
        [STATUS.TRAINING] = "training",
    }
    for status, adsStatus in pairs(expected) do
        local worker = addWorker(tc, 1, { mechanic = 1 }, status)
        assertEquals(TheContractorWorkshop.getADSStatus(worker), adsStatus, status)
    end
end)

test("ticking needs ADS and the skill, and moves the old holder out", function()
    local world, tc = setup()
    local sam = addWorker(tc, 1, { mechanic = 2 })
    local jo = addWorker(tc, 2, { mechanic = 1, bodyworker = 3 })

    assertEquals(TheContractorWorkshop.setRole(1, 1, "bodyworker"), TheContractorWorkshop.PROBLEM.NO_SKILL, "no skill")
    assertEquals(TheContractorWorkshop.setRole(1, 1, "receptionist"), TheContractorWorkshop.PROBLEM.UNKNOWN_ROLE,
        "office role")
    world.adsOn = false
    assertEquals(TheContractorWorkshop.setRole(1, 1, "mechanic"), TheContractorWorkshop.PROBLEM.NEEDS_ADS, "no ADS")
    world.adsOn = true

    assertEquals(TheContractorWorkshop.setRole(1, 1, "mechanic"), nil, "ticked")
    assertEquals(sam.workshopRole, "mechanic", "Sam's the mechanic")
    assertEquals(#world.broadcasts, 1, "broadcast")
    assertEquals(world.broadcasts[1].workshopRole, "mechanic", "broadcast role")
    assertEquals(world.refreshes[1], 1, "ADS told")
    assertTrue(world.menuRefreshes > 0, "menu redrawn")

    assertEquals(TheContractorWorkshop.setRole(1, 2, "mechanic"), nil, "Jo takes over")
    assertEquals(jo.workshopRole, "mechanic", "Jo's the mechanic")
    assertEquals(sam.workshopRole, nil, "Sam moved out")
    assertEquals(TheContractorWorkshop.getRoleHolder(1, "mechanic"), jo, "one holder")

    -- A worker is in one role at a time.
    assertEquals(TheContractorWorkshop.setRole(1, 2, "bodyworker"), nil, "Jo moves to bodywork")
    assertEquals(jo.workshopRole, "bodyworker", "bodyworker")
    assertEquals(TheContractorWorkshop.getRoleHolder(1, "mechanic"), nil, "mechanic free")

    -- Unticking works without ADS (so a player can tidy up after removing it).
    world.adsOn = false
    assertEquals(TheContractorWorkshop.setRole(1, 2, nil), nil, "unticked")
    assertEquals(jo.workshopRole, nil, "out")
end)

test("ADS is told the ticked workers with their level and status, alongside the office", function()
    local _, tc = setup()
    local sam = addWorker(tc, 3, { mechanic = 2 })
    local jo = addWorker(tc, 4, { diagnostician = 1 }, TheContractorWorker.STATUS.COOLDOWN)
    addWorker(tc, 5, { bodyworker = 3 })
    sam.workshopRole = "mechanic"
    jo.workshopRole = "diagnostician"
    tc.Office.membersByFarm[1] = {
        administrator = { id = 9, role = "administrator", farmId = 1, name = "Ann", level = 2 },
    }

    local assignments = TCADSWorkshop.getAssignments(1)
    assertEquals(assignments.mechanic.id, 3, "mechanic")
    assertEquals(assignments.mechanic.level, 2, "mechanic level")
    assertEquals(assignments.mechanic.status, "available", "idle")
    assertEquals(assignments.diagnostician.status, "working", "cooldown")
    assertEquals(assignments.bodyworker, nil, "not ticked")
    assertEquals(assignments.receptionist.id, 9, "office too")

    -- Two claiming one role (a bad save): the lowest id wins.
    local other = addWorker(tc, 2, { mechanic = 1 })
    other.workshopRole = "mechanic"
    assertEquals(TCADSWorkshop.getAssignments(1).mechanic.id, 2, "lowest id")
end)

test("removing the skill they're ticked into unticks them", function()
    local world, tc = setup()
    local sam = addWorker(tc, 1, { mechanic = 2, bodyworker = 1 })
    TheContractorWorkshop.setRole(1, 1, "mechanic")
    TheContractorWorkshop.setSkills(sam, { bodyworker = 1 })
    assertEquals(sam.workshopRole, nil, "unticked")
    assertEquals(sam.adsSkills.mechanic, nil, "skill gone")
    assertEquals(world.broadcasts[#world.broadcasts].adsSkills.bodyworker, 1, "broadcast skills")
end)

test("skills and the role save, load and stream", function()
    local world, tc = setup()
    local sam = addWorker(tc, 1, { mechanic = 2, bodyworker = 1 })
    sam.workshopRole = "bodyworker"

    local xmlFile = {}
    TheContractorWorkshop.writeXML(xmlFile, "w", sam)
    local skills = TheContractorWorkshop.readSkillsXML(xmlFile, "w")
    assertEquals(skills.mechanic, 2, "mechanic")
    assertEquals(skills.bodyworker, 1, "bodyworker")
    assertEquals(skills.diagnostician, nil, "no diagnostician")
    assertEquals(TheContractorWorkshop.readRoleXML(xmlFile, "w", skills), "bodyworker", "role")
    assertEquals(TheContractorWorkshop.readRoleXML(xmlFile, "w", { mechanic = 2 }), nil, "role without its skill")

    local stream = world:newStream()
    TheContractorWorkshop.writeState(stream, sam)
    local streamed, role = TheContractorWorkshop.readState(stream)
    assertEquals(streamed.mechanic, 2, "streamed mechanic")
    assertEquals(streamed.bodyworker, 1, "streamed bodyworker")
    assertEquals(role, "bodyworker", "streamed role")

    local plain = addWorker(tc, 2, {})
    stream = world:newStream()
    TheContractorWorkshop.writeState(stream, plain)
    streamed, role = TheContractorWorkshop.readState(stream)
    assertEquals(next(streamed), nil, "no skills")
    assertEquals(role, nil, "no role")
end)

test("tcWorker adsSkill sets, removes and caps skills", function()
    local _, tc = setup()
    TCConsole.reset()
    TheContractorWorkshop.registerConsoleCommands()
    local adsSkill = TCConsole.groups.worker.subcommands.adsskill
    local sam = addWorker(tc, 1, {})
    sam.name = "Sam Hill"

    assertEquals(adsSkill.run(1, { "1", "mechanic", "2" }), "Sam Hill: mechanic 2", "set")
    assertEquals(adsSkill.run(1, { "Sam", "Hill", "bodyworker", "1" }), "Sam Hill: mechanic 2, bodyworker 1",
        "by name")
    assertEquals(adsSkill.run(1, { "1", "diagnostician", "1" }),
        "Sam Hill already has 2 workshop skills: set one to 0 first", "capped")
    assertEquals(adsSkill.run(1, { "1", "mechanic", "0" }), "Sam Hill: bodyworker 1", "removed")
    assertEquals(adsSkill.run(1, { "1", "mechanic", "4" }), false, "bad level")
    assertEquals(adsSkill.run(1, { "1", "receptionist", "1" }), false, "office role")
end)

test("trades go by ADS's names: the diagnostician is the electrician, the receptionist the advisor", function()
    local _, tc = setup()
    assertEquals(TheContractorWorkshop.getRoleName("diagnostician"), "Electrician", "electrician")
    assertEquals(TheContractorOffice.getDefinition("administrator").adsRole, "receptionist", "still ADS's id")
    assertEquals(g_i18n:getText("tc_office_adsRole_receptionist"), "Advisor", "advisor")
    assertEquals(TheContractorWorkshop.findRole("Electrician"), "diagnostician", "the console takes ADS's name")
    assertEquals(TheContractorWorkshop.findRole("diagnostician"), "diagnostician", "or the id")
    assertEquals(TheContractorWorkshop.findRole("advisor"), nil, "not a trade")

    TCConsole.reset()
    TheContractorWorkshop.registerConsoleCommands()
    local adsSkill = TCConsole.groups.worker.subcommands.adsskill
    local sam = addWorker(tc, 1, {})
    sam.name = "Sam Hill"
    assertEquals(adsSkill.run(1, { "1", "electrician", "2" }), "Sam Hill: electrician 2", "set by ADS's name")
    assertEquals(sam.adsSkills.diagnostician, 2, "saved under the id")
end)

test("a whole worker keeps their skills and role through the save and the stream", function()
    local world, tc = setup()
    world:load("src/business/Training.lua")
    world:load("src/business/Morale.lua")
    world:load("src/business/PayReviews.lua")
    world:load("src/business/Holidays.lua")
    -- Looks aren't what's tested: every look builds.
    TCWorkerAppearance.toPlayerStyle = function(data)
        return data ~= nil and {} or nil
    end
    local sam = addWorker(tc, 1, { mechanic = 2 })
    sam.appearance = { model = "male.xml", configs = {} }
    sam.workshopRole = "mechanic"

    local xmlFile = {}
    TheContractorStaff.writeWorkerXML(xmlFile, "w", sam)
    local loaded = TheContractorStaff.readWorkerXML(xmlFile, "w", 1)
    assertEquals(loaded.adsSkills.mechanic, 2, "saved skill")
    assertEquals(loaded.workshopRole, "mechanic", "saved role")

    -- A pool candidate never has a role, and their asking salary counts the skill.
    local candidate = TheContractorStaff.readWorkerXML(xmlFile, "w", nil)
    assertEquals(candidate.workshopRole, nil, "candidate role")
    assertEquals(candidate.salary, TheContractorStaff.getSalary(sam.workSpeed, sam.tierCapability, candidate.skills) + 350,
        "candidate salary")

    local stream = world:newStream()
    TheContractorStaff.writeWorker(stream, sam)
    local streamed = TheContractorStaff.readWorker(stream)
    assertEquals(streamed.adsSkills.mechanic, 2, "streamed skill")
    assertEquals(streamed.workshopRole, "mechanic", "streamed role")
    assertEquals(stream.position, #stream.values, "everything read")
end)

test("every trade has a name", function()
    setup()
    for _, role in ipairs(TheContractorWorkshop.ROLES) do
        -- g_i18n fails the test on a missing key.
        assertTrue(TheContractorWorkshop.getRoleName(role) ~= "", role)
    end
end)
