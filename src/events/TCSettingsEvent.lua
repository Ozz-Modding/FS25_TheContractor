-- Carries every setting's value (048). Client -> server when a player
-- changes an option: the server checks the sender is the host or an admin,
-- applies and broadcasts to the other clients - or, if not allowed, sends
-- its own values back so the sender's menu snaps back. Server -> client:
-- apply and refresh the menu controls.

TCSettingsEvent = {}
local TCSettingsEvent_mt = Class(TCSettingsEvent, Event)

InitEventClass(TCSettingsEvent, "TCSettingsEvent")

function TCSettingsEvent.emptyNew()
    return Event.new(TCSettingsEvent_mt)
end

-- Carries a snapshot of the local current values. A snapshot, not read at
-- write time, because a local (host) send runs the event without streaming.
function TCSettingsEvent.new()
    local self = TCSettingsEvent.emptyNew()
    self.values = g_currentMission.TheContractor.Settings:copyValues()
    return self
end

function TCSettingsEvent:writeStream(streamId, connection)
    TheContractorSettings.writeValues(streamId, self.values)
end

function TCSettingsEvent:readStream(streamId, connection)
    self.values = TheContractorSettings.readValues(streamId)
    self:run(connection)
end

function TCSettingsEvent:run(connection)
    local settings = g_currentMission.TheContractor.Settings

    if not connection:getIsServer() then
        if TheContractorSettings.getCanConnectionChange(connection) then
            settings:applyValues(self.values)
            g_server:broadcastEvent(TCSettingsEvent.new(), false, connection)
            Logging.info("TheContractor: settings changed, job pay rate %d%%", settings:get("jobPayRate"))
        else
            connection:sendEvent(TCSettingsEvent.new())
        end
        -- The host's own menu (it might be open on a listen server).
        TCSettingsMenu.refreshControls()
    else
        settings:applyValues(self.values)
        TCSettingsMenu.refreshControls()
    end
end
