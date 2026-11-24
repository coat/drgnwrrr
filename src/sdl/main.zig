//! drgnwrrr, the native game: SDL3's app callbacks driving App. See App.zig.
//!
//!   drgnwrrr [--save PATH] [--size WxH] [--scale N] [--cmd LINE]... [--click X,Y | --pad BUTTON]... [--screenshot PATH]
//!
//! --save: the save file (default drgnwrrr.sav in SDL's per-user data folder);
//! prefs.txt goes beside it. --scale: screen pixels a font pixel (default:
//! by the window size).
//! --cmd runs a command line at startup, as if typed (the first can be the
//! hero's name). --screenshot saves a frame as a PNG and quits, after
//! replaying each --click (window pixels) and --pad press (south, east,
//! north, west, up, down, left, right, start, back, l1, r1) in order, a
//! frame apart; with SDL_VIDEO_DRIVER=offscreen it needs no display.
const std = @import("std");
const c = @import("c");
const App = @import("App.zig");

const gpa = std.heap.c_allocator;

var app: App = undefined;
/// Set once app.init succeeds.
var live = false;
/// The error that ended the app, if one did.
var failed: ?anyerror = null;
var options: App.Options = .{};

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.args.toSlice(arena);
    var cmds: std.ArrayList([]const u8) = .empty;
    var script: std.ArrayList(App.Step) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, arg, "--save")) {
            options.save = value;
        } else if (std.mem.eql(u8, arg, "--screenshot")) {
            options.screenshot = value;
        } else if (std.mem.eql(u8, arg, "--cmd")) {
            try cmds.append(arena, value);
        } else if (std.mem.eql(u8, arg, "--click")) {
            var it = std.mem.splitScalar(u8, value, ',');
            try script.append(arena, .{ .click = .{ @floatFromInt(try std.fmt.parseInt(i32, it.next() orelse "", 10)), @floatFromInt(try std.fmt.parseInt(i32, it.next() orelse "", 10)) } });
        } else if (std.mem.eql(u8, arg, "--pad")) {
            const buttons = [_]struct { []const u8, c.SDL_GamepadButton }{
                .{ "south", c.SDL_GAMEPAD_BUTTON_SOUTH },      .{ "east", c.SDL_GAMEPAD_BUTTON_EAST },
                .{ "north", c.SDL_GAMEPAD_BUTTON_NORTH },      .{ "west", c.SDL_GAMEPAD_BUTTON_WEST },
                .{ "up", c.SDL_GAMEPAD_BUTTON_DPAD_UP },       .{ "down", c.SDL_GAMEPAD_BUTTON_DPAD_DOWN },
                .{ "left", c.SDL_GAMEPAD_BUTTON_DPAD_LEFT },   .{ "right", c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT },
                .{ "start", c.SDL_GAMEPAD_BUTTON_START },      .{ "back", c.SDL_GAMEPAD_BUTTON_BACK },
                .{ "l1", c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER }, .{ "r1", c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER },
            };
            for (buttons) |b| {
                if (std.mem.eql(u8, value, b[0])) break try script.append(arena, .{ .pad = b[1] });
            } else {
                say("--pad: unknown button {s}\n", .{value});
                return 2;
            }
        } else if (std.mem.eql(u8, arg, "--scale")) {
            options.scale = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, arg, "--size")) {
            var it = std.mem.splitScalar(u8, value, 'x');
            options.size = .{ try std.fmt.parseInt(c_int, it.next() orelse "", 10), try std.fmt.parseInt(c_int, it.next() orelse "", 10) };
        } else {
            say("usage: drgnwrrr [--save PATH] [--size WxH] [--scale N] [--cmd LINE]... [--click X,Y | --pad BUTTON]... [--screenshot PATH]\n", .{});
            return 2;
        }
        i += 1;
    }
    options.cmds = cmds.items;
    options.script = script.items;

    var argv: [0:null]?[*:0]u8 = .{};
    const status = c.SDL_RunApp(0, @ptrCast(&argv), sdlMain, null);
    return if (failed != null) 1 else @truncate(@as(c_uint, @bitCast(status)));
}

comptime {
    // On Android the game is libmain.so, and SDL's Java glue calls SDL_main
    // (with no arguments) instead of main running.
    if (@import("builtin").abi.isAndroid()) @export(&sdlMain, .{ .name = "SDL_main" });
}

fn sdlMain(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return c.SDL_EnterAppMainCallbacks(argc, argv, appInit, appIterate, appEvent, appQuit);
}

// Logging, panics and say go through SDL rather than std's stderr, whose
// std.Io runtime (and the stack-trace machinery behind the default panic
// and segfault handlers) was about 100 KB of the binary.
pub const std_options: std.Options = .{ .logFn = sdlLog, .signal_stack_size = null, .enable_segfault_handler = false };
pub const panic = std.debug.FullPanic(sdlPanic);

/// A line for the player, from the command line: std.debug.print's job.
fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    c.SDL_Log("%s", msg.ptr);
}

fn sdlLog(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, prefix ++ fmt, args, 0) catch return;
    c.SDL_LogMessage(c.SDL_LOG_CATEGORY_APPLICATION, switch (level) {
        .err => c.SDL_LOG_PRIORITY_ERROR,
        .warn => c.SDL_LOG_PRIORITY_WARN,
        .info => c.SDL_LOG_PRIORITY_INFO,
        .debug => c.SDL_LOG_PRIORITY_DEBUG,
    }, "%s", msg.ptr);
}

fn sdlPanic(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    c.SDL_LogCritical(c.SDL_LOG_CATEGORY_APPLICATION, "panic: %.*s", @as(c_int, @intCast(msg.len)), msg.ptr);
    std.c.abort();
}

fn fail(err: anyerror) c.SDL_AppResult {
    failed = err;
    if (err == error.SdlError) std.log.err("SDL: {s}", .{c.SDL_GetError()}) else std.log.err("{t}", .{err});
    return c.SDL_APP_FAILURE;
}

fn appInit(_: [*c]?*anyopaque, _: c_int, _: [*c][*c]u8) callconv(.c) c.SDL_AppResult {
    app.init(gpa, options) catch |err| return fail(err);
    live = true;
    return c.SDL_APP_CONTINUE;
}

fn appIterate(_: ?*anyopaque) callconv(.c) c.SDL_AppResult {
    return app.iterate() catch |err| fail(err);
}

fn appEvent(_: ?*anyopaque, event: [*c]c.SDL_Event) callconv(.c) c.SDL_AppResult {
    return app.event(event) catch |err| fail(err);
}

fn appQuit(_: ?*anyopaque, result: c.SDL_AppResult) callconv(.c) void {
    _ = result;
    if (live) app.deinit();
}

// Taken from
// <https://github.com/castholm/zig-examples/blob/master/breakout/main.zig>
pub inline fn errify(value: anytype) error{SdlError}!switch (@typeInfo(@TypeOf(value))) {
    .bool => void,
    .pointer, .optional => @TypeOf(value.?),
    .int => |info| switch (info.signedness) {
        .signed => @TypeOf(@max(0, value)),
        .unsigned => @TypeOf(value),
    },
    else => @compileError("unerrifiable type: " ++ @typeName(@TypeOf(value))),
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (!value) error.SdlError,
        .pointer, .optional => value orelse error.SdlError,
        .int => |info| switch (info.signedness) {
            .signed => if (value >= 0) @max(0, value) else error.SdlError,
            .unsigned => if (value != 0) value else error.SdlError,
        },
        else => comptime unreachable,
    };
}
