/**
 * `bun run thumb` — the store/docs hero and banner.
 *
 * The frame, the light rig and the guards are tLib's (`shared/ts/build/hero.ts`); this file is
 * only tChirp's words and its layer placement.
 *
 * NO ART YET. tChirp has no gallery: it is a reminder that fires on leaving a running vehicle,
 * so what it looks like is a prompt in the world, not a panel a headless browser can
 * photograph. Drop captures into `assets/hero/` and name them in LAYERS below. Until then this
 * exits 2 with the list of what it wanted, and writes no placeholder image — a
 * plausible-looking wrong hero is worse than no hero.
 *
 * Anything Chromium can decode works: `.png`, `.webp`, `.jpg`. A capture with a transparent
 * ground beats one with the game behind it — see tUnit's thumb for how those are placed, with
 * no border-radius and no box-shadow.
 *
 *   bun run thumb
 *   bun run thumb -- --format banner
 *   bun run thumb -- --subtitle "..."
 */

import fs from "node:fs";
import path from "node:path";
import { cliArg } from "../../tLib/shared/ts/build/argv.ts";
import { type HeroLayer, renderHero } from "../../tLib/shared/ts/build/hero.ts";

const REPO = path.resolve(import.meta.dir, "..");
const HERO = path.join(REPO, "assets", "hero");
const out = (name: string) => path.join(REPO, "docs", "public", name);

const headline = cliArg("headline") ?? "tChirp";
const subtitle = cliArg("subtitle") ?? "Park-kill siren chirp reminder for FiveM";
const only = cliArg("format");

/**
 * The art this hero is composed from, in paint order — first is furthest back.
 *
 * These placements are untuned: they cannot be checked against captures that do not exist yet.
 * Size and angle them once the real art is in.
 */
const LAYERS: { file: string; thumb: string; banner: string }[] = [
  {
    file: "chirp.png",
    thumb: `width: 1480px; left: 220px; top: 20px; border-radius: 0;`,
    banner: `width: 1000px; left: 800px; top: 48px; border-radius: 0;
             transform: rotateY(-9deg) rotateX(3deg) rotateZ(-1deg);`,
  },
];

const missing = LAYERS.map((l) => l.file).filter((f) => !fs.existsSync(path.join(HERO, f)));
if (missing.length) {
  console.error(`tChirp has no hero art yet. Put these in ${path.relative(REPO, HERO)}/:`);
  for (const f of missing) console.error(`  ${f}`);
  console.error("Then adjust LAYERS in scripts/thumb.ts to size and angle them.");
  process.exit(2);
}

const layers = (format: "thumb" | "banner"): HeroLayer[] =>
  LAYERS.map((l) => ({ file: path.join(HERO, l.file), css: l[format] }));

/** Six characters against tRadio's thirteen, so this runs above the 148px default to land on a
 *  comparable lockup width — matching the font-size would make the shorter name look small. */
if (only !== "banner") {
  await renderHero({
    format: "thumb",
    headline,
    subtitle,
    headlineSize: 172,
    stageCss: "top: 430px; height: 650px;",
    layers: layers("thumb"),
    out: out("thumb.jpg"),
  });
}
if (only !== "thumb") {
  await renderHero({
    format: "banner",
    headline,
    subtitle,
    headlineSize: 104,
    layers: layers("banner"),
    out: out("banner.jpg"),
  });
}
