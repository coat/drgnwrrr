//! The web build: the engine and one Session, compiled to wasm32-freestanding
//! and driven from JavaScript (web/engine.js). Strings cross as a pointer and
//! length into this module's memory; state comes back as JSON from view().
//! No libc and no imports besides jsLog.
const std = @import("std");
const lib = @import("drgnwrrr");
const dw = lib.dw;
const game = lib.game;
const travel = lib.travel;
const quests = lib.quests;
const session_ = lib.session;
const Session = lib.Session;
const Game = lib.Game;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const gpa = std.heap.wasm_allocator;

/// console.error, for panics.
extern "env" fn jsLog(ptr: [*]const u8, len: usize) void;

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        jsLog(msg.ptr, msg.len);
        @trap();
    }
}.f);

var session: Session = undefined;
var booted = false;
/// The log text from the last submit or continueGame.
var out: Writer.Allocating = undefined;
/// The last view() or danger().
var json: Writer.Allocating = undefined;
var arena: std.heap.ArenaAllocator = undefined;
var cells: []u8 = &.{};

// ---------- memory ----------

export fn alloc(n: usize) ?[*]u8 {
    return (gpa.alloc(u8, n) catch return null).ptr;
}

export fn free(p: [*]u8, n: usize) void {
    gpa.free(p[0..n]);
}

// ---------- the session ----------

/// Start (or restart) with `seed` for a new game. The SRAM is cleared:
/// write a save into sramPtr() afterwards.
export fn boot(seed: u32) void {
    if (booted) {
        session.deinit();
    } else {
        out = .init(gpa);
        json = .init(gpa);
        arena = .init(gpa);
        booted = true;
    }
    session = .init(gpa, @truncate(seed));
    session.assist = true;
}

/// The remakes' conveniences (Session.assist): on by default here.
export fn setAssist(on: bool) void {
    session.assist = on;
}

export fn sramPtr() [*]u8 {
    return &session.sram;
}

export fn sramLen() usize {
    return dw.Sram.size;
}

export fn hasSave() bool {
    var copy = session.sram;
    return Game.load(&copy, 0) != null;
}

/// True once after the king saves: store the SRAM then.
export fn sramDirty() bool {
    defer session.sram_dirty = false;
    return session.sram_dirty;
}

export fn continueGame() bool {
    out.clearRetainingCapacity();
    return session.continueGame(&out.writer) catch false;
}

/// Ask for a name for a new game (the save stays until the king saves again).
export fn newGame() void {
    session.newGame();
}

/// Reseed the game's RNG, for deterministic runs (like the CLI's --seed).
export fn reseed(seed: u32) void {
    if (session.pending != .name) session.g.rng = .init(@truncate(seed));
}

/// One command line. `idle_ms` is how long the player took to decide.
export fn submit(ptr: [*]const u8, len: usize, idle_ms: u32) void {
    out.clearRetainingCapacity();
    const frames = dw.framesFromNs(@as(u64, idle_ms) * std.time.ns_per_ms);
    session.submit(&out.writer, ptr[0..len], frames) catch |err| {
        out.writer.print("  (error: {t})\n", .{err}) catch {};
    };
}

export fn outPtr() [*]const u8 {
    return out.written().ptr;
}

export fn outLen() usize {
    return out.written().len;
}

export fn jsonPtr() [*]const u8 {
    return json.written().ptr;
}

// ---------- the map ----------

/// The tiles of a w x h rectangle of the current map at (x0, y0), row by row,
/// followed by as many session_.Mark bytes (see Session.mapCells).
export fn tiles(x0: i32, y0: i32, w: u32, h: u32) ?[*]u8 {
    const n = @as(usize, w) * h;
    if (cells.len < 2 * n) {
        gpa.free(cells);
        cells = gpa.alloc(u8, 2 * n) catch return null;
    }
    session.mapCells(x0, y0, w, h, cells[0..n], cells[n .. 2 * n]);
    return cells.ptr;
}

// ---------- views ----------

const SpellView = struct { name: []const u8, mp: u8, field: bool, battle: bool };
const ItemView = struct { n: usize, name: []const u8, count: u8, worn: bool, sell: ?u16, droppable: bool };
const OfferView = struct { n: usize, shop: u8, kind: []const u8, name: []const u8, price: u16 };
const RouteView = struct {
    name: []const u8,
    risk: []const u8,
    stop: u8,
    steps: u32,
    fights: f32,
    hp_loss: f32,
    death: f32,
    worst_zone: ?u8,
    doors: u32,
    keys: u8,
    fixed: u32,
    via: []const []const u8,
};
const BattleView = struct {
    enemy: []const u8,
    id: []const u8,
    fixed: bool,
    enemy_asleep: bool,
    enemy_stopped: bool,
    hero_asleep: bool,
    hero_stopped: bool,
    /// What `stop` would end once this fight is over ("go" or "grind").
    job: ?[]const u8,
    stopping: bool,
};
const ObjectiveView = struct { n: usize, name: []const u8, where: []const u8, needs: []const u8, optional: bool, done: bool };
const PlaceView = struct { name: []const u8, map: u8, x: u8, y: u8 };

const GameView = struct {
    name: []const u8,
    level: u8,
    hp: u8,
    max_hp: u8,
    mp: u8,
    max_mp: u8,
    gold: u16,
    xp: u16,
    /// Only with Gwaelin's Love, as in the game.
    xp_to_next: ?u16,
    low_hp: bool,
    str: u8,
    agi: u8,
    attack: u8,
    defense: u8,
    herbs: u8,
    keys: u8,
    weapon: ?[]const u8,
    armor: ?[]const u8,
    shield: ?[]const u8,
    map: u8,
    map_name: []const u8,
    x: u8,
    y: u8,
    width: u16,
    height: u16,
    town: ?[]const u8,
    king: bool,
    zone: ?u8,
    /// Percent chance a step here starts a fight.
    encounter: f32,
    auto: bool,
    assist: bool,
    repel_steps: u8,
    steps: u32,
    battles: u32,
    ended: bool,
    actions: []const []const u8,
    spells: []const SpellView,
    items: []const ItemView,
    shop: []const OfferView,
    inn: ?u8,
    route: ?RouteView,
    battle: ?BattleView,
    make_room: ?[]const u8,
    checklist: []const ObjectiveView,
    towns: []const PlaceView,
    landmarks: []const PlaceView,
};

const View = struct {
    mode: []const u8,
    question: ?[]const u8,
    has_save: bool,
    game: ?GameView,
    /// Where the title screen's overworld is centred (Session.title_at).
    title_at: struct { x: u8, y: u8 },
};

/// Writes the view as JSON (read it at jsonPtr()) and returns its length.
export fn view() usize {
    json.clearRetainingCapacity();
    _ = arena.reset(.retain_capacity);
    const v: View = .{
        .mode = @tagName(session.pending),
        .question = session.question(),
        .has_save = hasSave(),
        .title_at = .{ .x = Session.title_at.x, .y = Session.title_at.y },
        .game = if (session.pending == .name) null else gameView(arena.allocator()) catch return 0,
    };
    var s: std.json.Stringify = .{ .writer = &json.writer };
    s.write(v) catch return 0;
    return json.written().len;
}

fn gameView(a: Allocator) Allocator.Error!GameView {
    const g = &session.g;
    const h = g.hero();
    const town = game.townFor(g.at.map);
    const hdr = dw.map_headers[g.at.map];

    var abuf: [16]session_.Action = undefined;
    const acts = session.actions(&abuf);
    const actions = try a.alloc([]const u8, acts.len);
    for (acts, actions) |act, *s| s.* = @tagName(act);

    var spells: std.ArrayList(SpellView) = .empty;
    inline for (@typeInfo(dw.Spell).@"enum".field_names) |name| {
        const sp = @field(dw.Spell, name);
        if (h.spells.contains(sp)) try spells.append(a, .{
            .name = name,
            .mp = dw.mp_cost[@backingInt(sp)],
            .field = switch (sp) {
                .heal, .healmore, .radiant, .outside, .@"return", .repel => true,
                else => false,
            },
            .battle = switch (sp) {
                .heal, .healmore, .hurt, .hurtmore, .sleep, .stopspell => true,
                else => false,
            },
        });
    }

    var obuf: [10]session_.Owned = undefined;
    const owned = session.owned(&obuf);
    const items = try a.alloc(ItemView, owned.len);
    for (owned, items, 1..) |o, *it, n| it.* = .{
        .n = n,
        .name = game.itemName(o.item),
        .count = o.count,
        .worn = session.worn(o.item),
        .sell = session.sellPrice(o.item),
        .droppable = dw.droppable(o.item, g.cf),
    };

    var cbuf: [48]game.Offer = undefined;
    const catalog = g.catalog(&cbuf);
    const shop = try a.alloc(OfferView, catalog.len);
    for (catalog, shop, 1..) |o, *s, n| s.* = .{ .n = n, .shop = o.shop, .kind = Session.shopTitle(o.kind), .name = o.name(), .price = o.price() };

    const route: ?RouteView = if (session.route) |r| blk: {
        const via = try a.alloc([]const u8, r.plan.via_len);
        for (r.plan.via[0..r.plan.via_len], via) |m, *s| s.* = dw.map_names[m];
        break :blk .{
            .name = r.go.name,
            .risk = @tagName(r.go.risk),
            .stop = r.go.stop,
            .steps = r.plan.steps,
            .fights = r.plan.encounters,
            .hp_loss = r.plan.hp_loss,
            .death = r.plan.death * 100,
            .worst_zone = r.plan.worst_zone,
            .doors = r.plan.doors,
            .keys = r.keys,
            .fixed = r.plan.fixed_battles,
            .via = via,
        };
    } else null;

    const fight: ?BattleView = switch (session.pending) {
        .battle => |f| blk: {
            var nb: [24]u8 = undefined;
            break :blk .{
                .enemy = try a.dupe(u8, f.b.name(&nb)),
                .id = @tagName(f.e.id),
                .fixed = f.e.fixed,
                .enemy_asleep = f.b.enemy_asleep,
                .enemy_stopped = f.b.enemy_stopped,
                .hero_asleep = f.b.hero_asleep,
                .hero_stopped = f.b.hero_stopped,
                .job = session.stoppableJob(),
                .stopping = session.stop_job,
            };
        },
        else => null,
    };

    const checklist = try a.alloc(ObjectiveView, quests.objectives.len);
    for (quests.objectives, checklist, 1..) |o, *c, n| c.* = .{ .n = n, .name = o.name, .where = o.where, .needs = o.needs, .optional = o.optional, .done = o.done(g) };

    var towns: [game.towns.len]PlaceView = undefined;
    for (game.towns, &towns) |t, *p| p.* = .{ .name = t.name, .map = t.entrance.map, .x = t.entrance.x, .y = t.entrance.y };
    var landmarks: [travel.landmarks.len]PlaceView = undefined;
    for (travel.landmarks, &landmarks) |l, *p| p.* = .{ .name = l.name, .map = l.at.map, .x = l.at.x, .y = l.at.y };

    const here = g.tileAt(g.at.x, g.at.y);
    return .{
        .name = g.nameSlice(),
        .level = h.level,
        .hp = g.hp,
        .max_hp = h.stats.hp,
        .mp = g.mp,
        .max_mp = h.stats.mp,
        .gold = g.gold,
        .xp = g.xp,
        .xp_to_next = if (g.inv.has(.gwaelins_love)) dw.xpToNext(g.xp) else null,
        .low_hp = g.lowHp(),
        .str = h.stats.str,
        .agi = h.stats.agi,
        .attack = h.attack,
        .defense = h.defense,
        .herbs = g.inv.herbs,
        .keys = g.inv.keys,
        .weapon = game.equipName(0, g.equip.weapon),
        .armor = game.equipName(7, g.equip.armor),
        .shield = game.equipName(14, g.equip.shield),
        .map = g.at.map,
        .map_name = dw.map_names[g.at.map],
        .x = g.at.x,
        .y = g.at.y,
        .width = @as(u16, hdr.max_x) + 1,
        .height = @as(u16, hdr.max_y) + 1,
        .town = if (town) |t| t.name else null,
        .king = if (town) |t| t.king else false,
        .zone = travel.zoneAt(g.at.map, g.at.x, g.at.y),
        .encounter = travel.encounterChance(g, g.at.map, here, g.at.x, g.at.y) * 100,
        .auto = session.auto,
        .assist = session.assist,
        .repel_steps = if (g.repel.active()) g.repel.counter / 2 else 0,
        .steps = g.steps,
        .battles = g.battles,
        .ended = g.ended,
        .actions = actions,
        .spells = spells.items,
        .items = items,
        .shop = shop,
        .inn = g.innPrice(),
        .route = route,
        .battle = fight,
        .make_room = switch (session.pending) {
            .make_room => |it| game.itemName(it),
            else => null,
        },
        .checklist = checklist,
        .towns = try a.dupe(PlaceView, &towns),
        .landmarks = try a.dupe(PlaceView, &landmarks),
    };
}

const ZoneView = struct { zone: usize, loss: f32, death: f32, enemies: []const []const u8 };

/// What one fight costs in each zone, for the hero as they are (JSON, like view()).
export fn danger() usize {
    json.clearRetainingCapacity();
    _ = arena.reset(.retain_capacity);
    if (session.pending == .name) return 0;
    const a = arena.allocator();
    const d: travel.Danger = .estimate(&session.g);
    var zones: [20]ZoneView = undefined;
    for (&zones, 0..) |*z, i| {
        var names: std.ArrayList([]const u8) = .empty;
        for (dw.enemy_sets[i], 0..) |id, k| {
            if (std.mem.findScalar(dw.EnemyId, dw.enemy_sets[i][0..k], id) != null) continue;
            var nb: [24]u8 = undefined;
            names.append(a, a.dupe(u8, game.enemyName(id, &nb)) catch return 0) catch return 0;
        }
        z.* = .{ .zone = i, .loss = d.loss[i], .death = d.death[i] * 100, .enemies = names.items };
    }
    const g = &session.g;
    var s: std.json.Stringify = .{ .writer = &json.writer };
    s.write(.{ .here = travel.zoneAt(g.at.map, g.at.x, g.at.y), .hp = g.hp, .zones = &zones }) catch return 0;
    return json.written().len;
}
