//! UTF-8 编解码模块
//! 使用 Zig 标准库的 std.unicode

const std = @import("std");
const utf8 = std.unicode;

pub const Utf8Error = error{
    InvalidUtf8,
    OverlongEncoding,
    InvalidCodepoint,
};

/// 从 UTF-8 字节序列解码 Unicode 码点
pub fn decode(utf8_bytes: []const u8) Utf8Error!u21 {
    if (utf8_bytes.len == 0) {
        return error.InvalidUtf8;
    }

    // 使用 Zig 标准库的 utf8Decode
    const codepoint = utf8.utf8Decode(utf8_bytes) catch |err| {
        switch (err) {
            error.Utf8InvalidStartByte => return error.InvalidUtf8,
            error.Utf8InvalidContinuationByte => return error.InvalidUtf8,
            error.Utf8OverlongEncoding => return error.OverlongEncoding,
            error.Utf8ExpectedContinuationByte => return error.InvalidUtf8,
            error.Utf8CodepointTooLarge => return error.InvalidCodepoint,
            error.Utf8EncodesSurrogateHalf => return error.InvalidCodepoint,
        }
    };

    return codepoint;
}

/// 将 Unicode 码点编码为 UTF-8 字节序列
pub fn encode(codepoint: u21, buffer: []u8) Utf8Error!usize {
    // 检查码点有效性
    if (!std.unicode.isValidCodepoint(codepoint)) {
        return error.InvalidCodepoint;
    }

    // 使用 Zig 标准库的 utf8Encode
    const len = utf8.utf8Encode(codepoint, buffer) catch |err| {
        switch (err) {
            error.CodepointTooLarge => return error.InvalidCodepoint,
            error.Utf8CannotEncodeSurrogateHalf => return error.InvalidCodepoint,
        }
    };

    return len;
}

/// 计算字符显示宽度（列数）
/// 返回 0（不可见）、1（半角）、2（全角）
pub fn runeWidth(codepoint: u21) u8 {
    // 检查控制字符和不可见字符
    if (codepoint < 32 or (codepoint >= 0x7f and codepoint < 0xa0)) {
        return 0;
    }

    // 使用 Zig 标准库的 unicode 宽度计算
    return @truncate(utf8.utf16LeToUtf8Len(&[2]u16{
        @as(u16, codepoint),
        @as(u16, codepoint >> 16),
    }));
}

/// 获取 UTF-8 字符的字节长度
pub fn utf8ByteLength(byte: u8) u8 {
    // UTF-8 首字节指示后续字节数
    if (byte & 0x80 == 0) {
        return 1; // 0xxxxxxx
    } else if (byte & 0xE0 == 0xC0) {
        return 2; // 110xxxxx
    } else if (byte & 0xF0 == 0xE0) {
        return 3; // 1110xxxx
    } else if (byte & 0xF8 == 0xF0) {
        return 4; // 11110xxx
    } else {
        return 0; // 无效的首字节
    }
}

/// 检查是否是 C0 控制字符 (0x00-0x1F, 0x7F)
pub fn isControlC0(c: u21) bool {
    return (c < 0x20 or c == 0x7F);
}

/// 检查是否是 C1 控制字符 (0x80-0x9F)
pub fn isControlC1(c: u21) bool {
    return (c >= 0x80 and c <= 0x9F);
}

/// 检查是否是控制字符
pub fn isControl(c: u21) bool {
    return isControlC0(c) or isControlC1(c);
}

/// UTF-8 无效替换字符
pub const REPLACEMENT_CHARACTER: u21 = 0xFFFD;
