-- Who may put a car on the chirp list. config.lua ships `mode = "everyone"`, so
-- the gate is open unless an owner narrows it; `tchirp.use` is the ace to grant
-- under `mode = "ace"`.
--
-- ⚠️ Only the ADD handler is gated. Gating the other two client-facing events
-- breaks the feature:
--
--   RemoveChirpVehicle  not even ownership-checked (see sv_chirp.lua) -- a
--                       forged remove costs one chirp that stops early. Gating
--                       it also makes cl_chirp.lua's optimistic local clear lie
--                       to the player: the button goes quiet before the server
--                       has refused.
--   RequestChirpList    playback is client-side, so the list goes to everybody
--                       or nobody hears anything. Gate the read and a civilian
--                       beside a chirping patrol car hears silence.

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
