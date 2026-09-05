#!/usr/bin/env node
/**
 * One command: capture every page of a site, then cut it into a film.
 *
 *   node promo/tools/tour.mjs --url https://your-site.com/              # the scripted film
 *   node promo/tools/tour.mjs --url https://your-site.com/ --edit tour  # the page-by-page tour
 *
 * --edit film  site/film.html — written copy carries the piece; the pages appear
 *              as evidence between statements. Slower, art-directed.
 * --edit tour  site/tour.html — every page in turn inside a device mockup.
 *
 * Passes --pages / --max / --hide / --tall through to site-shots.mjs and
 * --out / --fps / --scale / --stills through to render.mjs.
 */
import { spawn } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { args } from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const { get } = args();

if (!get('url')) {
  console.error('usage: node promo/tools/tour.mjs --url https://your-site.com/');
  process.exit(1);
}

const pass = (names) => names.flatMap((n) => (get(n, null) == null ? [] : ['--' + n, get(n)]));
const run = (script, argv) =>
  new Promise((res, rej) => {
    const p = spawn(process.execPath, [join(HERE, script), ...argv], { stdio: 'inherit', cwd: ROOT });
    p.on('close', (c) => (c === 0 ? res() : rej(new Error(`${script} exited ${c}`))));
  });

await run('site-shots.mjs', ['--url', get('url'), ...pass(['pages', 'max', 'hide', 'tall'])]);
const edit = get('edit', 'film');
if (!['film', 'tour'].includes(edit)) {
  console.error(`unknown --edit "${edit}" (expected film or tour)`);
  process.exit(1);
}
await run('render.mjs', [
  '--page', `site/${edit}.html`,
  '--data', 'promo/shots/shots.json',
  '--out', get('out', `promo/out/${edit}-9x16.mp4`),
  ...pass(['fps', 'scale', 'stills', 'duration']),
]);
