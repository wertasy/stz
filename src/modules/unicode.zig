//! UTF-8 编解码模块
//! 使用 Zig 标准库的 std.unicode

const std = @import("std");
const utf8 = std.unicode;
const libc = @cImport({
    @cDefine("_XOPEN_SOURCE", "700");
    @cInclude("wchar.h");
});

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

    // 检查字节长度是否足够
    const needed_len = utf8ByteLength(utf8_bytes[0]);
    if (needed_len == 0 or needed_len > utf8_bytes.len) {
        return error.InvalidUtf8;
    }

    // 手动解码以避免标准库的断言问题
    return utf8DecodeManual(utf8_bytes[0..needed_len]);
}

/// 手动 UTF-8 解码实现
fn utf8DecodeManual(utf8_bytes: []const u8) Utf8Error!u21 {
    const len = utf8_bytes.len;
    const b0 = utf8_bytes[0];

    if (len == 1) {
        // 0xxxxxxx
        return b0;
    } else if (len == 2) {
        // 110xxxxx 10xxxxxx
        if (b0 & 0xE0 != 0xC0) return error.InvalidUtf8;
        const b1 = utf8_bytes[1];
        if (b1 & 0xC0 != 0x80) return error.InvalidUtf8;
        const codepoint = (@as(u21, b0 & 0x1F) << 6) | @as(u21, b1 & 0x3F);
        // 检查过短编码
        if (codepoint < 0x80) return error.OverlongEncoding;
        return codepoint;
    } else if (len == 3) {
        // 1110xxxx 10xxxxxx 10xxxxxx
        if (b0 & 0xF0 != 0xE0) return error.InvalidUtf8;
        const b1 = utf8_bytes[1];
        const b2 = utf8_bytes[2];
        if (b1 & 0xC0 != 0x80) return error.InvalidUtf8;
        if (b2 & 0xC0 != 0x80) return error.InvalidUtf8;
        const codepoint = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | @as(u21, b2 & 0x3F);
        // 检查过短编码
        if (codepoint < 0x800) return error.OverlongEncoding;
        // 检查代理区
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return error.InvalidCodepoint;
        return codepoint;
    } else if (len == 4) {
        // 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        if (b0 & 0xF8 != 0xF0) return error.InvalidUtf8;
        const b1 = utf8_bytes[1];
        const b2 = utf8_bytes[2];
        const b3 = utf8_bytes[3];
        if (b1 & 0xC0 != 0x80) return error.InvalidUtf8;
        if (b2 & 0xC0 != 0x80) return error.InvalidUtf8;
        if (b3 & 0xC0 != 0x80) return error.InvalidUtf8;
        const codepoint = (@as(u21, b0 & 0x07) << 18) | (@as(u21, b1 & 0x3F) << 12) | (@as(u21, b2 & 0x3F) << 6) | @as(u21, b3 & 0x3F);
        // 检查过短编码
        if (codepoint < 0x10000) return error.OverlongEncoding;
        // 检查超出 Unicode 范围
        if (codepoint > 0x10FFFF) return error.InvalidCodepoint;
        return codepoint;
    } else {
        return error.InvalidUtf8;
    }
}

/// 将 Unicode 码点编码为 UTF-8 字节序列
pub fn encode(codepoint: u21, buffer: []u8) Utf8Error!usize {
    // 使用 Zig 标准库的 utf8Encode
    return utf8.utf8Encode(codepoint, buffer) catch error.InvalidCodepoint;
}

/// 计算字符显示宽度（列数）
/// 使用系统 libc 的 wcwidth
pub fn runeWidth(codepoint: u21) u8 {
    // 检查控制字符和不可见字符
    if (codepoint < 32 or (codepoint >= 0x7f and codepoint < 0xa0)) {
        return 0;
    }

    // 使用 libc wcwidth
    const width = libc.wcwidth(@intCast(codepoint));
    if (width < 0) return 0;
    return @intCast(width);
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
