-- No-op stub: ticket 016 (staff data model and hiring) fills this in.
-- Exists now so TheContractor's save/load loop has a stable place to
-- delegate into.

TheContractorStaff = {}
TheContractorStaff_mt = Class(TheContractorStaff)

function TheContractorStaff.new()
    local self = {}
    setmetatable(self, TheContractorStaff_mt)

    return self
end

function TheContractorStaff:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end
end

function TheContractorStaff:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end
end

function TheContractorStaff:writeInitialClientState(streamId, connection)
end

function TheContractorStaff:readInitialClientState(streamId, connection)
end
