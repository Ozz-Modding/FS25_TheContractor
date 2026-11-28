-- The ploughing match (169): a competition on 165's show day, on 164's
-- plots, scored by 168's rules. The pure half is TCPloughMatch.
--
-- The plots: 164's, kept on the show's synced scene (TCShowScene.
--   getPlotFrames: numbered, each facing across its row away from the
--   showground, marked out with pegs by the show's dressing). At midnight
--   before the day (onSetOut), each company farm can have one and farmers
--   fill the rest (TCPloughMatch.planPlots).
-- The lent kit: one store model of tractor and reversible plough for every
--   plot (TCPloughMatch.pickPlough/pickTractor), spawned at midnight
--   before inside each plot at its near edge, facing in, hitched and
--   fuelled. Owned by nobody (farm 0, MISSION state, as 071's courtesy
--   vehicle: no costs, no wear, never sold). TCVehicleLock keeps everyone
--   out until 11:00, then lets only the plot's farm drive it until its run's
--   finished (getLockedKit). Its plough works only its own plot, and the
--   margin 168 scores ploughing outside it in (the WorkArea patch below).
--   Taken away after the results, wherever it was left.
-- Taking a plot: a company farm's player at a free plot's start peg
--   (TCPloughPlotActivatable, TCPloughPlotEvent), any time from the set-out
--   until the match ends: one a farm. Before 11:00 it's reserved.
-- The match (11:00 to 15:00): at 11:00 each player's plot's ground is read
--   (168's grid), a notice goes to every company, and the server samples
--   each taken plot's kit (168's path) every SAMPLE_MS. The time counts from
--   each ploughman's first run (TCPloughMatch). The driver can say they've
--   finished at the start peg; at 15:00 everyone has. A finished plot is
--   scored then (168's TCPloughScore.score), its kit locked again. A
--   farmer's plot is painted ploughed in strips as the hours go
--   (TCFieldPreparation.paintPloughed), and the farmer stands by the kit;
--   their score's rolled from a hidden skill (server-only, kept), with a
--   breakdown made to fit it.
-- A worker (170, TheContractorShowWorker): a farm that's entered one has
--   its plot reserved for them at the set-out (reserveWorkerPlots). Its kit
--   is locked to everyone. Once the worker's at the show and the match is
--   on, their score's rolled (ShowWorker:rollRun, never the ground) and the
--   plot's painted in strips as a farmer's is, the worker standing by the
--   kit in their own look. A worker withdrawn on the day (sick, gone, not
--   there by 15:00) leaves their plot to a farmer (onWorkerWithdrawn). The
--   farm's prize, reputation and best are as if its player had ploughed.
-- Results (16:00, the show's giveResults): every scored plot ranked, the top
--   three paid and rewarded by the show (prizes, reputation, the host's
--   opinion), each plot's scorecard sent to every machine, each ploughing
--   farm's scorecard to its inbox, and each farm's best kept (best score,
--   wins) for the Show tab.
--
-- Server only, never streamed: the ground, the path, live scores, farmers'
-- skills and their rolled scores until the results. Every machine: the plots
-- (state, who, the kit's ids), whether the match has started and is over,
-- the scorecards once given, and the farms' bests. The plots and cards last
-- until the next show's announced, so the Show tab can show them after the
-- day. Saved in TheContractor.xml (.ploughingMatch), the kit by uniqueId; in
-- the initial client state. Farms (forgetFarm), farmers (replacePerson,
-- through the show). Nothing's a date. Tested in
-- tests/test_ploughingMatch.lua.

TheContractorPloughingMatch = {}
TheContractorPloughingMatch_mt = Class(TheContractorPloughingMatch)

TheContractorPloughingMatch.KEY = "ploughing"
TheContractorPloughingMatch.TITLE_KEY = "tc_ploughMatch_title"
TheContractorPloughingMatch.SAVE_KEY = "ploughingMatch"

-- The path is sampled this often (ms), and kept to this many samples a plot.
TheContractorPloughingMatch.SAMPLE_MS = 200
TheContractorPloughingMatch.MAX_SAMPLES = 30000
-- How often (ms) farmers' plots are painted on.
TheContractorPloughingMatch.PAINT_MS = 2000
-- How long the match's notices last (months; they're dropped at the results).
TheContractorPloughingMatch.NOTICE_MONTHS = 1

local STATE = TCPloughMatch.STATE

function TheContractorPloughingMatch.new()
    local self = setmetatable({}, TheContractorPloughingMatch_mt)
    -- Every machine, as the server sent it: the show the plots are for
    -- (nil for none), the plots in number order ({ number, state, farmId
    -- (0 none), farmerId (0 none), workerId (170: the farm's entered
    -- worker's, 0 none), tractorId, ploughId (the kit's object
    -- ids, nil while it's not out), card (its scorecard, once the results
    -- are given: { total, minutes, placing, coverage, parts = { [name] = {
    -- marks, max } } }) }), whether they're out, the match started and
    -- over, and whether the results are in. best: farmId -> { bestScore,
    -- wins, matches }, kept from match to match.
    self.showId = nil
    self.plots = {}
    self.setOut = false
    self.started = false
    self.over = false
    self.resultsGiven = false
    self.best = {}
    -- Server only: each plot's run, by number (see newRun); farmers'
    -- ploughing skills; the kit's models; the match's start (game minutes);
    -- the kit waiting to load and the one loading; the notices to drop.
    self.runs = {}
    self.skills = {}
    self.kitModels = nil
    self.startMinute = nil
    self.spawnQueue = {}
    self.loading = nil
    self.noticeIds = {}
    self.sinceSampleMs = 0
    self.sincePaintMs = 0
    -- Server: the rolls, and the engine's half (the tests swap both).
    self.random = math.random
    self.engine = TheContractorPloughingMatch.ENGINE
    -- This machine: the plots' map markers and the farmers by their plots.
    self.markers = {}
    self.markersKey = nil
    self.figures = nil
    self.figuresKey = nil
    return self
end

-- Every machine, at load: the match as a show competition. Players needn't
-- enter; a worker's entered through 170's ShowWorker.
function TheContractorPloughingMatch:register(show)
    show:registerCompetition(TheContractorPloughingMatch.KEY, {
        titleKey = TheContractorPloughingMatch.TITLE_KEY,
        takesEntries = false,
        getPlacings = function(event)
            return self:getPlacings(event)
        end,
        onAnnounced = function(event)
            self:reset(event.id)
        end,
        onSetOut = function(event)
            self:setUpPlots(event)
        end,
        onHour = function(event, hour)
            self:onHour(event, hour)
        end,
        onResults = function()
            self:removeKit()
        end,
        onFinished = function()
            self:removeKit()
        end,
        onCancelled = function()
            self:removeKit()
            self:reset(nil)
        end,
        replacePerson = function(oldId, newId)
            return self:replacePerson(oldId, newId)
        end,
    })
end

-- Queries (every machine) ------------------------------------------------------------------

local function getTC()
    return g_currentMission ~= nil and g_currentMission.TheContractor or nil
end

-- The plots' frames (TCShowScene.getPlotFrames) from the show's scene, by
-- number; empty when there's no show site up.
-- Worked out once a scene (the work area patch asks every tick).
function TheContractorPloughingMatch:getFrames()
    local tc = getTC()
    local site = tc ~= nil and tc.AuctionSite or nil
    local scene = site ~= nil and site:getScene() or nil
    if scene == nil or not TCShowScene.isShowDressing(scene) then
        return {}
    end
    if self.framesScene ~= scene then
        self.framesScene = scene
        self.frames = TCShowScene.getPlotFrames(scene)
    end
    return self.frames
end

function TheContractorPloughingMatch:getFrame(number)
    return self:getFrames()[number]
end

function TheContractorPloughingMatch:getPlot(number)
    return self.plots[number]
end

function TheContractorPloughingMatch:getFarmPlot(farmId)
    return TCPloughMatch.getFarmPlot(self.plots, farmId)
end

-- Whether a vehicle's one of the lent kit: its plot, or nil.
function TheContractorPloughingMatch:getKitPlot(vehicleId)
    if vehicleId == nil then
        return nil
    end
    for _, plot in ipairs(self.plots) do
        if plot.tractorId == vehicleId or plot.ploughId == vehicleId then
            return plot
        end
    end
    return nil
end

function TheContractorPloughingMatch:isKit(vehicle)
    return vehicle ~= nil and self:getKitPlot(NetworkUtil.getObjectId(vehicle)) ~= nil
end

-- TCVehicleLock (every machine, for its own player): vehicleId -> why it's
-- locked, for every piece of kit that player mayn't drive now.
function TheContractorPloughingMatch:getLockedKit(farmId)
    local locked = {}
    for _, plot in ipairs(self.plots) do
        local reason = TCPloughMatch.getKitLock(self, plot, farmId)
        if reason ~= nil then
            for _, vehicleId in ipairs({ plot.tractorId or false, plot.ploughId or false }) do
                if vehicleId then
                    locked[vehicleId] = reason
                end
            end
        end
    end
    return locked
end

-- A farm's best (TCPloughMatch.addBest's), or nil.
function TheContractorPloughingMatch:getBest(farmId)
    return self.best[farmId]
end

-- Who's on a plot, by name: the farm's (170: its worker's, for it) or the
-- farmer's; nil for an open one.
function TheContractorPloughingMatch.getPlotWho(plot)
    local tc = getTC()
    if plot.farmId ~= nil and plot.farmId > 0 then
        local farm = g_farmManager ~= nil and g_farmManager:getFarmById(plot.farmId) or nil
        local farmName = farm ~= nil and farm.name or nil
        local workerName = (plot.workerId or 0) > 0 and tc ~= nil and tc.ShowWorker ~= nil and
            tc.ShowWorker:getWorkerName(plot.farmId, plot.workerId) or nil
        if workerName ~= nil then
            return string.format(g_i18n:getText("tc_showWorker_plotWho"), workerName, farmName or "-")
        end
        return farmName
    end
    local farmers = tc ~= nil and tc.Farmers or nil
    local person = farmers ~= nil and plot.farmerId ~= nil and plot.farmerId > 0 and
        farmers:getPerson(plot.farmerId) or nil
    return person ~= nil and person.name or nil
end

-- The match starts again (server): a new show, or none. The farms' bests
-- and the farmers' skills stay.
function TheContractorPloughingMatch:reset(showId)
    self.showId = showId
    self.plots = {}
    self.setOut = false
    self.started = false
    self.over = false
    self.resultsGiven = false
    self.runs = {}
    self.startMinute = nil
    self.spawnQueue = {}
    self.loading = nil
    self.noticeIds = {}
    self:sync()
end

-- Setting out (server) ----------------------------------------------------------------------

local function newRun()
    -- grid: 168's, "before" read at 11:00 (players' plots); samples since
    -- the last load; savedRuns (measured runs from before a load) and their
    -- reverses and stops; firstMinute, lastMinute (game minutes of the
    -- first run and the last time the plough was down in the plot); result
    -- (its scorecard, server-only until the results); a farmer's plot's
    -- rolled card and painted strips.
    return { samples = {}, savedRuns = {}, reverses = 0, stops = 0, painted = 0 }
end

-- Server, at midnight before the day: the plots from the show's scene,
-- open to every company farm with farmers on the rest, and the kit for each.
function TheContractorPloughingMatch:setUpPlots(event)
    if event == nil then
        return
    end
    if self.showId ~= event.id then
        self:reset(event.id)
    end
    if self.setOut then
        return
    end
    local frames = self:getFrames()
    if #frames == 0 then
        TCLog.warning("TheContractor: show %d has no ploughing plots on its site: no match", event.id)
        return
    end
    local tc = getTC()
    local companies = tc.RandomEvents ~= nil and #tc.RandomEvents:getCompanyFarmIds() or 0
    local states = TCPloughMatch.planPlots(#frames, companies)
    local farmerCount = 0
    for _, state in ipairs(states) do
        if state == STATE.FARMER then
            farmerCount = farmerCount + 1
        end
    end
    -- 188: never a breeder, who's at their pen all day.
    local farmers = {}
    local breeders = tc.BreedersPen
    for _, farmer in ipairs(tc.Farmers ~= nil and tc.Farmers:getFarmers() or {}) do
        if breeders == nil or not breeders:isBreeder(farmer.id) then
            table.insert(farmers, farmer)
        end
    end
    local picked = TCPloughMatch.pickSome(farmers, farmerCount, self.random)
    self.plots, self.runs = {}, {}
    local nextFarmer = 1
    for number, state in ipairs(states) do
        local plot = { number = number, state = state, farmId = 0, farmerId = 0, workerId = 0 }
        self.runs[number] = newRun()
        if state == STATE.FARMER then
            local farmer = picked[nextFarmer]
            nextFarmer = nextFarmer + 1
            if farmer ~= nil then
                plot.farmerId = farmer.id
                self:rollFarmerRun(plot)
            else
                -- More plots than farmers: left empty.
                plot.state = STATE.OPEN
            end
        end
        self.plots[number] = plot
    end
    self.setOut = true
    -- 170: entered workers' plots, then anyone who can't make it withdrawn
    -- (their plot to a farmer) and the rest off to the show.
    self:reserveWorkerPlots()
    self.kitModels = self.kitModels or self.engine.pickKit()
    if self.kitModels == nil then
        TCLog.warning("TheContractor: no tractor and reversible plough in the store to lend: the plots have no kit")
    else
        for number = 1, #self.plots do
            self.engine.spawnKit(self, number)
        end
    end
    if tc.ShowWorker ~= nil then
        tc.ShowWorker:checkEntries(event)
    end
    TCLog.info("TheContractor: show %d's ploughing match set out: %d plots, %d farmers'", event.id, #self.plots,
        farmerCount)
    self:sync()
end

-- Server (170): each entered worker's farm gets the first open plot,
-- reserved for the worker. One with none left is withdrawn. Once the plots
-- are out.
function TheContractorPloughingMatch:reserveWorkerPlots()
    local tc = getTC()
    if not self.setOut or self.over or tc.ShowWorker == nil or tc.ShowWorker.showId ~= self.showId then
        return
    end
    local entries = {}
    for i, entry in ipairs(tc.ShowWorker:getEntries()) do
        entries[i] = entry
    end
    for _, entry in ipairs(entries) do
        if self:getFarmPlot(entry.farmId) == nil then
            local plot = nil
            for _, candidate in ipairs(self.plots) do
                if candidate.state == STATE.OPEN then
                    plot = candidate
                    break
                end
            end
            if plot ~= nil then
                plot.state = STATE.TAKEN
                plot.farmId = entry.farmId
                plot.workerId = entry.workerId
                TCLog.info("TheContractor: ploughing plot %d reserved for farm %d's worker %d", plot.number,
                    entry.farmId, entry.workerId)
            else
                tc.ShowWorker:withdrawEntry(entry.farmId, TCShowWorker.WITHDRAW.noPlot)
            end
        end
    end
    self:sync()
end

-- Server (170, ShowWorker:withdrawEntry): a farm's worker can't plough. Their
-- plot, if they had one and the match isn't over, goes to a farmer. Returns
-- whether there was one.
function TheContractorPloughingMatch:onWorkerWithdrawn(farmId, workerId)
    for _, plot in ipairs(self.plots) do
        if plot.farmId == farmId and plot.workerId == workerId and workerId ~= nil and workerId > 0 then
            if self.over then
                return false
            end
            self:giveToFarmer(plot)
            self:sync()
            return true
        end
    end
    return false
end

-- Server: a plot to a farmer who's not on one already (their score rolled,
-- painted from now), or left open with no farmer to spare.
function TheContractorPloughingMatch:giveToFarmer(plot)
    local tc = getTC()
    local used = {}
    for _, other in ipairs(self.plots) do
        if other.farmerId ~= nil and other.farmerId > 0 then
            used[other.farmerId] = true
        end
    end
    local free = {}
    local breeders = tc.BreedersPen
    for _, farmer in ipairs(tc.Farmers ~= nil and tc.Farmers:getFarmers() or {}) do
        if not used[farmer.id] and (breeders == nil or not breeders:isBreeder(farmer.id)) then
            table.insert(free, farmer)
        end
    end
    local farmer = TCPloughMatch.pickSome(free, 1, self.random)[1]
    plot.farmId, plot.workerId = 0, 0
    self.runs[plot.number] = newRun()
    if farmer == nil then
        plot.state, plot.farmerId = STATE.OPEN, 0
        TCLog.info("TheContractor: ploughing plot %d is free again (no farmer to spare)", plot.number)
        return
    end
    plot.state, plot.farmerId = STATE.FARMER, farmer.id
    self:rollFarmerRun(plot)
    if self.started then
        self.runs[plot.number].paintFrom = self.engine.getGameMinute()
    end
    TCLog.info("TheContractor: ploughing plot %d goes to farmer %d", plot.number, farmer.id)
end

-- A farmer's skill, rolled the first time it's needed and kept.
function TheContractorPloughingMatch:getSkill(farmerId)
    local skill = self.skills[farmerId]
    if skill == nil then
        skill = TCPloughMatch.rollSkill(self.random)
        self.skills[farmerId] = skill
    end
    return skill
end

-- Server: a farmer's plot's score and breakdown, rolled now and kept
-- hidden until the results.
function TheContractorPloughingMatch:rollFarmerRun(plot)
    local run = self.runs[plot.number]
    local total = TCPloughMatch.rollFarmerScore(self:getSkill(plot.farmerId), self.random)
    local minutes = TCPloughMatch.rollFarmerMinutes(self.random)
    run.result = TCPloughMatch.makeBreakdown(total, minutes, self.random, TCPloughScore.RULES.weights,
        TCPloughScore.PARTS)
    run.result.coverage = 0.8 + 0.2 * (run.result.parts.coverage.marks / run.result.parts.coverage.max)
    run.farmerMinutes = minutes
end

-- Server: the kit for a plot is out (the engine's spawnKit, done).
function TheContractorPloughingMatch:onKitSpawned(number, tractorId, ploughId)
    local plot = self.plots[number]
    if plot == nil then
        return
    end
    plot.tractorId, plot.ploughId = tractorId, ploughId
    self:sync()
end

-- Taking a plot (server) ----------------------------------------------------------------------

local function hasCompany(farmId)
    local tc = getTC()
    return tc ~= nil and tc.Company ~= nil and tc.Company:hasCompany(farmId)
end

-- What's wrong with a farm taking a plot, or nil (every machine: the prompt
-- asks before sending, the server again).
function TheContractorPloughingMatch:getTakeProblem(number, farmId)
    return TCPloughMatch.getTakeProblem(self, number, farmId, hasCompany(farmId))
end

function TheContractorPloughingMatch:getFinishProblem(number, farmId)
    return TCPloughMatch.getFinishProblem(self, number, farmId)
end

local function publishNotice(self, farmId, text)
    local tc = getTC()
    if tc.Notices == nil then
        return
    end
    local id = tc.Notices:publish(farmId, text, TheContractorPloughingMatch.NOTICE_MONTHS, true)
    if id ~= nil then
        table.insert(self.noticeIds, id)
    end
end

-- Server (TCPloughPlotEvent): a farm takes a plot. Returns nil, or the
-- problem.
function TheContractorPloughingMatch:takePlot(number, farmId)
    local problem = self:getTakeProblem(number, farmId)
    if problem ~= nil then
        TCLog.info("TheContractor: farm %d can't take plot %s: %s", farmId, tostring(number), problem)
        return problem
    end
    local plot = self.plots[number]
    plot.state = STATE.TAKEN
    plot.farmId = farmId
    TCLog.info("TheContractor: farm %d took ploughing plot %d", farmId, number)
    publishNotice(self, farmId, string.format(g_i18n:getText(self.started and "tc_ploughMatch_takenNoticeNow" or
        "tc_ploughMatch_takenNotice"), number, TCPloughMatch.START_HOUR))
    self:sync()
    return nil
end

-- Server (TCPloughPlotEvent): a farm says its run's finished: scored now,
-- the kit locked. Returns nil, or the problem.
function TheContractorPloughingMatch:finishPlot(number, farmId)
    local problem = self:getFinishProblem(number, farmId)
    if problem ~= nil then
        return problem
    end
    self:scorePlot(number)
    TCLog.info("TheContractor: farm %d finished on ploughing plot %d", farmId, number)
    self:sync()
    return nil
end

-- The match (server) -----------------------------------------------------------------------------

function TheContractorPloughingMatch:onHour(event, hour)
    if self.showId ~= event.id or not self.setOut then
        return
    end
    if hour >= TCPloughMatch.START_HOUR and not self.started then
        self:startMatch()
    end
    if hour >= TCPloughMatch.END_HOUR and not self.over then
        self:endMatch()
    end
end

-- Server, at 11:00: the players' plots' ground read, every company told.
function TheContractorPloughingMatch:startMatch()
    if self.started or not self.setOut then
        return
    end
    self.started = true
    self.startMinute = self.engine.getGameMinute()
    local frames = self:getFrames()
    for _, plot in ipairs(self.plots) do
        local run, frame = self.runs[plot.number], frames[plot.number]
        if plot.state ~= STATE.FARMER and (plot.workerId or 0) == 0 and frame ~= nil and run ~= nil then
            run.grid = TCPloughScore.makeGrid(frame, TCPloughScore.RULES)
            self.engine.readGround(frame, run.grid, "before")
        end
    end
    local tc = getTC()
    for _, farmId in ipairs(tc.RandomEvents ~= nil and tc.RandomEvents:getCompanyFarmIds() or {}) do
        local plot = self:getFarmPlot(farmId)
        publishNotice(self, farmId, plot ~= nil and
            string.format(g_i18n:getText("tc_ploughMatch_startedNoticePlot"), plot.number, TCPloughMatch.END_HOUR) or
            string.format(g_i18n:getText("tc_ploughMatch_startedNotice"), TCPloughMatch.END_HOUR))
    end
    TCLog.info("TheContractor: the ploughing match has started")
    self:sync()
end

-- Server, at 15:00 (or when the results are wanted, if that was slept
-- through): every run that isn't finished is, and the farmers' plots are
-- ploughed.
function TheContractorPloughingMatch:endMatch()
    if self.over then
        return
    end
    if not self.started then
        self:startMatch()
    end
    -- 170: a worker who's there has ploughed; one who never came is
    -- withdrawn, their plot a farmer's.
    self:startWorkerRuns()
    local tc = getTC()
    for _, plot in ipairs(self.plots) do
        if plot.state == STATE.TAKEN and (plot.workerId or 0) > 0 then
            local run = self.runs[plot.number]
            if run ~= nil and run.result ~= nil then
                plot.state = STATE.FINISHED
            elseif tc.ShowWorker ~= nil and tc.ShowWorker:getEntry(plot.farmId) ~= nil then
                tc.ShowWorker:withdrawEntry(plot.farmId, TCShowWorker.WITHDRAW.late)
            else
                self:giveToFarmer(plot)
            end
        end
    end
    for _, plot in ipairs(self.plots) do
        if plot.state == STATE.TAKEN then
            self:scorePlot(plot.number)
        end
    end
    self:paintFarmers(true)
    self.over = true
    TCLog.info("TheContractor: the ploughing match is over")
    self:sync()
end

-- Server: a plot's run scored from its ground and path (168), and finished.
function TheContractorPloughingMatch:scorePlot(number)
    local plot, run, frame = self.plots[number], self.runs[number], self:getFrame(number)
    plot.state = STATE.FINISHED
    if run == nil or frame == nil then
        return
    end
    run.result = self:measure(number)
    TCLog.info("TheContractor: ploughing plot %d scored %.1f", number, run.result ~= nil and run.result.total or 0)
end

-- Server: a plot's scorecard from its ground and path as they stand (also
-- the console's live score).
function TheContractorPloughingMatch:measure(number)
    local run, frame = self.runs[number], self:getFrame(number)
    if run == nil or frame == nil then
        return nil
    end
    local rules = TCPloughScore.RULES
    if run.grid == nil then
        run.grid = TCPloughScore.makeGrid(frame, rules)
        self.engine.readGround(frame, run.grid, "before")
    end
    self.engine.readGround(frame, run.grid, "ploughed")
    local histogram = self.engine.readAngles(frame)
    local runs, reverses, stops = TCPloughScore.splitRuns(run.samples, frame, rules)
    local allRuns = {}
    for _, measured in ipairs(run.savedRuns) do
        table.insert(allRuns, measured)
    end
    for _, measured in ipairs(runs) do
        table.insert(allRuns, measured)
    end
    local alongU = TCPloughScore.getWorkAxis(allRuns, frame)
    local ground = TCPloughScore.measureGround(run.grid, frame, alongU, rules)
    local angles = histogram ~= nil and TCPloughScore.measureAngles(histogram) or nil
    local minutes = TCPloughMatch.getMinutesUsed(run.firstMinute, run.lastMinute) or 0
    local result = TCPloughScore.score({
        ground = ground,
        runs = allRuns,
        angles = angles,
        reverses = run.reverses + reverses,
        stops = run.stops + stops,
        minutes = minutes,
    }, rules)
    local card = { total = result.total, minutes = minutes, coverage = ground.coverage, parts = {} }
    for name, part in pairs(result.parts) do
        card.parts[name] = { marks = part.marks, max = part.max }
    end
    return card
end

-- Server, every frame while the match is on: each taken plot's kit sampled
-- (168's path), and the farmers' plots painted on.
function TheContractorPloughingMatch:updateMatch(dt)
    if not self.started or self.over then
        return
    end
    self.sinceSampleMs = self.sinceSampleMs + dt
    if self.sinceSampleMs >= TheContractorPloughingMatch.SAMPLE_MS then
        local elapsed = self.sinceSampleMs
        self.sinceSampleMs = 0
        local frames = self:getFrames()
        for _, plot in ipairs(self.plots) do
            if plot.state == STATE.TAKEN and (plot.workerId or 0) == 0 and plot.tractorId ~= nil and
                    frames[plot.number] ~= nil then
                self:samplePlot(plot, frames[plot.number], elapsed)
            end
        end
    end
    self.sincePaintMs = self.sincePaintMs + dt
    if self.sincePaintMs >= TheContractorPloughingMatch.PAINT_MS then
        self.sincePaintMs = 0
        self:startWorkerRuns()
        self:paintFarmers(false)
    end
end

-- Server: one sample of a plot's ploughman, its first and last minutes.
function TheContractorPloughingMatch:samplePlot(plot, frame, elapsedMs)
    local run = self.runs[plot.number]
    run.realMs = (run.realMs or 0) + elapsedMs
    local sample = self.engine.sample(plot.tractorId, run.realMs / 1000)
    if sample == nil then
        return
    end
    if #run.samples < TheContractorPloughingMatch.MAX_SAMPLES then
        table.insert(run.samples, sample)
    end
    local u, v = TCPloughScore.toLocal(frame, sample.x, sample.z)
    if sample.lowered and TCPloughScore.isInside(frame, u, v) then
        local minute = self.engine.getGameMinute()
        run.firstMinute = run.firstMinute or minute
        run.lastMinute = minute
    end
end

-- Whether a plot's painted, not driven: a farmer's, or (170) a worker's
-- once their run's started.
local function isPainted(plot, run)
    return run ~= nil and (plot.state == STATE.FARMER or ((plot.workerId or 0) > 0 and run.result ~= nil))
end

-- Server (170): each worker's run starts once they're at the show and the
-- match is on: their score rolled now (kept hidden), painted from now.
function TheContractorPloughingMatch:startWorkerRuns()
    local tc = getTC()
    if not self.started or self.over or tc.ShowWorker == nil then
        return
    end
    for _, plot in ipairs(self.plots) do
        local run = self.runs[plot.number]
        if plot.state == STATE.TAKEN and (plot.workerId or 0) > 0 and run ~= nil and run.result == nil and
                tc.ShowWorker:isAtShow(plot.farmId) then
            local total, minutes = tc.ShowWorker:rollRun(plot.farmId)
            if total ~= nil then
                run.result = TCPloughMatch.makeBreakdown(total, minutes, self.random, TCPloughScore.RULES.weights,
                    TCPloughScore.PARTS)
                run.result.coverage = 0.8 + 0.2 * (run.result.parts.coverage.marks / run.result.parts.coverage.max)
                run.farmerMinutes = minutes
                run.paintFrom = self.engine.getGameMinute()
                TCLog.info("TheContractor: farm %d's worker starts on ploughing plot %d", plot.farmId, plot.number)
            end
        end
    end
end

-- Server: each farmer's (and 170 worker's) plot painted ploughed up to
-- where they'd be by now (their rolled minutes from the match's start, or
-- from when they started), or all of it.
function TheContractorPloughingMatch:paintFarmers(finish)
    local frames = self:getFrames()
    local now = self.engine.getGameMinute()
    for _, plot in ipairs(self.plots) do
        local run, frame = self.runs[plot.number], frames[plot.number]
        if isPainted(plot, run) and frame ~= nil then
            local strips = math.ceil(frame.size / TCPloughMatch.PLOUGH_WIDTH)
            local share = 1
            if not finish then
                local elapsed = now - (run.paintFrom or self.startMinute or now)
                share = math.max(0, math.min(1, elapsed / math.max(1, run.farmerMinutes or 1)))
            end
            local target = math.floor(share * strips + 0.0001)
            if target > run.painted then
                self.engine.paintStrips(self, frame, run.painted + 1, target, strips)
                run.painted = target
            end
        end
    end
end

-- Results (server) -------------------------------------------------------------------------------

-- The show's giveResults (16:00, once): every scored plot ranked, the
-- players' scorecards to their farms, each farm's best kept. Returns the
-- placings for the show to pay (see TheContractorShow:registerCompetition).
function TheContractorPloughingMatch:getPlacings(event)
    if self.showId ~= event.id or not self.setOut then
        return {}
    end
    if not self.over then
        self:endMatch()
    end
    local competitors = {}
    for _, plot in ipairs(self.plots) do
        local run = self.runs[plot.number]
        if run ~= nil and run.result ~= nil and (plot.farmId > 0 or plot.farmerId > 0) then
            table.insert(competitors, { score = run.result.total, number = plot.number, plot = plot })
        end
    end
    local ranked = TCPloughMatch.rankPlots(competitors)
    local placings = {}
    for _, competitor in ipairs(ranked) do
        local plot = competitor.plot
        local card = self.runs[plot.number].result
        card.placing = competitor.placing
        plot.card = card
        local placing = competitor.placing
        if placing ~= nil then
            table.insert(placings, {
                placing = placing,
                farmId = plot.farmId > 0 and plot.farmId or nil,
                farmerId = plot.farmId == 0 and plot.farmerId > 0 and plot.farmerId or nil,
                entrant = string.format("%.1f", card.total),
                prize = TCPloughMatch.PRIZES[placing],
                reputation = TCPloughMatch.REPUTATION[placing],
                opinion = TCPloughMatch.OPINION[placing],
            })
        end
        if plot.farmId > 0 then
            TCPloughMatch.addBest(self.best, plot.farmId, card.total, placing)
            self:postScorecard(event, plot, card)
        end
    end
    self:dropNotices()
    self.resultsGiven = true
    TCLog.info("TheContractor: ploughing match results: %d run(s) scored, %d placed", #ranked, #placings)
    self:sync()
    return placings
end

-- The scorecard's parts as the inbox shows them: "marks/max" for each of
-- 168's parts, "-" for one that wasn't measured.
function TheContractorPloughingMatch.getCardArgs(card)
    local args = {}
    for _, name in ipairs(TCPloughScore.PARTS) do
        local part = card.parts[name]
        table.insert(args, part ~= nil and string.format("%.1f/%d", part.marks, part.max) or "-")
    end
    return args
end

-- Server: a farm's scorecard, by inbox (the show's kind, kept like the
-- results).
function TheContractorPloughingMatch:postScorecard(event, plot, card)
    local tc = getTC()
    if tc.Inbox == nil then
        return
    end
    local placingArg = card.placing ~= nil and ("$l10n_" .. TheContractorShow.getPlacingNameKey(card.placing)) or
        "$l10n_tc_ploughMatch_unplaced"
    local args = { tostring(plot.number), placingArg, string.format("%.1f", card.total),
        tostring(math.floor((card.minutes or 0) + 0.5)) }
    for _, arg in ipairs(TheContractorPloughingMatch.getCardArgs(card)) do
        table.insert(args, arg)
    end
    -- 170: a worker's run names them.
    local body = "tc_ploughMatch_cardBody"
    if (plot.workerId or 0) > 0 and tc.ShowWorker ~= nil then
        body = "tc_ploughMatch_cardBodyWorker"
        table.insert(args, tc.ShowWorker:getWorkerName(plot.farmId, plot.workerId) or "-")
    end
    tc.Inbox:postMessage(plot.farmId, TheContractorShow.KIND, "tc_ploughMatch_cardTitle", body,
        args, { TheContractorInbox.DISMISS_ACTION },
        { resultsShowId = event.id, farmerId = event.hostFarmerId, fieldId = event.ploughFieldId or event.fieldId })
end

function TheContractorPloughingMatch:dropNotices()
    local tc = getTC()
    if tc.Notices ~= nil then
        for _, id in ipairs(self.noticeIds) do
            tc.Notices:remove(id)
        end
    end
    self.noticeIds = {}
end

-- Server: the kit taken away (after the results, or the day's called off).
function TheContractorPloughingMatch:removeKit()
    self.spawnQueue = {}
    self.loading = nil
    local changed = false
    for _, plot in ipairs(self.plots) do
        for _, key in ipairs({ "ploughId", "tractorId" }) do
            if plot[key] ~= nil then
                self.engine.deleteVehicle(plot[key])
                plot[key] = nil
                changed = true
            end
        end
    end
    -- Nothing more to sample or paint.
    for _, run in pairs(self.runs) do
        run.samples = {}
    end
    if changed then
        TCLog.info("TheContractor: the ploughing match's kit taken away")
        self:sync()
    end
end

-- Farms and farmers ---------------------------------------------------------------------------------

-- Every machine (TCFarmDeletion): a deleted farm's plot's open again (its
-- run and card gone), and its best forgotten.
function TheContractorPloughingMatch:forgetFarm(farmId)
    for _, plot in ipairs(self.plots) do
        if plot.farmId == farmId then
            plot.farmId = 0
            plot.workerId = 0
            plot.card = nil
            plot.state = self.over and STATE.FINISHED or STATE.OPEN
            local run = self.runs[plot.number]
            if run ~= nil then
                self.runs[plot.number] = newRun()
                self.runs[plot.number].grid = run.grid
            end
        end
    end
    self.best[farmId] = nil
end

-- Every machine (128, through the show): a retired farmer's plot is their
-- successor's, who has their own skill. Returns how many.
function TheContractorPloughingMatch:replacePerson(oldId, newId)
    local count = 0
    for _, plot in ipairs(self.plots) do
        if plot.farmerId == oldId then
            plot.farmerId = newId
            count = count + 1
        end
    end
    self.skills[oldId] = nil
    return count
end

-- Sync ----------------------------------------------------------------------------------------------

function TheContractorPloughingMatch:sync()
    if g_server ~= nil then
        g_server:broadcastEvent(TCPloughMatchEvent.new(self))
    end
    self.markersKey = nil
end

local function writeCard(streamId, card)
    if not streamWriteBool(streamId, card ~= nil) then
        return
    end
    streamWriteFloat32(streamId, card.total or 0)
    streamWriteFloat32(streamId, card.minutes or 0)
    streamWriteFloat32(streamId, card.coverage or 0)
    streamWriteUInt8(streamId, card.placing or 0)
    for _, name in ipairs(TCPloughScore.PARTS) do
        local part = card.parts[name]
        if streamWriteBool(streamId, part ~= nil) then
            streamWriteFloat32(streamId, part.marks)
            streamWriteUInt8(streamId, part.max)
        end
    end
end

local function readCard(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local card = {
        total = streamReadFloat32(streamId),
        minutes = streamReadFloat32(streamId),
        coverage = streamReadFloat32(streamId),
        parts = {},
    }
    local placing = streamReadUInt8(streamId)
    card.placing = placing > 0 and placing or nil
    for _, name in ipairs(TCPloughScore.PARTS) do
        if streamReadBool(streamId) then
            card.parts[name] = { marks = streamReadFloat32(streamId), max = streamReadUInt8(streamId) }
        end
    end
    return card
end

-- What every machine has: no ground, path, skill or live score, and a card
-- only once the results are given.
function TheContractorPloughingMatch.writeState(streamId, state)
    streamWriteInt32(streamId, state.showId or -1)
    streamWriteBool(streamId, state.setOut == true)
    streamWriteBool(streamId, state.started == true)
    streamWriteBool(streamId, state.over == true)
    streamWriteBool(streamId, state.resultsGiven == true)
    streamWriteUInt8(streamId, #state.plots)
    for _, plot in ipairs(state.plots) do
        streamWriteString(streamId, plot.state)
        streamWriteInt32(streamId, plot.farmId or 0)
        streamWriteInt32(streamId, plot.farmerId or 0)
        streamWriteInt32(streamId, plot.workerId or 0)
        streamWriteInt32(streamId, plot.tractorId or -1)
        streamWriteInt32(streamId, plot.ploughId or -1)
        writeCard(streamId, state.resultsGiven and plot.card or nil)
    end
    local farmIds = {}
    for farmId in pairs(state.best) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)
    streamWriteUInt8(streamId, #farmIds)
    for _, farmId in ipairs(farmIds) do
        local best = state.best[farmId]
        streamWriteInt32(streamId, farmId)
        streamWriteFloat32(streamId, best.bestScore)
        streamWriteUInt16(streamId, best.wins)
        streamWriteUInt16(streamId, best.matches)
    end
end

function TheContractorPloughingMatch.readState(streamId)
    local state = { plots = {}, best = {} }
    local showId = streamReadInt32(streamId)
    state.showId = showId >= 0 and showId or nil
    state.setOut = streamReadBool(streamId)
    state.started = streamReadBool(streamId)
    state.over = streamReadBool(streamId)
    state.resultsGiven = streamReadBool(streamId)
    for number = 1, streamReadUInt8(streamId) do
        local plot = { number = number, state = streamReadString(streamId), farmId = streamReadInt32(streamId),
            farmerId = streamReadInt32(streamId), workerId = streamReadInt32(streamId) }
        local tractorId, ploughId = streamReadInt32(streamId), streamReadInt32(streamId)
        plot.tractorId = tractorId >= 0 and tractorId or nil
        plot.ploughId = ploughId >= 0 and ploughId or nil
        plot.card = readCard(streamId)
        state.plots[number] = plot
    end
    for _ = 1, streamReadUInt8(streamId) do
        local farmId = streamReadInt32(streamId)
        state.best[farmId] = { bestScore = streamReadFloat32(streamId), wins = streamReadUInt16(streamId),
            matches = streamReadUInt16(streamId) }
    end
    return state
end

-- A client: the match as the server sent it.
function TheContractorPloughingMatch:applyState(state)
    self.showId = state.showId
    self.setOut = state.setOut
    self.started = state.started
    self.over = state.over
    self.resultsGiven = state.resultsGiven
    self.plots = state.plots
    self.best = state.best
    self.markersKey = nil
end

function TheContractorPloughingMatch:writeInitialClientState(streamId, connection)
    TheContractorPloughingMatch.writeState(streamId, self)
end

function TheContractorPloughingMatch:readInitialClientState(streamId, connection)
    self:applyState(TheContractorPloughingMatch.readState(streamId))
end

-- Persistence (server) -------------------------------------------------------------------------------

local RUN_KEYS = { "length", "lateralRms", "lateralMax", "headingRms", "axisX", "axisZ", "count" }

local function saveCard(xmlFile, key, card)
    setXMLFloat(xmlFile, key .. "#total", card.total or 0)
    setXMLFloat(xmlFile, key .. "#minutes", card.minutes or 0)
    setXMLFloat(xmlFile, key .. "#coverage", card.coverage or 0)
    if card.placing ~= nil then
        setXMLInt(xmlFile, key .. "#placing", card.placing)
    end
    local i = 0
    for _, name in ipairs(TCPloughScore.PARTS) do
        local part = card.parts[name]
        if part ~= nil then
            local partKey = string.format("%s.part(%d)", key, i)
            setXMLString(xmlFile, partKey .. "#name", name)
            setXMLFloat(xmlFile, partKey .. "#marks", part.marks)
            setXMLInt(xmlFile, partKey .. "#max", part.max)
            i = i + 1
        end
    end
end

local function loadCard(xmlFile, key)
    local total = getXMLFloat(xmlFile, key .. "#total")
    if total == nil then
        return nil
    end
    local card = { total = total, minutes = getXMLFloat(xmlFile, key .. "#minutes") or 0,
        coverage = getXMLFloat(xmlFile, key .. "#coverage") or 0, placing = getXMLInt(xmlFile, key .. "#placing"),
        parts = {} }
    local i = 0
    while hasXMLProperty(xmlFile, string.format("%s.part(%d)", key, i)) do
        local partKey = string.format("%s.part(%d)", key, i)
        local name = getXMLString(xmlFile, partKey .. "#name")
        if name ~= nil then
            card.parts[name] = { marks = getXMLFloat(xmlFile, partKey .. "#marks") or 0,
                max = getXMLInt(xmlFile, partKey .. "#max") or 0 }
        end
        i = i + 1
    end
    return card
end

function TheContractorPloughingMatch:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorPloughingMatch.SAVE_KEY
    if self.showId ~= nil then
        setXMLInt(xmlFile, key .. "#showId", self.showId)
    end
    setXMLBool(xmlFile, key .. "#setOut", self.setOut)
    setXMLBool(xmlFile, key .. "#started", self.started)
    setXMLBool(xmlFile, key .. "#over", self.over)
    setXMLBool(xmlFile, key .. "#resultsGiven", self.resultsGiven)
    if self.startMinute ~= nil then
        setXMLFloat(xmlFile, key .. "#startMinute", self.startMinute)
    end
    if self.kitModels ~= nil then
        setXMLString(xmlFile, key .. "#tractor", self.kitModels.tractorXml)
        setXMLString(xmlFile, key .. "#plough", self.kitModels.ploughXml)
    end
    local frames = self:getFrames()
    for i, plot in ipairs(self.plots) do
        local plotKey = string.format("%s.plot(%d)", key, i - 1)
        setXMLString(xmlFile, plotKey .. "#state", plot.state)
        setXMLInt(xmlFile, plotKey .. "#farmId", plot.farmId or 0)
        setXMLInt(xmlFile, plotKey .. "#farmerId", plot.farmerId or 0)
        if (plot.workerId or 0) > 0 then
            setXMLInt(xmlFile, plotKey .. "#workerId", plot.workerId)
        end
        for _, name in ipairs({ "tractor", "plough" }) do
            local uniqueId = TCVehicleIds.getUniqueId(plot[name .. "Id"]) or (plot.uniqueIds or {})[name]
            if uniqueId ~= nil then
                setXMLString(xmlFile, plotKey .. "#" .. name, uniqueId)
            end
        end
        local run = self.runs[plot.number]
        if run ~= nil then
            if run.firstMinute ~= nil then
                setXMLFloat(xmlFile, plotKey .. "#firstMinute", run.firstMinute)
                setXMLFloat(xmlFile, plotKey .. "#lastMinute", run.lastMinute or run.firstMinute)
            end
            setXMLInt(xmlFile, plotKey .. "#painted", run.painted or 0)
            if run.farmerMinutes ~= nil then
                setXMLFloat(xmlFile, plotKey .. "#farmerMinutes", run.farmerMinutes)
            end
            if run.paintFrom ~= nil then
                setXMLFloat(xmlFile, plotKey .. "#paintFrom", run.paintFrom)
            end
            if run.grid ~= nil then
                setXMLString(xmlFile, plotKey .. "#before", TCPloughMatch.packGrid(run.grid, "before"))
            end
            -- The path so far, as runs (a run under way when it's saved
            -- carries on as a new one after the load).
            local runs, reverses, stops = {}, 0, 0
            if frames[plot.number] ~= nil and #run.samples > 0 then
                runs, reverses, stops = TCPloughScore.splitRuns(run.samples, frames[plot.number], TCPloughScore.RULES)
            end
            setXMLInt(xmlFile, plotKey .. "#reverses", run.reverses + reverses)
            setXMLInt(xmlFile, plotKey .. "#stops", run.stops + stops)
            local index = 0
            for _, list in ipairs({ run.savedRuns, runs }) do
                for _, measured in ipairs(list) do
                    local runKey = string.format("%s.run(%d)", plotKey, index)
                    for _, name in ipairs(RUN_KEYS) do
                        setXMLFloat(xmlFile, runKey .. "#" .. name, measured[name] or 0)
                    end
                    index = index + 1
                end
            end
            if run.result ~= nil then
                saveCard(xmlFile, plotKey .. ".result", run.result)
            end
        end
    end
    local farmerIds = {}
    for farmerId in pairs(self.skills) do
        table.insert(farmerIds, farmerId)
    end
    table.sort(farmerIds)
    for i, farmerId in ipairs(farmerIds) do
        local skillKey = string.format("%s.skill(%d)", key, i - 1)
        setXMLInt(xmlFile, skillKey .. "#farmerId", farmerId)
        setXMLFloat(xmlFile, skillKey .. "#value", self.skills[farmerId])
    end
    local farmIds = {}
    for farmId in pairs(self.best) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)
    for i, farmId in ipairs(farmIds) do
        local bestKey = string.format("%s.best(%d)", key, i - 1)
        local best = self.best[farmId]
        setXMLInt(xmlFile, bestKey .. "#farmId", farmId)
        setXMLFloat(xmlFile, bestKey .. "#bestScore", best.bestScore)
        setXMLInt(xmlFile, bestKey .. "#wins", best.wins)
        setXMLInt(xmlFile, bestKey .. "#matches", best.matches)
    end
end

function TheContractorPloughingMatch:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorPloughingMatch.SAVE_KEY
    self.showId = getXMLInt(xmlFile, key .. "#showId")
    self.setOut = getXMLBool(xmlFile, key .. "#setOut") == true
    self.started = getXMLBool(xmlFile, key .. "#started") == true
    self.over = getXMLBool(xmlFile, key .. "#over") == true
    self.resultsGiven = getXMLBool(xmlFile, key .. "#resultsGiven") == true
    self.startMinute = getXMLFloat(xmlFile, key .. "#startMinute")
    local tractorXml = getXMLString(xmlFile, key .. "#tractor")
    local ploughXml = getXMLString(xmlFile, key .. "#plough")
    if tractorXml ~= nil and ploughXml ~= nil then
        self.kitModels = { tractorXml = tractorXml, ploughXml = ploughXml }
    end
    self.plots, self.runs = {}, {}
    local i = 0
    while hasXMLProperty(xmlFile, string.format("%s.plot(%d)", key, i)) do
        local plotKey = string.format("%s.plot(%d)", key, i)
        local number = i + 1
        local plot = {
            number = number,
            state = getXMLString(xmlFile, plotKey .. "#state") or STATE.OPEN,
            farmId = getXMLInt(xmlFile, plotKey .. "#farmId") or 0,
            farmerId = getXMLInt(xmlFile, plotKey .. "#farmerId") or 0,
            workerId = getXMLInt(xmlFile, plotKey .. "#workerId") or 0,
            uniqueIds = { tractor = getXMLString(xmlFile, plotKey .. "#tractor"),
                plough = getXMLString(xmlFile, plotKey .. "#plough") },
        }
        local run = newRun()
        run.firstMinute = getXMLFloat(xmlFile, plotKey .. "#firstMinute")
        run.lastMinute = getXMLFloat(xmlFile, plotKey .. "#lastMinute")
        run.painted = getXMLInt(xmlFile, plotKey .. "#painted") or 0
        run.farmerMinutes = getXMLFloat(xmlFile, plotKey .. "#farmerMinutes")
        run.paintFrom = getXMLFloat(xmlFile, plotKey .. "#paintFrom")
        run.reverses = getXMLInt(xmlFile, plotKey .. "#reverses") or 0
        run.stops = getXMLInt(xmlFile, plotKey .. "#stops") or 0
        run.packedBefore = getXMLString(xmlFile, plotKey .. "#before")
        local j = 0
        while hasXMLProperty(xmlFile, string.format("%s.run(%d)", plotKey, j)) do
            local runKey = string.format("%s.run(%d)", plotKey, j)
            local measured = {}
            for _, name in ipairs(RUN_KEYS) do
                measured[name] = getXMLFloat(xmlFile, runKey .. "#" .. name) or 0
            end
            table.insert(run.savedRuns, measured)
            j = j + 1
        end
        run.result = loadCard(xmlFile, plotKey .. ".result")
        if self.resultsGiven and run.result ~= nil then
            plot.card = run.result
        end
        self.plots[number] = plot
        self.runs[number] = run
        i = i + 1
    end
    self.skills = {}
    i = 0
    while hasXMLProperty(xmlFile, string.format("%s.skill(%d)", key, i)) do
        local skillKey = string.format("%s.skill(%d)", key, i)
        local farmerId = getXMLInt(xmlFile, skillKey .. "#farmerId")
        if farmerId ~= nil then
            self.skills[farmerId] = getXMLFloat(xmlFile, skillKey .. "#value") or 0
        end
        i = i + 1
    end
    self.best = {}
    i = 0
    while hasXMLProperty(xmlFile, string.format("%s.best(%d)", key, i)) do
        local bestKey = string.format("%s.best(%d)", key, i)
        local farmId = getXMLInt(xmlFile, bestKey .. "#farmId")
        if farmId ~= nil then
            self.best[farmId] = { bestScore = getXMLFloat(xmlFile, bestKey .. "#bestScore") or 0,
                wins = getXMLInt(xmlFile, bestKey .. "#wins") or 0, matches = getXMLInt(xmlFile, bestKey .. "#matches") or 0 }
        end
        i = i + 1
    end
end

-- Server, once vehicles exist: the kit's object ids from their uniqueIds,
-- the saved ground back on its grid (the site's scene has loaded by now),
-- and any kit that's missing on a day that's still on spawned again.
function TheContractorPloughingMatch:resolveSavedVehicles()
    local frames = self:getFrames()
    local respawn = {}
    for _, plot in ipairs(self.plots) do
        local uniqueIds = plot.uniqueIds or {}
        plot.tractorId = uniqueIds.tractor ~= nil and TCVehicleIds.getObjectId(uniqueIds.tractor) or nil
        plot.ploughId = uniqueIds.plough ~= nil and TCVehicleIds.getObjectId(uniqueIds.plough) or nil
        plot.uniqueIds = nil
        local run, frame = self.runs[plot.number], frames[plot.number]
        if run ~= nil and run.packedBefore ~= nil and frame ~= nil then
            run.grid = TCPloughScore.makeGrid(frame, TCPloughScore.RULES)
            TCPloughMatch.unpackGrid(run.grid, "before", run.packedBefore)
        end
        if run ~= nil then
            run.packedBefore = nil
        end
        if self.setOut and not self.resultsGiven and self.kitModels ~= nil and
                (plot.tractorId == nil or plot.ploughId == nil) then
            table.insert(respawn, plot.number)
        end
    end
    for _, number in ipairs(respawn) do
        local plot = self.plots[number]
        for _, key in ipairs({ "ploughId", "tractorId" }) do
            if plot[key] ~= nil then
                self.engine.deleteVehicle(plot[key])
                plot[key] = nil
            end
        end
        TCLog.info("TheContractor: ploughing plot %d's kit is missing after the load: spawned again", number)
        self.engine.spawnKit(self, number)
    end
    self:sync()
end

-- This machine: markers and farmers ----------------------------------------------------------------

-- Every frame, on every machine: the server's sampling, loading and
-- painting; each machine's map markers and the farmers by their plots.
function TheContractorPloughingMatch:update(dt)
    if g_currentMission:getIsServer() then
        self.engine.processSpawnQueue(self)
        self:updateMatch(dt)
    end
    self:refreshMarkers()
    self:updateFigures(dt)
end

-- Whether the plots are out on the field now (set out, before the results).
function TheContractorPloughingMatch:isOnField()
    return self.setOut and not self.resultsGiven and #self.plots > 0
end

-- The plots' map markers (a machine with a map): each plot's, while they're
-- out.
function TheContractorPloughingMatch:refreshMarkers()
    local frames = self:isOnField() and self:getFrames() or {}
    local key = string.format("%s:%d:%d", tostring(self.showId), #frames, self:isOnField() and 1 or 0)
    if key == self.markersKey then
        return
    end
    self.markersKey = key
    self:removeMarkers()
    if g_currentMission.hud == nil or PlaceableHotspot == nil or g_currentMission.addMapHotspot == nil then
        return
    end
    for _, frame in ipairs(frames) do
        local hotspot = PlaceableHotspot.new()
        hotspot:setName(string.format(g_i18n:getText("tc_ploughMatch_mapName"), frame.number))
        hotspot:createIcon()
        hotspot:setPlaceableType(PlaceableHotspot.TYPE.EXCLAMATION_MARK)
        hotspot:setWorldPosition(frame.cx, frame.cz)
        local x, z = TCShowScene.getStartPeg(frame)
        hotspot:setTeleportWorldPosition(x, getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z), z)
        g_currentMission:addMapHotspot(hotspot)
        table.insert(self.markers, hotspot)
    end
end

function TheContractorPloughingMatch:removeMarkers()
    for _, hotspot in ipairs(self.markers) do
        if g_currentMission ~= nil and g_currentMission.removeMapHotspot ~= nil and g_currentMission.hud ~= nil then
            g_currentMission:removeMapHotspot(hotspot)
        end
        hotspot:delete()
    end
    self.markers = {}
end

-- The worker on a plot (170), while they're at the show: their roster
-- entry, or nil.
function TheContractorPloughingMatch:getPlotWorker(plot)
    local tc = getTC()
    if (plot.workerId or 0) == 0 or tc == nil or tc.ShowWorker == nil or tc.Staff == nil or
            not tc.ShowWorker:isAtShow(plot.farmId) then
        return nil
    end
    return tc.Staff:getWorker(plot.farmId, plot.workerId)
end

-- The farmers by their plots (a machine with a client): one standing by
-- each farmer's parked kit while the plots are out. A look from the base
-- maps' people, picked from the show and the plot (the same on every
-- machine). 170: an entered worker stands by their plot's kit in their own
-- look while they're at the show.
function TheContractorPloughingMatch:updateFigures(dt)
    if (self.figures == nil and not self:isOnField()) or TCFigures.getUnavailableReason() ~= nil then
        return
    end
    local frames = self:isOnField() and self:getFrames() or {}
    local wanted, workers = {}, {}
    for _, plot in ipairs(self.plots) do
        if frames[plot.number] ~= nil then
            local worker = self:getPlotWorker(plot)
            if plot.state == STATE.FARMER then
                table.insert(wanted, plot.number)
            elseif worker ~= nil then
                table.insert(wanted, plot.number)
                workers[plot.number] = worker
            end
        end
    end
    local parts = {}
    for _, number in ipairs(wanted) do
        -- A worker's look by its cached style, so an edited look (066) loads
        -- afresh.
        table.insert(parts, workers[number] ~= nil and string.format("%dw%d%s", number, workers[number].id,
            tostring(TCWorkerAppearance.getPlayerStyle(workers[number]))) or tostring(number))
    end
    local key = string.format("%s:%s", tostring(self.showId), table.concat(parts, ","))
    if key ~= self.figuresKey then
        self.figuresKey = key
        self:removeFigures()
        if #wanted > 0 then
            self.templates = self.templates or TCFigures.readTemplates()
            local templates = self.templates
            if #templates > 0 then
                self.figures = {}
                for _, number in ipairs(wanted) do
                    local frame = frames[number]
                    local spot = TCPloughMatch.FARMER_SPOT
                    local x, z = TCShowScene.plotToWorld(frame, spot.u, spot.v)
                    local template = templates[((self.showId or 0) * 7 + number * 13) % #templates + 1]
                    local style = workers[number] ~= nil and TCWorkerAppearance.getPlayerStyle(workers[number]) or nil
                    if style ~= nil then
                        template = { style = style }
                    end
                    -- Facing out of the plot, to the crowd.
                    table.insert(self.figures, { kind = "stand", template = template, x = x,
                        y = TCFigures.groundY(x, z), z = z, yaw = math.atan2(-frame.dirX, -frame.dirZ) })
                end
            end
        end
    end
    if self.figures ~= nil then
        local cx, cy, cz = TCFigures.getCameraPosition()
        if cx ~= nil then
            TCFigures.update(self.figures, dt, cx, cy, cz, 1)
        end
    end
end

function TheContractorPloughingMatch:removeFigures()
    if self.figures ~= nil then
        TCFigures.freeAll(self.figures)
        self.figures = nil
    end
end

-- deleteMap.
function TheContractorPloughingMatch:delete()
    self:removeMarkers()
    self:removeFigures()
    self.templates = nil
end

-- The kit's plough works only its own plot ------------------------------------------------------------

-- Vanilla only lets a MISSION vehicle's work areas work a mission's field.
-- The lent plough works its own plot and the margin round it 168 scores
-- ploughing outside the plot in, and nowhere else. Every machine (from the
-- synced plots and scene). Patched at module scope, like 071's.
function TheContractorPloughingMatch.getIsAccessibleAtWorldPosition(vehicle, superFunc, farmId, x, z, ...)
    local tc = getTC()
    local match = tc ~= nil and tc.PloughingMatch or nil
    local plot = match ~= nil and match:getKitPlot(NetworkUtil.getObjectId(vehicle)) or nil
    if plot ~= nil then
        local frame = match:getFrame(plot.number)
        if frame == nil then
            return false, farmId, false
        end
        -- Outside it, nothing to buy: no "farmland not owned" warning.
        local u, v = TCPloughScore.toLocal(frame, x, z)
        local isInside = TCPloughScore.isInside(frame, u, v, TCPloughScore.RULES.margin)
        return isInside, farmId, isInside
    end
    return superFunc(vehicle, farmId, x, z, ...)
end

if WorkArea ~= nil and not WorkArea.tcPloughMatchHookInstalled and WorkArea.getIsAccessibleAtWorldPosition ~= nil then
    WorkArea.getIsAccessibleAtWorldPosition = Utils.overwrittenFunction(WorkArea.getIsAccessibleAtWorldPosition,
        TheContractorPloughingMatch.getIsAccessibleAtWorldPosition)
    WorkArea.tcPloughMatchHookInstalled = true
end

-- The engine's half (server) ---------------------------------------------------------------------------

local ENGINE = {}
TheContractorPloughingMatch.ENGINE = ENGINE

-- Game minutes since day 0, now.
function ENGINE.getGameMinute()
    local environment = g_currentMission.environment
    return TCPloughMatch.toGameMinute(environment.currentMonotonicDay, (environment.dayTime or 0) / 60000)
end

function ENGINE.readGround(frame, grid, key)
    TCPloughTrial.readGrid(frame, grid, key)
end

function ENGINE.readAngles(frame)
    return TCPloughTrial.readAngles(frame)
end

local function getVehicle(vehicleId)
    local vehicle = vehicleId ~= nil and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

function ENGINE.sample(vehicleId, t)
    local vehicle = getVehicle(vehicleId)
    if vehicle == nil then
        return nil
    end
    return TCPloughTrial.sampleVehicle(vehicle, t)
end

function ENGINE.deleteVehicle(vehicleId)
    local vehicle = getVehicle(vehicleId)
    if vehicle ~= nil then
        vehicle:delete()
    end
end

-- Strips from..to (of count, across the plot) painted ploughed, the
-- furrows along the plot.
function ENGINE.paintStrips(match, frame, from, to, count)
    local tc = getTC()
    local event = tc.Show ~= nil and tc.Show:getEvent() or nil
    local field = event ~= nil and g_fieldManager:getFieldById(event.ploughFieldId or event.fieldId) or nil
    if field == nil then
        return
    end
    local width = frame.size / count
    local half = frame.size * 0.5
    local v1, v2 = -half + (from - 1) * width, -half + to * width
    local points = {}
    for _, corner in ipairs({ { 0, v1 }, { frame.size, v1 }, { frame.size, v2 }, { 0, v2 } }) do
        local x, z = TCShowScene.plotToWorld(frame, corner[1], corner[2])
        table.insert(points, { x = x, z = z })
    end
    TCFieldPreparation.paintPloughed(field, TCFieldPreparation.makeArea(points),
        MathUtil.getYRotationFromDirection(frame.dirX, frame.dirZ))
end

-- The store's models -----------------------------------------------------------------------------------

local function isStoreCandidate(storeItem)
    if storeItem.bundleInfo ~= nil or storeItem.showInStore == false or storeItem.xmlFilename == nil then
        return false
    end
    if StoreSpecies ~= nil and storeItem.species ~= nil and storeItem.species ~= StoreSpecies.VEHICLE then
        return false
    end
    if g_storeManager.getIsItemUnlocked ~= nil and not g_storeManager:getIsItemUnlocked(storeItem) then
        return false
    end
    return true
end

-- Whether a plough model turns over (its turn animation, in its own or its
-- first plough configuration), read from its file.
local function isReversible(xmlFilename)
    local xmlFile = loadXMLFile ~= nil and loadXMLFile("tcPloughModel", xmlFilename) or nil
    if xmlFile == nil or xmlFile == 0 then
        return false
    end
    local reversible = getXMLString(xmlFile, "vehicle.plow.rotationPart#turnAnimationName") ~= nil or
        getXMLString(xmlFile, "vehicle.plow.plowConfigurations.plowConfiguration(0).rotationPart#turnAnimationName") ~= nil
    delete(xmlFile)
    return reversible
end

-- The kit's models: { tractorXml, ploughXml }, or nil.
function ENGINE.pickKit()
    if g_storeManager == nil or g_vehicleTypeManager == nil then
        return nil
    end
    local ploughs = {}
    for _, storeItem in ipairs(g_storeManager:getItems()) do
        if isStoreCandidate(storeItem) then
            local vehicleType = g_vehicleTypeManager:getObjectTypeFromXML(storeItem.xmlFilename)
            local specs = vehicleType ~= nil and vehicleType.specializationsByName or nil
            if specs ~= nil and specs.plow ~= nil and specs.drivable == nil then
                if StoreItemUtil ~= nil and StoreItemUtil.loadSpecsFromXML ~= nil then
                    StoreItemUtil.loadSpecsFromXML(storeItem)
                end
                local storeSpecs = storeItem.specs or {}
                local width = storeSpecs.workingWidth ~= nil and storeSpecs.workingWidth.width or nil
                local joints = TheContractorFarmerFleet.getInputJointTypes(storeItem.xmlFilename) or {}
                table.insert(ploughs, {
                    xmlFilename = storeItem.xmlFilename,
                    width = width,
                    reversible = isReversible(storeItem.xmlFilename),
                    mounted = joints.implement == true,
                    neededPower = storeSpecs.neededPower ~= nil and storeSpecs.neededPower.base or nil,
                    price = storeItem.price or 0,
                    name = storeItem.name or storeItem.xmlFilename,
                })
            end
        end
    end
    local plough = TCPloughMatch.pickPlough(ploughs)
    if plough == nil then
        return nil
    end
    -- A mid-size tractor, or the other sizes on a map with none.
    local tractor = nil
    for _, categories in ipairs({ { "TRACTORSM" }, { "TRACTORSL", "TRACTORSS" } }) do
        local tractors = TheContractorCourtesyVehicle.getCandidates(categories)
        for i, candidate in ipairs(tractors) do
            tractors[i] = { power = candidate.power, price = candidate.price, name = candidate.name,
                xmlFilename = candidate.storeItem.xmlFilename }
        end
        tractor = tractor or TCPloughMatch.pickTractor(tractors, plough.neededPower)
    end
    if tractor == nil then
        return nil
    end
    TCLog.info("TheContractor: ploughing match kit: %s (%d hp) and %s (%.1f m%s)", tractor.name, tractor.power,
        plough.name, plough.width, plough.reversible and ", reversible" or "")
    return { tractorXml = tractor.xmlFilename, ploughXml = plough.xmlFilename }
end

-- Loading the kit ------------------------------------------------------------------------------------------

function ENGINE.spawnKit(match, number)
    table.insert(match.spawnQueue, number)
end

-- A machine's tanks full (its fuel, whichever it runs on, and AdBlue).
local function fillTanks(vehicle)
    if vehicle.getConsumerFillUnitIndex == nil then
        return
    end
    local fuels = TCJobSupplies.getDieselFillTypes()
    for _, name in ipairs({ "ELECTRICCHARGE", "METHANE", "DEF" }) do
        if FillType[name] ~= nil then
            table.insert(fuels, FillType[name])
        end
    end
    for _, fillType in ipairs(fuels) do
        local fillUnitIndex = vehicle:getConsumerFillUnitIndex(fillType)
        if fillUnitIndex ~= nil then
            local delta = vehicle:getFillUnitCapacity(fillUnitIndex) - vehicle:getFillUnitFillLevel(fillUnitIndex)
            if delta > 0 then
                vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), fillUnitIndex, delta, fillType,
                    ToolType.UNDEFINED, nil)
            end
        end
    end
end

local function newLoadingData(storeItem, x, z, yaw)
    local loadingData = VehicleLoadingData.new()
    loadingData:setStoreItem(storeItem)
    TCStoreConfigurations.apply(loadingData, storeItem)
    loadingData:setPosition(x, nil, z, TCParking.PLACE_HEIGHT_OFFSET)
    loadingData:setRotation(0, yaw, 0)
    loadingData:setPropertyState(VehiclePropertyState.MISSION)
    loadingData:setOwnerFarmId(AccessHandler.EVERYONE)
    return loadingData
end

local function deleteAll(vehicles)
    for _, vehicle in ipairs(vehicles or {}) do
        if vehicle ~= nil and not vehicle.isDeleted then
            vehicle:delete()
        end
    end
end

-- Every frame (server): the next plot's kit, one at a time: the tractor
-- inside the plot at its near edge, facing in; then the plough behind it,
-- hitched on.
function ENGINE.processSpawnQueue(match)
    if match.loading ~= nil or #match.spawnQueue == 0 or VehicleLoadingData == nil then
        return
    end
    local number = table.remove(match.spawnQueue, 1)
    local frame = match:getFrame(number)
    local models = match.kitModels
    local tractorItem = models ~= nil and g_storeManager:getItemByXMLFilename(models.tractorXml) or nil
    if frame == nil or tractorItem == nil then
        return
    end
    local x, z = TCShowScene.plotToWorld(frame, TCPloughMatch.KIT_U, 0)
    local yaw = MathUtil.getYRotationFromDirection(frame.dirX, frame.dirZ)
    match.loading = { number = number, showId = match.showId }
    newLoadingData(tractorItem, x, z, yaw):load(ENGINE.onTractorLoaded, nil,
        { match = match, loading = match.loading, frame = frame })
end

function ENGINE.onTractorLoaded(_, vehicles, loadingState, args)
    local match, loading = args.match, args.loading
    local tractor = vehicles ~= nil and vehicles[1] or nil
    if match.loading ~= loading or match.showId ~= loading.showId then
        deleteAll(vehicles)
        return
    end
    if tractor == nil or loadingState ~= VehicleLoadingState.OK then
        TCLog.warning("TheContractor: ploughing plot %d's tractor didn't load", loading.number)
        deleteAll(vehicles)
        match.loading = nil
        return
    end
    fillTanks(tractor)
    local ploughItem = g_storeManager:getItemByXMLFilename(match.kitModels.ploughXml)
    if ploughItem == nil then
        match.loading = nil
        match:onKitSpawned(loading.number, NetworkUtil.getObjectId(tractor), nil)
        return
    end
    local frame = args.frame
    local x, z = TCShowScene.plotToWorld(frame, TCPloughMatch.KIT_U - 8, 0)
    newLoadingData(ploughItem, x, z, MathUtil.getYRotationFromDirection(frame.dirX, frame.dirZ)):load(
        ENGINE.onPloughLoaded, nil, { match = match, loading = loading, tractor = tractor })
end

function ENGINE.onPloughLoaded(_, vehicles, loadingState, args)
    local match, loading, tractor = args.match, args.loading, args.tractor
    local plough = vehicles ~= nil and vehicles[1] or nil
    if match.loading ~= loading or match.showId ~= loading.showId then
        deleteAll(vehicles)
        deleteAll({ tractor })
        return
    end
    match.loading = nil
    if plough == nil or loadingState ~= VehicleLoadingState.OK then
        TCLog.warning("TheContractor: ploughing plot %d's plough didn't load", loading.number)
        deleteAll(vehicles)
        match:onKitSpawned(loading.number, NetworkUtil.getObjectId(tractor), nil)
        return
    end
    -- Attaching asks whether a farm may: any real farm may, the kit being
    -- everyone's (farm 0 is the spectators', who mayn't).
    if not TCJobSiteSetup.hitchImplement(tractor, plough, FarmManager.SINGLEPLAYER_FARM_ID) then
        TCLog.warning("TheContractor: ploughing plot %d's plough couldn't be hitched", loading.number)
    end
    match:onKitSpawned(loading.number, NetworkUtil.getObjectId(tractor), NetworkUtil.getObjectId(plough))
end

-- Console --------------------------------------------------------------------------------------------------

local function describePlotWho(plot)
    local who = TheContractorPloughingMatch.getPlotWho(plot)
    if plot.farmId > 0 and (plot.workerId or 0) > 0 then
        return string.format("farm %d's worker %d (%s)", plot.farmId, plot.workerId, who or "?")
    elseif plot.farmId > 0 then
        return string.format("farm %d (%s)", plot.farmId, who or "?")
    elseif plot.farmerId > 0 then
        return string.format("farmer %d (%s)", plot.farmerId, who or "?")
    end
    return "nobody"
end

-- tcShow plots: the plots, who's on each and the scores (live while a run's
-- on). The console runs on the server, which has them all.
function TheContractorPloughingMatch:describePlots()
    if self.showId == nil or #self.plots == 0 then
        return "There's no ploughing match out: the plots are set out at midnight before the show's day."
    end
    local phase = "before 11:00"
    if self.resultsGiven then
        phase = "results given"
    elseif self.over then
        phase = "over"
    elseif self.started then
        phase = "on"
    end
    local lines = { string.format("Show %d's ploughing match (%s), %d plots:", self.showId, phase, #self.plots) }
    for _, plot in ipairs(self.plots) do
        local run = self.runs[plot.number]
        local score = "-"
        local card = plot.card or (run ~= nil and run.result or nil)
        if card ~= nil then
            score = string.format("%.1f%s", card.total,
                (plot.state == STATE.FARMER or (plot.workerId or 0) > 0) and " (rolled)" or "")
        elseif plot.state == STATE.TAKEN and (plot.workerId or 0) > 0 then
            score = "worker not started"
        elseif plot.state == STATE.TAKEN and self.started and g_currentMission:getIsServer() then
            local live = self:measure(plot.number)
            score = live ~= nil and string.format("%.1f so far", live.total) or "-"
        end
        local minutes = run ~= nil and TCPloughMatch.getMinutesUsed(run.firstMinute, run.lastMinute) or nil
        table.insert(lines, string.format("  plot %d: %s, %s, kit %s, %s%s%s", plot.number, plot.state,
            describePlotWho(plot), plot.tractorId ~= nil and "out" or "not out", score,
            minutes ~= nil and string.format(", %.0f game min", minutes) or "",
            card ~= nil and card.placing ~= nil and string.format(", placed %d", card.placing) or ""))
    end
    return table.concat(lines, "\n")
end

function TheContractorPloughingMatch.registerConsoleCommands()
    TCConsole.register("show", "plots", {
        description = "The show's ploughing plots: who's on each, its kit, and the scores (live while a run's on)",
        serverOnly = false,
        run = function()
            return g_currentMission.TheContractor.PloughingMatch:describePlots()
        end,
    })

    TCConsole.register("debug", "showMatch", {
        args = "<start|end>",
        description = "Start the show's ploughing match now, or end it now (every run scored), on the show's day",
        run = function(_, args)
            local action = args[1] ~= nil and string.lower(args[1]) or nil
            if (action ~= "start" and action ~= "end") or args[2] ~= nil then
                return false
            end
            local tc = g_currentMission.TheContractor
            local match = tc.PloughingMatch
            if not match.setOut then
                return "The plots aren't out: 'tcDebug showDay' sets the show out today."
            end
            if action == "start" then
                match:startMatch()
            else
                match:endMatch()
            end
            return match:describePlots()
        end,
    })
end
