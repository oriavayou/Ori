#!/usr/bin/env node
/**
 * Renders promo/scene.html into an MP4, frame by frame.
 *
 * The scene is animated with plain CSS animations; here they are all paused and
 * seeked to an exact timestamp before each screenshot, so the output is
 * deterministic (no dropped or duplicated frames, no realtime capture).
 *
 *   node promo/tools/render.mjs                       # full render -> meta.output
 *   node promo/tools/render.mjs --scale 0.5           # fast draft
 *   node promo/tools/render.mjs --stills 0,5,9,14,18  # PNG stills instead of video
 *
 * Options: --content --out --fps --duration --scale --stills --format --quality --quiet
 * Env: FFMPEG=/path/to/ffmpeg (defaults to `ffmpeg` on PATH)
 */
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { args, loadPlaywright, serveDir, encoder, progress } from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const PROMO = resolve(HERE, '..');

const { get, has } = args();
const contentPath = resolve(ROOT, get('content', join(PROMO, 'content.json')));
const content = JSON.parse(readFileSync(contentPath, 'utf8'));
const meta = content.meta || {};
const fps = Number(get('fps', meta.fps || 30));
const duration = Number(get('duration', meta.duration || 20));
const scale = Number(get('scale', 1));
const width = Math.round((meta.width || 1080) * scale);
const height = Math.round((meta.height || 1920) * scale);
const outPath = resolve(ROOT, get('out', meta.output || 'promo/out/promo.mp4'));
const stills = get('stills', null);
const quiet = has('quiet');
const shot = get('format', 'jpeg') === 'png'
  ? { type: 'png' }
  : { type: 'jpeg', quality: Number(get('quality', 95)) };
const log = (...a) => !quiet && console.log(...a);

const server = await serveDir(PROMO);
const { chromium } = await loadPlaywright();
const browser = await chromium.launch({ args: ['--force-color-profile=srgb', '--disable-lcd-text'] });
const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
await page.addInitScript((c) => { window.__CONTENT = c; }, content);
await page.goto(server.origin + '/scene.html', { waitUntil: 'load' });
await page.evaluate(() => window.__ready);
await page.addStyleTag({ content: `.stage{zoom:${scale}}` });
await page.evaluate(() => document.documentElement.classList.add('paused'));

// one round-trip per frame: seek, then wait for the next paint
const seek = (t) =>
  page.evaluate(
    (tt) => (window.__seek(tt), new Promise((r) => requestAnimationFrame(() => r(true)))),
    t
  );

mkdirSync(dirname(outPath), { recursive: true });

if (stills) {
  for (const t of stills.split(',').map(Number)) {
    await seek(t);
    const file = join(dirname(outPath), `still-${t.toFixed(2)}.png`);
    writeFileSync(file, await page.screenshot({ type: 'png' }));
    log('still', file);
  }
  await browser.close();
  server.close();
  process.exit(0);
}

const total = Math.round(duration * fps);
const enc = encoder(outPath, { fps });

log(`rendering ${total} frames @ ${width}x${height} ${fps}fps -> ${outPath}`);
const t0 = Date.now();
for (let i = 0; i < total; i++) {
  await seek(i / fps);
  await enc.write(await page.screenshot(shot));
  progress(i, total, t0, quiet);
}
await enc.finish();
log('');

// cover image, taken from the middle of the opening scene
const coverAt = Math.min(duration - 0.1, (content.scenes?.[0]?.end ?? 4) - 0.9);
await seek(Math.max(0, coverAt));
const cover = join(dirname(outPath), 'cover.png');
writeFileSync(cover, await page.screenshot({ type: 'png' }));

await browser.close();
server.close();
log(`done in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
log(`  video: ${outPath}`);
log(`  cover: ${cover}`);
