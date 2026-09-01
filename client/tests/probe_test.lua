-- What the client tells a harness about its own screen.
--
--     lua5.1 client/tests/probe_test.lua
--
-- Two things are worth pinning here, and neither is "the payload has a field
-- called x".
--
-- The first is the encoder. It is thirty lines of hand-written JSON because
-- the client has none, and a pilot who calls themselves `he said "hi"` is not
-- hypothetical: call signs are typed by players and go straight into this
-- string. An encoder that breaks on one takes the whole reading with it, and
-- the harness reads a parse error rather than a screen.
--
-- The second is the covered box. `ui.pick` keeps the first box of the highest
-- priority, so a row published at priority 0 behind a panel's glass is
-- unpressable, which is how the roster's fly-this-ship press was dead for
-- weeks. The probe exists to make that visible, so the test that matters is
-- that a covered box reports the thing that actually takes the press, not
-- itself.

package.path = "client/?.lua;" .. package.path

_G.sim = {}
_G.html5 = nil

local probe = require("arena.probe")

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local enc = probe.encode

-- --- the encoder -----------------------------------------------------------

check("a plain string", enc("hello") == '"hello"', enc("hello"))
check("a quote is escaped", enc('he said "hi"') == '"he said \\"hi\\""',
      enc('he said "hi"'))
check("a backslash is escaped", enc("a\\b") == '"a\\\\b"', enc("a\\b"))
check("a newline is not a literal newline",
      enc("a\nb") == '"a\\nb"', enc("a\nb"))
check("a tab is escaped", enc("a\tb") == '"a\\tb"', enc("a\tb"))
-- string.format("%q") writes a bell as \7, which JSON does not accept.
check("a control character becomes \\u", enc("a\7b") == '"a\\u0007b"',
      enc("a\7b"))

check("an integer keeps its digits", enc(42) == "42", enc(42))
check("a negative integer", enc(-7) == "-7", enc(-7))
check("a fraction", enc(1.5) == "1.5000", enc(1.5))
-- A non-finite number is not JSON. Left in, it is a parse error rather than a
-- reading, so the whole payload is lost to one bad divide.
check("nan is null", enc(0 / 0) == "null", enc(0 / 0))
check("infinity is null", enc(math.huge) == "null", enc(math.huge))

check("true", enc(true) == "true")
check("false", enc(false) == "false")
check("nil", enc(nil) == "null")

check("an array", enc({1, 2, 3}) == "[1,2,3]", enc({1, 2, 3}))
check("an empty table is an object", enc({}) == "{}", enc({}))
-- A field that is always a list has to encode as one when it is empty, or
-- every reader that asks a list for its length gets an object instead: the
-- harness reported a TypeError where it meant to report a timeout, and the
-- oracle watching for a client in a room with no ships stopped firing.
check("an empty list is a list", enc(probe.list({})) == "[]",
      enc(probe.list({})))
check("and a filled one is unchanged",
      enc(probe.list({1, 2})) == "[1,2]", enc(probe.list({1, 2})))
check("an object sorts its keys",
      enc({b = 2, a = 1}) == '{"a":1,"b":2}', enc({b = 2, a = 1}))
check("nesting", enc({a = {1, {b = "c"}}}) == '{"a":[1,{"b":"c"}]}',
      enc({a = {1, {b = "c"}}}))
-- The same screen twice has to encode the same, or a harness cannot tell a
-- still screen from a changing one.
check("two encodings of one table agree",
      enc({z = 1, a = 2, m = 3}) == enc({m = 3, a = 2, z = 1}))

-- --- the covered box -------------------------------------------------------
--
-- A stand-in for `ui` that publishes boxes the way a panel does: the head at
-- priority 1, the glass at 0, then a row at 0 inside the glass. `pick` is the
-- real rule, first-of-the-highest-priority, written the way ui.lua writes it.

-- `pick` answers with the winning box, not with its action. The first version
-- of this stand-in returned `action, value` instead, which is a signature the
-- real one has never had, and the probe written against it published every
-- box's `hits` as a table. It passed here and failed against the client on the
-- first run. A stand-in that is wrong about the signature is worse than none.
local function fake_ui(hits)
    return {
        hits = hits,
        pick = function(px, py)
            local best, bestpri
            for i = 1, #hits do
                local b = hits[i]
                if px >= b.x and px <= b.x + b.w
                   and py >= b.y and py <= b.y + b.h then
                    local pri = b.pri or 0
                    if not best or pri > bestpri then
                        best, bestpri = b, pri
                    end
                end
            end
            return best
        end,
    }
end

local hits = {
    {x = 0, y = 0, w = 400, h = 40, action = "land_back", pri = 1},
    {x = 0, y = 0, w = 400, h = 600, action = "panel_hold", pri = 0},
    -- Published after the glass, at the same priority: swallowed.
    {x = 20, y = 100, w = 360, h = 44, action = "land_pick_ship",
     value = 3, pri = 0},
    -- A row at priority 1 takes its own press even inside the same glass.
    {x = 20, y = 200, w = 360, h = 44, action = "land_list", value = 1,
     pri = 1},
}
local ui = fake_ui(hits)

-- The probe reports boxes at density 1, so CSS pixels are drawable pixels.
local function boxes_of(u)
    local out = {}
    for i = 1, #u.hits do
        local b = u.hits[i]
        local cx, cy = b.x + b.w / 2, b.y + b.h / 2
        local won = u.pick(cx, cy, false)
        out[b.action] = won and won.action or nil
    end
    return out
end

local resolved = boxes_of(ui)
check("the panel head takes its own press",
      resolved.land_back == "land_back", tostring(resolved.land_back))
check("a row at the glass's priority is swallowed by the glass",
      resolved.land_pick_ship == "panel_hold",
      tostring(resolved.land_pick_ship))
check("a row above the glass takes its own press",
      resolved.land_list == "land_list", tostring(resolved.land_list))
check("the glass takes a press on itself",
      resolved.panel_hold == "panel_hold", tostring(resolved.panel_hold))

-- --- arming ----------------------------------------------------------------
--
-- Off is the shipped state and has to cost nothing but the occasional ask.
-- The page has to say a number before anything is published.

local ran = {}
local function html5_saying(answer)
    return {
        run = function(js)
            ran[#ran + 1] = js
            return answer
        end,
    }
end

local touch = {used = false}
local menu = {}

probe.armed = false
probe.hz = 0
ran = {}
-- A page that has not armed it: asked once, then nothing published.
probe.finish({}, 0, html5_saying(""), touch, ui, menu)
check("a silent page publishes nothing", #ran == 1, #ran .. " calls")
check("and what it ran was the question",
      ran[1]:find("vwProbeHz", 1, true) ~= nil, ran[1])

ran = {}
-- Asked again only after the interval, not every frame.
probe.finish({}, 0.016, html5_saying(""), touch, ui, menu)
check("and it does not ask again the next frame", #ran == 0,
      #ran .. " calls")

check("no html5 at all is not an error",
      pcall(probe.finish, {}, 0, nil, touch, ui, menu))

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
