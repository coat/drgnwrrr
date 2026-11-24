//! The panel's widgets on Clay: buttons in grids that fill their row, the
//! web game's segmented pickers and steppers, text and key/value rows.
//!
//! Immediate mode, with a twist: a pressed button doesn't act while the frame
//! is being laid out (its strings are still in use). It records an Action,
//! which App runs after the layout, then lays the frame out again.
//!
//! For controllers, buttons can be focused: each one registers itself, App
//! moves the focus between their boxes, and pressing the focused one comes
//! back here as `activate`, the same way a click does.
const std = @import("std");
const c = @import("c");
const clay = @import("clay.zig");
const lib = @import("drgnwrrr");
const travel = lib.travel;
const looks = @import("looks");

/// The web game's colours (web/style.css).
pub const ink = 0xe4e7ea;
pub const dim = 0x858c93;
pub const rule = 0x24282c;
pub const echo = 0x9db3c6;
pub const accent = 0xc5cdd4;
pub const accent_hover = 0xe2e7eb;
pub const on_accent = 0x0b0d0f;
pub const field = 0x0d0f11;
pub const field_border = 0x30353a;
pub const hover_bg = 0x1a1d20;
pub const disabled = 0x4a5056;
pub const hp = 0x58d854;
pub const mp = 0x3cbcfc;
pub const gold = 0xf8b800;
pub const bad = 0xf83800;

/// A command line, kept in the Action itself.
pub const Line = struct {
    buf: [96]u8 = undefined,
    len: u8 = 0,

    pub fn init(comptime fmt: []const u8, args: anytype) Line {
        var l: Line = .{};
        const s: []u8 = std.fmt.bufPrint(&l.buf, fmt, args) catch l.buf[0..0];
        l.len = @intCast(s.len);
        return l;
    }

    pub fn slice(self: *const Line) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Menu = enum { go, grind, shop, cast, items, more, status, checklist, danger, options, about };

pub const Toggle = enum { grind_auto, assist, show_log, show_cmd, show_where };

pub const Action = union(enum) {
    /// Run a command line, echoed in the log.
    run: Line,
    /// Run one without the echo (the hero's name).
    quiet: Line,
    menu: Menu,
    back,
    risk: travel.Risk,
    /// Drop the planned route and plan the last `go` again with this risk.
    replan: travel.Risk,
    stop: struct { grind: bool, by: i8 },
    fights: u8,
    toggle: Toggle,
    new_game,
    continue_game,
    zoom_in,
    zoom_out,
    overview,
    recentre,
    quit,
    /// The on-screen keyboard: add a letter to the name, or take one off.
    letter: u8,
    erase,

    pub fn cmd(comptime fmt: []const u8, args: anytype) Action {
        return .{ .run = .init(fmt, args) };
    }
};

/// What a custom element draws (Clay's customData points at one).
pub const Custom = union(enum) {
    map,
    sprite: looks.Look,
};

pub const Style = enum {
    /// Filled: the one thing to do.
    primary,
    outline,
    /// Borderless, over the map.
    ghost,
};

pub const ButtonOptions = struct {
    style: Style = .outline,
    disabled: bool = false,
    /// A second, quieter line (a price).
    sub: ?[]const u8 = null,
    /// Text starts at the left instead of the middle (checkboxes).
    left: bool = false,
    /// What identifies the button, if not its label (one whose label
    /// changes, like Herb - 3, keeps its focus by a key that doesn't).
    key: ?[]const u8 = null,
};

/// The key of a menu's Back button, which the focus starts on only if there's nothing else.
pub const back_key = "back";

/// A button the controller can move to.
pub const Focusable = struct { id: u32, primary: bool };

/// A press and release at the same place.
pub const Click = struct { down: [2]f32, up: [2]f32 };

pub const Ui = struct {
    /// Pixels a font pixel: everything is sized in these.
    u: u16,
    /// The panel's inner width, for laying out grids.
    width: f32,
    arena: std.mem.Allocator,
    click: ?Click = null,
    action: ?Action = null,
    /// The focused button's id, and whether to draw it (while a controller's in use).
    focus: ?u32 = null,
    show_focus: bool = false,
    /// Press this button (the controller pressed the focused one).
    activate: ?u32 = null,
    /// This frame's buttons, in order, for the focus to move between.
    focusables: std.ArrayList(Focusable) = .empty,
    /// How many buttons have had each key so far: ids are the key and its count.
    keys: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn px(self: *const Ui, n: f32) f32 {
        return n * @as(f32, @floatFromInt(self.u));
    }

    pub fn upx(self: *const Ui, n: u16) u16 {
        return n * self.u;
    }

    pub fn fmt(self: *Ui, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena, f, args) catch "";
    }

    pub fn textConfig(self: *const Ui, color: u24) clay.TextConfig {
        return std.mem.zeroInit(clay.TextConfig, .{
            .textColor = clay.rgb(color),
            .fontSize = self.u,
            .lineHeight = 10 * self.u,
            .wrapMode = clay.wrap_words,
        });
    }

    pub fn text(self: *Ui, s: []const u8, color: u24) void {
        clay.text(self.breakLong(s), self.textConfig(color));
    }

    /// Clay wraps only at spaces, so a word wider than the panel (a file
    /// path) would widen the whole layout. Such words get line breaks.
    pub fn breakLong(self: *Ui, s: []const u8) []const u8 {
        return self.breakAt(s, self.width);
    }

    /// Line breaks in any word wider than `width` pixels.
    pub fn breakAt(self: *Ui, s: []const u8, width: f32) []const u8 {
        const max: usize = @intFromFloat(@max(1, @floor(width / self.px(8))));
        var words = std.mem.tokenizeAny(u8, s, " \n");
        while (words.next()) |w| {
            if (w.len > max) break;
        } else return s;
        var out: std.ArrayList(u8) = .empty;
        var run: usize = 0;
        for (s) |ch| {
            if (ch == ' ' or ch == '\n') {
                run = 0;
            } else if (run == max) {
                out.append(self.arena, '\n') catch return s;
                run = 0;
            }
            if (ch != ' ' and ch != '\n') run += 1;
            out.append(self.arena, ch) catch return s;
        }
        return out.items;
    }

    /// Text in its own full-width block, wrapping.
    pub fn para(self: *Ui, s: []const u8, color: u24) void {
        clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .padding = .{ .top = self.upx(1), .bottom = self.upx(2) } } });
        self.text(s, color);
        clay.close();
    }

    pub fn hint(self: *Ui, s: []const u8) void {
        self.para(s, dim);
    }

    /// A small heading over a group.
    pub fn heading(self: *Ui, s: []const u8) void {
        clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .padding = .{ .top = self.upx(5), .bottom = self.upx(2) } } });
        self.text(s, dim);
        clay.close();
    }

    /// A gap of `n` font pixels.
    pub fn space(self: *Ui, n: f32) void {
        clay.leaf(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fixed(self.px(n))) } });
    }

    pub fn buttonHeight(self: *const Ui) f32 {
        return self.px(24);
    }

    /// A button's id: its key, told apart from earlier buttons with the same key.
    fn buttonId(self: *Ui, key: []const u8) clay.ElementId {
        const n = self.keys.getOrPut(self.arena, key) catch return c.Clay__HashString(clay.str(key), 0, 0);
        if (!n.found_existing) n.value_ptr.* = 0;
        defer n.value_ptr.* += 1;
        return c.Clay__HashString(clay.str(key), n.value_ptr.*, 0);
    }

    fn focused(self: *const Ui, id: clay.ElementId) bool {
        return self.show_focus and self.focus != null and self.focus.? == id.id;
    }

    /// Pressed this frame: by the controller, or by a click that both started
    /// and ended in `id`'s box (as last drawn).
    fn pressed(self: *const Ui, id: clay.ElementId) bool {
        if (self.activate != null and self.activate.? == id.id) return true;
        const k = self.click orelse return false;
        if (!c.Clay_PointerOver(id)) return false;
        const data = c.Clay_GetElementData(id);
        if (!data.found) return false;
        const b = data.boundingBox;
        return k.down[0] >= b.x and k.down[1] >= b.y and k.down[0] < b.x + b.width and k.down[1] < b.y + b.height;
    }

    /// A button that grows to fill its row; pressing it records `action`.
    pub fn button(self: *Ui, label: []const u8, action: Action, opts: ButtonOptions) void {
        self.buttonSized(label, action, opts, clay.sizing(clay.grow(), fitMin(self.buttonHeight())));
    }

    pub fn buttonSized(self: *Ui, label: []const u8, action: Action, opts: ButtonOptions, sizing: c.Clay_Sizing) void {
        const id = self.buttonId(opts.key orelse label);
        if (!opts.disabled) self.focusables.append(self.arena, .{ .id = id.id, .primary = opts.style == .primary }) catch {};
        const focus = !opts.disabled and self.focused(id);
        const over = focus or (!opts.disabled and !self.show_focus and c.Clay_PointerOver(id));
        if (!opts.disabled and self.pressed(id)) self.action = action;
        const bg: ?u24, const fg: u24, const border: ?u24 = if (opts.disabled) switch (opts.style) {
            .primary => .{ field_border, disabled, null },
            .outline => .{ null, disabled, field_border },
            .ghost => .{ null, disabled, null },
        } else switch (opts.style) {
            .primary => .{ if (over) accent_hover else accent, on_accent, null },
            .outline => .{ if (over) hover_bg else null, if (over) accent_hover else accent, if (over) accent_hover else accent },
            .ghost => .{ if (over) hover_bg else null, ink, null },
        };
        clay.open(.{
            .id = id,
            .layout = .{
                .sizing = sizing,
                .padding = clay.padding(self.upx(4), self.upx(3)),
                .childGap = self.upx(1),
                .childAlignment = .{ .x = if (opts.left) clay.align_left else clay.align_center, .y = clay.align_middle },
                .layoutDirection = clay.top_to_bottom,
            },
            .backgroundColor = if (bg) |col| clay.rgb(col) else clay.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            // The focus: a heavier frame in the text's colour.
            .border = if (focus) clay.border(if (opts.style == .primary) on_accent else accent_hover, @max(2, self.u)) else clay.border(border, 1),
        });
        var config = self.textConfig(fg);
        if (!opts.left) config.textAlignment = clay.text_center;
        // In a fixed width, break a word too long for it.
        const inner = if (sizing.width.type == c.CLAY__SIZING_TYPE_FIXED) sizing.width.size.minMax.min - self.px(8) else self.width;
        clay.text(self.breakAt(label, inner), config);
        if (opts.sub) |s| {
            config.textColor = clay.rgb(if (opts.disabled) disabled else dim);
            clay.text(s, config);
        }
        clay.close();
    }

    /// A square button showing a sprite (the map's buttons).
    pub fn spriteButton(self: *Ui, look: *const Custom, action: Action, size: f32) void {
        const id = self.buttonId(@tagName(action));
        self.focusables.append(self.arena, .{ .id = id.id, .primary = false }) catch {};
        const focus = self.focused(id);
        const over = focus or (!self.show_focus and c.Clay_PointerOver(id));
        if (self.pressed(id)) self.action = action;
        clay.open(.{
            .id = id,
            .layout = .{ .sizing = clay.sizing(clay.fixed(size), clay.fixed(size)), .padding = clay.padding(self.upx(2), self.upx(2)) },
            .backgroundColor = if (over) clay.Color{ .r = 255, .g = 255, .b = 255, .a = 30 } else clay.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .border = if (focus) clay.border(accent_hover, @max(2, self.u)) else clay.border(null, 0),
        });
        clay.leaf(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.grow()) }, .custom = .{ .customData = @constCast(look) } });
        clay.close();
    }

    /// Starts a grid of buttons at least `min_chars` characters wide, as many
    /// to a row as fit. `fill` stretches the rows into the room left.
    pub fn grid(self: *Ui, min_chars: f32, fill: bool) Grid {
        const gap = self.px(2);
        const min_w = self.px(8 * min_chars + 8);
        return self.gridCols(@intFromFloat(@max(1, @floor((self.width + gap) / (min_w + gap)))), fill);
    }

    /// A grid of exactly `cols` columns.
    pub fn gridCols(self: *Ui, cols: u32, fill: bool) Grid {
        const gap = self.px(2);
        clay.open(.{ .layout = .{
            .sizing = clay.sizing(clay.grow(), if (fill) clay.grow() else clay.fit()),
            .childGap = self.upx(2),
            .layoutDirection = clay.top_to_bottom,
            .padding = .{ .bottom = self.upx(2) },
        } });
        const col_w = @floor((self.width - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols)));
        return .{ .ui = self, .cols = cols, .col_w = col_w, .fill = fill };
    }

    /// Three buttons side by side, the chosen one filled.
    pub fn segmented(self: *Ui, comptime T: type, chosen: T, action: fn (T) Action) void {
        clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .childGap = self.upx(2), .padding = .{ .bottom = self.upx(2) } } });
        inline for (@typeInfo(T).@"enum".field_names) |name| {
            const v = @field(T, name);
            self.button(name, action(v), .{ .style = if (v == chosen) .primary else .outline });
        }
        clay.close();
    }

    /// − and + around a label.
    pub fn stepper(self: *Ui, label: []const u8, down: ?Action, up: ?Action) void {
        clay.open(.{ .layout = .{
            .sizing = clay.sizing(clay.grow(), clay.fit()),
            .childGap = self.upx(2),
            .childAlignment = .{ .y = clay.align_middle },
            .padding = .{ .bottom = self.upx(2) },
        } });
        const side = clay.sizing(clay.fixed(self.buttonHeight()), clay.fixed(self.buttonHeight()));
        self.buttonSized("-", down orelse .back, .{ .disabled = down == null }, side);
        clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .childAlignment = .{ .x = clay.align_center } } });
        var config = self.textConfig(ink);
        config.textAlignment = clay.text_center;
        clay.text(label, config);
        clay.close();
        self.buttonSized("+", up orelse .back, .{ .disabled = up == null }, side);
        clay.close();
    }

    /// A key in dim text, `key_chars` wide, then its value.
    pub fn row(self: *Ui, key: []const u8, key_chars: f32, value: []const u8, color: u24) void {
        clay.open(.{
            .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .childGap = self.upx(4), .padding = .{ .top = self.upx(1), .bottom = self.upx(1) } },
            .border = .{ .color = clay.rgb(rule), .width = .{ .bottom = 1 } },
        });
        clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.fixed(self.px(8 * key_chars)), clay.fit()) } });
        self.text(key, dim);
        clay.close();
        clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()) } });
        self.text(value, color);
        clay.close();
        clay.close();
    }
};

pub fn growMin(min: f32) c.Clay_SizingAxis {
    return .{ .type = c.CLAY__SIZING_TYPE_GROW, .size = .{ .minMax = .{ .min = min, .max = 0 } } };
}

pub fn fitMin(min: f32) c.Clay_SizingAxis {
    return .{ .type = c.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = min, .max = 0 } } };
}

pub const Grid = struct {
    ui: *Ui,
    cols: u32,
    /// Every column's width, so labels wrap rather than widen their column.
    col_w: f32,
    fill: bool,
    /// Buttons in the open row; 0 when no row is open.
    in_row: u32 = 0,

    fn openRow(self: *Grid) void {
        clay.open(.{ .layout = .{
            .sizing = clay.sizing(clay.grow(), if (self.fill) growMin(self.ui.buttonHeight()) else clay.fit()),
            .childGap = self.ui.upx(2),
        } });
    }

    fn closeRow(self: *Grid) void {
        if (self.in_row == 0) return;
        // Keep the last row's buttons as wide as the rest.
        while (self.in_row < self.cols) : (self.in_row += 1)
            clay.leaf(.{ .layout = .{ .sizing = clay.sizing(clay.fixed(self.col_w), clay.fit()) } });
        clay.close();
        self.in_row = 0;
    }

    pub fn button(self: *Grid, label: []const u8, action: Action, opts: ButtonOptions) void {
        if (self.in_row == 0) self.openRow();
        self.ui.buttonSized(label, action, opts, clay.sizing(clay.fixed(self.col_w), growMin(self.ui.buttonHeight())));
        self.in_row += 1;
        if (self.in_row == self.cols) {
            clay.close();
            self.in_row = 0;
        }
    }

    /// Starts the next button on a fresh row (the spells in a battle).
    pub fn newRow(self: *Grid) void {
        self.closeRow();
    }

    /// A button with a row to itself.
    pub fn wide(self: *Grid, label: []const u8, action: Action, opts: ButtonOptions) void {
        self.closeRow();
        self.openRow();
        self.ui.button(label, action, opts);
        clay.close();
    }

    pub fn end(self: *Grid) void {
        self.closeRow();
        clay.close();
    }
};
