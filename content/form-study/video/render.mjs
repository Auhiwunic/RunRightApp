// Fully in-house video render: deterministic HTML scene -> PNG frames (headless
// Chrome) -> mp4 (static ffmpeg from npm). No system installs, no cloud.
//   node render.mjs [seconds] [fps]
import puppeteer from "puppeteer-core";
import ffmpegPath from "@ffmpeg-installer/ffmpeg";
import { spawnSync } from "child_process";
import { mkdirSync, rmSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const here = dirname(fileURLToPath(import.meta.url));
const SCENE = process.env.SCENE || "scene.html";
const OUTNAME = "gaita-" + SCENE.replace(/\.html$/, "") + ".mp4";
const SECONDS = +(process.argv[2] || 10);
const FPS = +(process.argv[3] || 30);
const total = Math.round(SECONDS * FPS);
const W = 1080, H = 1920;
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const framesDir = join(here, "frames");
rmSync(framesDir, { recursive: true, force: true });
mkdirSync(framesDir, { recursive: true });

const browser = await puppeteer.launch({ executablePath: CHROME, headless: "new",
  args: ["--force-device-scale-factor=1", "--hide-scrollbars"] });
const page = await browser.newPage();
await page.setViewport({ width: W, height: H, deviceScaleFactor: 1 });

// Load the page ONCE, then re-render each frame by calling the in-page render(f).
// (Reloading per frame detaches the navigating frame under headless.)
await page.goto(`file://${join(here, SCENE)}?total=${total}&fps=${FPS}`,
  { waitUntil: "networkidle0" });

const t0 = Date.now();
for (let f = 0; f < total; f++) {
  await page.evaluate((frame) => window.renderFrame(frame), f);
  await page.screenshot({ path: join(framesDir, `f${String(f).padStart(4, "0")}.png`) });
  if (f % 30 === 0) console.log(`frame ${f}/${total}`);
}
await browser.close();
console.log(`rendered ${total} frames in ${((Date.now() - t0) / 1000).toFixed(1)}s`);

const out = join(here, OUTNAME);
const r = spawnSync(ffmpegPath.path, [
  "-y", "-framerate", String(FPS), "-i", join(framesDir, "f%04d.png"),
  "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18",
  "-vf", "scale=1080:1920", out,
], { stdio: "inherit" });
console.log(r.status === 0 ? `\nDONE -> ${out}` : "ffmpeg failed");
