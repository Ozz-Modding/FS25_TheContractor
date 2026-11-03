-- A console command an admin typed on a client (TCConsole.dispatch), sent to
-- the server to run there, and its answer sent back to them to print. A
-- dedicated server has nobody at its own console, so this is how its admins
-- use the server-only commands. The context is the typing player's (where
-- they stand, what they're in), taken on their machine.

TCConsoleEvent = {}
local TCConsoleEvent_mt = Class(TCConsoleEvent, Event)

InitEventClass(TCConsoleEvent, "TCConsoleEvent")

function TCConsoleEvent.emptyNew()
    return Event.new(TCConsoleEvent_mt)
end

-- Client to server: args[1] is the subcommand's name.
function TCConsoleEvent.newRequest(groupKey, args, context)
    local self = TCConsoleEvent.emptyNew()
    self.isResult = false
    self.groupKey = groupKey
    self.args = args
    self.context = context
    return self
end

-- Server to that client: the text to print.
function TCConsoleEvent.newResult(text)
    local self = TCConsoleEvent.emptyNew()
    self.isResult = true
    self.text = text
    return self
end

function TCConsoleEvent:writeStream(streamId, connection)
    if streamWriteBool(streamId, self.isResult) then
        streamWriteString(streamId, self.text or "")
        return
    end
    streamWriteString(streamId, self.groupKey)
    streamWriteUInt8(streamId, #self.args)
    for _, arg in ipairs(self.args) do
        streamWriteString(streamId, tostring(arg))
    end
    TCConsole.writeContext(streamId, self.context)
end

function TCConsoleEvent:readStream(streamId, connection)
    self.isResult = streamReadBool(streamId)
    if self.isResult then
        self.text = streamReadString(streamId)
    else
        self.groupKey = streamReadString(streamId)
        self.args = {}
        for i = 1, streamReadUInt8(streamId) do
            self.args[i] = streamReadString(streamId)
        end
        self.context = TCConsole.readContext(streamId)
    end
    self:run(connection)
end

function TCConsoleEvent:run(connection)
    if self.isResult then
        if connection:getIsServer() and self.text ~= "" then
            print(self.text)
        end
        return
    end
    if not g_currentMission:getIsServer() then
        return
    end
    local text = TCConsole.runRequest(self.groupKey, self.args, self.context, connection)
    if text ~= nil and text ~= "" then
        connection:sendEvent(TCConsoleEvent.newResult(text))
    end
end
