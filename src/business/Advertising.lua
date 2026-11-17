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
-- Campaigns stack: a farm can run any of the levels at once, each on its
-- own clock, and their bonuses add up (JobGeneration's MAX_HOURLY_CHANCE
-- still caps the total, and the purchase dialog says when a campaign would
-- add less than its full effect, or nothing). Buying a level that's
-- already running extends it by the months bought. Expiry is tracked in
-- months, not days: an absolute month count (getCurrentMonth) a campaign
-- lapses at the start of, so it's immune to save/load timing and to the
-- save's days per month changing (vanilla rescales currentDay then, which
-- would move a day-based expiry). A new campaign bought partway through a
-- month gets the rest of that month free on top of the months paid for.
-- Which campaign brought an offer is the job's offerSource
-- (JobGeneration:getOfferSource).

TheContractorAdvertising = {}
TheContractorAdvertising_mt = Class(TheContractorAdvertising)

-- Ascending order: the purchase dialog lists them in this order, and
-- JobGeneration:getOfferSource credits offers to them in it.
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

    -- campaigns[farmId][levelKey] = the month (getCurrentMonth) that
    -- campaign lapses at the start of. A farm with nothing running has no
    -- entry. The durations bought aren't stored: the only thing displayed
    -- is the months remaining, which the expiry already gives.
    self.campaigns = {}

    MoneyType.TC_ADVERTISING = MoneyType.register("tcAdvertising", "tc_moneyType_advertising")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

-- Months ----------------------------------------------------------------

-- An absolute month count (0 = the save's first month), from currentDay so
-- it survives a change of days per month: vanilla rescales currentDay then
-- to keep the same point in the year.
function TheContractorAdvertising.getCurrentMonth()
    local environment = g_currentMission.environment
    return math.floor((environment.currentDay - 1) / environment.daysPerPeriod)
end

-- Whether today is past the first day of the month.
function TheContractorAdvertising.isMonthUnderway()
    local environment = g_currentMission.environment
    return (environment.currentDay - 1) % environment.daysPerPeriod > 0
end

-- Full months left before a campaign lapsing at expiresOnMonth, not
-- counting what's left of this one once it's underway (0 = it ends at the
-- end of this month).
function TheContractorAdvertising.getMonthsUntil(expiresOnMonth)
    local months = expiresOnMonth - TheContractorAdvertising.getCurrentMonth()
    if TheContractorAdvertising.isMonthUnderway() then
        months = months - 1
    end
    return math.max(0, months)
end

-- Query API -------------------------------------------------------------

-- The farm's running campaigns in LEVELS order: { levelKey, expiresOnMonth }.
function TheContractorAdvertising:getCampaigns(farmId)
    local campaigns = {}
    local byLevel = self.campaigns[farmId]
    if byLevel == nil then
        return campaigns
    end
    for _, levelDef in ipairs(TheContractorAdvertising.LEVELS) do
        if byLevel[levelDef.key] ~= nil then
            table.insert(campaigns, { levelKey = levelDef.key, expiresOnMonth = byLevel[levelDef.key] })
        end
    end
    return campaigns
end

function TheContractorAdvertising:isRunning(farmId, levelKey)
    local byLevel = self.campaigns[farmId]
    return byLevel ~= nil and byLevel[levelKey] ~= nil
end

-- Full months a running campaign has left (getMonthsUntil), 0 if it isn't
-- running.
function TheContractorAdvertising:getMonthsRemaining(farmId, levelKey)
    local byLevel = self.campaigns[farmId]
    if byLevel == nil or byLevel[levelKey] == nil then
        return 0
    end
    return TheContractorAdvertising.getMonthsUntil(byLevel[levelKey])
end

-- 0-1 multiplier on an ad's chanceBonus, from the farm's reputation
-- standing (see MIN_EFFECTIVENESS).
function TheContractorAdvertising:getEffectiveness(farmId)
    local standing = g_currentMission.TheContractor.Reputation:getStanding(farmId)
    local minEffectiveness = TheContractorAdvertising.MIN_EFFECTIVENESS
    return minEffectiveness + standing * (1 - minEffectiveness)
end

-- Each running campaign's bonus at the farm's effectiveness, in LEVELS
-- order: { levelKey, bonus }.
function TheContractorAdvertising:getCampaignBonuses(farmId)
    local effectiveness = self:getEffectiveness(farmId)
    local bonuses = {}
    for _, campaign in ipairs(self:getCampaigns(farmId)) do
        local levelDef = TheContractorAdvertising.LEVELS_BY_KEY[campaign.levelKey]
        if levelDef ~= nil then
            table.insert(bonuses, { levelKey = campaign.levelKey, bonus = levelDef.chanceBonus * effectiveness })
        end
    end
    return bonuses
end

-- Reads as an input to 011's generation roll (see LEVELS): every running
-- campaign's bonus added up. Zero when nothing's running.
function TheContractorAdvertising:getChanceBonus(farmId)
    local total = 0
    for _, campaign in ipairs(self:getCampaignBonuses(farmId)) do
        total = total + campaign.bonus
    end
    return total
end

-- How much of a level's bonus would actually reach the farm's offers if it
-- were added to what's running, 0-1: under 1 when the total would pass
-- JobGeneration's MAX_HOURLY_CHANCE. 1 for a level already running (more
-- months change nothing about its effect).
function TheContractorAdvertising:getAddedShare(farmId, levelKey)
    local levelDef = TheContractorAdvertising.LEVELS_BY_KEY[levelKey]
    if levelDef == nil or self:isRunning(farmId, levelKey) then
        return 1
    end
    local bonus = levelDef.chanceBonus * self:getEffectiveness(farmId)
    if bonus <= 0 then
        return 1
    end
    local running = self:getChanceBonus(farmId)
    local added = TheContractorJobGeneration.getAdvertisingChance(farmId, running + bonus) -
        TheContractorJobGeneration.getAdvertisingChance(farmId, running)
    return math.max(0, math.min(1, added / bonus))
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

function TheContractorAdvertising:canPurchase(farmId, levelKey, durationPeriods)
    return TheContractorAdvertising.isValidDuration(durationPeriods)
        and self:isUnlocked(farmId, levelKey)
        and self:canAfford(farmId, levelKey, durationPeriods)
end

-- The expiry month a purchase would result in: a running campaign runs on
-- for the months bought; a new one starts today and runs the full months
-- bought after the rest of this one.
function TheContractorAdvertising:getExpiryAfterPurchase(farmId, levelKey, durationPeriods)
    local byLevel = self.campaigns[farmId]
    if byLevel ~= nil and byLevel[levelKey] ~= nil then
        return byLevel[levelKey] + durationPeriods
    end

    local expiresOnMonth = TheContractorAdvertising.getCurrentMonth() + durationPeriods
    if TheContractorAdvertising.isMonthUnderway() then
        expiresOnMonth = expiresOnMonth + 1
    end
    return expiresOnMonth
end

-- Mutation API (server-authoritative) ------------------------------------

-- Deducts cost, starts or extends the campaign, and broadcasts the
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

    local expiresOnMonth = self:getExpiryAfterPurchase(farmId, levelKey, durationPeriods)
    self:applyAdvertisingState(farmId, levelKey, expiresOnMonth)

    if g_server ~= nil then
        g_server:broadcastEvent(TCAdvertisingStateChangedEvent.new(farmId, levelKey, expiresOnMonth))
    end

    return true
end

-- The actual state flip for one campaign, run on whichever machine
-- (server, or a client receiving TCAdvertisingStateChangedEvent) is
-- applying the change. expiresOnMonth nil means the campaign has lapsed.
function TheContractorAdvertising:applyAdvertisingState(farmId, levelKey, expiresOnMonth)
    if expiresOnMonth ~= nil then
        self.campaigns[farmId] = self.campaigns[farmId] or {}
        self.campaigns[farmId][levelKey] = expiresOnMonth
        TCLog.info("TheContractor: farm %d is running %s (expires at the start of month %d)", farmId, levelKey,
            expiresOnMonth)
        return
    end

    local byLevel = self.campaigns[farmId]
    if byLevel ~= nil then
        byLevel[levelKey] = nil
        if next(byLevel) == nil then
            self.campaigns[farmId] = nil
        end
    end
    TCLog.info("TheContractor: farm %d's %s campaign has ended", farmId, levelKey)
end

-- Server-only daily expiry check (Q9-style hook, same as 011's hourly
-- generation tick): any campaign that's reached its expiry month ends, and
-- the change is broadcast.
function TheContractorAdvertising:startDailyTick()
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
end

function TheContractorAdvertising:stopDailyTick()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
end

function TheContractorAdvertising:onDayChanged()
    local currentMonth = TheContractorAdvertising.getCurrentMonth()
    local lapsed = {}
    for farmId, byLevel in pairs(self.campaigns) do
        for levelKey, expiresOnMonth in pairs(byLevel) do
            if currentMonth >= expiresOnMonth then
                table.insert(lapsed, { farmId = farmId, levelKey = levelKey })
            end
        end
    end

    for _, entry in ipairs(lapsed) do
        self:applyAdvertisingState(entry.farmId, entry.levelKey, nil)
        if g_server ~= nil then
            g_server:broadcastEvent(TCAdvertisingStateChangedEvent.new(entry.farmId, entry.levelKey, nil))
        end
    end
end

-- Persistence -------------------------------------------------------------

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorAdvertising:forgetFarm(farmId)
    self.campaigns[farmId] = nil
end

-- Saves from before expiry was in months stored the day it lapsed on: it
-- now lapses at the start of the month after that day's, or that day's own
-- month if the day was its first.
function TheContractorAdvertising.getLegacyExpiryMonth(expiresOnDay)
    if expiresOnDay == nil then
        return nil
    end
    local environment = g_currentMission.environment
    local daysPerPeriod = (environment ~= nil and environment.daysPerPeriod) or 1
    return math.ceil((expiresOnDay - 1) / daysPerPeriod)
end

function TheContractorAdvertising:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.campaigns = {}

    local i = 0
    while true do
        local key = string.format("%s.advertising.farm(%d)", TheContractor.SaveKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        if farmId ~= nil then
            -- From before campaigns stacked: the farm's one campaign on the
            -- farm itself.
            local legacyLevel = getXMLString(xmlFile, key .. "#level")
            if legacyLevel ~= nil then
                local expiresOnMonth = getXMLInt(xmlFile, key .. "#expiresOnMonth") or
                    TheContractorAdvertising.getLegacyExpiryMonth(getXMLInt(xmlFile, key .. "#expiresOnDay"))
                self:loadCampaign(farmId, legacyLevel, expiresOnMonth)
            end

            local j = 0
            while true do
                local campaignKey = string.format("%s.campaign(%d)", key, j)
                if not hasXMLProperty(xmlFile, campaignKey) then
                    break
                end
                self:loadCampaign(farmId, getXMLString(xmlFile, campaignKey .. "#level"),
                    getXMLInt(xmlFile, campaignKey .. "#expiresOnMonth"))
                j = j + 1
            end
        end

        i = i + 1
    end
end

function TheContractorAdvertising:loadCampaign(farmId, levelKey, expiresOnMonth)
    if levelKey == nil or expiresOnMonth == nil or TheContractorAdvertising.LEVELS_BY_KEY[levelKey] == nil then
        return
    end
    self.campaigns[farmId] = self.campaigns[farmId] or {}
    self.campaigns[farmId][levelKey] = expiresOnMonth
end

function TheContractorAdvertising:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local i = 0
    for farmId in pairs(self.campaigns) do
        local key = string.format("%s.advertising.farm(%d)", TheContractor.SaveKey, i)
        setXMLInt(xmlFile, key .. "#farmId", farmId)
        for j, campaign in ipairs(self:getCampaigns(farmId)) do
            local campaignKey = string.format("%s.campaign(%d)", key, j - 1)
            setXMLString(xmlFile, campaignKey .. "#level", campaign.levelKey)
            setXMLInt(xmlFile, campaignKey .. "#expiresOnMonth", campaign.expiresOnMonth)
        end
        i = i + 1
    end
end

function TheContractorAdvertising:writeInitialClientState(streamId, connection)
    local farmCount = 0
    for _ in pairs(self.campaigns) do
        farmCount = farmCount + 1
    end
    streamWriteInt32(streamId, farmCount)

    for farmId in pairs(self.campaigns) do
        local campaigns = self:getCampaigns(farmId)
        streamWriteInt32(streamId, farmId)
        streamWriteInt32(streamId, #campaigns)
        for _, campaign in ipairs(campaigns) do
            streamWriteString(streamId, campaign.levelKey)
            streamWriteInt32(streamId, campaign.expiresOnMonth)
        end
    end
end

function TheContractorAdvertising:readInitialClientState(streamId, connection)
    local farmCount = streamReadInt32(streamId)
    for _ = 1, farmCount do
        local farmId = streamReadInt32(streamId)
        local campaignCount = streamReadInt32(streamId)
        for _ = 1, campaignCount do
            local levelKey = streamReadString(streamId)
            local expiresOnMonth = streamReadInt32(streamId)
            self:loadCampaign(farmId, levelKey, expiresOnMonth)
        end
    end
end
