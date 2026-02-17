-- =============================================================================
-- IME Control Module for Hammerspoon
-- =============================================================================

local M = {}
local logger = hs.logger.new('IMECtrl', 'info')

-- =============================================================================
-- 1. Configuration / 設定
-- =============================================================================
M.config = {
    -- Input Source IDs
    sources = {
        eng = "com.apple.keylayout.ABC",
        jpn = "com.google.inputmethod.Japanese.base"
    },

    -- Key Bindings
    bindings = {
        toggle = { key = "f12", modifiers = {"shift"}},
        debug  = { key = "f11", modifiers = {"shift"} }
    },

    -- JIS Keycodes (Fixed for JIS keyboard emulation)
    keycodes = {
        eisu = 102,
        kana = 104,
        f15  = 113 -- Dummy key for event loop refresh
    },

    -- Behavior Settings
    behavior = {
        watchdogInterval = 30,
        retryInterval = 0.1,
        retryCount = 5,
        alertDuration = 0.5,
        showAlert = true,
        useSourceChangedWatcher = true, -- Set to false to avoid conflict with other modules
        
        -- Timing settings (in seconds)
        applyDelay = 0.02,
        focusDelay = 0.1,
        alertDelay = 0.1,
        keyTapDelay = 0.001 -- 1ms for physical key tap emulation
    }
}

-- =============================================================================
-- 2. State Management / 内部状態
-- =============================================================================
local STATE = {
    lastKnownIME = nil,
    alertTimer = nil,
    alertUUID = nil,
    inputWatcher = nil,
    enforcementTimer = nil,
    systemWatcher = nil,
    watchdogTimer = nil,
    windowFilter = nil,
    focusTimer = nil,
    applyTimer = nil,
    hotkeyTimer = nil,
    keyUpTimers = {},
    sourceChangedEnabled = false,
    sourceChangedInstalled = false
}

-- =============================================================================
-- 3. Core Logic / コアロジック
-- =============================================================================

--- Post a JIS key event with a small delay between down/up
local function postJISKey(keyCode)
    hs.eventtap.event.newKeyEvent({}, keyCode, true):post()
    
    -- Requirement 1 (Revised): Use a table to manage multiple concurrent keyUp timers.
    -- This prevents keyUp events from being cancelled by subsequent keyDown events.
    local timer
    timer = hs.timer.doAfter(M.config.behavior.keyTapDelay, function()
        hs.eventtap.event.newKeyEvent({}, keyCode, false):post()
        if timer then
            STATE.keyUpTimers[timer] = nil
        end
    end)
    STATE.keyUpTimers[timer] = true -- Requirement 4: Explicitly use true for Set-like behavior
end

--- Apply IME source and sync all layers
local function applyIME(sourceID)
    if not sourceID then return end

    -- Stop existing timers to prevent race conditions
    if STATE.applyTimer then
        STATE.applyTimer:stop()
        STATE.applyTimer = nil
    end
    if STATE.enforcementTimer then
        STATE.enforcementTimer:stop()
        STATE.enforcementTimer = nil
    end

    -- Update cache
    STATE.lastKnownIME = sourceID
    
    -- Determine forceKey only for known sources (safety fallback)
    local forceKey = nil
    if sourceID == M.config.sources.eng then
        forceKey = M.config.keycodes.eisu
    elseif sourceID == M.config.sources.jpn then
        forceKey = M.config.keycodes.kana
    end

    -- Step 1: Attempt via API
    local success = hs.keycodes.currentSourceID(sourceID)
    if not success then
        logger:e(string.format("Failed to set source ID: %s", sourceID))
    end
    
    -- Step 2: Immediate check and fallback to physical key
    STATE.applyTimer = hs.timer.doAfter(M.config.behavior.applyDelay, function()
        STATE.applyTimer = nil -- Requirement 3: Reset timer on execution
        
        local current = hs.keycodes.currentSourceID()
        if current ~= sourceID and forceKey then
            postJISKey(forceKey)
        end

        -- Step 3: Retry logic for stubborn apps (Chromium, etc.)
        local count = 0
        STATE.enforcementTimer = hs.timer.doWhile(
            function()
                count = count + 1
                local currentNow = hs.keycodes.currentSourceID()
                local shouldContinue = count <= M.config.behavior.retryCount and currentNow ~= sourceID
                if not shouldContinue then
                    STATE.enforcementTimer = nil -- Requirement 3: Reset on completion
                end
                return shouldContinue
            end,
            function()
                hs.keycodes.currentSourceID(sourceID)
                if forceKey then postJISKey(forceKey) end
            end,
            M.config.behavior.retryInterval
        )
    end)
end

--- Toggle between English and Japanese
local function toggleIME()
    local current = hs.keycodes.currentSourceID()
    local target = (current == M.config.sources.eng) and M.config.sources.jpn or M.config.sources.eng
    local label  = (target == M.config.sources.jpn) and "🇯🇵 日本語" or "Aa 英数"

    applyIME(target)
    postJISKey(M.config.keycodes.f15)
    
    -- Visual feedback
    if M.config.behavior.showAlert then
        if STATE.alertTimer then STATE.alertTimer:stop() end
        STATE.alertTimer = hs.timer.doAfter(M.config.behavior.alertDelay, function()
            STATE.alertTimer = nil -- Requirement 3: Reset timer on execution
            
            if STATE.alertUUID then
                hs.alert.closeSpecific(STATE.alertUUID)
            end
            STATE.alertUUID = hs.alert.show(label, M.config.behavior.alertDuration)
        end)
    end
end

-- =============================================================================
-- 4. Event Handlers / イベントハンドラ
-- =============================================================================

--- Check if the event matches a specific binding configuration
local function isBindingMatch(keyCode, flags, bindingConfig)
    if not bindingConfig or keyCode ~= hs.keycodes.map[bindingConfig.key] then return false end
    
    -- Check required modifiers
    local allowed = {}
    for _, mod in ipairs(bindingConfig.modifiers) do
        if not flags[mod] then return false end
        allowed[mod] = true
    end
    
    -- Ensure no other modifiers are pressed (Strict check)
    for _, mod in ipairs({"cmd", "alt", "shift", "ctrl", "fn"}) do
        if flags[mod] and not allowed[mod] then return false end
    end
    
    return true
end

local function handleKeyEvent(event)
    -- Ignore autorepeat events (Requirement 7 & Point 3 in Review)
    local isAutoRepeat = (event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) or 0) ~= 0
    if isAutoRepeat then return false end

    local keyCode = event:getKeyCode()
    local flags = event:getFlags()
    
    -- Toggle IME
    if isBindingMatch(keyCode, flags, M.config.bindings.toggle) then
        -- Requirement 1: Use separate timer for hotkeys to avoid collision with focusTimer
        if STATE.hotkeyTimer then STATE.hotkeyTimer:stop() end
        STATE.hotkeyTimer = hs.timer.doAfter(0, function()
            STATE.hotkeyTimer = nil -- Requirement 3: Reset on execution
            toggleIME()
        end)
        return true
    end

    -- Debug Info
    if isBindingMatch(keyCode, flags, M.config.bindings.debug) then
        hs.alert.show(string.format("Current: %s\nLast: %s", hs.keycodes.currentSourceID(), STATE.lastKnownIME))
        return true
    end
    
    return false
end

-- =============================================================================
-- 5. API / モジュール公開関数
-- =============================================================================

--- Stop IME control and cleanup all resources
function M.stop()
    -- Stop all timers
    local timers = {
        "alertTimer", "enforcementTimer", "watchdogTimer", 
        "focusTimer", "applyTimer", "hotkeyTimer"
    }
    for _, name in ipairs(timers) do
        if STATE[name] then
            STATE[name]:stop()
            STATE[name] = nil
        end
    end

    -- Stop all concurrent keyUp timers
    for t, _ in pairs(STATE.keyUpTimers) do
        t:stop()
    end
    STATE.keyUpTimers = {}

    -- Stop and cleanup watchers
    if STATE.inputWatcher then
        STATE.inputWatcher:stop()
        STATE.inputWatcher = nil
    end
    if STATE.windowFilter then
        STATE.windowFilter:unsubscribeAll()
        STATE.windowFilter = nil
    end
    if STATE.systemWatcher then
        STATE.systemWatcher:stop()
        STATE.systemWatcher = nil
    end

    -- Requirement 1 (Revised): Disable internal flag for source changed watcher.
    -- We don't call inputSourceChanged(nil) here to avoid breaking other modules.
    STATE.sourceChangedEnabled = false

    if STATE.alertUUID then
        hs.alert.closeSpecific(STATE.alertUUID)
        STATE.alertUUID = nil
    end

    -- Requirement 2: Safety KeyUp events to prevent stuck keys
    local keys = {M.config.keycodes.eisu, M.config.keycodes.kana, M.config.keycodes.f15}
    for _, k in ipairs(keys) do
        hs.eventtap.event.newKeyEvent({}, k, false):post()
    end

    logger:i("Stopped and cleaned up")
end

--- Start IME control
function M.start(userConfig)
    -- Prevent multiple instances
    M.stop()

    -- Override default config with user config
    if userConfig then
        for k, v in pairs(userConfig) do
            if type(v) == "table" and type(M.config[k]) == "table" then
                for subK, subV in pairs(v) do M.config[k][subK] = subV end
            else
                M.config[k] = v
            end
        end
    end

    -- Initialize State
    STATE.lastKnownIME = hs.keycodes.currentSourceID() or M.config.sources.eng

    -- 1. IME Change Watcher (Optional)
    -- Requirement 1 (Revised): Use internal flags to control the shared callback
    if M.config.behavior.useSourceChangedWatcher then
        STATE.sourceChangedEnabled = true
        
        if not STATE.sourceChangedInstalled then
            hs.keycodes.inputSourceChanged(function()
                if not STATE.sourceChangedEnabled then return end

                local current = hs.keycodes.currentSourceID()
                -- Only update state and stop ongoing enforcements
                if current and current ~= STATE.lastKnownIME then
                    STATE.lastKnownIME = current
                    if STATE.applyTimer then STATE.applyTimer:stop(); STATE.applyTimer = nil end
                    if STATE.enforcementTimer then STATE.enforcementTimer:stop(); STATE.enforcementTimer = nil end
                end
            end)
            STATE.sourceChangedInstalled = true
        end
    else
        STATE.sourceChangedEnabled = false
    end

    -- 2. Hotkey Watcher (EventTap)
    STATE.inputWatcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, handleKeyEvent)
    STATE.inputWatcher:start()

    -- 3. Watchdog (Requirement 1: Store reference to prevent GC)
    STATE.watchdogTimer = hs.timer.doEvery(M.config.behavior.watchdogInterval, function()
        if STATE.inputWatcher and not STATE.inputWatcher:isEnabled() then
            STATE.inputWatcher:start()
            logger:w("Watchdog: Restarted input watcher")
        end
    end)

    -- 4. Window Focus Watcher (Requirement 1: Store reference to prevent GC)
    STATE.windowFilter = hs.window.filter.new()
    STATE.windowFilter:subscribe(hs.window.filter.windowFocused, function()
        -- Prevent overlapping focus timers (Requirement 1 & 2)
        if STATE.focusTimer then
            STATE.focusTimer:stop()
        end
        STATE.focusTimer = hs.timer.doAfter(M.config.behavior.focusDelay, function()
            STATE.focusTimer = nil -- Requirement 3: Reset on execution
            applyIME(hs.keycodes.currentSourceID())
        end)
    end)

    -- 5. System Watcher (Stability for sleep/wake)
    STATE.systemWatcher = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake or
           event == hs.caffeinate.watcher.screensDidUnlock then
            logger:i("System wake/unlock detected. Resetting watchers.")
            if STATE.inputWatcher then
                STATE.inputWatcher:stop()
                STATE.inputWatcher:start()
            end
            applyIME(hs.keycodes.currentSourceID())
        end
    end)
    STATE.systemWatcher:start()
    
    logger:i("Initialized")
end

return M
