-- Farm-scoped advertising state (012, reworked in 027): buying an ad
-- campaign generates *interest*, a lever separate from reputation (007)
-- that 011's generation roll reads as an extra input — a new company with
-- zero reputation shouldn't get flooded with work just by buying the
-- biggest campaign, so this is additive on top of the reputation-driven
-- base chance, not a replacement for it. Ads only add offer frequency; job
-- size and pay stay reputation-driven (see JobGeneration), so buying the
-- biggest ad early brings more small, low-paid jobs, not better ones (026).
-- On top of that, reputation also scales how well an ad works (027, see
-- getEffectiveness): the same campaign brings in less for an unknown
-- company than for a well-known one.
--
-- One active level per farm at a time, with the player choosing how many
-- periods to run it for (027). The level that's already running can't be
-- bought again until it lapses; buying a different one replaces it (the
-- purchase dialog warns about the lost days). Expiry is tracked as an absolute
-- environment.currentDay value rather than a countdown so it's immune to
-- save/load timing.

TheContractorAdvertising = {}
TheContractorAdvertising_mt = Class(TheContractorAdvertising)

-- Ascending order: the purchase dialog lists them in this order.
-- requiredTier gates purchase to farms that have reached at least that
-- reputation tier (007's TIERS) — bigger campaigns need an established
-- reputation to unlock.
--
-- Balance (026, retuned for 027): chanceBonus is the full-effect bonus,
-- scaled by getEffectiveness before JobGeneration adds it to the hourly
-- chance (ahead of its daysPerPeriod division), so each 0.01 is ~0.24 extra
-- generation hits per period at full effect. At the tier that unlocks each
-- level that works out to roughly: local newspaper +0.5 hits per period,
-- regional magazine +1, national magazine +1.8, online ads +2.9.
-- costPerPeriod is per period rather than per day so what an ad buys
-- doesn't depend on the save's daysPerPeriod, and each is set under the
-- expected earnings of the extra offers at the unlocking tier (allowing
-- for offers the fleet can't do or that get declined), so an ad pays for
-- itself if the player takes the work. At standing 1, the base chance plus
-- online ads' full bonus lands exactly on JobGeneration's MAX_HOURLY_CHANCE.
TheContractorAdvertising.LEVELS = {
    { key = "localNewspaper",   costPerPeriod = 500,   requiredTier = nil,                     chanceBonus = 0.04 },
    { key = "regionalMagazine", costPerPeriod = 2500,  requiredTier = "localContractor",       chanceBonus = 0.07 },
    { key = "nationalMagazine", costPerPeriod = 6000,  requiredTier = "establishedContractor", chanceBonus = 0.11 },
    { key = "onlineAds",        costPerPeriod = 15000, requiredTier = "regionalContractor",    chanceBonus = 0.15 },
}

TheContractorAdvertising.LEVELS_BY_KEY = {}
for _, level in ipairs(TheContractorAdvertising.LEVELS) do
    TheContractorAdvertising.LEVELS_BY_KEY[level.key] = level
end

-- Campaign lengths the purchase dialog offers, in periods (in-game
-- months). Server-side validation only accepts these, so a client can't
-- ask for a zero/negative/huge duration.
TheContractorAdvertising.DURATION_PERIODS = { 1, 2, 3, 6, 12 }

-- Reputation dampening (027): an ad works at MIN_EFFECTIVENESS of its
-- chanceBonus at standing 0, rising linearly to full effect at standing 1
-- (Reputation:getStanding).
TheContractorAdvertising.MIN_EFFECTIVENESS = 0.5

table.insert(FinanceStats.statNames, "tcAdvertising")
FinanceStats.statNameToIndex["tcAdvertising"] = #FinanceStats.statNames

function TheContractorAdvertising.new()
    local self = {}
    setmetatable(self, TheContractorAdvertising_mt)

    -- activeLevel[farmId] = levelKey, expiresOnDay[farmId] = absolute
    -- environment.currentDay the ad lapses on. Both nil/absent for a farm
    -- with no active advertising. The chosen duration isn't stored: an
    -- extension makes "the" duration ambiguous anyway, and the only thing
    -- displayed is the days remaining, which expiresOnDay already gives.
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

-- 0-1 multiplier on an ad's chanceBonus, from the farm's reputation
-- standing (see MIN_EFFECTIVENESS).
function TheContractorAdvertising:getEffectiveness(farmId)
    local standing = g_currentMission.TheContractor.Reputation:getStanding(farmId)
    local minEffectiveness = TheContractorAdvertising.MIN_EFFECTIVENESS
    return minEffectiveness + standing * (1 - minEffectiveness)
end

-- Reads as an input to 011's generation roll (see LEVELS). Zero when no ad
-- is active.
function TheContractorAdvertising:getChanceBonus(farmId)
    local levelKey = self.activeLevel[farmId]
    if levelKey == nil then
        return 0
    end

    local levelDef = TheContractorAdvertising.LEVELS_BY_KEY[levelKey]
    if levelDef == nil then
        return 0
    end

    return levelDef.chanceBonus * self:getEffectiveness(farmId)
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

function TheContractorAdvertising.isValidDuration(durationPeriods)
    for _, choice in ipairs(TheContractorAdvertising.DURATION_PERIODS) do
        if choice == durationPeriods then
            return true
        end
    end
    return false
end

-- A level's price per period at FS25_EconomyScale's price level
-- (TCEconomyScale).
function TheContractorAdvertising.getCostPerPeriod(levelDef)
    return TCEconomyScale.scale(levelDef.costPerPeriod)
end

function TheContractorAdvertising.getCost(levelKey, durationPeriods)
    local levelDef = TheContractorAdvertising.LEVELS_BY_KEY[levelKey]
    if levelDef == nil then
        return 0
    end
    return TheContractorAdvertising.getCostPerPeriod(levelDef) * durationPeriods
end

function TheContractorAdvertising:isUnlocked(farmId, levelKey)
    local levelDef = TheContractorAdvertising.LEVELS_BY_KEY[levelKey]
    if levelDef == nil then
        return false
    end

    if levelDef.requiredTier == nil then
        return true
    end

    local currentTier = g_currentMission.TheContractor.Reputation:getReputationTier(farmId)
    local currentIndex = TheContractorAdvertising.getTierIndex(currentTier.key)
    local requiredIndex = TheContractorAdvertising.getTierIndex(levelDef.requiredTier)
    return currentIndex ~= nil and requiredIndex ~= nil and currentIndex >= requiredIndex
end

function TheContractorAdvertising:canAfford(farmId, levelKey, durationPeriods)
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil then
        return false
    end

    return farm:getBalance() >= TheContractorAdvertising.getCost(levelKey, durationPeriods)
end

-- The running campaign can't be bought again (or extended) until it lapses.
function TheContractorAdvertising:isRunning(farmId, levelKey)
    return self.activeLevel[farmId] == levelKey
end

function TheContractorAdvertising:canPurchase(farmId, levelKey, durationPeriods)
    return TheContractorAdvertising.isValidDuration(durationPeriods)
        and not self:isRunning(farmId, levelKey)
        and self:isUnlocked(farmId, levelKey)
        and self:canAfford(farmId, levelKey, durationPeriods)
end

-- The expiry day a purchase would result in: it starts from today,
-- replacing whatever was running.
function TheContractorAdvertising.getExpiryAfterPurchase(durationPeriods)
    local environment = g_currentMission.environment
    return environment.currentDay + durationPeriods * environment.daysPerPeriod
end

-- Mutation API (server-authoritative) ------------------------------------

-- Deducts cost, sets the new active level + expiry, and broadcasts the
-- resulting state. Only call after canPurchase() has been checked (see
-- TCPurchaseAdvertisingEvent).
function TheContractorAdvertising:purchaseAdvertising(farmId, levelKey, durationPeriods)
    if not g_currentMission:getIsServer() then
        return false
    end

    if TheContractorAdvertising.LEVELS_BY_KEY[levelKey] == nil then
        return false
    end

    local cost = TheContractorAdvertising.getCost(levelKey, durationPeriods)
    g_currentMission:addMoney(-cost, farmId, MoneyType.TC_ADVERTISING, true, true)

    local expiresOnDay = TheContractorAdvertising.getExpiryAfterPurchase(durationPeriods)
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
        TCLog.info("TheContractor: farm %d advertising is now %s (expires day %d)", farmId, levelKey,
            expiresOnDay)
    else
        TCLog.info("TheContractor: farm %d advertising has expired", farmId)
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

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorAdvertising:forgetFarm(farmId)
    self.activeLevel[farmId] = nil
    self.expiresOnDay[farmId] = nil
end

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
