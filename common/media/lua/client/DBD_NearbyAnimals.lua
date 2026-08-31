-- DBD_NearbyAnimals
-- Build 42.13 Compatible Version
-- Displays nearby animals with their stats in a UI panel

print("[DBD_NearbyAnimals] Loading mod...")

require "ISUI/ISUIElement"
require "ISUI/ISButton"
require "ISUI/ISContextMenu"
require "ISUI/ISLabel"
-- AnimalContextMenu is defined in ISUI/Animal/ISAnimalContextMenu.lua
-- It will be loaded when needed, but we can't require it at top level as it may not be available

DBD_NearbyAnimals = ISUIElement:derive("DBD_NearbyAnimals")
DBD_NearbyAnimals.instance = nil

-- Constants
local DEFAULT_WIDTH = 350  -- Increased to fit percentage text
local DEFAULT_HEIGHT = 400
local MIN_WIDTH = 300  -- Increased minimum width to ensure percentage text fits
local MIN_HEIGHT = 200
local MAX_DETECTION_RANGE = 10  -- tiles
local UPDATE_INTERVAL = 30  -- frames between updates
local RESIZE_HANDLE_SIZE = 12
local ICON_SIZE = 32
local PADDING = 10
local ROW_HEIGHT = 60  -- Compact height for animal entries
local STAT_BAR_HEIGHT = 6  -- Slightly taller bars for better visibility
local STAT_SPACING = 6  -- Spacing below each stat bar
local SCROLLBAR_WIDTH = 16  -- Width of the scrollbar

-- Font heights (will be initialized when needed)
local FONT_HGT_SMALL = nil
local FONT_HGT_MEDIUM = nil

-- Function to initialize font heights
local function initFontHeights()
    if not FONT_HGT_SMALL then
        FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
        FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
    end
end

-- Helper function to round numbers
local function round(num, decimals)
    decimals = decimals or 0
    local mult = 10 ^ decimals
    return math.floor(num * mult + 0.5) / mult
end

-- Function to find nearby animals
local function findNearbyAnimals(player, range)
    local nearbyAnimals = {}
    if not player then return nearbyAnimals end
    
    local playerSquare = player:getCurrentSquare()
    if not playerSquare then return nearbyAnimals end
    
    local cell = getCell()
    if not cell then return nearbyAnimals end
    
    local px, py, pz = playerSquare:getX(), playerSquare:getY(), playerSquare:getZ()
    local addedAnimals = {}  -- Track added animals by reference (hash table for O(1) lookup)
    
    -- Helper to add animal if not already added
    -- Optimize: pre-calculate range squared to avoid recalculating in loop
    local rangeSq = range * range
    
    local function addAnimalIfNew(animal)
        if not animal then return end
        
        -- Optimize: use hash table for O(1) duplicate check instead of O(n) linear search
        if addedAnimals[animal] then
            return
        end
        
        -- Quick health check (optimize: check before expensive operations)
        if animal:getHealth() <= 0 then return end
        
        addedAnimals[animal] = true
        
        -- Check distance - animals can be in world, hutches, or vehicles
        local animalSquare = nil
        if animal:isExistInTheWorld() then
            animalSquare = animal:getCurrentSquare()
        elseif animal:getHutch() then
            animalSquare = animal:getHutch():getSquare()
        elseif animal:getVehicle() then
            animalSquare = animal:getVehicle():getCurrentSquare()
        end
        
        if animalSquare then
            -- Optimize: compare squared distances to avoid sqrt calculation
            local dx = animalSquare:getX() - px
            local dy = animalSquare:getY() - py
            local distSq = dx * dx + dy * dy
            if distSq <= rangeSq then
                table.insert(nearbyAnimals, animal)
            end
        end
    end
    
    -- Check squares in a radius around the player
    -- Optimize: rangeSq already calculated above
    for x = px - range, px + range do
        for y = py - range, py + range do
            local dx = x - px
            local dy = y - py
            local distSq = dx * dx + dy * dy
            if distSq <= rangeSq then
                local square = cell:getGridSquare(x, y, pz)
                if square then
                    -- Check moving objects (animals are moving objects)
                    for i = 0, square:getMovingObjects():size() - 1 do
                        local obj = square:getMovingObjects():get(i)
                        if obj and instanceof(obj, "IsoAnimal") then
                            addAnimalIfNew(obj)
                        end
                    end
                    
                    -- Check for hutches on this square
                    for i = 0, square:getObjects():size() - 1 do
                        local obj = square:getObjects():get(i)
                        if obj and instanceof(obj, "IsoHutch") then
                            -- Get animals in the hutch
                            local hutch = obj
                            if hutch.getAnimals then
                                local animals = hutch:getAnimals()
                                if animals then
                                    for j = 0, animals:size() - 1 do
                                        local animal = animals:get(j)
                                        addAnimalIfNew(animal)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    return nearbyAnimals
end

-- Function to get animal stats
local function getAnimalStats(animal)
    if not animal then return nil end
    
    -- Cache animal type to avoid multiple calls
    local animalType = animal:getAnimalType()
    
    local stats = {
        name = animal:getFullName() or getText("IGUI_AnimalType_" .. animalType),
        type = animalType,
        health = 0,
        hunger = 0,
        thirst = 0,
        stress = 0,
        isFemale = animal:isFemale(),
        isBaby = animal:isBaby(),
        isPettedRecently = nil,  -- nil = can't be petted, true = petted recently, false = not petted recently
        age = nil  -- Age in days
    }
    
    -- Check if animal was petted recently (canBePet checks if it can be petted, petTimerDone checks if timer is done)
    local success, canBePet = pcall(function() 
        if animal.canBePet then
            return animal:canBePet()
        end
        return false
    end)
    if success and canBePet then
        local timerDoneSuccess, timerDone = pcall(function()
            if animal.petTimerDone then
                return animal:petTimerDone()
            end
            return true  -- If method doesn't exist, assume timer is done (can be petted)
        end)
        if timerDoneSuccess then
            -- If timer is NOT done, animal was petted recently (within last 24 hours)
            -- If timer IS done, animal can be petted (hasn't been petted recently)
            stats.isPettedRecently = not timerDone
        end
    end
    -- If canBePet is false or failed, isPettedRecently remains nil (don't show icon)
    
    -- Get health (optimize: remove pcall for standard method)
    local health = animal:getHealth()
    if health then
        stats.health = math.max(0, math.min(100, health * 100))
    end
    
    -- Get hunger (optimize: try direct method first, fallback only if needed)
    if animal.getHunger then
        local hunger = animal:getHunger()
        if hunger then
            stats.hunger = math.max(0, math.min(100, hunger * 100))
        end
    else
        -- Fallback to data only if direct method doesn't exist
        local data = animal:getData()
        if data and data.getHunger then
            local hunger = data:getHunger()
            if hunger then
                stats.hunger = math.max(0, math.min(100, hunger * 100))
            end
        end
    end
    
    -- Get thirst (optimize: remove pcall for standard method)
    local thirst = animal:getThirst()
    if thirst then
        stats.thirst = math.max(0, math.min(100, thirst * 100))
    end
    
    -- Get stress (getStress returns 0-100 already, unlike health/hunger/thirst which return 0-1)
    local stress = animal:getStress()
    if stress then
        stats.stress = math.max(0, math.min(100, stress))
    end
    
    -- Get age (optimized: use animal:getAge() which is the working method)
    -- Remove pcall since we know the method exists and works
    if animal.getAge then
        stats.age = math.floor(animal:getAge())
    end
    
    return stats
end

-- Function to get animal icon texture (optimized: use animal:getInventoryIconTexture() which is the working method)
local function getAnimalIcon(animal)
    if not animal then return nil end
    
    -- Use the same method as the game's context menu - this is the reliable method
    if animal.getInventoryIconTexture then
        return animal:getInventoryIconTexture()
    end
    
    -- Return nil - we'll draw a placeholder with animal type letter
    return nil
end

function DBD_NearbyAnimals:initialise()
    ISUIElement.initialise(self)
    self:create()
end

function DBD_NearbyAnimals:create()
    -- Set initial size
    self:setWidth(DEFAULT_WIDTH)
    self:setHeight(DEFAULT_HEIGHT)
    
    -- Initialize update counter
    self.updateCounter = 0
    self.nearbyAnimals = {}
    self.animalIconBounds = {}  -- Store icon positions for click detection
    self.animalEntryBounds = {}  -- Store entry bounds for click detection
    self.scrollY = 0  -- Scroll position
    self.scrolling = false  -- Whether user is dragging scrollbar
    self.scrollStartY = 0  -- Starting Y position when dragging scrollbar
    self.scrollStartScrollY = 0  -- Starting scrollY when dragging scrollbar
    self.selectedAnimal = nil  -- Currently selected/highlighted animal (for UI)
    self.highlightedAnimal = nil  -- Currently highlighted animal on the map
    -- Settings button bounds (will be set in prerender)
    self.settingsBtnX = nil
    self.settingsBtnY = nil
    self.settingsBtnSize = nil
end

function DBD_NearbyAnimals:clearHighlight()
    -- Clear the highlighted animal on the map (optimize: reduce redundant checks)
    if not self.highlightedAnimal then return end
    
    local player = getSpecificPlayer(0)
    if player and instanceof(self.highlightedAnimal, "IsoAnimal") then
        local playerNum = player:getPlayerNum()
        if self.highlightedAnimal.setOutlineHighlight then
            self.highlightedAnimal:setOutlineHighlight(playerNum, false)
        end
    end
    self.highlightedAnimal = nil
    self.selectedAnimal = nil
end

function DBD_NearbyAnimals:setVisible(visible)
    ISUIElement.setVisible(self, visible)
    if not visible then
        -- Clear highlight when panel is hidden
        self:clearHighlight()
    end
end

function DBD_NearbyAnimals:removeFromUIManager()
    -- Clear highlight when removing from UI
    self:clearHighlight()
    ISUIElement.removeFromUIManager(self)
end

function DBD_NearbyAnimals:prerender()
    -- Don't run if not in-game (prevents errors when returning to main menu)
    if not isIngameState() then
        return
    end
    
    -- Don't run if UI is not visible
    if not self:isVisible() then
        -- Clear highlight when UI is hidden
        if self.highlightedAnimal then
            self:clearHighlight()
        end
        return
    end
    
    -- Initialize font heights if needed
    initFontHeights()
    
    -- Refresh highlight every frame (same as context menu behavior)
    -- Optimize: reduce redundant checks
    if self.highlightedAnimal then
        local player = getSpecificPlayer(0)
        if not player then
            self:clearHighlight()
            return
        end
        
        -- Optimize: check instanceof once
        if not instanceof(self.highlightedAnimal, "IsoAnimal") then
            self:clearHighlight()
            return
        end
        
        -- Check if animal is still valid and nearby (optimize: use hash lookup if possible)
        local stillNearby = false
        for _, animal in ipairs(self.nearbyAnimals) do
            if animal == self.highlightedAnimal then
                stillNearby = true
                break
            end
        end
        
        if stillNearby then
            -- Optimize: only check validity if still nearby
            local animalValid = self.highlightedAnimal:isExistInTheWorld() or self.highlightedAnimal:getHutch() or self.highlightedAnimal:getVehicle()
            if animalValid then
                -- Refresh highlight every frame (same as context menu does)
                local playerNum = player:getPlayerNum()
                if self.highlightedAnimal.setOutlineHighlight then
                    self.highlightedAnimal:setOutlineHighlight(playerNum, true)
                    if self.highlightedAnimal.setOutlineHighlightCol then
                        self.highlightedAnimal:setOutlineHighlightCol(playerNum, 1, 1, 1, 1)  -- White highlight
                    end
                end
            else
                self:clearHighlight()
            end
        else
            -- Animal no longer nearby, clear highlight
            self:clearHighlight()
        end
    end
    
    -- Draw background
    self:drawRect(0, 0, self.width, self.height, 0.8, 0.1, 0.1, 0.1)
    self:drawRectBorder(0, 0, self.width, self.height, 0.5, 0.4, 0.4, 0.4)
    
    -- Draw title (half size - using Small font)
    self:drawText(getText("IGUI_DBD_NearbyAnimals_Title"), PADDING, PADDING + 2, 1, 1, 1, 1, UIFont.Small)
    
    -- Draw settings button (gear icon) next to close button
    local btnSize = 18
    local closeBtnX = self.width - btnSize - PADDING
    local settingsBtnX = closeBtnX - btnSize - 5
    local btnY = PADDING
    
    -- Store settings button bounds for click detection
    self.settingsBtnX = settingsBtnX
    self.settingsBtnY = btnY
    self.settingsBtnSize = btnSize
    
    -- Settings button
    self:drawRect(settingsBtnX, btnY, btnSize, btnSize, 1.0, 0.2, 0.2, 0.2)
    self:drawRectBorder(settingsBtnX, btnY, btnSize, btnSize, 0.8, 0.8, 0.8, 0.8)
    self:drawText("⚙", settingsBtnX + 4, btnY + 1, 1, 1, 1, 1, UIFont.Small)
    
    -- Draw close X button in top right corner
    self:drawRect(closeBtnX, btnY, btnSize, btnSize, 1.0, 0.2, 0.2, 0.2)
    self:drawRectBorder(closeBtnX, btnY, btnSize, btnSize, 0.8, 0.8, 0.2, 0.2)
    self:drawText("X", closeBtnX + 5, btnY + 2, 1, 1, 1, 1, UIFont.Small)
    
    -- Draw separator line
    local titleHeight = FONT_HGT_SMALL + PADDING * 2
    self:drawRect(PADDING, titleHeight, self.width - PADDING * 2, 1, 1.0, 0.4, 0.4, 0.4)
end

function DBD_NearbyAnimals:render()
    -- Don't run if not in-game (prevents errors when returning to main menu)
    if not isIngameState() then
        return
    end
    
    -- Don't run if UI is not visible
    if not self:isVisible() then
        return
    end
    
    ISUIElement.render(self)
    
    -- Initialize font heights if needed
    initFontHeights()
    
    local player = getSpecificPlayer(0)
    if not player then return end
    
    -- Update animal list periodically (only when visible)
    self.updateCounter = (self.updateCounter or 0) + 1
    if self.updateCounter >= UPDATE_INTERVAL then
        self.updateCounter = 0
        self.nearbyAnimals = findNearbyAnimals(player, MAX_DETECTION_RANGE)
    end
    
    -- Calculate header height (title + separator + padding)
    local titleHeight = FONT_HGT_SMALL + PADDING * 2
    local separatorHeight = 1
    local headerBottom = titleHeight + separatorHeight
    
    -- Draw animals with scrolling support
    local startY = headerBottom + PADDING
    local currentY = startY - (self.scrollY or 0)  -- Apply scroll offset
    
    -- Calculate visible area (content area, excluding header)
    local visibleTop = startY
    local visibleBottom = self.height - PADDING
    local contentWidth = self.width - PADDING * 2
    if self.width > SCROLLBAR_WIDTH + PADDING * 2 then
        contentWidth = self.width - SCROLLBAR_WIDTH - PADDING * 2  -- Reserve space for scrollbar
    end
    
    -- Calculate total content height first (for scrollbar)
    local totalContentHeight = 0
    if #self.nearbyAnimals == 0 then
        totalContentHeight = FONT_HGT_SMALL + PADDING
    else
        for i, animal in ipairs(self.nearbyAnimals) do
            if animal and animal:getHealth() > 0 then
                local stillExists = animal:isExistInTheWorld() or animal:getHutch() or animal:getVehicle()
                if stillExists then
                    local estimatedHeight = (FONT_HGT_SMALL + STAT_SPACING) + (STAT_BAR_HEIGHT + STAT_SPACING) * 4 + 10
                    local entryHeight = math.max(ROW_HEIGHT, estimatedHeight)
                    totalContentHeight = totalContentHeight + entryHeight + PADDING
                end
            end
        end
    end
    
    local visibleHeight = visibleBottom - visibleTop
    local needsScrollbar = totalContentHeight > visibleHeight
    
    -- Clamp scroll position
    local maxScroll = math.max(0, totalContentHeight - visibleHeight)
    if self.scrollY > maxScroll then
        self.scrollY = maxScroll
    end
    if self.scrollY < 0 then
        self.scrollY = 0
    end
    
    -- Recalculate currentY with clamped scroll
    currentY = startY - self.scrollY
    
    -- Set clipping rectangle to prevent content from drawing outside visible area
    -- Clip to content area (below header, above bottom padding, excluding scrollbar area)
    local clipX = PADDING
    local clipY = visibleTop
    local clipWidth = contentWidth
    local clipHeight = visibleBottom - visibleTop
    self:setStencilRect(clipX, clipY, clipWidth, clipHeight)
    
    -- Clear icon bounds and entry bounds for this frame
    self.animalIconBounds = {}
    self.animalEntryBounds = {}  -- Store full entry bounds for click detection
    
    if #self.nearbyAnimals == 0 then
        -- Only draw if within visible bounds
        if currentY >= visibleTop and currentY <= visibleBottom then
            self:drawText(getText("IGUI_DBD_NearbyAnimals_NoAnimals"), PADDING, currentY, 0.7, 0.7, 0.7, 1, UIFont.Small)
        end
        currentY = currentY + FONT_HGT_SMALL + PADDING
    else
        for i, animal in ipairs(self.nearbyAnimals) do
            -- Skip invalid animals
            if animal and animal:getHealth() > 0 then
                -- Check if animal still exists (in world, hutch, or vehicle)
                local stillExists = animal:isExistInTheWorld() or animal:getHutch() or animal:getVehicle()
                if stillExists then
                    local stats = getAnimalStats(animal)
                    if stats then
                        -- Calculate entry height first (estimate based on content)
                        -- Name/Type combined (FONT_HGT_SMALL + STAT_SPACING) + 4 stats (STAT_BAR_HEIGHT + STAT_SPACING each) + padding
                        local estimatedHeight = (FONT_HGT_SMALL + STAT_SPACING) + (STAT_BAR_HEIGHT + STAT_SPACING) * 4 + 10
                        local entryHeight = math.max(ROW_HEIGHT, estimatedHeight)
                        
                        -- Only draw if entry is at least partially visible (with small margin for smooth scrolling)
                        local entryBottom = currentY + entryHeight
                        if entryBottom >= visibleTop - 5 and currentY <= visibleBottom + 5 then
                            -- Store entry bounds for click detection (use actual Y position, not scrolled)
                            table.insert(self.animalEntryBounds, {
                                animal = animal,
                                x = PADDING,
                                y = currentY,
                                width = contentWidth,
                                height = entryHeight
                            })
                            
                            -- Draw animal entry background first
                            -- Highlight if this is the selected animal
                            local isSelected = (self.selectedAnimal == animal)
                            local bgAlpha = isSelected and 0.5 or 0.3
                            local borderAlpha = isSelected and 1.0 or 0.5
                            local borderR, borderG, borderB = 0.3, 0.3, 0.3
                            if isSelected then
                                borderR, borderG, borderB = 1.0, 1.0, 1.0  -- White outline for selected
                            end
                            self:drawRect(PADDING, currentY, contentWidth, entryHeight, bgAlpha, 0.15, 0.15, 0.15)
                            -- Draw thicker border for selected animal
                            if isSelected then
                                -- Draw outer border (thicker)
                                self:drawRectBorder(PADDING - 2, currentY - 2, contentWidth + 4, entryHeight + 4, borderAlpha, borderR, borderG, borderB)
                                -- Draw inner border
                                self:drawRectBorder(PADDING, currentY, contentWidth, entryHeight, borderAlpha * 0.7, borderR, borderG, borderB)
                            else
                                self:drawRectBorder(PADDING, currentY, contentWidth, entryHeight, borderAlpha, borderR, borderG, borderB)
                            end
                            
                            -- Draw animal icon
                            local iconX = PADDING + 5
                            local iconY = currentY + 5
                            
                            -- Store icon bounds for click detection
                            table.insert(self.animalIconBounds, {
                                animal = animal,
                                x = iconX,
                                y = iconY,
                                width = ICON_SIZE,
                                height = ICON_SIZE
                            })
                            
                            local iconTexture = getAnimalIcon(animal)
                            if iconTexture then
                                self:drawTexture(iconTexture, iconX, iconY, ICON_SIZE, ICON_SIZE, 1, 1, 1, 1)
                            else
                                -- Draw placeholder rectangle with animal type letter
                                self:drawRect(iconX, iconY, ICON_SIZE, ICON_SIZE, 0.5, 0.3, 0.3, 0.3)
                                self:drawRectBorder(iconX, iconY, ICON_SIZE, ICON_SIZE, 0.8, 0.5, 0.5, 0.5)
                                -- Draw first letter of animal type as icon
                                local animalType = stats.type or "?"
                                local firstLetter = string.sub(animalType, 1, 1):upper()
                                local textWidth = getTextManager():MeasureStringX(UIFont.Small, firstLetter)
                                local textHeight = FONT_HGT_SMALL
                                self:drawText(firstLetter, iconX + (ICON_SIZE - textWidth) / 2, iconY + (ICON_SIZE - textHeight) / 2, 0.8, 0.8, 0.8, 1, UIFont.Small)
                            end
                            
                            -- Draw age in top right corner of animal box
                            if stats.age ~= nil then
                                local ageText = tostring(stats.age) .. "d"
                                local ageTextWidth = getTextManager():MeasureStringX(UIFont.Small, ageText)
                                local ageX = PADDING + contentWidth - ageTextWidth - 5
                                local ageY = currentY + 5
                                
                                -- Draw background for better readability
                                local bgAlpha = 0.7
                                local bgColor = {r=0.1, g=0.1, b=0.1}
                                local bgPadding = 2
                                self:drawRect(ageX - bgPadding, ageY - 1, ageTextWidth + bgPadding * 2, FONT_HGT_SMALL + 2, bgAlpha, bgColor.r, bgColor.g, bgColor.b)
                                
                                -- Draw age text
                                self:drawText(ageText, ageX, ageY, 0.9, 0.9, 0.9, 1, UIFont.Small)
                            end
                            
                            -- Draw gender icon below animal icon
                            local genderIconSize = 12
                            local genderIconX = iconX + (ICON_SIZE - genderIconSize) / 2
                            local genderIconY = iconY + ICON_SIZE + 2
                            local genderSymbol = stats.isFemale and "F" or "M"
                            local genderColor = stats.isFemale and {r=1.0, g=0.4, b=0.8} or {r=0.4, g=0.6, b=1.0}
                            -- Draw gender icon background
                            self:drawRect(genderIconX, genderIconY, genderIconSize, genderIconSize, 0.3, 0.2, 0.2, 0.2)
                            self:drawRectBorder(genderIconX, genderIconY, genderIconSize, genderIconSize, 0.6, genderColor.r, genderColor.g, genderColor.b)
                            -- Draw gender symbol centered
                            local genderTextWidth = getTextManager():MeasureStringX(UIFont.Small, genderSymbol)
                            local genderTextX = genderIconX + (genderIconSize - genderTextWidth) / 2
                            local genderTextY = genderIconY + (genderIconSize - FONT_HGT_SMALL) / 2
                            self:drawText(genderSymbol, genderTextX, genderTextY, genderColor.r, genderColor.g, genderColor.b, 1, UIFont.Small)
                            
                            -- Draw petting status label below gender icon (only show if petted recently)
                            if stats.isPettedRecently == true then
                                local petLabelText = getText("IGUI_DBD_NearbyAnimals_Petted")
                                local petLabelColor = {r=0.2, g=0.8, b=0.2}  -- Green for petted
                                local petLabelY = genderIconY + genderIconSize + 3 + 2  -- Add 2px margin to top
                                local petLabelTextWidth = getTextManager():MeasureStringX(UIFont.Small, petLabelText)
                                local petLabelHeight = FONT_HGT_SMALL + 2
                                local petLabelX = iconX + (ICON_SIZE - petLabelTextWidth) / 2 - 2 + 2  -- Add 2px margin to left
                                local petLabelWidth = petLabelTextWidth + 4
                                
                                -- Draw background box for better readability
                                local bgAlpha = 0.7
                                local bgColor = {r=0.1, g=0.1, b=0.1}
                                self:drawRect(petLabelX, petLabelY - 1, petLabelWidth, petLabelHeight, bgAlpha, bgColor.r, bgColor.g, bgColor.b)
                                
                                -- Draw outline border
                                local outlineColor = petLabelColor
                                self:drawRectBorder(petLabelX, petLabelY - 1, petLabelWidth, petLabelHeight, 1.0, outlineColor.r, outlineColor.g, outlineColor.b)
                                
                                -- Draw text centered in box (use white/brighter text for better contrast)
                                local textColor = {r=0.9, g=1.0, b=0.9}  -- Light green/white for better readability
                                local textX = petLabelX + 2
                                local textY = petLabelY
                                self:drawText(petLabelText, textX, textY, textColor.r, textColor.g, textColor.b, 1, UIFont.Small)
                            end
                            
                            -- Draw animal name and type (combined on one line, no gender text)
                            local textX = iconX + ICON_SIZE + PADDING
                            local textY = currentY + 5
                            
                            -- Name with type (gender removed from text)
                            local nameText = stats.name
                            if stats.isBaby then
                                nameText = nameText .. " (" .. getText("IGUI_DBD_NearbyAnimals_Baby") .. ")"
                            end
                            self:drawText(nameText, textX, textY, 1, 1, 1, 1, UIFont.Small)
                            textY = textY + FONT_HGT_SMALL + STAT_SPACING
                            
                            -- Stats with progress bar style (matching DBD_PrettySimpleStats)
                            -- Calculate maximum label width to ensure bars align properly
                            local labelWidth = math.max(
                                getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_DBD_NearbyAnimals_HP")),
                                getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_DBD_NearbyAnimals_Hunger")),
                                getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_DBD_NearbyAnimals_Thirst")),
                                getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_DBD_NearbyAnimals_Stress"))
                            ) + 5  -- Add 5px spacing after label
                            local barStartX = textX + labelWidth
                            local percentTextWidth = getTextManager():MeasureStringX(UIFont.Small, "100%") + 8  -- Increased spacing for percentage text
                            -- Calculate available width: content width minus bar start position, padding, and percentage text width
                            local availableWidth = contentWidth - (barStartX - PADDING) - percentTextWidth
                            local statBarWidth = math.max(0, availableWidth)
                        
                            -- Helper function to draw a stat bar with percentage
                            local function drawStatBar(labelKey, value, color, barY)
                                -- Center text vertically with bar
                                local textY = barY + (STAT_BAR_HEIGHT / 2) - 6  -- 6px is half font height
                                local label = getText(labelKey)
                                self:drawText(label, textX, textY, 1, 1, 1, 1, UIFont.Small)
                                
                                if statBarWidth > 0 then
                                    -- Bar background (light cyan/white like DBD_PrettySimpleStats)
                                    self:drawRect(barStartX, barY, statBarWidth, STAT_BAR_HEIGHT, 0.15, 1, 1, 1)
                                    
                                    -- Bar fill (colored)
                                    local fillWidth = math.min(statBarWidth, (statBarWidth * math.min(value, 100) / 100))
                                    self:drawRect(barStartX, barY, fillWidth, STAT_BAR_HEIGHT, 1, color.r, color.g, color.b)
                                    
                                    -- Bar border (light border)
                                    self:drawRectBorder(barStartX, barY, statBarWidth, STAT_BAR_HEIGHT, 0.4, 1, 1, 1)
                                    
                                    -- Divider lines at 25%, 50%, 75% (matching DBD_PrettySimpleStats style)
                                    for i = 1, 3 do
                                        self:drawRect(barStartX + (statBarWidth * 0.25 * i), barY, 1, STAT_BAR_HEIGHT, 0.2, 1, 1, 1)
                                    end
                                    
                                    -- Percentage text after bar
                                    local percentText = string.format("%d%%", math.floor(value))
                                    local percentX = barStartX + statBarWidth + 5
                                    self:drawText(percentText, percentX, textY, 1, 1, 1, 1, UIFont.Small)
                                end
                            end
                            
                            -- Health
                            local healthColor = {r = 0.8, g = 0.2, b = 0.2}
                            if stats.health > 50 then
                                healthColor = {r = 0.2, g = 0.8, b = 0.2}
                            elseif stats.health > 25 then
                                healthColor = {r = 0.8, g = 0.6, b = 0.2}
                            end
                            drawStatBar("IGUI_DBD_NearbyAnimals_HP", stats.health, healthColor, textY)
                            textY = textY + STAT_BAR_HEIGHT + STAT_SPACING
                            
                            -- Hunger
                            local hungerColor = {r = 0.8, g = 0.4, b = 0.0}
                            if stats.hunger > 50 then
                                hungerColor = {r = 0.2, g = 0.8, b = 0.2}
                            elseif stats.hunger > 25 then
                                hungerColor = {r = 0.8, g = 0.6, b = 0.2}
                            end
                            drawStatBar("IGUI_DBD_NearbyAnimals_Hunger", stats.hunger, hungerColor, textY)
                            textY = textY + STAT_BAR_HEIGHT + STAT_SPACING
                            
                            -- Thirst
                            local thirstColor = {r = 0.0, g = 0.4, b = 0.8}
                            if stats.thirst > 50 then
                                thirstColor = {r = 0.2, g = 0.8, b = 0.2}
                            elseif stats.thirst > 25 then
                                thirstColor = {r = 0.8, g = 0.6, b = 0.2}
                            end
                            drawStatBar("IGUI_DBD_NearbyAnimals_Thirst", stats.thirst, thirstColor, textY)
                            textY = textY + STAT_BAR_HEIGHT + STAT_SPACING
                            
                            -- Stress
                            local stressColor = {r = 0.8, g = 0.2, b = 0.8}
                            if stats.stress < 50 then
                                stressColor = {r = 0.2, g = 0.8, b = 0.2}
                            elseif stats.stress < 75 then
                                stressColor = {r = 0.8, g = 0.6, b = 0.2}
                            end
                            drawStatBar("IGUI_DBD_NearbyAnimals_Stress", stats.stress, stressColor, textY)
                        end
                        
                        currentY = currentY + entryHeight + PADDING
                    end
                end
            end
        end
    end
    
    -- Clear clipping rectangle
    self:clearStencilRect()
    
    -- Draw scrollbar if needed
    if needsScrollbar then
        local scrollbarX = self.width - SCROLLBAR_WIDTH - 1
        local scrollbarY = visibleTop
        local scrollbarHeight = visibleBottom - visibleTop
        
        -- Scrollbar background
        self:drawRect(scrollbarX, scrollbarY, SCROLLBAR_WIDTH, scrollbarHeight, 0.5, 0.2, 0.2, 0.2)
        self:drawRectBorder(scrollbarX, scrollbarY, SCROLLBAR_WIDTH, scrollbarHeight, 0.8, 0.4, 0.4, 0.4)
        
        -- Calculate thumb size and position
        local thumbHeight = math.max(20, (visibleHeight / totalContentHeight) * scrollbarHeight)
        local thumbY = scrollbarY + (self.scrollY / maxScroll) * (scrollbarHeight - thumbHeight)
        if maxScroll == 0 then
            thumbY = scrollbarY
        end
        
        -- Scrollbar thumb
        local thumbColor = 0.7
        if self.scrolling or (self.mouseOver and self:getMouseX() >= scrollbarX and self:getMouseX() <= scrollbarX + SCROLLBAR_WIDTH) then
            thumbColor = 0.9
        end
        self:drawRect(scrollbarX + 2, thumbY, SCROLLBAR_WIDTH - 4, thumbHeight, thumbColor, 0.5, 0.5, 0.5)
        self:drawRectBorder(scrollbarX + 2, thumbY, SCROLLBAR_WIDTH - 4, thumbHeight, 1.0, 0.7, 0.7, 0.7)
    end
    
    -- Don't auto-resize height - keep fixed height with scrolling
    
    -- Draw resize handle if mouse is over
    if self.mouseOver then
        local handleX = self.width - RESIZE_HANDLE_SIZE
        local handleY = self.height - RESIZE_HANDLE_SIZE
        self:drawRect(handleX, handleY, RESIZE_HANDLE_SIZE, RESIZE_HANDLE_SIZE, 0.6, 0.5, 0.5, 0.5)
        -- Draw diagonal lines
        local lineOffset = 2
        for i = 1, 3 do
            self:drawRect(handleX + lineOffset * i, handleY + RESIZE_HANDLE_SIZE - lineOffset * i, 1, 1, 0.9, 1, 1, 1)
        end
    end
end

function DBD_NearbyAnimals:new(x, y)
    local o = ISUIElement.new(self, x, y, DEFAULT_WIDTH, DEFAULT_HEIGHT)
    o.backgroundColor = {r=0, g=0, b=0, a=0}
    o.borderColor = {r=0.4, g=0.4, b=0.4, a=0.5}
    o.moveWithMouse = false  -- We'll handle dragging manually
    o.updateCounter = 0
    o.nearbyAnimals = {}
    o.dragging = false
    o.resizing = false
    o.mouseOver = false
    return o
end

-- Mouse event handlers for dragging and resizing
function DBD_NearbyAnimals:onMouseMove(dx, dy)
    self.mouseOver = true
    
    -- Handle scrolling (scrollbar dragging)
    if self.scrolling and self.scrollStartY then
        local visibleTop = FONT_HGT_SMALL + PADDING * 3
        local visibleBottom = self.height - PADDING
        local visibleHeight = visibleBottom - visibleTop
        
        -- Calculate total content height
        local totalContentHeight = 0
        if #self.nearbyAnimals > 0 then
            for i, animal in ipairs(self.nearbyAnimals) do
                if animal and animal:getHealth() > 0 then
                    local stillExists = animal:isExistInTheWorld() or animal:getHutch() or animal:getVehicle()
                    if stillExists then
                        local estimatedHeight = (FONT_HGT_SMALL + STAT_SPACING) + (STAT_BAR_HEIGHT + STAT_SPACING) * 4 + 10
                        local entryHeight = math.max(ROW_HEIGHT, estimatedHeight)
                        totalContentHeight = totalContentHeight + entryHeight + PADDING
                    end
                end
            end
        end
        
        local maxScroll = math.max(0, totalContentHeight - visibleHeight)
        local mouseY = self:getMouseY()
        local scrollbarHeight = visibleBottom - visibleTop
        local scrollDelta = (mouseY - self.scrollStartY) / scrollbarHeight * totalContentHeight
        self.scrollY = math.max(0, math.min(maxScroll, self.scrollStartScrollY + scrollDelta))
        return true
    end
    
    -- Handle resizing
    if self.resizing and self.resizeStartWidth then
        if not self.resizeDeltaX then self.resizeDeltaX = 0 end
        if not self.resizeDeltaY then self.resizeDeltaY = 0 end
        self.resizeDeltaX = self.resizeDeltaX + dx
        self.resizeDeltaY = self.resizeDeltaY + dy
        
        local newWidth = math.max(MIN_WIDTH, self.resizeStartWidth + self.resizeDeltaX)
        local newHeight = math.max(MIN_HEIGHT, self.resizeStartHeight + self.resizeDeltaY)
        self:setWidth(newWidth)
        self:setHeight(newHeight)
        return true
    end
    
    -- Handle dragging
    if self.dragging then
        self:setX(self:getX() + dx)
        self:setY(self:getY() + dy)
        return true
    end
    
    return true
end

function DBD_NearbyAnimals:onMouseDown(x, y)
    -- Check if clicking on settings button
    -- Use stored bounds if available, otherwise calculate them
    local btnSize = 18
    local closeBtnX = self.width - btnSize - PADDING
    local settingsBtnX = closeBtnX - btnSize - 5
    local btnY = PADDING
    
    -- Use stored bounds if available (from prerender), otherwise use calculated values
    if self.settingsBtnX then settingsBtnX = self.settingsBtnX end
    if self.settingsBtnY then btnY = self.settingsBtnY end
    if self.settingsBtnSize then btnSize = self.settingsBtnSize end
    
    -- Check if click is within the entire button area
    if x >= settingsBtnX and x <= settingsBtnX + btnSize and y >= btnY and y <= btnY + btnSize then
        -- Open settings window
        self:openSettingsWindow()
        getSoundManager():playUISound("UIToggle")
        return true
    end
    
    -- Check if clicking on close X button
    local btnSize = 18
    local closeBtnX = self.width - btnSize - PADDING
    local btnY = PADDING
    if x >= closeBtnX and x <= closeBtnX + btnSize and y >= btnY and y <= btnY + btnSize then
        -- Hide the panel (but don't remove from UI manager so it can be toggled back)
        self:setVisible(false)
        -- Clear any highlights when closing
        self:clearHighlight()
        getSoundManager():playUISound("UIToggle")
        return true
    end
    
    -- Check if clicking on scrollbar
    local visibleTop = FONT_HGT_SMALL + PADDING * 3
    local visibleBottom = self.height - PADDING
    local scrollbarX = self.width - SCROLLBAR_WIDTH - 1
    
    -- Calculate if scrollbar is needed
    local totalContentHeight = 0
    if #self.nearbyAnimals > 0 then
        for i, animal in ipairs(self.nearbyAnimals) do
            if animal and animal:getHealth() > 0 then
                local stillExists = animal:isExistInTheWorld() or animal:getHutch() or animal:getVehicle()
                if stillExists then
                    local estimatedHeight = (FONT_HGT_SMALL + STAT_SPACING) + (STAT_BAR_HEIGHT + STAT_SPACING) * 4 + 10
                    local entryHeight = math.max(ROW_HEIGHT, estimatedHeight)
                    totalContentHeight = totalContentHeight + entryHeight + PADDING
                end
            end
        end
    end
    local visibleHeight = visibleBottom - visibleTop
    local needsScrollbar = totalContentHeight > visibleHeight
    
    if needsScrollbar and x >= scrollbarX and x <= scrollbarX + SCROLLBAR_WIDTH and y >= visibleTop and y <= visibleBottom then
        -- Clicked on scrollbar - start scrolling
        self.scrolling = true
        self.scrollStartY = y
        self.scrollStartScrollY = self.scrollY
        return true
    end
    
    -- Check if clicking on resize handle
    local handleX = self.width - RESIZE_HANDLE_SIZE
    local handleY = self.height - RESIZE_HANDLE_SIZE
    if x >= handleX and x <= self.width and y >= handleY and y <= self.height then
        self.resizing = true
        self.resizeStartWidth = self.width
        self.resizeStartHeight = self.height
        self.resizeDeltaX = 0
        self.resizeDeltaY = 0
        return true
    end
    
    -- Check if left-clicking on an animal entry (for highlighting)
    if self.animalEntryBounds then
        for _, entryBounds in ipairs(self.animalEntryBounds) do
            -- Entry bounds Y is stored with scroll offset applied
            local entryScreenY = entryBounds.y  -- This is the scrolled Y position
            local entryScreenBottom = entryScreenY + entryBounds.height
            
            -- Check if click is within the entry bounds (using scrolled coordinates)
            if x >= entryBounds.x and x <= entryBounds.x + entryBounds.width and
               y >= entryScreenY and y <= entryScreenBottom then
                -- Found clicked animal entry, highlight the animal
                local animal = entryBounds.animal
                if animal then
                    local player = getSpecificPlayer(0)
                    if player then
                        -- Verify animal is an IsoAnimal and still exists
                        local animalValid = false
                        if instanceof(animal, "IsoAnimal") then
                            animalValid = animal:isExistInTheWorld() or animal:getHutch() or animal:getVehicle()
                        end
                        
                        if animalValid then
                            -- Toggle selection: if clicking the same animal, deselect it
                            if self.selectedAnimal == animal and self.highlightedAnimal == animal then
                                -- Deselect: clear highlight and selection
                                pcall(function()
                                    if self.highlightedAnimal and instanceof(self.highlightedAnimal, "IsoAnimal") then
                                        local playerNum = player:getPlayerNum()
                                        -- Use setOutlineHighlight with player number to clear highlight
                                        if self.highlightedAnimal.setOutlineHighlight then
                                            self.highlightedAnimal:setOutlineHighlight(playerNum, false)
                                        end
                                    end
                                end)
                                self.selectedAnimal = nil
                                self.highlightedAnimal = nil
                                -- Play sound feedback
                                getSoundManager():playUISound("UIToggle")
                                return true  -- Don't start dragging
                            end
                            
                            -- Clear previous highlight if selecting a different animal
                            if self.highlightedAnimal and self.highlightedAnimal ~= animal then
                                pcall(function()
                                    if self.highlightedAnimal and instanceof(self.highlightedAnimal, "IsoAnimal") then
                                        local playerNum = player:getPlayerNum()
                                        -- Use setOutlineHighlight with player number to clear highlight
                                        if self.highlightedAnimal.setOutlineHighlight then
                                            self.highlightedAnimal:setOutlineHighlight(playerNum, false)
                                        end
                                    end
                                end)
                            end
                            
                            -- Set as selected animal (for UI highlighting)
                            self.selectedAnimal = animal
                            self.highlightedAnimal = animal
                            
                            -- Highlight the animal on the map (same as context menu hover)
                            -- Use setOutlineHighlight with player number (not player object)
                            pcall(function()
                                if animal and instanceof(animal, "IsoAnimal") then
                                    local playerNum = player:getPlayerNum()
                                    -- Use setOutlineHighlight with player number (like context menu does)
                                    if animal.setOutlineHighlight then
                                        animal:setOutlineHighlight(playerNum, true)
                                        if animal.setOutlineHighlightCol then
                                            animal:setOutlineHighlightCol(playerNum, 1, 1, 1, 1)  -- White highlight
                                        end
                                    end
                                end
                            end)
                        
                            -- Try to center camera on animal (optional feature)
                            -- Wrapped in pcall to prevent errors if camera isn't available
                            pcall(function()
                                -- Only try camera movement if animal is in the world (not in hutch/vehicle)
                                if animal:isExistInTheWorld() then
                                    local animalSquare = animal:getCurrentSquare()
                                    if animalSquare then
                                        -- Check if getCamera exists and works
                                        local cameraFunc = getCamera
                                        if cameraFunc and type(cameraFunc) == "function" then
                                            local success, camera = pcall(cameraFunc)
                                            if success and camera then
                                                -- Check if camera has the set methods
                                                if camera.setX and camera.setY and camera.setZ then
                                                    pcall(function()
                                                        camera:setX(animalSquare:getX())
                                                        camera:setY(animalSquare:getY())
                                                        camera:setZ(animalSquare:getZ())
                                                    end)
                                                end
                                            end
                                        end
                                    end
                                end
                            end)
                            
                            -- Play sound feedback
                            getSoundManager():playUISound("UIToggle")
                        end  -- closes if animalValid and animal.setOutlineHighlight then
                    end  -- closes if player then
                end  -- closes if animal then
                -- Don't start dragging if clicking on an animal entry
                return true
            end
        end
    end
    
    -- Clear highlight if clicking elsewhere (not on an animal entry)
    if self.highlightedAnimal then
        local player = getSpecificPlayer(0)
        if player and self.highlightedAnimal and instanceof(self.highlightedAnimal, "IsoAnimal") then
            pcall(function()
                if self.highlightedAnimal and instanceof(self.highlightedAnimal, "IsoAnimal") then
                    local playerNum = player:getPlayerNum()
                    -- Use setOutlineHighlight with player number to clear highlight
                    if self.highlightedAnimal.setOutlineHighlight then
                        self.highlightedAnimal:setOutlineHighlight(playerNum, false)
                    end
                end
            end)
        end
        self.highlightedAnimal = nil
        self.selectedAnimal = nil
    end
    
    -- Don't start dragging if we were just resizing (prevents accidental drag after resize)
    if self.resizing then
        return true
    end
    
    -- Don't start dragging if clicking on close button area
    local closeBtnSize = 18
    local closeBtnX = self.width - closeBtnSize - PADDING
    local closeBtnY = PADDING
    if x >= closeBtnX and x <= closeBtnX + closeBtnSize and y >= closeBtnY and y <= closeBtnY + closeBtnSize then
        return true  -- Already handled close button above
    end
    
    -- Start dragging (allow dragging from anywhere except resize handle, scrollbar, close button, and animal entries)
    self.dragging = true
    return true
end

function DBD_NearbyAnimals:onMouseUp(x, y)
    if self.scrolling then
        self.scrolling = false
        self.scrollStartY = nil
        self.scrollStartScrollY = nil
        return true
    end
    
    if self.resizing then
        self.resizing = false
        self.resizeStartWidth = nil
        self.resizeStartHeight = nil
        self.resizeDeltaX = nil
        self.resizeDeltaY = nil
        return true
    end
    
    if self.dragging then
        self.dragging = false
        return true
    end
    
    return true
end

function DBD_NearbyAnimals:onMouseUpOutside(x, y)
    -- Stop all operations when mouse is released outside the box
    if self.scrolling then
        self.scrolling = false
        self.scrollStartY = nil
        self.scrollStartScrollY = nil
    end
    
    if self.resizing then
        self.resizing = false
        self.resizeStartWidth = nil
        self.resizeStartHeight = nil
        self.resizeDeltaX = nil
        self.resizeDeltaY = nil
    end
    
    if self.dragging then
        self.dragging = false
    end
    
    return true
end

function DBD_NearbyAnimals:onRightMouseUp(x, y)
    -- Check if right-clicking on an animal entry (anywhere in the entry box)
    -- Need to account for scroll offset when checking bounds
    local headerBottom = FONT_HGT_SMALL + PADDING * 2 + 1  -- Header + separator
    local startY = headerBottom + PADDING
    
    if self.animalEntryBounds then
        for _, entryBounds in ipairs(self.animalEntryBounds) do
            -- Entry bounds Y is stored with scroll offset applied
            -- Click Y is relative to panel (not scrolled)
            -- So we need to check if click Y matches the scrolled entry Y
            local entryScreenY = entryBounds.y  -- This is the scrolled Y position
            local entryScreenBottom = entryScreenY + entryBounds.height
            
            -- Check if click is within the entry bounds (using scrolled coordinates)
            if x >= entryBounds.x and x <= entryBounds.x + entryBounds.width and
               y >= entryScreenY and y <= entryScreenBottom then
                -- Found clicked animal entry, show context menu for this animal
                local animal = entryBounds.animal
                if animal then
                    -- Try to get the player
                    local player = getSpecificPlayer(0)
                    if player then
                        -- Convert screen coordinates to world coordinates for context menu
                        local screenX = self:getAbsoluteX() + x
                        local screenY = self:getAbsoluteY() + y
                        
                        -- Create context menu using the game's standard method
                        -- Use ISContextMenu.get() to create/get the context menu, then add animal options
                        local success, err = pcall(function()
                            -- Ensure AnimalContextMenu is loaded
                            if not AnimalContextMenu then
                                require "ISUI/Animal/ISAnimalContextMenu"
                            end
                            
                            local playerNum = player:getPlayerNum()
                            local context = ISContextMenu.get(playerNum, screenX, screenY)
                            
                            if context and AnimalContextMenu and AnimalContextMenu.doMenu then
                                -- Add animal menu to the context
                                AnimalContextMenu.doMenu(playerNum, context, animal, false)
                                return true
                            end
                            return false
                        end)
                        
                        if not success then
                            print("[DBD_NearbyAnimals] Failed to create animal context menu. Error: " .. tostring(err or "Unknown"))
                        end
                    end
                end
                return true  -- Handled the click
            end
        end
    end
    
    return false  -- Not handled, allow default behavior
end

function DBD_NearbyAnimals:onMouseMoveOutside(dx, dy)
    -- Continue scrolling/dragging/resizing even when mouse moves outside
    if self.scrolling and self.scrollStartY then
        -- Continue scrolling (handled in onMouseMove)
        return true
    end
    
    if self.resizing and self.resizeStartWidth then
        if not self.resizeDeltaX then self.resizeDeltaX = 0 end
        if not self.resizeDeltaY then self.resizeDeltaY = 0 end
        self.resizeDeltaX = self.resizeDeltaX + dx
        self.resizeDeltaY = self.resizeDeltaY + dy
        
        local newWidth = math.max(MIN_WIDTH, self.resizeStartWidth + self.resizeDeltaX)
        local newHeight = math.max(MIN_HEIGHT, self.resizeStartHeight + self.resizeDeltaY)
        self:setWidth(newWidth)
        self:setHeight(newHeight)
        return true
    end
    
    if self.dragging then
        self:setX(self:getX() + dx)
        self:setY(self:getY() + dy)
        return true
    end
    
    self.mouseOver = false
    return true
end

function DBD_NearbyAnimals:onMouseWheel(del)
    -- Only handle mouse wheel if panel is visible and mouse is over it
    if not self:isVisible() then
        return false
    end
    
    -- Check if mouse is over the panel
    local mouseX = self:getMouseX()
    local mouseY = self:getMouseY()
    if mouseX < 0 or mouseX > self.width or mouseY < 0 or mouseY > self.height then
        return false
    end
    
    -- Handle mouse wheel scrolling
    local titleHeight = FONT_HGT_SMALL + PADDING * 2
    local separatorHeight = 1
    local visibleTop = titleHeight + separatorHeight + PADDING
    local visibleBottom = self.height - PADDING
    local visibleHeight = visibleBottom - visibleTop
    
    -- Calculate total content height (reuse same calculation as render)
    local totalContentHeight = 0
    if #self.nearbyAnimals == 0 then
        totalContentHeight = FONT_HGT_SMALL + PADDING
    else
        for i, animal in ipairs(self.nearbyAnimals) do
            if animal and animal:getHealth() > 0 then
                local stillExists = animal:isExistInTheWorld() or animal:getHutch() or animal:getVehicle()
                if stillExists then
                    local estimatedHeight = (FONT_HGT_SMALL + STAT_SPACING) + (STAT_BAR_HEIGHT + STAT_SPACING) * 4 + 10
                    local entryHeight = math.max(ROW_HEIGHT, estimatedHeight)
                    totalContentHeight = totalContentHeight + entryHeight + PADDING
                end
            end
        end
    end
    
    local maxScroll = math.max(0, totalContentHeight - visibleHeight)
    if maxScroll > 0 then
        -- Scroll by a reasonable amount (3 rows worth, adjustable)
        -- del is negative when scrolling up, positive when scrolling down
        -- When scrolling up (negative del), we want to decrease scrollY to see content above
        local scrollAmount = 60 * del  -- Negative del = scroll up, positive = scroll down
        self.scrollY = math.max(0, math.min(maxScroll, (self.scrollY or 0) + scrollAmount))
        return true  -- Indicate we handled the scroll
    end
    
    return false
end

-- Settings system for configurable hotkey
local Settings = {}
Settings.hotkey = Keyboard.KEY_T  -- Default: T key
Settings.requireShift = false  -- Default: single key (no Shift required)

-- Load settings from ModData
local function loadSettings()
    -- Ensure Settings table exists
    if not Settings then
        Settings = {}
    end
    
    local player = getSpecificPlayer(0)
    if not player then 
        -- Set defaults if player not available
        Settings.hotkey = Settings.hotkey or Keyboard.KEY_T
        Settings.requireShift = Settings.requireShift ~= nil and Settings.requireShift or false
        return 
    end
    
    local modData = player:getModData()
    if not modData then 
        Settings.hotkey = Settings.hotkey or Keyboard.KEY_T
        Settings.requireShift = Settings.requireShift ~= nil and Settings.requireShift or false
        return 
    end
    
    if not modData.DBD_NearbyAnimals or type(modData.DBD_NearbyAnimals) ~= "table" then
        modData.DBD_NearbyAnimals = {}
    end
    
    local settings = modData.DBD_NearbyAnimals
    
    -- Load hotkey (default to T if not set)
    if settings.hotkey and type(settings.hotkey) == "number" then
        Settings.hotkey = settings.hotkey
    else
        Settings.hotkey = Settings.hotkey or Keyboard.KEY_T
    end
    
    -- Load shift requirement (default to false if not set)
    if settings.requireShift ~= nil then
        Settings.requireShift = settings.requireShift
    else
        Settings.requireShift = Settings.requireShift ~= nil and Settings.requireShift or false
    end
end

-- Save settings to ModData
local function saveSettings()
    -- Ensure Settings exists
    if not Settings then
        Settings = {}
        Settings.hotkey = Keyboard.KEY_T
        Settings.requireShift = false
    end
    
    local player = getSpecificPlayer(0)
    if not player then return end
    
    local modData = player:getModData()
    if not modData then return end
    
    if not modData.DBD_NearbyAnimals or type(modData.DBD_NearbyAnimals) ~= "table" then
        modData.DBD_NearbyAnimals = {}
    end
    
    local settings = modData.DBD_NearbyAnimals
    settings.hotkey = Settings.hotkey or Keyboard.KEY_T
    settings.requireShift = Settings.requireShift ~= nil and Settings.requireShift or false
    
    -- In multiplayer, transmit ModData changes to server
    if isClient() then
        pcall(function()
            if player.syncModData then
                player:syncModData()
            end
        end)
    end
end

-- Settings window class for configuring hotkey
DBD_NearbyAnimalsSettings = ISUIElement:derive("DBD_NearbyAnimalsSettings")

function DBD_NearbyAnimalsSettings:initialise()
    ISUIElement.initialise(self)
    local success, err = pcall(function()
        self:createChildren()
    end)
    if not success then
        print("[DBD_NearbyAnimals] Error in createChildren: " .. tostring(err or "Unknown"))
    end
end

function DBD_NearbyAnimalsSettings:createChildren()
    -- Ensure Settings is initialized and loaded
    if not Settings then
        Settings = {}
        Settings.hotkey = Keyboard.KEY_T
        Settings.requireShift = false
    end
    
    -- Load saved settings (with safety check)
    if type(loadSettings) == "function" then
        loadSettings()
    else
        -- Fallback: set defaults if loadSettings doesn't exist
        Settings.hotkey = Settings.hotkey or Keyboard.KEY_T
        Settings.requireShift = Settings.requireShift ~= nil and Settings.requireShift or false
    end
    
    -- Key selection label (with proper spacing from title bar)
    initFontHeights()
    local titleHeight = FONT_HGT_SMALL + PADDING * 2
    local separatorHeight = 1
    local keyLabelY = titleHeight + separatorHeight + PADDING + 5
    local keyLabel = ISLabel:new(PADDING, keyLabelY, 20, getText("IGUI_DBD_NearbyAnimals_ToggleKey"), 1, 1, 1, 1, UIFont.Small, true)
    keyLabel:initialise()
    self:addChild(keyLabel)
    
    -- Key display/input button (matching Nearby Animals style)
    local keyBtnWidth = 200
    local keyBtnX = PADDING
    local keyBtnY = keyLabelY + 20
    local keyBtn = ISButton:new(keyBtnX, keyBtnY, keyBtnWidth, 30, getText("IGUI_DBD_NearbyAnimals_PressKey"), self, function()
        -- This will be handled by key capture
        if self.keyBtn then
            self.keyBtn:setTitle(getText("IGUI_DBD_NearbyAnimals_PressKey"))
        end
        self.waitingForKey = true
    end)
    keyBtn:initialise()
    self.waitingForKey = false
    self.keyBtn = keyBtn  -- Store reference on self
    self:addChild(keyBtn)
    
    -- Update button text with current key
    local function updateKeyButtonText()
        -- Safety check for Settings
        if not Settings then
            Settings = {}
            Settings.hotkey = Keyboard.KEY_T
            Settings.requireShift = false
        end
        
        if not self.keyBtn then
            return  -- Button not ready yet
        end
        
        local keyName = getText("IGUI_DBD_NearbyAnimals_Unknown")
        if Settings.hotkey then
            -- Comprehensive key name mapping
            local keyNames = {
                -- Letters A-Z
                [Keyboard.KEY_A] = "A", [Keyboard.KEY_B] = "B", [Keyboard.KEY_C] = "C", [Keyboard.KEY_D] = "D",
                [Keyboard.KEY_E] = "E", [Keyboard.KEY_F] = "F", [Keyboard.KEY_G] = "G", [Keyboard.KEY_H] = "H",
                [Keyboard.KEY_I] = "I", [Keyboard.KEY_J] = "J", [Keyboard.KEY_K] = "K", [Keyboard.KEY_L] = "L",
                [Keyboard.KEY_M] = "M", [Keyboard.KEY_N] = "N", [Keyboard.KEY_O] = "O", [Keyboard.KEY_P] = "P",
                [Keyboard.KEY_Q] = "Q", [Keyboard.KEY_R] = "R", [Keyboard.KEY_S] = "S", [Keyboard.KEY_T] = "T",
                [Keyboard.KEY_U] = "U", [Keyboard.KEY_V] = "V", [Keyboard.KEY_W] = "W", [Keyboard.KEY_X] = "X",
                [Keyboard.KEY_Y] = "Y", [Keyboard.KEY_Z] = "Z",
                -- Numbers 0-9
                [Keyboard.KEY_0] = "0", [Keyboard.KEY_1] = "1", [Keyboard.KEY_2] = "2", [Keyboard.KEY_3] = "3",
                [Keyboard.KEY_4] = "4", [Keyboard.KEY_5] = "5", [Keyboard.KEY_6] = "6", [Keyboard.KEY_7] = "7",
                [Keyboard.KEY_8] = "8", [Keyboard.KEY_9] = "9",
                -- Function keys F1-F12
                [Keyboard.KEY_F1] = "F1", [Keyboard.KEY_F2] = "F2", [Keyboard.KEY_F3] = "F3", [Keyboard.KEY_F4] = "F4",
                [Keyboard.KEY_F5] = "F5", [Keyboard.KEY_F6] = "F6", [Keyboard.KEY_F7] = "F7", [Keyboard.KEY_F8] = "F8",
                [Keyboard.KEY_F9] = "F9", [Keyboard.KEY_F10] = "F10", [Keyboard.KEY_F11] = "F11", [Keyboard.KEY_F12] = "F12",
                -- Special keys
                [Keyboard.KEY_SPACE] = "Space",
                [Keyboard.KEY_ENTER] = "Enter",
                [Keyboard.KEY_ESCAPE] = "Esc",
                [Keyboard.KEY_TAB] = "Tab",
                [Keyboard.KEY_BACKSPACE] = "Backspace",
                [Keyboard.KEY_DELETE] = "Delete",
                [Keyboard.KEY_INSERT] = "Insert",
                [Keyboard.KEY_HOME] = "Home",
                [Keyboard.KEY_END] = "End",
                [Keyboard.KEY_PAGEUP] = "Page Up",
                [Keyboard.KEY_PAGEDOWN] = "Page Down",
                -- Arrow keys
                [Keyboard.KEY_UP] = "Up",
                [Keyboard.KEY_DOWN] = "Down",
                [Keyboard.KEY_LEFT] = "Left",
                [Keyboard.KEY_RIGHT] = "Right",
                -- Numpad
                [Keyboard.KEY_NUMPAD0] = "Numpad 0", [Keyboard.KEY_NUMPAD1] = "Numpad 1", [Keyboard.KEY_NUMPAD2] = "Numpad 2",
                [Keyboard.KEY_NUMPAD3] = "Numpad 3", [Keyboard.KEY_NUMPAD4] = "Numpad 4", [Keyboard.KEY_NUMPAD5] = "Numpad 5",
                [Keyboard.KEY_NUMPAD6] = "Numpad 6", [Keyboard.KEY_NUMPAD7] = "Numpad 7", [Keyboard.KEY_NUMPAD8] = "Numpad 8",
                [Keyboard.KEY_NUMPAD9] = "Numpad 9",
                [Keyboard.KEY_MULTIPLY] = "Numpad *",
                [Keyboard.KEY_ADD] = "Numpad +",
                [Keyboard.KEY_SUBTRACT] = "Numpad -",
                [Keyboard.KEY_DECIMAL] = "Numpad .",
                [Keyboard.KEY_DIVIDE] = "Numpad /",
                -- Other common keys
                [Keyboard.KEY_LBRACKET] = "[",
                [Keyboard.KEY_RBRACKET] = "]",
                [Keyboard.KEY_SEMICOLON] = ";",
                [Keyboard.KEY_APOSTROPHE] = "'",
                [Keyboard.KEY_BACKSLASH] = "\\",
                [Keyboard.KEY_COMMA] = ",",
                [Keyboard.KEY_PERIOD] = ".",
                [Keyboard.KEY_SLASH] = "/",
                [Keyboard.KEY_MINUS] = "-",
                [Keyboard.KEY_EQUALS] = "=",
            }
            keyName = keyNames[Settings.hotkey] or getText("IGUI_DBD_NearbyAnimals_Key") .. tostring(Settings.hotkey)
        end
        -- No shift prefix since we don't support shift modifier
        self.keyBtn:setTitle(keyName)
    end
    updateKeyButtonText()
    self.updateKeyButtonText = updateKeyButtonText
    
    -- Shift requirement is always false (removed UI for it)
    Settings.requireShift = false
end

function DBD_NearbyAnimalsSettings:prerender()
    ISUIElement.prerender(self)
    initFontHeights()
    
    -- Match Nearby Animals panel design
    self:drawRect(0, 0, self.width, self.height, 0.8, 0.1, 0.1, 0.1)
    self:drawRectBorder(0, 0, self.width, self.height, 0.5, 0.4, 0.4, 0.4)
    
    -- Draw title (matching Nearby Animals style)
    self:drawText(getText("IGUI_DBD_NearbyAnimals_SettingsTitle"), PADDING, PADDING + 2, 1, 1, 1, 1, UIFont.Small)
    
    -- Draw close X button in top right corner (matching Nearby Animals style)
    local closeBtnSize = 18
    local closeBtnX = self.width - closeBtnSize - PADDING
    local closeBtnY = PADDING
    self:drawRect(closeBtnX, closeBtnY, closeBtnSize, closeBtnSize, 1.0, 0.2, 0.2, 0.2)
    self:drawRectBorder(closeBtnX, closeBtnY, closeBtnSize, closeBtnSize, 0.8, 0.8, 0.2, 0.2)
    self:drawText("X", closeBtnX + 5, closeBtnY + 2, 1, 1, 1, 1, UIFont.Small)
    
    -- Draw separator line (matching Nearby Animals style)
    local titleHeight = FONT_HGT_SMALL + PADDING * 2
    self:drawRect(PADDING, titleHeight, self.width - PADDING * 2, 1, 1.0, 0.4, 0.4, 0.4)
end

function DBD_NearbyAnimalsSettings:onMouseDown(x, y)
    -- Safety check
    if not self or not x or not y then
        return false
    end
    
    initFontHeights()
    
    -- Check if clicking on close X button (matching Nearby Animals style)
    local closeBtnSize = 18
    local closeBtnX = self.width - closeBtnSize - PADDING
    local closeBtnY = PADDING
    if x >= closeBtnX and x <= closeBtnX + closeBtnSize and y >= closeBtnY and y <= closeBtnY + closeBtnSize then
        self:close()
        getSoundManager():playUISound("UIToggle")
        return true
    end
    
    -- Check if clicking in title bar area for dragging (but not on close button)
    local titleHeight = FONT_HGT_SMALL + PADDING * 2
    if y <= titleHeight and not (x >= closeBtnX and x <= closeBtnX + closeBtnSize) then
        -- Start dragging
        self.dragging = true
        return true
    end
    
    -- Let child elements handle their own clicks
    local handled = false
    if self.children then
        for _, child in ipairs(self.children) do
            if child and child.onMouseDown then
                local childX = x - child:getX()
                local childY = y - child:getY()
                if childX >= 0 and childX <= child:getWidth() and childY >= 0 and childY <= child:getHeight() then
                    handled = child:onMouseDown(childX, childY)
                    if handled then
                        return true
                    end
                end
            end
        end
    end
    
    -- If not handled by children, allow default behavior
    return false
end

function DBD_NearbyAnimalsSettings:onMouseMove(dx, dy)
    -- Handle dragging
    if self.dragging then
        self:setX(self:getX() + dx)
        self:setY(self:getY() + dy)
        return true
    end
    
    -- Let child elements handle mouse move
    if self.children then
        for _, child in ipairs(self.children) do
            if child and child.onMouseMove then
                child:onMouseMove(dx, dy)
            end
        end
    end
    
    return false
end

function DBD_NearbyAnimalsSettings:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        return true
    end
    
    -- Let child elements handle mouse up
    if self.children then
        for _, child in ipairs(self.children) do
            if child and child.onMouseUp then
                local childX = x - child:getX()
                local childY = y - child:getY()
                if childX >= 0 and childX <= child:getWidth() and childY >= 0 and childY <= child:getHeight() then
                    if child:onMouseUp(childX, childY) then
                        return true
                    end
                end
            end
        end
    end
    
    return false
end

function DBD_NearbyAnimalsSettings:onMouseUpOutside(x, y)
    if self.dragging then
        self.dragging = false
    end
    
    -- Let child elements handle mouse up outside
    if self.children then
        for _, child in ipairs(self.children) do
            if child and child.onMouseUpOutside then
                child:onMouseUpOutside(x, y)
            end
        end
    end
    
    return false
end

function DBD_NearbyAnimalsSettings:close()
    -- Settings are auto-saved, so no need to reload
    if self.parentUI then
        self.parentUI.settingsWindow = nil
    end
    self:removeFromUIManager()
end

function DBD_NearbyAnimalsSettings:new(x, y, width, height)
    local o = ISUIElement.new(self, x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    -- Match Nearby Animals panel style
    o.backgroundColor = {r=0, g=0, b=0, a=0}
    o.borderColor = {r=0.4, g=0.4, b=0.4, a=0.5}
    o.moveWithMouse = false  -- We'll handle dragging manually
    o.dragging = false
    return o
end

-- Settings window instance
DBD_NearbyAnimals.settingsWindow = nil

function DBD_NearbyAnimals:openSettingsWindow()
    -- Close existing settings window if open
    if DBD_NearbyAnimals.settingsWindow then
        DBD_NearbyAnimals.settingsWindow:removeFromUIManager()
        DBD_NearbyAnimals.settingsWindow = nil
        return
    end
    
    -- Match Nearby Animals panel width
    local windowWidth = DEFAULT_WIDTH
    local windowHeight = 120  -- Compact height since no buttons needed
    
    -- Position settings window below the Nearby Animals panel
    local animalsInstance = DBD_NearbyAnimals.instance
    local windowX = animalsInstance:getX()  -- Align with Nearby Animals panel
    local windowY = animalsInstance:getY() + animalsInstance:getHeight() + 5  -- 5px gap below
    
    -- Make sure window stays on screen
    local screenWidth = getCore():getScreenWidth()
    local screenHeight = getCore():getScreenHeight()
    if windowY + windowHeight > screenHeight then
        -- If it would go off bottom, position it above instead
        windowY = animalsInstance:getY() - windowHeight - 5
    end
    if windowY < 0 then windowY = 5 end
    if windowX + windowWidth > screenWidth then
        windowX = screenWidth - windowWidth - 5
    end
    if windowX < 0 then windowX = 5 end
    
    -- Create settings window
    local window = DBD_NearbyAnimalsSettings:new(windowX, windowY, windowWidth, windowHeight)
    window.parentUI = self
    window:initialise()
    
    -- Store reference
    DBD_NearbyAnimals.settingsWindow = window
    
    window:addToUIManager()
    window:setVisible(true)
    window:bringToTop()
end

-- Initialize the mod
local initAttempts = 0
local function initDBD_NearbyAnimals()
    initAttempts = initAttempts + 1
    
    local player = getSpecificPlayer(0)
    if not player then
        if initAttempts < 20 then
            return
        end
    end
    
    if DBD_NearbyAnimals.instance then
        DBD_NearbyAnimals.instance:removeFromUIManager()
    end
    
    -- Position in top-right corner
    local screenWidth = getCore():getScreenWidth()
    local startX = screenWidth - DEFAULT_WIDTH - 20
    local startY = 100
    
    DBD_NearbyAnimals.instance = DBD_NearbyAnimals:new(startX, startY)
    DBD_NearbyAnimals.instance:initialise()
    DBD_NearbyAnimals.instance:addToUIManager()
    DBD_NearbyAnimals.instance:setVisible(true)
    
    -- Load settings after initialization
    loadSettings()
    
    print("[DBD_NearbyAnimals] Initialized")
end

-- Hook into game start
Events.OnGameStart.Add(initDBD_NearbyAnimals)

-- Also try on every tick until we succeed (for multiplayer)
local initTickHandler = nil
initTickHandler = function()
    if DBD_NearbyAnimals.instance then
        -- Already initialized, remove this handler
        Events.OnTick.Remove(initTickHandler)
        return
    end
    
    local player = getSpecificPlayer(0)
    if player then
        -- Player is ready, try to initialize
        initDBD_NearbyAnimals()
        if DBD_NearbyAnimals.instance then
            -- Success, remove handler
            Events.OnTick.Remove(initTickHandler)
        end
    end
end
Events.OnTick.Add(initTickHandler)

-- Toggle function for showing/hiding the Nearby Animals panel
local function toggleNearbyAnimalsPanel()
    -- Don't run if not in-game (prevents errors when returning to main menu)
    if not isIngameState() then
        return
    end
    
    local animalsInstance = DBD_NearbyAnimals.instance
    if not animalsInstance then
        return
    end
    
    -- Toggle visibility
    local isVisible = animalsInstance:isVisible()
    if not isVisible then
        -- Panel is hidden, make sure it's in the UI manager and visible
        if not animalsInstance:getIsVisible() then
            animalsInstance:addToUIManager()
        end
        animalsInstance:setVisible(true)
    else
        -- Panel is visible, hide it
        animalsInstance:setVisible(false)
    end
    getSoundManager():playUISound("UIToggle")
end

-- Handle key press to toggle the panel
local keyPressHandler = function(key)
    -- Ensure Settings is initialized
    if not Settings then
        Settings = {}
        Settings.hotkey = Keyboard.KEY_T
        Settings.requireShift = false
    end
    
    -- Check if settings window is open and waiting for key
    if DBD_NearbyAnimals.settingsWindow and DBD_NearbyAnimals.settingsWindow.waitingForKey then
        -- Filter out mouse buttons and invalid keys
        -- Mouse buttons: 10000 (left), 10001 (right), and other high values
        -- Also filter out ESC, ENTER, and modifier keys
        if key ~= Keyboard.KEY_ESCAPE and key ~= Keyboard.KEY_ENTER and 
           key ~= Keyboard.KEY_LSHIFT and key ~= Keyboard.KEY_RSHIFT and
           key ~= Keyboard.KEY_LCONTROL and key ~= Keyboard.KEY_RCONTROL and
           key ~= Keyboard.KEY_LMENU and key ~= Keyboard.KEY_RMENU and
           key < 10000 then  -- Filter out mouse button codes (10000+)
            if not Settings then
                Settings = {}
            end
            Settings.hotkey = key
            DBD_NearbyAnimals.settingsWindow.waitingForKey = false
            -- Update button text
            if DBD_NearbyAnimals.settingsWindow.updateKeyButtonText then
                DBD_NearbyAnimals.settingsWindow.updateKeyButtonText()
            end
            -- Auto-save when key is changed
            saveSettings()
            getSoundManager():playUISound("UIToggle")
        end
        return
    end
    
    -- Handle ESC to close settings window
    if key == Keyboard.KEY_ESCAPE and DBD_NearbyAnimals.settingsWindow then
        DBD_NearbyAnimals.settingsWindow:close()
        DBD_NearbyAnimals.settingsWindow = nil
        return
    end
    
    -- Load settings if not already loaded (for first time)
    if not Settings.hotkey then
        loadSettings()
    end
    
    -- Safety check
    if not Settings or not Settings.hotkey then
        return
    end
    
    -- Check if the pressed key matches our hotkey (no shift required)
    if key == Settings.hotkey then
        -- Only toggle if we're in-game
        if isIngameState() then
            local player = getSpecificPlayer(0)
            if player then
                -- Toggle the panel (wrapped in pcall to prevent errors)
                local success, err = pcall(function()
                    toggleNearbyAnimalsPanel()
                end)
                if not success then
                    print("[DBD_NearbyAnimals] Error toggling panel: " .. tostring(err or "Unknown"))
                end
            end
        end
    end
end

Events.OnKeyPressed.Add(keyPressHandler)

-- Load settings when player is created
Events.OnCreatePlayer.Add(function(playerNum)
    if playerNum == 0 then
        -- Wait a bit for player data to be ready
        local attempts = 0
        local loadSettingsHandler = function()
            attempts = attempts + 1
            if attempts > 20 then
                Events.OnTick.Remove(loadSettingsHandler)
                return
            end
            
            local player = getSpecificPlayer(0)
            if player then
                loadSettings()
                Events.OnTick.Remove(loadSettingsHandler)
            end
        end
        Events.OnTick.Add(loadSettingsHandler)
    end
end)
