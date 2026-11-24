-- A worker entered in the ploughing match (170): the pure half of
-- TheContractorShowWorker. Plain numbers and tables only, so it's tested
-- outside the game (tests/test_showWorker.lua).
--
--   Entering (getEntryProblem): a company farm's worker, while the show's
--     entries are open, one a farm (the farm's one plot, 169). They must be
--     free on the show's day (not off sick now, not on holiday or training
--     that day, not leaving), with at least MIN_TILLAGE in tillage (044) and
--     experience of the kit's tractor size (KIT_TIER: 169 lends a mid-size
--     one).
--   The score (rollScore): from the worker's tillage skill and tractor
--     experience, scaled by their morale (TheContractorMorale's job quality
--     factor, passed in), give or take FORM for the day. Never from the
--     ground: the plot's painted, as the farmers' are. The time it takes
--     (rollMinutes) is shorter the better they are, always inside 168's
--     limit.
--   Afterwards (getMoraleBoost): a placing lifts morale, a win most. A poor
--     run costs nothing.

TCShowWorker = {}

-- The kit's tractor size (169 picks a mid-size tractor first) and the least
-- tillage a worker needs to be entered.
TCShowWorker.KIT_TIER = "medium"
TCShowWorker.MIN_TILLAGE = 4

-- The score: BASE + SPAN x (TILLAGE_SHARE of the tillage skill and the rest
-- of the tractor experience, each 0 at 1 and 1 at 10), times the morale
-- factor, give or take FORM, between MIN and MAX. An average worker (5 and 5)
-- scores about the farmers' 80 (TCPloughMatch.FARMER_SCORE); a top one, in
-- good spirits, about a careful player's 100.
TCShowWorker.SCORE = { base = 66, span = 30, tillageShare = 0.6, form = 5, min = 40, max = 98 }
-- Game minutes: MINUTES[2] for the least able, MINUTES[1] for the best,
-- give or take MINUTES_JITTER, never over the limit.
TCShowWorker.MINUTES = { 145, 175 }
TCShowWorker.MINUTES_JITTER = 4

-- Morale (056) by placing: 1st, 2nd, 3rd.
TCShowWorker.MORALE_BOOST = { 8, 5, 3 }

-- Why a worker can't be entered (l10n keys).
TCShowWorker.PROBLEM = {
    noShow = "tc_showWorker_problemNoShow",
    closed = "tc_showWorker_problemClosed",
    noCompany = "tc_showWorker_problemNoCompany",
    noWorker = "tc_showWorker_problemNoWorker",
    entered = "tc_showWorker_problemEntered",
    sick = "tc_showWorker_problemSick",
    away = "tc_showWorker_problemAway",
    leaving = "tc_showWorker_problemLeaving",
    skill = "tc_showWorker_problemSkill",
    tractor = "tc_showWorker_problemTractor",
    notEntered = "tc_showWorker_problemNotEntered",
}
local PROBLEM = TCShowWorker.PROBLEM

-- Why an entry's withdrawn on its own (l10n keys, the inbox message's
-- reason).
TCShowWorker.WITHDRAW = {
    sick = "tc_showWorker_reasonSick",
    away = "tc_showWorker_reasonAway",
    gone = "tc_showWorker_reasonGone",
    noPlot = "tc_showWorker_reasonNoPlot",
    late = "tc_showWorker_reasonLate",
}

-- 0 at 1, 1 at 10 (044's ratings).
local function share(rating)
    return math.max(0, math.min(1, ((rating or 1) - 1) / 9))
end

-- Entering ---------------------------------------------------------------------------------

-- Why a worker can't be entered, or nil (pure). check: {
--   hasShow, isOpen, hasCompany, hasEntry (the farm's entered one already),
--   worker (nil if they're not on the farm's roster), isSick (now),
--   isAway (on holiday or training on the show's day), isLeaving
-- }.
function TCShowWorker.getEntryProblem(check)
    if not check.hasShow then
        return PROBLEM.noShow
    end
    if not check.isOpen then
        return PROBLEM.closed
    end
    if not check.hasCompany then
        return PROBLEM.noCompany
    end
    if check.hasEntry then
        return PROBLEM.entered
    end
    local worker = check.worker
    if worker == nil then
        return PROBLEM.noWorker
    end
    if check.isLeaving then
        return PROBLEM.leaving
    end
    if check.isSick then
        return PROBLEM.sick
    end
    if check.isAway then
        return PROBLEM.away
    end
    if (worker.skills ~= nil and worker.skills.tillage or 0) < TCShowWorker.MIN_TILLAGE then
        return PROBLEM.skill
    end
    if worker.tierCapability == nil or worker.tierCapability[TCShowWorker.KIT_TIER] == nil then
        return PROBLEM.tractor
    end
    return nil
end

-- Whether a sick worker's still off on a day (pure): today counts as one
-- of their days (Staff:updateSickness counts one off each morning), and a
-- worker due off once back from a job (pendingDays) starts today at the
-- soonest.
function TCShowWorker.isSickOn(today, day, sickDays, pendingDays)
    local days = math.max(sickDays or 0, pendingDays or 0)
    return days > 0 and today + days > day
end

-- The score ---------------------------------------------------------------------------------

-- How able they are, 0 to 1 (pure): tillage and tractor experience.
function TCShowWorker.getAbility(tillage, tractor)
    local r = TCShowWorker.SCORE
    return r.tillageShare * share(tillage) + (1 - r.tillageShare) * share(tractor)
end

-- A total out of 100 (pure). moraleFactor: TheContractorMorale.
-- getQualityMultiplierFor their morale (1 in good spirits).
function TCShowWorker.rollScore(tillage, tractor, moraleFactor, random)
    local r = TCShowWorker.SCORE
    local score = (r.base + r.span * TCShowWorker.getAbility(tillage, tractor)) * (moraleFactor or 1) +
        (random() * 2 - 1) * r.form
    return math.max(r.min, math.min(r.max, score))
end

-- Game minutes their ploughing takes (pure), inside the limit.
function TCShowWorker.rollMinutes(tillage, tractor, random)
    local range = TCShowWorker.MINUTES
    local minutes = range[2] - (range[2] - range[1]) * TCShowWorker.getAbility(tillage, tractor) +
        (random() * 2 - 1) * TCShowWorker.MINUTES_JITTER
    return math.floor(math.max(range[1], math.min(range[2], minutes)) + 0.5)
end

-- Afterwards ---------------------------------------------------------------------------------

-- Morale for a placing (pure): 0 for none.
function TCShowWorker.getMoraleBoost(placing)
    return placing ~= nil and TCShowWorker.MORALE_BOOST[placing] or 0
end
