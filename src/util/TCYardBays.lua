-- Yard machine bays (183): where a farmer's machine or trailer goes in their
-- yard, ahead of the yard's standing spots (FieldBreakdowns.pickYardSpot,
-- which 116's favours, 123's yard breakdowns and 126's load to sell all go
-- through). The bays themselves are PlaceableTCYardBay; a yard's are found
-- by TheContractorYards.findBays.
--
-- A bay is free when nothing's in it (TCParking.isAreaClear over the whole
-- bay) and nothing's claimed it: a machine on its way (100's queue,
-- RepairContracts.arrivals), a load to sell whose trailer isn't out yet
-- (126, its spot is the job's) or a yard bales job's drop area and
-- telehandler (124). Two offers can pick a spot before either machine is
-- out, so the clear check alone isn't enough. A retry's own claim keeps its
-- own bay out, which is what a retry wants (its spot was blocked).
--
-- Among the free bays a machine fits in (with RepairContracts' CLEARANCE,
-- which the arrival checks too), the smallest, so a trailer leaves the big
-- bays for a machine with its attachment; a random one of that size. It
-- stands in the bay's middle facing the bay's way. The bay is trusted: the
-- player put it there, so there are no ground checks.
--
-- Server only (the pick, the queue and the jobs are the server's).

TCYardBays = {}

-- Bays within this many square metres of each other are the same size.
TCYardBays.SIZE_TOLERANCE = 0.5

-- Rectangles ---------------------------------------------------------------

-- An area (PlaceableTCParkingSlot.getArea's shape) centred on x, z, facing
-- rotY, width across and length along.
function TCYardBays.makeArea(x, z, rotY, width, length)
    local vX, vZ = math.sin(rotY or 0), math.cos(rotY or 0)
    local uX, uZ = vZ, -vX
    return {
        x = x - (uX * width + vX * length) * 0.5,
        z = z - (uZ * width + vZ * length) * 0.5,
        uX = uX,
        uZ = uZ,
        vX = vX,
        vZ = vZ,
        width = width,
        length = length,
    }
end

-- The area's middle and the way it faces (from its start edge towards its
-- height node): x, z, rotY.
function TCYardBays.getPose(area)
    local x = area.x + (area.uX * area.width + area.vX * area.length) * 0.5
    local z = area.z + (area.uZ * area.width + area.vZ * area.length) * 0.5
    return x, z, MathUtil.getYRotationFromDirection(area.vX, area.vZ)
end

local function getCorners(area)
    local corners = {}
    for _, at in ipairs({ { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }) do
        local u, v = area.width * at[1], area.length * at[2]
        table.insert(corners, { area.x + area.uX * u + area.vX * v, area.z + area.uZ * u + area.vZ * v })
    end
    return corners
end

-- Edges this close (metres) only touch.
TCYardBays.TOUCH_TOLERANCE = 0.01

local function isSeparated(axisX, axisZ, cornersA, cornersB)
    local minA, maxA, minB, maxB = math.huge, -math.huge, math.huge, -math.huge
    for _, corner in ipairs(cornersA) do
        local p = corner[1] * axisX + corner[2] * axisZ
        minA, maxA = math.min(minA, p), math.max(maxA, p)
    end
    for _, corner in ipairs(cornersB) do
        local p = corner[1] * axisX + corner[2] * axisZ
        minB, maxB = math.min(minB, p), math.max(maxB, p)
    end
    local tolerance = TCYardBays.TOUCH_TOLERANCE
    return maxA <= minB + tolerance or maxB <= minA + tolerance
end

-- Whether two areas overlap (a zero-sized one is a point). Touching edges
-- don't count, so bays placed flush don't take each other.
function TCYardBays.overlaps(a, b)
    local cornersA, cornersB = getCorners(a), getCorners(b)
    for _, axis in ipairs({ { a.uX, a.uZ }, { a.vX, a.vZ }, { b.uX, b.uZ }, { b.vX, b.vZ } }) do
        if isSeparated(axis[1], axis[2], cornersA, cornersB) then
            return false
        end
    end
    return true
end

-- Whether any of the areas overlaps area.
function TCYardBays.overlapsAny(areas, area)
    for _, other in ipairs(areas) do
        if TCYardBays.overlaps(other, area) then
            return true
        end
    end
    return false
end

-- Claims and the pick --------------------------------------------------------

-- Server: every spot something's on its way to or has a job on, as areas
-- (a point is a zero-sized one).
function TCYardBays.getClaims()
    local claims = {}
    local tc = g_currentMission.TheContractor
    if tc == nil then
        return claims
    end
    local repairContracts = tc.RepairContracts
    for _, entry in ipairs(repairContracts ~= nil and repairContracts.arrivals or {}) do
        if entry.x ~= nil and entry.z ~= nil then
            table.insert(claims, TCYardBays.makeArea(entry.x, entry.z, 0, 0, 0))
        end
    end
    local jobs = tc.Jobs
    for _, farmJobs in pairs(jobs ~= nil and jobs.jobsByFarm or {}) do
        for _, job in pairs(farmJobs) do
            if not job:isTerminal() then
                local haul = job.yardHaul
                if haul ~= nil and haul.x ~= nil and (haul.trailerVehicleId or 0) == 0 then
                    table.insert(claims, TCYardBays.makeArea(haul.x, haul.z, 0, 0, 0))
                end
                local yard = job.yardDelivery
                if yard ~= nil and yard.x ~= nil then
                    table.insert(claims, TCYardBays.makeArea(yard.x, yard.z, yard.rotY, yard.width or 0,
                        yard.length or 0))
                    if yard.kitX ~= nil then
                        table.insert(claims, TCYardBays.makeArea(yard.kitX, yard.kitZ, 0, 0, 0))
                    end
                end
            end
        end
    end
    return claims
end

-- Whether a model ({ width, length }) fits in the area with clearance.
function TCYardBays.fits(area, model, clearance)
    clearance = clearance or 0
    return model.width + clearance <= area.width + 0.001 and model.length + clearance <= area.length + 0.001
end

-- Of the areas, the ones the model fits in that isFree(area) says are
-- free, the smallest; a random one of those: x, z, rotY, area, or nil.
-- Pure apart from isFree and random, for the tests.
function TCYardBays.pick(areas, model, random, isFree, clearance)
    local fitting = {}
    for _, area in ipairs(areas) do
        if TCYardBays.fits(area, model, clearance) and isFree(area) then
            table.insert(fitting, area)
        end
    end
    if #fitting == 0 then
        return nil
    end
    local smallest = math.huge
    for _, area in ipairs(fitting) do
        smallest = math.min(smallest, area.width * area.length)
    end
    local choices = {}
    for _, area in ipairs(fitting) do
        if area.width * area.length <= smallest + TCYardBays.SIZE_TOLERANCE then
            table.insert(choices, area)
        end
    end
    local area = choices[math.min(#choices, math.floor(random() * #choices) + 1)]
    local x, z, rotY = TCYardBays.getPose(area)
    return x, z, rotY, area
end

local function getMapPlaceables()
    local placeableSystem = g_currentMission.placeableSystem
    return placeableSystem ~= nil and placeableSystem.placeables or {}
end

-- The live map's bays on the farmland, as areas.
function TCYardBays.getYardBays(farmlandId)
    return TheContractorYards.findBays(getMapPlaceables(), farmlandId)
end

-- Server: a free bay on the farmland's yard for the model (with its
-- attachment, FarmerFleet.getFootprint's): x, z, rotY, or nil.
function TCYardBays.pickOnYard(farmlandId, model, random)
    local areas = TCYardBays.getYardBays(farmlandId)
    if #areas == 0 then
        return nil
    end
    local claims = TCYardBays.getClaims()
    local x, z, rotY, area = TCYardBays.pick(areas, model, random, function(bay)
        if TCYardBays.overlapsAny(claims, bay) then
            return false
        end
        local bayX, bayZ, bayRotY = TCYardBays.getPose(bay)
        return TCParking.isAreaClear(bayX, bayZ, bayRotY, bay.width, bay.length, model.height)
    end, TheContractorRepairContracts.CLEARANCE)
    if x ~= nil then
        TCLog.info("TheContractor: yard %d: a %.1f x %.1f m bay for a %.1f x %.1f m machine at %.0f, %.0f",
            farmlandId, area.width, area.length, model.width, model.length, x, z)
    else
        TCLog.info("TheContractor: yard %d: none of its %d bay(s) free for a %.1f x %.1f m machine", farmlandId,
            #areas, model.width, model.length)
    end
    return x, z, rotY
end
