-- The show's stalls and farmers on the showground (171), on each machine
-- with a client: the people (TCFigures), the activate prompt and the
-- conversations (TCConversation). Everything is from synced state (the
-- show, its scene, the farmers, the visits), so every machine has the same
-- people in the same places; what happens goes to the server
-- (TheContractorShowStands:handleRequest, through TCShowTalkEvent from a
-- client) and the answer is said back in the same conversation.
--
--   Stallholders: one behind each stall's table (TCShowScene's stalls), in
--     a look from the base maps' people picked from the show.
--   Farmers: those at the show (ShowStands:getFarmersAtShow), each in their
--     own look on their spot for this part of the day (TCShowStands.
--     getPlaces). One waiting by a machine of theirs (TCYardFarmers) is
--     there instead.
--   173: the breeder, while the breeders' pen's open (BreedersPen:isOpen),
--     at their stand (TCShowScene.getBreederStand) in their own look (or a
--     stallholder's, with no farmer to spare); talking to them is
--     TCBreedersPenWorld's.
--   172: the staff given the show's day off (ShowDayOff:getCrowdPlacesNow),
--     each in their own look ringside, the crowd's figure on a spectator
--     spot they're on standing aside (TCAuctionCrowd.setReservedSpots).
--     Not talked to: that's 130's.
--   Anyone within FACE_DISTANCE of the local player turns to face them.
--   The prompt (one activatable): the nearest stallholder within
--     TCShowStands.STALL_DISTANCE or farmer within TALK_DISTANCE, while the
--     stands are open and nobody's being talked to.

TCShowStandsWorld = {}

TCShowStandsWorld.FACE_DISTANCE = 5

local REQUEST = TCShowStands.REQUEST
local ANSWER = TCShowStands.ANSWER

-- figures: { figure.target = { kind ("stall"/"farmer"/"staff"), role,
-- personId, name } }; key: what they were built from.
TCShowStandsWorld.figures = nil
TCShowStandsWorld.key = nil
TCShowStandsWorld.templates = nil
-- Requests sent to the server, waiting for an answer: token -> onAnswer.
TCShowStandsWorld.pending = {}
TCShowStandsWorld.nextToken = 1

local function getTC()
    return g_currentMission ~= nil and g_currentMission.TheContractor or nil
end

local function getText(key)
    return g_i18n:getText(key)
end

-- A random variant of a line (text only, so any machine picks its own).
local function line(name)
    local count = TCShowStands.LINES[name] or 1
    return getText(TCShowStands.getLineKey(name, math.random(1, count)))
end

local function getLocalPlayerPosition()
    local player = g_localPlayer
    if player == nil or player.getPosition == nil then
        return nil
    end
    local x, y, z = player:getPosition()
    return x, y, z
end

-- The people (every frame) ---------------------------------------------------------------------------

function TCShowStandsWorld.freeAll()
    if TCShowStandsWorld.figures ~= nil then
        TCFigures.freeAll(TCShowStandsWorld.figures)
        TCAuctionCrowd.setReservedSpots(nil)
    end
    TCShowStandsWorld.figures = nil
    TCShowStandsWorld.key = nil
end

-- Who should be on the showground now: a list of { target, x, z, yaw,
-- style (a farmer's or a member of staff's own look, or nil) }, the key
-- they're built from, and the crowd's spots they're on (172: spotKey ->
-- true).
function TCShowStandsWorld.getWanted()
    local tc = getTC()
    local stands = tc ~= nil and tc.ShowStands or nil
    if stands == nil or not stands:isOpen() then
        return nil, nil
    end
    local event = tc.Show:getEvent()
    local wanted, parts = {}, { tostring(event.id), tostring(TheContractorShowStands.getSlotNow()) }
    local places, stalls = stands:getPlacesNow()
    for _, stall in ipairs(stalls) do
        table.insert(wanted, { target = { kind = "stall", role = stall.role,
            name = getText("tc_showStands_name_" .. stall.role) }, x = stall.x, z = stall.z, yaw = stall.yaw })
        table.insert(parts, stall.role)
    end
    -- 173: the breeder at their stand.
    local pen = tc.BreedersPen
    local breederStand = pen ~= nil and pen:isOpen() and TCShowScene.getBreederStand(stands:getScene()) or nil
    if breederStand ~= nil then
        local breeder = pen:getBreeder()
        local style = breeder ~= nil and TCWorkerAppearance.getPlayerStyle(breeder) or nil
        table.insert(wanted, { target = { kind = "stall", role = "breeder", personId = breeder ~= nil and breeder.id or nil,
            name = breeder ~= nil and breeder.name or getText("tc_showStands_name_breeder") }, x = breederStand.x,
            z = breederStand.z, yaw = breederStand.yaw, style = style })
        table.insert(parts, string.format("breeder%d:%s", pen.breederId, tostring(style)))
    end
    for _, id in ipairs(stands:getFarmersAtShow()) do
        local spot = places[id]
        local person = tc.Farmers ~= nil and tc.Farmers:getPerson(id) or nil
        -- One waiting by their machine (114's) is there, not here.
        local yard = TCYardFarmers ~= nil and TCYardFarmers.wanted ~= nil and TCYardFarmers.wanted[id] or nil
        local byMachine = yard ~= nil and yard.spot ~= nil and yard.spot.jobId ~= nil
        if spot ~= nil and person ~= nil and not byMachine then
            local style = TCWorkerAppearance.getPlayerStyle(person)
            table.insert(wanted, { target = { kind = "farmer", personId = id, name = person.name }, x = spot.x,
                z = spot.z, yaw = spot.yaw, style = style })
            -- The look's in the key, so an edited one (111) loads afresh.
            table.insert(parts, string.format("%d@%.1f,%.1f:%s", id, spot.x, spot.z, tostring(style)))
        end
    end
    -- 172: the staff on the show's day off.
    local reserved = {}
    if tc.ShowDayOff ~= nil then
        for _, entry in ipairs(tc.ShowDayOff:getCrowdPlacesNow(places)) do
            local place = entry.place
            local style = TCWorkerAppearance.getPlayerStyle(entry.person)
            if style ~= nil then
                table.insert(wanted, { target = { kind = "staff", personId = entry.id, name = entry.person.name },
                    x = place.x, z = place.z, yaw = place.yaw, style = style })
                table.insert(parts, string.format("s%d@%.1f,%.1f:%s", entry.id, place.x, place.z, tostring(style)))
                if place.isCrowdSpot then
                    reserved[TCAuctionCrowd.spotKey(place.x, place.z)] = true
                end
            end
        end
    end
    return wanted, table.concat(parts, "|"), reserved
end

function TCShowStandsWorld.rebuild(wanted, key, reserved)
    TCShowStandsWorld.freeAll()
    TCShowStandsWorld.key = key
    TCAuctionCrowd.setReservedSpots(reserved)
    TCShowStandsWorld.templates = TCShowStandsWorld.templates or TCFigures.readTemplates()
    local templates = TCShowStandsWorld.templates
    if #templates == 0 then
        return
    end
    local event = getTC().Show:getEvent()
    local figures = {}
    for i, entry in ipairs(wanted) do
        local template
        if entry.style ~= nil then
            template = { style = entry.style }
        else
            local pick = TCAuctionScene.hash(event ~= nil and event.id or 0, 1711, i)
            template = templates[math.floor(pick * #templates) % #templates + 1]
        end
        table.insert(figures, { kind = "stand", template = template, x = entry.x, y = TCFigures.groundY(entry.x, entry.z),
            z = entry.z, yaw = entry.yaw, baseYaw = entry.yaw, target = entry.target })
    end
    TCShowStandsWorld.figures = figures
end

-- Every frame on a machine with a client.
function TCShowStandsWorld.update(dt)
    TCConversation.update(dt)
    if TCFigures.getUnavailableReason() ~= nil then
        return
    end
    local wanted, key, reserved = TCShowStandsWorld.getWanted()
    if wanted == nil then
        if TCShowStandsWorld.figures ~= nil then
            TCConversation.finish()
            TCShowStandsWorld.freeAll()
        end
        return
    end
    -- Nobody moves while they're being talked to.
    if key ~= TCShowStandsWorld.key and not TCConversation.isActive() then
        TCShowStandsWorld.rebuild(wanted, key, reserved)
    end
    local figures = TCShowStandsWorld.figures
    local cx, cy, cz = TCFigures.getCameraPosition()
    if figures == nil or cx == nil then
        return
    end
    local px, _, pz = getLocalPlayerPosition()
    TCFigures.update(figures, dt, cx, cy, cz, 1, {
        place = function(figure)
            figure.yaw = figure.baseYaw
            if px ~= nil then
                local dx, dz = px - figure.x, pz - figure.z
                if dx * dx + dz * dz <= TCShowStandsWorld.FACE_DISTANCE ^ 2 then
                    figure.yaw = math.atan2(dx, dz)
                end
            end
        end,
    })
end

-- The nearest person a player at (x, z) can talk to, and how far: a
-- figure, or nil.
function TCShowStandsWorld.findNearest(x, z)
    local best, bestDistance = nil, math.huge
    for _, figure in ipairs(TCShowStandsWorld.figures or {}) do
        -- 172: the staff aren't talked to (130's).
        if figure.target.kind ~= "staff" then
            local reach = figure.target.kind == "stall" and TCShowStands.STALL_DISTANCE or TCShowStands.TALK_DISTANCE
            local distance = math.sqrt((x - figure.x) ^ 2 + (z - figure.z) ^ 2)
            if distance <= reach and distance < bestDistance then
                best, bestDistance = figure, distance
            end
        end
    end
    return best, bestDistance
end

-- Asking the server ------------------------------------------------------------------------------------

-- Sends a request for the local player's farm; onAnswer(answer, value) when
-- the answer comes (straight away on the server).
function TCShowStandsWorld.request(request, personId, onAnswer)
    local tc = getTC()
    local farmId = g_currentMission:getFarmId()
    if g_currentMission:getIsServer() then
        local answer, value = tc.ShowStands:handleRequest(farmId, request, personId)
        if onAnswer ~= nil then
            onAnswer(answer, value)
        end
        return
    end
    local token = TCShowStandsWorld.nextToken
    TCShowStandsWorld.nextToken = token + 1
    TCShowStandsWorld.pending[token] = onAnswer
    g_client:getServerConnection():sendEvent(TCShowTalkEvent.newRequest(farmId, request, personId, token))
end

-- A client (TCShowTalkEvent): the server's answer to a request.
function TCShowStandsWorld.onAnswer(request, token, answer, value)
    local onAnswer = TCShowStandsWorld.pending[token]
    TCShowStandsWorld.pending[token] = nil
    if onAnswer ~= nil then
        onAnswer(answer, value)
    end
end

-- Conversations ----------------------------------------------------------------------------------------

local function sayAndFinish(text)
    TCConversation.say(text, {}, function()
        TCConversation.finish()
    end)
end

-- The answer's line, in the conversation it was asked in (a late answer to
-- one that's over is dropped: an offer still comes by Inbox).
local function answerIn(session, request)
    return function(answer)
        if TCConversation.getSession() ~= session then
            return
        end
        local name = TCShowStands.getAnswerLine(answer, request)
        if name == nil then
            TCConversation.finish()
            return
        end
        sayAndFinish(line(name))
    end
end

-- Asks and, until the answer, a line of the speaker's thinking it over
-- (none on the server: the answer's there at once).
local function askAndWait(request, personId)
    local session = TCConversation.getSession()
    if not g_currentMission:getIsServer() then
        sayAndFinish(line("thinking"))
    end
    TCShowStandsWorld.request(request, personId, answerIn(session, request))
end

local function hasCompany(farmId)
    local tc = getTC()
    return tc.Company ~= nil and tc.Company:hasCompany(farmId)
end

function TCShowStandsWorld.talkToFarmer(personId)
    local tc = getTC()
    local farmId = g_currentMission:getFarmId()
    local event = tc.Show:getEvent()
    TCShowStandsWorld.request(REQUEST.TALK, personId, nil)
    if tc.Relationships ~= nil and tc.Relationships:refuses(farmId, personId) then
        sayAndFinish(line("curt"))
        return
    end
    local greeting = line(event ~= nil and event.hostFarmerId == personId and "greetHost" or "greet")
    if not hasCompany(farmId) or tc.ShowStands:hasAsked(farmId, personId) then
        sayAndFinish(greeting)
        return
    end
    TCConversation.say(greeting, { getText("tc_showTalk_optionAsk"), getText("tc_showTalk_optionBye") },
        function(index)
            if index == 1 then
                askAndWait(REQUEST.ASK, personId)
            else
                TCConversation.finish()
            end
        end)
end

function TCShowStandsWorld.visitAssociation()
    local tc = getTC()
    local farmId = g_currentMission:getFarmId()
    if not hasCompany(farmId) then
        sayAndFinish(line("associationNoCompany"))
        return
    end
    if tc.Association:isMember(farmId) then
        sayAndFinish(line("associationMember"))
        return
    end
    local BILLING = TheContractorOverheads.BILLING
    local annual = TheContractorShowStands.getJoinCharge(farmId, BILLING.ANNUAL)
    local monthly = TheContractorShowStands.getJoinCharge(farmId, BILLING.MONTHLY)
    local function money(amount)
        return g_i18n:formatMoney(amount, 0, true, true)
    end
    local text = string.format(line("associationOffer"), math.floor(TCShowStands.JOIN_DISCOUNT * 100 + 0.5),
        money(annual), money(monthly))
    TCConversation.say(text, {
        string.format(getText("tc_showTalk_optionJoinAnnual"), money(annual)),
        string.format(getText("tc_showTalk_optionJoinMonthly"), money(monthly)),
        getText("tc_showTalk_optionNotToday"),
    }, function(index)
        if index == 1 or index == 2 then
            askAndWait(index == 1 and REQUEST.JOIN_ANNUAL or REQUEST.JOIN_MONTHLY, nil)
        elseif index == 3 then
            sayAndFinish(line("associationLater"))
        else
            TCConversation.finish()
        end
    end)
end

function TCShowStandsWorld.visitCareers()
    local tc = getTC()
    local farmId = g_currentMission:getFarmId()
    if not hasCompany(farmId) then
        sayAndFinish(line("careersNoCompany"))
        return
    end
    if tc.ShowStands:hasVisitedCareers(farmId) then
        sayAndFinish(line("careersVisited"))
        return
    end
    TCConversation.say(line("careersOffer"), { getText("tc_showTalk_optionYes"), getText("tc_showTalk_optionNotNow") },
        function(index)
            if index == 1 then
                askAndWait(REQUEST.CAREERS, nil)
            elseif index == 2 then
                sayAndFinish(line("careersLater"))
            else
                TCConversation.finish()
            end
        end)
end

-- Starts a conversation with a figure on the showground.
function TCShowStandsWorld.talkTo(figure)
    local target = figure.target
    local started = TCConversation.start({
        name = target.name,
        getGraphics = function()
            return figure.graphics
        end,
        getPosition = function()
            return figure.x, figure.y, figure.z
        end,
    })
    if not started then
        return
    end
    if target.kind == "farmer" then
        TCShowStandsWorld.talkToFarmer(target.personId)
    elseif target.role == "breeder" then
        TCBreedersPenWorld.visit()
    elseif target.role == "association" then
        TCShowStandsWorld.visitAssociation()
    else
        TCShowStandsWorld.visitCareers()
    end
end

-- The prompt -------------------------------------------------------------------------------------------

TCShowStandsActivatable = {}
local TCShowStandsActivatable_mt = Class(TCShowStandsActivatable)

function TCShowStandsActivatable.new()
    local self = setmetatable({}, TCShowStandsActivatable_mt)
    self.activateText = ""
    self.figure = nil
    self.distance = math.huge
    return self
end

function TCShowStandsActivatable:getIsActivatable()
    self.figure, self.distance = nil, math.huge
    local player = g_localPlayer
    if player == nil or player.getCurrentVehicle == nil or player:getCurrentVehicle() ~= nil or
            TCConversation.isActive() or not TCConversation.isAvailable() then
        return false
    end
    local x, _, z = player:getPosition()
    local figure, distance = TCShowStandsWorld.findNearest(x, z)
    if figure == nil then
        return false
    end
    if figure ~= self.shownFigure then
        self.shownFigure = figure
        local target = figure.target
        if target.kind == "farmer" then
            self.activateText = string.format(getText("tc_showTalk_promptFarmer"), target.name)
        else
            self.activateText = getText("tc_showTalk_prompt_" .. target.role)
        end
    end
    self.figure, self.distance = figure, distance
    return true
end

function TCShowStandsActivatable:getDistance(x, y, z)
    return self.distance
end

function TCShowStandsActivatable:run()
    if self.figure ~= nil then
        TCShowStandsWorld.talkTo(self.figure)
    end
end

-- Registered once per load, taken away in deleteMap (with the people).
function TCShowStandsWorld.install()
    local system = g_currentMission.activatableObjectsSystem
    if system == nil then
        return
    end
    TCShowStandsWorld.activatable = TCShowStandsActivatable.new()
    system:addActivatable(TCShowStandsWorld.activatable)
end

function TCShowStandsWorld.uninstall()
    local activatable = TCShowStandsWorld.activatable
    if activatable ~= nil then
        local system = g_currentMission ~= nil and g_currentMission.activatableObjectsSystem or nil
        if system ~= nil then
            system:removeActivatable(activatable)
        end
        TCShowStandsWorld.activatable = nil
    end
    TCConversation.reset()
    TCShowStandsWorld.freeAll()
    TCShowStandsWorld.templates = nil
    TCShowStandsWorld.pending = {}
    TCBreedersPenWorld.reset()
end
