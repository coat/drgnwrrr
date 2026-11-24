//! Route planning. The player names a destination and how much risk they'll
//! take; the planner finds the path. Costs are expected values from the ROM's
//! own odds (the tile mask, zone 0's extra roll, terrain damage) and from
//! simulated battles with the real battle code. It never looks at the RNG
//! state, so it can't steer into or away from particular fights.
const std = @import("std");
const dw = @import("dw");
const game = @import("game.zig");
const battle = @import("battle.zig");
const Game = game.Game;

pub const Risk = enum {
    safe,
    balanced,
    fast,

    /// How many steps one percent of max HP is worth.
    pub fn weight(self: Risk) f32 {
        return switch (self) {
            .safe => 4.0,
            .balanced => 1.0,
            .fast => 0.05,
        };
    }
};

/// Chance that one step onto (x, y) starts a random battle, assuming RAND is
/// uniform. From the step code: the tile mask ($CDC6), and zone 0's extra
/// roll on the overworld ($CEC1).
pub fn encounterChance(g: *const Game, map: u8, tile: dw.Tile, x: u8, y: u8) f32 {
    if (dw.isEntrance(tile) or g.e4 & dw.Story.dragonlord_beaten != 0) return 0;
    const overworld = map == 0x01;
    const zone = zoneAt(map, x, y) orelse return 0;
    var p = 1.0 / @as(f32, @floatFromInt(@as(u16, dw.encounterMask(tile, x, y)) + 1));
    if (overworld and zone == 0) p *= if (tile == .hills) 0.25 else 0.5;
    return p;
}

pub fn zoneAt(map: u8, x: u8, y: u8) ?u8 {
    if (map == 0x01) return dw.overworldZone(x, y);
    return dw.mapZone(map, @backingInt(dw.mapKind(map)));
}

/// Expected cost of one fight in each zone, for this hero as they are now.
pub const Danger = struct {
    /// Expected HP lost (capped at current HP).
    loss: [20]f32,
    /// Chance the fight kills you.
    death: [20]f32,
    /// The same with REPEL or Fairy Water active (repelled fights cost nothing).
    loss_repel: [20]f32,
    death_repel: [20]f32,

    const sims = 24;

    /// Fight-only battles against each of the zone's five slots, run on a copy
    /// of the game with its own RNG seeds. The real game isn't touched.
    pub fn estimate(g: *const Game) Danger {
        var d: Danger = undefined;
        var sink: std.Io.Writer.Discarding = .init(&.{});
        const def = g.hero().defense;
        for (dw.enemy_sets, 0..) |set, zone| {
            var loss: [2]f32 = .{ 0, 0 };
            var death: [2]f32 = .{ 0, 0 };
            for (set, 0..) |id, slot| {
                var l: f32 = 0;
                var k: f32 = 0;
                for (0..sims) |i| {
                    var c = g.*;
                    c.rng = .init(@truncate(zone * 7919 + slot * 977 + i * 131 + 1));
                    const b = battle.runBattle(&c, &sink.writer, id, false, battle.fightOnly) catch unreachable;
                    l += @floatFromInt(b.hp_lost);
                    if (b.outcome.? == .died) k += 1;
                }
                l /= sims;
                k /= sims;
                // The slots are close to evenly likely (the guide's table: 16-22 % each).
                loss[0] += l / 5;
                death[0] += k / 5;
                if (!dw.repelled(def, dw.enemies[@backingInt(id)].str)) {
                    loss[1] += l / 5;
                    death[1] += k / 5;
                }
            }
            d.loss[zone] = loss[0];
            d.death[zone] = death[0];
            d.loss_repel[zone] = loss[1];
            d.death_repel[zone] = death[1];
        }
        return d;
    }
};

pub const Place = struct { name: []const u8, at: dw.Warp };

/// Overworld spots the planner can aim for besides towns.
pub const landmarks = [_]Place{
    .{ .name = "Swamp Cave north", .at = .{ .map = 0x01, .x = 104, .y = 44 } },
    .{ .name = "Swamp Cave south", .at = .{ .map = 0x01, .x = 104, .y = 49 } },
    .{ .name = "Charlock (across the water)", .at = .{ .map = 0x01, .x = 48, .y = 48 } },
};

/// Every node is one tile on a walked map.
const Graph = struct {
    base: [0x1E]u32,
    total: u32,

    fn init() Graph {
        var g: Graph = .{ .base = @splat(0), .total = 0 };
        for (0..0x1E) |m| {
            g.base[m] = g.total;
            if (!game.walkedMap(@intCast(m))) continue;
            const h = dw.map_headers[m];
            g.total += (@as(u32, h.max_x) + 1) * (@as(u32, h.max_y) + 1);
        }
        return g;
    }

    fn id(self: Graph, w: dw.Warp) u32 {
        const h = dw.map_headers[w.map];
        return self.base[w.map] + @as(u32, w.y) * (@as(u32, h.max_x) + 1) + w.x;
    }

    fn warp(self: Graph, n: u32) dw.Warp {
        var m: u8 = 0x1D;
        while (!game.walkedMap(m) or self.base[m] > n) m -= 1;
        const w = @as(u32, dw.map_headers[m].max_x) + 1;
        const off = n - self.base[m];
        return .{ .map = m, .x = @intCast(off % w), .y = @intCast(off / w) };
    }
};

pub const Plan = struct {
    /// Every tile entered, in order (map changes included).
    path: []dw.Warp,
    steps: u32,
    encounters: f32,
    hp_loss: f32,
    death: f32,
    worst_zone: ?u8,
    fixed_battles: u32,
    /// Maps other than the overworld the route goes through.
    via_cave: bool,
    /// Doors on the way: each takes a Magic Key.
    doors: u32 = 0,
    /// The planner's own cost (steps plus weighted risk).
    cost: f32 = 0,
    /// Maps passed through besides the start and the overworld, in order.
    via: [8]u8 = undefined,
    via_len: usize = 0,

    pub fn deinit(self: *Plan, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
    }
};

const QItem = struct { cost: f32, node: u32 };
fn qLess(_: void, a: QItem, b: QItem) std.math.Order {
    return std.math.order(a.cost, b.cost);
}

/// Cost of stepping onto `to`, and its expected contribution to the summary.
const Edge = struct { cost: f32, p: f32, loss: f32, death: f32, zone: ?u8, fixed: bool };

const fixed_cost = 2000;
/// A door costs a Magic Key (98, 53 or 85 gold): worth a detour of this many steps.
const door_cost = 40;

fn edgeCost(g: *const Game, d: *const Danger, risk: Risk, to: dw.Warp, tile: dw.Tile) Edge {
    const max_hp: f32 = @floatFromInt(g.hero().stats.hp);
    const p = encounterChance(g, to.map, tile, to.x, to.y);
    const zone = zoneAt(to.map, to.x, to.y);
    const repel = g.repel.active() and to.map == 0x01;
    var loss: f32 = 0;
    var death: f32 = 0;
    if (zone) |z| {
        loss = p * if (repel) d.loss_repel[z] else d.loss[z];
        death = p * if (repel) d.death_repel[z] else d.death[z];
    }
    if (g.equip.armor != dw.erdricks_armor) loss += switch (tile) {
        .swamp => 2,
        .barrier => 15,
        else => 0,
    };
    const fixed = dw.fixedBattle(to.map, to.x, to.y, g.e4) != null;
    var cost: f32 = 1 + risk.weight() * (loss / max_hp * 100 + death * 1000);
    if (fixed) cost += fixed_cost; // only if there's no other way
    return .{ .cost = cost, .p = p, .loss = loss, .death = death, .zone = if (p > 0) zone else null, .fixed = fixed };
}

/// Dijkstra over the overworld and the caves. Entrances to towns are only
/// entered when they're the goal; stairs are followed with the STAIRS command.
pub fn plan(gpa: std.mem.Allocator, g: *const Game, goal: dw.Warp, risk: Risk) !?Plan {
    if (!game.walkedMap(g.at.map)) return null;
    const graph: Graph = .init();
    const d: Danger = .estimate(g);
    const cost = try gpa.alloc(f32, graph.total);
    defer gpa.free(cost);
    const prev = try gpa.alloc(u32, graph.total);
    defer gpa.free(prev);
    @memset(cost, std.math.inf(f32));
    @memset(prev, std.math.maxInt(u32));

    var q: std.PriorityQueue(QItem, void, qLess) = .empty;
    defer q.deinit(gpa);
    const start = graph.id(g.at);
    const target = graph.id(goal);
    cost[start] = 0;
    try q.push(gpa, .{ .cost = 0, .node = start });

    var state: dw.MapState = undefined;
    while (q.pop()) |it| {
        if (it.cost > cost[it.node]) continue;
        if (it.node == target) break;
        const at = graph.warp(it.node);
        state = g.mapStateOn(at.map);
        // Neighbours, plus the stairs on this tile.
        const dirs = [4][2]u8{ .{ 0, 0xFF }, .{ 0, 1 }, .{ 0xFF, 0 }, .{ 1, 0 } };
        var next: [5]?struct { w: dw.Warp, cost: f32 } = @splat(null);
        for (dirs, 0..) |dv, i| {
            const x = at.x +% dv[0];
            const y = at.y +% dv[1];
            const h = dw.map_headers[at.map];
            if (x > h.max_x or y > h.max_y) {
                // Off the edge of a town or cave: its exit ($B228).
                if (at.map != 0x01 and dw.walkable(dw.tileAt(game.maps, state, x, y))) {
                    if (dw.edgeExit(at.map)) |w| next[i] = .{ .w = w, .cost = 1 };
                }
                continue;
            }
            const tile = dw.tileAt(game.maps, state, x, y);
            const here: dw.Warp = .{ .map = at.map, .x = x, .y = y };
            if (tile == .door) {
                // Opening it takes a Magic Key, so it's only a way through if you have one.
                if (g.inv.keys > 0) next[i] = .{ .w = here, .cost = door_cost };
                continue;
            }
            if (!dw.walkable(tile) or g.npcAt(at.map, x, y)) continue;
            if (dw.isEntrance(tile)) {
                const w = dw.warpForward(here) orelse continue;
                if (std.meta.eql(here, goal)) {
                    next[i] = .{ .w = here, .cost = 1 };
                } else if (game.walkedMap(w.map)) {
                    next[i] = .{ .w = w, .cost = 1 };
                }
                continue;
            }
            var c = edgeCost(g, &d, risk, here, tile);
            if (c.fixed and std.meta.eql(here, goal)) c.cost -= fixed_cost; // the guard is the point
            next[i] = .{ .w = here, .cost = c.cost };
        }
        if (dw.stairs(game.maps, state, at.x, at.y)) |w| {
            if (game.walkedMap(w.map)) next[4] = .{ .w = w, .cost = 0.5 };
        }
        for (next) |maybe| {
            const n = maybe orelse continue;
            const v = graph.id(n.w);
            const c = it.cost + n.cost;
            if (c < cost[v]) {
                cost[v] = c;
                prev[v] = it.node;
                try q.push(gpa, .{ .cost = c, .node = v });
            }
        }
    }
    if (prev[target] == std.math.maxInt(u32) and target != start) return null;

    var rev: std.ArrayList(dw.Warp) = .empty;
    defer rev.deinit(gpa);
    var n = target;
    while (n != start) : (n = prev[n]) try rev.append(gpa, graph.warp(n));
    std.mem.reverse(dw.Warp, rev.items);

    var p: Plan = .{ .path = try gpa.dupe(dw.Warp, rev.items), .steps = 0, .encounters = 0, .hp_loss = 0, .death = 0, .worst_zone = null, .fixed_battles = 0, .via_cave = false };
    p.cost = cost[target];
    var survive: f32 = 1;
    var from = g.at;
    for (p.path) |w| {
        defer from = w;
        if (w.map != from.map) {
            p.via_cave = true;
            if (w.map != 0x01 and w.map != g.at.map and std.mem.findScalar(u8, p.via[0..p.via_len], w.map) == null and p.via_len < p.via.len) {
                p.via[p.via_len] = w.map;
                p.via_len += 1;
            }
            if (dw.tileAt(game.maps, g.mapStateOn(from.map), from.x, from.y) != .stairs_up and
                dw.tileAt(game.maps, g.mapStateOn(from.map), from.x, from.y) != .stairs_down) p.steps += 1; // an entrance step
            continue;
        }
        p.steps += 1;
        const tile = dw.tileAt(game.maps, g.mapStateOn(w.map), w.x, w.y);
        if (tile == .door) p.doors += 1;
        if (dw.isEntrance(tile)) continue;
        const e = edgeCost(g, &d, risk, w, tile);
        p.encounters += e.p;
        p.hp_loss += e.loss;
        survive *= 1 - e.death;
        if (e.fixed) p.fixed_battles += 1;
        if (e.zone) |z| {
            // Death risk first: the loss is capped at current HP, so it ties when you're weak.
            const score = d.death[z] * 1000 + d.loss[z];
            if (p.worst_zone == null or score > d.death[p.worst_zone.?] * 1000 + d.loss[p.worst_zone.?]) p.worst_zone = z;
        }
    }
    p.death = 1 - survive;
    return p;
}

/// A pair of adjacent tiles near you to walk back and forth on: the best
/// encounter rate in your current zone, without damage tiles, entrances or
/// fixed battles.
pub fn grindSpot(g: *const Game) ?[2]dw.Warp {
    const here_zone = zoneAt(g.at.map, g.at.x, g.at.y) orelse return null;
    const h = dw.map_headers[g.at.map];
    const st = g.mapState();
    var best: ?[2]dw.Warp = null;
    var best_score: f32 = 0;
    var dy: i16 = -6;
    while (dy <= 6) : (dy += 1) {
        var dx: i16 = -6;
        while (dx <= 6) : (dx += 1) {
            const x = @as(i16, g.at.x) + dx;
            const y = @as(i16, g.at.y) + dy;
            if (x < 0 or y < 0 or x + 1 > h.max_x or y > h.max_y) continue;
            const a: dw.Warp = .{ .map = g.at.map, .x = @intCast(x), .y = @intCast(y) };
            const b: dw.Warp = .{ .map = g.at.map, .x = a.x + 1, .y = a.y };
            var score: f32 = 0;
            var ok = true;
            for ([2]dw.Warp{ a, b }) |w| {
                const t = dw.tileAt(game.maps, st, w.x, w.y);
                if (!dw.walkable(t) or dw.isEntrance(t) or t == .swamp or t == .barrier or
                    dw.fixedBattle(w.map, w.x, w.y, g.e4) != null or zoneAt(w.map, w.x, w.y) != here_zone) ok = false;
                score += encounterChance(g, w.map, t, w.x, w.y);
            }
            // Prefer closer spots when the rates tie.
            score -= @as(f32, @floatFromInt(@abs(dx) + @abs(dy))) * 0.0001;
            if (ok and score > best_score) {
                best_score = score;
                best = .{ a, b };
            }
        }
    }
    return best;
}

test "the safe route to Brecconary expects fewer fights than the fast one" {
    var g = try Game.new("Erdrick", 1);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expect(try g.leaveTown(&sink.writer));
    const goal = game.findTown("brec").?.entrance;
    var safe = (try plan(std.testing.allocator, &g, goal, .safe)).?;
    defer safe.deinit(std.testing.allocator);
    var fast = (try plan(std.testing.allocator, &g, goal, .fast)).?;
    defer fast.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.eql(safe.path[safe.path.len - 1], goal));
    try std.testing.expect(fast.steps <= safe.steps);
    try std.testing.expect(safe.hp_loss <= fast.hp_loss + 0.001);
}

test "Rimuldar is only reachable through the Swamp Cave" {
    var g = try Game.new("Erdrick", 1);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expect(try g.leaveTown(&sink.writer));
    var p = (try plan(std.testing.allocator, &g, game.findTown("rim").?.entrance, .balanced)).?;
    defer p.deinit(std.testing.allocator);
    try std.testing.expect(p.via_cave);
}

