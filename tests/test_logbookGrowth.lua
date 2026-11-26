-- Issue #16: a worker's growth from a job (030's roll, 074's stepping up)
-- goes on their row in the job's logbook entry, on the server as it's
-- announced and on clients as TCWorkerGrewEvent lands, and is kept through
-- the stream and the save. Growth from driving (037) belongs to no job.

local fakes = dofile("tests/fakes.lua")

local function makeSkills(value)
    local skills = {}
    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        skills[skill] = value
    end
    return skills
end

local function setup()
    local world = stubs.install()
    fakes.installContractor(world)
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    TCWorkerAppearance = { GENDER = { MALE = "male", FEMALE = "female" } }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/Logbook.lua")
    world:load("src/events/TCWorkerGrewEvent.lua")
    TCWorkerGrewEvent.showNotification = function() end

    local tc = g_currentMission.TheContractor
    tc.Logbook = TheContractorLogbook.new()
    tc.Staff = setmetatable({ workersByFarm = {} }, TheContractorStaff_mt)
    world.worker = TheContractorWorker.new(1, 1, "John White", 5, { small = 5 }, 2000, 34, 10, 1, 0,
        makeSkills(4), 5)
    tc.Staff.workersByFarm[1] = { [1] = world.worker }

    -- A logged job (42) with the worker as its operator.
    tc.Logbook:applyJobEntry({ jobId = 42, farmId = 1, outcome = TheContractorLogbook.OUTCOME.COMPLETED,
        jobType = "plow", title = "Plough", fieldId = 3, day = 10, price = 1000,
        crew = { { workerId = 1, name = "John White", role = TheContractorLogbook.ROLE.OPERATOR, rating = 4 } },
        equipment = {}, supplies = {} })
    return world, tc
end

local function getGrowth(tc)
    return tc.Logbook:getJobEntry(1, 42).crew[1].growth
end

test("growth from a job goes on the worker's row in its entry", function()
    local _, tc = setup()
    tc.Staff:boostWorker(1, 1, "tillage", 42)

    local growth = getGrowth(tc)
    assertEquals(#growth, 1)
    assertEquals(growth[1].stat, "tillage")
    assertEquals(growth[1].from, 4)
    assertEquals(growth[1].to, 5)
end)

test("a tractor rating reaching the threshold logs the next size's certificate too", function()
    local world, tc = setup()
    world.worker:setStat("small", TheContractorStaff.CERTIFY_THRESHOLD - 1)
    tc.Staff:boostWorker(1, 1, "small", 42)

    local growth = getGrowth(tc)
    assertEquals(#growth, 2)
    assertEquals(growth[1].stat, "small")
    assertEquals(growth[1].to, TheContractorStaff.CERTIFY_THRESHOLD)
    assertEquals(growth[2].stat, "medium")
    assertEquals(growth[2].from, nil, "newly certified")
    assertEquals(growth[2].to, TheContractorStaff.CERTIFY_START_RATING)
end)

test("growth from no job (driving) leaves the logbook alone", function()
    local _, tc = setup()
    tc.Staff:boostWorker(1, 1, "tillage")
    assertEquals(getGrowth(tc), nil)
end)

test("a client puts the growth on the entry as the event lands", function()
    local world, tc = setup()
    local stream = world:newStream()
    TCWorkerGrewEvent.new(1, 1, "haulage", 5, 42):writeStream(stream)
    TCWorkerGrewEvent.emptyNew():readStream(stream)

    assertEquals(world.worker:getSkill("haulage"), 5)
    local growth = getGrowth(tc)
    assertEquals(#growth, 1)
    assertEquals(growth[1].stat, "haulage")
    assertEquals(growth[1].from, 4)
end)

test("an event with no job carries none", function()
    local world, tc = setup()
    local stream = world:newStream()
    TCWorkerGrewEvent.new(1, 1, "haulage", 5):writeStream(stream)
    TCWorkerGrewEvent.emptyNew():readStream(stream)

    assertEquals(world.worker:getSkill("haulage"), 5)
    assertEquals(getGrowth(tc), nil)
end)

test("growth is kept through the stream", function()
    local world, tc = setup()
    tc.Staff:boostWorker(1, 1, "tillage", 42)
    tc.Logbook.jobEntriesByFarm[1][42].crew[1].growth[2] = { stat = "medium", to = 1 }

    local stream = world:newStream()
    TheContractorLogbook.writeJobEntry(stream, tc.Logbook:getJobEntry(1, 42))
    local entry = TheContractorLogbook.readJobEntry(stream)

    local growth = entry.crew[1].growth
    assertEquals(#growth, 2)
    assertEquals(growth[1].stat, "tillage")
    assertEquals(growth[1].from, 4)
    assertEquals(growth[1].to, 5)
    assertEquals(growth[2].from, nil)
end)

test("a crew member with no growth streams as none", function()
    local world, tc = setup()
    local stream = world:newStream()
    TheContractorLogbook.writeJobEntry(stream, tc.Logbook:getJobEntry(1, 42))
    assertEquals(TheContractorLogbook.readJobEntry(stream).crew[1].growth, nil)
end)

test("growth is kept through the save", function()
    local _, tc = setup()
    tc.Staff:boostWorker(1, 1, "tillage", 42)
    tc.Logbook.jobEntriesByFarm[1][42].crew[1].growth[2] = { stat = "medium", to = 1 }
    tc.Drivers = { bindingsByVehicleId = {} }

    local xmlFile = {}
    tc.Logbook:saveToXmlFile(xmlFile)
    local loaded = TheContractorLogbook.new()
    tc.Logbook = loaded
    loaded:loadFromXMLFile(xmlFile)

    local growth = loaded:getJobEntry(1, 42).crew[1].growth
    assertEquals(#growth, 2)
    assertEquals(growth[1].stat, "tillage")
    assertEquals(growth[1].from, 4)
    assertEquals(growth[1].to, 5)
    assertEquals(growth[2].stat, "medium")
    assertEquals(growth[2].from, nil)
end)
