/**
 * `bun run thumb` — the store/docs hero and banner.
 *
 * The frame, the light rig and the guards are tLib's (`shared/ts/build/hero.ts`); this file is
 * only tChirp's words and its layer placement.
 *
 * Art goes in `assets/hero/` and is named in LAYERS below — anything Chromium can decode. With
 * a file missing this exits 2 with the list of what it wanted and writes no image: a
 * plausible-looking wrong hero is worse than no hero.
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
 * One layer, and it is the whole frame rather than a panel floating in it. Every other
 * resource composites UI captures onto this dark ground; tChirp has no UI to capture, so the
 * art is a photograph of a marked unit parked with its lights going, and a photograph has to
 * BE the background with the type on a scrim over it.
 *
 *   `-webkit-mask-image`   fades the photo out where the type goes. ⚠️ The prefix is
 *                          load-bearing: this renders in the vendored NUI Chromium, revision
 *                          103, and unprefixed `mask-image` only arrived in 120 — unprefixed
 *                          it is ignored and the photo runs behind the wordmark at full
 *                          strength.
 *   `filter: brightness`   the source is bright midday GTA against a near-black frame. At full
 *                          strength the photo reads as a different image pasted in.
 *
 * Mask percentages are relative to the IMAGE, which is larger than the frame and offset, so
 * they do not line up with frame percentages. The car sits at roughly 39% across and 26-60%
 * down the source, which is what the offsets below position.
 */
const LAYERS: { file: string; thumb: string; banner: string }[] = [
  {
    file: "chirp.jpg",
    // 2651x1172 source; at 3200 wide it stands 1415 tall, and `top` drops the car into the
    // lower half so the headline is not sitting on the roof.
    thumb: `width: 3200px; left: -380px; top: 60px; border-radius: 0;
            filter: brightness(.52) saturate(.88) contrast(1.05);
            -webkit-mask-image: linear-gradient(to bottom, transparent 8%, rgba(0,0,0,.35) 26%, #000 44%);
            mask-image: linear-gradient(to bottom, transparent 8%, rgba(0,0,0,.35) 26%, #000 44%);`,
    // The banner puts its copy down the left, so the fade runs the other way. The car is left
    // of centre in the source, so the image is pushed right to clear the type — the gap that
    // opens on the left is inside the masked-out region anyway.
    // The car spans 34-67% of the source width; at 1900 wide and pushed to 300 that put its
    // nose 73px past the right edge, so the whole unit read as leaving the frame.
    banner: `width: 1750px; left: 250px; top: -120px; border-radius: 0;
             filter: brightness(.56) saturate(.88) contrast(1.05);
             -webkit-mask-image: linear-gradient(to right, transparent 2%, rgba(0,0,0,.3) 20%, #000 40%);
             mask-image: linear-gradient(to right, transparent 2%, rgba(0,0,0,.3) 20%, #000 40%);`,
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
    // Full frame, not the default band below the type: this layer IS the background.
    stageCss: "top: 0; height: 1080px;",
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
