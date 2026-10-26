-- Entry point for every Lua suite under scripts/tests, run from the resource root:
--   bunx --bun fengari scripts/run-lua-suite.lua scripts/tests/<suite>.lua
--
-- It exists for one reason: fengari's CLI can print an unhandled Lua error while
-- still exiting zero, so a suite that blew up on its first line would be reported
-- as a pass. Every suite exception becomes a non-zero exit here instead.
--
-- The same shim tLib and tDetector use. Each suite loads the files it is an
-- oracle for, with its own host stubs.
local ok, err = xpcall(function()
    dofile(assert(arg[1], 'Suite path required'))
end, debug.traceback)
if not ok then print(err); os.exit(1) end
