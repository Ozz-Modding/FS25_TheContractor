-- Trade association membership and legal cover (053). Two optional
-- overheads (051), registered here on every machine:
--
--   - Membership of the Agricultural Contractors' Association (loosely the
--     UK's NAAC), MEMBERSHIP_COST a year. Members earn REPUTATION_BONUS more
--     reputation per completed job (Jobs:calculateReputationReward), get
--     CERTIFICATION_DISCOUNT off certification courses (054 - non-members
--     can still take them, at full price) and cheaper legal cover.
--   - Legal expenses insurance, LEGAL_COVER_COST a year (LEGAL_COVER_MEMBER_COST
--     for members). Like any policy it's priced once per term, so joining the
--     association mid-term only lowers it from the next renewal.
--
-- Legal cover pays for pursuing an overdue invoice (Finances:requestPursuit).
-- Without it the player instructs a solicitor: SOLICITOR_FEE plus
-- SOLICITOR_FEE_RATE of the invoice (the fee and a rough court fee), paid
-- up front under MoneyType.TC_LEGAL, kept whatever happens. The pursuit
-- itself (delay, roll, outcome) lives with the invoice in Finances; the
-- outcome messages are this file's inbox kind.
--
-- Everything here reads overhead state, so there's nothing of its own to
-- save or sync: the stubs below are just the subsystem convention.

TheContractorAssociation = {}
TheContractorAssociation_mt = Class(TheContractorAssociation)

TheContractorAssociation.MEMBERSHIP_KEY = "tradeAssociation"
TheContractorAssociation.LEGAL_COVER_KEY = "legalExpenses"

TheContractorAssociation.MEMBERSHIP_COST = 400
TheContractorAssociation.LEGAL_COVER_COST = 350
TheContractorAssociation.LEGAL_COVER_MEMBER_COST = 200

-- Members' extra reputation per completed job, never less than a point.
TheContractorAssociation.REPUTATION_BONUS = 0.05
TheContractorAssociation.MIN_REPUTATION_BONUS = 1

-- Off certification courses (054), for members.
TheContractorAssociation.CERTIFICATION_DISCOUNT = 0.25

-- Pursuing without legal cover.
TheContractorAssociation.SOLICITOR_FEE = 500
TheContractorAssociation.SOLICITOR_FEE_RATE = 0.05

TheContractorAssociation.MESSAGE_KIND = "legal"

table.insert(FinanceStats.statNames, "tcLegal")
FinanceStats.statNameToIndex["tcLegal"] = #FinanceStats.statNames

function TheContractorAssociation.new()
    local self = {}
    setmetatable(self, TheContractorAssociation_mt)

    MoneyType.TC_LEGAL = MoneyType.register("tcLegal", "tc_moneyType_legal")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

-- Every machine, at load, once Overheads and the Inbox exist.
function TheContractorAssociation:register(overheads, inbox)
    overheads:registerOverhead({
        key = TheContractorAssociation.MEMBERSHIP_KEY,
        l10nKey = "tc_overhead_tradeAssociation",
        mandatory = false,
        annualCost = function(farmId)
            return TheContractorAssociation.MEMBERSHIP_COST
        end,
        descriptionAmounts = { TheContractorAssociation.MEMBERSHIP_COST },
    })

    overheads:registerOverhead({
        key = TheContractorAssociation.LEGAL_COVER_KEY,
        l10nKey = "tc_overhead_legalExpenses",
        mandatory = false,
        annualCost = function(farmId)
            return self:isMember(farmId) and TheContractorAssociation.LEGAL_COVER_MEMBER_COST or
                TheContractorAssociation.LEGAL_COVER_COST
        end,
        descriptionAmounts = { TheContractorAssociation.LEGAL_COVER_COST,
            TheContractorAssociation.LEGAL_COVER_MEMBER_COST },
    })

    inbox:registerMessageKind(TheContractorAssociation.MESSAGE_KIND, {
        chipKey = "tc_inbox_chipLegal",
        chipTone = "info",
    })
end

-- Query API ---------------------------------------------------------------------

function TheContractorAssociation:isMember(farmId)
    return g_currentMission.TheContractor.Overheads:isActive(farmId, TheContractorAssociation.MEMBERSHIP_KEY)
end

function TheContractorAssociation:hasLegalCover(farmId)
    return g_currentMission.TheContractor.Overheads:isActive(farmId, TheContractorAssociation.LEGAL_COVER_KEY)
end

-- Extra reputation on top of a completed job's reward: 0 for non-members.
function TheContractorAssociation:getReputationBonus(farmId, reward)
    if not self:isMember(farmId) then
        return 0
    end
    return math.max(TheContractorAssociation.MIN_REPUTATION_BONUS,
        math.floor(reward * TheContractorAssociation.REPUTATION_BONUS + 0.5))
end

-- 054: the share off a certification course, 0 for non-members.
function TheContractorAssociation:getCertificationDiscount(farmId)
    return self:isMember(farmId) and TheContractorAssociation.CERTIFICATION_DISCOUNT or 0
end

-- What pursuing this invoice costs up front: 0 with legal cover.
function TheContractorAssociation:getPursuitFee(farmId, invoice)
    if self:hasLegalCover(farmId) then
        return 0
    end
    -- The fixed fee is 1x UK, so it's scaled; the rate is on the invoice,
    -- which already is.
    return math.floor(g_currentMission.TheContractor.Settings:scaleCost(TheContractorAssociation.SOLICITOR_FEE) +
        TheContractorAssociation.SOLICITOR_FEE_RATE * invoice.amount + 0.5)
end

-- Persistence (nothing of its own - see the header) -----------------------------

function TheContractorAssociation:loadFromXMLFile(xmlFile)
end

function TheContractorAssociation:saveToXmlFile(xmlFile)
end

function TheContractorAssociation:writeInitialClientState(streamId, connection)
end

function TheContractorAssociation:readInitialClientState(streamId, connection)
end
