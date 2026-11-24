//! atlas: packs the sprites src/gfx/looks.zig names, and the Anvil font, into
//! one white-on-transparent PNG, and writes where everything landed for each
//! frontend. build.zig runs it, so only the art the game draws ships.
//!
//!   atlas <1bit.png> <prompts.png> <anvil.bin> <out dir>
//!
//! It also draws the icons from looks.icon and looks.favicon: icon.png
//! (64 px) and icon-256.png, favicon-32.png and favicon-16.png (the hero).
//!
//! The out dir gets atlas.png, atlas.zig (the native game: the PNG embedded,
//! sprite cells by looks.Sprite, the font's place) and atlas.js (the web
//! game: sprite cells by name, and the looks of tiles, the hero and NPCs).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const looks = @import("looks");
const Sprite = looks.Sprite;

/// Sprites are 16 px cells, `sprite_cols` to a row, with the font's 8 px
/// glyphs (characters 32-126) under them, `font_cols` to a row.
const cell = 16;
const sprite_cols = 16;
const glyph = 8;
const font_first = 32;
const font_count = 95;
const font_cols = 32;
const width = sprite_cols * cell;
const sprite_rows = (std.enums.values(Sprite).len + sprite_cols - 1) / sprite_cols;
const font_y = sprite_rows * cell;
const height = font_y + (font_count + font_cols - 1) / font_cols * glyph;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) fail("usage: atlas <1bit.png> <prompts.png> <anvil.bin> <out dir>", .{});
    const cwd = Io.Dir.cwd();

    const sheets = std.EnumArray(looks.Sheet, Mask).init(.{
        .onebit = try readPng(io, arena, args[1]),
        .prompts = try readPng(io, arena, args[2]),
    });
    const font = cwd.readFileAlloc(io, args[3], arena, .limited(4096)) catch |err|
        fail("can't read {s} ({t})", .{ args[3], err });
    if (font.len != font_count * glyph) fail("{s}: expected {d} bytes, got {d}", .{ args[3], font_count * glyph, font.len });

    var atlas: Mask = .{ .w = width, .h = height, .ink = try arena.alloc(bool, width * height) };
    @memset(atlas.ink, false);
    for (std.enums.values(Sprite)) |s| {
        const x0, const y0 = spriteAt(s);
        switch (s.source()) {
            .cell => |c| {
                const sheet = sheets.get(c.sheet);
                if ((@as(usize, c.col) + 1) * cell > sheet.w or (@as(usize, c.row) + 1) * cell > sheet.h)
                    fail("{t}: cell {d}, {d} is off the {t} sheet", .{ s, c.col, c.row, c.sheet });
                for (0..cell) |y| for (0..cell) |x| {
                    const sx = if (c.flip) cell - 1 - x else x;
                    atlas.set(x0 + x, y0 + y, sheet.at(@as(usize, c.col) * cell + sx, @as(usize, c.row) * cell + y));
                };
            },
            .bits => |rows| for (rows, 0..) |row, y| for (row, 0..) |ch, x| atlas.set(x0 + x, y0 + y, ch == '#'),
        }
    }
    for (0..font_count) |i| {
        const x0 = i % font_cols * glyph;
        const y0 = font_y + i / font_cols * glyph;
        for (0..glyph) |y| for (0..glyph) |x| atlas.set(x0 + x, y0 + y, font[i * glyph + y] & (@as(u8, 0x80) >> @intCast(x)) != 0);
    }

    var out_dir = cwd.openDir(io, args[4], .{}) catch |err| fail("can't open {s} ({t})", .{ args[4], err });
    defer out_dir.close(io);
    try out_dir.writeFile(io, .{ .sub_path = "atlas.png", .data = try writePng(arena, atlas) });

    const icons = [_]struct { []const u8, Image }{
        .{ "icon.png", try scene(arena, atlas, &looks.icon, 1) },
        .{ "icon-256.png", try scene(arena, atlas, &looks.icon, 4) },
        .{ "favicon-32.png", try scene(arena, atlas, &looks.favicon, 1) },
        .{ "favicon-16.png", try scene(arena, atlas, &[1][1]looks.Look{.{looks.hero}}, 1) },
    };
    for (icons) |i| try out_dir.writeFile(io, .{ .sub_path = i[0], .data = try writeRgbaPng(arena, i[1]) });

    var zig: Io.Writer.Allocating = .init(arena);
    try writeZig(&zig.writer);
    try out_dir.writeFile(io, .{ .sub_path = "atlas.zig", .data = zig.written() });

    var js: Io.Writer.Allocating = .init(arena);
    try writeJs(&js.writer);
    try out_dir.writeFile(io, .{ .sub_path = "atlas.js", .data = js.written() });
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("atlas: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn spriteAt(s: Sprite) struct { usize, usize } {
    const i: usize = @backingInt(s);
    return .{ i % sprite_cols * cell, i / sprite_cols * cell };
}

/// Which pixels are ink.
const Mask = struct {
    w: usize,
    h: usize,
    ink: []bool,

    fn at(m: Mask, x: usize, y: usize) bool {
        return m.ink[y * m.w + x];
    }

    fn set(m: *Mask, x: usize, y: usize, ink: bool) void {
        m.ink[y * m.w + x] = ink;
    }
};

// ---------- PNG ----------

const png_magic = "\x89PNG\r\n\x1a\n";

/// Reads a palette PNG (Kenney's one-bit sheets): a pixel is ink unless its
/// palette entry is transparent.
fn readPng(io: Io, arena: Allocator, path: []const u8) !Mask {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24)) catch |err|
        fail("can't read {s} ({t})", .{ path, err });
    if (!std.mem.startsWith(u8, data, png_magic)) fail("{s} isn't a PNG", .{path});

    var w: usize = 0;
    var h: usize = 0;
    var depth: u8 = 0;
    var palette_len: usize = 0;
    var alpha: []const u8 = &.{};
    var idat: std.ArrayList(u8) = .empty;
    var i: usize = png_magic.len;
    while (i + 12 <= data.len) {
        const len = std.mem.readInt(u32, data[i..][0..4], .big);
        const kind = data[i + 4 ..][0..4];
        if (i + 12 + len > data.len) fail("{s}: truncated", .{path});
        const body = data[i + 8 ..][0..len];
        i += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            w = std.mem.readInt(u32, body[0..4], .big);
            h = std.mem.readInt(u32, body[4..8], .big);
            depth = body[8];
            if (body[9] != 3 or body[12] != 0) fail("{s}: only non-interlaced palette PNGs are supported", .{path});
            if (depth != 1 and depth != 2 and depth != 4 and depth != 8) fail("{s}: bad bit depth {d}", .{ path, depth });
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette_len = len / 3;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            alpha = body;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(arena, body);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (w == 0 or palette_len == 0) fail("{s}: no IHDR or PLTE", .{path});

    var in: Io.Reader = .fixed(idat.items);
    var dec: flate.Decompress = .init(&in, .zlib, &.{});
    const raw = dec.reader.allocRemaining(arena, .unlimited) catch |err| fail("{s}: bad image data ({t})", .{ path, err });
    const stride = (w * depth + 7) / 8;
    if (raw.len != h * (stride + 1)) fail("{s}: image data is {d} bytes, expected {d}", .{ path, raw.len, h * (stride + 1) });

    // Undo each row's filter in place (for bit depths under 8 the filters work on whole bytes).
    const zero = try arena.alloc(u8, stride);
    @memset(zero, 0);
    var prev: []const u8 = zero;
    for (0..h) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        const filter = raw[y * (stride + 1)];
        for (row, 0..) |*b, x| {
            const a: u8 = if (x > 0) row[x - 1] else 0;
            const c: u8 = if (x > 0) prev[x - 1] else 0;
            b.* +%= switch (filter) {
                0 => 0,
                1 => a,
                2 => prev[x],
                3 => @intCast((@as(u16, a) + prev[x]) / 2),
                4 => paeth(a, prev[x], c),
                else => fail("{s}: bad filter {d}", .{ path, filter }),
            };
        }
        prev = row;
    }

    const m: Mask = .{ .w = w, .h = h, .ink = try arena.alloc(bool, w * h) };
    const per_byte = 8 / depth;
    for (0..h) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        for (0..w) |x| {
            const shift: u3 = @intCast(8 - depth - (x % per_byte) * depth);
            const index = (row[x / per_byte] >> shift) & ((@as(u16, 1) << @intCast(depth)) - 1);
            m.ink[y * w + x] = if (index < alpha.len) alpha[index] != 0 else true;
        }
    }
    return m;
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

/// An 8-bit greyscale + alpha PNG, white where `m` has ink: the simplest form
/// every loader (browsers, SDL_LoadPNG) reads, and it compresses to nearly
/// nothing.
fn writePng(arena: Allocator, m: Mask) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..m.h) |y| {
        try raw.append(arena, 0); // no filter
        for (0..m.w) |x| try raw.appendSlice(arena, if (m.at(x, y)) &.{ 0xff, 0xff } else &.{ 0, 0 });
    }
    return pngFile(arena, m.w, m.h, 4, raw.items);
}

/// A PNG of 8-bit `color_type` (4 grey + alpha, 6 RGBA) from filtered rows.
fn pngFile(arena: Allocator, w_px: usize, h_px: usize, color_type: u8, raw: []const u8) ![]u8 {
    var z: Io.Writer.Allocating = try .initCapacity(arena, 4096);
    const window = try arena.alloc(u8, flate.max_window_len);
    const c = try arena.create(flate.Compress);
    c.* = try .init(&z.writer, window, .zlib, .best);
    try c.writer.writeAll(raw);
    try c.finish();

    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(png_magic);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(w_px), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(h_px), .big);
    ihdr[8..].* = .{ 8, color_type, 0, 0, 0 }; // 8-bit, deflate, no filter, no interlace
    try chunk(w, "IHDR", &ihdr);
    try chunk(w, "IDAT", z.written());
    try chunk(w, "IEND", "");
    return out.written();
}

/// RGBA pixels.
const Image = struct {
    w: usize,
    h: usize,
    px: []u8,
};

/// Rows of sprites (an array of arrays of looks.Look), each in its colour on
/// black, `scale` times their size.
fn scene(arena: Allocator, atlas: Mask, rows: anytype, scale: usize) !Image {
    const size = cell * scale;
    const img: Image = .{ .w = rows[0].len * size, .h = rows.len * size, .px = try arena.alloc(u8, rows[0].len * size * rows.len * size * 4) };
    for (0..img.h) |y| for (0..img.w) |x| {
        const look = rows[y / size][x / size];
        const x0, const y0 = spriteAt(look.sprite);
        const ink = atlas.at(x0 + x % size / scale, y0 + y % size / scale);
        const rgb: u24 = if (ink) look.color else 0;
        img.px[(y * img.w + x) * 4 ..][0..4].* = .{ @truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb), 0xff };
    };
    return img;
}

/// An 8-bit RGBA PNG.
fn writeRgbaPng(arena: Allocator, img: Image) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..img.h) |y| {
        try raw.append(arena, 0); // no filter
        try raw.appendSlice(arena, img.px[y * img.w * 4 ..][0 .. img.w * 4]);
    }
    return pngFile(arena, img.w, img.h, 6, raw.items);
}

fn chunk(w: *Io.Writer, kind: *const [4]u8, body: []const u8) !void {
    try w.writeInt(u32, @intCast(body.len), .big);
    try w.writeAll(kind);
    try w.writeAll(body);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(body);
    try w.writeInt(u32, crc.final(), .big);
}

// ---------- the frontends' tables ----------

fn writeZig(w: *Io.Writer) !void {
    try w.print(
        \\//! The sprite atlas, generated by tools/atlas from src/gfx/looks.zig.
        \\//! Don't edit: build.zig regenerates it.
        \\
        \\/// White on transparent: tint it.
        \\pub const png = @embedFile("atlas.png");
        \\/// The window's icon (looks.icon), 64 px.
        \\pub const icon_png = @embedFile("icon.png");
        \\pub const width = {d};
        \\pub const height = {d};
        \\
        \\/// Each looks.Sprite's top-left corner, by @intFromEnum.
        \\pub const sprites = [_][2]u16{{
        \\
    , .{ width, height });
    for (std.enums.values(Sprite)) |s| {
        const x, const y = spriteAt(s);
        try w.print("    .{{ {d}, {d} }}, // {t}\n", .{ x, y, s });
    }
    try w.print(
        \\}};
        \\pub const sprite_size = {d};
        \\
        \\/// The Anvil font: characters `first` to `first + count - 1`, `cols` to a row from (x, y).
        \\pub const font = .{{ .x = 0, .y = {d}, .size = {d}, .cols = {d}, .first = {d}, .count = {d} }};
        \\
    , .{ cell, font_y, glyph, font_cols, font_first, font_count });
}

fn writeJs(w: *Io.Writer) !void {
    try w.print(
        \\// The sprite atlas, generated by tools/atlas from src/gfx/looks.zig.
        \\// Don't edit: build.zig regenerates it. assets/atlas.png is white on
        \\// transparent: tint it.
        \\
        \\export const ATLAS = {{ src: 'assets/atlas.png', width: {d}, height: {d}, cell: {d} }};
        \\
        \\/** Each sprite's top-left corner in the atlas. */
        \\export const SPRITES = {{
        \\
    , .{ width, height, cell });
    for (std.enums.values(Sprite)) |s| {
        const x, const y = spriteAt(s);
        try w.print("  {t}: [{d}, {d}],\n", .{ s, x, y });
    }
    try w.writeAll(
        \\};
        \\
        \\/** dw.Tile value -> { sprite, color, name }. Missing values draw nothing. */
        \\export const TILES = {
        \\
    );
    for (0..256) |t| {
        const look = looks.tile(@fromBackingInt(@as(u8, @intCast(t)))) orelse continue;
        try w.print("  0x{x:0>2}: {{ sprite: '{t}', color: '#{x:0>6}', name: '{s}' }},\n", .{ t, look.sprite, look.color, look.name });
    }
    try w.writeAll("};\n\nexport const HERO = ");
    try writeLook(w, looks.hero);
    try w.writeAll(";\n/** By the NPC's sprite bits (dw.Npc.sprite). */\nexport const NPCS = [\n");
    for (looks.npcs) |look| {
        try w.writeAll("  ");
        try writeLook(w, look);
        try w.writeAll(",\n");
    }
    try w.print("];\nexport const ROUTE_COLOR = '#{x:0>6}';\n", .{looks.route_color});
    try w.print(
        \\/** The Anvil font: characters `first` to `first + count - 1`, `cols` to a row from (x, y). */
        \\export const FONT = {{ x: 0, y: {d}, size: {d}, cols: {d}, first: {d}, count: {d} }};
        \\/** The title screen (see looks.zig). */
        \\export const TITLE = {{ tiles: {d}, dim: {d}, color: '#{x:0>6}' }};
        \\
    , .{ font_y, glyph, font_cols, font_first, font_count, looks.title_tiles, looks.title_dim, looks.title_color });
}

fn writeLook(w: *Io.Writer, look: looks.Look) !void {
    try w.print("{{ sprite: '{t}', color: '#{x:0>6}' }}", .{ look.sprite, look.color });
}
