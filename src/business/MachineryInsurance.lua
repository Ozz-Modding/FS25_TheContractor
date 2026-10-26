-- Machinery insurance (070): an optional overhead (051) that insures the
-- farm's machinery, at one of three levels of cover (LEVELS). When a random
-- event (068) ends in a loss - for now only a theft (069) the police don't
-- solve - an insured farm claims, and the insurer pays the vehicle's value
-- times the level's payout share, less the excess.
--
-- The premium is a share of the insured fleet's value a year (premiumRate
-- times the sell price of every owned vehicle the farm still has), plus
-- CLAIMS_LOADING per claim in the last CLAIMS_WINDOW_PERIODS, like 052's.
-- Vehicle values are already game prices, so the premium and the payout
-- aren't scaled (the overhead is `unscaled`); the excess is a 1x UK cost
-- and is (TheContractorSettings:scaleCost).
--
-- The policy covers PERILS. An event type that can be insured names its
-- peril, and asks getCoverLevel on the day it happens: cover is judged
-- then, so taking a policy out afterwards doesn't help. The level found is
-- kept in the incident's data as coverLevel ("" for uninsured).
--
-- The claim is a run of stages (getClaimStages) the event type puts in its
-- own stage list. They read the incident's data: name, value (copied when
-- it happened) and coverLevel.
--   claim            the day the loss is known. With an office administrator
--                    (057) the claim goes in at once and settles in
--                    ADMIN_SETTLE_DELAY_PERIODS. Without, an inbox message
--                    has a Submit claim action (submitted anyway if it
--                    expires unanswered), and it settles SETTLE_DELAY_PERIODS
--                    after that.
--                    From then until it settles, an Overview notice
--                    says the claim's in (claimNoticeId).
--   claimSettle /    pays out (tcInsurancePayout), records the excess as a
--   claimSettleFast  claim and the payout as its own year-to-date figure
--                    (049), puts the claim on the history, then goes on to
--                    the stage the event type named (069: writtenOff).
--
-- State: the claims history (historyByFarm), saved and synced like 052's,
-- since clients price the policy for the Finances tab. Open claims live in
-- their 068 incidents.

TheContractorMachineryInsurance = {}
TheContractorMachineryInsurance_mt = Class(TheContractorMachineryInsurance)

TheContractorMachineryInsurance.OVERHEAD_KEY = "machineryInsurance"

-- payoutShare of the value, less excess (1x UK, scaled). premiumRate is
-- the share of the fleet's value a year. courtesyVehicle: a stolen vehicle
-- is replaced on loan until the claim settles (071).
TheContractorMachineryInsurance.LEVELS = {
    { key = "basic", payoutShare = 0.8, excess = 1000, premiumRate = 0.010 },
    { key = "standard", payoutShare = 0.9, excess = 500, premiumRate = 0.014 },
    { key = "comprehensive", payoutShare = 1.0, excess = 250, premiumRate = 0.018, courtesyVehicle = true },
}

TheContractorMachineryInsurance.PERILS = {
    theft = true,
}

TheContractorMachineryInsurance.CLAIMS_LOADING = 0.35

-- 096: a vehicle with ADS's anti-theft system fitted (TheContractorTheft.
-- hasAntiTheft) counts this much less of its value in the premium. The
-- "_antiTheft" description says 15% in words: change both together.
TheContractorMachineryInsurance.ANTI_THEFT_DISCOUNT = 0.15
TheContractorMachineryInsurance.CLAIMS_WINDOW_PERIODS = 36

-- Months from the claim going in to the money arriving.
TheContractorMachineryInsurance.SETTLE_DELAY_PERIODS = { 1, 2 }
TheContractorMachineryInsurance.ADMIN_SETTLE_DELAY_PERIODS = { 0.5, 1 }

TheContractorMachineryInsurance.STAGE = {
    CLAIM = "claim",
    SETTLE = "claimSettle",
    SETTLE_FAST = "claimSettleFast",
}

TheContractorMachineryInsurance.MESSAGE_KIND = "insuranceClaim"
TheContractorMachineryInsurance.ACTION_SUBMIT = "submitClaim"
TheContractorMachineryInsurance.NOTICE_MONTHS = 1

table.insert(FinanceStats.statNames, "tcInsurancePayout")
FinanceStats.statNameToIndex["tcInsurancePayout"] = #FinanceStats.statNames

function TheContractorMachineryInsurance.new()
    local self = {}
    setmetatable(self, TheContractorMachineryInsurance_mt)

    -- historyByFarm[farmId] = { { periodIndex, amount }, ... } - settled
    -- claims, for the premium loading. Synced to clients.
    self.historyByFarm = {}

    MoneyType.TC_INSURANCE_PAYOUT = MoneyType.register("tcInsurancePayout", "tc_moneyType_insurancePayout")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

function TheContractorMachineryInsurance.getLevel(levelKey)
    for _, level in ipairs(TheContractorMachineryInsurance.LEVELS) do
        if level.key == levelKey then
            return level
        end
    end
    return nil
end

function TheContractorMachineryInsurance.getLevelTextKey(levelKey)
    return "tc_insurance_level_" .. levelKey
end

-- Every machine, at load, once Overheads, the Inbox and RandomEvents exist.
function TheContractorMachineryInsurance:register(overheads, inbox, randomEvents)
    self.overheads = overheads
    self.randomEvents = randomEvents

    local levels = {}
    for _, level in ipairs(TheContractorMachineryInsurance.LEVELS) do
        local levelKey = level.key
        table.insert(levels, {
            key = levelKey,
            l10nKey = TheContractorMachineryInsurance.getLevelTextKey(levelKey),
            annualCost = function(farmId)
                return self:getPremium(farmId, levelKey)
            end,
            getDescription = function()
                return TheContractorMachineryInsurance.getLevelDescription(levelKey)
            end,
        })
    end

    local excesses = {}
    for i, level in ipairs(TheContractorMachineryInsurance.LEVELS) do
        excesses[i] = level.excess
    end

    overheads:registerOverhead({
        key = TheContractorMachineryInsurance.OVERHEAD_KEY,
        l10nKey = "tc_overhead_machineryInsurance",
        mandatory = false,
        unscaled = true,
        levels = levels,
        getRenewalLoading = function(farmId)
            local count = self:getRecentClaimCount(farmId)
            return count, math.floor(count * TheContractorMachineryInsurance.CLAIMS_LOADING * 100 + 0.5)
        end,
        descriptionAmounts = excesses,
        -- 096: the anti-theft discount, only where it can be fitted.
        getDescriptionKey = function()
            return TheContractorTheft.isAntiTheftOffered() and "tc_overhead_machineryInsurance_desc_antiTheft" or
                "tc_overhead_machineryInsurance_desc"
        end,
    })

    inbox:registerMessageKind(TheContractorMachineryInsurance.MESSAGE_KIND, {
        onAction = function(farmId, message, actionKey)
            if actionKey == TheContractorMachineryInsurance.ACTION_SUBMIT then
                self:submitClaim(message.payload.incidentId)
            end
        end,
        onExpire = function(farmId, message)
            self:submitClaim(message.payload.incidentId)
        end,
        getConfirmText = function(message, actionKey)
            if actionKey ~= TheContractorMachineryInsurance.ACTION_SUBMIT then
                return nil
            end
            return string.format(g_i18n:getText("tc_insurance_submitConfirm"), tostring(message.args[1]))
        end,
        chipKey = "tc_inbox_chipInsurance",
        chipTone = "info",
    })
end

-- "pays 80% of the value, 1,000 excess" - for the level picker.
function TheContractorMachineryInsurance.getLevelDescription(levelKey)
    local level = TheContractorMachineryInsurance.getLevel(levelKey)
    local textKey = level.courtesyVehicle and "tc_insurance_levelDescriptionCourtesy" or "tc_insurance_levelDescription"
    return string.format(g_i18n:getText(textKey), math.floor(level.payoutShare * 100 + 0.5),
        g_i18n:formatMoney(g_currentMission.TheContractor.Settings:scaleCost(level.excess), 0, true, true))
end

-- Premium and history (every machine) ------------------------------------------

-- What the farm's insured machinery is worth: the sell price of every owned
-- vehicle it still has (a stolen one's gone). Then what the premium is
-- worked out on: the same, with each vehicle that has an anti-theft system
-- (096) at ANTI_THEFT_DISCOUNT less. And how many have one.
function TheContractorMachineryInsurance:getFleetValue(farmId)
    local theft = g_currentMission.TheContractor.Theft
    local total, insured, fitted = 0, 0, 0
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if not vehicle.isDeleted and not vehicle.isPallet and vehicle.getOwnerFarmId ~= nil and
            vehicle:getOwnerFarmId() == farmId and vehicle.propertyState == VehiclePropertyState.OWNED and
            vehicle.getSellPrice ~= nil and
            (theft == nil or not theft:isStolen(NetworkUtil.getObjectId(vehicle))) then
            local value = math.max(0, vehicle:getSellPrice())
            total = total + value
            if TheContractorTheft.hasAntiTheft(vehicle) then
                insured = insured + value * (1 - TheContractorMachineryInsurance.ANTI_THEFT_DISCOUNT)
                fitted = fitted + 1
            else
                insured = insured + value
            end
        end
    end
    return total, insured, fitted
end

-- Settled claims in the last CLAIMS_WINDOW_PERIODS, this period included.
function TheContractorMachineryInsurance:getRecentClaimCount(farmId)
    local firstPeriod = TCCalendar.getPeriodIndex() - TheContractorMachineryInsurance.CLAIMS_WINDOW_PERIODS + 1
    local count = 0
    for _, claim in ipairs(self.historyByFarm[farmId] or {}) do
        if claim.periodIndex >= firstPeriod then
            count = count + 1
        end
    end
    return count
end

-- A year's premium at this level right now (a game price, not scaled).
function TheContractorMachineryInsurance:getPremium(farmId, levelKey)
    local level = TheContractorMachineryInsurance.getLevel(levelKey) or TheContractorMachineryInsurance.LEVELS[1]
    local _, insuredValue = self:getFleetValue(farmId)
    return insuredValue * level.premiumRate *
        (1 + TheContractorMachineryInsurance.CLAIMS_LOADING * self:getRecentClaimCount(farmId))
end

-- The farm's level of cover against this peril today, or nil.
function TheContractorMachineryInsurance:getCoverLevel(farmId, peril)
    if not TheContractorMachineryInsurance.PERILS[peril] or self.overheads == nil then
        return nil
    end
    local state = self.overheads:getState(farmId, TheContractorMachineryInsurance.OVERHEAD_KEY)
    if state == nil or not state.enabled then
        return nil
    end
    local definition = self.overheads:getDefinition(TheContractorMachineryInsurance.OVERHEAD_KEY)
    return TheContractorOverheads.getLevel(definition, state.level).key
end

-- What a claim pays: value * the level's share, less the (scaled) excess,
-- never below 0. Returns payout, excess borne (what the excess took off).
function TheContractorMachineryInsurance.getSettlement(value, levelKey)
    local level = TheContractorMachineryInsurance.getLevel(levelKey)
    if level == nil then
        return 0, 0
    end
    local covered = math.floor(math.max(0, value) * level.payoutShare)
    local excess = g_currentMission.TheContractor.Settings:scaleCost(level.excess)
    local payout = math.max(0, covered - excess)
    return payout, covered - payout
end

function TheContractorMachineryInsurance:applyClaimRecorded(farmId, record)
    if self.historyByFarm[farmId] == nil then
        self.historyByFarm[farmId] = {}
    end
    table.insert(self.historyByFarm[farmId], record)
end

-- Claim stages (server) ------------------------------------------------------------

-- The stages an insured event type puts in its own list, after the loss is
-- known. Settling goes on to afterStageKey.
function TheContractorMachineryInsurance:getClaimStages(afterStageKey)
    local stage = TheContractorMachineryInsurance.STAGE
    return {
        { key = stage.CLAIM, run = function(incident)
            return self:onClaim(incident)
        end },
        { key = stage.SETTLE, delayPeriods = TheContractorMachineryInsurance.SETTLE_DELAY_PERIODS,
            run = function(incident)
                self:settle(incident)
                return afterStageKey
            end },
        { key = stage.SETTLE_FAST, delayPeriods = TheContractorMachineryInsurance.ADMIN_SETTLE_DELAY_PERIODS,
            run = function(incident)
                self:settle(incident)
                return afterStageKey
            end },
    }
end

local function getToday()
    return g_currentMission.environment.currentMonotonicDay
end

function TheContractorMachineryInsurance:onClaim(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local args = { data.name, "$l10n_" .. TheContractorMachineryInsurance.getLevelTextKey(data.coverLevel) }

    if tc.Office:hasAdministrator(incident.farmId) then
        data.claimSubmittedDay = getToday()
        self:publishClaimNotice(incident)
        tc.Inbox:postMessage(incident.farmId, TheContractorMachineryInsurance.MESSAGE_KIND,
            "tc_insurance_claimTitle", "tc_insurance_claimByAdminBody", args, nil, { incidentId = incident.id })
        TCLog.info("TheContractor: farm %d incident %d: administrator submitted the insurance claim for %s",
            incident.farmId, incident.id, data.name)
        return TheContractorMachineryInsurance.STAGE.SETTLE_FAST
    end

    -- A month to answer; unanswered, it goes in anyway.
    tc.Inbox:postMessage(incident.farmId, TheContractorMachineryInsurance.MESSAGE_KIND,
        "tc_insurance_claimTitle", "tc_insurance_claimBody", args,
        { { key = TheContractorMachineryInsurance.ACTION_SUBMIT, textKey = "tc_insurance_submitButton" } },
        { incidentId = incident.id }, TCCalendar.getDaysPerPeriodOn(getToday()))
    return TheContractorRandomEvents.WAIT
end

-- The Submit claim action, or its message expiring. Ignored unless the
-- incident is still waiting on it.
function TheContractorMachineryInsurance:submitClaim(incidentId)
    local incident = incidentId ~= nil and self.randomEvents:getIncident(incidentId) or nil
    if incident == nil or incident.stage ~= TheContractorMachineryInsurance.STAGE.CLAIM or
        incident.nextStageDay > 0 then
        return
    end
    incident.data.claimSubmittedDay = getToday()
    self:publishClaimNotice(incident)
    TCLog.info("TheContractor: farm %d incident %d: insurance claim for %s submitted", incident.farmId,
        incident.id, incident.data.name)
    self.randomEvents:goToStage(incident, TheContractorMachineryInsurance.STAGE.SETTLE)
end

-- An Overview notice from the claim going in until it settles; its id is
-- kept in the incident's data (claimNoticeId) to take it down.
function TheContractorMachineryInsurance:publishClaimNotice(incident)
    incident.data.claimNoticeId = g_currentMission.TheContractor.Notices:publish(incident.farmId,
        string.format(g_i18n:getText("tc_insurance_claimNotice"), incident.data.name))
end

function TheContractorMachineryInsurance:settle(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local farmId = incident.farmId
    if data.claimNoticeId ~= nil then
        tc.Notices:remove(data.claimNoticeId)
        data.claimNoticeId = nil
    end
    local level = TheContractorMachineryInsurance.getLevel(data.coverLevel)
    if level == nil then
        return
    end

    local payout, excessBorne = TheContractorMachineryInsurance.getSettlement(data.value, data.coverLevel)
    data.payout = payout

    if payout > 0 then
        g_currentMission:addMoney(payout, farmId, MoneyType.TC_INSURANCE_PAYOUT, true, true)
    end
    tc.Finances:recordClaims(farmId, excessBorne)
    tc.Finances:recordInsurancePayout(farmId, payout)

    local record = { periodIndex = TCCalendar.getPeriodIndex(), amount = data.value }
    self:applyClaimRecorded(farmId, record)
    if g_server ~= nil then
        g_server:broadcastEvent(TCInsuranceClaimRecordedEvent.new(farmId, record))
    end

    tc.Inbox:postMessage(farmId, TheContractorMachineryInsurance.MESSAGE_KIND, "tc_insurance_settledTitle",
        "tc_insurance_settledBody", {
            data.name,
            "$money_" .. data.value,
            "$l10n_" .. TheContractorMachineryInsurance.getLevelTextKey(level.key),
            math.floor(level.payoutShare * 100 + 0.5),
            "$money_" .. excessBorne,
            "$money_" .. payout,
        }, nil, { incidentId = incident.id })
    tc.Notices:publish(farmId, string.format(g_i18n:getText("tc_insurance_settledNotice"),
        g_i18n:formatMoney(payout, 0, true, true), data.name), TheContractorMachineryInsurance.NOTICE_MONTHS)

    TCLog.info("TheContractor: farm %d incident %d: insurance settled for %s (%s): value %.0f, paid %.0f, excess %.0f",
        farmId, incident.id, data.name, level.key, data.value, payout, excessBorne)
end

-- Wire serialization ----------------------------------------------------------------

function TheContractorMachineryInsurance.writeRecord(streamId, record)
    streamWriteInt32(streamId, record.periodIndex)
    streamWriteFloat32(streamId, record.amount)
end

function TheContractorMachineryInsurance.readRecord(streamId)
    return { periodIndex = streamReadInt32(streamId), amount = streamReadFloat32(streamId) }
end

-- Persistence -------------------------------------------------------------------------

function TheContractorMachineryInsurance:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.historyByFarm = {}

    local rootKey = string.format("%s.machineryInsurance", TheContractor.SaveKey)
    local index = 0
    while true do
        local key = string.format("%s.claim(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        if farmId ~= nil then
            self:applyClaimRecorded(farmId, {
                periodIndex = Utils.getNoNil(getXMLInt(xmlFile, key .. "#periodIndex"), 0),
                amount = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#amount"), 0),
            })
        end
        index = index + 1
    end
end

-- Claims older than the loading window are dropped: nothing reads them.
function TheContractorMachineryInsurance:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.machineryInsurance", TheContractor.SaveKey)
    local firstPeriod = TCCalendar.getPeriodIndex() - TheContractorMachineryInsurance.CLAIMS_WINDOW_PERIODS + 1
    local index = 0
    for farmId, history in pairs(self.historyByFarm) do
        for _, record in ipairs(history) do
            if record.periodIndex >= firstPeriod then
                local key = string.format("%s.claim(%d)", rootKey, index)
                setXMLInt(xmlFile, key .. "#farmId", farmId)
                setXMLInt(xmlFile, key .. "#periodIndex", record.periodIndex)
                setXMLFloat(xmlFile, key .. "#amount", record.amount)
                index = index + 1
            end
        end
    end
end

function TheContractorMachineryInsurance:writeInitialClientState(streamId, connection)
    local entries = {}
    for farmId, history in pairs(self.historyByFarm) do
        for _, record in ipairs(history) do
            table.insert(entries, { farmId = farmId, record = record })
        end
    end

    streamWriteInt32(streamId, #entries)
    for _, entry in ipairs(entries) do
        streamWriteInt32(streamId, entry.farmId)
        TheContractorMachineryInsurance.writeRecord(streamId, entry.record)
    end
end

function TheContractorMachineryInsurance:readInitialClientState(streamId, connection)
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local farmId = streamReadInt32(streamId)
        self:applyClaimRecorded(farmId, TheContractorMachineryInsurance.readRecord(streamId))
    end
end

-- Console commands (tcFinance - see TCConsole) -----------------------------------------

function TheContractorMachineryInsurance.registerConsoleCommands()
    TCConsole.register("finance", "insurance", {
        description = "Machinery insurance: your cover, the fleet value, each level's premium, claims",
        serverOnly = false,
        run = function(farmId, args)
            local insurance = g_currentMission.TheContractor.MachineryInsurance
            local overheads = g_currentMission.TheContractor.Overheads
            local state = overheads:getState(farmId, TheContractorMachineryInsurance.OVERHEAD_KEY)
            local cover = "not insured"
            if state ~= nil and state.enabled then
                cover = string.format("insured, %s cover%s", insurance:getCoverLevel(farmId, "theft"),
                    state.pendingLevel ~= nil and string.format(" (%s from renewal)", state.pendingLevel) or "")
            end

            local fleetValue, insuredValue, fitted = insurance:getFleetValue(farmId)
            local lines = { string.format("Farm %d: %s. Fleet value %.0f, %d claim(s) in the last 3 years", farmId,
                cover, fleetValue, insurance:getRecentClaimCount(farmId)) }
            if fitted > 0 then
                table.insert(lines, string.format("  %d vehicle(s) with an anti-theft system: priced on %.0f (%d%% off theirs)",
                    fitted, insuredValue, math.floor(TheContractorMachineryInsurance.ANTI_THEFT_DISCOUNT * 100 + 0.5)))
            end
            for _, level in ipairs(TheContractorMachineryInsurance.LEVELS) do
                local excess = g_currentMission.TheContractor.Settings:scaleCost(level.excess)
                table.insert(lines, string.format("  %s: %.0f a year, pays %d%% less %.0f excess", level.key,
                    insurance:getPremium(farmId, level.key), math.floor(level.payoutShare * 100 + 0.5), excess))
            end

            local claims = {}
            for _, incident in ipairs(insurance.randomEvents:getIncidents(farmId)) do
                local stage = incident.stage
                if stage == TheContractorMachineryInsurance.STAGE.CLAIM or
                    stage == TheContractorMachineryInsurance.STAGE.SETTLE or
                    stage == TheContractorMachineryInsurance.STAGE.SETTLE_FAST then
                    local courtesyId = incident.data.courtesyVehicleId
                    table.insert(claims, string.format("  #%d %s (%.0f, %s): %s%s", incident.id,
                        tostring(incident.data.name), incident.data.value or 0, tostring(incident.data.coverLevel),
                        stage == TheContractorMachineryInsurance.STAGE.CLAIM and "waiting to be submitted" or
                        string.format("settles day %d", incident.nextStageDay),
                        courtesyId ~= nil and courtesyId ~= 0 and
                        string.format(", courtesy %s (%d)", tostring(incident.data.courtesyName), courtesyId) or ""))
                elseif TheContractorCourtesyVehicle ~= nil and stage == TheContractorCourtesyVehicle.STAGE.RETRY then
                    table.insert(claims, string.format("  #%d %s: settled, courtesy %s (%d) to be collected once free",
                        incident.id, tostring(incident.data.name), tostring(incident.data.courtesyName),
                        incident.data.courtesyVehicleId or 0))
                end
            end
            table.insert(lines, string.format("Open claims: %d", #claims))
            for _, line in ipairs(claims) do
                table.insert(lines, line)
            end
            return table.concat(lines, "\n")
        end,
    })
end
