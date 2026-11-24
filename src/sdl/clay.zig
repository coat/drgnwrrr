//! A thin layer over Clay's C API, standing in for its macros (CLAY, CLAY_TEXT,
//! CLAY_ID, CLAY_SIZING_*), which translate-c can't carry over. Translated
//! structs have no defaults, so declarations and text configs are partial
//! literals, zeroed where they leave fields out (Clay's defaults are zeroes).
const std = @import("std");
const c = @import("c");

pub const Declaration = c.Clay_ElementDeclaration;
pub const Color = c.Clay_Color;
pub const ElementId = c.Clay_ElementId;

pub fn str(s: []const u8) c.Clay_String {
    return .{ .isStaticallyAllocated = false, .length = @intCast(s.len), .chars = s.ptr };
}

pub fn id(label: []const u8) ElementId {
    return c.Clay__HashString(str(label), 0, 0);
}

/// Opens an element (`d` is a partial Declaration); its children follow, then
/// close(). A clipped element scrolls: its offset is Clay's, which can only
/// be asked for once the element is open.
pub fn open(d: anytype) void {
    c.Clay__OpenElement();
    var decl = std.mem.zeroInit(Declaration, d);
    if (decl.clip.vertical or decl.clip.horizontal) decl.clip.childOffset = c.Clay_GetScrollOffset();
    c.Clay__ConfigureOpenElement(decl);
}

pub fn close() void {
    c.Clay__CloseElement();
}

/// An element with no children.
pub fn leaf(d: anytype) void {
    open(d);
    close();
}

pub const TextConfig = c.Clay_TextElementConfig;

/// `s` must stay put until the frame is drawn; `config` is a partial TextConfig.
pub fn text(s: []const u8, config: anytype) void {
    c.Clay__OpenTextElement(str(s), c.Clay__StoreTextElementConfig(std.mem.zeroInit(TextConfig, config)));
}

pub fn sizing(width: c.Clay_SizingAxis, height: c.Clay_SizingAxis) c.Clay_Sizing {
    return .{ .width = width, .height = height };
}

pub fn grow() c.Clay_SizingAxis {
    return .{ .type = c.CLAY__SIZING_TYPE_GROW, .size = .{ .minMax = .{ .min = 0, .max = 0 } } };
}

pub fn fit() c.Clay_SizingAxis {
    return .{ .type = c.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 0, .max = 0 } } };
}

pub fn fixed(px: f32) c.Clay_SizingAxis {
    return .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = px, .max = px } } };
}

pub fn padding(x: u16, y: u16) c.Clay_Padding {
    return .{ .left = x, .right = x, .top = y, .bottom = y };
}

/// 0xRRGGBB, opaque. Clay's colours run 0-255.
pub fn rgb(hex: u24) Color {
    return .{
        .r = @floatFromInt(hex >> 16),
        .g = @floatFromInt((hex >> 8) & 0xff),
        .b = @floatFromInt(hex & 0xff),
        .a = 255,
    };
}

// Clay's packed enums are one byte, but translate-c gives their values as c_int.
pub const left_to_right: u8 = c.CLAY_LEFT_TO_RIGHT;
pub const top_to_bottom: u8 = c.CLAY_TOP_TO_BOTTOM;
pub const wrap_words: u8 = c.CLAY_TEXT_WRAP_WORDS;
pub const wrap_none: u8 = c.CLAY_TEXT_WRAP_NONE;
pub const align_left: u8 = c.CLAY_ALIGN_X_LEFT;
pub const align_center: u8 = c.CLAY_ALIGN_X_CENTER;
pub const align_right: u8 = c.CLAY_ALIGN_X_RIGHT;
pub const align_top: u8 = c.CLAY_ALIGN_Y_TOP;
pub const align_middle: u8 = c.CLAY_ALIGN_Y_CENTER;
pub const text_center: u8 = c.CLAY_TEXT_ALIGN_CENTER;
pub const text_right: u8 = c.CLAY_TEXT_ALIGN_RIGHT;
pub const attach_parent: u8 = c.CLAY_ATTACH_TO_PARENT;
pub const point_left_top: u8 = c.CLAY_ATTACH_POINT_LEFT_TOP;
pub const point_right_top: u8 = c.CLAY_ATTACH_POINT_RIGHT_TOP;
pub const pointer_passthrough: u8 = c.CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;

pub fn percent(p: f32) c.Clay_SizingAxis {
    return .{ .type = c.CLAY__SIZING_TYPE_PERCENT, .size = .{ .percent = p } };
}

/// The box `id` was given in the last layout.
pub fn box(label: []const u8) ?c.Clay_BoundingBox {
    const data = c.Clay_GetElementData(id(label));
    return if (data.found) data.boundingBox else null;
}

pub fn inBox(b: ?c.Clay_BoundingBox, x: f32, y: f32) bool {
    const r = b orelse return false;
    return x >= r.x and y >= r.y and x < r.x + r.width and y < r.y + r.height;
}

/// A `w` px border all round; no border for null.
pub fn border(color: ?u24, w: u16) c.Clay_BorderElementConfig {
    const col = color orelse return std.mem.zeroes(c.Clay_BorderElementConfig);
    return .{ .color = rgb(col), .width = .{ .left = w, .right = w, .top = w, .bottom = w, .betweenChildren = 0 } };
}
