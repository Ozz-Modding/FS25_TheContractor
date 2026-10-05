-- Client asks to write off one of its farm's overdue invoices, from the
-- Finances tab (049). The server re-checks the invoice is the farm's and
-- still overdue (TheContractorFinances:requestWriteOff); the result goes
-- out as a TCInvoiceStatusChangedEvent. See src/events/README.md for the
-- general event conventions.

TCWriteOffInvoiceEvent = {}
local TCWriteOffInvoiceEvent_mt = Class(TCWriteOffInvoiceEvent, Event)

InitEventClass(TCWriteOffInvoiceEvent, "TCWriteOffInvoiceEvent")

function TCWriteOffInvoiceEvent.emptyNew()
    return Event.new(TCWriteOffInvoiceEvent_mt)
end

function TCWriteOffInvoiceEvent.new(farmId, invoiceId)
    local self = TCWriteOffInvoiceEvent.emptyNew()
    self.farmId = farmId
    self.invoiceId = invoiceId
    return self
end

function TCWriteOffInvoiceEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.invoiceId)
end

function TCWriteOffInvoiceEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.invoiceId = streamReadInt32(streamId)
    self:run(connection)
end

function TCWriteOffInvoiceEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Finances:requestWriteOff(self.farmId, self.invoiceId)
    end
end
