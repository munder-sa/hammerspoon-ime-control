-- =============================================================================
-- Hammerspoon IME Control Script
-- For details and license, see: https://github.com/munder-sa/hammerspoon-ime-control
--
-- 詳細は README.md を参照してください。
-- =============================================================================

-- =============================================================================
-- Logger Configuration / ログ設定
-- =============================================================================
hs.logger.defaultLogLevel = "warning"

-- =============================================================================
-- Constants / 定数定義
-- =============================================================================
local SOURCES = {
    ENG = "com.apple.keylayout.ABC",
    JPN = "com.google.inputmethod.Japanese.base" -- Google Japanese Input / Google日本語入力
}

local KEYCODES = {
    EISU = 102, -- JIS 'Eisu' key / JIS英数キー
    KANA = 104, -- JIS 'Kana' key / JISかなキー
    F15  = 113 -- Dummy key to refresh OS event loop / イベントループ更新用ダミーキー
}

-- =============================================================================
-- State Management / 状態管理
-- =============================================================================
local lastKnownIME = hs.keycodes.currentSourceID() or SOURCES.ENG
local alertTimer = nil

-- =============================================================================
-- Utilities / ユーティリティ
-- =============================================================================

--- Post a JIS key event (Down/Up)
--- JISキーイベント（英数/かな）を送信します
local function postJISKey(keyCode)
    hs.eventtap.event.newKeyEvent({}, keyCode, true):post()
    hs.eventtap.event.newKeyEvent({}, keyCode, false):post()
end

--- Forcefully apply IME source and synchronize caches
--- IME状態を強制適用し、アプリ（Chromium/Deskflow等）の状態を同期します
local function forceApplyIMESource(sourceID)
    -- 1. Re-notify the OS via API / API経由でOSに再通知
    hs.keycodes.currentSourceID(sourceID)
    
    -- 2. Synchronize internal state variable / 内部変数の同期
    lastKnownIME = sourceID
    
    -- 3. Simulate JIS key press to bypass app-level caching
    -- アプリ層のキャッシュを回避するため、JISキー入力をシミュレートします
    local forceKey = (sourceID == SOURCES.ENG) and KEYCODES.EISU or KEYCODES.KANA
    postJISKey(forceKey)
end

-- =============================================================================
-- Core Logic / メインロジック
-- =============================================================================

--- Refresh IME state on focus change
--- フォーカス切り替え時にIME状態をリフレッシュします
local function resetIMECache()
    hs.timer.doAfter(0.1, function()
        local actualSource = hs.keycodes.currentSourceID()
        forceApplyIMESource(actualSource)
    end)
end

--- Toggle between English and Japanese IME
--- 英数と日本語のIMEを交互に切り替えます
local function toggleIME()
    local current = hs.keycodes.currentSourceID()
    local nextSource = (current == SOURCES.ENG) and SOURCES.JPN or SOURCES.ENG
    
    local label = (nextSource == SOURCES.JPN) and "🇯🇵 日本語" or "Aa 英数"

    -- 1. Apply forcefully / 強制適用
    forceApplyIMESource(nextSource)

    -- 2. Refresh event loop / イベントループを更新
    postJISKey(KEYCODES.F15)

    -- 3. Delayed secondary attempt for Chromium/Deskflow
    -- ChromiumやDeskflowのための時間差・再試行
    hs.timer.doAfter(0.05, function()
        hs.keycodes.currentSourceID(nextSource)
    end)
    
    -- 4. Show visual alert / アラートを表示
    if alertTimer then alertTimer:stop() end
    alertTimer = hs.timer.doAfter(0.1, function()
        hs.alert.closeAll()
        hs.alert.show(label)
    end)
end

-- =============================================================================
-- Watchers / 監視設定
-- =============================================================================

-- 1. Watch for system-wide IME changes
-- システム全体のIME変更を監視
hs.keycodes.inputSourceChanged(function()
    local current = hs.keycodes.currentSourceID()
    if current ~= lastKnownIME then
        forceApplyIMESource(current)
    end
end)

-- 2. Watch for hotkeys (EventTap)
-- ホットキーの監視 (EventTap)
local events = hs.eventtap.event.types
local inputWatcher = hs.eventtap.new({events.keyDown}, function(event)
    local keyCode = event:getKeyCode()
    local flags = event:getFlags()
    
    -- F12 + Cmd + Shift -> Toggle IME
    if keyCode == hs.keycodes.map["f12"] and flags.cmd and flags.shift and not (flags.ctrl or flags.alt) then
        hs.timer.doAfter(0, toggleIME)
        return true
    end

    -- F11 + Shift -> Debug Info
    if keyCode == hs.keycodes.map["f11"] and flags.shift and not (flags.ctrl or flags.cmd or flags.alt) then
        local id = hs.keycodes.currentSourceID()
        hs.alert.show("OS Report: " .. id .. "\nScript State: " .. lastKnownIME)
        return true
    end
    
    return false
end)

inputWatcher:start()

-- Watchdog to ensure EventTap stays active
-- ウォッチドッグ
hs.timer.doEvery(30, function()
    if inputWatcher and not inputWatcher:isEnabled() then
        inputWatcher:start()
    end
end)

-- 3. Watch for window focus changes
-- ウィンドウフォーカスの変更を監視
local windowFilter = hs.window.filter.new()
windowFilter:subscribe(hs.window.filter.windowFocused, function()
    resetIMECache()
end)
