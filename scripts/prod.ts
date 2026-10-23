/**
 * `bun run prod` — cut the release zip.
 *
 * Until this existed tChirp had no release path at all. The only artifact it had
 * ever shipped was the committed `tChirp.zip` that .gitignore now names: a
 * hand-made copy of the source files beside it, which the gitignore comment
 * records as having left the repository holding two versions of the resource
 * with nothing to say which one a server had installed. "Releasable" was the
 * one thing the resource could not do.
 *
 * Modelled on tDB's, which is the right comparator: both are MIT, unescrowed,
 * Lua all the way down, and have no NUI bundle to build. There is nothing here
 * to obfuscate and no provenance token to arm, so what is left is the part that
 * actually goes wrong — deciding what ships.
 */
import { existsSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import AdmZip from "adm-zip";
import {
  assertManifestStaged,
  checkStagedTree,
  createZip,
  failing,
  formatFindings,
  stageFiles,
  step,
} from "../../tLib/shared/ts/build/index.ts";

const ROOT = resolve(join(import.meta.dir, ".."));
// Everything generated lands under one root, so .gitignore needs a single rule —
// and it already has it: `.build/`.
const DIST = join(ROOT, ".build", "dist");

// An allowlist, not a list of things to leave out. A denylist ships anything
// nobody thought to name; naming what ships means a new file is ABSENT from the
// release until someone adds it here, and both directions are checked below, so
// an unlisted runtime file fails the build loudly instead of shipping broken.
//
// Listed file by file rather than as `client`, `server`, `shared`: those three
// directories hold exactly the manifest's scripts today, so a tree-level entry
// would be shorter and identical — right up to the first helper, fixture or
// note filed next to them, which would then ship silently. tDB and tDetector
// both name files; tAFK's comment records what the other choice cost it.
//
// Deliberately absent: `scripts/` (the gates and the release packer itself —
// a release already has what they produce), `docs/` (published to
// timmygstudios.com by .gitea/workflows/docs.yml, not to a server owner),
// `node_modules/`, `.build/`, and the repo's own tooling — package.json,
// bun.lock, biome.json, .githooks, .gitea.
//
// `config.local.lua` cannot appear here and must never be staged: it is the
// developer's real credentials, gitignored, and overlaid onto Config at server
// start by tlib.secrets. The tracked `config.lua` ships with its blanks, which
// is what makes an update safe to unzip over a live install — createZip's
// sanitizer re-checks that below.
const INCLUDE = [
  "fxmanifest.lua",
  "LICENSE",
  // The install and configuration instructions a zip is the only copy of. The
  // full docs are on the site; a server owner who downloaded a zip has this.
  "README.md",
  "config.lua",
  "shared/config-spec.lua",
  "client/cl_sirens.lua",
  "client/cl_chirp.lua",
  // The /tchirp dialog. It shipped in the manifest and not in this list, so
  // `bun run prod` has refused to build since 55bfde8 -- which is the gate
  // working: a zip without it loads and then errors on the command.
  "client/cl_menu.lua",
  "server/sv_access.lua",
  "server/sv_chirp.lua",
  "server/sv_version.lua",
];

// Both directions. `stageFiles` throws on an included path that has stopped
// existing — a rename or a move; `assertManifestStaged` throws on a path
// fxmanifest.lua declares that nobody added to INCLUDE — a release that builds
// clean and then fails at load on someone's server, reported to the player
// rather than to whoever cut the release. Neither check can see the other's
// failure, which is why both are here.
//
// ── ⚠️ BOTH NETS WERE WATCHED FAILING, NOT ASSUMED ──────────────────────────
//
// They are the whole reason the allowlist is safe to maintain by hand, so
// "an unlisted runtime file fails the build loudly" was measured rather than
// reasoned about. There is no permanent control script for it: the two checks
// are tLib's, shared with eight other resources, and tLib's own
// `check:regression` owns their fixtures — a per-resource control here would be
// a ninth copy of a test of tLib. These are the measurements, reproducible by
// redoing either edit:
//
//   · `client/cl_chirp.lua` removed from INCLUDE → exit 1,
//     "fxmanifest.lua names 1 path(s) the release does not stage:
//      client/cl_chirp.lua". So an unlisted runtime file cannot ship silently.
//   · a `data.json` planted at the root and added to INCLUDE → exit 1,
//     R-DATA-FILE, 1 finding. So runtime state cannot reach the archive.
assertManifestStaged(readFileSync(join(ROOT, "fxmanifest.lua"), "utf8"), INCLUDE);

stageFiles(ROOT, DIST, INCLUDE);

// MIT requires the notice in every copy, and the only thing putting it there is
// the `"LICENSE"` line in the hand-maintained list above. `assertManifestStaged`
// cannot cover it: it compares against fxmanifest.lua, which declares no
// LICENSE and no README because neither is a script. MEASURED: deleting that one
// line built green and produced a zip of 10 Lua files with no licence in it.
const licence = join(DIST, "LICENSE");
if (!existsSync(licence) || statSync(licence).size === 0) {
  console.error("No LICENSE in the staged tree — add it back to INCLUDE; MIT needs it in the zip.");
  process.exit(1);
}

// ── Runtime state must not be in the archive ────────────────────────────────
//
// tChirp has no persistent state today: it writes no data.json, calls no
// SaveResourceFile and opens no kvp or jsonstore. MEASURED, not assumed — and
// that is exactly why this runs. The allowlist above is the thing that keeps it
// true, and an allowlist is edited by hand. The day tChirp gains a store, the
// first release after it is where a copy of the developer's file would ship,
// and this is the check that stops it rather than a reviewer remembering.
//
// It is free: tLib already owns the rule set and its floors. `minFiles` is 5
// against a staged tree of 9 — a floor against a collapsed or wrong-directory
// scan, not a budget, because every rule in it is green on an empty directory.
step("Checking the staged tree for runtime state");
const staged = checkStagedTree({ dist: DIST, minFiles: 5 });
const findings = failing(staged.findings, false);
const summary = `${staged.fileCount} file(s), ${(staged.totalBytes / 1024).toFixed(0)} KB staged`;
if (findings.length > 0) {
  console.error(formatFindings("staged tree", findings, summary));
  process.exit(1);
}
console.log(formatFindings("staged tree", findings, `${summary}, no forbidden runtime state`));

// `expectConfig` is left at its default (true): tChirp tracks and ships
// `config.lua`, so there IS a file for the sanitizer to read. A pass with zero
// config files found would be the silent-zero failure the default refusal
// exists to catch.
step("Packaging");
createZip(new AdmZip(), DIST, join(ROOT, ".build", "tChirp.zip"), "tChirp");
