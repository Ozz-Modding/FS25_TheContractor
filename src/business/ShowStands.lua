-- The show's stands and the farmers about the showground (171). The rules
-- and numbers are TCShowStands' (src/util/TCShowStands.lua); the people on
-- the showground and the conversations are TCShowStandsWorld's. This holds
-- who's been where, and does what a visit does, on the server:
--
--   The trade association's stall: a company that isn't a member can join
--     on the day, its first term TCShowStands.JOIN_DISCOUNT off (053's
--     membership through tc.Overheads:startPolicy, priced through
--     Settings:scaleCost as any overhead). A member gets a cup of tea.
--   The careers stand: once a farm per show, a few young candidates kept
--     for the farm for a week (Staff:addKeptCandidates).
--   Farmers: talking to one at the show the first time lifts their opinion
--     a little; "any work going?" rolls once a farm per farmer per show for
--     an offer from their fields (JobGeneration:generateForFarm with the
--     farmer, offer source OFFER_SOURCE), as their yard would (130).
--   The attend job done (Show:onAttended): the host's opinion lifted.
--   None of the opinion lifts lets word get round (129's WORD_REASON).
--
-- A competition of the show's that places nobody (registerCompetition), for
-- its hooks. Every machine holds the show the visits are for and the
-- visits, { farmId -> { attended, joined, careers, talked = { personId ->
-- true }, asked = { personId -> true } } }, kept until the next show's
-- announced so the Show tab can say what was done. Saved in
-- TheContractor.xml (.showStands), in the initial client state and sent
-- whole (TCShowStandsEvent). Visits hold farms (forgetFarm) and farmers
-- (replacePerson, through the show). Nothing's a date. Tested in
-- tests/test_showStands.lua.

TheContractorShowStands = {}
TheContractorShowStands_mt = Class(TheContractorShowStands)

TheContractorShowStands.KEY = "stands"
TheContractorShowStands.SAVE_KEY = "showStands"
TheContractorShowStands.TITLE_KEY = "tc_showStands_title"
-- Job.offerSource for an offer asked for at the show.
TheContractorShowStands.OFFER_SOURCE = "show"

local REQUEST = TCShowStands.REQUEST
local ANSWER = TCShowStands.ANSWER

function TheContractorShowStands.new()
    local self = setmetatable({}, TheContractorShowStands_mt)
    self.showId = nil
    self.visits = {}
    -- Server: the rolls (the tests swap them). random() in [0, 1), and
    -- randomInt(a, b) as math.random's.
    self.random = math.random
    self.randomInt = math.random
    return self
end

-- Every machine, at load.
function TheContractorShowStands:register(show)
    show:registerCompetition(TheContractorShowStands.KEY, {
        titleKey = TheContractorShowStands.TITLE_KEY,
        onAnnounced = function(event)
            self:reset(event.id)
        end,
        onAttended = function(event, farmId)
            self:onAttended(event, farmId)
        end,
        onCancelled = function()
            self:reset(nil)
        end,
        replacePerson = function(oldId, newId)
            return self:replacePerson(oldId, newId)
        end,
    })
end

local function getTC()
    return g_currentMission ~= nil and g_currentMission.TheContractor or nil
end

local function getShowEvent()
    local tc = getTC()
    return tc ~= nil and tc.Show ~= nil and tc.Show:getEvent() or nil
end

local function getToday()
    return g_currentMission.environment.currentMonotonicDay
end

-- The hour of the day on this machine, minutes as a fraction.
local function getHour()
    local environment = g_currentMission.environment
    if environment.dayTime ~= nil then
        return environment.dayTime / 3600000
    end
    return environment.currentHour or 0
end

-- Server: starts again for a show (nil: none).
function TheContractorShowStands:reset(showId)
    self.showId = showId
    self.visits = {}
    self:sync()
end

-- Queries (every machine) ------------------------------------------------------------------

-- The show's scene, while its showground's laid out (nil otherwise).
function TheContractorShowStands:getScene()
    local tc = getTC()
    local site = tc ~= nil and tc.AuctionSite or nil
    local scene = site ~= nil and site:getScene() or nil
    if scene == nil or not TCShowScene.isShowDressing(scene) then
        return nil
    end
    return scene
end

-- Whether the stands are open now: the show's day in its hours, with its
-- showground out.
function TheContractorShowStands:isOpen()
    local event = getShowEvent()
    return self:getScene() ~= nil and TCShowStands.isOpen(event, getToday(), getHour(), TheContractorShow.START_HOUR,
        TheContractorShow.END_HOUR)
end

-- The farmers at the show (ids, the host first): never one ploughing a plot
-- (169), nor 188's breeders. Empty with no show.
function TheContractorShowStands:getFarmersAtShow()
    local tc = getTC()
    local event = getShowEvent()
    if event == nil or tc.Farmers == nil then
        return {}
    end
    local excluded = {}
    local match = tc.PloughingMatch
    for _, plot in ipairs(match ~= nil and match.plots or {}) do
        if (plot.farmerId or 0) > 0 then
            excluded[plot.farmerId] = true
        end
    end
    -- 188: nor the breeders, who're at their pens.
    local pen = tc.BreedersPen
    for _, id in ipairs(pen ~= nil and pen:getBreederIds() or {}) do
        excluded[id] = true
    end
    return TCShowStands.pickFarmers(event.id, tc.Farmers:getFarmers(), event.hostFarmerId, excluded)
end

-- Whether a farmer's at the show now.
function TheContractorShowStands:isAtShow(personId)
    if personId == nil or not self:isOpen() then
        return false
    end
    for _, id in ipairs(self:getFarmersAtShow()) do
        if id == personId then
            return true
        end
    end
    return false
end

-- A farm's visit for this show (nil: none yet).
function TheContractorShowStands:getVisit(farmId)
    local event = getShowEvent()
    if event == nil or self.showId ~= event.id then
        return nil
    end
    return self.visits[farmId]
end

-- The last show's visit, whichever show it was (the Show tab after the day).
function TheContractorShowStands:getLastVisit(farmId)
    return self.visits[farmId]
end

function TheContractorShowStands:hasTalked(farmId, personId)
    local visit = self:getVisit(farmId)
    return visit ~= nil and visit.talked[personId] == true
end

function TheContractorShowStands:hasAsked(farmId, personId)
    local visit = self:getVisit(farmId)
    return visit ~= nil and visit.asked[personId] == true
end

function TheContractorShowStands:hasVisitedCareers(farmId)
    local visit = self:getVisit(farmId)
    return visit ~= nil and visit.careers == true
end

-- What joining the association at the show costs now (every machine):
-- the first charge by billing, its first term JOIN_DISCOUNT off.
function TheContractorShowStands.getJoinCharge(farmId, billing)
    local overheads = getTC().Overheads
    local definition = overheads:getDefinition(TheContractorAssociation.MEMBERSHIP_KEY)
    if definition == nil then
        return 0
    end
    local annual = overheads:getAnnualCost(farmId, definition) * (1 - TCShowStands.JOIN_DISCOUNT)
    return TheContractorOverheads.getChargeAmount(annual, billing)
end

-- Visits (server) -----------------------------------------------------------------------------

local function newVisit()
    return { attended = false, joined = false, careers = false, talked = {}, asked = {} }
end

-- Server: a farm's visit for the show, made if it hasn't one.
function TheContractorShowStands:takeVisit(farmId)
    local event = getShowEvent()
    if event ~= nil and self.showId ~= event.id then
        self:reset(event.id)
    end
    self.visits[farmId] = self.visits[farmId] or newVisit()
    return self.visits[farmId]
end

local function hasCompany(farmId)
    local tc = getTC()
    return tc.Company ~= nil and tc.Company:hasCompany(farmId)
end

local function lift(farmId, personId, delta)
    local tc = getTC()
    if tc.Relationships ~= nil and personId ~= nil and delta > 0 then
        tc.Relationships:adjust(farmId, personId, delta, TheContractorRelationships.WORD_REASON)
    end
end

-- Server: a farm's attend job's done: the host's goodwill, once a show.
function TheContractorShowStands:onAttended(event, farmId)
    local visit = self:takeVisit(farmId)
    if visit.attended then
        return
    end
    visit.attended = true
    lift(farmId, event.hostFarmerId, TCShowStands.HOST_OPINION)
    TCLog.info("TheContractor: farm %d came to show %d: host %d's goodwill", farmId, event.id, event.hostFarmerId)
    self:sync()
end

-- Server: a player's request (TCShowTalkEvent, or the host's own directly).
-- personId: the farmer, for TALK and ASK. Returns an ANSWER and a value
-- (the offer's job id, what joining cost, how many candidates came; 0 for
-- none).
function TheContractorShowStands:handleRequest(farmId, request, personId)
    if not g_currentMission:getIsServer() then
        return ANSWER.CLOSED, 0
    end
    if not self:isOpen() then
        return ANSWER.CLOSED, 0
    end
    if request == REQUEST.TALK or request == REQUEST.ASK then
        if not self:isAtShow(personId) then
            return ANSWER.CLOSED, 0
        end
        if request == REQUEST.TALK then
            self:talk(farmId, personId)
            return ANSWER.OK, 0
        end
        return self:ask(farmId, personId)
    elseif request == REQUEST.JOIN_ANNUAL or request == REQUEST.JOIN_MONTHLY then
        return self:join(farmId, request == REQUEST.JOIN_ANNUAL and TheContractorOverheads.BILLING.ANNUAL or
            TheContractorOverheads.BILLING.MONTHLY)
    elseif request == REQUEST.CAREERS then
        return self:visitCareers(farmId)
    end
    return ANSWER.CLOSED, 0
end

-- Server: a farm talks to a farmer: the first time this show, their
-- goodwill. Returns whether it was the first time.
function TheContractorShowStands:talk(farmId, personId)
    local visit = self:takeVisit(farmId)
    if visit.talked[personId] then
        return false
    end
    visit.talked[personId] = true
    lift(farmId, personId, TCShowStands.TALK_OPINION)
    self:sync()
    return true
end

-- Server: "any work going?", once a farm per farmer per show.
function TheContractorShowStands:ask(farmId, personId)
    local tc = getTC()
    if not hasCompany(farmId) then
        return ANSWER.NO_COMPANY, 0
    end
    local relationships = tc.Relationships
    local refuses = relationships ~= nil and relationships:refuses(farmId, personId)
    if refuses then
        self:talk(farmId, personId)
        return ANSWER.REFUSED, 0
    end
    local visit = self:takeVisit(farmId)
    if visit.asked[personId] then
        return ANSWER.ASKED, 0
    end
    visit.asked[personId] = true
    self:talk(farmId, personId)
    self:sync()
    local score = relationships ~= nil and relationships:getScore(farmId, personId) or 0
    local chance = TCShowStands.getOfferChance(score, false)
    local roll = self.random()
    local job = nil
    if roll < chance and tc.JobGeneration ~= nil then
        job = tc.JobGeneration:generateForFarm(farmId, TheContractorShowStands.OFFER_SOURCE, personId)
    end
    TCLog.info("TheContractor: farm %d asked farmer %d for work at the show: roll %.2f against %.2f, %s", farmId,
        personId, roll, chance, job ~= nil and string.format("job %d offered", job.id) or "nothing")
    if job == nil then
        return ANSWER.NO_WORK, 0
    end
    return ANSWER.OFFER, job.id
end

-- Server: joining the association at its stall, the first term discounted.
function TheContractorShowStands:join(farmId, billing)
    local tc = getTC()
    if not hasCompany(farmId) then
        return ANSWER.NO_COMPANY, 0
    end
    if tc.Association:isMember(farmId) then
        return ANSWER.MEMBER, 0
    end
    local definition = tc.Overheads:getDefinition(TheContractorAssociation.MEMBERSHIP_KEY)
    local charge = TheContractorShowStands.getJoinCharge(farmId, billing)
    local farm = g_farmManager:getFarmById(farmId)
    if definition == nil or farm == nil or farm:getBalance() < charge then
        return ANSWER.CANT_AFFORD, 0
    end
    tc.Overheads:startPolicy(farmId, definition, billing, nil, TCShowStands.JOIN_DISCOUNT)
    local visit = self:takeVisit(farmId)
    visit.joined = true
    self:sync()
    TCLog.info("TheContractor: farm %d joined the association at the show (%s, %.0f)", farmId, billing, charge)
    return ANSWER.JOINED, math.floor(charge + 0.5)
end

-- Server: the careers stand, once a farm per show: young candidates kept
-- for the farm for a week.
function TheContractorShowStands:visitCareers(farmId)
    local tc = getTC()
    if not hasCompany(farmId) then
        return ANSWER.NO_COMPANY, 0
    end
    local visit = self:takeVisit(farmId)
    if visit.careers then
        return ANSWER.VISITED, 0
    end
    visit.careers = true
    local untilDay = getToday() + TCShowStands.getCareersDays(g_currentMission.environment.daysPerPeriod)
    local randomInt = self.randomInt
    local added = tc.Staff:addKeptCandidates(farmId, TCShowStands.CAREERS.count, untilDay, function()
        return TCShowStands.rollCareersAge(TheContractorStaff.MIN_AGE, randomInt)
    end)
    self:sync()
    return ANSWER.SENT, added
end

-- Farms and farmers ------------------------------------------------------------------------------

-- Every machine (TCFarmDeletion).
function TheContractorShowStands:forgetFarm(farmId)
    self.visits[farmId] = nil
end

-- Every machine (128, through the show): a retired farmer's talks are their
-- successor's. Returns how many.
function TheContractorShowStands:replacePerson(oldId, newId)
    local count = 0
    for _, visit in pairs(self.visits) do
        for _, key in ipairs({ "talked", "asked" }) do
            if visit[key][oldId] then
                visit[key][oldId] = nil
                visit[key][newId] = true
                count = count + 1
            end
        end
    end
    return count
end

-- Sync ---------------------------------------------------------------------------------------------

function TheContractorShowStands:sync()
    if g_server ~= nil then
        g_server:broadcastEvent(TCShowStandsEvent.new(self))
    end
end

local function sortedKeys(set)
    local keys = {}
    for key in pairs(set) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

function TheContractorShowStands.writeState(streamId, state)
    streamWriteInt32(streamId, state.showId or -1)
    local farmIds = sortedKeys(state.visits)
    streamWriteUInt8(streamId, #farmIds)
    for _, farmId in ipairs(farmIds) do
        local visit = state.visits[farmId]
        streamWriteInt32(streamId, farmId)
        streamWriteBool(streamId, visit.attended == true)
        streamWriteBool(streamId, visit.joined == true)
        streamWriteBool(streamId, visit.careers == true)
        for _, key in ipairs({ "talked", "asked" }) do
            local ids = sortedKeys(visit[key])
            streamWriteUInt16(streamId, #ids)
            for _, id in ipairs(ids) do
                streamWriteInt32(streamId, id)
            end
        end
    end
end

function TheContractorShowStands.readState(streamId)
    local state = { visits = {} }
    local showId = streamReadInt32(streamId)
    state.showId = showId >= 0 and showId or nil
    for _ = 1, streamReadUInt8(streamId) do
        local farmId = streamReadInt32(streamId)
        local visit = newVisit()
        visit.attended = streamReadBool(streamId)
        visit.joined = streamReadBool(streamId)
        visit.careers = streamReadBool(streamId)
        for _, key in ipairs({ "talked", "asked" }) do
            for _ = 1, streamReadUInt16(streamId) do
                visit[key][streamReadInt32(streamId)] = true
            end
        end
        state.visits[farmId] = visit
    end
    return state
end

-- A client: the visits as the server sent them.
function TheContractorShowStands:applyState(state)
    self.showId = state.showId
    self.visits = state.visits
end

function TheContractorShowStands:writeInitialClientState(streamId, connection)
    TheContractorShowStands.writeState(streamId, self)
end

function TheContractorShowStands:readInitialClientState(streamId, connection)
    self:applyState(TheContractorShowStands.readState(streamId))
end

-- Persistence (server) -------------------------------------------------------------------------------

function TheContractorShowStands:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorShowStands.SAVE_KEY
    if self.showId ~= nil then
        setXMLInt(xmlFile, key .. "#showId", self.showId)
    end
    for i, farmId in ipairs(sortedKeys(self.visits)) do
        local visit = self.visits[farmId]
        local visitKey = string.format("%s.visit(%d)", key, i - 1)
        setXMLInt(xmlFile, visitKey .. "#farmId", farmId)
        setXMLBool(xmlFile, visitKey .. "#attended", visit.attended == true)
        setXMLBool(xmlFile, visitKey .. "#joined", visit.joined == true)
        setXMLBool(xmlFile, visitKey .. "#careers", visit.careers == true)
        for _, name in ipairs({ "talked", "asked" }) do
            for j, id in ipairs(sortedKeys(visit[name])) do
                setXMLInt(xmlFile, string.format("%s.%s(%d)#personId", visitKey, name, j - 1), id)
            end
        end
    end
end

function TheContractorShowStands:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorShowStands.SAVE_KEY
    self.showId = getXMLInt(xmlFile, key .. "#showId")
    self.visits = {}
    local i = 0
    while hasXMLProperty(xmlFile, string.format("%s.visit(%d)", key, i)) do
        local visitKey = string.format("%s.visit(%d)", key, i)
        local farmId = getXMLInt(xmlFile, visitKey .. "#farmId")
        if farmId ~= nil then
            local visit = newVisit()
            visit.attended = getXMLBool(xmlFile, visitKey .. "#attended") == true
            visit.joined = getXMLBool(xmlFile, visitKey .. "#joined") == true
            visit.careers = getXMLBool(xmlFile, visitKey .. "#careers") == true
            for _, name in ipairs({ "talked", "asked" }) do
                local j = 0
                while true do
                    local id = getXMLInt(xmlFile, string.format("%s.%s(%d)#personId", visitKey, name, j))
                    if id == nil then
                        break
                    end
                    visit[name][id] = true
                    j = j + 1
                end
            end
            self.visits[farmId] = visit
        end
        i = i + 1
    end
end

-- Console ----------------------------------------------------------------------------------------------

-- The slot of the open day it is now (TCShowStands.getSlot), or nil.
function TheContractorShowStands.getSlotNow()
    return TCShowStands.getSlot(getHour(), TheContractorShow.START_HOUR, TheContractorShow.END_HOUR)
end

-- Where everyone stands now, from the synced scene (TCShowStands.getPlaces):
-- personId -> spot, and the stalls. Empty without a showground.
function TheContractorShowStands:getPlacesNow()
    local scene = self:getScene()
    local event = getShowEvent()
    if scene == nil or event == nil then
        return {}, {}
    end
    return TCShowStands.getPlaces(scene, event.id, TheContractorShowStands.getSlotNow(), self:getFarmersAtShow())
end

-- tcShow people: the stalls and the farmers at the show, where they stand
-- and how far that is from the typing player (context), and what the farm's
-- done there.
function TheContractorShowStands:describe(farmId, context)
    local tc = getTC()
    local event = getShowEvent()
    if event == nil then
        return "There's no show announced."
    end
    local lines = {}
    local isOpen = self:isOpen()
    if isOpen then
        table.insert(lines, string.format("Show %d is open: the stalls and these farmers are on the showground.",
            event.id))
    else
        table.insert(lines, string.format(
            "Show %d's stalls and farmers are on its showground on the day, %02d:00 to %02d:00. The farmers who'd be there:",
            event.id, TheContractorShow.START_HOUR, TheContractorShow.END_HOUR))
    end
    local places, stalls = self:getPlacesNow()
    local function where(spot)
        if spot == nil then
            return nil
        end
        if TCConsole.hasPosition(context) then
            return string.format("at %.0f, %.0f, %.0f m from you", spot.x, spot.z,
                math.sqrt((spot.x - context.x) ^ 2 + (spot.z - context.z) ^ 2))
        end
        return string.format("at %.0f, %.0f", spot.x, spot.z)
    end
    for _, id in ipairs(self:getFarmersAtShow()) do
        local person = tc.Farmers ~= nil and tc.Farmers:getPerson(id) or nil
        local notes = {}
        if id == event.hostFarmerId then
            table.insert(notes, "the host")
        end
        if self:hasTalked(farmId, id) then
            table.insert(notes, "talked to")
        end
        if self:hasAsked(farmId, id) then
            table.insert(notes, "asked for work")
        end
        if isOpen then
            table.insert(notes, where(places[id]) or "no spot left for them")
        end
        table.insert(lines, string.format("  %d %s%s", id, person ~= nil and person.name or "?",
            #notes > 0 and (" (" .. table.concat(notes, ", ") .. ")") or ""))
    end
    for _, stall in ipairs(stalls) do
        table.insert(lines, string.format("  The %s stall, %s.", stall.role == "association" and "trade association's" or
            "careers", where(stall)))
    end
    local visit = self:getVisit(farmId)
    local member = tc.Association ~= nil and tc.Association:isMember(farmId)
    table.insert(lines, string.format("Farm %d: %s; trade association: %s; careers stand: %s.", farmId,
        (visit ~= nil and visit.attended) and "has come (the host's goodwill given)" or "hasn't come yet",
        (visit ~= nil and visit.joined) and "joined here" or (member and "a member" or "not a member"),
        (visit ~= nil and visit.careers) and "visited" or "not visited"))
    return table.concat(lines, "\n")
end

function TheContractorShowStands.registerConsoleCommands()
    TCConsole.register("show", "people", {
        description = "The show's stalls and the farmers at it (who, where, how far from you), and what your farm's done there",
        serverOnly = false,
        run = function(farmId, args, context)
            if args[1] ~= nil then
                return false
            end
            return g_currentMission.TheContractor.ShowStands:describe(farmId, context)
        end,
    })
end
