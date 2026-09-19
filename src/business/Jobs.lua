-- No-op stub: ticket 008 (job data model) and later job tickets fill this
-- in. Exists now so TheContractor's save/load loop has a stable place to
-- delegate into.

TheContractorJobs = {}
TheContractorJobs_mt = Class(TheContractorJobs)

function TheContractorJobs.new()
    local self = {}
    setmetatable(self, TheContractorJobs_mt)

    return self
end

function TheContractorJobs:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end
end

function TheContractorJobs:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end
end

function TheContractorJobs:writeInitialClientState(streamId, connection)
end

function TheContractorJobs:readInitialClientState(streamId, connection)
end
