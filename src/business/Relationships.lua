-- Relationships (113): how each farmer, and the local official (110), feel
-- about working with a farm. Overall reputation (007) is the farm's standing
-- in the trade, what people who don't know it have heard; a relationship is
-- one customer's own history with it, and decides who offers work and how
-- they haggle.
--
-- A score per farm and customer, MIN_SCORE..MAX_SCORE, 0 to start (nothing
-- stored). Server-authoritative like reputation: adjust() clamps, applies
-- and broadcasts the absolute score in a TCRelationshipChangedEvent.
--
-- What moves it (the job's customer, job.customerId; a workshop job has
-- none, so nothing does):
--   completed       COMPLETED_GAIN times the quality factor (080), as
--                   reputation, so poor work loses it
--   missed (024)    MISSED_LOSS, less the share already done, never less
--                   than MIN_MISSED_LOSS
--   declined        DECLINED_LOSS
--   lapsed          LAPSED_LOSS (left unanswered to its deadline)
--   walked away     WALKED_AWAY_LOSS (014: they refused the counter-offer)
--   pursued (053)   PURSUED_LOSS (an overdue invoice handed to the lawyers)
-- None of these touch overall reputation beyond what they already did.
--
-- Every month each score drifts DRIFT_PER_MONTH back towards 0, both ways:
-- a grudge fades, and goodwill needs repeat work to last.
--
-- Effects:
--   generation (011)   a field's customer weights its pick (getOfferWeight),
--                      and one below REFUSES_BELOW offers nothing (refuses)
--   negotiation (014)  a good relationship gives more room on a counter-offer
--                      (getToleranceFactor)
-- The People tab's Others view and an offer's From and Customer rows show
-- the band (getBand) as a chip.
--
-- 129: when it goes bad (server):
--   a complaint       a missed job, or one completed under COMPLAINT_QUALITY,
--                     that leaves the customer in the poor band posts a
--                     message from them (COMPLAINT_KIND), no more than one a
--                     customer per COMPLAINT_COOLDOWN months for each farm
--                     (lastComplaints, saved, never streamed). A warning
--                     only: it does nothing else.
--   word gets round   a customer falling out (crossing REFUSES_BELOW, for
--                     any reason but word itself, so it never cascades)
--                     costs each of their neighbours (Farmers.getNeighbours)
--                     WORD_RELATIONSHIP and the farm WORD_REPUTATION, and
--                     posts a notice naming them (WORD_KIND).

TheContractorRelationships = {}
TheContractorRelationships_mt = Class(TheContractorRelationships)

TheContractorRelationships.MIN_SCORE = -100
TheContractorRelationships.MAX_SCORE = 100

TheContractorRelationships.COMPLETED_GAIN = 10
TheContractorRelationships.MISSED_LOSS = 30
TheContractorRelationships.MIN_MISSED_LOSS = 10
TheContractorRelationships.DECLINED_LOSS = 3
TheContractorRelationships.LAPSED_LOSS = 5
TheContractorRelationships.WALKED_AWAY_LOSS = 3
TheContractorRelationships.PURSUED_LOSS = 15

TheContractorRelationships.DRIFT_PER_MONTH = 5

-- Below this a customer offers no work until the drift brings them back.
TheContractorRelationships.REFUSES_BELOW = -40

-- A field's pick weight (011) runs from MIN_OFFER_WEIGHT at MIN_SCORE through
-- 1 at 0 to MAX_OFFER_WEIGHT at MAX_SCORE.
TheContractorRelationships.MIN_OFFER_WEIGHT = 0.25
TheContractorRelationships.MAX_OFFER_WEIGHT = 3

-- Negotiation tolerance (014) is scaled by 1 +/- this at MAX/MIN_SCORE.
TheContractorRelationships.TOLERANCE_SWING = 0.5

-- 129: a job completed under this quality score (080) can bring a complaint.
TheContractorRelationships.COMPLAINT_QUALITY = 50
-- Months before the same customer complains to the same farm again.
TheContractorRelationships.COMPLAINT_COOLDOWN = 1
-- Each complaint body's variants (tc_complaint_body_<cause>_<n>).
TheContractorRelationships.COMPLAINT_VARIANTS = 3
TheContractorRelationships.COMPLAINT_CAUSE = {
    MISSED = "missed",
    POOR_WORK = "poorWork",
}
TheContractorRelationships.COMPLAINT_KIND = "complaint"

-- 129: what a customer falling out costs with each neighbour, and in
-- overall reputation (007).
TheContractorRelationships.WORD_RELATIONSHIP = 5
TheContractorRelationships.WORD_REPUTATION = 15
TheContractorRelationships.WORD_REASON = "word"
TheContractorRelationships.WORD_KIND = "wordGetsRound"

-- How an offer ended without being taken (Jobs:onJobDeclined).
TheContractorRelationships.DECLINE_REASON = {
    DECLINED = "declined",
    LAPSED = "lapsed",
    WALKED_AWAY = "walkedAway",
}

-- The bands shown on the chip, highest first: the first whose minScore the
-- score reaches. The last is the refusing band (below REFUSES_BELOW).
TheContractorRelationships.BANDS = {
    { key = "excellent", minScore = 50, tone = "good" },
    { key = "good", minScore = 15, tone = "good" },
    { key = "neutral", minScore = -14, tone = "neutral" },
    { key = "poor", minScore = TheContractorRelationships.REFUSES_BELOW, tone = "warn" },
    { key = "fallenOut", minScore = -math.huge, tone = "bad" },
}

function TheContractorRelationships.new()
    local self = {}
    setmetatable(self, TheContractorRelationships_mt)

    -- farmId -> customerId -> score (never 0: a neutral score isn't kept).
    self.scores = {}
    -- 129, server: farmId -> customerId -> the period index of their last
    -- complaint.
    self.lastComplaints = {}

    return self
end

-- Every machine, at load (129).
function TheContractorRelationships:registerMessageKinds(inbox)
    inbox:registerMessageKind(TheContractorRelationships.COMPLAINT_KIND, {
        category = "feedback",
        chipTone = "warn",
        fromFarmer = true,
        getArgs = function(message)
            return TheContractorRelationships.getComplaintArgs(message)
        end,
    })
    inbox:registerMessageKind(TheContractorRelationships.WORD_KIND, {
        category = "feedback",
        chipTone = "warn",
    })
end

-- A complaint's args (client): the customer's name as it is now, then the
-- job's place.
function TheContractorRelationships.getComplaintArgs(message)
    local farmers = g_currentMission.TheContractor.Farmers
    local person = farmers ~= nil and farmers:getPerson(message.payload.farmerId) or nil
    return { person ~= nil and person.name or g_i18n:getText("tc_inbox_customerUnknown"), message.args[1] or "" }
end

-- Queries (every machine) -------------------------------------------------------

-- A farm's score with a customer, MIN_SCORE..MAX_SCORE, 0 if nothing's stored.
--
-- PUBLIC API: another mod calls this, through
-- g_currentMission.TheContractor.Relationships:getScore(farmId, farmer.id),
-- with the farmer from Farmers:getHolder. Any edit must stay backwards
-- compatible: keep the name, the access path, the arguments (a farm id and a
-- person id), a number back on every machine (0 for an unknown pair or a nil
-- id, never nil) and the -100..100 range. Add, never change.
function TheContractorRelationships:getScore(farmId, customerId)
    local farmScores = self.scores[farmId]
    return farmScores ~= nil and customerId ~= nil and farmScores[customerId] or 0
end

function TheContractorRelationships.getBand(score)
    for _, band in ipairs(TheContractorRelationships.BANDS) do
        if score >= band.minScore then
            return band
        end
    end
    return TheContractorRelationships.BANDS[#TheContractorRelationships.BANDS]
end

-- The chip for a farm's relationship with a customer: text and tone.
function TheContractorRelationships:getChip(farmId, customerId)
    local band = TheContractorRelationships.getBand(self:getScore(farmId, customerId))
    return g_i18n:getText("tc_relationship_" .. band.key), band.tone
end

function TheContractorRelationships:refuses(farmId, customerId)
    return customerId ~= nil and self:getScore(farmId, customerId) < TheContractorRelationships.REFUSES_BELOW
end

-- A field's weight in 011's pick for its customer: 0 if they refuse.
function TheContractorRelationships:getOfferWeight(farmId, customerId)
    if self:refuses(farmId, customerId) then
        return 0
    end
    local T = TheContractorRelationships
    local score = self:getScore(farmId, customerId)
    if score >= 0 then
        return 1 + score / T.MAX_SCORE * (T.MAX_OFFER_WEIGHT - 1)
    end
    return 1 + score / -T.MIN_SCORE * (1 - T.MIN_OFFER_WEIGHT)
end

-- 014's tolerance for a job is multiplied by this.
function TheContractorRelationships:getToleranceFactor(job)
    local score = self:getScore(job.farmId, job.customerId)
    return 1 + score / TheContractorRelationships.MAX_SCORE * TheContractorRelationships.TOLERANCE_SWING
end

-- Changes (server) ---------------------------------------------------------------

-- Server: moves a farm's relationship with a customer by delta (rounded,
-- clamped) and tells the clients. Returns the new score.
function TheContractorRelationships:adjust(farmId, customerId, delta, reason)
    local score = self:getScore(farmId, customerId)
    if not g_currentMission:getIsServer() or customerId == nil then
        return score
    end
    local T = TheContractorRelationships
    local rounded = delta >= 0 and math.floor(delta + 0.5) or -math.floor(-delta + 0.5)
    local newScore = math.max(T.MIN_SCORE, math.min(T.MAX_SCORE, score + rounded))
    if newScore == score then
        return score
    end

    TCLog.info("TheContractor: farm %d relationship with person %d %d -> %d (%s)", farmId, customerId, score,
        newScore, reason or "?")
    self:applyScore(farmId, customerId, newScore)
    if g_server ~= nil then
        g_server:broadcastEvent(TCRelationshipChangedEvent.new(farmId, customerId, newScore))
    end
    -- 129: they've fallen out, and tell the neighbours.
    if reason ~= T.WORD_REASON and score >= T.REFUSES_BELOW and newScore < T.REFUSES_BELOW then
        self:spreadWord(farmId, customerId)
    end
    return newScore
end

-- Every machine: the score lands.
function TheContractorRelationships:applyScore(farmId, customerId, score)
    if score == 0 then
        if self.scores[farmId] ~= nil then
            self.scores[farmId][customerId] = nil
        end
    else
        self.scores[farmId] = self.scores[farmId] or {}
        self.scores[farmId][customerId] = score
    end
    local menu = g_currentMission.TheContractor.MenuContractor
    if menu ~= nil and menu.onPeopleChanged ~= nil and farmId == g_currentMission:getFarmId() then
        menu:onPeopleChanged()
    end
end

-- Server, from Jobs:completeJob once the quality score is set (080).
function TheContractorRelationships:onJobCompleted(job)
    local factor = TheContractorJobs.getQualityReputationFactor(job.qualityScore or 100)
    self:adjust(job.farmId, job.customerId, TheContractorRelationships.COMPLETED_GAIN * factor, "completed")
    if (job.qualityScore or 100) < TheContractorRelationships.COMPLAINT_QUALITY then
        self:checkComplaint(job, TheContractorRelationships.COMPLAINT_CAUSE.POOR_WORK)
    end
end

-- Server, from Jobs:missJob: less the share of the work already done.
function TheContractorRelationships:onJobMissed(job)
    local T = TheContractorRelationships
    local loss = math.max(T.MIN_MISSED_LOSS, T.MISSED_LOSS * (1 - (job.completionPercentage or 0) / 100))
    self:adjust(job.farmId, job.customerId, -loss, "missed")
    self:checkComplaint(job, T.COMPLAINT_CAUSE.MISSED)
end

-- Server, from Jobs:onJobDeclined. reason: a DECLINE_REASON (nil: declined).
function TheContractorRelationships:onJobDeclined(job, reason)
    local T = TheContractorRelationships
    local loss = T.DECLINED_LOSS
    if reason == T.DECLINE_REASON.LAPSED then
        loss = T.LAPSED_LOSS
    elseif reason == T.DECLINE_REASON.WALKED_AWAY then
        loss = T.WALKED_AWAY_LOSS
    end
    self:adjust(job.farmId, job.customerId, -loss, reason or T.DECLINE_REASON.DECLINED)
end

-- Server, from Finances:requestPursuit (053): the invoice's job's customer.
function TheContractorRelationships:onInvoicePursued(farmId, job)
    if job ~= nil then
        self:adjust(farmId, job.customerId, -TheContractorRelationships.PURSUED_LOSS, "pursued")
    end
end

-- When it goes bad (129, server) ---------------------------------------------------

function TheContractorRelationships:getLastComplaintPeriod(farmId, customerId)
    local farmComplaints = self.lastComplaints[farmId]
    return farmComplaints ~= nil and farmComplaints[customerId] or nil
end

-- Whether a farm's customer, at their score now, may complain this month.
function TheContractorRelationships:canComplain(farmId, customerId)
    if customerId == nil or TheContractorRelationships.getBand(self:getScore(farmId, customerId)).key ~= "poor" then
        return false
    end
    local last = self:getLastComplaintPeriod(farmId, customerId)
    return last == nil or TCCalendar.getPeriodIndex() >= last + TheContractorRelationships.COMPLAINT_COOLDOWN
end

-- After a job's change has landed: the customer complains if they're now
-- in the poor band and haven't lately. cause: a COMPLAINT_CAUSE.
function TheContractorRelationships:checkComplaint(job, cause)
    local T = TheContractorRelationships
    if not g_currentMission:getIsServer() or not self:canComplain(job.farmId, job.customerId) then
        return
    end
    local periodIndex = TCCalendar.getPeriodIndex()
    self.lastComplaints[job.farmId] = self.lastComplaints[job.farmId] or {}
    self.lastComplaints[job.farmId][job.customerId] = periodIndex
    local bodyKey = string.format("tc_complaint_body_%s_%d", cause, math.random(1, T.COMPLAINT_VARIANTS))
    TCLog.info("TheContractor: farm %d: person %d complains about job %d (%s)", job.farmId, job.customerId, job.id,
        cause)
    g_currentMission.TheContractor.Inbox:postMessage(job.farmId, T.COMPLAINT_KIND, "tc_complaint_title", bodyKey,
        { job:getLocationText() }, nil, { farmerId = job.customerId })
end

-- A customer has just fallen out with a farm: each of their neighbours
-- thinks less of it, so does the trade, and the farm hears about it.
function TheContractorRelationships:spreadWord(farmId, customerId)
    local T = TheContractorRelationships
    local tc = g_currentMission.TheContractor
    local person = tc.Farmers ~= nil and tc.Farmers:getPerson(customerId) or nil
    if person == nil then
        return
    end
    local neighbours = TheContractorFarmers.getNeighbours(tc.Farmers:getFarmers(), person,
        TheContractorFarmers.getLand(), TheContractorFarmers.getFreeYards())
    local names = {}
    for _, neighbour in ipairs(neighbours) do
        self:adjust(farmId, neighbour.id, -T.WORD_RELATIONSHIP, T.WORD_REASON)
        table.insert(names, neighbour.name)
    end
    tc.Reputation:addReputation(farmId, -T.WORD_REPUTATION)
    TCLog.info("TheContractor: farm %d: person %d has fallen out and told %d neighbours", farmId, customerId,
        #neighbours)

    local bodyKey = #names > 0 and "tc_wordGetsRound_body" or "tc_wordGetsRound_bodyNoNeighbours"
    tc.Inbox:postMessage(farmId, T.WORD_KIND, "tc_wordGetsRound_title", bodyKey,
        { person.name, table.concat(names, ", ") })
end

-- Server: every score a step nearer 0.
function TheContractorRelationships:drift()
    local step = TheContractorRelationships.DRIFT_PER_MONTH
    local changes = {}
    for farmId, farmScores in pairs(self.scores) do
        for customerId, score in pairs(farmScores) do
            local delta = score > 0 and -math.min(step, score) or math.min(step, -score)
            table.insert(changes, { farmId = farmId, customerId = customerId, delta = delta })
        end
    end
    for _, change in ipairs(changes) do
        self:adjust(change.farmId, change.customerId, change.delta, "drift")
    end
end

function TheContractorRelationships:startPeriodTick()
    if g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.drift, self)
    end
end

function TheContractorRelationships:stopPeriodTick()
    g_messageCenter:unsubscribe(MessageType.PERIOD_CHANGED, self)
end

-- Every machine, from Company:applyCompanyCreation: a new company starts
-- with nobody's opinion.
function TheContractorRelationships:reset(farmId)
    self.scores[farmId] = nil
    self.lastComplaints[farmId] = nil
end

-- Every machine, when the farmers are made again (110's regenerate): the
-- old farmers' scores go. people: id -> person.
function TheContractorRelationships:forgetMissing(people)
    for _, farmScores in pairs(self.scores) do
        for customerId in pairs(farmScores) do
            if people[customerId] == nil then
                farmScores[customerId] = nil
            end
        end
    end
    for _, farmComplaints in pairs(self.lastComplaints) do
        for customerId in pairs(farmComplaints) do
            if people[customerId] == nil then
                farmComplaints[customerId] = nil
            end
        end
    end
end

-- Half a score, rounded towards 0.
function TheContractorRelationships.getInheritedScore(score)
    if score >= 0 then
        return math.floor(score / 2)
    end
    return -math.floor(-score / 2)
end

-- Every machine, from 128's retirement: a successor starts at half the old
-- farmer's score with each farm (they know the family's contractor, but
-- not as well), and the old farmer's scores go. Every machine holds the
-- same scores, so nothing needs sending.
function TheContractorRelationships:inheritScores(oldId, newId)
    for _, farmScores in pairs(self.scores) do
        local score = farmScores[oldId]
        if score ~= nil then
            farmScores[oldId] = nil
            local inherited = TheContractorRelationships.getInheritedScore(score)
            farmScores[newId] = inherited ~= 0 and inherited or nil
        end
    end
    -- 129: a successor hasn't complained yet.
    for _, farmComplaints in pairs(self.lastComplaints) do
        farmComplaints[oldId] = nil
    end
end

-- Persistence -------------------------------------------------------------------

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorRelationships:forgetFarm(farmId)
    self.scores[farmId] = nil
    self.lastComplaints[farmId] = nil
end

function TheContractorRelationships:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.scores = {}
    local i = 0
    while true do
        local key = string.format("%s.relationships.relationship(%d)", TheContractor.SaveKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        local customerId = getXMLInt(xmlFile, key .. "#personId")
        local score = getXMLInt(xmlFile, key .. "#score")
        if farmId ~= nil and customerId ~= nil and score ~= nil and score ~= 0 then
            self.scores[farmId] = self.scores[farmId] or {}
            self.scores[farmId][customerId] = score
        end
        i = i + 1
    end

    self.lastComplaints = {}
    i = 0
    while true do
        local key = string.format("%s.relationships.complaint(%d)", TheContractor.SaveKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        local customerId = getXMLInt(xmlFile, key .. "#personId")
        local period = getXMLInt(xmlFile, key .. "#period")
        if farmId ~= nil and customerId ~= nil and period ~= nil then
            self.lastComplaints[farmId] = self.lastComplaints[farmId] or {}
            self.lastComplaints[farmId][customerId] = period
        end
        i = i + 1
    end
end

-- In farm then person order, so the file doesn't reshuffle every save.
function TheContractorRelationships:getSortedEntries()
    local entries = {}
    for farmId, farmScores in pairs(self.scores) do
        for customerId, score in pairs(farmScores) do
            table.insert(entries, { farmId = farmId, customerId = customerId, score = score })
        end
    end
    table.sort(entries, function(a, b)
        if a.farmId ~= b.farmId then
            return a.farmId < b.farmId
        end
        return a.customerId < b.customerId
    end)
    return entries
end

-- 129: the last complaints, in the same order.
function TheContractorRelationships:getSortedComplaints()
    local entries = {}
    for farmId, farmComplaints in pairs(self.lastComplaints) do
        for customerId, period in pairs(farmComplaints) do
            table.insert(entries, { farmId = farmId, customerId = customerId, period = period })
        end
    end
    table.sort(entries, function(a, b)
        if a.farmId ~= b.farmId then
            return a.farmId < b.farmId
        end
        return a.customerId < b.customerId
    end)
    return entries
end

function TheContractorRelationships:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    for i, entry in ipairs(self:getSortedEntries()) do
        local key = string.format("%s.relationships.relationship(%d)", TheContractor.SaveKey, i - 1)
        setXMLInt(xmlFile, key .. "#farmId", entry.farmId)
        setXMLInt(xmlFile, key .. "#personId", entry.customerId)
        setXMLInt(xmlFile, key .. "#score", entry.score)
    end
    for i, entry in ipairs(self:getSortedComplaints()) do
        local key = string.format("%s.relationships.complaint(%d)", TheContractor.SaveKey, i - 1)
        setXMLInt(xmlFile, key .. "#farmId", entry.farmId)
        setXMLInt(xmlFile, key .. "#personId", entry.customerId)
        setXMLInt(xmlFile, key .. "#period", entry.period)
    end
end

function TheContractorRelationships:writeInitialClientState(streamId, connection)
    local entries = self:getSortedEntries()
    streamWriteInt32(streamId, #entries)
    for _, entry in ipairs(entries) do
        streamWriteInt32(streamId, entry.farmId)
        streamWriteInt32(streamId, entry.customerId)
        streamWriteInt32(streamId, entry.score)
    end
end

function TheContractorRelationships:readInitialClientState(streamId, connection)
    self.scores = {}
    for _ = 1, streamReadInt32(streamId) do
        local farmId = streamReadInt32(streamId)
        local customerId = streamReadInt32(streamId)
        local score = streamReadInt32(streamId)
        self.scores[farmId] = self.scores[farmId] or {}
        self.scores[farmId][customerId] = score
    end
end

-- Console (tcFarmer) -----------------------------------------------------------

-- A person by id or name (case-insensitive), or nil.
local function findPerson(text)
    local farmers = g_currentMission.TheContractor.Farmers
    local id = tonumber(text)
    if id ~= nil then
        return farmers:getPerson(id)
    end
    local wanted = string.lower(text)
    for _, person in pairs(farmers.people) do
        if string.lower(person.name) == wanted then
            return person
        end
    end
    return nil
end

function TheContractorRelationships:getListText(farmId)
    local farmers = g_currentMission.TheContractor.Farmers
    if not farmers:hasGenerated() then
        return "No farmers yet: they're made on the server once the map has loaded."
    end
    local people = farmers:getFarmers()
    table.insert(people, 1, farmers:getOfficial())
    local lines = { string.format("Farm %d's relationships (%d to %d, refusing work below %d):", farmId,
        TheContractorRelationships.MIN_SCORE, TheContractorRelationships.MAX_SCORE,
        TheContractorRelationships.REFUSES_BELOW) }
    for _, person in ipairs(people) do
        local score = self:getScore(farmId, person.id)
        table.insert(lines, string.format("  #%d %s%s: %d (%s)", person.id, person.name,
            person.isOfficial and " (local official)" or "", score,
            TheContractorRelationships.getBand(score).key))
    end
    return table.concat(lines, "\n")
end

function TheContractorRelationships.registerConsoleCommands()
    TCConsole.register("farmer", "relationships", {
        description = "Your farm's relationship with each farmer and the local official",
        serverOnly = false,
        run = function(farmId)
            return g_currentMission.TheContractor.Relationships:getListText(farmId)
        end,
    })

    -- Through adjust, so word gets round as it would in the game.
    TCConsole.register("farmer", "relationship", {
        args = "<farmer> <amount>",
        description = "Change your farm's relationship with a farmer or the official by an amount (can be negative)",
        hints = { farmer = "a farmer's or the official's id or full name (tcFarmer relationships)" },
        run = function(farmId, args)
            local amount = tonumber(args[#args])
            if #args < 2 or amount == nil then
                return false
            end
            local name = table.concat(args, " ", 1, #args - 1)
            local person = findPerson(name)
            if person == nil then
                return string.format("No farmer or official called %s (tcFarmer relationships lists them).", name)
            end
            local score = g_currentMission.TheContractor.Relationships:adjust(farmId, person.id, amount, "console")
            return string.format("Farm %d's relationship with %s is now %d (%s).", farmId, person.name, score,
                TheContractorRelationships.getBand(score).key)
        end,
    })
end
