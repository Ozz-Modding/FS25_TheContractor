-- Broadcast-only: a hired worker's holiday state changed on the server (040,
-- TheContractorHolidays) - a booking made, cancelled, cut short or over, or
-- the yearly allowance reset. Sends the whole visible state (allowance and
-- booking) rather than a diff, plus what to tell the farm about it. See
-- src/events/README.md for the general event conventions.

TCWorkerHolidayChangedEvent = {}
local TCWorkerHolidayChangedEvent_mt = Class(TCWorkerHolidayChangedEvent, Event)

InitEventClass(TCWorkerHolidayChangedEvent, "TCWorkerHolidayChangedEvent")

function TCWorkerHolidayChangedEvent.emptyNew()
    return Event.new(TCWorkerHolidayChangedEvent_mt)
end

function TCWorkerHolidayChangedEvent.new(worker, notify)
    local self = TCWorkerHolidayChangedEvent.emptyNew()
    self.farmId = worker.farmId
    self.workerId = worker.id
    self.allowance = worker.holidayAllowance
    self.startDay = worker.holidayStartDay
    self.days = worker.holidayDays
    self.notify = notify
    return self
end

-- startDay 0 = nothing booked (monotonic days start at 1).
function TCWorkerHolidayChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteFloat32(streamId, self.allowance)
    streamWriteInt32(streamId, self.startDay or 0)
    streamWriteInt32(streamId, self.days)
    streamWriteUInt8(streamId, self.notify)
end

function TCWorkerHolidayChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.allowance = streamReadFloat32(streamId)
    self.startDay = streamReadInt32(streamId)
    if self.startDay == 0 then
        self.startDay = nil
    end
    self.days = streamReadInt32(streamId)
    self.notify = streamReadUInt8(streamId)
    self:run(connection)
end

function TCWorkerHolidayChangedEvent:run(connection)
    local worker = g_currentMission.TheContractor.Staff:getWorker(self.farmId, self.workerId)
    if worker == nil then
        return
    end

    TheContractorHolidays.applyHolidayChanged(worker, self.allowance, self.startDay, self.days)
    TCWorkerHolidayChangedEvent.showNotification(worker, self.notify)
end

-- Only the worker's own farm hears about it. Shared by run() (remote
-- clients) and TheContractorHolidays:sendHolidayChanged (the host's own
-- copy, since the broadcast doesn't loop back to it).
function TCWorkerHolidayChangedEvent.showNotification(worker, notify)
    if worker == nil or worker.farmId ~= g_currentMission:getFarmId() then
        return
    end

    if notify == TheContractorHolidays.NOTIFY.BOOKED and worker:hasHolidayBooked() then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(g_i18n:getText("tc_holiday_booked"), worker.name,
                TCCalendar.formatDayRange(worker.holidayStartDay, worker:getHolidayEndDay())))
    elseif notify == TheContractorHolidays.NOTIFY.CANCELLED then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(g_i18n:getText("tc_holiday_cancelled"), worker.name))
    elseif notify == TheContractorHolidays.NOTIFY.REQUEST_WITHDRAWN then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(g_i18n:getText("tc_holiday_requestWithdrawn"), worker.name))
    end
end
