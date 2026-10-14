-- Who may put a car on the chirp list. config.lua ships `mode = "everyone"`,
-- so the gate is open unless an owner narrows it; `tchirp.use` is the ace to
-- grant under `mode = "ace"`.
--
-- Only the ADD handler is gated. The other two client-facing events must stay
-- open, and collapsing all three into one gate reads as tidier and breaks the
-- feature:
--
--   RemoveChirpVehicle  sv_chirp.lua does not even OWNERSHIP-check it, because
--                       the officer who parks the car and the officer who takes
--                       it out are routinely different people. A forged remove
--                       costs one chirp that stops early. Gating it would also
--                       make client/cl_chirp.lua's optimistic local clear lie to
--                       the player: the button goes quiet before the server has
--                       refused.
--   RequestChirpList    playback is client-side, so the list goes to everybody
--                       or nobody hears anything. Gate the read and a civilian
--                       standing next to a chirping patrol car hears silence.
--
-- There is deliberately no `tchirp.admin` parent. Nothing here consults
-- `tlib.admin`, and the only admin-shaped thing in the resource is
-- `tchirp_diag`, registered `restricted` so FiveM's own `command.tchirp_diag`
-- covers it -- chosen over a check of tChirp's own so the command an owner runs
-- when their install is broken cannot itself need a working tLib module. An ACE
-- object no code reads is worse than none: in a server.cfg and in the docs it
-- reads as a grant that is doing something.

local gate = tlib.access.gate(Config.access, {
    key   = 'chirp',
    label = 'the chirp list',
})

--- @param playerId number
--- @return boolean
function tchirpMayChirp(playerId)
    return gate:allowed(playerId)
end

--- Structured gate state. Assert on this, not on the prose of describe().
--- @return table
function tchirpAccessReport()
    return gate:report()
end

--- One line of prose for `tchirp_diag`, written by the gate itself.
--- @return string
function tchirpAccessDescribe()
    return gate:describe()
end
