-- Broadcast-only: an invoice was paid, went overdue or was written off
-- (049, TheContractorFinances:setInvoiceStatus). settledDay is the day it
-- was paid/written off, nil otherwise. See src/events/README.md for the
-- general event conventions.

TCInvoiceStatusChangedEvent = {}
local TCInvoiceStatusChangedEvent_mt = Class(TCInvoiceStatusChangedEvent, Event)

InitEventClass(TCInvoiceStatusChangedEvent, "TCInvoiceStatusChangedEvent")

function TCInvoiceStatusChangedEvent.emptyNew()
    return Event.new(TCInvoiceStatusChangedEvent_mt)
end

function TCInvoiceStatusChangedEvent.new(invoiceId, status, settledDay)
    local self = TCInvoiceStatusChangedEvent.emptyNew()
    self.invoiceId = invoiceId
    self.status = status
    self.settledDay = settledDay
    return self
end

function TCInvoiceStatusChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.invoiceId)
    streamWriteString(streamId, self.status)
    streamWriteInt32(streamId, self.settledDay or -1)
end

function TCInvoiceStatusChangedEvent:readStream(streamId, connection)
    self.invoiceId = streamReadInt32(streamId)
    self.status = streamReadString(streamId)
    local settledDay = streamReadInt32(streamId)
    self.settledDay = settledDay >= 0 and settledDay or nil
    self:run(connection)
end

function TCInvoiceStatusChangedEvent:run(connection)
    g_currentMission.TheContractor.Finances:applyInvoiceStatus(self.invoiceId, self.status, self.settledDay)
end
