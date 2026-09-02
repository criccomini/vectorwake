-- What a kill line says, and the figure on the end of it.
--
--     lua5.1 client/tests/kill_line_test.lua
--
-- The feed says who took whom. Since nothing is paid for a kill any more, the
-- rating is the only way two of them differ, and it used to be said in exactly
-- one place: a figure drifting off the wreck for a second and a half, in the
-- world, where a pilot who is looking anywhere else never sees it. The line in
-- the corner stands for nine seconds and said nothing about it.
--
-- So the figure goes on the line as well, and the point of this file is that
-- the two cannot disagree. One condition decides whether a death moved this
-- pilot's rating; the wreck and the line both hang off it, and both print the
-- same number through the same formatter. The clock the wreck's copy runs on
-- is at the foot of the file, since that is the other half of whether a figure
-- is read at all.
--
-- `arena.script` is a Defold script and cannot be required here, so this pulls
-- `drain_announced` out and runs it, which is what column_test and
-- landing_test do with the same file for the same reason.

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local pal = require("arena.palette")
-- The real interface module, for the one thing this needs off it: the
-- formatter both the wreck and the line print through.
local ui = require("tests.ui_harness").install({})

local f = assert(io.open("client/arena/arena.script"))
local src = f:read("*a")
f:close()

local body = src:match("local function drain_announced%(%)(.-)\nend\n")
check("the arena has a drain_announced to run", body ~= nil)
if not body then os.exit(1) end

-- The seat this test is flown from, and the two it fights.
local ME, THEM = 3, 1

-- One drain over one announced death, from whichever seat is asked for.
-- Returns the line the feed got, the color it got, and every figure the
-- wreck was handed.
local function drain(kill, watching)
    local lines, floats = {}, {}
    local env = {
        ui = {signed = ui.signed,
              payout = function(x, y, n)
                  floats[#floats + 1] = {x = x, y = y, n = n}
              end},
        sim = {ship_x = function(i) return 100 + i end,
               ship_y = function(i) return 200 + i end},
        pal = pal,
        net = {kills = {kill}},
        me = ME,
        watching = watching or false,
        drain_no_team = function() end,
        pilot_named = function(i) return {"P" .. i} end,
        notify = function(text, col, mine)
            lines[#lines + 1] = {text = text, col = col, mine = mine}
        end,
    }
    -- The arena runs under the standard library like everything else; only
    -- what it reaches out of its own file is stood in for above.
    setmetatable(env, {__index = _G})
    local chunk = assert(loadstring("return function()" .. body .. "\nend",
                                    "drain"))
    setfenv(chunk, env)
    chunk()()
    return lines[1], floats
end

-- The words on the end of a line, which is where the figure lands. A table
-- part is a name and a string part is the interface talking, and a line that
-- ends on a name has ended on nothing this file is asking about.
local function tail(line)
    local t = line and line.text
    local last = t and t[#t]
    return type(last) == "string" and last or nil
end

-- The figure on the end of a line, or nil where there is none.
local function figure(line)
    local last = tail(line)
    return last and last:match("^ ([%+%-]%d+)$") or nil
end

-- --- the three lines that are yours ----------------------------------------
--
-- A kill, a death and a kill you helped with. Every one of them moved your
-- rating and every one of them says by how much, because a rating that moves
-- in silence in one direction and out loud in the other is a rating nobody
-- trusts. That was the argument for the figure over the wreck and it is the
-- same argument here.

local line, floats = drain({killer = ME, victim = THEM, gain = 12})
check("a kill of yours ends in what it paid your rating",
      tail(line) == " +12", tostring(tail(line)))
check("and is lit in the payout green", line.col == pal.PAID)
check("and floats the same number off the wreck",
      #floats == 1 and floats[1].n == 12,
      #floats .. " figures")

line = drain({killer = THEM, victim = ME, gain = -9})
check("a death of yours ends in what it cost", tail(line) == " -9",
      tostring(tail(line)))
check("and is lit in the feed's red", line.col == pal.HURT)

line = drain({killer = THEM, victim = 2, assist = true, gain = 3})
check("a kill you helped with says so and then says what it was worth",
      line.text[#line.text - 1] == ", you assisted"
      and tail(line) == " +3", tostring(tail(line)))
check("and is lit in the assist green", line.col == pal.ASSIST)

-- A kill that moved nothing still prints its zero. The kill was yours, and a
-- figure that failed to arrive reads as a fault rather than as a nought.
line = drain({killer = ME, victim = THEM, gain = 0})
check("a kill of yours that paid nothing still prints a zero",
      tail(line) == " +0", tostring(tail(line)))

-- --- and the lines that are not --------------------------------------------

line, floats = drain({killer = 0, victim = 2, gain = 0})
check("somebody else's kill carries no figure", figure(line) == nil,
      tostring(tail(line)))
check("and floats nothing off a wreck that is not yours", #floats == 0)
check("and stays the feed's own color", line.col == nil)

-- From the stands there is no rating to move, and the sentinel seat a watcher
-- holds is also the killer on a wall death, so a figure here would land on
-- every rock anybody flew into.
line, floats = drain({killer = ME, victim = THEM, gain = 12}, true)
check("a watcher is told nothing about a rating", figure(line) == nil,
      tostring(tail(line)))
check("and gets no figure over the wreck either", #floats == 0)

-- --- one rule, both places -------------------------------------------------
--
-- The figure and the line are written by one condition, so a death cannot
-- float a number the corner disagrees with. This walks the cases and asks
-- only that the two answer together, whatever the answer is.
for _, case in ipairs({
    {killer = ME, victim = THEM, gain = 12},
    {killer = THEM, victim = ME, gain = -9},
    {killer = THEM, victim = 2, assist = true, gain = 3},
    {killer = ME, victim = THEM, gain = 0},
    {killer = 0, victim = 2, gain = 0},
    {killer = 255, victim = ME, gain = -4},
    {killer = ME, victim = THEM},
}) do
    local l, fl = drain(case)
    local said = figure(l)
    local flew = fl[1] and ui.signed(fl[1].n)
    check("the line and the wreck agree on a kill by " .. case.killer
          .. " of " .. case.victim, said == flew,
          tostring(said) .. " vs " .. tostring(flew))
end

-- Signed in both directions and signed at zero, which is the whole of what
-- the two share.
check("the formatter signs a gain", ui.signed(7) == "+7", ui.signed(7))
check("and a loss", ui.signed(-7) == "-7", ui.signed(-7))
check("and nought, which is a gain", ui.signed(0) == "+0", ui.signed(0))

-- --- how long the figure over the wreck stands -----------------------------
--
-- A second and a half was long enough to notice and not long enough to read.
-- The glance that finds a number over a wreck is the second glance, and by the
-- time a pilot who has just taken somebody has one to spare the figure had
-- gone. What is pinned here is what Chris asked for rather than the constant
-- behind it: a number solid for most of a second, still legible at two, and
-- off the screen before three.
do
    local payouts = require("arena.ui_payouts").new()
    payouts:add(0, 0, 0, 12)

    local function alpha_at(t)
        local seen = nil
        payouts:each(t, function(_, _, a) seen = a end)
        return seen
    end

    check("a figure is at full strength half a second in",
          alpha_at(0.5) == 1, tostring(alpha_at(0.5)))
    local late = alpha_at(2.0)
    check("still readable at two seconds", late ~= nil and late > 0.2,
          tostring(late))
    check("and gone before three", alpha_at(3.0) == nil,
          tostring(alpha_at(3.0)))
    -- The list compacts itself in the pass that draws it, so a room killing
    -- fast does not grow one.
    check("and drops itself once it has gone", #payouts.items == 0,
          #payouts.items .. " left")
end

os.exit(fails == 0 and 0 or 1)
