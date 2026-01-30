//! Terminal 模块单元测试

const std = @import("std");
const stz = @import("stz");
const types = stz.types;
const terminal = stz.Terminal;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "Screen initialization" {
    const allocator = std.testing.allocator;
    var term = try terminal.init(24, 80, allocator);
    defer term.deinit();

    try expect(term.row == 24);
    try expect(term.col == 80);
    try expect(term.screen != null);
    try expect(term.dirty != null);
}

test "Screen dirty flag" {
    const allocator = std.testing.allocator;
    var term = try terminal.init(24, 80, allocator);
    defer term.deinit();

    // Clear dirty flags from init
    term.setFullDirty();
    if (term.dirty) |dirty| {
        for (dirty) |*d| d.* = false;
    }

    // Mark a row as dirty
    term.setDirty(5, 5);

    if (term.dirty) |dirty| {
        try expect(dirty[5]);
        try expect(!dirty[0]);
        try expect(!dirty[10]);
    } else {
        try expect(false); // Should not reach here
    }
}

test "Screen full dirty" {
    const allocator = std.testing.allocator;
    var term = try terminal.init(24, 80, allocator);
    defer term.deinit();

    // Mark all rows as dirty
    term.setFullDirty();

    if (term.dirty) |dirty| {
        for (dirty) |is_dirty| {
            try expect(is_dirty);
        }
    } else {
        try expect(false); // Should not reach here
    }
}

test "Clear dirty flags" {
    const allocator = std.testing.allocator;
    var term = try terminal.init(24, 80, allocator);
    defer term.deinit();

    // Mark all rows as dirty
    term.setFullDirty();

    // Manually clear dirty flags
    if (term.dirty) |dirty| {
        for (dirty) |*d| {
            d.* = false;
        }
    }

    if (term.dirty) |dirty| {
        for (dirty) |is_dirty| {
            try expect(!is_dirty);
        }
    } else {
        try expect(false); // Should not reach here
    }
}

test "Screen scroll" {
    const allocator = std.testing.allocator;
    var term = try terminal.init(24, 80, allocator);
    defer term.deinit();

    // Set scroll region [5, 15]
    term.top = 5;
    term.bot = 15;

    // Write some content to the scroll region (lines 5-9)
    if (term.screen) |line| {
        for (0..5) |i| {
            line[term.top + i][0].codepoint = @intCast('A' + i);
        }
        // Row 5: A
        // Row 6: B
        // Row 7: C
        // ...
    }

    // Scroll up by 1 (move content UP)
    // Row 5 should get Row 6 content ('B')
    try term.scrollUp(term.top, 1);

    if (term.screen) |line| {
        // Row 5 should now contain what was in row 6 ('B')
        try expectEqual(@as(u21, 'B'), line[5][0].codepoint);
        // Row 6 should contain 'C'
        try expectEqual(@as(u21, 'C'), line[6][0].codepoint);
    }
}
