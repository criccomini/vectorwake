-- The Lua files this client ships still compile, and no function in them has
-- outgrown the sixty upvalues a VM allows one.
--
--     lua5.1 client/tests/upvalues_test.lua
--
-- An upvalue is a local from an enclosing scope that a function reaches, and
-- `arena.script` is a file of module handles, tuning constants and session
-- state with one nine-hundred-line frame function reaching most of them.
-- Adding one more local beside the others is the most ordinary edit in this
-- file and it is the edit that hits the ceiling.
--
-- What made that worth a test is how the failure reads. It is not a warning
-- and not a lint: the bundle simply does not build, and the error names the
-- line the function *starts* on plus an unrelated line number in the
-- surrounding chunk, so it points at a `function update(self, dt)` that has
-- been fine for months rather than at the constant just added. It also only
-- appears in the Defold build, twenty minutes into CI, after the engine has
-- already been fetched.
--
-- `luac -p` parses and compiles without running, which is the same front end
-- and the same limit, so the whole check is a syntax pass over the shipped
-- files. It costs a second and it fails on the machine that made the change.
--
-- The fix, when this does fail, is not to shave a local off whatever was added.
-- It is to gather a coherent group onto one table, the way `TUNE` and `static`
-- already are: a table is one upvalue however many numbers it holds.

local LIMIT = 60

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

-- Every Lua file the client ships, which is what the bundle compiles. The
-- tests themselves are not shipped and are not checked.
local function sources()
    local out = {}
    local find = io.popen("ls client/arena/*.lua client/arena/*.script "
                          .. "client/render/*.lua client/render/*.script 2>/dev/null")
    if not find then return out end
    for line in find:lines() do out[#out + 1] = line end
    find:close()
    return out
end

-- `luac -p` on one file: nil when it compiled, the compiler's complaint when
-- it did not. Read off stderr, which is where luac writes.
local function compile(path)
    local pipe = io.popen("luac5.1 -p " .. path .. " 2>&1", "r")
    if not pipe then return nil end
    local said = pipe:read("*a")
    pipe:close()
    if said == nil or said == "" then return nil end
    return (said:gsub("%s+$", ""))
end

local files = sources()
check("there are client sources to check", #files > 0,
      "found none; is this being run from the repository root?")

for _, path in ipairs(files) do
    local trouble = compile(path)
    -- Said as one check per file so a failure names the file rather than
    -- leaving somebody to bisect the list.
    check(path .. " compiles", trouble == nil, trouble)
    -- The ceiling has its own line, because "more than 60 upvalues" is the one
    -- compile error here that is about a limit rather than about a typo, and
    -- the two want different fixes.
    if trouble and trouble:find("upvalues", 1, true) then
        check(path .. " is under the upvalue ceiling", false,
              "a function reaches more than " .. LIMIT .. " enclosing locals; "
              .. "gather a group onto one table, as TUNE and static are")
    end
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
