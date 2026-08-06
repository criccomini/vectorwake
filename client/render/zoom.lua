-- How far a small window is allowed to stand back.
--
-- Decision 13 holds the camera at a fixed zoom: one world pixel per point,
-- so a bigger window sees further. Between a laptop and a monitor that is
-- fair and looks right. A phone is where the rule stops being either: a
-- 390-point screen sees a third of the world a desktop window does, while
-- rounds cross it at the same speed, so the phone player is flying with a
-- third of the warning time.
--
-- So the short axis of the view is guaranteed a minimum of the world: a
-- window whose smaller dimension is under SHORT_WORLD points backs the
-- camera off until that dimension holds SHORT_WORLD world pixels, down to a
-- floor past which the hulls would be too small to read and the shrink
-- stops. A desktop window is past the threshold and never changes; there is
-- no device test anywhere, only the window's own size, which is the same
-- rule decision 13 already applied.

local M = {}

-- What the short axis is guaranteed to hold, in world pixels. A desktop
-- window at 800 points of height sees 800; guaranteeing a phone 640 puts it
-- near that without shrinking its ships past reading size.
M.SHORT_WORLD = 640

-- The most the camera may stand back. At the floor a hull's 23-pixel reach
-- draws at about 14 points, which a thumb's distance still reads; past it
-- the fights turn into punctuation.
M.FLOOR = 0.6

-- The multiplier on the zoom, from the drawable size and the density that
-- turns it into points. One for any window whose short axis is already
-- SHORT_WORLD points; below that, the factor that makes the short axis hold
-- SHORT_WORLD, held at the floor.
function M.factor(w, h, density)
    local pts = math.min(w, h) / (density or 1)
    if pts <= 0 then return 1 end
    local f = pts / M.SHORT_WORLD
    if f >= 1 then return 1 end
    if f < M.FLOOR then return M.FLOOR end
    return f
end

return M
