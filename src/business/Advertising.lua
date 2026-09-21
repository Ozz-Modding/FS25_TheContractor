-- Farm-scoped advertising state (012): buying an ad level generates
-- *interest*, a lever separate from reputation (007) that 011's generation
-- roll reads as an extra input — a new company with zero reputation
-- shouldn't get flooded with work just by buying the biggest TV ad, so this
-- is additive on top of the reputation-driven base chance, not a
-- replacement for it. The actual interest-weighting formula is explicitly
-- deferred to 026 (ticket's own design decision); this only needs the
-- purchase action, persistence, and the hook point into 011 to exist.
--
-- One active level per farm at a time (buying a new one while one is
-- already active simply replaces it, per canPurchase not blocking on an
-- existing active ad) with a fixed expiry, tracked as an absolute
-- environment.currentDay value rather than a countdown so it's immune to
-- save/load timing.

TheContractorAdvertising = {}
TheContractorAdvertising_mt = Class(TheContractorAdvertising)

-- Placeholder costs/durations/interest bonus — 026 owns the real balance
-- pass. requiredTier gates purchase to farms that have reached at least
-- that reputation tier (007's TIERS, Q21) — bigger ad types need an
-- established reputation to unlock, per the ticket's design decision.
TheContractorAdvertising.LEVELS = {
    { key = "localNewspaper",   cost = 200,  durationDays = 7, requiredTier = nil,                 chanceBonus = 0.02 },
    { key = "regionalNewspaper", cost = 750,  durationDays = 7, requiredTier = "establishedContractor", chanceBonus = 0.05 },
    { key = "tv",                cost = 2500, durationDays = 7, requiredTier = "regionalContractor",    chanceBonus = 0.10 },
}
TheContractorAdvertising.LEVEL_KEYS = { "localNewspaper", "regionalNewspaper", "tv" }

TheContractorAdvertising.LEVELS_BY_KEY = {}
for _, level in ipairs(TheContractorAdvertising.LEVELS) do
    TheContractorAdvertising.LEVELS_BY_KEY[level.key] = level
end

table.insert(FinanceStats.statNames, "tcAdvertising")
FinanceStats.statNameToIndex["tcAdvertising"] = #FinanceStats.statNames

function TheContractorAdvertising.new()
    local self = {}
    setmetatable(self, TheContractorAdvertising_mt)

    -- activeLevel[farmId] = levelKey, expiresOnDay[farmId] = absolute
    -- environment.currentDay the ad lapses on. Both nil/absent for a farm
    -- with no active advertising.
    self.activeLevel = {}
    self.expiresOnDay = {}

    MoneyType.TC_ADVERTISING = MoneyType.register("tcAdvertising", "tc_moneyType_advertising")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

-- Query API -------------------------------------------------------------

function TheContractorAdvertising:getActiveLevel(farmId)
    return self.activeLevel[farmId]
end

function TheContractorAdvertising:getDaysRemaining(farmId)
    local expiresOnDay = self.expiresOnDay[farmId]
    if expiresOnDay == nil then
        return 0
    end

    return math.max(0, expiresOnDay - g_currentMission.environment.currentDay)
end

-- Reads as an input to 011's generation roll — placeholder magnitude, 026
-- owns the real weighting. Zero when no ad is active.
function TheContractorAdvertising:getChanceBonus(farmId)
    local levelKey = self.activeLevel[farmId]
    if levelKey == nil then
        return 0
    end

    local levelDef = TheContractorAdvertising.LEVELS_BY_KEY[levelKey]
    return levelDef ~= nil and levelDef.chanceBonus or 0
end

-- Reputation.TIERS is ordered ascending; find where tierKey sits in it so
-- gating can compare "at least this tier" rather than exact-match.
function TheContractorAdvertising.getTierIndex(tierKey)
    for i, tier in ipairs(TheContractorReputation.TIERS) do
        if tier.key == tierKey then
            return i
        end
    end
    return nil
end

function TheContractorAdvertising:canPurchase(farmId, levelKey)
    local levelDef = TheContractorAdvertising.LEVELS_BY_KEY[levelKey]
    if levelDef == nil then
        return false
    end

    if levelDef.requiredTier ~= nil then
        local currentTier = g_currentMission.TheContractor.Reputation:getReputationTier(farmId)
        local currentIndex = TheContractorAdvertising.getTierIndex(currentTier.key)
        local requiredIndex = TheContractorAdvertising.getTierIndex(levelDef.requiredTier)
        if currentIndex == nil or requiredIndex == nil or currentIndex < requiredIndex then
            return false
        end
    end

    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil then
        return false
    end

    return farm:getBalance() >= levelDef.cost
end

-- Mutation API (server-authoritative) ------------------------------------

-- Deducts cost, sets the new active level + expiry, and broadcasts the
-- resulting state. Only call after canPurchase() has been checked (see
-- TCPurchaseAdvertisingEvent) — buying a new level while one is already
-- active simply replaces it, there's no stacking.
function TheContractorAdvertising:purchaseAdvertising(farmId, levelKey)
    if not g_currentMission:getIsServer() then
        return false
    end

    local levelDef = TheContractorAdvertising.LEVELS_BY_KEY[levelKey]
    if levelDef == nil then
        return false
    end

    g_currentMission:addMoney(-levelDef.cost, farmId, MoneyType.TC_ADVERTISING, true, true)

    local expiresOnDay = g_currentMission.environment.currentDay + levelDef.durationDays
    self:applyAdvertisingState(farmId, levelKey, expiresOnDay)

    if g_server ~= nil then
        g_server:broadcastEvent(TCAdvertisingStateChangedEvent.new(farmId, levelKey, expiresOnDay))
    end

    return true
end

-- The actual state flip, run on whichever machine (server, or a client
-- receiving TCAdvertisingStateChangedEvent) is applying the change.
-- levelKey/expiresOnDay both nil means "no active advertising" (expiry).
function TheContractorAdvertising:applyAdvertisingState(farmId, levelKey, expiresOnDay)
    self.activeLevel[farmId] = levelKey
    self.expiresOnDay[farmId] = expiresOnDay

    if levelKey ~= nil then
        Logging.info("TheContractor: farm %d advertising is now %s (expires day %d)", farmId, levelKey,
            expiresOnDay)
    else
        Logging.info("TheContractor: farm %d advertising has expired", farmId)
    end
end

-- Server-only daily expiry check (Q9-style hook, same as 011's hourly
-- generation tick): any farm whose active ad has reached its expiry day
-- reverts to "no active advertising" and broadcasts the change.
function TheContractorAdvertising:startDailyTick()
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
end

function TheContractorAdvertising:stopDailyTick()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
end

function TheContractorAdvertising:onDayChanged(currentDay)
    for farmId, expiresOnDay in pairs(self.expiresOnDay) do
        if expiresOnDay ~= nil and currentDay >= expiresOnDay and self.activeLevel[farmId] ~= nil then
            self:applyAdvertisingState(farmId, nil, nil)

            if g_server ~= nil then
                g_server:broadcastEvent(TCAdvertisingStateChangedEvent.new(farmId, nil, nil))
            end
        end
    end
end

-- Persistence -------------------------------------------------------------

function TheContractorAdvertising:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.activeLevel = {}
    self.expiresOnDay = {}

    local i = 0
    while true do
        local key = string.format("%s.advertising.farm(%d)", TheContractor.SaveKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        local levelKey = getXMLString(xmlFile, key .. "#level")
        local expiresOnDay = getXMLInt(xmlFile, key .. "#expiresOnDay")
        self.activeLevel[farmId] = levelKey
        self.expiresOnDay[farmId] = expiresOnDay

        i = i + 1
    end
end

function TheContractorAdvertising:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local i = 0
    for farmId, levelKey in pairs(self.activeLevel) do
        local key = string.format("%s.advertising.farm(%d)", TheContractor.SaveKey, i)
        setXMLInt(xmlFile, key .. "#farmId", farmId)
        setXMLString(xmlFile, key .. "#level", levelKey)
        setXMLInt(xmlFile, key .. "#expiresOnDay", self.expiresOnDay[farmId])
        i = i + 1
    end
end

function TheContractorAdvertising:writeInitialClientState(streamId, connection)
    local farmCount = 0
    for _ in pairs(self.activeLevel) do
        farmCount = farmCount + 1
    end
    streamWriteInt32(streamId, farmCount)

    for farmId, levelKey in pairs(self.activeLevel) do
        streamWriteInt32(streamId, farmId)
        streamWriteString(streamId, levelKey)
        streamWriteInt32(streamId, self.expiresOnDay[farmId])
    end
end

function TheContractorAdvertising:readInitialClientState(streamId, connection)
    local farmCount = streamReadInt32(streamId)
    for _ = 1, farmCount do
        local farmId = streamReadInt32(streamId)
        local levelKey = streamReadString(streamId)
        local expiresOnDay = streamReadInt32(streamId)
        self.activeLevel[farmId] = levelKey
        self.expiresOnDay[farmId] = expiresOnDay
    end
end
