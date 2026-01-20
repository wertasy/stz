//! 屏幕缓冲区管理
//! 负责管理终端屏幕的行、字符、滚动、脏标记等

const std = @import("std");
const types = @import("types.zig");

const Glyph = types.Glyph;
const Term = types.Term;
const GlyphAttr = types.GlyphAttr;
const TCursor = types.TCursor;
const Selection = types.Selection;

pub const ScreenError = error{
    InvalidPosition,
    OutOfBounds,
};

/// 初始化终端屏幕
pub fn init(term: *Term, row: usize, col: usize, allocator: std.mem.Allocator) !void {
    term.row = row;
    term.col = col;
    term.allocator = allocator;

    // 分配主屏幕
    term.line = try allocator.alloc([]Glyph, row);
    errdefer allocator.free(term.line);

    // 分配备用屏幕
    term.alt = try allocator.alloc([]Glyph, row);
    errdefer allocator.free(term.alt);

    // 分配脏标记
    term.dirty = try allocator.alloc(bool, row);
    errdefer allocator.free(term.dirty);

    // 分配制表符
    term.tabs = try allocator.alloc(bool, col);
    errdefer allocator.free(term.tabs);

    // 初始化每一行
    for (0..row) |y| {
        term.line.?[y] = try allocator.alloc(Glyph, col);
        term.alt.?[y] = try allocator.alloc(Glyph, col);
        term.dirty.?[y] = true;

        // 初始化为空格字符
        for (0..col) |x| {
            term.line.?[y][x] = Glyph{};
            term.alt.?[y][x] = Glyph{};
        }
    }

    // 初始化制表符
    for (term.tabs.?) |*tab| {
        tab.* = false;
    }

    // 设置默认制表符间隔（每8列一个）
    for (0..col) |x| {
        if (x % 8 == 0) {
            term.tabs.?[x] = true;
        }
    }

    // 初始化光标
    term.c = TCursor{};
}

/// 清理终端屏幕资源
pub fn deinit(term: *Term) void {
    const allocator = term.allocator;

    if (term.line) |lines| {
        for (lines) |line| {
            allocator.free(line);
        }
        allocator.free(lines);
    }

    if (term.alt) |lines| {
        for (lines) |line| {
            allocator.free(line);
        }
        allocator.free(lines);
    }

    if (term.dirty) |d| {
        allocator.free(d);
    }

    if (term.tabs) |t| {
        allocator.free(t);
    }

    term.line = null;
    term.alt = null;
    term.dirty = null;
    term.tabs = null;
}

/// 调整终端大小
pub fn resize(term: *Term, new_row: usize, new_col: usize) !void {
    const allocator = term.allocator;

    // 调整主屏幕
    if (term.line) |lines| {
        for (lines) |line| {
            allocator.free(line);
        }
        allocator.free(lines);
    }

    // 调配备用屏幕
    if (term.alt) |lines| {
        for (lines) |line| {
            allocator.free(line);
        }
        allocator.free(lines);
    }

    // 分配新大小的行
    term.line = try allocator.alloc([]Glyph, new_row);
    term.alt = try allocator.alloc([]Glyph, new_row);

    // 分配每一行的字符
    for (0..new_row) |y| {
        term.line.?[y] = try allocator.alloc(Glyph, new_col);
        term.alt.?[y] = try allocator.alloc(Glyph, new_col);

        // 初始化为空格
        for (0..new_col) |x| {
            const default_glyph = Glyph{};
            if (y < term.row and x < term.col) {
                // 保留原有内容
                term.line.?[y][x] = default_glyph;
                term.alt.?[y][x] = default_glyph;
            } else {
                term.line.?[y][x] = default_glyph;
                term.alt.?[y][x] = default_glyph;
            }
        }
    }

    // 调整脏标记
    if (term.dirty) |d| {
        allocator.free(d);
    }
    term.dirty = try allocator.alloc(bool, new_row);
    for (term.dirty.?) |*dirty| {
        dirty.* = true;
    }

    // 调整制表符
    if (term.tabs) |t| {
        allocator.free(t);
    }
    term.tabs = try allocator.alloc(bool, new_col);
    for (term.tabs.?) |*tab| {
        tab.* = false;
    }
    // 设置默认制表符
    for (0..new_col) |x| {
        if (x % 8 == 0) {
            term.tabs.?[x] = true;
        }
    }

    term.row = new_row;
    term.col = new_col;
}

/// 清除区域
pub fn clearRegion(term: *Term, x1: usize, y1: usize, x2: usize, y2: usize) !void {
    const gx1 = @min(x1, x2);
    const gx2 = @max(x1, x2);
    const gy1 = @min(y1, y2);
    const gy2 = @max(y1, y2);

    // 限制在屏幕范围内
    const sx1 = @min(gx1, term.col - 1);
    const sx2 = @min(gx2, term.col - 1);
    const sy1 = @min(gy1, term.row - 1);
    const sy2 = @min(gy2, term.row - 1);

    const screen = if (term.mode.alt_screen) term.alt else term.line;

    for (sy1..sy2 + 1) |y| {
        if (term.dirty) |dirty| {
            dirty[y] = true;
        }
        for (sx1..sx2 + 1) |x| {
            if (screen) |scr| {
                scr[y][x] = .{
                    .u = ' ',
                    .fg = term.c.attr.fg,
                    .bg = term.c.attr.bg,
                    .attr = .{},
                };
            }
        }
    }
}

/// 屏幕向上滚动
pub fn scrollUp(term: *Term, orig: usize, n: usize) !void {
    const limit_n = @min(n, term.bot - orig + 1);
    const screen = if (term.mode.alt_screen) term.alt else term.line;

    // 移动行
    var i: usize = orig;
    while (i + limit_n <= term.bot) : (i += 1) {
        const temp = screen.?[i];
        screen.?[i] = screen.?[i + limit_n];
        screen.?[i + limit_n] = temp;
        i += 1;
    }

    // 清除底部行
    for (0..limit_n) |_| {
        const idx = term.bot - limit_n + 1;
        if (term.dirty) |dirty| {
            dirty[idx] = true;
        }
        if (screen) |scr| {
            for (scr[idx]) |*glyph| {
                glyph.* = .{
                    .u = ' ',
                    .fg = term.c.attr.fg,
                    .bg = term.c.attr.bg,
                    .attr = .{},
                };
            }
        }
    }
}

/// 屏幕向下滚动
pub fn scrollDown(term: *Term, orig: usize, n: usize) !void {
    const limit_n = @min(n, term.bot - orig + 1);
    const screen = if (term.mode.alt_screen) term.alt else term.line;

    // 移动行
    var i: usize = term.bot;
    while (i >= orig + limit_n) : (i -= 1) {
        const temp = screen.?[i];
        screen.?[i] = screen.?[i - limit_n];
        screen.?[i - limit_n] = temp;
        i -= 1;
    }

    // 清除顶部行
    for (0..limit_n) |_| {
        if (term.dirty) |dirty| {
            dirty[orig] = true;
        }
        if (screen) |scr| {
            for (scr[orig]) |*glyph| {
                glyph.* = .{
                    .u = ' ',
                    .fg = term.c.attr.fg,
                    .bg = term.c.attr.bg,
                    .attr = .{},
                };
            }
        }
    }
}

/// 设置所有行为脏
pub fn setFullDirty(term: *Term) void {
    if (term.dirty) |dirty| {
        for (dirty) |*d| {
            d.* = true;
        }
    }
}

/// 设置行为脏
pub fn setDirty(term: *Term, top: usize, bot: usize) void {
    const t = @min(top, term.row - 1);
    const b = @min(bot, term.row - 1);

    if (term.dirty) |dirty| {
        for (t..b + 1) |i| {
            dirty[i] = true;
        }
    }
}

/// 获取行长度（忽略尾部空格）
pub fn lineLength(term: *Term, y: usize) usize {
    const screen = if (term.mode.alt_screen) term.alt else term.line;
    if (screen) |scr| {
        // 检查是否换行到下一行
        if (scr[y][term.col - 1].attr.wrap) {
            return term.col;
        }

        // 从末尾向前查找非空格
        var len: usize = term.col;
        while (len > 0 and scr[y][len - 1].u == ' ') {
            len -= 1;
        }
        return len;
    }
    return 0;
}
