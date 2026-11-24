// The map: centred on the hero (or wherever you've panned), redrawn in full
// after every change. Pinch, the wheel or the on-map buttons zoom; dragging
// pans; a tap picks a tile. Far out, tiles are drawn as solid colour, like a
// minimap.
import { Mark } from './engine.js';
import { ATLAS, SPRITES, TILES, HERO, NPCS, ROUTE_COLOR, FONT, TITLE } from './atlas.js';

const GLYPH = ATLAS.cell;

/** Tiles across the shorter side, at least, at the default zoom. */
const MIN_TILES = 11;
/** The default zoom draws glyphs at most this many times their size (CSS pixels). */
const DEFAULT_ZOOM = 2;
/** Zooming in stops at this many CSS pixels a tile. */
const MAX_TILE_CSS = 64;
/** Below this many device pixels a tile, draw colour instead of a glyph. */
const SOLID_BELOW = 8;
/** A drag shorter than this (CSS px) is a tap. */
const TAP_SLOP = 8;

export function createMap(canvas, getEngine, { onTap, onHover } = {}) {
  const ctx = canvas.getContext('2d');
  const sheet = new Image();
  const cache = new Map();
  let view = null;
  /** Device pixels a tile, or null for the default zoom. */
  let zoomTs = null;
  /** Where the view is centred, in tiles from the hero. */
  let pan = { x: 0, y: 0 };
  let heroKey = '';
  let ts = 32;

  /** The `size` px square of the sheet at (sx, sy), in `color`. */
  function tinted(key, sx, sy, size, color) {
    let c = cache.get(key);
    if (c) return c;
    c = document.createElement('canvas');
    c.width = c.height = size;
    const t = c.getContext('2d');
    t.drawImage(sheet, sx, sy, size, size, 0, 0, size, size);
    t.globalCompositeOperation = 'source-in';
    t.fillStyle = color;
    t.fillRect(0, 0, size, size);
    cache.set(key, c);
    return c;
  }

  function glyph(look) {
    const [sx, sy] = SPRITES[look.sprite];
    return tinted(`${look.sprite}|${look.color}`, sx, sy, GLYPH, look.color);
  }

  /** Before there's a game: the overworld around view.title_at, dimmed, with
   * the game's name big across the middle (as src/sdl/Map.zig drawTitle). */
  function drawTitle() {
    const at = view?.title_at;
    if (!at) return;
    const w = canvas.width, h = canvas.height;
    const tsz = GLYPH * Math.max(1, Math.round(Math.min(w, h) / (GLYPH * TITLE.tiles)));
    const cols = Math.ceil(w / tsz) + 2, rows = Math.ceil(h / tsz) + 2;
    const hc = Math.floor(cols / 2), hr = Math.floor(rows / 2);
    const { tile } = getEngine().tiles(at.x - hc, at.y - hr, cols, rows);
    // The middle of title_at's tile in the middle of the canvas.
    const ox = Math.round(w / 2 - (hc + 0.5) * tsz), oy = Math.round(h / 2 - (hr + 0.5) * tsz);
    for (let j = 0; j < rows; j++) {
      for (let i = 0; i < cols; i++) {
        const look = TILES[tile[j * cols + i]];
        if (look) ctx.drawImage(glyph(look), ox + i * tsz, oy + j * tsz, tsz, tsz);
      }
    }
    ctx.fillStyle = `rgba(0, 0, 0, ${TITLE.dim / 255})`;
    ctx.fillRect(0, 0, w, h);

    // The name in whole multiples of the font, about two thirds of the width.
    const name = 'drgnwrrr';
    const scale = Math.max(Math.round(dpr()), Math.floor((w * 2) / 3 / (FONT.size * name.length)));
    const x = Math.round((w - name.length * FONT.size * scale) / 2);
    const y = Math.round((h - FONT.size * scale) / 2);
    const drop = Math.max(1, Math.round(scale / 2));
    text(name, x + drop, y + drop, scale, '#000');
    text(name, x, y, scale, TITLE.color);
  }

  /** One line in the atlas's Anvil font, `scale` device px a font pixel. */
  function text(s, x, y, scale, color) {
    const n = FONT.size;
    for (let i = 0; i < s.length; i++) {
      const ch = s.charCodeAt(i);
      if (ch === 32) continue;
      const k = ch >= FONT.first && ch < FONT.first + FONT.count ? ch - FONT.first : 63 - FONT.first;
      ctx.drawImage(tinted(`font${k}|${color}`, FONT.x + (k % FONT.cols) * n, FONT.y + Math.floor(k / FONT.cols) * n, n, color),
        x + i * n * scale, y, n * scale, n * scale);
    }
  }

  const dpr = () => window.devicePixelRatio || 1;

  /** The tile-size range for the current map, in device pixels. */
  function limits() {
    const g = view?.game;
    const most = g ? Math.max(g.width, g.height) + 4 : 24;
    const min = Math.max(2, Math.floor(Math.min(canvas.width, canvas.height) / most));
    return { min, max: Math.max(min, Math.round(MAX_TILE_CSS * dpr())) };
  }

  function layout() {
    const w = Math.max(1, Math.round(canvas.clientWidth * dpr()));
    const h = Math.max(1, Math.round(canvas.clientHeight * dpr()));
    if (canvas.width !== w) canvas.width = w;
    if (canvas.height !== h) canvas.height = h;
    const fit = Math.floor(Math.min(w, h) / (GLYPH * MIN_TILES));
    const def = GLYPH * Math.max(1, Math.min(fit, Math.round(DEFAULT_ZOOM * dpr())));
    const { min, max } = limits();
    ts = Math.min(max, Math.max(min, zoomTs ?? def));
  }

  /** The view's centre, in tile coordinates (the middle of the hero's tile is g.x + 0.5). */
  const centre = () => ({ x: view.game.x + 0.5 + pan.x, y: view.game.y + 0.5 + pan.y });
  const toWorld = (sx, sy) => {
    const c = centre();
    return { x: c.x + (sx - canvas.width / 2) / ts, y: c.y + (sy - canvas.height / 2) / ts };
  };

  function draw(v) {
    if (v !== undefined) {
      view = v;
      const g = v?.game;
      const key = g ? `${g.map},${g.x},${g.y}` : '';
      if (key !== heroKey) {
        heroKey = key;
        pan = { x: 0, y: 0 }; // the hero moved: follow them again
      }
    }
    layout();
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    if (!sheet.complete) return;
    ctx.imageSmoothingEnabled = false;
    const g = view?.game;
    if (!g) return drawTitle();
    const tl = toWorld(0, 0);
    const x0 = Math.floor(tl.x), y0 = Math.floor(tl.y);
    const cols = Math.ceil(canvas.width / ts) + 2;
    const rows = Math.ceil(canvas.height / ts) + 2;
    const c = centre();
    const ox = Math.round(canvas.width / 2 - (c.x - x0) * ts);
    const oy = Math.round(canvas.height / 2 - (c.y - y0) * ts);
    const { tile, mark } = getEngine().tiles(x0, y0, cols, rows);
    const solid = ts < SOLID_BELOW;
    const dot = Math.max(2, ts / 8);
    for (let j = 0; j < rows; j++) {
      for (let i = 0; i < cols; i++) {
        const k = j * cols + i;
        const px = ox + i * ts, py = oy + j * ts;
        const m = mark[k];
        const look = m & Mark.hero ? HERO : m & Mark.npc ? NPCS[m & Mark.sprite] : TILES[tile[k]];
        if (look) {
          if (solid) {
            ctx.fillStyle = look.color;
            ctx.fillRect(px, py, ts, ts);
          } else ctx.drawImage(glyph(look), px, py, ts, ts);
        }
        if (m & Mark.route && !(m & Mark.hero)) {
          ctx.fillStyle = '#000';
          ctx.fillRect(px + (ts - dot) / 2 - 1, py + (ts - dot) / 2 - 1, dot + 2, dot + 2);
          ctx.fillStyle = ROUTE_COLOR;
          ctx.fillRect(px + (ts - dot) / 2, py + (ts - dot) / 2, dot, dot);
        }
      }
    }
    if (solid) {
      // Too small to see: ring the hero.
      const hx = ox + (g.x - x0) * ts, hy = oy + (g.y - y0) * ts;
      ctx.strokeStyle = HERO.color;
      ctx.lineWidth = Math.max(1, dpr());
      ctx.strokeRect(hx - 2 * ts, hy - 2 * ts, 5 * ts, 5 * ts);
    }
  }

  /** The tile at a client position; `off` past the map's edge. */
  function tileAtClient(clientX, clientY) {
    const g = view?.game;
    if (!g) return null;
    const r = canvas.getBoundingClientRect();
    const w = toWorld((clientX - r.left) * dpr(), (clientY - r.top) * dpr());
    const x = Math.floor(w.x), y = Math.floor(w.y);
    const off = x < 0 || y < 0 || x >= g.width || y >= g.height;
    const { tile } = getEngine().tiles(x, y, 1, 1);
    return { x, y, off, tile: tile[0], name: TILES[tile[0]]?.name ?? '' };
  }

  /** Zoom by `factor`, keeping the point at (sx, sy) device px still. */
  function zoomAt(factor, sx = canvas.width / 2, sy = canvas.height / 2) {
    if (!view?.game) return;
    const before = toWorld(sx, sy);
    const { min, max } = limits();
    const next = Math.min(max, Math.max(min, Math.round(ts * factor)));
    if (next === ts) return;
    zoomTs = next;
    ts = next;
    const after = toWorld(sx, sy);
    pan.x += before.x - after.x;
    pan.y += before.y - after.y;
    draw();
  }

  // ---------- gestures ----------

  const pointers = new Map();
  let gesture = null;

  canvas.addEventListener('pointerdown', (ev) => {
    canvas.setPointerCapture(ev.pointerId);
    pointers.set(ev.pointerId, { x: ev.clientX, y: ev.clientY });
    if (pointers.size === 1) {
      gesture = { kind: 'one', sx: ev.clientX, sy: ev.clientY, pan: { ...pan }, moved: false };
    } else if (pointers.size === 2 && view?.game) {
      const [a, b] = [...pointers.values()];
      const r = canvas.getBoundingClientRect();
      const mid = { x: ((a.x + b.x) / 2 - r.left) * dpr(), y: ((a.y + b.y) / 2 - r.top) * dpr() };
      gesture = { kind: 'pinch', d: Math.hypot(a.x - b.x, a.y - b.y), ts, mid, world: toWorld(mid.x, mid.y) };
    }
  });

  canvas.addEventListener('pointermove', (ev) => {
    if (!pointers.has(ev.pointerId)) {
      if (ev.pointerType === 'mouse' && onHover) onHover(tileAtClient(ev.clientX, ev.clientY));
      return;
    }
    pointers.set(ev.pointerId, { x: ev.clientX, y: ev.clientY });
    if (!gesture || !view?.game) return;
    if (gesture.kind === 'one') {
      const dx = ev.clientX - gesture.sx, dy = ev.clientY - gesture.sy;
      if (!gesture.moved && Math.hypot(dx, dy) > TAP_SLOP) gesture.moved = true;
      if (gesture.moved) {
        pan = { x: gesture.pan.x - (dx * dpr()) / ts, y: gesture.pan.y - (dy * dpr()) / ts };
        draw();
      }
    } else if (gesture.kind === 'pinch' && pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      const { min, max } = limits();
      zoomTs = Math.min(max, Math.max(min, Math.round(gesture.ts * Math.hypot(a.x - b.x, a.y - b.y) / gesture.d)));
      ts = zoomTs;
      // Keep the world point that started under the fingers there.
      const now = toWorld(gesture.mid.x, gesture.mid.y);
      pan.x += gesture.world.x - now.x;
      pan.y += gesture.world.y - now.y;
      draw();
    }
  });

  function release(ev) {
    if (!pointers.delete(ev.pointerId)) return;
    const gs = gesture;
    if (pointers.size > 0) {
      gesture = gs?.kind === 'pinch' ? { kind: 'done' } : gs;
      return;
    }
    gesture = null;
    if (!gs || gs.kind !== 'one' || gs.moved || ev.type === 'pointercancel') return;
    const t = tileAtClient(ev.clientX, ev.clientY);
    if (t && onTap) onTap(t);
  }
  canvas.addEventListener('pointerup', release);
  canvas.addEventListener('pointercancel', release);
  canvas.addEventListener('pointerleave', (ev) => {
    if (ev.pointerType === 'mouse' && onHover) onHover(null);
  });
  canvas.addEventListener('wheel', (ev) => {
    ev.preventDefault();
    const r = canvas.getBoundingClientRect();
    zoomAt(ev.deltaY < 0 ? 1.25 : 0.8, (ev.clientX - r.left) * dpr(), (ev.clientY - r.top) * dpr());
  }, { passive: false });

  new ResizeObserver(() => draw()).observe(canvas);
  sheet.onload = () => draw();
  sheet.src = ATLAS.src;

  return {
    draw,
    zoomIn: () => zoomAt(2),
    zoomOut: () => zoomAt(0.5),
    /** Back to the hero, at the default zoom. */
    recentre() {
      pan = { x: 0, y: 0 };
      zoomTs = null;
      draw();
    },
    /** The whole map, as far out as it goes. */
    overview() {
      if (!view?.game) return;
      zoomTs = limits().min;
      pan = { x: view.game.width / 2 - view.game.x - 0.5, y: view.game.height / 2 - view.game.y - 0.5 };
      draw();
    },
  };
}
