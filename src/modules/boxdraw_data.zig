//! Box Drawing 字符绘制数据
//! 基于 st 的 boxdraw_data.h 实现

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

// Light/Double 线条方向
pub const LL = 1 << 0; // Left
pub const LU = 1 << 1; // Up
pub const LR = 1 << 2; // Right
pub const LD = 1 << 3; // Down
pub const LH = LL + LR; // Horizontal
pub const LV = LU + LD; // Vertical

pub const DL = 1 << 4; // Double Left
pub const DU = 1 << 5; // Double Up
pub const DR = 1 << 6; // Double Right
pub const DD = 1 << 7; // Double Down
pub const DH = DL + DR; // Double Horizontal
pub const DV = DU + DD; // Double Vertical

// Quadrants (for BBQ)
pub const TL = 1 << 0; // Top Left
pub const TR = 1 << 1; // Top Right
pub const BL = 1 << 2; // Bottom Left
pub const BR = 1 << 3; // Bottom Right

// Heavy lines (light + double)
pub const HH = LH + DH; // Heavy Horizontal
pub const HV = LV + DV; // Heavy Vertical
pub const HL = LL + DL; // Heavy Left
pub const HR = LR + DR; // Heavy Right
pub const HU = LU + DU; // Heavy Up
pub const HD = LD + DD; // Heavy Down
