-- TheContractorNotices (038, 063): publishing, removing and saving.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world:load("src/business/Notices.lua")
    return world, TheContractorNotices.new()
end

test("published notices are listed newest first, per farm", function()
    local _, notices = setup()
    notices:publish(1, "first")
    notices:publish(2, "other farm")
    notices:publish(1, "second")

    local farmNotices = notices:getNotices(1)
    assertEquals(#farmNotices, 2, "count")
    assertEquals(farmNotices[1].text, "second", "newest first")
end)

test("a removed notice is gone, and removing it twice is harmless", function()
    local _, notices = setup()
    local id = notices:publish(1, "notice")
    notices:remove(id)
    notices:remove(id)
    assertEquals(#notices:getNotices(1), 0, "count")
end)

test("save and load round-trip, leaving transient notices out", function()
    local _, notices = setup()
    notices:publish(1, "kept")
    notices:publish(1, "transient", nil, true)

    local xmlFile = {}
    notices:saveToXmlFile(xmlFile)

    local loaded = TheContractorNotices.new()
    loaded:loadFromXMLFile(xmlFile)
    local farmNotices = loaded:getNotices(1)
    assertEquals(#farmNotices, 1, "count")
    assertEquals(farmNotices[1].text, "kept", "text")
    assertEquals(loaded.nextNoticeId, 3, "ids carry on after the transient one")
end)
