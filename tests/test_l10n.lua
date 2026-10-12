-- languages/l10n_en.xml: each key once. The game quietly keeps one of two
-- texts with the same name, so a reused key shows the wrong text (or
-- breaks a string.format) with no error at load.

test("no text key is defined twice", function()
    local file = io.open("languages/l10n_en.xml", "r")
    assert(file ~= nil, "can't open languages/l10n_en.xml")
    local content = file:read("*a")
    file:close()

    local seen, duplicates = {}, {}
    for name in content:gmatch("<text%s+name=\"([^\"]+)\"") do
        if seen[name] then
            table.insert(duplicates, name)
        end
        seen[name] = true
    end
    assertEquals(table.concat(duplicates, ", "), "")
end)
