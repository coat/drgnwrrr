//! romcheck: differential tests of the reference ports against the original ROM.
//!
//! Each case runs a Dragon Warrior routine in the 6502 interpreter and the matching port in
//! reference.zig from the same inputs and RNG state, then compares the result and the RNG
//! state afterwards (so missing or extra RNG calls are caught too).
//!
//! Usage: romcheck [rom-path] [--full]
//!   Without --full, inputs are sampled (a few seconds). With --full, most sections are
//!   exhaustive (about 140 million cases, a few minutes in ReleaseFast).
//!   If the ROM is missing, prints a notice and exits successfully.
const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;
const dw = @import("reference.zig");

/// Dragon Warrior (U) as checked against docs/formula_guide.txt.
const expected_sha1 = "a794907cdfc17c6056320ac2810461976c5d3403";
const prg_size = 4 * 0x4000;

var rom: []const u8 = undefined;
/// Bank 0's maps and NPC tables, decoded from the ROM once (dw.Maps.fromBank0).
var rom_maps: dw.Maps = undefined;
var mem: [0x10000]u8 = undefined;
var cpu: Cpu = .{ .mem = &mem };

/// Sampling strides: 1 everywhere in --full mode.
const Strides = struct {
    /// RAND values (0..255).
    rand: u32,
    /// Stat values such as STR/DEF/ATK/AGI/HP (0..255).
    stat: u32,
    /// Multiplier on RNG-state strides.
    state: u32,
};
var strides: Strides = .{ .rand = 5, .stat = 3, .state = 61 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var rom_path: []const u8 = "dragon_warrior.nes";
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--full")) {
            strides = .{ .rand = 1, .stat = 1, .state = 1 };
        } else {
            rom_path = arg;
        }
    }

    rom = std.Io.Dir.cwd().readFileAlloc(init.io, rom_path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("romcheck: {s} not found, skipping (pass a ROM path to check)\n", .{rom_path});
            return;
        },
        else => return err,
    };
    try checkRom();
    rom_maps = .fromBank0(rom[16..][0..0x4000]);

    std.debug.print("romcheck: {s} ({s})\n", .{ rom_path, if (strides.rand == 1) "full" else "quick, use --full for exhaustive" });
    try runAll();
}

fn checkRom() !void {
    if (rom.len < 16 + prg_size or !std.mem.eql(u8, rom[0..4], "NES\x1a")) {
        std.debug.print("romcheck: not an iNES ROM\n", .{});
        return error.BadRom;
    }
    const mapper = (rom[6] >> 4) | (rom[7] & 0xF0);
    if (rom[4] != 4 or mapper != 1) {
        std.debug.print("romcheck: expected 4 PRG banks on MMC1, got {d} banks on mapper {d}\n", .{ rom[4], mapper });
        return error.BadRom;
    }
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(rom, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, expected_sha1)) {
        std.debug.print("romcheck: warning: sha1 {s} differs from the checked revision {s}\n", .{ &hex, expected_sha1 });
    }
}

fn loadBanks(bank: usize) void {
    @memset(mem[0..0x8000], 0);
    @memcpy(mem[0x8000..0xC000], rom[16 + bank * 0x4000 ..][0..0x4000]);
    @memcpy(mem[0xC000..], rom[16 + 3 * 0x4000 ..][0..0x4000]);
}

fn setRng(state: u16) void {
    mem[0x94] = @truncate(state);
    mem[0x95] = @truncate(state >> 8);
}

fn romRng() u16 {
    return @as(u16, mem[0x94]) | (@as(u16, mem[0x95]) << 8);
}

/// Start at `start` with a return address that leads to $0000, and stop at $0000
/// (returned) or any address in `stops`. Returns the stop PC.
fn run(start: u16, stops: []const u16) !u16 {
    mem[0x1FF] = 0xFF;
    mem[0x1FE] = 0xFF;
    cpu.sp = 0xFD;
    cpu.pc = start;
    var n: u32 = 0;
    while (true) : (n += 1) {
        if (cpu.pc == 0x0000) return 0;
        for (stops) |s| if (cpu.pc == s) return s;
        if (cpu.pc == 0xFF74) { // wait-for-NMI: no RNG call, so just return
            const lo = mem[0x100 | @as(u16, cpu.sp +% 1)];
            const hi = mem[0x100 | @as(u16, cpu.sp +% 2)];
            cpu.sp +%= 2;
            cpu.pc = (@as(u16, lo) | (@as(u16, hi) << 8)) +% 1;
            continue;
        }
        if (n > 1_000_000) return error.Runaway;
        cpu.step() catch |e| {
            std.debug.print("6502 {s} at ${X:0>4}\n", .{ @errorName(e), cpu.pc -% 1 });
            return e;
        };
    }
}

/// pre[r] = an RNG state whose next output is r.
var pre: [256]u16 = undefined;

fn initPre() void {
    var found: [256]bool = @splat(false);
    var s: u32 = 0;
    while (s < 0x10000) : (s += 1) {
        var r: dw.Rng = .init(@intCast(s));
        const v = r.next();
        if (!found[v]) {
            found[v] = true;
            pre[v] = @intCast(s);
        }
    }
}

var checks: u64 = 0;
var failures: u64 = 0;

fn expect(name: []const u8, ok: bool, comptime fmt: []const u8, args: anytype) void {
    checks += 1;
    if (ok) return;
    failures += 1;
    if (failures <= 20) std.debug.print("MISMATCH {s}: " ++ fmt ++ "\n", .{name} ++ args);
}

fn setEnemy(id: u8) void {
    const e = dw.enemies[id];
    mem[0x0100] = e.str;
    mem[0x0101] = e.agi;
    mem[0x0102] = e.hp;
    mem[0x0103] = e.pattern;
    mem[0x0104] = e.sr;
    mem[0x0105] = e.dr;
    mem[0x0106] = e.xp;
    mem[0x0107] = e.gp;
    mem[0xE0] = id;
}

const Section = struct {
    checks: u64,
    failures: u64,

    fn begin() Section {
        return .{ .checks = checks, .failures = failures };
    }

    fn end(self: Section, name: []const u8) void {
        const status = if (failures == self.failures) "ok" else "FAIL";
        std.debug.print("  {s:<34} {d:>12} cases  {s}\n", .{ name, checks - self.checks, status });
    }
};

/// Values 0..255 with `step`, always including 255.
fn byteValues(step: u32, buf: *[256]u8) []const u8 {
    var n: usize = 0;
    var v: u32 = 0;
    while (v < 256) : (v += step) {
        buf[n] = @intCast(v);
        n += 1;
    }
    if (buf[n - 1] != 255) {
        buf[n] = 255;
        n += 1;
    }
    return buf[0..n];
}

fn runAll() !void {
    loadBanks(1);
    initPre();

    var rand_buf: [256]u8 = undefined;
    var stat_buf: [256]u8 = undefined;
    const rands = byteValues(strides.rand, &rand_buf);
    const stats = byteValues(strides.stat, &stat_buf);
    const ss = strides.state;

    {
        const sec: Section = .begin();
        var s: u32 = 0;
        while (s < 0x10000) : (s += 1) {
            setRng(@intCast(s));
            _ = try run(0xC55B, &.{});
            var r: dw.Rng = .init(@intCast(s));
            _ = r.next();
            expect("rng", romRng() == r.state and @intFromBool(cpu.c) == r.carry, "s={x}", .{s});
        }
        sec.end("RNG $C55B (+carry)");
    }

    {
        const sec: Section = .begin();
        for (stats) |str| for (stats) |def| for (rands) |r| {
            mem[0x42] = str;
            mem[0x43] = def;
            setRng(pre[r]);
            _ = try run(0xEFF4, &.{});
            var g: dw.Rng = .init(pre[r]);
            const z = dw.enemyAttack(&g, str, def);
            expect("enemyAttack", mem[0x3C] == z and romRng() == g.state, "str={d} def={d} r={d} rom={d} zig={d}", .{ str, def, r, mem[0x3C], z });
        };
        sec.end("Enemy attack $EFF4");
    }

    {
        const sec: Section = .begin();
        for (stats) |atk| for (stats) |agi| for (rands) |r| {
            mem[0x42] = atk;
            mem[0x43] = agi;
            setRng(pre[r]);
            _ = try run(0xEFE5, &.{});
            var g: dw.Rng = .init(pre[r]);
            const z = dw.heroDamage(&g, atk, agi);
            expect("heroDamage", mem[0x3C] == z and romRng() == g.state, "atk={d} agi={d} r={d} rom={d} zig={d}", .{ atk, agi, r, mem[0x3C], z });
        };
        sec.end("Hero damage $EFE5");
    }

    {
        const sec: Section = .begin();
        for (0..256) |atk| for (rands) |r| {
            mem[0xCC] = @intCast(atk);
            setRng(pre[r]);
            _ = try run(0xE634, &.{0xE64E});
            var g: dw.Rng = .init(pre[r]);
            expect("excellent", cpu.a == dw.excellentDamage(&g, @intCast(atk)), "atk={d} r={d}", .{ atk, r });
        };
        sec.end("Excellent move $E634");
    }

    {
        const sec: Section = .begin();
        for (0..40) |id| for ([_]bool{ false, true }) |asleep| for ([_]u8{ 1, 20, 60, 140, 255 }) |atk| {
            var s: u32 = 0;
            while (s < 0x10000) : (s += 7 * ss) {
                setEnemy(@intCast(id));
                mem[0xCC] = atk;
                mem[0x42] = atk;
                mem[0x43] = dw.enemies[id].agi;
                mem[0xDF] = if (asleep) 0x40 else 0;
                setRng(@intCast(s));
                // $E615: Dragonlord check, then the excellent roll. Stop before the BRK sound call.
                var pc = try run(0xE615, &.{ 0xE628, 0xE651 });
                const excellent = pc == 0xE628;
                if (excellent) {
                    _ = try run(0xE634, &.{0xE64E}); // A = damage, then JMP $E664
                } else {
                    _ = try run(0xEFE5, &.{}); // JSR $EFE5
                    cpu.a = mem[0x3C];
                }
                const dmg = cpu.a;
                var dodged = false;
                if (excellent or dmg != 0) {
                    pc = try run(if (excellent) 0xE664 else 0xE654, &.{ 0xE685, 0xE69A, 0xE658 });
                    dodged = pc == 0xE685;
                }
                var g: dw.Rng = .init(@intCast(s));
                const z = dw.heroFight(&g, atk, @fromBackingInt(@intCast(id)), asleep);
                expect("heroFight", z.damage == dmg and z.excellent == excellent and z.dodged == dodged and romRng() == g.state, "id={d} s={x} asleep={} rom=({d},{},{}) zig=({d},{},{})", .{ id, s, asleep, dmg, excellent, dodged, z.damage, z.excellent, z.dodged });
            }
        };
        sec.end("Hero FIGHT $E615-$E69A");
    }

    {
        const sec: Section = .begin();
        for (0..39) |id| { // Dragonlord 2nd form skips the roll at $E585
            var s: u32 = 0;
            while (s < 0x10000) : (s += ss) {
                setEnemy(@intCast(id));
                setRng(@intCast(s));
                _ = try run(0xE599, &.{0xE5BC});
                var g: dw.Rng = .init(@intCast(s));
                expect("hp", mem[0xE2] == dw.rollEnemyHp(&g, @fromBackingInt(@intCast(id))), "id={d} s={x}", .{ id, s });

                setRng(@intCast(s));
                _ = try run(0xEA2A, &.{0xEA48});
                g = .init(@intCast(s));
                expect("gold", mem[0x00] == dw.rollGold(&g, @fromBackingInt(@intCast(id))), "id={d} s={x}", .{ id, s });
            }
        }
        sec.end("Enemy HP roll $E599, gold $EA2A");
    }

    {
        const sec: Section = .begin();
        const heals = .{
            .{ 0xDBB8, 0xDBCF, dw.HealKind.heal },
            .{ 0xDBD7, 0xDBCF, dw.HealKind.healmore },
            .{ 0xDCFE, 0xDD12, dw.HealKind.herb },
        };
        for (stats) |max| for (stats) |hp| for (rands) |r| {
            if (hp > max) continue;
            inline for (heals) |t| {
                mem[0xC5] = hp;
                mem[0xCA] = max;
                setRng(pre[r]);
                _ = try run(t[0], &.{t[1]});
                var g: dw.Rng = .init(pre[r]);
                const amount = dw.healAmount(&g, t[2]);
                const z = if (t[2] == .herb) dw.applyHerb(hp, max, amount) else dw.applyHeal(hp, max, amount);
                expect("heal", mem[0xC5] == z, "{s} hp={d} max={d} r={d} rom={d} zig={d}", .{ @tagName(t[2]), hp, max, r, mem[0xC5], z });
            }
        };
        sec.end("Herb / HEAL / HEALMORE");
    }

    {
        const sec: Section = .begin();
        for (0..40) |id| {
            const enemy: dw.EnemyId = @fromBackingInt(@intCast(id));
            var s: u32 = 0;
            while (s < 0x10000) : (s += 3 * ss) {
                for ([_]bool{ false, true }) |more| {
                    setEnemy(@intCast(id));
                    setRng(@intCast(s));
                    const pc = try run(if (more) 0xE755 else 0xE73A, &.{ 0xE769, 0xE74E, 0xE954 });
                    var g: dw.Rng = .init(@intCast(s));
                    const z = dw.heroHurt(&g, enemy, more);
                    const ok = if (pc == 0xE954) z == null else (z != null and z.? == cpu.a);
                    expect("heroHurt", ok and romRng() == g.state, "id={d} s={x}", .{ id, s });
                }
                for ([_]dw.ResistKind{ .sleep, .stopspell }) |kind| {
                    setEnemy(@intCast(id));
                    setRng(@intCast(s));
                    const pc = try run(if (kind == .sleep) 0xE770 else 0xE78A, &.{ 0xE77A, 0xE792, 0xE954 });
                    var g: dw.Rng = .init(@intCast(s));
                    expect("resist", (pc != 0xE954) == dw.spellLands(&g, enemy, kind), "id={d} s={x}", .{ id, s });
                }
            }
        }
        sec.end("Hero spells + resist $E73A $E946");
    }

    {
        const sec: Section = .begin();
        const stops = [_]u16{ 0xEC92, 0xEC69, 0xECA6, 0xECCE, 0xEC23, 0xEC55, 0xECED, 0xECE1, 0xEBC1 };
        const actions = [_]dw.Action{ .sleep, .stopspell, .heal, .healmore, .hurt, .hurtmore, .fire, .strong_fire, .attack };
        for (0..40) |id| {
            const t = dw.enemies[id].hp;
            for ([_]u8{ 1, t >> 2, (t >> 2) + 1, t }) |hp| for (0..4) |status| {
                var s: u32 = 0;
                while (s < 0x10000) : (s += ss) {
                    setEnemy(@intCast(id));
                    mem[0xE2] = hp;
                    mem[0xDF] = (if (status & 1 != 0) @as(u8, 0x80) else 0) | (if (status & 2 != 0) @as(u8, 0x10) else 0);
                    setRng(@intCast(s));
                    const pc = try run(0xEB4B, &stops);
                    const rom_action = actions[std.mem.indexOfScalar(u16, &stops, pc) orelse return error.UnexpectedExit];
                    var g: dw.Rng = .init(@intCast(s));
                    const z = dw.chooseAction(&g, @fromBackingInt(@intCast(id)), hp, .{ .asleep = status & 1 != 0, .spell_stopped = status & 2 != 0 });
                    expect("ai", z == rom_action and romRng() == g.state, "id={d} hp={d} st={d} s={x} rom={s} zig={s}", .{ id, hp, status, s, @tagName(rom_action), @tagName(z) });
                }
            };
        }
        sec.end("Enemy AI $EB4B");
    }

    {
        const sec: Section = .begin();
        const effects = .{
            .{ 0xEC2A, 0xEC52, dw.Action.hurt },
            .{ 0xEC5C, 0xEC52, dw.Action.hurtmore },
            .{ 0xECED, 0xED14, dw.Action.fire },
            .{ 0xECE1, 0xED14, dw.Action.strong_fire },
        };
        for ([_]u8{ 0x00, 0x04, 0x18, 0x1C }) |be| for (0..256) |r| {
            const armor: dw.Armor = switch (be) {
                0x1C => .erdricks,
                0x18 => .magic,
                else => .other,
            };
            inline for (effects) |t| {
                mem[0xBE] = be;
                setRng(pre[r]);
                _ = try run(t[0], &.{t[1]});
                var g: dw.Rng = .init(pre[r]);
                const z = dw.enemyEffect(&g, t[2], armor);
                expect("enemyEffect", mem[0x00] == z, "{s} armor={x} r={d} rom={d} zig={d}", .{ @tagName(t[2]), be, r, mem[0x00], z });
            }
        };
        for (0..40) |id| for (stats) |hp| for (rands) |r| {
            inline for (.{ .{ 0xECAD, dw.Action.heal }, .{ 0xECD5, dw.Action.healmore } }) |t| {
                setEnemy(@intCast(id));
                mem[0xE2] = hp;
                setRng(pre[r]);
                _ = try run(t[0], &.{0xECC4});
                var g: dw.Rng = .init(pre[r]);
                const z = dw.enemyHealed(hp, @fromBackingInt(@intCast(id)), dw.enemyEffect(&g, t[1], .other));
                expect("enemyHeal", mem[0xE2] == z, "id={d} hp={d} r={d}", .{ id, hp, r });
            }
        };
        sec.end("Enemy HURT/fire/HEAL $EC2A-$ED14");
    }

    {
        const sec: Section = .begin();
        var s: u32 = 0;
        while (s < 0x10000) : (s += 1) {
            setRng(@intCast(s));
            var pc = try run(0xE5D6, &.{ 0xE5DE, 0xE5E5 });
            var g: dw.Rng = .init(@intCast(s));
            expect("heroWakes", (pc == 0xE5E5) == dw.heroWakes(&g), "s={x}", .{s});

            setRng(@intCast(s));
            pc = try run(0xEB21, &.{ 0xEB2E, 0xEB3E });
            g = .init(@intCast(s));
            expect("enemyWakes", (pc == 0xEB2E) == dw.enemyWakes(&g) and romRng() == g.state, "s={x}", .{s});

            for ([_]u8{ 0x00, 0x18, 0x1C }) |be| {
                mem[0xBE] = be;
                setRng(@intCast(s));
                pc = try run(0xEC70, &.{ 0xEC80, 0xEC8E });
                g = .init(@intCast(s));
                const armor: dw.Armor = if (be == 0x1C) .erdricks else if (be == 0x18) .magic else .other;
                expect("stopspell", (pc == 0xEC80) == dw.stopspellLands(&g, armor) and romRng() == g.state, "s={x}", .{s});
            }
        }
        sec.end("Wake rolls, STOPSPELL on hero");
    }

    {
        const sec: Section = .begin();
        for (0..40) |id| {
            var s: u32 = 0;
            while (s < 0x10000) : (s += ss) {
                setEnemy(@intCast(id));
                setRng(@intCast(s));
                const pc = try run(0xE66E, &.{ 0xE685, 0xE69A });
                var g: dw.Rng = .init(@intCast(s));
                expect("dodge", (pc == 0xE685) == dw.enemyDodges(&g, @fromBackingInt(@intCast(id))) and romRng() == g.state, "id={d} s={x}", .{ id, s });
            }
        }
        sec.end("Dodge $E66E (+$95 write)");
    }

    {
        const sec: Section = .begin();
        for (0..40) |id| for ([_]u8{ 0, 1, 4, 10, 30, 60, 100, 150, 200, 255 }) |agi| {
            const enemy: dw.EnemyId = @fromBackingInt(@intCast(id));
            var s: u32 = 0;
            while (s < 0x10000) : (s += 5 * ss) {
                setEnemy(@intCast(id));
                mem[0xC9] = agi;
                setRng(@intCast(s));
                _ = try run(0xEE91, &.{});
                var g: dw.Rng = .init(@intCast(s));
                expect("run", cpu.c == dw.heroEscapes(&g, enemy, agi, false) and romRng() == g.state, "id={d} agi={d} s={x}", .{ id, agi, s });

                setRng(@intCast(s));
                _ = try run(0xEEC0, &.{});
                g = .init(@intCast(s));
                expect("initiative", cpu.c == dw.heroGoesFirst(&g, enemy, agi), "id={d} agi={d} s={x}", .{ id, agi, s });
            }
        };
        for (0..40) |id| for (0..256) |hstr| {
            var s: u32 = 0;
            while (s < 0x10000) : (s += 257) {
                setEnemy(@intCast(id));
                mem[0xC8] = @intCast(hstr);
                setRng(@intCast(s));
                const pc = try run(0xEFB7, &.{ 0xEFC8, 0xEFE4 });
                var g: dw.Rng = .init(@intCast(s));
                expect("flee", (pc == 0xEFC8) == dw.enemyFlees(&g, @intCast(hstr), @fromBackingInt(@intCast(id))) and romRng() == g.state, "id={d} str={d}", .{ id, hstr });
            }
        };
        sec.end("Run / initiative / enemy flee");
    }

    {
        const sec: Section = .begin();
        for (0..40) |id| for (0..256) |def| {
            mem[0x45] = 1;
            mem[0xDB] = 0xFF;
            mem[0xCD] = @intCast(def);
            mem[0x3C] = @intCast(id);
            const pc = try run(0xCF20, &.{0xCF44});
            expect("repel", (pc == 0) == dw.repelled(@intCast(def), dw.enemies[id].str), "id={d} def={d}", .{ id, def });
        };
        for (0..256) |start| {
            mem[0xDB] = @intCast(start);
            const pc = try run(0xCA6C, &.{ 0xCA7C, 0xCA9B });
            var r: dw.Repel = .{ .counter = @intCast(start) };
            expect("repelStep", (pc == 0xCA7C) == (r.step() != null), "start={x}", .{start});
        }
        for (0..256) |timer| for ([_]u8{ 1, 3, 5, 7 }) |radius| {
            mem[0xDA] = @intCast(timer);
            mem[0xD0] = radius;
            _ = try run(0xCA56, &.{0xCA6C});
            var l: dw.Light = .{ .radius = radius, .timer = @intCast(timer) };
            l.step();
            expect("radiant", mem[0xDA] == l.timer and mem[0xD0] == l.radius, "t={d} r={d}", .{ timer, radius });
        };
        sec.end("REPEL $CF20 $CA6C, Radiant $CA56");
    }

    {
        const sec: Section = .begin();
        const tiles = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x0B, 0x0C, 0x0D };
        const seeds = [_]u16{ 0x0000, 0x0001, 0x1234, 0x8000, 0xBEEF, 0xFFFF, 0x4242, 0x0F0F, 0x7777, 0xC0DE, 0x2B2C, 0x9999 };
        const seed_count: usize = if (ss == 1) seeds.len else 3;
        for (0..120) |x| for (0..120) |y| for (tiles) |tile| for (seeds[0..seed_count]) |seed| {
            try stepCase(0x01, 0x20, @intCast(x), @intCast(y), tile, seed);
        };
        const maps = [_]u8{ 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0E, 0x0F, 0x10, 0x14, 0x17, 0x19, 0x1A, 0x1B, 0x1C, 0x1D };
        for (maps) |map| for ([_]u8{ 0x20, 0x00 }) |flag| {
            // Town maps never have $16 = 0x20; the ROM would index past $F542.
            if (map < 0x0F and flag == 0x20 and map != 2 and map != 3 and map != 6) continue;
            var s: u32 = 0;
            while (s < 0x10000) : (s += ss) try stepCase(map, flag, 5, 5, 0x04, @intCast(s));
        };
        sec.end("Encounter step $CDC6-$CF1E");
    }

    {
        const sec: Section = .begin();
        for (0..256) |sum| for (dw.level_stats) |base| {
            mem[0xB5] = @intCast(sum);
            mem[0xB6] = 0;
            mem[0xB7] = 0;
            mem[0xB8] = 0;
            mem[0xC8] = base.str;
            mem[0xC9] = base.agi;
            mem[0xCA] = base.hp;
            mem[0xCB] = base.mp;
            _ = try run(0xF085, &.{0xF0CD});
            const z = dw.applyName(base, @intCast(sum));
            expect("name", mem[0xC8] == z.str and mem[0xC9] == z.agi and mem[0xCA] == z.hp and mem[0xCB] == z.mp, "sum={d} base-str={d}", .{ sum, base.str });
        };
        sec.end("Name stats $F085");
    }

    {
        const sec: Section = .begin();
        var s: u32 = 0;
        while (s < 0x10000) : (s += 1) {
            setRng(@intCast(s));
            _ = try run(0xDE1E, &.{0xDE2D});
            var g: dw.Rng = .init(@intCast(s));
            expect("harp", cpu.a == @backingInt(dw.silverHarp(&g)) and romRng() == g.state, "s={x}", .{s});

            for ([_]u8{ 0x0E, 0x12, 0x13, 0x14, 0x15, 0x16 }) |chest| {
                const gc = dw.goldChest(chest).?;
                mem[0x3E] = gc.mask;
                mem[0x00] = @truncate(gc.base);
                mem[0x01] = @truncate(gc.base >> 8);
                setRng(@intCast(s));
                _ = try run(0xE365, &.{0xE377});
                g = .init(@intCast(s));
                const rom_gold = @as(u16, mem[0x00]) | (@as(u16, mem[0x01]) << 8);
                expect("chest", rom_gold == dw.chestGold(&g, gc.base, gc.mask), "chest={x} s={x}", .{ chest, s });
            }

            for ([_]bool{ false, true }) |found| {
                mem[0xDF] = if (found) 0x04 else 0;
                setRng(@intCast(s));
                const pc = try run(0xE254, &.{ 0xE263, 0xE288 });
                g = .init(@intCast(s));
                expect("necklace", (pc == 0xE263) == (dw.mountainCaveChest(&g, found) == .death_necklace), "s={x}", .{s});
            }
        }
        sec.end("Harp / chests $DE1E $E365 $E254");
    }

    {
        const sec: Section = .begin();
        var xp: u32 = 0;
        while (xp < 0x10000) : (xp += 1) {
            const lv = dw.levelFor(@intCast(xp));
            mem[0xBA] = @truncate(xp);
            mem[0xBB] = @truncate(xp >> 8);
            _ = try run(0xC156, &.{});
            expect("level", mem[0xC7] == lv, "$C156 xp={d} rom={d} zig={d}", .{ xp, mem[0xC7], lv });
            _ = try run(0xF050, &.{0xF069}); // stop before the frame wait and stat load
            expect("level", mem[0xC7] == lv, "$F050 xp={d} rom={d} zig={d}", .{ xp, mem[0xC7], lv });
            if (dw.xpToNext(@intCast(xp))) |next| {
                _ = try run(0xF134, &.{});
                const rom_next = @as(u16, mem[0x00]) | (@as(u16, mem[0x01]) << 8);
                expect("xpToNext", rom_next == next, "xp={d} rom={d} zig={d}", .{ xp, rom_next, next });
            }
            for (rands) |gain| {
                const want = dw.addCapped(@intCast(xp), gain);
                // $EA17: XP add (after the "N experience points" message).
                mem[0xBA] = @truncate(xp);
                mem[0xBB] = @truncate(xp >> 8);
                mem[0x00] = gain;
                _ = try run(0xEA17, &.{0xEA2A});
                const rom_xp = @as(u16, mem[0xBA]) | (@as(u16, mem[0xBB]) << 8);
                expect("addXp", rom_xp == want, "xp={d} gain={d}", .{ xp, gain });
                // $EA50: gold add, same pattern.
                mem[0xBC] = @truncate(xp);
                mem[0xBD] = @truncate(xp >> 8);
                mem[0x00] = gain;
                _ = try run(0xEA50, &.{0xEA63});
                const rom_gold = @as(u16, mem[0xBC]) | (@as(u16, mem[0xBD]) << 8);
                expect("addGold", rom_gold == want, "gold={d} gain={d}", .{ xp, gain });
            }
        }

        const bare: dw.Equipment = .{ .shield = 0, .armor = 0, .weapon = 0 };
        for (1..31) |lv| {
            // $EAE6: the "learned a new spell" message, checked against the new level.
            mem[0xC7] = @intCast(lv);
            const pc = try run(0xEAE6, &.{ 0xEB10, 0xEB14 });
            const before = dw.heroFor(if (lv == 1) 0 else dw.xp_table[lv - 2], 0, bare, false);
            const after = dw.heroFor(dw.xp_table[lv - 1], 0, bare, false);
            const message = if (dw.levelUp(before, after)) |up| up.spell_message else false;
            expect("spellMessage", (pc == 0xEB10) == message, "level={d}", .{lv});
        }
        sec.end("Level / XP / gold $C156 $F050 $EA17");
    }

    {
        loadBanks(1);
        const sec: Section = .begin();
        for (1..31) |lv| for (0..64) |flags| {
            // Bank 1 $99B4 copies a level row. Fill $CF's item bits to check the OR.
            const cf: u8 = @intCast(flags << 2);
            mem[0x3C] = @intCast((lv - 1) * 6);
            mem[0xCF] = cf;
            _ = try run(0x99B4, &.{});
            const base = dw.level_stats[lv - 1];
            const bits = dw.spellsAt(@intCast(lv)).bits;
            expect("levelRow", mem[0xC8] == base.str and mem[0xC9] == base.agi and mem[0xCA] == base.hp and mem[0xCB] == base.mp and
                mem[0xCE] == @as(u8, @truncate(bits)) and mem[0xCF] == cf | @as(u8, @intCast(bits >> 8)), "level={d} cf={x}", .{ lv, cf });
        };
        sec.end("Level row + spells bank 1 $99B4");
    }

    {
        loadBanks(0); // equipment tables live in bank 0
        const sec: Section = .begin();
        for (0..256) |be| for ([_]bool{ false, true }) |scale| for (stats) |str| for (stats) |agi| {
            mem[0xC8] = str;
            mem[0xC9] = agi;
            mem[0xBE] = @intCast(be);
            mem[0xCF] = if (scale) 0xFC else 0xEC; // bit 4 = Dragon's Scale; the other bits must not matter
            _ = try run(0xF0CD, &.{});
            const z = dw.combatStats(.{ .str = str, .agi = agi, .hp = 0, .mp = 0 }, @bitCast(@as(u8, @intCast(be))), scale);
            expect("combatStats", mem[0xCC] == z.attack and mem[0xCD] == z.defense, "be={x} scale={} str={d} agi={d}", .{ be, scale, str, agi });
        };

        for (0..256) |map| {
            mem[0x45] = @intCast(map);
            mem[0xDF] = 0x02; // skip the throne-room branch before $B02E
            _ = try run(0xB02E, &.{ 0xB038, 0xB04F });
            expect("mapKind", mem[0x16] == @backingInt(dw.mapKind(@intCast(map))), "map={x}", .{map});
        }
        sec.end("ATK/DEF $F0CD, map kind $B02E");
        loadBanks(1);
    }

    {
        loadBanks(0); // the MP cost table $9D53 is in bank 0
        const sec: Section = .begin();
        for (0..10) |spell_i| {
            const spell: dw.Spell = @fromBackingInt(@intCast(spell_i));
            for (0..256) |mp| {
                // $DB85: MP check and payment.
                mem[0xC6] = @intCast(mp);
                cpu.a = @intCast(spell_i);
                const pc = try run(0xDB85, &.{ 0xDB92, 0xDB98 });
                var z_mp: u8 = @intCast(mp);
                const paid = dw.payMp(&z_mp, spell);
                expect("payMp", (pc == 0xDB98) == paid and mem[0xC6] == z_mp, "spell={d} mp={d}", .{ spell_i, mp });

                // $E6ED-$E720: battle gate. Stop inside $DB85 rather than run its messages.
                for ([_]bool{ false, true }) |stopped| {
                    mem[0xC6] = @intCast(mp);
                    mem[0xDF] = if (stopped) 0x10 else 0;
                    cpu.a = @intCast(spell_i);
                    var bpc = try run(0xE6ED, &.{ 0xE6FD, 0xDB92, 0xDB98 });
                    const rom_result: dw.BattleCast = switch (bpc) {
                        0xE6FD => .field_only,
                        0xDB92 => .not_enough_mp,
                        else => blk: {
                            cpu.a = @intCast(spell_i);
                            bpc = try run(0xE711, &.{ 0xE719, 0xE720 });
                            break :blk if (bpc == 0xE719) .stopped else .cast;
                        },
                    };
                    var b_mp: u8 = @intCast(mp);
                    const z = dw.battleCast(&b_mp, spell, stopped);
                    expect("battleCast", rom_result == z and mem[0xC6] == b_mp, "spell={d} mp={d} stopped={} rom={t} zig={t}", .{ spell_i, mp, stopped, rom_result, z });
                }
            }

            // $DA47: the field dispatcher after a successful payment.
            for (0..0x30) |map| {
                mem[0x45] = @intCast(map);
                mem[0x16] = @backingInt(dw.mapKind(@intCast(map)));
                cpu.a = @intCast(spell_i);
                const pc = try run(0xDA47, &.{ 0xDBB8, 0xDBD7, 0xDA55, 0xDA6A, 0xDA98, 0xD9E2, 0xDB00 });
                var rom_result: dw.FieldCast = switch (pc) {
                    0xDBB8 => .heal,
                    0xDBD7 => .healmore,
                    0xDA55 => .nothing_happened,
                    0xDA6A => .radiant,
                    0xDA98 => .repel,
                    else => undefined,
                };
                if (pc == 0xD9E2 or pc == 0xDB00) {
                    _ = try run(pc, &.{ 0xD9FA, 0xDB1A });
                    rom_result = .{ .warp = .{ .map = mem[0x45], .x = mem[0x3A], .y = mem[0x3B] } };
                }
                var f_mp: u8 = 255;
                const z = dw.fieldCast(&f_mp, spell, @intCast(map));
                const same = std.meta.eql(rom_result, z);
                expect("fieldCast", same, "spell={d} map={x} rom={any} zig={any}", .{ spell_i, map, rom_result, z });
            }
        }
        sec.end("Casting $DB85 $DA47 $E6ED");
        loadBanks(1);
    }

    {
        const sec: Section = .begin();
        var g: dw.Rng = .init(0x1234); // just a source of inventory layouts
        const cases: u32 = if (strides.rand == 1) 200_000 else 5_000;
        for (0..cases) |_| {
            var inv: dw.Inventory = .{ .herbs = g.next() % 7, .keys = g.next() % 7 };
            for (&inv.slots) |*b| {
                const lo = g.next() % 15;
                const hi = g.next() % 15;
                b.* = lo | (hi << 4);
            }
            const item: dw.Item = @fromBackingInt(4 + g.next() % 14);
            const load = struct {
                fn f(i: dw.Inventory) void {
                    mem[0xC0] = i.herbs;
                    mem[0xBF] = i.keys;
                    @memcpy(mem[0xC1..0xC5], &i.slots);
                    mem[0xC5] = 0x5A; // $E04B ANDs $C5 when nothing matches
                }
            }.f;

            load(inv);
            cpu.a = @backingInt(item) - 3;
            _ = try run(0xE055, &.{});
            expect("has", (cpu.a != 0xFF) == inv.has(item), "slots={x} item={t}", .{ inv.slots, item });

            load(inv);
            cpu.a = @backingInt(item) - 3;
            _ = try run(0xE04B, &.{});
            var removed = inv;
            removed.remove(item);
            expect("remove", std.mem.eql(u8, mem[0xC1..0xC5], &removed.slots) and mem[0xC5] == 0x5A, "slots={x} item={t}", .{ inv.slots, item });

            load(inv);
            cpu.a = @backingInt(item) - 3;
            _ = try run(0xE01B, &.{});
            var added = inv;
            const ok = added.add(item);
            expect("add", std.mem.eql(u8, mem[0xC1..0xC5], &added.slots) and (cpu.x != 4) == ok, "slots={x} item={t}", .{ inv.slots, item });

            load(inv);
            _ = try run(0xDF77, &.{});
            var buf: [10]dw.Item = undefined;
            const list = inv.menu(&buf);
            var same = mem[0xA3] == 0x01 and mem[0xA4 + list.len] == 0xFF;
            for (list, 0..) |it, i| same = same and mem[0xA4 + i] == @backingInt(it);
            expect("menu", same, "inv={any}", .{inv});

            // Bank 0 $AD45 (door drawn open?) and $DCA8 (key spent, door logged).
            var log: dw.DoorLog = .{};
            const used = g.next() % 9;
            for (log.slots[0..used]) |*s| s.* = .{ 1 + g.next() % 0x7F, g.next() };
            const tx = 1 + g.next() % 0x7F;
            const ty = g.next();
            loadBanks(0);
            for (log.slots, 0..) |s, i| {
                mem[0x600C + 2 * i] = s[0];
                mem[0x600D + 2 * i] = s[1];
            }
            mem[0x3C] = 0x11; // door tile
            mem[0x42] = if (used > 0 and g.next() & 1 == 0) log.slots[0][0] else tx;
            mem[0x43] = if (mem[0x42] == log.slots[0][0]) log.slots[0][1] else ty;
            const pc = try run(0xAD45, &.{ 0xAD38, 0xAD3C });
            expect("doorOpen", (pc == 0xAD38) == log.opened(mem[0x42], mem[0x43]), "x={d} y={d}", .{ mem[0x42], mem[0x43] });

            mem[0xBF] = 1 + g.next() % 6;
            const keys = mem[0xBF];
            mem[0x42] = tx;
            mem[0x43] = ty;
            const kpc = try run(0xDCA8, &.{ 0xDCC4, 0xCFD9 });
            var kinv: dw.Inventory = .{ .keys = keys };
            var klog = log;
            const r = dw.useKey(&kinv, &klog, tx - 1, ty, .{ false, false, false, true }); // door to the right
            var rom_log: dw.DoorLog = .{};
            for (&rom_log.slots, 0..) |*s, i| s.* = .{ mem[0x600C + 2 * i], mem[0x600D + 2 * i] };
            expect("useKey", (kpc == 0xDCC4) == (r == .opened) and mem[0xBF] == kinv.keys and std.meta.eql(rom_log, klog), "used={d} r={t}", .{ used, r });
            loadBanks(1);
        }
        sec.end("Inventory $E01B $E04B $E055 $DF77, doors");
    }

    {
        loadBanks(0);
        const sec: Section = .begin();
        const places = [_][3]u8{ .{ 0x41, 0x31, 0 }, .{ 0x41, 0x30, 0 }, .{ 0x40, 0x31, 0 }, .{ 0x2B, 0x2B, 0 } };
        for (2..0x12) |code| {
            if (code == 0x03) continue; // the key is checked above
            const item: dw.Item = @fromBackingInt(@intCast(code));
            for (0..0x20) |map| for (places) |p| for ([_]u8{ 0x00, 0x08 }) |cf| {
                // $DCEA field dispatcher, resuming past the window/text calls at each check.
                mem[0x45] = @intCast(map);
                mem[0x16] = @backingInt(dw.mapKind(@intCast(map)));
                mem[0x3A] = p[0];
                mem[0x3B] = p[1];
                mem[0xCF] = cf;
                cpu.a = @intCast(code);
                const stops = [_]u16{ 0xDCEE, 0xDD24, 0xDD2F, 0xDD57, 0xDD6F, 0xDD99, 0xDDA7, 0xDDCA, 0xDDD8, 0xDDF0, 0xDDFC, 0xDE08, 0xDE54, 0xDE6A, 0xDE83, 0xDF11, 0xDF74 };
                var pc = try run(0xDCEA, &stops);
                pc = switch (pc) {
                    0xDD6F => try run(0xDD73, &.{ 0xDD7F, 0xDD86 }),
                    0xDE08 => try run(0xDE18, &.{ 0xDE1E, 0xDE41 }),
                    0xDE83 => try run(0xDE8B, &.{ 0xDEA3, 0xDF08 }),
                    else => pc,
                };
                const rom_use: ?dw.FieldItem = switch (pc) {
                    0xDCEE => .herb,
                    0xDD2F => .torch,
                    0xDD24, 0xDD7F => .cant_use_here,
                    0xDD57 => .fairy_water,
                    0xDD86 => .wings,
                    0xDD99, 0xDDCA, 0xDE54, 0xDE6A => .wear,
                    0xDE1E => .harp,
                    0xDEA3 => .rainbow_bridge,
                    0xDF11 => .love,
                    0xDDA7, 0xDDD8, 0xDDF0, 0xDDFC, 0xDE41, 0xDF08 => .nothing_happened,
                    else => null,
                };
                const z = dw.fieldItem(item, .{ .map = @intCast(map), .x = p[0], .y = p[1] }, cf);
                expect("fieldItem", rom_use == z, "item={t} map={x} at=({d},{d}) cf={x} rom={?t} zig={t}", .{ item, map, p[0], p[1], cf, rom_use, z });
            };

            // $E7D6 battle dispatcher.
            cpu.a = @intCast(code);
            const bpc = try run(0xE7D6, &.{ 0xE7DA, 0xE7EA, 0xE824, 0xE84E, 0xE858, 0xE862, 0xE871, 0xE87C });
            const brom: dw.BattleItem = switch (bpc) {
                0xE7DA => .herb,
                0xE7EA => .flute,
                0xE824 => .harp,
                0xE87C => .refused,
                else => .wear,
            };
            expect("battleItem", brom == dw.battleItem(item), "item={t}", .{item});

            // $E0A6: may it be thrown away?
            for ([_]u8{ 0x00, 0x40, 0x80, 0xC0 }) |cf| {
                mem[0xCF] = cf;
                mem[0xA4] = @intCast(code);
                cpu.x = 0;
                cpu.a = @intCast(code);
                const dpc = try run(0xE0A6, &.{ 0xE0AD, 0xE0C1, 0xE0D2 });
                expect("droppable", (dpc == 0xE0D2) == dw.droppable(item, cf), "item={t} cf={x}", .{ item, cf });
            }
        }

        // Wear routines, already worn or not.
        const wears = [_]struct { item: dw.Item, start: u16, done: u16, already: u16 }{
            .{ .item = .dragons_scale, .start = 0xDFB9, .done = 0xDFC5, .already = 0xDFCC },
            .{ .item = .fighters_ring, .start = 0xDFD1, .done = 0xDFDD, .already = 0xDFE2 },
            .{ .item = .cursed_belt, .start = 0xDFEC, .done = 0xDFF6, .already = 0xE003 },
            .{ .item = .death_necklace, .start = 0xE00F, .done = 0xDFF6, .already = 0xE003 },
        };
        for (wears) |w| for (0..256) |cf| {
            mem[0xCF] = @intCast(cf);
            const pc = try run(w.start, &.{ w.done, w.already });
            var z_cf: u8 = @intCast(cf);
            const worn = dw.wear(&z_cf, w.item);
            expect("wear", (pc == w.done) == worn and mem[0xCF] == z_cf, "item={t} cf={x}", .{ w.item, cf });
        };

        for (0..40) |id| {
            mem[0xE0] = @intCast(id);
            const pc = try run(0xE806, &.{ 0xE80C, 0xE819 });
            expect("flute", (pc == 0xE80C) == dw.fluteSleeps(@fromBackingInt(@intCast(id))), "id={d}", .{id});
        }
        sec.end("Item use $DCEA $E7D6 $E0A6 $DFB9");
        loadBanks(1);
    }

    {
        const sec: Section = .begin();
        // $CCF6 armor regen: every armor x counter x (hp <= max).
        for (0..8) |armor| for (0..256) |counter| for (stats) |max| {
            var hp: u32 = 0;
            while (hp <= max) : (hp += strides.stat) {
                mem[0xBE] = @intCast(armor << 2);
                mem[0xE3] = @intCast(counter);
                mem[0xC5] = @intCast(hp);
                mem[0xCA] = max;
                _ = try run(0xCCF6, &.{ 0xCD16, 0xCD30 });
                var z_hp: u8 = @intCast(hp);
                var z_counter: u8 = @intCast(counter);
                dw.armorRegen(&z_hp, max, @intCast(armor), &z_counter);
                expect("armorRegen", mem[0xC5] == z_hp and mem[0xE3] == z_counter, "armor={d} counter={d} hp={d} max={d}", .{ armor, counter, hp, max });
            }
        };

        // $CDC6 / $CE17: immunity check, then the subtraction (past the sound and flashes).
        for ([_]dw.Tile{ .swamp, .barrier }) |tile| for (0..8) |armor| for (0..256) |hp| {
            mem[0xE0] = @backingInt(tile);
            mem[0xBE] = @intCast(armor << 2);
            mem[0xC5] = @intCast(hp);
            const swamp = tile == .swamp;
            const pc = try run(0xCDC6, if (swamp) &.{ 0xCDD4, 0xCDFB } else &.{ 0xCE2B, 0xCE5F });
            if (pc == 0xCDD4 or pc == 0xCE2B) _ = try run(if (swamp) 0xCDDF else 0xCE44, &.{ 0xCDEA, 0xCE51 });
            var z_hp: u8 = @intCast(hp);
            const died = dw.terrainDamage(&z_hp, tile, @intCast(armor));
            expect("terrainDamage", mem[0xC5] == z_hp and died == (mem[0xC5] == 0 and (pc == 0xCDD4 or pc == 0xCE2B)), "tile={t} armor={d} hp={d}", .{ tile, armor, hp });
        };

        // $CBF7 up to the RNG call: ending, curse kick, fixed battles.
        const spots = [_][3]u8{ .{ 0x03, 0x12, 0x0C }, .{ 0x15, 0x04, 0x0E }, .{ 0x01, 0x49, 0x64 }, .{ 0x04, 0x0A, 0x08 }, .{ 0x04, 0x0B, 0x08 }, .{ 0x04, 0x0C, 0x1B }, .{ 0x04, 0x0A, 0x1A }, .{ 0x01, 0x2B, 0x2B } };
        for (0..0x1E) |map| for (spots) |spot| for ([_]u8{ 0x00, 0x40, 0x80 }) |cf| for ([_]u8{ 0x00, 0x02, 0x04, 0x40, 0x42, 0x46 }) |story| {
            mem[0x45] = @intCast(map);
            mem[0x3A] = spot[1];
            mem[0x3B] = spot[2];
            mem[0xCF] = cf;
            mem[0xE4] = story;
            mem[0xBE] = 0; // no regen, so the palette code at $CD16 is skipped
            const pc = try run(0xCBF7, &.{ 0xCC19, 0xCD42, 0xE4DF, 0xCDA2 });
            const rom_ev: ?dw.StepEvent = switch (pc) {
                0xCC19 => .ending,
                0xCD42 => .kicked_out,
                0xE4DF => .{ .fixed_battle = @fromBackingInt(cpu.a) },
                else => null, // reached the RNG call
            };
            var rng: dw.Rng = .init(0);
            var hero: dw.StepHero = .{ .hp = 1, .max_hp = 1, .armor = 0, .cf = cf };
            // Use an entrance tile so takeStep stops right after the roll.
            const z = dw.takeStep(&rng, &hero, .{ .map = @intCast(map), .tile = @fromBackingInt(0x07), .x = spot[1], .y = spot[2], .hero_defense = 0, .repel_active = false }, story);
            const z_ev: ?dw.StepEvent = if (z == .entrance) null else z;
            expect("stepGate", std.meta.eql(rom_ev, z_ev), "map={x} at=({d},{d}) cf={x} story={x}", .{ map, spot[1], spot[2], cf, story });
        };

        // $CDB0: entrance tiles and the Dragonlord-beaten return, after the roll.
        for (0..0x20) |tile| for ([_]u8{ 0x00, 0x04 }) |story| {
            mem[0x3C] = @intCast(tile);
            mem[0xE4] = story;
            const pc = try run(0xCDB0, &.{ 0xD941, 0xCDC6 });
            const Outcome = enum { entrance, stop, go_on }; // go_on: damage and encounter next
            const rom_out: Outcome = switch (pc) {
                0xD941 => .entrance,
                0 => .stop,
                else => .go_on,
            };
            const z_out: Outcome = if (dw.isEntrance(@fromBackingInt(@intCast(tile))))
                .entrance
            else if (story & dw.Story.dragonlord_beaten != 0) .stop else .go_on;
            expect("stepTile", rom_out == z_out, "tile={x} story={x}", .{ tile, story });
        };
        sec.end("Step $CBF7 $CCF6 $CDB0 $CDC6 $CE17");
    }

    {
        loadBanks(0); // price and stock tables live in bank 0
        const sec: Section = .begin();
        const gold16 = struct {
            fn get(lo: u16) u16 {
                return @as(u16, mem[lo]) | (@as(u16, mem[lo + 1]) << 8);
            }
            fn set(lo: u16, v: u16) void {
                mem[lo] = @truncate(v);
                mem[lo + 1] = @truncate(v >> 8);
            }
        };

        // Tables.
        for (dw.prices, 0..) |p, i| expect("prices", gold16.get(@intCast(0x9947 + 2 * i)) == p, "index={d}", .{i});
        var at: u16 = 0x9991;
        for (dw.shop_stock, 0..) |list, i| {
            for (list) |v| {
                expect("shopStock", mem[at] == v, "shop={d}", .{i});
                at += 1;
            }
            expect("shopStock", mem[at] == 0xFD, "shop={d} end", .{i});
            at += 1;
        }
        for (dw.key_prices, 0..) |p, i| {
            cpu.a = @intCast(0x0C + i);
            _ = try run(0xD7ED, &.{0xD7FA});
            expect("keyPrice", mem[0x00] == p and mem[0x01] == 0, "seller={d}", .{i});
        }
        for (dw.inn_prices, 0..) |p, i| {
            cpu.a = @intCast(0x11 + i);
            _ = try run(0xD895, &.{0xD8A2});
            expect("innPrice", mem[0x00] == p and mem[0x01] == 0, "inn={d}", .{i});
        }

        var g: dw.Rng = .init(0x5151); // source of gold amounts and inventories
        const cases: u32 = if (strides.rand == 1) 100_000 else 3_000;
        for (0..cases) |_| {
            const gold: u16 = switch (g.next() & 3) {
                0 => g.next(),
                1 => @as(u16, g.next()) << 6,
                else => @as(u16, g.next()) << 8 | g.next(),
            };

            // Equipment: gold check, trade-in, new $BE.
            const index = g.next() % 17;
            const be = g.next();
            gold16.set(0xBC, gold);
            mem[0xBE] = be;
            cpu.x = 2 * index;
            var pc = try run(0xD589, &.{ 0xD596, 0xD599 });
            if (pc == 0xD599) {
                mem[0x00] = 0;
                mem[0x01] = 0;
                pc = try run(0xD599, &.{ 0xD5D4, 0xD5E0 }); // trade-in into $00/$01, if any
                cpu.x = 2 * index;
                _ = try run(0xD5F5, &.{0xD619});
                _ = try run(0xD619, &.{0xD631});
            }
            var z_gold = gold;
            var z_equip: dw.Equipment = @bitCast(be);
            const bought = dw.buyEquipment(&z_gold, &z_equip, index);
            expect("buyEquipment", bought == (pc != 0xD596) and gold16.get(0xBC) == z_gold and mem[0xBE] == @as(u8, @bitCast(z_equip)), "gold={d} index={d} be={x}", .{ gold, index, be });

            // Item shop: gold, herb cap, full inventory.
            var inv: dw.Inventory = .{ .herbs = g.next() % 7 };
            for (&inv.slots) |*b| b.* = (g.next() % 15) | ((g.next() % 15) << 4);
            const items = [_]dw.Item{ .herb, .torch, .wings, .dragons_scale };
            const item = items[g.next() & 3];
            gold16.set(0xBC, gold);
            mem[0xC0] = inv.herbs;
            @memcpy(mem[0xC1..0xC5], &inv.slots);
            cpu.x = 2 * (@backingInt(item) + 15);
            pc = try run(0xD6DB, &.{ 0xD6EC, 0xD6F3 });
            if (pc == 0xD6F3) pc = try run(0xD6F3, &.{ 0xD6FD, 0xD70E, 0xD732 });
            const rom_buy: dw.BuyResult = switch (pc) {
                0xD6EC => .not_enough_gold,
                0xD70E => .bought,
                else => .full,
            };
            var z_inv = inv;
            z_gold = gold;
            const z_buy = dw.buyItem(&z_gold, &z_inv, item, dw.itemPrice(item));
            expect("buyItem", rom_buy == z_buy and gold16.get(0xBC) == z_gold and mem[0xC0] == z_inv.herbs and std.mem.eql(u8, mem[0xC1..0xC5], &z_inv.slots), "gold={d} item={t} inv={any}", .{ gold, item, inv });

            // Key seller: key count first, then gold.
            const keys = g.next() % 7;
            const kp = dw.key_prices[g.next() % 3];
            gold16.set(0xBC, gold);
            mem[0xBF] = keys;
            mem[0x00] = kp;
            mem[0x01] = 0;
            pc = try run(0xD80B, &.{ 0xD811, 0xD827, 0xD838 });
            const rom_key: dw.BuyResult = switch (pc) {
                0xD811 => .full,
                0xD827 => .not_enough_gold,
                else => .bought,
            };
            var k_inv: dw.Inventory = .{ .keys = keys };
            z_gold = gold;
            expect("buyKey", rom_key == dw.buyKey(&z_gold, &k_inv, kp) and gold16.get(0xBC) == z_gold and mem[0xBF] == k_inv.keys, "gold={d} keys={d}", .{ gold, keys });

            // Selling: price lookup and halving, then the per-item branch.
            const sell_item: dw.Item = @fromBackingInt(2 + g.next() % 16);
            const cf = g.next() & 0xC0;
            var s_inv = inv;
            s_inv.keys = 1 + g.next() % 6;
            if (s_inv.herbs == 0) s_inv.herbs = 1;
            if (sell_item != .herb and sell_item != .magic_key) {
                const i = g.next() & 3;
                s_inv.slots[i] = (s_inv.slots[i] & 0xF0) | (@backingInt(sell_item) - 3);
            }
            gold16.set(0xBC, gold);
            mem[0xBF] = s_inv.keys;
            mem[0xC0] = s_inv.herbs;
            @memcpy(mem[0xC1..0xC5], &s_inv.slots);
            mem[0xCF] = cf;
            mem[0xDE] = @backingInt(sell_item);
            cpu.a = @backingInt(sell_item);
            pc = try run(0xD763, &.{ 0xD776, 0xD78A });
            var rom_sell: dw.SellResult = .worthless;
            if (pc == 0xD78A) {
                _ = try run(0xD78A, &.{0xD78E});
                pc = try run(0xD798, &.{ 0xD7B5, 0xD7CE });
                rom_sell = if (pc == 0xD7B5) .sold else .cursed;
            }
            var z_sinv = s_inv;
            z_gold = gold;
            const z_sell = dw.sell(&z_gold, &z_sinv, sell_item, cf);
            expect("sell", rom_sell == z_sell and gold16.get(0xBC) == z_gold and mem[0xBF] == z_sinv.keys and mem[0xC0] == z_sinv.herbs and std.mem.eql(u8, mem[0xC1..0xC5], &z_sinv.slots), "gold={d} item={t} cf={x} rom={t} zig={t}", .{ gold, sell_item, cf, rom_sell, z_sell });

            // Inn: gold check and payment, then HP/MP after the music call.
            const ip = dw.inn_prices[g.next() % 5];
            gold16.set(0xBC, gold);
            mem[0x00] = ip;
            mem[0x01] = 0;
            const max_hp = g.next();
            const max_mp = g.next();
            mem[0xC5] = 1;
            mem[0xC6] = 0;
            mem[0xCA] = max_hp;
            mem[0xCB] = max_mp;
            pc = try run(0xD8B3, &.{ 0xD8C2, 0xD8C9 });
            if (pc == 0xD8C9) {
                _ = try run(0xD8C9, &.{0xD8D1});
                _ = try run(0xD8E4, &.{0xD8EC});
            }
            var hp: u8 = 1;
            var mp: u8 = 0;
            z_gold = gold;
            const stayed = dw.stayAtInn(&z_gold, ip, &hp, &mp, max_hp, max_mp);
            expect("inn", stayed == (pc == 0xD8C9) and gold16.get(0xBC) == z_gold and mem[0xC5] == hp and mem[0xC6] == mp, "gold={d} price={d}", .{ gold, ip });

            // Death: halve gold ($EDCB), then the revive at $CB6B.
            const death_cf = g.next() & 0xC0;
            const old_mp = g.next();
            gold16.set(0xBC, gold);
            mem[0xDF] = 0xFF;
            _ = try run(0xEDCB, &.{0xEDDE});
            mem[0xCF] = death_cf;
            mem[0xC5] = 0;
            mem[0xC6] = old_mp;
            mem[0x603A] = 0x78; // set by $EDB9 on the death path
            mem[0x6039] = 0;
            mem[0xDB] = 0xFF;
            _ = try run(0xCB6B, &.{0xCBC0});
            const z_rev = dw.die(gold, old_mp, max_hp, max_mp, death_cf);
            const rom_at: dw.Warp = .{ .map = mem[0x45], .x = mem[0x3A], .y = mem[0x3B] };
            const at_ok = if (death_cf != 0) rom_at.map == 0x05 else std.meta.eql(rom_at, z_rev.at); // cursed: warped later, at $EDE1
            expect("die", gold16.get(0xBC) == z_rev.gold and mem[0xC5] == z_rev.hp and mem[0xC6] == z_rev.mp and at_ok and mem[0xDB] == 0 and mem[0xDF] & 1 == 0, "gold={d} cf={x}", .{ gold, death_cf });
        }
        sec.end("Shops, inns, death $D589-$D8EB $EDCB");
        loadBanks(1);
    }

    {
        const sec: Section = .begin();
        expect("signature", std.mem.eql(u8, mem[0xFC76..0xFC80], dw.Sram.signature), "", .{});
        var g: dw.Rng = .init(0xBEEF);
        const cases: u32 = if (strides.rand == 1) 20_000 else 600;
        for (0..cases) |_| {
            const slot: u2 = @intCast(g.next() % 3);
            var rec: dw.SaveRecord = .{
                .xp = @as(u16, g.next()) << 8 | g.next(),
                .gold = @as(u16, g.next()) << 8 | g.next(),
                .slots = .{ g.next(), g.next(), g.next(), g.next() },
                .keys = g.next(),
                .herbs = g.next(),
                .equipment = g.next(),
                .cf = g.next(),
                .df = g.next(),
                .e4 = g.next(),
                .name = undefined,
                .message_speed = g.next(),
                .hp = g.next(),
                .mp = g.next(),
                .start_flag = if (g.next() & 1 == 0) 0x78 else 0xAB,
            };
            for (&rec.name) |*c| c.* = g.next();
            for (mem[0x6000..0x6440]) |*b| b.* = g.next(); // SRAM noise

            // Hero state in RAM.
            const setHero = struct {
                fn f(r: dw.SaveRecord, s: u2) void {
                    mem[0xBA] = @truncate(r.xp);
                    mem[0xBB] = @truncate(r.xp >> 8);
                    mem[0xBC] = @truncate(r.gold);
                    mem[0xBD] = @truncate(r.gold >> 8);
                    @memcpy(mem[0xC1..0xC5], &r.slots);
                    mem[0xBF] = r.keys;
                    mem[0xC0] = r.herbs;
                    mem[0xBE] = r.equipment;
                    mem[0xCF] = r.cf;
                    mem[0xDF] = r.df;
                    mem[0xE4] = r.e4;
                    @memcpy(mem[0xB5..0xB9], r.name[0..4]);
                    @memcpy(mem[0x64C6..0x64CA], r.name[4..8]);
                    mem[0xE5] = r.message_speed;
                    mem[0xC5] = r.hp;
                    mem[0xC6] = r.mp;
                    mem[0x6045 + @as(u16, s)] = r.start_flag;
                    mem[0x6039] = s;
                }
            }.f;
            setHero(rec, slot);
            var z_sram: [dw.Sram.size]u8 = mem[0x6000..0x8000].*;
            _ = try run(0xF9DF, &.{});
            var z_rng: dw.Rng = .init(0);
            dw.Sram.save(&z_sram, slot, rec, &z_rng);
            expect("save", std.mem.eql(u8, mem[0x6000..0x8000], &z_sram) and romRng() == z_rng.state, "slot={d}", .{slot});

            // Break some copies, wipe the hero, load.
            const bad = g.next() % 11;
            for (0..bad) |i| mem[0x6068 + @as(u16, slot) * 0x140 + 0x20 * @as(u16, @intCast(i)) + g.next() % 0x1E] ^= 1 + g.next() % 0xFF;
            z_sram = mem[0x6000..0x8000].*;
            @memset(mem[0xB5..0xE6], 0);
            mem[0x6039] = slot;
            cpu.a = slot;
            _ = try run(0xFAC1, &.{});
            const rom_ok = cpu.a == 0;
            const z = dw.Sram.load(&z_sram, slot, &z_rng);
            if (z) |r| { // $FB6B also writes the name's second half and the start flag
                @memcpy(z_sram[0x4C6..0x4CA], r.name[4..8]);
                z_sram[0x45 + @as(usize, slot)] = r.start_flag;
            }
            var ram_ok = true;
            if (z) |r| {
                var expect_rec = r;
                expect_rec.name = undefined;
                @memcpy(expect_rec.name[0..4], mem[0xB5..0xB9]);
                @memcpy(expect_rec.name[4..8], mem[0x64C6..0x64CA]);
                ram_ok = std.mem.eql(u8, &expect_rec.name, &r.name) and
                    mem[0xBA] == @as(u8, @truncate(r.xp)) and mem[0xBB] == @as(u8, @truncate(r.xp >> 8)) and
                    mem[0xBC] == @as(u8, @truncate(r.gold)) and mem[0xBD] == @as(u8, @truncate(r.gold >> 8)) and
                    std.mem.eql(u8, mem[0xC1..0xC5], &r.slots) and mem[0xBF] == r.keys and mem[0xC0] == r.herbs and
                    mem[0xBE] == r.equipment and mem[0xCF] == r.cf and mem[0xDF] == r.df and mem[0xE4] == r.e4 and
                    mem[0xE5] == r.message_speed and mem[0xC5] == r.hp and mem[0xC6] == r.mp;
            }
            expect("load", rom_ok == (z != null) and ram_ok and std.mem.eql(u8, mem[0x6000..0x8000], &z_sram) and romRng() == z_rng.state, "slot={d} bad={d}", .{ slot, bad });
        }
        sec.end("Save $F9DF, load $FAC1, CRC $FBEF");
    }

    {
        const sec: Section = .begin();
        // Bank 1 $AE48 (fill the name buffer) and $AE19 (copy it into place).
        loadBanks(1);
        for (mem[0x64CA..0x64D7]) |*b| b.* = 0xAA;
        _ = try run(0xAE48, &.{});
        expect("namePad", std.mem.allEqual(u8, mem[0x64CA..0x64D7], dw.name_pad), "", .{});

        var g: dw.Rng = .init(0x7A7A);
        const charset = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'.,-?!)( ";
        for (0..20_000) |_| {
            var name: [8]u8 = undefined;
            const len = 1 + g.next() % 8;
            for (name[0..len]) |*c| c.* = charset[g.next() % charset.len];
            for (mem[0x64CA..0x64D7]) |*b| b.* = dw.name_pad;
            for (name[0..len], 0..) |c, i| mem[0x64CA + i] = dw.nameTile(c).?;
            _ = try run(0xAE19, &.{});
            _ = try run(0xF085, &.{0xF090}); // the sum of $B5-$B8
            expect("nameSum", cpu.a == dw.nameSum(name[0..len]).?, "name={s}", .{name[0..len]});
        }

        // $D3BC: the king takes the princess. Inventories with and without room.
        loadBanks(0);
        for (0..20_000) |_| {
            var inv: dw.Inventory = .{};
            for (&inv.slots) |*b| b.* = (1 + g.next() % 14) | (@as(u8, 1 + g.next() % 14) << 4);
            if (g.next() & 3 == 0) inv.slots[g.next() & 3] &= 0xF0; // sometimes a free slot
            const df: u8 = dw.Quest.carrying_princess | (g.next() & 0xFC);
            @memcpy(mem[0xC1..0xC5], &inv.slots);
            mem[0xDF] = df;
            var pc = try run(0xD3BC, &.{ 0xD3C5, 0xD3EF });
            if (pc == 0xD3C5) {
                pc = try run(0xD3C5, &.{ 0xD3D8, 0xD3EF });
                if (pc == 0xD3D8) {
                    _ = try run(0xD3D8, &.{0xD3DF});
                    _ = try run(0xD3E6, &.{0xD3EB});
                }
            }
            _ = try run(0xD3F7, &.{0xD3FF});
            var z_inv = inv;
            var z_df = df;
            _ = dw.returnPrincess(&z_inv, &z_df);
            expect("returnPrincess", std.mem.eql(u8, mem[0xC1..0xC5], &z_inv.slots) and mem[0xDF] == z_df, "slots={x}", .{inv.slots});
        }

        // $D4EF: the bad ending's wipe, and nothing else.
        for (0..100) |_| {
            for (mem[0x80..0x100]) |*b| b.* = g.next();
            var before: [0x80]u8 = mem[0x80..0x100].*;
            _ = try run(0xD4EF, &.{0xD50D});
            var xp: u16 = 1;
            var gold: u16 = 1;
            var inv: dw.Inventory = .{ .herbs = 1, .keys = 1, .slots = @splat(1) };
            var equip: u8 = 1;
            var cf: u8 = 1;
            var df: u8 = 1;
            var e4: u8 = 1;
            dw.badEnding(&xp, &gold, &inv, &equip, &cf, &df, &e4);
            before[0xBA - 0x80] = @truncate(xp);
            before[0xBB - 0x80] = @truncate(xp >> 8);
            before[0xBC - 0x80] = @truncate(gold);
            before[0xBD - 0x80] = @truncate(gold >> 8);
            before[0xBF - 0x80] = inv.keys;
            before[0xC0 - 0x80] = inv.herbs;
            @memcpy(before[0xC1 - 0x80 .. 0xC5 - 0x80], &inv.slots);
            before[0xBE - 0x80] = equip;
            before[0xCF - 0x80] = cf;
            before[0xDF - 0x80] = df;
            before[0xE4 - 0x80] = e4;
            before[0xFD - 0x80] = mem[0xFD]; // stack bytes used by run()
            before[0xFE - 0x80] = mem[0xFE];
            before[0xFF - 0x80] = mem[0xFF];
            expect("badEnding", std.mem.eql(u8, mem[0x80..0x100], &before), "", .{});
        }
        sec.end("Names $AE19 $F085, princess $D3BC, $D4EF");
        loadBanks(1);
    }

    try checkMaps();
    try checkWalking();
    try checkNpcs();
    try checkTreasure();
    try checkDragonlordWin();

    std.debug.print("\n{d} checks, {d} mismatches\n", .{ checks, failures });
    if (failures != 0) return error.Mismatch;
}

/// What the bank 0 map loader ($AF6A, $B02E) and the game state leave in RAM for $AC17.
fn setMapState(s: dw.MapState) void {
    @memcpy(mem[0x11..0x16], rom[16 + 0x1A + @as(usize, s.map) * 5 ..][0..5]);
    mem[0x16] = @backingInt(dw.mapKind(s.map));
    mem[0x45] = s.map;
    mem[0xE0] = s.e0;
    mem[0xCF] = s.cf;
    mem[0xDF] = s.df;
    for (s.doors.slots, 0..) |slot, i| @memcpy(mem[0x600C + i * 2 ..][0..2], &slot);
    for (s.chests.slots, 0..) |slot, i| @memcpy(mem[0x601C + i * 2 ..][0..2], &slot);
}

/// x or y values to try on a map: every one in range, one past each edge, and far out.
fn mapCoords(max: u8, buf: *[256]u8) []const u8 {
    var n: usize = 0;
    var v: u16 = 0;
    while (v <= @as(u16, max) + 1) : (v += 1) {
        buf[n] = @intCast(v);
        n += 1;
    }
    for ([_]u8{ 0x80, 0xFE, 0xFF }) |far| {
        if (far > max + 1) {
            buf[n] = far;
            n += 1;
        }
    }
    return buf[0..n];
}

fn checkMaps() !void {
    loadBanks(0);
    defer loadBanks(1);
    const bank0: dw.Bank0 = rom[16..][0..0x4000];
    const bank3 = rom[16 + 3 * 0x4000 ..][0..0x4000];

    {
        const sec: Section = .begin();
        for (dw.map_headers, 0..) |h, m| {
            const r = bank0[0x1A + m * 5 ..][0..5];
            const ok = r[0] == @as(u8, @truncate(h.data)) and r[1] == @as(u8, @truncate(h.data >> 8)) and
                r[2] == h.max_x and r[3] == h.max_y and r[4] == @backingInt(h.border);
            expect("map_headers", ok, "map={x}", .{m});
        }
        expect("overworld_tiles", std.mem.eql(u8, bank0[0x19E3..][0..16], &dw.overworld_tiles), "", .{});
        expect("map_tiles", std.mem.eql(u8, bank0[0x19F0..][0..0x28], &dw.map_tiles), "", .{});
        for (dw.warps, 0..) |w, i| {
            const f = bank3[0x33C8 + i * 3 ..][0..3];
            const t = bank3[0x3461 + i * 3 ..][0..3];
            const ok = f[0] == w.from.map and f[1] == w.from.x and f[2] == w.from.y and
                t[0] == w.to.map and t[1] == w.to.x and t[2] == w.to.y;
            expect("warps", ok, "entry={d}", .{i});
        }
        sec.end("Map tables $801A $99E3 $F3C8");
    }

    var xbuf: [256]u8 = undefined;
    var ybuf: [256]u8 = undefined;

    {
        const sec: Section = .begin();
        for (1..0x1E) |m| {
            const map: u8 = @intCast(m);
            const h = dw.map_headers[m];
            const xs = mapCoords(h.max_x, &xbuf);
            const ys = mapCoords(h.max_y, &ybuf);

            // Log up to 8 of this map's chests and doors, to see them read as brick.
            var full: dw.MapState = .{ .map = map };
            var nc: usize = 0;
            var nd: usize = 0;
            for (0..@as(usize, h.max_y) + 1) |y| for (0..@as(usize, h.max_x) + 1) |x| {
                const xy = [2]u8{ @intCast(x), @intCast(y) };
                switch (dw.tileAt(&rom_maps, .{ .map = map }, xy[0], xy[1])) {
                    .chest => if (nc < 8) {
                        full.chests.slots[nc] = xy;
                        nc += 1;
                    },
                    .door => if (nd < 8) {
                        full.doors.slots[nd] = xy;
                        nd += 1;
                    },
                    else => {},
                }
            };

            var states: [6]dw.MapState = @splat(.{ .map = map });
            states[1] = full;
            states[1].cf = dw.Worn.rainbow_bridge | dw.charlock_stairs_found;
            states[2].cf = dw.charlock_stairs_found;
            states[2].df = dw.Quest.carrying_princess;
            states[3].cf = dw.Worn.rainbow_bridge;
            states[3].df = dw.Quest.princess_returned;
            states[4].e0 = 0x27;
            states[5].df = 0xFC; // other Quest and battle bits don't matter
            // The overworld is big: in quick mode, only the plain and all-flags states.
            const n_states: usize = if (map == 0x01 and strides.rand != 1) 2 else states.len;

            for (states[0..n_states]) |s| for (ys) |y| for (xs) |x| {
                setMapState(s);
                mem[0x3C] = x;
                mem[0x3E] = y;
                _ = try run(0xAC17, &.{});
                const z = dw.tileAt(&rom_maps, s, x, y);
                expect("tileAt", mem[0x3C] == @backingInt(z), "map={x} ({d},{d}) e0={x} cf={x} df={x} rom={x} zig={x}", .{ map, x, y, s.e0, s.cf, s.df, mem[0x3C], @backingInt(z) });
            };

            // A move ($B1CC, then $B219) and STAIRS ($D9AF), for the plain and all-flags states.
            for (states[0..2]) |s| for (ys) |y| for (xs) |x| {
                setMapState(s);
                mem[0x8D] = 0xFF; // no NPCs
                mem[0x8E] = x;
                mem[0x8F] = y;
                const blocked = try run(0xB1CC, &.{0xB1DD}) == 0xB1DD;
                var rom_move: dw.Move = .blocked;
                if (!blocked) {
                    setMapState(s);
                    mem[0x3A] = x;
                    mem[0x3B] = y;
                    const pc = try run(0xB219, &.{ 0xCBF7, 0xB097 });
                    rom_move = switch (pc) {
                        0xCBF7 => .{ .step = dw.tileAt(&rom_maps, s, x, y) },
                        0xB097 => .{ .exit = .{ .map = mem[0x45], .x = mem[0x3A], .y = mem[0x3B] } },
                        else => .blocked,
                    };
                }
                const z_move = dw.move(&rom_maps, s, x, y);
                expect("move", std.meta.eql(rom_move, z_move), "map={x} ({d},{d}) cf={x}", .{ map, x, y, s.cf });

                if (x > h.max_x or y > h.max_y) continue;
                setMapState(s);
                mem[0x3A] = x;
                mem[0x3B] = y;
                const rom_stairs: ?dw.Warp = if (try run(0xD9AF, &.{ 0xB097, 0xC6F0 }) == 0xB097)
                    .{ .map = mem[0x45], .x = mem[0x3A], .y = mem[0x3B] }
                else
                    null;
                expect("stairs", std.meta.eql(rom_stairs, dw.stairs(&rom_maps, s, x, y)), "map={x} ({d},{d}) cf={x}", .{ map, x, y, s.cf });
            };

            // $D941, as reached from an entrance tile, at every position.
            for (0..@as(usize, h.max_y) + 1) |y| for (0..@as(usize, h.max_x) + 1) |x| {
                const at: dw.Warp = .{ .map = map, .x = @intCast(x), .y = @intCast(y) };
                mem[0x45] = at.map;
                mem[0x3A] = at.x;
                mem[0x3B] = at.y;
                const rom_to: ?dw.Warp = if (try run(0xD941, &.{ 0xB097, 0xC6F0 }) == 0xB097)
                    .{ .map = mem[0x45], .x = mem[0x3A], .y = mem[0x3B] }
                else
                    null;
                expect("warpForward", std.meta.eql(rom_to, dw.warpForward(at)), "map={x} ({d},{d})", .{ map, x, y });
            };
        }
        sec.end("Tiles $AC17, move $B1CC $B219, warps");
    }
}

/// Pops a return address and resumes after it (plus `skip` inline bytes).
fn returnFrom(skip: u16) void {
    const lo = mem[0x100 | @as(u16, cpu.sp +% 1)];
    const hi = mem[0x100 | @as(u16, cpu.sp +% 2)];
    cpu.sp +%= 2;
    cpu.pc = (@as(u16, lo) | (@as(u16, hi) << 8)) +% 1 +% skip;
}

/// Runs the real field loop ($CA9F) after a real map load ($B097), with
/// `pad` held, and returns the RNG calls between consecutive steps ($CDA2).
/// Frame waits get the NMI's effects ($4F += 1, PPU buffer flushed); an
/// encounter is cut short where it would start ($CE7C).
fn walkSteps(map: u8, x: u8, y: u8, pad: u8, calls: *[6]u32) !void {
    loadBanks(0);
    @memset(mem[0..0x8000], 0);
    @memcpy(mem[0x11..0x16], rom[16 + 0x1A + @as(usize, map) * 5 ..][0..5]);
    mem[0x16] = @backingInt(dw.mapKind(map));
    mem[0x45] = map;
    mem[0x3A] = x;
    mem[0x3B] = y;
    mem[0x8E] = x;
    mem[0x8F] = y;
    mem[0x90] = x << 4;
    mem[0x91] = x >> 4;
    mem[0x92] = y << 4;
    mem[0x93] = y >> 4;
    mem[0x8D] = 0xFF;
    mem[0xBE] = 0x1C; // Erdrick's Armor: no swamp damage (its message needs text)
    mem[0xD0] = 1;
    mem[0xCA] = 30;
    mem[0xC5] = 30;
    setRng(0x1234);
    // $B097 loads the map and returns past "jsr $B219" ($CAF3: jmp $CA56).
    cpu.sp = 0xFB;
    mem[0x1FD] = 0xCA;
    mem[0x1FC] = 0xF2;
    cpu.pc = 0xB097;
    var rng_calls: u32 = 0;
    var last: u32 = 0;
    var steps: usize = 0;
    var n: u32 = 0;
    while (steps < calls.len + 1) : (n += 1) {
        if (n > 5_000_000) return error.Runaway;
        switch (cpu.pc) {
            0xC55B => rng_calls += 1,
            0xC621 => { // the joypad: report `pad` (after its RNG call and strobe)
                mem[0x47] = pad;
                cpu.pc = 0xC631;
                continue;
            },
            0xCDA2 => {
                if (steps > 0) calls[steps - 1] = rng_calls - last;
                last = rng_calls;
                steps += 1;
            },
            0xCE7C => {
                returnFrom(0);
                continue;
            },
            0xFF74 => {
                mem[0x4F] +%= 1;
                mem[0x02] = 0;
                mem[0x03] = 0;
                mem[0x04] = 0;
                mem[0x602C] = 0;
                returnFrom(0);
                continue;
            },
            0xFF91, 0xFF96, 0xC6F0, 0xC7CB, 0xC7C5 => return error.UnexpectedCall,
            else => {},
        }
        if (mem[cpu.pc] == 0x00) { // BRK + 2 inline bytes: sound and bank calls
            cpu.pc +%= 3;
            continue;
        }
        try cpu.step();
    }
}

fn checkWalking() !void {
    defer loadBanks(1);
    const sec: Section = .begin();
    // One run of 9 tiles of each kind, walked right; then every direction on grass.
    for ([_]dw.Tile{ .grass, .hills, .forest, .desert, .swamp }) |want| {
        var y: u8 = 0;
        found: while (y < 120) : (y += 1) {
            var x: u8 = 0;
            while (x + 9 < 120) : (x += 1) {
                for (0..9) |k| {
                    if (dw.tileAt(&rom_maps, .{ .map = 1 }, x + @as(u8, @intCast(k)), y) != want) break;
                } else {
                    var calls: [6]u32 = undefined;
                    try walkSteps(0x01, x, y, 0x80, &calls);
                    for (calls) |c| expect("walking", c == dw.step_polls + 1, "tile={t} calls={d}", .{ want, c });
                    break :found;
                }
            }
        }
    }
    for ([_]struct { pad: u8, x: u8, y: u8 }{ .{ .pad = 0x40, .x = 40, .y = 45 }, .{ .pad = 0x20, .x = 30, .y = 45 }, .{ .pad = 0x10, .x = 30, .y = 52 } }) |d| {
        var calls: [6]u32 = undefined;
        try walkSteps(0x01, d.x, d.y, d.pad, &calls);
        for (calls) |c| expect("walking", c == dw.step_polls + 1, "pad={x} calls={d}", .{ d.pad, c });
    }
    var calls: [6]u32 = undefined;
    try walkSteps(0x16, 0, 3, 0x80, &calls); // Mountain Cave B1, brick floor
    for (calls) |c| expect("walking", c == dw.step_polls + 1, "cave calls={d}", .{c});
    sec.end("Walking loop $CA9F $C608 $B252");
}

/// Text and window calls take an inline byte; skip them like a silent screen.
fn runQuiet(start: u16, stops: []const u16) !u16 {
    mem[0x1FF] = 0xFF;
    mem[0x1FE] = 0xFF;
    cpu.sp = 0xFD;
    cpu.pc = start;
    var n: u32 = 0;
    while (true) : (n += 1) {
        if (cpu.pc == 0x0000) return 0;
        for (stops) |s| if (cpu.pc == s) return s;
        switch (cpu.pc) {
            0xFF74 => {
                returnFrom(0);
                continue;
            },
            0xC7CB, 0xC7C5, 0xC6F0 => {
                returnFrom(1);
                continue;
            },
            0xC7BD => {
                returnFrom(0);
                continue;
            },
            else => {},
        }
        if (n > 200_000) return error.Runaway;
        if (mem[cpu.pc] == 0x00) {
            cpu.pc +%= 3;
            continue;
        }
        try cpu.step();
    }
}

fn checkNpcs() !void {
    defer loadBanks(1);
    {
        const sec: Section = .begin();
        // The map loader ($AF6A) copies each NPC's x and y to $51 (moving) and $6F (stationary).
        for (0x04..0x0F) |m| for ([_]u8{ 0x00, dw.Quest.princess_returned }) |df| {
            loadBanks(0);
            @memset(mem[0..0x8000], 0);
            mem[0x45] = @intCast(m);
            mem[0xDF] = df;
            _ = try run(0xAF6A, &.{});
            var buf: [20]dw.Npc = undefined;
            var used: [20]bool = @splat(false);
            for (dw.npcs(&rom_maps, @intCast(m), df, &buf)) |npc| {
                const at = 0x51 + @as(usize, npc.slot) * 3;
                used[npc.slot] = true;
                expect("npcs", mem[at] & 0x1F == npc.x and mem[at + 1] & 0x1F == npc.y, "map={x} df={x} npc at ({d},{d})", .{ m, df, npc.x, npc.y });
            }
            // Every other slot is empty.
            for (used, 0..) |u, slot| {
                if (u) continue;
                const at = 0x51 + slot * 3;
                expect("npcs", mem[at] | mem[at + 1] | mem[at + 2] == 0, "map={x} df={x} slot {d} not empty", .{ m, df, slot });
            }
        };
        sec.end("NPC tables $9734 $974C (loader $AF6A)");
    }
    {
        const sec: Section = .begin();
        loadBanks(3 - 3); // bank 0 at $8000 (dialogue data), bank 3 fixed
        for (0..256) |d| for ([_]u8{ 0x00, dw.Story.dragonlord_beaten }) |story| {
            loadBanks(0);
            @memset(mem[0..0x8000], 0);
            mem[0x400] = 1;
            mem[0x401] = 1;
            mem[0x402] = @intCast(d);
            mem[0x3C] = 0x00;
            mem[0x3D] = 0x04;
            mem[0x45] = 0x08;
            mem[0xE4] = story;
            mem[0xCB] = 77;
            mem[0xC6] = 1;
            // Harp, Cursed Belt, Death Necklace (slot ids 0x0A, 0x09, 0x0B), cursed:
            // 0x67 lifts the curse, 0x6C takes the harp, 0x6D (no Token) throws you out.
            mem[0xC1] = 0x9A;
            mem[0xC2] = 0x0B;
            mem[0xCF] = 0xC0;
            cpu.y = 2; // the dialogue byte of the NPC record at $0400
            // $D134: the Dragonlord check, then the dispatch at $D16A.
            const pc = runQuiet(0xD134, &.{ 0xD553, 0xD6A7, 0xD7ED, 0xD843, 0xD895, 0xCFD9, 0xB228, 0xD4AB }) catch 0xCFD9;
            const rom_kind: std.meta.Tag(dw.NpcService) = switch (pc) {
                0xD553 => .equipment,
                0xD6A7 => .items,
                0xD7ED => .keys,
                0xD843 => .fairy_water,
                0xD895 => .inn,
                0xB228 => .rainbow_shrine,
                0xD4AB => .dragonlord,
                else => if (mem[0xC6] == 77)
                    .restore_mp
                else if (mem[0xCF] == 0)
                    .remove_curse
                else if (mem[0xC1] & 0x0F != 0x0A)
                    .staff_shrine
                else
                    .talk,
            };
            const z = dw.npcService(@intCast(d), story);
            const index_ok = switch (z) {
                .equipment, .items => |i| cpu.a == i,
                .keys => |i| cpu.a -% 0x0C == i,
                .inn => |i| cpu.a -% 0x11 == i,
                else => true,
            };
            expect("npcService", rom_kind == std.meta.activeTag(z) and index_ok, "dialogue={x} story={x} rom={t} zig={t}", .{ d, story, rom_kind, std.meta.activeTag(z) });
        };
        // Prices and stock lists behind each index.
        for (0..3) |i| {
            cpu.a = @intCast(0x0C + i);
            _ = try runQuiet(0xD7ED, &.{0xD7F6});
            expect("keyPrice", mem[0x00] == dw.key_prices[i], "seller={d}", .{i});
        }
        for (0..5) |i| {
            cpu.a = @intCast(0x11 + i);
            _ = try runQuiet(0xD895, &.{0xD89E});
            expect("innPrice", mem[0x00] == dw.inn_prices[i], "inn={d}", .{i});
        }
        var offset: usize = 0;
        for (dw.shop_stock, 0..) |list, i| {
            mem[0xDE] = @intCast(i);
            _ = try runQuiet(0xD672, &.{0xD686});
            expect("shopList", cpu.x == offset, "list={d} rom={d} zig={d}", .{ i, cpu.x, offset });
            offset += list.len + 1;
        }
        sec.end("TALK dispatch $D134 $D16A, prices");
    }
}

/// $E99E: what defeating an enemy leads to, for both of the Dragonlord's forms
/// and some ordinary enemies.
fn checkDragonlordWin() !void {
    defer loadBanks(1);
    const sec: Section = .begin();
    var g: dw.Rng = .init(0xD1D1);
    const cases: u32 = if (strides.rand == 1) 5_000 else 300;
    for ([_]dw.EnemyId{ .dragonlord1, .dragonlord2, .slime, .golem, .green_dragon, .red_dragon }) |id| for (0..cases) |_| {
        loadBanks(0);
        @memset(mem[0..0x8000], 0);
        mem[0xCFE4] = 0x60; // "wait for a button": return at once
        var e4: u8 = g.next();
        var hp: u8 = g.next();
        var mp: u8 = g.next();
        const max_hp: u8 = g.next();
        const max_mp: u8 = g.next();
        var e0: u8 = @backingInt(id);
        const seed: u16 = @as(u16, g.next()) << 8 | g.next();
        mem[0xE0] = e0;
        mem[0xE4] = e4;
        mem[0xC5] = hp;
        mem[0xC6] = mp;
        mem[0xCA] = max_hp;
        mem[0xCB] = max_mp;
        setRng(seed);
        const pc = try runQuiet(0xE99E, &.{ 0xE4DF, 0xEA0A, 0xB097 });
        const z = dw.dragonlordDefeated(id, &e0, &e4, &hp, &mp, max_hp, max_mp);
        const ok = switch (pc) {
            0xE4DF => z != null and z.? == .true_form and cpu.a == 0x27,
            0xB097 => z != null and z.? == .victory and
                std.meta.eql(z.?.victory, dw.Warp{ .map = mem[0x45], .x = mem[0x3A], .y = mem[0x3B] }) and
                mem[0xE0] == e0 and mem[0xE4] == e4 and mem[0xC5] == hp and mem[0xC6] == mp,
            else => z == null and dw.givesRewards(id),
        };
        expect("dragonlordDefeated", ok and romRng() == seed and (dw.givesRewards(id) == (pc == 0xEA0A)), "id={t} pc={X}", .{ id, pc });
    };
    sec.end("Dragonlord falls $E99E-$EA07");
}

fn randomInventory(g: *dw.Rng) dw.Inventory {
    var inv: dw.Inventory = .{ .herbs = g.next() % 7, .keys = g.next() % 7 };
    for (&inv.slots) |*b| {
        // Mostly empty or small, so both "added" and "no room" happen.
        const lo: u8 = if (g.next() & 1 == 0) 0 else g.next() % 15;
        const hi: u8 = if (g.next() & 1 == 0) 0 else g.next() % 15;
        b.* = lo | (hi << 4);
    }
    return inv;
}

fn putInventory(inv: dw.Inventory) void {
    mem[0xC0] = inv.herbs;
    mem[0xBF] = inv.keys;
    @memcpy(mem[0xC1..0xC5], &inv.slots);
}

fn sameInventory(inv: dw.Inventory) bool {
    return mem[0xC0] == inv.herbs and mem[0xBF] == inv.keys and std.mem.eql(u8, mem[0xC1..0xC5], &inv.slots);
}

fn checkTreasure() !void {
    defer loadBanks(1);
    const bank1 = rom[16 + 0x4000 ..][0..0x4000];
    var g: dw.Rng = .init(0xBEEF);
    const cases: u32 = if (strides.rand == 1) 20_000 else 1_000;
    {
        const sec: Section = .begin();
        for (dw.chest_table, 0..) |c, i| {
            const r = bank1[0x1DCD + i * 4 ..][0..4];
            expect("chest_table", r[0] == c.map and r[1] == c.x and r[2] == c.y and r[3] == c.contents, "entry={d}", .{i});
        }
        // $E202 on every chest and its neighbours.
        loadBanks(0);
        for (dw.chest_table) |c| for ([_][2]i8{ .{ 0, 0 }, .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d| {
            @memcpy(mem[0x320..][0..124], bank1[0x1DCD..][0..124]);
            const at: dw.Warp = .{ .map = c.map, .x = c.x +% @as(u8, @bitCast(d[0])), .y = c.y +% @as(u8, @bitCast(d[1])) };
            mem[0x45] = at.map;
            mem[0x3A] = at.x;
            mem[0x3B] = at.y;
            cpu.y = 0;
            const pc = try runQuiet(0xE202, &.{ 0xE221, 0xE1F8 });
            const rom_c: ?u8 = if (pc == 0xE221) mem[0x323 + @as(u16, cpu.y)] else null;
            expect("chestAt", rom_c == dw.chestAt(at), "map={x} ({d},{d})", .{ at.map, at.x, at.y });
        };
        sec.end("Chest table bank 1 $9DCD, $E202");
    }
    {
        const sec: Section = .begin();
        for (0x02..0x19) |contents| for (0..cases / 10) |_| {
            loadBanks(0);
            @memset(mem[0..0x8000], 0);
            var inv = randomInventory(&g);
            var gold: u16 = @as(u16, g.next()) << 8 | g.next();
            if (g.next() & 3 == 0) gold = 0xFFF0;
            var equip: u8 = g.next();
            var df: u8 = g.next() & 0x0F;
            var chests: dw.ChestLog = .{};
            const seed: u16 = @as(u16, g.next()) << 8 | g.next();
            putInventory(inv);
            mem[0xBC] = @truncate(gold);
            mem[0xBD] = @truncate(gold >> 8);
            mem[0xBE] = equip;
            mem[0xDF] = df;
            mem[0x320] = 0x04;
            mem[0x321] = 1;
            mem[0x322] = 2;
            mem[0x323] = @intCast(contents);
            mem[0x45] = 0x04;
            mem[0x3A] = 1;
            mem[0x3B] = 2;
            setRng(seed);
            cpu.y = 0;
            const pc = try runQuiet(0xE221, &.{ 0xCFD9, 0xE07B });
            var rng: dw.Rng = .init(seed);
            const z = dw.takeChest(&rng, @intCast(contents), &inv, &gold, &equip, &df);
            chests.record(1, 2);
            const ok = sameInventory(inv) and mem[0xBC] == @as(u8, @truncate(gold)) and mem[0xBD] == @as(u8, @truncate(gold >> 8)) and
                mem[0xBE] == equip and mem[0xDF] == df and romRng() == rng.state and
                std.mem.eql(u8, mem[0x601C..0x602C], std.mem.sliceAsBytes(&chests.slots)) and
                ((pc == 0xE07B) == (z == .no_room));
            expect("takeChest", ok, "contents={x} result={t}", .{ contents, std.meta.activeTag(z) });
        };
        sec.end("TAKE $E221-$E39A");
    }
    {
        const sec: Section = .begin();
        const spots = [_]dw.Warp{
            .{ .map = 0x01, .x = 83, .y = 113 }, .{ .map = 0x07, .x = 9, .y = 6 },    .{ .map = 0x03, .x = 18, .y = 12 },
            .{ .map = 0x02, .x = 10, .y = 1 },   .{ .map = 0x02, .x = 10, .y = 3 },   .{ .map = 0x02, .x = 10, .y = 2 },
            .{ .map = 0x04, .x = 1, .y = 13 },   .{ .map = 0x01, .x = 83, .y = 112 }, .{ .map = 0x04, .x = 5, .y = 5 },
        };
        for (spots) |at| for (0..cases / 10) |_| {
            loadBanks(0);
            @memset(mem[0..0x8000], 0);
            var inv = randomInventory(&g);
            var equip: u8 = g.next();
            var cf: u8 = g.next();
            const s: dw.MapState = .{ .map = at.map, .cf = cf };
            setMapState(s);
            putInventory(inv);
            mem[0xBE] = equip;
            mem[0x3A] = at.x;
            mem[0x3B] = at.y;
            const tile = dw.tileAt(&rom_maps, s, at.x, at.y);
            const pc = try runQuiet(0xE103, &.{ 0xD242, 0xE07B, 0xCFD9 });
            const msg = cpu.a;
            const z = dw.search(at, tile, &inv, &equip, &cf);
            const want_pc: u16, const want_msg: ?u8 = switch (z) {
                .nothing => .{ 0xD242, 0xD3 },
                .chest => .{ 0xD242, 0xD4 },
                .erdricks_armor => .{ 0xD242, 0xD5 },
                .hint => .{ 0xD242, 0xD6 },
                .no_room => .{ 0xE07B, null },
                .item, .charlock_stairs => .{ 0xCFD9, null },
            };
            const ok = pc == want_pc and (want_msg == null or msg == want_msg.?) and sameInventory(inv) and mem[0xBE] == equip and mem[0xCF] == cf;
            expect("search", ok, "map={x} ({d},{d}) result={t} pc={X}", .{ at.map, at.x, at.y, std.meta.activeTag(z), pc });
        };
        sec.end("SEARCH $E103-$E1DE");
    }
    {
        const sec: Section = .begin();
        // Inventories built from the quest items, so every branch is reached.
        const quest = [_]u8{ 0x0A, 0x07, 0x0C, 0x0D, 0x0E, 0x09, 0x0B, 0x01 }; // harp token stones staff drop belt necklace torch
        for (0..cases) |_| {
            var inv: dw.Inventory = .{};
            for (&inv.slots) |*b| b.* = quest[g.next() & 7] | (@as(u8, if (g.next() & 1 == 0) quest[g.next() & 7] else 0) << 4);
            const cf: u8 = g.next();
            for ([_]u8{ 0x6C, 0x6D, 0x67 }) |dialogue| {
                loadBanks(0);
                @memset(mem[0..0x8000], 0);
                putInventory(inv);
                mem[0xCF] = cf;
                @memset(mem[0x6F..0x72], 0x55); // the old man's NPC slot
                mem[0x45] = 0x0D;
                cpu.a = dialogue;
                const start: u16 = switch (dialogue) {
                    0x6C => 0xD2F8,
                    0x6D => 0xD345,
                    else => 0xD26A,
                };
                const pc = try runQuiet(start, &.{ 0xCFD9, 0xB228 });
                var z_inv = inv;
                var z_cf = cf;
                const ok = switch (dialogue) {
                    0x6C => blk: {
                        const r = dw.staffShrine(&z_inv);
                        break :blk (r == .harp_taken) == (mem[0x6F] == 0);
                    },
                    0x6D => (dw.rainbowShrine(&z_inv) == .kicked_out) == (pc == 0xB228),
                    else => blk: {
                        _ = dw.removeCurse(&z_inv, &z_cf);
                        break :blk mem[0xCF] == z_cf;
                    },
                };
                expect("shrines", ok and std.mem.eql(u8, mem[0xC1..0xC5], &z_inv.slots), "dialogue={x} slots={x} cf={x}", .{ dialogue, inv.slots, cf });
            }
        }
        sec.end("Shrines $D2F8 $D345, curse $D26A");
    }
}

fn stepCase(map: u8, flag: u8, x: u8, y: u8, tile: u8, seed: u16) !void {
    mem[0x45] = map;
    mem[0x16] = flag;
    mem[0x3A] = x;
    mem[0x3B] = y;
    mem[0xE0] = tile;
    mem[0xBE] = 0x1C; // Erdrick's Armor: skips swamp/barrier damage (which prints and BRKs)
    var g: dw.Rng = .init(seed);
    _ = g.next(); // the step's RNG call at $CDA2 comes before $CDC6
    setRng(g.state);
    const pc = try run(0xCDC6, &.{0xCF20});
    var z_rng: dw.Rng = .init(seed);
    const z = dw.stepEncounter(&z_rng, .{
        .map = map,
        .map_flag = flag,
        .tile = @fromBackingInt(tile),
        .x = x,
        .y = y,
        .hero_defense = 0,
        .repel_active = false,
    });
    const rom_id: ?u8 = if (pc == 0xCF20) mem[0x3C] else null;
    const zig_id: ?u8 = if (z) |e| @backingInt(e) else null;
    expect("step", rom_id == zig_id and romRng() == z_rng.state, "map={x} x={d} y={d} tile={x} seed={x} rom={?d} zig={?d}", .{ map, x, y, tile, seed, rom_id, zig_id });
}
