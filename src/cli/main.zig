//! drgnwrrr-cli: the command-line game. You say where to go and how much risk
//! you'll take; the game walks for you and stops for battles and decisions.
//! The game itself is a Session (src/session.zig), shared with the web build;
//! this file reads lines, prints the log, and draws the prompts.
//!
//!   drgnwrrr-cli [--save drgnwrrr.sav] [--new] [--seed N] [--assist] [--no-color]
//!
//! --seed makes a run reproducible: every prompt then counts as 30 idle frames
//! instead of the real time you spent deciding. --assist turns on the later
//! remakes' conveniences (Session.assist).
//!
//! On a terminal, input goes through isocline: history (up/down, saved between
//! runs), ctrl+r search and Tab completion. Piped input is read plainly.
const std = @import("std");
const Io = std.Io;
const lib = @import("drgnwrrr");
const dw = lib.dw;
const game = lib.game;
const travel = lib.travel;
const quests = lib.quests;
const session = lib.session;
const Session = lib.Session;
const term = @import("term.zig");
const ic = @import("isocline.zig");

const deterministic_prompt_frames = 30;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var sav_path: []const u8 = "drgnwrrr.sav";
    var seed: ?u16 = null;
    var fresh = false;
    var no_color = false;
    var assist = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--new")) {
            fresh = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            no_color = true;
        } else if (std.mem.eql(u8, a, "--assist")) {
            assist = true;
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--save")) {
            i += 1;
            sav_path = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--seed")) {
            i += 1;
            seed = try std.fmt.parseInt(u16, args[i], 0);
        } else {
            std.debug.print("usage: drgnwrrr-cli [--save PATH] [--new] [--seed N] [--assist] [--no-color]\n", .{});
            return;
        }
    }

    const env = init.environ_map;
    const tty = try Io.File.stdin().isTty(io) and try Io.File.stdout().isTty(io);
    const color = !no_color and try Io.File.stdout().isTty(io) and env.get("NO_COLOR") == null and
        !std.mem.eql(u8, env.get("TERM") orelse "", "dumb");

    var out_buf: [4096]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    var hl_buf: [1024]u8 = undefined;
    var hl: term.Highlighter = .init(&out_file.interface, color, &hl_buf);
    const out = &hl.writer;
    defer out.flush() catch {};
    var in_buf: [1024]u8 = undefined;
    var in_file: Io.File.Reader = .init(.stdin(), io, &in_buf);

    const new_seed: u16 = seed orelse @truncate(@as(u96, @bitCast(Io.Timestamp.now(io, .real).nanoseconds)));
    var cli: Cli = .{
        .io = io,
        .out = out,
        .in = &in_file.interface,
        .s = .init(init.gpa, new_seed),
        .seed = seed,
        .sav_path = sav_path,
        .tty = tty,
        .color = color,
    };
    defer cli.s.deinit();
    cli.s.assist = assist;
    if (tty) {
        _ = ic.ic_enable_color(color);
        _ = ic.ic_enable_multiline(false);
        ic.ic_set_prompt_marker("", "");
        ic.ic_style_def("ic-prompt", "ansi-default"); // our prompts color themselves
        if (historyPath(arena, io, env)) |p| ic.ic_set_history(p, 500);
        ic.ic_set_default_completer(&completer, &cli);
    }
    if (Io.Dir.cwd().readFileAlloc(io, sav_path, arena, .limited(dw.Sram.size + 1))) |data| {
        if (data.len == dw.Sram.size) @memcpy(&cli.s.sram, data);
    } else |_| {}

    try out.writeAll("drgnwrrr: Dragon Warrior, minus the walking. Type `help` for commands.\n\n");
    if (!fresh and try cli.s.continueGame(out)) {
        if (seed) |s| cli.s.g.rng = .init(s);
    }
    try cli.run();
}

const Cli = struct {
    io: Io,
    out: *Io.Writer,
    in: *Io.Reader,
    s: Session,
    /// --seed: prompts count as a fixed number of frames.
    seed: ?u16,
    sav_path: []const u8,
    line: [256]u8 = undefined,
    tty: bool = false,
    color: bool = false,
    banner_map: u8 = 0,

    fn run(self: *Cli) !void {
        while (true) {
            if (self.s.pending == .over) return;
            const g = &self.s.g;
            if (self.s.pending == .command) {
                if (g.inTown() and self.banner_map != g.at.map) try self.townBanner();
                if (!g.inTown()) self.banner_map = 0;
            }
            var plain: [192]u8 = undefined;
            var styled: [384]u8 = undefined;
            const p = self.prompt(&plain, &styled);
            const read = try self.readLine(p[0], p[1]) orelse return;
            if (!try self.command(read.line, read.frames)) return;
        }
    }

    /// Reads one line, and how many frames it took (the RNG spends one call
    /// per frame, as on the NES). `styled` is the prompt with isocline markup
    /// (used on a terminal); `plain` is printed otherwise.
    fn readLine(self: *Cli, plain: []const u8, styled: []const u8) !?struct { line: []const u8, frames: u32 } {
        try self.out.flush();
        const t0 = Io.Timestamp.now(self.io, .awake);
        var raw: []const u8 = undefined;
        var c_line: ?[*:0]u8 = null;
        defer if (c_line) |p| ic.ic_free(p);
        if (self.tty) {
            var buf: [512]u8 = undefined;
            const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{styled}, 0) catch return error.PromptTooLong;
            c_line = ic.ic_readline(z.ptr) orelse return null;
            raw = std.mem.span(c_line.?);
            // Names and answers stay out of the history. (isocline already
            // drops entries of 0-1 characters, so only remove longer ones.)
            if (self.s.pending != .command and self.s.pending != .battle and raw.len > 1) ic.ic_history_remove_last();
        } else {
            try self.out.writeAll(plain);
            try self.out.flush();
            raw = (try self.in.takeDelimiter('\n')) orelse return null;
        }
        const frames: u32 = if (self.seed != null)
            deterministic_prompt_frames
        else
            dw.framesFromNs(@intCast(@max(0, t0.durationTo(Io.Timestamp.now(self.io, .awake)).nanoseconds)));
        const t = std.mem.trim(u8, raw, " \t\r");
        const n = @min(t.len, self.line.len);
        @memcpy(self.line[0..n], t[0..n]);
        return .{ .line = self.line[0..n], .frames = frames };
    }

    /// False to quit.
    fn command(self: *Cli, line: []const u8, frames: u32) !bool {
        const s = &self.s;
        if (s.pending == .command) {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            const cmd = it.next() orelse "";
            if (eq(cmd, "q") or eq(cmd, "quit")) return false;
            // The CLI's own views, in color. They change nothing, so no frames are spent.
            if (eq(cmd, "help") or eq(cmd, "?")) {
                try self.out.writeAll(help);
                return true;
            } else if (eq(cmd, "status") or eq(cmd, "st")) {
                try self.status();
                return true;
            } else if (eq(cmd, "checklist") or eq(cmd, "quests") or eq(cmd, "cl")) {
                try self.checklist();
                return true;
            } else if (eq(cmd, "look") or eq(cmd, "l")) {
                try self.look();
                return true;
            }
        }
        const was_new = s.pending == .name;
        try s.submit(self.out, line, frames);
        if (was_new and s.pending == .command) {
            if (self.seed) |sd| s.g.rng = .init(sd);
        }
        if (s.sram_dirty) {
            s.sram_dirty = false;
            Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.sav_path, .data = &s.sram }) catch |err| {
                try self.out.print("  Couldn't write {s}: {t}\n", .{ self.sav_path, err });
            };
        }
        return s.pending != .over;
    }

    // ---------- prompts ----------

    fn prompt(self: *Cli, plain: *[192]u8, styled: *[384]u8) [2][]const u8 {
        const s = &self.s;
        if (s.question()) |q| return .{ q, escapeMarkup(q, styled) };
        if (s.pending == .battle) return self.battlePrompt(plain, styled);
        return self.statusPrompt(plain, styled);
    }

    /// "Lv2 HP 6/21 MP 0 44G Brecconary> ". Like the NES status window, it
    /// turns red when HP is low (game.lowHp, ROM $C671).
    fn statusPrompt(self: *Cli, plain: *[192]u8, styled: *[384]u8) [2][]const u8 {
        const g = &self.s.g;
        const h = g.hero();
        const place = if (game.townFor(g.at.map)) |t| t.name else "";
        const p = std.fmt.bufPrint(plain, "Lv{d} HP {d}/{d} MP {d} {d}G {s}> ", .{ h.level, g.hp, h.stats.hp, g.mp, g.gold, place }) catch plain[0..2];
        const st = if (g.lowHp())
            std.fmt.bufPrint(styled, "[ansi-red][b]Lv{d} HP {d}/{d}[/b] MP {d} {d}G [b]{s}[/b]> [/]", .{ h.level, g.hp, h.stats.hp, g.mp, g.gold, place }) catch styled[0..2]
        else
            std.fmt.bufPrint(styled, "[b]Lv{d}[/b] [ansi-green]HP {d}/{d}[/] [ansi-cyan]MP {d}[/] [ansi-yellow]{d}G[/] [b]{s}[/]> ", .{ h.level, g.hp, h.stats.hp, g.mp, g.gold, place }) catch styled[0..2];
        return .{ p, st };
    }

    fn battlePrompt(self: *Cli, plain: *[192]u8, styled: *[384]u8) [2][]const u8 {
        const g = &self.s.g;
        const h = g.hero();
        const p = std.fmt.bufPrint(plain, "  HP {d}/{d} MP {d}/{d}  [f]ight [r]un [h]erb [c]ast <spell> [a]uto > ", .{ g.hp, h.stats.hp, g.mp, h.stats.mp }) catch plain[0..2];
        const st = std.fmt.bufPrint(styled, "  [{s}]HP {d}/{d}[/] [ansi-cyan]MP {d}/{d}[/]  [b]\\[f][/b]ight [b]\\[r][/b]un [b]\\[h][/b]erb [b]\\[c][/b]ast <spell> [b]\\[a][/b]uto > ", .{
            if (g.lowHp()) "b ansi-red" else "ansi-green", g.hp, h.stats.hp, g.mp, h.stats.mp,
        }) catch styled[0..2];
        return .{ p, st };
    }

    /// Brackets escaped, for isocline.
    fn escapeMarkup(text: []const u8, buf: *[384]u8) []const u8 {
        var w: Io.Writer = .fixed(buf);
        for (text) |c| {
            if (c == '[' or c == '\\') w.writeByte('\\') catch {};
            w.writeByte(c) catch {};
        }
        return w.buffered();
    }

    fn townBanner(self: *Cli) !void {
        const g = &self.s.g;
        self.banner_map = g.at.map;
        const t = game.townFor(g.at.map).?;
        try self.out.writeAll("\n");
        try term.styled(self.out, self.color, .bold_blue, t.name);
        try self.out.writeAll(": ");
        if (t.king) try self.out.writeAll("king: `talk` `save` · ");
        var sbuf: [20]dw.NpcService = undefined;
        for (g.services(&sbuf)) |sv| if (sv == .remove_curse) try self.out.writeAll("curse-lifter: `talk` · ");
        if (g.canRestoreMp()) try self.out.writeAll("old man: `mp` · ");
        if (g.innPrice()) |p| try self.out.print("inn: `inn` ({d} G) · ", .{p});
        var cat: [48]game.Offer = undefined;
        if (g.catalog(&cat).len > 0) try self.out.writeAll("`shop` · ");
        try self.out.writeAll("`leave` · `go <place>`\n");
    }

    // ---------- the CLI's own views (color) ----------

    /// An SGR code, or nothing when color is off.
    fn sgr(self: *const Cli, code: []const u8) []const u8 {
        return if (self.color) code else "";
    }

    fn status(self: *Cli) !void {
        const g = &self.s.g;
        const h = g.hero();
        const out = self.out;
        const r = self.sgr("\x1b[0m");
        const dim = self.sgr("\x1b[2m");
        const bold = self.sgr("\x1b[1m");
        const hp_color = self.sgr(if (g.lowHp()) "\x1b[1;31m" else "\x1b[32m");
        try out.print("  {s}{s}{s}, level {s}{d}{s}   {s}HP {d}/{d}{s}  {s}MP {d}/{d}{s}\n", .{
            bold, g.nameSlice(), r, bold, h.level, r, hp_color, g.hp, h.stats.hp, r, self.sgr("\x1b[36m"), g.mp, h.stats.mp, r,
        });
        try out.print("  {s}STR{s} {d}  {s}AGI{s} {d}  {s}ATK{s} {d}  {s}DEF{s} {d}\n", .{ dim, r, h.stats.str, dim, r, h.stats.agi, dim, r, h.attack, dim, r, h.defense });
        try out.print("  {s}Experience{s} {s}{d}{s}  {s}Gold{s} {s}{d}{s}", .{ dim, r, self.sgr("\x1b[35m"), g.xp, r, dim, r, self.sgr("\x1b[33m"), g.gold, r });
        // Only the king (at a save) or Gwaelin's Love tells you how far the next level is.
        if (g.inv.has(.gwaelins_love)) {
            if (dw.xpToNext(g.xp)) |n| try out.print("  {s}({d} XP to the next level){s}", .{ dim, n, r });
        }
        try out.print("\n  {s}Herbs{s} {d}  {s}Keys{s} {d}", .{ dim, r, g.inv.herbs, dim, r, g.inv.keys });
        var buf: [10]session.Owned = undefined;
        for (self.s.owned(&buf)) |o| {
            if (o.item == .herb or o.item == .magic_key) continue;
            try out.print("  {s}", .{game.itemName(o.item)});
            if (o.count > 1) try out.print(" x{d}", .{o.count});
        }
        try out.print("\n  {s}Weapon{s} {s}{s}{s}  {s}Armor{s} {s}{s}{s}  {s}Shield{s} {s}{s}{s}\n", .{
            dim, r, bold, game.equipName(0, g.equip.weapon) orelse "none", r,
            dim, r, bold, game.equipName(7, g.equip.armor) orelse "none", r,
            dim, r, bold, game.equipName(14, g.equip.shield) orelse "none", r,
        });
        if (h.spells.bits != 0) {
            try out.print("  {s}Spells{s}", .{ dim, r });
            inline for (@typeInfo(dw.Spell).@"enum".field_names) |name| {
                const sp = @field(dw.Spell, name);
                if (h.spells.contains(sp)) try out.print(" {s}{s}{s}{s}({d}){s}", .{ self.sgr("\x1b[36m"), name, r, dim, dw.mp_cost[@backingInt(sp)], r });
            }
            try out.writeAll("\n");
        }
        if (g.repel.active()) try out.print("  {s}Repel{s} {d} steps left\n", .{ dim, r, g.repel.counter / 2 });
        try self.where();
    }

    fn checklist(self: *Cli) !void {
        const g = &self.s.g;
        const out = self.out;
        try out.writeAll("  ");
        try term.styled(out, self.color, .bold, "Story checklist");
        try out.writeAll(" (`go <number>` walks there)\n");
        for (quests.objectives, 1..) |o, n| {
            const done = o.done(g);
            const mark = if (done) self.sgr("\x1b[32m") else "";
            try out.print("  {s}{d:>3}. [{s}] {s}{s}", .{ mark, n, if (done) "x" else " ", o.name, self.sgr("\x1b[0m") });
            if (o.optional) try out.writeAll(" (optional)");
            if (!done) {
                try out.print("\n         {s}{s}{s}", .{ self.sgr("\x1b[2m"), o.where, self.sgr("\x1b[0m") });
                if (o.needs.len > 0) try out.print("\n         {s}needs: {s}{s}", .{ self.sgr("\x1b[33m"), o.needs, self.sgr("\x1b[0m") });
            }
            try out.writeAll("\n");
        }
    }

    fn where(self: *Cli) !void {
        const g = &self.s.g;
        if (g.inTown()) return;
        try self.out.print("  {s} ({d}, {d})", .{ dw.map_names[g.at.map], g.at.x, g.at.y });
        if (travel.zoneAt(g.at.map, g.at.x, g.at.y)) |z| try self.out.print(", zone {d}", .{z});
        if (g.at.map == 0x01) {
            const dx = @as(i16, g.at.x) - 43;
            const dy = @as(i16, g.at.y) - 43;
            try self.out.print(", {d} steps from Tantegel", .{@abs(dx) + @abs(dy)});
        }
        try self.out.writeAll(".\n");
    }

    fn look(self: *Cli) !void {
        const g = &self.s.g;
        const out = self.out;
        var dy: i16 = -6;
        while (dy <= 6) : (dy += 1) {
            try out.writeAll("  ");
            var dx: i16 = -15;
            var current: []const u8 = "";
            while (dx <= 15) : (dx += 1) {
                const x: u8 = @truncate(@as(u16, @bitCast(@as(i16, g.at.x) + dx)));
                const y: u8 = @truncate(@as(u16, @bitCast(@as(i16, g.at.y) + dy)));
                const t = g.tileAt(x, y);
                const hero = dx == 0 and dy == 0;
                // Only emit a color code when it changes along the row.
                const code = self.sgr(if (hero) hero_color else tileColor(t));
                if (!std.mem.eql(u8, code, current)) {
                    try out.writeAll(self.sgr("\x1b[0m"));
                    try out.writeAll(code);
                    current = code;
                }
                try out.writeByte(if (hero) '@' else session.tileChar(t));
            }
            try out.print("{s}\n", .{self.sgr("\x1b[0m")});
        }
        try out.writeAll("  ");
        for ([_]dw.Tile{ .grass, .desert, .hills, .mountain, .water, .forest, .swamp, .bridge }, [_][]const u8{ "grass", "desert", "hills", "mountain", "water", "forest", "swamp", "bridge" }) |t, n| {
            try out.print("{s}{c}{s} {s}  ", .{ self.sgr(tileColor(t)), session.tileChar(t), self.sgr("\x1b[0m"), n });
        }
        try out.writeAll("\n  ");
        for ([_]dw.Tile{ .town, .castle, .cave, .stairs_down, .wall, .barrier, .chest, .door }, [_][]const u8{ "town", "castle", "cave", "stairs", "wall", "barrier", "chest", "door" }) |t, n| {
            try out.print("{s}{c}{s} {s}  ", .{ self.sgr(tileColor(t)), session.tileChar(t), self.sgr("\x1b[0m"), n });
        }
        try out.print("{s}@{s} you\n", .{ self.sgr(hero_color), self.sgr("\x1b[0m") });
        const t = g.tileAt(g.at.x, g.at.y);
        try out.print("  Each step here: {d:.1}% chance of a fight.\n", .{travel.encounterChance(g, g.at.map, t, g.at.x, g.at.y) * 100});
        try self.where();
    }
};

const help = session.help ++
    \\  CLI:       quit (q) · Tab completes · ctrl+r searches the history
    \\
;

// ---------- line editing ----------

/// $XDG_DATA_HOME/drgnwrrr/history, or ~/.local/share/drgnwrrr/history.
fn historyPath(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) ?[:0]const u8 {
    const dir = if (env.get("XDG_DATA_HOME")) |d|
        std.fmt.allocPrint(arena, "{s}/drgnwrrr", .{d}) catch return null
    else if (env.get("HOME")) |h|
        std.fmt.allocPrint(arena, "{s}/.local/share/drgnwrrr", .{h}) catch return null
    else
        return null;
    Io.Dir.cwd().createDirPath(io, dir) catch return null;
    return std.fmt.allocPrintSentinel(arena, "{s}/history", .{dir}, 0) catch null;
}

fn completer(cenv: *ic.CompletionEnv, prefix: [*:0]const u8) callconv(.c) void {
    const cli: *Cli = @ptrCast(@alignCast(ic.ic_completion_arg(cenv) orelse return));
    var c: Completer = .{ .cenv = cenv };
    c.complete(&cli.s, std.mem.span(prefix));
}

/// Tab completion that knows the command you're typing: `go bre` -> Brecconary,
/// `cast he` -> heal/healmore (spells you know), `use fa` -> what you carry.
const Completer = struct {
    cenv: *ic.CompletionEnv,
    partial: []const u8 = "",

    fn add(self: *Completer, word: []const u8) void {
        if (!std.ascii.startsWithIgnoreCase(word, self.partial)) return;
        var buf: [64]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{word}, 0) catch return;
        _ = ic.ic_add_completion_prim(self.cenv, z.ptr, null, null, @intCast(self.partial.len), 0);
    }

    fn addAll(self: *Completer, words: []const []const u8) void {
        for (words) |w| self.add(w);
    }

    fn complete(self: *Completer, s: *const Session, input: []const u8) void {
        const space = std.mem.findScalar(u8, input, ' ');
        if (space == null) {
            self.partial = input;
            switch (s.pending) {
                .name, .over => {},
                .confirm_route, .dragonlord => self.addAll(&.{ "yes", "no" }),
                .make_room => {
                    var buf: [10]session.Owned = undefined;
                    for (s.owned(&buf)) |o| self.add(game.itemName(o.item));
                    self.add("leave");
                },
                .battle => self.addAll(&.{ "fight", "run", "herb", "cast", "flute", "auto" }),
                .command => {
                    self.addAll(&.{ "go", "grind", "status", "items", "checklist", "places", "danger", "cast", "use", "look", "auto", "help", "quit", "north", "south", "east", "west" });
                    var abuf: [16]session.Action = undefined;
                    for (s.actions(&abuf)) |a| self.add(@tagName(a));
                    if (game.townFor(s.g.at.map) != null) {
                        var cat_buf: [48]game.Offer = undefined;
                        if (s.g.catalog(&cat_buf).len > 0) self.addAll(&.{ "buy", "sell" });
                    }
                },
            }
            return;
        }
        if (s.pending != .command and s.pending != .battle) return;
        const cmd = input[0..space.?];
        const rest = input[space.? + 1 ..];
        // Item names have spaces, so they complete from the whole rest of the line.
        if (eq(cmd, "use") or eq(cmd, "sell")) {
            self.partial = rest;
            var buf: [10]session.Owned = undefined;
            for (s.owned(&buf)) |o| self.add(game.itemName(o.item));
            return;
        }
        self.partial = rest[if (std.mem.findScalarLast(u8, rest, ' ')) |i| i + 1 else 0..];
        if (eq(cmd, "go")) {
            for (game.towns) |t| self.add(t.name);
            self.addAll(&.{ "safe", "balanced", "fast", "stop=" });
        } else if (eq(cmd, "cast") or eq(cmd, "c")) {
            const h = s.g.hero();
            inline for (@typeInfo(dw.Spell).@"enum".field_names) |f| {
                if (h.spells.contains(@field(dw.Spell, f))) self.add(f);
            }
        } else if (eq(cmd, "grind")) {
            self.addAll(&.{ "auto", "stop=" });
        } else if (eq(cmd, "auto")) {
            self.addAll(&.{ "on", "off" });
        }
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

const hero_color = "\x1b[1;7m";

/// 16-color ANSI, so it works in any terminal.
fn tileColor(t: dw.Tile) []const u8 {
    if (dw.isWater(t)) return "\x1b[34m";
    return switch (t) {
        .grass => "\x1b[32m",
        .forest => "\x1b[1;32m",
        .hills => "\x1b[33m",
        .desert => "\x1b[93m",
        .mountain => "\x1b[37m",
        .swamp => "\x1b[35m",
        .bridge => "\x1b[33m",
        .town, .castle => "\x1b[1;97m",
        .cave, .stairs_down, .stairs_up => "\x1b[1;36m",
        .wall => "\x1b[90m",
        .brick => "\x1b[37m",
        .barrier => "\x1b[1;31m",
        .chest => "\x1b[1;93m",
        .door => "\x1b[36m",
        else => "\x1b[0m",
    };
}

test {
    _ = term;
}

test "the CLI plays from piped input" {
    var sink: Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    var input: Io.Reader = .fixed("Lu\nstatus\nleave\nq\n");
    var cli: Cli = .{
        .io = std.testing.io,
        .out = &sink.writer,
        .in = &input,
        .s = .init(std.testing.allocator, 3),
        .seed = 3,
        .sav_path = "unused",
    };
    defer cli.s.deinit();
    try cli.run();
    const log = sink.written();
    try std.testing.expect(std.mem.find(u8, log, "Your name (1-8 letters): ") != null);
    try std.testing.expect(std.mem.find(u8, log, "Lu, level 1") != null);
    try std.testing.expect(std.mem.find(u8, log, "Tantegel: king") != null);
    try std.testing.expect(std.mem.find(u8, log, "Overworld (43, 43)") != null);
}
