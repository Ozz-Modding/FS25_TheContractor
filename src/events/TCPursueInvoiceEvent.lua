-- Client asks to pursue one of its farm's overdue invoices, from the
-- Finances tab (053). The server re-checks the invoice is the farm's and
-- still overdue, and that any solicitor's fee is affordable
-- (TheContractorFinances:requestPursuit); the result goes out as a
-- TCInvoiceStatusChangedEvent. See src/events/README.md for the general
-- event conventions.

TCPursueInvoiceEvent = {}
local TCPursueInvoiceEvent_mt = Class(TCPursueInvoiceEvent, Event)

InitEventClass(TCPursueInvoiceEvent, "TCPursueInvoiceEvent")

function TCPursueInvoiceEvent.emptyNew()
    return Event.new(TCPursueInvoiceEvent_mt)
end

function TCPursueInvoiceEvent.new(farmId, invoiceId)
    local self = TCPursueInvoiceEvent.emptyNew()
    self.farmId = farmId
    self.invoiceId = invoiceId
    return self
end

function TCPursueInvoiceEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.invoiceId)
end

function TCPursueInvoiceEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.invoiceId = streamReadInt32(streamId)
    self:run(connection)
end

function TCPursueInvoiceEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Finances:requestPursuit(self.farmId, self.invoiceId)
    end
end
