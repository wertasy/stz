//! 框线字符绘制
//! 绘制 Unicode 框线字符 (U+2500-U+259F)

const std = @import("std");
const types = @import("types.zig");

const Glyph = types.Glyph;

pub const BoxDrawError = error{
    NotBoxDrawChar,
};

/// 框线字符检测和绘制
pub const BoxDraw = struct {
    /// 检查是否是框线字符
    pub fn isBoxDraw(u: u21) bool {
        return u >= 0x2500 and u <= 0x259F;
    }

    /// 获取框线字符索引
    pub fn getIndex(u: u21) !u8 {
        if (!isBoxDraw(u)) {
            return error.NotBoxDrawChar;
        }

        // 简化映射：实际需要完整的框线字符表
        const index = @as(u8, (u - 0x2500) / 64);
        return index;
    }

    /// 绘制框线字符（简化实现）
    /// 实际实现需要根据字符类型绘制不同的线条
    pub fn draw(u: u21, x: i32, y: i32, w: i32, h: i32) !void {
        _ = u;
        _ = x;
        _ = y;
        _ = w;
        _ = h;

        // TODO: 实现完整的框线字符绘制
        // 这需要根据具体的框线字符类型（竖线、横线、角等）
        // 绘制对应的图形元素

        // 常见的框线字符范围：
        // 0x2500-0x257F: 框线
        // 0x2580-0x259F: 块元素
    }

    /// 检查字符是否需要特殊处理
    pub fn needsSpecialDraw(glyph: *const Glyph) bool {
        return glyph.attr.boxdraw and isBoxDraw(glyph.u);
    }
};

/// 框线字符类型
const BoxCharType = enum(u8) {
    /// 水平线
    horizontal_light = 0x2500,
    horizontal_heavy = 0x2501,
    horizontal_double = 0x2550,

    /// 垂直线
    vertical_light = 0x2502,
    vertical_heavy = 0x2503,
    vertical_double = 0x2551,

    /// 角落
    corner_down_right_light = 0x250C,
    corner_down_left_light = 0x2510,
    corner_up_right_light = 0x2518,
    corner_up_left_light = 0x2514,

    /// 交叉点
    cross_light = 0x253C,

    /// 块元素（用于绘制更复杂的图形）
    block_full = 0x2588,
    block_three_quarters = 0x2592,
    block_half = 0x258C,
};
