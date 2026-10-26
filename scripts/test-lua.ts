// Runs tChirp's Lua suites: bun run test:lua
//
// tChirp is Lua all the way down — no NUI, no bundle — so `bun test` reaches
// none of it. Fengari is a Lua VM that runs under bun, which is how the suites
// run with no native interpreter on the machine. The same runner tLib, tDetector
// and tRadar use, kept identical on purpose.
//
// Suites are discovered off disk. A hardcoded list is the one way a runner fails
// silently: it keeps passing while the suite nobody added to it is the suite that
// would have caught the regression.
//
// EXIT CODES
//
//   0  every suite passed
//   1  a suite failed, discovery found nothing, or a control did not fail
//
// `LUA_CONTROL=1` is this gate's negative control; see the block below.
// ⚠️ Exit codes are read from `Bun.spawnSync().exitCode`, never from `$?` after a
// pipe — `… | head` hands you `head`'s status.
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const CONTROL = process.env.LUA_CONTROL === "1";

/**
 * Run one suite through the shim and hand back its exit code.
 *
 * `--package fengari-node-cli`: the `fengari` package ships no executable, and
 * the CLI that does is not a dependency here. Fetched into bunx's cache rather
 * than installed, so running the suites does not touch the package.json or
 * lockfile of a resource that ships to servers.
 */
function runSuite(relativePath: string, quiet = false): number {
  const result = Bun.spawnSync(
    [
      "bunx",
      "--bun",
      "--package",
      "fengari-node-cli",
      "fengari",
      "scripts/run-lua-suite.lua",
      relativePath,
    ],
    { cwd: root, stdout: quiet ? "pipe" : "inherit", stderr: quiet ? "pipe" : "inherit" }
  );
  // `exitCode` is null when the process was killed by a signal, which is a
  // failure and must not read as 0.
  return result.exitCode ?? 1;
}

async function discover(dir: string): Promise<string[]> {
  // Recursive, matching tLib's runner: a non-recursive `*.lua` skips any suite
  // filed into a subdirectory without saying so.
  return (await Array.fromAsync(new Bun.Glob("**/*.lua").scan({ cwd: resolve(root, dir) }))).sort();
}

// ── Negative control (LUA_CONTROL=1) ────────────────────────────────────────
//
// Three cases, all about the HARNESS rather than tChirp's behaviour. The suites
// under scripts/tests already assert both directions of every rule — every "X
// was accepted" has a matching "Y was rejected" — so a dead validator trips one
// half of a pair. What has no floor under it is whether a failing suite goes RED,
// and that is not hypothetical: fengari's CLI prints an unhandled Lua error and
// still exits ZERO.
if (CONTROL) {
  const failures: string[] = [];

  for (const [label, suite] of [
    ["a false assertion", "scripts/controls/lua/lua-fails.lua"],
    ["an error raised at the top level", "scripts/controls/lua/lua-throws.lua"],
  ] as const) {
    const code = runSuite(suite, true);
    if (code === 0) {
      failures.push(
        `${suite} (${label}) exited 0. The Lua gate cannot fail there, so every ` +
          "passing run of `bun run test:lua` has been measuring nothing."
      );
      console.log(`  NOT FAILING  ${suite} — exit 0`);
    } else {
      console.log(`  failed as required  ${suite} — exit ${code} (${label})`);
    }
  }

  // The vacuous-pass guard. Pointed at a directory that exists and holds no
  // `.lua`, because that is what a renamed or moved suite directory looks like.
  const empty = await discover("scripts/controls/lua/empty");
  if (empty.length !== 0) {
    failures.push(
      "scripts/controls/lua/empty is not empty, so the vacuous-pass guard in the " +
        "runner below was not actually exercised."
    );
  } else {
    console.log("  discovery over an empty directory found 0 suites, as required");
  }

  console.log("");
  if (failures.length > 0) {
    for (const f of failures) console.error(`FAIL  ${f}`);
    process.exit(1);
  }
  console.log("PASS  the tChirp Lua gate is demonstrably capable of failing.");
  process.exit(0);
}

const suites = await discover("scripts/tests");
if (suites.length === 0) {
  // Thrown, not warned. An empty suite directory produces a green run that
  // proves nothing, and that is indistinguishable from a healthy one in CI.
  throw new Error("scripts/tests contains no Lua suites; this run would pass vacuously");
}

let failed = 0;
for (const suite of suites) {
  const code = runSuite(`scripts/tests/${suite}`);
  if (code !== 0) {
    console.error(`FAIL scripts/tests/${suite} (exit ${code})`);
    failed += 1;
  }
}

if (failed > 0) {
  console.error(`\n${failed} of ${suites.length} tChirp Lua suites failed`);
  process.exit(1);
}

console.log(`PASS: ${suites.length} tChirp Lua suites`);
