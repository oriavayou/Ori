#!/usr/bin/env node
/**
 * Builds the shareable single-file version of promo/site/index.html:
 * takes the ARTIFACT region, inlines the fonts, and swaps the vendored library
 * paths for pinned CDN URLs (the only script hosts an Artifact may load).
 *
 *   node promo/tools/build-artifact.mjs   ->  promo/site/artifact.html
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { VERSIONS } from './vendor-libs.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const PROMO = join(HERE, '..');
const SITE = join(PROMO, 'site');

const CDN = {
  'vendor/gsap.min.js': `https://cdn.jsdelivr.net/npm/gsap@${VERSIONS.gsap}/dist/gsap.min.js`,
  'vendor/ScrollTrigger.min.js': `https://cdn.jsdelivr.net/npm/gsap@${VERSIONS.gsap}/dist/ScrollTrigger.min.js`,
  'vendor/SplitText.min.js': `https://cdn.jsdelivr.net/npm/gsap@${VERSIONS.gsap}/dist/SplitText.min.js`,
  'vendor/lenis.min.js': `https://cdn.jsdelivr.net/npm/lenis@${VERSIONS.lenis}/dist/lenis.min.js`,
};

const src = readFileSync(join(SITE, 'index.html'), 'utf8');
const start = src.indexOf('<!--ARTIFACT:START-->');
const end = src.indexOf('<!--ARTIFACT:END-->');
if (start < 0 || end < 0) throw new Error('ARTIFACT markers not found in site/index.html');

let out = src.slice(start + '<!--ARTIFACT:START-->'.length, end).trim();
out = out.replace('<!--FONTS-->', `<style>\n${readFileSync(join(PROMO, 'fonts.css'), 'utf8')}</style>`);
for (const [local, cdn] of Object.entries(CDN)) out = out.replaceAll(`"${local}"`, `"${cdn}"`);

// the title has to sit in the first 8KB, i.e. before the inlined fonts
writeFileSync(join(SITE, 'artifact.html'), `<title>יפתח ונגר</title>\n${out}\n`);
console.log(`wrote ${join(SITE, 'artifact.html')}`);
