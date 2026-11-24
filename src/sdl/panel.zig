//! The panel's controls, as web/app.js lays them out: the main command
//! buttons, the menus that open in their place, and the prompts the
//! session stops for (a route, a battle, a full bag, the Dragonlord, a name).
const std = @import("std");
const c = @import("c");
const clay = @import("clay.zig");
const ui_ = @import("ui.zig");
const Ui = ui_.Ui;
const Action = ui_.Action;
const Menu = ui_.Menu;
const App = @import("App.zig");
const lib = @import("drgnwrrr");
const dw = lib.dw;
const game = lib.game;
const quests = lib.quests;
const travel = lib.travel;
const session_ = lib.session;
const Session = lib.Session;
const Game = lib.Game;

pub fn menuTitle(m: Menu) []const u8 {
    return switch (m) {
        .go => "Go",
        .grind => "Grind",
        .shop => "Shop",
        .cast => "Cast",
        .items => "Items",
        .more => "More",
        .status => "Status",
        .checklist => "Checklist",
        .danger => "Danger",
        .options => "Options",
        .about => "About",
    };
}

/// The menus under More.
pub const more = [_]Menu{ .status, .checklist, .danger, .options, .about };

/// The controls for whatever the session is waiting for.
pub fn controls(app: *App, ui: *Ui) void {
    switch (app.session.pending) {
        .name => title(app, ui),
        .confirm_route => confirmRoute(app, ui),
        .battle => |*f| battle(app, ui, f),
        .make_room => |item| makeRoom(app, ui, item),
        .dragonlord => dragonlord(app, ui),
        .over => {
            ui.heading("The end");
            var g = ui.grid(20, false);
            g.wide("New game", .new_game, .{ .style = .primary });
            g.end();
        },
        .command => if (app.menu) |m| {
            header(ui, menuTitle(m), .back);
            menu(app, ui, m);
        } else commands(app, ui),
    }
}

/// The row over a menu or prompt: Back, and what it is.
fn header(ui: *Ui, name: []const u8, back: Action) void {
    clay.open(.{
        .layout = .{
            .sizing = clay.sizing(clay.grow(), clay.fit()),
            .childGap = ui.upx(6),
            .childAlignment = .{ .y = clay.align_middle },
            .padding = .{ .top = ui.upx(4), .bottom = ui.upx(3) },
        },
        .border = .{ .color = clay.rgb(ui_.rule), .width = .{ .bottom = 1 } },
    });
    ui.buttonSized("< Back", back, .{ .key = ui_.back_key }, clay.sizing(clay.fixed(ui.px(8 * 8 + 8)), clay.fixed(ui.buttonHeight())));
    ui.text(name, ui_.ink);
    clay.close();
    ui.space(3);
}

pub fn goCommand(app: *const App, target: []const u8) Action {
    return .cmd("go {s} {t} stop={d}", .{ target, app.prefs.risk, app.prefs.stop });
}

/// Yes to a planned route, with the HP threshold as it stands now.
pub fn walkCommand(app: *const App) Action {
    return .cmd("y stop={d}", .{app.prefs.stop});
}

fn actionLabel(a: session_.Action) []const u8 {
    return switch (a) {
        .take => "Take",
        .search => "Search",
        .talk => "Talk",
        .open => "Open door",
        .stairs => "Stairs",
        .herb => "Herb",
        .leave => "Leave",
        .inn => "Inn",
        .shop => "Shop",
        .save => "Save",
        .mp => "Restore MP",
    };
}

const Key = enum { take, stairs, open, inn, shop, go, leave, save, mp, items, cast, herb, talk, grind, search, more, auto };

/// The main buttons, most used first: what's underfoot, then town services, then travel.
const town_order = [_]Key{ .take, .stairs, .open, .inn, .shop, .go, .leave, .save, .mp, .items, .cast, .herb, .talk, .grind, .search, .more, .auto };
const field_order = [_]Key{ .take, .stairs, .open, .go, .grind, .items, .cast, .herb, .talk, .search, .more, .auto };

fn commands(app: *App, ui: *Ui) void {
    const s = &app.session;
    const g = &s.g;
    var abuf: [16]session_.Action = undefined;
    const acts = s.actions(&abuf);
    const order: []const Key = if (game.townFor(g.at.map) != null) &town_order else &field_order;
    var grid = ui.grid(6.75, true);
    for (order) |k| switch (k) {
        .go => grid.button("Go >", .{ .menu = .go }, .{}),
        .grind => grid.button("Grind >", .{ .menu = .grind }, .{}),
        .items => grid.button("Items >", .{ .menu = .items }, .{}),
        .cast => if (hasSpell(g, .field)) grid.button("Cast >", .{ .menu = .cast }, .{}),
        .more => grid.button("More >", .{ .menu = .more }, .{}),
        .auto => grid.button(
            if (s.auto) "Auto-battle: on" else "Auto-battle: off",
            .cmd("auto {s}", .{if (s.auto) "off" else "on"}),
            .{ .style = if (s.auto) .primary else .outline, .key = "auto" },
        ),
        else => for (acts) |a| {
            if (!std.mem.eql(u8, @tagName(a), @tagName(k))) continue;
            switch (a) {
                .shop => grid.button("Shop >", .{ .menu = .shop }, .{}),
                .inn => grid.button(ui.fmt("Inn - {d} G", .{g.innPrice() orelse 0}), .cmd("inn", .{}), .{ .key = "inn" }),
                else => grid.button(actionLabel(a), .cmd("{t}", .{a}), .{}),
            }
        },
    };
    grid.end();
}

const SpellUse = enum { field, battle };

fn spellUse(sp: dw.Spell, use: SpellUse) bool {
    return switch (use) {
        .field => switch (sp) {
            .heal, .healmore, .radiant, .outside, .@"return", .repel => true,
            else => false,
        },
        .battle => switch (sp) {
            .heal, .healmore, .hurt, .hurtmore, .sleep, .stopspell => true,
            else => false,
        },
    };
}

fn hasSpell(g: *const Game, use: SpellUse) bool {
    const h = g.hero();
    for (std.enums.values(dw.Spell)) |sp| if (h.spells.contains(sp) and spellUse(sp, use)) return true;
    return false;
}

/// Buttons for the hero's spells of one use: `prefix` and the name cast them.
fn spellButtons(ui: *Ui, grid: *ui_.Grid, g: *const Game, use: SpellUse, prefix: []const u8, blocked: bool) void {
    const h = g.hero();
    inline for (@typeInfo(dw.Spell).@"enum".field_names) |name| {
        const sp = @field(dw.Spell, name);
        if (h.spells.contains(sp) and spellUse(sp, use)) {
            const cost = dw.mp_cost[@backingInt(sp)];
            grid.button(ui.fmt("{s} - {d}", .{ name, cost }), .cmd("{s} {s}", .{ prefix, name }), .{ .disabled = g.mp < cost or blocked });
        }
    }
}

fn menu(app: *App, ui: *Ui, m: Menu) void {
    const g = &app.session.g;
    switch (m) {
        .more => {
            var grid = ui.grid(10.5, false);
            for (more) |k| grid.button(menuTitle(k), .{ .menu = k }, .{});
            grid.end();
            // Only the king saves: quitting loses what's happened since.
            ui.heading("Quit");
            ui.hint("Only the king saves: anything since then is lost.");
            grid = ui.grid(10.5, false);
            grid.button("Quit", .quit, .{});
            grid.end();
        },
        .go => goMenu(app, ui),
        .grind => {
            var grid = ui.grid(10, false);
            grid.wide("Grind", .cmd("grind {d}{s} stop={d}", .{ app.prefs.fights, if (app.prefs.grind_auto) " auto" else "", app.prefs.grind_stop }), .{});
            grid.end();
            ui.heading("Fights");
            clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .childGap = ui.upx(2), .padding = .{ .bottom = ui.upx(2) } } });
            for ([_]u8{ 3, 5, 10, 20, 50 }) |n|
                ui.button(ui.fmt("{d}", .{n}), .{ .fights = n }, .{ .style = if (n == app.prefs.fights) .primary else .outline });
            clay.close();
            check(ui, app.prefs.grind_auto, "Auto-battle", .{ .toggle = .grind_auto }, null);
            stopStepper(app, ui, true);
        },
        .cast => {
            var grid = ui.grid(10, false);
            spellButtons(ui, &grid, g, .field, "cast", false);
            grid.end();
        },
        .items => items(app, ui),
        .shop => shop(app, ui),
        .status => status(app, ui),
        .checklist => checklist(app, ui),
        .danger => danger(app, ui),
        .options => options(app, ui),
        .about => about(ui),
    }
}

fn goMenu(app: *App, ui: *Ui) void {
    const g = &app.session.g;
    riskPicker(app, ui);
    ui.heading("Towns");
    const here = game.townFor(g.at.map);
    var grid = ui.grid(10.5, false);
    for (game.towns) |t| {
        const dist = if (g.at.map == 1)
            ui.fmt(" - {d}", .{@abs(@as(i32, t.entrance.x) - g.at.x) + @abs(@as(i32, t.entrance.y) - g.at.y)})
        else
            "";
        var lower: [32]u8 = undefined;
        const name = std.ascii.lowerString(&lower, t.name);
        grid.button(ui.fmt("{s}{s}", .{ t.name, dist }), goCommand(app, name), .{ .disabled = here != null and std.mem.eql(u8, here.?.name, t.name) });
    }
    grid.end();
    var todo = false;
    for (quests.objectives) |o| todo = todo or !o.done(g);
    if (todo) {
        ui.heading("Checklist");
        grid = ui.grid(10.5, false);
        for (quests.objectives, 1..) |o, n| {
            if (o.done(g)) continue;
            grid.button(ui.fmt("{d}. {s}", .{ n, o.name }), goCommand(app, ui.fmt("{d}", .{n})), .{});
        }
        grid.end();
    }
    if (g.at.map == 1) {
        ui.heading("Places");
        grid = ui.grid(10.5, false);
        for (travel.landmarks) |l| grid.button(l.name, goCommand(app, ui.fmt("{d} {d}", .{ l.at.x, l.at.y })), .{});
        grid.end();
    }
    ui.hint("Or tap the map.");
}

fn riskAction(r: travel.Risk) Action {
    return .{ .risk = r };
}

fn replanAction(r: travel.Risk) Action {
    return .{ .replan = r };
}

fn riskPicker(app: *App, ui: *Ui) void {
    ui.segmented(travel.Risk, app.prefs.risk, riskAction);
    stopStepper(app, ui, false);
}

/// − and + for when a walk (or a grind) stops.
fn stopStepper(app: *App, ui: *Ui, grind: bool) void {
    const v = if (grind) app.prefs.grind_stop else app.prefs.stop;
    ui.stepper(
        ui.fmt("Stop under {d}% HP", .{v}),
        if (v > 0) Action{ .stop = .{ .grind = grind, .by = -10 } } else null,
        if (v < 90) Action{ .stop = .{ .grind = grind, .by = 10 } } else null,
    );
}

/// A checkbox: a full-width button with [x] or [ ] and a hint under it.
fn check(ui: *Ui, on: bool, label: []const u8, action: Action, hint: ?[]const u8) void {
    ui.button(ui.fmt("{s} {s}", .{ if (on) "[x]" else "[ ]", label }), action, .{ .left = true, .style = if (on) .primary else .outline, .key = label });
    if (hint) |h| ui.hint(h) else ui.space(2);
}

fn items(app: *App, ui: *Ui) void {
    const s = &app.session;
    const g = &s.g;
    var obuf: [10]session_.Owned = undefined;
    const owned = s.owned(&obuf);
    if (owned.len == 0) return ui.hint("You carry nothing.");
    var cbuf: [48]game.Offer = undefined;
    const selling = g.catalog(&cbuf).len > 0;
    const small = clay.sizing(clay.fixed(ui.px(8 * 6 + 8)), clay.fixed(ui.buttonHeight()));
    const wide = clay.sizing(clay.fixed(ui.px(8 * 11 + 8)), clay.fixed(ui.buttonHeight()));
    for (owned, 1..) |o, n| {
        clay.open(.{ .layout = .{
            .sizing = clay.sizing(clay.grow(), clay.fit()),
            .childGap = ui.upx(2),
            .childAlignment = .{ .y = clay.align_middle },
            .padding = .{ .bottom = ui.upx(2) },
        } });
        const name = game.itemName(o.item);
        clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()) } });
        ui.text(ui.fmt("{s}{s}{s}", .{
            name,
            if (o.count > 1) ui.fmt(" x{d}", .{o.count}) else "",
            if (s.worn(o.item)) " (worn)" else "",
        }), ui_.ink);
        clay.close();
        if (o.item != .magic_key) ui.buttonSized("Use", .cmd("use {d}", .{n}), .{}, small);
        if (selling) {
            if (s.sellPrice(o.item)) |p| ui.buttonSized(ui.fmt("Sell - {d} G", .{p}), .cmd("sell {d}", .{n}), .{}, wide);
        }
        clay.close();
    }
    ui.hint(ui.fmt("Equipped: {s}, {s}, {s}.", .{
        game.equipName(0, g.equip.weapon) orelse "no weapon",
        game.equipName(7, g.equip.armor) orelse "no armor",
        game.equipName(14, g.equip.shield) orelse "no shield",
    }));
}

fn shop(app: *App, ui: *Ui) void {
    const g = &app.session.g;
    var cbuf: [48]game.Offer = undefined;
    const catalog = g.catalog(&cbuf);
    var i: usize = 0;
    while (i < catalog.len) {
        const first = catalog[i];
        ui.heading(Session.shopTitle(first.kind));
        var grid = ui.grid(10, false);
        while (i < catalog.len and catalog[i].shop == first.shop) : (i += 1) {
            const o = catalog[i];
            grid.button(o.name(), .cmd("buy {d}", .{i + 1}), .{ .sub = ui.fmt("{d} G", .{o.price()}), .disabled = o.price() > g.gold });
        }
        grid.end();
    }
    ui.hint("Weapons and armor are traded in when you buy. Sell from Items.");
}

fn status(app: *App, ui: *Ui) void {
    const g = &app.session.g;
    const h = g.hero();
    const k = 11;
    ui.row("Name", k, g.nameSlice(), ui_.ink);
    ui.row("Level", k, ui.fmt("{d}", .{h.level}), ui_.ink);
    ui.row("HP", k, ui.fmt("{d}/{d}", .{ g.hp, h.stats.hp }), ui_.ink);
    ui.row("MP", k, ui.fmt("{d}/{d}", .{ g.mp, h.stats.mp }), ui_.ink);
    ui.row("Strength", k, ui.fmt("{d}", .{h.stats.str}), ui_.ink);
    ui.row("Agility", k, ui.fmt("{d}", .{h.stats.agi}), ui_.ink);
    ui.row("Attack", k, ui.fmt("{d}", .{h.attack}), ui_.ink);
    ui.row("Defense", k, ui.fmt("{d}", .{h.defense}), ui_.ink);
    // How far to the next level, only with Gwaelin's Love, as in the game.
    const next = if (g.inv.has(.gwaelins_love)) dw.xpToNext(g.xp) else null;
    ui.row("Experience", k, if (next) |n| ui.fmt("{d} ({d} to next)", .{ g.xp, n }) else ui.fmt("{d}", .{g.xp}), ui_.ink);
    ui.row("Gold", k, ui.fmt("{d}", .{g.gold}), ui_.ink);
    ui.row("Herbs", k, ui.fmt("{d}", .{g.inv.herbs}), ui_.ink);
    ui.row("Keys", k, ui.fmt("{d}", .{g.inv.keys}), ui_.ink);
    ui.row("Weapon", k, game.equipName(0, g.equip.weapon) orelse "-", ui_.ink);
    ui.row("Armor", k, game.equipName(7, g.equip.armor) orelse "-", ui_.ink);
    ui.row("Shield", k, game.equipName(14, g.equip.shield) orelse "-", ui_.ink);
    var spells: std.ArrayList(u8) = .empty;
    inline for (@typeInfo(dw.Spell).@"enum".field_names) |name| {
        const sp = @field(dw.Spell, name);
        if (h.spells.contains(sp)) {
            if (spells.items.len > 0) spells.appendSlice(ui.arena, ", ") catch {};
            spells.print(ui.arena, "{s} ({d})", .{ name, dw.mp_cost[@backingInt(sp)] }) catch {};
        }
    }
    ui.row("Spells", k, if (spells.items.len > 0) spells.items else "-", ui_.ink);
    if (g.repel.active()) ui.row("Repel", k, ui.fmt("{d} steps", .{g.repel.counter / 2}), ui_.ink);
    ui.row("Steps", k, ui.fmt("{d}", .{g.steps}), ui_.ink);
    ui.row("Battles", k, ui.fmt("{d}", .{g.battles}), ui_.ink);
}

fn checklist(app: *App, ui: *Ui) void {
    const g = &app.session.g;
    for (quests.objectives, 1..) |o, n| {
        const done = o.done(g);
        clay.open(.{
            .layout = .{
                .sizing = clay.sizing(clay.grow(), clay.fit()),
                .childGap = ui.upx(4),
                .childAlignment = .{ .y = clay.align_middle },
                .padding = .{ .top = ui.upx(2), .bottom = ui.upx(2) },
            },
            .border = .{ .color = clay.rgb(ui_.rule), .width = .{ .bottom = 1 } },
        });
        clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.fixed(ui.px(8 * 3)), clay.fit()) } });
        ui.text(ui.fmt("{d}.", .{n}), ui_.dim);
        clay.close();
        clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .layoutDirection = clay.top_to_bottom, .childGap = ui.upx(1) } });
        ui.text(ui.fmt("{s}{s}", .{ o.name, if (o.optional) " (optional)" else "" }), if (done) ui_.dim else ui_.ink);
        if (!done) ui.text(ui.fmt("{s}{s}{s}", .{ o.where, if (o.needs.len > 0) " - needs " else "", o.needs }), ui_.dim);
        clay.close();
        if (done) {
            clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.fixed(ui.px(8 * 5 + 8)), clay.fit()) } });
            ui.text("done", ui_.dim);
            clay.close();
        } else ui.buttonSized("Go", goCommand(app, ui.fmt("{d}", .{n})), .{}, clay.sizing(clay.fixed(ui.px(8 * 5 + 8)), clay.fixed(ui.buttonHeight())));
        clay.close();
    }
}

fn danger(app: *App, ui: *Ui) void {
    const d = app.danger orelse return;
    const g = &app.session.g;
    const here = travel.zoneAt(g.at.map, g.at.x, g.at.y);
    ui.hint(ui.fmt("One fight, for you as you are now (HP {d}).", .{g.hp}));
    const cols = [_]struct { []const u8, f32 }{ .{ "Zone", 5 }, .{ "Loss", 6 }, .{ "Death", 6 } };
    dangerRow(ui, cols, .{ cols[0][0], cols[1][0], cols[2][0], "Enemies" }, ui_.dim);
    for (0..20) |z| {
        var names: std.ArrayList(u8) = .empty;
        for (dw.enemy_sets[z], 0..) |id, k| {
            if (std.mem.findScalar(dw.EnemyId, dw.enemy_sets[z][0..k], id) != null) continue;
            var nb: [24]u8 = undefined;
            if (names.items.len > 0) names.appendSlice(ui.arena, ", ") catch {};
            names.appendSlice(ui.arena, game.enemyName(id, &nb)) catch {};
        }
        if (z >= 14) names.appendSlice(ui.arena, " (caves)") catch {};
        dangerRow(ui, cols, .{
            ui.fmt("{d}", .{z}),
            ui.fmt("{d:.1}", .{d.loss[z]}),
            ui.fmt("{d:.0}%", .{d.death[z] * 100}),
            names.items,
        }, if (here != null and here.? == z) ui_.ink else ui_.dim);
    }
}

fn dangerRow(ui: *Ui, cols: anytype, cells: [4][]const u8, color: u24) void {
    clay.open(.{
        .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .childGap = ui.upx(3), .padding = .{ .top = ui.upx(1), .bottom = ui.upx(1) } },
        .border = .{ .color = clay.rgb(ui_.rule), .width = .{ .bottom = 1 } },
    });
    for (cols, 0..) |col, i| {
        clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.fixed(ui.px(8 * col[1])), clay.fit()) } });
        ui.text(cells[i], color);
        clay.close();
    }
    clay.open(.{ .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()) } });
    ui.text(cells[3], color);
    clay.close();
    clay.close();
}

fn options(app: *App, ui: *Ui) void {
    const p = &app.prefs;
    check(ui, p.assist, "Remake conveniences", .{ .toggle = .assist }, "Step onto stairs to take them and onto a chest to open it - routes with no fights, damage, guards or doors are walked without asking.");
    check(ui, p.show_log, "Show the log", .{ .toggle = .show_log }, "Above the buttons - drag its lower edge to resize it.");
    check(ui, p.show_cmd, "Show the command line", .{ .toggle = .show_cmd }, null);
    check(ui, p.show_where, "Show coordinates and encounter rate", .{ .toggle = .show_where }, "A second status line: where you stand, the zone and the chance of a fight each step.");
    ui.heading("Save file");
    ui.hint(ui.fmt("Only the king saves (Tantegel throne room). The save is {s}, in the same 8 KB format as the CLI's.", .{app.sav_path}));
    var grid = ui.grid(10, false);
    grid.button("New game", .new_game, .{});
    grid.end();
}

fn about(ui: *Ui) void {
    ui.hint("This is Dragon Warrior minus the walking, basically. Dragon Warrior is a trademark of Square Enix; this is an unofficial fan project, not affiliated with or endorsed by them.");
    ui.heading("Credits");
    const credits = [_][3][]const u8{
        .{ "Anvil font", "ZX Origins by DamienG, damieng.com/zx-origins", "used with permission" },
        .{ "1-Bit Pack (map tiles)", "Kenney, kenney.nl", "CC0" },
        .{ "Input Prompts Pixel 1-Bit (map buttons)", "Kenney, kenney.nl", "CC0" },
        .{ "SDL", "libsdl.org", "zlib" },
        .{ "Clay", "Nic Barker, github.com/nicbarker/clay", "zlib" },
    };
    for (credits) |cr| {
        clay.open(.{
            .layout = .{ .sizing = clay.sizing(clay.grow(), clay.fit()), .layoutDirection = clay.top_to_bottom, .childGap = ui.upx(1), .padding = .{ .top = ui.upx(2), .bottom = ui.upx(2) } },
            .border = .{ .color = clay.rgb(ui_.rule), .width = .{ .bottom = 1 } },
        });
        ui.text(cr[0], ui_.ink);
        ui.text(ui.fmt("{s} - {s}", .{ cr[1], cr[2] }), ui_.dim);
        clay.close();
    }
}

fn confirmRoute(app: *App, ui: *Ui) void {
    const s = &app.session;
    const r = s.route orelse return;
    const g = &s.g;
    header(ui, ui.fmt("To {s}", .{r.go.name}), .cmd("n", .{}));
    var grid = ui.grid(10, false);
    grid.wide("Walk", walkCommand(app), .{ .style = .primary });
    grid.end();
    ui.segmented(travel.Risk, r.go.risk, replanAction);
    stopStepper(app, ui, false);
    if (app.tapped != null) ui.hint("Or tap the same tile again.");
    const p = r.plan;
    const k = 8;
    ui.row("Steps", k, ui.fmt("{d}", .{p.steps}), ui_.ink);
    ui.row("Fights", k, ui.fmt("~{d:.1}", .{p.encounters}), ui_.ink);
    ui.row("HP loss", k, ui.fmt("~{d:.0} of {d}", .{ p.hp_loss, g.hp }), ui_.ink);
    ui.row("Death", k, ui.fmt("{d:.1}%", .{p.death * 100}), if (p.death * 100 >= 10) ui_.bad else ui_.ink);
    if (p.worst_zone) |z| ui.row("Zone", k, ui.fmt("up to {d}", .{z}), ui_.ink);
    if (p.doors > 0) ui.row("Doors", k, ui.fmt("{d} ({d} keys)", .{ p.doors, r.keys }), if (p.doors > r.keys) ui_.bad else ui_.ink);
    if (p.via_len > 0) {
        var via: std.ArrayList(u8) = .empty;
        for (p.via[0..p.via_len], 0..) |m, i| {
            if (i > 0) via.appendSlice(ui.arena, ", ") catch {};
            via.appendSlice(ui.arena, dw.map_names[m]) catch {};
        }
        ui.row("Via", k, via.items, ui_.ink);
    }
    if (p.fixed_battles > 0) ui.para(ui.fmt("{d} guarded tile(s) on the way.", .{p.fixed_battles}), ui_.bad);
}

fn battle(app: *App, ui: *Ui, f: *const session_.Fight) void {
    const g = &app.session.g;
    const b = &f.b;
    var nb: [24]u8 = undefined;
    const flags = if (b.enemy_asleep and b.enemy_stopped)
        " (asleep, spells blocked)"
    else if (b.enemy_asleep)
        " (asleep)"
    else if (b.enemy_stopped)
        " (spells blocked)"
    else
        "";
    ui.heading(ui.fmt("{s}{s}", .{ b.name(&nb), flags }));
    if (b.hero_asleep or b.hero_stopped) ui.para(if (b.hero_asleep and b.hero_stopped)
        "you are asleep; your spells are blocked"
    else if (b.hero_asleep)
        "you are asleep"
    else
        "your spells are blocked", ui_.bad);
    var grid = ui.grid(6.75, true);
    grid.button("Fight", .cmd("f", .{}), .{ .style = .primary });
    grid.button("Run", .cmd("r", .{}), .{});
    if (g.inv.herbs > 0) grid.button(ui.fmt("Herb - {d}", .{g.inv.herbs}), .cmd("h", .{}), .{ .key = "herb" });
    if (g.inv.has(.fairy_flute)) grid.button("Flute", .cmd("flute", .{}), .{});
    grid.button("Auto", .cmd("a", .{}), .{});
    if (app.session.stoppableJob()) |job| {
        if (app.session.stop_job)
            grid.button("Stopping", .cmd("stop", .{}), .{ .disabled = true })
        else
            grid.button(if (std.mem.eql(u8, job, "grind")) "Stop grind" else "Stop walk", .cmd("stop", .{}), .{});
    }
    // One grid, so every row stretches alike; the spells start a row of their own.
    grid.newRow();
    spellButtons(ui, &grid, g, .battle, "c", b.hero_stopped);
    grid.end();
}

fn makeRoom(app: *App, ui: *Ui, item: dw.Item) void {
    const s = &app.session;
    ui.heading(ui.fmt("Your bag is full: {s}", .{game.itemName(item)}));
    ui.hint("Throw something away for it?");
    var obuf: [10]session_.Owned = undefined;
    var grid = ui.grid(10, false);
    for (s.owned(&obuf), 1..) |o, n| {
        if (!dw.droppable(o.item, s.g.cf) or o.item == .herb or o.item == .magic_key) continue;
        grid.button(game.itemName(o.item), .cmd("{d}", .{n}), .{});
    }
    grid.button("Leave it", .cmd("leave", .{}), .{});
    grid.end();
}

fn dragonlord(app: *App, ui: *Ui) void {
    ui.heading(std.mem.trim(u8, app.session.question() orelse "", " "));
    var grid = ui.grid(10, false);
    grid.button("Yes", .cmd("y", .{}), .{});
    grid.button("No", .cmd("n", .{}), .{ .style = .primary });
    grid.end();
}

fn title(app: *App, ui: *Ui) void {
    ui.space(4);
    ui.text("drgnwrrr", ui_.ink);
    ui.hint("This is basically Dragon Warrior minus the walking. Is it still fun? I don't know!");
    const has_save = app.hasSave();
    if (has_save) {
        var grid = ui.grid(10, false);
        grid.wide("Continue", .continue_game, .{ .style = .primary });
        grid.end();
    }
    ui.heading(if (has_save) "Or start over: your name" else "Your name");
    app.inputField(ui, "1-8 letters");
    ui.space(2);
    if (app.wantsLetters()) letters(app, ui);
    var grid = ui.grid(10, false);
    grid.wide("New game", .{ .quiet = .init("{s}", .{app.nameInput()}) }, .{ .style = if (has_save) .outline else .primary, .disabled = app.nameInput().len == 0 });
    grid.end();
}

/// The characters a name can have (Game.new), 13 to a row as on the NES's name screen.
const name_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'.,-?!()";

/// An on-screen keyboard for the name, for a controller (or no keyboard at all).
fn letters(app: *App, ui: *Ui) void {
    // Letters stay pressable when the name is full (they do nothing), so the focus stays put.
    var grid = ui.gridCols(13, false);
    for (name_chars, 0..) |ch, i| grid.button(name_chars[i..][0..1], .{ .letter = ch }, .{});
    grid.end();
    grid = ui.gridCols(2, false);
    grid.button("Space", .{ .letter = ' ' }, .{});
    grid.button("Delete", .erase, .{ .disabled = app.input.items.len == 0 });
    grid.end();
}
