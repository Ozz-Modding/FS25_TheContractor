-- The parking return queue (062). Equipment coming back from a job - the
-- end of a cooldown (023), a job missed before any work (024), a dispatch
-- that was called off (020), haulage rigs (035) - is never revealed where
-- it stood. It's unhitched and each piece joins this FIFO queue, still
-- hidden and out of physics, and the server parks one piece at a time in a
-- free parking slot owned by the job's farm (TCParking.findSpot).
--
--   tc.Parking:returnVehicles(farmId, vehicleIds)        -- server only
--   tc.Parking:returnHiddenVehicles(farmId, vehicleIds)  -- only those hidden
--   tc.Parking:removeVehicles(vehicleIds)                -- taken out early
--   tc.Parking:isPending(vehicleId)                      -- every machine
--
-- Fixed interval, never every frame: every FAST_INTERVAL_MS while the last
-- pass placed something, the oldest piece that fits is placed. Placing one
-- per pass also gives physics time to see the vehicle it just put down
-- before the next overlap test, so there's no reservation table. A pass
-- that places nothing backs off to SLOW_INTERVAL_MS.
--
-- Folding: each piece is folded (or unfolded) to how it may stand unhitched
-- (TCFolding) as it joins the queue, and isn't placed until it's done, so
-- it comes back folded where it may. A piece that hasn't finished after
-- FOLD_MAX_WAIT_PASSES passes is placed as it is.
--
-- A vehicle is in a cooldown or in this queue, never both: returnVehicles
-- skips anything still in a cooldown, and a cooldown or a fresh dispatch
-- takes its vehicles out of the queue first (removeVehicles).
--
-- While pending, a vehicle stays in TCEquipmentVisibility's hidden set (so
-- a joining client hides it, 061) and TCVehicleLock locks it. It still
-- counts as free for allocation (Allocation:isVehicleFree): a hired worker's
-- dispatch takes it straight from the queue, and a player self-allocation
-- puts it at the shop first (sendToShop).
--
-- The queue itself is replicated (TCParkingQueuedEvent/TCParkingRemovedEvent
-- and initial state, object ids), since every machine derives its locks
-- from it and the allocation picker shows an "Awaiting parking" chip. The
-- rest - batches' inbox messages, the farm's notice, whether the player's
-- been told - is server-only.
--
-- Telling the player: once every piece of a return (a batch) that was
-- parked here is down, the farm gets a "back and parked" notification
-- naming them. The first time a piece can't be parked, the farm gets
-- a notification (TCParkingNoticeEvent). Each return (a batch) with a piece
-- that can't be parked posts one inbox message with a Send to shop action,
-- removed once the whole batch is parked. While the farm has anything
-- waiting, its Overview board carries one notice with the count.

TheContractorParking = {}
TheContractorParking_mt = Class(TheContractorParking)

TheContractorParking.FAST_INTERVAL_MS = 1000
TheContractorParking.SLOW_INTERVAL_MS = 5000
TheContractorParking.FOLD_MAX_WAIT_PASSES = 30

TheContractorParking.MESSAGE_KIND = "parkingWaiting"
TheContractorParking.SEND_TO_SHOP_ACTION = { key = "sendToShop", textKey = "tc_parking_sendToShopButton" }

function TheContractorParking.new()
    local self = {}
    setmetatable(self, TheContractorParking_mt)

    -- FIFO: { vehicleId, farmId, batchId, notified (server only) }.
    self.queue = {}
    -- vehicleId -> entry, derived from the queue.
    self.entryByVehicleId = {}
    self.nextBatchId = 1

    -- Server only. batchId -> inbox message id.
    self.messageIdByBatch = {}
    -- Server only, not saved. batchId -> { farmId, names } of the pieces
    -- parked so far, for the notification once the batch is done.
    self.parkedByBatch = {}
    -- Server only. farmId -> { id, count }, the farm's Overview notice.
    self.noticeByFarm = {}

    self.intervalMs = TheContractorParking.FAST_INTERVAL_MS
    self.accumulatedMs = 0
    -- Server only, not saved (159). farmId -> { vehicleIds (still to try,
    -- in order), parked (names), noRoom (names) }.
    self.parkAllByFarm = {}
    self.parkAllAccumulatedMs = 0
    -- Server, from a save until resolveSavedVehicles.
    self.savedEntries = nil

    return self
end

function TheContractorParking:register(inbox)
    self.inbox = inbox
    inbox:registerMessageKind(TheContractorParking.MESSAGE_KIND, {
        onAction = function(farmId, message, actionKey)
            self:onMessageAction(farmId, message, actionKey)
        end,
        category = "parking",
        chipTone = "warn",
    })
end

-- Query API ---------------------------------------------------------------

function TheContractorParking:isPending(vehicleId)
    return vehicleId ~= nil and self.entryByVehicleId[vehicleId] ~= nil
end

function TheContractorParking:getPendingCount(farmId)
    local count = 0
    for _, entry in ipairs(self.queue) do
        if entry.farmId == farmId then
            count = count + 1
        end
    end
    return count
end

local function getVehicle(vehicleId)
    local vehicle = NetworkUtil.getObject(vehicleId)
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

local function getVehicleName(vehicleId)
    local vehicle = getVehicle(vehicleId)
    return vehicle ~= nil and vehicle:getFullName() or "?"
end

-- Queueing (server-authoritative) ------------------------------------------

-- Unhitches, hides and queues each vehicle as one batch. Skips vehicles
-- that are gone, already queued or still in a cooldown.
function TheContractorParking:returnVehicles(farmId, vehicleIds)
    if not g_currentMission:getIsServer() then
        return
    end

    -- 071: a courtesy vehicle the insurer's waiting for goes back to them
    -- instead.
    local courtesy = g_currentMission.TheContractor.CourtesyVehicle
    if courtesy ~= nil then
        vehicleIds = courtesy:collectDueVehicles(vehicleIds)
    end

    local cooldown = g_currentMission.TheContractor.Cooldown
    local batchId = self.nextBatchId
    local entries = {}
    local ids = {}
    local seen = {}
    for _, vehicleId in ipairs(vehicleIds) do
        if not seen[vehicleId] and not self:isPending(vehicleId) and not cooldown:isVehicleInCooldown(vehicleId) and
            getVehicle(vehicleId) ~= nil then
            seen[vehicleId] = true
            table.insert(entries, { vehicleId = vehicleId, farmId = farmId, batchId = batchId, notified = false })
            table.insert(ids, vehicleId)
        end
    end
    if #entries == 0 then
        return
    end
    self.nextBatchId = self.nextBatchId + 1

    TCJobSiteSetup.unhitchVehicles(ids)
    for _, vehicleId in ipairs(ids) do
        TCFolding.foldForParking(getVehicle(vehicleId))
    end
    TCEquipmentVisibility.setVisibleEverywhere(ids, false)

    self:applyQueued(entries)
    if g_server ~= nil then
        g_server:broadcastEvent(TCParkingQueuedEvent.new(entries))
    end

    TCLog.info("TheContractor: farm %d batch %d of %d machines waiting to be parked", farmId, batchId, #entries)

    self:updateNotice(farmId)
    TCVehicleLock.refresh()

    -- First try soon, not after a slow back-off.
    self.intervalMs = TheContractorParking.FAST_INTERVAL_MS
    self.accumulatedMs = 0
end

-- returnVehicles for only those the server currently has hidden - for a
-- return where some of the equipment may never have left the yard.
function TheContractorParking:returnHiddenVehicles(farmId, vehicleIds)
    local hidden = {}
    for _, vehicleId in ipairs(vehicleIds) do
        if TCEquipmentVisibility.isHidden(vehicleId) then
            table.insert(hidden, vehicleId)
        end
    end
    self:returnVehicles(farmId, hidden)
end

-- Takes vehicles out of the queue as they are (still hidden). A no-op for
-- any that aren't queued.
function TheContractorParking:removeVehicles(vehicleIds)
    if not g_currentMission:getIsServer() then
        return
    end

    local removed = {}
    local farmIds = {}
    for _, vehicleId in ipairs(vehicleIds) do
        local entry = self.entryByVehicleId[vehicleId]
        if entry ~= nil then
            table.insert(removed, vehicleId)
            farmIds[entry.farmId] = true
        end
    end
    if #removed == 0 then
        return
    end

    self:applyRemoved(removed)
    if g_server ~= nil then
        g_server:broadcastEvent(TCParkingRemovedEvent.new(removed))
    end

    for farmId in pairs(farmIds) do
        self:updateNotice(farmId)
    end
    self:removeFinishedBatchMessages()
    TCVehicleLock.refresh()
end

-- State application, on every machine.

function TheContractorParking:applyQueued(entries)
    for _, entry in ipairs(entries) do
        if self.entryByVehicleId[entry.vehicleId] == nil then
            table.insert(self.queue, entry)
            self.entryByVehicleId[entry.vehicleId] = entry
        end
        if entry.batchId >= self.nextBatchId then
            self.nextBatchId = entry.batchId + 1
        end
    end
end

function TheContractorParking:applyRemoved(vehicleIds)
    local isRemoved = {}
    for _, vehicleId in ipairs(vehicleIds) do
        isRemoved[vehicleId] = true
        self.entryByVehicleId[vehicleId] = nil
    end
    local kept = {}
    for _, entry in ipairs(self.queue) do
        if not isRemoved[entry.vehicleId] then
            table.insert(kept, entry)
        end
    end
    self.queue = kept
end

-- Parking (server-only tick) ----------------------------------------------

function TheContractorParking:update(dt)
    if not g_currentMission:getIsServer() or self.savedEntries ~= nil then
        return
    end
    self:updateParkAll(dt)
    if #self.queue == 0 then
        return
    end

    self.accumulatedMs = self.accumulatedMs + dt
    if self.accumulatedMs < self.intervalMs then
        return
    end
    self.accumulatedMs = 0

    local placed, isFolding = self:runPass()
    self.intervalMs = (placed or isFolding) and TheContractorParking.FAST_INTERVAL_MS or
        TheContractorParking.SLOW_INTERVAL_MS
end

-- Whether the entry's piece is still folding for parking (TCFolding), up to
-- FOLD_MAX_WAIT_PASSES passes. Asked again each pass, which also folds a
-- piece loaded from a save mid-fold.
local function isStillFolding(entry, vehicle)
    if (entry.foldPasses or 0) >= TheContractorParking.FOLD_MAX_WAIT_PASSES or
        not TCFolding.foldForParking(vehicle) then
        return false
    end
    entry.foldPasses = (entry.foldPasses or 0) + 1
    return true
end

-- Parks the oldest piece that fits and has finished folding. Pieces tried
-- and turned down for the first time are told to their farm, one
-- notification per farm, and their batch gets its inbox message. Returns
-- whether anything was placed, and whether anything's still folding.
function TheContractorParking:runPass()
    local gone = {}
    for _, entry in ipairs(self.queue) do
        if getVehicle(entry.vehicleId) == nil then
            table.insert(gone, entry.vehicleId)
        end
    end
    if #gone > 0 then
        self:removeVehicles(gone)
    end

    local newlyStuck = {}
    local placed = false
    local isFolding = false
    for _, entry in ipairs(self.queue) do
        local vehicle = getVehicle(entry.vehicleId)
        local stillFolding = isStillFolding(entry, vehicle)
        local x, y, z, rotY = nil, nil, nil, nil
        if stillFolding then
            isFolding = true
        else
            x, y, z, rotY = TCParking.findSpot(vehicle, entry.farmId)
        end
        if stillFolding then
            -- Waiting for its fold, not stuck.
        elseif x ~= nil then
            local parked = self.parkedByBatch[entry.batchId] or { farmId = entry.farmId, names = {} }
            table.insert(parked.names, vehicle:getFullName())
            self.parkedByBatch[entry.batchId] = parked
            self:removeVehicles({ entry.vehicleId })
            TCParking.placeVehicle(vehicle, x, y, z, rotY)
            TCLog.info("TheContractor: farm %d parked '%s'", entry.farmId, vehicle:getFullName())
            placed = true
            break
        elseif not entry.notified then
            entry.notified = true
            table.insert(newlyStuck, entry)
        end
    end

    self:tellStuck(newlyStuck)
    return placed, isFolding
end

-- One notification per farm naming its newly stuck pieces, and an inbox
-- message for each of their batches that hasn't had one.
function TheContractorParking:tellStuck(entries)
    local namesByFarm = {}
    local batches = {}
    for _, entry in ipairs(entries) do
        namesByFarm[entry.farmId] = namesByFarm[entry.farmId] or {}
        table.insert(namesByFarm[entry.farmId], getVehicleName(entry.vehicleId))
        if self.messageIdByBatch[entry.batchId] == nil and not batches[entry.batchId] then
            batches[entry.batchId] = entry.farmId
        end
    end

    for farmId, names in pairs(namesByFarm) do
        self:notify(farmId, "tc_parking_waitingNotification", table.concat(names, ", "))
    end
    for batchId, farmId in pairs(batches) do
        self:postBatchMessage(farmId, batchId)
    end
end

-- Shows a notification on the farm's machines (TCParkingNoticeEvent) - a
-- warning, or a plain one if isGood.
function TheContractorParking:notify(farmId, textKey, arg, isGood)
    TCParkingNoticeEvent.showNotification(farmId, textKey, arg, isGood)
    if g_server ~= nil then
        g_server:broadcastEvent(TCParkingNoticeEvent.new(farmId, textKey, arg, isGood))
    end
end

-- Server: the batch's still-pending entries.
function TheContractorParking:getBatchEntries(farmId, batchId)
    local entries = {}
    for _, entry in ipairs(self.queue) do
        if entry.batchId == batchId and entry.farmId == farmId then
            table.insert(entries, entry)
        end
    end
    return entries
end

function TheContractorParking:postBatchMessage(farmId, batchId)
    local names = {}
    for _, entry in ipairs(self:getBatchEntries(farmId, batchId)) do
        table.insert(names, getVehicleName(entry.vehicleId))
    end
    if #names == 0 then
        return
    end

    self.messageIdByBatch[batchId] = self.inbox:postMessage(farmId, TheContractorParking.MESSAGE_KIND,
        "tc_parking_messageTitle", "tc_parking_messageBody", { table.concat(names, ", ") },
        { TheContractorParking.SEND_TO_SHOP_ACTION, TheContractorInbox.DISMISS_ACTION }, { batchId = batchId })
end

-- Takes down the inbox message of every batch with nothing left waiting,
-- and tells the farm what of it was parked here (anything sent to the shop
-- or taken out by a new dispatch isn't).
function TheContractorParking:removeFinishedBatchMessages()
    local hasEntries = {}
    for _, entry in ipairs(self.queue) do
        hasEntries[entry.batchId] = true
    end

    local done = {}
    for batchId, parked in pairs(self.parkedByBatch) do
        if not hasEntries[batchId] then
            table.insert(done, batchId)
            self:notify(parked.farmId, "tc_parking_returnedNotification", table.concat(parked.names, ", "), true)
        end
    end
    for _, batchId in ipairs(done) do
        self.parkedByBatch[batchId] = nil
    end
    local finished = {}
    for batchId in pairs(self.messageIdByBatch) do
        if not hasEntries[batchId] then
            table.insert(finished, batchId)
        end
    end
    for _, batchId in ipairs(finished) do
        self.inbox:removeMessage(self.messageIdByBatch[batchId])
        self.messageIdByBatch[batchId] = nil
    end
end

-- The farm's Overview notice: re-published when the count changes, taken
-- down when nothing's waiting.
function TheContractorParking:updateNotice(farmId)
    local notices = g_currentMission.TheContractor.Notices
    local count = self:getPendingCount(farmId)
    local notice = self.noticeByFarm[farmId]
    if notice ~= nil and notice.count == count then
        return
    end

    if notice ~= nil then
        notices:remove(notice.id)
        self.noticeByFarm[farmId] = nil
    end
    if count > 0 then
        local text = count == 1 and g_i18n:getText("tc_parking_noticeOne") or
            string.format(g_i18n:getText("tc_parking_noticeMany"), count)
        self.noticeByFarm[farmId] = { id = notices:publish(farmId, text), count = count }
    end
end

-- Getting a pending vehicle back early -------------------------------------

-- Server: puts pending vehicles at the shop's reset spots and takes them
-- out of the queue. Returns the names of any that didn't fit, which stay
-- pending.
function TheContractorParking:sendToShop(vehicleIds)
    local placed = {}
    local failedNames = {}
    for _, vehicleId in ipairs(vehicleIds) do
        local vehicle = getVehicle(vehicleId)
        if vehicle ~= nil and self:isPending(vehicleId) then
            local x, y, z, rotY = TCParking.findShopSpot(vehicle)
            if x ~= nil then
                table.insert(placed, { vehicle = vehicle, x = x, y = y, z = z, rotY = rotY })
            else
                table.insert(failedNames, vehicle:getFullName())
            end
        end
    end

    local placedIds = {}
    for _, placement in ipairs(placed) do
        table.insert(placedIds, NetworkUtil.getObjectId(placement.vehicle))
    end
    self:removeVehicles(placedIds)
    for _, placement in ipairs(placed) do
        TCParking.placeVehicle(placement.vehicle, placement.x, placement.y, placement.z, placement.rotY)
        TCLog.info("TheContractor: '%s' sent to the shop instead of a parking slot", placement.vehicle:getFullName())
    end

    return failedNames
end

-- Server: the inbox message's Send to shop. Whatever doesn't fit at the
-- shop stays pending, the player's told, and the batch gets a fresh message
-- (this one is removed once the handler returns).
function TheContractorParking:onMessageAction(farmId, message, actionKey)
    local batchId = message.payload.batchId
    if self.messageIdByBatch[batchId] == message.id then
        self.messageIdByBatch[batchId] = nil
    end
    if actionKey ~= TheContractorParking.SEND_TO_SHOP_ACTION.key then
        return
    end

    local vehicleIds = {}
    for _, entry in ipairs(self:getBatchEntries(farmId, batchId)) do
        table.insert(vehicleIds, entry.vehicleId)
    end
    local failedNames = self:sendToShop(vehicleIds)
    if #failedNames > 0 then
        self:notify(farmId, "tc_parking_shopFullNotification", table.concat(failedNames, ", "))
        self:postBatchMessage(farmId, batchId)
    end
end

-- Park all (159) --------------------------------------------------------------
-- The Logbook's Park all button (TCParkAllEvent): every machine of the farm
-- that's free and not already standing in a slot that would take it is
-- parked, for a farm that started with machines and placed its slots after.
-- One machine a pass, every PARK_ALL_INTERVAL_MS, so physics sees the one
-- just put down before the next overlap test (as the queue does), biggest
-- first so the small ones fill the gaps. Unlike a return it never hides
-- anything: a machine with no room stays where it is. The farm's told once
-- the run's done. Server only, not saved: a run takes seconds.
--
-- A dispatch uses the same run (parkMachines, quietly) for what it unhitched
-- from a job's tractor and left in the yard (a front loader, its bucket),
-- so that's parked if there's room and left where it stood if not. A quiet
-- run tells nobody; park all joining one makes it tell.

TheContractorParking.PARK_ALL_INTERVAL_MS = 250

local function getChain(vehicle)
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    local chain = root ~= nil and root.getChildVehicles ~= nil and root:getChildVehicles() or nil
    return chain or { vehicle }
end

-- Whether anything in the vehicle's combination is being used: someone in
-- it, a helper, AutoDrive or a staff driver on it, or it's locked (out on a
-- job, in a cooldown or the queue, stolen, an auction lot).
function TheContractorParking.isChainBusy(vehicle)
    local drivers = g_currentMission.TheContractor.Drivers
    for _, chainVehicle in pairs(getChain(vehicle)) do
        if TCVehicleLock.isLocked(chainVehicle) or
            (chainVehicle.getIsControlled ~= nil and chainVehicle:getIsControlled()) or
            TheContractorDrivers.isVehicleDriven(chainVehicle) or
            (drivers ~= nil and drivers:hasDriver(chainVehicle)) then
            return true
        end
    end
    return false
end

-- Whether park all may move the vehicle: one of the farm's own machines
-- (owned or leased; not a pallet, a train, a customer's or anything else on
-- a mission), in sight, and nothing in its combination busy.
function TheContractorParking.isParkable(vehicle, farmId)
    if vehicle == nil or vehicle.isDeleted or vehicle.isPallet or vehicle.spec_wearable == nil or
        vehicle.spec_splineVehicle ~= nil or vehicle.getOwnerFarmId == nil or vehicle:getOwnerFarmId() ~= farmId or
        vehicle.propertyState == VehiclePropertyState.MISSION then
        return false
    end
    -- A weight on its machine stays on, and is parked with it.
    if TCBallast.isHitchedWeight(vehicle) then
        return false
    end
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    local tc = g_currentMission.TheContractor
    if vehicleId == nil or TCEquipmentVisibility.isHidden(vehicleId) or (tc.Theft ~= nil and tc.Theft:isStolen(vehicleId)) or
        TheContractorRepairContracts.isContractVehicle(vehicle) then
        return false
    end
    return not TheContractorParking.isChainBusy(vehicle)
end

-- Server: starts a run for the farm (none if one's going, unless it's a
-- dispatch's quiet one, which it joins). Returns how many machines it'll
-- try.
function TheContractorParking:parkAll(farmId)
    local run = self.parkAllByFarm[farmId]
    if not g_currentMission:getIsServer() or (run ~= nil and not run.isQuiet) then
        return 0
    end

    local candidates = {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if TheContractorParking.isParkable(vehicle, farmId) and not TCParking.isParked(vehicle, farmId) then
            local size = vehicle.size or {}
            table.insert(candidates, { id = NetworkUtil.getObjectId(vehicle), area = (size.width or 0) * (size.length or 0) })
        end
    end
    if #candidates == 0 then
        if run ~= nil then
            run.isQuiet = false
        else
            self:notify(farmId, "tc_parking_parkAllNothing", "", true)
        end
        return 0
    end
    table.sort(candidates, function(a, b)
        if a.area ~= b.area then
            return a.area > b.area
        end
        return a.id < b.id
    end)

    local vehicleIds = {}
    for _, candidate in ipairs(candidates) do
        table.insert(vehicleIds, candidate.id)
    end
    local count = self:parkMachines(farmId, vehicleIds, false)
    TCLog.info("TheContractor: farm %d parking all, %d machines to try", farmId, count)
    return count
end

-- Server: adds machines to the farm's run, starting one if there's none,
-- each tried as park all tries them. A quiet run (a dispatch's) tells the
-- farm nothing when it's done; it stops being quiet if anything loud joins.
-- Returns how many were added (any already in the run aren't).
function TheContractorParking:parkMachines(farmId, vehicleIds, isQuiet)
    if not g_currentMission:getIsServer() or #vehicleIds == 0 then
        return 0
    end
    local run = self.parkAllByFarm[farmId]
    if run == nil then
        run = { vehicleIds = {}, parked = {}, noRoom = {}, isQuiet = isQuiet == true }
        self.parkAllByFarm[farmId] = run
    elseif not isQuiet then
        run.isQuiet = false
    end

    local inRun = {}
    for _, vehicleId in ipairs(run.vehicleIds) do
        inRun[vehicleId] = true
    end
    local count = 0
    for _, vehicleId in ipairs(vehicleIds) do
        if not inRun[vehicleId] then
            inRun[vehicleId] = true
            table.insert(run.vehicleIds, vehicleId)
            count = count + 1
        end
    end
    return count
end

function TheContractorParking:updateParkAll(dt)
    if next(self.parkAllByFarm) == nil then
        self.parkAllAccumulatedMs = 0
        return
    end
    self.parkAllAccumulatedMs = self.parkAllAccumulatedMs + dt
    if self.parkAllAccumulatedMs < TheContractorParking.PARK_ALL_INTERVAL_MS then
        return
    end
    self.parkAllAccumulatedMs = 0

    local finished = {}
    for farmId, run in pairs(self.parkAllByFarm) do
        if self:parkAllStep(farmId, run) then
            table.insert(finished, farmId)
        end
    end
    for _, farmId in ipairs(finished) do
        self:finishParkAll(farmId)
    end
end

-- Tries the run's next machine: parked if there's room, left where it is if
-- not, skipped if it's gone or been taken into use since. Returns whether
-- the run's done.
function TheContractorParking:parkAllStep(farmId, run)
    local vehicleId = table.remove(run.vehicleIds, 1)
    if vehicleId == nil then
        return true
    end
    local vehicle = getVehicle(vehicleId)
    if vehicle ~= nil and TheContractorParking.isParkable(vehicle, farmId) and not TCParking.isParked(vehicle, farmId) then
        local x, y, z, rotY = TCParking.findSpot(vehicle, farmId)
        if x ~= nil then
            TCJobSiteSetup.unhitchVehicles({ vehicleId })
            TCParking.placeVehicle(vehicle, x, y, z, rotY)
            -- In sight, so it folds where it's put down (TCFolding).
            TCFolding.foldForParking(vehicle)
            table.insert(run.parked, vehicle:getFullName())
            TCLog.info("TheContractor: farm %d parked '%s' (park all)", farmId, vehicle:getFullName())
        else
            table.insert(run.noRoom, vehicle:getFullName())
        end
    end
    return #run.vehicleIds == 0
end

function TheContractorParking:finishParkAll(farmId)
    local run = self.parkAllByFarm[farmId]
    self.parkAllByFarm[farmId] = nil
    if run == nil then
        return
    end
    TCLog.info("TheContractor: farm %d park all done, %d parked, %d with no room", farmId, #run.parked, #run.noRoom)
    if run.isQuiet then
        return
    end
    if #run.parked > 0 then
        self:notify(farmId, "tc_parking_parkAllParked", tostring(#run.parked), true)
    end
    if #run.noRoom > 0 then
        self:notify(farmId, "tc_parking_parkAllNoRoom", table.concat(run.noRoom, ", "))
    elseif #run.parked == 0 then
        self:notify(farmId, "tc_parking_parkAllNothing", "", true)
    end
end

-- Wire serialization --------------------------------------------------------

function TheContractorParking.writeEntries(streamId, entries)
    streamWriteInt32(streamId, #entries)
    for _, entry in ipairs(entries) do
        streamWriteInt32(streamId, entry.vehicleId)
        streamWriteInt32(streamId, entry.farmId)
        streamWriteInt32(streamId, entry.batchId)
    end
end

function TheContractorParking.readEntries(streamId)
    local entries = {}
    local count = streamReadInt32(streamId)
    for i = 1, count do
        entries[i] = {
            vehicleId = streamReadInt32(streamId),
            farmId = streamReadInt32(streamId),
            batchId = streamReadInt32(streamId),
        }
    end
    return entries
end

function TheContractorParking:writeInitialClientState(streamId, connection)
    TheContractorParking.writeEntries(streamId, self.queue)
end

function TheContractorParking:readInitialClientState(streamId, connection)
    self:applyQueued(TheContractorParking.readEntries(streamId))
end

-- Persistence -----------------------------------------------------------------
-- The queue is saved in FIFO order by vehicle uniqueId (TCVehicleIds) and
-- turned back into object ids in resolveSavedVehicles. The notice and
-- message ids are kept so a reload doesn't post them twice.

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
-- Every machine (TCVehicleReplace): a machine reloaded as a new object
-- keeps its place in the queue and in a park all.
function TheContractorParking:remapVehicle(oldId, newId)
    for _, entry in ipairs(self.queue) do
        TCVehicleIds.replaceField(entry, "vehicleId", oldId, newId)
    end
    TCVehicleIds.replaceKey(self.entryByVehicleId, oldId, newId)
    for _, run in pairs(self.parkAllByFarm) do
        TCVehicleIds.replaceInList(run.vehicleIds, oldId, newId)
    end
end

function TheContractorParking:forgetFarm(farmId)
    local kept = {}
    for _, entry in ipairs(self.queue) do
        if entry.farmId == farmId then
            self.entryByVehicleId[entry.vehicleId] = nil
        else
            table.insert(kept, entry)
        end
    end
    self.queue = kept
    for batchId, parked in pairs(self.parkedByBatch) do
        if parked.farmId == farmId then
            self.parkedByBatch[batchId] = nil
            self.messageIdByBatch[batchId] = nil
        end
    end
    self.noticeByFarm[farmId] = nil
    self.parkAllByFarm[farmId] = nil
end

function TheContractorParking:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.parking", TheContractor.SaveKey)
    self.nextBatchId = Utils.getNoNil(getXMLInt(xmlFile, rootKey .. "#nextBatchId"), 1)

    self.savedEntries = {}
    local index = 0
    while true do
        local key = string.format("%s.vehicle(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        table.insert(self.savedEntries, {
            uniqueId = getXMLString(xmlFile, key .. "#uniqueId"),
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            batchId = Utils.getNoNil(getXMLInt(xmlFile, key .. "#batchId"), 0),
            notified = Utils.getNoNil(getXMLBool(xmlFile, key .. "#notified"), false),
        })
        index = index + 1
    end

    index = 0
    while true do
        local key = string.format("%s.batch(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local batchId = getXMLInt(xmlFile, key .. "#id")
        local messageId = getXMLInt(xmlFile, key .. "#messageId")
        if batchId ~= nil and messageId ~= nil then
            self.messageIdByBatch[batchId] = messageId
        end
        index = index + 1
    end

    index = 0
    while true do
        local key = string.format("%s.notice(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        local noticeId = getXMLInt(xmlFile, key .. "#id")
        if farmId ~= nil and noticeId ~= nil then
            self.noticeByFarm[farmId] = { id = noticeId, count = Utils.getNoNil(getXMLInt(xmlFile, key .. "#count"), 0) }
        end
        index = index + 1
    end
end

function TheContractorParking:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.parking", TheContractor.SaveKey)
    setXMLInt(xmlFile, rootKey .. "#nextBatchId", self.nextBatchId)

    local index = 0
    for _, entry in ipairs(self.queue) do
        local uniqueId = TCVehicleIds.getUniqueId(entry.vehicleId)
        if uniqueId ~= nil then
            local key = string.format("%s.vehicle(%d)", rootKey, index)
            setXMLString(xmlFile, key .. "#uniqueId", uniqueId)
            setXMLInt(xmlFile, key .. "#farmId", entry.farmId)
            setXMLInt(xmlFile, key .. "#batchId", entry.batchId)
            setXMLBool(xmlFile, key .. "#notified", entry.notified == true)
            index = index + 1
        end
    end

    index = 0
    for batchId, messageId in pairs(self.messageIdByBatch) do
        local key = string.format("%s.batch(%d)", rootKey, index)
        setXMLInt(xmlFile, key .. "#id", batchId)
        setXMLInt(xmlFile, key .. "#messageId", messageId)
        index = index + 1
    end

    index = 0
    for farmId, notice in pairs(self.noticeByFarm) do
        local key = string.format("%s.notice(%d)", rootKey, index)
        setXMLInt(xmlFile, key .. "#farmId", farmId)
        setXMLInt(xmlFile, key .. "#id", notice.id)
        setXMLInt(xmlFile, key .. "#count", notice.count)
        index = index + 1
    end
end

-- Server, once vehicles exist (TheContractor:resolveSavedVehicles): the
-- saved uniqueIds back to object ids, in order, and every pending vehicle
-- hidden again (vehicles always load visible). One sold while pending just
-- drops out, so the notices and messages are brought up to date too.
function TheContractorParking:resolveSavedVehicles()
    local savedEntries = self.savedEntries
    self.savedEntries = nil
    if savedEntries == nil then
        return
    end

    local entries = {}
    local vehicleIds = {}
    for _, saved in ipairs(savedEntries) do
        local vehicleId = TCVehicleIds.getObjectId(saved.uniqueId)
        if vehicleId ~= nil and saved.farmId ~= nil then
            table.insert(entries, {
                vehicleId = vehicleId,
                farmId = saved.farmId,
                batchId = saved.batchId,
                notified = saved.notified,
            })
            table.insert(vehicleIds, vehicleId)
        end
    end
    self:applyQueued(entries)
    TCEquipmentVisibility.hideVehicles(vehicleIds)

    local farmIds = {}
    for farmId in pairs(self.noticeByFarm) do
        farmIds[farmId] = true
    end
    for _, entry in ipairs(self.queue) do
        farmIds[entry.farmId] = true
    end
    for farmId in pairs(farmIds) do
        self:updateNotice(farmId)
    end
    self:removeFinishedBatchMessages()
end

-- Console commands (tcDebug park - see TCConsole) --------------------------------

function TheContractorParking.registerConsoleCommands()
    TCConsole.register("debug", "park", {
        description = "Park the vehicle you're in: a random free parking slot, or the parking queue if none is free",
        run = function(farmId, args, context)
            local vehicle = TCConsole.getVehicle(context)
            if vehicle == nil then
                return "Error: get in the vehicle you want parked first."
            end
            if vehicle:getOwnerFarmId() ~= farmId then
                return "Error: that vehicle isn't your farm's."
            end
            if TCVehicleLock.isLocked(vehicle) then
                return "Error: that vehicle is out on a job."
            end

            -- Out first, wherever they typed it (the server's leave reaches
            -- their machine).
            local player = TCConsole.getPlayer(context)
            if player ~= nil and player.getCurrentVehicle ~= nil and player:getCurrentVehicle() == vehicle then
                player:leaveVehicle(vehicle)
            end
            local name = vehicle:getFullName()
            local vehicleId = NetworkUtil.getObjectId(vehicle)
            TCJobSiteSetup.unhitchVehicles({ vehicleId })

            local x, y, z, rotY = TCParking.findSpot(vehicle, farmId, true)
            if x ~= nil then
                TCParking.placeVehicle(vehicle, x, y, z, rotY)
                return string.format("Parked %s in a parking slot.", name)
            end

            g_currentMission.TheContractor.Parking:returnVehicles(farmId, { vehicleId })
            return string.format("No free parking slot: %s is hidden and waiting in the parking queue.", name)
        end,
    })

    -- The dev panel's Parking page lists these itself; this is its typed twin.
    TCConsole.register("debug", "zones", {
        description = "List your farm's parking slots and repair zones, with their map coordinates",
        serverOnly = false,
        run = function(farmId, args, context)
            local px, pz
            if TCConsole.hasPosition(context) then
                px, pz = context.x, context.z
            end
            local rows, nearestIndex = TCParking.getZoneRows(farmId, px, pz)
            if #rows == 0 then
                return "Your farm has no parking slots or repair zones."
            end
            local lines = {}
            for index, row in ipairs(rows) do
                table.insert(lines, string.format("%d: %s (%s) at x %d, z %d%s", row.id, row.kind, row.name,
                    math.floor(row.mapX + 0.5), math.floor(row.mapZ + 0.5),
                    index == nearestIndex and string.format(", nearest you (%d m)", math.floor(row.distance + 0.5)) or ""))
            end
            return table.concat(lines, "\n")
        end,
    })

    TCConsole.register("debug", "removeZone", {
        args = "<zoneId>",
        hints = { zoneId = "a parking slot's or repair zone's id (tcDebug zones)" },
        description = "Sell one of your parking slots or repair zones, for one the construction menu can't pick",
        run = function(farmId, args)
            local zoneId = tonumber(args[1])
            if zoneId == nil then
                return false
            end
            local placeable = NetworkUtil.getObject(zoneId)
            if not TCParking.isZone(placeable) or placeable.isDeleted or placeable.markedForDeletion then
                return string.format("Error: no parking slot or repair zone %d (tcDebug zones lists them).", zoneId)
            end
            if placeable:getOwnerFarmId() ~= farmId then
                return string.format("Error: zone %d isn't your farm's.", zoneId)
            end
            local kind = TCParking.getZoneKind(placeable)
            local price = TCParking.removeZone(placeable)
            return string.format("Sold %s %d for %s.", string.lower(kind), zoneId, g_i18n:formatMoney(price, 0, true, true))
        end,
    })
end
