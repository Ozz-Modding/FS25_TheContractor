-- Every one of our events tells the menu its data may have changed
-- (MessageType.TC_DATA_UPDATED): on the machine that receives it (after its
-- readStream has run it), and on the server as it broadcasts one, since a
-- broadcast doesn't loop back to the host (src/events/README.md). So a remote
-- client's menu catches up when the server's answer lands, and the host's
-- when the server changes something on its own.
--
-- Our events are found in vanilla's event registry, where a mod's
-- InitEventClass files them as "<modName>.<className>" (mods.lua), so they're
-- the ones under our mod's name whose class name starts with TC. Each is
-- marked so the broadcast hook can tell them apart.

TCDataUpdated = {}

-- At source time, while the mod's environment has it.
TCDataUpdated.modName = g_currentModName

function TCDataUpdated.publish()
    g_messageCenter:publish(MessageType.TC_DATA_UPDATED)
end

-- Whether a registered event class name is one of ours.
function TCDataUpdated.isOwnEventClass(className, modName)
    if modName == nil then
        return false
    end
    local prefix = modName .. ".TC"
    return string.sub(className, 1, #prefix) == prefix
end

-- After every event file has been sourced.
function TCDataUpdated.install()
    for className, eventClass in pairs(EventIds.eventClasses) do
        if TCDataUpdated.isOwnEventClass(className, TCDataUpdated.modName) and
                rawget(eventClass, "tcPublishesDataUpdated") == nil then
            eventClass.readStream = Utils.appendedFunction(eventClass.readStream, TCDataUpdated.publish)
            eventClass.tcPublishesDataUpdated = true
        end
    end

    if not Server.tcDataUpdatedHookInstalled then
        Server.broadcastEvent = Utils.appendedFunction(Server.broadcastEvent, function(_, event)
            if event ~= nil and event.tcPublishesDataUpdated then
                TCDataUpdated.publish()
            end
        end)
        Server.tcDataUpdatedHookInstalled = true
    end
end
