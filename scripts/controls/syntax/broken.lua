-- Negative control for check:syntax: Lua that CANNOT PARSE.
--
-- Never reached by `bun run check:syntax` — scripts/controls/syntax/ is excluded
-- from its glob by name, with the reason written at the exclusion. Driven only by
-- `SYNTAX_CONTROL=1 bun run check:syntax`, which points the checker at this
-- directory and REQUIRES exit 1.
--
-- A missing `end`, deliberately, because that is the error that actually happens
-- and the one the gate's header names: it is invisible to `bun test` (which loads
-- no Lua at all) and invisible to the fengari suites (which only load the files
-- they are oracles for), so before this gate existed its first report was a
-- resource that refused to start on a live server.
--
-- ⚠️ Do not "fix" this file. It is red on purpose. Deleting it does not make the
-- gate pass — it makes the gate's control fail, which is the point.
local function tchirpControlBrokenOnPurpose(a, b)
    if a > b then
        return a
    -- no `end` for the `if`, and no `end` for the function
