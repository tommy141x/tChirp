/**
 * Parses every Lua file in the resource without executing it, in about a second:
 * `bun run check:syntax`
 *
 * The fengari suites only load the files they are oracles for, and nothing
 * parses the manifest-adjacent files at all. A missing `end` in anything
 * uncovered first surfaces as a resource that REFUSES TO START on a live server.
 *
 * Suites are parsed too: the test runner reports a suite that does not parse as a
 * failure with no message, so this turns that into a named file and a line
 * number. Files are discovered off disk, because a hardcoded list keeps passing
 * while the file nobody added to it is the one that is broken.
 *
 * EXIT CODES
 *
 *   0  every file parses
 *   1  a file failed to parse
 *   2  the gate could not measure — zero files found. ⚠️ NOT a pass: a glob that
 *      stops matching after a move reports no syntax errors, and "no errors" and
 *      "nothing was read" are otherwise the same green.
 *
 * ⚠️ Read the exit code from `Bun.spawnSync().exitCode`, never from `$?` after a
 * pipe: `… | head` hands you `head`'s status.
 *
 * `SYNTAX_CONTROL=1` is this gate's negative control — see the block below.
 * `--root=DIR` points the scan somewhere else and exists only for that control.
 */
import { resolve } from "node:path";

const SELF = "check:syntax";

/**
 * The control's fixture directory, excluded from the real scan because it holds
 * a file that cannot parse by design.
 *
 * ⚠️ scripts/controls/lua/ is NOT excluded. Those two fixtures are a false
 * assertion and a top-level `error()`; both are valid Lua and must parse, or the
 * Lua gate's control would be measuring a syntax error rather than the hazard it
 * names.
 */
const CONTROL_FIXTURES = "scripts/controls/syntax/";

async function scan(root: string): Promise<string[]> {
  // Separators are normalised before filtering. Bun.Glob hands back backslashes
  // on Windows, so a filter written against "node_modules/" silently matches
  // nothing there — the difference between skipping a dependency tree and
  // parsing it.
  return (await Array.fromAsync(new Bun.Glob("**/*.lua").scan({ cwd: root })))
    .map((p) => p.replaceAll("\\", "/"))
    .filter((p) => !p.startsWith("node_modules/"))
    .filter((p) => !p.startsWith(CONTROL_FIXTURES))
    .sort();
}

/** Parse every Lua file under `root`. Returns this gate's exit code. */
async function check(root: string, quiet = false): Promise<number> {
  const files = await scan(root);

  if (files.length === 0) {
    console.error(
      `${SELF}: found no Lua files under ${root}. Exit 2, not 0 — a run that read ` +
        "nothing has proven nothing, and reporting it as a pass is how a moved " +
        "directory becomes a silent gate."
    );
    return 2;
  }

  const result = Bun.spawnSync(
    [
      "bunx",
      "--bun",
      "--package",
      "fengari-node-cli",
      "fengari",
      // Absolute: the Lua shim is always this resource's, whatever `root` is.
      resolve(import.meta.dir, "syntax-check.lua"),
      ...files,
    ],
    {
      cwd: root,
      stdout: quiet ? "pipe" : "inherit",
      stderr: quiet ? "pipe" : "inherit",
    }
  );
  // `exitCode` is null when the process was killed by a signal, which is a
  // failure and must not read as 0.
  return result.exitCode ?? 1;
}

const ROOT = resolve(import.meta.dir, "..");
const rootArg = process.argv.find((a) => a.startsWith("--root="));

// ── Negative control (SYNTAX_CONTROL=1) ─────────────────────────────────────
//
// Both of this gate's failure modes are invisible from a green run: the glob
// could stop matching, or the Lua shim's `loadfile` could stop being consulted.
// Either way every subsequent run reports "all files parse".
//
// ⚠️ THE DECOY CASE IS NOT OPTIONAL. A harness that has stopped reading exit
// codes reports every case as failing, which is what a correct run of the two
// red cases looks like. So the real resource root must still come back GREEN.
if (process.env.SYNTAX_CONTROL === "1") {
  const fixtures = resolve(ROOT, CONTROL_FIXTURES);
  const failures: string[] = [];

  const expect = async (label: string, root: string, want: number) => {
    const got = await check(root, true);
    if (got === want) {
      console.log(`  as required  exit ${got}  ${label}`);
    } else {
      failures.push(`${label}: wanted exit ${want}, got ${got}`);
      console.log(`  WRONG        exit ${got} (wanted ${want})  ${label}`);
    }
  };

  // 1. A file that cannot parse. The whole claim of the gate.
  await expect("a Lua file with a missing `end`", fixtures, 1);

  // 2. A directory that exists and holds no .lua — what a renamed or moved
  //    source tree looks like. Must be 2, the cannot-measure code, never 0.
  await expect("a directory with no Lua in it", resolve(fixtures, "empty"), 2);

  // 3. The decoy. Must stay green, or the two cases above prove nothing.
  await expect("tChirp's real source tree, which must stay GREEN", ROOT, 0);

  console.log("");
  if (failures.length > 0) {
    for (const f of failures) console.error(`FAIL  ${f}`);
    process.exit(1);
  }
  console.log(`PASS  ${SELF} is demonstrably capable of failing, and of passing.`);
  process.exit(0);
}

process.exit(await check(rootArg ? resolve(rootArg.slice("--root=".length)) : ROOT));
