//! The story checklist: what the game only tells you through dialogue, as a
//! list of objectives with where to go and what to do there. Whether each is
//! done comes from the same flags and inventory the ROM keeps.
const std = @import("std");
const dw = @import("dw");
const game = @import("game.zig");
const Game = game.Game;

/// `fight`: a guardian stands on the next tile; step `toward` it.
pub const Action = enum { search, take, talk, use_rainbow_drop, arrive, fight };

pub const Spot = struct {
    at: dw.Warp,
    /// Stand next to it (an NPC), rather than on it.
    beside: bool = false,
    action: Action,
    /// For `fight`: the move onto the guarded tile.
    toward: []const u8 = "",
};

pub const Objective = struct {
    name: []const u8,
    where: []const u8,
    /// What you need first, if anything.
    needs: []const u8 = "",
    optional: bool = false,
    done: *const fn (g: *const Game) bool,
    spot: *const fn (g: *const Game) Spot,
};

fn has(g: *const Game, item: dw.Item) bool {
    return g.inv.has(item);
}

/// In story order, as the game leads you: the king's daughter, what you'll
/// want on the road, the three relics the south shrine joins into the Rainbow
/// Drop, then Charlock. `go <n>` numbers them this way. Erdrick's Tablet isn't
/// here: the ROM keeps no flag for it, so it couldn't survive a save.
pub const objectives = [_]Objective{
    .{
        .name = "Rescue Princess Gwaelin",
        .where = "the Swamp Cave (5, 18), past the Green Dragon",
        .done = struct {
            fn f(g: *const Game) bool {
                return g.df & (dw.Quest.carrying_princess | dw.Quest.princess_returned) != 0;
            }
        }.f,
        .spot = struct {
            fn f(g: *const Game) Spot {
                // Stop short of the Green Dragon at (4, 14), so the fight is yours to start.
                if (g.e4 & dw.Story.green_dragon_beaten == 0)
                    return .{ .at = .{ .map = 0x15, .x = 4, .y = 13 }, .action = .fight, .toward = "s" };
                return .{ .at = dw.gwaelin, .beside = true, .action = .talk };
            }
        }.f,
    },
    .{
        .name = "Bring Gwaelin to the king",
        .where = "Tantegel: talk to the king while you carry her",
        .needs = "Princess Gwaelin",
        .done = struct {
            fn f(g: *const Game) bool {
                return g.df & dw.Quest.princess_returned != 0;
            }
        }.f,
        .spot = struct {
            fn f(_: *const Game) Spot {
                return .{ .at = .{ .map = 0x04, .x = 11, .y = 29 }, .action = .talk }; // just inside the gate
            }
        }.f,
    },
    .{
        .name = "Fairy Flute",
        .where = "buried in Kol (9, 6); it puts the Golem to sleep",
        .done = struct {
            fn f(g: *const Game) bool {
                return has(g, .fairy_flute) or g.e4 & dw.Story.golem_beaten != 0;
            }
        }.f,
        .spot = struct {
            fn f(_: *const Game) Spot {
                return .{ .at = .{ .map = 0x07, .x = 9, .y = 6 }, .action = .search };
            }
        }.f,
    },
    .{
        .name = "Silver Harp",
        .where = "a chest in Garin's Grave B3 (13, 6), under Garinham",
        .done = struct {
            fn f(g: *const Game) bool {
                return has(g, .silver_harp) or has(g, .staff_of_rain) or has(g, .rainbow_drop);
            }
        }.f,
        .spot = struct {
            fn f(_: *const Game) Spot {
                return .{ .at = .{ .map = 0x1A, .x = 13, .y = 6 }, .action = .take };
            }
        }.f,
    },
    .{
        .name = "Staff of Rain",
        .where = "the north shrine: give the old man the Silver Harp, then take the chest behind him",
        .needs = "Silver Harp",
        .done = struct {
            fn f(g: *const Game) bool {
                return has(g, .staff_of_rain) or has(g, .rainbow_drop);
            }
        }.f,
        .spot = struct {
            fn f(g: *const Game) Spot {
                if (g.old_man_gone) return .{ .at = .{ .map = 0x0D, .x = 3, .y = 4 }, .action = .take };
                return .{ .at = .{ .map = 0x0D, .x = 4, .y = 4 }, .beside = true, .action = .talk };
            }
        }.f,
    },
    .{
        .name = "Erdrick's Armor",
        .where = "buried in Hauksness (18, 12), where the Axe Knight stands guard",
        .done = struct {
            fn f(g: *const Game) bool {
                return g.equip.armor == dw.erdricks_armor;
            }
        }.f,
        .spot = struct {
            fn f(_: *const Game) Spot {
                return .{ .at = .{ .map = 0x03, .x = 18, .y = 12 }, .action = .search };
            }
        }.f,
    },
    .{
        .name = "Erdrick's Token",
        .where = "buried in the southern swamp, overworld (83, 113)",
        .done = struct {
            fn f(g: *const Game) bool {
                return has(g, .erdricks_token);
            }
        }.f,
        .spot = struct {
            fn f(_: *const Game) Spot {
                return .{ .at = .{ .map = 0x01, .x = 83, .y = 113 }, .action = .search };
            }
        }.f,
    },
    .{
        .name = "Stones of Sunlight",
        .where = "a chest in Tantegel's basement (4, 5)",
        .done = struct {
            fn f(g: *const Game) bool {
                return has(g, .stones_of_sunlight) or has(g, .rainbow_drop);
            }
        }.f,
        .spot = struct {
            fn f(_: *const Game) Spot {
                return .{ .at = .{ .map = 0x0C, .x = 4, .y = 5 }, .action = .take };
            }
        }.f,
    },
    .{
        .name = "Rainbow Drop",
        .where = "the south shrine's old man joins the Stones and the Staff (he turns away anyone without Erdrick's Token)",
        .needs = "Erdrick's Token, Staff of Rain, Stones of Sunlight",
        .done = struct {
            fn f(g: *const Game) bool {
                return has(g, .rainbow_drop);
            }
        }.f,
        .spot = struct {
            fn f(_: *const Game) Spot {
                return .{ .at = .{ .map = 0x0E, .x = 4, .y = 5 }, .beside = true, .action = .talk };
            }
        }.f,
    },
    .{
        .name = "Rainbow Bridge",
        .where = "use the Rainbow Drop on the shore at (65, 49), facing Charlock",
        .needs = "Rainbow Drop",
        .done = struct {
            fn f(g: *const Game) bool {
                return g.cf & dw.Worn.rainbow_bridge != 0;
            }
        }.f,
        .spot = struct {
            fn f(_: *const Game) Spot {
                return .{ .at = .{ .map = 0x01, .x = 65, .y = 49 }, .action = .use_rainbow_drop };
            }
        }.f,
    },
    .{
        .name = "Charlock's hidden stairs",
        .where = "search behind the throne in Charlock Castle (10, 1)",
        .needs = "Rainbow Bridge",
        .done = struct {
            fn f(g: *const Game) bool {
                return g.cf & dw.charlock_stairs_found != 0;
            }
        }.f,
        .spot = struct {
            fn f(_: *const Game) Spot {
                return .{ .at = .{ .map = 0x02, .x = 10, .y = 1 }, .action = .search };
            }
        }.f,
    },
    .{
        .name = "Erdrick's Sword",
        .where = "a chest in Charlock B2 (5, 5)",
        .needs = "Charlock's hidden stairs",
        .done = struct {
            fn f(g: *const Game) bool {
                return g.equip.weapon == 7;
            }
        }.f,
        .spot = struct {
            fn f(_: *const Game) Spot {
                return .{ .at = .{ .map = 0x10, .x = 5, .y = 5 }, .action = .take };
            }
        }.f,
    },
    .{
        .name = "Defeat the Dragonlord",
        .where = "the bottom of Charlock, on his throne (16, 24)",
        .needs = "Charlock's hidden stairs",
        .done = struct {
            fn f(g: *const Game) bool {
                return g.e4 & dw.Story.dragonlord_beaten != 0;
            }
        }.f,
        .spot = struct {
            fn f(_: *const Game) Spot {
                return .{ .at = .{ .map = 0x06, .x = 16, .y = 24 }, .beside = true, .action = .talk };
            }
        }.f,
    },
};

/// Tiles to stand on to do `spot`: the spot itself, or the open tiles beside
/// it (or across a counter from it, for TALK).
pub fn standingTiles(g: *const Game, spot: Spot, buf: *[8]dw.Warp) []dw.Warp {
    if (!spot.beside) {
        buf[0] = spot.at;
        return buf[0..1];
    }
    var n: usize = 0;
    const dirs = [4][2]i8{ .{ 0, -1 }, .{ 0, 1 }, .{ -1, 0 }, .{ 1, 0 } };
    const s = g.mapStateOn(spot.at.map);
    for (dirs) |d| for ([_]i8{ 1, 2 }) |dist| {
        const x = @as(i16, spot.at.x) + d[0] * dist;
        const y = @as(i16, spot.at.y) + d[1] * dist;
        if (x < 0 or y < 0) continue;
        const w: dw.Warp = .{ .map = spot.at.map, .x = @intCast(x), .y = @intCast(y) };
        if (dist == 2) {
            const mid = dw.tileAt(game.maps, s, @intCast(@as(i16, spot.at.x) + d[0]), @intCast(@as(i16, spot.at.y) + d[1]));
            if (mid != .counter) continue;
        }
        const t = dw.tileAt(game.maps, s, w.x, w.y);
        if (!dw.walkable(t) or g.npcAt(w.map, w.x, w.y)) continue;
        buf[n] = w;
        n += 1;
    };
    return buf[0..n];
}

test "a new game has done nothing on the checklist" {
    const g = try Game.new("Lu", 1);
    for (objectives) |o| try std.testing.expect(!o.done(&g));
    var buf: [8]dw.Warp = undefined;
    // The Dragonlord is reached across a counter.
    try std.testing.expect(standingTiles(&g, find("Defeat the Dragonlord").spot(&g), &buf).len > 0);
}

/// The objective named `name`; for tests, which shouldn't care about the order.
pub fn find(name: []const u8) Objective {
    for (objectives) |o| if (std.mem.eql(u8, o.name, name)) return o;
    unreachable;
}
