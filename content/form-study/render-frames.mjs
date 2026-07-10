// Render each .frame in frame-template.html to a 1080x1920 PNG.
// Usage: npm i -D playwright && node render-frames.mjs
import { chromium } from "playwright";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { mkdirSync } from "fs";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "out");
mkdirSync(out, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1080, height: 1920 }, deviceScaleFactor: 2 });
await page.goto("file://" + join(here, "frame-template.html"));

const frames = await page.$$(".frame");
for (let i = 0; i < frames.length; i++) {
  await frames[i].screenshot({ path: join(out, `frame-${i + 1}.png`) });
  console.log(`wrote frame-${i + 1}.png`);
}
await browser.close();
console.log(`done — ${frames.length} frames in ${out}`);
