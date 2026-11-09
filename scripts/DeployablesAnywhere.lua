-- Deployables Anywhere
-- Place buildings, decorations, fences and trees where the game says "cannot be placed here".
-- Free placement is off by default. In construction mode a key combination (Ctrl+Shift+P) turns it on for the
-- placing tools; it turns itself off again when the construction screen closes.
-- While it is on, the location checks of the placing brushes are skipped: land ownership, overlap with objects,
-- restricted/store/spawn areas and water, the placeable's own "can be placed here" check and blocked terrain leveling.
-- The cursor names the checks that are skipped. Money, slots, build permission and "cannot be bought" are still checked.
-- The server does not repeat the location checks when buying a placeable or a fence segment, so this is client side.
-- For buildings and decorations there is also: placing without flattening the ground (Ctrl+Shift+G), and fine
-- adjustment: nudge, raise/lower and rotate in small steps (Ctrl+Shift + arrows, PageUp/PageDown, comma/period).
-- Selling your farm's items with the sell brush always works, also on land you do not own; no key needed.
-- Removed fence segments and panels are refunded at the price they cost to build.

DeployablesAnywhere = {}
DeployablesAnywhere.MOD_NAME = g_currentModName
-- How long a placement without terrain leveling stays armed after the click, in ms
DeployablesAnywhere.SKIP_LEVELING_TIMEOUT = 10000

-- Fine adjustment steps, and the key repeat while a key is held (ms)
DeployablesAnywhere.NUDGE_STEP = 0.1
DeployablesAnywhere.HEIGHT_STEP = 0.05
DeployablesAnywhere.ROTATION_STEP = math.rad(1)
DeployablesAnywhere.REPEAT_DELAY = 350
DeployablesAnywhere.REPEAT_INTERVAL = 50
-- A held key calls back every frame; a longer gap means it was released
DeployablesAnywhere.RELEASE_GAP = 150

-- Free placement (all placing brushes) and placing without flattening (placeable brushes), both off on close
DeployablesAnywhere.isEnabled = false
DeployablesAnywhere.isNoLeveling = false
-- Fine adjustment of placeable brushes: offsets added to the snapped position/rotation, and the cursor position the
-- item is locked to after the first nudge
DeployablesAnywhere.adjust = {x = 0, y = 0, z = 0, rotY = 0, lock = nil}
-- Action name -> event id of the keys registered for the current brush
DeployablesAnywhere.eventIds = {}
-- Action name -> {lastCall, nextRepeat} of held axis keys
DeployablesAnywhere.axisStates = {}
-- g_time until which the next placeable bought is placed without terrain leveling
DeployablesAnywhere.skipLevelingUntil = nil
-- True while verifyPlacement runs once unchanged to learn which check fails
DeployablesAnywhere.isProbing = false

-- Brush classes whose location checks free placement skips (looked up by name, some may not exist)
DeployablesAnywhere.BRUSH_CLASS_NAMES = {"ConstructionBrushPlaceable", "ConstructionBrushNewFence", "ConstructionBrushFence", "ConstructionBrushTree"}
-- Brush classes that place a placeable; subclasses are wrapped too when they define the functions themselves
DeployablesAnywhere.PLACEABLE_BRUSH_CLASS_NAMES = {"ConstructionBrushPlaceable", "ConstructionBrushHusbandry"}

-- Error names that are not about the location and stay enforced
DeployablesAnywhere.KEPT_ERROR_PATTERNS = {"MONEY", "SLOT", "PERMISSION", "BOUGHT", "LIMIT"}

-- Placeable functions that check the location, replaced on the brush's preview placeable while it is verified
DeployablesAnywhere.PLACEABLE_STUBS = {
    getCanBePlacedAt = function() return true, nil end,
    getHasOverlap = function() return false, nil end,
    getHasOverlapWithZones = function() return false end,
    getHasOverlapWithPlaces = function() return false end,
    getIsOnOwnedFarmland = function() return true end,
    getIsAreaOwnedByFarm = function() return true end,
    getCanBePlacedInWater = function() return true end,
    getIsAreaBlocked = function() return false end,
    getHasOverlapWithDensityHeight = function() return false end
}

-- Keys: action name, which brushes get it, callback, and the help text (toggles: text for off/on)
DeployablesAnywhere.ACTIONS = {
    {name = "DA_TOGGLE_FREE_PLACEMENT", forAllPlacing = true, callback = "onToggleFreePlacement", textOff = "da_freePlacementOff", textOn = "da_freePlacementOn"},
    {name = "DA_TOGGLE_NO_LEVELING", callback = "onToggleNoLeveling", textOff = "da_noLevelingOff", textOn = "da_noLevelingOn"},
    {name = "DA_AXIS_NUDGE_FORWARD", isAxis = true, callback = "onAxisNudgeForward", text = "da_nudgeForward"},
    {name = "DA_AXIS_NUDGE_SIDE", isAxis = true, callback = "onAxisNudgeSide", text = "da_nudgeSide"},
    {name = "DA_AXIS_HEIGHT", isAxis = true, callback = "onAxisHeight", text = "da_height"},
    {name = "DA_AXIS_ROTATE", isAxis = true, callback = "onAxisRotate", text = "da_rotate"},
    {name = "DA_RESET_ADJUST", callback = "onResetAdjust", text = "da_resetAdjust"}
}

local function packResults(...)
    return select("#", ...), {...}
end

local function wrap(class, functionName, func)
    if class ~= nil and type(class[functionName]) == "function" then
        class[functionName] = Utils.overwrittenFunction(class[functionName], func)
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------

function DeployablesAnywhere.isInstanceOf(object, classObject)
    if type(object) ~= "table" or classObject == nil then
        return false
    end
    if type(object.isa) == "function" then
        local ok, result = pcall(object.isa, object, classObject)
        if ok then
            return result == true
        end
    end
    -- Class() instances: metatable.__index is the class, whose metatable.__index is the super class
    local mt = getmetatable(object)
    local class = mt ~= nil and mt.__index or nil
    while type(class) == "table" do
        if class == classObject then
            return true
        end
        local classMt = getmetatable(class)
        class = classMt ~= nil and classMt.__index or nil
    end
    return false
end

function DeployablesAnywhere.isPlacingBrush(brush)
    for _, className in ipairs(DeployablesAnywhere.BRUSH_CLASS_NAMES) do
        if DeployablesAnywhere.isInstanceOf(brush, _G[className]) then
            return true
        end
    end
    return false
end

function DeployablesAnywhere.isPlaceableBrush(brush)
    return DeployablesAnywhere.isInstanceOf(brush, ConstructionBrushPlaceable)
end

function DeployablesAnywhere.isActiveFor(brush)
    return DeployablesAnywhere.isEnabled and DeployablesAnywhere.isPlacingBrush(brush)
end

function DeployablesAnywhere.isNoLevelingFor(brush)
    return DeployablesAnywhere.isNoLeveling and DeployablesAnywhere.isPlaceableBrush(brush)
end

-- Raised or lowered items are placed without leveling: leveling realigns the item to the terrain
function DeployablesAnywhere.isSkippingLevelingFor(brush)
    return DeployablesAnywhere.isNoLevelingFor(brush)
        or (DeployablesAnywhere.adjust.y ~= 0 and DeployablesAnywhere.isPlaceableBrush(brush))
end

-- Error codes by number -> name, from the brush error tables, to tell location errors from the others
function DeployablesAnywhere.getErrorName(errorCode)
    for _, className in ipairs({"ConstructionBrushPlaceable", "ConstructionBrushNewFence", "ConstructionBrush"}) do
        local class = _G[className]
        if class ~= nil and type(class.ERROR) == "table" then
            for name, code in pairs(class.ERROR) do
                if code == errorCode then
                    return name
                end
            end
        end
    end
    return nil
end

-- The text the game shows for an error code
function DeployablesAnywhere.getErrorText(errorCode)
    for _, className in ipairs({"ConstructionBrushPlaceable", "ConstructionBrushNewFence", "ConstructionBrush"}) do
        local class = _G[className]
        local key = class ~= nil and type(class.ERROR_MESSAGES) == "table" and class.ERROR_MESSAGES[errorCode] or nil
        if key ~= nil then
            return g_i18n:getText(key)
        end
    end
    return nil
end

function DeployablesAnywhere.isBypassableError(errorCode)
    if errorCode == nil then
        return false
    end
    local name = DeployablesAnywhere.getErrorName(errorCode)
    if name == nil then
        -- Unknown codes are left alone
        return false
    end
    for _, pattern in ipairs(DeployablesAnywhere.KEPT_ERROR_PATTERNS) do
        if string.find(name, pattern, 1, true) ~= nil then
            return false
        end
    end
    return true
end

function DeployablesAnywhere.setEnabled(isEnabled)
    DeployablesAnywhere.isEnabled = isEnabled
    DeployablesAnywhere.updateActionEventTexts()
end

function DeployablesAnywhere.setNoLeveling(isNoLeveling)
    DeployablesAnywhere.isNoLeveling = isNoLeveling
    DeployablesAnywhere.updateActionEventTexts()
end

function DeployablesAnywhere.resetAdjustments()
    DeployablesAnywhere.adjust = {x = 0, y = 0, z = 0, rotY = 0, lock = nil}
    DeployablesAnywhere.axisStates = {}
end

-- ---------------------------------------------------------------------------------------------
-- Keys: registered with the brush keys of the construction screen
-- ---------------------------------------------------------------------------------------------

function DeployablesAnywhere.updateActionEventTexts()
    if g_inputBinding == nil then
        return
    end
    for _, action in ipairs(DeployablesAnywhere.ACTIONS) do
        local eventId = DeployablesAnywhere.eventIds[action.name]
        if eventId ~= nil then
            local key = action.text
            if key == nil then
                local isOn = (action.name == "DA_TOGGLE_FREE_PLACEMENT" and DeployablesAnywhere.isEnabled)
                    or (action.name == "DA_TOGGLE_NO_LEVELING" and DeployablesAnywhere.isNoLeveling)
                key = isOn and action.textOn or action.textOff
            end
            g_inputBinding:setActionEventText(eventId, g_i18n:getText(key))
        end
    end
end

function DeployablesAnywhere.onToggleFreePlacement()
    DeployablesAnywhere.setEnabled(not DeployablesAnywhere.isEnabled)
end

function DeployablesAnywhere.onToggleNoLeveling()
    DeployablesAnywhere.setNoLeveling(not DeployablesAnywhere.isNoLeveling)
end

function DeployablesAnywhere.onResetAdjust()
    DeployablesAnywhere.resetAdjustments()
end

-- Returns the steps to apply for a held axis key: one on press, then repeats after a delay
function DeployablesAnywhere.getAxisSteps(actionName, inputValue)
    local states = DeployablesAnywhere.axisStates
    if inputValue == nil or inputValue == 0 then
        states[actionName] = nil
        return 0
    end
    local direction = inputValue > 0 and 1 or -1
    local state = states[actionName]
    if state == nil or g_time - state.lastCall > DeployablesAnywhere.RELEASE_GAP then
        states[actionName] = {lastCall = g_time, nextRepeat = g_time + DeployablesAnywhere.REPEAT_DELAY}
        return direction
    end
    state.lastCall = g_time
    if g_time >= state.nextRepeat then
        state.nextRepeat = g_time + DeployablesAnywhere.REPEAT_INTERVAL
        return direction
    end
    return 0
end

-- Ground directions of the camera: forward (away from the camera) and right
function DeployablesAnywhere.getCameraGroundDirections()
    local camera = getCamera()
    local fx, _, fz = localDirectionToWorld(camera, 0, 0, -1)
    if fx * fx + fz * fz < 0.01 then
        -- Looking straight down: the top of the screen is forward
        fx, _, fz = localDirectionToWorld(camera, 0, 1, 0)
    end
    local length = math.sqrt(fx * fx + fz * fz)
    if length < 0.0001 then
        return 0, -1, 1, 0
    end
    fx, fz = fx / length, fz / length
    -- Right of forward, seen from above
    return fx, fz, -fz, fx
end

function DeployablesAnywhere.nudge(forwardSteps, rightSteps)
    local brush = g_constructionScreen ~= nil and g_constructionScreen.brush or nil
    local adjust = DeployablesAnywhere.adjust
    if adjust.lock == nil and brush ~= nil and brush.cursor ~= nil then
        -- The first nudge locks the item where the cursor is, so the mouse no longer moves it
        local x, y, z = brush.cursor:getPosition()
        if x ~= nil then
            adjust.lock = {x = x, y = y, z = z}
        end
    end
    local fx, fz, rx, rz = DeployablesAnywhere.getCameraGroundDirections()
    local step = DeployablesAnywhere.NUDGE_STEP
    adjust.x = adjust.x + (fx * forwardSteps + rx * rightSteps) * step
    adjust.z = adjust.z + (fz * forwardSteps + rz * rightSteps) * step
end

function DeployablesAnywhere.onAxisNudgeForward(_, actionName, inputValue)
    local steps = DeployablesAnywhere.getAxisSteps(actionName, inputValue)
    if steps ~= 0 then
        DeployablesAnywhere.nudge(steps, 0)
    end
end

function DeployablesAnywhere.onAxisNudgeSide(_, actionName, inputValue)
    local steps = DeployablesAnywhere.getAxisSteps(actionName, inputValue)
    if steps ~= 0 then
        DeployablesAnywhere.nudge(0, steps)
    end
end

function DeployablesAnywhere.onAxisHeight(_, actionName, inputValue)
    local steps = DeployablesAnywhere.getAxisSteps(actionName, inputValue)
    local adjust = DeployablesAnywhere.adjust
    adjust.y = adjust.y + steps * DeployablesAnywhere.HEIGHT_STEP
    if math.abs(adjust.y) < 0.001 then
        adjust.y = 0
    end
end

function DeployablesAnywhere.onAxisRotate(_, actionName, inputValue)
    local steps = DeployablesAnywhere.getAxisSteps(actionName, inputValue)
    DeployablesAnywhere.adjust.rotY = DeployablesAnywhere.adjust.rotY + steps * DeployablesAnywhere.ROTATION_STEP
end

function DeployablesAnywhere.registerActionEvents(screen)
    DeployablesAnywhere.eventIds = {}
    if screen.brushEvents == nil or not DeployablesAnywhere.isPlacingBrush(screen.brush) then
        return
    end
    local isPlaceableBrush = DeployablesAnywhere.isPlaceableBrush(screen.brush)

    for _, action in ipairs(DeployablesAnywhere.ACTIONS) do
        local inputAction = InputAction[action.name]
        if inputAction ~= nil and (action.forAllPlacing or isPlaceableBrush) then
            -- Axis keys are called every frame while held, for the key repeat
            local _, eventId = g_inputBinding:registerActionEvent(inputAction, DeployablesAnywhere, DeployablesAnywhere[action.callback],
                false, true, action.isAxis == true, true)
            if eventId ~= nil then
                -- Removed by ConstructionScreen:removeBrushActionEvents with the other brush keys
                table.insert(screen.brushEvents, eventId)
                g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_HIGH)
                DeployablesAnywhere.eventIds[action.name] = eventId
            end
        end
    end
    DeployablesAnywhere.updateActionEventTexts()
end

-- ---------------------------------------------------------------------------------------------
-- Brush hooks: free placement
-- ---------------------------------------------------------------------------------------------

-- Land ownership and restricted/store/spawn areas of the cursor position, used by every brush
function DeployablesAnywhere.verifyAccess(brush, superFunc, ...)
    local count, results = packResults(superFunc(brush, ...))
    if results[1] ~= nil and not DeployablesAnywhere.isProbing
        and (DeployablesAnywhere.isActiveFor(brush) or DeployablesAnywhere.isSelling())
        and DeployablesAnywhere.isBypassableError(results[1]) then
        return nil
    end
    return unpack(results, 1, count)
end

-- Calls func with the location checks of the placeable replaced, restoring them even if func fails
function DeployablesAnywhere.callWithPlaceableStubs(placeable, func, ...)
    if type(placeable) ~= "table" then
        return func(...)
    end

    local saved = {}
    for name, stub in pairs(DeployablesAnywhere.PLACEABLE_STUBS) do
        if placeable[name] ~= nil then
            saved[name] = {value = rawget(placeable, name)}
            placeable[name] = stub
        end
    end

    local count, results = packResults(pcall(func, ...))

    for name, entry in pairs(saved) do
        rawset(placeable, name, entry.value)
    end

    if not results[1] then
        error(results[2], 0)
    end
    return unpack(results, 2, count)
end

function DeployablesAnywhere.hasEnoughMoneyAndSlots(brush)
    if type(brush.getPrice) == "function" and g_currentMission:getMoney() < brush:getPrice() then
        return false, ConstructionBrushPlaceable.ERROR.NOT_ENOUGH_MONEY
    end
    local slotSystem = g_currentMission.slotSystem
    if slotSystem ~= nil and brush.storeItem ~= nil and not slotSystem:hasEnoughSlots(brush.storeItem) then
        return false, ConstructionBrushPlaceable.ERROR.NOT_ENOUGH_SLOTS
    end
    return true, nil
end

function DeployablesAnywhere.verifyPlacement(brush, superFunc, ...)
    if not DeployablesAnywhere.isActiveFor(brush) then
        return superFunc(brush, ...)
    end

    -- First unchanged, to learn which check fails (shown at the cursor); most of the time nothing fails
    DeployablesAnywhere.isProbing = true
    local probeCount, probe = packResults(pcall(superFunc, brush, ...))
    DeployablesAnywhere.isProbing = false
    if not probe[1] then
        error(probe[2], 0)
    end
    local probeError = probe[2]
    if probeError == nil or not DeployablesAnywhere.isBypassableError(probeError) then
        brush.daSkippedReason = nil
        return unpack(probe, 2, probeCount)
    end
    brush.daSkippedReason = probe[3] or DeployablesAnywhere.getErrorText(probeError) or DeployablesAnywhere.getErrorName(probeError)

    local count, results = packResults(DeployablesAnywhere.callWithPlaceableStubs(brush.placeable, superFunc, brush, ...))
    local errorCode = results[1]
    if errorCode ~= nil and DeployablesAnywhere.isBypassableError(errorCode) then
        -- A location error may have returned before the money and slot checks ran
        local isOk, keptError = DeployablesAnywhere.hasEnoughMoneyAndSlots(brush)
        if not isOk then
            return keptError
        end
        return nil
    end
    return unpack(results, 1, count)
end

-- Calls func with the brush's terrain leveling error hidden; returns whether there was one
function DeployablesAnywhere.callWithoutLevelingError(brush, func, ...)
    local levelingError = brush.displacementError
    if levelingError == nil then
        return false, func(brush, ...)
    end

    brush.displacementError = nil
    local count, results = packResults(pcall(func, brush, ...))
    if brush.displacementError == nil then
        brush.displacementError = levelingError
    end

    if not results[1] then
        error(results[2], 0)
    end
    return true, unpack(results, 2, count)
end

-- The notes after the price at the cursor: skipped checks, no flattening, height and rotation adjustment.
-- levelingError: the brush's leveling error, hidden from the brush while it updates
function DeployablesAnywhere.getCursorNotes(brush, levelingError)
    local notes = {}
    if DeployablesAnywhere.isActiveFor(brush) then
        local reasons = {}
        if brush.daSkippedReason ~= nil then
            table.insert(reasons, brush.daSkippedReason)
        end
        if levelingError ~= nil and not DeployablesAnywhere.isSkippingLevelingFor(brush) then
            table.insert(reasons, DeployablesAnywhere.getErrorText(levelingError) or DeployablesAnywhere.getErrorName(levelingError))
        end
        if #reasons > 0 then
            table.insert(notes, g_i18n:getText("da_noteFree") .. ": " .. table.concat(reasons, "; "))
        else
            table.insert(notes, g_i18n:getText("da_noteFree"))
        end
    end
    if DeployablesAnywhere.isSkippingLevelingFor(brush) then
        table.insert(notes, g_i18n:getText("da_noteNoLeveling"))
    end
    if DeployablesAnywhere.isPlaceableBrush(brush) then
        local adjust = DeployablesAnywhere.adjust
        if adjust.lock ~= nil then
            table.insert(notes, g_i18n:getText("da_noteLocked"))
        end
        if adjust.y ~= 0 then
            table.insert(notes, string.format(g_i18n:getText("da_noteHeight"), string.format("%+.2f", adjust.y)))
        end
        local degrees = math.floor(math.deg(adjust.rotY) + 0.5)
        if degrees ~= 0 then
            table.insert(notes, string.format(g_i18n:getText("da_noteRotation"), string.format("%+d", degrees)))
        end
    end
    return notes
end

function DeployablesAnywhere.updatePlaceablePosition(brush, superFunc, ...)
    if brush.cursor == nil then
        return superFunc(brush, ...)
    end
    local hidesLevelingError = DeployablesAnywhere.isActiveFor(brush) or DeployablesAnywhere.isSkippingLevelingFor(brush)
    local levelingError = brush.displacementError

    local cursor = brush.cursor
    local setMessage = cursor.setMessage
    cursor.setMessage = function(self, message, ...)
        local notes = DeployablesAnywhere.getCursorNotes(brush, levelingError)
        if type(message) == "string" and #notes > 0 then
            message = message .. " (" .. table.concat(notes, ", ") .. ")"
        end
        return setMessage(self, message, ...)
    end

    local count, results
    if hidesLevelingError then
        count, results = packResults(pcall(DeployablesAnywhere.callWithoutLevelingError, brush, superFunc, ...))
        if results[1] then
            table.remove(results, 2)
            count = count - 1
        end
    else
        count, results = packResults(pcall(superFunc, brush, ...))
    end
    cursor.setMessage = setMessage

    if not results[1] then
        error(results[2], 0)
    end
    return unpack(results, 2, count)
end

function DeployablesAnywhere.onButtonPrimary(brush, superFunc, ...)
    if brush.placeable == nil then
        return superFunc(brush, ...)
    end
    local isFree = DeployablesAnywhere.isActiveFor(brush)
    local isSkippingLeveling = DeployablesAnywhere.isSkippingLevelingFor(brush)
    if not isFree and not isSkippingLeveling then
        return superFunc(brush, ...)
    end

    -- No flattening wanted, or leveling is blocked here (the server would refuse the placeable): buy without leveling
    if isSkippingLeveling or brush.displacementError ~= nil then
        DeployablesAnywhere.skipLevelingUntil = g_time + DeployablesAnywhere.SKIP_LEVELING_TIMEOUT
    end
    local count, results = packResults(pcall(DeployablesAnywhere.callWithoutLevelingError, brush, superFunc, ...))
    if not results[1] then
        DeployablesAnywhere.skipLevelingUntil = nil
        error(results[2], 0)
    end
    return unpack(results, 3, count)
end

-- Leveling costs nothing when the ground is not flattened
function DeployablesAnywhere.getDisplacementCost(brush, superFunc, ...)
    if DeployablesAnywhere.isSkippingLevelingFor(brush) then
        return 0
    end
    return superFunc(brush, ...)
end

-- Fence segments: one check for the whole segment (land along the line, overlaps, angles, money)
function DeployablesAnywhere.validateCurrentSegment(brush, superFunc, ...)
    local cursor = brush.cursor
    if not DeployablesAnywhere.isActiveFor(brush) or cursor == nil then
        return superFunc(brush, ...)
    end

    -- The cursor draws error messages right away, so the ones of the check are held back until it is known
    -- whether the segment is allowed anyway
    local setErrorMessage = cursor.setErrorMessage
    local errorMessages = {}
    cursor.setErrorMessage = function(_, ...)
        table.insert(errorMessages, {n = select("#", ...), ...})
    end
    local count, results = packResults(pcall(superFunc, brush, ...))
    cursor.setErrorMessage = setErrorMessage
    if not results[1] then
        error(results[2], 0)
    end

    local function refuse()
        for _, args in ipairs(errorMessages) do
            setErrorMessage(cursor, unpack(args, 1, args.n))
        end
        return unpack(results, 2, count)
    end

    if results[2] then
        return refuse()
    end

    local segment = brush.currentSegment
    if segment == nil or type(segment.getStartPos) ~= "function" then
        return refuse()
    end
    local startX = segment:getStartPos()
    if startX == nil then
        return refuse()
    end

    local price = type(segment.getPrice) == "function" and segment:getPrice() or 0
    if g_currentMission:getMoney() < price then
        return refuse()
    end

    local note = g_i18n:getText("da_noteFree")
    local reason = errorMessages[1] ~= nil and errorMessages[1][1] or nil
    if type(reason) == "string" and reason ~= "" then
        note = note .. ": " .. reason
    end
    cursor:setMessage(g_i18n:formatMoney(price) .. " (" .. note .. ")")
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Brush hooks: fine adjustment of placeables
-- ---------------------------------------------------------------------------------------------

function DeployablesAnywhere.getSnappedPosition(brush, superFunc, x, y, z, ...)
    if x == nil or not DeployablesAnywhere.isPlaceableBrush(brush) then
        return superFunc(brush, x, y, z, ...)
    end
    local adjust = DeployablesAnywhere.adjust
    local lock = adjust.lock
    if lock ~= nil then
        -- Locked: the cursor no longer moves the item; the height follows the terrain at the nudged spot
        x, z = lock.x, lock.z
        y = lock.y
        if g_terrainNode ~= nil then
            y = getTerrainHeightAtWorldPos(g_terrainNode, x + adjust.x, 0, z + adjust.z)
        end
    end
    local count, results = packResults(superFunc(brush, x, y, z, ...))
    if results[1] == nil then
        return unpack(results, 1, count)
    end
    results[1] = results[1] + adjust.x
    results[2] = results[2] + adjust.y
    results[3] = results[3] + adjust.z
    return unpack(results, 1, count)
end

function DeployablesAnywhere.getSnappedRotation(brush, superFunc, ...)
    local count, results = packResults(superFunc(brush, ...))
    if type(results[1]) == "number" and DeployablesAnywhere.isPlaceableBrush(brush) then
        results[1] = results[1] + DeployablesAnywhere.adjust.rotY
    end
    return unpack(results, 1, count)
end

-- ---------------------------------------------------------------------------------------------
-- Selling: your farm's items can always be sold, also on land you do not own (no key needed)
-- ---------------------------------------------------------------------------------------------

-- Depth of sell brush calls in progress; land checks pass while it is above 0
DeployablesAnywhere.sellingDepth = 0
-- Placeable -> {value = its own getIsOnOwnedFarmland} for your farm's placeables, stubbed while demolition mode is open
DeployablesAnywhere.sellingStubs = {}
DeployablesAnywhere.hasSellingStubs = false

function DeployablesAnywhere.isSelling()
    return DeployablesAnywhere.sellingDepth > 0
end

-- The local player's farm, nil for spectators
function DeployablesAnywhere.getOwnFarmId()
    if g_currentMission == nil then
        return nil
    end
    local farmId = g_currentMission:getFarmId()
    local spectatorFarmId = FarmManager ~= nil and FarmManager.SPECTATOR_FARM_ID or 0
    if farmId == nil or farmId == spectatorFarmId then
        return nil
    end
    return farmId
end

function DeployablesAnywhere.isOwnFarmPlaceable(placeable)
    if type(placeable) ~= "table" or type(placeable.getOwnerFarmId) ~= "function" then
        return false
    end
    local farmId = DeployablesAnywhere.getOwnFarmId()
    return farmId ~= nil and placeable:getOwnerFarmId() == farmId
end

function DeployablesAnywhere.allowSellingOf(placeable)
    if DeployablesAnywhere.sellingStubs[placeable] ~= nil or not DeployablesAnywhere.isOwnFarmPlaceable(placeable)
        or placeable.getIsOnOwnedFarmland == nil then
        return
    end
    DeployablesAnywhere.sellingStubs[placeable] = {value = rawget(placeable, "getIsOnOwnedFarmland")}
    placeable.getIsOnOwnedFarmland = DeployablesAnywhere.PLACEABLE_STUBS.getIsOnOwnedFarmland
end

-- All of your farm's placeables count as on your own land until demolition mode is left
function DeployablesAnywhere.allowSellingOfOwnPlaceables()
    if DeployablesAnywhere.hasSellingStubs then
        return
    end
    DeployablesAnywhere.hasSellingStubs = true
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if placeableSystem == nil or type(placeableSystem.placeables) ~= "table" then
        return
    end
    for _, placeable in pairs(placeableSystem.placeables) do
        DeployablesAnywhere.allowSellingOf(placeable)
    end
end

function DeployablesAnywhere.restoreSellingStubs()
    for placeable, entry in pairs(DeployablesAnywhere.sellingStubs) do
        rawset(placeable, "getIsOnOwnedFarmland", entry.value)
    end
    DeployablesAnywhere.sellingStubs = {}
    DeployablesAnywhere.hasSellingStubs = false
end

function DeployablesAnywhere.callSelling(functionName, func, ...)
    DeployablesAnywhere.sellingDepth = DeployablesAnywhere.sellingDepth + 1
    if functionName ~= "deactivate" and functionName ~= "delete" then
        DeployablesAnywhere.allowSellingOfOwnPlaceables()
    end
    local count, results = packResults(pcall(func, ...))
    DeployablesAnywhere.sellingDepth = DeployablesAnywhere.sellingDepth - 1
    if functionName == "deactivate" or functionName == "delete" then
        DeployablesAnywhere.restoreSellingStubs()
    end
    if not results[1] then
        error(results[2], 0)
    end
    return unpack(results, 2, count)
end

-- The placeable under the cursor of the sell brush
function DeployablesAnywhere.getHitPlaceable(cursor, superFunc, ...)
    local count, results = packResults(superFunc(cursor, ...))
    if DeployablesAnywhere.isSelling() then
        DeployablesAnywhere.allowSellingOf(results[1])
    end
    return unpack(results, 1, count)
end

-- Land ownership and access checks, passed while the sell brush is working
function DeployablesAnywhere.landCheck(object, superFunc, ...)
    if DeployablesAnywhere.isSelling() then
        return true
    end
    return superFunc(object, ...)
end

-- Owner of the land, reported as your farm while the sell brush is working
function DeployablesAnywhere.landOwner(object, superFunc, ...)
    local farmId = DeployablesAnywhere.getOwnFarmId()
    if DeployablesAnywhere.isSelling() and farmId ~= nil then
        return farmId
    end
    return superFunc(object, ...)
end

-- ---------------------------------------------------------------------------------------------
-- Fence refunds: the game removes fence segments and panels without paying anything back.
-- On the server, the value of the fence (sum of its segment prices) is taken before and after a delete
-- request; the difference is what was removed and is paid to the farm of the player who removed it.
-- ---------------------------------------------------------------------------------------------

function DeployablesAnywhere.isPlaceableGone(placeable)
    if placeable.isDeleted or placeable.isDeleting then
        return true
    end
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if placeableSystem ~= nil and type(placeableSystem.placeables) == "table" then
        for _, other in pairs(placeableSystem.placeables) do
            if other == placeable then
                return false
            end
        end
        return true
    end
    return false
end

function DeployablesAnywhere.getFenceValue(fencePlaceable)
    if type(fencePlaceable) ~= "table" or type(fencePlaceable.getFence) ~= "function"
        or DeployablesAnywhere.isPlaceableGone(fencePlaceable) then
        return 0
    end
    local ok, fence = pcall(fencePlaceable.getFence, fencePlaceable)
    if not ok or type(fence) ~= "table" or type(fence.segments) ~= "table" then
        return 0
    end
    local value = 0
    for _, segment in ipairs(fence.segments) do
        if type(segment.getPrice) == "function" then
            local okPrice, price = pcall(segment.getPrice, segment)
            if okPrice and type(price) == "number" then
                value = value + price
            end
        end
    end
    return value
end

function DeployablesAnywhere.runFenceDeleteEvent(event, superFunc, connection, ...)
    -- Only the server's handling of a client's request; the reply to the client is left alone
    if connection == nil or connection:getIsServer() or g_currentMission == nil then
        return superFunc(event, connection, ...)
    end

    local fencePlaceable = event.fencePlaceable
    local player = type(g_currentMission.getPlayerByConnection) == "function" and g_currentMission:getPlayerByConnection(connection) or nil
    local farmId = player ~= nil and player.farmId or nil
    if farmId == nil and type(fencePlaceable) == "table" and type(fencePlaceable.getOwnerFarmId) == "function" then
        farmId = fencePlaceable:getOwnerFarmId()
    end
    local valueBefore = DeployablesAnywhere.getFenceValue(fencePlaceable)

    local count, results = packResults(superFunc(event, connection, ...))

    local refund = math.floor(valueBefore - DeployablesAnywhere.getFenceValue(fencePlaceable) + 0.5)
    local spectatorFarmId = FarmManager ~= nil and FarmManager.SPECTATOR_FARM_ID or 0
    if refund > 0 and farmId ~= nil and farmId ~= spectatorFarmId then
        local moneyType = MoneyType.SHOP_PROPERTY_SELL or MoneyType.OTHER or MoneyType.SHOP_PROPERTY_BUY
        g_currentMission:addMoney(refund, farmId, moneyType, true, true)
    end
    return unpack(results, 1, count)
end

-- Server: the sell request of a client, in case it checks the land too. Farm permission and ownership stay checked.
function DeployablesAnywhere.runSellPlaceableEvent(event, superFunc, connection, ...)
    local placeable = event.placeable
    if type(placeable) ~= "table" or placeable.getIsOnOwnedFarmland == nil or connection == nil or connection:getIsServer() then
        return superFunc(event, connection, ...)
    end
    local saved = rawget(placeable, "getIsOnOwnedFarmland")
    placeable.getIsOnOwnedFarmland = DeployablesAnywhere.PLACEABLE_STUBS.getIsOnOwnedFarmland
    local count, results = packResults(pcall(superFunc, event, connection, ...))
    rawset(placeable, "getIsOnOwnedFarmland", saved)
    if not results[1] then
        error(results[2], 0)
    end
    return unpack(results, 2, count)
end

function DeployablesAnywhere.installSellingHooks()
    if DeployablesAnywhere.sellingHooked then
        return
    end
    local destructClass = ConstructionBrushDestruct
    if destructClass == nil and g_constructionBrushTypeManager ~= nil then
        destructClass = g_constructionBrushTypeManager:getClassObjectByTypeName("destruct")
    end
    if destructClass == nil then
        return
    end
    DeployablesAnywhere.sellingHooked = true

    -- Every method of the sell brush runs in selling context
    local functionNames = {}
    for name, value in pairs(destructClass) do
        if type(value) == "function" and name ~= "new" then
            functionNames[name] = true
        end
    end
    for _, name in ipairs({"update", "onButtonPrimary", "onButtonSecondary"}) do
        if type(destructClass[name]) == "function" then
            functionNames[name] = true
        end
    end
    for name in pairs(functionNames) do
        local original = destructClass[name]
        destructClass[name] = function(...) return DeployablesAnywhere.callSelling(name, original, ...) end
    end

    wrap(GuiTopDownCursor, "getHitPlaceable", function(...) return DeployablesAnywhere.getHitPlaceable(...) end)
    wrap(AccessHandler, "canFarmAccessLand", function(...) return DeployablesAnywhere.landCheck(...) end)
    for _, functionName in ipairs({"getIsOwnedByFarmAlongLine", "getIsOwnedByFarmAtWorldPosition", "getCanAccessLandAtWorldPosition"}) do
        wrap(FarmlandManager, functionName, function(...) return DeployablesAnywhere.landCheck(...) end)
    end
    for _, functionName in ipairs({"getOwnerIdAtWorldPosition", "getFarmlandOwner"}) do
        wrap(FarmlandManager, functionName, function(...) return DeployablesAnywhere.landOwner(...) end)
    end
    wrap(SellPlaceableEvent, "run", function(...) return DeployablesAnywhere.runSellPlaceableEvent(...) end)
    -- Removing a fence panel or a whole segment, and the older whole-segment request
    wrap(FenceRequestDeleteSegmentPartEvent, "run", function(...) return DeployablesAnywhere.runFenceDeleteEvent(...) end)
    wrap(FenceRequestDeleteSegmentEvent, "run", function(...) return DeployablesAnywhere.runFenceDeleteEvent(...) end)

    if ConstructionScreen ~= nil then
        -- Demolition mode always ends with the screen
        ConstructionScreen.onClose = Utils.prependedFunction(ConstructionScreen.onClose,
            function() DeployablesAnywhere.restoreSellingStubs() end)
    end
end

-- Placeable bought: no terrain leveling when wanted, or when free placement went past a leveling error
function DeployablesAnywhere.consumeSkipLeveling(buyData)
    local skipUntil = DeployablesAnywhere.skipLevelingUntil
    if skipUntil == nil then
        return
    end
    DeployablesAnywhere.skipLevelingUntil = nil
    if g_time <= skipUntil then
        buyData.modifyTerrain = false
    end
end

-- ---------------------------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------------------------

-- A subclass wrap calls the base class wrap through its superclass: only the outer one applies the mod
function DeployablesAnywhere.callGuarded(functionName, brush, superFunc, ...)
    local guards = rawget(brush, "daGuards")
    if guards == nil then
        guards = {}
        rawset(brush, "daGuards", guards)
    end
    if guards[functionName] then
        return superFunc(brush, ...)
    end
    guards[functionName] = true
    local count, results = packResults(pcall(DeployablesAnywhere[functionName], brush, superFunc, ...))
    guards[functionName] = nil
    if not results[1] then
        error(results[2], 0)
    end
    return unpack(results, 2, count)
end

-- Savegames re-source mod scripts, so the hooks are installed once and call the current DeployablesAnywhere table
function DeployablesAnywhere.installHooks()
    if ConstructionBrush == nil or ConstructionBrush.daHooked then
        return
    end
    ConstructionBrush.daHooked = true

    -- Subclasses that define their own verifyAccess get it wrapped too
    wrap(ConstructionBrush, "verifyAccess", function(...) return DeployablesAnywhere.verifyAccess(...) end)
    for _, className in ipairs(DeployablesAnywhere.BRUSH_CLASS_NAMES) do
        local class = _G[className]
        if class ~= nil and rawget(class, "verifyAccess") ~= nil then
            wrap(class, "verifyAccess", function(...) return DeployablesAnywhere.verifyAccess(...) end)
        end
    end

    local placeableBrushFunctions = {"verifyPlacement", "updatePlaceablePosition", "onButtonPrimary", "getDisplacementCost",
        "getSnappedPosition", "getSnappedRotation"}
    for i, className in ipairs(DeployablesAnywhere.PLACEABLE_BRUSH_CLASS_NAMES) do
        local class = _G[className]
        if class ~= nil then
            for _, functionName in ipairs(placeableBrushFunctions) do
                if i == 1 or rawget(class, functionName) ~= nil then
                    local hook = function(...) return DeployablesAnywhere.callGuarded(functionName, ...) end
                    if not wrap(class, functionName, hook) and i == 1 then
                        Logging.warning("[%s] %s.%s not found; this part of the mod does nothing.", DeployablesAnywhere.MOD_NAME, className, functionName)
                    end
                end
            end
        end
    end
    -- A new item starts without fine adjustment
    if ConstructionBrushPlaceable ~= nil and type(ConstructionBrushPlaceable.activate) == "function" then
        ConstructionBrushPlaceable.activate = Utils.appendedFunction(ConstructionBrushPlaceable.activate,
            function() DeployablesAnywhere.resetAdjustments() end)
    end
    if not wrap(ConstructionBrushNewFence, "validateCurrentSegment", function(...) return DeployablesAnywhere.validateCurrentSegment(...) end) then
        Logging.warning("[%s] ConstructionBrushNewFence.validateCurrentSegment not found; fences keep their placement limits.", DeployablesAnywhere.MOD_NAME)
    end

    if BuyPlaceableData ~= nil then
        -- writeStream: client to server; buy: single player and host
        BuyPlaceableData.writeStream = Utils.prependedFunction(BuyPlaceableData.writeStream,
            function(buyData) DeployablesAnywhere.consumeSkipLeveling(buyData) end)
        BuyPlaceableData.buy = Utils.prependedFunction(BuyPlaceableData.buy,
            function(buyData) DeployablesAnywhere.consumeSkipLeveling(buyData) end)
    end

    if ConstructionScreen ~= nil then
        ConstructionScreen.registerBrushActionEvents = Utils.appendedFunction(ConstructionScreen.registerBrushActionEvents,
            function(screen) DeployablesAnywhere.registerActionEvents(screen) end)
        -- Everything off again every time construction mode is left
        ConstructionScreen.onClose = Utils.prependedFunction(ConstructionScreen.onClose,
            function()
                DeployablesAnywhere.setEnabled(false)
                DeployablesAnywhere.setNoLeveling(false)
                DeployablesAnywhere.resetAdjustments()
            end)
    end
end

function DeployablesAnywhere:loadMap()
    DeployablesAnywhere.installHooks()
    DeployablesAnywhere.installSellingHooks()
end

function DeployablesAnywhere:deleteMap()
    self.isEnabled = false
    self.isNoLeveling = false
    self.eventIds = {}
    self.skipLevelingUntil = nil
    self.resetAdjustments()
end

DeployablesAnywhere.installHooks()
DeployablesAnywhere.installSellingHooks()

addModEventListener(DeployablesAnywhere)
