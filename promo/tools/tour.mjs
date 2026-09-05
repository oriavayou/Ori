#!/usr/bin/env node
/**
 * One command for the edited tour: capture every page of a site, then render the
 * edit (title card → page by page with a different move each time → all pages in
 * a grid → closing card) into an MP4.
 *
 *   node promo/tools/tour.mjs --url https://your-site.com/
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
await run('render.mjs', [
  '--page', 'site/tour.html',
  '--data', 'promo/shots/shots.json',
  '--out', get('out', 'promo/out/tour-9x16.mp4'),
  ...pass(['fps', 'scale', 'stills', 'duration']),
]);
