//! The native game, laid out like the web game: the map beside (or above) a
//! panel with the status line, the buttons and the menus that open in their
//! place, and optionally the log and a command line. Every button sends the
//! engine's Session a command line, so the log reads like the CLI's.
const App = @This();

gpa: Allocator,
window: *c.SDL_Window,
r: Renderer,
session: Session,
prefs: Prefs,
map: Map,
/// The log text from the last submit.
out: Writer.Allocating,
log: std.ArrayList(Line) = .empty,
/// The command line (or the hero's name) being typed.
input: std.ArrayList(u8) = .empty,
history: std.ArrayList([]u8) = .empty,
/// Where Up/Down are in `history`; history.items.len is the line being typed.
history_at: usize = 0,
/// Whether SDL is sending text input (it's on while there's a field to type in).
typing: bool = false,
/// Typing means an on-screen keyboard (as on a phone): it's only shown once
/// a field is tapped, and the name has the letter grid instead.
screen_keyboard: bool = false,
/// A field was tapped and the on-screen keyboard is wanted.
keyboard_up: bool = false,
/// A pinch's zoom, waiting to add up to a step of the map's.
pinch: f32 = 1,
/// When the player last saw a fresh screen: the time until the next command is idle time.
shown_at: u64 = 0,
/// Where drgnwrrr.sav and prefs.txt live.
sav_path: [:0]u8,
prefs_path: [:0]u8,
clay_memory: []u8,
/// The frame's strings (button labels and the like).
frame: std.heap.ArenaAllocator,
/// The menu shown in place of the commands, or null.
menu: ?ui.Menu = null,
/// The Danger menu's table, worked out when it opens.
danger: ?travel.Danger = null,
/// The map tile last tapped: tapping it again while its route waits walks it.
tapped: ?dw.Warp = null,
/// The last `go`, to plan again with another risk.
last_go: ?ui.Line = null,
/// The pointer, in pixels.
mouse: [2]f32 = .{ 0, 0 },
/// A press in progress.
press: ?Press = null,
/// A click for the next layout's buttons.
click: ?ui.Click = null,
/// The map tile under the pointer, for the HUD.
hover: ?Map.Spot = null,
/// Pixels the wheel scrolled the panel since the last frame.
wheel: f32 = 0,
/// Scroll the log to its end, and the controls to their top, on the next frame.
log_to_end: bool = true,
controls_to_top: bool = false,
last_frame: u64 = 0,
err_buf: [512]u8 = undefined,
/// --screenshot: save a frame here, then quit.
screenshot: ?[:0]u8 = null,
/// --click and --pad: input to replay, a frame apart, before the screenshot.
script: []const Step = &.{},
/// What was used last: the focus is drawn only for a controller.
input_mode: enum { pointer, pad } = .pointer,
gamepad: ?*c.SDL_Gamepad = null,
/// The focused button (see ui.Ui.focus), and the buttons the last layout drew.
focus: ?u32 = null,
focusables: std.ArrayList(ui.Focusable) = .empty,
/// Where the focus was when each open menu opened, to go back to.
focus_stack: std.ArrayList(u32) = .empty,
/// Press the focused button on the next layout.
activate: ?u32 = null,
/// Scroll the controls so the focused button shows.
focus_into_view: bool = false,
/// The controller moves a cursor on the map instead of the focus.
map_mode: bool = false,
/// The name field still holds the name it started with.
name_untouched: bool = false,
/// A direction held on the d-pad or the left stick, and when it next repeats.
held: ?Dir = null,
next_repeat: u64 = 0,
/// The left stick's direction, so it only fires as it changes.
stick: ?Dir = null,
/// The right stick and the triggers scroll the controls: pixels a second.
scroll_speed: f32 = 0,
/// --scale, or null to go by the window.
scale_override: ?u16 = null,
/// A handheld's console or a phone: held closer, so text is drawn bigger.
handheld: bool = false,
/// Quit was pressed.
quit: bool = false,
/// Pixels to scroll the controls by on the next frame.
pad_scroll: f32 = 0,
/// The main loop's pace: "waitevent", or "60" while something's held.
rate_fast: bool = false,

const log_lines = 300;

const Line = struct {
    text: []u8,
    kind: enum { out, cmd, warn },
    /// From the last command; older lines are dimmer.
    fresh: bool = true,
};

const Press = struct {
    at: [2]f32,
    target: enum { ui, map, divider, log_divider },
    /// The map's pan when the press began.
    pan: [2]f32 = .{ 0, 0 },
    /// Past the tap slop: a drag, not a tap.
    moved: bool = false,
};

pub const Dir = enum { up, down, left, right };

/// A scripted input (--click, --pad).
pub const Step = union(enum) {
    click: [2]f32,
    pad: c.SDL_GamepadButton,
};

pub const Options = struct {
    save: ?[]const u8 = null,
    /// The window's size, in points.
    size: [2]c_int = .{ 1280, 720 },
    /// Command lines to run at startup.
    cmds: []const []const u8 = &.{},
    /// With `screenshot`: input to replay first, a frame apart.
    script: []const Step = &.{},
    /// Save a frame here and quit.
    screenshot: ?[]const u8 = null,
    /// Pixels a font pixel, instead of working it out from the window.
    scale: ?u16 = null,
};

pub fn init(self: *App, gpa: Allocator, options: Options) !void {
    // Draw only when something happens, except while a screenshot script runs.
    _ = c.SDL_SetHint(c.SDL_HINT_MAIN_CALLBACK_RATE, if (options.screenshot != null) "60" else "waitevent");
    _ = c.SDL_SetAppMetadata("drgnwrrr", "0.1.0", "com.sadbeast.drgnwrrr");
    try errify(c.SDL_Init(c.SDL_INIT_VIDEO));
    if (!c.SDL_InitSubSystem(c.SDL_INIT_GAMEPAD)) app_log.warn("no gamepads: {s}", .{c.SDL_GetError()});
    // A handheld's console (kmsdrm, as on PortMaster's devices) takes the whole screen.
    const driver: [*:0]const u8 = c.SDL_GetCurrentVideoDriver() orelse "";
    const console = std.mem.eql(u8, std.mem.span(driver), "kmsdrm");
    // A phone's is the whole screen too, and resizable so it turns with it.
    const phone = builtin.abi.isAndroid();
    const window = try errify(c.SDL_CreateWindow(
        "drgnwrrr",
        options.size[0],
        options.size[1],
        if (console)
            c.SDL_WINDOW_FULLSCREEN
        else if (phone)
            c.SDL_WINDOW_FULLSCREEN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY
        else
            c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ));
    setIcon(window);
    const sdl_renderer = try errify(c.SDL_CreateRenderer(window, null));
    _ = c.SDL_SetRenderVSync(sdl_renderer, 1);

    const sav_path = if (options.save) |p| try gpa.dupeSentinel(u8, p, 0) else blk: {
        const pref: [*:0]u8 = try errify(c.SDL_GetPrefPath("drgnwrrr", "drgnwrrr"));
        defer c.SDL_free(pref);
        break :blk try std.fmt.allocPrintSentinel(gpa, "{s}drgnwrrr.sav", .{std.mem.span(pref)}, 0);
    };
    const prefs_path = try std.fmt.allocPrintSentinel(gpa, "{s}/prefs.txt", .{std.fs.path.dirname(sav_path) orelse "."}, 0);
    const screenshot = if (options.screenshot) |p| try gpa.dupeSentinel(u8, p, 0) else null;

    const clay_memory = try gpa.alloc(u8, c.Clay_MinMemorySize());
    const arena = c.Clay_CreateArenaWithCapacityAndMemory(clay_memory.len, clay_memory.ptr);
    _ = c.Clay_Initialize(arena, .{ .width = 1280, .height = 720 }, .{ .errorHandlerFunction = clayError, .userData = null });
    c.Clay_SetMeasureTextFunction(measureText, null);

    const prefs: Prefs = .load(prefs_path);
    self.* = .{
        .gpa = gpa,
        .window = window,
        .r = try .init(sdl_renderer),
        .session = .init(gpa, @truncate(c.SDL_GetPerformanceCounter())),
        .prefs = prefs,
        .map = .{ .gpa = gpa },
        .out = .init(gpa),
        .sav_path = sav_path,
        .prefs_path = prefs_path,
        .clay_memory = clay_memory,
        .frame = .init(gpa),
        .screenshot = screenshot,
        .script = options.script,
        .scale_override = options.scale,
        .handheld = console or phone,
        .screen_keyboard = c.SDL_HasScreenKeyboardSupport(),
    };
    self.session.assist = prefs.assist;

    var size: usize = 0;
    if (c.SDL_LoadFile(sav_path.ptr, &size)) |data| {
        defer c.SDL_free(data);
        if (size == dw.Sram.size) @memcpy(&self.session.sram, @as([*]const u8, @ptrCast(data))[0..size]);
    }
    try self.say("drgnwrrr: Dragon Warrior, minus the walking. Type `help` for commands.\n", .out);
    try self.nameField();
    self.shown_at = c.SDL_GetTicksNS();
    self.last_frame = self.shown_at;
    for (options.cmds) |line| try self.run(line, true);
}

/// The hero in a few tiles of Alefgard (looks.icon). Not every platform has window icons.
fn setIcon(window: *c.SDL_Window) void {
    const io = c.SDL_IOFromConstMem(atlas.icon_png, atlas.icon_png.len) orelse return;
    const icon = c.SDL_LoadPNG_IO(io, true) orelse return;
    defer c.SDL_DestroySurface(icon);
    _ = c.SDL_SetWindowIcon(window, icon);
}

pub fn deinit(self: *App) void {
    for (self.log.items) |l| self.gpa.free(l.text);
    self.log.deinit(self.gpa);
    for (self.history.items) |h| self.gpa.free(h);
    self.history.deinit(self.gpa);
    self.input.deinit(self.gpa);
    self.out.deinit();
    self.session.deinit();
    self.map.deinit();
    self.focusables.deinit(self.gpa);
    self.focus_stack.deinit(self.gpa);
    if (self.gamepad) |pad| c.SDL_CloseGamepad(pad);
    self.frame.deinit();
    self.gpa.free(self.clay_memory);
    self.gpa.free(self.sav_path);
    self.gpa.free(self.prefs_path);
    if (self.screenshot) |p| self.gpa.free(p);
    self.r.deinit();
    c.SDL_DestroyRenderer(self.r.sdl);
    c.SDL_DestroyWindow(self.window);
    c.SDL_Quit();
}

// ---------- the session ----------

/// Adds `text`'s lines to the log.
fn say(self: *App, text: []const u8, kind: @FieldType(Line, "kind")) !void {
    if (text.len == 0) return;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        // An empty line still takes a line's height.
        try self.log.append(self.gpa, .{ .text = try self.gpa.dupe(u8, if (line.len == 0) " " else line), .kind = kind });
    }
    if (self.log.items.len > log_lines) {
        const drop = self.log.items.len - log_lines;
        for (self.log.items[0..drop]) |l| self.gpa.free(l.text);
        self.log.replaceRangeAssumeCapacity(0, drop, &.{});
    }
    self.log_to_end = true;
}

/// Runs one command line, as if typed.
fn run(self: *App, line: []const u8, echo: bool) !void {
    for (self.log.items) |*l| l.fresh = false;
    const before = self.session.pending;
    // The hero's name isn't a command: don't echo it.
    if (echo and before != .name) {
        const echoed = try std.fmt.allocPrint(self.gpa, "> {s}", .{line});
        defer self.gpa.free(echoed);
        try self.say(echoed, .cmd);
    }
    self.out.clearRetainingCapacity();
    const idle = dw.framesFromNs(c.SDL_GetTicksNS() - self.shown_at);
    self.session.submit(&self.out.writer, line, idle) catch |err| {
        try self.out.writer.print("  (error: {t})\n", .{err});
    };
    try self.say(self.out.written(), .out);

    if (startsWithWord(line, "go")) self.last_go = .init("{s}", .{line});
    if (!isTapFollowUp(line)) self.tapped = null;
    if (self.session.sram_dirty) {
        self.session.sram_dirty = false;
        if (!c.SDL_SaveFile(self.sav_path.ptr, &self.session.sram, self.session.sram.len))
            try self.say(try std.fmt.bufPrint(&self.err_buf, "  Couldn't write {s}: {s}", .{ self.sav_path, c.SDL_GetError() }), .warn);
    }
    const now = self.session.pending;
    if (now != .command or before != .command) {
        self.menu = null;
        self.focus_stack.clearRetainingCapacity();
    }
    if (std.meta.activeTag(now) != std.meta.activeTag(before)) self.controls_to_top = true;
    if (self.menu == .danger) self.danger = .estimate(&self.session.g);
    if (now == .name and before != .name) try self.nameField();
    if (before == .name and now != .name) self.input.clearRetainingCapacity();
    self.shown_at = c.SDL_GetTicksNS();
}

fn startsWithWord(line: []const u8, word: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " ");
    return std.ascii.startsWithIgnoreCase(t, word) and (t.len == word.len or t[word.len] == ' ');
}

/// `go X Y` and `y` keep the tapped tile (tapping it again walks the route).
fn isTapFollowUp(line: []const u8) bool {
    if (startsWithWord(line, "y")) return true;
    if (!startsWithWord(line, "go")) return false;
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    _ = words.next();
    for (0..2) |_| {
        const w = words.next() orelse return false;
        _ = std.fmt.parseInt(u8, w, 10) catch return false;
    }
    return true;
}

pub fn hasSave(self: *const App) bool {
    var copy = self.session.sram;
    return Game.load(&copy, 0) != null;
}

/// The name field starts filled in, as the web game's does.
fn nameField(self: *App) !void {
    if (self.session.pending != .name) return;
    self.input.clearRetainingCapacity();
    try self.input.appendSlice(self.gpa, "Erdrick");
    self.name_untouched = true;
}

pub fn nameInput(self: *const App) []const u8 {
    return std.mem.trim(u8, self.input.items, " ");
}

fn submitInput(self: *App) !void {
    const line = try self.gpa.dupe(u8, std.mem.trim(u8, self.input.items, " "));
    defer self.gpa.free(line);
    // Out of the way of what the line does.
    self.keyboard_up = false;
    if (self.session.pending == .name) {
        if (line.len > 0) try self.run(line, false);
        return;
    }
    if (line.len > 0 and (self.history.items.len == 0 or !std.mem.eql(u8, self.history.items[self.history.items.len - 1], line)))
        try self.history.append(self.gpa, try self.gpa.dupe(u8, line));
    self.input.clearRetainingCapacity();
    self.history_at = self.history.items.len;
    // An empty line answers a route with its default: walk it.
    if (line.len == 0 and self.session.pending == .confirm_route) return self.perform(panel.walkCommand(self));
    try self.run(line, true);
}

fn savePrefs(self: *App) void {
    self.prefs.save(self.prefs_path);
}

/// Does what a button asked.
fn perform(self: *App, action: ui.Action) !void {
    switch (action) {
        .run => |l| try self.run(l.slice(), true),
        .quiet => |l| try self.run(l.slice(), false),
        .menu => |m| {
            if (self.focus) |f| try self.focus_stack.append(self.gpa, f);
            self.focus = null;
            self.menu = m;
            self.controls_to_top = true;
            if (m == .danger) self.danger = .estimate(&self.session.g);
        },
        .back => {
            self.menu = if (self.menu != null and std.mem.findScalar(ui.Menu, &panel.more, self.menu.?) != null) .more else null;
            self.controls_to_top = true;
            self.focus = self.focus_stack.pop();
            self.focus_into_view = true;
        },
        .letter => |ch| {
            // The first letter replaces the name the field starts with.
            if (self.name_untouched) self.input.clearRetainingCapacity();
            self.name_untouched = false;
            if (self.nameInput().len < 8 and !(ch == ' ' and self.input.items.len == 0)) try self.input.append(self.gpa, ch);
        },
        .erase => {
            self.name_untouched = false;
            _ = self.input.pop();
        },
        .risk => |r| {
            self.prefs.risk = r;
            self.savePrefs();
        },
        .replan => |r| {
            if (self.session.route) |route| if (route.go.risk == r) return;
            self.prefs.risk = r;
            self.savePrefs();
            const last = self.last_go;
            try self.run("n", false);
            if (last) |l| try self.run(withRisk(l.slice(), r).slice(), true);
        },
        .stop => |s| {
            const v = if (s.grind) &self.prefs.grind_stop else &self.prefs.stop;
            v.* = @intCast(std.math.clamp(@as(i16, v.*) + s.by, 0, 90));
            self.savePrefs();
        },
        .fights => |n| {
            self.prefs.fights = n;
            self.savePrefs();
        },
        .toggle => |t| {
            switch (t) {
                inline else => |f| {
                    const field = &@field(self.prefs, @tagName(f));
                    field.* = !field.*;
                },
            }
            self.session.assist = self.prefs.assist;
            self.savePrefs();
        },
        .new_game => {
            self.prefs.grind_auto = false;
            self.savePrefs();
            self.session.newGame();
            self.menu = null;
            try self.nameField();
        },
        .continue_game => {
            self.out.clearRetainingCapacity();
            if (try self.session.continueGame(&self.out.writer)) self.input.clearRetainingCapacity();
            self.menu = null;
            try self.say(self.out.written(), .out);
            self.controls_to_top = true;
        },
        .zoom_in => self.map.zoom(&self.session.g, 2),
        .zoom_out => self.map.zoom(&self.session.g, 0.5),
        .overview => self.map.overview(&self.session.g),
        .recentre => self.map.recentre(),
        .quit => self.quit = true,
    }
}

/// `line` (a go) with its risk word swapped for `risk`.
fn withRisk(line: []const u8, risk: travel.Risk) ui.Line {
    var out: ui.Line = .{};
    var w: Writer = .fixed(&out.buf);
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    var first = true;
    while (words.next()) |word| {
        if (!first) w.writeByte(' ') catch {};
        first = false;
        w.writeAll(if (std.meta.stringToEnum(travel.Risk, word) != null) @tagName(risk) else word) catch {};
    }
    out.len = @intCast(w.end);
    return out;
}

/// A tap on the map: step next to the hero, walk out of town past its
/// edge, or plan a route there (tap the same tile again to walk it).
fn tap(self: *App, spot: Map.Spot) !void {
    const s = &self.session;
    if (s.pending != .command and s.pending != .confirm_route) return;
    const g = &s.g;
    const dx = spot.x - g.at.x;
    const dy = spot.y - g.at.y;
    if (dx == 0 and dy == 0) return;
    if (s.pending == .command and @abs(dx) + @abs(dy) == 1) {
        self.tapped = null;
        return self.run(if (dy < 0) "n" else if (dy > 0) "s" else if (dx < 0) "w" else "e", true);
    }
    if (spot.off) {
        if (game.townFor(g.at.map) != null and s.pending == .command) {
            self.tapped = null;
            try self.run("leave", true);
        }
        return;
    }
    const at: dw.Warp = .{ .map = g.at.map, .x = @intCast(spot.x), .y = @intCast(spot.y) };
    if (s.pending == .confirm_route and self.tapped != null and std.meta.eql(self.tapped.?, at)) {
        self.tapped = null;
        return self.perform(panel.walkCommand(self));
    }
    self.tapped = at;
    const target: ui.Line = .init("{d} {d}", .{ spot.x, spot.y });
    try self.perform(panel.goCommand(self, target.slice()));
}

// ---------- events ----------

/// Typing goes to a field: the hero's name, or the command line when it's shown.
fn wantsText(self: *const App) bool {
    return self.session.pending == .name or self.prefs.show_cmd;
}

pub fn event(self: *App, ev: *c.SDL_Event) !c.SDL_AppResult {
    const density = c.SDL_GetWindowPixelDensity(self.window);
    switch (ev.type) {
        c.SDL_EVENT_QUIT => return c.SDL_APP_SUCCESS,
        c.SDL_EVENT_TEXT_INPUT => if (self.wantsText()) {
            try self.input.appendSlice(self.gpa, std.mem.span(ev.text.text));
            // Names are 1-8 letters.
            if (self.session.pending == .name and self.input.items.len > 8) self.input.shrinkRetainingCapacity(8);
        },
        c.SDL_EVENT_KEY_DOWN => {
            self.input_mode = .pointer;
            try self.key(ev.key.key);
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            self.input_mode = .pointer;
            self.mouse = .{ ev.motion.x * density, ev.motion.y * density };
            self.drag();
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (ev.button.button == c.SDL_BUTTON_LEFT) {
            self.input_mode = .pointer;
            self.mouse = .{ ev.button.x * density, ev.button.y * density };
            self.pressAt(self.mouse);
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => if (ev.button.button == c.SDL_BUTTON_LEFT) {
            self.mouse = .{ ev.button.x * density, ev.button.y * density };
            try self.release();
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            const x, const y = self.mouse;
            if (self.session.pending != .name and self.map.contains(x, y) and !clay.inBox(clay.box("mapctl"), x, y)) {
                self.map.zoomAt(&self.session.g, if (ev.wheel.y > 0) 1.25 else 0.8, x, y);
            } else self.wheel += ev.wheel.y * 3 * self.lineHeight();
        },
        c.SDL_EVENT_WINDOW_MOUSE_LEAVE => self.hover = null,
        c.SDL_EVENT_SCREEN_KEYBOARD_HIDDEN => self.keyboard_up = false,
        c.SDL_EVENT_PINCH_BEGIN => {
            // The first finger's press isn't a drag or a tap now.
            self.press = null;
            self.pinch = 1;
        },
        c.SDL_EVENT_PINCH_UPDATE => {
            const x, const y = self.mouse;
            self.pinch *= ev.pinch.scale;
            // The map zooms in steps; zoomAt rounds smaller ones away.
            if (self.session.pending != .name and self.map.contains(x, y) and (self.pinch > 1.25 or self.pinch < 0.8)) {
                self.map.zoomAt(&self.session.g, self.pinch, x, y);
                self.pinch = 1;
            }
        },
        c.SDL_EVENT_GAMEPAD_ADDED => if (self.gamepad == null) {
            self.gamepad = c.SDL_OpenGamepad(ev.gdevice.which);
            // Show the focus from the start, so the first press does something.
            if (self.gamepad != null) self.input_mode = .pad;
        },
        c.SDL_EVENT_GAMEPAD_REMOVED => if (self.gamepad) |pad| {
            if (c.SDL_GetGamepadID(pad) == ev.gdevice.which) {
                c.SDL_CloseGamepad(pad);
                self.gamepad = null;
                self.held = null;
            }
        },
        c.SDL_EVENT_GAMEPAD_BUTTON_DOWN => {
            self.input_mode = .pad;
            try self.padButton(ev.gbutton.button);
        },
        c.SDL_EVENT_GAMEPAD_BUTTON_UP => if (dpadDir(ev.gbutton.button)) |d| {
            if (self.held == d) self.held = null;
        },
        c.SDL_EVENT_GAMEPAD_AXIS_MOTION => try self.padAxis(ev.gaxis.axis, ev.gaxis.value),
        else => {},
    }
    return c.SDL_APP_CONTINUE;
}

fn key(self: *App, k: c.SDL_Keycode) !void {
    const pending = self.session.pending;
    // Keys every mode shares.
    switch (k) {
        c.SDLK_PAGEUP => return {
            self.wheel += self.pageHeight();
        },
        c.SDLK_PAGEDOWN => return {
            self.wheel -= self.pageHeight();
        },
        // Android's Back too (SDL_ANDROID_TRAP_BACK_BUTTON).
        c.SDLK_ESCAPE, c.SDLK_AC_BACK => {
            if (self.keyboard_up) return {
                self.keyboard_up = false;
            };
            if (self.wantsText() and self.input.items.len > 0 and pending != .name) return self.input.clearRetainingCapacity();
            if (pending == .confirm_route) return self.run("n", true);
            if (self.menu != null) return self.perform(.back);
            return;
        },
        else => {},
    }
    if (self.wantsText()) return switch (k) {
        c.SDLK_RETURN, c.SDLK_KP_ENTER => self.submitInput(),
        c.SDLK_BACKSPACE => {
            // Back over one UTF-8 character.
            while (self.input.pop()) |b| if (b & 0xC0 != 0x80) break;
        },
        c.SDLK_UP => if (pending != .name and self.history_at > 0) {
            self.history_at -= 1;
            try self.recall();
        },
        c.SDLK_DOWN => if (pending != .name and self.history_at < self.history.items.len) {
            self.history_at += 1;
            try self.recall();
        },
        else => {},
    };
    // No field: the web game's keys.
    const dir: ?[]const u8 = switch (k) {
        c.SDLK_UP, c.SDLK_W => "n",
        c.SDLK_DOWN, c.SDLK_S => "s",
        c.SDLK_LEFT, c.SDLK_A => "w",
        c.SDLK_RIGHT, c.SDLK_D => "e",
        else => null,
    };
    if (dir != null and pending == .command) return self.run(dir.?, true);
    switch (k) {
        c.SDLK_RETURN, c.SDLK_KP_ENTER => if (pending == .confirm_route) try self.perform(panel.walkCommand(self)),
        c.SDLK_EQUALS, c.SDLK_PLUS, c.SDLK_KP_PLUS => try self.perform(.zoom_in),
        c.SDLK_MINUS, c.SDLK_KP_MINUS => try self.perform(.zoom_out),
        c.SDLK_0 => try self.perform(.recentre),
        c.SDLK_F, c.SDLK_R, c.SDLK_H => if (pending == .battle) try self.run(switch (k) {
            c.SDLK_F => "f",
            c.SDLK_R => "r",
            else => "h",
        }, true),
        else => {},
    }
}

fn recall(self: *App) !void {
    self.input.clearRetainingCapacity();
    if (self.history_at < self.history.items.len) try self.input.appendSlice(self.gpa, self.history.items[self.history_at]);
}

/// The dividers' grab area reaches this far either side of the line.
fn grip(self: *const App) f32 {
    return @floatFromInt(4 * self.scale());
}

fn nearLine(b: ?c.Clay_BoundingBox, x: f32, y: f32, slop: f32) bool {
    const r = b orelse return false;
    return x >= r.x - slop and y >= r.y - slop and x < r.x + r.width + slop and y < r.y + r.height + slop;
}

fn pressAt(self: *App, p: [2]f32) void {
    const x, const y = p;
    self.press = if (nearLine(clay.box("divider"), x, y, self.grip()))
        .{ .at = p, .target = .divider }
    else if (nearLine(clay.box("logdivider"), x, y, self.grip()))
        .{ .at = p, .target = .log_divider }
    else if (self.session.pending != .name and self.map.contains(x, y) and !clay.inBox(clay.box("mapctl"), x, y))
        .{ .at = p, .target = .map, .pan = self.map.pan }
    else
        .{ .at = p, .target = .ui };
}

/// A press that moves less than this (in font pixels) is still a tap.
const tap_slop = 4;

fn drag(self: *App) void {
    const x, const y = self.mouse;
    const p = if (self.press) |*p| p else {
        self.hover = if (self.session.pending != .name and self.map.contains(x, y)) self.map.spotAt(&self.session, x, y) else null;
        return;
    };
    const dx = x - p.at[0];
    const dy = y - p.at[1];
    if (!p.moved and @sqrt(dx * dx + dy * dy) > @as(f32, @floatFromInt(tap_slop * self.scale()))) p.moved = true;
    const size = pixelSize();
    switch (p.target) {
        .map => if (p.moved) self.map.dragFrom(p.pan, dx, dy),
        .divider => if (self.sideBySide()) {
            self.prefs.panel_w = std.math.clamp((size.width - x) / size.width, 0.2, 0.7);
        } else {
            self.prefs.panel_h = std.math.clamp((size.height - y) / size.height, 0.2, 0.75);
        },
        .log_divider => if (clay.box("split")) |b| {
            self.prefs.log_size = std.math.clamp((y - b.y) / b.height, 0.05, 0.9);
        },
        .ui => {},
    }
}

fn release(self: *App) !void {
    const p = self.press orelse return;
    self.press = null;
    switch (p.target) {
        .map => if (!p.moved) try self.tap(self.map.spotAt(&self.session, p.at[0], p.at[1])),
        .divider, .log_divider => self.savePrefs(),
        .ui => {
            if (self.screen_keyboard and clay.inBox(clay.box("field"), self.mouse[0], self.mouse[1])) self.keyboard_up = true;
            self.click = .{ .down = p.at, .up = self.mouse };
        },
    }
}

// ---------- layout ----------

/// Pixels a font pixel: text is drawn at whole multiples of the font's 8 px,
/// by the window's shorter side: 1 up to 480 px, 2 at 720p, 3 at 1080p. A
/// handheld's small screen is held close, so there it's 2 at 480 px, 3 at 720.
fn scale(self: *const App) u16 {
    if (self.scale_override) |s| return s;
    const size = pixelSize();
    const per: f32 = if (self.handheld) 240 else 300;
    return @max(1, @as(u16, @intFromFloat(@min(size.width, size.height) / per)));
}

fn lineHeight(self: *const App) f32 {
    return @floatFromInt(10 * self.scale());
}

fn pageHeight(self: *const App) f32 {
    return @max(self.lineHeight(), pixelSize().height / 2);
}

fn pixelSize() c.Clay_Dimensions {
    return .{ .width = @floatFromInt(win_w), .height = @floatFromInt(win_h) };
}

var win_w: c_int = 1280;
var win_h: c_int = 720;
/// The window's edges that a notch, rounded corners or the system's bars
/// cover, in pixels: left, top, right, bottom.
var insets: [4]u16 = .{ 0, 0, 0, 0 };

fn updateInsets(window: *c.SDL_Window) void {
    var safe: c.SDL_Rect = undefined;
    if (!c.SDL_GetWindowSafeArea(window, &safe)) return;
    const density = c.SDL_GetWindowPixelDensity(window);
    const px = struct {
        fn px(points: c_int, d: f32) u16 {
            return @intFromFloat(@max(0, @ceil(@as(f32, @floatFromInt(points)) * d)));
        }
    }.px;
    var points: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &points, &h);
    insets = .{
        px(safe.x, density),
        px(safe.y, density),
        px(points - safe.x - safe.w, density),
        px(h - safe.y - safe.h, density),
    };
}

/// The map beside the panel, when the window is wide enough (else above it).
/// Beside it takes a landscape window at least 48 characters wide (at the
/// text's size), so the panel gets room for a few columns of buttons.
fn sideBySide(self: *const App) bool {
    const size = pixelSize();
    const chars = size.width / @as(f32, @floatFromInt(8 * self.scale()));
    return size.width > size.height and chars >= 48;
}

const map_custom: ui.Custom = .map;
const prompt_looks = [_]ui.Custom{
    .{ .sprite = .{ .sprite = .zoom_in, .color = ui.ink } },
    .{ .sprite = .{ .sprite = .zoom_out, .color = ui.ink } },
    .{ .sprite = .{ .sprite = .overview, .color = ui.ink } },
    .{ .sprite = .{ .sprite = .recentre, .color = ui.ink } },
};

fn layout(self: *App, click: ?ui.Click, activate: ?u32) struct { c.Clay_RenderCommandArray, ?ui.Action } {
    _ = self.frame.reset(.retain_capacity);
    const s = self.scale();
    const size = pixelSize();
    const side = self.sideBySide();
    const pad = 6 * s;
    const panel_size = if (side)
        if (self.prefs.panel_w > 0) self.prefs.panel_w * size.width else @min(@as(f32, @floatFromInt(8 * 30 * s + 2 * pad)), size.width * 0.42)
    else if (self.prefs.panel_h > 0) self.prefs.panel_h * size.height else size.height * 0.52;
    var u: ui.Ui = .{
        .u = s,
        .width = (if (side) panel_size else size.width) - @as(f32, @floatFromInt(2 * pad)),
        .arena = self.frame.allocator(),
        .click = click,
        .focus = self.focus,
        .show_focus = self.input_mode == .pad and !self.map_mode,
        .activate = activate,
    };
    const playing = self.session.pending != .name;

    // Before every pass, not once a frame: this is where Clay forgets scroll
    // containers the last pass didn't declare. A frame lays out several times,
    // and one left over from an earlier pass (the title's name field, after
    // Continue) keeps a pointer to whatever element now sits in its slot,
    // which crashes the next hover. The wheel goes to the first pass; the
    // time step only matters for drag scrolling, which is off.
    c.Clay_UpdateScrollContainers(false, .{ .x = 0, .y = self.wheel }, 0);
    self.wheel = 0;
    c.Clay_BeginLayout();
    clay.open(.{
        .id = clay.id("root"),
        .layout = .{
            .sizing = clay.sizing(clay.grow(), clay.grow()),
            .padding = .{ .left = insets[0], .top = insets[1], .right = insets[2], .bottom = insets[3] },
            .layoutDirection = if (side) clay.left_to_right else clay.top_to_bottom,
        },
        .backgroundColor = clay.rgb(0),
    });
    {
        clay.open(.{
            .id = clay.id("stage"),
            .layout = .{ .sizing = clay.sizing(clay.grow(), clay.grow()) },
            .custom = .{ .customData = @constCast(&map_custom) },
        });
        if (playing) self.mapOverlays(&u);
        clay.close();
        clay.leaf(.{
            .id = clay.id("divider"),
            .layout = .{ .sizing = if (side) clay.sizing(clay.fixed(1), clay.grow()) else clay.sizing(clay.grow(), clay.fixed(1)) },
            .backgroundColor = clay.rgb(if (self.press != null and self.press.?.target == .divider) ui.dim else ui.rule),
        });
        clay.open(.{
            .id = clay.id("panel"),
            .layout = .{
                .sizing = if (side) clay.sizing(clay.fixed(panel_size), clay.grow()) else clay.sizing(clay.grow(), clay.fixed(panel_size)),
                .padding = .{ .left = pad, .right = pad, .bottom = 4 * s },
                .layoutDirection = clay.top_to_bottom,
            },
        });
        {
            if (playing) self.status(&u);
            clay.open(.{ .id = clay.id("split"), .layout = .{ .sizing = clay.sizing(clay.grow(), clay.grow()), .layoutDirection = clay.top_to_bottom } });
            if (self.prefs.show_log and playing) {
                self.logView(&u);
                clay.leaf(.{
                    .id = clay.id("logdivider"),
                    .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fixed(1)) },
                    .backgroundColor = clay.rgb(if (self.press != null and self.press.?.target == .log_divider) ui.dim else ui.rule),
                });
            }
            clay.open(.{
                .id = clay.id("controls"),
                .layout = .{ .sizing = clay.sizing(clay.grow(), clay.grow()), .padding = .{ .top = 4 * s, .bottom = 2 * s }, .layoutDirection = clay.top_to_bottom },
                .clip = .{ .vertical = true },
            });
            panel.controls(self, &u);
            clay.close();
            clay.close();
            if (self.prefs.show_cmd and playing) {
                clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .padding = .{ .top = 3 * s } }, .border = .{ .color = clay.rgb(ui.rule), .width = .{ .top = 1 } } });
                self.inputField(&u, "type a command (help)");
                clay.close();
            }
            if (self.input_mode == .pad) self.padHints(&u);
        }
        clay.close();
    }
    clay.close();
    const cmds = c.Clay_EndLayout();
    self.focusables.clearRetainingCapacity();
    self.focusables.appendSlice(self.gpa, u.focusables.items) catch {};
    return .{ cmds, u.action };
}

/// Over the map: where you are and what's under the pointer, and the map's buttons.
fn mapOverlays(self: *App, u: *ui.Ui) void {
    const s = u.u;
    const g = &self.session.g;
    const town = game.townFor(g.at.map);
    clay.open(.{
        .id = clay.id("hud"),
        .layout = .{ .sizing = clay.sizing(clay.fit(), clay.fit()), .padding = clay.padding(3 * s, 1 * s), .childGap = 6 * s },
        .backgroundColor = .{ .r = 0, .g = 0, .b = 0, .a = 190 },
        .floating = .{
            .attachTo = clay.attach_parent,
            .attachPoints = .{ .element = clay.point_left_top, .parent = clay.point_left_top },
            .pointerCaptureMode = clay.pointer_passthrough,
            .zIndex = 1,
        },
    });
    var config = u.textConfig(ui.dim);
    config.wrapMode = clay.wrap_none;
    clay.text(if (town) |t| t.name else dw.map_names[g.at.map], config);
    const spot = if (self.map_mode) if (self.map.cursor) |cur| Map.tileSpot(&self.session, cur[0], cur[1]) else null else self.hover;
    if (spot) |h| {
        config.textColor = clay.rgb(ui.ink);
        if (!h.off) {
            clay.text(u.fmt("{s} {d}, {d}", .{ if (looks.tile(h.tile)) |t| t.name else "", h.x, h.y }), config);
        } else if (town != null) clay.text("Leave town", config);
    }
    clay.close();

    const b = u.px(22);
    clay.open(.{
        .id = clay.id("mapctl"),
        .layout = .{ .sizing = clay.sizing(clay.fit(), clay.fit()), .layoutDirection = clay.top_to_bottom, .childGap = 2 * s },
        .floating = .{
            .attachTo = clay.attach_parent,
            .attachPoints = .{ .element = clay.point_right_top, .parent = clay.point_right_top },
            .offset = .{ .x = -u.px(4), .y = u.px(4) },
            .zIndex = 1,
        },
    });
    const actions = [_]ui.Action{ .zoom_in, .zoom_out, .overview, .recentre };
    for (0..2) |row| {
        clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.fit(), clay.fit()), .childGap = 2 * s } });
        for (0..2) |col| u.spriteButton(&prompt_looks[row * 2 + col], actions[row * 2 + col], b);
        clay.close();
    }
    clay.close();
}

var status_bufs: [4][24]u8 = undefined;

/// One line, whatever the numbers; pressing it opens Status, when a menu can open.
fn status(self: *App, u: *ui.Ui) void {
    const s = u.u;
    const g = &self.session.g;
    const h = g.hero();
    const low = g.lowHp();
    const id = clay.id("status");
    if (self.session.pending == .command) if (u.click) |k| {
        if (c.Clay_PointerOver(id) and clay.inBox(clay.box("status"), k.down[0], k.down[1])) u.action = .{ .menu = .status };
    };
    clay.open(.{
        .id = id,
        .layout = .{
            .sizing = clay.sizing(clay.grow(), clay.fit()),
            .padding = .{ .top = 4 * s, .bottom = 3 * s },
            .childGap = 1 * s,
            .layoutDirection = clay.top_to_bottom,
        },
        .border = .{ .color = clay.rgb(ui.rule), .width = .{ .bottom = 1 } },
    });
    var config = u.textConfig(ui.ink);
    config.wrapMode = clay.wrap_none;
    clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .childGap = 6 * s } });
    const parts = [_]struct { []const u8, u24 }{
        .{ std.fmt.bufPrint(&status_bufs[0], "Lv {d}", .{h.level}) catch "", if (low) ui.bad else ui.ink },
        .{ std.fmt.bufPrint(&status_bufs[1], "HP {d}/{d}", .{ g.hp, h.stats.hp }) catch "", if (low) ui.bad else ui.hp },
        .{ std.fmt.bufPrint(&status_bufs[2], "MP {d}/{d}", .{ g.mp, h.stats.mp }) catch "", if (low) ui.bad else ui.mp },
        .{ std.fmt.bufPrint(&status_bufs[3], "{d} G", .{g.gold}) catch "", ui.gold },
    };
    for (parts) |p| {
        config.textColor = clay.rgb(p[1]);
        clay.text(p[0], config);
    }
    clay.close();
    if (self.prefs.show_where) {
        // Where you are: quieter than the stats.
        config.textColor = clay.rgb(ui.dim);
        const zone = travel.zoneAt(g.at.map, g.at.x, g.at.y);
        const here = g.tileAt(g.at.x, g.at.y);
        clay.text(u.fmt("{d}, {d}{s}  {d:.1}% a step", .{
            g.at.x,
            g.at.y,
            if (zone) |z| u.fmt("  zone {d}", .{z}) else "",
            travel.encounterChance(g, g.at.map, here, g.at.x, g.at.y) * 100,
        }), config);
    }
    clay.close();
}

fn logView(self: *App, u: *ui.Ui) void {
    const s = u.u;
    clay.open(.{
        .id = clay.id("log"),
        .layout = .{
            .sizing = clay.sizing(clay.grow(), clay.percent(self.prefs.log_size)),
            .padding = .{ .top = 3 * s, .bottom = 3 * s },
            .layoutDirection = clay.top_to_bottom,
        },
        .clip = .{ .vertical = true },
    });
    for (self.log.items) |l| {
        const color: u24 = switch (l.kind) {
            .cmd => ui.echo,
            .warn => ui.bad,
            .out => if (l.fresh) ui.ink else ui.dim,
        };
        u.text(l.text, color);
    }
    clay.close();
}

/// The line being typed, in a field, with a cursor after it.
pub fn inputField(self: *App, u: *ui.Ui, placeholder: []const u8) void {
    const s = u.u;
    clay.open(.{
        .id = clay.id("field"),
        .layout = .{
            .sizing = clay.sizing(clay.grow(), clay.fit()),
            .padding = .{ .left = 4 * s, .right = 4 * s, .top = 3 * s, .bottom = 3 * s },
        },
        .clip = .{ .horizontal = true },
        .backgroundColor = clay.rgb(ui.field),
        .border = .{ .color = clay.rgb(ui.field_border), .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    });
    var config = u.textConfig(ui.ink);
    config.wrapMode = clay.wrap_none;
    if (self.input.items.len > 0) clay.text(self.input.items, config);
    clay.text("_", config);
    if (self.input.items.len == 0) {
        config.textColor = clay.rgb(ui.dim);
        clay.text(u.fmt(" {s}", .{placeholder}), config);
    }
    clay.close();
}

// ---------- the controller ----------

fn dpadDir(b: c.SDL_GamepadButton) ?Dir {
    return switch (b) {
        c.SDL_GAMEPAD_BUTTON_DPAD_UP => .up,
        c.SDL_GAMEPAD_BUTTON_DPAD_DOWN => .down,
        c.SDL_GAMEPAD_BUTTON_DPAD_LEFT => .left,
        c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT => .right,
        else => null,
    };
}

/// Held directions repeat after this long, then this often.
const repeat_delay = 300 * std.time.ns_per_ms;
const repeat_every = 90 * std.time.ns_per_ms;

/// Buttons go by position, as SDL reports them: south (A on an Xbox pad)
/// presses, east goes back. padHints shows the pad's own names for them.
fn padButton(self: *App, b: c.SDL_GamepadButton) !void {
    if (dpadDir(b)) |d| {
        self.held = d;
        self.next_repeat = c.SDL_GetTicksNS() + repeat_delay;
        return self.direction(d);
    }
    const pending = self.session.pending;
    switch (b) {
        c.SDL_GAMEPAD_BUTTON_SOUTH => if (self.map_mode) {
            if (self.map.cursor) |cur| try self.tap(Map.tileSpot(&self.session, cur[0], cur[1]));
        } else {
            self.activate = self.focus;
        },
        c.SDL_GAMEPAD_BUTTON_EAST => if (self.map_mode) {
            self.setMapMode(false);
        } else switch (pending) {
            .name => _ = self.input.pop(),
            .confirm_route => try self.run("n", true),
            else => if (self.menu != null) try self.perform(.back),
        },
        c.SDL_GAMEPAD_BUTTON_NORTH, c.SDL_GAMEPAD_BUTTON_BACK => self.setMapMode(!self.map_mode),
        c.SDL_GAMEPAD_BUTTON_WEST => if (pending != .name) {
            try self.perform(.recentre);
            if (self.map_mode) self.map.cursor = .{ self.session.g.at.x, self.session.g.at.y };
        },
        c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER => if (pending != .name) try self.perform(.zoom_out),
        c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER => if (pending != .name) try self.perform(.zoom_in),
        c.SDL_GAMEPAD_BUTTON_START => switch (pending) {
            .name => if (self.nameInput().len > 0) try self.run(self.nameInput(), false),
            .command => try self.perform(if (self.menu == null) .{ .menu = .more } else .back),
            else => {},
        },
        else => {},
    }
}

/// Map mode is for when a tap would do something: walking about or answering a route.
fn canTap(self: *const App) bool {
    return self.session.pending == .command or self.session.pending == .confirm_route;
}

fn setMapMode(self: *App, on: bool) void {
    self.map_mode = on and self.canTap();
    self.map.cursor = if (self.map_mode) .{ self.session.g.at.x, self.session.g.at.y } else null;
}

/// The d-pad: moves the map cursor in map mode, else the focus.
fn direction(self: *App, d: Dir) !void {
    if (self.map_mode) {
        const dx: i32, const dy: i32 = switch (d) {
            .up => .{ 0, -1 },
            .down => .{ 0, 1 },
            .left => .{ -1, 0 },
            .right => .{ 1, 0 },
        };
        return self.map.moveCursor(&self.session.g, dx, dy);
    }
    self.moveFocus(d);
}

/// The left stick works as a d-pad; the right stick and the triggers scroll.
fn padAxis(self: *App, axis: c.SDL_GamepadAxis, value: i16) !void {
    _ = value; // read both axes of a stick together instead
    switch (axis) {
        c.SDL_GAMEPAD_AXIS_LEFTX, c.SDL_GAMEPAD_AXIS_LEFTY => {
            const pad = self.gamepad orelse return;
            const x = @as(f32, @floatFromInt(c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_LEFTX))) / 32767;
            const y = @as(f32, @floatFromInt(c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_LEFTY))) / 32767;
            // Past half way on its stronger axis; back under a third lets go.
            const d: ?Dir = if (@max(@abs(x), @abs(y)) < (if (self.stick == null) @as(f32, 0.5) else 0.33))
                null
            else if (@abs(x) > @abs(y))
                (if (x < 0) Dir.left else Dir.right)
            else
                (if (y < 0) Dir.up else Dir.down);
            if (d == self.stick) return;
            if (self.stick != null and self.held == self.stick) self.held = null;
            self.stick = d;
            if (d) |dir| {
                self.input_mode = .pad;
                self.held = dir;
                self.next_repeat = c.SDL_GetTicksNS() + repeat_delay;
                try self.direction(dir);
            }
        },
        c.SDL_GAMEPAD_AXIS_RIGHTY, c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER, c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER => {
            const pad = self.gamepad orelse return;
            const ry = @as(f32, @floatFromInt(c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_RIGHTY))) / 32767;
            const lt = @as(f32, @floatFromInt(c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER))) / 32767;
            const rt = @as(f32, @floatFromInt(c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER))) / 32767;
            const amount = (if (@abs(ry) > 0.25) ry else 0) + rt - lt;
            self.scroll_speed = if (@abs(amount) > 0.1) amount * self.lineHeight() * 30 else 0;
            if (self.scroll_speed != 0) self.input_mode = .pad;
        },
        else => {},
    }
}

/// Repeats a held direction and scrolls while a stick or trigger is pushed;
/// only then does the main loop run at a steady pace.
fn tick(self: *App) void {
    const now = c.SDL_GetTicksNS();
    if (self.held) |d| if (now >= self.next_repeat) {
        self.next_repeat = now + repeat_every;
        self.direction(d) catch {};
    };
    if (self.scroll_speed != 0) {
        const dt: f32 = @as(f32, @floatFromInt(now -| self.last_frame)) / std.time.ns_per_s;
        self.pad_scroll += self.scroll_speed * @min(dt, 0.1);
    }
    if (self.map_mode and !self.canTap()) self.setMapMode(false);
    const fast = self.held != null or self.scroll_speed != 0;
    if (fast != self.rate_fast and self.screenshot == null) {
        self.rate_fast = fast;
        _ = c.SDL_SetHint(c.SDL_HINT_MAIN_CALLBACK_RATE, if (fast) "60" else "waitevent");
    }
}

fn boxOf(id: u32) ?c.Clay_BoundingBox {
    const data = c.Clay_GetElementData(std.mem.zeroInit(c.Clay_ElementId, .{ .id = id }));
    return if (data.found) data.boundingBox else null;
}

fn focusIndex(self: *const App) ?usize {
    const f = self.focus orelse return null;
    for (self.focusables.items, 0..) |b, i| if (b.id == f) return i;
    return null;
}

/// How far `p` is outside [lo, hi].
fn outside(p: f32, lo: f32, hi: f32) f32 {
    return if (p < lo) lo - p else if (p > hi) p - hi else 0;
}

/// Moves the focus to the nearest button that way: nearest along the way,
/// with being off to the side (past the button's edge) counting double.
fn moveFocus(self: *App, d: Dir) void {
    const from = boxOf(self.focus orelse return) orelse return;
    const fx = from.x + from.width / 2;
    const fy = from.y + from.height / 2;
    var best: ?u32 = null;
    var best_score: f32 = std.math.inf(f32);
    for (self.focusables.items) |b| {
        if (b.id == self.focus.?) continue;
        const r = boxOf(b.id) orelse continue;
        // Edge to edge along the way, so a wide button next door counts as next door.
        const along: f32, const side: f32 = switch (d) {
            .up => .{ from.y - (r.y + r.height), outside(fx, r.x, r.x + r.width) },
            .down => .{ r.y - (from.y + from.height), outside(fx, r.x, r.x + r.width) },
            .left => .{ from.x - (r.x + r.width), outside(fy, r.y, r.y + r.height) },
            .right => .{ r.x - (from.x + from.width), outside(fy, r.y, r.y + r.height) },
        };
        if (along < -1) continue;
        const score = @max(0, along) + 2 * side;
        if (score < best_score) {
            best_score = score;
            best = b.id;
        }
    }
    if (best) |id| {
        self.focus = id;
        self.focus_into_view = true;
    }
}

/// After a layout: if the focused button has gone, focus the panel's first
/// filled button (else its first); then scroll the focus into view. True if
/// that changed anything to draw.
fn settleFocus(self: *App) bool {
    var changed = false;
    if (self.focusIndex() == null) {
        const panel_box = clay.box("controls");
        const back = c.Clay__HashString(clay.str(ui.back_key), 0, 0).id;
        var first: ?u32 = null;
        var primary: ?u32 = null;
        var back_here = false;
        for (self.focusables.items) |b| {
            const r = boxOf(b.id) orelse continue;
            if (!clay.inBox(panel_box, r.x + r.width / 2, r.y + r.height / 2)) continue;
            if (b.id == back) back_here = true;
            if (first == null and b.id != back) first = b.id;
            if (b.primary and primary == null) primary = b.id;
        }
        self.focus = primary orelse first orelse if (back_here) back else if (self.focusables.items.len > 0) self.focusables.items[0].id else null;
        changed = self.focus != null;
        self.focus_into_view = true;
    }
    const sc = c.Clay_GetScrollContainerData(clay.id("controls"));
    if (sc.found and self.pad_scroll != 0) {
        const lowest = @min(0, sc.scrollContainerDimensions.height - sc.contentDimensions.height);
        sc.scrollPosition.*.y = std.math.clamp(sc.scrollPosition.*.y - self.pad_scroll, lowest, 0);
        self.pad_scroll = 0;
        changed = true;
    }
    if (self.focus_into_view and sc.found) {
        self.focus_into_view = false;
        const view = clay.box("controls") orelse return changed;
        const r = boxOf(self.focus orelse return changed) orelse return changed;
        // Only the panel scrolls (not the map's buttons).
        if (!clay.inBox(view, r.x + r.width / 2, view.y)) return changed;
        const margin = @as(f32, @floatFromInt(4 * self.scale()));
        const lowest = @min(0, sc.scrollContainerDimensions.height - sc.contentDimensions.height);
        var y = sc.scrollPosition.*.y;
        if (r.y < view.y + margin) y += view.y + margin - r.y;
        if (r.y + r.height > view.y + view.height - margin) y -= r.y + r.height - (view.y + view.height - margin);
        y = std.math.clamp(y, lowest, 0);
        if (y != sc.scrollPosition.*.y) {
            sc.scrollPosition.*.y = y;
            changed = true;
        }
    }
    return changed;
}

/// The pad's own name for a button (A, Cross, ...), by where it sits.
fn padLabel(self: *const App, b: c.SDL_GamepadButton) []const u8 {
    const pad = self.gamepad orelse return switch (b) {
        c.SDL_GAMEPAD_BUTTON_SOUTH => "A",
        c.SDL_GAMEPAD_BUTTON_EAST => "B",
        c.SDL_GAMEPAD_BUTTON_WEST => "X",
        else => "Y",
    };
    return switch (c.SDL_GetGamepadButtonLabel(pad, b)) {
        c.SDL_GAMEPAD_BUTTON_LABEL_A => "A",
        c.SDL_GAMEPAD_BUTTON_LABEL_B => "B",
        c.SDL_GAMEPAD_BUTTON_LABEL_X => "X",
        c.SDL_GAMEPAD_BUTTON_LABEL_Y => "Y",
        c.SDL_GAMEPAD_BUTTON_LABEL_CROSS => "Cross",
        c.SDL_GAMEPAD_BUTTON_LABEL_CIRCLE => "Circle",
        c.SDL_GAMEPAD_BUTTON_LABEL_SQUARE => "Square",
        c.SDL_GAMEPAD_BUTTON_LABEL_TRIANGLE => "Triangle",
        else => "?",
    };
}

/// What the buttons do now, under the panel.
fn padHints(self: *App, u: *ui.Ui) void {
    const s = u.u;
    const a = self.padLabel(c.SDL_GAMEPAD_BUTTON_SOUTH);
    const b = self.padLabel(c.SDL_GAMEPAD_BUTTON_EAST);
    const x = self.padLabel(c.SDL_GAMEPAD_BUTTON_WEST);
    const y = self.padLabel(c.SDL_GAMEPAD_BUTTON_NORTH);
    const line = if (self.session.pending == .name)
        u.fmt("{s} type  {s} delete  Start done", .{ a, b })
    else if (self.map_mode)
        u.fmt("{s} go here  {s} done  {s} hero  L/R zoom", .{ a, b, x })
    else
        u.fmt("{s} press  {s} back  {s} map  L/R zoom  Start more", .{ a, b, y });
    clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .padding = .{ .top = 3 * s } }, .border = .{ .color = clay.rgb(ui.rule), .width = .{ .top = 1 } } });
    u.text(line, ui.dim);
    clay.close();
}

/// Whether to offer the on-screen keyboard for the name.
pub fn wantsLetters(self: *const App) bool {
    return self.input_mode == .pad or !c.SDL_HasKeyboard();
}

// ---------- the frame ----------

pub fn iterate(self: *App) !c.SDL_AppResult {
    if (self.quit) return c.SDL_APP_SUCCESS;
    _ = c.SDL_GetWindowSizeInPixels(self.window, &win_w, &win_h);
    updateInsets(self.window);
    c.Clay_SetLayoutDimensions(pixelSize());
    const want_text = self.wantsText() and (!self.screen_keyboard or self.keyboard_up);
    if (want_text != self.typing) {
        self.typing = want_text;
        _ = if (self.typing) c.SDL_StartTextInput(self.window) else c.SDL_StopTextInput(self.window);
    }

    self.tick();
    // A click is checked against the buttons where it was released.
    const click = self.click;
    self.click = null;
    const activate = self.activate;
    self.activate = null;
    const at = if (click) |k| k.up else self.mouse;
    c.Clay_SetPointerState(.{ .x = at[0], .y = at[1] }, false);
    self.last_frame = c.SDL_GetTicksNS();

    var cmds, const action = self.layout(click, activate);
    var again = false;
    if (action) |a| {
        try self.perform(a);
        again = true;
    }
    if (self.log_to_end or self.controls_to_top) {
        // Lay out to measure, then scroll; the layout below shows it.
        if (again) cmds = self.layout(null, null)[0];
        if (self.log_to_end) {
            const sc = c.Clay_GetScrollContainerData(clay.id("log"));
            if (sc.found) sc.scrollPosition.*.y = @min(0, sc.scrollContainerDimensions.height - sc.contentDimensions.height);
        }
        if (self.controls_to_top) {
            const sc = c.Clay_GetScrollContainerData(clay.id("controls"));
            if (sc.found) sc.scrollPosition.*.y = 0;
        }
        self.log_to_end = false;
        self.controls_to_top = false;
        again = true;
    }
    if (again) {
        // What's under the pointer, among the buttons as they are now.
        _ = self.layout(null, null);
        c.Clay_SetPointerState(.{ .x = self.mouse[0], .y = self.mouse[1] }, false);
        cmds = self.layout(null, null)[0];
    }
    if (self.input_mode == .pad) {
        // Keep the focus on a button that's there, in view.
        if (self.settleFocus()) cmds = self.layout(null, null)[0];
    }

    try errify(c.SDL_SetRenderDrawColor(self.r.sdl, 0, 0, 0, 255));
    try errify(c.SDL_RenderClear(self.r.sdl));
    self.r.commands(cmds, self, drawCustom);
    if (self.script.len > 0) {
        // The frame's laid out: replay the next input on it.
        const step = self.script[0];
        self.script = self.script[1..];
        switch (step) {
            .click => |p| {
                self.input_mode = .pointer;
                self.mouse = p;
                self.pressAt(p);
                try self.release();
            },
            .pad => |b| {
                self.input_mode = .pad;
                try self.padButton(b);
                if (dpadDir(b) != null) self.held = null;
            },
        }
        return c.SDL_APP_CONTINUE;
    }
    if (self.screenshot) |path| {
        const shot = try errify(c.SDL_RenderReadPixels(self.r.sdl, null));
        defer c.SDL_DestroySurface(shot);
        try errify(c.SDL_SavePNG(shot, path.ptr));
        return c.SDL_APP_SUCCESS;
    }
    try errify(c.SDL_RenderPresent(self.r.sdl));
    return c.SDL_APP_CONTINUE;
}

fn drawCustom(self: *App, box: c.SDL_FRect, data: ?*anyopaque) void {
    const custom: *const ui.Custom = @ptrCast(@alignCast(data orelse return));
    switch (custom.*) {
        .map => {
            if (self.session.pending == .name) return self.map.drawTitle(self.r, &self.session, box, @floatFromInt(self.scale()));
            self.map.place(box, @floatFromInt(self.scale()), &self.session.g);
            self.map.draw(self.r, &self.session);
        },
        .sprite => |look| {
            // Whole multiples of the sprite's size, centred.
            const n = @max(1, @floor(@min(box.w, box.h) / atlas.sprite_size));
            const side = n * atlas.sprite_size;
            self.r.sprite(look.sprite, look.color, .{ .x = @round(box.x + (box.w - side) / 2), .y = @round(box.y + (box.h - side) / 2), .w = side, .h = side });
        },
    }
}

// ---------- Clay callbacks ----------

fn measureText(text: c.Clay_StringSlice, config: [*c]c.Clay_TextElementConfig, _: ?*anyopaque) callconv(.c) c.Clay_Dimensions {
    const s: f32 = @floatFromInt(config.*.fontSize);
    return .{ .width = Renderer.textWidth(@intCast(text.length), s), .height = atlas.font.size * s };
}

fn clayError(err: c.Clay_ErrorData) callconv(.c) void {
    app_log.err("clay: {s}", .{err.errorText.chars[0..@intCast(err.errorText.length)]});
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const app_log = std.log.scoped(.app);
const c = @import("c");
const atlas = @import("atlas");
const looks = @import("looks");
const lib = @import("drgnwrrr");
const dw = lib.dw;
const game = lib.game;
const travel = lib.travel;
const Game = lib.Game;
const Session = lib.Session;
const clay = @import("clay.zig");
const ui = @import("ui.zig");
const panel = @import("panel.zig");
const Prefs = @import("Prefs.zig");
const Map = @import("Map.zig");
const Renderer = @import("Renderer.zig");
const errify = @import("main.zig").errify;
