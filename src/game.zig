//! Game state and the rules around it: steps, towns, field commands and saves.
//! Every formula and table comes from `dw` (tools/romcheck/reference.zig),
//! which `zig build romcheck` checks against the original ROM. This file only
//! decides what happens in what order, and what is left out (graphics,
//! dialogue, NPCs).
const std = @import("std");
const dw = @import("dw");
const Writer = std.Io.Writer;

/// Bank 0's maps and NPC tables, extracted from the ROM at build time.
pub const maps: *const dw.Maps = &@import("romdata").maps;


pub const Game = struct {
    rng: dw.Rng,
    /// ASCII, padded with spaces. Only name-tile characters are allowed.
    name: [8]u8 = @splat(' '),
    xp: u16 = 0,
    gold: u16 = 0,
    hp: u8 = 0,
    mp: u8 = 0,
    equip: dw.Equipment = .{ .shield = 0, .armor = 0, .weapon = 0 },
    inv: dw.Inventory = .{},
    cf: u8 = 0,
    df: u8 = 0,
    e4: u8 = 0,
    magic_armor_steps: u8 = 0,
    repel: dw.Repel = .{},
    light: dw.Light = .{},
    chests: dw.ChestLog = .{},
    doors: dw.DoorLog = .{},
    /// $E0: the last tile stepped on, or the enemy ID after a battle.
    e0: u8 = 0,
    at: dw.Warp,
    steps: u32 = 0,
    battles: u32 = 0,
    /// The north shrine's old man has taken the harp and left. His NPC slot
    /// stays clear until the map loads again ($D32E).
    old_man_gone: bool = false,
    /// The ending has played.
    ended: bool = false,

    /// A new game: level 1, full HP and MP, in the throne room. The king's three
    /// chests (120 gold, a torch, a key) are opened for you; the gold chest
    /// makes its one RNG call ($E365).
    pub fn new(name: []const u8, seed: u16) error{BadName}!Game {
        var g: Game = .{ .rng = .init(seed), .at = .{ .map = 0x05, .x = 3, .y = 4 } };
        try g.setName(name);
        const h = g.hero();
        g.hp = h.stats.hp;
        g.mp = h.stats.mp;
        g.gold = dw.chestGold(&g.rng, 120, 0);
        g.inv.keys = 1;
        _ = g.inv.add(.torch);
        // Opened, so they read as floor and can't be taken twice ($E39A logs each one).
        for ([3][2]u8{ .{ 6, 1 }, .{ 5, 4 }, .{ 4, 4 } }) |c| g.chests.record(c[0], c[1]);
        return g;
    }

    pub fn setName(self: *Game, name: []const u8) error{BadName}!void {
        if (name.len == 0 or name.len > 8) return error.BadName;
        for (name) |c| if (dw.nameTile(c) == null) return error.BadName;
        self.name = @splat(' ');
        @memcpy(self.name[0..name.len], name);
    }

    pub fn nameSlice(self: *const Game) []const u8 {
        return std.mem.trimEnd(u8, &self.name, " ");
    }

    /// $F050: everything derived from XP, name and equipment.
    pub fn hero(self: *const Game) dw.Hero {
        return dw.heroFor(self.xp, dw.nameSum(self.nameSlice()).?, self.equip, self.cf & dw.Worn.dragons_scale != 0);
    }

    /// $C671 / $CD16: the status window turns red when HP <= max HP / 4 + 1,
    /// and white again above that. (Read from the ROM; not in romcheck.)
    pub fn lowHp(self: *const Game) bool {
        return self.hp <= (self.hero().stats.hp >> 2) + 1;
    }

    pub fn armor(self: *const Game) dw.Armor {
        return switch (self.equip.armor) {
            dw.magic_armor => .magic,
            dw.erdricks_armor => .erdricks,
            else => .other,
        };
    }

    /// Frames spent waiting for input: one RNG call each (porting rule 3).
    pub fn idle(self: *Game, frames: u32) void {
        dw.idleFrames(&self.rng, frames);
    }

    pub fn mapState(self: *const Game) dw.MapState {
        return .{ .map = self.at.map, .e0 = self.e0, .cf = self.cf, .df = self.df, .chests = self.chests, .doors = self.doors };
    }

    /// `map` as you'd find it on arriving from here, for planning a walk:
    /// arriving on the overworld clears both logs (bank 0 $AF2B), and the
    /// throne room marks its door and chests (you've left it, $AF3C). Other
    /// maps keep the logs as they are.
    pub fn mapStateOn(self: *const Game, map: u8) dw.MapState {
        var s = self.mapState();
        if (map == self.at.map) return s;
        s.map = map;
        if (map == 0x01) {
            s.chests = .{};
            s.doors = .{};
        }
        if (map == 0x05) markThroneRoom(&s.doors, &s.chests);
        return s;
    }

    pub fn tileAt(self: *const Game, x: u8, y: u8) dw.Tile {
        return dw.tileAt(maps, self.mapState(), x, y);
    }

    pub fn inTown(self: *const Game) bool {
        return townFor(self.at.map) != null;
    }

    pub const Step = union(enum) {
        blocked,
        moved,
        /// Walked onto a town or castle: the town menu takes over.
        town: *const Town,
        /// Walked into a cave or down/up stairs.
        entered: u8,
        /// An entrance or stairs this prototype can't follow.
        unsupported: dw.Warp,
        /// A closed door: openDoor() first (it takes a Magic Key).
        door,
        /// The Dragonlord is beaten and you reached the king ($CC19).
        ending,
        battle: Encounter,
        died,
    };

    pub const Encounter = struct {
        id: dw.EnemyId,
        fixed: bool,
        /// Where a successful RUN from a fixed battle puts you back.
        back: dw.Warp,
    };

    /// One move to (x, y) on the current map: $B1CC, $B219, then $CBF7.
    pub fn step(self: *Game, out: *Writer, x: u8, y: u8) Writer.Error!Step {
        const tile = switch (dw.move(maps, self.mapState(), x, y)) {
            .blocked => return if (self.tileAt(x, y) == .door) .door else .blocked,
            .exit => |w| return self.arrive(out, w),
            .step => |t| t,
        };
        if (self.npcAt(self.at.map, x, y)) return .blocked; // $B1F5
        const back = self.at;
        self.at.x = x;
        self.at.y = y;
        self.e0 = @backingInt(tile);
        self.idle(dw.step_polls); // the joypad read that started the move ($CA9F)
        self.steps += 1;

        const h = self.hero();
        var sh: dw.StepHero = .{ .hp = self.hp, .max_hp = h.stats.hp, .armor = self.equip.armor, .magic_armor_steps = self.magic_armor_steps, .cf = self.cf };
        const ev = dw.takeStep(&self.rng, &sh, .{
            .map = self.at.map,
            .map_flag = @backingInt(dw.mapKind(self.at.map)),
            .tile = tile,
            .x = x,
            .y = y,
            .hero_defense = h.defense,
            .repel_active = self.repel.active(),
        }, self.e4);
        self.hp = sh.hp;
        self.magic_armor_steps = sh.magic_armor_steps;

        // $CA56: the light and REPEL timers tick after the move.
        self.light.step();
        if (self.repel.step()) |what| try out.print("  ({s} has worn off.)\n", .{if (what == .repel) "REPEL" else "Fairy Water"});

        return switch (ev) {
            .none => .moved,
            .ending => .ending,
            .kicked_out => self.arrive(out, dw.edgeExit(0x04).?),
            .fixed_battle => |id| .{ .battle = .{ .id = id, .fixed = true, .back = back } },
            .battle => |id| .{ .battle = .{ .id = id, .fixed = false, .back = back } },
            .died => .died,
            .entrance => if (dw.warpForward(self.at)) |w| self.arrive(out, w) else .moved,
        };
    }

    /// The STAIRS command ($D9AF).
    pub fn stairs(self: *Game, out: *Writer) Writer.Error!Step {
        const w = dw.stairs(maps, self.mapState(), self.at.x, self.at.y) orelse {
            try out.writeAll("  There are no stairs here.\n");
            return .blocked;
        };
        return self.arrive(out, w);
    }

    /// A map change. Towns become menus; the overworld and dungeons are walked.
    pub fn arrive(self: *Game, out: *Writer, w: dw.Warp) Writer.Error!Step {
        if (!walkedMap(w.map) and townFor(w.map) == null) {
            try out.print("  ({s} isn't in this prototype yet.)\n", .{dw.map_names[w.map]});
            return .{ .unsupported = w };
        }
        if (w.map == 0x01) {
            // Bank 0 $AF2B: arriving on the overworld clears both logs.
            self.chests.clear();
            self.doors.clear();
        }
        if (w.map != 0x05) self.df |= dw.Quest.left_throne_room;
        if (dw.mapKind(w.map) != .dungeon) self.light = .{};
        self.old_man_gone = false; // a map load brings NPCs back
        self.at = w;
        if (w.map == 0x05) self.enterThroneRoom();
        if (townFor(w.map)) |t| return .{ .town = t };
        if (w.map != 0x01) try out.print("  You enter {s}.\n", .{dw.map_names[w.map]});
        return .{ .entered = w.map };
    }

    /// A stationary NPC standing at (x, y): bank 0 $B1F5 blocks the move.
    /// Moving NPCs wander, so they're left out.
    pub fn npcAt(self: *const Game, map: u8, x: u8, y: u8) bool {
        var buf: [20]dw.Npc = undefined;
        for (dw.npcs(maps, map, self.df, &buf)) |n| {
            if (n.moves or n.x != x or n.y != y) continue;
            if (map == 0x0D and self.old_man_gone and n.dialogue == 0x6C) continue;
            return true;
        }
        return false;
    }

    /// $DC42: the DOOR command. Opens the first closed door up, down, left or
    /// right of you, for one Magic Key.
    pub fn openDoor(self: *Game, out: *Writer) Writer.Error!bool {
        const dirs = [4][2]u8{ .{ 0, 0xFF }, .{ 0, 1 }, .{ 0xFF, 0 }, .{ 1, 0 } };
        var doors: [4]bool = undefined;
        for (dirs, 0..) |d, i| doors[i] = self.tileAt(self.at.x +% d[0], self.at.y +% d[1]) == .door;
        switch (dw.useKey(&self.inv, &self.doors, self.at.x, self.at.y, doors)) {
            .opened => {
                try out.print("  You open the door. ({d} keys left)\n", .{self.inv.keys});
                return true;
            },
            .no_door => try out.writeAll("  There's no door here.\n"),
            .no_key => try out.writeAll("  The door is locked, and you have no Magic Key.\n"),
            .lost => try out.writeAll("  The key is spent, but the door stays shut.\n"),
        }
        return false;
    }

    /// TAKE ($E1E3). Returns the item if your bag is full, for the throw-away
    /// question ($E07B).
    pub fn take(self: *Game, out: *Writer) Writer.Error!?dw.Item {
        const contents = if (self.tileAt(self.at.x, self.at.y) == .chest) dw.chestAt(self.at) else null;
        const c = contents orelse {
            try out.writeAll("  There's nothing to take here.\n");
            return null;
        };
        var equip: u8 = @bitCast(self.equip);
        const r = dw.takeChest(&self.rng, c, &self.inv, &self.gold, &equip, &self.df);
        self.equip = @bitCast(equip);
        self.chests.record(self.at.x, self.at.y); // $E39A
        switch (r) {
            .herb => try out.print("  You find a Herb. ({d} herbs)\n", .{self.inv.herbs}),
            .key => try out.print("  You find a Magic Key. ({d} keys)\n", .{self.inv.keys}),
            .full => try out.writeAll("  The chest is empty: you can't carry any more of those.\n"),
            .item => |it| try out.print("  You find {s}!\n", .{itemName(it)}),
            .no_room => |it| {
                try out.print("  You find {s}, but your bag is full.\n", .{itemName(it)});
                return it;
            },
            .gold => |n| try out.print("  You find {d} gold. ({d} gold)\n", .{ n, self.gold }),
            .erdricks_sword => try out.writeAll("  You find Erdrick's Sword and take it up!\n"),
            .already => try out.writeAll("  The chest is empty.\n"),
            .tablet => try out.writeAll("  You find Erdrick's Tablet: \"I have entrusted the Rainbow Drop's three ingredients... Seek the Token, the Staff and the Stones.\"\n"),
        }
        return null;
    }

    /// SEARCH ($E103). Returns the item if your bag is full.
    pub fn searchHere(self: *Game, out: *Writer) Writer.Error!?dw.Item {
        var equip: u8 = @bitCast(self.equip);
        const r = dw.search(self.at, self.tileAt(self.at.x, self.at.y), &self.inv, &equip, &self.cf);
        self.equip = @bitCast(equip);
        switch (r) {
            .nothing => try out.writeAll("  You search, but find nothing.\n"),
            .chest => try out.writeAll("  There's a treasure chest here. (`take`)\n"),
            .item => |it| try out.print("  You find {s}!\n", .{itemName(it)}),
            .no_room => |it| {
                try out.print("  You find {s}, but your bag is full.\n", .{itemName(it)});
                return it;
            },
            .erdricks_armor => try out.writeAll("  You find Erdrick's Armor and put it on!\n"),
            .hint => try out.writeAll("  \"Behind the throne, search and ye shall find.\" (try one step north)\n"),
            .charlock_stairs => try out.writeAll("  You find a hidden staircase!\n"),
        }
        return null;
    }

    /// The throw-away question ($E07B): make room for `item` by dropping
    /// `drop`, or give `item` up (null).
    pub fn makeRoom(self: *Game, out: *Writer, item: dw.Item, drop: ?dw.Item) Writer.Error!void {
        const d = drop orelse return out.print("  You leave {s} behind.\n", .{itemName(item)});
        if (!dw.droppable(d, self.cf) or !self.inv.has(d)) return out.print("  You can't throw that away. You leave {s} behind.\n", .{itemName(item)});
        self.inv.remove(d);
        _ = self.inv.add(item);
        try out.print("  You throw away {s} and take {s}.\n", .{ itemName(d), itemName(item) });
    }

    pub const Talk = enum { nothing, dragonlord, ending };

    /// TALK: the NPCs that do something. Town services (shops, inns, MP) are
    /// menu commands; these are the rest.
    pub fn talk(self: *Game, out: *Writer) Writer.Error!Talk {
        const at = self.at;
        // Gwaelin, from any side ($D051 looks at the tile you face).
        const dirs = [4][2]u8{ .{ 0, 0xFF }, .{ 0, 1 }, .{ 0xFF, 0 }, .{ 1, 0 } };
        for (dirs) |d| {
            if (self.tileAt(at.x +% d[0], at.y +% d[1]) == .princess) {
                self.df |= dw.Quest.carrying_princess;
                try out.writeAll("  Princess Gwaelin: \"Will thou take me to the castle?\" You carry her in your arms.\n");
                return .nothing;
            }
        }
        if ((at.map == 0x04 or at.map == 0x05) and self.e4 & dw.Story.dragonlord_beaten != 0) return .ending;
        if (at.map == 0x04 or at.map == 0x05) {
            if (self.df & dw.Quest.carrying_princess != 0) {
                const r = dw.returnPrincess(&self.inv, &self.df);
                try out.writeAll("  The king: \"Thou hast brought back my daughter!\" Gwaelin gives you her love.\n");
                if (r.taken) |t| try out.print("  (The king made room by taking {s}.)\n", .{itemName(t)});
                if (!r.love) try out.writeAll("  (Your bag was too full for Gwaelin's Love.)\n");
                return .nothing;
            }
        }
        var sbuf: [20]dw.NpcService = undefined;
        for (self.services(&sbuf)) |sv| switch (sv) {
            .remove_curse => {
                if (dw.removeCurse(&self.inv, &self.cf)) {
                    try out.writeAll("  \"Thou art cursed! I shall free thee.\" The curse is lifted.\n");
                } else try out.writeAll("  \"If thou art cursed, come to me.\"\n");
                return .nothing;
            },
            else => {},
        };
        var nbuf: [20]dw.Npc = undefined;
        for (dw.npcs(maps, at.map, self.df, &nbuf)) |n| {
            if (n.moves or !nearNpc(self, n)) continue;
            switch (dw.npcService(n.dialogue, self.e4)) {
                .staff_shrine => {
                    switch (dw.staffShrine(&self.inv)) {
                        .have_it => try out.writeAll("  \"Thou hast the Staff already.\"\n"),
                        .hint => try out.writeAll("  \"Bring me the Silver Harp, and I shall give thee the Staff of Rain.\"\n"),
                        .harp_taken => {
                            self.old_man_gone = true;
                            try out.writeAll("  The old man takes the Silver Harp and steps aside. The Staff of Rain is in the chest behind him.\n");
                        },
                    }
                    return .nothing;
                },
                .rainbow_shrine => {
                    switch (dw.rainbowShrine(&self.inv)) {
                        .have_it => try out.writeAll("  \"Thou hast the Rainbow Drop already.\"\n"),
                        .missing => try out.writeAll("  \"Bring the Stones of Sunlight and the Staff of Rain.\"\n"),
                        .kicked_out => {
                            try out.writeAll("  \"Thou hast no token of Erdrick. Begone!\"\n");
                            _ = try self.arrive(out, dw.edgeExit(0x0E).?);
                        },
                        .rainbow_drop => try out.writeAll("  The Stones and the Staff join: you receive the Rainbow Drop!\n"),
                    }
                    return .nothing;
                },
                .dragonlord => return .dragonlord,
                else => {},
            }
        }
        try out.writeAll("  No one answers.\n");
        return .nothing;
    }

    pub const throne_room_door = [2]u8{ 4, 7 };
    /// The king on his throne (stationary NPC, dialogue 0x6E).
    pub const king: dw.Warp = .{ .map = 0x05, .x = 3, .y = 3 };

    /// Bank 0 $AF3C: once you've left the throne room, every load of it marks
    /// its door and three chests as opened. Before that, the door is locked.
    fn enterThroneRoom(self: *Game) void {
        if (self.df & dw.Quest.left_throne_room == 0) return;
        markThroneRoom(&self.doors, &self.chests);
    }

    fn markThroneRoom(doors: *dw.DoorLog, chests: *dw.ChestLog) void {
        doors.slots[7] = throne_room_door; // $601A
        chests.markThroneRoom(.{ .{ 6, 1 }, .{ 5, 4 }, .{ 4, 4 } }); // $6026-$602B
    }

    /// Off the edge of the town, as the ROM does it ($B228). From the throne
    /// room you go down the stairs to the castle first; the first time, its
    /// door needs the key from the king's chest. False if you're locked in.
    pub fn leaveTown(self: *Game, out: *Writer) Writer.Error!bool {
        if (self.at.map == 0x05 and !self.doors.opened(throne_room_door[0], throne_room_door[1])) {
            // Standing above the door at (4, 6); $DC42 checks up, down, left, right.
            switch (dw.useKey(&self.inv, &self.doors, 4, 6, .{ false, true, false, false })) {
                .opened => try out.writeAll("  You unlock the throne room door with the magic key.\n"),
                .no_key => {
                    try out.writeAll("  The throne room door is locked, and you have no key.\n");
                    return false;
                },
                .lost, .no_door => {
                    try out.writeAll("  The key is spent, but the door stays shut.\n");
                    return false;
                },
            }
        }
        const map: u8 = if (self.at.map == 0x05) 0x04 else self.at.map; // the throne room is upstairs
        _ = try self.arrive(out, dw.edgeExit(map).?);
        return true;
    }

    /// $EDB4 / $CB47. The caller has already said you died.
    pub fn die(self: *Game, out: *Writer) Writer.Error!void {
        const h = self.hero();
        const r = dw.die(self.gold, self.mp, h.stats.hp, h.stats.mp, self.cf);
        self.gold = r.gold;
        self.hp = r.hp;
        self.mp = r.mp;
        self.repel = .{};
        self.df &= ~dw.Quest.carrying_princess;
        if (r.at.map == 0x01) {
            _ = try self.arrive(out, r.at);
        } else {
            self.at = r.at;
            self.enterThroneRoom();
        }
        try out.print("  You wake in Tantegel Castle. Gold halved to {d}.\n", .{self.gold});
    }

    // ---------- field commands ----------

    pub fn useHerb(self: *Game, out: *Writer) Writer.Error!void {
        if (self.inv.herbs == 0) return out.writeAll("  You have no herbs.\n");
        self.inv.herbs -= 1;
        const before = self.hp;
        self.hp = dw.applyHerb(self.hp, self.hero().stats.hp, dw.healAmount(&self.rng, .herb));
        try out.print("  Herb: +{d} HP ({d} herbs left).\n", .{ self.hp - before, self.inv.herbs });
    }

    pub fn castField(self: *Game, out: *Writer, spell: dw.Spell) Writer.Error!?Step {
        const h = self.hero();
        if (!h.spells.contains(spell)) {
            try out.writeAll("  You don't know that spell.\n");
            return null;
        }
        const before = self.hp;
        switch (dw.fieldCast(&self.mp, spell, self.at.map)) {
            .not_enough_mp => try out.writeAll("  Not enough MP.\n"),
            .nothing_happened => try out.writeAll("  But nothing happened. (MP spent)\n"),
            .heal => {
                self.hp = dw.applyHeal(self.hp, h.stats.hp, dw.healAmount(&self.rng, .heal));
                try out.print("  HEAL: +{d} HP.\n", .{self.hp - before});
            },
            .healmore => {
                self.hp = dw.applyHeal(self.hp, h.stats.hp, dw.healAmount(&self.rng, .healmore));
                try out.print("  HEALMORE: +{d} HP.\n", .{self.hp - before});
            },
            .radiant => {
                self.light.castRadiant();
                try out.writeAll("  The area brightens.\n");
            },
            .repel => {
                self.repel.castRepel();
                try out.writeAll("  REPEL: weaker monsters will keep away for 127 steps.\n");
            },
            .warp => |w| return try self.arrive(out, w),
        }
        return null;
    }

    pub fn useItem(self: *Game, out: *Writer, item: dw.Item) Writer.Error!?Step {
        if (item == .herb) {
            try self.useHerb(out);
            return null;
        }
        if (item == .magic_key or !self.inv.has(item)) {
            try out.writeAll("  You can't use that here.\n");
            return null;
        }
        switch (dw.fieldItem(item, .{ .map = self.at.map, .x = self.at.x, .y = self.at.y }, self.cf)) {
            .herb => unreachable, // handled above
            .torch => {
                self.inv.remove(item);
                self.light.useTorch();
                try out.writeAll("  The torch lights the way.\n");
            },
            .fairy_water => {
                self.inv.remove(item);
                self.repel.useFairyWater();
                try out.writeAll("  Fairy Water: weaker monsters will keep away for 127 steps.\n");
            },
            .wings => {
                self.inv.remove(item);
                return try self.arrive(out, dw.return_dest);
            },
            .wear => try out.print("  {s}\n", .{if (dw.wear(&self.cf, item)) "You put it on." else "You're already wearing it."}),
            .harp => return .{ .battle = .{ .id = dw.silverHarp(&self.rng), .fixed = false, .back = self.at } },
            .rainbow_bridge => {
                self.cf |= dw.Worn.rainbow_bridge;
                try out.writeAll("  A rainbow bridge appears!\n");
            },
            .love => {
                const r = dw.gwaelinsLove(self.xp, .{ .map = self.at.map, .x = self.at.x, .y = self.at.y });
                if (r.xp_to_next) |n| try out.print("  {d} XP to the next level.", .{n}) else try out.writeAll("  You're at the top level.");
                if (r.from_tantegel) |d| try out.print(" Tantegel is {d} east-west, {d} north-south.", .{ -d.dx, -d.dy });
                try out.writeAll("\n");
            },
            .cant_use_here => try out.writeAll("  You can't use that here.\n"),
            .nothing_happened => try out.writeAll("  Nothing happens.\n"),
        }
        return null;
    }

    // ---------- towns ----------

    pub fn inn(self: *Game, out: *Writer, price: u8) Writer.Error!void {
        const h = self.hero();
        if (dw.stayAtInn(&self.gold, price, &self.hp, &self.mp, h.stats.hp, h.stats.mp)) {
            try out.print("  You rest. HP {d}/{d}, MP {d}/{d}. {d} gold left.\n", .{ self.hp, h.stats.hp, self.mp, h.stats.mp, self.gold });
        } else try out.print("  The inn costs {d} gold; you have {d}.\n", .{ price, self.gold });
    }

    /// The old man in Tantegel who restores MP.
    pub fn restoreMp(self: *Game, out: *Writer) Writer.Error!void {
        self.mp = self.hero().stats.mp;
        try out.print("  Your MP is restored ({d}).\n", .{self.mp});
    }

    /// The NPC services of the town you're in, read from the ROM's NPC
    /// tables (dw.npcs, dw.npcService). None once the Dragonlord is beaten.
    pub fn services(self: *const Game, buf: *[20]dw.NpcService) []dw.NpcService {
        const t = townFor(self.at.map) orelse return buf[0..0];
        var npcs: [20]dw.Npc = undefined;
        var n: usize = 0;
        for (dw.npcs(maps, t.map, self.df, &npcs)) |npc| {
            const s = dw.npcService(npc.dialogue, self.e4);
            if (s == .talk) continue;
            buf[n] = s;
            n += 1;
        }
        return buf[0..n];
    }

    /// Where each of `services` stands, in the same order, on the town's map.
    pub fn serviceSpots(self: *const Game, buf: *[20]dw.Warp) []dw.Warp {
        const t = townFor(self.at.map) orelse return buf[0..0];
        var npcs: [20]dw.Npc = undefined;
        var n: usize = 0;
        for (dw.npcs(maps, t.map, self.df, &npcs)) |npc| {
            if (dw.npcService(npc.dialogue, self.e4) == .talk) continue;
            buf[n] = .{ .map = t.map, .x = npc.x, .y = npc.y };
            n += 1;
        }
        return buf[0..n];
    }

    pub fn innPrice(self: *const Game) ?u8 {
        var buf: [20]dw.NpcService = undefined;
        for (self.services(&buf)) |s| if (s == .inn) return dw.inn_prices[s.inn];
        return null;
    }

    pub fn canRestoreMp(self: *const Game) bool {
        var buf: [20]dw.NpcService = undefined;
        for (self.services(&buf)) |s| if (s == .restore_mp) return true;
        return false;
    }

    /// Everything for sale in town, shop by shop: weapons and armor, tools,
    /// keys, then Fairy Water (each kind in NPC order).
    pub fn catalog(self: *const Game, buf: *[48]Offer) []Offer {
        var sbuf: [20]dw.NpcService = undefined;
        var n: usize = 0;
        const services_ = self.services(&sbuf);
        const order = [_]std.meta.Tag(dw.NpcService){ .equipment, .items, .keys, .fairy_water };
        for (order) |kind| for (services_, 0..) |s, shop| {
            if (std.meta.activeTag(s) != kind) continue;
            const sh: u8 = @intCast(shop);
            switch (s) {
                .equipment, .items => |list| for (dw.shop_stock[list]) |index| {
                    buf[n] = .{ .shop = sh, .kind = s, .what = if (index < 17) .{ .equipment = index } else .{ .item = index } };
                    n += 1;
                },
                .keys => |i| {
                    buf[n] = .{ .shop = sh, .kind = s, .what = .{ .key = dw.key_prices[i] } };
                    n += 1;
                },
                .fairy_water => {
                    buf[n] = .{ .shop = sh, .kind = s, .what = .fairy_water };
                    n += 1;
                },
                else => {},
            }
        };
        return buf[0..n];
    }

    pub fn buy(self: *Game, out: *Writer, offer: Offer) Writer.Error!void {
        switch (offer.what) {
            .equipment => |index| return self.buyEquipment(out, index),
            .key => |price| return switch (dw.buyKey(&self.gold, &self.inv, price)) {
                .bought => out.print("  Bought a Magic Key. {d} gold left.\n", .{self.gold}),
                .not_enough_gold => out.print("  A key costs {d} gold; you have {d}.\n", .{ price, self.gold }),
                .full => out.writeAll("  You can't carry any more keys.\n"),
            },
            .item, .fairy_water => {},
        }
        const item: dw.Item = switch (offer.what) {
            .item => |index| @fromBackingInt(index - 15),
            else => .fairy_water,
        };
        const price = offer.price();
        switch (dw.buyItem(&self.gold, &self.inv, item, price)) {
            .bought => try out.print("  Bought {s}. {d} gold left.\n", .{ itemName(item), self.gold }),
            .not_enough_gold => try out.print("  {s} costs {d} gold; you have {d}.\n", .{ itemName(item), price, self.gold }),
            .full => try out.writeAll("  You can't carry any more.\n"),
        }
    }

    fn buyEquipment(self: *Game, out: *Writer, index: u8) Writer.Error!void {
        {
            const before = self.equip;
            if (!dw.buyEquipment(&self.gold, &self.equip, index)) {
                return out.print("  {s} costs {d} gold; you have {d}.\n", .{ shop_names[index], dw.prices[index], self.gold });
            }
            const old = switch (index) {
                0...6 => equipName(0, before.weapon),
                7...13 => equipName(7, before.armor),
                else => equipName(14, before.shield),
            };
            return out.print("  Bought {s}{s}{s}. {d} gold left.\n", .{ shop_names[index], if (old != null) ", trading in " else "", old orelse "", self.gold });
        }
    }

    pub fn sell(self: *Game, out: *Writer, item: dw.Item) Writer.Error!void {
        const have = switch (item) {
            .herb => self.inv.herbs > 0,
            .magic_key => self.inv.keys > 0,
            else => self.inv.has(item),
        };
        if (!have) return out.writeAll("  You don't have that.\n");
        switch (dw.sell(&self.gold, &self.inv, item, self.cf)) {
            .sold => try out.print("  Sold {s}. {d} gold.\n", .{ itemName(item), self.gold }),
            .worthless => try out.writeAll("  The shopkeeper won't buy that.\n"),
            .cursed => try out.writeAll("  It's cursed and won't come off.\n"),
        }
    }

    // ---------- saves ----------

    pub fn record(self: *const Game) dw.SaveRecord {
        var tiles: [8]u8 = undefined;
        for (self.name, 0..) |c, i| tiles[i] = dw.nameTile(c).?;
        return .{
            .xp = self.xp,
            .gold = self.gold,
            .slots = self.inv.slots,
            .keys = self.inv.keys,
            .herbs = self.inv.herbs,
            .equipment = @bitCast(self.equip),
            .cf = self.cf,
            .df = self.df,
            .e4 = self.e4,
            .name = tiles,
            .message_speed = 1,
            .hp = self.hp,
            .mp = self.mp,
            .start_flag = 0xAB,
        };
    }

    /// $F9DF. Leaves the RNG equal to the record's CRC, like the ROM.
    pub fn save(self: *Game, sram: *[dw.Sram.size]u8, slot: u2) void {
        dw.Sram.save(sram, slot, self.record(), &self.rng);
    }

    /// $FAC1. You continue at the king, with the RNG set to the record's CRC.
    pub fn load(sram: *[dw.Sram.size]u8, slot: u2) ?Game {
        var rng: dw.Rng = .init(0);
        const rec = dw.Sram.load(sram, slot, &rng) orelse return null;
        var g: Game = .{ .rng = rng, .at = .{ .map = 0x05, .x = 3, .y = 4 } };
        for (rec.name, 0..) |t, i| g.name[i] = tileChar(t) orelse ' ';
        g.xp = rec.xp;
        g.gold = rec.gold;
        g.inv = .{ .herbs = rec.herbs, .keys = rec.keys, .slots = rec.slots };
        g.equip = @bitCast(rec.equipment);
        g.cf = rec.cf;
        g.df = rec.df;
        g.e4 = rec.e4;
        g.hp = rec.hp;
        g.mp = rec.mp;
        if (rec.start_flag == 0x78) {
            const h = g.hero();
            g.hp = h.stats.hp;
            g.mp = h.stats.mp;
        }
        g.enterThroneRoom(); // continuing loads the throne room
        return g;
    }
};

/// Maps the prototype walks tile by tile: the overworld and the caves.
/// Every map can be walked: the overworld, caves, and towns too (their
/// services work from anywhere inside, but quest spots are walked to).
pub fn walkedMap(map: u8) bool {
    return map >= 0x01 and map <= 0x1D;
}

// ---------- towns ----------

/// Next to the NPC, or across a counter from it (TALK reaches across 0x0E, $CFF9).
pub fn nearNpc(g: *const Game, n: dw.Npc) bool {
    const dx = @as(i16, n.x) - g.at.x;
    const dy = @as(i16, n.y) - g.at.y;
    if (@abs(dx) + @abs(dy) == 1) return true;
    if (@abs(dx) + @abs(dy) == 2 and (dx == 0 or dy == 0)) {
        const mx: u8 = @intCast(@as(i16, g.at.x) + @divExact(dx, 2));
        const my: u8 = @intCast(@as(i16, g.at.y) + @divExact(dy, 2));
        return g.tileAt(mx, my) == .counter;
    }
    return false;
}

/// What a town offers comes from its NPCs (Game.services); this is just
/// where it is and what it's called.
pub const Town = struct {
    name: []const u8,
    map: u8,
    /// Overworld entrance.
    entrance: dw.Warp,
    /// The king saves your game. He's in the throne room, not an NPC service.
    king: bool = false,
};

/// One thing for sale. `shop` numbers the seller within the town.
pub const Offer = struct {
    shop: u8,
    kind: dw.NpcService,
    what: union(enum) {
        /// dw.prices index 0-16.
        equipment: u8,
        /// dw.prices index 17+ (item code + 15).
        item: u8,
        /// Price from dw.key_prices.
        key: u8,
        fairy_water,
    },

    pub fn price(self: Offer) u16 {
        return switch (self.what) {
            .equipment, .item => |i| dw.prices[i],
            .key => |p| p,
            .fairy_water => dw.fairy_water_price,
        };
    }

    pub fn name(self: Offer) []const u8 {
        return switch (self.what) {
            .equipment, .item => |i| shop_names[i],
            .key => "Magic Key",
            .fairy_water => "Fairy Water",
        };
    }
};

pub const towns = [_]Town{
    .{ .name = "Tantegel", .map = 0x04, .entrance = .{ .map = 0x01, .x = 43, .y = 43 }, .king = true },
    .{ .name = "Brecconary", .map = 0x08, .entrance = .{ .map = 0x01, .x = 48, .y = 41 } },
    .{ .name = "Garinham", .map = 0x09, .entrance = .{ .map = 0x01, .x = 2, .y = 2 } },
    .{ .name = "Kol", .map = 0x07, .entrance = .{ .map = 0x01, .x = 104, .y = 10 } },
    .{ .name = "Rimuldar", .map = 0x0B, .entrance = .{ .map = 0x01, .x = 102, .y = 72 } },
    .{ .name = "Cantlin", .map = 0x0A, .entrance = .{ .map = 0x01, .x = 73, .y = 102 } },
};

pub fn townFor(map: u8) ?*const Town {
    const m: u8 = if (map == 0x05) 0x04 else map; // throne room = Tantegel
    for (&towns) |*t| if (t.map == m) return t;
    return null;
}

pub fn findTown(name: []const u8) ?*const Town {
    for (&towns) |*t| if (std.ascii.startsWithIgnoreCase(t.name, name)) return t;
    return null;
}

// ---------- names ----------

/// dw.prices order.
pub const shop_names = [33][]const u8{
    "Bamboo Pole",  "Club",           "Copper Sword",   "Hand Axe",       "Broad Sword",  "Flame Sword",     "Erdrick's Sword",
    "Clothes",      "Leather Armor",  "Chain Mail",     "Half Plate",     "Full Plate",   "Magic Armor",     "Erdrick's Armor",
    "Small Shield", "Large Shield",   "Silver Shield",  "Herb",           "Magic Key",    "Torch",           "Fairy Water",
    "Wings",        "Dragon's Scale", "Fairy Flute",    "Fighter's Ring", "Erdrick's Token", "Gwaelin's Love", "Cursed Belt",
    "Silver Harp",  "Death Necklace", "Stones of Sunlight", "Staff of Rain", "Rainbow Drop",
};

pub fn itemName(item: dw.Item) []const u8 {
    return shop_names[@as(usize, @backingInt(item)) + 15];
}

/// `base` is 0, 7 or 14; `value` is the 1-based equipment value (0 = none).
pub fn equipName(base: u8, value: u8) ?[]const u8 {
    return if (value == 0) null else shop_names[base + value - 1];
}

pub fn findItem(name: []const u8) ?dw.Item {
    inline for (@typeInfo(dw.Item).@"enum".field_names) |f| {
        const item = @field(dw.Item, f);
        if (matches(itemName(item), name)) return item;
    }
    return null;
}

pub fn findSpell(name: []const u8) ?dw.Spell {
    inline for (@typeInfo(dw.Spell).@"enum".field_names) |f| {
        if (std.ascii.eqlIgnoreCase(f, name)) return @field(dw.Spell, f);
    }
    return null;
}

/// Case-insensitive prefix match that ignores spaces and apostrophes,
/// so "fairy", "fairywater" and "dragons" all work.
pub fn matches(full: []const u8, typed: []const u8) bool {
    if (typed.len == 0) return false;
    var i: usize = 0;
    for (typed) |c| {
        if (c == ' ' or c == '\'' or c == '_') continue;
        while (i < full.len and (full[i] == ' ' or full[i] == '\'')) i += 1;
        if (i >= full.len or std.ascii.toLower(full[i]) != std.ascii.toLower(c)) return false;
        i += 1;
    }
    return true;
}

pub fn enemyName(id: dw.EnemyId, buf: *[24]u8) []const u8 {
    const tag = switch (id) {
        .dragonlord1, .dragonlord2 => "dragonlord",
        else => @tagName(id),
    };
    var cap = true;
    for (tag, 0..) |c, i| {
        buf[i] = if (c == '_') ' ' else if (cap) std.ascii.toUpper(c) else c;
        cap = c == '_';
    }
    return buf[0..tag.len];
}

/// Inverse of dw.nameTile, for loading saves.
fn tileChar(t: u8) ?u8 {
    inline for (0..128) |c| {
        if (comptime dw.nameTile(c)) |v| if (v == t) return c;
    }
    return null;
}

// ---------- tests ----------

test "a new game starts in the throne room with the king's chests" {
    const g = try Game.new("Erdrick", 0);
    try std.testing.expectEqual(120, g.gold);
    try std.testing.expectEqual(1, g.inv.keys);
    try std.testing.expect(g.inv.has(.torch));
    try std.testing.expectEqual(g.hero().stats.hp, g.hp);
    try std.testing.expect(g.inTown());
}

test "save and load round trip, and the RNG becomes the CRC" {
    var g = try Game.new("Lu", 7);
    g.xp = 300;
    var sram: [dw.Sram.size]u8 = @splat(0);
    g.save(&sram, 0);
    const l = Game.load(&sram, 0).?;
    try std.testing.expectEqualStrings("Lu", l.nameSlice());
    try std.testing.expectEqual(300, l.xp);
    try std.testing.expectEqual(g.rng.state, l.rng.state);
}

test "leaving Tantegel puts you on the castle tile" {
    var g = try Game.new("Lu", 7);
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try std.testing.expect(try g.leaveTown(&w));
    try std.testing.expectEqual(dw.Warp{ .map = 1, .x = 43, .y = 43 }, g.at);
    try std.testing.expectEqual(dw.Tile.castle, g.tileAt(43, 43));
}

test "names" {
    try std.testing.expect(matches("Dragon's Scale", "dragons"));
    try std.testing.expect(matches("Fairy Water", "fairywater"));
    try std.testing.expect(!matches("Herb", "herbs"));
    try std.testing.expectEqual(dw.Item.fairy_water, findItem("fairy").?);
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("Metal Slime", enemyName(.metal_slime, &b));
}

test "the key opens the throne room door once; after that it's always open" {
    var g = try Game.new("Lu", 7);
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try std.testing.expectEqual(dw.Tile.door, g.tileAt(Game.throne_room_door[0], Game.throne_room_door[1]));
    try std.testing.expect(try g.leaveTown(&w));
    try std.testing.expectEqual(0, g.inv.keys);
    // Die and wake in the throne room: $AF3C has marked the door open.
    try g.die(&w);
    try std.testing.expectEqual(0x05, g.at.map);
    try std.testing.expectEqual(dw.Tile.brick, g.tileAt(Game.throne_room_door[0], Game.throne_room_door[1]));
    try std.testing.expect(try g.leaveTown(&w));
}

test "without the key you're locked in" {
    var g = try Game.new("Lu", 7);
    g.inv.keys = 0;
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try std.testing.expect(!try g.leaveTown(&w));
    try std.testing.expectEqual(0x05, g.at.map);
}

test "town services come from the ROM's NPC tables" {
    var g = try Game.new("Lu", 1);
    var buf: [48]Offer = undefined;
    // Tantegel: an MP restorer and a key seller (85), no inn.
    try std.testing.expect(g.canRestoreMp());
    try std.testing.expectEqual(null, g.innPrice());
    const tantegel = g.catalog(&buf);
    try std.testing.expectEqual(1, tantegel.len);
    try std.testing.expectEqual(85, tantegel[0].price());

    g.at = .{ .map = 0x08, .x = 0, .y = 15 }; // Brecconary
    try std.testing.expectEqual(6, g.innPrice().?);
    var names: [48][]const u8 = undefined;
    for (g.catalog(&buf), 0..) |o, i| names[i] = o.name();
    const brecconary = names[0..g.catalog(&buf).len];
    try std.testing.expectEqualStrings("Bamboo Pole", brecconary[0]);
    try std.testing.expectEqualStrings("Fairy Water", brecconary[brecconary.len - 1]);

    g.at = .{ .map = 0x0A, .x = 15, .y = 0 }; // Cantlin: 3 equipment, 2 tool shops, keys, Fairy Water
    var sbuf: [20]dw.NpcService = undefined;
    try std.testing.expectEqual(7, g.services(&sbuf).len - 1); // plus the inn

    g.e4 |= dw.Story.dragonlord_beaten; // $D134: nobody does business after that
    try std.testing.expectEqual(0, g.services(&sbuf).len);
}
