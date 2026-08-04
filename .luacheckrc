-- What the client's Lua is allowed to reach for.
--
-- This file exists to catch one class of bug, and it is worth naming because
-- nothing else in the toolchain catches it. Lua resolves a local at compile
-- time, so a function written above the `local` it uses does not see that
-- local at all: it compiles to a global read, the global is nil, and nothing
-- says so until the line runs. It shipped exactly that way once. `rolls` was
-- declared below the function that clears it, `init` ends by calling that
-- function, and every boot threw on `pairs(nil)`. The client still drew,
-- because everything above the last line of `init` had already run, so the
-- only visible symptom was that the audio device never woke up.
--
-- Declaring the real globals is what makes an accidental one stand out. The
-- list below is the whole surface this client has: Defold's engine modules,
-- the native extensions in client/ext and client/websocket, and nothing else.
-- Anything not on it is a mistake by construction.

std = "lua51"
max_line_length = 100

-- Two of luacheck's defaults are wrong for this client rather than for Lua.
--
-- An unused argument is usually a callback keeping the shape the engine calls
-- it with. `final(self)` has to take a self whether it reads one or not, and
-- renaming it to an underscore to satisfy a linter makes the signature harder
-- to match against Defold's manual, not easier.
--
-- An empty `if` branch is how everything culled is written here: the test that
-- says "off screen" reads forwards, and inverting it to satisfy the check
-- would nest the body of every draw loop one level deeper for nothing.
ignore = {"212", "542"}

read_globals = {
    -- Defold's engine API, the parts this client uses.
    "buffer", "go", "graphics", "gui", "hash", "html5", "http", "json",
    "msg", "pprint", "render", "resource", "socket", "sound", "sys",
    "timer", "vmath", "window",
    -- Ours. `sim`, `vwbuf` and `vwsfx` are registered by the simcore
    -- extension in client/ext/simcore; `websocket` by client/websocket.
    "sim", "vwbuf", "vwsfx", "websocket",
}

-- Defold calls these by name, so a script defines them as globals. Only in
-- the file kinds the engine loads that way: a misspelling in one of them is
-- a callback that is simply never called, which is its own silent failure.
local lifecycle = {
    "init", "final", "update", "fixed_update",
    "on_message", "on_input", "on_reload",
}
files["**/*.script"] = {globals = lifecycle}
files["**/*.gui_script"] = {globals = lifecycle}
files["**/*.render_script"] = {globals = lifecycle}

-- The test harness builds the stand-ins the engine would otherwise provide,
-- so it writes the globals every other file only reads.
files["client/tests/*.lua"] = {
    globals = {"sim", "vwbuf", "vwsfx", "websocket", "buffer", "go", "hash",
               "resource", "sound", "sys", "html5"},
}
