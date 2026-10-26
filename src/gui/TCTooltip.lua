-- A mouse-over tooltip for elements that can't take focus (the Overview's
-- company logo first), modelled on FS25_AdvancedDamageSystem's
-- ADS_VehicleSummaryTooltip: one popup in the page's XML (a tc_tooltipBox
-- holding a tc_tooltipSurface, tc_tooltipTitle, tc_tooltipDivider and
-- tc_tooltipText), hover checked every frame against the targets' screen
-- rectangles, shown after a short delay and sized to its text.
--
-- Mouse only, so it can only ever add to what's on screen: anything a
-- gamepad player needs must be reachable some other way too.

TCTooltip = {}
local TCTooltip_mt = Class(TCTooltip)

TCTooltip.DELAY_MS = 400
TCTooltip.WIDTH_PX = 640
-- Room left by the engine's text width against our own measuring.
TCTooltip.WRAP_SLACK = 0.97

-- elements: { box, surface, title, divider, text }, from the page's ids.
function TCTooltip.new(elements)
    local self = setmetatable({}, TCTooltip_mt)
    self.elements = elements
    self.targets = {}
    self.hovered = nil
    self.elapsed = 0
    return self
end

-- getContent() returns the title and the body text, worked out as the
-- tooltip opens. The body can use "\n"; long words (paths) are broken at
-- "/" to fit.
function TCTooltip:addTarget(element, getContent)
    table.insert(self.targets, { element = element, getContent = getContent })
end

function TCTooltip:hide()
    self.hovered = nil
    self.elapsed = 0
    self.elements.box:setVisible(false)
end

function TCTooltip:getHoveredTarget()
    local x, y = g_lastMousePosX, g_lastMousePosY
    if x == nil or y == nil then
        return nil
    end
    for _, target in ipairs(self.targets) do
        local element = target.element
        if element:getIsVisible() and GuiUtils.checkOverlayOverlap(x, y, element.absPosition[1],
                element.absPosition[2], element.absSize[1], element.absSize[2]) then
            return target
        end
    end
    return nil
end

function TCTooltip:update(dt)
    local target = nil
    if g_inputBinding:getShowMouseCursor() and not g_gui:getIsDialogVisible() then
        target = self:getHoveredTarget()
    end
    if target == nil then
        if self.hovered ~= nil then
            self:hide()
        end
        return
    end
    if target ~= self.hovered then
        self:hide()
        self.hovered = target
    end
    if self.elements.box:getIsVisible() then
        return
    end
    self.elapsed = self.elapsed + dt
    if self.elapsed >= TCTooltip.DELAY_MS then
        self:show(target)
    end
end

function TCTooltip:show(target)
    local e = self.elements
    local title, body = target.getContent()
    local width = getNormalizedScreenValues(TCTooltip.WIDTH_PX, 0)
    local padding = GuiUtils.getNormalizedScreenValues("20px 16px")
    local inset = GuiUtils.getNormalizedScreenValues("2px 2px")
    local _, titleHeight = getNormalizedScreenValues(0, 28)
    local _, dividerGap = getNormalizedScreenValues(0, 10)

    setTextBold(false)
    e.text:setSize(width, nil)
    e.text:setText(TCTooltip.wrap(body, width * TCTooltip.WRAP_SLACK, function(text)
        return getTextWidth(e.text.textSize, text)
    end))
    local textHeight = e.text:getTextHeight()
    e.text:setSize(width, textHeight)
    e.title:setText(title)
    e.title:setSize(width, titleHeight)
    e.divider:setSize(width, nil)

    -- Children are anchored bottom-left, so they're placed upwards.
    local boxWidth = width + 2 * padding[1]
    local boxHeight = textHeight + titleHeight + 2 * dividerGap + 2 * padding[2]
    e.box:setSize(boxWidth, boxHeight)
    e.surface:setSize(boxWidth - 2 * inset[1], boxHeight - 2 * inset[2])
    e.text:setPosition(padding[1], padding[2])
    e.divider:setPosition(padding[1], padding[2] + textHeight + dividerGap)
    e.title:setPosition(padding[1], boxHeight - padding[2] - titleHeight)

    -- Under the target, or above it if there's no room, kept on screen.
    local element = target.element
    local _, gap = getNormalizedScreenValues(0, 8)
    local x = math.max(0, math.min(element.absPosition[1], 1 - boxWidth))
    local y = element.absPosition[2] - gap - boxHeight
    if y < 0 then
        y = math.min(element.absPosition[2] + element.absSize[2] + gap, 1 - boxHeight)
    end
    e.box:setAbsolutePosition(x, math.max(0, y))
    e.box:setVisible(true)
end

-- Breaks text into lines no wider than maxWidth, at spaces and after "/",
-- so a long path wraps too (the engine only breaks at spaces). Lines
-- already split by "\n" stay split.
function TCTooltip.wrap(text, maxWidth, measure)
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local current = ""
        for piece in line:gmatch("[^ /]*[ /]?") do
            if piece ~= "" then
                local candidate = current .. piece
                if current ~= "" and measure((candidate:gsub(" $", ""))) > maxWidth then
                    table.insert(out, (current:gsub(" $", "")))
                    current = piece
                else
                    current = candidate
                end
            end
        end
        table.insert(out, (current:gsub(" $", "")))
    end
    return table.concat(out, "\n")
end
