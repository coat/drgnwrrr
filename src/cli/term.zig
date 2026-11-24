//! Terminal colors for the CLI. The engine prints plain text; `Highlighter`
//! colors whole lines by what they say, and `Style` lets the CLI color its own
//! output. Both do nothing when color is off (not a terminal, NO_COLOR, --no-color).
const std = @import("std");
const Writer = std.Io.Writer;

pub const Style = enum {
    none,
    bold,
    dim,
    red,
    bold_red,
    green,
    yellow,
    bold_yellow,
    blue,
    bold_blue,
    magenta,
    bold_magenta,
    cyan,

    pub fn sgr(self: Style) []const u8 {
        return switch (self) {
            .none => "",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .red => "\x1b[31m",
            .bold_red => "\x1b[1;31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .bold_yellow => "\x1b[1;33m",
            .blue => "\x1b[34m",
            .bold_blue => "\x1b[1;34m",
            .magenta => "\x1b[35m",
            .bold_magenta => "\x1b[1;35m",
            .cyan => "\x1b[36m",
        };
    }
};

pub const reset = "\x1b[0m";

/// Which style a line of game text gets. First match wins.
const rules = [_]struct { has: []const u8, style: Style }{
    .{ .has = "You have died", .style = .bold_red },
    .{ .has = "You fall asleep", .style = .red },
    .{ .has = "You're still asleep", .style = .red },
    .{ .has = "Level up", .style = .bold_magenta },
    .{ .has = "learned a new spell", .style = .bold_magenta },
    .{ .has = "Excellent move", .style = .bold_yellow },
    .{ .has = "draws near", .style = .bold },
    .{ .has = "is defeated", .style = .green },
    .{ .has = ": won in", .style = .green },
    .{ .has = " damage. (HP", .style = .red },
    .{ .has = "Route to", .style = .cyan },
    .{ .has = "You arrive at", .style = .cyan },
    .{ .has = "Warning", .style = .yellow },
    .{ .has = "stop line", .style = .yellow },
    .{ .has = "locked", .style = .yellow },
    .{ .has = "isn't in this prototype", .style = .yellow },
    .{ .has = "wore off", .style = .yellow },
    .{ .has = "has worn off", .style = .yellow },
};

/// A writer that passes text through to `out`, coloring each finished line.
pub const Highlighter = struct {
    out: *Writer,
    color: bool,
    line: [1024]u8 = undefined,
    len: usize = 0,
    writer: Writer,

    pub fn init(out: *Writer, color: bool, buffer: []u8) Highlighter {
        return .{ .out = out, .color = color, .writer = .{
            .vtable = &.{ .drain = drain, .flush = flush },
            .buffer = buffer,
        } };
    }

    fn feed(h: *Highlighter, bytes: []const u8) Writer.Error!void {
        for (bytes) |c| {
            if (c == '\n') {
                try h.emit();
                try h.out.writeByte('\n');
            } else {
                if (h.len == h.line.len) try h.emit();
                h.line[h.len] = c;
                h.len += 1;
            }
        }
    }

    fn emit(h: *Highlighter) Writer.Error!void {
        const text = h.line[0..h.len];
        h.len = 0;
        // Lines the CLI already styled are left alone.
        const style: Style = if (!h.color or std.mem.findScalar(u8, text, 0x1b) != null) .none else for (rules) |r| {
            if (std.mem.find(u8, text, r.has) != null) break r.style;
        } else .none;
        if (style == .none) return h.out.writeAll(text);
        try h.out.print("{s}{s}{s}", .{ style.sgr(), text, reset });
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const h: *Highlighter = @alignCast(@fieldParentPtr("writer", w));
        try h.feed(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try h.feed(d);
            n += d.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| try h.feed(pattern);
        return n + pattern.len * splat;
    }

    /// Writes any unfinished line (a prompt, say) as it is, then flushes.
    fn flush(w: *Writer) Writer.Error!void {
        const h: *Highlighter = @alignCast(@fieldParentPtr("writer", w));
        try h.feed(w.buffer[0..w.end]);
        w.end = 0;
        if (h.len > 0) try h.emit();
        try h.out.flush();
    }
};

/// Writes `text` in `style` if color is on.
pub fn styled(out: *Writer, color: bool, style: Style, text: []const u8) Writer.Error!void {
    if (color and style != .none) return out.print("{s}{s}{s}", .{ style.sgr(), text, reset });
    try out.writeAll(text);
}

test "lines are colored by what they say, and only when color is on" {
    var buf: [256]u8 = undefined;
    var sink: Writer = .fixed(&buf);
    var hb: [16]u8 = undefined;
    var h: Highlighter = .init(&sink, true, &hb);
    try h.writer.print("  A {s} draws near!\n  plain\n", .{"Slime"});
    try h.writer.flush();
    try std.testing.expectEqualStrings("\x1b[1m  A Slime draws near!\x1b[0m\n  plain\n", sink.buffered());

    var buf2: [64]u8 = undefined;
    var sink2: Writer = .fixed(&buf2);
    var h2: Highlighter = .init(&sink2, false, &hb);
    try h2.writer.writeAll("  You have died.\n");
    try h2.writer.flush();
    try std.testing.expectEqualStrings("  You have died.\n", sink2.buffered());
}
