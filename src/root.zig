//! drgnwrrr: Dragon Warrior's rules without the walking, dialogue and drama.
pub const dw = @import("dw");
pub const game = @import("game.zig");
pub const battle = @import("battle.zig");
pub const travel = @import("travel.zig");
pub const quests = @import("quests.zig");
pub const session = @import("session.zig");

pub const Game = game.Game;
pub const Session = session.Session;

test {
    @import("std").testing.refAllDecls(@This());
    _ = game;
    _ = battle;
    _ = travel;
    _ = quests;
    _ = session;
}
