const std = @import("std");
const testing = std.testing;

const Terminal = @import("../src/terminal.zig").Terminal;
const Parser = @import("../src/parser.zig").Parser;

test "窗口标题内存管理" {
    // 使用 GPA 检查内存泄漏
    const gpa = std.testing.allocator;

    // 初始化终端
    var terminal = try Terminal.init(24, 80, gpa);
    defer terminal.deinit();

    // 初始标题应该是 "stz"
    try testing.expectEqualSlices(u8, "stz", terminal.window_title);

    // 创建解析器
    var parser = try Parser.init(&terminal, gpa);
    defer parser.deinit();

    // 模拟 OSC 2;测试标题 BEL
    const seq1 = "\x1B]2;测试标题\x07";
    try parser.processBytes(seq1[0..]);

    // 标题应该已更新
    try testing.expectEqualSlices(u8, "测试标题", terminal.window_title);
    try testing.expect(terminal.window_title_dirty);

    // 标记脏位已处理
    terminal.window_title_dirty = false;

    // 模拟 OSC 2; (空字符串，重置标题)
    const seq2 = "\x1B]2;\x07";
    try parser.processBytes(seq2[0..]);

    // 标题应该已重置为 "stz"
    try testing.expectEqualSlices(u8, "stz", terminal.window_title);
    try testing.expect(terminal.window_title_dirty);

    // 多次设置不同标题，确保没有内存泄漏
    for (0..100) |i| {
        const seq = std.fmt.allocPrint(gpa, "\x1B]2;标题{d}\x07", .{i}) catch unreachable;
        defer gpa.free(seq);
        try parser.processBytes(seq[0..]);
        terminal.window_title_dirty = false;
    }

    // 最终标题应该是 "标题99"
    try testing.expectEqualSlices(u8, "标题99", terminal.window_title);

    // 测试完成后，GPA 会自动检查内存泄漏
}

test "OSC 0 和 OSC 1 也应该正确设置标题" {
    const gpa = std.testing.allocator;

    var terminal = try Terminal.init(24, 80, gpa);
    defer terminal.deinit();

    var parser = try Parser.init(&terminal, gpa);
    defer parser.deinit();

    // 测试 OSC 0 (窗口标题和图标标题)
    try parser.processBytes("\x1B]0;OSC 0 标题\x07");
    try testing.expectEqualSlices(u8, "OSC 0 标题", terminal.window_title);

    // 测试 OSC 1 (图标标题)
    try parser.processBytes("\x1B]1;OSC 1 标题\x07");
    try testing.expectEqualSlices(u8, "OSC 1 标题", terminal.window_title);

    // 测试 OSC 2 (窗口标题)
    try parser.processBytes("\x1B]2;OSC 2 标题\x07");
    try testing.expectEqualSlices(u8, "OSC 2 标题", terminal.window_title);
}
