-- Which way is up when the world turns under the ship, and what that costs.
--
-- Decision 13 holds the camera at a fixed zoom and north at the top of the
-- screen, and that is still what every desktop and every phone that has not
-- asked otherwise gets. The one setting that changes it keeps the ship's nose
-- at the top instead and turns the world underneath, which is a phone answer:
-- a thumb has no tactile edge to stop a turn against, so the view doing the
-- turning is one thing a player does not have to hold.
--
-- The rule lives here rather than in the render script for the reason zoom.lua
-- does: a render script runs where CI cannot see a frame, and both of these
-- fail quietly. A wrong up vector is a world that turns the wrong way, and a
-- wrong extent is corners that go missing on exactly the diagonals a turn
-- spends most of its time on. Both are arithmetic, so both are checked as
-- arithmetic in client/tests/turn_test.lua.

local M = {}

-- The up vector for a view turned to `spin` radians, as two numbers rather
-- than a vmath.vector3 so this stays arithmetic a test can read without an
-- engine. Nil means north up, which is the whole of the ordinary case.
--
-- Heading zero is north, north is the simulation's -y, and the projection puts
-- -y at the top of the screen, so the ship's nose points along
-- (sin spin, -cos spin) in world space. The up vector names the world
-- direction that lands at the *bottom*, which is the opposite of that. Hence
-- the negated sine and the bare cosine, and hence north up coming out as
-- (0, 1) rather than (0, -1).
function M.up(spin)
    if not spin then return 0, 1 end
    return -math.sin(spin), math.cos(spin)
end

-- How much world has to be built to fill a turned frame.
--
-- A frame turned off the axes covers ground its own width and height do not
-- describe: at forty-five degrees the corners reach half a diagonal out. So
-- the arena is asked for the circumcircle's radius on both axes, which holds
-- for every angle.
--
-- The radius rather than the exact turned box, which would be tighter. These
-- numbers size a mesh buffer, and the exact box changes shape continuously
-- through a turn, so tracking it would reallocate that buffer every frame for
-- as long as a player held the stick over. A constant that is too generous
-- costs a portrait phone about two and a half times its starfield, once.
function M.extent(half_w, half_h, spin)
    if not spin then return half_w, half_h end
    local r = math.sqrt(half_w * half_w + half_h * half_h)
    return r, r
end

-- A world offset from the camera, in the directions the glass runs.
--
-- The camera turn is done by the view matrix, so everything drawn in world
-- space follows it without being told. Anything drawn in screen space over a
-- world position does have to be told, and the interface has two: a pilot's
-- nameplate and the bounty that drifts off their wreck. Both were a plain
-- subtraction while the frame was square to the world, and both would sit
-- where their hull would have been if nobody had turned the camera.
--
-- Turned by -spin, because the view turned by +spin: this is the same rotation
-- the up vector above applies, read the other way round. Screen x runs right
-- and screen y runs down, which is the simulation's own sense of y and the
-- reason there is no sign flip here.
function M.offset(spin, dx, dy)
    if not spin then return dx, dy end
    local c, s = math.cos(spin), math.sin(spin)
    return dx * c + dy * s, dy * c - dx * s
end

return M
