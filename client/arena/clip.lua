-- The clipboard, where there is one.
--
-- One credential is ever copied through here, the account key, which is why
-- this is twenty lines rather than a text field: the game has no text entry
-- anywhere and is not getting any. See the note in menu.lua about the address
-- field that was tried and removed.
--
-- Reading is asynchronous and this engine's JS bridge is not, so the read is
-- started and the answer is picked up on a later frame, the same shape the
-- fullscreen lock check uses. Nothing here fails loudly: a browser that
-- refuses the clipboard leaves the key to be typed, which is the path that
-- has to work anyway.

local M = {}

-- Whether the machine has one at all. Off the web there is no bridge, so the
-- interface asks this before it offers a paste.
function M.have()
    return html5 ~= nil
end

function M.copy(text)
    if not M.have() then return false end
    -- Quoted through the JSON escape the sound layer already trusts for its
    -- own strings: a key is base32 and dashes, so this is belt and braces.
    local safe = string.gsub(text or "", "['\\\\]", "")
    return pcall(html5.run,
                 "navigator.clipboard && navigator.clipboard.writeText('"
                 .. safe .. "')")
end

-- Start a read. The answer lands in `take` on some later frame, or never.
function M.ask()
    if not M.have() then return false end
    return pcall(html5.run,
                 "window.vwClip = '';" ..
                 "navigator.clipboard && navigator.clipboard.readText()" ..
                 ".then(function(t){window.vwClip = t || ''})" ..
                 ".catch(function(){window.vwClip = ''})")
end

-- What the last read produced, once, and nothing until there is something.
function M.take()
    if not M.have() then return nil end
    local ok, r = pcall(html5.run,
                        "(function(){var t = window.vwClip || '';" ..
                        "window.vwClip = ''; return t})()")
    if not ok or type(r) ~= "string" or r == "" then return nil end
    return r
end

return M
