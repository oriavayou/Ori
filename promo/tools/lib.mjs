/** Shared helpers for the promo renderers. */
import { spawn, execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, extname, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createServer } from 'node:http';

export const args = (argv = process.argv.slice(2)) => ({
  get: (name, def) => {
    const i = argv.indexOf('--' + name);
    return i === -1 ? def : argv[i + 1];
  },
  has: (name) => argv.includes('--' + name),
});

/** Playwright may be a project dependency or installed globally in the sandbox. */
export async function loadPlaywright() {
  const pick = (m) => (m?.chromium ? m : m?.default?.chromium ? m.default : null);
  try { const m = pick(await import('playwright')); if (m) return m; } catch {}
  const globalRoot = execSync('npm root -g').toString().trim();
  const m = pick(await import(pathToFileURL(join(globalRoot, 'playwright', 'index.js')).href));
  if (!m) throw new Error('playwright not found - install it with `npm i -D playwright`');
  return m;
}

/** Serves one directory over localhost; file:// would block the local stylesheet. */
export async function serveDir(dir) {
  const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript' };
  const server = createServer((req, res) => {
    const name = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
    try {
      const body = readFileSync(join(dir, name));
      res.writeHead(200, { 'content-type': MIME[extname(name)] || 'application/octet-stream' });
      res.end(body);
    } catch {
      res.writeHead(404).end('not found');
    }
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { origin: `http://127.0.0.1:${server.address().port}`, close: () => server.close() };
}

/** An ffmpeg process that turns a stream of image buffers into an H.264 mp4. */
export function encoder(outPath, { fps = 30, crf = 19 } = {}) {
  const bin = process.env.FFMPEG || 'ffmpeg';
  const ff = spawn(bin, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'image2pipe', '-framerate', String(fps), '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', String(crf),
    '-profile:v', 'high', '-level', '4.2',
    '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
    outPath,
  ], { stdio: ['pipe', 'inherit', 'inherit'] });

  const closed = new Promise((res, rej) => {
    ff.on('error', rej);
    ff.on('close', (code) => (code === 0 ? res() : rej(new Error('ffmpeg exited ' + code))));
  });

  return {
    async write(buf) {
      if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once('drain', r));
    },
    async finish() {
      ff.stdin.end();
      await closed;
    },
  };
}

export const progress = (i, total, t0, quiet) => {
  if (quiet || (i % 30 !== 0 && i !== total - 1)) return;
  const pct = (((i + 1) / total) * 100).toFixed(0);
  process.stdout.write(`\r  ${pct}%  frame ${i + 1}/${total}  ${((Date.now() - t0) / 1000).toFixed(0)}s`);
};
