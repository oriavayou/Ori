#!/usr/bin/env node
/**
 * Captures the raw material for the edited tour: a full-page screenshot of every
 * page, in phone and desktop widths, plus each page's real title.
 *
 *   node promo/tools/site-shots.mjs --url https://example.com/
 *   node promo/tools/site-shots.mjs --url https://example.com/ --pages "/,/about,/contact"
 *
 * Writes promo/shots/*.jpg and promo/shots/shots.json (the edit's manifest).
 *
 * Options:
 *   --url      site to capture [required]
 *   --pages    comma separated paths; default: discovered from the home page's links
 *   --max      how many pages to keep when discovering (default 4)
 *   --hide     selectors to hide before capturing (cookie bars, chat bubbles)
 *   --tall     max page height to keep, in CSS px (default 7000)
 */
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { args, loadPlaywright, ffmpegPath } from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const PROMO = join(HERE, '..');
const OUT = join(PROMO, 'shots');

const { get } = args();
const url = get('url');
if (!url) {
  console.error('usage: node promo/tools/site-shots.mjs --url https://your-site.com/');
  process.exit(1);
}
const max = Number(get('max', 4));
const tall = Number(get('tall', 7000));
const hideSel = (get('hide', '') || '').split(',').map((s) => s.trim()).filter(Boolean);
const explicit = (get('pages', '') || '').split(',').map((s) => s.trim()).filter(Boolean);

// A full-page screenshot is taken beyond the viewport, so viewport units keep
// meaning what they mean on the real screen. Pixel ratios are set so the tallest
// realistic page still lands under Chromium's image size ceiling.
const VIEWS = [
  { name: 'phone', width: 432, height: 768, dpr: 1.5, mobile: true },
  { name: 'desktop', width: 1280, height: 800, dpr: 1.25, mobile: false },
];

rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });

const FFMPEG = await ffmpegPath();
const { chromium } = await loadPlaywright();
const browser = await chromium.launch({ args: ['--force-color-profile=srgb'] });

const prep = async (page) => {
  await page.addStyleTag({
    content: `html{scroll-behavior:auto !important}
      ${hideSel.length ? hideSel.join(',') + '{display:none !important}' : ''}`,
  }).catch(() => {});
  // wake lazy images, then return to the top
  await page.evaluate(async () => {
    const step = window.innerHeight * 0.9;
    for (let y = 0; y < document.body.scrollHeight; y += step) {
      window.scrollTo(0, y);
      await new Promise((r) => setTimeout(r, 110));
    }
    window.scrollTo(0, 0);
  });
  await page.waitForTimeout(700);
};

/* --- which pages to film ---------------------------------------------------- */
let paths = explicit;
if (!paths.length) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  await page.goto(url, { waitUntil: 'load', timeout: 90000 });
  await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {});
  paths = await page.evaluate((max) => {
    const origin = location.origin;
    const seen = new Map([['/', document.title]]);
    for (const a of document.querySelectorAll('a[href]')) {
      let u;
      try { u = new URL(a.href, origin); } catch { continue; }
      if (u.origin !== origin) continue;
      const p = u.pathname.replace(/\/+$/, '') || '/';
      if (/\.(pdf|jpe?g|png|zip|docx?)$/i.test(p)) continue;
      if (!seen.has(p)) seen.set(p, (a.textContent || '').trim());
    }
    // shortest paths first: those are the real sections, not deep leaves
    return [...seen.keys()].sort((a, b) => a.length - b.length).slice(0, max + 1);
  }, max);
  await page.close();
}
paths = [...new Set(paths)].slice(0, max + 1);
console.log(`filming ${paths.length} pages:`, paths.join('  '));

/* --- capture ---------------------------------------------------------------- */
const shots = [];
for (const [i, path] of paths.entries()) {
  const target = new URL(path, url).href;
  const slug = (path === '/' ? 'home' : path.replace(/[^\w֐-׿]+/g, '-')).replace(/^-|-$/g, '') || `p${i}`;
  const entry = { slug, path, url: target, views: {} };

  for (const v of VIEWS) {
    const page = await browser.newPage({
      viewport: { width: v.width, height: v.height },
      deviceScaleFactor: v.dpr,
      isMobile: v.mobile,
      hasTouch: v.mobile,
    });
    try {
      await page.goto(target, { waitUntil: 'load', timeout: 90000 });
      await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {});
      await prep(page);
      const h = await page.evaluate(() => document.documentElement.scrollHeight);
      const file = `${slug}-${v.name}.jpg`;
      const path = join(OUT, file);
      writeFileSync(path, await page.screenshot({ type: 'jpeg', quality: 86, fullPage: true }));
      let height = h;
      if (h > tall) {                      // keep the top of very long pages only
        height = tall;
        const px = Math.round(tall * v.dpr);
        execFileSync(FFMPEG, ['-y', '-hide_banner', '-loglevel', 'error', '-i', path,
          '-vf', `crop=${Math.round(v.width * v.dpr)}:${px}:0:0`, '-q:v', '3', path + '.tmp.jpg']);
        execFileSync('mv', [path + '.tmp.jpg', path]);
      }
      entry.views[v.name] = { file, w: v.width, h: height };
      if (!entry.title) {
        entry.title = (await page.title()).split(/[|–—-]/)[0].trim();
        entry.heading = await page.evaluate(() => {
          const h1 = document.querySelector('h1, h2');
          return h1 ? h1.textContent.trim().slice(0, 60) : '';
        });
      }
      console.log(`  ${slug} ${v.name}: ${v.width}x${height}`);
    } catch (e) {
      console.warn(`  ! ${slug} ${v.name}: ${e.message.split('\n')[0]}`);
    }
    await page.close();
  }
  if (Object.keys(entry.views).length) shots.push(entry);
}

await browser.close();
writeFileSync(join(OUT, 'shots.json'), JSON.stringify({ site: url, shots }, null, 2));
console.log(`\nwrote ${join(OUT, 'shots.json')} (${shots.length} pages)`);
