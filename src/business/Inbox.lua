-- Inbox messages (050): non-job items in the Inbox, through which the
-- business asks the player something (insurance renewals, claims, training
-- requests, bonuses). The inbox only stores, syncs, shows and routes them -
-- what a message means is up to the subsystem that registered its kind:
--
--   tc.Inbox:registerMessageKind("certRequest", {
--       onAction = function(farmId, message, actionKey) ... end,  -- server
--       onExpire = function(farmId, message) ... end,             -- optional, server
--       category = "staff",                                       -- optional: a CATEGORIES key
--       chipTone = "info",                                        -- optional
--       getConfirmText = function(message, actionKey) ... end,    -- optional, client:
--                                                                 -- text for a Yes/No first, or nil
--       getArgs = function(message) ... end,                      -- optional, client: the args to
--                                                                 -- render with, worked out live
--       endsWithJob = true,                                       -- optional: see below
--       fromFarmer = true,                                        -- optional: from payload.farmerId
--       onClientAction = function(message, actionKey) ... end,    -- optional, client: true if it
--                                                                 -- handled the action on this
--                                                                 -- machine (137's Show on map):
--                                                                 -- nothing's sent, the message stays
--   })
--   local id = tc.Inbox:postMessage(farmId, "certRequest", titleKey, bodyKey,
--       args, actions, payload, expiresInDays)                    -- server only
--
-- Register on every machine (not just the server), at load: clients need
-- the chip, the server needs the handlers. The chip says what sort of
-- message it is (CATEGORIES: Job, Staff, Claim...), never what it's about,
-- and a kind with endsWithJob is a Job unless it says otherwise.
--
-- Message: { id, farmId, kind, createdDay, expiresDay, titleKey, bodyKey,
-- args, actions = { { key, textKey }, ... }, payload } - days are
-- monotonic, expiresDay nil for no expiry. Title and body are l10n keys
-- formatted with args on each client, so everyone reads their own
-- language; a string arg starting "$l10n_" is translated too, and one
-- starting "$money_" (then a number) is formatted as money, and "$pay_"
-- likewise after TheContractorStaff.scalePay, so a full-month salary shows
-- at this month's pay even if days per period changes later. "$volume_"
-- (then litres, 078) is formatted in the reader's own units, and
-- "$days_<first>_<last>" (monotonic days, 089) as a date range. args and
-- payload hold plain values only (numbers, strings, booleans) - never a
-- node (see src/events/README.md). A message with no actions gets a single
-- Dismiss. Ids are unique across all farms.
--
-- A kind with endsWithJob (072's joyriders, 075's fly-tipping) posts offers
-- of a job, named by payload.jobId: such a message expires with the job's
-- deadline, and goes as soon as the job's no longer on offer (accepted,
-- declined or lapsed, completed, missed, or gone).

TheContractorInbox = {}
TheContractorInbox_mt = Class(TheContractorInbox)

-- One bottom-bar button per action, in this order.
TheContractorInbox.MAX_ACTIONS = 3

TheContractorInbox.DISMISS_ACTION = { key = "dismiss", textKey = "tc_inbox_dismissButton" }

-- Message categories, each its chip's text (tc_inbox_chip_<category>).
TheContractorInbox.CATEGORIES = {
    message = true,
    job = true,
    feedback = true,
    staff = true,
    holiday = true,
    parking = true,
    claim = true,
    insurance = true,
    crime = true,
    workshop = true,
    admin = true,
}
TheContractorInbox.DEFAULT_CATEGORY = "message"
TheContractorInbox.DEFAULT_CHIP_TONE = "info"

function TheContractorInbox.new()
    local self = {}
    setmetatable(self, TheContractorInbox_mt)

    -- messagesById[id] = message
    self.messagesById = {}
    self.nextMessageId = 1

    -- kinds[kind] = { onAction, onExpire, category, chipTone, ... }
    self.kinds = {}

    return self
end

-- Registry --------------------------------------------------------------------

function TheContractorInbox:registerMessageKind(kind, definition)
    self.kinds[kind] = definition
end

function TheContractorInbox:getKind(kind)
    return self.kinds[kind]
end

-- Query API -------------------------------------------------------------------

-- The farm's messages, newest first.
function TheContractorInbox:getMessages(farmId)
    local result = {}
    for _, message in pairs(self.messagesById) do
        if message.farmId == farmId then
            table.insert(result, message)
        end
    end
    table.sort(result, function(a, b)
        return a.id > b.id
    end)
    return result
end

function TheContractorInbox:getMessage(messageId)
    return self.messagesById[messageId]
end

function TheContractorInbox:getAction(message, actionKey)
    for _, action in ipairs(message.actions) do
        if action.key == actionKey then
            return action
        end
    end
    return nil
end

-- Rendering (client side, in the local language) -----------------------------

local function resolveArgs(args)
    local resolved = {}
    for i, arg in ipairs(args) do
        if type(arg) == "string" and string.sub(arg, 1, 6) == "$l10n_" then
            resolved[i] = g_i18n:getText(string.sub(arg, 7))
        elseif type(arg) == "string" and string.sub(arg, 1, 7) == "$money_" then
            resolved[i] = g_i18n:formatMoney(tonumber(string.sub(arg, 8)) or 0, 0, true, true)
        elseif type(arg) == "string" and string.sub(arg, 1, 5) == "$pay_" then
            resolved[i] = g_i18n:formatMoney(TheContractorStaff.scalePay(tonumber(string.sub(arg, 6)) or 0), 0, true,
                true)
        elseif type(arg) == "string" and string.sub(arg, 1, 8) == "$volume_" then
            resolved[i] = g_i18n:formatVolume(tonumber(string.sub(arg, 9)) or 0, 0)
        elseif type(arg) == "string" and string.sub(arg, 1, 6) == "$days_" then
            local firstDay, lastDay = string.match(arg, "^%$days_(%d+)_(%d+)$")
            resolved[i] = firstDay ~= nil and TCCalendar.formatDayRange(tonumber(firstDay), tonumber(lastDay)) or ""
        else
            resolved[i] = arg
        end
    end
    return resolved
end

local function formatText(key, args)
    local text = g_i18n:getText(key)
    if #args == 0 then
        return text
    end
    return string.format(text, unpack(resolveArgs(args)))
end

-- The kind's own live args (getArgs), if it has them.
local function getArgs(message)
    local tc = g_currentMission.TheContractor
    local definition = tc ~= nil and tc.Inbox ~= nil and tc.Inbox:getKind(message.kind) or nil
    if definition ~= nil and definition.getArgs ~= nil then
        return definition.getArgs(message)
    end
    return message.args
end

function TheContractorInbox.getTitle(message)
    return formatText(message.titleKey, getArgs(message))
end

function TheContractorInbox.getBody(message)
    return formatText(message.bodyKey, getArgs(message))
end

-- 112: the job an endsWithJob message offers, on any machine, or nil.
function TheContractorInbox:getMessageJob(message)
    local jobId = self:getMessageJobId(message.kind, message.payload)
    local tc = g_currentMission.TheContractor
    if jobId == nil or tc.Jobs == nil then
        return nil
    end
    return tc.Jobs:getJob(message.farmId, jobId)
end

-- 112: who an offer is from (its job's customer, 110), or nil. 129: a
-- fromFarmer kind's message is from the person in payload.farmerId.
function TheContractorInbox:getMessageCustomer(message)
    local definition = self.kinds[message.kind]
    if definition ~= nil and definition.fromFarmer then
        local farmers = g_currentMission.TheContractor.Farmers
        return farmers ~= nil and farmers:getPerson(message.payload.farmerId) or nil
    end
    local job = self:getMessageJob(message)
    return job ~= nil and job:getCustomer() or nil
end

-- 112: a kind's getArgs for offer texts that name the customer: for a body
-- in namedBodyKeys, the message's args with the customer's name as it is
-- now on the end (so a rename shows, and older saved messages get it too).
-- The name always starts a sentence there, hence the fallback's capital.
function TheContractorInbox.getCustomerNamedArgs(message, namedBodyKeys)
    if not namedBodyKeys[message.bodyKey] then
        return message.args
    end
    local args = {}
    for i, arg in ipairs(message.args) do
        args[i] = arg
    end
    local customer = g_currentMission.TheContractor.Inbox:getMessageCustomer(message)
    table.insert(args, customer ~= nil and customer.name or g_i18n:getText("tc_inbox_customerUnknown"))
    return args
end

-- A message's category (CATEGORIES): its kind's, else job for one that
-- offers a job, else DEFAULT_CATEGORY. Unregistered kinds get the default.
function TheContractorInbox:getCategory(message)
    local definition = self.kinds[message.kind] or {}
    local category = definition.category
    if category == nil and definition.endsWithJob then
        category = "job"
    end
    if category == nil or not TheContractorInbox.CATEGORIES[category] then
        category = TheContractorInbox.DEFAULT_CATEGORY
    end
    return category
end

function TheContractorInbox:getChip(message)
    local definition = self.kinds[message.kind] or {}
    return g_i18n:getText("tc_inbox_chip_" .. self:getCategory(message)),
        definition.chipTone or TheContractorInbox.DEFAULT_CHIP_TONE
end

-- Posting/removing (server-authoritative) -------------------------------------

-- Returns the new message's id, or nil if called on a client.
function TheContractorInbox:postMessage(farmId, kind, titleKey, bodyKey, args, actions, payload, expiresInDays)
    if not g_currentMission:getIsServer() then
        return nil
    end

    if actions == nil or #actions == 0 then
        actions = { TheContractorInbox.DISMISS_ACTION }
    elseif #actions > TheContractorInbox.MAX_ACTIONS then
        TCLog.warning("TheContractor: inbox message kind '%s' has %d actions, only the first %d are kept", kind,
            #actions, TheContractorInbox.MAX_ACTIONS)
        local kept = {}
        for i = 1, TheContractorInbox.MAX_ACTIONS do
            kept[i] = actions[i]
        end
        actions = kept
    end

    if self.kinds[kind] == nil then
        TCLog.warning("TheContractor: inbox message posted with unregistered kind '%s'", kind)
    end

    local today = g_currentMission.environment.currentMonotonicDay
    local expiresDay = expiresInDays ~= nil and today + math.max(1, math.floor(expiresInDays)) or nil
    if expiresDay == nil then
        expiresDay = self:getJobExpiryDay(farmId, kind, payload)
    end
    local message = {
        id = self.nextMessageId,
        farmId = farmId,
        kind = kind,
        createdDay = today,
        expiresDay = expiresDay,
        titleKey = titleKey,
        bodyKey = bodyKey,
        args = args or {},
        actions = actions,
        payload = payload or {},
    }
    self:applyMessagePosted(message, true)

    if g_server ~= nil then
        g_server:broadcastEvent(TCMessagePostedEvent.new(message))
    end

    TCLog.info("TheContractor: farm %d inbox message %d posted (%s, %s)", farmId, message.id, kind,
        message.expiresDay ~= nil and ("expires day " .. message.expiresDay) or "no expiry")

    return message.id
end

-- Job-linked messages (endsWithJob, server) -------------------------------------

-- Whether a job's no longer on offer: taken on, or over.
local function isOfferOver(job)
    return job == nil or (job.state ~= TheContractorJob.STATE.OFFERED and
        job.state ~= TheContractorJob.STATE.NEGOTIATING)
end

-- The job an endsWithJob message offers, or nil (another kind, or none named).
function TheContractorInbox:getMessageJobId(kind, payload)
    local definition = self.kinds[kind]
    if definition == nil or not definition.endsWithJob or payload == nil then
        return nil
    end
    return payload.jobId
end

-- An offer lapses the day after its job's deadline (Jobs:onDayChanged).
function TheContractorInbox:getJobExpiryDay(farmId, kind, payload)
    local jobId = self:getMessageJobId(kind, payload)
    if jobId == nil then
        return nil
    end
    local job = g_currentMission.TheContractor.Jobs:getJob(farmId, jobId)
    if job == nil or job.deadlineDay == nil then
        return nil
    end
    return job.deadlineDay + 1
end

-- Server: the job's been taken on or is over, so its offer messages go.
function TheContractorInbox:removeMessagesForJob(farmId, jobId)
    for _, message in ipairs(self:getMessages(farmId)) do
        if self:getMessageJobId(message.kind, message.payload) == jobId then
            self:removeMessage(message.id)
        end
    end
end

-- Server, daily: catches any whose job was taken on or ended without
-- telling us (an older save's, from before endsWithJob or from before an
-- accepted offer's message went).
function TheContractorInbox:removeEndedJobMessages()
    local jobs = g_currentMission.TheContractor.Jobs
    local ended = {}
    for _, message in pairs(self.messagesById) do
        local jobId = self:getMessageJobId(message.kind, message.payload)
        if jobId ~= nil and isOfferOver(jobs:getJob(message.farmId, jobId)) then
            table.insert(ended, message.id)
        end
    end
    table.sort(ended)
    for _, messageId in ipairs(ended) do
        TCLog.info("TheContractor: inbox message %d's job is no longer on offer, removed", messageId)
        self:removeMessage(messageId)
    end
end

-- isNewArrival: false while replaying saved/initial state, so only a
-- genuinely new message plays the HUD sound (same as Jobs:registerJob).
function TheContractorInbox:applyMessagePosted(message, isNewArrival)
    self.messagesById[message.id] = message

    if message.id >= self.nextMessageId then
        self.nextMessageId = message.id + 1
    end

    local tc = g_currentMission.TheContractor
    if isNewArrival and tc ~= nil and tc.InboxHUD ~= nil then
        tc.InboxHUD:onMessagePosted(message)
    end
end

-- A no-op if the message is already gone.
function TheContractorInbox:removeMessage(messageId)
    if not g_currentMission:getIsServer() then
        return
    end

    if messageId == nil or self.messagesById[messageId] == nil then
        return
    end

    self:applyMessageRemoved(messageId)

    if g_server ~= nil then
        g_server:broadcastEvent(TCMessageRemovedEvent.new(messageId))
    end
end

function TheContractorInbox:applyMessageRemoved(messageId)
    self.messagesById[messageId] = nil
end

-- Server side of TCMessageActionEvent: the message must exist, be the
-- farm's, and offer the action. The handler runs before the message goes,
-- so it still sees it. Dismiss on a kind with no handler just removes it.
function TheContractorInbox:requestAction(farmId, messageId, actionKey)
    if not g_currentMission:getIsServer() then
        return
    end

    local message = self.messagesById[messageId]
    if message == nil or message.farmId ~= farmId or self:getAction(message, actionKey) == nil then
        return
    end

    local definition = self.kinds[message.kind]
    if definition ~= nil and definition.onAction ~= nil then
        definition.onAction(farmId, message, actionKey)
    elseif actionKey ~= TheContractorInbox.DISMISS_ACTION.key then
        TCLog.warning("TheContractor: inbox message %d kind '%s' has no handler for action '%s'", messageId,
            message.kind, actionKey)
    end

    TCLog.info("TheContractor: farm %d inbox message %d answered (%s)", farmId, messageId, actionKey)
    self:removeMessage(messageId)
end

-- Expiry (server-only daily tick) ---------------------------------------------

function TheContractorInbox:startDailyTick()
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
end

function TheContractorInbox:stopDailyTick()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
end

function TheContractorInbox:onDayChanged()
    local today = g_currentMission.environment.currentMonotonicDay

    local expired = {}
    for _, message in pairs(self.messagesById) do
        if message.expiresDay ~= nil and message.expiresDay <= today then
            table.insert(expired, message)
        end
    end
    table.sort(expired, function(a, b)
        return a.id < b.id
    end)

    for _, message in ipairs(expired) do
        local definition = self.kinds[message.kind]
        if definition ~= nil and definition.onExpire ~= nil then
            definition.onExpire(message.farmId, message)
        end
        TCLog.info("TheContractor: farm %d inbox message %d expired (%s)", message.farmId, message.id, message.kind)
        self:removeMessage(message.id)
    end

    self:removeEndedJobMessages()
end

-- Plain values (args/payload) ---------------------------------------------------
-- Tagged "n"/"s"/"b" so numbers, strings and booleans survive the wire and
-- the XML as what they were. Anything else is dropped with a warning.

local function getValueType(value)
    local valueType = type(value)
    if valueType == "number" then
        return "n"
    elseif valueType == "string" then
        return "s"
    elseif valueType == "boolean" then
        return "b"
    end
    return nil
end

local function valueFromString(valueType, text)
    if valueType == "n" then
        return tonumber(text) or 0
    elseif valueType == "b" then
        return text == "true"
    end
    return text or ""
end

-- { { key, type, value }, ... } in a stable order: array args by index,
-- payload by sorted key.
local function getArgEntries(args)
    local entries = {}
    for i, value in ipairs(args) do
        local valueType = getValueType(value)
        if valueType == nil then
            TCLog.warning("TheContractor: inbox message arg %d isn't a plain value, sending an empty string", i)
            valueType, value = "s", ""
        end
        table.insert(entries, { type = valueType, value = value })
    end
    return entries
end

local function getPayloadEntries(payload)
    -- Keys go over as strings, so key by those.
    local byKey = {}
    local keys = {}
    for key, value in pairs(payload) do
        byKey[tostring(key)] = value
        table.insert(keys, tostring(key))
    end
    table.sort(keys)

    local entries = {}
    for _, key in ipairs(keys) do
        local value = byKey[key]
        local valueType = getValueType(value)
        if valueType ~= nil then
            table.insert(entries, { key = key, type = valueType, value = value })
        else
            TCLog.warning("TheContractor: inbox payload '%s' isn't a plain value, dropped", key)
        end
    end
    return entries
end

-- Wire serialization ------------------------------------------------------------
-- expiresDay -1 = no expiry.

local function writeValue(streamId, valueType, value)
    streamWriteString(streamId, valueType)
    streamWriteString(streamId, tostring(value))
end

local function readValue(streamId)
    local valueType = streamReadString(streamId)
    return valueFromString(valueType, streamReadString(streamId))
end

function TheContractorInbox.writeMessage(streamId, message)
    streamWriteInt32(streamId, message.id)
    streamWriteInt32(streamId, message.farmId)
    streamWriteString(streamId, message.kind)
    streamWriteInt32(streamId, message.createdDay)
    streamWriteInt32(streamId, message.expiresDay or -1)
    streamWriteString(streamId, message.titleKey)
    streamWriteString(streamId, message.bodyKey)

    local args = getArgEntries(message.args)
    streamWriteUInt8(streamId, #args)
    for _, entry in ipairs(args) do
        writeValue(streamId, entry.type, entry.value)
    end

    streamWriteUInt8(streamId, #message.actions)
    for _, action in ipairs(message.actions) do
        streamWriteString(streamId, action.key)
        streamWriteString(streamId, action.textKey)
    end

    local payload = getPayloadEntries(message.payload)
    streamWriteUInt8(streamId, #payload)
    for _, entry in ipairs(payload) do
        streamWriteString(streamId, entry.key)
        writeValue(streamId, entry.type, entry.value)
    end
end

function TheContractorInbox.readMessage(streamId)
    local message = {
        id = streamReadInt32(streamId),
        farmId = streamReadInt32(streamId),
        kind = streamReadString(streamId),
        createdDay = streamReadInt32(streamId),
        expiresDay = streamReadInt32(streamId),
        titleKey = streamReadString(streamId),
        bodyKey = streamReadString(streamId),
        args = {},
        actions = {},
        payload = {},
    }
    if message.expiresDay < 0 then
        message.expiresDay = nil
    end

    for i = 1, streamReadUInt8(streamId) do
        message.args[i] = readValue(streamId)
    end

    for i = 1, streamReadUInt8(streamId) do
        message.actions[i] = { key = streamReadString(streamId), textKey = streamReadString(streamId) }
    end

    for _ = 1, streamReadUInt8(streamId) do
        local key = streamReadString(streamId)
        message.payload[key] = readValue(streamId)
    end

    return message
end

-- Persistence ---------------------------------------------------------------------

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorInbox:forgetFarm(farmId)
    for id, message in pairs(self.messagesById) do
        if message.farmId == farmId then
            self.messagesById[id] = nil
        end
    end
end

function TheContractorInbox:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.messagesById = {}

    local rootKey = string.format("%s.inbox", TheContractor.SaveKey)
    self.nextMessageId = Utils.getNoNil(getXMLInt(xmlFile, rootKey .. "#nextMessageId"), 1)

    local index = 0
    while true do
        local key = string.format("%s.message(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        local message = {
            id = getXMLInt(xmlFile, key .. "#id"),
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            kind = Utils.getNoNil(getXMLString(xmlFile, key .. "#kind"), ""),
            createdDay = Utils.getNoNil(getXMLInt(xmlFile, key .. "#createdDay"), 0),
            expiresDay = getXMLInt(xmlFile, key .. "#expiresDay"),
            titleKey = Utils.getNoNil(getXMLString(xmlFile, key .. "#titleKey"), ""),
            bodyKey = Utils.getNoNil(getXMLString(xmlFile, key .. "#bodyKey"), ""),
            args = {},
            actions = {},
            payload = {},
        }

        local i = 0
        while true do
            local argKey = string.format("%s.arg(%d)", key, i)
            if not hasXMLProperty(xmlFile, argKey) then
                break
            end
            table.insert(message.args, valueFromString(getXMLString(xmlFile, argKey .. "#type"),
                getXMLString(xmlFile, argKey .. "#value")))
            i = i + 1
        end

        i = 0
        while true do
            local actionKey = string.format("%s.action(%d)", key, i)
            if not hasXMLProperty(xmlFile, actionKey) then
                break
            end
            table.insert(message.actions, {
                key = Utils.getNoNil(getXMLString(xmlFile, actionKey .. "#key"), ""),
                textKey = Utils.getNoNil(getXMLString(xmlFile, actionKey .. "#textKey"), ""),
            })
            i = i + 1
        end
        if #message.actions == 0 then
            message.actions = { TheContractorInbox.DISMISS_ACTION }
        end

        i = 0
        while true do
            local payloadKey = string.format("%s.payload(%d)", key, i)
            if not hasXMLProperty(xmlFile, payloadKey) then
                break
            end
            local name = getXMLString(xmlFile, payloadKey .. "#key")
            if name ~= nil then
                message.payload[name] = valueFromString(getXMLString(xmlFile, payloadKey .. "#type"),
                    getXMLString(xmlFile, payloadKey .. "#value"))
            end
            i = i + 1
        end

        self:applyMessagePosted(message, false)

        index = index + 1
    end
end

function TheContractorInbox:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.inbox", TheContractor.SaveKey)
    setXMLInt(xmlFile, rootKey .. "#nextMessageId", self.nextMessageId)

    local index = 0
    for _, message in pairs(self.messagesById) do
        local key = string.format("%s.message(%d)", rootKey, index)
        setXMLInt(xmlFile, key .. "#id", message.id)
        setXMLInt(xmlFile, key .. "#farmId", message.farmId)
        setXMLString(xmlFile, key .. "#kind", message.kind)
        setXMLInt(xmlFile, key .. "#createdDay", message.createdDay)
        if message.expiresDay ~= nil then
            setXMLInt(xmlFile, key .. "#expiresDay", message.expiresDay)
        end
        setXMLString(xmlFile, key .. "#titleKey", message.titleKey)
        setXMLString(xmlFile, key .. "#bodyKey", message.bodyKey)

        for i, entry in ipairs(getArgEntries(message.args)) do
            local argKey = string.format("%s.arg(%d)", key, i - 1)
            setXMLString(xmlFile, argKey .. "#type", entry.type)
            setXMLString(xmlFile, argKey .. "#value", tostring(entry.value))
        end

        for i, action in ipairs(message.actions) do
            local actionKey = string.format("%s.action(%d)", key, i - 1)
            setXMLString(xmlFile, actionKey .. "#key", action.key)
            setXMLString(xmlFile, actionKey .. "#textKey", action.textKey)
        end

        for i, entry in ipairs(getPayloadEntries(message.payload)) do
            local payloadKey = string.format("%s.payload(%d)", key, i - 1)
            setXMLString(xmlFile, payloadKey .. "#key", entry.key)
            setXMLString(xmlFile, payloadKey .. "#type", entry.type)
            setXMLString(xmlFile, payloadKey .. "#value", tostring(entry.value))
        end

        index = index + 1
    end
end

function TheContractorInbox:writeInitialClientState(streamId, connection)
    local messages = {}
    for _, message in pairs(self.messagesById) do
        table.insert(messages, message)
    end

    streamWriteInt32(streamId, #messages)
    for _, message in ipairs(messages) do
        TheContractorInbox.writeMessage(streamId, message)
    end
end

function TheContractorInbox:readInitialClientState(streamId, connection)
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        self:applyMessagePosted(TheContractorInbox.readMessage(streamId), false)
    end
end
