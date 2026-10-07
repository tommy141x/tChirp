-- Parses the paths handed to it and reports the ones that do not. Driven by
-- scripts/check-syntax.ts, which decides WHICH files; this file only decides
-- what "parses" means, and `loadfile` is the answer — it compiles the chunk and
-- never runs it, so a file with side effects at file scope (every one of
-- tChirp's shared scripts) is safe to point at.
--
-- The same shim tUnit uses, kept identical on purpose.
local paths = { ... }
local bad = 0
for _, path in ipairs(paths) do
  local chunk, err = loadfile(path)
  if not chunk then
    print('SYNTAX   ' .. path)
    print('         ' .. tostring(err))
    bad = bad + 1
  else
    print('ok       ' .. path)
  end
end
if bad > 0 then print(('\n%d file(s) failed to parse'):format(bad)); os.exit(1) end
print(('\nall %d files parse'):format(#paths))
