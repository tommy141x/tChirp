/** `bun run prod` — cut the release zip. */
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import AdmZip from "adm-zip";
import {
  mergeLicenceFiles,
  assertManifestStaged,
  checkStagedTree,
  createZip,
  failing,
  formatFindings,
  stageFiles,
  step,
} from "../../tLib/shared/ts/build/index.ts";

const ROOT = resolve(join(import.meta.dir, ".."));
const DIST = join(ROOT, ".build", "dist");

// An allowlist, so a new file is ABSENT from the release until someone adds it
// here; both directions are checked below, so an unlisted runtime file fails the
// build loudly instead of shipping broken.
//
// Named file by file rather than as `client`, `server`, `shared`: a tree-level
// entry is identical today, right up to the first helper, fixture or note filed
// next to them, which would then ship silently.
//
// ⚠️ `config.local.lua` must never be staged: it is the developer's real
// credentials, gitignored, overlaid onto Config at server start by tlib.secrets.
// The tracked `config.lua` ships with its blanks, which is what makes an update
// safe to unzip over a live install — createZip's sanitizer re-checks that below.
const INCLUDE = [
  "fxmanifest.lua",
  "README.md",
  "config.lua",
  "shared/config-spec.lua",
  "client/cl_sirens.lua",
  "client/cl_chirp.lua",
  "client/cl_menu.lua",
  "server/sv_access.lua",
  "server/sv_chirp.lua",
  "server/sv_version.lua",
];

// Both directions, and neither check can see the other's failure. `stageFiles`
// throws on an included path that has stopped existing — a rename or a move.
// `assertManifestStaged` throws on a path fxmanifest.lua declares that nobody
// added to INCLUDE — a release that builds clean and then fails at load on
// someone's server, reported to the player rather than to whoever cut it.
//
// MEASURED, reproducible by redoing either edit (the checks are tLib's, and
// tLib's own `check:regression` owns their fixtures):
//
//   · `client/cl_chirp.lua` removed from INCLUDE → exit 1, "fxmanifest.lua names
//     1 path(s) the release does not stage: client/cl_chirp.lua".
//   · a `data.json` planted at the root and added to INCLUDE → exit 1,
//     R-DATA-FILE, 1 finding. So runtime state cannot reach the archive.
assertManifestStaged(readFileSync(join(ROOT, "fxmanifest.lua"), "utf8"), INCLUDE);

stageFiles(ROOT, DIST, INCLUDE);

step("Merging the licence and notices");
{
  const bundle = mergeLicenceFiles({
    root: ROOT,
    dist: DIST,
    name: "tChirp",
    sources: [
      { title: "Licence (MIT)", file: "LICENSE" }
    ],
  });
  console.log(`  ${bundle.out} — ${bundle.sections.length} section(s), ${(bundle.bytes / 1024).toFixed(1)} KB`);
}


// MIT requires the notice in every copy, and nothing but the `"LICENSE"` line in
// mergeLicenceFiles above puts it there — `assertManifestStaged` compares against
// fxmanifest.lua, which declares neither LICENSE nor README. MEASURED: deleting
// that line built green and produced a zip of 10 Lua files with no licence.
const licence = join(DIST, "server", "LICENSE.txt");
if (!existsSync(licence) || !readFileSync(licence, "utf8").includes("MIT License")) {
  console.error("No MIT text in server/LICENSE.txt — MIT needs the notice inside the zip.");
  process.exit(1);
}

// tChirp has no persistent state today — no data.json, no SaveResourceFile, no
// kvp or jsonstore — and the hand-edited allowlist above is the only thing
// keeping that true. The day tChirp gains a store, the first release after it is
// where a copy of the developer's file would ship.
//
// `minFiles` is 5 against a staged tree of 9: a floor against a collapsed or
// wrong-directory scan, not a budget, because every rule in it is green on an
// empty directory.
step("Checking the staged tree for runtime state");
const staged = checkStagedTree({ dist: DIST, minFiles: 5 });
const findings = failing(staged.findings, false);
const summary = `${staged.fileCount} file(s), ${(staged.totalBytes / 1024).toFixed(0)} KB staged`;
if (findings.length > 0) {
  console.error(formatFindings("staged tree", findings, summary));
  process.exit(1);
}
console.log(formatFindings("staged tree", findings, `${summary}, no forbidden runtime state`));

step("Packaging");
// One merged `server/LICENSE.txt` rather than loose legal files at the resource
// root, which is what an operator sees when they extract the zip. The repo keeps
// them separate -- different things edit them at different times -- so the merge
// happens here, on the staged tree.
createZip(new AdmZip(), DIST, join(ROOT, ".build", "tChirp.zip"), "tChirp");
