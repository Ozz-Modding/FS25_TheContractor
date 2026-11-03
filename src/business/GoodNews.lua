-- Good news (073), a random event (068): something nice happens to the
-- business, an inbox message says so, and the story's reward is applied.
-- Only stories with no mechanics of their own belong here - a reward and
-- nothing else. Each one is a STORIES entry with exactly one of:
--
--   reputation   job-equivalents: a multiple of a typical job's completion
--                reward at the farm's current tier (getReputationReward), so
--                a "small" boost stays small at every tier
--   money        a 1x UK amount, paid through scaleCost (a refund of a fixed
--                business cost) under MoneyType.TC_GOOD_NEWS
--
-- plus tc_goodNews_<key>_title / tc_goodNews_<key>_body l10n keys (the body
-- gets the amount as its one %s). A new story is a table entry and two texts.
--
-- One event type, so every story shares one rate and one cooldown. Never the
-- same story twice in a row on a farm: lastStoryByFarm, server-only (only
-- the server picks stories), saved. The incident's data is { story = key }.

TheContractorGoodNews = {}
TheContractorGoodNews_mt = Class(TheContractorGoodNews)

TheContractorGoodNews.EVENT_TYPE = "goodNews"
TheContractorGoodNews.MESSAGE_KIND = "goodNews"

TheContractorGoodNews.RATE_PER_PERIOD = 0.1
TheContractorGoodNews.COOLDOWN_PERIODS = 3

-- A typical job's completion reputation per hectare (JobGeneration's
-- reputationPerHa is 5-10, most around 8).
TheContractorGoodNews.REPUTATION_PER_HA = 8

TheContractorGoodNews.STORIES = {
    { key = "photoPosted", reputation = 0.25 },
    { key = "parishNews", reputation = 0.5 },
    { key = "parishCouncil", reputation = 0.35 },
    { key = "youngFarmers", reputation = 0.25 },
    { key = "supplierRefund", money = 400 },
    { key = "loyaltyRebate", money = 250 },
    { key = "ratesRefund", money = 300 },
}

table.insert(FinanceStats.statNames, "tcGoodNews")
FinanceStats.statNameToIndex["tcGoodNews"] = #FinanceStats.statNames

function TheContractorGoodNews.new()
    local self = {}
    setmetatable(self, TheContractorGoodNews_mt)

    MoneyType.TC_GOOD_NEWS = MoneyType.register("tcGoodNews", "tc_moneyType_goodNews")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    -- lastStoryByFarm[farmId] = the story key that farm last had (server).
    self.lastStoryByFarm = {}
    -- Set by tcCompany event goodNews [story] around its triggerEvent.
    self.forcedStory = nil

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorGoodNews:register(randomEvents, inbox)
    randomEvents:registerEventType(TheContractorGoodNews.EVENT_TYPE, {
        l10nKey = "tc_goodNews_eventName",
        cooldownPeriods = TheContractorGoodNews.COOLDOWN_PERIODS,
        ratePerPeriod = function(farmId)
            return TheContractorGoodNews.RATE_PER_PERIOD
        end,
        canTrigger = function(farmId)
            return self:pickStory(farmId)
        end,
        -- tcCompany event goodNews [story]: that story, or a random one other
        -- than the last, with or without a completed job.
        console = {
            prepareTrigger = function(farmId, details)
                return self:prepareConsoleStory(farmId, details[1])
            end,
            clearTrigger = function()
                self.forcedStory = nil
            end,
        },
        stages = {
            { key = "announce", run = function(incident)
                return self:onAnnounce(incident)
            end },
        },
    })

    inbox:registerMessageKind(TheContractorGoodNews.MESSAGE_KIND, {
        category = "feedback",
        chipTone = "good",
    })
end

-- Stories ---------------------------------------------------------------------

function TheContractorGoodNews.getStory(key)
    for _, story in ipairs(TheContractorGoodNews.STORIES) do
        if story.key == key then
            return story
        end
    end
    return nil
end

-- Reputation for a story worth jobEquivalents at the farm's tier: that many
-- jobs on the tier's preferred field size (the last tier with one, at the
-- top). At least 1.
function TheContractorGoodNews.getReputationReward(farmId, jobEquivalents)
    local tiers = TheContractorReputation.TIERS
    local tierIndex = g_currentMission.TheContractor.Reputation:getProgress(farmId).tierIndex
    local fieldHa = nil
    for i = tierIndex, 1, -1 do
        fieldHa = tiers[i].maxPreferredFieldHa
        if fieldHa ~= nil then
            break
        end
    end
    local reward = math.floor(jobEquivalents * (fieldHa or 1) * TheContractorGoodNews.REPUTATION_PER_HA)
    return math.max(1, reward)
end

-- A cash story's amount now, rounded down to 10: job pay setting and
-- EconomyScale both apply (scaleCost).
function TheContractorGoodNews.getMoneyReward(amount)
    return math.floor(g_currentMission.TheContractor.Settings:scaleCost(amount) / 10) * 10
end

-- Any story but the last one, at random. random is for the tests.
function TheContractorGoodNews.chooseStory(lastKey, random)
    random = random or math.random
    local candidates = {}
    for _, story in ipairs(TheContractorGoodNews.STORIES) do
        if story.key ~= lastKey then
            table.insert(candidates, story)
        end
    end
    if #candidates == 0 then
        return nil
    end
    return candidates[random(1, #candidates)]
end

function TheContractorGoodNews:hasCompletedJob(farmId)
    local jobs = g_currentMission.TheContractor.Jobs
    return #jobs:getJobsByState(farmId, TheContractorJob.STATE.COMPLETED) > 0
end

-- canTrigger (068): the incident's starting data, or nil. Not before the
-- farm's first completed job (a newsletter feature for a business that's done
-- no work reads oddly) - unless the console asked for a story.
function TheContractorGoodNews:pickStory(farmId)
    if self.forcedStory ~= nil then
        return { story = self.forcedStory }
    end
    if not self:hasCompletedJob(farmId) then
        return nil
    end
    local story = TheContractorGoodNews.chooseStory(self.lastStoryByFarm[farmId])
    if story == nil then
        return nil
    end
    return { story = story.key }
end

-- Stage (server) ----------------------------------------------------------------

function TheContractorGoodNews:onAnnounce(incident)
    local farmId = incident.farmId
    local story = TheContractorGoodNews.getStory(incident.data.story)
    -- A story taken out in an update since the roll.
    if story == nil then
        return TheContractorRandomEvents.DONE
    end
    self.lastStoryByFarm[farmId] = story.key

    local tc = g_currentMission.TheContractor
    local arg
    if story.money ~= nil then
        local amount = TheContractorGoodNews.getMoneyReward(story.money)
        g_currentMission:addMoney(amount, farmId, MoneyType.TC_GOOD_NEWS, true, true)
        tc.Finances:recordGoodNews(farmId, amount)
        arg = "$money_" .. amount
        TCLog.info("TheContractor: farm %d incident %d: good news '%s', %d paid in", farmId, incident.id,
            story.key, amount)
    else
        local amount = TheContractorGoodNews.getReputationReward(farmId, story.reputation or 0)
        tc.Reputation:addReputation(farmId, amount)
        arg = amount
        TCLog.info("TheContractor: farm %d incident %d: good news '%s', +%d reputation", farmId, incident.id,
            story.key, amount)
    end

    local prefix = "tc_goodNews_" .. story.key
    tc.Inbox:postMessage(farmId, TheContractorGoodNews.MESSAGE_KIND, prefix .. "_title", prefix .. "_body", { arg },
        nil, { incidentId = incident.id })
    return TheContractorRandomEvents.DONE
end

-- Persistence (server) -----------------------------------------------------------

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorGoodNews:forgetFarm(farmId)
    self.lastStoryByFarm[farmId] = nil
end

function TheContractorGoodNews:loadFromXMLFile(xmlFile)
    self.lastStoryByFarm = {}
    local index = 0
    while true do
        local key = string.format("%s.goodNews.farm(%d)", TheContractor.SaveKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        local story = getXMLString(xmlFile, key .. "#lastStory")
        if farmId ~= nil and story ~= nil then
            self.lastStoryByFarm[farmId] = story
        end
        index = index + 1
    end
end

function TheContractorGoodNews:saveToXmlFile(xmlFile)
    local farmIds = {}
    for farmId in pairs(self.lastStoryByFarm) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)
    for index, farmId in ipairs(farmIds) do
        local key = string.format("%s.goodNews.farm(%d)", TheContractor.SaveKey, index - 1)
        setXMLInt(xmlFile, key .. "#farmId", farmId)
        setXMLString(xmlFile, key .. "#lastStory", self.lastStoryByFarm[farmId])
    end
end

-- Nothing to stream: only the server picks stories.
function TheContractorGoodNews:writeInitialClientState(streamId, connection)
end

function TheContractorGoodNews:readInitialClientState(streamId, connection)
end

-- Console ----------------------------------------------------------------------

function TheContractorGoodNews.registerConsoleCommands()
    TCConsole.register("company", "goodNews", {
        args = "[story]",
        description = "Good news for your farm now: that story, or a random one (ignores the odds and the cooldown)",
        run = function(farmId, args)
            local tc = g_currentMission.TheContractor
            local keys = {}
            for _, story in ipairs(TheContractorGoodNews.STORIES) do
                table.insert(keys, story.key)
            end

            local wanted = args[1]
            local storyKey = nil
            if wanted ~= nil then
                for _, key in ipairs(keys) do
                    if string.lower(key) == string.lower(wanted) then
                        storyKey = key
                    end
                end
                if storyKey == nil then
                    return string.format("Error: no story '%s'. Stories: %s", wanted, table.concat(keys, ", "))
                end
            else
                storyKey = TheContractorGoodNews.chooseStory(tc.GoodNews.lastStoryByFarm[farmId]).key
            end

            tc.GoodNews.forcedStory = storyKey
            local incident, reason = tc.RandomEvents:triggerEvent(farmId, TheContractorGoodNews.EVENT_TYPE)
            tc.GoodNews.forcedStory = nil
            if incident == nil then
                return string.format("No good news: %s", reason)
            end
            return string.format("Good news '%s' for farm %d (incident %d)", storyKey, farmId, incident.id)
        end,
    })
end

-- Console (068's tcCompany event) ---------------------------------------------------

-- Sets forcedStory for the trigger, or returns why not.
function TheContractorGoodNews:prepareConsoleStory(farmId, wanted)
    if wanted == nil then
        self.forcedStory = TheContractorGoodNews.chooseStory(self.lastStoryByFarm[farmId]).key
        return nil
    end

    local keys = {}
    for _, story in ipairs(TheContractorGoodNews.STORIES) do
        table.insert(keys, story.key)
        if string.lower(story.key) == string.lower(wanted) then
            self.forcedStory = story.key
            return nil
        end
    end
    return string.format("Error: no story '%s'. Stories: %s", wanted, table.concat(keys, ", "))
end
