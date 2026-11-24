//! The player's choices, kept between runs in prefs.txt beside the save:
//! the web game's prefs (web/app.js), with the panel's size as a fraction of
//! the window so it carries across screens.
//!
//! One `name=value` line a field. Fractions are written in thousandths so
//! neither side needs std's float parsing and formatting (std.json, used
//! before, cost the binary some 56 KB).
const Prefs = @This();

/// How routes trade safety for speed.
risk: travel.Risk = .balanced,
/// Walks stop under this % of max HP.
stop: u8 = 50,
/// Grind: how many fights, by auto-battle or not, stopping under this % HP.
fights: u8 = 10,
grind_auto: bool = false,
grind_stop: u8 = 40,
/// The remakes' conveniences (Session.assist).
assist: bool = true,
show_log: bool = false,
show_cmd: bool = false,
/// A second status line: where you stand, the zone, the chance of a fight a step.
show_where: bool = false,
/// The log's share of the room under the status line.
log_size: f32 = 0.2,
/// The panel's width beside the map and height under it, as fractions of
/// the window; 0 for the default.
panel_w: f32 = 0,
panel_h: f32 = 0,

/// The prefs in the file at `path`; defaults for whatever it lacks or
/// garbles, and for all of them if it can't be read.
pub fn load(path: [:0]const u8) Prefs {
    var prefs: Prefs = .{};
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return prefs;
    defer c.SDL_free(data);
    var lines = std.mem.tokenizeAny(u8, @as([*]const u8, @ptrCast(data))[0..size], "\r\n");
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        inline for (comptime std.meta.fieldNames(Prefs)) |field| {
            if (std.mem.eql(u8, name, field)) {
                if (parse(@FieldType(Prefs, field), value)) |v| @field(prefs, field) = v;
            }
        }
    }
    return prefs;
}

fn parse(comptime T: type, value: []const u8) ?T {
    return switch (T) {
        bool => if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else null,
        u8 => std.fmt.parseInt(u8, value, 10) catch null,
        f32 => @as(f32, @floatFromInt(std.fmt.parseInt(u16, value, 10) catch return null)) / 1000,
        else => std.meta.stringToEnum(T, value),
    };
}

pub fn save(self: Prefs, path: [:0]const u8) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    inline for (comptime std.meta.fieldNames(Prefs)) |field| {
        const v = @field(self, field);
        (switch (@FieldType(Prefs, field)) {
            bool => w.print(field ++ "={s}\n", .{if (v) "true" else "false"}),
            u8 => w.print(field ++ "={d}\n", .{v}),
            f32 => w.print(field ++ "={d}\n", .{@as(u16, @intFromFloat(@round(std.math.clamp(v, 0, 1) * 1000)))}),
            else => w.print(field ++ "={t}\n", .{v}),
        }) catch unreachable; // buf has room for every field
    }
    const text = w.buffered();
    if (!c.SDL_SaveFile(path.ptr, text.ptr, text.len)) std.log.warn("couldn't write {s}: {s}", .{ path, c.SDL_GetError() });
}

const std = @import("std");
const c = @import("c");
const travel = @import("drgnwrrr").travel;
