#!/usr/bin/env node

// Validates docs/ before the sync workflow publishes it. The site's own CI only
// runs after that push has landed, so a bad page would already be live.
//
// Run: bun run docs:check
//
// What it checks:
//
//   1. Frontmatter      — the `---` block exists and carries `title`; `description`,
//                         `order` and `group` warn when absent.
//   2. URL collisions   — `x.mdx` and `x/index.mdx` collapse to the same slug.
//   3. Media references — every `/assets/tChirp/<file>` resolves in docs/public/.
//   4. Orphan media     — a file in docs/public/ no page references (warning only:
//                         one may be staged ahead of the page that uses it).
//   5. Link targets     — every in-page `](#anchor)` and cross-page
//                         `](/docs/tChirp/<page>#anchor)` resolves to a real heading.
//
// Plain node, no dependencies, so the CI runner needs nothing but a checkout.
//
// ⚠️ EXIT CODES: 0 clean, 1 at least one error. Warnings never fail. An empty
// docs/content is exit 1, not 0 — see the floor below.

import fs from "node:fs";
import path from "node:path";

const SLUG = "tChirp";
const ROOT = path.resolve(import.meta.dirname, "..");
const CONTENT_DIR = path.join(ROOT, "docs", "content");
const PUBLIC_DIR = path.join(ROOT, "docs", "public");
const ASSET_PREFIX = `/assets/${SLUG}/`;
const DOCS_PREFIX = `/docs/${SLUG}/`;

// Every check above is a regex over MDX source, and a regex that stops matching
// reports NOTHING rather than a problem. So they are named constants the negative
// control can kill one at a time and watch the gate go quiet.
// `DOCS_CONTROL_DEAD=asset,anchor` substitutes a regex that can never match, and
// is honoured ONLY in control mode.
const CONTROL = process.env.DOCS_GATE_CONTROL === "1";
const DEAD = new Set(
  CONTROL ? (process.env.DOCS_CONTROL_DEAD ?? "").split(",").filter(Boolean) : []
);
/** The named regex, or one that can never match — `(?!)` fails at every position. */
const scanner = (name, re) => (DEAD.has(name) ? new RegExp("(?!)", re.flags) : re);

const RE_FRONTMATTER = scanner("frontmatter", /^---\r?\n([\s\S]*?)\r?\n---/);
const RE_ASSET = scanner("asset", new RegExp(`/assets/${SLUG}/([A-Za-z0-9._-]+)`, "g"));
/** Fenced blocks, removed before headings are collected. */
const RE_FENCE = scanner("fence", /^```[\s\S]*?^```/gm);
const RE_HEADING = scanner("heading", /^#{2,6}\s+(.+)$/gm);
const RE_ANCHOR_LINK = scanner("anchor", /\]\(#([A-Za-z0-9._-]+)\)/g);
const RE_PAGE_LINK = scanner(
  "page",
  new RegExp(`\\]\\((/docs/${SLUG}/[A-Za-z0-9/_-]+)(#([A-Za-z0-9._-]+))?\\)`, "g")
);

const errors = [];
const warnings = [];
const fail = (file, msg) => errors.push(`${file}: ${msg}`);
const warn = (file, msg) => warnings.push(`${file}: ${msg}`);

function walk(dir, base = dir) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full, base));
    else out.push(path.relative(base, full).split(path.sep).join("/"));
  }
  return out;
}

const mdxFiles = walk(CONTENT_DIR).filter((f) => f.endsWith(".mdx"));
const mediaFiles = new Set(walk(PUBLIC_DIR).filter((f) => !f.startsWith(".")));

// ⛔ The floor. Every check below is green on an empty directory, so "no broken
// links" and "no pages were read" are otherwise the same result — and a moved
// or renamed docs/content is exactly what produces that shape.
if (mdxFiles.length === 0) {
  console.error(
    "check-docs: no .mdx files in docs/content — refusing to publish nothing. " +
      "This is exit 1, not a pass: every check below reports clean on zero pages."
  );
  process.exit(1);
}

/**
 * Heading → anchor id, matching the site's github-slugger.
 *
 * ⚠️ The order of the last two steps is load-bearing: github-slugger drops the
 * stripped characters and THEN replaces each remaining space one at a time, so
 * `## \`/tunit\` — the driver menu` leaves two adjacent spaces where the em dash
 * was and the real anchor is `tunit--the-driver-menu`, with two hyphens. A
 * `\s+ → -` collapse produces the single-hyphen form, which exists nowhere.
 * Underscores survive, so `tunit_diag` is `#tunit_diag`.
 */
function slugify(heading) {
  return heading
    .replace(/`([^`]*)`/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\*\*([^*]*)\*\*/g, "$1")
    .replace(/\*([^*]*)\*/g, "$1")
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9 _-]/g, "")
    .replace(/ /g, "-");
}

const pages = new Map();
const referenced = new Set();

for (const rel of mdxFiles) {
  const text = fs.readFileSync(path.join(CONTENT_DIR, rel), "utf8");

  const fm = text.match(RE_FRONTMATTER);
  if (!fm) {
    fail(rel, "no frontmatter block; the docs schema requires at least `title`");
    continue;
  }
  const field = (name) => fm[1].match(new RegExp(`^${name}:\\s*(.+)$`, "m"))?.[1]?.trim();
  if (!field("title")) fail(rel, "frontmatter is missing required `title`");
  for (const optional of ["description", "order", "group"]) {
    if (!field(optional)) warn(rel, `frontmatter has no \`${optional}\``);
  }

  // A folder index collapses to the folder slug, so x.mdx and x/index.mdx collide.
  const slug = rel.replace(/\.mdx$/, "").replace(/\/index$/, "");
  if (pages.has(slug)) {
    fail(rel, `collapses to the same URL as ${pages.get(slug).file} (${DOCS_PREFIX}${slug})`);
    continue;
  }

  const anchors = new Set();
  const body = text.slice(fm[0].length).replace(RE_FENCE, "");
  for (const m of body.matchAll(RE_HEADING)) anchors.add(slugify(m[1]));
  if (/^#\s+/m.test(body)) {
    warn(rel, "body starts a level-1 heading; the h1 is rendered from frontmatter `title`");
  }
  pages.set(slug, { file: rel, anchors, body });

  for (const m of text.matchAll(RE_ASSET)) {
    referenced.add(m[1]);
    if (!mediaFiles.has(m[1])) {
      fail(rel, `references ${ASSET_PREFIX}${m[1]}, which is not in docs/public/`);
    }
  }
}

for (const file of mediaFiles) {
  if (!referenced.has(file)) warn("docs/public", `${file} is not referenced by any page`);
}

for (const page of pages.values()) {
  for (const m of page.body.matchAll(RE_ANCHOR_LINK)) {
    if (!page.anchors.has(m[1])) fail(page.file, `link to #${m[1]}, no such heading on this page`);
  }
  for (const m of page.body.matchAll(RE_PAGE_LINK)) {
    const dest = pages.get(m[1].slice(DOCS_PREFIX.length));
    if (!dest) fail(page.file, `link to ${m[1]}, no such page`);
    else if (m[3] && !dest.anchors.has(m[3])) {
      fail(page.file, `link to ${m[1]}#${m[3]}, no such heading on ${dest.file}`);
    }
  }
}

for (const w of warnings) console.warn(`  warn  ${w}`);
for (const e of errors) console.error(`  ERROR ${e}`);

console.log(
  `\ncheck-docs: ${mdxFiles.length} pages, ${mediaFiles.size} media files, ` +
    `${warnings.length} warning(s), ${errors.length} error(s)`
);
if (errors.length === 0) console.log(`  pages: ${[...pages.keys()].sort().join(", ")}`);

// ── Negative control (DOCS_GATE_CONTROL=1) ──────────────────────────────────
//
// `bun run docs:check:control` re-runs this file with named scanners dead and
// requires the error count to move as named. Each case is a separate process, so
// it goes through the real code path.
//
// ⚠️ Killing each scanner in turn and asserting its findings disappear is the
// obvious design and two of the four cases passed VACUOUSLY — measured, not
// reasoned about. tChirp's docs are clean, so `page` and `asset` report zero
// findings on a healthy run, and zero is also what a dead scanner reports.
//
// So a case must move a count that is NOT already zero, which needs a defect in
// play: case 2 plants one (no anchors, so every cross-page link breaks) and case
// 3 kills `page` while it is still planted and requires exactly those to vanish.
// That is what makes `page` load-bearing rather than merely silent.
//
// NOT proven:
//
//   · `asset` / `orphan` — tChirp references no media, so no run of either can
//     be told from a dead one. Kept because the sync workflow's media step is
//     wired and the first screenshot added must not be what discovers them.
//   · `fence` — killing it can only ADD anchors (headings inside code blocks),
//     never remove one, so it cannot break a link that resolves today.
if (CONTROL && DEAD.size === 0) {
  const failuresFound = [];
  const run = (dead) => {
    const proc = Bun.spawnSync(["bun", import.meta.filename], {
      cwd: ROOT,
      env: { ...process.env, DOCS_GATE_CONTROL: "1", DOCS_CONTROL_DEAD: dead },
      stdout: "pipe",
      stderr: "pipe",
    });
    const out = new TextDecoder().decode(proc.stdout) + new TextDecoder().decode(proc.stderr);
    const seen = out.match(/(\d+) error\(s\)/);
    return {
      // -1, never 0, when the report line is missing: a run whose output could
      // not be read must not score as a clean one.
      errors: seen ? Number(seen[1]) : -1,
      exit: proc.exitCode,
    };
  };

  // Cases 2 and 3 both move this quantity, so the control is meaningless at 0.
  const anchorLinks = [...pages.values()].reduce(
    (n, p) =>
      n + [...p.body.matchAll(new RegExp(RE_PAGE_LINK.source, "g"))].filter((m) => m[3]).length,
    0
  );

  // ⛔ Floors on the control itself.
  if (errors.length !== 0) {
    console.error(
      `\ndocs:check:control: the clean run reported ${errors.length} error(s). ` +
        "Every case below is measured as a change FROM clean, so fix the docs first. " +
        "Exit 1 — a control that cannot establish a baseline must not report a pass."
    );
    process.exit(1);
  }
  if (anchorLinks === 0) {
    console.error(
      "\ndocs:check:control: the docs carry 0 cross-page anchor links, so cases 2 and 3 " +
        "below both move a count that is already zero and neither proves anything. " +
        "Exit 1 — this is the vacuous pass that an earlier version of this control " +
        "actually printed as a success."
    );
    process.exit(1);
  }

  console.log(
    `\ndocs:check:control — baseline: ${mdxFiles.length} pages, 0 errors, ` +
      `${anchorLinks} cross-page anchor link(s)\n`
  );

  // Case 3's expectation is arithmetic on case 2's result, so the cases run in
  // order and each predicate may read what the ones before it measured.
  const seen = {};

  const cases = [
    [
      "frontmatter",
      () => `all ${mdxFiles.length} pages must fail for having none`,
      (r) => r.errors >= mdxFiles.length && r.exit === 1,
    ],
    [
      "heading",
      () => `no anchors are collected, so all ${anchorLinks} cross-page anchor links must break`,
      (r) => r.errors >= anchorLinks && r.exit === 1,
    ],
    [
      // Both dead: `heading` plants the defect and killing `page` must make the
      // gate blind to EXACTLY the cross-page half of it.
      //
      // ⚠️ NOT "must report 0". `heading` also breaks every in-page `](#anchor)`
      // link, which `page` never looked at, so on a resource that has some a
      // working `page` kill still leaves them behind — requiring 0 reports NOT
      // MEASURED on tAFK (4 left) and tUnit (4 left) while the scanner is doing
      // its job. The honest quantity is the DROP, and it must equal anchorLinks
      // exactly: fewer means `page` is still finding some, more means it took
      // something that was never its to take.
      "heading,page",
      () =>
        `with the anchors still missing, killing \`page\` must hide exactly the ` +
        `${anchorLinks} cross-page one(s) and leave the ` +
        `${seen.heading.errors - anchorLinks} in-page one(s)`,
      (r) =>
        r.errors === seen.heading.errors - anchorLinks && r.exit === (r.errors > 0 ? 1 : 0),
    ],
  ];

  for (const [dead, whyOf, holds] of cases) {
    const measured = run(dead);
    seen[dead] = measured;
    const why = whyOf();
    if (holds(measured)) {
      console.log(`  as required  \`${dead}\` dead → ${why} (${measured.errors} error(s))`);
    } else {
      failuresFound.push(
        `\`${dead}\` dead reported ${measured.errors} error(s) and exit ${measured.exit}, ` +
          `but ${why}. The scanner is not load-bearing, so a passing docs:check is ` +
          "not evidence about it."
      );
      console.log(
        `  NOT MEASURED \`${dead}\` dead → ${measured.errors} error(s), exit ${measured.exit}`
      );
    }
  }

  console.log("");
  if (failuresFound.length > 0) {
    for (const f of failuresFound) console.error(`FAIL  ${f}`);
    process.exit(1);
  }
  console.log(
    "PASS  docs:check's frontmatter, heading and page scanners are demonstrably " +
      "load-bearing. `asset`, `orphan` and `fence` are NOT proven — see the header."
  );
  process.exit(0);
}

process.exit(errors.length > 0 ? 1 : 0);
