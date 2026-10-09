/* Loads the calculator page (src/site/nekudat-hakera.html) in headless Chromium
   so its in-page functions can be tested directly.
   Run with:  NODE_PATH="$(npm root -g)" node tests/run.mjs
   CDN scripts are aborted unless VENDOR_DIR points at a folder holding
   node_modules/{pdfjs-dist,jszip,jspdf,html2canvas}. */
import { readFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const HTML_PATH = path.join(here, "..", "src", "site", "nekudat-hakera.html");

function loadPlaywright() {
  const require = createRequire(import.meta.url);
  try {
    return require("playwright");
  } catch {
    /* fall through */
  }
  for (const dir of (process.env.NODE_PATH || "").split(path.delimiter).filter(Boolean)) {
    try {
      return require(path.join(dir, "playwright"));
    } catch {
      /* next */
    }
  }
  throw new Error('playwright not found — run with NODE_PATH="$(npm root -g)"');
}

const CDN = {
  "pdf.min.js": "pdfjs-dist/build/pdf.min.js",
  "pdf.worker.min.js": "pdfjs-dist/build/pdf.worker.min.js",
  "jszip.min.js": "jszip/dist/jszip.min.js",
  "jspdf.umd.min.js": "jspdf/dist/jspdf.umd.min.js",
  "html2canvas.min.js": "html2canvas/dist/html2canvas.min.js",
};

export async function openPage(htmlPath = HTML_PATH) {
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  const vendor = process.env.VENDOR_DIR;
  await page.route("**/*", (route) => {
    const url = route.request().url();
    if (url.startsWith("http://maazan.test/")) {
      return route.fulfill({ contentType: "text/html", body: readFileSync(htmlPath, "utf8") });
    }
    const file = Object.keys(CDN).find((k) => url.endsWith("/" + k));
    if (file && vendor) {
      const p = path.join(vendor, "node_modules", CDN[file]);
      if (existsSync(p))
        return route.fulfill({ contentType: "application/javascript", body: readFileSync(p) });
    }
    return route.abort();
  });
  await page.goto("http://maazan.test/", { waitUntil: "load" });
  return { browser, page, errors };
}
