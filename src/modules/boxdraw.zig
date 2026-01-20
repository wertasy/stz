//! 框线字符绘制
//! 绘制 Unicode 框线字符 (U+2500-U+259F)

const std = @import("std");
const types = @import("types.zig");
const boxdraw_data = @import("boxdraw_data.zig");

const Glyph = types.Glyph;

pub const BoxDrawError = error{
    NotBoxDrawChar,
};

/// 框线字符检测和绘制
pub const BoxDraw = struct {
    /// 检查是否是框线字符
    pub fn isBoxDraw(u: u21) bool {
        if (u >= 0x2800 and u <= 0x28FF) return true;
        if (u >= 0x2500 and u <= 0x259F) {
            return boxdraw_data.boxdata[u - 0x2500] != 0;
        }
        return false;
    }

    /// 获取绘制数据
    pub fn getDrawData(u: u21) u16 {
        if (u >= 0x2800 and u <= 0x28FF) {
            return boxdraw_data.BRL | @as(u16, @truncate(u));
        }
        if (u >= 0x2500 and u <= 0x259F) {
            return boxdraw_data.boxdata[u - 0x2500];
        }
        return 0;
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
