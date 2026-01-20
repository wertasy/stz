//! Box Drawing 字符绘制数据
//! 基于 st 的 boxdraw_data.h 实现 (原始 C 代码版)

/// Box Drawing 字符数据编码 (16-bit)
/// 高位是类别，低位是数据

// 类别标志
pub const BDL = 1 << 8; // Box Draw Lines (light/double/heavy)
pub const BDA = 1 << 9; // Box Draw Arc (light)
pub const BBD = 1 << 10; // Box Block Down (lower) X/8
pub const BBL = 2 << 10; // Box Block Left X/8
pub const BBU = 3 << 10; // Box Block Upper X/8
pub const BBR = 4 << 10; // Box Block Right (8-X)/8
pub const BBQ = 5 << 10; // Box Block Quadrants
pub const BRL = 6 << 10; // Box Braille (data is lower byte of U28XX)
pub const BBS = 1 << 14; // Box Block Shades
pub const BDB = 1 << 15; // Box Draw is Bold

// (BDL/BDA) Light/Double/Heavy x Left/Up/Right/Down/Horizontal/Vertical
// Heavy is light+double (literally drawing light+double align to form heavy)
pub const LL = 1 << 0;
pub const LU = 1 << 1;
pub const LR = 1 << 2;
pub const LD = 1 << 3;
pub const LH = LL + LR;
pub const LV = LU + LD;

pub const DL = 1 << 4;
pub const DU = 1 << 5;
pub const DR = 1 << 6;
pub const DD = 1 << 7;
pub const DH = DL + DR;
pub const DV = DU + DD;

pub const HL = LL + DL;
pub const HR = LR + DR;
pub const HU = LU + DU;
pub const HD = LD + DD;
pub const HH = HL + HR;
pub const HV = HU + HD;

// (BBQ) Quadrants Top/Bottom x Left/Right
pub const TL = 1 << 0;
pub const TR = 1 << 1;
pub const BL = 1 << 2;
pub const BR = 1 << 3;

/// Box Drawing 字符查找表 (U+2500 - U+25FF)
/// 虽然索引只需到 0x9F (160)，但原 C 代码使用了 256 大小以直接映射低 8 位
pub const boxdata = init: {
    var data = [_]u16{0} ** 256;

    // light lines
    data[0x00] = BDL + LH; // light horizontal
    data[0x02] = BDL + LV; // light vertical
    data[0x0c] = BDL + LD + LR; // light down and right
    data[0x10] = BDL + LD + LL; // light down and left
    data[0x14] = BDL + LU + LR; // light up and right
    data[0x18] = BDL + LU + LL; // light up and left
    data[0x1c] = BDL + LV + LR; // light vertical and right
    data[0x24] = BDL + LV + LL; // light vertical and left
    data[0x2c] = BDL + LH + LD; // light horizontal and down
    data[0x34] = BDL + LH + LU; // light horizontal and up
    data[0x3c] = BDL + LV + LH; // light vertical and horizontal
    data[0x74] = BDL + LL; // light left
    data[0x75] = BDL + LU; // light up
    data[0x76] = BDL + LR; // light right
    data[0x77] = BDL + LD; // light down

    // heavy [+light] lines
    data[0x01] = BDL + HH;
    data[0x03] = BDL + HV;
    data[0x0d] = BDL + HR + LD;
    data[0x0e] = BDL + HD + LR;
    data[0x0f] = BDL + HD + HR;
    data[0x11] = BDL + HL + LD;
    data[0x12] = BDL + HD + LL;
    data[0x13] = BDL + HD + HL;
    data[0x15] = BDL + HR + LU;
    data[0x16] = BDL + HU + LR;
    data[0x17] = BDL + HU + HR;
    data[0x19] = BDL + HL + LU;
    data[0x1a] = BDL + HU + LL;
    data[0x1b] = BDL + HU + HL;
    data[0x1d] = BDL + HR + LV;
    data[0x1e] = BDL + HD + LR + LU;
    data[0x1f] = BDL + HU + LD + LR;
    data[0x20] = BDL + HV + LR;
    data[0x21] = BDL + HU + HR + LD;
    data[0x22] = BDL + HD + HR + LU;
    data[0x23] = BDL + HV + HR;
    data[0x25] = BDL + HL + LV;
    data[0x26] = BDL + HU + LD + LL;
    data[0x27] = BDL + HD + LU + LL;
    data[0x28] = BDL + HV + LL;
    data[0x29] = BDL + HU + HL + LD;
    data[0x2a] = BDL + HD + HL + LU;
    data[0x2b] = BDL + HV + HL;
    data[0x2d] = BDL + HL + LD + LR;
    data[0x2e] = BDL + HR + LL + LD;
    data[0x2f] = BDL + HH + LD;
    data[0x30] = BDL + HD + LH;
    data[0x31] = BDL + HD + HL + LR;
    data[0x32] = BDL + HR + HD + LL;
    data[0x33] = BDL + HH + HD;
    data[0x35] = BDL + HL + LU + LR;
    data[0x36] = BDL + HR + LU + LL;
    data[0x37] = BDL + HH + LU;
    data[0x38] = BDL + HU + LH;
    data[0x39] = BDL + HU + HL + LR;
    data[0x3a] = BDL + HU + HR + LL;
    data[0x3b] = BDL + HH + HU;
    data[0x3d] = BDL + HL + LV + LR;
    data[0x3e] = BDL + HR + LV + LL;
    data[0x3f] = BDL + HH + LV;
    data[0x40] = BDL + HU + LH + LD;
    data[0x41] = BDL + HD + LH + LU;
    data[0x42] = BDL + HV + LH;
    data[0x43] = BDL + HU + HL + LD + LR;
    data[0x44] = BDL + HU + HR + LD + LL;
    data[0x45] = BDL + HD + HL + LU + LR;
    data[0x46] = BDL + HD + HR + LU + LL;
    data[0x47] = BDL + HH + HU + LD;
    data[0x48] = BDL + HH + HD + LU;
    data[0x49] = BDL + HV + HL + LR;
    data[0x4a] = BDL + HV + HR + LL;
    data[0x4b] = BDL + HV + HH;
    data[0x78] = BDL + HL;
    data[0x79] = BDL + HU;
    data[0x7a] = BDL + HR;
    data[0x7b] = BDL + HD;
    data[0x7c] = BDL + HR + LL;
    data[0x7d] = BDL + HD + LU;
    data[0x7e] = BDL + HL + LR;
    data[0x7f] = BDL + HU + LD;

    // double [+light] lines
    data[0x50] = BDL + DH;
    data[0x51] = BDL + DV;
    data[0x52] = BDL + DR + LD;
    data[0x53] = BDL + DD + LR;
    data[0x54] = BDL + DR + DD;
    data[0x55] = BDL + DL + LD;
    data[0x56] = BDL + DD + LL;
    data[0x57] = BDL + DL + DD;
    data[0x58] = BDL + DR + LU;
    data[0x59] = BDL + DU + LR;
    data[0x5a] = BDL + DU + DR;
    data[0x5b] = BDL + DL + LU;
    data[0x5c] = BDL + DU + LL;
    data[0x5d] = BDL + DL + DU;
    data[0x5e] = BDL + DR + LV;
    data[0x5f] = BDL + DV + LR;
    data[0x60] = BDL + DV + DR;
    data[0x61] = BDL + DL + LV;
    data[0x62] = BDL + DV + LL;
    data[0x63] = BDL + DV + DL;
    data[0x64] = BDL + DH + LD;
    data[0x65] = BDL + DD + LH;
    data[0x66] = BDL + DD + DH;
    data[0x67] = BDL + DH + LU;
    data[0x68] = BDL + DU + LH;
    data[0x69] = BDL + DH + DU;
    data[0x6a] = BDL + DH + LV;
    data[0x6b] = BDL + DV + LH;
    data[0x6c] = BDL + DH + DV;

    // (light) arcs
    data[0x6d] = BDA + LD + LR;
    data[0x6e] = BDA + LD + LL;
    data[0x6f] = BDA + LU + LL;
    data[0x70] = BDA + LU + LR;

    // Lower (Down) X/8 block (data is 8 - X)
    data[0x81] = BBD + 7;
    data[0x82] = BBD + 6;
    data[0x83] = BBD + 5;
    data[0x84] = BBD + 4;
    data[0x85] = BBD + 3;
    data[0x86] = BBD + 2;
    data[0x87] = BBD + 1;
    data[0x88] = BBD + 0;

    // Left X/8 block (data is X)
    data[0x89] = BBL + 7;
    data[0x8a] = BBL + 6;
    data[0x8b] = BBL + 5;
    data[0x8c] = BBL + 4;
    data[0x8d] = BBL + 3;
    data[0x8e] = BBL + 2;
    data[0x8f] = BBL + 1;

    // upper 1/2 (4/8), 1/8 block (X), right 1/2, 1/8 block (8-X)
    data[0x80] = BBU + 4;
    data[0x94] = BBU + 1;
    data[0x90] = BBR + 4;
    data[0x95] = BBR + 7;

    // Quadrants
    data[0x96] = BBQ + BL;
    data[0x97] = BBQ + BR;
    data[0x98] = BBQ + TL;
    data[0x99] = BBQ + TL + BL + BR;
    data[0x9a] = BBQ + TL + BR;
    data[0x9b] = BBQ + TL + TR + BL;
    data[0x9c] = BBQ + TL + TR + BR;
    data[0x9d] = BBQ + TR;
    data[0x9e] = BBQ + BL + TR;
    data[0x9f] = BBQ + BL + TR + BR;

    // Shades, data is an alpha value in 25% units (1/4, 1/2, 3/4)
    data[0x91] = BBS + 1;
    data[0x92] = BBS + 2;
    data[0x93] = BBS + 3;

    // Geometric Shapes (to avoid gaps in common symbols)
    data[0xa0] = BBD + 0; // ■ (BLACK SQUARE) -> Full Block

    break :init data;
};
