//! The map, as web/map.js draws it: centred on the hero (or wherever it's
//! panned), zoomed by whole pixels a tile, and drawn as solid colour like a
//! minimap when zoomed far out.
const Map = @This();

gpa: Allocator,
/// Pixels a tile, or null for the default zoom.
zoom_ts: ?f32 = null,
/// Where the view is centred, in tiles from the hero.
pan: [2]f32 = .{ 0, 0 },
/// Where the hero was last drawn: when they move, the view follows again.
hero_at: ?dw.Warp = null,
/// Pixels a tile this frame.
ts: f32 = 32,
/// The map's box this frame, in pixels.
box: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
/// The UI scale this frame.
u: f32 = 1,
/// Tiles, then as many Mark bytes, for Session.mapCells.
cells: []u8 = &.{},
/// The controller's tile cursor, in map mode.
cursor: ?[2]i32 = null,

/// Tiles across the shorter side, at least, at the default zoom.
const min_tiles = 11;
/// Below this many pixels a tile, draw colour instead of a sprite.
const solid_below = 8;
const glyph: f32 = atlas.sprite_size;

pub fn deinit(self: *Map) void {
    self.gpa.free(self.cells);
}

/// The tile-size range for the current map.
fn limits(self: *const Map, g: *const Game) struct { f32, f32 } {
    const hdr = dw.map_headers[g.at.map];
    const most: f32 = @floatFromInt(@max(@as(u16, hdr.max_x), hdr.max_y) + 1 + 4);
    const min = @max(2, @floor(@min(self.box.w, self.box.h) / most));
    return .{ min, @max(min, 32 * self.u) };
}

/// Sizes the map to `box` for this frame.
pub fn place(self: *Map, box: c.SDL_FRect, u: f32, g: *const Game) void {
    self.box = box;
    self.u = u;
    if (self.hero_at == null or !std.meta.eql(self.hero_at.?, g.at)) {
        self.hero_at = g.at;
        self.pan = .{ 0, 0 }; // the hero moved: follow them again
    }
    const fit = @floor(@min(box.w, box.h) / (glyph * min_tiles));
    const def = glyph * @max(1, @min(fit, u));
    const min, const max = self.limits(g);
    self.ts = std.math.clamp(self.zoom_ts orelse def, min, max);
}

/// The view's centre in tile coordinates (the middle of the hero's tile is x + 0.5).
fn centre(self: *const Map, g: *const Game) [2]f32 {
    return .{ @as(f32, @floatFromInt(g.at.x)) + 0.5 + self.pan[0], @as(f32, @floatFromInt(g.at.y)) + 0.5 + self.pan[1] };
}

/// The world point at a window pixel.
fn toWorld(self: *const Map, g: *const Game, sx: f32, sy: f32) [2]f32 {
    const ctr = self.centre(g);
    return .{
        ctr[0] + (sx - self.box.x - self.box.w / 2) / self.ts,
        ctr[1] + (sy - self.box.y - self.box.h / 2) / self.ts,
    };
}

pub fn contains(self: *const Map, x: f32, y: f32) bool {
    return x >= self.box.x and y >= self.box.y and x < self.box.x + self.box.w and y < self.box.y + self.box.h;
}

pub const Spot = struct {
    x: i32,
    y: i32,
    /// Past the map's edge.
    off: bool,
    tile: dw.Tile,
};

/// The tile at a window pixel.
pub fn spotAt(self: *const Map, s: *const Session, sx: f32, sy: f32) Spot {
    const w = self.toWorld(&s.g, sx, sy);
    return tileSpot(s, @intFromFloat(@floor(w[0])), @intFromFloat(@floor(w[1])));
}

/// The tile at (x, y) of the current map.
pub fn tileSpot(s: *const Session, x: i32, y: i32) Spot {
    const g = &s.g;
    const hdr = dw.map_headers[g.at.map];
    var tile: [1]u8 = undefined;
    var mark: [1]u8 = undefined;
    s.mapCells(x, y, 1, 1, &tile, &mark);
    return .{ .x = x, .y = y, .off = x < 0 or y < 0 or x > hdr.max_x or y > hdr.max_y, .tile = @fromBackingInt(tile[0]) };
}

/// Zoom by `factor`, keeping the point at (sx, sy) still.
pub fn zoomAt(self: *Map, g: *const Game, factor: f32, sx: f32, sy: f32) void {
    const before = self.toWorld(g, sx, sy);
    const min, const max = self.limits(g);
    const next = std.math.clamp(@round(self.ts * factor), min, max);
    if (next == self.ts) return;
    self.zoom_ts = next;
    self.ts = next;
    const after = self.toWorld(g, sx, sy);
    self.pan[0] += before[0] - after[0];
    self.pan[1] += before[1] - after[1];
}

pub fn zoom(self: *Map, g: *const Game, factor: f32) void {
    self.zoomAt(g, factor, self.box.x + self.box.w / 2, self.box.y + self.box.h / 2);
}

/// Back to the hero, at the default zoom.
pub fn recentre(self: *Map) void {
    self.pan = .{ 0, 0 };
    self.zoom_ts = null;
}

/// The whole map, as far out as it goes.
pub fn overview(self: *Map, g: *const Game) void {
    const hdr = dw.map_headers[g.at.map];
    self.zoom_ts = self.limits(g)[0];
    self.pan = .{
        (@as(f32, @floatFromInt(hdr.max_x)) + 1) / 2 - @as(f32, @floatFromInt(g.at.x)) - 0.5,
        (@as(f32, @floatFromInt(hdr.max_y)) + 1) / 2 - @as(f32, @floatFromInt(g.at.y)) - 0.5,
    };
}

/// Moves the cursor a tile (starting at the hero), panning to keep it a tile
/// clear of the view's edge.
pub fn moveCursor(self: *Map, g: *const Game, dx: i32, dy: i32) void {
    const at = self.cursor orelse [2]i32{ g.at.x, g.at.y };
    const hdr = dw.map_headers[g.at.map];
    // One step past the edge is allowed: that's how you leave a town.
    const next = [2]i32{
        std.math.clamp(at[0] + dx, -1, @as(i32, hdr.max_x) + 1),
        std.math.clamp(at[1] + dy, -1, @as(i32, hdr.max_y) + 1),
    };
    self.cursor = next;
    const ctr = self.centre(g);
    const half = [2]f32{ self.box.w / 2 / self.ts, self.box.h / 2 / self.ts };
    for (0..2) |i| {
        const p = @as(f32, @floatFromInt(next[i])) + 0.5;
        const margin = @min(1.5, half[i] - 0.5);
        if (p < ctr[i] - half[i] + margin) self.pan[i] -= ctr[i] - half[i] + margin - p;
        if (p > ctr[i] + half[i] - margin) self.pan[i] += p - (ctr[i] + half[i] - margin);
    }
}

/// Drag the view by (dx, dy) pixels from where it was at `from`.
pub fn dragFrom(self: *Map, from: [2]f32, dx: f32, dy: f32) void {
    self.pan = .{ from[0] - dx / self.ts, from[1] - dy / self.ts };
}

/// Fills `cells` with the w x h rectangle at (x0, y0); null if it can't.
fn fetch(self: *Map, s: *const Session, x0: i32, y0: i32, cols: u32, rows: u32) ?struct { []u8, []u8 } {
    const n = @as(usize, cols) * rows;
    if (self.cells.len < 2 * n) {
        self.gpa.free(self.cells);
        self.cells = self.gpa.alloc(u8, 2 * n) catch {
            self.cells = &.{};
            return null;
        };
    }
    s.mapCells(x0, y0, cols, rows, self.cells[0..n], self.cells[n .. 2 * n]);
    return .{ self.cells[0..n], self.cells[n .. 2 * n] };
}

/// Before there's a game: the overworld around Session.title_at, dimmed,
/// with the game's name big across the middle.
pub fn drawTitle(self: *Map, r: Renderer, s: *const Session, box: c.SDL_FRect, u: f32) void {
    const at = Session.title_at;
    // Sprites at a whole multiple of their size, title_tiles or so across the shorter side.
    const ts = glyph * @max(1, @round(@min(box.w, box.h) / (glyph * looks.title_tiles)));
    const cols: u32 = @intFromFloat(@ceil(box.w / ts) + 2);
    const rows: u32 = @intFromFloat(@ceil(box.h / ts) + 2);
    const x0 = @as(i32, at.x) - @as(i32, @intCast(cols / 2));
    const y0 = @as(i32, at.y) - @as(i32, @intCast(rows / 2));
    const tile, _ = self.fetch(s, x0, y0, cols, rows) orelse return;
    // The middle of title_at's tile in the middle of the box.
    const ox = @round(box.x + box.w / 2 - (@as(f32, @floatFromInt(cols / 2)) + 0.5) * ts);
    const oy = @round(box.y + box.h / 2 - (@as(f32, @floatFromInt(rows / 2)) + 0.5) * ts);
    const clip: c.SDL_Rect = .{ .x = @intFromFloat(box.x), .y = @intFromFloat(box.y), .w = @intFromFloat(box.w), .h = @intFromFloat(box.h) };
    _ = c.SDL_SetRenderClipRect(r.sdl, &clip);
    defer _ = c.SDL_SetRenderClipRect(r.sdl, null);
    for (0..rows) |j| for (0..cols) |i| {
        const t = looks.tile(@fromBackingInt(tile[j * cols + i])) orelse continue;
        r.sprite(t.sprite, t.color, .{ .x = ox + @as(f32, @floatFromInt(i)) * ts, .y = oy + @as(f32, @floatFromInt(j)) * ts, .w = ts, .h = ts });
    };
    r.fillAlpha(box, 0, looks.title_dim);

    // The name in whole multiples of the font, about two thirds of the width.
    const name = "drgnwrrr";
    const font: f32 = atlas.font.size;
    const scale = @max(u, @floor(box.w * 2 / 3 / (font * name.len)));
    const w = Renderer.textWidth(name.len, scale);
    const x = @round(box.x + (box.w - w) / 2);
    const y = @round(box.y + (box.h - font * scale) / 2);
    const drop = @max(1, @round(scale / 2));
    r.text(name, x + drop, y + drop, scale, 0);
    r.text(name, x, y, scale, looks.title_color);
}

pub fn draw(self: *Map, r: Renderer, s: *const Session) void {
    const g = &s.g;
    const ts = self.ts;
    const tl = self.toWorld(g, self.box.x, self.box.y);
    const x0: i32 = @intFromFloat(@floor(tl[0]));
    const y0: i32 = @intFromFloat(@floor(tl[1]));
    const cols: u32 = @intFromFloat(@ceil(self.box.w / ts) + 2);
    const rows: u32 = @intFromFloat(@ceil(self.box.h / ts) + 2);
    const tile, const mark = self.fetch(s, x0, y0, cols, rows) orelse return;

    const ctr = self.centre(g);
    const ox = @round(self.box.x + self.box.w / 2 - (ctr[0] - @as(f32, @floatFromInt(x0))) * ts);
    const oy = @round(self.box.y + self.box.h / 2 - (ctr[1] - @as(f32, @floatFromInt(y0))) * ts);
    const clip: c.SDL_Rect = .{ .x = @intFromFloat(self.box.x), .y = @intFromFloat(self.box.y), .w = @intFromFloat(self.box.w), .h = @intFromFloat(self.box.h) };
    _ = c.SDL_SetRenderClipRect(r.sdl, &clip);
    defer _ = c.SDL_SetRenderClipRect(r.sdl, null);

    const solid = ts < solid_below;
    const dot = @max(2, ts / 8);
    for (0..rows) |j| for (0..cols) |i| {
        const k = j * cols + i;
        const dst: c.SDL_FRect = .{ .x = ox + @as(f32, @floatFromInt(i)) * ts, .y = oy + @as(f32, @floatFromInt(j)) * ts, .w = ts, .h = ts };
        const m = mark[k];
        const look: ?looks.Look = if (m & Mark.hero != 0)
            looks.hero
        else if (m & Mark.npc != 0)
            looks.npcs[m & 0x07]
        else if (looks.tile(@fromBackingInt(tile[k]))) |t|
            .{ .sprite = t.sprite, .color = t.color }
        else
            null;
        if (look) |l| {
            if (solid) r.fill(dst, l.color) else r.sprite(l.sprite, l.color, dst);
        }
        if (m & Mark.route != 0 and m & Mark.hero == 0) {
            r.fill(.{ .x = dst.x + (ts - dot) / 2 - 1, .y = dst.y + (ts - dot) / 2 - 1, .w = dot + 2, .h = dot + 2 }, 0);
            r.fill(.{ .x = dst.x + (ts - dot) / 2, .y = dst.y + (ts - dot) / 2, .w = dot, .h = dot }, looks.route_color);
        }
    };
    if (self.cursor) |cur| {
        // White on a black edge, to show on any tile.
        const tile_box: c.SDL_FRect = .{
            .x = ox + @as(f32, @floatFromInt(cur[0] - x0)) * ts,
            .y = oy + @as(f32, @floatFromInt(cur[1] - y0)) * ts,
            .w = ts,
            .h = ts,
        };
        const w = @max(2, @round(ts / 16));
        r.outline(.{ .x = tile_box.x - w, .y = tile_box.y - w, .w = tile_box.w + 2 * w, .h = tile_box.h + 2 * w }, w, 0);
        r.outline(tile_box, w, looks.route_color);
    }
    if (solid) {
        // Too small to see: ring the hero.
        const hx = ox + @as(f32, @floatFromInt(@as(i32, g.at.x) - x0)) * ts;
        const hy = oy + @as(f32, @floatFromInt(@as(i32, g.at.y) - y0)) * ts;
        r.outline(.{ .x = hx - 2 * ts, .y = hy - 2 * ts, .w = 5 * ts, .h = 5 * ts }, @max(1, self.u / 2), looks.hero.color);
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const atlas = @import("atlas");
const looks = @import("looks");
const lib = @import("drgnwrrr");
const dw = lib.dw;
const Game = lib.Game;
const Session = lib.Session;
const Mark = lib.session.Mark;
const Renderer = @import("Renderer.zig");
