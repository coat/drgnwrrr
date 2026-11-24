// The wasm engine (src/web/main.zig) behind a small JS API. Strings go in as
// UTF-8 copied into wasm memory; the log comes back as text, state as JSON.

/** Mark bits in tiles().mark (see Mark in src/session.zig). */
export const Mark = { hero: 0x80, npc: 0x40, moves: 0x08, route: 0x20, sprite: 0x07 };

export async function loadEngine(url = 'drgnwrrr.wasm') {
  const dec = new TextDecoder();
  const enc = new TextEncoder();
  let x;
  const text = (p, n) => dec.decode(new Uint8Array(x.memory.buffer, p, n));
  const env = { jsLog: (p, n) => console.error('[drgnwrrr]', text(p, n)) };
  const { instance } = await WebAssembly.instantiateStreaming(fetch(url), { env });
  x = instance.exports;

  const json = (n) => (n ? JSON.parse(text(x.jsonPtr(), n)) : null);
  const sram = () => new Uint8Array(x.memory.buffer, x.sramPtr(), x.sramLen());

  return {
    /** Start over with a seed for a new game; clears the SRAM. */
    boot: (seed) => x.boot(seed >>> 0),
    /** A copy of the SRAM (8 KB, the CLI's .sav format). */
    saveData: () => sram().slice(),
    loadSaveData: (bytes) => sram().set(bytes.subarray(0, x.sramLen())),
    hasSave: () => !!x.hasSave(),
    /** True once after the king saves. */
    sramDirty: () => !!x.sramDirty(),
    continueGame() {
      const ok = !!x.continueGame();
      return { ok, out: text(x.outPtr(), x.outLen()) };
    },
    newGame: () => x.newGame(),
    reseed: (seed) => x.reseed(seed >>> 0),
    setAssist: (on) => x.setAssist(on ? 1 : 0),
    /** Runs one command line; returns its log text. */
    submit(line, idleMs = 0) {
      const bytes = enc.encode(line);
      const size = Math.max(1, bytes.length);
      const p = x.alloc(size);
      new Uint8Array(x.memory.buffer, p, bytes.length).set(bytes);
      try {
        x.submit(p, bytes.length, Math.max(0, Math.round(idleMs)) >>> 0);
      } finally {
        x.free(p, size);
      }
      return text(x.outPtr(), x.outLen());
    },
    view: () => json(x.view()),
    danger: () => json(x.danger()),
    /** w*h tile ids and w*h Mark bytes for a rectangle of the current map. */
    tiles(x0, y0, w, h) {
      const p = x.tiles(x0 | 0, y0 | 0, w >>> 0, h >>> 0);
      const n = w * h;
      return {
        tile: new Uint8Array(x.memory.buffer, p, n).slice(),
        mark: new Uint8Array(x.memory.buffer, p + n, n).slice(),
      };
    },
  };
}
