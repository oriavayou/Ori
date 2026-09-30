// Piggy Growth renderer
//   node render.mjs stills 0.5 1.3 ...   -> out/stills/*.png (review frames only)
//   node render.mjs check                -> automated framing/safety checks over all frames
//   node render.mjs video                -> out/piggy-growth.mp4 (frames piped straight into FFmpeg)
//   node render.mjs luma                 -> per-frame brightness report of the rendered MP4
import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import ffmpegPath from 'ffmpeg-static';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(ROOT, 'out');
const W = 1080, H = 1920, FPS = 60, DURATION = 10, SUB = 4;
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.ttf': 'font/ttf', '.json': 'application/json', '.png': 'image/png' };

function serve() {
  const server = http.createServer((req, res) => {
    const url = decodeURIComponent(req.url.split('?')[0]);
    const file = path.join(ROOT, url === '/' ? 'index.html' : url);
    if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise(r => server.listen(0, '127.0.0.1', () => r(server)));
}

async function openPage(server, query = '') {
  const browser = await chromium.launch({
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--disable-gpu-vsync', '--font-render-hinting=none'],
  });
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  page.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') console.log(`[page ${m.type()}]`, m.text()); });
  page.on('pageerror', e => console.log('[page error]', e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html${query}`);
  await page.waitForFunction(() => window.__ready === true, null, { timeout: 180000 });
  return { browser, page };
}

const shot = page => page.screenshot({ type: 'png', clip: { x: 0, y: 0, width: W, height: H }, animations: 'disabled', caret: 'hide' });

async function stills(times, query) {
  const server = await serve();
  const { browser, page } = await openPage(server, query);
  fs.mkdirSync(path.join(OUT, 'stills'), { recursive: true });
  for (const t of times) {
    const t0 = Date.now();
    await page.evaluate(tt => window.seek(tt), t);
    const buf = await shot(page);
    const f = path.join(OUT, 'stills', `t_${t.toFixed(2).padStart(5, '0')}.png`);
    fs.writeFileSync(f, buf);
    console.log(f, `${Date.now() - t0}ms`);
  }
  await browser.close(); server.close();
}

async function check() {
  const server = await serve();
  const { browser, page } = await openPage(server);
  const info = await page.evaluate(() => window.__info());
  const report = await page.evaluate(() => window.runChecks());
  console.log(JSON.stringify({ info, report }, null, 2));
  await browser.close(); server.close();
  if (!report.ok) process.exitCode = 1;
}

async function video(workers = Number(process.env.WORKERS || 3)) {
  const server = await serve();
  const sessions = await Promise.all(Array.from({ length: workers }, () => openPage(server)));
  fs.mkdirSync(OUT, { recursive: true });
  const outFile = path.join(OUT, 'piggy-growth.mp4');
  // 240 fps input: 4 sub-frames per output frame, spread over half a frame (180 deg shutter),
  // blended with tmix and decimated back to 60 fps.
  const ff = spawn(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'image2pipe', '-framerate', String(FPS * SUB), '-c:v', 'png', '-i', '-',
    '-vf', `tmix=frames=${SUB},select='eq(mod(n\\,${SUB})\\,${SUB - 1})',setpts=N/(${FPS}*TB)`,
    '-r', String(FPS), '-c:v', 'libx264', '-preset', 'slow', '-crf', '15', '-pix_fmt', 'yuv420p',
    '-profile:v', 'high', '-movflags', '+faststart', outFile,
  ], { stdio: ['pipe', 'inherit', 'inherit'] });
  const ffDone = new Promise((res, rej) => ff.on('close', c => c === 0 ? res() : rej(new Error('ffmpeg exit ' + c))));
  const write = buf => new Promise(res => { if (ff.stdin.write(buf)) res(); else ff.stdin.once('drain', res); });

  // sub-frame times: centred on each output frame, spread over half a frame
  const frames = FPS * DURATION, frameDur = 1 / FPS, shutter = frameDur / 2;
  const times = [];
  for (let k = 0; k < frames; k++) for (let j = 0; j < SUB; j++)
    times.push(Math.min(Math.max(k * frameDur + (j - (SUB - 1) / 2) * (shutter / SUB), 0), DURATION - 1e-4));

  // workers render strided indices; buffers are handed to FFmpeg strictly in order (memory only)
  const ready = new Map();
  let waiting = null, written = 0;
  const t0 = Date.now();
  const writer = (async () => {
    while (written < times.length) {
      if (!ready.has(written)) { await new Promise(r => { waiting = r; }); continue; }
      const buf = ready.get(written); ready.delete(written);
      await write(buf);
      written++;
      if (written % (SUB * 30) === 0) {
        const el = (Date.now() - t0) / 1000, f = written / SUB;
        console.log(`frame ${f}/${frames}  ${el.toFixed(0)}s elapsed, eta ${((frames - f) * el / f).toFixed(0)}s`);
      }
    }
  })();
  await Promise.all(sessions.map(async ({ page }, w) => {
    for (let i = w; i < times.length; i += workers) {
      while (i - written > workers * 6) await new Promise(r => setTimeout(r, 20));   // bounded look-ahead
      await page.evaluate(tt => window.seek(tt), times[i]);
      ready.set(i, await shot(page));
      if (waiting) { const r = waiting; waiting = null; r(); }
    }
  }));
  await writer;
  ff.stdin.end();
  await ffDone;
  await Promise.all(sessions.map(s => s.browser.close()));
  server.close();
  console.log('wrote', outFile, `in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
}

function luma() {
  const file = path.join(OUT, 'piggy-growth.mp4');
  const ff = spawn(ffmpegPath, ['-hide_banner', '-i', file, '-vf', 'signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-', '-f', 'null', '-'], { stdio: ['ignore', 'pipe', 'pipe'] });
  let txt = '';
  ff.stdout.on('data', d => txt += d);
  ff.on('close', () => {
    const vals = [...txt.matchAll(/YAVG=([\d.]+)/g)].map(m => +m[1]);
    let maxJump = 0, at = 0;
    for (let i = 1; i < vals.length; i++) { const d = Math.abs(vals[i] - vals[i - 1]); if (d > maxJump) { maxJump = d; at = i; } }
    const win = vals.slice(Math.round(4.6 * FPS), Math.round(6.6 * FPS));
    console.log(JSON.stringify({
      frames: vals.length, min: Math.min(...vals).toFixed(2), max: Math.max(...vals).toFixed(2),
      maxFrameToFrameJump: maxJump.toFixed(3), atFrame: at, atTime: (at / FPS).toFixed(3),
      burstWindow_4_6_to_6_6: { min: Math.min(...win).toFixed(2), max: Math.max(...win).toFixed(2) },
      perTenth: Array.from({ length: 100 }, (_, i) => vals[i * 6]?.toFixed(1)).join(' '),
    }, null, 2));
  });
}

const [mode, ...rest] = process.argv.slice(2);
if (mode === 'stills') {
  const q = rest.filter(a => a.startsWith('?'))[0] || '';
  await stills(rest.filter(a => !a.startsWith('?')).map(Number), q);
} else if (mode === 'check') await check();
else if (mode === 'video') await video();
else if (mode === 'luma') luma();
else console.log('usage: node render.mjs stills <t...> [?guides=1] | check | video | luma');
