pub const EnemyId = enum(u8) {
    slime, // 0x00
    red_slime, // 0x01
    drakee, // 0x02
    ghost, // 0x03
    magician, // 0x04
    magidrakee, // 0x05
    scorpion, // 0x06
    druin, // 0x07
    poltergeist, // 0x08
    droll, // 0x09
    drakeema, // 0x0A
    skeleton, // 0x0B
    warlock, // 0x0C
    metal_scorpion, // 0x0D
    wolf, // 0x0E
    wraith, // 0x0F
    metal_slime, // 0x10
    specter, // 0x11
    wolflord, // 0x12
    druinlord, // 0x13
    drollmagi, // 0x14
    wyvern, // 0x15
    rogue_scorpion, // 0x16
    wraith_knight, // 0x17
    golem, // 0x18
    goldman, // 0x19
    knight, // 0x1A
    magiwyvern, // 0x1B
    demon_knight, // 0x1C
    werewolf, // 0x1D
    green_dragon, // 0x1E
    starwyvern, // 0x1F
    wizard, // 0x20
    axe_knight, // 0x21
    blue_dragon, // 0x22
    stoneman, // 0x23
    armored_knight, // 0x24
    red_dragon, // 0x25
    dragonlord1, // 0x26
    dragonlord2, // 0x27
};

pub const Enemy = struct {
    str: u8,
    agi: u8,
    /// Table max. The rolled HP is lower; AI heal checks still use this value.
    hp: u8,
    /// AI byte: see "Enemy AI pattern byte".
    pattern: u8,
    /// High nibble: SLEEP resist /16. Low nibble: STOPSPELL resist /16.
    sr: u8,
    /// High nibble: HURT resist /16. Low nibble: dodge /64.
    dr: u8,
    xp: u8,
    /// Max gold + 1.
    gp: u8,
};

/// ROM table, indexed by @intFromEnum(EnemyId).
pub const enemies = [40]Enemy{
    .{ .str = 0x05, .agi = 0x03, .hp = 0x03, .pattern = 0x00, .sr = 0x0F, .dr = 0x01, .xp = 0x01, .gp = 0x02 }, // Slime
    .{ .str = 0x07, .agi = 0x03, .hp = 0x04, .pattern = 0x00, .sr = 0x0F, .dr = 0x01, .xp = 0x01, .gp = 0x03 }, // Red Slime
    .{ .str = 0x09, .agi = 0x06, .hp = 0x06, .pattern = 0x00, .sr = 0x0F, .dr = 0x01, .xp = 0x02, .gp = 0x03 }, // Drakee
    .{ .str = 0x0B, .agi = 0x08, .hp = 0x07, .pattern = 0x00, .sr = 0x0F, .dr = 0x04, .xp = 0x03, .gp = 0x05 }, // Ghost
    .{ .str = 0x0B, .agi = 0x0C, .hp = 0x0D, .pattern = 0x02, .sr = 0x00, .dr = 0x01, .xp = 0x04, .gp = 0x0C }, // Magician
    .{ .str = 0x0E, .agi = 0x0E, .hp = 0x0F, .pattern = 0x02, .sr = 0x00, .dr = 0x01, .xp = 0x05, .gp = 0x0C }, // Magidrakee
    .{ .str = 0x12, .agi = 0x10, .hp = 0x14, .pattern = 0x00, .sr = 0x0F, .dr = 0x01, .xp = 0x06, .gp = 0x10 }, // Scorpion
    .{ .str = 0x14, .agi = 0x12, .hp = 0x16, .pattern = 0x00, .sr = 0x0F, .dr = 0x02, .xp = 0x07, .gp = 0x10 }, // Druin
    .{ .str = 0x12, .agi = 0x14, .hp = 0x17, .pattern = 0x03, .sr = 0x00, .dr = 0x06, .xp = 0x08, .gp = 0x12 }, // Poltergeist
    .{ .str = 0x18, .agi = 0x18, .hp = 0x19, .pattern = 0x00, .sr = 0x0E, .dr = 0x02, .xp = 0x0A, .gp = 0x19 }, // Droll
    .{ .str = 0x16, .agi = 0x1A, .hp = 0x14, .pattern = 0x92, .sr = 0x20, .dr = 0x06, .xp = 0x0B, .gp = 0x14 }, // Drakeema
    .{ .str = 0x1C, .agi = 0x16, .hp = 0x1E, .pattern = 0x00, .sr = 0x0F, .dr = 0x04, .xp = 0x0B, .gp = 0x1E }, // Skeleton
    .{ .str = 0x1C, .agi = 0x16, .hp = 0x1E, .pattern = 0x12, .sr = 0x31, .dr = 0x02, .xp = 0x0D, .gp = 0x23 }, // Warlock
    .{ .str = 0x24, .agi = 0x2A, .hp = 0x16, .pattern = 0x00, .sr = 0x0F, .dr = 0x02, .xp = 0x0E, .gp = 0x28 }, // Metal Scorpion
    .{ .str = 0x28, .agi = 0x1E, .hp = 0x22, .pattern = 0x00, .sr = 0x1F, .dr = 0x02, .xp = 0x10, .gp = 0x32 }, // Wolf
    .{ .str = 0x2C, .agi = 0x22, .hp = 0x24, .pattern = 0x90, .sr = 0x70, .dr = 0x04, .xp = 0x11, .gp = 0x3C }, // Wraith
    .{ .str = 0x0A, .agi = 0xFF, .hp = 0x04, .pattern = 0x03, .sr = 0xFF, .dr = 0xF1, .xp = 0x73, .gp = 0x06 }, // Metal Slime
    .{ .str = 0x28, .agi = 0x26, .hp = 0x24, .pattern = 0x13, .sr = 0x31, .dr = 0x04, .xp = 0x12, .gp = 0x46 }, // Specter
    .{ .str = 0x32, .agi = 0x24, .hp = 0x26, .pattern = 0x60, .sr = 0x47, .dr = 0x02, .xp = 0x14, .gp = 0x50 }, // Wolflord
    .{ .str = 0x2F, .agi = 0x28, .hp = 0x23, .pattern = 0xB1, .sr = 0xF0, .dr = 0x04, .xp = 0x14, .gp = 0x55 }, // Druinlord
    .{ .str = 0x34, .agi = 0x32, .hp = 0x26, .pattern = 0x60, .sr = 0x22, .dr = 0x01, .xp = 0x16, .gp = 0x5A }, // Drollmagi
    .{ .str = 0x38, .agi = 0x30, .hp = 0x2A, .pattern = 0x00, .sr = 0x4F, .dr = 0x02, .xp = 0x18, .gp = 0x64 }, // Wyvern
    .{ .str = 0x3C, .agi = 0x5A, .hp = 0x23, .pattern = 0x00, .sr = 0x7F, .dr = 0x02, .xp = 0x1A, .gp = 0x6E }, // Rogue Scorpion
    .{ .str = 0x44, .agi = 0x38, .hp = 0x2E, .pattern = 0xB0, .sr = 0x50, .dr = 0x34, .xp = 0x1C, .gp = 0x78 }, // Wraith Knight
    .{ .str = 0x78, .agi = 0x3C, .hp = 0x46, .pattern = 0x00, .sr = 0xFF, .dr = 0xF0, .xp = 0x05, .gp = 0x0A }, // Golem
    .{ .str = 0x30, .agi = 0x28, .hp = 0x32, .pattern = 0x00, .sr = 0xDF, .dr = 0x01, .xp = 0x06, .gp = 0xC8 }, // Goldman
    .{ .str = 0x4C, .agi = 0x4E, .hp = 0x37, .pattern = 0x60, .sr = 0x67, .dr = 0x01, .xp = 0x21, .gp = 0x82 }, // Knight
    .{ .str = 0x4E, .agi = 0x44, .hp = 0x3A, .pattern = 0x20, .sr = 0x20, .dr = 0x02, .xp = 0x22, .gp = 0x8C }, // Magiwyvern
    .{ .str = 0x4F, .agi = 0x40, .hp = 0x32, .pattern = 0x00, .sr = 0xFF, .dr = 0xFF, .xp = 0x25, .gp = 0x96 }, // Demon Knight
    .{ .str = 0x56, .agi = 0x46, .hp = 0x3C, .pattern = 0x00, .sr = 0x7F, .dr = 0x07, .xp = 0x28, .gp = 0x9B }, // Werewolf
    .{ .str = 0x58, .agi = 0x4A, .hp = 0x41, .pattern = 0x09, .sr = 0x7F, .dr = 0x22, .xp = 0x2D, .gp = 0xA0 }, // Green Dragon
    .{ .str = 0x56, .agi = 0x50, .hp = 0x41, .pattern = 0xF9, .sr = 0x80, .dr = 0x12, .xp = 0x2B, .gp = 0xA0 }, // Starwyvern
    .{ .str = 0x50, .agi = 0x46, .hp = 0x41, .pattern = 0x06, .sr = 0xF7, .dr = 0xF2, .xp = 0x32, .gp = 0xA5 }, // Wizard
    .{ .str = 0x5E, .agi = 0x52, .hp = 0x46, .pattern = 0x10, .sr = 0xF3, .dr = 0x11, .xp = 0x36, .gp = 0xA5 }, // Axe Knight
    .{ .str = 0x62, .agi = 0x54, .hp = 0x46, .pattern = 0x09, .sr = 0xFF, .dr = 0x72, .xp = 0x3C, .gp = 0x96 }, // Blue Dragon
    .{ .str = 0x64, .agi = 0x28, .hp = 0xA0, .pattern = 0x00, .sr = 0x2F, .dr = 0x71, .xp = 0x41, .gp = 0x8C }, // Stoneman
    .{ .str = 0x69, .agi = 0x56, .hp = 0x5A, .pattern = 0xF5, .sr = 0xF7, .dr = 0x12, .xp = 0x46, .gp = 0x8C }, // Armored Knight
    .{ .str = 0x78, .agi = 0x5A, .hp = 0x64, .pattern = 0x19, .sr = 0xF7, .dr = 0xF2, .xp = 0x64, .gp = 0x8C }, // Red Dragon
    .{ .str = 0x5A, .agi = 0x4B, .hp = 0x64, .pattern = 0x57, .sr = 0xFF, .dr = 0xF0, .xp = 0x00, .gp = 0x00 }, // Dragonlord1
    .{ .str = 0x8C, .agi = 0xC8, .hp = 0x82, .pattern = 0x0E, .sr = 0xFF, .dr = 0xF0, .xp = 0x00, .gp = 0x00 }, // Dragonlord2
};

/// $F54F: five slots per zone. Zones 0-13 are overworld, 14-19 dungeons.
pub const enemy_sets = [20][5]EnemyId{
    .{ .slime, .red_slime, .slime, .red_slime, .slime }, // zone 0
    .{ .red_slime, .slime, .red_slime, .drakee, .red_slime }, // zone 1
    .{ .slime, .ghost, .drakee, .ghost, .red_slime }, // zone 2
    .{ .red_slime, .red_slime, .drakee, .ghost, .magician }, // zone 3
    .{ .ghost, .magician, .magidrakee, .magidrakee, .scorpion }, // zone 4
    .{ .ghost, .magician, .magidrakee, .scorpion, .skeleton }, // zone 5
    .{ .magidrakee, .scorpion, .skeleton, .warlock, .wolf }, // zone 6
    .{ .skeleton, .warlock, .metal_scorpion, .wolf, .wolf }, // zone 7
    .{ .metal_scorpion, .wraith, .wolflord, .wolflord, .goldman }, // zone 8
    .{ .wraith, .wyvern, .wolflord, .wyvern, .goldman }, // zone 9
    .{ .wyvern, .rogue_scorpion, .wraith_knight, .knight, .demon_knight }, // zone 10
    .{ .wraith_knight, .knight, .magiwyvern, .demon_knight, .metal_slime }, // zone 11
    .{ .knight, .magiwyvern, .demon_knight, .werewolf, .starwyvern }, // zone 12
    .{ .werewolf, .green_dragon, .starwyvern, .starwyvern, .wizard }, // zone 13
    .{ .poltergeist, .droll, .drakeema, .skeleton, .warlock }, // zone 14
    .{ .specter, .wolflord, .druinlord, .drollmagi, .wraith_knight }, // zone 15
    .{ .werewolf, .green_dragon, .starwyvern, .wizard, .axe_knight }, // zone 16
    .{ .wizard, .axe_knight, .blue_dragon, .blue_dragon, .stoneman }, // zone 17
    .{ .wizard, .stoneman, .armored_knight, .armored_knight, .red_dragon }, // zone 18
    .{ .ghost, .magician, .scorpion, .druin, .druin }, // zone 19
};
