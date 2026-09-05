#!/usr/bin/env node
/**
 * Downloads the animation libraries the scroll site uses into promo/site/vendor/
 * so the page renders offline and can be filmed without a CDN.
 *
 *   node promo/tools/vendor-libs.mjs
 *
 * The published/artifact build loads the same versions from a CDN instead —
 * see tools/build-artifact.mjs. Keep the versions here and there in sync.
 */
import { execSync } from 'node:child_process';
import { mkdirSync, copyFileSync, rmSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const VERSIONS = { gsap: '3.13.0', lenis: '1.3.11' };

const HERE = dirname(fileURLToPath(import.meta.url));
const VENDOR = join(HERE, '..', 'site', 'vendor');
const TMP = join(HERE, '..', '.vendor-tmp');

const WANTED = [
  ['gsap', 'dist/gsap.min.js'],
  ['gsap', 'dist/ScrollTrigger.min.js'],
  ['gsap', 'dist/SplitText.min.js'],
  ['gsap', 'dist/CustomEase.min.js'],
  ['gsap', 'dist/DrawSVGPlugin.min.js'],
  ['gsap', 'dist/MorphSVGPlugin.min.js'],
  ['lenis', 'dist/lenis.min.js'],
];

rmSync(TMP, { recursive: true, force: true });
mkdirSync(TMP, { recursive: true });
mkdirSync(VENDOR, { recursive: true });

for (const [pkg, version] of Object.entries(VERSIONS)) {
  console.log(`fetching ${pkg}@${version}`);
  execSync(`npm pack ${pkg}@${version} --silent`, { cwd: TMP, stdio: 'inherit' });
  const tgz = `${pkg}-${version}.tgz`;
  execSync(`tar -xzf ${tgz}`, { cwd: TMP });
  execSync(`mv package ${pkg}`, { cwd: TMP });
}

for (const [pkg, file] of WANTED) {
  const from = join(TMP, pkg, file);
  if (!existsSync(from)) throw new Error(`missing ${pkg}/${file}`);
  copyFileSync(from, join(VENDOR, file.split('/').pop()));
  console.log(`  vendor/${file.split('/').pop()}`);
}

rmSync(TMP, { recursive: true, force: true });
console.log(`\nvendored into ${VENDOR}`);
