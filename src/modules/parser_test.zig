//! Parser 模块单元测试

const std = @import("std");
const libc = @cImport({
    @cInclude("locale.h");
});
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

test "SGR 4 and 58 underline style and color" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();
    term.parser.term = &term.term;

    var parser = &term.parser;

    // Test 4:3 (Curly Underline)
    const seq_curly = "\x1b[4:3m";
    for (seq_curly) |c| try parser.putc(@intCast(c));
    try expect(term.term.c.attr.attr.underline);
    try expectEqual(@as(i32, 3), term.term.c.attr.ustyle);

    // Test 58:5:1 (Set Underline Color to Red/Index 1)
    // Index 1 (Red) in normal colors is usually 0xFF0000 (RGB) or similar
    // Just check if it sets valid RGB in ucolor
    const seq_ucolor = "\x1b[58:5:1m";
    for (seq_ucolor) |c| try parser.putc(@intCast(c));

    // Check that ucolor is set (not default -1)
    try expect(term.term.c.attr.ucolor[0] != -1);

    // Test 59 (Reset Underline Color)
    const seq_reset_ucolor = "\x1b[59m";
    for (seq_reset_ucolor) |c| try parser.putc(@intCast(c));
    try expectEqual(@as(i32, -1), term.term.c.attr.ucolor[0]);
    try expectEqual(@as(i32, -1), term.term.c.attr.ucolor[1]);
    try expectEqual(@as(i32, -1), term.term.c.attr.ucolor[2]);
}

test "Wide character wrapping" {
    // 设置 locale 以确保 wcwidth 正确返回宽字符宽度
    _ = libc.setlocale(libc.LC_CTYPE, "C.UTF-8");

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

    // 更新：为了兼容 Vim 等应用在行尾可能的宽度误判，我们实施了“智能挤压”策略
    // 如果宽字符在行尾溢出，我们强制将其视为单宽而不换行，以防止意外滚动。
    // 所以光标应该停留在行尾 (x=9)，且行号不变 (y=0)。
    try expectEqual(@as(usize, 0), term.term.c.y);
    // x 保持在 9 (因为 x+1 == col)，wrap_next=true
    try expectEqual(@as(usize, 9), term.term.c.x);
    try expect(term.term.c.state.wrap_next);
    // 字符应该被写入到最后一个格子
    try expectEqual(wide_char, term.term.line.?[0][9].u);
    // 且不应该有 wide_dummy (因为被强行当单宽写了)
    try expect(!term.term.line.?[0][9].attr.wide);
}

test "LF behavior (LNM)" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();
    term.parser.term = &term.term;

    // 1. 默认 LNM 关闭
    term.term.mode.crlf = false;
    term.term.c.x = 5;
    term.term.c.y = 5;

    // 发送 LF -> 光标应该在 (5, 6)
    try term.parser.putc('\x0A');
    try expectEqual(@as(usize, 6), term.term.c.y);
    try expectEqual(@as(usize, 5), term.term.c.x);

    // 2. 开启 LNM
    term.term.mode.crlf = true;
    term.term.c.x = 5;
    term.term.c.y = 5;

    // 发送 LF -> 光标应该在 (0, 6)
    try term.parser.putc('\x0A');
    try expectEqual(@as(usize, 6), term.term.c.y);
    try expectEqual(@as(usize, 0), term.term.c.x);
}
