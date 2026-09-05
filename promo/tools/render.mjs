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
import { spawn, execSync } from 'node:child_process';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createServer } from 'node:http';
import { extname } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const PROMO = resolve(HERE, '..');

// ---- args ----------------------------------------------------------------
const argv = process.argv.slice(2);
const flag = (name, def) => {
  const i = argv.indexOf('--' + name);
  return i === -1 ? def : argv[i + 1];
};
const has = (name) => argv.includes('--' + name);

const contentPath = resolve(ROOT, flag('content', join(PROMO, 'content.json')));
const content = JSON.parse(readFileSync(contentPath, 'utf8'));
const meta = content.meta || {};
const fps = Number(flag('fps', meta.fps || 30));
const duration = Number(flag('duration', meta.duration || 20));
const scale = Number(flag('scale', 1));
const width = Math.round((meta.width || 1080) * scale);
const height = Math.round((meta.height || 1920) * scale);
const outPath = resolve(ROOT, flag('out', meta.output || 'promo/out/promo.mp4'));
const stills = flag('stills', null);
const shot = flag('format', 'jpeg') === 'png'
  ? { type: 'png' }
  : { type: 'jpeg', quality: Number(flag('quality', 95)) };
const quiet = has('quiet');
const log = (...a) => !quiet && console.log(...a);

// ---- playwright (may be installed globally in this environment) -----------
async function loadPlaywright() {
  const pick = (m) => m?.chromium ? m : m?.default?.chromium ? m.default : null;
  try { const m = pick(await import('playwright')); if (m) return m; } catch {}
  const globalRoot = execSync('npm root -g').toString().trim();
  const m = pick(await import(pathToFileURL(join(globalRoot, 'playwright', 'index.js')).href));
  if (!m) throw new Error('playwright not found - install it with `npm i -D playwright`');
  return m;
}

// ---- tiny static server for the scene (file:// blocks the local stylesheet) --
const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript' };
const server = createServer((req, res) => {
  const name = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'scene.html';
  try {
    const body = readFileSync(join(PROMO, name));
    res.writeHead(200, { 'content-type': MIME[extname(name)] || 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404).end('not found');
  }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/scene.html`;

// ---- page ----------------------------------------------------------------
const { chromium } = await loadPlaywright();
const browser = await chromium.launch({ args: ['--force-color-profile=srgb', '--disable-lcd-text'] });
const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
await page.addInitScript((c) => { window.__CONTENT = c; }, content);
await page.goto(base, { waitUntil: 'load' });
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

// ---- stills mode ---------------------------------------------------------
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

// ---- video ---------------------------------------------------------------
const total = Math.round(duration * fps);
const ffmpeg = process.env.FFMPEG || 'ffmpeg';
const ff = spawn(ffmpeg, [
  '-y', '-hide_banner', '-loglevel', 'error',
  '-f', 'image2pipe', '-framerate', String(fps), '-i', '-',
  '-c:v', 'libx264', '-preset', 'slow', '-crf', '19',
  '-profile:v', 'high', '-level', '4.2',
  '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
  outPath,
], { stdio: ['pipe', 'inherit', 'inherit'] });

const done = new Promise((res, rej) => {
  ff.on('error', rej);
  ff.on('close', (code) => (code === 0 ? res() : rej(new Error('ffmpeg exited ' + code))));
});

log(`rendering ${total} frames @ ${width}x${height} ${fps}fps -> ${outPath}`);
const t0 = Date.now();
for (let i = 0; i < total; i++) {
  await seek(i / fps);
  const buf = await page.screenshot(shot);
  if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once('drain', r));
  if (!quiet && (i % 30 === 0 || i === total - 1)) {
    const pct = (((i + 1) / total) * 100).toFixed(0);
    process.stdout.write(`\r  ${pct}%  frame ${i + 1}/${total}  ${((Date.now() - t0) / 1000).toFixed(0)}s`);
  }
}
ff.stdin.end();
await done;
log('');

// cover image, taken from the middle of the opening scene
const coverAt = Math.min(duration - 0.1, ((content.scenes?.[0]?.end ?? 4) - 0.9));
await seek(Math.max(0, coverAt));
const cover = join(dirname(outPath), 'cover.png');
writeFileSync(cover, await page.screenshot({ type: 'png' }));

await browser.close();
server.close();
log(`done in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
log(`  video: ${outPath}`);
log(`  cover: ${cover}`);
