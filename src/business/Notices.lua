-- Important notices (038): a farm-scoped board of short messages shown on
-- the Overview tab, which any other part of the mod can publish to. The
-- board doesn't know what a notice is about - it just holds text.
--
--   local id = tc.Notices:publish(farmId, text, ttlMonths)  -- server only
--   tc.Notices:remove(id)
--
-- publish returns the notice's id; keep it to take the notice down again.
-- ttlMonths is optional: given, the notice removes itself that many period
-- changes later; nil means it stays until removed. isTransient (optional)
-- keeps it out of the save, for a notice its publisher puts up again
-- after a load anyway (063's supply holds). Ids are unique across all
-- farms (one shared counter, like Staff's worker ids), so remove needs no
-- farmId.
--
-- text is a finished string, formatted on the server, so a client playing
-- in another language sees the host's language. Fine while the mod only
-- ships English.

TheContractorNotices = {}
TheContractorNotices_mt = Class(TheContractorNotices)

function TheContractorNotices.new()
    local self = {}
    setmetatable(self, TheContractorNotices_mt)

    -- noticesById[id] = { id, farmId, text, expiresAtPeriod } -
    -- expiresAtPeriod is a TCCalendar period index, nil for no expiry.
    self.noticesById = {}
    self.nextNoticeId = 1

    return self
end

-- Query API -------------------------------------------------------------

-- The farm's notices, newest first.
function TheContractorNotices:getNotices(farmId)
    local result = {}
    for _, notice in pairs(self.noticesById) do
        if notice.farmId == farmId then
            table.insert(result, notice)
        end
    end
    table.sort(result, function(a, b)
        return a.id > b.id
    end)
    return result
end

function TheContractorNotices:getNotice(noticeId)
    return self.noticesById[noticeId]
end

-- Publishing/removing (server-authoritative) ----------------------------

-- Returns the new notice's id, or nil if called on a client.
function TheContractorNotices:publish(farmId, text, ttlMonths, isTransient)
    if not g_currentMission:getIsServer() then
        return nil
    end

    local expiresAtPeriod = nil
    if ttlMonths ~= nil then
        expiresAtPeriod = TCCalendar.getPeriodIndex() + math.max(1, math.floor(ttlMonths))
    end

    local notice = {
        id = self.nextNoticeId,
        farmId = farmId,
        text = text,
        expiresAtPeriod = expiresAtPeriod,
        -- Server-only, never streamed: only the server saves.
        isTransient = isTransient == true,
    }
    self:applyNoticePublished(notice)

    if g_server ~= nil then
        g_server:broadcastEvent(TCNoticePublishedEvent.new(notice))
    end

    TCLog.info("TheContractor: farm %d notice %d published (%s): %s", farmId, notice.id,
        expiresAtPeriod ~= nil and ("expires period " .. expiresAtPeriod) or "no expiry", text)

    return notice.id
end

function TheContractorNotices:applyNoticePublished(notice)
    self.noticesById[notice.id] = notice

    if notice.id >= self.nextNoticeId then
        self.nextNoticeId = notice.id + 1
    end
end

-- A no-op if the notice is already gone (expired, or removed twice).
function TheContractorNotices:remove(noticeId)
    if not g_currentMission:getIsServer() then
        return
    end

    if noticeId == nil or self.noticesById[noticeId] == nil then
        return
    end

    self:applyNoticeRemoved(noticeId)

    if g_server ~= nil then
        g_server:broadcastEvent(TCNoticeRemovedEvent.new(noticeId))
    end
end

function TheContractorNotices:applyNoticeRemoved(noticeId)
    self.noticesById[noticeId] = nil
end

-- Expiry (server-only period tick) ----------------------------------------

function TheContractorNotices:startPeriodTick()
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
end

function TheContractorNotices:stopPeriodTick()
    g_messageCenter:unsubscribe(MessageType.PERIOD_CHANGED, self)
end

function TheContractorNotices:onPeriodChanged()
    local now = TCCalendar.getPeriodIndex()
    local expired = {}
    for id, notice in pairs(self.noticesById) do
        if notice.expiresAtPeriod ~= nil and notice.expiresAtPeriod <= now then
            table.insert(expired, id)
        end
    end
    for _, id in ipairs(expired) do
        self:remove(id)
    end
end

-- Wire serialization ----------------------------------------------------
-- expiresAtPeriod 0 = no expiry (period indexes start at 1).

function TheContractorNotices.writeNotice(streamId, notice)
    streamWriteInt32(streamId, notice.id)
    streamWriteInt32(streamId, notice.farmId)
    streamWriteString(streamId, notice.text)
    streamWriteInt32(streamId, notice.expiresAtPeriod or 0)
end

function TheContractorNotices.readNotice(streamId)
    local notice = {
        id = streamReadInt32(streamId),
        farmId = streamReadInt32(streamId),
        text = streamReadString(streamId),
        expiresAtPeriod = streamReadInt32(streamId),
    }
    if notice.expiresAtPeriod == 0 then
        notice.expiresAtPeriod = nil
    end
    return notice
end

-- Persistence -------------------------------------------------------------

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorNotices:forgetFarm(farmId)
    for id, notice in pairs(self.noticesById) do
        if notice.farmId == farmId then
            self.noticesById[id] = nil
        end
    end
end

function TheContractorNotices:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.noticesById = {}

    local rootKey = string.format("%s.notices", TheContractor.SaveKey)
    self.nextNoticeId = Utils.getNoNil(getXMLInt(xmlFile, rootKey .. "#nextNoticeId"), 1)

    local index = 0
    while true do
        local key = string.format("%s.notice(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        self:applyNoticePublished({
            id = getXMLInt(xmlFile, key .. "#id"),
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            text = Utils.getNoNil(getXMLString(xmlFile, key .. "#text"), ""),
            expiresAtPeriod = getXMLInt(xmlFile, key .. "#expiresAtPeriod"),
        })

        index = index + 1
    end
end

function TheContractorNotices:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.notices", TheContractor.SaveKey)
    setXMLInt(xmlFile, rootKey .. "#nextNoticeId", self.nextNoticeId)

    local index = 0
    for _, notice in pairs(self.noticesById) do
        if not notice.isTransient then
            local key = string.format("%s.notice(%d)", rootKey, index)
            setXMLInt(xmlFile, key .. "#id", notice.id)
            setXMLInt(xmlFile, key .. "#farmId", notice.farmId)
            setXMLString(xmlFile, key .. "#text", notice.text)
            if notice.expiresAtPeriod ~= nil then
                setXMLInt(xmlFile, key .. "#expiresAtPeriod", notice.expiresAtPeriod)
            end
            index = index + 1
        end
    end
end

function TheContractorNotices:writeInitialClientState(streamId, connection)
    local notices = {}
    for _, notice in pairs(self.noticesById) do
        table.insert(notices, notice)
    end

    streamWriteInt32(streamId, #notices)
    for _, notice in ipairs(notices) do
        TheContractorNotices.writeNotice(streamId, notice)
    end
end

function TheContractorNotices:readInitialClientState(streamId, connection)
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        self:applyNoticePublished(TheContractorNotices.readNotice(streamId))
    end
end

-- Console commands (tcCompany - see TCConsole) -----------------------------------------

function TheContractorNotices.registerConsoleCommands()
    TCConsole.registerHint("noticeId", "a notice's id (tcCompany notices)")
    -- The board doesn't show ids, and removeNotice needs one. Read-only.
    TCConsole.register("company", "notices", {
        description = "The notices on your Overview board, with their ids",
        serverOnly = false,
        run = function(farmId, args)
            local notices = g_currentMission.TheContractor.Notices:getNotices(farmId)
            if #notices == 0 then
                return string.format("Farm %d has no notices.", farmId)
            end

            local lines = { string.format("Farm %d notices:", farmId) }
            for _, notice in ipairs(notices) do
                table.insert(lines, string.format("#%d (%s) %s", notice.id, notice.expiresAtPeriod ~= nil and
                    ("until " .. TCCalendar.formatPeriodIndex(notice.expiresAtPeriod)) or "no expiry", notice.text))
            end
            return table.concat(lines, "\n")
        end,
    })

    TCConsole.register("company", "notice", {
        args = "<months|none> <text...>",
        description = "Put a notice on your Overview board, for that many months or until removed",
        run = function(farmId, args)
            local ttl = args[1] ~= nil and string.lower(args[1]) or nil
            local months = TCConsole.toCount(ttl, nil)
            local text = table.concat(args, " ", 2)
            if text == "" or (months == nil and ttl ~= "none") then
                return false
            end

            local noticeId = g_currentMission.TheContractor.Notices:publish(farmId, text, months)
            return string.format("Published notice %d", noticeId)
        end,
    })

    TCConsole.register("company", "removeNotice", {
        args = "<noticeId>",
        description = "Take a notice off the board",
        run = function(farmId, args)
            local noticeId = tonumber(args[1])
            if noticeId == nil then
                return false
            end
            local notices = g_currentMission.TheContractor.Notices
            local notice = notices:getNotice(noticeId)
            if notice == nil or notice.farmId ~= farmId then
                return string.format("Error: your farm has no notice %d", noticeId)
            end

            notices:remove(noticeId)
            return string.format("Removed notice %d", noticeId)
        end,
    })
end
