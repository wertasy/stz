//! Parser 模块单元测试

const std = @import("std");
const Parser = @import("parser.zig").Parser;
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "Parser initialization" {
    const allocator = std.testing.allocator;
    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    var parser = Parser.init(&term);
    try expect(parser.esc == .{});
}

test "SGR reset sequence" {
    const allocator = std.testing.allocator;
    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    var parser = Parser.init(&term);
    parser.term = &term;

    // Set some attributes
    term.c.attr.attr.bold = true;
    term.c.attr.attr.underline = true;
    term.c.attr.fg = 3; // Yellow

    // Send reset sequence
    const sequence = "\x1B[0m";
    for (sequence) |c| {
        parser.processChar(c);
    }

    // Check attributes are reset
    try expect(!term.c.attr.attr.bold);
    try expect(!term.c.attr.attr.underline);
    try expectEqual(@as(u32, 7), term.c.attr.fg); // Default white
}

test "SGR color setting (16-color)" {
    const allocator = std.testing.allocator;
    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    var parser = Parser.init(&term);
    parser.term = &term;

    // Set foreground to red (31)
    const sequence = "\x1B[31m";
    for (sequence) |c| {
        parser.processChar(c);
    }

    try expectEqual(@as(u32, 1), term.c.attr.fg);
}

test "SGR bold attribute" {
    const allocator = std.testing.allocator;
    defer allocator.deinit();

    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    var parser = Parser.init(&term);
    parser.term = &term;

    // Set bold
    const sequence = "\x1B[1m";
    for (sequence) |c| {
        parser.processChar(c);
    }

    try expect(term.c.attr.attr.bold);
}

test "Cursor movement - forward" {
    const allocator = std.testing.allocator;
    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    var parser = Parser.init(&term);
    parser.term = &term;

    // Initial position
    try expectEqual(@as(usize, 0), term.c.x);

    // Move cursor forward by 5
    const sequence = "\x1B[5C";
    for (sequence) |c| {
        parser.processChar(c);
    }

    try expectEqual(@as(usize, 5), term.c.x);
}

test "Cursor movement - up" {
    const allocator = std.testing.allocator;
    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    var parser = Parser.init(&term);
    parser.term = &term;

    // Set initial position
    term.c.x = 10;
    term.c.y = 10;

    // Move cursor up by 3
    const sequence = "\x1B[3A";
    for (sequence) |c| {
        parser.processChar(c);
    }

    try expectEqual(@as(usize, 10), term.c.x);
    try expectEqual(@as(usize, 7), term.c.y);
}

test "Clear screen" {
    const allocator = std.testing.allocator;
    var term = try types.Term.init(24, 80, allocator);
    defer term.deinit();

    var parser = Parser.init(&term);
    parser.term = &term;

    // Write some characters
    term.line = try allocator.alloc([]types.Glyph, 24);
    for (0..24) |y| {
        term.line[y] = try allocator.alloc(types.Glyph, 80);
        for (0..80) |x| {
            term.line[y][x].u = @intCast('A' + x % 26);
        }
    }

    // Clear screen
    const sequence = "\x1B[2J";
    for (sequence) |c| {
        parser.processChar(c);
    }

    // Check screen is cleared (spaces)
    try expectEqual(@as(u21, ' '), term.line[0][0].u);
}
