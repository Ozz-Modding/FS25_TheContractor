-- FS25_EconomyScale support. That mod scales every vanilla price by one
-- factor (a historical year, a custom multiplier and a currency rate), in
-- getters. Our own prices are built from constants its hooks never see, so
-- we apply its factor ourselves, live, at the same few places everything
-- already passes through: TheContractorJob:getPrice (job prices, stored
-- without it until paid), TheContractorStaff.scalePay (salaries),
-- TheContractorSettings:scaleCost (fixed costs), plus the loose constants
-- (company creation, advertising, bonuses) through TCEconomyScale.scale.
-- What's already happened (invoices, payments, the logbook, Finances
-- figures) keeps the amount it had.
--
-- Anything read from a vanilla price getter (getSellPrice, getPrice,
-- getCostPerLiter, ...) is already scaled by EconomyScale and must not go
-- through here as well: insurance (fleet value), stolen vehicle values,
-- job diesel and repair prices.
--
-- EconomyScale's loadMap sets g_currentMission.EconomyScale, and its
-- factor is synced to every client, so reading it live gives every machine
-- the same answer. Without the mod the factor is 1.

TCEconomyScale = {}

function TCEconomyScale.getFactor()
    local economyScale = g_currentMission ~= nil and g_currentMission.EconomyScale or nil
    local factor = economyScale ~= nil and economyScale.factor or nil
    if type(factor) ~= "number" or factor ~= factor or factor <= 0 then
        return 1
    end
    return factor
end

-- A fixed amount at EconomyScale's price level, to the nearest whole unit.
function TCEconomyScale.scale(amount)
    return math.floor(amount * TCEconomyScale.getFactor() + 0.5)
end
