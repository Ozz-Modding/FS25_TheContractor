-- An open day (163, testing only): the plainest public day out, a crowd on a
-- farmer's field with nothing for sale. It's the second kind of
-- TheContractorEventDay, there to prove the shared day works without lots
-- (165's show will be the next): started only from the console (tcDebug
-- openDay), it never rolls, posts no messages and gives no attend job.
--
--   Set out (the day's midnight): bare ground (AuctionSite:startOpen): the
--     field's largest rectangle, its entrance space dressed plainly (the
--     car park, food, toilets, bunting; nothing of the auction's), and
--     walking lanes over the rest for the crowd. A field that isn't grass
--     is put down to grass and put back after (143).
--   On from 08:00 to 18:00, over at midnight: the ground put back, the
--     signs (the auction's board for now: a kind's own face needs its own
--     art) and the crowd down.
--
-- Saved in TheContractor.xml (.openDay), in the initial client state, and
-- sent with TCEventDayEvent.

TheContractorOpenDay = {}
local TheContractorOpenDay_mt = Class(TheContractorOpenDay, TheContractorEventDay)

TheContractorOpenDay.KIND = "openDay"
TheContractorOpenDay.TC_KEY = "OpenDay"
TheContractorOpenDay.NAME = "open day"
TheContractorOpenDay.TITLE = "Open day"
TheContractorOpenDay.SAVE_KEY = "openDays"
TheContractorOpenDay.SAVE_EVENT_KEY = "openDay"
TheContractorOpenDay.PAYLOAD_ID = "openDayId"
-- No messages, no roll: the console's only.
TheContractorOpenDay.TEXTS = nil
TheContractorOpenDay.ANNOUNCE_CHANCE_BASE = nil
TheContractorOpenDay.LEAD_MONTHS = { 1, 2 }
TheContractorOpenDay.SIGNS_MONTHS = 1
TheContractorOpenDay.REMINDER_MONTHS = 0.25
TheContractorOpenDay.START_HOUR = 8
TheContractorOpenDay.END_HOUR = 18
TheContractorOpenDay.AFTER_DAYS = 0
TheContractorOpenDay.TOP_PICKS = 3

function TheContractorOpenDay.new()
    return TheContractorEventDay.new(TheContractorOpenDay_mt)
end

-- A testing aid: its marker isn't a player's text.
function TheContractorOpenDay:getMapName()
    return "Open day (test)"
end

function TheContractorOpenDay:onStateEntered(event, state, passing)
    if state ~= TheContractorEventDay.STATE.SET_OUT or passing then
        return
    end
    local site = g_currentMission.TheContractor.AuctionSite
    site:startOpen(event.fieldId, self.KIND, event.id)
    if site.site == nil or site.site.fieldId ~= event.fieldId then
        TCLog.warning("TheContractor: open day %d's ground couldn't be set out on field %d", event.id, event.fieldId)
    end
end

function TheContractorOpenDay.registerConsoleCommands()
    TCConsole.register("debug", "openDay", {
        args = "[start [fieldId] [days]|day|cancel]",
        description = "163's test kind of day out: a crowd on a farmer's field with no lots. Its state, or start one, make it today, or call it off",
        hints = { fieldId = "a field's number (tcAuction fields lists those that can hold a sale)" },
        run = function(_, args)
            local openDay = g_currentMission.TheContractor.OpenDay
            local action = args[1] ~= nil and string.lower(args[1]) or nil
            if action == nil then
                if args[2] ~= nil then
                    return false
                end
                return openDay:describe()
            end
            if action == "start" then
                local fieldId = args[2] ~= nil and tonumber(args[2]) or nil
                local days = args[3] ~= nil and tonumber(args[3]) or nil
                if (args[2] ~= nil and fieldId == nil) or (args[3] ~= nil and (days == nil or days < 1)) or
                        args[4] ~= nil then
                    return false
                end
                return openDay:consoleStart(fieldId, days ~= nil and math.floor(days) or nil)
            end
            if args[2] ~= nil then
                return false
            end
            if action == "day" then
                if openDay:getEvent() == nil then
                    return "There's no open day announced."
                end
                if openDay:getEvent().day ~= g_currentMission.environment.currentMonotonicDay then
                    openDay:moveToToday()
                end
                return openDay:describe()
            end
            if action == "cancel" then
                if not openDay:cancel(false) then
                    return "There's no open day announced."
                end
                return "Open day cancelled: its ground put back and everything cleared away."
            end
            return false
        end,
    })
end
