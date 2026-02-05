-- =============================================================================
-- Hammerspoon IME Control Script
-- For details and license, see: https://github.com/munder-sa/hammerspoon-ime-control
-- =============================================================================

-- =============================================================================
-- 1. Configuration / 設定
-- =============================================================================
local CONFIG = {
    -- Input Source IDs
    sources = {
        eng = "com.apple.keylayout.ABC",
        jpn = "com.google.inputmethod.Japanese.base"
    },

    -- JIS Keycodes (Fixed for JIS keyboard emulation)
    keycodes = {
        eisu = 102,
        kana = 104,
        f15  = 113 -- Dummy key for event loop refresh
    },

    -- Watchdog interval (seconds)
    watchdogInterval = 30,

    -- Retry interval for Chromium-based apps (seconds)
    retryInterval = 0.1,
    retryCount = 5,

    -- Log level
    logLevel = "warning"
}

-- =============================================================================
-- 2. State Management / 内部状態
-- =============================================================================
local STATE = {
    lastKnownIME = hs.keycodes.currentSourceID() or CONFIG.sources.eng,
    alertTimer = nil,
    inputWatcher = nil,
    enforcementTimer = nil
}

hs.logger.defaultLogLevel = CONFIG.logLevel

-- =============================================================================
-- 3. Actions / アクション
-- =============================================================================

--- Post a JIS key event
local function postJISKey(keyCode)
    hs.eventtap.event.newKeyEvent({}, keyCode, true):post()
    hs.eventtap.event.newKeyEvent({}, keyCode, false):post()
end

--- Apply IME source and sync all layers (API, Physical Key, Cache)
local function applyIME(sourceID)
    -- Stop existing retry timer
    if STATE.enforcementTimer then
        STATE.enforcementTimer:stop()
        STATE.enforcementTimer = nil
    end

    -- First attempt
    hs.keycodes.currentSourceID(sourceID)
    STATE.lastKnownIME = sourceID
    
    local forceKey = (sourceID == CONFIG.sources.eng) and CONFIG.keycodes.eisu or CONFIG.keycodes.kana
    postJISKey(forceKey)

    -- Retry logic for Chromium-based apps
    local count = 0
    STATE.enforcementTimer = hs.timer.doWhile(
        function()
            count = count + 1
            local current = hs.keycodes.currentSourceID()
            return count <= CONFIG.retryCount and current ~= sourceID
        end,
        function()
            hs.keycodes.currentSourceID(sourceID)
            postJISKey(forceKey)
        end,
        CONFIG.retryInterval
    )
end

--- Toggle between English and Japanese
local function toggleIME()
    local current = hs.keycodes.currentSourceID()
    local target = (current == CONFIG.sources.eng) and CONFIG.sources.jpn or CONFIG.sources.eng
    local label  = (target == CONFIG.sources.jpn) and "🇯🇵 日本語" or "Aa 英数"

    applyIME(target)
    postJISKey(CONFIG.keycodes.f15)
    
    -- Visual feedback
    if STATE.alertTimer then STATE.alertTimer:stop() end
    STATE.alertTimer = hs.timer.doAfter(0.1, function()
        hs.alert.closeAll()
        hs.alert.show(label)
    end)
end

--- Refresh state on focus change
local function refreshIMECache()
    hs.timer.doAfter(0.1, function()
        applyIME(hs.keycodes.currentSourceID())
    end)
end

-- =============================================================================
-- 4. Watchers / 監視設定
-- =============================================================================

-- A. IME Change Watcher (System-wide)
hs.keycodes.inputSourceChanged(function()
    local current = hs.keycodes.currentSourceID()
    if current ~= STATE.lastKnownIME then applyIME(current) end
end)

-- B. Hotkey Watcher (EventTap for Deskflow compatibility)
local function setupInputWatcher()
    local types = hs.eventtap.event.types
    STATE.inputWatcher = hs.eventtap.new({types.keyDown}, function(event)
        local keyCode = event:getKeyCode()
        local flags = event:getFlags()
        
        -- CMD + SHIFT + F12 -> Toggle
        if keyCode == hs.keycodes.map["f12"] and flags.cmd and flags.shift and not (flags.ctrl or flags.alt) then
            hs.timer.doAfter(0, toggleIME)
            return true
        end

        -- SHIFT + F11 -> Debug
        if keyCode == hs.keycodes.map["f11"] and flags.shift and not (flags.ctrl or flags.cmd or flags.alt) then
            hs.alert.show(string.format("OS: %s\nScript: %s", hs.keycodes.currentSourceID(), STATE.lastKnownIME))
            return true
        end
        
        return false
    end)
    STATE.inputWatcher:start()
end

-- C. Watchdog (Ensures EventTap stays alive during heavy usage)
hs.timer.doEvery(CONFIG.watchdogInterval, function()
    if STATE.inputWatcher and not STATE.inputWatcher:isEnabled() then
        STATE.inputWatcher:start()
    end
end)

-- D. Window Focus Watcher
local windowFilter = hs.window.filter.new()
windowFilter:subscribe(hs.window.filter.windowFocused, refreshIMECache)

-- Initialize
setupInputWatcher()
