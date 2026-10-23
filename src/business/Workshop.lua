-- ADS workshop trades (091). Field workers can have FS25_AdvancedDamageSystem
-- workshop skills - mechanic, diagnostician, bodyworker - at level 1-3, at
-- most MAX_SKILLS of them (worker.adsSkills = { [role] = level }). A worker
-- can be ticked to work in the farm's ADS own workshop in one of those
-- roles whenever they aren't out on a job (worker.workshopRole, nil when
-- unticked). One ticked worker per role per farm: ADS takes one person per
-- role, and ticking someone into a role that's taken moves the other worker
-- out. TCADSWorkshop hands ticked workers to ADS with their status, which
-- only counts as there while they're idle (COOLDOWN counts as working).
-- Their trade's work in ADS waits while they're away; allocation still
-- takes them as normal.
--
-- Skills are only rolled for candidates while ADS is taking our staff
-- (TCADSWorkshop.isActive), so a game without it has none. Once a worker
-- has them they always count toward market value (getSalaryPremium), used
-- or not: a skilled worker is paid as one. A hired worker's pay only moves
-- through pay reviews (058), as ever. The tick itself doesn't change pay.
--
-- Both fields live on the worker: saved and streamed with it, and changed
-- through TCWorkerWorkshopEvent. No state of its own.
--
-- 092: the player can book a worker on a trade course (COURSES) to learn a
-- trade or raise one a level. It's one more kind of 054 training booking
-- (see "Trade courses" below), only while ADS is taking our staff.

TheContractorWorkshop = {}

-- In display order. The office roles (receptionist, storekeeper) are 090's.
TheContractorWorkshop.ROLES = { "mechanic", "diagnostician", "bodyworker" }
TheContractorWorkshop.IS_ROLE = {}
for _, role in ipairs(TheContractorWorkshop.ROLES) do
    TheContractorWorkshop.IS_ROLE[role] = true
end
-- These are ADS's role ids, which its API and our saves use. ADS shows the
-- diagnostician as "electrician" (and the receptionist, 090's
-- administrator, as "advisor"), so our texts do too, and the console takes
-- either name.
TheContractorWorkshop.ROLE_ALIASES = { electrician = "diagnostician" }

-- The trade a console argument names ("electrician" or "diagnostician"),
-- or nil.
function TheContractorWorkshop.findRole(name)
    name = name ~= nil and string.lower(name) or nil
    name = TheContractorWorkshop.ROLE_ALIASES[name] or name
    return TheContractorWorkshop.IS_ROLE[name] and name or nil
end

TheContractorWorkshop.MAX_LEVEL = 3
TheContractorWorkshop.MAX_SKILLS = 2

-- A candidate's roll: ONE_SKILL_CHANCE of at least one skill, and of those
-- SECOND_SKILL_CHANCE of a second (so about 25% have one or more and 7% two).
-- Each skill's level from LEVEL_WEIGHTS (levels 1-3).
TheContractorWorkshop.ONE_SKILL_CHANCE = 0.25
TheContractorWorkshop.SECOND_SKILL_CHANCE = 0.28
TheContractorWorkshop.LEVEL_WEIGHTS = { 0.6, 0.3, 0.1 }

-- Market value on top of their other stats (full month, 1x UK): their best
-- skill's level, plus SECOND_SKILL_SHARE of the other's.
TheContractorWorkshop.SALARY_PER_LEVEL = { 150, 350, 600 }
TheContractorWorkshop.SECOND_SKILL_SHARE = 0.5

-- 092: trade courses, indexed by the level they lead to (1 learns the
-- trade). Costs are 1x UK (through scaleCost, less 053's association
-- discount); days are course days in a row.
TheContractorWorkshop.COURSES = {
    mechanic = { costs = { 300, 600, 1000 }, days = { 2, 2, 3 } },
    diagnostician = { costs = { 400, 800, 1300 }, days = { 2, 2, 3 } },
    bodyworker = { costs = { 300, 600, 1000 }, days = { 2, 2, 3 } },
}
-- A trade course's key in worker.trainingCert, next to 054's certificates.
TheContractorWorkshop.COURSE_PREFIX = "workshop_"

-- ADS's staff statuses (ADS_OwnWorkshop.STAFF_STATUSES).
TheContractorWorkshop.ADS_STATUS = {
    AVAILABLE = "available",
    WORKING = "working",
    SICK = "sick",
    HOLIDAY = "holiday",
    TRAINING = "training",
    UNAVAILABLE = "unavailable",
}

-- Why a tick can't be set (getRoleProblem).
TheContractorWorkshop.PROBLEM = {
    NO_WORKER = "noWorker",
    NEEDS_ADS = "needsADS",
    UNKNOWN_ROLE = "unknownRole",
    NO_SKILL = "noSkill",
    -- 092's course problems.
    MAX_LEVEL = "maxLevel",
    TOO_MANY_SKILLS = "tooManySkills",
    BOOKED = "booked",
    LEAVING = "leaving",
}

-- Skills -------------------------------------------------------------------------

local function rollLevel()
    local roll = math.random()
    for level, weight in ipairs(TheContractorWorkshop.LEVEL_WEIGHTS) do
        if roll < weight then
            return level
        end
        roll = roll - weight
    end
    return #TheContractorWorkshop.LEVEL_WEIGHTS
end

-- A new candidate's skills: {} for most.
function TheContractorWorkshop.rollSkills()
    local skills = {}
    if math.random() >= TheContractorWorkshop.ONE_SKILL_CHANCE then
        return skills
    end
    local count = math.random() < TheContractorWorkshop.SECOND_SKILL_CHANCE and 2 or 1
    local remaining = {}
    for _, role in ipairs(TheContractorWorkshop.ROLES) do
        table.insert(remaining, role)
    end
    for _ = 1, math.min(count, TheContractorWorkshop.MAX_SKILLS) do
        local role = table.remove(remaining, math.random(#remaining))
        skills[role] = rollLevel()
    end
    return skills
end

-- Their level in a role, 0 without it.
function TheContractorWorkshop.getLevel(worker, role)
    return (worker.adsSkills or {})[role] or 0
end

function TheContractorWorkshop.hasSkills(worker)
    return next(worker.adsSkills or {}) ~= nil
end

-- Their skills in ROLES order: { { role, level }, ... }.
function TheContractorWorkshop.getSkillList(worker)
    local list = {}
    for _, role in ipairs(TheContractorWorkshop.ROLES) do
        local level = TheContractorWorkshop.getLevel(worker, role)
        if level > 0 then
            table.insert(list, { role = role, level = level })
        end
    end
    return list
end

function TheContractorWorkshop.getRoleName(role)
    return g_i18n:getText("tc_office_adsRole_" .. role)
end

-- The market value the skills add (full month, unscaled).
function TheContractorWorkshop.getSalaryPremium(adsSkills)
    local levels = {}
    for _, level in pairs(adsSkills or {}) do
        table.insert(levels, level)
    end
    table.sort(levels, function(a, b)
        return a > b
    end)
    local premium = 0
    for i, level in ipairs(levels) do
        local amount = TheContractorWorkshop.SALARY_PER_LEVEL[math.max(1, math.min(level, #TheContractorWorkshop.SALARY_PER_LEVEL))]
        premium = premium + (i == 1 and amount or amount * TheContractorWorkshop.SECOND_SKILL_SHARE)
    end
    return premium
end

-- The tick ------------------------------------------------------------------------

-- ADS's status for a ticked worker: only an idle one is there.
function TheContractorWorkshop.getADSStatus(worker)
    local STATUS = TheContractorWorker.STATUS
    local ADS = TheContractorWorkshop.ADS_STATUS
    if worker.status == STATUS.IDLE then
        -- 097: unless they've gone home.
        return TheContractorWorkingHours.isOnSite(worker) and ADS.AVAILABLE or ADS.UNAVAILABLE
    elseif worker.status == STATUS.ASSIGNED or worker.status == STATUS.DRIVING or worker.status == STATUS.COOLDOWN then
        return ADS.WORKING
    elseif worker.status == STATUS.SICK then
        return ADS.SICK
    elseif worker.status == STATUS.HOLIDAY then
        return ADS.HOLIDAY
    elseif worker.status == STATUS.TRAINING then
        return ADS.TRAINING
    end
    return ADS.UNAVAILABLE
end

-- The farm's worker ticked into `role`, or nil.
function TheContractorWorkshop.getRoleHolder(farmId, role)
    for _, worker in ipairs(g_currentMission.TheContractor.Staff:getRoster(farmId)) do
        if worker.workshopRole == role then
            return worker
        end
    end
    return nil
end

-- Why `worker` can't be ticked into `role` (nil role = unticked), or nil.
-- Same on every machine. Unticking is always allowed.
function TheContractorWorkshop.getRoleProblem(worker, role)
    if worker == nil then
        return TheContractorWorkshop.PROBLEM.NO_WORKER
    end
    if role == nil then
        return nil
    end
    if not TheContractorWorkshop.IS_ROLE[role] then
        return TheContractorWorkshop.PROBLEM.UNKNOWN_ROLE
    end
    if not TCADSWorkshop.isActive() then
        return TheContractorWorkshop.PROBLEM.NEEDS_ADS
    end
    if TheContractorWorkshop.getLevel(worker, role) <= 0 then
        return TheContractorWorkshop.PROBLEM.NO_SKILL
    end
    return nil
end

-- Server: ticks `worker` into `role` (nil unticks), moving anyone else in
-- that role out. Returns nil once done, or the problem.
function TheContractorWorkshop.setRole(farmId, workerId, role)
    local staff = g_currentMission.TheContractor.Staff
    local worker = staff:getWorker(farmId, workerId)
    local problem = TheContractorWorkshop.getRoleProblem(worker, role)
    if problem ~= nil then
        Logging.info("TheContractor: farm %d can't put worker %d in the workshop as %s: %s", farmId, workerId,
            tostring(role), problem)
        return problem
    end

    if role ~= nil then
        local holder = TheContractorWorkshop.getRoleHolder(farmId, role)
        if holder ~= nil and holder.id ~= worker.id then
            TheContractorWorkshop.commit(holder, holder.adsSkills, nil)
        end
    end
    TheContractorWorkshop.commit(worker, worker.adsSkills, role)
    Logging.info("TheContractor: farm %d worker %d (%s) workshop role: %s", farmId, worker.id, worker.name,
        tostring(role))
    return nil
end

-- Server: sets a worker's skills (the console's way in). A ticked role
-- they no longer have is unticked.
function TheContractorWorkshop.setSkills(worker, adsSkills)
    local role = worker.workshopRole
    if role ~= nil and (adsSkills[role] or 0) <= 0 then
        role = nil
    end
    TheContractorWorkshop.commit(worker, adsSkills, role)
end

-- Server: applies, broadcasts and tells ADS.
function TheContractorWorkshop.commit(worker, adsSkills, workshopRole)
    TheContractorWorkshop.apply(worker, adsSkills, workshopRole)
    if g_server ~= nil and worker.farmId ~= nil then
        g_server:broadcastEvent(TCWorkerWorkshopEvent.new(worker.farmId, worker.id, adsSkills, workshopRole))
    end
    if worker.farmId ~= nil then
        TCADSWorkshop.refresh(worker.farmId)
    end
end

-- Every machine.
function TheContractorWorkshop.apply(worker, adsSkills, workshopRole)
    worker.adsSkills = adsSkills or {}
    worker.workshopRole = workshopRole

    local menu = g_currentMission.TheContractor.MenuContractor
    if menu ~= nil and menu.onOfficeChanged ~= nil then
        menu:onOfficeChanged()
    end
end

-- Trade courses (092) ---------------------------------------------------------------
-- Booked by the player from Manage worker, one level at a time: 0 -> 1
-- learns a trade (up to MAX_SKILLS), then 1 -> 2 and 2 -> 3. A course is a
-- 054 booking (TheContractorTraining) with no assessment, so it's
-- scheduled, saved and streamed like the spraying course; the level comes
-- when its last day is done (completeCourse).

function TheContractorWorkshop.getCourseKey(role)
    return TheContractorWorkshop.COURSE_PREFIX .. role
end

-- The trade a course key is for, or nil if it isn't a trade course.
function TheContractorWorkshop.getCourseRole(key)
    local prefix = TheContractorWorkshop.COURSE_PREFIX
    if type(key) ~= "string" or string.sub(key, 1, #prefix) ~= prefix then
        return nil
    end
    local role = string.sub(key, #prefix + 1)
    return TheContractorWorkshop.IS_ROLE[role] and role or nil
end

local function countSkills(worker)
    local count = 0
    for _, level in pairs(worker.adsSkills or {}) do
        if level > 0 then
            count = count + 1
        end
    end
    return count
end

-- The level a course in `role` would take them to.
function TheContractorWorkshop.getCourseLevel(worker, role)
    return TheContractorWorkshop.getLevel(worker, role) + 1
end

-- Why `role` can't go up a level for `worker`: already at the top, or a
-- third trade. nil if it can.
function TheContractorWorkshop.getLevelProblem(worker, role)
    local level = TheContractorWorkshop.getLevel(worker, role)
    if level >= TheContractorWorkshop.MAX_LEVEL then
        return TheContractorWorkshop.PROBLEM.MAX_LEVEL
    end
    if level == 0 and countSkills(worker) >= TheContractorWorkshop.MAX_SKILLS then
        return TheContractorWorkshop.PROBLEM.TOO_MANY_SKILLS
    end
    return nil
end

-- Why `worker` can't be booked on a course in `role` now (money aside), or
-- nil. Same on every machine.
function TheContractorWorkshop.getCourseProblem(worker, role)
    local PROBLEM = TheContractorWorkshop.PROBLEM
    if worker == nil then
        return PROBLEM.NO_WORKER
    end
    if not TheContractorWorkshop.IS_ROLE[role] then
        return PROBLEM.UNKNOWN_ROLE
    end
    if not TCADSWorkshop.isActive() then
        return PROBLEM.NEEDS_ADS
    end
    local levelProblem = TheContractorWorkshop.getLevelProblem(worker, role)
    if levelProblem ~= nil then
        return levelProblem
    end
    if worker:hasTrainingBooked() then
        return PROBLEM.BOOKED
    end
    if worker:isLeaving() then
        return PROBLEM.LEAVING
    end
    return nil
end

-- What the course costs the farm: scaled, less the association discount.
function TheContractorWorkshop.getCoursePrice(farmId, worker, role)
    local tc = g_currentMission.TheContractor
    local cost = TheContractorWorkshop.COURSES[role].costs[TheContractorWorkshop.getCourseLevel(worker, role)]
    return tc.Settings:scaleCost(cost) * (1 - tc.Association:getCertificationDiscount(farmId))
end

function TheContractorWorkshop.getCourseDays(worker, role)
    return TheContractorTraining.scaleDays(
        TheContractorWorkshop.COURSES[role].days[TheContractorWorkshop.getCourseLevel(worker, role)])
end

-- The courses they could be booked on now, in ROLES order: { { role, level }, ... }.
function TheContractorWorkshop.getCourseOptions(worker)
    local options = {}
    for _, role in ipairs(TheContractorWorkshop.ROLES) do
        if TheContractorWorkshop.getCourseProblem(worker, role) == nil then
            table.insert(options, { role = role, level = TheContractorWorkshop.getCourseLevel(worker, role) })
        end
    end
    return options
end

-- "level 2 mechanic": what the course is called in text.
function TheContractorWorkshop.getCourseName(worker, role)
    return string.format(g_i18n:getText("tc_workshop_courseName"), TheContractorWorkshop.getCourseLevel(worker, role),
        string.lower(TheContractorWorkshop.getRoleName(role)))
end

-- Server (Training's last course day): the trade goes up a level. Returns
-- the new level, or nil if it can't any more (the console changed their
-- skills meanwhile).
function TheContractorWorkshop.completeCourse(worker, role)
    if TheContractorWorkshop.getLevelProblem(worker, role) ~= nil then
        return nil
    end
    local level = TheContractorWorkshop.getLevel(worker, role)

    local skills = {}
    for skillRole, skillLevel in pairs(worker.adsSkills or {}) do
        skills[skillRole] = skillLevel
    end
    skills[role] = level + 1
    TheContractorWorkshop.setSkills(worker, skills)
    return level + 1
end

-- Wire serialization and persistence ----------------------------------------------
-- Part of the worker's own (TheContractorStaff.writeWorker/writeWorkerXML).

function TheContractorWorkshop.writeSkills(streamId, adsSkills)
    for _, role in ipairs(TheContractorWorkshop.ROLES) do
        streamWriteUInt8(streamId, (adsSkills or {})[role] or 0)
    end
end

function TheContractorWorkshop.readSkills(streamId)
    local adsSkills = {}
    for _, role in ipairs(TheContractorWorkshop.ROLES) do
        local level = streamReadUInt8(streamId)
        if level > 0 then
            adsSkills[role] = level
        end
    end
    return adsSkills
end

function TheContractorWorkshop.writeState(streamId, worker)
    TheContractorWorkshop.writeSkills(streamId, worker.adsSkills)
    streamWriteString(streamId, worker.workshopRole or "")
end

function TheContractorWorkshop.readState(streamId)
    local adsSkills = TheContractorWorkshop.readSkills(streamId)
    local role = streamReadString(streamId)
    return adsSkills, role ~= "" and role or nil
end

function TheContractorWorkshop.writeXML(xmlFile, key, worker)
    for role, level in pairs(worker.adsSkills or {}) do
        setXMLInt(xmlFile, key .. "#ads_" .. role, level)
    end
    if worker.workshopRole ~= nil then
        setXMLString(xmlFile, key .. "#workshopRole", worker.workshopRole)
    end
end

-- The saved skills (clamped to 1-3, unknown roles dropped). A save from
-- before 091 has none: they aren't rolled for existing workers.
function TheContractorWorkshop.readSkillsXML(xmlFile, key)
    local adsSkills = {}
    for _, role in ipairs(TheContractorWorkshop.ROLES) do
        local level = getXMLInt(xmlFile, key .. "#ads_" .. role)
        if level ~= nil and level > 0 then
            adsSkills[role] = math.min(level, TheContractorWorkshop.MAX_LEVEL)
        end
    end
    return adsSkills
end

-- The saved role, if they still have the skill for it.
function TheContractorWorkshop.readRoleXML(xmlFile, key, adsSkills)
    local role = getXMLString(xmlFile, key .. "#workshopRole")
    if role ~= nil and (adsSkills[role] or 0) > 0 then
        return role
    end
    return nil
end

-- Console ---------------------------------------------------------------------------

function TheContractorWorkshop.registerConsoleCommands()
    TCConsole.register("worker", "adsSkill", {
        args = "<worker> <mechanic|electrician|bodyworker> <0-3>",
        description = "Set a hired worker's ADS workshop skill (0 removes it)",
        run = function(farmId, args)
            local level = tonumber(args[#args])
            local role = TheContractorWorkshop.findRole(args[#args - 1])
            if #args < 3 or level == nil or level ~= math.floor(level) or level < 0 or
                    level > TheContractorWorkshop.MAX_LEVEL or role == nil then
                return false
            end
            local worker, problem = TCConsole.findWorker(farmId, table.concat(args, " ", 1, #args - 2))
            if worker == nil then
                return problem
            end

            local skills = {}
            for skillRole, skillLevel in pairs(worker.adsSkills or {}) do
                skills[skillRole] = skillLevel
            end
            skills[role] = level > 0 and level or nil
            local count = 0
            for _ in pairs(skills) do
                count = count + 1
            end
            if count > TheContractorWorkshop.MAX_SKILLS then
                return string.format("%s already has %d workshop skills: set one to 0 first", worker.name,
                    TheContractorWorkshop.MAX_SKILLS)
            end

            TheContractorWorkshop.setSkills(worker, skills)
            return string.format("%s: %s", worker.name, TheContractorWorkshop.describeSkills(worker))
        end,
    })
end

-- "mechanic 2, electrician 1 (in the workshop as mechanic)", or "none".
-- Trades by the names ADS shows.
function TheContractorWorkshop.describeSkills(worker)
    local function name(role)
        return string.lower(TheContractorWorkshop.getRoleName(role))
    end
    local parts = {}
    for _, entry in ipairs(TheContractorWorkshop.getSkillList(worker)) do
        table.insert(parts, string.format("%s %d", name(entry.role), entry.level))
    end
    local text = #parts > 0 and table.concat(parts, ", ") or "none"
    if worker.workshopRole ~= nil then
        text = text .. " (in the workshop as " .. name(worker.workshopRole) .. ")"
    end
    return text
end
