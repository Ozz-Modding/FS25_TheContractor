TCInitialClientStateEvent = {}
local TCInitialClientStateEvent_mt = Class(TCInitialClientStateEvent, Event)

InitEventClass(TCInitialClientStateEvent, "TCInitialClientStateEvent")

function TCInitialClientStateEvent.emptyNew()
    return Event.new(TCInitialClientStateEvent_mt)
end

function TCInitialClientStateEvent.new()
    return TCInitialClientStateEvent.emptyNew()
end

function TCInitialClientStateEvent:writeStream(streamId, connection)
    local tc = g_currentMission.TheContractor

    tc.Reputation:writeInitialClientState(streamId, connection)
    tc.Jobs:writeInitialClientState(streamId, connection)
    tc.Staff:writeInitialClientState(streamId, connection)
    tc.Cooldown:writeInitialClientState(streamId, connection)
    tc.Company:writeInitialClientState(streamId, connection)
    tc.Advertising:writeInitialClientState(streamId, connection)
end

function TCInitialClientStateEvent:readStream(streamId, connection)
    local tc = g_currentMission.TheContractor

    tc.Reputation:readInitialClientState(streamId, connection)
    tc.Jobs:readInitialClientState(streamId, connection)
    tc.Staff:readInitialClientState(streamId, connection)
    tc.Cooldown:readInitialClientState(streamId, connection)
    tc.Company:readInitialClientState(streamId, connection)
    tc.Advertising:readInitialClientState(streamId, connection)

    self:run(connection)
end

function TCInitialClientStateEvent:run(connection)
end
