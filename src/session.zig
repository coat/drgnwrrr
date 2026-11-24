//! A game session for any frontend. It takes the CLI's command lines and
//! writes the same log text, but it never blocks: where the CLI stops to ask
//! (a route to confirm, a battle command, what to throw away, the Dragonlord's
//! offer), the session sets `pending` and returns, and the next line answers.
//! A walk or grind interrupted by a battle you fight by hand carries on once
//! the battle ends.
//!
//! No I/O and no libc: frontends pass lines in, read the log from a Writer,
//! and store `sram` themselves when `sram_dirty` is set.
pub const Error = Writer.Error || Allocator.Error;

pub const Pending = union(enum) {
    /// No game yet: the next line is the hero's name.
    name,
    command,
    /// `route` holds a planned walk: yes walks it, no drops it, anything
    /// else drops it and runs as a command.
    confirm_route,
    /// Your battle command (f, r, h, c <spell>, flute, a).
    battle: Fight,
    /// Your bag is full: an item to throw away for this one, or nothing.
    make_room: dw.Item,
    /// The Dragonlord's offer: join him? Then: really?
    dragonlord: enum { first, second },
    /// The game has ended.
    over,
};

pub const Fight = struct { b: battle.Battle, e: Game.Encounter };

/// Where a `go` is headed.
pub const Go = struct {
    target: dw.Warp,
    name: []const u8,
    risk: travel.Risk,
    stop: u8,
    objective: ?quests.Objective = null,
    /// What to do on arriving.
    errand: ?Errand = null,
};

/// A town service at the end of a walk to whoever provides it.
pub const Errand = union(enum) {
    save,
    mp,
    /// The price.
    inn: u8,
    buy: game.Offer,
    sell: dw.Item,
    /// Off the edge of the town.
    leave,

    fn who(self: Errand) []const u8 {
        return switch (self) {
            .save => "the king",
            .mp => "the old man",
            .inn => "the inn",
            .buy, .sell => "the shop",
            .leave => "the edge of town",
        };
    }
};

/// A planned walk waiting for a yes.
pub const Route = struct {
    go: Go,
    plan: travel.Plan,
    /// Magic Keys you have when you set off.
    keys: u8,
};

const Grind = struct {
    spot: [2]dw.Warp,
    fights: u32,
    done: u32 = 0,
    stop: u8,
    start_xp: u16,
    start_gold: u16,
    start_steps: u32,
    /// `grind auto` turned auto-battle on for this grind only: what it was before.
    restore_auto: ?bool,
    /// Still walking to the spot.
    approaching: bool,
    announced: bool = false,
};

/// What carries on once a hand-fought battle ends.
const Job = union(enum) {
    none,
    go: Go,
    grind: Grind,
    dragonlord: struct { here: dw.Warp, form: u2 },
};

/// Buttons a frontend can offer here, beyond the ones that always work
/// (go, grind, status, items, checklist, places, danger, cast, use, auto).
pub const Action = enum { take, search, talk, open, stairs, herb, leave, inn, shop, save, mp };

pub const Owned = struct { item: dw.Item, count: u8 };

pub const Session = struct {
    gpa: Allocator,
    g: Game = undefined,
    pending: Pending = .name,
    sram: [dw.Sram.size]u8 = @splat(0),
    /// The king saved: the frontend should store `sram` now.
    sram_dirty: bool = false,
    auto: bool = false,
    /// The RNG seed for a new game.
    seed: u16 = 0,
    /// The later remakes' conveniences: stepping onto stairs takes them,
    /// ending a move on a chest takes it, and a route with nothing to fear
    /// (no fights, damage, guards or doors) is walked without asking. Off,
    /// the session plays like the NES (and the CLI).
    assist: bool = false,
    route: ?Route = null,
    job: Job = .none,
    /// `stop` in a hand-fought battle: end the job once this fight is over.
    stop_job: bool = false,

    pub fn init(gpa: Allocator, seed: u16) Session {
        return .{ .gpa = gpa, .seed = seed };
    }

    pub fn deinit(self: *Session) void {
        self.dropRoute();
    }

    /// Continue from the save in `sram`. False if there isn't one.
    pub fn continueGame(self: *Session, out: *Writer) Error!bool {
        const g = Game.load(&self.sram, 0) orelse return false;
        self.dropRoute();
        self.job = .none;
        self.stop_job = false;
        self.g = g;
        self.pending = .command;
        try out.print("Welcome back, {s}. You continue at the king.\n", .{g.nameSlice()});
        return true;
    }

    /// Start over: the next line is a name.
    pub fn newGame(self: *Session) void {
        self.dropRoute();
        self.job = .none;
        self.stop_job = false;
        self.pending = .name;
    }

    /// One line from the player. `idle_frames` is how long they took to
    /// decide, spent on the RNG first, one call per frame, as on the NES.
    pub fn submit(self: *Session, out: *Writer, raw: []const u8, idle_frames: u32) Error!void {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (self.pending != .name and self.pending != .over) self.g.idle(idle_frames);
        switch (self.pending) {
            .name => try self.named(out, line),
            .command => try self.command(out, line),
            .confirm_route => try self.answerRoute(out, line),
            .battle => try self.battleCommand(out, line),
            .make_room => |item| try self.answerMakeRoom(out, item, line),
            .dragonlord => |q| try self.answerDragonlord(out, q, line),
            .over => try out.writeAll("  The game is over.\n"),
        }
    }

    /// What a hand-fought battle interrupted that `stop` can end: "go" or
    /// "grind", or null. Frontends offer a Stop button while it isn't null.
    pub fn stoppableJob(self: *const Session) ?[]const u8 {
        if (self.pending != .battle) return null;
        return switch (self.job) {
            .go => "go",
            .grind => "grind",
            .none, .dragonlord => null,
        };
    }

    /// The question a pending prompt asks, for frontends that print one.
    pub fn question(self: *const Session) ?[]const u8 {
        return switch (self.pending) {
            .name => "Your name (1-8 letters): ",
            .confirm_route => "  Walk it? [Y/n] ",
            .make_room => "  Throw something away to make room? (number, or Enter to leave it) ",
            .dragonlord => |q| if (q == .first) "  Join him? [y/n] " else "  \"Really?\" [y/n] ",
            .command, .battle, .over => null,
        };
    }

    fn named(self: *Session, out: *Writer, name: []const u8) Error!void {
        self.g = Game.new(name, self.seed) catch return out.writeAll("  Letters, digits, spaces and ' . , - ? ! ( ) only.\n");
        self.pending = .command;
        try out.print("In the king's chests: 120 gold, a torch, and a magic key for the throne room door. Go and defeat the Dragonlord, {s}!\n", .{self.g.nameSlice()});
    }

    fn dropRoute(self: *Session) void {
        if (self.route) |*r| r.plan.deinit(self.gpa);
        self.route = null;
    }

    // ---------- commands ----------

    fn command(self: *Session, out: *Writer, line: []const u8) Error!void {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse return;
        const rest = std.mem.trim(u8, it.rest(), " ");
        const g = &self.g;
        const town = game.townFor(g.at.map);

        if (eq(cmd, "help") or eq(cmd, "?")) {
            try out.writeAll(help);
        } else if (eq(cmd, "status") or eq(cmd, "st")) {
            try self.status(out);
        } else if (eq(cmd, "auto")) {
            if (rest.len > 0) self.auto = eq(rest, "on");
            try out.print("  Auto-battle is {s}.\n", .{if (self.auto) "on" else "off"});
        } else if (eq(cmd, "danger")) {
            try self.danger(out);
        } else if (eq(cmd, "places")) {
            try self.places(out);
        } else if (eq(cmd, "go")) {
            try self.go(out, rest);
        } else if (eq(cmd, "herb")) {
            try g.useHerb(out);
        } else if (eq(cmd, "cast")) {
            const spell = game.findSpell(rest) orelse return out.writeAll("  Cast what? (heal, healmore, repel, return, radiant, outside)\n");
            if (try g.castField(out, spell)) |st| try self.afterStep(out, st);
        } else if (eq(cmd, "items") or eq(cmd, "i")) {
            try self.listItems(out);
        } else if (eq(cmd, "use")) {
            const item = self.pickItem(rest) orelse return out.writeAll("  Use what? (`items` lists them)\n");
            if (try g.useItem(out, item)) |st| try self.afterStep(out, st);
        } else if (eq(cmd, "checklist") or eq(cmd, "quests") or eq(cmd, "cl")) {
            try self.checklist(out);
        } else if (eq(cmd, "take")) {
            if (try g.take(out)) |item| try self.askMakeRoom(out, item);
        } else if (eq(cmd, "search")) {
            if (try g.searchHere(out)) |item| try self.askMakeRoom(out, item);
        } else if (eq(cmd, "open") or eq(cmd, "door")) {
            _ = try g.openDoor(out);
        } else if (eq(cmd, "talk")) {
            switch (try g.talk(out)) {
                .nothing => {},
                .dragonlord => {
                    try out.writeAll("  The Dragonlord: \"Welcome, I have been waiting. If thou wilt join me, I will give thee half the world.\"\n");
                    self.pending = .{ .dragonlord = .first };
                },
                .ending => try self.ending(out),
            }
        } else if (eq(cmd, "grind")) {
            try self.grind(out, rest);
        } else if (town != null and try self.townCommand(out, town.?, cmd, rest)) {
            // done
        } else if (eq(cmd, "look") or eq(cmd, "l")) {
            try self.look(out);
        } else if (eq(cmd, "stairs")) {
            try self.afterStep(out, try g.stairs(out));
        } else if (dirOf(cmd)) |d| {
            const n = std.fmt.parseInt(u8, rest, 10) catch 1;
            for (0..n) |_| {
                var st = try g.step(out, g.at.x +% d[0], g.at.y +% d[1]);
                if (st == .door) {
                    if (!try g.openDoor(out)) break;
                    st = try g.step(out, g.at.x +% d[0], g.at.y +% d[1]);
                }
                if (st == .blocked) {
                    try out.writeAll("  You can't go that way.\n");
                    break;
                }
                if (st != .moved) {
                    try self.afterStep(out, st);
                    break;
                }
                if (try self.assistHere(out)) break;
            }
            if (self.pending == .command) try self.where(out);
        } else if (town != null) {
            try out.writeAll("  You can't do that here. Type `help`.\n");
        } else {
            try out.writeAll("  Unknown command. Type `help`.\n");
        }
    }

    /// False if `cmd` isn't a town command (or not one this town offers).
    fn townCommand(self: *Session, out: *Writer, t: *const game.Town, cmd: []const u8, rest: []const u8) Error!bool {
        const g = &self.g;
        var cat_buf: [48]game.Offer = undefined;
        const catalog = g.catalog(&cat_buf);
        if (eq(cmd, "leave")) {
            try self.errand(out, .leave);
        } else if (eq(cmd, "inn") and g.innPrice() != null) {
            try self.errand(out, .{ .inn = g.innPrice().? });
        } else if (eq(cmd, "save") and t.king) {
            try self.errand(out, .save);
        } else if (eq(cmd, "mp") and g.canRestoreMp()) {
            try self.errand(out, .mp);
        } else if (eq(cmd, "shop") and catalog.len > 0) {
            try out.print("  You have {d} gold.\n", .{g.gold});
            var shop: ?u8 = null;
            for (catalog, 1..) |o, n| {
                if (shop == null or shop.? != o.shop) {
                    shop = o.shop;
                    try out.print("  {s}:\n", .{shopTitle(o.kind)});
                }
                try out.print("  {d:>4}. {s:<16} {d:>5} G\n", .{ n, o.name(), o.price() });
            }
            try out.writeAll("  `buy <number>` · `sell <number>` (see `items`)\n");
        } else if (eq(cmd, "buy") and catalog.len > 0) {
            const n = std.fmt.parseInt(usize, rest, 10) catch 0;
            if (n == 0 or n > catalog.len) {
                try out.writeAll("  Buy which? (`shop` lists them)\n");
            } else try self.errand(out, .{ .buy = catalog[n - 1] });
        } else if (eq(cmd, "sell") and catalog.len > 0) {
            if (self.pickItem(rest)) |item| try self.errand(out, .{ .sell = item }) else try out.writeAll("  Sell what? (`items` lists them)\n");
        } else return false;
        return true;
    }

    /// Walks to whoever does `e` in this town (the nearest, if several can),
    /// then does it, so every step on the way counts: armor regen, the RNG.
    /// Towns have no fights, so the walk only asks first if it needs a key.
    fn errand(self: *Session, out: *Writer, e: Errand) Error!void {
        const g = &self.g;
        const t = game.townFor(g.at.map).?;
        var npcs: [20]dw.Warp = undefined;
        var n_npcs: usize = 0;
        switch (e) {
            .leave => {},
            .save => {
                npcs[0] = Game.king;
                n_npcs = 1;
            },
            else => {
                var sbuf: [20]dw.NpcService = undefined;
                var wbuf: [20]dw.Warp = undefined;
                const svc = g.services(&sbuf);
                const at = g.serviceSpots(&wbuf);
                // Selling: a tool shop if the town has one, else any shop.
                for ([_]bool{ true, false }) |strict| {
                    for (svc, at, 0..) |s, w, i| if (serves(e, s, i, strict)) {
                        npcs[n_npcs] = w;
                        n_npcs += 1;
                    };
                    if (n_npcs > 0) break;
                }
            },
        }
        var goals: [20 * 8 + 1]dw.Warp = undefined;
        var n_goals: usize = 0;
        if (e == .leave) {
            goals[0] = dw.edgeExit(t.map).?;
            n_goals = 1;
        }
        for (npcs[0..n_npcs]) |w| {
            var buf: [8]dw.Warp = undefined;
            for (quests.standingTiles(g, .{ .at = w, .beside = true, .action = .talk }, &buf)) |s| {
                if (std.meta.eql(s, g.at)) return self.doErrand(out, e);
                goals[n_goals] = s;
                n_goals += 1;
            }
        }
        var best: ?travel.Plan = null;
        var goal: dw.Warp = undefined;
        for (goals[0..n_goals]) |w| {
            var p = (try travel.plan(self.gpa, g, w, .safe)) orelse continue;
            if (best == null or p.cost < best.?.cost) {
                if (best) |*b| b.deinit(self.gpa);
                best = p;
                goal = w;
            } else p.deinit(self.gpa);
        }
        const p = best orelse return out.print("  You can't find a way to {s}.\n", .{e.who()});
        const g_go: Go = .{ .target = goal, .name = e.who(), .risk = .safe, .stop = 0, .errand = e };
        self.dropRoute();
        if (self.doorsToAsk(p) == 0) return self.runGo(out, g_go, p);
        self.route = .{ .go = g_go, .plan = p, .keys = g.inv.keys };
        try self.routeSummary(out, self.route.?);
        self.pending = .confirm_route;
    }

    /// The doors on a walk worth asking about. The throne room's, the first
    /// time, is the only way out, and the king's key is for it.
    fn doorsToAsk(self: *const Session, p: travel.Plan) u32 {
        const g = &self.g;
        const door = Game.throne_room_door;
        if (g.at.map != 0x05 or g.doors.opened(door[0], door[1])) return p.doors;
        for (p.path) |w| if (w.map == 0x05 and w.x == door[0] and w.y == door[1]) return p.doors - 1;
        return p.doors;
    }

    fn serves(e: Errand, s: dw.NpcService, shop: usize, strict: bool) bool {
        return switch (e) {
            .inn => s == .inn,
            .mp => s == .restore_mp,
            .buy => |o| shop == o.shop,
            .sell => s == .items or (!strict and (s == .equipment or s == .keys or s == .fairy_water)),
            .save, .leave => false,
        };
    }

    fn doErrand(self: *Session, out: *Writer, e: Errand) Error!void {
        const g = &self.g;
        switch (e) {
            .save => {
                g.save(&self.sram, 0);
                self.sram_dirty = true;
                try out.writeAll("  The king records your deeds.");
                if (dw.xpToNext(g.xp)) |n| try out.print(" {d} more XP for the next level.", .{n});
                try out.writeAll("\n");
            },
            .mp => try g.restoreMp(out),
            .inn => |price| try g.inn(out, price),
            .buy => |o| try g.buy(out, o),
            .sell => |item| try g.sell(out, item),
            .leave => try self.where(out),
        }
    }

    pub fn shopTitle(kind: dw.NpcService) []const u8 {
        return switch (kind) {
            .equipment => "Weapons and armor",
            .items => "Tools",
            .keys => "Magic Keys",
            .fairy_water => "Fairy Water",
            else => "",
        };
    }

    fn afterStep(self: *Session, out: *Writer, st: Game.Step) Error!void {
        switch (st) {
            .battle => |e| _ = try self.fight(out, e),
            .died => {
                try out.writeAll("  You have died.\n");
                try self.g.die(out);
            },
            .town => |t| try out.print("  You arrive at {s}.\n", .{t.name}),
            .ending => try self.ending(out),
            else => {},
        }
    }

    fn ending(self: *Session, out: *Writer) Error!void {
        const g = &self.g;
        g.ended = true;
        self.job = .none;
        self.pending = .over;
        try out.print("\n  The king: \"Thou hast defeated the Dragonlord! All of Alefgard is thine.\"\n  {s}, level {d}, in {d} steps and {d} battles. THE END.\n", .{ g.nameSlice(), g.hero().level, g.steps, g.battles });
    }

    // ---------- travel ----------

    /// `go <town | number | X Y> [safe|balanced|fast] [stop=N]`. X Y is a tile
    /// on the map you're on. Plans the route and asks before walking it.
    fn go(self: *Session, out: *Writer, args: []const u8) Error!void {
        var risk: travel.Risk = .balanced;
        var stop: u8 = 50;
        var goal: ?dw.Warp = null;
        var goal_name: []const u8 = "";
        var nums: [2]?u8 = .{ null, null };
        var it = std.mem.tokenizeScalar(u8, args, ' ');
        while (it.next()) |tok| {
            if (std.meta.stringToEnum(travel.Risk, tok)) |r| {
                risk = r;
            } else if (std.mem.startsWith(u8, tok, "stop=")) {
                stop = std.fmt.parseInt(u8, tok[5..], 10) catch stop;
            } else if (std.fmt.parseInt(u8, std.mem.trim(u8, tok, ","), 10)) |n| {
                if (nums[0] == null) nums[0] = n else nums[1] = n;
            } else |_| if (game.findTown(tok)) |t| {
                goal = t.entrance;
                goal_name = t.name;
            } else {
                return out.print("  I don't know \"{s}\". Try `places`, or `go X Y`.\n", .{tok});
            }
        }
        if (goal == null and nums[1] != null) {
            const h = dw.map_headers[self.g.at.map];
            if (nums[0].? > h.max_x or nums[1].? > h.max_y) return out.writeAll("  That's off the map.\n");
            goal = .{ .map = self.g.at.map, .x = nums[0].?, .y = nums[1].? };
            goal_name = "there";
        }
        // `go 3`: checklist objective 3. Stand wherever is cheapest to reach.
        var objective: ?quests.Objective = null;
        if (goal == null and nums[0] != null) {
            const n = nums[0].?;
            if (n == 0 or n > quests.objectives.len) return out.print("  The checklist has {d} objectives. (`checklist`)\n", .{quests.objectives.len});
            const o = quests.objectives[n - 1];
            objective = o;
            goal_name = o.name;
            goal = try self.objectiveGoal(out, o, risk) orelse return;
        }
        const target = goal orelse return out.writeAll("  Go where? e.g. `go brecconary safe`, `go 50 50 fast stop=40`\n");
        if (self.g.inTown() and std.meta.eql(game.townFor(self.g.at.map).?.entrance, target)) {
            return out.writeAll("  You're already here.\n");
        }
        const g_go: Go = .{ .target = target, .name = goal_name, .risk = risk, .stop = stop, .objective = objective };
        if (std.meta.eql(self.g.at, target)) {
            if (objective) |o| try self.objectiveHint(out, o);
            return;
        }

        const p = (try travel.plan(self.gpa, &self.g, target, risk)) orelse {
            return out.writeAll("  There's no way to walk there from here.\n");
        };
        self.dropRoute();
        if (self.assist and p.encounters == 0 and p.hp_loss == 0 and p.fixed_battles == 0 and self.doorsToAsk(p) == 0) {
            try out.print("  Walking to {s}: {d} steps.\n", .{ goal_name, p.steps });
            return self.runGo(out, g_go, p);
        }
        self.route = .{ .go = g_go, .plan = p, .keys = self.g.inv.keys };
        try self.routeSummary(out, self.route.?);
        self.pending = .confirm_route;
    }

    fn routeSummary(self: *Session, out: *Writer, r: Route) Error!void {
        const p = r.plan;
        try out.print("  Route to {s} ({t}): {d} steps, ~{d:.1} fights, ~{d:.0} HP expected loss (you have {d}), {d:.1}% death risk", .{
            r.go.name, r.go.risk, p.steps, p.encounters, p.hp_loss, self.g.hp, p.death * 100,
        });
        if (p.worst_zone) |z| try out.print(", up to zone {d}", .{z});
        if (p.doors > 0) try out.print(", {d} door{s} (you'll have {d} key{s})", .{ p.doors, if (p.doors == 1) "" else "s", r.keys, if (r.keys == 1) "" else "s" });
        if (p.via_len > 0) {
            try out.writeAll(", via");
            for (p.via[0..p.via_len], 0..) |m, k| try out.print("{s} {s}", .{ if (k == 0) "" else ",", dw.map_names[m] });
        }
        try out.writeAll(".\n");
        if (p.doors > r.keys) try out.writeAll("  Warning: not enough Magic Keys for every door.\n");
        if (p.fixed_battles > 0) try out.print("  Warning: {d} guarded tile(s) on the way (a fixed battle).\n", .{p.fixed_battles});
    }

    /// The cheapest tile to stand on for an objective, or null (after saying why).
    fn objectiveGoal(self: *Session, out: *Writer, o: quests.Objective, risk: travel.Risk) Error!?dw.Warp {
        var buf: [8]dw.Warp = undefined;
        var best: ?f32 = null;
        var goal: ?dw.Warp = null;
        for (quests.standingTiles(&self.g, o.spot(&self.g), &buf)) |w| {
            var p = (try travel.plan(self.gpa, &self.g, w, risk)) orelse continue;
            defer p.deinit(self.gpa);
            if (best == null or p.cost < best.?) {
                best = p.cost;
                goal = w;
            }
        }
        if (goal != null) return goal;
        // Would a key get you there? Then a locked door is what's in the way.
        var keyed = self.g;
        keyed.inv.keys = 6;
        for (quests.standingTiles(&self.g, o.spot(&self.g), &buf)) |w| {
            var p = (try travel.plan(self.gpa, &keyed, w, risk)) orelse continue;
            p.deinit(self.gpa);
            try out.print("  A locked door stands in the way to {s}. You need a Magic Key (Tantegel, Rimuldar and Cantlin sell them).\n", .{o.name});
            return null;
        }
        try out.print("  There's no way to walk to {s} from here yet.{s}\n", .{ o.name, if (o.needs.len > 0) " Check what it needs in `checklist`." else "" });
        return null;
    }

    fn answerRoute(self: *Session, out: *Writer, line: []const u8) Error!void {
        self.pending = .command;
        var r = self.route.?;
        self.route = null;
        // `y stop=N` walks it with a new HP threshold; the route doesn't depend on it.
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const first = it.next() orelse "";
        if (first.len == 0 or first[0] == 'y' or first[0] == 'Y' or eq(first, "walk")) {
            while (it.next()) |tok| if (std.mem.startsWith(u8, tok, "stop=")) {
                r.go.stop = std.fmt.parseInt(u8, tok[5..], 10) catch r.go.stop;
            };
            return self.runGo(out, r.go, r.plan);
        }
        r.plan.deinit(self.gpa);
        if (line[0] != 'n' and line[0] != 'N' and !eq(line, "cancel")) try self.command(out, line);
    }

    /// Walks to `go.target`, replanning after each fight. `first` is a plan
    /// already made from here (it's freed).
    fn runGo(self: *Session, out: *Writer, go_: Go, first: ?travel.Plan) Error!void {
        var plan_now = first;
        while (true) {
            if (std.meta.eql(self.g.at, go_.target)) {
                if (plan_now) |*p| p.deinit(self.gpa);
                if (go_.objective) |o| try self.objectiveHint(out, o);
                if (go_.errand) |e| try self.doErrand(out, e);
                return;
            }
            var p = plan_now orelse (try travel.plan(self.gpa, &self.g, go_.target, go_.risk)) orelse {
                return out.writeAll("  There's no way to walk there from here.\n");
            };
            plan_now = null;
            defer p.deinit(self.gpa);
            // Whether the last move is a step on one map (not stairs or an entrance into it).
            const before_last = if (p.path.len >= 2) p.path[p.path.len - 2].map else self.g.at.map;
            const steps_onto = p.path.len > 0 and before_last == go_.target.map;
            self.job = .{ .go = go_ };
            const end = try self.walk(out, p.path, go_.stop);
            if (end != .suspended) self.job = .none;
            switch (end) {
                .arrived => {
                    if (steps_onto) _ = try self.assistHere(out);
                    if (go_.errand) |e| return self.doErrand(out, e);
                    if (go_.objective) |o| if (self.pending == .command and !o.done(&self.g)) try self.objectiveHint(out, o);
                    return;
                },
                .stopped => return out.writeAll("  You stop. `go` again to carry on.\n"),
                .replan => try out.print("  On to {s}...\n", .{go_.name}),
                .ended, .suspended => return,
            }
        }
    }

    /// With `assist`, after stepping onto the tile you're on: take the chest
    /// or the stairs. True if it did either (a walk of several steps stops).
    fn assistHere(self: *Session, out: *Writer) Error!bool {
        if (!self.assist) return false;
        const g = &self.g;
        switch (g.tileAt(g.at.x, g.at.y)) {
            .chest => if (try g.take(out)) |item| try self.askMakeRoom(out, item),
            .stairs_up, .stairs_down => try self.afterStep(out, try g.stairs(out)),
            else => return false,
        }
        return true;
    }

    fn objectiveHint(self: *Session, out: *Writer, o: quests.Objective) Error!void {
        const spot = o.spot(&self.g);
        if (spot.action == .fight)
            return out.print("  You're at {s}: a guardian blocks the next tile. `{s}` to fight it.\n", .{ o.name, spot.toward });
        try out.print("  You're at {s}: {s}\n", .{ o.name, switch (spot.action) {
            .fight => unreachable,
            .search => "`search` here.",
            .take => "`take` the chest.",
            .talk => "`talk`.",
            .use_rainbow_drop => "`use rainbow drop`.",
            .arrive => "you're there.",
        } });
    }

    const WalkEnd = enum { arrived, stopped, replan, ended, suspended };

    fn walk(self: *Session, out: *Writer, path: []const dw.Warp, stop: u8) Error!WalkEnd {
        const g = &self.g;
        for (path, 0..) |w, k| {
            // A stairs tile can be on a town's edge too (Garinham's grave), so
            // take the stairs only when they go where the path does.
            const stairs_to = dw.stairs(game.maps, g.mapState(), g.at.x, g.at.y);
            var st = if (w.map == g.at.map and adjacent(g.at, w))
                try g.step(out, w.x, w.y)
            else if (stairs_to != null and std.meta.eql(stairs_to.?, w))
                try g.stairs(out)
            else if (g.at.map != 0x01 and dw.edgeExit(g.at.map) != null and std.meta.eql(w, dw.edgeExit(g.at.map).?))
                try self.stepOffEdge(out)
            else
                try self.stepIntoEntrance(out, w);
            if (st == .door) {
                if (!try g.openDoor(out)) return .stopped;
                st = try g.step(out, w.x, w.y);
            }
            switch (st) {
                .moved, .entered => {},
                .door => return .stopped,
                .blocked => {
                    try out.writeAll("  The way is blocked.\n");
                    return .stopped;
                },
                .town => |t| {
                    // A town on the way (Garinham for the grave, say) isn't the end.
                    if (k + 1 < path.len) continue;
                    try out.print("  You arrive at {s}.\n", .{t.name});
                    return .arrived;
                },
                .unsupported => return .stopped,
                .ending => {
                    try self.ending(out);
                    return .ended;
                },
                .died => {
                    try out.writeAll("  The terrain drains the last of your HP. You have died.\n");
                    try g.die(out);
                    return .stopped;
                },
                .battle => |e| return switch (try self.fight(out, e)) {
                    .suspended => .suspended,
                    .done => |o| try self.afterWalkBattle(out, e, o, stop),
                },
            }
        }
        return .arrived;
    }

    fn afterWalkBattle(self: *Session, out: *Writer, e: Game.Encounter, o: battle.Outcome, stop: u8) Error!WalkEnd {
        if (o == .died) return .stopped;
        if (o == .ran and e.fixed) return .stopped;
        const max = self.g.hero().stats.hp;
        if (@as(u16, self.g.hp) * 100 < @as(u16, stop) * max) {
            try out.print("  HP {d}/{d} is under your stop line ({d}%).\n", .{ self.g.hp, max, stop });
            return .stopped;
        }
        return .replan; // HP changed, so the safest way on may have too
    }

    /// Walk off the edge of a town or cave, toward the first side that's open.
    fn stepOffEdge(self: *Session, out: *Writer) Error!Game.Step {
        const g = &self.g;
        const h = dw.map_headers[g.at.map];
        for (dirs) |d| {
            const x = g.at.x +% d[0];
            const y = g.at.y +% d[1];
            if ((x > h.max_x or y > h.max_y) and dw.walkable(g.tileAt(x, y))) return g.step(out, x, y);
        }
        return .blocked;
    }

    fn stepIntoEntrance(self: *Session, out: *Writer, target: dw.Warp) Error!Game.Step {
        const g = &self.g;
        for (dirs) |d| {
            const at: dw.Warp = .{ .map = g.at.map, .x = g.at.x +% d[0], .y = g.at.y +% d[1] };
            if (dw.warpForward(at)) |w| if (std.meta.eql(w, target)) return g.step(out, at.x, at.y);
        }
        return .blocked;
    }

    // ---------- grinding ----------

    fn grind(self: *Session, out: *Writer, args: []const u8) Error!void {
        const g = &self.g;
        var fights: u32 = 10;
        var stop: u8 = 40;
        var auto_flag = false;
        var it = std.mem.tokenizeScalar(u8, args, ' ');
        while (it.next()) |tok| {
            if (eq(tok, "auto")) {
                auto_flag = true;
            } else if (std.mem.startsWith(u8, tok, "stop=")) {
                stop = std.fmt.parseInt(u8, tok[5..], 10) catch stop;
            } else fights = std.fmt.parseInt(u32, tok, 10) catch fights;
        }
        // From a town, look around its gate; you walk out to it.
        var outside = g.*;
        if (outside.inTown()) {
            var sink: Writer.Discarding = .init(&.{});
            _ = outside.leaveTown(&sink.writer) catch unreachable;
        }
        const spot = travel.grindSpot(&outside) orelse return out.writeAll("  There's nowhere to fight around here.\n");
        // `grind auto` is auto for this grind only. Switching it on mid-fight
        // (`a`) without the flag keeps it on afterwards, like `auto on`.
        const restore: ?bool = if (auto_flag) self.auto else null;
        if (auto_flag) self.auto = true;
        try self.runGrind(out, .{
            .spot = spot,
            .fights = fights,
            .stop = stop,
            .start_xp = g.xp,
            .start_gold = g.gold,
            .start_steps = g.steps,
            .restore_auto = restore,
            .approaching = !std.meta.eql(g.at, spot[0]) and !std.meta.eql(g.at, spot[1]),
        });
    }

    fn runGrind(self: *Session, out: *Writer, start: Grind) Error!void {
        const g = &self.g;
        var gr = start;
        while (gr.approaching) {
            if (std.meta.eql(g.at, gr.spot[0]) or std.meta.eql(g.at, gr.spot[1])) break;
            var p = (try travel.plan(self.gpa, g, gr.spot[0], .balanced)) orelse {
                try out.writeAll("  Can't reach a good spot.\n");
                return self.endGrind(gr);
            };
            defer p.deinit(self.gpa);
            self.job = .{ .grind = gr };
            const end = try self.walk(out, p.path, gr.stop);
            if (end != .suspended) self.job = .none;
            switch (end) {
                .arrived, .replan => {},
                .stopped, .ended => return self.endGrind(gr),
                .suspended => return,
            }
        }
        gr.approaching = false;
        if (!gr.announced) {
            gr.announced = true;
            try out.print("  Fighting around ({d}, {d}) in zone {d}: up to {d} fights, stopping under {d}% HP{s}.\n", .{ g.at.x, g.at.y, travel.zoneAt(g.at.map, g.at.x, g.at.y).?, gr.fights, gr.stop, if (self.auto) ", auto-battle" else "" });
        }
        while (gr.done < gr.fights) {
            const next = if (std.meta.eql(g.at, gr.spot[0])) gr.spot[1] else gr.spot[0];
            const st = try g.step(out, next.x, next.y);
            switch (st) {
                .moved => continue,
                .battle => |e| {
                    gr.done += 1;
                    self.job = .{ .grind = gr };
                    switch (try self.fight(out, e)) {
                        .suspended => return,
                        .done => |o| {
                            self.job = .none;
                            if (self.grindStopAt(o, gr.stop)) |why| return self.grindSummary(out, gr, why);
                        },
                    }
                },
                else => {
                    try self.afterStep(out, st);
                    return self.grindSummary(out, gr, "interrupted");
                },
            }
        }
        try self.grindSummary(out, gr, "done");
    }

    /// Why a grind ends after a battle, if it does.
    fn grindStopAt(self: *Session, o: battle.Outcome, stop: u8) ?[]const u8 {
        if (o == .died) return "you died";
        const max = self.g.hero().stats.hp;
        if (@as(u16, self.g.hp) * 100 < @as(u16, stop) * max) return "HP under the stop line";
        return null;
    }

    fn endGrind(self: *Session, gr: Grind) void {
        if (gr.restore_auto) |a| self.auto = a;
    }

    fn grindSummary(self: *Session, out: *Writer, gr: Grind, why: []const u8) Error!void {
        const g = &self.g;
        self.endGrind(gr);
        const gold_delta = @as(i32, g.gold) - gr.start_gold;
        try out.print("  Grinding over ({s}): {d} fights in {d} steps, +{d} XP, {s}{d} gold. HP {d}/{d}, MP {d}.\n", .{
            why, gr.done, g.steps - gr.start_steps, g.xp - gr.start_xp, if (gold_delta >= 0) "+" else "", gold_delta, g.hp, g.hero().stats.hp, g.mp,
        });
    }

    // ---------- battle ----------

    const FightEnd = union(enum) { done: battle.Outcome, suspended };

    /// Auto-battle settles it now; otherwise the battle waits for commands.
    fn fight(self: *Session, out: *Writer, e: Game.Encounter) Error!FightEnd {
        if (self.auto) return .{ .done = try self.autoFight(out, e) };
        try out.writeAll("\n");
        var b = try battle.Battle.start(&self.g, out, e.id, e.fixed);
        try advance(&b, &self.g, out);
        if (b.outcome) |o| {
            try self.settle(out, e, o);
            return .{ .done = o };
        }
        self.pending = .{ .battle = .{ .b = b, .e = e } };
        return .suspended;
    }

    /// Until it's your turn to pick a command, or the battle is over.
    fn advance(b: *battle.Battle, g: *Game, out: *Writer) Writer.Error!void {
        while (b.outcome == null) if (try b.heroTurn(g, out)) return;
    }

    fn settle(self: *Session, out: *Writer, e: Game.Encounter, o: battle.Outcome) Error!void {
        switch (o) {
            .died => try self.g.die(out),
            .ran => if (e.fixed) {
                self.g.at = e.back; // $E8A4: running from a guardian puts you back a tile
            },
            .won, .enemy_fled => {},
        }
    }

    fn battleCommand(self: *Session, out: *Writer, line: []const u8) Error!void {
        const f = &self.pending.battle;
        const g = &self.g;
        if (eq(line, "stop")) {
            const what = self.stoppableJob() orelse return out.writeAll("  There's nothing to stop; this is just a fight.\n");
            self.stop_job = true;
            return out.print("  You'll stop {s} after this fight.\n", .{if (eq(what, "go")) "walking" else "grinding"});
        } else if (eq(line, "a") or eq(line, "auto")) {
            // Hand the rest of this fight (and later ones) to auto-battle.
            self.auto = true;
            try out.writeAll("  Auto-battle on. (`auto off` turns it off.)\n");
            while (f.b.outcome == null) {
                if (!try f.b.heroTurn(g, out)) continue;
                _ = try f.b.act(g, out, battle.autoCommand(g, &f.b));
            }
        } else {
            const cmd = parseBattle(line) orelse {
                return out.writeAll("  f, r, h, a(uto), flute, stop, or c heal / c hurt / c sleep / c stopspell / c healmore / c hurtmore\n");
            };
            _ = try f.b.act(g, out, cmd);
            try advance(&f.b, g, out);
        }
        const o = f.b.outcome orelse return;
        const e = f.e;
        self.pending = .command;
        try self.settle(out, e, o);
        try self.resumeJob(out, e, o);
    }

    /// Carry on with what the battle interrupted.
    fn resumeJob(self: *Session, out: *Writer, e: Game.Encounter, o: battle.Outcome) Error!void {
        const job = self.job;
        const stop = self.stop_job;
        self.job = .none;
        self.stop_job = false;
        if (stop and o != .died) switch (job) {
            .go => return out.writeAll("  You stop. `go` again to carry on.\n"),
            .grind => |gr| return if (gr.approaching) {
                self.endGrind(gr);
                try out.writeAll("  You stop.\n");
            } else self.grindSummary(out, gr, "stopped"),
            else => {},
        };
        switch (job) {
            .none => {},
            .go => |go_| switch (try self.afterWalkBattle(out, e, o, go_.stop)) {
                .replan => {
                    try out.print("  On to {s}...\n", .{go_.name});
                    try self.runGo(out, go_, null);
                },
                else => try out.writeAll("  You stop. `go` again to carry on.\n"),
            },
            .grind => |gr| if (gr.approaching) {
                if (try self.afterWalkBattle(out, e, o, gr.stop) == .replan) try self.runGrind(out, gr) else self.endGrind(gr);
            } else if (self.grindStopAt(o, gr.stop)) |why| {
                try self.grindSummary(out, gr, why);
            } else try self.runGrind(out, gr),
            .dragonlord => |d| try self.dragonlordAfter(out, d.here, d.form, o),
        }
    }

    /// Auto-battle: the same battle, summarized in one line.
    fn autoFight(self: *Session, out: *Writer, e: Game.Encounter) Error!battle.Outcome {
        const g = &self.g;
        const level = g.hero().level;
        const xp = g.xp;
        const herbs = g.inv.herbs;
        const mp = g.mp;
        var sink: Writer.Discarding = .init(&.{});
        const b = try battle.runBattle(g, &sink.writer, e.id, e.fixed, battle.autoCommand);
        var nb: [24]u8 = undefined;
        const h = g.hero();
        try out.print("  {s}: {s} in {d} round{s}, -{d} HP", .{ b.name(&nb), @tagName(b.outcome.?), b.rounds, if (b.rounds == 1) "" else "s", b.hp_lost });
        if (herbs > g.inv.herbs) try out.print(", {d} herb{s} used", .{ herbs - g.inv.herbs, if (herbs - g.inv.herbs == 1) "" else "s" });
        if (mp > g.mp) try out.print(", {d} MP spent", .{mp - g.mp});
        if (b.outcome.? == .won) try out.print(", +{d} XP +{d} G", .{ g.xp - xp, b.gold });
        try out.print(". HP {d}/{d} MP {d}.\n", .{ g.hp, h.stats.hp, g.mp });
        if (h.level != level) try out.print("  Level up! Now level {d}: HP {d}, MP {d}, STR {d}, AGI {d}.\n", .{ h.level, h.stats.hp, h.stats.mp, h.stats.str, h.stats.agi });
        if (b.outcome.? == .died) try out.writeAll("  You have died.\n");
        try self.settle(out, e, b.outcome.?);
        return b.outcome.?;
    }

    fn parseBattle(line: []const u8) ?battle.Command {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const c = it.next() orelse return .fight; // Enter = fight
        if (eq(c, "f") or eq(c, "fight")) return .fight;
        if (eq(c, "r") or eq(c, "run")) return .run;
        if (eq(c, "h") or eq(c, "herb")) return .herb;
        if (eq(c, "flute")) return .flute;
        if (eq(c, "c") or eq(c, "cast")) return .{ .cast = game.findSpell(it.next() orelse return null) orelse return null };
        return null;
    }

    // ---------- the Dragonlord ----------

    fn answerDragonlord(self: *Session, out: *Writer, q: @FieldType(Pending, "dragonlord"), line: []const u8) Error!void {
        const yes = line.len > 0 and (line[0] == 'y' or line[0] == 'Y');
        const no = line.len > 0 and (line[0] == 'n' or line[0] == 'N');
        if (!yes and !no) return out.writeAll("  Yes or no?\n");
        if (q == .first and yes) {
            self.pending = .{ .dragonlord = .second };
            return;
        }
        self.pending = .command;
        const g = &self.g;
        if (dw.dragonlordOffer(q == .second, yes) == .bad_ending) {
            var xp = g.xp;
            var gold = g.gold;
            var equip: u8 = @bitCast(g.equip);
            dw.badEnding(&xp, &gold, &g.inv, &equip, &g.cf, &g.df, &g.e4);
            self.pending = .over;
            return out.writeAll("\n  \"Then half of this world is thine.\" The world fell into darkness, and you were never heard from again.\n  THE END. (Your saved game is untouched.)\n");
        }
        try out.writeAll("  \"Then thou must die!\"\n");
        try self.dragonlordForm(out, g.at, 1);
    }

    fn dragonlordForm(self: *Session, out: *Writer, here: dw.Warp, form: u2) Error!void {
        const e: Game.Encounter = .{ .id = if (form == 1) .dragonlord1 else .dragonlord2, .fixed = true, .back = here };
        self.job = .{ .dragonlord = .{ .here = here, .form = form } };
        switch (try self.fight(out, e)) {
            .suspended => {},
            .done => |o| {
                self.job = .none;
                try self.dragonlordAfter(out, here, form, o);
            },
        }
    }

    fn dragonlordAfter(self: *Session, out: *Writer, here: dw.Warp, form: u2, o: battle.Outcome) Error!void {
        if (o != .won) return;
        if (form == 1) {
            try out.writeAll("\n  The Dragonlord revealed his true self!\n");
            return self.dragonlordForm(out, here, 2);
        }
        // $E9EA: $E0 cleared, the flag set, HP and MP full, and out to the
        // overworld at Charlock's entrance (warp entry 6's source, via $D9E2).
        const g = &self.g;
        const h = g.hero();
        const after = dw.dragonlordDefeated(.dragonlord2, &g.e0, &g.e4, &g.hp, &g.mp, h.stats.hp, h.stats.mp).?;
        _ = try g.arrive(out, after.victory);
        try out.writeAll("  Thou hast brought back the light! You stand outside Charlock. Return to Tantegel.\n");
    }

    // ---------- items ----------

    fn askMakeRoom(self: *Session, out: *Writer, item: dw.Item) Error!void {
        try self.listItems(out);
        self.pending = .{ .make_room = item };
    }

    fn answerMakeRoom(self: *Session, out: *Writer, item: dw.Item, line: []const u8) Error!void {
        self.pending = .command;
        const drop = if (line.len == 0 or eq(line, "leave")) null else self.pickItem(line);
        try self.g.makeRoom(out, item, drop);
    }

    /// What you carry, in ITEM-menu order, duplicates counted.
    pub fn owned(self: *const Session, buf: *[10]Owned) []Owned {
        const g = &self.g;
        var menu: [10]dw.Item = undefined;
        var n: usize = 0;
        for (g.inv.menu(&menu)) |it| {
            const count: u8 = switch (it) {
                .herb => g.inv.herbs,
                .magic_key => g.inv.keys,
                else => 1,
            };
            const seen = for (buf[0..n]) |*o| {
                if (o.item == it) break o;
            } else null;
            if (seen) |o| {
                o.count += count;
            } else {
                buf[n] = .{ .item = it, .count = count };
                n += 1;
            }
        }
        return buf[0..n];
    }

    /// An item by its `items` number or by name.
    pub fn pickItem(self: *const Session, arg: []const u8) ?dw.Item {
        var buf: [10]Owned = undefined;
        const list = self.owned(&buf);
        if (std.fmt.parseInt(usize, arg, 10)) |n| {
            return if (n >= 1 and n <= list.len) list[n - 1].item else null;
        } else |_| return game.findItem(arg);
    }

    pub fn worn(self: *const Session, item: dw.Item) bool {
        const cf = self.g.cf;
        return switch (item) {
            .dragons_scale => cf & dw.Worn.dragons_scale != 0,
            .fighters_ring => cf & dw.Worn.fighters_ring != 0,
            .cursed_belt => cf & dw.Worn.cursed_belt != 0,
            .death_necklace => cf & dw.Worn.death_necklace != 0,
            else => false,
        };
    }

    /// What a shop here pays for `item`: null if you can't sell it.
    pub fn sellPrice(self: *const Session, item: dw.Item) ?u16 {
        const price = dw.itemPrice(item);
        if (price == 0) return null;
        if (!dw.droppable(item, self.g.cf) and (item == .cursed_belt or item == .death_necklace)) return null;
        return price / 2;
    }

    fn listItems(self: *Session, out: *Writer) Error!void {
        const g = &self.g;
        var buf: [10]Owned = undefined;
        const list = self.owned(&buf);
        var cat_buf: [48]game.Offer = undefined;
        const shop = g.catalog(&cat_buf).len > 0;
        if (list.len == 0) try out.writeAll("  You carry nothing.\n");
        for (list, 1..) |o, n| {
            try out.print("  {d:>2}. {s}", .{ n, game.itemName(o.item) });
            if (o.count > 1) try out.print(" x{d}", .{o.count});
            if (self.worn(o.item)) try out.writeAll(" (worn)");
            if (shop) {
                if (self.sellPrice(o.item)) |p| {
                    try out.print("  - sells for {d} G", .{p});
                } else if (dw.itemPrice(o.item) == 0) {
                    try out.writeAll("  - can't be sold");
                } else try out.writeAll("  - cursed, can't be sold");
            }
            try out.writeAll("\n");
        }
        try out.print("  Equipped: {s}, {s}, {s}.", .{
            game.equipName(0, g.equip.weapon) orelse "no weapon", game.equipName(7, g.equip.armor) orelse "no armor", game.equipName(14, g.equip.shield) orelse "no shield",
        });
        try out.writeAll(if (shop) " (Equipment is traded in when you buy, not sold.)\n  `sell <number>` · `use <number>`\n" else "\n  `use <number>`\n");
    }

    // ---------- what's here ----------

    /// The context buttons for where you stand (nothing while a prompt is pending).
    pub fn actions(self: *const Session, buf: *[16]Action) []Action {
        if (self.pending != .command) return buf[0..0];
        const g = &self.g;
        var n: usize = 0;
        const add = struct {
            fn f(b: *[16]Action, i: *usize, a: Action) void {
                b[i.*] = a;
                i.* += 1;
            }
        }.f;
        const here = g.tileAt(g.at.x, g.at.y);
        if (here == .chest) add(buf, &n, .take);
        add(buf, &n, .search);
        if (self.canTalk()) add(buf, &n, .talk);
        for (dirs) |d| if (g.tileAt(g.at.x +% d[0], g.at.y +% d[1]) == .door) {
            add(buf, &n, .open);
            break;
        };
        if (here == .stairs_up or here == .stairs_down) add(buf, &n, .stairs);
        if (g.inv.herbs > 0) add(buf, &n, .herb);
        if (game.townFor(g.at.map)) |t| {
            add(buf, &n, .leave);
            if (g.innPrice() != null) add(buf, &n, .inn);
            var cat: [48]game.Offer = undefined;
            if (g.catalog(&cat).len > 0) add(buf, &n, .shop);
            if (t.king) add(buf, &n, .save);
            if (g.canRestoreMp()) add(buf, &n, .mp);
        }
        return buf[0..n];
    }

    /// Whether TALK would do something here (see Game.talk).
    pub fn canTalk(self: *const Session) bool {
        const g = &self.g;
        for (dirs) |d| if (g.tileAt(g.at.x +% d[0], g.at.y +% d[1]) == .princess) return true;
        if (g.at.map == 0x04 or g.at.map == 0x05) {
            if (g.e4 & dw.Story.dragonlord_beaten != 0 or g.df & dw.Quest.carrying_princess != 0) return true;
        }
        var sbuf: [20]dw.NpcService = undefined;
        // The curse-lifter answers anyone, but only does something for the cursed.
        if (dw.cursed(g.cf)) for (g.services(&sbuf)) |sv| if (sv == .remove_curse) return true;
        var nbuf: [20]dw.Npc = undefined;
        for (dw.npcs(game.maps, g.at.map, g.df, &nbuf)) |npc| {
            if (npc.moves or !game.nearNpc(g, npc)) continue;
            switch (dw.npcService(npc.dialogue, g.e4)) {
                .staff_shrine, .rainbow_shrine, .dragonlord => return true,
                else => {},
            }
        }
        return false;
    }

    // ---------- information ----------

    fn status(self: *Session, out: *Writer) Error!void {
        const g = &self.g;
        const h = g.hero();
        try out.print("  {s}, level {d}   HP {d}/{d}  MP {d}/{d}\n", .{ g.nameSlice(), h.level, g.hp, h.stats.hp, g.mp, h.stats.mp });
        try out.print("  STR {d}  AGI {d}  ATK {d}  DEF {d}\n", .{ h.stats.str, h.stats.agi, h.attack, h.defense });
        try out.print("  Experience {d}  Gold {d}", .{ g.xp, g.gold });
        // Only the king (at a save) or Gwaelin's Love tells you how far the next level is.
        if (g.inv.has(.gwaelins_love)) {
            if (dw.xpToNext(g.xp)) |n| try out.print("  ({d} XP to the next level)", .{n});
        }
        try out.print("\n  Herbs {d}  Keys {d}", .{ g.inv.herbs, g.inv.keys });
        var buf: [10]Owned = undefined;
        for (self.owned(&buf)) |o| {
            if (o.item == .herb or o.item == .magic_key) continue;
            try out.print("  {s}", .{game.itemName(o.item)});
            if (o.count > 1) try out.print(" x{d}", .{o.count});
        }
        try out.print("\n  Weapon {s}  Armor {s}  Shield {s}\n", .{
            game.equipName(0, g.equip.weapon) orelse "none",
            game.equipName(7, g.equip.armor) orelse "none",
            game.equipName(14, g.equip.shield) orelse "none",
        });
        if (h.spells.bits != 0) {
            try out.writeAll("  Spells");
            inline for (@typeInfo(dw.Spell).@"enum".field_names) |name| {
                const sp = @field(dw.Spell, name);
                if (h.spells.contains(sp)) try out.print(" {s}({d})", .{ name, dw.mp_cost[@backingInt(sp)] });
            }
            try out.writeAll("\n");
        }
        if (g.repel.active()) try out.print("  Repel {d} steps left\n", .{g.repel.counter / 2});
        try self.where(out);
    }

    fn where(self: *Session, out: *Writer) Error!void {
        const g = &self.g;
        if (g.inTown()) return;
        try out.print("  {s} ({d}, {d})", .{ dw.map_names[g.at.map], g.at.x, g.at.y });
        if (travel.zoneAt(g.at.map, g.at.x, g.at.y)) |z| try out.print(", zone {d}", .{z});
        if (g.at.map == 0x01) {
            const dx = @as(i16, g.at.x) - 43;
            const dy = @as(i16, g.at.y) - 43;
            try out.print(", {d} steps from Tantegel", .{@abs(dx) + @abs(dy)});
        }
        try out.writeAll(".\n");
    }

    fn checklist(self: *Session, out: *Writer) Error!void {
        try out.writeAll("  Story checklist (`go <number>` walks there)\n");
        for (quests.objectives, 1..) |o, n| {
            const done = o.done(&self.g);
            try out.print("  {d:>3}. [{s}] {s}", .{ n, if (done) "x" else " ", o.name });
            if (o.optional) try out.writeAll(" (optional)");
            if (!done) {
                try out.print("\n         {s}", .{o.where});
                if (o.needs.len > 0) try out.print("\n         needs: {s}", .{o.needs});
            }
            try out.writeAll("\n");
        }
    }

    fn danger(self: *Session, out: *Writer) Error!void {
        const d: travel.Danger = .estimate(&self.g);
        const here = travel.zoneAt(self.g.at.map, self.g.at.x, self.g.at.y);
        try out.print("  One fight, for you as you are now (HP {d}):\n  zone  exp. HP lost  death   enemies\n", .{self.g.hp});
        for (0..20) |z| {
            try out.print("  {s}{d:>3}  {d:>12.1}  {d:>4.0}%   ", .{ if (here != null and here.? == z) ">" else " ", z, d.loss[z], d.death[z] * 100 });
            var nb: [24]u8 = undefined;
            for (dw.enemy_sets[z], 0..) |id, i| {
                if (std.mem.findScalar(dw.EnemyId, dw.enemy_sets[z][0..i], id) != null) continue;
                try out.print("{s}{s}", .{ if (i == 0) "" else ", ", game.enemyName(id, &nb) });
            }
            try out.writeAll(if (z >= 14) " (caves)\n" else "\n");
        }
    }

    fn places(self: *Session, out: *Writer) Error!void {
        const g = &self.g;
        try out.writeAll("  Towns (`go <name>`):\n");
        for (game.towns) |t| {
            const dx = @as(i16, t.entrance.x) - g.at.x;
            const dy = @as(i16, t.entrance.y) - g.at.y;
            try out.print("    {s:<11} ({d:>3}, {d:>3})", .{ t.name, t.entrance.x, t.entrance.y });
            if (g.at.map == 0x01) try out.print("  {d} tiles away as the crow flies", .{@abs(dx) + @abs(dy)});
            try out.writeAll("\n");
        }
        try out.writeAll("  Other spots (`go X Y` on the overworld):\n");
        for (travel.landmarks) |l| try out.print("    {s:<28} ({d}, {d})\n", .{ l.name, l.at.x, l.at.y });
    }

    fn look(self: *Session, out: *Writer) Error!void {
        const g = &self.g;
        var dy: i16 = -6;
        while (dy <= 6) : (dy += 1) {
            try out.writeAll("  ");
            var dx: i16 = -15;
            while (dx <= 15) : (dx += 1) {
                const x: u8 = @truncate(@as(u16, @bitCast(@as(i16, g.at.x) + dx)));
                const y: u8 = @truncate(@as(u16, @bitCast(@as(i16, g.at.y) + dy)));
                try out.writeByte(if (dx == 0 and dy == 0) '@' else tileChar(g.tileAt(x, y)));
            }
            try out.writeAll("\n");
        }
        const t = g.tileAt(g.at.x, g.at.y);
        try out.print("  Each step here: {d:.1}% chance of a fight.\n", .{travel.encounterChance(g, g.at.map, t, g.at.x, g.at.y) * 100});
        try self.where(out);
    }

    /// Where the title screen's map is centred: the bay between Tantegel and
    /// Brecconary (above the name) and Charlock (below it).
    pub const title_at: dw.Warp = .{ .map = 0x01, .x = 46, .y = 45 };

    /// The `w` x `h` rectangle of the current map at (x0, y0), row by row: each
    /// cell's tile into `tile` and its Mark bits (hero, NPCs, the planned
    /// route) into `mark`. Anything far past the edge is the map's border.
    /// Before there's a game, the overworld as a new game finds it, with no
    /// marks: the title screen shows it around title_at.
    pub fn mapCells(self: *const Session, x0: i32, y0: i32, w: u32, h: u32, tile: []u8, mark: []u8) void {
        const n = @as(usize, w) * h;
        @memset(mark[0..n], 0);
        const g = &self.g;
        const state: dw.MapState = if (self.pending == .name) .{ .map = title_at.map } else g.mapState();
        const border = @backingInt(dw.map_headers[state.map].border);
        for (0..h) |j| for (0..w) |i| {
            const x = x0 + @as(i32, @intCast(i));
            const y = y0 + @as(i32, @intCast(j));
            // -1 is 0xFF to the ROM: one step outside, where the overworld draws shore.
            tile[j * w + i] = if (x < -1 or y < -1 or x > 0xFF or y > 0xFF)
                border
            else
                @backingInt(dw.tileAt(game.maps, state, @truncate(@as(u32, @bitCast(x))), @truncate(@as(u32, @bitCast(y)))));
        };
        if (self.pending == .name) return;
        const put = struct {
            fn f(m: []u8, x0_: i32, y0_: i32, w_: u32, h_: u32, x: u8, y: u8, bits: u8) void {
                const i = @as(i32, x) - x0_;
                const j = @as(i32, y) - y0_;
                if (i < 0 or j < 0 or i >= w_ or j >= h_) return;
                m[@as(usize, @intCast(j)) * w_ + @as(usize, @intCast(i))] |= bits;
            }
        }.f;
        if (self.route) |r| for (r.plan.path) |p| {
            if (p.map == g.at.map) put(mark, x0, y0, w, h, p.x, p.y, Mark.route);
        };
        var nbuf: [20]dw.Npc = undefined;
        for (dw.npcs(game.maps, g.at.map, g.df, &nbuf)) |npc| {
            if (g.at.map == 0x0D and g.old_man_gone and npc.dialogue == 0x6C) continue;
            put(mark, x0, y0, w, h, npc.x, npc.y, Mark.npc | @as(u8, npc.sprite) | if (npc.moves) Mark.moves else 0);
        }
        put(mark, x0, y0, w, h, g.at.x, g.at.y, Mark.hero);
    }
};

/// What's on a map cell, from Session.mapCells.
pub const Mark = struct {
    pub const hero: u8 = 0x80;
    /// Low 3 bits: the NPC's sprite; `moves` if it wanders.
    pub const npc: u8 = 0x40;
    pub const moves: u8 = 0x08;
    pub const route: u8 = 0x20;
};

/// Up, down, left, right.
const dirs = [4][2]u8{ .{ 0, 0xFF }, .{ 0, 1 }, .{ 0xFF, 0 }, .{ 1, 0 } };

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn adjacent(a: dw.Warp, b: dw.Warp) bool {
    const dx = @as(i16, a.x) - b.x;
    const dy = @as(i16, a.y) - b.y;
    return @abs(dx) + @abs(dy) == 1;
}

fn dirOf(cmd: []const u8) ?[2]u8 {
    if (eq(cmd, "n") or eq(cmd, "north")) return dirs[0];
    if (eq(cmd, "s") or eq(cmd, "south")) return dirs[1];
    if (eq(cmd, "w") or eq(cmd, "west")) return dirs[2];
    if (eq(cmd, "e") or eq(cmd, "east")) return dirs[3];
    return null;
}

pub fn tileChar(t: dw.Tile) u8 {
    if (dw.isWater(t)) return '~';
    return switch (t) {
        .grass => '.',
        .desert => ':',
        .hills => 'n',
        .mountain => '^',
        .forest => '"',
        .swamp => '%',
        .bridge => '=',
        .town => 'H',
        .castle => 'K',
        .cave => 'O',
        .stairs_down => '>',
        .stairs_up => '<',
        .wall => '#',
        .brick => '_',
        .barrier => '!',
        .chest => '$',
        .door => '+',
        else => ' ',
    };
}

pub const help =
    \\  Anywhere:  status · items · places · danger · herb · cast <spell> · use <item> · auto on|off
    \\  Story:     checklist · go <number> · take · search · talk · open (a door, for a key)
    \\  Travel:    go <town | X Y> [safe|balanced|fast] [stop=HP%]   walk there, stopping for fights
    \\             grind [fights] [auto] [stop=HP%]                    fight near here
    \\             look · n/s/e/w [steps] · stairs
    \\  In town:   leave · inn · shop · buy <n> · sell <n|item> · save and mp (Tantegel)
    \\  Battle:    f(ight) · r(un) · h(erb) · c(ast) <spell> · flute · a(uto)   Enter = fight
    \\             stop: end the walk or grind once this fight is over
    \\  `danger` shows what one fight costs in each zone - `go` weighs that against distance.
    \\
;

// ---------- tests ----------

const testing = std.testing;

/// A session for tests, with output discarded unless `log` is given.
fn testSession(seed: u16) !Session {
    var s: Session = .init(testing.allocator, seed);
    var sink: Writer.Discarding = .init(&.{});
    try s.submit(&sink.writer, "Erdrick", 0);
    try expectEqual(Pending.command, std.meta.activeTag(s.pending));
    return s;
}

fn strong(s: *Session) void {
    s.g.xp = 65535;
    s.g.equip = .{ .shield = 3, .armor = 7, .weapon = 7 };
    s.g.hp = s.g.hero().stats.hp;
    s.g.mp = s.g.hero().stats.mp;
}

/// Answers every battle with `f` until the session wants a command again.
/// Returns how many battle commands it took.
fn fightThrough(s: *Session, out: *Writer) !u32 {
    var n: u32 = 0;
    while (s.pending == .battle) : (n += 1) {
        try s.submit(out, "f", 30);
        if (n > 10_000) return error.Stuck;
    }
    return n;
}

test "a new game asks for a name, then takes commands" {
    var s: Session = .init(testing.allocator, 3);
    defer s.deinit();
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try expectEqualStrings("Your name (1-8 letters): ", s.question().?);
    try s.submit(&w, "toolongname", 0);
    try expectEqual(Pending.name, std.meta.activeTag(s.pending));
    try s.submit(&w, "Lu", 0);
    try expectEqualStrings("Lu", s.g.nameSlice());
    var abuf: [16]Action = undefined;
    const acts = s.actions(&abuf);
    try expect(std.mem.findScalar(Action, acts, .save) != null);
    try expect(std.mem.findScalar(Action, acts, .leave) != null);
}

test "go plans, waits for a yes, and walks; a no walks nowhere" {
    var s = try testSession(11);
    defer s.deinit();
    var sink: Writer.Discarding = .init(&.{});
    const out = &sink.writer;
    try s.submit(out, "go brecconary safe", 0);
    try expectEqual(Pending.confirm_route, std.meta.activeTag(s.pending));
    try expect(s.route != null);
    try s.submit(out, "n", 0);
    try expectEqual(Pending.command, std.meta.activeTag(s.pending));
    try expectEqual(0x05, s.g.at.map); // still in the throne room

    strong(&s);
    try s.submit(out, "go brecconary safe", 0);
    try s.submit(out, "", 0);
    _ = try fightThrough(&s, out);
    try expectEqual(0x08, s.g.at.map);
    try expect(s.route == null);
}

test "a battle fought by hand pauses the walk, which carries on after it" {
    var s = try testSession(3);
    defer s.deinit();
    var sink: Writer.Discarding = .init(&.{});
    const out = &sink.writer;
    strong(&s);
    try s.submit(out, "go rimuldar fast stop=0", 0);
    try s.submit(out, "y", 0);
    var fights: u32 = 0;
    var tries: u32 = 0;
    while (s.g.at.map != 0x0B and tries < 50) : (tries += 1) {
        if (s.pending == .battle) {
            fights += 1;
            _ = try fightThrough(&s, out);
            continue;
        }
        // Stopped somewhere (a door, say): ask again.
        try s.submit(out, "go rimuldar fast stop=0", 0);
        try s.submit(out, "y", 0);
    }
    try expectEqual(0x0B, s.g.at.map);
    try expect(fights > 0);
    try expectEqual(Pending.command, std.meta.activeTag(s.pending));
}

test "grinding by hand counts fights across battles" {
    var s = try testSession(5);
    defer s.deinit();
    var buf: [1 << 16]u8 = undefined;
    var w: Writer = .fixed(&buf);
    strong(&s);
    try s.submit(&w, "leave", 0);
    try s.submit(&w, "grind 3 stop=0", 0);
    var tries: u32 = 0;
    while (s.pending == .battle and tries < 10) : (tries += 1) _ = try fightThrough(&s, &w);
    try expect(std.mem.find(u8, w.buffered(), "Grinding over (done): 3 fights") != null);
}

test "stop in a hand-fought battle ends the grind after it" {
    var s = try testSession(5);
    defer s.deinit();
    var buf: [1 << 16]u8 = undefined;
    var w: Writer = .fixed(&buf);
    strong(&s);
    try s.submit(&w, "leave", 0);
    try s.submit(&w, "grind 5 stop=0", 0);
    while (s.pending != .battle) try s.submit(&w, "grind 5 stop=0", 0);
    try expectEqualStrings("grind", s.stoppableJob().?);
    try s.submit(&w, "stop", 0);
    _ = try fightThrough(&s, &w);
    try expectEqual(Pending.command, std.meta.activeTag(s.pending));
    try expect(std.mem.find(u8, w.buffered(), "Grinding over (stopped): 1 fights") != null);
}

test "grind auto restores auto-battle afterwards" {
    var s = try testSession(5);
    defer s.deinit();
    var sink: Writer.Discarding = .init(&.{});
    strong(&s);
    try s.submit(&sink.writer, "grind 2 auto stop=0", 0);
    try expectEqual(Pending.command, std.meta.activeTag(s.pending));
    try expect(!s.auto);
}

test "a full bag asks what to throw away" {
    var s = try testSession(1);
    defer s.deinit();
    var sink: Writer.Discarding = .init(&.{});
    const out = &sink.writer;
    s.g.at = .{ .map = 0x1A, .x = 13, .y = 6 }; // the Silver Harp's chest
    s.g.inv.slots = @splat(0);
    for (0..8) |_| _ = s.g.inv.add(.torch);
    try s.submit(out, "take", 0);
    try expectEqual(dw.Item.silver_harp, s.pending.make_room);
    try s.submit(out, "torch", 0);
    try expect(s.g.inv.has(.silver_harp));
    try expectEqual(Pending.command, std.meta.activeTag(s.pending));
}

test "the Dragonlord: refuse him and fight both forms, or join him and lose" {
    for ([2]bool{ false, true }) |join| {
        var s = try testSession(9);
        defer s.deinit();
        var sink: Writer.Discarding = .init(&.{});
        const out = &sink.writer;
        strong(&s);
        const o = quests.find("Defeat the Dragonlord");
        var buf: [8]dw.Warp = undefined;
        s.g.at = quests.standingTiles(&s.g, o.spot(&s.g), &buf)[0];
        try s.submit(out, "talk", 0);
        try expectEqual(Pending.dragonlord, std.meta.activeTag(s.pending));
        try s.submit(out, "maybe", 0);
        try expectEqual(Pending.dragonlord, std.meta.activeTag(s.pending));
        if (join) {
            try s.submit(out, "y", 0);
            try s.submit(out, "y", 0);
            try expectEqual(Pending.over, std.meta.activeTag(s.pending));
            continue;
        }
        try s.submit(out, "n", 0);
        // The first form waits for a command; auto-battle (which heals) takes
        // it from there, through the second form.
        try expectEqual(dw.EnemyId.dragonlord1, s.pending.battle.e.id);
        try s.submit(out, "a", 0);
        try expectEqual(Pending.command, std.meta.activeTag(s.pending));
        try expect(s.g.e4 & dw.Story.dragonlord_beaten != 0);
        try expectEqual(0x01, s.g.at.map);
    }
}

test "the king saves, and a new session continues from it" {
    var s = try testSession(2);
    defer s.deinit();
    var sink: Writer.Discarding = .init(&.{});
    s.g.xp = 500;
    try s.submit(&sink.writer, "save", 0);
    try expect(s.sram_dirty);

    var t: Session = .init(testing.allocator, 0);
    defer t.deinit();
    try expect(!try t.continueGame(&sink.writer));
    t.sram = s.sram;
    try expect(try t.continueGame(&sink.writer));
    try expectEqualStrings("Erdrick", t.g.nameSlice());
    try expectEqual(500, t.g.xp);
}

test "saving from the castle gate walks up to the king, healing on the way" {
    var s = try testSession(2);
    defer s.deinit();
    var sink: Writer.Discarding = .init(&.{});
    const g = &s.g;
    g.df |= dw.Quest.left_throne_room;
    g.at = .{ .map = 0x04, .x = 11, .y = 29 }; // just inside the gate
    g.equip.armor = dw.erdricks_armor;
    g.hp = 1;
    try s.submit(&sink.writer, "save", 0);
    try expect(s.sram_dirty);
    try expectEqual(0x05, g.at.map); // up the stairs, through the open door
    var buf: [8]dw.Warp = undefined;
    const beside = quests.standingTiles(g, .{ .at = Game.king, .beside = true, .action = .talk }, &buf);
    try expect(for (beside) |w| {
        if (std.meta.eql(w, g.at)) break true;
    } else false);
    try expect(g.hp > 1); // +1 HP a step
    try expectEqual(g.hp, Game.load(&s.sram, 0).?.hp); // the HP you arrived with is saved
}

test "town services walk to their NPC; leave walks off the edge" {
    var s = try testSession(2);
    defer s.deinit();
    var sink: Writer.Discarding = .init(&.{});
    const g = &s.g;
    // Out of the throne room (the king's key opens its door) to the old man.
    try s.submit(&sink.writer, "mp", 0);
    try expectEqual(Pending.command, std.meta.activeTag(s.pending));
    try expectEqual(0x04, g.at.map);
    var sbuf: [20]dw.NpcService = undefined;
    var wbuf: [20]dw.Warp = undefined;
    const i = for (g.services(&sbuf), 0..) |sv, k| {
        if (sv == .restore_mp) break k;
    } else unreachable;
    const old_man = g.serviceSpots(&wbuf)[i];
    try expect(game.nearNpc(g, .{ .x = old_man.x, .y = old_man.y, .dialogue = 0x6A, .moves = false, .slot = 0 }));
    const steps = g.steps;
    try s.submit(&sink.writer, "leave", 0);
    try expectEqual(dw.edgeExit(0x04).?, g.at);
    try expect(g.steps > steps);
}

test "assist: stepping onto stairs takes them, but arriving on stairs doesn't" {
    var s = try testSession(4);
    defer s.deinit();
    var sink: Writer.Discarding = .init(&.{});
    s.assist = true;
    s.g.at = .{ .map = 0x05, .x = 8, .y = 7 }; // above the throne room's stairs
    try expectEqual(dw.Tile.stairs_down, s.g.tileAt(8, 8));
    try s.submit(&sink.writer, "s", 0);
    try expectEqual(0x04, s.g.at.map);
    try expectEqual(dw.Tile.stairs_up, s.g.tileAt(s.g.at.x, s.g.at.y));
}

test "assist: walking onto a chest takes it" {
    var s = try testSession(4);
    defer s.deinit();
    var sink: Writer.Discarding = .init(&.{});
    s.assist = true;
    const chest: dw.Warp = .{ .map = 0x1A, .x = 13, .y = 6 }; // the Silver Harp
    const names = [4][]const u8{ "n", "s", "w", "e" }; // the move from the tile beside it
    for (dirs, names) |d, name| {
        const x = chest.x -% d[0];
        const y = chest.y -% d[1];
        s.g.at = .{ .map = chest.map, .x = x, .y = y };
        if (!dw.walkable(s.g.tileAt(x, y))) continue;
        try s.submit(&sink.writer, name, 0);
        break;
    }
    try expect(s.g.inv.has(.silver_harp));
}

test "assist: a route with nothing to fear is walked without asking" {
    var s = try testSession(4);
    defer s.deinit();
    var sink: Writer.Discarding = .init(&.{});
    s.assist = true;
    s.g.at = .{ .map = 0x04, .x = 11, .y = 29 }; // inside Tantegel's gate
    s.g.df |= dw.Quest.left_throne_room;
    try s.submit(&sink.writer, "go 11 24", 0);
    try expectEqual(Pending.command, std.meta.activeTag(s.pending));
    try expectEqual(dw.Warp{ .map = 0x04, .x = 11, .y = 24 }, s.g.at);
    // Out on the overworld there are fights, so it asks.
    try s.submit(&sink.writer, "leave", 0);
    try s.submit(&sink.writer, "go brecconary", 0);
    try expectEqual(Pending.confirm_route, std.meta.activeTag(s.pending));
}

test "the whole quest can be played with commands, objective by objective" {
    var s = try testSession(5);
    defer s.deinit();
    var sink: Writer.Discarding = .init(&.{});
    const out = &sink.writer;
    const g = &s.g;
    s.auto = true;
    g.xp = 65535;
    g.equip = .{ .shield = 3, .armor = 5, .weapon = 5 };
    for (quests.objectives, 1..) |o, n| {
        var tries: u32 = 0;
        while (!o.done(g) and tries < 8) : (tries += 1) {
            g.hp = g.hero().stats.hp;
            g.mp = g.hero().stats.mp;
            g.inv.keys = 6;
            g.inv.herbs = 6;
            var buf: [32]u8 = undefined;
            try s.submit(out, try std.fmt.bufPrint(&buf, "go {d} fast stop=0", .{n}), 0);
            if (s.pending == .confirm_route) try s.submit(out, "y", 0);
            var spots: [8]dw.Warp = undefined;
            const here = for (quests.standingTiles(g, o.spot(g), &spots)) |w| {
                if (std.meta.eql(w, g.at)) break true;
            } else false;
            if (!here) continue; // stopped on the way: go again
            switch (o.spot(g).action) {
                .search => try s.submit(out, "search", 0),
                .take => try s.submit(out, "take", 0),
                .talk => try s.submit(out, "talk", 0),
                .use_rainbow_drop => try s.submit(out, "use rainbow drop", 0),
                .arrive => {},
                .fight => try s.submit(out, o.spot(g).toward, 0),
            }
            if (s.pending == .dragonlord) try s.submit(out, "n", 0);
            if (s.pending == .make_room) try s.submit(out, "", 0);
        }
        if (!o.done(g)) {
            std.debug.print("objective {d} ({s}) not done; at {any}\n", .{ n, o.name, g.at });
            return error.ObjectiveNotDone;
        }
    }
    // Home to the king for the ending.
    try s.submit(out, "go tantegel fast stop=0", 0);
    if (s.pending == .confirm_route) try s.submit(out, "y", 0);
    try s.submit(out, "talk", 0);
    try expectEqual(Pending.over, std.meta.activeTag(s.pending));
    try expect(g.ended);
}

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const dw = @import("dw");
const game = @import("game.zig");
const battle = @import("battle.zig");
const travel = @import("travel.zig");
const quests = @import("quests.zig");
const Game = game.Game;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
