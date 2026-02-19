-- =============================================================================
-- IME Control Module for Hammerspoon
-- =============================================================================

--- @class IMECtrl
local M = {}
local logger = hs.logger.new('IMECtrl', 'debug')

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
        useSourceChangedWatcher = true, -- Enable for better tracking

        -- Shortcut Fallback Settings (for CJKV environments)
        useShortcutFallback = true,
        useCjkBounce = false,     -- Enable as last resort for CJK instability
        useChromiumNudge = false, -- Experimental: Nudge Chromium to re-sync state
        sourceSwitchShortcut = {
            mods = {"ctrl"},
            key  = "space",
            delayUS = 50000,    -- increased for better reliability (50ms)
            interval = 0.1,     -- increased interval between presses (100ms)
            maxPresses = 10     -- increased max tries
        },
        
        -- Timing settings (in seconds)
        applyDelay = 0.05,  -- Increase delay for sync stability
        focusDelay = 0.3,
        alertDelay = 0.02,
        keyTapDelay = 0.005,
        justAppliedThreshold = 1.0 -- threshold for inputSourceChanged guard
    }
}

-- =============================================================================
-- 2. Internal State Management / 内部状態管理
-- =============================================================================

local STATE = {
    lastKnownIME = nil,
    lastApplyTime = 0,
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
--- @param app hs.application? Optional application to post to
local function postJISKey(keyCode, app)
    hs.eventtap.event.newKeyEvent({}, keyCode, true):post(app)
    
    local timer
    timer = hs.timer.doAfter(M.config.behavior.keyTapDelay, function()
        hs.eventtap.event.newKeyEvent({}, keyCode, false):post(app)
        if timer then STATE.keyUpTimers[timer] = nil end
    end)
    STATE.keyUpTimers[timer] = true
end

--- Check if the bundle ID belongs to a Chromium-based browser
--- @param bundleID string?
--- @return boolean
local function isChromium(bundleID)
    local t = {
        ["com.google.Chrome"] = true,
        ["com.google.Chrome.canary"] = true,
        ["com.microsoft.Edge"] = true,
        ["com.brave.Browser"] = true,
        ["com.vivaldi.Vivaldi"] = true,
        ["com.operasoftware.Opera"] = true,
    }
    return bundleID ~= nil and t[bundleID] ~= nil
end

--- Nudge Chromium to re-sync its input state
local function chromiumNudge()
    if not M.config.behavior.useChromiumNudge then return end
    
    local app = hs.application.frontmostApplication()
    if not app then return end
    if not isChromium(app:bundleID()) then return end

    -- Post a harmless key (F19) to the app to trigger input state refresh
    timerManager.start("chromiumNudge", 0.02, function()
        postJISKey(M.config.keycodes.f19, app)
    end)
end

--- Fallback mechanism using CJK bounce workaround
--- @param targetID string Input source ID
local function cjkBounceWorkaround(targetID)
    if not M.config.behavior.useCjkBounce or targetID ~= M.config.sources.jpn then return end
    local sc = M.config.behavior.sourceSwitchShortcut
    if not sc then return end

    logger:d("Starting CJK bounce workaround")
    -- 1. Ensure target is in history
    hs.keycodes.currentSourceID(targetID)

    -- 2. Escape to English
    timerManager.start("cjkBounce1", 0.03, function()
        hs.keycodes.currentSourceID(M.config.sources.eng)

        -- 3. Bounce back using "previous source" shortcut
        timerManager.start("cjkBounce2", 0.03, function()
            hs.eventtap.keyStroke(sc.mods, sc.key, sc.delayUS or 200000)
        end)
    end)
end

--- Fallback mechanism using OS shortcuts
--- @param targetID string Input source ID
local function fallbackByShortcut(targetID)
    local sc = M.config.behavior.sourceSwitchShortcut
    if not (M.config.behavior.useShortcutFallback and sc) then return end

    logger:d(string.format("Starting shortcut fallback for %s", targetID))
    local presses = 0
    timerManager.doWhile("shortcutFallback",
        function()
            presses = presses + 1
            local current = hs.keycodes.currentSourceID()
            local shouldContinue = presses <= sc.maxPresses and current ~= targetID
            if not shouldContinue then
                if current == targetID then
                    logger:i(string.format("Shortcut fallback succeeded after %d presses", presses - 1))
                else
                    logger:w(string.format("Shortcut fallback failed after %d presses", sc.maxPresses))
                end
            end
            return shouldContinue
        end,
        function()
            hs.eventtap.keyStroke(sc.mods, sc.key, sc.delayUS or 50000)
        end,
        sc.interval or 0.05
    )
end

-- =============================================================================
-- 5. Core Logic / コアロジック
-- =============================================================================

--- Apply IME source and sync all layers
--- @param sourceID string Input source ID
--- @param force boolean? Bypass time/ID checks
local function applyIME(sourceID, force)
    if not sourceID then return end
    
    local current = hs.keycodes.currentSourceID()
    local now = hs.timer.secondsSinceEpoch()
    
    -- Improved Debounce:
    -- Skip only if NOT a forced call AND target matches current state AND called very recently
    local recentlyApplied = (now - STATE.lastApplyTime) < 0.2
    if not force and sourceID == current and recentlyApplied then
        return
    end

    logger:d(string.format("applyIME: %s (Current: %s, Last: %s, Force: %s)", 
        sourceID, tostring(current), tostring(STATE.lastKnownIME), tostring(force or "nil")))
    
    STATE.lastApplyTime = now

    -- Reset ongoing enforcements
    timerManager.stop("apply")
    timerManager.stop("enforcement")

    -- Update internal state immediately to prevent race conditions during applyDelay
    STATE.lastKnownIME = sourceID
    
    local forceKey = nil
    if sourceID == M.config.sources.eng then
        forceKey = M.config.keycodes.eisu
    elseif sourceID == M.config.sources.jpn then
        forceKey = M.config.keycodes.kana
    end

    -- 1. Force Physical Key First (More reliable than API in some cases)
    if forceKey then
        postJISKey(forceKey)
    end

    -- 2. API call after a short delay to let the physical key process
    timerManager.start("apply", M.config.behavior.applyDelay, function()
        hs.keycodes.currentSourceID(sourceID)

        -- Nudge Chromium-based browsers to sync state
        chromiumNudge()
        
        -- 3. Enforcement: Retry logic if still not applied
        if hs.keycodes.currentSourceID() ~= sourceID then
            local count = 0
            timerManager.doWhile("enforcement", 
                function()
                    count = count + 1
                    local current = hs.keycodes.currentSourceID()
                    local shouldContinue = count <= M.config.behavior.retryCount and current ~= sourceID
                    
                    if not shouldContinue and current ~= sourceID then
                        -- 4. Final Fallbacks: Use OS shortcuts/bounce if still not switched
                        fallbackByShortcut(sourceID)
                        cjkBounceWorkaround(sourceID)
                    end
                    
                    return shouldContinue
                end,
                function()
                    if forceKey then postJISKey(forceKey) end
                    hs.keycodes.currentSourceID(sourceID)
                end,
                M.config.behavior.retryInterval
            )
        end
    end)
end

--- Toggle between English and Japanese
local function toggleIME()
    logger:d("toggleIME called")
    local current = hs.keycodes.currentSourceID()
    local target = (current == M.config.sources.eng) and M.config.sources.jpn or M.config.sources.eng
    local label  = (target == M.config.sources.jpn) and "🇯🇵 日本語" or "Aa 英数"

    applyIME(target, true) -- Use force for manual toggle
    
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
    if not bindingConfig then return false end
    local targetCode = hs.keycodes.map[bindingConfig.key]
    if keyCode ~= targetCode then return false end
    
    local allowed = {}
    for _, mod in ipairs(bindingConfig.modifiers) do
        if not flags[mod] then return false end
        allowed[mod] = true
    end
    
    -- Strict check: ensure NO OTHER modifiers are pressed
    for _, mod in ipairs({"cmd", "alt", "shift", "ctrl"}) do
        if flags[mod] and not allowed[mod] then
            return false
        end
    end
    
    return true
end

--- Primary key event handler
local function handleKeyEvent(event)
    local isAutoRepeat = (event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) or 0) ~= 0
    if isAutoRepeat then return false end

    local keyCode = event:getKeyCode()
    local flags = event:getFlags()
    
    -- Ignore dummy keys generated by ourselves
    if keyCode == M.config.keycodes.f19 or 
       keyCode == M.config.keycodes.eisu or 
       keyCode == M.config.keycodes.kana then
        return false
    end

    -- Temporarily verbose for debugging
    logger:d(string.format("Key event: code=%d, flags=%s", keyCode, hs.inspect(flags)))

    if isBindingMatch(keyCode, flags, M.config.bindings.toggle) then
        logger:d("toggleIME triggered (SecureInput=" .. tostring(hs.eventtap.isSecureInputEnabled()) .. ")")
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

--- Start IME control
--- @param userConfig table? Optional user configuration
function M.start(userConfig)
    M.stop()
    loadConfig(userConfig)
    validateConfig()

    STATE.running = true
    STATE.lastKnownIME = hs.keycodes.currentSourceID() or M.config.sources.eng

    -- 1. IME Change Watcher
    if M.config.behavior.useSourceChangedWatcher then
        STATE.sourceChangedEnabled = true
        if not STATE.sourceChangedInstalled then
            hs.keycodes.inputSourceChanged(function()
                if not STATE.sourceChangedEnabled then return end
                local current = hs.keycodes.currentSourceID()
                local now = hs.timer.secondsSinceEpoch()
                local justApplied = (now - STATE.lastApplyTime) < (M.config.behavior.justAppliedThreshold or 1.0)

                if current and current ~= STATE.lastKnownIME then
                    STATE.lastKnownIME = current
                    
                    -- Don't stop enforcement if it was just applied (prevents Chrome/macOS auto-switch bounce)
                    if not justApplied then
                        timerManager.stop("apply")
                        timerManager.stop("enforcement")
                    else
                        logger:d("inputSourceChanged during switching -> keep enforcement")
                    end
                end
            end)
            STATE.sourceChangedInstalled = true
        end
    else
        STATE.sourceChangedEnabled = false
    end

    -- 2. Hotkey Watcher
    STATE.inputWatcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, handleKeyEvent)
    STATE.inputWatcher:start()

    -- 3. Watchdog
    timerManager.every("watchdog", M.config.behavior.watchdogInterval, function()
        if STATE.inputWatcher and not STATE.inputWatcher:isEnabled() then
            STATE.inputWatcher:start()
            logger:w("Watchdog: Restarted input watcher")
        end
    end)

    -- 4. Window Focus Watcher
    STATE.windowFilter = hs.window.filter.new()
    STATE.windowFilter:subscribe(hs.window.filter.windowFocused, function()
        timerManager.start("focus", M.config.behavior.focusDelay, function()
            applyIME(hs.keycodes.currentSourceID())
        end)
    end)

    -- 5. System Watcher
    STATE.systemWatcher = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake or
           event == hs.caffeinate.watcher.screensDidUnlock then
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
