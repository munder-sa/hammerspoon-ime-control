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
        showAlert = true
    }
}

-- =============================================================================
-- 2. State Management / 内部状態
-- =============================================================================
local STATE = {
    lastKnownIME = nil,
    alertTimer = nil,
    inputWatcher = nil,
    enforcementTimer = nil,
    systemWatcher = nil
}

-- =============================================================================
-- 3. Core Logic / コアロジック
-- =============================================================================

--- Post a JIS key event with a small delay between down/up
local function postJISKey(keyCode)
    hs.eventtap.event.newKeyEvent({}, keyCode, true):post()
    -- Use a very small delay for physical key emulation stability
    hs.timer.usleep(1000)
    hs.eventtap.event.newKeyEvent({}, keyCode, false):post()
end

--- Apply IME source and sync all layers
local function applyIME(sourceID)
    if not sourceID then return end

    -- Stop existing retry timer
    if STATE.enforcementTimer then
        STATE.enforcementTimer:stop()
        STATE.enforcementTimer = nil
    end

    -- Update cache
    STATE.lastKnownIME = sourceID
    
    local forceKey = (sourceID == M.config.sources.eng) and M.config.keycodes.eisu or M.config.keycodes.kana

    -- Step 1: Attempt via API
    hs.keycodes.currentSourceID(sourceID)
    
    -- Step 2: Immediate check and fallback to physical key
    hs.timer.doAfter(0.02, function()
        local current = hs.keycodes.currentSourceID()
        if current ~= sourceID then
            postJISKey(forceKey)
        end

        -- Step 3: Retry logic for stubborn apps (Chromium, etc.)
        local count = 0
        STATE.enforcementTimer = hs.timer.doWhile(
            function()
                count = count + 1
                local currentNow = hs.keycodes.currentSourceID()
                return count <= M.config.behavior.retryCount and currentNow ~= sourceID
            end,
            function()
                hs.keycodes.currentSourceID(sourceID)
                postJISKey(forceKey)
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
        STATE.alertTimer = hs.timer.doAfter(0.1, function()
            hs.alert.closeAll()
            hs.alert.show(label, M.config.behavior.alertDuration)
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
    local keyCode = event:getKeyCode()
    local flags = event:getFlags()
    
    -- Toggle IME
    if isBindingMatch(keyCode, flags, M.config.bindings.toggle) then
        hs.timer.doAfter(0, toggleIME)
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

--- Start IME control
function M.start(userConfig)
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

    -- 1. IME Change Watcher
    hs.keycodes.inputSourceChanged(function()
        local current = hs.keycodes.currentSourceID()
        if current and current ~= STATE.lastKnownIME then
            applyIME(current)
        end
    end)

    -- 2. Hotkey Watcher (EventTap)
    STATE.inputWatcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, handleKeyEvent)
    STATE.inputWatcher:start()

    -- 3. Watchdog
    hs.timer.doEvery(M.config.behavior.watchdogInterval, function()
        if STATE.inputWatcher and not STATE.inputWatcher:isEnabled() then
            STATE.inputWatcher:start()
            logger:w("Watchdog: Restarted input watcher")
        end
    end)

    -- 4. Window Focus Watcher
    local windowFilter = hs.window.filter.new()
    windowFilter:subscribe(hs.window.filter.windowFocused, function()
        hs.timer.doAfter(0.1, function() applyIME(hs.keycodes.currentSourceID()) end)
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
