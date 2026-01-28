//! Box Drawing 字符绘制数据
//! 基于 st 的 boxdraw_data.h 实现 (原始 C 代码版)

/// Box Drawing 字符数据编码 (16-bit)
/// 高位是类别，低位是数据

// 类别标志
pub const LINE = 1 << 8; // Box Draw Lines (light/double/heavy)
pub const ARC = 1 << 9; // Box Draw Arc (light)
pub const BLOCK_DOWN = 1 << 10; // Box Block Down (lower) X/8
pub const BLOCK_LEFT = 2 << 10; // Box Block Left X/8
pub const BLOCK_UPPER = 3 << 10; // Box Block Upper X/8
pub const BLOCK_RIGHT = 4 << 10; // Box Block Right (8-X)/8
pub const BLOCK_QUADRANT = 5 << 10; // Box Block Quadrants
pub const BRAILLE = 6 << 10; // Box Braille (data is lower byte of U28XX)
pub const BLOCK_SHADE = 1 << 14; // Box Block Shades
pub const BOLD = 1 << 15; // Box Draw is Bold
pub const TRIANGLE = 1 << 13; // Box Triangle (up/down/left/right)

// (BDL/BDA) Light/Double/Heavy x Left/Up/Right/Down/Horizontal/Vertical
// Heavy is light+double (literally drawing light+double align to form heavy)
pub const LIGHT_LEFT = 1 << 0;
pub const LIGHT_UP = 1 << 1;
pub const LIGHT_RIGHT = 1 << 2;
pub const LIGHT_DOWN = 1 << 3;
pub const LIGHT_HORIZONTAL = LIGHT_LEFT + LIGHT_RIGHT;
pub const LIGHT_VERTICAL = LIGHT_UP + LIGHT_DOWN;

pub const DOUBLE_LEFT = 1 << 4;
pub const DOUBLE_UP = 1 << 5;
pub const DOUBLE_RIGHT = 1 << 6;
pub const DOUBLE_DOWN = 1 << 7;
pub const DOUBLE_HORIZONTAL = DOUBLE_LEFT + DOUBLE_RIGHT;
pub const DOUBLE_VERTICAL = DOUBLE_UP + DOUBLE_DOWN;

pub const HEAVY_LEFT = LIGHT_LEFT + DOUBLE_LEFT;
pub const HEAVY_RIGHT = LIGHT_RIGHT + DOUBLE_RIGHT;
pub const HEAVY_UP = LIGHT_UP + DOUBLE_UP;
pub const HEAVY_DOWN = LIGHT_DOWN + DOUBLE_DOWN;
pub const HEAVY_HORIZONTAL = HEAVY_LEFT + HEAVY_RIGHT;
pub const HEAVY_VERTICAL = HEAVY_UP + HEAVY_DOWN;

// (BBQ) Quadrants Top/Bottom x Left/Right
pub const TOP_LEFT = 1 << 0;
pub const TOP_RIGHT = 1 << 1;
pub const BOTTOM_LEFT = 1 << 2;
pub const BOTTOM_RIGHT = 1 << 3;

/// Box Drawing 字符查找表 (U+2500 - U+25FF)
/// 虽然索引只需到 0x9F (160)，但原 C 代码使用了 256 大小以直接映射低 8 位
pub const boxdata = init: {
    var data = [_]u16{0} ** 256;

    // light lines
    data[0x00] = LINE + LIGHT_HORIZONTAL; // light horizontal
    data[0x02] = LINE + LIGHT_VERTICAL; // light vertical
    data[0x0c] = LINE + LIGHT_DOWN + LIGHT_RIGHT; // light down and right
    data[0x10] = LINE + LIGHT_DOWN + LIGHT_LEFT; // light down and left
    data[0x14] = LINE + LIGHT_UP + LIGHT_RIGHT; // light up and right
    data[0x18] = LINE + LIGHT_UP + LIGHT_LEFT; // light up and left
    data[0x1c] = LINE + LIGHT_VERTICAL + LIGHT_RIGHT; // light vertical and right
    data[0x24] = LINE + LIGHT_VERTICAL + LIGHT_LEFT; // light vertical and left
    data[0x2c] = LINE + LIGHT_HORIZONTAL + LIGHT_DOWN; // light horizontal and down
    data[0x34] = LINE + LIGHT_HORIZONTAL + LIGHT_UP; // light horizontal and up
    data[0x3c] = LINE + LIGHT_VERTICAL + LIGHT_HORIZONTAL; // light vertical and horizontal
    data[0x74] = LINE + LIGHT_LEFT; // light left
    data[0x75] = LINE + LIGHT_UP; // light up
    data[0x76] = LINE + LIGHT_RIGHT; // light right
    data[0x77] = LINE + LIGHT_DOWN; // light down

    // heavy [+light] lines
    data[0x01] = LINE + HEAVY_HORIZONTAL;
    data[0x03] = LINE + HEAVY_VERTICAL;
    data[0x0d] = LINE + HEAVY_RIGHT + LIGHT_DOWN;
    data[0x0e] = LINE + HEAVY_DOWN + LIGHT_RIGHT;
    data[0x0f] = LINE + HEAVY_DOWN + HEAVY_RIGHT;
    data[0x11] = LINE + HEAVY_LEFT + LIGHT_DOWN;
    data[0x12] = LINE + HEAVY_DOWN + LIGHT_LEFT;
    data[0x13] = LINE + HEAVY_DOWN + HEAVY_LEFT;
    data[0x15] = LINE + HEAVY_RIGHT + LIGHT_UP;
    data[0x16] = LINE + HEAVY_UP + LIGHT_RIGHT;
    data[0x17] = LINE + HEAVY_UP + HEAVY_RIGHT;
    data[0x19] = LINE + HEAVY_LEFT + LIGHT_UP;
    data[0x1a] = LINE + HEAVY_UP + LIGHT_LEFT;
    data[0x1b] = LINE + HEAVY_UP + HEAVY_LEFT;
    data[0x1d] = LINE + HEAVY_RIGHT + LIGHT_VERTICAL;
    data[0x1e] = LINE + HEAVY_DOWN + LIGHT_RIGHT + LIGHT_UP;
    data[0x1f] = LINE + HEAVY_UP + LIGHT_DOWN + LIGHT_RIGHT;
    data[0x20] = LINE + HEAVY_VERTICAL + LIGHT_RIGHT;
    data[0x21] = LINE + HEAVY_UP + HEAVY_RIGHT + LIGHT_DOWN;
    data[0x22] = LINE + HEAVY_DOWN + HEAVY_RIGHT + LIGHT_UP;
    data[0x23] = LINE + HEAVY_VERTICAL + HEAVY_RIGHT;
    data[0x25] = LINE + HEAVY_LEFT + LIGHT_VERTICAL;
    data[0x26] = LINE + HEAVY_UP + LIGHT_DOWN + LIGHT_LEFT;
    data[0x27] = LINE + HEAVY_DOWN + LIGHT_UP + LIGHT_LEFT;
    data[0x28] = LINE + HEAVY_VERTICAL + LIGHT_LEFT;
    data[0x29] = LINE + HEAVY_UP + HEAVY_LEFT + LIGHT_DOWN;
    data[0x2a] = LINE + HEAVY_DOWN + HEAVY_LEFT + LIGHT_UP;
    data[0x2b] = LINE + HEAVY_VERTICAL + HEAVY_LEFT;
    data[0x2d] = LINE + HEAVY_LEFT + LIGHT_DOWN + LIGHT_RIGHT;
    data[0x2e] = LINE + HEAVY_RIGHT + LIGHT_LEFT + LIGHT_DOWN;
    data[0x2f] = LINE + HEAVY_HORIZONTAL + LIGHT_DOWN;
    data[0x30] = LINE + HEAVY_DOWN + LIGHT_HORIZONTAL;
    data[0x31] = LINE + HEAVY_DOWN + HEAVY_LEFT + LIGHT_RIGHT;
    data[0x32] = LINE + HEAVY_RIGHT + HEAVY_DOWN + LIGHT_LEFT;
    data[0x33] = LINE + HEAVY_HORIZONTAL + HEAVY_DOWN;
    data[0x35] = LINE + HEAVY_LEFT + LIGHT_UP + LIGHT_RIGHT;
    data[0x36] = LINE + HEAVY_RIGHT + LIGHT_UP + LIGHT_LEFT;
    data[0x37] = LINE + HEAVY_HORIZONTAL + LIGHT_UP;
    data[0x38] = LINE + HEAVY_UP + LIGHT_HORIZONTAL;
    data[0x39] = LINE + HEAVY_UP + HEAVY_LEFT + LIGHT_RIGHT;
    data[0x3a] = LINE + HEAVY_UP + HEAVY_RIGHT + LIGHT_LEFT;
    data[0x3b] = LINE + HEAVY_HORIZONTAL + HEAVY_UP;
    data[0x3d] = LINE + HEAVY_LEFT + LIGHT_VERTICAL + LIGHT_RIGHT;
    data[0x3e] = LINE + HEAVY_RIGHT + LIGHT_VERTICAL + LIGHT_LEFT;
    data[0x3f] = LINE + HEAVY_HORIZONTAL + LIGHT_VERTICAL;
    data[0x40] = LINE + HEAVY_UP + LIGHT_HORIZONTAL + LIGHT_DOWN;
    data[0x41] = LINE + HEAVY_DOWN + LIGHT_HORIZONTAL + LIGHT_UP;
    data[0x42] = LINE + HEAVY_VERTICAL + LIGHT_HORIZONTAL;
    data[0x43] = LINE + HEAVY_UP + HEAVY_LEFT + LIGHT_DOWN + LIGHT_RIGHT;
    data[0x44] = LINE + HEAVY_UP + HEAVY_RIGHT + LIGHT_DOWN + LIGHT_LEFT;
    data[0x45] = LINE + HEAVY_DOWN + HEAVY_LEFT + LIGHT_UP + LIGHT_RIGHT;
    data[0x46] = LINE + HEAVY_DOWN + HEAVY_RIGHT + LIGHT_UP + LIGHT_LEFT;
    data[0x47] = LINE + HEAVY_HORIZONTAL + HEAVY_UP + LIGHT_DOWN;
    data[0x48] = LINE + HEAVY_HORIZONTAL + HEAVY_DOWN + LIGHT_UP;
    data[0x49] = LINE + HEAVY_VERTICAL + HEAVY_LEFT + LIGHT_RIGHT;
    data[0x4a] = LINE + HEAVY_VERTICAL + HEAVY_RIGHT + LIGHT_LEFT;
    data[0x4b] = LINE + HEAVY_VERTICAL + HEAVY_HORIZONTAL;
    data[0x78] = LINE + HEAVY_LEFT;
    data[0x79] = LINE + HEAVY_UP;
    data[0x7a] = LINE + HEAVY_RIGHT;
    data[0x7b] = LINE + HEAVY_DOWN;
    data[0x7c] = LINE + HEAVY_RIGHT + LIGHT_LEFT;
    data[0x7d] = LINE + HEAVY_DOWN + LIGHT_UP;
    data[0x7e] = LINE + HEAVY_LEFT + LIGHT_RIGHT;
    data[0x7f] = LINE + HEAVY_UP + LIGHT_DOWN;

    // double [+light] lines
    data[0x50] = LINE + DOUBLE_HORIZONTAL;
    data[0x51] = LINE + DOUBLE_VERTICAL;
    data[0x52] = LINE + DOUBLE_RIGHT + LIGHT_DOWN;
    data[0x53] = LINE + DOUBLE_DOWN + LIGHT_RIGHT;
    data[0x54] = LINE + DOUBLE_RIGHT + DOUBLE_DOWN;
    data[0x55] = LINE + DOUBLE_LEFT + LIGHT_DOWN;
    data[0x56] = LINE + DOUBLE_DOWN + LIGHT_LEFT;
    data[0x57] = LINE + DOUBLE_LEFT + DOUBLE_DOWN;
    data[0x58] = LINE + DOUBLE_RIGHT + LIGHT_UP;
    data[0x59] = LINE + DOUBLE_UP + LIGHT_RIGHT;
    data[0x5a] = LINE + DOUBLE_UP + DOUBLE_RIGHT;
    data[0x5b] = LINE + DOUBLE_LEFT + LIGHT_UP;
    data[0x5c] = LINE + DOUBLE_UP + LIGHT_LEFT;
    data[0x5d] = LINE + DOUBLE_LEFT + DOUBLE_UP;
    data[0x5e] = LINE + DOUBLE_RIGHT + LIGHT_VERTICAL;
    data[0x5f] = LINE + DOUBLE_VERTICAL + LIGHT_RIGHT;
    data[0x60] = LINE + DOUBLE_VERTICAL + DOUBLE_RIGHT;
    data[0x61] = LINE + DOUBLE_LEFT + LIGHT_VERTICAL;
    data[0x62] = LINE + DOUBLE_VERTICAL + LIGHT_LEFT;
    data[0x63] = LINE + DOUBLE_VERTICAL + DOUBLE_LEFT;
    data[0x64] = LINE + DOUBLE_HORIZONTAL + LIGHT_DOWN;
    data[0x65] = LINE + DOUBLE_DOWN + LIGHT_HORIZONTAL;
    data[0x66] = LINE + DOUBLE_DOWN + DOUBLE_HORIZONTAL;
    data[0x67] = LINE + DOUBLE_HORIZONTAL + LIGHT_UP;
    data[0x68] = LINE + DOUBLE_UP + LIGHT_HORIZONTAL;
    data[0x69] = LINE + DOUBLE_HORIZONTAL + DOUBLE_UP;
    data[0x6a] = LINE + DOUBLE_HORIZONTAL + LIGHT_VERTICAL;
    data[0x6b] = LINE + DOUBLE_VERTICAL + LIGHT_HORIZONTAL;
    data[0x6c] = LINE + DOUBLE_HORIZONTAL + DOUBLE_VERTICAL;

    // (light) arcs
    data[0x6d] = ARC + LIGHT_DOWN + LIGHT_RIGHT;
    data[0x6e] = ARC + LIGHT_DOWN + LIGHT_LEFT;
    data[0x6f] = ARC + LIGHT_UP + LIGHT_LEFT;
    data[0x70] = ARC + LIGHT_UP + LIGHT_RIGHT;

    // Lower (Down) X/8 block (data is 8 - X)
    data[0x81] = BLOCK_DOWN + 7;
    data[0x82] = BLOCK_DOWN + 6;
    data[0x83] = BLOCK_DOWN + 5;
    data[0x84] = BLOCK_DOWN + 4;
    data[0x85] = BLOCK_DOWN + 3;
    data[0x86] = BLOCK_DOWN + 2;
    data[0x87] = BLOCK_DOWN + 1;
    data[0x88] = BLOCK_DOWN + 0;

    // Left X/8 block (data is X)
    data[0x89] = BLOCK_LEFT + 7;
    data[0x8a] = BLOCK_LEFT + 6;
    data[0x8b] = BLOCK_LEFT + 5;
    data[0x8c] = BLOCK_LEFT + 4;
    data[0x8d] = BLOCK_LEFT + 3;
    data[0x8e] = BLOCK_LEFT + 2;
    data[0x8f] = BLOCK_LEFT + 1;

    // upper 1/2 (4/8), 1/8 block (X), right 1/2, 1/8 block (8-X)
    data[0x80] = BLOCK_UPPER + 4;
    data[0x94] = BLOCK_UPPER + 1;
    data[0x90] = BLOCK_RIGHT + 4;
    data[0x95] = BLOCK_RIGHT + 7;

    // Quadrants
    data[0x96] = BLOCK_QUADRANT + BOTTOM_LEFT;
    data[0x97] = BLOCK_QUADRANT + BOTTOM_RIGHT;
    data[0x98] = BLOCK_QUADRANT + TOP_LEFT;
    data[0x99] = BLOCK_QUADRANT + TOP_LEFT + BOTTOM_LEFT + BOTTOM_RIGHT;
    data[0x9a] = BLOCK_QUADRANT + TOP_LEFT + BOTTOM_RIGHT;
    data[0x9b] = BLOCK_QUADRANT + TOP_LEFT + TOP_RIGHT + BOTTOM_LEFT;
    data[0x9c] = BLOCK_QUADRANT + TOP_LEFT + TOP_RIGHT + BOTTOM_RIGHT;
    data[0x9d] = BLOCK_QUADRANT + TOP_RIGHT;
    data[0x9e] = BLOCK_QUADRANT + BOTTOM_LEFT + TOP_RIGHT;
    data[0x9f] = BLOCK_QUADRANT + BOTTOM_LEFT + TOP_RIGHT + BOTTOM_RIGHT;

    // Shades, data is an alpha value in 25% units (1/4, 1/2, 3/4)
    data[0x91] = BLOCK_SHADE + 1;
    data[0x92] = BLOCK_SHADE + 2;
    data[0x93] = BLOCK_SHADE + 3;

    break :init data;
};
