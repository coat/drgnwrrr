//! One battle, driven a command at a time. The order of rolls follows the ROM:
//! start $E599 (HP, enemy flee, initiative), hero turn $E5CE (wake roll, then
//! the command), enemy turn $EB1B (wake roll, flee check $EB48, AI $EB4B).
//! The formulas are the ROM-checked ports in `dw`.
const std = @import("std");
const dw = @import("dw");
const game = @import("game.zig");
const Game = game.Game;
const Writer = std.Io.Writer;

pub const Command = union(enum) {
    fight,
    run,
    herb,
    cast: dw.Spell,
    /// The Fairy Flute ($E806): puts the Golem to sleep, no roll.
    flute,
};

pub const Outcome = enum { won, ran, enemy_fled, died };

pub const Battle = struct {
    id: dw.EnemyId,
    hp: u8,
    fixed: bool,
    enemy_asleep: bool = false,
    /// SLEEP just landed: the enemy's next turn skips its wake roll ($EB3E).
    skip_wake: bool = false,
    enemy_stopped: bool = false,
    hero_asleep: bool = false,
    hero_stopped: bool = false,
    outcome: ?Outcome = null,
    rounds: u32 = 0,
    hp_lost: u16 = 0,
    gold: u8 = 0,

    pub fn enemy(self: *const Battle) dw.Enemy {
        return dw.enemies[@backingInt(self.id)];
    }

    pub fn name(self: *const Battle, buf: *[24]u8) []const u8 {
        return game.enemyName(self.id, buf);
    }

    /// $E599-$E5C2.
    pub fn start(g: *Game, out: *Writer, id: dw.EnemyId, fixed: bool) Writer.Error!Battle {
        g.e0 = @backingInt(id);
        g.battles += 1;
        var b: Battle = .{ .id = id, .hp = dw.rollEnemyHp(&g.rng, id), .fixed = fixed };
        var nb: [24]u8 = undefined;
        try out.print("  A {s} draws near!\n", .{b.name(&nb)});
        const h = g.hero();
        if (dw.enemyFlees(&g.rng, h.stats.str, id)) {
            b.outcome = .enemy_fled;
            try out.print("  The {s} runs away.\n", .{b.name(&nb)});
        } else if (!dw.heroGoesFirst(&g.rng, id, h.stats.agi)) {
            try out.print("  The {s} attacks before you're ready!\n", .{b.name(&nb)});
            try b.enemyTurn(g, out);
        }
        return b;
    }

    /// $E5CE: true if you get to pick a command now. A sleeping hero rolls to
    /// wake first; if that fails, the enemy takes its turn instead.
    pub fn heroTurn(self: *Battle, g: *Game, out: *Writer) Writer.Error!bool {
        if (self.outcome != null) return false;
        self.rounds += 1;
        if (!self.hero_asleep) return true;
        if (dw.heroWakes(&g.rng)) {
            self.hero_asleep = false;
            try out.writeAll("  You wake up.\n");
            return true;
        }
        try out.writeAll("  You're still asleep.\n");
        try self.enemyTurn(g, out);
        return false;
    }

    /// Your command, then the enemy's turn. False if the command was refused
    /// without using the turn (unknown spell, not enough MP, no herbs...).
    pub fn act(self: *Battle, g: *Game, out: *Writer, cmd: Command) Writer.Error!bool {
        var nb: [24]u8 = undefined;
        const h = g.hero();
        switch (cmd) {
            .fight => {
                const r = dw.heroFight(&g.rng, h.attack, self.id, self.enemy_asleep);
                if (r.excellent) try out.writeAll("  Excellent move!\n");
                if (r.damage == 0) {
                    try out.writeAll("  You miss.\n");
                } else if (r.dodged) {
                    try out.print("  The {s} dodges.\n", .{self.name(&nb)});
                } else try self.hurtEnemy(g, out, r.damage);
            },
            .run => {
                if (dw.heroEscapes(&g.rng, self.id, h.stats.agi, self.enemy_asleep)) {
                    self.outcome = .ran;
                    try out.writeAll("  You get away.\n");
                } else try out.writeAll("  You try to run, but you're blocked.\n");
            },
            .herb => {
                if (g.inv.herbs == 0) {
                    try out.writeAll("  You have no herbs.\n");
                    return false;
                }
                try g.useHerb(out);
            },
            .flute => {
                if (!g.inv.has(.fairy_flute)) {
                    try out.writeAll("  You don't have the Fairy Flute.\n");
                    return false;
                }
                try out.writeAll("  You play the Fairy Flute.\n");
                if (dw.fluteSleeps(self.id)) {
                    // The same "still asleep" branch as SLEEP ($EB3E).
                    self.enemy_asleep = true;
                    self.skip_wake = true;
                    try out.print("  The {s} falls asleep.\n", .{self.name(&nb)});
                } else try out.writeAll("  But nothing happens.\n");
            },
            .cast => |spell| {
                if (!h.spells.contains(spell)) {
                    try out.writeAll("  You don't know that spell.\n");
                    return false;
                }
                switch (dw.battleCast(&g.mp, spell, self.hero_stopped)) {
                    .field_only => {
                        try out.writeAll("  That can't be used in battle.\n");
                        return false;
                    },
                    .not_enough_mp => {
                        try out.writeAll("  Not enough MP.\n");
                        return false;
                    },
                    .stopped => try out.writeAll("  Your spell has been blocked!\n"),
                    .cast => try self.castSpell(g, out, spell),
                }
            },
        }
        if (self.outcome == null) try self.enemyTurn(g, out);
        return true;
    }

    fn castSpell(self: *Battle, g: *Game, out: *Writer, spell: dw.Spell) Writer.Error!void {
        var nb: [24]u8 = undefined;
        const max = g.hero().stats.hp;
        const before = g.hp;
        switch (spell) {
            .heal, .healmore => {
                g.hp = dw.applyHeal(g.hp, max, dw.healAmount(&g.rng, if (spell == .heal) .heal else .healmore));
                try out.print("  {s}: +{d} HP.\n", .{ if (spell == .heal) "HEAL" else "HEALMORE", g.hp - before });
            },
            .hurt, .hurtmore => if (dw.heroHurt(&g.rng, self.id, spell == .hurtmore)) |dmg| {
                try self.hurtEnemy(g, out, dmg);
            } else try out.print("  The {s} resists.\n", .{self.name(&nb)}),
            .sleep => if (dw.spellLands(&g.rng, self.id, .sleep)) {
                self.enemy_asleep = true;
                self.skip_wake = true;
                try out.print("  The {s} falls asleep.\n", .{self.name(&nb)});
            } else try out.print("  The {s} resists.\n", .{self.name(&nb)}),
            .stopspell => if (dw.spellLands(&g.rng, self.id, .stopspell)) {
                self.enemy_stopped = true;
                try out.print("  The {s}'s spells are blocked.\n", .{self.name(&nb)});
            } else try out.print("  The {s} resists.\n", .{self.name(&nb)}),
            .radiant, .outside, .@"return", .repel => unreachable, // battleCast refuses these
        }
    }

    fn hurtEnemy(self: *Battle, g: *Game, out: *Writer, dmg: u8) Writer.Error!void {
        var nb: [24]u8 = undefined;
        self.hp -|= dmg;
        try out.print("  You hit the {s} for {d}.\n", .{ self.name(&nb), dmg });
        if (self.hp == 0) try self.win(g, out);
    }

    /// $EA0A: XP, then the gold roll, then gold; $EA63 the level-up text.
    fn win(self: *Battle, g: *Game, out: *Writer) Writer.Error!void {
        var nb: [24]u8 = undefined;
        self.outcome = .won;
        // $E99E / $E9B1: neither of the Dragonlord's forms reaches the XP and
        // gold code at $EA0A, so there's no gold roll.
        if (!dw.givesRewards(self.id)) {
            return out.print("  The {s} is defeated.\n", .{self.name(&nb)});
        }
        const before = g.hero();
        const e = self.enemy();
        g.xp = dw.addCapped(g.xp, e.xp);
        self.gold = dw.rollGold(&g.rng, self.id);
        g.gold = dw.addCapped(g.gold, self.gold);
        try out.print("  The {s} is defeated. +{d} XP, +{d} gold.\n", .{ self.name(&nb), e.xp, self.gold });
        if (dw.levelUp(before, g.hero())) |up| {
            try out.print("  Level up! Level {d}: +{d} STR, +{d} AGI, +{d} max HP, +{d} max MP.\n", .{ up.level, up.str, up.agi, up.hp, up.mp });
            if (up.spell_message) try out.writeAll("  You learned a new spell.\n");
        }
        // $E989 / $E96B: only on their own maps.
        if (self.id == .golem and g.at.map == 0x01) g.e4 |= dw.Story.golem_beaten;
        if (self.id == .green_dragon and g.at.map == 0x15) g.e4 |= dw.Story.green_dragon_beaten;
    }

    /// $EB1B.
    fn enemyTurn(self: *Battle, g: *Game, out: *Writer) Writer.Error!void {
        var nb: [24]u8 = undefined;
        const n = self.name(&nb);
        if (self.enemy_asleep) {
            if (self.skip_wake) {
                self.skip_wake = false;
                return out.print("  The {s} is asleep.\n", .{n});
            }
            if (!dw.enemyWakes(&g.rng)) return out.print("  The {s} is asleep.\n", .{n});
            self.enemy_asleep = false;
            try out.print("  The {s} wakes up.\n", .{n});
        }
        const h = g.hero();
        if (dw.enemyFlees(&g.rng, h.stats.str, self.id)) {
            self.outcome = .enemy_fled;
            return out.print("  The {s} runs away.\n", .{n});
        }
        const action = dw.chooseAction(&g.rng, self.id, self.hp, .{ .asleep = self.hero_asleep, .spell_stopped = self.hero_stopped });
        if (dw.enemySpellBlocked(action, self.enemy_stopped)) {
            return out.print("  The {s} casts {s}, but its spell is blocked.\n", .{ n, @tagName(action) });
        }
        switch (action) {
            .attack => {
                const dmg = dw.enemyAttack(&g.rng, self.enemy().str, h.defense);
                try out.print("  The {s} attacks", .{n});
                try self.hurtHero(g, out, dmg);
            },
            .sleep => {
                self.hero_asleep = true;
                try out.print("  The {s} casts SLEEP. You fall asleep.\n", .{n});
            },
            .stopspell => {
                const landed = dw.stopspellLands(&g.rng, g.armor());
                if (landed) self.hero_stopped = true;
                try out.print("  The {s} casts STOPSPELL{s}\n", .{ n, if (landed) ". Your spells are blocked." else ", but it fails." });
            },
            .heal, .healmore => {
                const amount = dw.enemyEffect(&g.rng, action, g.armor());
                self.hp = dw.enemyHealed(self.hp, self.id, amount);
                try out.print("  The {s} casts {s}. (HP {d})\n", .{ n, if (action == .heal) "HEAL" else "HEALMORE", self.hp });
            },
            .hurt, .hurtmore, .fire, .strong_fire => {
                const dmg = dw.enemyEffect(&g.rng, action, g.armor());
                try out.print("  The {s} {s}", .{ n, switch (action) {
                    .hurt => "casts HURT",
                    .hurtmore => "casts HURTMORE",
                    else => "breathes fire",
                } });
                try self.hurtHero(g, out, dmg);
            },
        }
    }

    fn hurtHero(self: *Battle, g: *Game, out: *Writer, dmg: u8) Writer.Error!void {
        const lost = @min(dmg, g.hp);
        g.hp -= lost;
        self.hp_lost += lost;
        if (dmg == 0) try out.writeAll(", but misses.\n") else try out.print(": {d} damage. (HP {d})\n", .{ dmg, g.hp });
        if (g.hp == 0) {
            self.outcome = .died;
            try out.writeAll("  You have died.\n");
        }
    }
};

/// What auto-battle does: heal when at a third of max HP or less, else fight.
pub fn autoCommand(g: *const Game, b: *const Battle) Command {
    const h = g.hero();
    if (b.id == .golem and !b.enemy_asleep and g.inv.has(.fairy_flute)) return .flute;
    if (@as(u16, g.hp) * 3 <= h.stats.hp) {
        if (!b.hero_stopped and h.spells.contains(.healmore) and g.mp >= dw.mp_cost[@backingInt(dw.Spell.healmore)]) return .{ .cast = .healmore };
        if (!b.hero_stopped and h.spells.contains(.heal) and g.mp >= dw.mp_cost[@backingInt(dw.Spell.heal)]) return .{ .cast = .heal };
        if (g.inv.herbs > 0) return .herb;
    }
    return .fight;
}

/// Runs a whole battle with `policy` choosing every command.
pub fn runBattle(g: *Game, out: *Writer, id: dw.EnemyId, fixed: bool, policy: *const fn (*const Game, *const Battle) Command) Writer.Error!Battle {
    var b = try Battle.start(g, out, id, fixed);
    while (b.outcome == null and b.rounds < 200) {
        if (!try b.heroTurn(g, out)) continue;
        _ = try b.act(g, out, policy(g, &b));
    }
    if (b.outcome == null) b.outcome = .ran; // can't happen in practice; keeps sims finite
    return b;
}

pub fn fightOnly(g: *const Game, b: *const Battle) Command {
    _ = g;
    _ = b;
    return .fight;
}

test "a level 1 hero beats a slime and the rolls follow the ROM order" {
    const g = try Game.new("Erdrick", 0x1234);
    var d: Writer.Discarding = .init(&.{});
    var won: u32 = 0;
    var seed: u16 = 0;
    while (seed < 200) : (seed += 1) {
        var c = g;
        c.rng = .init(seed);
        const b = try runBattle(&c, &d.writer, .slime, false, fightOnly);
        if (b.outcome.? == .won) {
            won += 1;
            try std.testing.expect(c.xp == 1);
        }
    }
    try std.testing.expect(won > 150);
}
