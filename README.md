# Welcome to your Lovable project

This project was built with [Lovable](https://lovable.dev).

## Build with Lovable

Open your project in the [Lovable editor](https://lovable.dev) and keep building.

- **Ship faster**: describe what you want to build and Lovable handles the code.
- **Stay in sync**: connect the project to GitHub and every change made in Lovable is committed straight to your repository.
- **Full ownership**: this code is yours. Push to your repository and your changes sync back into Lovable, ready for your next prompt.

## Development

Prefer working locally? You need Node.js and npm — [install with nvm](https://github.com/nvm-sh/nvm#installing-and-updating).

```sh
git clone <this-repository-url>
cd <repository-name>
npm i
npm run dev
```

## Built with

- TanStack Start
- TypeScript
- React
- Tailwind CSS

## Tests

The calculator lives in `src/site/nekudat-hakera.html`. Its tests load that page in headless Chromium and call its functions, then run the whole wizard with a synthetic clearing-house XML file:

```sh
NODE_PATH="$(npm root -g)" node tests/run.mjs
```

They need Playwright installed globally (`npm i -g playwright`). Set `VENDOR_DIR` to a folder whose `node_modules` holds `pdfjs-dist`, `jszip`, `jspdf` and `html2canvas` to serve those CDN scripts locally.
