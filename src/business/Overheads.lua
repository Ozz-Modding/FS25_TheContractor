-- Business overheads (051): recurring costs such as insurance policies,
-- memberships and programmes. Each one is registered here as a definition,
-- and each farm has its own state for it. Later tickets register their own
-- (052 public liability, 053 trade association + legal cover, 055 health
-- and safety):
--
--   tc.Overheads:registerOverhead({
--       key = "publicLiability",
--       l10nKey = "tc_overhead_publicLiability",   -- name; "<l10nKey>_desc" is its description
--       mandatory = false,
--       isRequired = function(farmId) ... end,     -- mandatory only, optional: false = not needed now
--       annualCost = function(farmId) ... end,     -- 1x UK; getAnnualCost scales it (Settings:scaleCost)
--       getRenewalLoading = function(farmId) ... end, -- optional only, optional:
--                                                  -- claimCount, loadingPercent for the renewal notice (052)
--       descriptionAmounts = { 800, 60 },          -- optional: 1x UK money for the description's %s,
--                                                  -- in order, scaled and formatted in the player's currency
--       onActiveChanged = function(farmId, isActive) ... end, -- optional, server: the farm's policy
--                                                  -- started or ended (053 reprices legal cover)
--       getDescriptionKey = function() ... end,    -- optional (096): the description's l10n key,
--                                                  -- instead of "<l10nKey>_desc"
--       unscaled = true,                           -- optional: annualCost is already a game price
--                                                  -- (a share of vehicle values, say), not 1x UK
--       levels = {                                 -- optional (070): levels of cover, each with its
--           { key = "basic", l10nKey = "...",      -- own price, used instead of annualCost
--             annualCost = function(farmId) ... end },
--       },
--   })
--
-- Register on every machine, at load: clients need the name and the cost
-- (for the Finances tab and its forecast), the server does the billing.
--
-- A policy runs in yearly terms from the period it was taken out, priced
-- once per term (at the renewal notice, else at renewal), so hiring
-- mid-term doesn't change the price until renewal (repriceMidTerm is the
-- exception, for a discount that comes and goes with another policy). It's
-- paid either:
--   - annually: the term's cost less ANNUAL_DISCOUNT, up front, or
--   - monthly: a twelfth of the term's cost each PERIOD_CHANGED.
-- Switching billing takes effect at the next renewal. Cancelling never
-- refunds: an annual policy runs to the end of its paid term, a monthly
-- one stops at the next period. Charges go through even if the farm can't
-- afford them, like salaries (036).
--
-- One period before a renewal the farm gets an inbox message (050) with the
-- new price and Pay annually / Pay monthly / Cancel (no Cancel for a
-- mandatory one). Unanswered, it renews on the current terms.
--
-- A mandatory overhead starts by itself as soon as it's required (for
-- employer's liability, once the farm employs anyone) and can't be
-- cancelled; once it's no longer required it just isn't renewed.
--
-- An overhead with levels (070) is taken out at a level the player picks,
-- and the level can be changed for the next term (pendingLevel, like
-- pendingBilling). Overheads without levels have level nil.
--
-- State, per farm per overhead: { enabled, billing, pendingBilling,
-- renewalPeriod, paidUntil, termCost, quotedCost, cancelled, level,
-- pendingLevel } - periods are TCCalendar period indices. paidUntil is the
-- first period not paid for. noticePeriod (the renewal a notice went out
-- for) stays on the server.

TheContractorOverheads = {}
TheContractorOverheads_mt = Class(TheContractorOverheads)

TheContractorOverheads.BILLING = {
    ANNUAL = "annual",
    MONTHLY = "monthly",
}

-- Annual billing is this much cheaper than twelve monthly payments: paying
-- monthly is credit, with interest.
TheContractorOverheads.ANNUAL_DISCOUNT = 0.12
TheContractorOverheads.TERM_PERIODS = 12

-- Employer's liability (051): £400 plus £100 per hired worker a year.
TheContractorOverheads.EMPLOYERS_LIABILITY_BASE = 400
TheContractorOverheads.EMPLOYERS_LIABILITY_PER_WORKER = 100

TheContractorOverheads.RENEWAL_MESSAGE_KIND = "overheadRenewal"
TheContractorOverheads.ACTION = {
    PAY_ANNUALLY = "payAnnually",
    PAY_MONTHLY = "payMonthly",
    CANCEL = "cancel",
}

-- How long the "policy started" notice stays on the Overview board.
TheContractorOverheads.STARTED_NOTICE_MONTHS = 1

table.insert(FinanceStats.statNames, "tcOverheads")
FinanceStats.statNameToIndex["tcOverheads"] = #FinanceStats.statNames

function TheContractorOverheads.new()
    local self = {}
    setmetatable(self, TheContractorOverheads_mt)

    -- definitions in registration order; definitionsByKey[key] = definition
    self.definitions = {}
    self.definitionsByKey = {}

    -- statesByFarm[farmId][key] = state
    self.statesByFarm = {}

    MoneyType.TC_OVERHEADS = MoneyType.register("tcOverheads", "tc_moneyType_overheads")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    self:registerOverhead({
        key = "employersLiability",
        l10nKey = "tc_overhead_employersLiability",
        mandatory = true,
        isRequired = function(farmId)
            return g_currentMission.TheContractor.Staff:getHeadcount(farmId) > 0
        end,
        annualCost = function(farmId)
            return TheContractorOverheads.EMPLOYERS_LIABILITY_BASE +
                TheContractorOverheads.EMPLOYERS_LIABILITY_PER_WORKER *
                g_currentMission.TheContractor.Staff:getHeadcount(farmId)
        end,
        descriptionAmounts = { TheContractorOverheads.EMPLOYERS_LIABILITY_BASE,
            TheContractorOverheads.EMPLOYERS_LIABILITY_PER_WORKER },
    })

    return self
end

-- Registry --------------------------------------------------------------------

function TheContractorOverheads:registerOverhead(definition)
    if self.definitionsByKey[definition.key] == nil then
        table.insert(self.definitions, definition)
    end
    self.definitionsByKey[definition.key] = definition
end

function TheContractorOverheads:getDefinitions()
    return self.definitions
end

function TheContractorOverheads:getDefinition(key)
    return self.definitionsByKey[key]
end

-- Inbox messages (050) - every machine, after the Inbox exists.
function TheContractorOverheads:registerMessageKinds(inbox)
    inbox:registerMessageKind(TheContractorOverheads.RENEWAL_MESSAGE_KIND, {
        onAction = function(farmId, message, actionKey)
            self:onRenewalAnswered(farmId, message, actionKey)
        end,
        category = "admin",
        chipTone = "info",
    })
end

-- Query API -----------------------------------------------------------------------

function TheContractorOverheads:getState(farmId, key)
    local farmStates = self.statesByFarm[farmId]
    return farmStates ~= nil and farmStates[key] or nil
end

function TheContractorOverheads:isActive(farmId, key)
    local state = self:getState(farmId, key)
    return state ~= nil and state.enabled
end

-- Required now: a mandatory overhead whose isRequired says so (or has none).
function TheContractorOverheads:isRequired(farmId, definition)
    if not definition.mandatory then
        return false
    end
    return definition.isRequired == nil or definition.isRequired(farmId)
end

-- A level of cover (070) by key, falling back to the first; nil for an
-- overhead without levels.
function TheContractorOverheads.getLevel(definition, levelKey)
    if definition.levels == nil or #definition.levels == 0 then
        return nil
    end
    for _, level in ipairs(definition.levels) do
        if level.key == levelKey then
            return level
        end
    end
    return definition.levels[1]
end

-- Whether levelKey is one of the definition's levels (nil for one without).
function TheContractorOverheads.isValidLevel(definition, levelKey)
    if definition.levels == nil or #definition.levels == 0 then
        return levelKey == nil
    end
    for _, level in ipairs(definition.levels) do
        if level.key == levelKey then
            return true
        end
    end
    return false
end

-- The level the next term will use.
function TheContractorOverheads.getNextLevel(state)
    return state.pendingLevel or state.level
end

-- The price for a year's cover right now (at levelKey, for an overhead with
-- levels), scaled from the 1x UK price (TheContractorSettings:scaleCost)
-- unless the definition is unscaled.
function TheContractorOverheads:getAnnualCost(farmId, definition, levelKey)
    local level = TheContractorOverheads.getLevel(definition, levelKey)
    local annualCost = level ~= nil and level.annualCost or definition.annualCost
    local cost = math.max(0, annualCost(farmId))
    if definition.unscaled then
        return cost
    end
    return g_currentMission.TheContractor.Settings:scaleCost(cost)
end

-- What one charge comes to for a term costing annualCost.
function TheContractorOverheads.getChargeAmount(annualCost, billing)
    if billing == TheContractorOverheads.BILLING.ANNUAL then
        return annualCost * (1 - TheContractorOverheads.ANNUAL_DISCOUNT)
    end
    return annualCost / TheContractorOverheads.TERM_PERIODS
end

-- The billing the next term will use.
function TheContractorOverheads.getNextBilling(state)
    return state.pendingBilling or state.billing
end

-- Whether the policy carries on at its renewal: not cancelled, and a
-- mandatory one only while it's still required.
function TheContractorOverheads:willRenew(farmId, definition, state)
    if not state.enabled or state.cancelled then
        return false
    end
    return not definition.mandatory or self:isRequired(farmId, definition)
end

-- What the policy will charge in the given (future) period, 0 for nothing.
-- The period being renewed into is charged at the quoted price if there is
-- one, else today's price.
function TheContractorOverheads:getChargeInPeriod(farmId, definition, state, periodIndex)
    if state == nil or not state.enabled then
        return 0
    end

    if periodIndex == state.renewalPeriod then
        if not self:willRenew(farmId, definition, state) then
            return 0
        end
        local annualCost = state.quotedCost or
            self:getAnnualCost(farmId, definition, TheContractorOverheads.getNextLevel(state))
        return TheContractorOverheads.getChargeAmount(annualCost, TheContractorOverheads.getNextBilling(state))
    end

    if periodIndex >= state.paidUntil and periodIndex < state.renewalPeriod and not state.cancelled and
        state.billing == TheContractorOverheads.BILLING.MONTHLY then
        return TheContractorOverheads.getChargeAmount(state.termCost, state.billing)
    end
    return 0
end

-- The next period anything is charged, and how much: nil if nothing more is
-- due (not active, or cancelled/lapsing).
function TheContractorOverheads:getNextCharge(farmId, definition, state)
    if state == nil or not state.enabled then
        return nil, 0
    end

    local firstPeriod = math.max(state.paidUntil, TCCalendar.getPeriodIndex() + 1)
    for periodIndex = firstPeriod, state.renewalPeriod do
        local amount = self:getChargeInPeriod(farmId, definition, state, periodIndex)
        if amount > 0 then
            return periodIndex, amount
        end
    end
    return nil, 0
end

-- Total overhead charges for the farm in the given period (049's forecast).
function TheContractorOverheads:getForecastForPeriod(farmId, periodIndex)
    local total = 0
    for _, definition in ipairs(self.definitions) do
        total = total + self:getChargeInPeriod(farmId, definition, self:getState(farmId, definition.key), periodIndex)
    end
    return total
end

-- Billing and state changes (server-only) ------------------------------------------

-- Applies locally, then sends the policy's whole state to the clients.
-- A policy starting or ending tells its definition's onActiveChanged.
function TheContractorOverheads:commitState(farmId, key, state)
    local wasActive = self:isActive(farmId, key)
    self:applyState(farmId, key, state)

    if g_server ~= nil then
        g_server:broadcastEvent(TCOverheadStateEvent.new(farmId, key, state))
    end

    local definition = self.definitionsByKey[key]
    if definition ~= nil and definition.onActiveChanged ~= nil and wasActive ~= (state.enabled == true) then
        definition.onActiveChanged(farmId, state.enabled == true)
    end
end

function TheContractorOverheads:applyState(farmId, key, state)
    if self.statesByFarm[farmId] == nil then
        self.statesByFarm[farmId] = {}
    end
    self.statesByFarm[farmId][key] = state
end

function TheContractorOverheads:charge(farmId, definition, amount)
    if amount <= 0 or g_farmManager:getFarmById(farmId) == nil then
        return
    end

    g_currentMission:addMoney(-amount, farmId, MoneyType.TC_OVERHEADS, true, true)
    g_currentMission.TheContractor.Finances:recordOverheads(farmId, amount)
    TCLog.info("TheContractor: farm %d paid %.2f for overhead %s", farmId, amount, definition.key)
end

-- Starts a new term now, priced now, and takes its first payment. levelKey
-- only for an overhead with levels (nil picks its first).
function TheContractorOverheads:startPolicy(farmId, definition, billing, levelKey)
    local periodIndex = TCCalendar.getPeriodIndex()
    local level = TheContractorOverheads.getLevel(definition, levelKey)
    levelKey = level ~= nil and level.key or nil
    local termCost = self:getAnnualCost(farmId, definition, levelKey)
    local renewalPeriod = periodIndex + TheContractorOverheads.TERM_PERIODS

    local state = {
        enabled = true,
        billing = billing,
        pendingBilling = nil,
        renewalPeriod = renewalPeriod,
        paidUntil = billing == TheContractorOverheads.BILLING.ANNUAL and renewalPeriod or periodIndex + 1,
        termCost = termCost,
        quotedCost = nil,
        cancelled = false,
        noticePeriod = nil,
        level = levelKey,
        pendingLevel = nil,
    }
    self:charge(farmId, definition, TheContractorOverheads.getChargeAmount(termCost, billing))
    self:commitState(farmId, definition.key, state)

    TCLog.info("TheContractor: farm %d took out overhead %s (%s%s, %.0f a year, renews period %d)", farmId,
        definition.key, billing, levelKey ~= nil and (", " .. levelKey) or "", termCost, renewalPeriod)
end

-- Reprices a running policy for the rest of its term, when something it's
-- priced on changes mid-term (053: joining or leaving the association, for
-- legal cover). Monthly: the remaining bills go at the new price. Annual:
-- the difference for the months after this one is refunded or charged. A
-- renewal already quoted is quoted again, its notice reposted. Returns the
-- amount refunded (negative: charged), 0 for a monthly policy or no change.
function TheContractorOverheads:repriceMidTerm(farmId, key)
    local definition = self.definitionsByKey[key]
    local state = self:getState(farmId, key)
    if not g_currentMission:getIsServer() or definition == nil or state == nil or not state.enabled then
        return 0
    end

    local newCost = self:getAnnualCost(farmId, definition, state.level)
    local difference = state.termCost - newCost
    if math.abs(difference) < 0.01 then
        return 0
    end

    local adjustment = 0
    if state.billing == TheContractorOverheads.BILLING.ANNUAL then
        local monthsLeft = math.max(0, state.renewalPeriod - TCCalendar.getPeriodIndex() - 1)
        adjustment = TheContractorOverheads.getChargeAmount(difference, state.billing) * monthsLeft /
            TheContractorOverheads.TERM_PERIODS
    end
    state.termCost = newCost

    local wasQuoted = state.quotedCost ~= nil
    if wasQuoted then
        state.quotedCost = self:getAnnualCost(farmId, definition, TheContractorOverheads.getNextLevel(state))
    end

    if adjustment > 0 then
        g_currentMission:addMoney(adjustment, farmId, MoneyType.TC_OVERHEADS, true, true)
        g_currentMission.TheContractor.Finances:recordOverheads(farmId, -adjustment)
    elseif adjustment < 0 then
        self:charge(farmId, definition, -adjustment)
    end
    self:commitState(farmId, key, state)

    if wasQuoted then
        self:repostRenewalNotice(farmId, definition, state)
    end

    TCLog.info("TheContractor: farm %d overhead %s repriced mid-term (%.0f a year, %.2f back)", farmId, key,
        newCost, adjustment)
    return adjustment
end

-- Takes down a policy's renewal notice and posts it again at the price
-- quoted now.
function TheContractorOverheads:repostRenewalNotice(farmId, definition, state)
    local inbox = g_currentMission.TheContractor.Inbox
    for _, message in ipairs(inbox:getMessages(farmId)) do
        if message.kind == TheContractorOverheads.RENEWAL_MESSAGE_KIND and message.payload ~= nil and
            message.payload.overheadKey == definition.key and
            message.payload.renewalPeriod == state.renewalPeriod then
            inbox:removeMessage(message.id)
        end
    end
    state.noticePeriod = nil
    self:postRenewalNotice(farmId, definition, state)
end

-- Starts any mandatory overhead the farm now needs and doesn't have.
-- Called on hiring, and from the daily/period ticks (which also catches a
-- save from before 051 that already has staff).
function TheContractorOverheads:ensureRequired(farmId)
    if not g_currentMission:getIsServer() then
        return
    end

    for _, definition in ipairs(self.definitions) do
        if self:isRequired(farmId, definition) and not self:isActive(farmId, definition.key) then
            self:startPolicy(farmId, definition, TheContractorOverheads.BILLING.ANNUAL)

            local termCost = self:getState(farmId, definition.key).termCost
            g_currentMission.TheContractor.Notices:publish(farmId,
                string.format(g_i18n:getText("tc_overheads_startedNotice"), g_i18n:getText(definition.l10nKey),
                    g_i18n:formatMoney(TheContractorOverheads.getChargeAmount(termCost,
                        TheContractorOverheads.BILLING.ANNUAL), 0, true, true)),
                TheContractorOverheads.STARTED_NOTICE_MONTHS)
        end
    end
end

-- Renews or lapses a policy whose term is up.
function TheContractorOverheads:renewPolicy(farmId, definition, state)
    if not self:willRenew(farmId, definition, state) then
        self:commitState(farmId, definition.key, { enabled = false, billing = state.billing, renewalPeriod = 0,
            paidUntil = 0, termCost = 0, cancelled = false })
        TCLog.info("TheContractor: farm %d overhead %s lapsed", farmId, definition.key)
        return
    end

    local periodIndex = TCCalendar.getPeriodIndex()
    local billing = TheContractorOverheads.getNextBilling(state)
    local levelKey = TheContractorOverheads.getNextLevel(state)
    state.termCost = state.quotedCost or self:getAnnualCost(farmId, definition, levelKey)
    state.quotedCost = nil
    state.billing = billing
    state.pendingBilling = nil
    state.level = levelKey
    state.pendingLevel = nil
    state.renewalPeriod = periodIndex + TheContractorOverheads.TERM_PERIODS
    state.paidUntil = billing == TheContractorOverheads.BILLING.ANNUAL and state.renewalPeriod or periodIndex + 1

    self:charge(farmId, definition, TheContractorOverheads.getChargeAmount(state.termCost, billing))
    self:commitState(farmId, definition.key, state)

    TCLog.info("TheContractor: farm %d renewed overhead %s (%s, %.0f a year)", farmId, definition.key, billing,
        state.termCost)
end

-- One period's billing for one policy.
function TheContractorOverheads:billPolicy(farmId, definition, state)
    local periodIndex = TCCalendar.getPeriodIndex()

    if periodIndex >= state.renewalPeriod then
        self:renewPolicy(farmId, definition, state)
        return
    end

    if periodIndex >= state.paidUntil then
        if state.cancelled then
            -- Monthly, cancelled: stops now.
            self:commitState(farmId, definition.key, { enabled = false, billing = state.billing,
                renewalPeriod = 0, paidUntil = 0, termCost = 0, cancelled = false })
            TCLog.info("TheContractor: farm %d overhead %s ended (cancelled)", farmId, definition.key)
            return
        end

        state.paidUntil = periodIndex + 1
        self:charge(farmId, definition, TheContractorOverheads.getChargeAmount(state.termCost, state.billing))
        self:commitState(farmId, definition.key, state)
    end

    if periodIndex == state.renewalPeriod - 1 then
        self:postRenewalNotice(farmId, definition, state)
    end
end

-- The renewal notice, one period ahead: quotes (and fixes) next term's
-- price. Nothing for a policy that won't renew anyway.
function TheContractorOverheads:postRenewalNotice(farmId, definition, state)
    if state.noticePeriod == state.renewalPeriod or not self:willRenew(farmId, definition, state) then
        return
    end

    state.quotedCost = self:getAnnualCost(farmId, definition, TheContractorOverheads.getNextLevel(state))
    state.noticePeriod = state.renewalPeriod
    self:commitState(farmId, definition.key, state)

    local actions = {
        { key = TheContractorOverheads.ACTION.PAY_ANNUALLY, textKey = "tc_overheads_payAnnuallyButton" },
        { key = TheContractorOverheads.ACTION.PAY_MONTHLY, textKey = "tc_overheads_payMonthlyButton" },
    }
    if not definition.mandatory then
        table.insert(actions, { key = TheContractorOverheads.ACTION.CANCEL, textKey = "tc_overheads_cancelButton" })
    end

    local environment = g_currentMission.environment
    local daysLeftInPeriod = environment.daysPerPeriod - environment.currentDayInPeriod + 1

    local bodyKey = definition.mandatory and "tc_overheads_renewalBodyMandatory" or "tc_overheads_renewalBody"
    local args = {
        "$l10n_" .. definition.l10nKey,
        "$l10n_" .. TCCalendar.getMonthTextKey(state.renewalPeriod),
        TCCalendar.getDisplayYearOfPeriodIndex(state.renewalPeriod),
        "$money_" .. TheContractorOverheads.getChargeAmount(state.quotedCost, TheContractorOverheads.BILLING.ANNUAL),
        "$money_" .. TheContractorOverheads.getChargeAmount(state.quotedCost, TheContractorOverheads.BILLING.MONTHLY),
        "$l10n_tc_overheads_billing_" .. TheContractorOverheads.getNextBilling(state),
    }

    -- 052: an optional policy priced up for recent claims says by how much.
    if definition.getRenewalLoading ~= nil and not definition.mandatory then
        local claimCount, loadingPercent = definition.getRenewalLoading(farmId)
        if claimCount > 0 then
            bodyKey = "tc_overheads_renewalBodyLoaded"
            table.insert(args, loadingPercent)
            table.insert(args, claimCount)
        end
    end

    g_currentMission.TheContractor.Inbox:postMessage(farmId, TheContractorOverheads.RENEWAL_MESSAGE_KIND,
        "tc_overheads_renewalTitle", bodyKey, args,
        actions,
        { overheadKey = definition.key, renewalPeriod = state.renewalPeriod },
        daysLeftInPeriod)
end

-- The renewal notice's answer. Ignored if the policy has moved on since.
function TheContractorOverheads:onRenewalAnswered(farmId, message, actionKey)
    local definition = self.definitionsByKey[message.payload.overheadKey]
    local state = definition ~= nil and self:getState(farmId, definition.key) or nil
    if state == nil or not state.enabled or state.renewalPeriod ~= message.payload.renewalPeriod then
        return
    end

    if actionKey == TheContractorOverheads.ACTION.CANCEL then
        if definition.mandatory then
            return
        end
        state.cancelled = true
    elseif actionKey == TheContractorOverheads.ACTION.PAY_ANNUALLY or actionKey == TheContractorOverheads.ACTION.PAY_MONTHLY then
        local billing = actionKey == TheContractorOverheads.ACTION.PAY_ANNUALLY and
            TheContractorOverheads.BILLING.ANNUAL or TheContractorOverheads.BILLING.MONTHLY
        state.cancelled = false
        state.pendingBilling = billing ~= state.billing and billing or nil
    else
        return
    end

    self:commitState(farmId, definition.key, state)
end

-- Player requests (TCOverheadRequestEvent, server side) -----------------------------

TheContractorOverheads.REQUEST = {
    ENABLE = "enable",
    CANCEL = "cancel",
    KEEP = "keep",
    SWITCH_BILLING = "switchBilling",
    SET_LEVEL = "setLevel",
}

-- Taking one out pays its first charge, so that has to be affordable.
function TheContractorOverheads:canAffordEnable(farmId, definition, billing, levelKey)
    local farm = g_farmManager:getFarmById(farmId)
    return farm ~= nil and farm:getBalance() >=
        TheContractorOverheads.getChargeAmount(self:getAnnualCost(farmId, definition, levelKey), billing)
end

-- Re-checks everything: the farm's own company, the overhead exists, and
-- the request makes sense for its state. billing is only for ENABLE;
-- levelKey is for ENABLE and SET_LEVEL on an overhead with levels.
function TheContractorOverheads:handleRequest(farmId, key, request, billing, levelKey)
    if not g_currentMission:getIsServer() then
        return
    end

    local tc = g_currentMission.TheContractor
    local definition = self.definitionsByKey[key]
    if definition == nil or not tc.Company:hasCompany(farmId) then
        return
    end

    local state = self:getState(farmId, key)
    local isActive = state ~= nil and state.enabled

    if request == TheContractorOverheads.REQUEST.ENABLE then
        if isActive or definition.mandatory or (billing ~= TheContractorOverheads.BILLING.ANNUAL and
                billing ~= TheContractorOverheads.BILLING.MONTHLY) or
            not TheContractorOverheads.isValidLevel(definition, levelKey) or
            not self:canAffordEnable(farmId, definition, billing, levelKey) then
            return
        end
        self:startPolicy(farmId, definition, billing, levelKey)
    elseif request == TheContractorOverheads.REQUEST.CANCEL then
        if not isActive or definition.mandatory or state.cancelled then
            return
        end
        state.cancelled = true
        self:commitState(farmId, key, state)
    elseif request == TheContractorOverheads.REQUEST.KEEP then
        if not isActive or not state.cancelled then
            return
        end
        state.cancelled = false
        self:commitState(farmId, key, state)
    elseif request == TheContractorOverheads.REQUEST.SWITCH_BILLING then
        if not isActive or state.cancelled then
            return
        end
        local nextBilling = TheContractorOverheads.getNextBilling(state) == TheContractorOverheads.BILLING.ANNUAL and
            TheContractorOverheads.BILLING.MONTHLY or TheContractorOverheads.BILLING.ANNUAL
        state.pendingBilling = nextBilling ~= state.billing and nextBilling or nil
        self:commitState(farmId, key, state)
    elseif request == TheContractorOverheads.REQUEST.SET_LEVEL then
        -- For the next term. A renewal already quoted is quoted again.
        if not isActive or state.cancelled or definition.levels == nil or
            not TheContractorOverheads.isValidLevel(definition, levelKey) then
            return
        end
        state.pendingLevel = levelKey ~= state.level and levelKey or nil
        if state.quotedCost ~= nil then
            state.quotedCost = self:getAnnualCost(farmId, definition, TheContractorOverheads.getNextLevel(state))
        end
        self:commitState(farmId, key, state)
    end
end

-- Ticks (server-only) ------------------------------------------------------------------

function TheContractorOverheads:startTicks()
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
    g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
end

function TheContractorOverheads:stopTicks()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
    g_messageCenter:unsubscribe(MessageType.PERIOD_CHANGED, self)
end

local function getSortedFarmIds(farmTable)
    local farmIds = {}
    for farmId in pairs(farmTable) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)
    return farmIds
end

function TheContractorOverheads:onDayChanged()
    for _, farmId in ipairs(getSortedFarmIds(g_currentMission.TheContractor.Staff.workersByFarm)) do
        self:ensureRequired(farmId)
    end
end

-- Bills every active policy for the new period (charging, renewing,
-- lapsing, sending renewal notices), then starts anything now required.
function TheContractorOverheads:onPeriodChanged()
    for _, farmId in ipairs(getSortedFarmIds(self.statesByFarm)) do
        for _, definition in ipairs(self.definitions) do
            local state = self:getState(farmId, definition.key)
            if state ~= nil and state.enabled then
                self:billPolicy(farmId, definition, state)
            end
        end
    end

    self:onDayChanged()
end

-- Wire serialization -------------------------------------------------------------------
-- Numbers that can be nil go as -1; pendingBilling, level and pendingLevel
-- as "".

function TheContractorOverheads.writeState(streamId, state)
    streamWriteBool(streamId, state.enabled)
    streamWriteString(streamId, state.billing)
    streamWriteString(streamId, state.pendingBilling or "")
    streamWriteInt32(streamId, state.renewalPeriod)
    streamWriteInt32(streamId, state.paidUntil)
    streamWriteFloat32(streamId, state.termCost)
    streamWriteFloat32(streamId, state.quotedCost or -1)
    streamWriteBool(streamId, state.cancelled)
    streamWriteString(streamId, state.level or "")
    streamWriteString(streamId, state.pendingLevel or "")
end

function TheContractorOverheads.readState(streamId)
    local state = {
        enabled = streamReadBool(streamId),
        billing = streamReadString(streamId),
        pendingBilling = streamReadString(streamId),
        renewalPeriod = streamReadInt32(streamId),
        paidUntil = streamReadInt32(streamId),
        termCost = streamReadFloat32(streamId),
        quotedCost = streamReadFloat32(streamId),
        cancelled = streamReadBool(streamId),
        level = streamReadString(streamId),
        pendingLevel = streamReadString(streamId),
    }
    if state.pendingBilling == "" then
        state.pendingBilling = nil
    end
    if state.level == "" then
        state.level = nil
    end
    if state.pendingLevel == "" then
        state.pendingLevel = nil
    end
    if state.quotedCost < 0 then
        state.quotedCost = nil
    end
    return state
end

-- Persistence ----------------------------------------------------------------------------

function TheContractorOverheads:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.statesByFarm = {}

    local rootKey = string.format("%s.overheads", TheContractor.SaveKey)
    local index = 0
    while true do
        local key = string.format("%s.policy(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        local overheadKey = getXMLString(xmlFile, key .. "#key")
        if farmId ~= nil and overheadKey ~= nil then
            self:applyState(farmId, overheadKey, {
                enabled = Utils.getNoNil(getXMLBool(xmlFile, key .. "#enabled"), false),
                billing = Utils.getNoNil(getXMLString(xmlFile, key .. "#billing"), TheContractorOverheads.BILLING.ANNUAL),
                pendingBilling = getXMLString(xmlFile, key .. "#pendingBilling"),
                renewalPeriod = Utils.getNoNil(getXMLInt(xmlFile, key .. "#renewalPeriod"), 0),
                paidUntil = Utils.getNoNil(getXMLInt(xmlFile, key .. "#paidUntil"), 0),
                termCost = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#termCost"), 0),
                quotedCost = getXMLFloat(xmlFile, key .. "#quotedCost"),
                cancelled = Utils.getNoNil(getXMLBool(xmlFile, key .. "#cancelled"), false),
                noticePeriod = getXMLInt(xmlFile, key .. "#noticePeriod"),
                level = getXMLString(xmlFile, key .. "#level"),
                pendingLevel = getXMLString(xmlFile, key .. "#pendingLevel"),
            })
        end

        index = index + 1
    end
end

function TheContractorOverheads:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.overheads", TheContractor.SaveKey)
    local index = 0
    for farmId, farmStates in pairs(self.statesByFarm) do
        for overheadKey, state in pairs(farmStates) do
            if state.enabled then
                local key = string.format("%s.policy(%d)", rootKey, index)
                setXMLInt(xmlFile, key .. "#farmId", farmId)
                setXMLString(xmlFile, key .. "#key", overheadKey)
                setXMLBool(xmlFile, key .. "#enabled", state.enabled)
                setXMLString(xmlFile, key .. "#billing", state.billing)
                if state.pendingBilling ~= nil then
                    setXMLString(xmlFile, key .. "#pendingBilling", state.pendingBilling)
                end
                setXMLInt(xmlFile, key .. "#renewalPeriod", state.renewalPeriod)
                setXMLInt(xmlFile, key .. "#paidUntil", state.paidUntil)
                setXMLFloat(xmlFile, key .. "#termCost", state.termCost)
                if state.quotedCost ~= nil then
                    setXMLFloat(xmlFile, key .. "#quotedCost", state.quotedCost)
                end
                setXMLBool(xmlFile, key .. "#cancelled", state.cancelled)
                if state.noticePeriod ~= nil then
                    setXMLInt(xmlFile, key .. "#noticePeriod", state.noticePeriod)
                end
                if state.level ~= nil then
                    setXMLString(xmlFile, key .. "#level", state.level)
                end
                if state.pendingLevel ~= nil then
                    setXMLString(xmlFile, key .. "#pendingLevel", state.pendingLevel)
                end
                index = index + 1
            end
        end
    end
end

function TheContractorOverheads:writeInitialClientState(streamId, connection)
    local entries = {}
    for farmId, farmStates in pairs(self.statesByFarm) do
        for key, state in pairs(farmStates) do
            table.insert(entries, { farmId = farmId, key = key, state = state })
        end
    end

    streamWriteInt32(streamId, #entries)
    for _, entry in ipairs(entries) do
        streamWriteInt32(streamId, entry.farmId)
        streamWriteString(streamId, entry.key)
        TheContractorOverheads.writeState(streamId, entry.state)
    end
end

function TheContractorOverheads:readInitialClientState(streamId, connection)
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local farmId = streamReadInt32(streamId)
        local key = streamReadString(streamId)
        self:applyState(farmId, key, TheContractorOverheads.readState(streamId))
    end
end
