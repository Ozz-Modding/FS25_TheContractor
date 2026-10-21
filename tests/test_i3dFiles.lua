-- Every file an i3d of ours points at (other than the game's own $data)
-- has to be in the mod, relative to the i3d. GIANTS Editor has rewritten
-- logoSign.i3d's logo texture to a path from its own working folder on
-- save, which only shows up in game as "Missing dds file".

local function listI3ds()
    local isWindows = package.config:sub(1, 1) == "\\"
    local command = isWindows and "dir /s /b i3d" or "find i3d"
    local pipe = io.popen(command)
    local files = {}
    for line in pipe:lines() do
        local path = line:gsub("\\", "/"):match("(i3d/.+%.i3d)$")
        if path ~= nil then
            table.insert(files, path)
        end
    end
    pipe:close()
    return files
end

local function exists(path)
    local file = io.open(path, "rb")
    if file == nil then
        return false
    end
    file:close()
    return true
end

-- "i3d/debris/" + "../../images/x.dds" -> "images/x.dds"
local function resolve(folder, relative)
    local parts = {}
    for part in (folder .. relative):gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." then
            table.insert(parts, part)
        end
    end
    return table.concat(parts, "/")
end

test("every file our i3ds use outside $data is in the mod", function()
    local i3ds = listI3ds()
    assertTrue(#i3ds > 0)
    for _, i3d in ipairs(i3ds) do
        local file = io.open(i3d, "rb")
        local text = file:read("*a")
        file:close()
        local folder = i3d:match("^(.*/)")
        for filename in text:gmatch('<File [^>]-filename="([^"]+)"') do
            if filename:sub(1, 5) ~= "$data" then
                local path = resolve(folder, filename)
                if not exists(path) then
                    error(string.format("%s points at %q, which isn't in the mod (%s)", i3d, filename, path))
                end
            end
        end
    end
end)
