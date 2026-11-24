//! Draws with the atlas (tools/atlas): Clay's render commands, the Anvil
//! font's glyphs and tinted sprites, all on SDL's 2D renderer.
const Renderer = @This();

sdl: *c.SDL_Renderer,
texture: *c.SDL_Texture,

pub fn init(sdl: *c.SDL_Renderer) !Renderer {
    const io = try errify(c.SDL_IOFromConstMem(atlas.png, atlas.png.len));
    const surface = try errify(c.SDL_LoadPNG_IO(io, true));
    defer c.SDL_DestroySurface(surface);
    const tex = try errify(c.SDL_CreateTextureFromSurface(sdl, surface));
    try errify(c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_NEAREST));
    try errify(c.SDL_SetRenderDrawBlendMode(sdl, c.SDL_BLENDMODE_BLEND));
    return .{ .sdl = sdl, .texture = tex };
}

pub fn deinit(self: *Renderer) void {
    c.SDL_DestroyTexture(self.texture);
}

/// Text measures in whole glyphs: `scale` times the font's 8 px a character.
pub fn textWidth(len: usize, scale: f32) f32 {
    return @as(f32, @floatFromInt(len)) * atlas.font.size * scale;
}

pub fn fill(self: Renderer, r: c.SDL_FRect, color: u24) void {
    self.fillAlpha(r, color, 255);
}

pub fn fillAlpha(self: Renderer, r: c.SDL_FRect, color: u24, alpha: u8) void {
    _ = c.SDL_SetRenderDrawColor(self.sdl, @truncate(color >> 16), @truncate(color >> 8), @truncate(color), alpha);
    _ = c.SDL_RenderFillRect(self.sdl, &r);
}

/// A `w` pixel frame just inside `r`.
pub fn outline(self: Renderer, r: c.SDL_FRect, w: f32, color: u24) void {
    self.fill(.{ .x = r.x, .y = r.y, .w = r.w, .h = w }, color);
    self.fill(.{ .x = r.x, .y = r.y + r.h - w, .w = r.w, .h = w }, color);
    self.fill(.{ .x = r.x, .y = r.y, .w = w, .h = r.h }, color);
    self.fill(.{ .x = r.x + r.w - w, .y = r.y, .w = w, .h = r.h }, color);
}

fn tint(self: Renderer, color: u24) void {
    _ = c.SDL_SetTextureColorMod(self.texture, @truncate(color >> 16), @truncate(color >> 8), @truncate(color));
}

/// `r` on whole pixels. Drawn from a fractional place, the nearest-pixel
/// scaling can sample the edge of the atlas cell next door.
fn snap(r: c.SDL_FRect) c.SDL_FRect {
    const x = @round(r.x);
    const y = @round(r.y);
    return .{ .x = x, .y = y, .w = @round(r.x + r.w) - x, .h = @round(r.y + r.h) - y };
}

pub fn sprite(self: Renderer, s: looks.Sprite, color: u24, to: c.SDL_FRect) void {
    const dst = snap(to);
    const at = atlas.sprites[@backingInt(s)];
    const size: f32 = atlas.sprite_size;
    const src: c.SDL_FRect = .{ .x = @floatFromInt(at[0]), .y = @floatFromInt(at[1]), .w = size, .h = size };
    self.tint(color);
    _ = c.SDL_RenderTexture(self.sdl, self.texture, &src, &dst);
}

/// One line of text from (x, y), `scale` times the font's size. Characters
/// outside printable ASCII draw as '?'.
pub fn text(self: Renderer, s: []const u8, x: f32, y: f32, scale: f32, color: u24) void {
    const f = atlas.font;
    const size: f32 = f.size;
    self.tint(color);
    for (s, 0..) |ch, i| {
        if (ch == ' ') continue;
        const k: usize = if (ch >= f.first and ch < f.first + f.count) ch - f.first else '?' - f.first;
        const src: c.SDL_FRect = .{
            .x = @floatFromInt(f.x + k % f.cols * f.size),
            .y = @floatFromInt(f.y + k / f.cols * f.size),
            .w = size,
            .h = size,
        };
        const dst = snap(.{ .x = x + @as(f32, @floatFromInt(i)) * size * scale, .y = y, .w = size * scale, .h = size * scale });
        _ = c.SDL_RenderTexture(self.sdl, self.texture, &src, &dst);
    }
}

fn hex(col: clay.Color) u24 {
    const r: u24 = @intFromFloat(col.r);
    const g: u24 = @intFromFloat(col.g);
    const b: u24 = @intFromFloat(col.b);
    return r << 16 | g << 8 | b;
}

/// Draws a laid-out frame. `custom` draws the custom elements (the map) in
/// their boxes.
pub fn commands(self: Renderer, cmds: c.Clay_RenderCommandArray, ctx: anytype, custom: fn (@TypeOf(ctx), c.SDL_FRect, ?*anyopaque) void) void {
    for (0..@intCast(cmds.length)) |i| {
        const cmd = &cmds.internalArray[i];
        const bb = cmd.boundingBox;
        const box: c.SDL_FRect = .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };
        switch (cmd.commandType) {
            c.CLAY_RENDER_COMMAND_TYPE_RECTANGLE => {
                const col = cmd.renderData.rectangle.backgroundColor;
                self.fillAlpha(box, hex(col), @intFromFloat(col.a));
            },
            c.CLAY_RENDER_COMMAND_TYPE_BORDER => {
                const b = cmd.renderData.border;
                const col = hex(b.color);
                const w = b.width;
                if (w.top > 0) self.fill(.{ .x = box.x, .y = box.y, .w = box.w, .h = @floatFromInt(w.top) }, col);
                if (w.bottom > 0) self.fill(.{ .x = box.x, .y = box.y + box.h - @as(f32, @floatFromInt(w.bottom)), .w = box.w, .h = @floatFromInt(w.bottom) }, col);
                if (w.left > 0) self.fill(.{ .x = box.x, .y = box.y, .w = @floatFromInt(w.left), .h = box.h }, col);
                if (w.right > 0) self.fill(.{ .x = box.x + box.w - @as(f32, @floatFromInt(w.right)), .y = box.y, .w = @floatFromInt(w.right), .h = box.h }, col);
            },
            c.CLAY_RENDER_COMMAND_TYPE_TEXT => {
                const t = cmd.renderData.text;
                const s = t.stringContents.chars[0..@intCast(t.stringContents.length)];
                const scale: f32 = @floatFromInt(t.fontSize);
                // Centred in its line.
                const y = box.y + @round((box.h - atlas.font.size * scale) / 2);
                self.text(s, box.x, y, scale, hex(t.textColor));
            },
            c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_START => {
                const r: c.SDL_Rect = .{ .x = @intFromFloat(box.x), .y = @intFromFloat(box.y), .w = @intFromFloat(box.w), .h = @intFromFloat(box.h) };
                _ = c.SDL_SetRenderClipRect(self.sdl, &r);
            },
            c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_END => _ = c.SDL_SetRenderClipRect(self.sdl, null),
            c.CLAY_RENDER_COMMAND_TYPE_CUSTOM => custom(ctx, box, cmd.renderData.custom.customData),
            else => {},
        }
    }
}

const std = @import("std");
const c = @import("c");
const atlas = @import("atlas");
const looks = @import("looks");
const clay = @import("clay.zig");
const errify = @import("main.zig").errify;
