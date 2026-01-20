//! Parser 模块单元测试

const std = @import("std");
const Terminal = @import("terminal.zig").Terminal;
const types = @import("types.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "Parser initialization" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();

    // 修复 Parser 中的 Term 指针
    term.parser.term = &term.term;

    try expect(term.parser.term == &term.term);
}

test "SGR reset sequence" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();
    term.parser.term = &term.term;

    // Set some attributes
    term.term.c.attr.attr.bold = true;
    term.term.c.attr.attr.underline = true;
    term.term.c.attr.fg = 3; // Yellow

    // Send reset sequence
    const sequence = "\x1B[0m";
    for (sequence) |c| try term.parser.putc(@intCast(c));

    // Check attributes are reset
    try expect(!term.term.c.attr.attr.bold);
    try expect(!term.term.c.attr.attr.underline);
    // 258 是 config.zig 中的默认前景色
    try expectEqual(@as(u32, 258), term.term.c.attr.fg);
}

test "CSI colon arguments" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();
    term.parser.term = &term.term;

    var parser = &term.parser;

    // 测试 38:5:123 (使用冒号的 256 色前景色)
    const seq1 = "\x1b[38:5:123m";
    for (seq1) |c| try parser.putc(@intCast(c));
    try expectEqual(@as(u32, 123), term.term.c.attr.fg);

    // 测试 48:2:255:128:64 (使用冒号的真彩色背景色)
    const seq2 = "\x1b[48:2:255:128:64m";
    for (seq2) |c| try parser.putc(@intCast(c));
    const expected_bg = (0xFF << 24) | (@as(u32, 255) << 16) | (@as(u32, 128) << 8) | 64;
    try expectEqual(expected_bg, term.term.c.attr.bg);
}

test "Wide character wrapping" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(2, 10, allocator); // 10 columns
    defer term.deinit();
    term.parser.term = &term.term;

    var parser = &term.parser;

    // 移动到第 10 列 (x=9)
    try parser.putc('\x1b');
    try parser.putc('[');
    try parser.putc('1');
    try parser.putc('0');
    try parser.putc('G');

    // 写入一个宽字符 (宽度 2)
    const wide_char: u21 = 0x6d4b;
    try parser.putc(wide_char);

    // 此时应该触发换行，因为 9+2 > 10
    try expectEqual(@as(usize, 1), term.term.c.y);
    try expectEqual(@as(usize, 2), term.term.c.x);
    try expectEqual(wide_char, term.term.line.?[1][0].u);
    try expect(term.term.line.?[1][1].attr.wide_dummy);
}
