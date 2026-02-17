-- =============================================================================
-- IME Control Module for Hammerspoon
-- =============================================================================

--- @class IMECtrl
--- @class IMECtrl
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
        f19  = 80 -- Dummy key for event loop refresh (F15 is reserved for Brightness Up)
    },

    -- Behavior Settings
    behavior = {
        watchdogInterval = 30,
        retryInterval = 0.1,
        retryCount = 5,
        alertDuration = 0.5,
        showAlert = true,
        useSourceChangedWatcher = false, -- Default to false for better compatibility
        
        -- Timing settings (in seconds)
        applyDelay = 0.02,
        focusDelay = 0.1,
        alertDelay = 0.1,
        keyTapDelay = 0.001
        keyTapDelay = 0.001
    }
}

-- =============================================================================
-- 2. Internal State Management / 内部状態管理
-- 2. Internal State Management / 内部状態管理
-- =============================================================================


local STATE = {
    lastKnownIME = nil,
    alertUUID = nil,
    inputWatcher = nil,
    systemWatcher = nil,
    windowFilter = nil,
    sourceChangedEnabled = false,
    sourceChangedInstalled = false,
    running = false,
    
    -- Managed by timerManager
    timers = {},
    keyUpTimers = {}
}

--- Timer management helper
local timerManager = {}

--- Safe callback execution with error logging
local function safeCall(fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        logger:e(string.format("Error in timer callback: %s", err))
    end
end

--- Start a one-shot timer and manage its lifecycle
--- @param name string Unique name for the timer
--- @param delay number Delay in seconds
--- @param fn function Callback function
function timerManager.start(name, delay, fn)
    timerManager.stop(name)
    STATE.timers[name] = hs.timer.doAfter(delay, function()
        STATE.timers[name] = nil
        safeCall(fn)
    end)
end

--- Start a recurring timer
--- @param name string Unique name for the timer
--- @param interval number Interval in seconds
--- @param fn function Callback function
function timerManager.every(name, interval, fn)
    timerManager.stop(name)
    STATE.timers[name] = hs.timer.doEvery(interval, function()
        safeCall(fn)
    end)
end

--- Start a doWhile timer
--- @param name string Unique name for the timer
--- @param checkFn function Condition function
--- @param actionFn function Action function
--- @param interval number Interval in seconds
function timerManager.doWhile(name, checkFn, actionFn, interval)
    timerManager.stop(name)
    STATE.timers[name] = hs.timer.doWhile(
        function()
            local shouldContinue = checkFn()
            if not shouldContinue then STATE.timers[name] = nil end
            return shouldContinue
        end,
        function()
            safeCall(actionFn)
        end,
        interval
    )
end

--- Stop a specific managed timer
--- @param name string Timer name
function timerManager.stop(name)
    if STATE.timers[name] then
        STATE.timers[name]:stop()
        STATE.timers[name] = nil
    end
end

--- Stop all managed timers safely using snapshot
function timerManager.stopAll()
    local activeTimers = STATE.timers
    STATE.timers = {} -- Clear reference first

    for _, t in pairs(activeTimers) do
        t:stop()
    end

    local activeKeyUpTimers = STATE.keyUpTimers
    STATE.keyUpTimers = {} -- Clear reference first

    for t, _ in pairs(activeKeyUpTimers) do
        t:stop()
    end
end

-- =============================================================================
-- 3. Internal Utils / 内部ユーティリティ
-- =============================================================================

--- Validate if the configured source IDs exist on the system
local function validateConfig()
    -- methods(true) / layouts(true) return arrays of sourceID strings
    local methods = hs.keycodes.methods(true)
    local layouts = hs.keycodes.layouts(true)
    local valid = true

    local function exists(id)
        for _, mID in ipairs(methods) do if mID == id then return true end end
        for _, lID in ipairs(layouts) do if lID == id then return true end end
        return false
    end

    for name, id in pairs(M.config.sources) do
        if not exists(id) then
            local msg = string.format("IME sourceID invalid: '%s' (%s)", name, id)
            logger:w(msg)
            hs.alert.show(msg, 3)
            valid = false
        end
    end
    return valid
end

-- =============================================================================
-- 4. Key Emulation / キーエミュレーション
-- =============================================================================

--- Post a JIS key event with a small delay between down/up
--- @param keyCode number JIS keycode
--- @param keyCode number JIS keycode
local function postJISKey(keyCode)
    hs.eventtap.event.newKeyEvent({}, keyCode, true):post()
    
    local timer
    timer = hs.timer.doAfter(M.config.behavior.keyTapDelay, function()
        hs.eventtap.event.newKeyEvent({}, keyCode, false):post()
        if timer then STATE.keyUpTimers[timer] = nil end
        if timer then STATE.keyUpTimers[timer] = nil end
    end)
    STATE.keyUpTimers[timer] = true
    STATE.keyUpTimers[timer] = true
end

-- =============================================================================
-- 5. Core Logic / コアロジック
-- =============================================================================

--- Apply IME source and sync all layers
--- @param sourceID string Input source ID
--- @param sourceID string Input source ID
local function applyIME(sourceID)
    if not sourceID then return end

    -- Reset ongoing enforcements
    timerManager.stop("apply")
    timerManager.stop("enforcement")

    -- Reset ongoing enforcements
    timerManager.stop("apply")
    timerManager.stop("enforcement")

    STATE.lastKnownIME = sourceID
    
    local forceKey = nil
    if sourceID == M.config.sources.eng then
        forceKey = M.config.keycodes.eisu
    elseif sourceID == M.config.sources.jpn then
        forceKey = M.config.keycodes.kana
    end

    -- Attempt via API
    -- Attempt via API
    local success = hs.keycodes.currentSourceID(sourceID)
    if not success then
        logger:e(string.format("Failed to set source ID: %s", sourceID))
    end
    
    -- Fallback to physical key and retry logic
    timerManager.start("apply", M.config.behavior.applyDelay, function()
    -- Fallback to physical key and retry logic
    timerManager.start("apply", M.config.behavior.applyDelay, function()
        local current = hs.keycodes.currentSourceID()
        if current ~= sourceID and forceKey then
            postJISKey(forceKey)
        end

        -- Requirement 2 (Optimized): Only start doWhile if source is still mismatched
        if hs.keycodes.currentSourceID() ~= sourceID then
            local count = 0
            timerManager.doWhile("enforcement", 
                function()
                    count = count + 1
                    return count <= M.config.behavior.retryCount and hs.keycodes.currentSourceID() ~= sourceID
                end,
                function()
                    hs.keycodes.currentSourceID(sourceID)
                    if forceKey then postJISKey(forceKey) end
                end,
                M.config.behavior.retryInterval
            )
        end
    end)
end

--- Toggle between English and Japanese
local function toggleIME()
    local current = hs.keycodes.currentSourceID()
    local target = (current == M.config.sources.eng) and M.config.sources.jpn or M.config.sources.eng
    local label  = (target == M.config.sources.jpn) and "🇯🇵 日本語" or "Aa 英数"

    applyIME(target)
    postJISKey(M.config.keycodes.f19)
    
    if M.config.behavior.showAlert then
        timerManager.start("alert", M.config.behavior.alertDelay, function()
            if STATE.alertUUID then hs.alert.closeSpecific(STATE.alertUUID) end
            local uuid = hs.alert.show(label, M.config.behavior.alertDuration)
            STATE.alertUUID = uuid

            -- Fail-safe: Manually close the alert after duration
            timerManager.start("alertClose", M.config.behavior.alertDuration + 0.05, function()
                if STATE.alertUUID == uuid then
                    hs.alert.closeSpecific(uuid)
                    STATE.alertUUID = nil
                end
            end)
        end)
    end
end

-- =============================================================================
-- 6. Event Handlers / イベントハンドラ
-- =============================================================================

--- Check if the event matches a specific binding configuration
local function isBindingMatch(keyCode, flags, bindingConfig)
    if not bindingConfig or keyCode ~= hs.keycodes.map[bindingConfig.key] then return false end
    
    local allowed = {}
    for _, mod in ipairs(bindingConfig.modifiers) do
        if not flags[mod] then return false end
        allowed[mod] = true
    end
    
    -- Strict check including capslock
    for _, mod in ipairs({"cmd", "alt", "shift", "ctrl", "fn", "capslock"}) do
        if flags[mod] and not allowed[mod] then return false end
    end
    
    return true
end

--- Primary key event handler
--- Primary key event handler
local function handleKeyEvent(event)
    local isAutoRepeat = (event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) or 0) ~= 0
    if isAutoRepeat then return false end

    local keyCode = event:getKeyCode()
    local flags = event:getFlags()
    
    if isBindingMatch(keyCode, flags, M.config.bindings.toggle) then
        timerManager.start("hotkey", 0, toggleIME)
        timerManager.start("hotkey", 0, toggleIME)
        return true
    end

    if isBindingMatch(keyCode, flags, M.config.bindings.debug) then
        hs.alert.show(string.format("Current: %s\nLast: %s", hs.keycodes.currentSourceID(), STATE.lastKnownIME))
        return true
    end
    
    return false
end

-- =============================================================================
-- 7. API / モジュール公開関数
-- =============================================================================

--- Stop IME control and cleanup all resources
function M.stop()
    local wasRunning = STATE.running
    STATE.running = false
    
    timerManager.stopAll()

    if STATE.inputWatcher then STATE.inputWatcher:stop(); STATE.inputWatcher = nil end
    if STATE.windowFilter then STATE.windowFilter:unsubscribeAll(); STATE.windowFilter = nil end
    if STATE.systemWatcher then STATE.systemWatcher:stop(); STATE.systemWatcher = nil end

    STATE.sourceChangedEnabled = false

    if STATE.alertUUID then
        hs.alert.closeSpecific(STATE.alertUUID)
        STATE.alertUUID = nil
    end

    -- Safety KeyUp events
    local keys = {M.config.keycodes.eisu, M.config.keycodes.kana, M.config.keycodes.f19}
    for _, k in ipairs(keys) do
        hs.eventtap.event.newKeyEvent({}, k, false):post()
    end

    -- Point 4-B: Suppress "Stopped" log if not actually running (e.g., during M.start's initial stop)
    if wasRunning then
        logger:i("Stopped")
    end
end

--- Load and merge configuration
local function loadConfig(userConfig)
    if not userConfig then return end
    for k, v in pairs(userConfig) do
        if type(v) == "table" and type(M.config[k]) == "table" then
            for subK, subV in pairs(v) do M.config[k][subK] = subV end
        else
            M.config[k] = v
        end
    end
end
--- Load and merge configuration
local function loadConfig(userConfig)
    if not userConfig then return end
    for k, v in pairs(userConfig) do
        if type(v) == "table" and type(M.config[k]) == "table" then
            for subK, subV in pairs(v) do M.config[k][subK] = subV end
        else
            M.config[k] = v
        end
    end
end

--- Start IME control
--- @param userConfig table? Optional user configuration
function M.start(userConfig)
    M.stop()
    loadConfig(userConfig)
    validateConfig()

    STATE.running = true
    STATE.lastKnownIME = hs.keycodes.currentSourceID() or M.config.sources.eng

    -- 1. IME Change Watcher
    -- 1. IME Change Watcher
    if M.config.behavior.useSourceChangedWatcher then
        STATE.sourceChangedEnabled = true
        if not STATE.sourceChangedInstalled then
            hs.keycodes.inputSourceChanged(function()
                if not STATE.sourceChangedEnabled then return end
                local current = hs.keycodes.currentSourceID()
                if current and current ~= STATE.lastKnownIME then
                    STATE.lastKnownIME = current
                    timerManager.stop("apply")
                    timerManager.stop("enforcement")
                    timerManager.stop("apply")
                    timerManager.stop("enforcement")
                end
            end)
            STATE.sourceChangedInstalled = true
        end
    else
        STATE.sourceChangedEnabled = false
    end

    -- 2. Hotkey Watcher
    -- 2. Hotkey Watcher
    STATE.inputWatcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, handleKeyEvent)
    STATE.inputWatcher:start()

    -- 3. Watchdog
    timerManager.every("watchdog", M.config.behavior.watchdogInterval, function()
    -- 3. Watchdog
    timerManager.every("watchdog", M.config.behavior.watchdogInterval, function()
        if STATE.inputWatcher and not STATE.inputWatcher:isEnabled() then
            STATE.inputWatcher:start()
            logger:w("Watchdog: Restarted input watcher")
        end
    end)

    -- 4. Window Focus Watcher
    -- 4. Window Focus Watcher
    STATE.windowFilter = hs.window.filter.new()
    STATE.windowFilter:subscribe(hs.window.filter.windowFocused, function()
        timerManager.start("focus", M.config.behavior.focusDelay, function()
        timerManager.start("focus", M.config.behavior.focusDelay, function()
            applyIME(hs.keycodes.currentSourceID())
        end)
    end)

    -- 5. System Watcher
    -- 5. System Watcher
    STATE.systemWatcher = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake or
           event == hs.caffeinate.watcher.screensDidUnlock then
            logger:i("System wake/unlock detected")
            logger:i("System wake/unlock detected")
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
