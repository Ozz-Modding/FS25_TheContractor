-- Farm-scoped contracting company: one company per farm, 1:1, keyed by
-- farmId. Presence of a name in `companyNames` IS "this farm has a company"
-- — there's no separate boolean flag to keep in sync.
--
-- Creating a company charges CREATION_COST from farm money and resets
-- reputation (007 fills in the real reputation system; for now
-- Reputation:reset() is a placeholder).

TheContractorCompany = {}
TheContractorCompany_mt = Class(TheContractorCompany)

TheContractorCompany.CREATION_COST = 500

-- CREATION_COST at FS25_EconomyScale's price level (TCEconomyScale).
function TheContractorCompany.getCreationCost()
    return TCEconomyScale.scale(TheContractorCompany.CREATION_COST)
end

table.insert(FinanceStats.statNames, "tcCompanyCreation")
FinanceStats.statNameToIndex["tcCompanyCreation"] = #FinanceStats.statNames

function TheContractorCompany.new()
    local self = {}
    setmetatable(self, TheContractorCompany_mt)

    self.companyNames = {}

    MoneyType.TC_COMPANY_CREATION = MoneyType.register("tcCompanyCreation", "tc_moneyType_companyCreation")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

function TheContractorCompany:hasCompany(farmId)
    return self.companyNames[farmId] ~= nil
end

function TheContractorCompany:getCompanyName(farmId)
    return self.companyNames[farmId]
end

function TheContractorCompany:canCreateCompany(farmId)
    if self:hasCompany(farmId) then
        return false
    end

    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil then
        return false
    end

    return farm:getBalance() >= TheContractorCompany.getCreationCost()
end

-- Server-authoritative: deducts the creation cost from farm money. Only
-- call after canCreateCompany() has been checked (see TCCreateCompanyEvent).
function TheContractorCompany:createCompany(farmId, name)
    if g_currentMission:getIsServer() then
        g_currentMission:addMoney(-TheContractorCompany.getCreationCost(), farmId, MoneyType.TC_COMPANY_CREATION,
            true, true)
    end

    self:applyCompanyCreation(farmId, name)
end

-- The actual state flip, run on whichever machine (server, or a client
-- receiving the broadcast) is applying the creation. No money movement
-- here — vanilla farm-money sync already keeps `farm.money` consistent
-- across clients, we don't need to mirror it ourselves.
function TheContractorCompany:applyCompanyCreation(farmId, name)
    if self:hasCompany(farmId) then
        return
    end

    self.companyNames[farmId] = name

    local tc = g_currentMission.TheContractor
    if tc ~= nil and tc.Reputation ~= nil then
        tc.Reputation:reset(farmId)
    end
    -- 113: and nobody has an opinion of it yet.
    if tc ~= nil and tc.Relationships ~= nil then
        tc.Relationships:reset(farmId)
    end

    -- On an MP client this lands a round trip after the player confirmed
    -- the name, with the menu still open on the "create a company" state.
    local menu = tc ~= nil and tc.MenuContractor or nil
    if menu ~= nil and menu.isFrameOpen and farmId == g_currentMission:getFarmId() then
        menu:refreshCompanyState()
        menu:setMenuButtonInfoDirty()
    end
end

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorCompany:forgetFarm(farmId)
    self.companyNames[farmId] = nil
end

function TheContractorCompany:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.companyNames = {}

    local i = 0
    while true do
        local key = string.format("%s.company.farm(%d)", TheContractor.SaveKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        local name = getXMLString(xmlFile, key .. "#name")
        self.companyNames[farmId] = name

        i = i + 1
    end
end

function TheContractorCompany:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local i = 0
    for farmId, name in pairs(self.companyNames) do
        local key = string.format("%s.company.farm(%d)", TheContractor.SaveKey, i)
        setXMLInt(xmlFile, key .. "#farmId", farmId)
        setXMLString(xmlFile, key .. "#name", name)
        i = i + 1
    end
end

function TheContractorCompany:writeInitialClientState(streamId, connection)
    local farmCount = 0
    for _ in pairs(self.companyNames) do
        farmCount = farmCount + 1
    end
    streamWriteInt32(streamId, farmCount)

    for farmId, name in pairs(self.companyNames) do
        streamWriteInt32(streamId, farmId)
        streamWriteString(streamId, name)
    end
end

function TheContractorCompany:readInitialClientState(streamId, connection)
    local farmCount = streamReadInt32(streamId)
    for _ = 1, farmCount do
        local farmId = streamReadInt32(streamId)
        local name = streamReadString(streamId)
        self.companyNames[farmId] = name
    end
end
