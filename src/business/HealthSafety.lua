-- Health and safety programme (055). An optional overhead (051), registered
-- here on every machine: PPE, first aid kits, refresher training and risk
-- assessments, COST_PER_WORKER per hired worker a year (priced per term by
-- headcount, like every 051 policy).
--
-- While it's active, sickness (031, TheContractorStaff:updateSickness) is
-- less likely and shorter: the daily chance is multiplied by
-- SICKNESS_MULTIPLIER and each extra sick day's chance drops by
-- EXTRA_DAY_CHANCE_REDUCTION. It applies from the day the policy starts to
-- the day it lapses - it's read live, from overhead state. It also takes a
-- quarter off the odds of a workplace injury (104, INJURY_MULTIPLIER).
--
-- Without it, each time a worker falls sick there's INSPECTION_CHANCE of a
-- workplace inspection that finds shortcomings (server-only, from
-- TheContractorStaff:makeWorkerSick): a FINE_MIN-FINE_MAX fine (a rough
-- UK scale for an improvement notice plus costs, written at 1x UK and scaled
-- by TheContractorSettings:scaleCost) under MoneyType.TC_FINES, an Overview notice and a
-- REPUTATION_PENALTY hit. Charged even into the red, like a claim (052).
--
-- Everything else is overhead state, so there's nothing of its own to save
-- or sync: the stubs below are just the subsystem convention.

TheContractorHealthSafety = {}
TheContractorHealthSafety_mt = Class(TheContractorHealthSafety)

TheContractorHealthSafety.OVERHEAD_KEY = "healthSafety"
TheContractorHealthSafety.COST_PER_WORKER = 250

TheContractorHealthSafety.SICKNESS_MULTIPLIER = 0.6
TheContractorHealthSafety.EXTRA_DAY_CHANCE_REDUCTION = 0.15
TheContractorHealthSafety.INJURY_MULTIPLIER = 0.75

TheContractorHealthSafety.INSPECTION_CHANCE = 0.03
TheContractorHealthSafety.FINE_MIN = 2000
TheContractorHealthSafety.FINE_MAX = 8000
TheContractorHealthSafety.REPUTATION_PENALTY = 5
TheContractorHealthSafety.NOTICE_MONTHS = 2

table.insert(FinanceStats.statNames, "tcFines")
FinanceStats.statNameToIndex["tcFines"] = #FinanceStats.statNames

function TheContractorHealthSafety.new()
    local self = {}
    setmetatable(self, TheContractorHealthSafety_mt)

    MoneyType.TC_FINES = MoneyType.register("tcFines", "tc_moneyType_fines")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

-- Every machine, at load, once Overheads exists.
function TheContractorHealthSafety:register(overheads)
    overheads:registerOverhead({
        key = TheContractorHealthSafety.OVERHEAD_KEY,
        l10nKey = "tc_overhead_healthSafety",
        mandatory = false,
        annualCost = function(farmId)
            return TheContractorHealthSafety.COST_PER_WORKER * #g_currentMission.TheContractor.Staff:getRoster(farmId)
        end,
        descriptionAmounts = { TheContractorHealthSafety.COST_PER_WORKER },
    })
end

-- Query API ---------------------------------------------------------------------

function TheContractorHealthSafety:isActive(farmId)
    return g_currentMission.TheContractor.Overheads:isActive(farmId, TheContractorHealthSafety.OVERHEAD_KEY)
end

-- Multiplies 031's daily sickness chance: 1 without the programme.
function TheContractorHealthSafety:getSicknessMultiplier(farmId)
    return self:isActive(farmId) and TheContractorHealthSafety.SICKNESS_MULTIPLIER or 1
end

-- Multiplies 104's monthly injury rate: 1 without the programme.
function TheContractorHealthSafety:getInjuryMultiplier(farmId)
    return self:isActive(farmId) and TheContractorHealthSafety.INJURY_MULTIPLIER or 1
end

-- 031's chance of each further sick day, for this farm.
function TheContractorHealthSafety:getExtraDayChance(farmId)
    local chance = TheContractorStaff.SICK_EXTRA_DAY_CHANCE
    if self:isActive(farmId) then
        chance = chance - TheContractorHealthSafety.EXTRA_DAY_CHANCE_REDUCTION
    end
    return math.max(0, chance)
end

-- Inspections (server-only) ------------------------------------------------------

-- A worker on the farm has just fallen sick. force (tcDebug sick ... inspect)
-- skips the roll, but never fines a farm that has the programme.
function TheContractorHealthSafety:onWorkerFellSick(farmId, worker, force)
    if not g_currentMission:getIsServer() or self:isActive(farmId) then
        return
    end

    local roll = math.random()
    TCLog.info("TheContractor: farm %d no H&S programme, inspection roll %.3f vs %.3f%s", farmId, roll,
        TheContractorHealthSafety.INSPECTION_CHANCE, force and " - forced" or "")
    if force or roll < TheContractorHealthSafety.INSPECTION_CHANCE then
        self:runInspection(farmId, worker)
    end
end

function TheContractorHealthSafety:runInspection(farmId, worker)
    local tc = g_currentMission.TheContractor
    local fine = math.floor(tc.Settings:scaleCost(math.random(TheContractorHealthSafety.FINE_MIN,
        TheContractorHealthSafety.FINE_MAX)) / 100) * 100

    g_currentMission:addMoney(-fine, farmId, MoneyType.TC_FINES, true, true)
    tc.Finances:recordFines(farmId, fine)
    tc.Reputation:addReputation(farmId, -TheContractorHealthSafety.REPUTATION_PENALTY)

    tc.Notices:publish(farmId, string.format(g_i18n:getText("tc_healthSafety_inspectionNotice"), worker.name,
        g_i18n:formatMoney(fine, 0, true, true)), TheContractorHealthSafety.NOTICE_MONTHS)

    TCLog.info("TheContractor: farm %d workplace inspection after %s fell sick: fined %d, -%d reputation", farmId,
        worker.name, fine, TheContractorHealthSafety.REPUTATION_PENALTY)
end

-- Persistence (nothing of its own - see the header) -----------------------------

function TheContractorHealthSafety:loadFromXMLFile(xmlFile)
end

function TheContractorHealthSafety:saveToXmlFile(xmlFile)
end

function TheContractorHealthSafety:writeInitialClientState(streamId, connection)
end

function TheContractorHealthSafety:readInitialClientState(streamId, connection)
end
