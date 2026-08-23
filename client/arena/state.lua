-- What the arena and the interface both need to see.
--
-- Defold gives a collection's components no defined update order, and the
-- text of the interface lives in a gui component while everything that knows
-- what to say lives in the arena script. Rather than message the strings
-- across every frame, both sides share this table: `shared_state` is on in
-- game.project, so `require` hands them the same one.
--
-- The arena writes. The interface reads. A frame of lag either way is
-- invisible at 60 Hz and costs nothing to allow.

return {
    -- Text the interface should draw this frame, rebuilt every frame by
    -- arena/ui.lua: {s, x, y, px, col, pivot}, in gui pixel space.
    text = {},
    n = 0,          -- how many entries of `text` are live
    version = 0,    -- bumped on every rebuild, so the gui can skip idle frames
    -- How many of those the gui will actually draw. The gui script builds
    -- this many nodes and silently drops the rest, so the number lives here,
    -- where the writer can be tested against it: the podium with the
    -- scoreboard open queued past the old pool of 128 and the phrase chips,
    -- drawn last, lost their words with nothing anywhere saying so.
    -- podium_test measures the worst frame against this; vwui.gui must hold
    -- at least this many nodes.
    TEXT_POOL = 320,
}
