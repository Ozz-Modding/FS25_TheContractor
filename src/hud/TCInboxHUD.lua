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

-- Normalised screen position (0-1, origin bottom-left, matching RTSaltSchemeHUD).
-- Bottom-left, stacked just above the minimap (which occupies roughly
-- 0-0.24 from the bottom at the default minimap size) rather than the
-- top-left corner — keeps it near where the player's eyes already are
-- (minimap/speedometer) without overlapping either.
TCInboxHUD.POS_X = 0.02
TCInboxHUD.POS_Y = 0.27
TCInboxHUD.ICON_HEIGHT = 0.035
TCInboxHUD.TEXT_SIZE = 0.02
TCInboxHUD.SYNC_INTERVAL_MS = 1000

function TCInboxHUD.new()
    local self = {}
    setmetatable(self, TCInboxHUD_mt)

    self.seenJobIds = {}
    self.seenMessageIds = {}
    self.unreadCount = 0
    self.syncTime = 0

    local iconWidth = TCInboxHUD.ICON_HEIGHT / g_screenAspectRatio
    self.iconOverlay = Overlay.new(Utils.getFilename("images/menuIcon.dds", TheContractor.dir),
        TCInboxHUD.POS_X, TCInboxHUD.POS_Y, iconWidth, TCInboxHUD.ICON_HEIGHT)

    return self
end

function TCInboxHUD:delete()
    self.iconOverlay:delete()
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

function TCInboxHUD:draw()
    if self.unreadCount <= 0 then
        return
    end

    -- Same guard vanilla's own AchievementMessage uses: don't draw world HUD
    -- over an open menu/dialog.
    if g_gui:getIsGuiVisible() then
        return
    end

    self.iconOverlay:render()

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
    setTextBold(true)
    setTextColor(1, 0.35, 0.35, 1)
    renderText(TCInboxHUD.POS_X + self.iconOverlay.width + 0.01, TCInboxHUD.POS_Y + self.iconOverlay.height * 0.5,
        TCInboxHUD.TEXT_SIZE, tostring(self.unreadCount))

    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_TOP)
    setTextBold(false)
end
