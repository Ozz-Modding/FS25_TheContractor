-- Staff driving for AI Helpers, AutoDrive, Courseplay and Follow Me (037)
-- get a growth roll for every in-game hour driven, plus a part-hour one on
-- release, so the basics come quickly (1 -> 4 in about 8 hours) and
-- Staff's level curve slows the rest.

local HOUR = 60 * 60 * 1000

local function setup(useRealStaff)
    local world = stubs.install()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    TCWorkerAppearance = { GENDER = { MALE = "male", FEMALE = "female" } }
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/Drivers.lua")

    TheContractorMorale = {
        getGrowthMultiplier = function()
            return 1
        end,
    }
    TCAutoDrive = {
        isDriving = function()
            return false
        end,
    }
    world.tier = "small"
    world.skill = nil
    TCEquipmentClass = {
        getSizeTier = function()
            return world.tier
        end,
        getOperationSkillForVehicles = function()
            return world.skill
        end,
    }
    world.grown = {}
    TCWorkerGrewEvent = {
        showNotification = function(worker, stat, oldValue, newValue)
            table.insert(world.grown, { stat = stat, newValue = newValue })
        end,
    }

    world.rolls = {}
    local staff
    if useRealStaff then
        staff = setmetatable({ workersByFarm = {} }, TheContractorStaff_mt)
    else
        staff = {
            growWorker = function(_, farmId, workerId, tier, skill, chance)
                table.insert(world.rolls, { tier = tier, skill = skill, chance = chance })
            end,
            getWorker = function()
                return nil
            end,
            setWorkerStatus = function() end,
        }
    end
    g_currentMission.getEffectiveTimeScale = function()
        return 1
    end
    g_currentMission.TheContractor = {
        Staff = staff,
        Logbook = {
            noteDriverActivity = function() end,
            onDriverReleased = function() end,
        },
    }

    local drivers = TheContractorDrivers.new()
    drivers.loadedBindings = nil

    world.vehicle = {
        isAIActive = true,
        getIsAIActive = function(self)
            return self.isAIActive
        end,
    }
    local vehicleId = world:register(world.vehicle)
    drivers.bindingsByVehicleId[vehicleId] = { vehicleId = vehicleId, farmId = 1, workerId = 1, activeMs = 0,
        idleMs = 0, graceMs = TheContractorDrivers.RELEASE_GRACE_MS }
    world.vehicleId = vehicleId
    return world, drivers, staff
end

-- Drives for `ms` of game time in 6-minute frames.
local function drive(drivers, ms)
    local step = HOUR / 10
    while ms > 0 do
        drivers:update(math.min(step, ms))
        ms = ms - step
    end
end

test("one roll for every hour driven, against the rig at the time", function()
    local world, drivers = setup(false)
    drive(drivers, HOUR * 0.9)
    assertEquals(#world.rolls, 0, "not an hour yet")

    world.skill = "haulage"
    drive(drivers, HOUR * 1.2)
    assertEquals(#world.rolls, 2, "two hours")
    assertEquals(world.rolls[1].chance, TheContractorDrivers.DRIVER_GROWTH_CHANCE_PER_HOUR)
    assertEquals(world.rolls[2].skill, "haulage", "trailer hitched by then")
    assertEquals(world.rolls[2].tier, "small")
end)

test("release rolls for the part-hour left, scaled down", function()
    local world, drivers = setup(false)
    drive(drivers, HOUR * 2.5)
    assertEquals(#world.rolls, 2)

    drivers:releaseDriver(world.vehicleId, world.vehicle)
    assertEquals(#world.rolls, 3)
    assertNear(world.rolls[3].chance, TheContractorDrivers.DRIVER_GROWTH_CHANCE_PER_HOUR * 0.5, 0.0001)
end)

test("a few minutes left over on release don't roll", function()
    local world, drivers = setup(false)
    drivers.bindingsByVehicleId[world.vehicleId].activeMs = HOUR + 3 * 60000
    drivers:releaseDriver(world.vehicleId, world.vehicle)
    assertEquals(#world.rolls, 0)
end)

local function makeSkills(value)
    local skills = {}
    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        skills[skill] = value
    end
    return skills
end

-- Average hours driven for `getValue(worker)` to go from 1 to 4, with work
-- speed still able to grow alongside it.
local function hoursToFour(world, drivers, staff, getValue)
    local binding = drivers.bindingsByVehicleId[world.vehicleId]
    local total, trials = 0, 2000
    for _ = 1, trials do
        local worker = TheContractorWorker.new(1, 1, "John White", 1, { small = 1 }, 2000, 34, 10, 1, 0,
            makeSkills(1), 5)
        staff.workersByFarm[1] = { [1] = worker }
        local hours = 0
        while getValue(worker) < 4 do
            hours = hours + 1
            drivers:rollDrivingGrowth(binding, world.vehicle, 1)
        end
        total = total + hours
    end
    return total / trials
end

test("a tractor's rating goes 1 -> 4 in about 8 hours", function()
    local world, drivers, staff = setup(true)
    math.randomseed(11)
    local hours = hoursToFour(world, drivers, staff, function(worker)
        return worker:getTierCapability("small")
    end)
    assertTrue(hours > 6 and hours < 10, "took " .. hours)
end)

test("a combine's harvesting goes 1 -> 4 in about 8 hours", function()
    local world, drivers, staff = setup(true)
    world.tier = nil
    world.skill = "harvesting"
    math.randomseed(12)
    local hours = hoursToFour(world, drivers, staff, function(worker)
        return worker:getSkill("harvesting")
    end)
    assertTrue(hours > 6 and hours < 10, "took " .. hours)
end)

test("high levels still take a long time", function()
    local world, drivers, staff = setup(true)
    math.randomseed(13)
    local binding = drivers.bindingsByVehicleId[world.vehicleId]
    local total, trials = 0, 1000
    for _ = 1, trials do
        local worker = TheContractorWorker.new(1, 1, "John White", 10, { small = 8 }, 2000, 34, 10, 1, 0,
            makeSkills(1), 5)
        staff.workersByFarm[1] = { [1] = worker }
        local hours = 0
        while worker:getTierCapability("small") == 8 do
            hours = hours + 1
            drivers:rollDrivingGrowth(binding, world.vehicle, 1)
        end
        total = total + hours
    end
    assertTrue(total / trials > 8, "8 -> 9 took " .. total / trials)
end)
