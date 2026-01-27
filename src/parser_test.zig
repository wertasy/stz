//! Parser 模块单元测试

const std = @import("std");
const libc = @cImport({
    @cInclude("locale.h");
});
const Terminal = @import("terminal.zig").Terminal;
const Parser = @import("parser.zig").Parser;
const types = @import("types.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "Parser initialization" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();

    var parser = try Parser.init(&term, null, allocator);
    defer parser.deinit();

    try expect(parser.term == &term);
}

test "SGR reset sequence" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();
    var parser = try Parser.init(&term, null, allocator);
    defer parser.deinit();

    // Set some attributes
    term.c.attr.attr.bold = true;
    term.c.attr.attr.underline = true;
    term.c.attr.fg = 3; // Yellow

    // Send reset sequence
    const sequence = "\x1B[0m";
    for (sequence) |c| try parser.putc(@intCast(c));

    // Check attributes are reset
    try expect(!term.c.attr.attr.bold);
    try expect(!term.c.attr.attr.underline);
    // 258 是 config.zig 中的默认前景色
    try expectEqual(@as(u32, 258), term.c.attr.fg);
}

test "CSI colon arguments" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();
    var parser = try Parser.init(&term, null, allocator);
    defer parser.deinit();

    // 测试 38:5:123 (使用冒号的 256 色前景色)
    const seq1 = "\x1b[38:5:123m";
    for (seq1) |c| try parser.putc(@intCast(c));
    try expectEqual(@as(u32, 123), term.c.attr.fg);

    // 测试 48:2:255:128:64 (使用冒号的真彩色背景色)
    const seq2 = "\x1b[48:2:255:128:64m";
    for (seq2) |c| try parser.putc(@intCast(c));
    const expected_bg = (0xFF << 24) | (@as(u32, 255) << 16) | (@as(u32, 128) << 8) | 64;
    try expectEqual(expected_bg, term.c.attr.bg);
}

test "SGR 4 and 58 underline style and color" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();
    var parser = try Parser.init(&term, null, allocator);
    defer parser.deinit();

    // Test 4:3 (Curly Underline)
    const seq_curly = "\x1b[4:3m";
    for (seq_curly) |c| try parser.putc(@intCast(c));
    try expect(term.c.attr.attr.underline);
    try expectEqual(@as(i32, 3), term.c.attr.ustyle);

    // Test 58:5:1 (Set Underline Color to Red/Index 1)
    // Index 1 (Red) in normal colors is usually 0xFF0000 (RGB) or similar
    // Just check if it sets valid RGB in ucolor
    const seq_ucolor = "\x1b[58:5:1m";
    for (seq_ucolor) |c| try parser.putc(@intCast(c));

    // Check that ucolor is set (not default -1)
    try expect(term.c.attr.ucolor[0] != -1);

    // Test 59 (Reset Underline Color)
    const seq_reset_ucolor = "\x1b[59m";
    for (seq_reset_ucolor) |c| try parser.putc(@intCast(c));
    try expectEqual(@as(i32, -1), term.c.attr.ucolor[0]);
    try expectEqual(@as(i32, -1), term.c.attr.ucolor[1]);
    try expectEqual(@as(i32, -1), term.c.attr.ucolor[2]);
}

test "Wide character wrapping" {
    // 设置 locale 以确保 wcwidth 正确返回宽字符宽度
    _ = libc.setlocale(libc.LC_CTYPE, "C.UTF-8");

    const allocator = std.testing.allocator;
    var term = try Terminal.init(2, 10, allocator); // 10 columns
    defer term.deinit();
    var parser = try Parser.init(&term, null, allocator);
    defer parser.deinit();

    // 移动到第 10 列 (x=9)
    try parser.putc('\x1b');
    try parser.putc('[');
    try parser.putc('1');
    try parser.putc('0');
    try parser.putc('G');

    // 写入一个宽字符 (宽度 2)
    const wide_char: u21 = 0x6d4b;
    try parser.putc(wide_char);

    // 更新：移除了"智能挤压" hack，恢复标准 wrapping 行为 (st 兼容)
    // 如果宽字符在行尾溢出，应该换行。
    // 所以光标应该移动到下一行 (y=1)，x=0 开始写入，写完后 x=2。
    try expectEqual(@as(usize, 1), term.c.y);
    try expectEqual(@as(usize, 2), term.c.x);
    try expect(!term.c.state.wrap_next);
    // 字符应该被写入到下一行开头
    try expectEqual(wide_char, term.line.?[1][0].u);
    // 且应该是 wide
    try expect(term.line.?[1][0].attr.wide);
}

test "LF behavior (LNM)" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();
    var parser = try Parser.init(&term, null, allocator);
    defer parser.deinit();

    // 1. 默认 LNM 关闭
    term.mode.crlf = false;
    term.c.x = 5;
    term.c.y = 5;

    // 发送 LF -> 光标应该在 (5, 6)
    try parser.putc('\x0A');
    try expectEqual(@as(usize, 6), term.c.y);
    try expectEqual(@as(usize, 5), term.c.x);

    // 2. 开启 LNM
    term.mode.crlf = true;
    term.c.x = 5;
    term.c.y = 5;

    // 发送 LF -> 光标应该在 (0, 6)
    try parser.putc('\x0A');

    try expectEqual(@as(usize, 6), term.c.y);
    try expectEqual(@as(usize, 0), term.c.x);
}

test "Parser setScrollRegion" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();

    var p = try Parser.init(&term, null, allocator);
    defer p.deinit();

    // 1. Test default setScrollRegion (ESC [ r) -> Full screen
    const seq1 = "\x1B[r";
    for (seq1) |c| try p.putc(@intCast(c));
    try expectEqual(@as(usize, 0), term.top);
    try expectEqual(@as(usize, 23), term.bot);

    // 2. Test specific region (ESC [ 2 ; 10 r) -> Rows 1 to 9 (0-indexed)
    const seq2 = "\x1B[2;10r";
    for (seq2) |c| try p.putc(@intCast(c));
    try expectEqual(@as(usize, 1), term.top);
    try expectEqual(@as(usize, 9), term.bot);

    // 3. Test clamping (ESC [ 1 ; 100 r) -> Rows 0 to 23
    const seq3 = "\x1B[1;100r";
    for (seq3) |c| try p.putc(@intCast(c));
    try expectEqual(@as(usize, 0), term.top);
    try expectEqual(@as(usize, 23), term.bot);
}

test "Private CSI handling" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();
    var parser = try Parser.init(&term, null, allocator);
    defer parser.deinit();

    // SGR 4 sets underline
    const seq_sgr = "\x1b[4m";
    for (seq_sgr) |c| try parser.putc(@intCast(c));
    try expect(term.c.attr.attr.underline);

    // Reset
    term.c.attr.attr.underline = false;

    // CSI > 4 m should NOT set underline (XTMODKEYS)
    const seq_priv = "\x1b[>4m";
    for (seq_priv) |c| try parser.putc(@intCast(c));
    try expect(!term.c.attr.attr.underline);
}

test "SGR empty arguments (Reset)" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();
    var parser = try Parser.init(&term, null, allocator);
    defer parser.deinit();

    // Set underline
    term.c.attr.attr.underline = true;

    // SGR m (no args) should equivalent to SGR 0 -> Reset
    const seq = "\x1b[m";
    for (seq) |c| try parser.putc(@intCast(c));

    // Should be reset
    try expect(!term.c.attr.attr.underline);
}
