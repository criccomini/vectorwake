-- The format strip on a games row: drawn, in order, and dropped whole.
--
--     lua5.1 client/tests/specs_test.lua
--
-- The strip is three label-over-value stacks under the row's name, in the
-- catalog's own words, and it is the whole of the row under that name. What
-- is worth proving is that the words reach the frame at all (the wiring test
-- in directory_test.lua stops at the view), that the stacks keep their order
-- across both rows so the games read down the same columns, that a value
-- keeps its authored case, that the stacks sit under the name they are
-- about, and that a list squeezed out of its second line drops the strip
-- rather than drawing it over the name.

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

local harness = require("tests.ui_harness")
local layer = harness.layer()
local ui, state = harness.install()

local function rows()
    return {
        {label = "Chaos",
         specs = {{"teams", "1 v 1"}, {"time", "one life"},
                  {"scoring", "streak"}},
         index = 1, pick = true},
        {label = "Team Battle",
         specs = {{"teams", "4 v 4"}, {"time", "3:00"},
                  {"scoring", "kills"}},
         index = 2, pick = true},
    }
end

local function draw(w, h)
    state.n = 0
    ui.begin(layer, w, h, 1, false)
    ui.menu({depth = 2, sel = 1, rail = {}, rail_sel = 1, focus = "stage",
             home = true, closable = true, at = "play", rows = rows()})
    ui.finish()
end

-- Every word of the frame, with where it landed.
local function drawn()
    local out = {}
    for i = 1, state.n do
        local t = state.text[i]
        out[#out + 1] = {s = t.s, x = t.x, y = t.y}
    end
    return out
end

local function find(words, s)
    for _, t in ipairs(words) do
        if t.s == s then return t end
    end
    return nil
end

-- A phone's drawer, with room for the third line.
draw(390, 844)
local words = drawn()
check("the strip's labels reach the frame in the label register",
      find(words, "TEAMS") ~= nil and find(words, "SCORING") ~= nil)
check("and the values in the catalog's own case",
      find(words, "4 v 4") ~= nil and find(words, "one life") ~= nil
      and find(words, "kills") ~= nil,
      "kills drawn as " .. tostring(find(words, "kills") or find(words, "Kills")))
local teams1, time1 = find(words, "1 v 1"), find(words, "one life")
local teams2, time2 = find(words, "4 v 4"), find(words, "3:00")
check("stacks keep their order inside a row",
      teams1 and time1 and teams1.x < time1.x
      and teams2 and time2 and teams2.x < time2.x)
-- Under the name, and under that name rather than the other one: `state.text`
-- counts up from the foot, so a lower line on the screen is the smaller y.
-- The row is the name and the stacks now, and nothing between them.
local chaos, battle = find(words, "Chaos"), find(words, "Team Battle")
check("the stacks stand under the name they are about",
      chaos and teams1 and battle and teams2
      and teams1.y < chaos.y and teams1.y > battle.y
      and teams2.y < battle.y,
      string.format("Chaos at %s over %s, Team Battle at %s over %s",
                    tostring(chaos and chaos.y), tostring(teams1 and teams1.y),
                    tostring(battle and battle.y),
                    tostring(teams2 and teams2.y)))
local expected = {}
for _, r in ipairs(rows()) do
    expected[r.label] = true
    for _, spec in ipairs(r.specs) do
        expected[string.upper(spec[1])] = true
        expected[spec[2]] = true
    end
end
local extra = {}
for _, t in ipairs(words) do
    if not expected[t.s] then extra[#extra + 1] = t.s end
end
check("and the row is those two things and nothing else",
      #extra == 0, table.concat(extra, ", "))

-- A window too short for the second line. The rows squeeze, and a squeezed
-- row drops the strip whole rather than laying it over the name.
draw(390, 260)
local squeezed = drawn()
check("a squeezed list drops the strip rather than stacking it",
      find(squeezed, "TEAMS") == nil and find(squeezed, "4 v 4") == nil)
check("but keeps the names", find(squeezed, "Chaos") ~= nil)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
