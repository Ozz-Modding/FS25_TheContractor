-- Land changing hands between farmers (128): two rare random events (068)
-- so the farming community moves on by itself, not only when a player buys
-- or sells (110).
--
--   fieldSold         a farmer with more than one farmland lets one go (not
--                     their yard's, and none a player owns). It goes by
--                     110's rule (chooseHolder), as if it were free land:
--                     the nearby farmer with the fewest acres for their
--                     target. When that rule would give it straight back to
--                     the seller, it's no sale, so holdings stay even. The
--                     reason (REASONS) is picked at the roll and kept in the
--                     incident. Open jobs there keep their customer.
--   farmerRetirement  only with the farmerRetirements setting on (off by
--                     default) or from the console: a farmer (never the
--                     official) hands everything to a successor
--                     (TheContractorFarmers:retireFarmer).
--
-- People are server-wide, but events are rolled per company farm, so each
-- rate is shared out between the company farms: the map sees the same
-- number whatever the farm count. Every company farm gets the notice.
-- Nothing of this module's own is saved or streamed: the change is the
-- farmers', the incident the framework's.

TheContractorFarmerLandChanges = {}
TheContractorFarmerLandChanges_mt = Class(TheContractorFarmerLandChanges)

TheContractorFarmerLandChanges.FIELD_SOLD_EVENT = "fieldSold"
TheContractorFarmerLandChanges.RETIREMENT_EVENT = "farmerRetirement"
TheContractorFarmerLandChanges.FIELD_SOLD_KIND = "fieldSold"
TheContractorFarmerLandChanges.RETIREMENT_KIND = "farmerRetirement"

-- Expected events a month on the map: a field sold once or twice a year, a
-- retirement once every year or two.
TheContractorFarmerLandChanges.FIELD_SOLD_RATE = 0.12
TheContractorFarmerLandChanges.RETIREMENT_RATE = 0.06
TheContractorFarmerLandChanges.FIELD_SOLD_COOLDOWN = 3
TheContractorFarmerLandChanges.RETIREMENT_COOLDOWN = 6

-- Why a field's sold, each its own body (tc_fieldSold_body_<reason>).
TheContractorFarmerLandChanges.REASONS = { "retiring", "selling", "bereavement" }

function TheContractorFarmerLandChanges.new()
    local self = {}
    setmetatable(self, TheContractorFarmerLandChanges_mt)

    -- Set by the console (tcCompany event) around its trigger.
    self.forcedReason = nil
    self.forcedFarmerId = nil
    self.forceRetirement = false

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorFarmerLandChanges:register(randomEvents, inbox)
    local L = TheContractorFarmerLandChanges
    randomEvents:registerEventType(L.FIELD_SOLD_EVENT, {
        l10nKey = "tc_fieldSold_eventName",
        cooldownPeriods = L.FIELD_SOLD_COOLDOWN,
        ratePerPeriod = function(farmId)
            return L.FIELD_SOLD_RATE / L.getCompanyCount()
        end,
        canTrigger = function(farmId)
            return self:pickSale()
        end,
        -- tcCompany event fieldSold [retiring|selling|bereavement] [farmer]
        console = {
            prepareTrigger = function(farmId, details)
                return self:prepareTrigger(details, true)
            end,
            clearTrigger = function()
                self:clearTrigger()
            end,
        },
        stages = {
            { key = "sold", run = function(incident)
                return self:onSold(incident)
            end },
        },
    })

    randomEvents:registerEventType(L.RETIREMENT_EVENT, {
        l10nKey = "tc_farmerRetirement_eventName",
        cooldownPeriods = L.RETIREMENT_COOLDOWN,
        ratePerPeriod = function(farmId)
            if not L.isRetirementOn() then
                return 0
            end
            return L.RETIREMENT_RATE / L.getCompanyCount()
        end,
        canTrigger = function(farmId)
            return self:pickRetirement()
        end,
        -- tcCompany event farmerRetirement [farmer], setting on or off.
        console = {
            prepareTrigger = function(farmId, details)
                self.forceRetirement = true
                return self:prepareTrigger(details, false)
            end,
            clearTrigger = function()
                self:clearTrigger()
            end,
        },
        stages = {
            { key = "retired", run = function(incident)
                return self:onRetired(incident)
            end },
        },
    })

    inbox:registerMessageKind(L.FIELD_SOLD_KIND, {
        category = "message",
        getArgs = function(message)
            return L.getFieldSoldArgs(message)
        end,
    })
    inbox:registerMessageKind(L.RETIREMENT_KIND, {
        category = "message",
    })
end

-- Queries --------------------------------------------------------------------

function TheContractorFarmerLandChanges.getCompanyCount()
    local count = 0
    local company = g_currentMission.TheContractor.Company
    for _ in pairs(company ~= nil and company.companyNames or {}) do
        count = count + 1
    end
    return math.max(1, count)
end

function TheContractorFarmerLandChanges.isRetirementOn()
    local settings = g_currentMission.TheContractor.Settings
    return settings ~= nil and settings:get("farmerRetirements") == true
end

-- A farmer's farmlands on the map that no player owns. land: getLand's map.
local function getFreeFarmlandIds(farmer, land)
    local ids = {}
    for _, farmlandId in ipairs(farmer.farmlandIds) do
        local farmland = land[farmlandId]
        if farmland ~= nil and farmland.ownerFarmId == FarmlandManager.NO_OWNER_FARM_ID then
            table.insert(ids, farmlandId)
        end
    end
    return ids
end

-- Every sale there could be (pure): { sellerId, farmlandId, buyerId } for
-- each farmland of a farmer with more than one, not their yard's, whose
-- holder by 110's rule (chooseHolder, the farmland taken off the seller)
-- would be someone else. farmers: getFarmers'; land: getLand's map; yards:
-- getFreeYards'.
function TheContractorFarmerLandChanges.findSales(farmers, land, yards)
    local sales = {}
    for index, seller in ipairs(farmers) do
        local farmlandIds = getFreeFarmlandIds(seller, land)
        if #farmlandIds > 1 then
            for _, farmlandId in ipairs(farmlandIds) do
                if farmlandId ~= seller.yardFarmlandId then
                    local without = {}
                    for _, id in ipairs(seller.farmlandIds) do
                        if id ~= farmlandId then
                            table.insert(without, id)
                        end
                    end
                    local candidates = {}
                    for i, farmer in ipairs(farmers) do
                        candidates[i] = farmer
                    end
                    candidates[index] = { id = seller.id, farmlandIds = without, yardFarmlandId = seller.yardFarmlandId,
                        targetAcres = seller.targetAcres }
                    local buyer = TheContractorFarmers.chooseHolder(candidates, land[farmlandId], land, yards)
                    if buyer ~= nil and buyer.id ~= seller.id then
                        table.insert(sales, { sellerId = seller.id, farmlandId = farmlandId, buyerId = buyer.id })
                    end
                end
            end
        end
    end
    return sales
end

-- The field a farmland's notice names: its only field's id, or nil when it
-- has several (the notice names the farmland then).
function TheContractorFarmerLandChanges.getOnlyFieldId(farmlandId)
    local found = nil
    for _, field in ipairs(g_fieldManager ~= nil and g_fieldManager:getFields() or {}) do
        local farmland = field.getFarmland ~= nil and field:getFarmland() or nil
        if farmland ~= nil and farmland:getId() == farmlandId then
            if found ~= nil then
                return nil
            end
            found = field:getId()
        end
    end
    return found
end

-- The field sold notice's args (client): seller, the place in the reader's
-- language, buyer.
function TheContractorFarmerLandChanges.getFieldSoldArgs(message)
    local args = message.args or {}
    local payload = message.payload or {}
    local place
    if payload.fieldId ~= nil then
        place = string.format(g_i18n:getText("tc_fieldSold_placeField"), tostring(payload.fieldId))
    else
        place = string.format(g_i18n:getText("tc_fieldSold_placeFarmland"), tostring(payload.farmlandId))
    end
    return { args[1] or "", place, args[2] or "" }
end

-- canTrigger (server) -----------------------------------------------------------

-- fieldSold's: { sellerId, buyerId, farmlandId, reason }, or nil.
function TheContractorFarmerLandChanges:pickSale()
    local farmers = g_currentMission.TheContractor.Farmers
    if farmers == nil or not farmers:hasGenerated() then
        return nil
    end
    local sales = TheContractorFarmerLandChanges.findSales(farmers:getFarmers(), TheContractorFarmers.getLand(),
        TheContractorFarmers.getFreeYards())
    if self.forcedFarmerId ~= nil then
        local kept = {}
        for _, sale in ipairs(sales) do
            if sale.sellerId == self.forcedFarmerId then
                table.insert(kept, sale)
            end
        end
        sales = kept
    end
    if #sales == 0 then
        TCLog.info("TheContractor: fieldSold: no farmer has a farmland a neighbour would take")
        return nil
    end
    local sale = sales[math.random(1, #sales)]
    local reasons = TheContractorFarmerLandChanges.REASONS
    return {
        sellerId = sale.sellerId,
        buyerId = sale.buyerId,
        farmlandId = sale.farmlandId,
        reason = self.forcedReason or reasons[math.random(1, #reasons)],
    }
end

-- farmerRetirement's: { farmerId }, or nil. Only with the setting on,
-- unless the console asked.
function TheContractorFarmerLandChanges:pickRetirement()
    if not self.forceRetirement and not TheContractorFarmerLandChanges.isRetirementOn() then
        return nil
    end
    local farmers = g_currentMission.TheContractor.Farmers
    if farmers == nil or not farmers:hasGenerated() then
        return nil
    end
    local candidates = {}
    for _, farmer in ipairs(farmers:getFarmers()) do
        if self.forcedFarmerId == nil or self.forcedFarmerId == farmer.id then
            table.insert(candidates, farmer)
        end
    end
    if #candidates == 0 then
        return nil
    end
    return { farmerId = candidates[math.random(1, #candidates)].id }
end

-- Stages (server) ------------------------------------------------------------------

-- Every company farm hears of it.
local function postToAll(kind, titleKey, bodyKey, args, payload)
    local tc = g_currentMission.TheContractor
    for _, farmId in ipairs(tc.RandomEvents:getCompanyFarmIds()) do
        tc.Inbox:postMessage(farmId, kind, titleKey, bodyKey, args, nil, payload)
    end
end

function TheContractorFarmerLandChanges:onSold(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local seller = tc.Farmers:getPerson(data.sellerId)
    local buyer = tc.Farmers:getPerson(data.buyerId)
    if seller == nil or buyer == nil or tc.Farmers:getHolder(data.farmlandId) ~= seller or
            not tc.Farmers:transferFarmland(data.farmlandId, buyer.id) then
        TCLog.info("TheContractor: farm %d incident %d: farmland %s no longer farmer #%s's to sell", incident.farmId,
            incident.id, tostring(data.farmlandId), tostring(data.sellerId))
        return TheContractorRandomEvents.DONE
    end
    postToAll(TheContractorFarmerLandChanges.FIELD_SOLD_KIND, "tc_fieldSold_title",
        "tc_fieldSold_body_" .. tostring(data.reason), { seller.name, buyer.name },
        { farmlandId = data.farmlandId, fieldId = TheContractorFarmerLandChanges.getOnlyFieldId(data.farmlandId) })
    return TheContractorRandomEvents.DONE
end

function TheContractorFarmerLandChanges:onRetired(incident)
    local tc = g_currentMission.TheContractor
    local farmer = tc.Farmers:getPerson(incident.data.farmerId)
    if farmer == nil or farmer.isOfficial then
        return TheContractorRandomEvents.DONE
    end
    local oldName = farmer.name
    local successor = tc.Farmers:retireFarmer(farmer.id)
    if successor == nil then
        return TheContractorRandomEvents.DONE
    end
    postToAll(TheContractorFarmerLandChanges.RETIREMENT_KIND, "tc_farmerRetirement_title",
        "tc_farmerRetirement_body", { oldName, successor.name })
    return TheContractorRandomEvents.DONE
end

-- Persistence and the wire: nothing of its own (see the header).

function TheContractorFarmerLandChanges:loadFromXMLFile(xmlFile)
end

function TheContractorFarmerLandChanges:saveToXmlFile(xmlFile)
end

function TheContractorFarmerLandChanges:writeInitialClientState(streamId, connection)
end

function TheContractorFarmerLandChanges:readInitialClientState(streamId, connection)
end

-- Console (068's tcCompany event, server) -------------------------------------------

-- details: a reason (fieldSold only) and a farmer's id or full name, in
-- any order. Sets them for the trigger, or returns the usage.
function TheContractorFarmerLandChanges:prepareTrigger(details, withReason)
    local rest = {}
    for _, detail in ipairs(details) do
        local isReason = false
        if withReason then
            for _, reason in ipairs(TheContractorFarmerLandChanges.REASONS) do
                if string.lower(detail) == reason then
                    self.forcedReason = reason
                    isReason = true
                end
            end
        end
        if not isReason then
            table.insert(rest, detail)
        end
    end
    if #rest == 0 then
        return nil
    end
    local wanted = table.concat(rest, " ")
    for _, farmer in ipairs(g_currentMission.TheContractor.Farmers:getFarmers()) do
        if tostring(farmer.id) == wanted or string.lower(farmer.name) == string.lower(wanted) then
            self.forcedFarmerId = farmer.id
            return nil
        end
    end
    self:clearTrigger()
    if withReason then
        return "Usage: tcCompany event fieldSold [retiring|selling|bereavement] [farmer id or name] (tcCompany farmers lists them)"
    end
    return "Usage: tcCompany event farmerRetirement [farmer id or name] (tcCompany farmers lists them)"
end

function TheContractorFarmerLandChanges:clearTrigger()
    self.forcedReason = nil
    self.forcedFarmerId = nil
    self.forceRetirement = false
end
