-- The breeders' pen at the show (173), on each machine with a client: the
-- talk at the breeder's stand. TCShowStandsWorld puts the breeder there (a
-- stall of role "breeder", in the farmer's own look) and hands a player who
-- walks up to them here. All of it's one conversation (TCConversation,
-- vanilla's NPC chat):
--
--   The stock: the animals in the breeder's trailers as RL has them on this
--     machine (BreedersPen:getCatalogue), each by its breed's own title,
--     its age in months and its price; a sick one isn't offered.
--   One of them: its name, age, weight, health, whether it's carrying or in
--     milk, its genetics and price; "I'll take it", the others, or not today.
--   Where to: the farm's livestock trailers at the show (free) and its
--     husbandries with room (the delivery fee) that take it
--     (BreedersPen:getTargets).
--   Then it's the server's (TheContractorBreedersPen:handleBuy, through
--     TCBreederBuyEvent from a client), and the answer's said back.

TCBreedersPenWorld = {}

-- Requests sent to the server, waiting for an answer: token -> onAnswer.
TCBreedersPenWorld.pending = {}
TCBreedersPenWorld.nextToken = 1

local function getTC()
    return g_currentMission ~= nil and g_currentMission.TheContractor or nil
end

local function getText(key)
    return g_i18n:getText(key)
end

-- A random variant of a line (text only, so any machine picks its own).
local function line(name)
    local count = TCBreedersPen.LINES[name] or 1
    return getText(TCBreedersPen.getLineKey(name, math.random(1, count)))
end

local function money(amount)
    return g_i18n:formatMoney(amount, 0, true, true)
end

local function sayAndFinish(text)
    TCConversation.say(text, {}, function()
        TCConversation.finish()
    end)
end

-- Asking the server ---------------------------------------------------------------------------------

-- Sends a buy for the local player's farm; onAnswer(answer, value) when
-- the answer comes (straight away on the server).
function TCBreedersPenWorld.request(key, targetId, onAnswer)
    local tc = getTC()
    local farmId = g_currentMission:getFarmId()
    if g_currentMission:getIsServer() then
        local answer, value = tc.BreedersPen:handleBuy(farmId, key, targetId, nil)
        if onAnswer ~= nil then
            onAnswer(answer, value)
        end
        return
    end
    local token = TCBreedersPenWorld.nextToken
    TCBreedersPenWorld.nextToken = token + 1
    TCBreedersPenWorld.pending[token] = onAnswer
    g_client:getServerConnection():sendEvent(TCBreederBuyEvent.newRequest(farmId, key, targetId, token))
end

-- A client (TCBreederBuyEvent): the server's answer to a buy.
function TCBreedersPenWorld.onAnswer(token, answer, value)
    local onAnswer = TCBreedersPenWorld.pending[token]
    TCBreedersPenWorld.pending[token] = nil
    if onAnswer ~= nil then
        onAnswer(answer, value)
    end
end

-- What's said ------------------------------------------------------------------------------------------

-- An animal's genetics as the stand shows them: "Quality 1.31, health ...".
function TCBreedersPenWorld.formatGenetics(genetics)
    local parts = {}
    for _, trait in ipairs(TCBreedersPen.GENETICS) do
        local value = genetics ~= nil and genetics[trait] or nil
        if type(value) == "number" then
            table.insert(parts, string.format(getText("tc_breeder_gene_" .. trait), value))
        end
    end
    return table.concat(parts, ", ")
end

-- The breeder's line about one animal.
function TCBreedersPenWorld.describeAnimal(entry)
    local info = entry.info
    local notes = {}
    if info.pregnant then
        table.insert(notes, getText("tc_breeder_pregnant"))
    end
    if info.lactating then
        table.insert(notes, getText("tc_breeder_lactating"))
    end
    return string.format(getText("tc_breeder_animal"), entry.title or "-",
        info.name ~= nil and info.name ~= "" and info.name or getText("tc_breeder_noName"), info.age or 0,
        math.floor((info.weight or 0) + 0.5), math.floor((info.health or 0) + 0.5),
        #notes > 0 and (" " .. table.concat(notes, " ")) or "", TCBreedersPenWorld.formatGenetics(info.genetics),
        money(entry.price))
end

-- The conversation ----------------------------------------------------------------------------------------

local function getCatalogue()
    return getTC().BreedersPen:getCatalogue(false)
end

-- Asks and, until the answer, the breeder's thinking it over (none on the
-- server: the answer's there at once).
local function buy(entry, target)
    local session = TCConversation.getSession()
    if not g_currentMission:getIsServer() then
        sayAndFinish(line("thinking"))
    end
    TCBreedersPenWorld.request(entry.key, target.objectId, function(answer)
        if TCConversation.getSession() ~= session then
            return
        end
        local name = TCBreedersPen.getAnswerLine(answer)
        if name == nil then
            TCConversation.finish()
            return
        end
        sayAndFinish(line(name))
    end)
end

local showList

local function chooseTarget(entry)
    local tc = getTC()
    local targets = tc.BreedersPen:getTargets(g_currentMission:getFarmId(), entry.subTypeIndex)
    if #targets == 0 then
        sayAndFinish(line("noRoom"))
        return
    end
    local options = {}
    for _, target in ipairs(targets) do
        if target.isHusbandry then
            table.insert(options, string.format(getText("tc_breeder_optionHusbandry"),
                TCShowAnimals.getHusbandryName(target.object), money(target.fee)))
        else
            local name = type(target.object.getFullName) == "function" and target.object:getFullName() or "-"
            table.insert(options, string.format(getText("tc_breeder_optionTrailer"), name))
        end
    end
    table.insert(options, getText("tc_breeder_optionNeverMind"))
    TCConversation.say(string.format(getText("tc_breeder_where"), money(entry.price)), options, function(index)
        if index ~= nil and index >= 1 and index <= #targets then
            buy(entry, targets[index])
        elseif index == #targets + 1 then
            sayAndFinish(line("later"))
        else
            TCConversation.finish()
        end
    end)
end

local function showAnimal(entry)
    TCConversation.say(TCBreedersPenWorld.describeAnimal(entry), {
        getText("tc_breeder_optionTake"),
        getText("tc_breeder_optionOthers"),
        getText("tc_breeder_optionNotToday"),
    }, function(index)
        if index == 1 then
            chooseTarget(entry)
        elseif index == 2 then
            showList(getText("tc_breeder_others"))
        elseif index == 3 then
            sayAndFinish(line("later"))
        else
            TCConversation.finish()
        end
    end)
end

showList = function(text)
    local entries = getCatalogue()
    if #entries == 0 then
        sayAndFinish(line("soldOut"))
        return
    end
    local options = {}
    for _, entry in ipairs(entries) do
        table.insert(options, string.format(getText("tc_breeder_optionAnimal"), entry.title or "-", entry.info.age or 0,
            money(entry.price)))
    end
    table.insert(options, getText("tc_breeder_optionJustLooking"))
    TCConversation.say(text, options, function(index)
        if index ~= nil and index >= 1 and index <= #entries then
            showAnimal(entries[index])
        elseif index == #entries + 1 then
            sayAndFinish(line("later"))
        else
            TCConversation.finish()
        end
    end)
end

-- TCShowStandsWorld.talkTo, the conversation started: the breeder's stock.
function TCBreedersPenWorld.visit()
    showList(line("greet"))
end

-- deleteMap.
function TCBreedersPenWorld.reset()
    TCBreedersPenWorld.pending = {}
end
