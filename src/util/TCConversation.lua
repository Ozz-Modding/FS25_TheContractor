-- Talking to one of the people we put in the world (171; the base for
-- 130's conversations in a farmer's yard). Vanilla's own NPC chat:
-- ConversationDialog (the speaker's name and line, and answers to pick,
-- mouse or gamepad) with, in third person, vanilla's over-the-shoulder
-- conversation camera on the speaker's head (PlayerCamera:
-- setIsInConversation, Player:updateWhileInConversation, as vanilla's NPC
-- does). Never a YesNo or Option dialog.
--
-- Local to this machine: what's said is the caller's (its lines and what
-- it asks the server). One conversation at a time:
--
--   TCConversation.start(speaker)  speaker = { name, getGraphics() (its
--     HumanGraphicsComponent, or nil), getPosition() -> x, y, z }
--   TCConversation.say(text, options, onAnswer)  a line, with answers (a
--     list of texts, or none). onAnswer(index): the answer picked, 0 for a
--     line without answers read and closed, nil if backed out of.
--   TCConversation.finish()  the box closed and the camera back.
--
-- A line is said again into the same box while it's open (vanilla's
-- ConversationDialog.show updates it), so a conversation is one box from
-- start to finish. update(dt) every frame keeps the camera on the speaker.
--
-- A line said from inside an answer's callback is held to the next frame
-- (update): vanilla's box clears its callback after calling it
-- (ConversationDialog:onClickOption), so a line shown there would lose its
-- own and the box could never be closed. Vanilla's NPC always answers
-- through an event, so never meets this; our server answers at once.

TCConversation = {}

-- The conversation on now: { speaker, session, camera (the conversation
-- camera's on) }, or nil.
TCConversation.active = nil
TCConversation.session = 0
-- Whether an answer's callback is running (see the header).
TCConversation.answering = false

-- Whether this machine can hold a conversation (vanilla's box exists).
function TCConversation.isAvailable()
    return ConversationDialog ~= nil and ConversationDialog.INSTANCE ~= nil and ConversationDialog.show ~= nil
end

function TCConversation.isActive()
    return TCConversation.active ~= nil
end

-- The conversation's number: a reply that comes after it's over (or for
-- another one) checks it.
function TCConversation.getSession()
    return TCConversation.active ~= nil and TCConversation.active.session or nil
end

local function getCamera()
    local player = g_localPlayer
    local camera = player ~= nil and player.camera or nil
    if camera == nil or camera.setIsInConversation == nil then
        return nil, nil
    end
    return player, camera
end

-- Starts a conversation with speaker. Returns whether it started (not if
-- one's on, or there's no box).
function TCConversation.start(speaker)
    if TCConversation.active ~= nil or not TCConversation.isAvailable() or speaker == nil then
        return false
    end
    TCConversation.session = TCConversation.session + 1
    TCConversation.active = { speaker = speaker, session = TCConversation.session, camera = false }
    -- Third person only: in first person vanilla keeps its own camera.
    local player, camera = getCamera()
    if camera ~= nil and not camera.isFirstPerson and player.graphicsComponent ~= nil and
            player.graphicsComponent.rightShoulderCameraNode ~= nil then
        camera:setIsInConversation(true)
        if camera.isInConversation then
            TCConversation.active.camera = true
            if camera.setTargetOverrideFromNode ~= nil then
                camera:setTargetOverrideFromNode(player.graphicsComponent.rightShoulderCameraNode, 250)
            end
        end
    end
    return true
end

local function show(active, text, options, onAnswer)
    local session = active.session
    local dialog = ConversationDialog.INSTANCE
    if dialog ~= nil and dialog.isOpen and dialog.time ~= nil then
        -- The box stays open between lines: the same input delay as a
        -- fresh one, so the press that answered can't skip the next line.
        dialog.inputDelay = dialog.time + 250
    end
    ConversationDialog.show(active.speaker.name or "", text or "", options, nil, function(canceled, optionIndex)
        if TCConversation.getSession() ~= session then
            return
        end
        TCConversation.answering = true
        if onAnswer ~= nil then
            onAnswer(not canceled and optionIndex or nil)
        else
            TCConversation.finish()
        end
        TCConversation.answering = false
    end)
end

-- Says a line (see the header). Nothing without a conversation on.
function TCConversation.say(text, options, onAnswer)
    local active = TCConversation.active
    if active == nil then
        return
    end
    options = options or {}
    if TCConversation.answering then
        active.queued = { text = text, options = options, onAnswer = onAnswer }
        return
    end
    show(active, text, options, onAnswer)
end

-- Ends the conversation: the box closed, the camera back.
function TCConversation.finish()
    local active = TCConversation.active
    if active == nil then
        return
    end
    TCConversation.active = nil
    if ConversationDialog ~= nil and ConversationDialog.hide ~= nil and ConversationDialog.INSTANCE ~= nil and
            ConversationDialog.INSTANCE.isOpen then
        ConversationDialog.hide()
    end
    if active.camera then
        local _, camera = getCamera()
        if camera ~= nil then
            camera:setIsInConversation(false)
            if camera.clearTargetOverride ~= nil then
                camera:clearTargetOverride()
            end
        end
    end
end

-- Every frame on a machine with a client: the camera kept on the speaker's
-- head, as vanilla's NPC keeps it (Player:updateWhileInConversation). A
-- speaker whose model's gone (freed out of range) ends the camera's part.
function TCConversation.update(dt)
    local active = TCConversation.active
    -- A line held from an answer's callback (see the header).
    if active ~= nil and active.queued ~= nil then
        local queued = active.queued
        active.queued = nil
        show(active, queued.text, queued.options, queued.onAnswer)
    end
    if active == nil or not active.camera then
        return
    end
    local player, camera = getCamera()
    local graphics = active.speaker.getGraphics ~= nil and active.speaker.getGraphics() or nil
    local model = graphics ~= nil and graphics.model or nil
    if player == nil or not camera.isInConversation or model == nil or model.thirdPersonHeadNode == nil or
            player.updateWhileInConversation == nil then
        if camera ~= nil and camera.isInConversation then
            camera:setIsInConversation(false)
            if camera.clearTargetOverride ~= nil then
                camera:clearTargetOverride()
            end
        end
        active.camera = false
        return
    end
    local speaker = active.speaker
    player:updateWhileInConversation(dt, {
        playerGraphics = graphics,
        getPosition = function()
            return speaker.getPosition()
        end,
    })
end

-- deleteMap: anything still open goes.
function TCConversation.reset()
    TCConversation.finish()
    TCConversation.answering = false
end
