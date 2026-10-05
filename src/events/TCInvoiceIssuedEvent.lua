-- Broadcast-only: the server invoiced a completed job (049,
-- TheContractorFinances:invoiceJob) and sends the invoice to every client.
-- Public fields only - whether it'll actually be paid stays on the server.
-- See src/events/README.md for the general event conventions.

TCInvoiceIssuedEvent = {}
local TCInvoiceIssuedEvent_mt = Class(TCInvoiceIssuedEvent, Event)

InitEventClass(TCInvoiceIssuedEvent, "TCInvoiceIssuedEvent")

function TCInvoiceIssuedEvent.emptyNew()
    return Event.new(TCInvoiceIssuedEvent_mt)
end

function TCInvoiceIssuedEvent.new(invoice)
    local self = TCInvoiceIssuedEvent.emptyNew()
    self.invoice = invoice
    return self
end

function TCInvoiceIssuedEvent:writeStream(streamId, connection)
    TheContractorFinances.writeInvoice(streamId, self.invoice)
end

function TCInvoiceIssuedEvent:readStream(streamId, connection)
    self.invoice = TheContractorFinances.readInvoice(streamId)
    self:run(connection)
end

function TCInvoiceIssuedEvent:run(connection)
    g_currentMission.TheContractor.Finances:applyInvoiceIssued(self.invoice)
end
