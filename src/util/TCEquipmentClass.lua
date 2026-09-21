-- Equipment size/capability classification (009). Only tractors carry a
-- vanilla small/medium/large split, and it's expressed as a suffix on the
-- store category id (TRACTORSS/TRACTORSM/TRACTORSL), not a numeric stat.
-- Confirmed by FS25_RedTape's tractor demo scheme (SchemeList.lua's
-- rt_scheme_tractor_demo), which already relies on exactly these three
-- category ids to pick a tractor of a given size for its demo events — so
-- we reuse the game's own bucketing instead of inventing power/mass
-- thresholds (see 009's Outcome for why the original threshold plan was
-- dropped). No other vehicle type has an equivalent S/M/L split, so
-- everything else is left as a single category (e.g. "COMBINES") rather
-- than force-fit into small/medium/large.

TCEquipmentClass = {}

TCEquipmentClass.TRACTOR_SIZE_CATEGORIES = {
    TRACTORSS = "small",
    TRACTORSM = "medium",
    TRACTORSL = "large",
}

-- storeItem.categoryName is categoryNames[1], the item's primary category
-- (shop/StoreManager.lua, StoreItemUtil.loadSpecsFromXML) — fine here since
-- vanilla tractors only ever carry one of the three size categories as
-- their primary category.
local function getStoreItem(vehicle)
    if vehicle == nil or vehicle.configFileName == nil then
        return nil
    end

    return g_storeManager:getItemByXMLFilename(vehicle.configFileName)
end

-- Returns "small" | "medium" | "large" for a tractor, or nil for anything
-- else — implements, harvesters, etc. don't carry a size-tiered store
-- category in vanilla (see file header). Callers that need to bucket
-- non-tractor equipment should match on getCategory() instead.
function TCEquipmentClass.getSizeTier(vehicle)
    local storeItem = getStoreItem(vehicle)
    if storeItem == nil or storeItem.categoryName == nil then
        return nil
    end

    return TCEquipmentClass.TRACTOR_SIZE_CATEGORIES[storeItem.categoryName]
end

-- Returns the vehicle's primary store category id (e.g. "COMBINES",
-- "TRACTORSM", "PLOWS"), or nil if it has no resolvable store item. This is
-- the single bucket non-tractor equipment is classified by, since it has no
-- size tier of its own.
function TCEquipmentClass.getCategory(vehicle)
    local storeItem = getStoreItem(vehicle)
    if storeItem == nil then
        return nil
    end

    return storeItem.categoryName
end
