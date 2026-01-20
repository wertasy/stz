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
    const line_buf = try allocator.alloc([]Glyph, row);
    errdefer allocator.free(line_buf);
    term.line = line_buf;

    // 分配备用屏幕
    const alt_buf = try allocator.alloc([]Glyph, row);
    errdefer allocator.free(alt_buf);
    term.alt = alt_buf;

    // 分配历史缓冲区
    const hist_rows = @import("config.zig").Config.scroll.history_lines;
    const hist_buf = try allocator.alloc([]Glyph, hist_rows);
    errdefer allocator.free(hist_buf);
    term.hist = hist_buf;
    term.hist_max = hist_rows;
    term.hist_idx = 0;
    term.hist_cnt = 0;
    term.scr = 0;

    // 分配脏标记
    const dirty_buf = try allocator.alloc(bool, row);
    errdefer allocator.free(dirty_buf);
    term.dirty = dirty_buf;

    // 分配制表符
    const tabs_buf = try allocator.alloc(bool, col);
    errdefer allocator.free(tabs_buf);
    term.tabs = tabs_buf;

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

    // 初始化历史缓冲区
    for (0..term.hist_max) |y| {
        term.hist.?[y] = try allocator.alloc(Glyph, col);
        for (0..col) |x| {
            term.hist.?[y][x] = Glyph{};
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

    if (term.hist) |lines| {
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
    term.hist = null;
    term.dirty = null;
    term.tabs = null;
}

/// 调整终端大小
/// 参考 st 的 tresize 实现，滑动屏幕以保持光标位置
pub fn resize(term: *Term, new_row: usize, new_col: usize) !void {
    const allocator = term.allocator;

    if (new_row < 1 or new_col < 1) {
        return error.InvalidSize;
    }

    const old_row = term.row;
    const old_col = term.col;

    // 滑动屏幕内容以保持光标位置
    // 如果光标在新屏幕外面，向上滚动屏幕
    if (term.c.y >= new_row) {
        const shift = term.c.y - new_row + 1;
        // 释放顶部的行
        for (0..shift) |y| {
            if (term.line) |lines| {
                allocator.free(lines[y]);
            }
            if (term.alt) |alt| {
                allocator.free(alt[y]);
            }
        }
        // 移动剩余的行
        if (term.line) |lines| {
            var dest: usize = 0;
            for (shift..old_row) |y| {
                if (dest < new_row) {
                    lines[dest] = lines[y];
                    dest += 1;
                }
            }
        }
        if (term.alt) |alt| {
            var dest: usize = 0;
            for (shift..old_row) |y| {
                if (dest < new_row) {
                    alt[dest] = alt[y];
                    dest += 1;
                }
            }
        }
        // 释放底部的行
        for (new_row..old_row) |y| {
            if (term.line) |lines| {
                allocator.free(lines[y]);
            }
            if (term.alt) |alt| {
                allocator.free(alt[y]);
            }
        }
    } else {
        // 释放超出新大小的行（仅在缩小屏幕时）
        if (new_row < old_row) {
            for (new_row..old_row) |y| {
                if (term.line) |lines| {
                    allocator.free(lines[y]);
                }
                if (term.alt) |alt| {
                    allocator.free(alt[y]);
                }
            }
        }
    }

    // 重新分配行数组
    term.line = try allocator.realloc(term.line.?, new_row);
    term.alt = try allocator.realloc(term.alt.?, new_row);

    // 调整每行的宽度
    const minrow = @min(new_row, old_row);
    for (0..minrow) |y| {
        term.line.?[y] = try allocator.realloc(term.line.?[y], new_col);
        term.alt.?[y] = try allocator.realloc(term.alt.?[y], new_col);

        // 清除新扩展的区域（如果有）
        if (new_col > old_col) {
            for (old_col..new_col) |x| {
                term.line.?[y][x] = Glyph{};
                term.alt.?[y][x] = Glyph{};
            }
        }
    }

    // 分配新的行（如果有）
    for (minrow..new_row) |y| {
        term.line.?[y] = try allocator.alloc(Glyph, new_col);
        term.alt.?[y] = try allocator.alloc(Glyph, new_col);
        for (0..new_col) |x| {
            term.line.?[y][x] = Glyph{};
            term.alt.?[y][x] = Glyph{};
        }
    }

    // 调整历史缓冲区（如果宽度改变）
    if (new_col != old_col) {
        if (term.hist) |hist| {
            for (hist) |line| {
                allocator.free(line);
            }
            allocator.free(hist);
        }
        const hist_rows = term.hist_max;
        term.hist = try allocator.alloc([]Glyph, hist_rows);
        for (0..hist_rows) |y| {
            term.hist.?[y] = try allocator.alloc(Glyph, new_col);
            for (0..new_col) |x| {
                term.hist.?[y][x] = Glyph{};
            }
        }
        term.hist_idx = 0;
        term.hist_cnt = 0;
        term.scr = 0;
    }

    // 调整脏标记
    term.dirty = try allocator.realloc(term.dirty.?, new_row);
    for (0..new_row) |y| {
        term.dirty.?[y] = true;
    }

    // 调整制表符
    term.tabs = try allocator.realloc(term.tabs.?, new_col);
    if (new_col > old_col) {
        for (old_col..new_col) |x| {
            term.tabs.?[x] = false;
        }
    }
    // 设置新的默认制表符
    const tab_spaces = @import("config.zig").Config.tab_spaces;
    var tab_col: usize = old_col;
    if (tab_col % tab_spaces != 0) {
        tab_col += tab_spaces - (tab_col % tab_spaces);
    }
    if (new_col > tab_col) {
        for (tab_col..new_col) |x| {
            if (x % tab_spaces == 0) {
                term.tabs.?[x] = true;
            }
        }
    }

    term.row = new_row;
    term.col = new_col;

    // 重置滚动区域
    term.top = 0;
    term.bot = new_row - 1;

    // 限制光标位置
    if (term.c.x >= new_col) {
        term.c.x = new_col - 1;
    }
    if (term.c.y >= new_row) {
        term.c.y = new_row - 1;
    }
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

    const screen = term.line;

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
    if (orig > term.bot) return;
    const limit_n = @min(n, term.bot - orig + 1);
    const screen = term.line;

    if (orig == 0 and limit_n > 0 and !term.mode.alt_screen) {
        // Save lines to history
        for (0..limit_n) |i| {
            const line_idx = orig + i;
            const src_line = screen.?[line_idx];
            const dest_line = term.hist.?[term.hist_idx];

            @memcpy(dest_line, src_line);

            term.hist_idx = (term.hist_idx + 1) % term.hist_max;
            if (term.hist_cnt < term.hist_max) {
                term.hist_cnt += 1;
            }
        }
    }

    // 移动行
    var i: usize = orig;
    while (i + limit_n <= term.bot) : (i += 1) {
        const temp = screen.?[i];
        screen.?[i] = screen.?[i + limit_n];
        screen.?[i + limit_n] = temp;
    }

    // Mark affected region as dirty
    setDirty(term, orig, term.bot);

    // 清除底部行
    for (0..limit_n) |k| {
        const idx = term.bot + 1 - limit_n + k;
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
    if (orig > term.bot) return;
    const limit_n = @min(n, term.bot - orig + 1);
    const screen = term.line;

    // 移动行
    var i: usize = term.bot;
    while (i >= orig + limit_n) : (i -= 1) {
        const temp = screen.?[i];
        screen.?[i] = screen.?[i - limit_n];
        screen.?[i - limit_n] = temp;
    }

    // Mark affected region as dirty
    setDirty(term, orig, term.bot);

    // 清除顶部行
    for (0..limit_n) |k| {
        const idx = orig + k;
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
    const screen = term.line;
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
