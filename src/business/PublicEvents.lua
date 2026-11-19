-- Public days out (163): the rules that hold across every kind of day on a
-- farmer's field (TheContractorEventDay's kinds: 137's auction, the open
-- day, 165's show to come). Each kind registers here on every machine at
-- load; this answers for all of them:
--
--   One at a time: no kind announces while another has one, from its
--     announcement until it's cleared up (getOtherEvent).
--   Its field's protected (isFieldInUse, for Jobs:isFieldProtected): no
--     jobs generated, no NPC fieldwork (034), no random event put down.
--   No protest (151) on a day its crowd's up (clashesWithCrowdDay).
--   128's retirements hand its host to the successor (replaceHost).
--   161's calendar change moves its day (remapDates, in TCCalendarChange's
--     SUBSYSTEMS).
--
-- No state of its own: the kinds save and sync themselves.

TheContractorPublicEvents = {}
local TheContractorPublicEvents_mt = Class(TheContractorPublicEvents)

function TheContractorPublicEvents.new()
    local self = setmetatable({}, TheContractorPublicEvents_mt)
    -- The kinds, in the order registered, and by KIND.
    self.kinds = {}
    self.kindsByKey = {}
    return self
end

-- Every machine, at load.
function TheContractorPublicEvents:registerKind(kind)
    table.insert(self.kinds, kind)
    self.kindsByKey[kind.KIND] = kind
end

function TheContractorPublicEvents:getKind(key)
    return self.kindsByKey[key]
end

function TheContractorPublicEvents:getKinds()
    return self.kinds
end

-- The first kind with an event, and the event; nil if none.
function TheContractorPublicEvents:getActive()
    for _, kind in ipairs(self.kinds) do
        local event = kind:getEvent()
        if event ~= nil then
            return kind, event
        end
    end
    return nil, nil
end

-- Any other kind's event, and its kind; nil if none.
function TheContractorPublicEvents:getOtherEvent(ownKind)
    for _, kind in ipairs(self.kinds) do
        local event = kind:getEvent()
        if kind ~= ownKind and event ~= nil then
            return kind, event
        end
    end
    return nil, nil
end

-- The kind and event on a field, if any.
function TheContractorPublicEvents:getEventOnField(fieldId)
    for _, kind in ipairs(self.kinds) do
        if kind:isFieldInUse(fieldId) then
            return kind, kind:getEvent()
        end
    end
    return nil, nil
end

-- Every machine: whether an event (any kind) has the field, from its
-- announcement until it's over.
function TheContractorPublicEvents:isFieldInUse(fieldId)
    return self:getEventOnField(fieldId) ~= nil
end

-- Whether a day is one an event's crowd is up (pure): its day to afterDays
-- after it.
function TheContractorPublicEvents.isCrowdDay(day, event, afterDays)
    if event == nil or event.day == nil then
        return false
    end
    return day >= event.day and day <= event.day + (afterDays or 0)
end

-- Server (151): whether any kind's crowd is up on a day.
function TheContractorPublicEvents:clashesWithCrowdDay(day)
    for _, kind in ipairs(self.kinds) do
        if TheContractorPublicEvents.isCrowdDay(day, kind:getEvent(), kind.AFTER_DAYS) then
            return true
        end
    end
    return false
end

-- Every machine (128): a retired farmer's events are hosted by their
-- successor. Returns how many.
function TheContractorPublicEvents:replaceHost(oldId, newId)
    local count = 0
    for _, kind in ipairs(self.kinds) do
        local event = kind:getEvent()
        if event ~= nil and event.hostFarmerId == oldId then
            event.hostFarmerId = newId
            count = count + 1
        end
    end
    return count
end

-- Every machine (161, TCCalendarChange).
function TheContractorPublicEvents:remapDates(fromModel, toModel)
    for _, kind in ipairs(self.kinds) do
        kind:remapDates(fromModel, toModel)
    end
end
