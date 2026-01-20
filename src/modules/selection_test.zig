//! Selection 模块单元测试

const std = @import("std");
const types = @import("types.zig");
const selection = @import("selection.zig");
const Terminal = @import("terminal.zig").Terminal;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "Selection word snap" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(1, 20, allocator);
    defer term.deinit();
    term.parser.term = &term.term;

    // 准备数据: "hello world test"
    const text = "hello world test";
    for (text, 0..) |c, i| {
        term.term.line.?[0][i].u = @intCast(c);
    }

    var selector = selection.Selector.init(allocator);
    defer selector.deinit();

    // 在 "hello" 中间点击 (x=2)
    selector.start(2, 0, .word);
    selector.extend(&term.term, 2, 0, .regular, true);

    // 应该选中 "hello" (0-4)
    try expectEqual(@as(usize, 0), selector.selection.nb.x);
    try expectEqual(@as(usize, 4), selector.selection.ne.x);

    // 在空格点击 (x=5)
    selector.clear();
    selector.start(5, 0, .word);
    selector.extend(&term.term, 5, 0, .regular, true);

    // 应该选中空格本身 (5-5)
    try expectEqual(@as(usize, 5), selector.selection.nb.x);
    try expectEqual(@as(usize, 5), selector.selection.ne.x);
}

test "Selection line snap" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(1, 20, allocator);
    defer term.deinit();

    var selector = selection.Selector.init(allocator);
    defer selector.deinit();

    // 在中间点击并启用行吸附
    selector.start(10, 0, .line);
    selector.extend(&term.term, 10, 0, .regular, true);

    // 应该选中整行 (0-19)
    try expectEqual(@as(usize, 0), selector.selection.nb.x);
    try expectEqual(@as(usize, 19), selector.selection.ne.x);
}
