//! Screen 模块单元测试

const std = @import("std");
const screen = @import("screen.zig");
const types = @import("types.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "Screen initialization" {
    const allocator = std.testing.allocator;
    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    try expect(term.row == 24);
    try expect(term.col == 80);
    try expect(term.line != null);
    try expect(term.dirty != null);
}

test "Screen dirty flag" {
    const allocator = std.testing.allocator;
    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    // Mark a row as dirty
    screen.setDirty(&term, 5);

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
    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    // Mark all rows as dirty
    screen.setFullDirty(&term);

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
    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    // Mark all rows as dirty
    screen.setFullDirty(&term);

    // Clear dirty flags
    screen.clearDirty(&term);

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
    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    // Set scroll region
    term.top = 5;
    term.bot = 15;

    // Write some content to verify scrolling
    if (term.line) |line| {
        for (0..5) |y| {
            line[y][0].u = @intCast('A' + y);
        }
    }

    // Scroll up by 1
    screen.scrollUp(&term, 1);

    if (term.line) |line| {
        // Row 6 should now contain what was in row 5
        try expectEqual(@as(u21, 'E'), line[6][0].u);
    }
}
