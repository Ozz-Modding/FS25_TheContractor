-- Tractor experience as a ladder (small -> medium -> large): candidates are
-- rolled the way growth builds it, and growing a tier to CERTIFY_THRESHOLD
-- qualifies the worker on the next one up.

local function setup()
    local world = stubs.install()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    TCWorkerAppearance = { GENDER = { MALE = "male", FEMALE = "female" } }
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")

    local staff = setmetatable({ workersByFarm = {} }, TheContractorStaff_mt)
    g_currentMission.TheContractor = { Staff = staff }

    world.grown = {}
    TCWorkerGrewEvent = {
        showNotification = function(worker, stat, oldValue, newValue)
            table.insert(world.grown, { stat = stat, oldValue = oldValue, newValue = newValue })
        end,
    }
    return world, staff
end

local function addWorker(staff, tierCapability, potential)
    local worker = TheContractorWorker.new(1, 1, "John White", 3, tierCapability, 1725, 34, potential or 5)
    staff.workersByFarm[1] = { [1] = worker }
    return worker
end

test("rolled tractor experience never skips a size or stalls past the threshold", function()
    setup()
    math.randomseed(42)
    local threshold = TheContractorStaff.CERTIFY_THRESHOLD
    local topCounts = { none = 0, small = 0, medium = 0, large = 0 }

    for _ = 1, 5000 do
        local caps = TheContractorStaff.rollTierCapability()
        local top = nil
        for i, tier in ipairs(TheContractorWorker.TIERS) do
            local rating = caps[tier]
            if rating ~= nil then
                assertTrue(rating >= 1 and rating <= 10, "rating in range")
                if i > 1 then
                    local below = caps[TheContractorWorker.TIERS[i - 1]]
                    assertTrue(below ~= nil and below >= threshold, "the size below is at the threshold")
                end
                top = tier
            end
        end
        if top ~= nil then
            local index = top == "small" and 1 or top == "medium" and 2 or 3
            if index > 1 then
                assertTrue(caps[top] <= caps[TheContractorWorker.TIERS[index - 1]], "top no better than the size below")
            end
            if TheContractorStaff.getNextTier(top) ~= nil then
                assertTrue(caps[top] < threshold, "top size under the threshold unless it's the biggest")
            end
        end
        topCounts[top or "none"] = topCounts[top or "none"] + 1
    end

    assertTrue(topCounts.none > 0 and topCounts.small > 0 and topCounts.medium > 0 and topCounts.large > 0,
        "every top size turns up")
end)

test("growing medium to the threshold qualifies them on large for the same point", function()
    local world, staff = setup()
    local worker = addWorker(staff, { small = 9, medium = 6 }, 5)

    staff:announceGrowth(1, worker, "medium", 7)
    assertEquals(worker:getTierCapability("large"), nil, "announceGrowth alone doesn't certify")

    worker.tierCapability.medium = 6
    math.randomseed(1)
    TheContractorStaff.pickGrowth = function() return "medium", 7 end
    staff:growWorker(1, worker.id, "medium", nil)

    assertEquals(worker:getTierCapability("medium"), 7, "medium")
    assertEquals(worker:getTierCapability("large"), TheContractorStaff.CERTIFY_START_RATING, "large")
    assertEquals(worker.growthPotential, 4, "one point spent")
    assertEquals(world.grown[#world.grown].stat, "large", "told about large")
    assertEquals(world.grown[#world.grown].oldValue, nil, "as a new certification")
end)

test("growth below the threshold, or with the next size held already, certifies nothing new", function()
    local _, staff = setup()
    TheContractorStaff.pickGrowth = function() return "medium", 5 end
    local worker = addWorker(staff, { small = 9, medium = 4 })
    staff:growWorker(1, worker.id, "medium", nil)
    assertEquals(worker:getTierCapability("large"), nil, "below the threshold")

    TheContractorStaff.pickGrowth = function() return "medium", 9 end
    worker = addWorker(staff, { small = 9, medium = 8, large = 5 })
    staff:growWorker(1, worker.id, "medium", nil)
    assertEquals(worker:getTierCapability("large"), 5, "large left as it was")
end)

test("the top size growing to the threshold has nothing above it to certify", function()
    local _, staff = setup()
    TheContractorStaff.pickGrowth = function() return "large", 7 end
    local worker = addWorker(staff, { small = 9, medium = 8, large = 6 })
    staff:growWorker(1, worker.id, "large", nil)
    assertEquals(worker:getTierCapability("large"), 7, "large")
end)
