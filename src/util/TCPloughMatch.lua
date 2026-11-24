-- The ploughing match (169): the pure half of TheContractorPloughingMatch.
-- Everything here works on plain numbers and tables, so it's tested outside
-- the game (tests/test_ploughingMatch.lua).
--
--   The plots: 164's, on the show's synced scene (TCShowScene.getPlotFrames).
--     At midnight before the day, each company farm can have one (planPlots:
--     the first plots are open to companies, as many as there are company
--     farms), and farmers fill the rest.
--   Taking a plot (getTakeProblem): a player of a company farm, at a free
--     plot's start peg, from when the site's set out until the match ends.
--     One plot a farm. The kit's theirs to drive from 11:00.
--   The lent kit's lock (getKitLock), on every machine for its own player:
--     nobody before 11:00; then only the plot's farm, until its run's
--     finished (the driver says so at the start peg, or 15:00).
--   The time: ploughing is limited to 168's 3 game hours
--     (TCPloughScore.RULES.timeLimitMinutes), counted from each ploughman's
--     first run (the first time their plough's down in the plot), and
--     everyone stops at 15:00. So the window's 4 hours: anyone ploughing by
--     12:00 has their full time, and arriving later costs time (the
--     user's question in 168's Outcome, settled here).
--   Farmers: a hidden ploughing skill each (rollSkill, kept), a total rolled
--     from it (rollFarmerScore) and a breakdown made to add up to it
--     (makeBreakdown), so a farmer's scorecard reads like a player's.
--   Placings (rankPlots): by score, the top three placed.
--   170: a farm's plot can be its entered worker's (plot.workerId): the
--     worker ploughs it (painted, as a farmer's), so its kit's locked to
--     everyone and nobody can finish its run at the start peg.
--   The kit (pickPlough, pickTractor): one model for every plot: a
--     reversible plough near PLOUGH_WIDTH wide (168's 3-4 furrow), and the
--     smallest mid-size tractor with the power for it.

TCPloughMatch = {}

TCPloughMatch.START_HOUR = 11
TCPloughMatch.END_HOUR = 15

-- A plot's state.
TCPloughMatch.STATE = {
    OPEN = "open",          -- a company's to take
    TAKEN = "taken",        -- a farm's (ploughing from 11:00)
    FINISHED = "finished",  -- its run's over (the driver's said, or 15:00)
    FARMER = "farmer",      -- a farmer's
}
local STATE = TCPloughMatch.STATE

-- Why the kit's locked (l10n keys, shown as vanilla's warning).
TCPloughMatch.LOCK = {
    NOT_STARTED = "tc_ploughMatch_lockNotStarted",
    FREE = "tc_ploughMatch_lockFree",
    NOT_YOURS = "tc_ploughMatch_lockNotYours",
    FINISHED = "tc_ploughMatch_lockFinished",
    -- 170.
    WORKER = "tc_ploughMatch_lockWorker",
}
local LOCK = TCPloughMatch.LOCK

-- Why a plot can't be taken or finished (l10n keys).
TCPloughMatch.PROBLEM = {
    noMatch = "tc_ploughMatch_problemNoMatch",
    noCompany = "tc_ploughMatch_problemNoCompany",
    closed = "tc_ploughMatch_problemClosed",
    taken = "tc_ploughMatch_problemTaken",
    hasPlot = "tc_ploughMatch_problemHasPlot",
    notYours = "tc_ploughMatch_problemNotYours",
    notStarted = "tc_ploughMatch_problemNotStarted",
    finished = "tc_ploughMatch_problemFinished",
    -- 170.
    worker = "tc_ploughMatch_problemWorker",
}
local PROBLEM = TCPloughMatch.PROBLEM

-- Farmers' ploughing: a skill from -1 to 1 (rolled once a farmer), a total
-- of BASE + skill * SPREAD, give or take NOISE, between the limits. A
-- careful player scores near 100 (168's tests), a sloppy one about 85.
TCPloughMatch.FARMER_SCORE = { base = 80, spread = 12, noise = 5, min = 45, max = 97 }
-- Game minutes a farmer's ploughing takes (inside the limit, always).
TCPloughMatch.FARMER_MINUTES = { 140, 175 }
-- How far a farmer's part scores stray from their total's share.
TCPloughMatch.BREAKDOWN_JITTER = 0.12

-- Prize money (unscaled pounds), reputation (jobs' worth) and the host's
-- opinion, by placing: small prizes, a good name.
TCPloughMatch.PRIZES = { 40, 25, 15 }
TCPloughMatch.REPUTATION = { 4, 3, 2 }
TCPloughMatch.OPINION = { 3, 2, 1 }
TCPloughMatch.PLACINGS = 3

-- The kit: a reversible plough as near this wide (metres) as there is,
-- between the limits; a mid-size tractor with at least MIN_POWER hp.
TCPloughMatch.PLOUGH_WIDTH = 1.4
TCPloughMatch.PLOUGH_WIDTH_RANGE = { 1.0, 1.8 }
TCPloughMatch.MIN_POWER = 90

-- Metres, in a plot's own frame (u in from its near edge, v to its right):
-- the kit's tractor stands inside the plot, facing in, far enough in for
-- its plough to clear the near edge; a farmer stands by it.
TCPloughMatch.KIT_U = 12
TCPloughMatch.FARMER_SPOT = { u = 12, v = 2.5 }

-- Plots -------------------------------------------------------------------------------------

-- What each plot is at the start (pure): the first `companies` are open,
-- the rest farmers'. Returns a list of STATEs.
function TCPloughMatch.planPlots(plotCount, companies)
    local states = {}
    for i = 1, plotCount do
        states[i] = i <= companies and STATE.OPEN or STATE.FARMER
    end
    return states
end

-- n of a list at random, in a random order (a copy).
function TCPloughMatch.pickSome(list, n, random)
    local pool = {}
    for i, item in ipairs(list) do
        pool[i] = item
    end
    local picked = {}
    while #picked < n and #pool > 0 do
        local index = math.min(#pool, 1 + math.floor(random() * #pool))
        table.insert(picked, table.remove(pool, index))
    end
    return picked
end

-- The plot a farm holds, or nil.
function TCPloughMatch.getFarmPlot(plots, farmId)
    for _, plot in ipairs(plots) do
        if farmId ~= nil and farmId > 0 and plot.farmId == farmId and
                (plot.state == STATE.TAKEN or plot.state == STATE.FINISHED) then
            return plot
        end
    end
    return nil
end

-- Why a farm can't take a plot, or nil (pure). match: { plots, setOut
-- (the plots are out), over (the match is) }.
function TCPloughMatch.getTakeProblem(match, number, farmId, hasCompany)
    if match == nil or not match.setOut then
        return PROBLEM.noMatch
    end
    if match.over then
        return PROBLEM.closed
    end
    if not hasCompany then
        return PROBLEM.noCompany
    end
    if TCPloughMatch.getFarmPlot(match.plots, farmId) ~= nil then
        return PROBLEM.hasPlot
    end
    local plot = match.plots[number]
    if plot == nil or plot.state ~= STATE.OPEN then
        return PROBLEM.taken
    end
    return nil
end

-- Why a farm can't say its run's finished, or nil (pure).
function TCPloughMatch.getFinishProblem(match, number, farmId)
    local plot = match ~= nil and match.plots[number] or nil
    if plot == nil or plot.farmId ~= farmId or (plot.state ~= STATE.TAKEN and plot.state ~= STATE.FINISHED) then
        return PROBLEM.notYours
    end
    if (plot.workerId or 0) > 0 then
        return PROBLEM.worker
    end
    if plot.state == STATE.FINISHED or match.over then
        return PROBLEM.finished
    end
    if not match.started then
        return PROBLEM.notStarted
    end
    return nil
end

-- Why a plot's kit is locked for a farm's player, or nil (pure). match: {
-- started, over }.
function TCPloughMatch.getKitLock(match, plot, farmId)
    if not match.started then
        return LOCK.NOT_STARTED
    end
    if match.over or plot.state == STATE.FINISHED then
        return LOCK.FINISHED
    end
    if plot.state == STATE.OPEN then
        return LOCK.FREE
    end
    if (plot.workerId or 0) > 0 then
        return LOCK.WORKER
    end
    if plot.state ~= STATE.TAKEN or farmId == nil or plot.farmId ~= farmId then
        return LOCK.NOT_YOURS
    end
    return nil
end

-- Time ---------------------------------------------------------------------------------------

-- A game time as minutes since day 0 (monotonic day, minutes into it).
function TCPloughMatch.toGameMinute(day, dayMinutes)
    return day * 1440 + dayMinutes
end

-- The game minutes a run counts (pure): from its first run to the last
-- time the plough was down in the plot. nil before it's started.
function TCPloughMatch.getMinutesUsed(firstMinute, lastMinute)
    if firstMinute == nil then
        return nil
    end
    return math.max(0, (lastMinute or firstMinute) - firstMinute)
end

-- Farmers -------------------------------------------------------------------------------------

function TCPloughMatch.rollSkill(random)
    return random() * 2 - 1
end

function TCPloughMatch.rollFarmerScore(skill, random)
    local r = TCPloughMatch.FARMER_SCORE
    local score = r.base + (skill or 0) * r.spread + (random() * 2 - 1) * r.noise
    return math.max(r.min, math.min(r.max, score))
end

function TCPloughMatch.rollFarmerMinutes(random)
    local range = TCPloughMatch.FARMER_MINUTES
    return math.floor(range[1] + random() * (range[2] - range[1]) + 0.5)
end

-- A scorecard that adds up to a total (pure): each part's share near the
-- total's, give or take BREAKDOWN_JITTER, scaled so the marks come to it.
-- weights: TCPloughScore.RULES.weights; parts: the part names in order.
-- Returns { total, minutes, parts = { [name] = { marks, max } } }.
function TCPloughMatch.makeBreakdown(total, minutes, random, weights, parts)
    local share = math.max(0, math.min(1, total / 100))
    local maxSum, markSum = 0, 0
    local fractions = {}
    for _, name in ipairs(parts) do
        local fraction = share + (random() * 2 - 1) * TCPloughMatch.BREAKDOWN_JITTER
        fractions[name] = math.max(0, math.min(1, fraction))
        maxSum = maxSum + weights[name]
        markSum = markSum + fractions[name] * weights[name]
    end
    local wanted = share * maxSum
    local scale = markSum > 0 and wanted / markSum or 0
    local card = { minutes = minutes, parts = {} }
    local sum = 0
    for _, name in ipairs(parts) do
        local marks = math.min(weights[name], fractions[name] * weights[name] * scale)
        card.parts[name] = { marks = marks, max = weights[name] }
        sum = sum + marks
    end
    card.total = maxSum > 0 and sum / maxSum * 100 or 0
    return card
end

-- Placings -------------------------------------------------------------------------------------

-- Ranks the scored plots (pure): competitors { score, number } (a plot's),
-- highest first, ties by plot number. Returns the list in order, each
-- with its placing (1 to PLACINGS; nil for the rest, and for a run that
-- scored nothing).
function TCPloughMatch.rankPlots(competitors)
    local ranked = {}
    for i, competitor in ipairs(competitors) do
        ranked[i] = competitor
    end
    table.sort(ranked, function(a, b)
        if math.abs(a.score - b.score) > 0.0001 then
            return a.score > b.score
        end
        return (a.number or 0) < (b.number or 0)
    end)
    for i, competitor in ipairs(ranked) do
        competitor.placing = i <= TCPloughMatch.PLACINGS and competitor.score > 0 and i or nil
    end
    return ranked
end

-- A farm's best results (pure): best[farmId] = { bestScore, wins, matches },
-- with this match's score and placing added.
function TCPloughMatch.addBest(best, farmId, score, placing)
    local entry = best[farmId] or { bestScore = 0, wins = 0, matches = 0 }
    entry.bestScore = math.max(entry.bestScore, score)
    entry.matches = entry.matches + 1
    if placing == 1 then
        entry.wins = entry.wins + 1
    end
    best[farmId] = entry
    return entry
end

-- The kit ----------------------------------------------------------------------------------------

-- The plough (pure): from candidates { xmlFilename, width, reversible,
-- mounted, price, name }, a mounted one in the width range, reversible
-- first, nearest PLOUGH_WIDTH, then cheapest, then by name. With none in the
-- range, the nearest mounted one; with none mounted, the nearest of any.
-- nil for none at all.
function TCPloughMatch.pickPlough(candidates)
    local picked = TCPloughMatch.pickPloughFrom(candidates, true, true)
    if picked == nil then
        picked = TCPloughMatch.pickPloughFrom(candidates, true, false)
    end
    if picked == nil then
        picked = TCPloughMatch.pickPloughFrom(candidates, false, false)
    end
    return picked
end

function TCPloughMatch.pickPloughFrom(candidates, mountedOnly, inRange)
    local range = TCPloughMatch.PLOUGH_WIDTH_RANGE
    local best = nil
    local function isBetter(candidate)
        if best == nil then
            return true
        end
        if candidate.reversible ~= best.reversible then
            return candidate.reversible
        end
        local a = math.abs(candidate.width - TCPloughMatch.PLOUGH_WIDTH)
        local b = math.abs(best.width - TCPloughMatch.PLOUGH_WIDTH)
        if math.abs(a - b) > 0.001 then
            return a < b
        end
        if (candidate.price or 0) ~= (best.price or 0) then
            return (candidate.price or 0) < (best.price or 0)
        end
        return (candidate.name or "") < (best.name or "")
    end
    for _, candidate in ipairs(candidates) do
        if (candidate.mounted or not mountedOnly) and candidate.width ~= nil and
                (not inRange or (candidate.width >= range[1] and candidate.width <= range[2])) and
                isBetter(candidate) then
            best = candidate
        end
    end
    return best
end

-- The tractor (pure): from candidates { power, price, name }, the least
-- powerful with at least the plough's need (and MIN_POWER), else the most
-- powerful there is; ties by price, then name. nil for none.
function TCPloughMatch.pickTractor(candidates, neededPower)
    local need = math.max(neededPower or 0, TCPloughMatch.MIN_POWER)
    local best = nil
    local function isBetter(candidate)
        if best == nil then
            return true
        end
        local candidateEnough, bestEnough = candidate.power >= need, best.power >= need
        if candidateEnough ~= bestEnough then
            return candidateEnough
        end
        if candidate.power ~= best.power then
            if candidateEnough then
                return candidate.power < best.power
            end
            return candidate.power > best.power
        end
        if (candidate.price or 0) ~= (best.price or 0) then
            return (candidate.price or 0) < (best.price or 0)
        end
        return (candidate.name or "") < (best.name or "")
    end
    for _, candidate in ipairs(candidates) do
        if candidate.power ~= nil and isBetter(candidate) then
            best = candidate
        end
    end
    return best
end

-- Saved ground -----------------------------------------------------------------------------------

-- A grid's `key` values as text: "index:value" for each cell above zero
-- (most of a stubble plot is none), two decimals.
function TCPloughMatch.packGrid(grid, key)
    local parts = {}
    for i, cell in ipairs(grid.cells) do
        local value = cell[key] or 0
        if value > 0.005 then
            table.insert(parts, string.format("%d:%.2f", i, value))
        end
    end
    return table.concat(parts, " ")
end

-- packGrid's text back onto a grid's cells (every other cell none).
function TCPloughMatch.unpackGrid(grid, key, text)
    for _, cell in ipairs(grid.cells) do
        cell[key] = 0
    end
    for index, value in string.gmatch(text or "", "(%d+):([%d%.]+)") do
        local cell = grid.cells[tonumber(index)]
        if cell ~= nil then
            cell[key] = tonumber(value) or 0
        end
    end
end
