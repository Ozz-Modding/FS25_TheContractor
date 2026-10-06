-- Broadcast-only: an invoice was paid, went overdue, was written off or is
-- being pursued (049/053, TheContractorFinances:setInvoiceStatus).
-- settledDay is the day it was paid/written off, nil otherwise;
-- pursuitStartDay/pursuitFee are nil unless it's been pursued (053). See
-- src/events/README.md for the general event conventions.

TCInvoiceStatusChangedEvent = {}
local TCInvoiceStatusChangedEvent_mt = Class(TCInvoiceStatusChangedEvent, Event)

InitEventClass(TCInvoiceStatusChangedEvent, "TCInvoiceStatusChangedEvent")

function TCInvoiceStatusChangedEvent.emptyNew()
    return Event.new(TCInvoiceStatusChangedEvent_mt)
end

function TCInvoiceStatusChangedEvent.new(invoiceId, status, settledDay, pursuitStartDay, pursuitFee)
    local self = TCInvoiceStatusChangedEvent.emptyNew()
    self.invoiceId = invoiceId
    self.status = status
    self.settledDay = settledDay
    self.pursuitStartDay = pursuitStartDay
    self.pursuitFee = pursuitFee
    return self
end

function TCInvoiceStatusChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.invoiceId)
    streamWriteString(streamId, self.status)
    streamWriteInt32(streamId, self.settledDay or -1)
    streamWriteInt32(streamId, self.pursuitStartDay or -1)
    streamWriteFloat32(streamId, self.pursuitFee or 0)
end

function TCInvoiceStatusChangedEvent:readStream(streamId, connection)
    self.invoiceId = streamReadInt32(streamId)
    self.status = streamReadString(streamId)
    local settledDay = streamReadInt32(streamId)
    self.settledDay = settledDay >= 0 and settledDay or nil
    local pursuitStartDay = streamReadInt32(streamId)
    local pursuitFee = streamReadFloat32(streamId)
    if pursuitStartDay >= 0 then
        self.pursuitStartDay = pursuitStartDay
        self.pursuitFee = pursuitFee
    end
    self:run(connection)
end

function TCInvoiceStatusChangedEvent:run(connection)
    g_currentMission.TheContractor.Finances:applyInvoiceStatus(self.invoiceId, self.status, self.settledDay,
        self.pursuitStartDay, self.pursuitFee)
end
