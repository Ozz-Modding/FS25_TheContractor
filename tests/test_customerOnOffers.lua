-- 112: who an Inbox offer is from (the job's customer, 110, through an
-- endsWithJob message), and offer texts naming them live: the real Inbox
-- and Job, the real texts, with the jobs and the farmers faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }

    world:load("src/business/Job.lua")
    world:load("src/business/Inbox.lua")

    local tc = g_currentMission.TheContractor
    world.people = {
        [1] = { id = 1, name = "Zed Official", isOfficial = true },
        [2] = { id = 2, name = "Tom Hargreaves", isOfficial = false },
    }
    tc.Farmers = {
        getPerson = function(_, personId) return world.people[personId] end,
    }
    world.jobs = {}
    tc.Jobs = {
        getJob = function(_, farmId, jobId)
            local job = world.jobs[jobId]
            return job ~= nil and job.farmId == farmId and job or nil
        end,
    }
    function world:addJob(id, customerId)
        local job = TheContractorJob.new(id, 1, "plow", 4, 1, 1, 1, 1000)
        job.customerId = customerId
        self.jobs[id] = job
        return job
    end

    tc.Inbox = TheContractorInbox.new()
    tc.Inbox:registerMessageKind("joyriders", {
        endsWithJob = true,
        getArgs = function(message)
            return TheContractorInbox.getCustomerNamedArgs(message, { tc_joyriders_offerBody = true })
        end,
    })
    tc.Inbox:registerMessageKind("notice", {})

    -- A message as the inbox holds one (posting is the server's business).
    function world:message(kind, bodyKey, args, jobId)
        return { id = 1, farmId = 1, kind = kind, createdDay = 1, titleKey = "tc_joyriders_offerTitle",
            bodyKey = bodyKey, args = args, actions = {}, payload = { jobId = jobId } }
    end

    return world, tc
end

test("an offer is from its job's customer", function()
    local world, tc = setup()
    world:addJob(7, 2)

    local customer = tc.Inbox:getMessageCustomer(world:message("joyriders", "tc_joyriders_offerBody", { 4 }, 7))
    assertEquals("Tom Hargreaves", customer.name)
end)

test("a message that doesn't offer a job is from nobody", function()
    local world, tc = setup()
    world:addJob(7, 2)

    assertEquals(nil, tc.Inbox:getMessageCustomer(world:message("notice", "tc_joyriders_offerBody", { 4 }, 7)))
end)

test("an offer whose job is gone, or has no customer, is from nobody", function()
    local world, tc = setup()
    world:addJob(8, nil)

    assertEquals(nil, tc.Inbox:getMessageCustomer(world:message("joyriders", "tc_joyriders_offerBody", { 4 }, 7)))
    assertEquals(nil, tc.Inbox:getMessageCustomer(world:message("joyriders", "tc_joyriders_offerBody", { 4 }, 8)))
end)

-- The args the inbox formats the body with, as its kind gives them.
local function shownArgs(tc, message)
    return tc.Inbox:getKind(message.kind).getArgs(message)
end

test("an offer's text names the customer as they're called now", function()
    local world, tc = setup()
    world:addJob(7, 2)
    local message = world:message("joyriders", "tc_joyriders_offerBody", { 4 }, 7)

    local args = shownArgs(tc, message)
    assertEquals(args[1], 4, "the posted args first")
    assertEquals(args[2], world.people[2].name, "then the customer")

    world.people[2].name = "Tom Fairweather"
    assertEquals(shownArgs(tc, message)[2], "Tom Fairweather", "renamed")
    -- The saved args aren't touched.
    assertEquals(1, #message.args)
end)

test("an offer with no customer still gets a name to show", function()
    local world, tc = setup()
    local message = world:message("joyriders", "tc_joyriders_offerBody", { 4 }, 7)

    assertEquals(tc.Inbox:getMessageCustomer(message), nil)
    assertEquals(#shownArgs(tc, message), 2, "a stand-in for the customer")
end)

test("a body not named for it keeps its own args", function()
    local world = setup()
    world:addJob(7, 2)
    local message = world:message("joyriders", "tc_joyriders_ownTitle", { 4 }, 7)

    assertEquals(message.args, TheContractorInbox.getCustomerNamedArgs(message, { tc_joyriders_offerBody = true }))
end)

test("the real kinds name the customer in every body they list, and only there", function()
    local world = setup()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    world:load("src/business/Joyriders.lua")
    world:load("src/business/FlyTipping.lua")
    world:addJob(7, 2)

    -- Each named body takes the posted args plus the name, with nothing
    -- left over or missing.
    local postedArgs = {
        tc_joyriders_offerBody = { 4 },
        tc_joyriders_sowBody = { 4 },
        tc_flyTipping_offerBody = { 4, 3 },
    }
    for _, keys in ipairs({ TheContractorJoyriders.NAMED_BODY_KEYS, TheContractorFlyTipping.NAMED_BODY_KEYS }) do
        for key in pairs(keys) do
            local args = TheContractorInbox.getCustomerNamedArgs(world:message("joyriders", key, postedArgs[key], 7),
                keys)
            local _, placeholders = string.gsub(g_i18n:getText(key), "%%s", "")
            assertEquals(#args, placeholders, key)
            assertEquals("Tom Hargreaves", args[#args], key)
        end
    end
end)
