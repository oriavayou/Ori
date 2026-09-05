#!/usr/bin/env node
/**
 * Films the real website and wraps it in the branded opening and closing cards:
 *
 *   [ intro card ] -> [ the actual site, scrolling ] -> [ closing card ]
 *
 * The site is loaded in a phone-sized viewport at a high device pixel ratio, so
 * it renders its real mobile layout and the screenshots come out at full
 * 1080x1920. Everything is written into a single ffmpeg pipe, so the three
 * sections come out as one continuous MP4.
 *
 *   node promo/tools/site-promo.mjs --url https://example.com/
 *   node promo/tools/site-promo.mjs --url file:///path/to/saved-page.html
 *
 * Options:
 *   --url        page to film (http(s):// or file://) [required]
 *   --content    branding + cards (default promo/content.json)
 *   --out        output mp4 (default promo/out/site-promo.mp4)
 *   --intro      scene types used for the opening card (default intro,hook)
 *   --outro      scene types used for the closing card (default cta)
 *   --scroll     seconds spent scrolling the site (default 13)
 *   --hold-top   seconds held on the top of the page (default 1.2)
 *   --hold-end   seconds held on the bottom (default 1)
 *   --css-width  CSS viewport width in px, i.e. which layout to film (default 430)
 *   --hide       comma separated selectors to hide (cookie bars, chat bubbles)
 *   --no-overlay drop the brand chip + progress bar drawn over the site
 *   --fps --quality --quiet
 * Env: FFMPEG=/path/to/ffmpeg (otherwise ffmpeg-static, otherwise `ffmpeg` on PATH)
 */
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { args, loadPlaywright, serveDir, encoder, progress, ffmpegPath } from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const PROMO = resolve(HERE, '..');

const { get, has } = args();
let url = get('url');
if (!url) {
  console.error('usage: node promo/tools/site-promo.mjs --url https://your-site.com/');
  process.exit(1);
}
const content = JSON.parse(readFileSync(resolve(ROOT, get('content', join(PROMO, 'content.json'))), 'utf8'));
const meta = content.meta || {};
const W = meta.width || 1080;
const H = meta.height || 1920;
const fps = Number(get('fps', meta.fps || 30));
const outPath = resolve(ROOT, get('out', 'promo/out/site-promo.mp4'));
const scrollSecs = Number(get('scroll', 13));
const holdTop = Number(get('hold-top', 1.2));
const holdEnd = Number(get('hold-end', 1));
const cssWidth = Number(get('css-width', 432));  // 432 * 2.5 = 1080 exactly
const hideSel = (get('hide', '') || '').split(',').map((s) => s.trim()).filter(Boolean);
const overlay = !has('no-overlay');
const quiet = has('quiet');
const shot = { type: 'jpeg', quality: Number(get('quality', 95)) };
const log = (...a) => !quiet && console.log(...a);

// --- split content.json into an opening and a closing card -------------------
const pickScenes = (types) => {
  const wanted = types.split(',').map((s) => s.trim()).filter(Boolean);
  const scenes = (content.scenes || []).filter((s) => wanted.includes(s.type));
  if (!scenes.length) return null;
  const offset = scenes[0].start;
  return {
    duration: scenes[scenes.length - 1].end - offset,
    scenes: scenes.map((s) => ({ ...s, start: s.start - offset, end: s.end - offset })),
  };
};
const intro = pickScenes(get('intro', 'intro,hook'));
const outro = pickScenes(get('outro', 'cta'));

const siteSecs = holdTop + scrollSecs + holdEnd;
const totalSecs = (intro?.duration || 0) + siteSecs + (outro?.duration || 0);
const clipContent = (clip, offset) => ({
  ...content,
  meta: { ...meta, duration: clip.duration, progress: { total: totalSecs, offset } },
  scenes: clip.scenes,
});

mkdirSync(dirname(outPath), { recursive: true });
const server = await serveDir(PROMO);
// a bare path means "a page inside promo/", e.g. --url site/index.html?render=1
if (!/^(https?|file):/.test(url)) url = server.origin + '/' + url.replace(/^\/+/, '');
const { chromium } = await loadPlaywright();
const browser = await chromium.launch({ args: ['--force-color-profile=srgb', '--disable-lcd-text'] });
const enc = encoder(outPath, { fps, bin: await ffmpegPath(), size: [W, H] });
const t0 = Date.now();
let written = 0;
const totalFrames = Math.round(totalSecs * fps);

// --- branded card sections ---------------------------------------------------
async function renderCard(clip, offset, label) {
  if (!clip) return;
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  await page.addInitScript((c) => { window.__CONTENT = c; }, clipContent(clip, offset));
  await page.goto(server.origin + '/scene.html', { waitUntil: 'load' });
  await page.evaluate(() => window.__ready);
  await page.evaluate(() => document.documentElement.classList.add('paused'));
  const frames = Math.round(clip.duration * fps);
  log(`\n${label}: ${frames} frames`);
  for (let i = 0; i < frames; i++) {
    await page.evaluate(
      (t) => (window.__seek(t), new Promise((r) => requestAnimationFrame(() => r(true)))),
      i / fps
    );
    await enc.write(await page.screenshot(shot));
    progress(written++, totalFrames, t0, quiet);
  }
  await page.close();
}

// --- the site itself ---------------------------------------------------------
async function renderSite() {
  const vh = Math.round((cssWidth * H) / W);
  const page = await browser.newPage({
    viewport: { width: cssWidth, height: vh },
    deviceScaleFactor: W / cssWidth,
    isMobile: true,
    hasTouch: true,
  });
  log(`\nloading ${url} at ${cssWidth}x${vh} css px (dpr ${(W / cssWidth).toFixed(2)})`);
  await page.goto(url, { waitUntil: 'load', timeout: 90000 });
  await page.waitForLoadState('networkidle', { timeout: 45000 }).catch(() => {});
  // pages that build their own scroll timeline announce when it is ready
  await page.evaluate(() => window.__ready).catch(() => {});

  // Never add a CSS transition to a page that animates with JS: the browser would
  // ease toward every value the animation library sets, so a frame captured right
  // after a seek shows the *previous* state. Only shorten transitions on pages
  // that have no scroll timeline of their own.
  const ownsTimeline = await page.evaluate(() => typeof window.__renderSeek === 'function');
  await page.addStyleTag({
    content: `html{scroll-behavior:auto !important}
      ${ownsTimeline ? '' : '*,*::before,*::after{transition-duration:.12s !important}'}
      ${hideSel.length ? hideSel.join(',') + '{display:none !important}' : ''}`,
  });

  // walk the page once so lazy-loaded images and scroll-triggered sections fire
  await page.evaluate(async () => {
    const step = window.innerHeight * 0.8;
    for (let y = 0; y < document.body.scrollHeight; y += step) {
      window.scrollTo(0, y);
      await new Promise((r) => setTimeout(r, 120));
    }
    window.scrollTo(0, 0);
  });
  await page.waitForTimeout(900);

  if (overlay) {
    await page.addStyleTag({ content: readFileSync(join(PROMO, 'fonts.css'), 'utf8') });
    await page.evaluate(({ brand, theme }) => {
      const wrap = document.createElement('div');
      wrap.id = '__promo_overlay';
      wrap.innerHTML = `
        <div id="__promo_bar"><i></i></div>
        <div id="__promo_chip"><b>${brand.mark || '★'}</b><span>${brand.name || ''}</span></div>`;
      const css = document.createElement('style');
      css.textContent = `
        #__promo_overlay{position:fixed;inset:0;z-index:2147483647;pointer-events:none;
          font-family:'Rubik',system-ui,sans-serif;direction:rtl}
        #__promo_bar{position:absolute;top:0;left:0;right:0;height:8px;background:rgba(0,0,0,.18)}
        #__promo_bar i{display:block;height:100%;transform-origin:right center;transform:scaleX(0);
          background:linear-gradient(90deg,${theme.c2},${theme.c1},${theme.c3})}
        #__promo_chip{position:absolute;bottom:28px;right:24px;display:flex;align-items:center;gap:9px;
          padding:8px 14px;border-radius:999px;font-size:15px;font-weight:600;color:#fff;
          background:rgba(10,12,20,.72);border:1px solid rgba(255,255,255,.16);
          box-shadow:0 8px 30px rgba(0,0,0,.35)}
        #__promo_chip b{display:grid;place-items:center;width:22px;height:22px;border-radius:50%;
          font-size:12px;background:linear-gradient(135deg,${theme.c1},${theme.c3})}`;
      document.head.appendChild(css);
      document.body.appendChild(wrap);
    }, { brand: content.brand || {}, theme: content.theme || {} });
  }

  const maxScroll = await page.evaluate(
    () => Math.max(0, document.documentElement.scrollHeight - window.innerHeight)
  );
  log(`  page height: ${maxScroll + vh}px css, scrolling ${maxScroll}px over ${scrollSecs}s`);

  const frames = Math.round(siteSecs * fps);
  const ease = (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2);
  const offset = intro?.duration || 0;

  for (let i = 0; i < frames; i++) {
    const t = i / fps;
    let p = 0;
    if (t > holdTop) p = Math.min(1, (t - holdTop) / scrollSecs);
    const y = Math.round(ease(p) * maxScroll);
    await page.evaluate(
      ([yy, prog]) => {
        // pages with scroll-driven animation expose __renderSeek so the frame is
        // guaranteed to be laid out for this exact scroll position
        if (window.__renderSeek) window.__renderSeek(yy);
        else window.scrollTo(0, yy);
        const bar = document.querySelector('#__promo_bar i');
        if (bar) bar.style.transform = `scaleX(${prog})`;
        return new Promise((r) => requestAnimationFrame(() => r(true)));
      },
      [y, (offset + t) / totalSecs]
    );
    await enc.write(await page.screenshot(shot));
    progress(written++, totalFrames, t0, quiet);
  }

  // a cover frame from the top of the real site
  await page.evaluate(() => window.scrollTo(0, 0));
  writeFileSync(join(dirname(outPath), 'site-cover.png'), await page.screenshot({ type: 'png' }));
  await page.close();
}

log(`total ${totalSecs.toFixed(1)}s -> ${outPath}`);
await renderCard(intro, 0, 'intro card');
await renderSite();
await renderCard(outro, (intro?.duration || 0) + siteSecs, 'closing card');
await enc.finish();

await browser.close();
server.close();
log(`\ndone in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
log(`  video: ${outPath}`);
