-- 171: TCConversation against a box that behaves as vanilla's
-- ConversationDialog does: onClickOption calls the callback, then clears it.
-- A line said from inside an answer (the server answers at once) must still
-- close the conversation when it's read.

local function setup()
    local world = stubs.install()
    local dialog = { isOpen = false, time = 0, inputDelay = 0 }
    ConversationDialog = {
        INSTANCE = dialog,
        show = function(name, text, options, duration, callback)
            dialog.text = text
            dialog.options = options
            dialog.callbackFunc = callback
            dialog.isOpen = true
        end,
        hide = function()
            dialog.isOpen = false
        end,
    }
    -- Vanilla's onClickOption, past its input delay.
    function dialog.click(canceled, optionIndex)
        if dialog.callbackFunc ~= nil then
            dialog.callbackFunc(canceled, optionIndex)
            dialog.callbackFunc = nil
        end
    end
    world:load("src/util/TCConversation.lua")
    TCConversation.active = nil
    TCConversation.answering = false
    return world, dialog
end

local SPEAKER = { name = "Farmer", getPosition = function() return 0, 0, 0 end }

test("a line said inside an answer closes when read", function()
    local _, dialog = setup()
    assertTrue(TCConversation.start(SPEAKER))
    TCConversation.say("hello", { "ask", "bye" }, function(index)
        assertEquals(index, 1)
        -- The server's answer, at once.
        TCConversation.say("no work", {}, function()
            TCConversation.finish()
        end)
    end)
    dialog.click(false, 1)
    -- Held to the next frame, not lost to the box clearing its callback.
    assertEquals(dialog.text, "hello")
    TCConversation.update(16)
    assertEquals(dialog.text, "no work")
    assertTrue(dialog.callbackFunc ~= nil)
    dialog.click(false, 0)
    assertEquals(TCConversation.isActive(), false)
    assertEquals(dialog.isOpen, false)
end)

test("a line said outside an answer shows at once", function()
    local _, dialog = setup()
    assertTrue(TCConversation.start(SPEAKER))
    TCConversation.say("hello", {}, nil)
    assertEquals(dialog.text, "hello")
    dialog.click(false, 0)
    assertEquals(TCConversation.isActive(), false)
end)

test("finishing inside an answer drops a held line", function()
    local _, dialog = setup()
    assertTrue(TCConversation.start(SPEAKER))
    TCConversation.say("hello", { "ask" }, function()
        TCConversation.say("late", {}, nil)
        TCConversation.finish()
    end)
    dialog.click(false, 1)
    TCConversation.update(16)
    assertEquals(dialog.text, "hello")
    assertEquals(TCConversation.isActive(), false)
end)

test("a held line's own answer can say another", function()
    local _, dialog = setup()
    assertTrue(TCConversation.start(SPEAKER))
    TCConversation.say("offer", { "yes", "no" }, function()
        TCConversation.say("thinking", {}, function()
            TCConversation.say("done", {}, function()
                TCConversation.finish()
            end)
        end)
    end)
    dialog.click(false, 1)
    TCConversation.update(16)
    dialog.click(false, 0)
    TCConversation.update(16)
    assertEquals(dialog.text, "done")
    dialog.click(false, 0)
    assertEquals(TCConversation.isActive(), false)
end)
