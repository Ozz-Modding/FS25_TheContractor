-- 133: the Jobs tab's list (TCJobList). Taken-on jobs only; those that can
-- be worked now first by deadline, then the ones still to come (132's
-- ready day) by ready day; each view its own part; days left to the
-- deadline.

local TODAY = 40

local function setup()
    local world = stubs.install()
    g_currentMission.environment = { currentMonotonicDay = TODAY }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    world:load("src/business/Job.lua")
    world:load("src/util/TCJobList.lua")
    return world
end

local nextId = 0

-- def: { state, deadline, ready }
local function job(def)
    nextId = nextId + 1
    local j = TheContractorJob.new(def.id or nextId, 1, "harvest", 7, 1, 1, 1, 1000)
    j.state = def.state or TheContractorJob.STATE.ACCEPTED
    j.deadlineDay = def.deadline
    j.readyDay = def.ready
    return j
end

local function ids(list)
    local result = {}
    for _, j in ipairs(list) do
        table.insert(result, j.id)
    end
    return table.concat(result, ",")
end

test("only taken-on jobs are listed", function()
    setup()
    local S = TheContractorJob.STATE
    local jobs = {}
    for i, state in ipairs({ S.OFFERED, S.NEGOTIATING, S.ACCEPTED, S.ALLOCATED, S.IN_PROGRESS, S.COMPLETED,
        S.DECLINED, S.MISSED }) do
        table.insert(jobs, job({ id = i, state = state, deadline = TODAY + i }))
    end
    assertEquals(ids(TCJobList.build(jobs, "all")), "3,4,5")
end)

test("ready now first by deadline, then upcoming by ready day", function()
    setup()
    local S = TheContractorJob.STATE
    local jobs = {
        job({ id = 1, deadline = TODAY + 5 }),
        job({ id = 2, deadline = TODAY, state = S.IN_PROGRESS }),
        job({ id = 3, deadline = TODAY + 62, ready = TODAY + 60 }),
        job({ id = 4, deadline = TODAY + 22, ready = TODAY + 20 }),
        job({ id = 5, deadline = TODAY + 2, state = S.ALLOCATED }),
        job({ id = 6, deadline = TODAY + 5 }),
        -- Ready today: in the ready part.
        job({ id = 7, deadline = TODAY + 1, ready = TODAY }),
        -- Same ready day as 4, due sooner.
        job({ id = 8, deadline = TODAY + 21, ready = TODAY + 20 }),
    }
    assertEquals(ids(TCJobList.build(jobs, "all")), "2,7,5,1,6,8,4,3")
    assertEquals(ids(TCJobList.build(jobs, "ready")), "2,7,5,1,6")
    assertEquals(ids(TCJobList.build(jobs, "upcoming")), "8,4,3")
    assertEquals(ids(TCJobList.build(jobs, "nonsense")), "2,7,5,1,6,8,4,3", "anything else is all")
end)

test("an allocated job is ready now whatever its ready day says", function()
    setup()
    local allocated = job({ state = TheContractorJob.STATE.ALLOCATED, deadline = TODAY + 9, ready = TODAY + 8 })
    assertTrue(TCJobList.isReadyNow(allocated))
    assertTrue(not TCJobList.isReadyNow(job({ deadline = TODAY + 9, ready = TODAY + 8 })))
end)

test("a job moves to the ready part on its ready day", function()
    setup()
    local upcoming = job({ id = 1, deadline = TODAY + 12, ready = TODAY + 10 })
    local now = job({ id = 2, deadline = TODAY + 11 })
    assertEquals(ids(TCJobList.build({ upcoming, now }, "ready")), "2")
    g_currentMission.environment.currentMonotonicDay = TODAY + 10
    assertEquals(ids(TCJobList.build({ upcoming, now }, "ready")), "2,1")
    assertEquals(ids(TCJobList.build({ upcoming, now }, "upcoming")), "")
end)

test("days left to the deadline", function()
    setup()
    assertEquals(TCJobList.getDaysLeft(job({ deadline = TODAY }), TODAY), 0)
    assertEquals(TCJobList.getDaysLeft(job({ deadline = TODAY + 1 }), TODAY), 1)
    assertEquals(TCJobList.getDaysLeft(job({ deadline = TODAY + 7 }), TODAY), 7)
    assertEquals(TCJobList.getDaysLeft(job({ deadline = TODAY - 1 }), TODAY), 0, "never below today")
    assertEquals(TCJobList.getDaysLeft(job({}), TODAY), nil)
end)
