#!/usr/bin/env node
/**
 * Turns a logo supplied on a white background into a transparent PNG, so it can
 * sit on the film's ink ground without a white box around it.
 *
 *   node promo/tools/prep-logo.mjs                     # promo/brand/logo.png -> logo-alpha.png
 *   node promo/tools/prep-logo.mjs --in path/to/logo.png --similarity 0.14
 *
 * If your logo is already transparent, skip this — film.html prefers
 * brand/logo-alpha.png but falls back to brand/logo.png.
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, rmSync, renameSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { args, ffmpegPath } from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const BRAND = join(HERE, '..', 'brand');
const { get } = args();

const input = resolve(get('in', join(BRAND, 'logo.png')));
const out = resolve(get('out', join(BRAND, 'logo-alpha.png')));
if (!existsSync(input)) {
  console.error(`no logo at ${input}\nput the file there (promo/brand/logo.png) and run again`);
  process.exit(1);
}

const FF = await ffmpegPath();

// A logo that already carries alpha must not be keyed: colorkey compares RGB to
// white, and a transparent pixel's RGB is black — so keying one turns the
// transparent field into an opaque black box.
const probe = spawnSync(FF, ['-hide_banner', '-i', input], { encoding: 'utf8' });
const hasAlpha = /Video: \w+, (?:\w*a\w*\b|ya\d*|rgba|bgra|argb|abgr)/.test(probe.stderr || '');

// colorkey removes a white field; blend keeps the anti-aliased edges soft
const similarity = get('similarity', '0.12');
const key = hasAlpha ? 'format=rgba' : `colorkey=white:${similarity}:0.06,format=rgba`;
const tmp = out + '.keyed.png';
if (hasAlpha) console.log('source already has alpha — trimming only');

execFileSync(FF, ['-y', '-hide_banner', '-loglevel', 'error', '-i', input, '-vf', key, tmp]);

// Logos ship with generous white padding. Once the white is transparent, the
// alpha channel's bounding box is the mark's real extent — cropdetect finds it
// there (it looks for black borders, which is exactly what alphaextract gives).
let crop = '';
if (get('trim', '1') !== '0') {
  const probe = spawnSync(FF,
    ['-hide_banner', '-loop', '1', '-i', tmp, '-vf', 'alphaextract,cropdetect=8:2:0', '-frames:v', '3', '-f', 'null', '-'],
    { encoding: 'utf8' });
  const m = [...((probe.stderr || '') + (probe.stdout || '')).matchAll(/crop=(\d+:\d+:\d+:\d+)/g)].pop();
  if (m) crop = m[1];
}

if (crop) {
  execFileSync(FF, ['-y', '-hide_banner', '-loglevel', 'error', '-i', tmp, '-vf', `crop=${crop},format=rgba`, out]);
  rmSync(tmp, { force: true });
} else {
  renameSync(tmp, out);
}
console.log(`wrote ${out}${crop ? `  (trimmed to ${crop.split(':').slice(0, 2).join('x')})` : ''}`);
