// Runs tChirp's Lua suites: bun run test:lua
//
// tChirp is Lua all the way down — there is no NUI and no bundle, so `bun test`
// reaches none of it. Before this runner existed every change to it was
// unexecuted: the resource had no tests of any kind, and the only way to find out
// whether a config edit or a provider change worked was to start a FiveM server.
//
// Fengari is a Lua VM that runs under bun, so "there is no Lua interpreter on
// this machine" turns out to be true only of native Lua. The same runner tLib,
// tDetector and tRadar use, kept identical on purpose.
//
// Suites are discovered off disk rather than listed here. A hardcoded list is the
// one way a runner fails silently: it keeps passing while the suite nobody added
// to it is the suite that would have caught the regression.
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");

// Recursive, matching tLib's runner: a non-recursive `*.lua` skips any suite
// filed into a subdirectory without saying so.
const suites = (
  await Array.fromAsync(new Bun.Glob("**/*.lua").scan({ cwd: resolve(root, "scripts/tests") }))
).sort();
if (suites.length === 0)
  throw new Error("scripts/tests contains no Lua suites; this run would pass vacuously");

let failed = 0;
for (const suite of suites) {
  // `--package fengari-node-cli`: the `fengari` package itself ships no
  // executable, and the CLI that does is not a dependency of this resource.
  // Fetched into bunx's own cache rather than installed, so running the suites
  // does not touch the package.json or lockfile of a resource that ships to
  // servers.
  const result = Bun.spawnSync(
    [
      "bunx",
      "--bun",
      "--package",
      "fengari-node-cli",
      "fengari",
      "scripts/run-lua-suite.lua",
      `scripts/tests/${suite}`,
    ],
    { cwd: root, stdout: "inherit", stderr: "inherit" }
  );
  if (result.exitCode !== 0) {
    console.error(`FAIL scripts/tests/${suite}`);
    failed += 1;
  }
}

if (failed > 0) process.exit(1);

console.log(`PASS: ${suites.length} tChirp Lua suites`);
