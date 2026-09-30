# Piggy Growth — 10s vertical 3D animation (1080×1920, 60fps)

- `index.html` — the whole scene (three.js). Every frame comes from `seek(t)` alone, with no accumulated state.
- `render.mjs` — Playwright + FFmpeg.

```bash
npm install
node render.mjs stills 0.6 5.2 9.9 "?guides=1"   # review frames with a safe-area overlay
node render.mjs check                            # automated checks over all 600 frames
node render.mjs video                            # out/piggy-growth.mp4 (WORKERS=3 by default)
node render.mjs luma                             # brightness check (flash detection)
```

Pipeline: 4 sub-frames per frame over half a frame's duration → image2pipe at 240fps →
`tmix=frames=4` → `select=eq(mod(n,4),3)` → `setpts=N/(60*TB)` → H.264 yuv420p.
