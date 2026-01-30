//! Terminal 模块单元测试

const std = @import("std");
const stz = @import("stz");
const types = stz.types;
const terminal = stz.Terminal;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "Screen initialization" {
    const allocator = std.testing.allocator;
    const term = terminal.init(24, 80, allocator);
    defer terminal.deinit();

    try expect(term.row == 24);
    try expect(term.col == 80);
    try expect(term.screen != null);
    try expect(term.dirty != null);
}

test "Screen dirty flag" {
    const allocator = std.testing.allocator;
    const term = terminal.init(24, 80, allocator);
    defer terminal.deinit();

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
    const term = terminal.init(24, 80, allocator);
    defer terminal.deinit();

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
    const term = terminal.init(24, 80, allocator);
    defer terminal.deinit();

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
    const term = terminal.init(24, 80, allocator);
    defer terminal.deinit();

    // Set scroll region
    term.top = 5;
    term.bot = 15;

    // Write some content to verify scrolling
    if (term.screen) |line| {
        for (0..5) |y| {
            line[y][0].u = @intCast('A' + y);
        }
    }

    // Scroll up by 1
    try term.scrollUp(1, 1);

    if (term.screen) |line| {
        // Row 6 should now contain what was in row 5
        try expectEqual(@as(u21, 'E'), line[6][0].u);
    }
}
