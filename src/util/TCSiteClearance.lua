-- Site clearance (156): the ground made where something is put down on a
-- field (075's fly-tipped pile, 101's broken-down machine, 127's machine
-- out of diesel), so it isn't standing hidden in a crop.
--
-- What's done depends on the crop (getTreatment):
--   none     nothing standing (bare, cultivated, stubble, sown and not up,
--            cut): nothing painted.
--   flatten  a crop growing: the patch and the run in from the edge are
--            run over, through vanilla's wheel destruction (the crop's
--            flattened state, as tyres leave it). Vanilla only flattens a
--            crop's taller states (isDestructibleByWheel), so a crop still
--            short is left as it is, and needs nothing.
--   cut      a crop ready to harvest (or forage): a machine's patch is
--            harvested (vanilla's cutFruitArea, so stubble, with no yield)
--            and its run in flattened. A fly-tipper's van doesn't harvest,
--            so a dump site is flattened instead.
--   refuse   a crop too tall to see anything in that can't be cut yet
--            (TALL_CROPS), or one that's there for good (PERMANENT_CROPS,
--            vines and trees): nothing goes on that field at all
--            (isUsableField, which each event's field pick asks).
--
-- Vanilla's foliage has no height to read (it's in the meshes), so the
-- tall and permanent crops are named. A crop from a mod that isn't named is
-- treated like wheat.
--
-- The patch is rounded (getOvalPieces): a superellipse built from strips the
-- ground map's resolution wide, a little ragged at the ends, sized so the
-- machine or pile is clear all round. The run in reuses the joyrider ruts'
-- geometry (TCJoyriderRuts). Painting is server only; the ground is synced
-- and saved by the engine, so there's no state here.

TCSiteClearance = {}

TCSiteClearance.TREATMENT = {
    NONE = "none",
    FLATTEN = "flatten",
    CUT = "cut",
    REFUSE = "refuse",
}

-- Fruit type names (vanilla's upper case).
TCSiteClearance.TALL_CROPS = {
    MAIZE = true,
    SUNFLOWER = true,
    SORGHUM = true,
    SUGARCANE = true,
}
TCSiteClearance.PERMANENT_CROPS = {
    GRAPE = true,
    OLIVE = true,
    POPLAR = true,
    BANANA = true,
    COFFEECHERRIES = true,
}

-- The patch: this much clear ground past the machine (or pile) all round
-- before the rounding, the rounding's exponent (2 an ellipse, higher
-- squarer), the strips' width and overlap, and how far past the shape a
-- strip's end may reach (never short of it, so the footprint's always
-- clear). Metres.
TCSiteClearance.MACHINE_MARGIN = 1
TCSiteClearance.MACHINE_EXPONENT = 3
TCSiteClearance.STRIP_WIDTH = 0.5
TCSiteClearance.STRIP_OVERLAP = 0.1
TCSiteClearance.EDGE_JITTER = 0.6
-- A fly-tipped pile's footprint across (TCDebris spreads it about this far),
-- rounded as an ellipse.
TCSiteClearance.PILE_SIZE = 4
TCSiteClearance.PILE_EXPONENT = 2

-- What's done for this crop in this growth state (see the header). Pure.
function TCSiteClearance.getTreatmentFor(fruitType, growthState)
    local T = TCSiteClearance.TREATMENT
    growthState = growthState or 0
    if fruitType == nil or growthState <= 0 then
        return T.NONE
    end
    local name = fruitType.name ~= nil and string.upper(fruitType.name) or ""
    if TCSiteClearance.PERMANENT_CROPS[name] then
        return T.REFUSE
    end
    if fruitType.getIsCut ~= nil and fruitType:getIsCut(growthState) then
        return T.NONE
    end
    if TCSiteClearance.getCutMode(fruitType, growthState) ~= nil then
        return T.CUT
    end
    if TCSiteClearance.TALL_CROPS[name] then
        return T.REFUSE
    end
    return T.FLATTEN
end

-- Whether cutFruitArea cuts this state: "harvest", "forage" (its
-- useMinForageState) or nil.
function TCSiteClearance.getCutMode(fruitType, growthState)
    if (fruitType.cutState or 0) == 0 then
        return nil
    end
    local maxState = fruitType.maxHarvestingGrowthState or 0
    local minHarvest = fruitType.minHarvestingGrowthState or 0
    local minForage = fruitType.minForageGrowthState or 0
    if minHarvest > 0 and growthState >= minHarvest and growthState <= maxState then
        return "harvest"
    end
    if minForage > 0 and growthState >= minForage and growthState <= maxState then
        return "forage"
    end
    return nil
end

-- The field's crop and its growth state, or nil.
local function getCrop(field)
    local fieldState = field ~= nil and field.getFieldState ~= nil and field:getFieldState() or nil
    if fieldState == nil or fieldState.fruitTypeIndex == nil or fieldState.fruitTypeIndex == FruitType.UNKNOWN then
        return nil, 0
    end
    local fruitType = g_fruitTypeManager.getFruitTypeByIndex ~= nil and
        g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex) or nil
    return fruitType, fieldState.growthState or 0
end

-- What's done on this field now.
function TCSiteClearance.getTreatment(field)
    local fruitType, growthState = getCrop(field)
    return TCSiteClearance.getTreatmentFor(fruitType, growthState)
end

-- Whether anything may be put down on this field now (not refused). The
-- crop grows, so an event checks again when it happens, not only at its roll.
function TCSiteClearance.isUsableField(field)
    return TCSiteClearance.getTreatment(field) ~= TCSiteClearance.TREATMENT.REFUSE
end

-- Geometry ---------------------------------------------------------------------

-- Semi-axes of a patch with the exponent's shape that has a rectangle
-- halfWidth by halfLength in its corners: (p/a)^n + (q/b)^n = 1 with both
-- terms equal.
function TCSiteClearance.getEnclosingAxes(halfWidth, halfLength, exponent)
    local factor = 2 ^ (1 / exponent)
    return halfWidth * factor, halfLength * factor
end

-- A rounded patch centred on (x, z), halfAcross by halfAlong the heading,
-- as paint pieces (TCJoyriderRuts.getTrackPieces's shape): strips along the
-- heading STRIP_WIDTH wide, each as long as the superellipse
-- |u/a|^n + |v/b|^n = 1 at its outer edge, plus up to EDGE_JITTER at
-- either end. random is for the tests.
function TCSiteClearance.getOvalPieces(x, z, heading, halfAcross, halfAlong, exponent, random)
    random = random or math.random
    local dx, dz = math.sin(heading), math.cos(heading)
    local nx, nz = dz, -dx
    local strip = TCSiteClearance.STRIP_WIDTH
    local overlap = TCSiteClearance.STRIP_OVERLAP
    local count = math.max(1, math.ceil(2 * halfAcross / strip))
    local pieces = {}
    for i = 1, count do
        local u0 = -halfAcross + (i - 1) * strip
        local u1 = math.min(halfAcross, u0 + strip)
        -- The strip's edge nearer the middle sets its length, so the shape
        -- is never short of the superellipse.
        local inner = math.min(math.abs(u0), math.abs(u1))
        if u0 < 0 and u1 > 0 then
            inner = 0
        end
        local ratio = math.min(1, inner / halfAcross)
        local half = halfAlong * (1 - ratio ^ exponent) ^ (1 / exponent)
        local back = half + random() * TCSiteClearance.EDGE_JITTER
        local front = half + random() * TCSiteClearance.EDGE_JITTER
        local stripWidth = (u1 - u0) + overlap
        local sx = x + nx * (u0 - overlap / 2) - dx * back
        local sz = z + nz * (u0 - overlap / 2) - dz * back
        table.insert(pieces, {
            sx, sz,
            sx + nx * stripWidth, sz + nz * stripWidth,
            sx + dx * (back + front), sz + dz * (back + front),
            heading,
        })
    end
    return pieces
end

-- The patch round a machine width by length, facing heading.
function TCSiteClearance.getMachinePatch(x, z, heading, width, length, random)
    local margin = TCSiteClearance.MACHINE_MARGIN
    local exponent = TCSiteClearance.MACHINE_EXPONENT
    local a, b = TCSiteClearance.getEnclosingAxes(width / 2 + margin, length / 2 + margin, exponent)
    return TCSiteClearance.getOvalPieces(x, z, heading, a, b, exponent, random)
end

-- The patch under a fly-tipped pile.
function TCSiteClearance.getPilePatch(x, z, heading, random)
    local radius = TCSiteClearance.PILE_SIZE / 2
    return TCSiteClearance.getOvalPieces(x, z, heading, radius, radius, TCSiteClearance.PILE_EXPONENT, random)
end

-- Painting (server) -------------------------------------------------------------

local function flattenPiece(piece)
    FSDensityMapUtil.updateWheelDestructionArea(piece[1], piece[2], piece[3], piece[4], piece[5], piece[6])
    FSDensityMapUtil.clearDecoArea(piece[1], piece[2], piece[3], piece[4], piece[5], piece[6])
end

local function cutPiece(piece, fruitType, cutMode)
    FSDensityMapUtil.cutFruitArea(fruitType.index, piece[1], piece[2], piece[3], piece[4], piece[5], piece[6],
        false, cutMode == "forage", nil, false, true)
    FSDensityMapUtil.clearDecoArea(piece[1], piece[2], piece[3], piece[4], piece[5], piece[6])
end

-- The run in's two tracks flattened (inside the field only), then the patch
-- flattened or cut. The treatment's worked out by the caller. Returns the
-- number of pieces painted.
local function paintSite(field, boundary, points, patch, treatment)
    local T = TCSiteClearance.TREATMENT
    if treatment ~= T.FLATTEN and treatment ~= T.CUT then
        return 0
    end
    local count = 0
    local tracks = TCJoyriderRuts.getWheelTracks(points)
    for _, track in ipairs({ tracks.left, tracks.right }) do
        for _, piece in ipairs(TCJoyriderRuts.getTrackPieces(track, boundary)) do
            flattenPiece(piece)
            count = count + 1
        end
    end
    local fruitType, growthState = getCrop(field)
    local cutMode = treatment == T.CUT and fruitType ~= nil and TCSiteClearance.getCutMode(fruitType, growthState)
        or nil
    for _, piece in ipairs(patch) do
        if cutMode ~= nil then
            cutPiece(piece, fruitType, cutMode)
        else
            flattenPiece(piece)
        end
        count = count + 1
    end
    return count
end

-- 075: plans a fly-tipping dump site on the field (TCJoyriderRuts.planDumpSite,
-- by its gate where it can) and clears it for the crop. Returns the site
-- (with its treatment), or nil if it can't (not the server, no boundary,
-- nowhere suitable). Refused fields are left out before this (isUsableField).
function TCSiteClearance.paintDumpSite(field, random)
    if not g_currentMission:getIsServer() or field == nil then
        return nil
    end
    local boundary = TCJoyriderRuts.getFieldBoundary(field)
    local gateX, gateZ = nil, nil
    if field.getTeleportPosition ~= nil then
        gateX, gateZ = field:getTeleportPosition()
    end
    local site = TCJoyriderRuts.planDumpSite(boundary, gateX, gateZ, random)
    if site == nil then
        return nil
    end

    -- A van doesn't harvest: a ripe crop's run over like a growing one.
    site.treatment = TCSiteClearance.getTreatment(field)
    if site.treatment == TCSiteClearance.TREATMENT.CUT then
        site.treatment = TCSiteClearance.TREATMENT.FLATTEN
    end
    local patch = TCSiteClearance.getPilePatch(site.x, site.z, site.heading, random)
    local pieceCount = paintSite(field, boundary, site.points, patch, site.treatment)
    TCLog.info("TheContractor: fly-tipping site on field %s: %.1f m in from the edge at (%.0f, %.0f), %s, %d pieces",
        tostring(field:getId()), site.depth, site.edgeX, site.edgeZ, site.treatment, pieceCount)
    return site
end

-- 101, 127: a machine's spot on the field (its centre x, z, facing heading,
-- its width and length, attachment and all): its run in from the edge and a
-- rounded patch round it, for the crop. Returns the number of pieces
-- painted, or nil if it can't (not the server, no boundary).
function TCSiteClearance.paintMachineSite(field, x, z, heading, width, length, random)
    if not g_currentMission:getIsServer() or field == nil then
        return nil
    end
    local boundary = TCJoyriderRuts.getFieldBoundary(field)
    if #boundary < 3 then
        return nil
    end
    local treatment = TCSiteClearance.getTreatment(field)
    local patch = TCSiteClearance.getMachinePatch(x, z, heading, width, length, random)
    local pieceCount = paintSite(field, boundary, TCJoyriderRuts.getRunInPoints(boundary, x, z, heading), patch,
        treatment)
    TCLog.info("TheContractor: machine spot on field %s at (%.0f, %.0f), %.1f m from the edge, %s, %d pieces",
        tostring(field:getId()), x, z, TCJoyriderRuts.getDistanceToBoundary(x, z, boundary), treatment, pieceCount)
    return pieceCount
end
