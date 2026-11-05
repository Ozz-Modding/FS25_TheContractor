-- HUD icon + unread badge + arrival sound for the Inbox (013). Mirrors
-- FS25_RedTape/src/hud/SaltSchemeHUD.lua's shape: a small standalone
-- Overlay/renderText draw, polled periodically from TheContractor:update,
-- rather than fighting the vanilla HUDDisplay class hierarchy for something
-- this simple.
--
-- "Unread" is purely client-local UI state, not farm-scoped persisted state
-- (see src/events/README.md) — it's just "which currently-offered job ids
-- has *this* client already looked at in the Inbox tab," reset to nothing
-- at map load. There's no need to synchronise it, and it self-corrects the
-- moment a job leaves the offered state (accepted/declined/negotiating),
-- since the unread count is always recomputed against Jobs:getJobsByState
-- rather than tracked as a running counter.
--
-- Only offered-state jobs count towards the badge/sound (not negotiating —
-- 014's territory, and a job already being negotiated isn't news to the
-- player). Sound only fires for genuinely new arrivals (TheContractorJobs:
-- registerJob's isNewArrival flag), never for the historical jobs replayed
-- into a newly joining client via TCInitialClientStateEvent.
--
-- Inbox messages (050) count the same way: every message on the farm the
-- player hasn't seen yet, with the sound on a genuinely new one.

TCInboxHUD = {}
TCInboxHUD_mt = Class(TCInboxHUD)

-- The badge is a tinted disc with the unread count on it, placed the way
-- FS25_ToolInclinationHelper places its circles: in pixels relative to the
-- vanilla speedometer, scaled through the speedometer's own
-- scalePixelValuesToScreenVector so it follows the UI scale setting.
-- In a vehicle it sits on the speedometer's bottom line, left of the
-- speedometer background (speedBg, repositioned by vanilla every draw since
-- its width depends on the vehicle's fuel/damage/gear bars) and one slot
-- beyond ToolInclinationHelper's two circles at 0 and -35 px. On foot there's
-- no speedometer, so it tucks into the bottom-right HUD anchor instead.
-- Sizes are in reference (1080p) pixels.
TCInboxHUD.BADGE_SIZE = 32
TCInboxHUD.VEHICLE_OFFSET_X = -70
-- FS25_AdvancedDamageSystem widens the speedometer panel to the left for its
-- vehicles (a dashboard band over where the badge would be), leaving speedBg
-- where it was. Then the badge sits this far left of the widened panel's own
-- left edge (ADS_Hud.getSpeedMeterLeftEdge) instead: its width plus a gap.
TCInboxHUD.ADS_OFFSET_X = -40
TCInboxHUD.ADS_MOD_NAME = "FS25_AdvancedDamageSystem"
TCInboxHUD.TEXT_SIZE = 18
-- Middle-aligned text sits slightly low; ToolInclinationHelper nudges its own
-- up by the same 2 px (text at 18 of a 32 px circle).
TCInboxHUD.TEXT_OFFSET_Y = 2
-- Vanilla's HUD green, so it's distinct from ToolInclinationHelper's black circles.
TCInboxHUD.BADGE_COLOR = { 0.2384, 0.4621, 0.0015, 0.95 }
TCInboxHUD.MAX_SHOWN_COUNT = 99
TCInboxHUD.SYNC_INTERVAL_MS = 1000

function TCInboxHUD.new()
    local self = {}
    setmetatable(self, TCInboxHUD_mt)

    self.seenJobIds = {}
    self.seenMessageIds = {}
    self.unreadCount = 0
    self.syncTime = 0

    self.badgeOverlay = Overlay.new(Utils.getFilename("images/hudBadge.dds", TheContractor.dir), 0, 0, 0, 0)
    self.badgeOverlay:setColor(unpack(TCInboxHUD.BADGE_COLOR))

    return self
end

function TCInboxHUD:delete()
    self.badgeOverlay:delete()
end

-- Called from TheContractorJobs:registerJob whenever a genuinely new job
-- offer lands (not during initial-client-state replay). Only the sound is
-- event-driven — the badge count itself is recomputed on the next poll.
function TCInboxHUD:onJobOffered(job)
    if job.farmId ~= g_currentMission:getFarmId() then
        return
    end

    g_gui.guiSoundPlayer:playSample(GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
end

-- Same, for an inbox message (050, TheContractorInbox:applyMessagePosted).
function TCInboxHUD:onMessagePosted(message)
    if message.farmId ~= g_currentMission:getFarmId() then
        return
    end

    g_gui.guiSoundPlayer:playSample(GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
end

-- Marks every currently-offered job and message for farmId as seen — called when the
-- player opens the Inbox tab (see MenuContractor:onClickInbox/updateContent).
function TCInboxHUD:markAllSeen(farmId)
    local tc = g_currentMission.TheContractor
    for _, job in ipairs(tc.Jobs:getJobsByState(farmId, TheContractorJob.STATE.OFFERED)) do
        self.seenJobIds[job.id] = true
    end
    for _, message in ipairs(tc.Inbox:getMessages(farmId)) do
        self.seenMessageIds[message.id] = true
    end
    self:syncUnreadCount()
end

function TCInboxHUD:syncUnreadCount()
    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId == 0 then
        self.unreadCount = 0
        return
    end

    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Jobs == nil then
        self.unreadCount = 0
        return
    end

    local count = 0
    for _, job in ipairs(tc.Jobs:getJobsByState(farmId, TheContractorJob.STATE.OFFERED)) do
        if not self.seenJobIds[job.id] then
            count = count + 1
        end
    end
    if tc.Inbox ~= nil then
        for _, message in ipairs(tc.Inbox:getMessages(farmId)) do
            if not self.seenMessageIds[message.id] then
                count = count + 1
            end
        end
    end

    self.unreadCount = count
end

function TCInboxHUD:update(dt)
    self.syncTime = self.syncTime - dt
    if self.syncTime <= 0 then
        self.syncTime = TCInboxHUD.SYNC_INTERVAL_MS
        self:syncUnreadCount()
    end
end

-- The left edge of ADS's widened speedometer panel, or nil when ADS isn't
-- loaded, lacks the functions, or hasn't widened it for this vehicle (an ADS
-- excluded vehicle keeps the vanilla panel).
function TCInboxHUD.getADSExtendedLeftEdge(speedMeter)
    local env = TheContractorDrivers.getModEnv(TCInboxHUD.ADS_MOD_NAME)
    local adsHud = env ~= nil and env.ADS_Hud or nil
    if adsHud == nil or type(adsHud.getIsSpeedMeterExtended) ~= "function"
        or type(adsHud.getSpeedMeterLeftEdge) ~= "function" then
        return nil
    end
    if not adsHud.getIsSpeedMeterExtended(speedMeter.vehicle) then
        return nil
    end
    return adsHud.getSpeedMeterLeftEdge(speedMeter)
end

function TCInboxHUD:draw()
    if self.unreadCount <= 0 then
        return
    end

    -- Same guard vanilla's own AchievementMessage uses: don't draw world HUD
    -- over an open menu/dialog.
    if g_gui:getIsGuiVisible() then
        return
    end

    -- Respect the player hiding the HUD.
    local hud = g_currentMission.hud
    if hud == nil or hud.speedMeter == nil or not hud:getIsVisible() then
        return
    end

    local speedMeter = hud.speedMeter
    local width, height = speedMeter:scalePixelValuesToScreenVector(TCInboxHUD.BADGE_SIZE, TCInboxHUD.BADGE_SIZE)
    local x, y
    if hud.controlledVehicle ~= nil and speedMeter.vehicle ~= nil then
        local adsLeftEdge = TCInboxHUD.getADSExtendedLeftEdge(speedMeter)
        if adsLeftEdge ~= nil then
            local offsetX = speedMeter:scalePixelToScreenWidth(TCInboxHUD.ADS_OFFSET_X)
            x, y = adsLeftEdge + offsetX, speedMeter.speedBg.y
        else
            local offsetX = speedMeter:scalePixelToScreenWidth(TCInboxHUD.VEHICLE_OFFSET_X)
            x, y = speedMeter.speedBg.x + offsetX, speedMeter.speedBg.y
        end
    else
        local anchorX, anchorY = speedMeter:getPosition()
        x, y = anchorX - width, anchorY
    end

    self.badgeOverlay:setDimension(width, height)
    self.badgeOverlay:setPosition(x, y)
    self.badgeOverlay:render()

    local count = math.min(self.unreadCount, TCInboxHUD.MAX_SHOWN_COUNT)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
    setTextBold(true)
    setTextColor(1, 1, 1, 1)
    local textY = y + height * 0.5 + speedMeter:scalePixelToScreenHeight(TCInboxHUD.TEXT_OFFSET_Y)
    renderText(x + width * 0.5, textY, speedMeter:scalePixelToScreenHeight(TCInboxHUD.TEXT_SIZE),
        tostring(count))

    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_TOP)
    setTextBold(false)
end
