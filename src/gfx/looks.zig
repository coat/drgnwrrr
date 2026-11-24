//! How the frontends draw things, shared by the web game and the native one:
//! each Sprite's source art and how map tiles, the hero and NPCs look.
//! tools/atlas packs just these sprites (and the Anvil font) into one atlas
//! and writes their places out for each frontend, so this table is the only
//! place a sprite is chosen.
//!
//! The art is one-colour: Kenney's 1-Bit Pack (assets/1bit.png, 49 x 22 cells
//! of 16 px) for the map, Kenney's Input Prompts (assets/prompts.png, 34 x 24
//! cells of 16 px) for buttons, and our own 16 x 16 drawings where the pack
//! has nothing that reads well. The atlas has them white on transparent; the
//! frontends tint them. Colours are from the NES palette.
const dw = @import("dw");

pub const Sheet = enum { onebit, prompts };

pub const Source = union(enum) {
    /// A cell of a Kenney sheet, mirrored left to right if `flip`.
    cell: struct { sheet: Sheet, col: u8, row: u8, flip: bool = false },
    /// One string a row, '#' for ink.
    bits: *const [16]*const [16]u8,
};

pub const Sprite = enum {
    grass,
    desert,
    hills,
    stairs_up,
    floor,
    stairs_down,
    swamp,
    town,
    cave,
    castle,
    bridge,
    forest,
    chest,
    barrier,
    counter,
    water,
    wall,
    door,
    mountain,
    shop,
    inn,
    princess,
    hero,
    townsfolk,
    soldier,
    merchant,
    wizard,
    king,
    elder,
    /// The map buttons.
    zoom_in,
    zoom_out,
    overview,
    recentre,

    pub fn source(s: Sprite) Source {
        return switch (s) {
            .grass => onebit(5, 0),
            .desert => onebit(2, 0),
            .hills => .{ .bits = &hills },
            .stairs_up => .{ .cell = .{ .sheet = .onebit, .col = 2, .row = 6, .flip = true } },
            .floor => onebit(17, 0),
            .stairs_down => onebit(2, 6),
            .swamp => onebit(0, 2),
            .town => onebit(1, 20),
            .cave => onebit(5, 18),
            .castle => onebit(6, 19),
            .bridge => onebit(7, 5),
            .forest => onebit(3, 1),
            .chest => onebit(8, 6),
            .barrier => onebit(1, 17),
            .counter => onebit(7, 4),
            .water => .{ .bits = &waves },
            .wall => onebit(10, 17),
            .door => onebit(6, 16),
            .mountain => .{ .bits = &mountain },
            .shop => onebit(0, 7),
            .inn => onebit(1, 7),
            .princess => onebit(29, 4),
            .hero => onebit(26, 0),
            .townsfolk => onebit(24, 0),
            .soldier => onebit(31, 0),
            .merchant => onebit(27, 3),
            .wizard => onebit(28, 4),
            .king => onebit(26, 2),
            .elder => onebit(25, 4),
            .zoom_in => prompt(5, 20),
            .zoom_out => prompt(4, 20),
            .overview => prompt(18, 4),
            .recentre => prompt(0, 20),
        };
    }

    fn onebit(col: u8, row: u8) Source {
        return .{ .cell = .{ .sheet = .onebit, .col = col, .row = row } };
    }

    fn prompt(col: u8, row: u8) Source {
        return .{ .cell = .{ .sheet = .prompts, .col = col, .row = row } };
    }
};

/// 0xRRGGBB
pub const Color = u24;

pub const nes = struct {
    pub const white: Color = 0xfcfcfc;
    pub const grey: Color = 0xbcbcbc;
    pub const dark_grey: Color = 0x7c7c7c;
    pub const light_green: Color = 0x58d854;
    pub const green: Color = 0x00a800;
    pub const ochre: Color = 0xac7c00;
    pub const gold: Color = 0xf8b800;
    pub const orange: Color = 0xe45c10;
    pub const red: Color = 0xf83800;
    pub const dark_red: Color = 0xa81000;
    pub const brown: Color = 0x503000;
    pub const blue: Color = 0x0078f8;
    pub const sky: Color = 0x3cbcfc;
    pub const cyan: Color = 0x00e8d8;
    pub const violet: Color = 0x6844fc;
    pub const salmon: Color = 0xf87858;
    pub const pink: Color = 0xf878f8;
    pub const peach: Color = 0xfcd8a8;
};

pub const Look = struct { sprite: Sprite, color: Color };

/// A map tile's look and the name the map's hover line gives it.
pub const TileLook = struct { sprite: Sprite, color: Color, name: []const u8 };

/// How `t` is drawn; null draws nothing (the throne room's border).
pub fn tile(t: dw.Tile) ?TileLook {
    return switch (t) {
        .grass => .{ .sprite = .grass, .color = nes.green, .name = "grass" },
        .desert => .{ .sprite = .desert, .color = nes.gold, .name = "desert" },
        .hills => .{ .sprite = .hills, .color = nes.ochre, .name = "hills" },
        .stairs_up => .{ .sprite = .stairs_up, .color = nes.cyan, .name = "stairs up" },
        .brick => .{ .sprite = .floor, .color = nes.brown, .name = "floor" },
        .stairs_down => .{ .sprite = .stairs_down, .color = nes.cyan, .name = "stairs down" },
        .swamp => .{ .sprite = .swamp, .color = nes.violet, .name = "swamp" },
        .town => .{ .sprite = .town, .color = nes.white, .name = "town" },
        .cave => .{ .sprite = .cave, .color = nes.sky, .name = "cave" },
        .castle => .{ .sprite = .castle, .color = nes.white, .name = "castle" },
        .bridge => .{ .sprite = .bridge, .color = nes.orange, .name = "bridge" },
        .forest => .{ .sprite = .forest, .color = nes.light_green, .name = "forest" },
        .chest => .{ .sprite = .chest, .color = nes.gold, .name = "chest" },
        .barrier => .{ .sprite = .barrier, .color = nes.red, .name = "barrier" },
        .counter => .{ .sprite = .counter, .color = nes.ochre, .name = "counter" },
        .water => .{ .sprite = .water, .color = nes.blue, .name = "water" },
        .wall => .{ .sprite = .wall, .color = nes.dark_grey, .name = "wall" },
        .door => .{ .sprite = .door, .color = nes.salmon, .name = "door" },
        .mountain => .{ .sprite = .mountain, .color = nes.grey, .name = "mountain" },
        .shop_sign => .{ .sprite = .shop, .color = nes.peach, .name = "shop" },
        .inn_sign => .{ .sprite = .inn, .color = nes.peach, .name = "inn" },
        .princess => .{ .sprite = .princess, .color = nes.pink, .name = "princess" },
        .empty, .blank => null,
        // Overworld water with land on some side.
        _ => if (@backingInt(t) >= 0x18 and @backingInt(t) <= 0x26) tile(.water) else null,
    };
}

pub const hero: Look = .{ .sprite = .hero, .color = nes.white };

/// By the NPC's sprite bits (dw.Npc.sprite).
pub const npcs = [8]Look{
    .{ .sprite = .townsfolk, .color = nes.peach },
    .{ .sprite = .soldier, .color = nes.red },
    .{ .sprite = .soldier, .color = nes.grey },
    .{ .sprite = .merchant, .color = nes.gold },
    .{ .sprite = .wizard, .color = nes.gold },
    .{ .sprite = .king, .color = nes.white },
    .{ .sprite = .princess, .color = nes.pink },
    .{ .sprite = .elder, .color = nes.sky },
};

pub const route_color = nes.white;

/// The title screen: the overworld about this many tiles across the map's
/// shorter side, under black at this alpha, with the name in this colour.
pub const title_tiles = 14;
pub const title_dim = 112;
pub const title_color = nes.white;

const mountain = [16]*const [16]u8{
    "................",
    ".......#........",
    "......#.#.......",
    "......#.#.......",
    ".....#...#......",
    ".....#...#......",
    "....#.#.#.#.....",
    "....####.##.....",
    "...####.#.##....",
    "..######.#.##...",
    "..#####.#.#.#...",
    ".#######.#.###..",
    ".######.#.#.##..",
    "########.#.#.##.",
    "#######.#.#.#.#.",
    "################",
};

const waves = [16]*const [16]u8{
    "................",
    "................",
    "....####........",
    "..##....##......",
    ".#........#.....",
    "#..........#....",
    "............####",
    "................",
    "................",
    "................",
    "####............",
    "....##........##",
    "......#......#..",
    ".......#....#...",
    "........####....",
    "................",
};

const hills = [16]*const [16]u8{
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "....####........",
    "...#....#..###..",
    "..#......##...#.",
    ".#........#....#",
    "#......#.#.#.#.#",
    "#.....#.#.#.#.##",
    "################",
    "................",
    "................",
    "................",
};

/// How a map tile looks on its own (for the icons).
fn at(t: dw.Tile) Look {
    const l = tile(t).?;
    return .{ .sprite = l.sprite, .color = l.color };
}

/// The app icon: the hero in a few tiles of Alefgard, as the map draws them
/// (each sprite in its colour on black), a row at a time.
pub const icon = [4][4]Look{
    .{ at(.mountain), at(.mountain), at(.forest), at(.forest) },
    .{ at(.hills), at(.grass), at(.grass), at(.castle) },
    .{ at(.forest), hero, at(.grass), at(.grass) },
    .{ at(.water), at(.water), at(.water), at(.water) },
};

/// The favicon at 32 px: the hero by the castle. At 16 px it's the hero alone.
pub const favicon = [2][2]Look{
    .{ at(.forest), at(.castle) },
    .{ hero, at(.grass) },
};
