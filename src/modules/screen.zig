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

/// 获取当前可见的行数据（考虑滚动偏移）
pub fn getVisibleLine(term: *const Term, y: usize) []Glyph {
    // 如果处于备用屏幕模式，直接返回当前行（因为 line/alt 已经交换过了）
    // 此时 term.line 指向的是备用屏幕缓冲区
    if (term.mode.alt_screen) {
        return term.line.?[y];
    }

    if (term.scr > 0) {
        if (y < term.scr) {
            // 在历史记录中
            const newest_idx = (term.hist_idx + term.hist_max - 1) % term.hist_max;
            const offset = term.scr - y - 1;
            if (term.hist_cnt > 0) {
                if (offset < term.hist_cnt) {
                    const hist_fetch_idx = (newest_idx + term.hist_max - offset) % term.hist_max;
                    return term.hist.?[hist_fetch_idx];
                }
            }
            // 超出历史记录，返回第一行
            return term.line.?[0];
        } else {
            // 在当前屏幕
            return term.line.?[y - term.scr];
        }
    }

    return term.line.?[y];
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
    var valid_rows: usize = 0;
    if (term.c.y >= new_row) {
        const shift = term.c.y - new_row + 1;
        // 释放顶部的行
        for (0..shift) |y| {
            if (term.line) |lines| allocator.free(lines[y]);
            if (term.alt) |alt| allocator.free(alt[y]);
        }

        valid_rows = old_row - shift;
        // 如果有效行数依然超过新屏幕高度，进一步释放
        if (valid_rows > new_row) {
            for (new_row..valid_rows) |y| {
                if (term.line) |lines| allocator.free(lines[y + shift]);
                if (term.alt) |alt| allocator.free(alt[y + shift]);
            }
            valid_rows = new_row;
        }

        // 移动剩余的行到顶部
        if (term.line) |lines| {
            for (0..valid_rows) |y| {
                lines[y] = lines[y + shift];
            }
        }
        if (term.alt) |alt| {
            for (0..valid_rows) |y| {
                alt[y] = alt[y + shift];
            }
        }
        term.c.y -= shift;
    } else {
        valid_rows = old_row;
        // 如果新屏幕比旧屏幕矮，释放超出的行
        if (new_row < old_row) {
            for (new_row..old_row) |y| {
                if (term.line) |lines| allocator.free(lines[y]);
                if (term.alt) |alt| allocator.free(alt[y]);
            }
            valid_rows = new_row;
        }
    }

    // 重新分配行数组
    term.line = try allocator.realloc(term.line.?, new_row);
    term.alt = try allocator.realloc(term.alt.?, new_row);

    // 调整现有行的宽度
    for (0..valid_rows) |y| {
        term.line.?[y] = try allocator.realloc(term.line.?[y], new_col);
        term.alt.?[y] = try allocator.realloc(term.alt.?[y], new_col);

        // 清除新扩展的区域（使用当前光标颜色，st 对齐）
        if (new_col > old_col) {
            for (old_col..new_col) |x| {
                term.line.?[y][x] = Glyph{
                    .u = ' ',
                    .fg = term.c.attr.fg,
                    .bg = term.c.attr.bg,
                };
                term.alt.?[y][x] = Glyph{
                    .u = ' ',
                    .fg = term.c.attr.fg,
                    .bg = term.c.attr.bg,
                };
            }
        }
    }

    // 分配并初始化新行 (st 对齐)
    for (valid_rows..new_row) |y| {
        term.line.?[y] = try allocator.alloc(Glyph, new_col);
        term.alt.?[y] = try allocator.alloc(Glyph, new_col);
        for (0..new_col) |x| {
            term.line.?[y][x] = Glyph{
                .u = ' ',
                .fg = term.c.attr.fg,
                .bg = term.c.attr.bg,
            };
            term.alt.?[y][x] = Glyph{
                .u = ' ',
                .fg = term.c.attr.fg,
                .bg = term.c.attr.bg,
            };
        }
    }

    // 调整历史缓冲区（如果宽度改变）
    if (new_col != old_col) {
        if (term.hist) |hist| {
            for (0..term.hist_max) |y| {
                hist[y] = try allocator.realloc(hist[y], new_col);
                // 清除新扩展的区域
                if (new_col > old_col) {
                    for (old_col..new_col) |x| {
                        hist[y][x] = Glyph{};
                    }
                }
            }
        }
        term.scr = 0;
    }

    // 调整脏标记
    term.dirty = try allocator.realloc(term.dirty.?, new_row);
    for (0..new_row) |y| {
        term.dirty.?[y] = true;
    }

    // 调整制表符
    const tab_spaces = @import("config.zig").Config.tab_spaces;
    term.tabs = try allocator.realloc(term.tabs.?, new_col);
    if (new_col > old_col) {
        // 从旧边界开始，按步进设置新的制表位
        var x = old_col;
        // 找到旧区域最后一个制表位（或起始点）
        while (x > 0 and !term.tabs.?[x - 1]) : (x -= 1) {}
        if (x == 0) {
            x = tab_spaces;
        } else {
            x += tab_spaces - 1;
        }

        // 清除新区域并设置新制表位
        for (old_col..new_col) |i| {
            term.tabs.?[i] = false;
        }
        var i = x;
        while (i < new_col) : (i += tab_spaces) {
            term.tabs.?[i] = true;
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

    // 限制保存的光标位置 (st 对齐)
    for (0..2) |i| {
        if (term.saved_cursor[i].x >= new_col) {
            term.saved_cursor[i].x = new_col - 1;
        }
        if (term.saved_cursor[i].y >= new_row) {
            term.saved_cursor[i].y = new_row - 1;
        }
    }

    term.c.state.wrap_next = false;
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
            // 如果清除的单元格在选择范围内，清除选择 (st 对齐)
            if (term.selection.mode != .idle) {
                if (isInsideSelection(term, x, y)) {
                    selClear(term);
                }
            }

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

    // Log scroll event
    std.log.debug("SCROLL_UP: orig={d}, n={d}, bot={d}, cursor=({d},{d})", .{ orig, n, term.bot, term.c.x, term.c.y });

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

    // 更新选择区域位置 (st 对齐)
    selScroll(term, orig, -@as(i32, @intCast(limit_n)));

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

    // 更新选择区域位置 (st 对齐)
    selScroll(term, orig, @as(i32, @intCast(limit_n)));

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

    if (t <= b) {
        if (term.dirty) |dirty| {
            for (t..b + 1) |i| {
                dirty[i] = true;
            }
        }
    }
}

/// 将包含特定属性的所有行标记为脏
pub fn setDirtyAttr(term: *Term, attr_mask: types.GlyphAttr) void {
    const screen = term.line orelse return;
    const dirty = term.dirty orelse return;

    for (0..term.row) |y| {
        if (dirty[y]) continue;
        for (0..term.col) |x| {
            // 使用自定义的属性检查逻辑 (st 的 tsetdirtattr)
            const glyph_attr = screen[y][x].attr;
            // 检查 bitmask
            if (attrMatches(glyph_attr, attr_mask)) {
                dirty[y] = true;
                break;
            }
        }
    }
}

/// 检查屏幕上是否存在带有特定属性的字符
pub fn isAttrSet(term: *Term, attr_mask: types.GlyphAttr) bool {
    const screen = term.line orelse return false;

    for (0..term.row) |y| {
        for (0..term.col) |x| {
            if (attrMatches(screen[y][x].attr, attr_mask)) return true;
        }
    }
    return false;
}

fn attrMatches(a: types.GlyphAttr, mask: types.GlyphAttr) bool {
    if (mask.bold and a.bold) return true;
    if (mask.faint and a.faint) return true;
    if (mask.italic and a.italic) return true;
    if (mask.underline and a.underline) return true;
    if (mask.blink and a.blink) return true;
    if (mask.reverse and a.reverse) return true;
    if (mask.hidden and a.hidden) return true;
    if (mask.struck and a.struck) return true;
    if (mask.wide and a.wide) return true;
    if (mask.wide_dummy and a.wide_dummy) return true;
    if (mask.url and a.url) return true;
    return false;
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

/// 清除当前选择 (st 对齐)
pub fn selClear(term: *Term) void {
    term.selection.mode = .idle;
    term.selection.ob.x = std.math.maxInt(usize);
    term.selection.nb.x = std.math.maxInt(usize);
}

/// 检查坐标是否在选择区域内 (st 对齐)
pub fn isInsideSelection(term: *const Term, x: usize, y: usize) bool {
    const sel = term.selection;
    if (sel.mode == .idle or sel.nb.x == std.math.maxInt(usize)) return false;

    if (sel.type == .regular) {
        return (y >= sel.nb.y and y <= sel.ne.y) and
            (y != sel.nb.y or x >= sel.nb.x) and
            (y != sel.ne.y or x <= sel.ne.x);
    } else {
        return (x >= sel.nb.x and x <= sel.ne.x and
            y >= sel.nb.y and y <= sel.ne.y);
    }
}

/// 处理屏幕滚动导致的选择区域偏移 (st 对齐)
pub fn selScroll(term: *Term, orig: usize, n: i32) void {
    const sel = &term.selection;
    if (sel.mode == .idle) return;

    // 如果选择区域不在当前屏幕模式（主/备），则不处理
    if (sel.alt != term.mode.alt_screen) return;

    const top = orig;
    const bot = term.bot;

    const start_in = (sel.nb.y >= top and sel.nb.y <= bot);
    const end_in = (sel.ne.y >= top and sel.ne.y <= bot);

    if (start_in != end_in) {
        // 部分在滚动区域内，清除选择
        selClear(term);
    } else if (start_in) {
        // 全部在滚动区域内，移动
        const new_ob_y = @as(isize, @intCast(sel.ob.y)) + n;
        const new_oe_y = @as(isize, @intCast(sel.oe.y)) + n;
        const new_nb_y = @as(isize, @intCast(sel.nb.y)) + n;
        const new_ne_y = @as(isize, @intCast(sel.ne.y)) + n;

        if (new_nb_y < @as(isize, @intCast(top)) or new_nb_y > @as(isize, @intCast(bot)) or
            new_ne_y < @as(isize, @intCast(top)) or new_ne_y > @as(isize, @intCast(bot)))
        {
            selClear(term);
        } else {
            sel.ob.y = @as(usize, @intCast(new_ob_y));
            sel.oe.y = @as(usize, @intCast(new_oe_y));
            sel.nb.y = @as(usize, @intCast(new_nb_y));
            sel.ne.y = @as(usize, @intCast(new_ne_y));
        }
    }
}
