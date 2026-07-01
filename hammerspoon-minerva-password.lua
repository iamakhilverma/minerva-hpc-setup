-- hammerspoon-minerva-password.lua
-- Optional macOS convenience: a hotkey CHORD that types your Minerva (Mount Sinai
-- SSO) password from the macOS Keychain into the focused window — the ssh
-- "password:" prompt, a browser login field, VPN, etc.
--
-- The password is NEVER written to this file or the repo. It lives encrypted in the
-- login Keychain; this script only looks it up at the moment you press the chord,
-- and only fires on that keypress (so it can never drive a background login storm).
--
-- Chord:  ⌃⌥⌘M  then  P     (M enters the "Minerva" mode, P = Password)
--         Esc cancels the mode without typing anything.
--
-- Setup (see README → "Type your Minerva password with a hotkey"):
--   1. brew install --cask hammerspoon      # then grant it Accessibility
--   2. security add-generic-password -s minerva-sso -a "$USER" -w
--   3. load this file from ~/.hammerspoon/init.lua, e.g.:
--        dofile(os.getenv("HOME") ..
--          "/Documents/minerva-hpc-setup/hammerspoon-minerva-password.lua")
--   4. Hammerspoon menu-bar icon → Reload Config
--
-- To change the chord or behaviour, edit the CONFIG block below and reload.

-- ---- CONFIG -----------------------------------------------------------------
local KEYCHAIN_SERVICE = "minerva-sso"        -- must match the -s value you stored
local CHORD_MODS       = { "ctrl", "alt", "cmd" }
local CHORD_KEY        = "M"                   -- enter the Minerva mode
local ACTION_KEY       = "P"                   -- P = type the Password
local AUTO_SUBMIT      = false                 -- true = press Return after typing
-- -----------------------------------------------------------------------------

local minerva = hs.hotkey.modal.new(CHORD_MODS, CHORD_KEY)

function minerva:entered()
  hs.alert.show("Minerva — press P for password  (Esc to cancel)", 1.5)
end

local function typePassword()
  minerva:exit()
  -- Full path to `security` so it works regardless of Hammerspoon's PATH.
  local out, ok = hs.execute(
    "/usr/bin/security find-generic-password -s '" .. KEYCHAIN_SERVICE .. "' -w 2>/dev/null")
  local pw = (out or ""):gsub("%s+$", "")
  if not ok or pw == "" then
    hs.alert.show("Minerva: no '" .. KEYCHAIN_SERVICE .. "' password in Keychain")
    return
  end
  hs.eventtap.keyStrokes(pw)
  if AUTO_SUBMIT then hs.eventtap.keyStroke({}, "return") end
end

minerva:bind({}, ACTION_KEY, typePassword)
minerva:bind({}, "escape", function() minerva:exit() end)

return minerva
