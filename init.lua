-- =============================================================================
-- Hammerspoon Configuration Entry Point
-- For details and license, see: https://github.com/munder-sa/hammerspoon-ime-control
-- =============================================================================

-- Load IME control module
local ime = require("ime")

-- Start IME control with default settings
-- You can customize settings by passing a table to ime.start()
ime.start({
    -- Example customization:
    -- behavior = {
    --     showAlert = true,
    --     alertDuration = 0.8
    -- }
})

-- Automatically reload configuration when init.lua or ime.lua is updated
local function reloadConfig(files)
    local doReload = false
    for _, file in ipairs(files) do
        if file:sub(-4) == ".lua" then
            doReload = true
        end
    end
    if doReload then
        hs.reload()
    end
end
local myWatcher = hs.pathwatcher.new(hs.configdir, reloadConfig):start()
hs.alert.show("Hammerspoon Config Loaded")
