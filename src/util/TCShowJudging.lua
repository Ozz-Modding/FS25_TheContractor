-- The show's livestock judging (167): an animal's or a herd's score from
-- what's read of it, the judge's eye, farmers' rolled entries and the
-- placings. Pure: everything comes in as arguments (a random function
-- where there's a roll), so it's tested outside the game
-- (tests/test_showLivestock.lua).
--
-- A score is out of 100: each thing judged is worth 0 to 1, weighted
-- (WEIGHTS), and anything that can't be read is left out and the rest
-- weighted up. Then:
--   the breeding bonus, in the bands where a judge counts it
--     (TCShowClasses.BREEDING_BANDS: carrying young or in milk for a grown
--     female, carrying young for a young one; RL's animals only);
--   the judge's eye, a small roll each way (EYE_POINTS), so the best animal
--     usually wins but not always. Server-only: never shown or streamed.
-- What a player sees of why they placed is the stats (getStats' order is
-- the weights'), never the eye or a farmer's numbers.

TCShowJudging = {}

-- What's judged, by model, heaviest first (the judge's card's order).
TCShowJudging.WEIGHTS = {
    -- Without RealisticLivestock there's little to judge: the animal's
    -- health and age, and how well its husbandry produces.
    vanilla = {
        { key = "health", weight = 0.6 },
        { key = "age", weight = 0.25 },
        { key = "productivity", weight = 0.15 },
    },
    -- With it: genetics first (quality and health), weight against the
    -- breed's target, health, productivity for the type's product (RL has it
    -- only for milk, wool and egg animals), age.
    rl = {
        { key = "quality", weight = 0.25 },
        { key = "geneticHealth", weight = 0.2 },
        { key = "weight", weight = 0.2 },
        { key = "health", weight = 0.15 },
        { key = "geneticProductivity", weight = 0.1 },
        { key = "age", weight = 0.1 },
    },
    -- Best Kept Herd, from the husbandry.
    herd = {
        { key = "productivity", weight = 0.25 },
        { key = "foodLevel", weight = 0.2 },
        { key = "foodVariety", weight = 0.15 },
        { key = "straw", weight = 0.15 },
        { key = "cleanliness", weight = 0.15 },
        { key = "water", weight = 0.1 },
    },
}

-- Points added for a pregnancy or lactation that counts (see header).
TCShowJudging.BREEDING_BONUS = { adult = 4, young = 2 }
-- The judge's eye: up to this many points either way.
TCShowJudging.EYE_POINTS = 6
-- How far an RL animal's weight may be off its target, as a share of the
-- target, before it scores nothing for weight. Heavier isn't better.
TCShowJudging.WEIGHT_TOLERANCE = 0.3
-- RL's genetics: 1.0 is average; GENETICS_LOW scores nothing, and a
-- GENETICS_RANGE above it scores full marks.
TCShowJudging.GENETICS_LOW = 0.5
TCShowJudging.GENETICS_RANGE = 1.0

-- Farmers' entries: a roll from `min` to `min + spread`, by the model the
-- class is judged on (a vanilla animal scores high easily), moved by the
-- farmer's hidden stockman trait (-1 to 1) up to STOCKMAN_POINTS.
TCShowJudging.FARMER_ROLLS = {
    vanilla = { min = 62, spread = 30 },
    rl = { min = 42, spread = 36 },
    herd = { min = 45, spread = 40 },
}
TCShowJudging.STOCKMAN_POINTS = 8

-- Placings given in a class: 1st, 2nd, 3rd and highly commended.
TCShowJudging.PLACINGS = 4

local function clamp01(value)
    return math.max(0, math.min(1, value))
end

function TCShowJudging.geneticsFactor(value)
    if value == nil then
        return nil
    end
    return clamp01((value - TCShowJudging.GENETICS_LOW) / TCShowJudging.GENETICS_RANGE)
end

-- 1 on the target, 0 at WEIGHT_TOLERANCE off it either way.
function TCShowJudging.weightFactor(weight, target)
    if weight == nil or target == nil or target <= 0 then
        return nil
    end
    return clamp01(1 - math.abs(weight - target) / (TCShowJudging.WEIGHT_TOLERANCE * target))
end

-- Weighted total out of 100 of the factors present (0-1 each), and the
-- stats in weight order: { key, value (shown), target (shown, or nil) }.
local function total(weights, factors, shown)
    local sum, weightSum = 0, 0
    local stats = {}
    for _, item in ipairs(weights) do
        local factor = factors[item.key]
        if factor ~= nil then
            sum = sum + item.weight * factor
            weightSum = weightSum + item.weight
            local entry = shown[item.key] or {}
            table.insert(stats, { key = item.key, value = entry.value, target = entry.target })
        end
    end
    if weightSum <= 0 then
        return 0, stats
    end
    return 100 * sum / weightSum, stats
end

-- Whether a female's pregnancy or lactation (RL's) counts in a class (its
-- band), and the points it adds.
function TCShowJudging.getBreedingBonus(class, animal)
    if class == nil or class.band == nil or animal == nil or animal.gender ~= "female" then
        return 0
    end
    local kind = TCShowClasses.BREEDING_BANDS[class.band.key]
    if kind == "adult" and (animal.isPregnant or animal.isLactating) then
        return TCShowJudging.BREEDING_BONUS.adult
    elseif kind == "young" and animal.isPregnant then
        return TCShowJudging.BREEDING_BONUS.young
    end
    return 0
end

-- An animal's score (before the judge's eye), in its class: read is what
-- TCShowAnimals.readCluster gives (age, health 0-100, and RL's `animal`);
-- productivity is its husbandry's (0-1, or nil). Returns the score, the
-- model ("rl" or "vanilla") and the stats.
function TCShowJudging.scoreAnimal(class, read, productivity)
    local animal = read.animal
    local band = class ~= nil and class.band or nil
    local factors = {
        health = read.health ~= nil and clamp01(read.health / 100) or nil,
        age = TCShowClasses.getAgeFactor(band, read.age),
    }
    local shown = {
        health = { value = read.health },
        age = { value = read.age },
    }
    local model = "vanilla"
    if animal ~= nil then
        model = "rl"
        local genetics = animal.genetics or {}
        factors.quality = TCShowJudging.geneticsFactor(genetics.quality)
        factors.geneticHealth = TCShowJudging.geneticsFactor(genetics.health)
        factors.geneticProductivity = TCShowJudging.geneticsFactor(genetics.productivity)
        factors.weight = TCShowJudging.weightFactor(animal.weight, animal.targetWeight)
        shown.quality = { value = genetics.quality }
        shown.geneticHealth = { value = genetics.health }
        shown.geneticProductivity = { value = genetics.productivity }
        shown.weight = { value = animal.weight, target = animal.targetWeight }
    else
        factors.productivity = productivity ~= nil and clamp01(productivity) or nil
        shown.productivity = { value = productivity ~= nil and clamp01(productivity) * 100 or nil }
    end
    local score, stats = total(TCShowJudging.WEIGHTS[model], factors, shown)
    local bonus = TCShowJudging.getBreedingBonus(class, animal)
    if bonus > 0 then
        score = score + bonus
        table.insert(stats, { key = "breeding", value = 1 })
    end
    return math.min(100, score), model, stats
end

-- A herd's score from its husbandry's readings (TCShowAnimals.readHerd:
-- each 0-1 or nil), and the stats (shown as percentages).
function TCShowJudging.scoreHerd(readings)
    local factors, shown = {}, {}
    for _, item in ipairs(TCShowJudging.WEIGHTS.herd) do
        local value = readings ~= nil and readings[item.key] or nil
        if value ~= nil then
            factors[item.key] = clamp01(value)
            shown[item.key] = { value = clamp01(value) * 100 }
        end
    end
    return total(TCShowJudging.WEIGHTS.herd, factors, shown)
end

-- The judge's eye for one entry (server).
function TCShowJudging.rollEye(random)
    return (random() * 2 - 1) * TCShowJudging.EYE_POINTS
end

-- A farmer's hidden stockman trait, -1 to 1 (server, once a farmer).
function TCShowJudging.rollStockman(random)
    return random() * 2 - 1
end

-- A farmer's entry's score in a class judged on a model (server).
function TCShowJudging.rollFarmerScore(model, stockman, random)
    local roll = TCShowJudging.FARMER_ROLLS[model] or TCShowJudging.FARMER_ROLLS.vanilla
    local score = roll.min + random() * roll.spread + (stockman or 0) * TCShowJudging.STOCKMAN_POINTS
    return math.max(0, math.min(100, score))
end

-- A class's competitors ({ score, ... }) best first, ties to the earlier
-- one, each given `placing` (1 to PLACINGS, nil past that). Returns a new
-- list; the competitors are the same tables.
function TCShowJudging.rank(competitors)
    local ranked = {}
    for i, competitor in ipairs(competitors) do
        ranked[i] = competitor
        competitor.rankOrder = i
    end
    table.sort(ranked, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.rankOrder < b.rankOrder
    end)
    for i, competitor in ipairs(ranked) do
        competitor.placing = i <= TCShowJudging.PLACINGS and i or nil
        competitor.rankOrder = nil
    end
    return ranked
end
