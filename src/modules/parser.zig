//! 终端转义序列解析器
//! 解析 ANSI/VT100/VT220 转义序列

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const screen = @import("screen.zig");

const Term = types.Term;
const Glyph = types.Glyph;
const CSIEscape = types.CSIEscape;
const STREscape = types.STREscape;
const EscapeState = types.EscapeState;
const Charset = types.Charset;

pub const ParserError = error{
    InvalidEscape,
    BufferOverflow,
};

/// 解析转义序列
pub const Parser = struct {
    term: *Term,
    csi: CSIEscape = .{},
    str: STREscape = .{},
    allocator: std.mem.Allocator,
    pty: ?*const anyopaque = null, // PTY 引用，用于发送响应

    pub fn init(term: *Term, allocator: std.mem.Allocator) !Parser {
        var p = Parser{
            .term = term,
            .allocator = allocator,
        };
        try p.strReset();
        p.resetPalette();
        return p;
    }

    /// 设置 PTY 引用
    pub fn setPty(self: *Parser, pty_ptr: *const anyopaque) void {
        self.pty = pty_ptr;
    }

    /// 写入数据到 PTY
    fn ptyWrite(self: *Parser, data: []const u8) void {
        if (self.pty) |pty_ptr| {
            const PTYType = @import("pty.zig").PTY;
            const pty = @as(*PTYType, @ptrCast(@alignCast(@constCast(pty_ptr))));
            _ = pty.write(data) catch {};
        }
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.str.buf);
    }

    /// 处理单个字符
    pub fn putc(self: *Parser, c: u21) !void {
        const control = c < 32 or c == 0x7F;

        // 处理字符串序列（OSC、DCS 等）
        if (self.term.esc.str) {
            if (c == '\x07' or c == 0x9C or c == 0x1B or
                (c >= 0x80 and c <= 0x9F))
            {
                self.term.esc.str = false;
                self.term.esc.str_end = true;
                try self.strHandle();
            } else {
                try self.strPut(c);
            }
            return;
        }

        // 处理控制字符
        if (control) {
            try self.controlCode(@intCast(c));
            return;
        }

        // 处理转义序列开始
        if (c == 0x1B) { // ESC
            self.csiReset();
            self.term.esc.start = true;
            self.term.esc.csi = false;
            self.term.esc.str = false;
            self.term.esc.alt_charset = false;
            self.term.esc.tstate = false;
            self.term.esc.utf8 = false;
            self.term.esc.str_end = false;
            self.term.esc.decaln = false;
            return;
        }

        // 处理 CSI 序列
        if (self.term.esc.csi) {
            // 累积字符到 buffer
            if (self.csi.len < self.csi.buf.len - 1) {
                self.csi.buf[self.csi.len] = @truncate(c);
                self.csi.len += 1;
            }

            // 检查序列是否结束 (0x40 - 0x7E)
            if (c >= 0x40 and c <= 0x7E) {
                self.term.esc.csi = false; // 退出 CSI 模式
                try self.csiParse();
                try self.csiHandle();
                self.csiReset();
            }
            return;
        }

        // 其他转义序列
        if (self.term.esc.start) {
            try self.escapeHandle(c);
            if (!self.term.esc.csi and !self.term.esc.str and !self.term.esc.alt_charset and
                !self.term.esc.utf8 and !self.term.esc.tstate and !self.term.esc.decaln)
            {
                self.term.esc = .{};
            }
            return;
        }

        // 处理字符集选择 (G0-G3)
        if (self.term.esc.alt_charset) {
            const cc: u8 = @truncate(c);
            self.term.trantbl[self.term.icharset] = switch (cc) {
                'B' => .usa, // US ASCII
                '0' => .graphic0, // VT100 line drawing
                'U' => .multi, // null
                'K' => .ger, // user preferred
                'A' => .uk, // UK
                else => self.term.trantbl[self.term.icharset], // 保持不变
            };
            self.term.esc.alt_charset = false;
            return;
        }

        // 处理临时字符集切换 (SS2, SS3)
        if (self.term.esc.tstate) {
            self.term.charset = self.term.icharset;
            self.term.esc.tstate = false;
            return;
        }

        // 普通字符 - 写入到屏幕
        self.term.lastc = c;
        try self.writeChar(c);
    }

    /// 写入字符到屏幕
    fn writeChar(self: *Parser, u: u21) !void {
        const width = @import("unicode.zig").runeWidth(u);

        // 检查自动换行
        if (self.term.mode.wrap and self.term.c.state == .wrap_next) {
            if (width > 0) {
                try self.newLine();
            }
            self.term.c.state = .default;
        }

        // 检查是否需要换行
        if (self.term.c.x + width > self.term.col) {
            if (self.term.mode.wrap) {
                try self.newLine();
            } else {
                self.term.c.x = @max(self.term.c.x, width) - width;
            }
        }

        // 限制光标位置
        if (self.term.c.x >= self.term.col) {
            try self.newLine();
            self.term.c.x = 0;
        }

        // 写入字符
        if (self.term.line) |lines| {
            if (self.term.c.y < lines.len and self.term.c.x < lines[self.term.c.y].len) {
                var glyph = self.term.c.attr;
                glyph.u = u;
                if (width == 2) {
                    glyph.attr.wide = true;
                }
                lines[self.term.c.y][self.term.c.x] = glyph;
            }

            // 移动光标 - 处理宽字符
            if (width == 2 and self.term.c.x + 1 < self.term.col) {
                self.term.c.x += 2;
                if (self.term.c.y < lines.len and self.term.c.x < lines[self.term.c.y].len) {
                    lines[self.term.c.y][self.term.c.x] = Glyph{
                        .u = 0,
                        .attr = self.term.c.attr.attr,
                        .fg = self.term.c.attr.fg,
                        .bg = self.term.c.attr.bg,
                    };
                    lines[self.term.c.y][self.term.c.x].attr.wide_dummy = true;
                }
            } else if (width > 0) {
                self.term.c.x += width;
            }
        }

        // 设置脏标记
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) {
                dirty[self.term.c.y] = true;
            }
        }
    }

    /// 插入空白字符
    fn insertBlank(self: *Parser, n: usize) !void {
        const max_chars = self.term.col - self.term.c.x;
        const insert_count = @min(n, max_chars);

        if (self.term.line) |lines| {
            if (self.term.c.y < lines.len) {
                const line = lines[self.term.c.y];
                // 移动字符腾出空间
                var i: usize = self.term.col - 1;
                while (i >= self.term.c.x + insert_count) : (i -= 1) {
                    if (i + insert_count < line.len) {
                        line[i + insert_count] = line[i];
                    }
                }
                // 清除新插入的字符
                var j: usize = self.term.c.x;
                while (j < self.term.c.x + insert_count) : (j += 1) {
                    var glyph = self.term.c.attr;
                    glyph.u = ' ';
                    if (j < line.len) {
                        line[j] = glyph;
                    }
                }
            }
        }

        // 设置脏标记
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// 擦除显示区域
    fn eraseDisplay(self: *Parser, mode: i32) !void {
        const x = self.term.c.x;
        const y = self.term.c.y;

        switch (mode) {
            0 => { // 从光标到屏幕末尾
                try self.clearRegion(x, y, self.term.col - 1, y);
                if (y < self.term.row - 1) {
                    try self.clearRegion(0, y + 1, self.term.col - 1, self.term.row - 1);
                }
            },
            1 => { // 从屏幕开头到光标
                if (y > 0) {
                    try self.clearRegion(0, 0, self.term.col - 1, y - 1);
                }
                try self.clearRegion(0, y, x, y);
            },
            2 => { // 清除整个屏幕
                try self.clearRegion(0, 0, self.term.col - 1, self.term.row - 1);
            },
            else => {},
        }
    }

    /// 擦除行
    fn eraseLine(self: *Parser, mode: i32) !void {
        const x = self.term.c.x;
        const y = self.term.c.y;

        switch (mode) {
            0 => { // 从光标到行末
                try self.clearRegion(x, y, self.term.col - 1, y);
            },
            1 => { // 从行首到光标
                try self.clearRegion(0, y, x, y);
            },
            2 => { // 清除整行
                try self.clearRegion(0, y, self.term.col - 1, y);
            },
            else => {},
        }
    }

    /// 清除区域
    fn clearRegion(self: *Parser, x1: usize, y1: usize, x2: usize, y2: usize) !void {
        var x_start = x1;
        var x_end = x2;
        var y_start = y1;
        var y_end = y2;

        // 确保坐标正确
        if (x_start > x_end) {
            const temp = x_start;
            x_start = x_end;
            x_end = temp;
        }
        if (y_start > y_end) {
            const temp = y_start;
            y_start = y_end;
            y_end = temp;
        }

        // 限制在屏幕范围内
        x_start = @max(0, x_start);
        x_end = @min(x_end, self.term.col - 1);
        y_start = @max(0, y_start);
        y_end = @min(y_end, self.term.row - 1);

        if (self.term.line) |lines| {
            const clear_glyph = self.term.c.attr;
            var glyph_var = clear_glyph;
            glyph_var.u = ' ';

            var row = y_start;
            while (row <= y_end) : (row += 1) {
                if (row < lines.len) {
                    const line = lines[row];
                    var col = x_start;
                    while (col <= x_end) : (col += 1) {
                        if (col < line.len) {
                            line[col] = glyph_var;
                        }
                    }
                }
            }
        }

        // 设置脏标记
        if (self.term.dirty) |dirty| {
            var row = y_start;
            while (row <= y_end) : (row += 1) {
                if (row < dirty.len) dirty[row] = true;
            }
        }
    }

    /// 插入空白行
    fn insertBlankLine(self: *Parser, n: usize) !void {
        if (self.term.c.y < self.term.top or self.term.c.y > self.term.bot) {
            return;
        }
        try self.scrollDown(self.term.c.y, n);
    }

    /// 删除行
    fn deleteLine(self: *Parser, n: usize) !void {
        if (self.term.c.y < self.term.top or self.term.c.y > self.term.bot) {
            return;
        }
        try self.scrollUp(self.term.c.y, n);
    }

    /// 删除字符
    fn deleteChar(self: *Parser, n: usize) !void {
        const max_chars = self.term.col - self.term.c.x;
        const delete_count = @min(n, max_chars);
        if (delete_count == 0) return;

        if (self.term.line) |lines| {
            if (self.term.c.y < lines.len) {
                const line = lines[self.term.c.y];
                // 向左移动字符
                var i = self.term.c.x;
                while (i + delete_count < self.term.col) : (i += 1) {
                    if (i + delete_count < line.len) {
                        line[i] = line[i + delete_count];
                    }
                }
                // 清除末尾字符
                var j: usize = @max(0, self.term.col - delete_count);
                while (j < self.term.col) : (j += 1) {
                    if (j < line.len) {
                        var glyph = self.term.c.attr;
                        glyph.u = ' ';
                        line[j] = glyph;
                    }
                }
            }
        }

        // 设置脏标记
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// 向上滚动
    fn scrollUp(self: *Parser, orig: usize, n: usize) !void {
        try screen.scrollUp(self.term, orig, n);
    }

    /// 向下滚动
    fn scrollDown(self: *Parser, orig: usize, n: usize) !void {
        try screen.scrollDown(self.term, orig, n);
    }

    /// 擦除光标处的字符
    fn eraseChar(self: *Parser, n: usize) !void {
        const max_chars = self.term.col - self.term.c.x;
        const erase_count = @min(n, max_chars);
        if (erase_count == 0) return;

        if (self.term.line) |lines| {
            if (self.term.c.y < lines.len) {
                const line = lines[self.term.c.y];
                const clear_glyph = self.term.c.attr;
                var glyph_var = clear_glyph;
                glyph_var.u = ' ';

                var i: usize = 0;
                while (i < erase_count and self.term.c.x + i < line.len) : (i += 1) {
                    line[self.term.c.x + i] = glyph_var;
                }
            }
        }

        // 设置脏标记
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// 设置图形模式 (SGR)
    fn setGraphicsMode(self: *Parser) !void {
        var i: usize = 0;
        while (i < self.csi.narg) : (i += 1) {
            const arg = self.csi.arg[i];
            switch (arg) {
                0 => { // 重置所有属性
                    self.term.c.attr.attr.bold = false;
                    self.term.c.attr.attr.faint = false;
                    self.term.c.attr.attr.italic = false;
                    self.term.c.attr.attr.underline = false;
                    self.term.c.attr.attr.blink = false;
                    self.term.c.attr.attr.reverse = false;
                    self.term.c.attr.attr.hidden = false;
                    self.term.c.attr.attr.struck = false;
                    self.term.c.attr.fg = config.Config.colors.default_foreground;
                    self.term.c.attr.bg = config.Config.colors.default_background;
                    self.term.c.attr.ustyle = -1;
                    for (0..3) |j| {
                        self.term.c.attr.ucolor[j] = -1;
                    }
                },
                1 => { // 加粗
                    self.term.c.attr.attr.bold = true;
                },
                2 => { // 淡色
                    self.term.c.attr.attr.faint = true;
                },
                3 => { // 斜体
                    self.term.c.attr.attr.italic = true;
                },
                4 => { // 下划线
                    self.term.c.attr.attr.underline = true;
                    self.term.c.attr.attr.dirty_underline = true;
                    if (i + 1 < self.csi.narg) {
                        const style = self.csi.arg[i + 1];
                        if (style >= 0 and style <= 5) {
                            self.term.c.attr.ustyle = @intCast(style);
                            i += 1; // 跳过下一个参数
                        }
                    }
                },
                5, 6 => { // 闪烁
                    self.term.c.attr.attr.blink = true;
                },
                7 => { // 反色
                    self.term.c.attr.attr.reverse = true;
                },
                8 => { // 隐藏
                    self.term.c.attr.attr.hidden = true;
                },
                9 => { // 删除线
                    self.term.c.attr.attr.struck = true;
                },
                22 => { // 关闭加粗/淡色
                    self.term.c.attr.attr.bold = false;
                    self.term.c.attr.attr.faint = false;
                },
                23 => { // 关闭斜体
                    self.term.c.attr.attr.italic = false;
                },
                24 => { // 关闭下划线
                    self.term.c.attr.attr.underline = false;
                    self.term.c.attr.ustyle = -1;
                    self.term.c.attr.attr.dirty_underline = true;
                },
                25 => { // 关闭闪烁
                    self.term.c.attr.attr.blink = false;
                },
                27 => { // 关闭反色
                    self.term.c.attr.attr.reverse = false;
                },
                28 => { // 关闭隐藏
                    self.term.c.attr.attr.hidden = false;
                },
                29 => { // 关闭删除线
                    self.term.c.attr.attr.struck = false;
                },
                38 => { // 前景色扩展
                    i += 1;
                    if (i < self.csi.narg) {
                        const color_submode = self.csi.arg[i];
                        if (color_submode == 5) {
                            // 索引颜色
                            i += 1;
                            if (i < self.csi.narg and self.csi.arg[i] >= 0 and self.csi.arg[i] <= 255) {
                                self.term.c.attr.fg = @intCast(self.csi.arg[i]);
                            }
                        } else if (color_submode == 2) {
                            // 24 位 RGB 颜色
                            i += 3;
                            if (i < self.csi.narg) {
                                const r = @as(u8, @intCast(@max(0, @min(255, self.csi.arg[i - 2]))));
                                const g = @as(u8, @intCast(@max(0, @min(255, self.csi.arg[i - 1]))));
                                const b = @as(u8, @intCast(@max(0, @min(255, self.csi.arg[i]))));
                                self.term.c.attr.fg = (0xFF << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
                            }
                        }
                    }
                },
                39 => { // 默认前景色
                    self.term.c.attr.fg = config.Config.colors.default_foreground;
                },
                48 => { // 背景色扩展
                    i += 1;
                    if (i < self.csi.narg) {
                        const color_submode = self.csi.arg[i];
                        if (color_submode == 5) {
                            // 索引颜色
                            i += 1;
                            if (i < self.csi.narg and self.csi.arg[i] >= 0 and self.csi.arg[i] <= 255) {
                                self.term.c.attr.bg = @intCast(self.csi.arg[i]);
                            }
                        } else if (color_submode == 2) {
                            // 24 位 RGB 颜色
                            i += 3;
                            if (i < self.csi.narg) {
                                const r = @as(u8, @intCast(@max(0, @min(255, self.csi.arg[i - 2]))));
                                const g = @as(u8, @intCast(@max(0, @min(255, self.csi.arg[i - 1]))));
                                const b = @as(u8, @intCast(@max(0, @min(255, self.csi.arg[i]))));
                                self.term.c.attr.bg = (0xFF << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
                            }
                        }
                    }
                },
                49 => { // 默认背景色
                    self.term.c.attr.bg = config.Config.colors.default_background;
                },
                58 => { // 下划线颜色
                    i += 1;
                    if (i < self.csi.narg and self.csi.arg[i] == 5) {
                        i += 3;
                        if (i < self.csi.narg) {
                            self.term.c.attr.ucolor[0] = @as(i32, @intCast(self.csi.arg[i - 2]));
                            self.term.c.attr.ucolor[1] = @as(i32, @intCast(self.csi.arg[i - 1]));
                            self.term.c.attr.ucolor[2] = @as(i32, @intCast(self.csi.arg[i]));
                            self.term.c.attr.attr.dirty_underline = true;
                        }
                    }
                },
                59 => { // 默认下划线颜色
                    for (0..3) |j| {
                        self.term.c.attr.ucolor[j] = -1;
                    }
                    self.term.c.attr.attr.dirty_underline = true;
                },
                else => {
                    // 处理标准颜色
                    if (arg >= 30 and arg <= 37) {
                        // 前景色 (标准颜色 0-7)
                        self.term.c.attr.fg = @as(u32, @intCast(arg - 30));
                    } else if (arg >= 40 and arg <= 47) {
                        // 背景色 (标准颜色 0-7)
                        self.term.c.attr.bg = @as(u32, @intCast(arg - 40));
                    } else if (arg >= 90 and arg <= 97) {
                        // 明亮前景色 (8-15)
                        self.term.c.attr.fg = @as(u32, @intCast((arg - 90) + 8));
                    } else if (arg >= 100 and arg <= 107) {
                        // 明亮背景色 (8-15)
                        self.term.c.attr.bg = @as(u32, @intCast((arg - 100) + 8));
                    }
                },
            }
        }
    }

    /// 新行
    fn newLine(self: *Parser) !void {
        // Mark old cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }

        if (self.term.c.y == self.term.bot) {
            try self.scrollUp(self.term.top, 1);
        } else {
            self.term.c.y += 1;
        }

        // Mark new cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// 移动光标
    fn moveCursor(self: *Parser, dx: i32, dy: i32) !void {
        // Mark old cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }

        var new_x = @as(isize, @intCast(self.term.c.x)) + dx;
        var new_y = @as(isize, @intCast(self.term.c.y)) + dy;

        // 限制在范围内
        new_x = @max(0, @min(new_x, @as(isize, @intCast(self.term.col - 1))));
        new_y = @max(0, @min(new_y, @as(isize, @intCast(self.term.row - 1))));

        self.term.c.x = @as(usize, @intCast(new_x));
        self.term.c.y = @as(usize, @intCast(new_y));
        self.term.c.state = .default; // Reset wrap state

        // Mark new cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// 移动光标到绝对位置
    fn moveTo(self: *Parser, x: usize, y: usize) !void {
        // Mark old cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }

        var new_x = x;
        var new_y = y;

        // 处理原点模式
        if (self.term.c.state == .origin) {
            new_y += self.term.top;
        }

        // 限制在范围内
        if (self.term.c.state == .origin) {
            new_x = @min(new_x, self.term.col - 1);
            new_y = @min(new_y, self.term.bot);
        } else {
            new_x = @min(new_x, self.term.col - 1);
            new_y = @min(new_y, self.term.row - 1);
        }

        self.term.c.x = new_x;
        self.term.c.y = new_y;
        self.term.c.state = .default;

        // Mark new cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// 制表符
    fn putTab(self: *Parser) !void {
        var x = self.term.c.x + 1;

        // 查找下一个制表位
        while (x < self.term.col) {
            if (self.term.tabs) |tabs| {
                if (x < tabs.len and tabs[x]) break;
            }
            x += 1;
        }

        self.term.c.x = @min(x, self.term.col - 1);
        self.term.c.state = .default;

        // Mark new cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// DECALN - 屏幕对齐测试 (填充屏幕为 'E')
    fn decaln(self: *Parser) !void {
        if (self.term.line) |lines| {
            const glyph = self.term.c.attr;
            var glyph_var = glyph;
            glyph_var.u = 'E'; // 使用大写字母 E

            for (0..self.term.row) |y| {
                if (y < lines.len) {
                    for (0..self.term.col) |x| {
                        if (x < lines[y].len) {
                            lines[y][x] = glyph_var;
                        }
                    }
                }
            }
        }

        // 标记所有行为脏
        if (self.term.dirty) |dirty| {
            for (0..dirty.len) |i| {
                dirty[i] = true;
            }
        }

        // 重置光标位置
        try self.moveTo(0, 0);
    }

    /// RIS - Reset to Initial State: 重置终端到初始状态
    fn resetTerminal(self: *Parser) !void {
        // 清除屏幕
        try self.eraseDisplay(2);

        // 重置光标到原点
        try self.moveTo(0, 0);

        // 重置光标状态
        self.term.c.state = .default;

        // 重置文本属性
        self.term.c.attr = .{};
        self.term.c.attr.fg = config.Config.colors.default_foreground;
        self.term.c.attr.bg = config.Config.colors.default_background;

        // 重置滚动区域
        self.term.top = 0;
        self.term.bot = self.term.row - 1;

        // 重置模式（保留一些模式）
        const preserve_insert = self.term.mode.insert;
        const preserve_wrap = self.term.mode.wrap;
        self.term.mode = .{};
        self.term.mode.insert = preserve_insert;
        self.term.mode.wrap = preserve_wrap;

        // 重置字符集
        for (0..4) |i| {
            self.term.trantbl[i] = .usa;
        }
        self.term.charset = 0;
        self.term.icharset = 0;

        // 重置制表符
        if (self.term.tabs) |tabs| {
            for (0..tabs.len) |i| {
                tabs[i] = (i % 8 == 0); // 每 8 列一个制表符
            }
        }

        // 重置转义序列状态
        self.term.esc = .{};

        // 重置调色板
        self.resetPalette();
        self.term.default_fg = config.Config.colors.default_foreground;
        self.term.default_bg = config.Config.colors.default_background;
        self.term.default_cs = config.Config.colors.default_cursor;

        // 重置窗口标题
        self.term.window_title = "stz";
        self.term.window_title_dirty = true;

        // 标记所有行为脏
        if (self.term.dirty) |dirty| {
            for (0..dirty.len) |i| {
                dirty[i] = true;
            }
        }
    }

    /// DECSC - 保存光标
    fn cursorSave(self: *Parser) void {
        const alt = if (self.term.mode.alt_screen) @as(usize, 1) else 0;
        self.term.saved_cursor[alt].attr = self.term.c.attr;
        self.term.saved_cursor[alt].x = self.term.c.x;
        self.term.saved_cursor[alt].y = self.term.c.y;
        self.term.saved_cursor[alt].state = self.term.c.state;
        // 标记行为脏
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// DECRC - 恢复光标
    fn cursorRestore(self: *Parser) !void {
        const alt = if (self.term.mode.alt_screen) @as(usize, 1) else 0;
        const saved = &self.term.saved_cursor[alt];
        // 恢复光标位置和状态
        self.term.c.attr = saved.attr;
        try self.moveTo(saved.x, saved.y);
        self.term.c.state = saved.state;
        // 标记行为脏
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// 处理控制字符
    fn controlCode(self: *Parser, c: u8) !void {
        switch (c) {
            '\x08' => { // BS - 退格
                try self.moveCursor(-1, 0);
            },
            '\x09' => { // HT - 水平制表符
                try self.putTab();
            },
            '\x0A', '\x0B', '\x0C' => { // LF, VT, FF - 换行
                try self.newLine();
                if (self.term.mode.crlf) {
                    self.term.c.x = 0;
                }
            },
            '\x0D' => { // CR - 回车
                try self.moveTo(0, self.term.c.y);
            },
            '\x07' => { // BEL - 响铃
                // 由 window 处理
            },
            0x0E => { // SO - Shift Out (切换到 G1)
                self.term.charset = 1;
            },
            0x0F => { // SI - Shift In (切换到 G0)
                self.term.charset = 0;
            },
            0x1B => { // ESC
                self.csiReset();
                self.term.esc.start = true;
                self.term.esc.csi = false;
                self.term.esc.str = false;
                self.term.esc.alt_charset = false;
                self.term.esc.tstate = false;
                self.term.esc.str_end = false;
            },
            0x84 => { // IND - Index: 光标下移一行，如需要则滚动
                if (self.term.c.y == self.term.bot) {
                    try self.scrollUp(self.term.top, 1);
                } else {
                    try self.moveCursor(0, 1);
                }
            },
            0x85 => { // NEL - Next Line: 移动到下一行开头
                if (self.term.c.y == self.term.bot) {
                    try self.scrollUp(self.term.top, 1);
                } else {
                    try self.moveCursor(0, 1);
                }
                self.term.c.x = 0;
            },
            0x88 => { // HTS - Horizontal Tabulation Set: 在当前位置设置制表符
                if (self.term.c.x < self.term.col) {
                    if (self.term.tabs) |tabs| {
                        tabs[self.term.c.x] = true;
                    }
                }
            },
            0x8D => { // RI - Reverse Index: 光标上移一行，如需要则反向滚动
                if (self.term.c.y == self.term.top) {
                    try self.scrollDown(self.term.top, 1);
                } else {
                    try self.moveCursor(0, -1);
                }
            },
            0x8E => { // SS2 - Single Shift 2: 临时使用 G2 字符集
                self.term.esc.alt_charset = true;
                self.term.icharset = 2; // G2
                self.term.esc.tstate = true;
            },
            0x8F => { // SS3 - Single Shift 3: 临时使用 G3 字符集
                self.term.esc.alt_charset = true;
                self.term.icharset = 3; // G3
                self.term.esc.tstate = true;
            },
            0x9B => { // CSI - Control Sequence Introducer
                self.term.esc.csi = true;
                self.term.esc.start = false;
            },
            0x90 => { // DCS - Device Control String
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = 'P';
            },
            0x9D => { // OSC - Operating System Command
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = ']';
            },
            0x9E => { // PM - Privacy Message
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = '^';
            },
            0x9F => { // APC - Application Program Command
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = '_';
            },
            else => {},
        }
    }

    /// 处理转义字符
    fn escapeHandle(self: *Parser, c: u21) !void {
        const cc: u8 = @truncate(c);
        switch (cc) {
            '[' => {
                self.term.esc.csi = true;
                self.term.esc.start = false;
            },
            'P', '_', '^', ']', 'k' => { // DCS, APC, PM, OSC
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = cc;
            },
            '(', ')', '*', '+' => { // 字符集选择
                self.term.esc.alt_charset = true;
                self.term.icharset = cc - '(';
                self.term.esc.start = false;
            },
            '#' => { // DECALN 前缀
                self.term.esc.decaln = true;
                self.term.esc.start = false;
            },
            '%' => { // UTF-8 模式选择
                // 下一个字符选择字符集
                self.term.esc.utf8 = true;
                self.term.esc.start = false;
            },
            'G' => { // 选择 UTF-8 (ESC % G)
                if (self.term.esc.utf8) {
                    self.term.mode.utf8 = true;
                    self.term.esc.utf8 = false;
                }
            },
            '@' => { // 选择默认字符集 (ESC % @)
                if (self.term.esc.utf8) {
                    self.term.mode.utf8 = false;
                    self.term.esc.utf8 = false;
                }
            },
            '7' => { // DECSC - 保存光标
                self.cursorSave();
            },
            '8' => {
                if (self.term.esc.decaln) {
                    // DECALN - 屏幕对齐测试 (ESC # 8)
                    try self.decaln();
                    self.term.esc.decaln = false;
                } else {
                    // DECRC - 恢复光标 (ESC 8)
                    try self.cursorRestore();
                }
            },
            'n' => { // LS2 - Locking Shift 2
                self.term.charset = 2;
            },
            'o' => { // LS3 - Locking Shift 3
                self.term.charset = 3;
            },
            'D' => { // IND - Index (7-bit escape version)
                if (self.term.c.y == self.term.bot) {
                    try self.scrollUp(self.term.top, 1);
                } else {
                    try self.moveCursor(0, 1);
                }
            },
            'E' => { // NEL - Next Line (7-bit escape version)
                if (self.term.c.y == self.term.bot) {
                    try self.scrollUp(self.term.top, 1);
                } else {
                    try self.moveCursor(0, 1);
                }
                self.term.c.x = 0;
            },
            'H' => { // HTS - Horizontal Tabulation Set (7-bit escape version)
                if (self.term.c.x < self.term.col) {
                    if (self.term.tabs) |tabs| {
                        tabs[self.term.c.x] = true;
                    }
                }
            },
            'M' => { // RI - Reverse Index (7-bit escape version)
                if (self.term.c.y == self.term.top) {
                    try self.scrollDown(self.term.top, 1);
                } else {
                    try self.moveCursor(0, -1);
                }
            },
            'Z' => { // DECID - 终端识别
                // 发送设备属性：ESC [ ? 6 c
                self.ptyWrite("\x1B[?6c");
            },
            'c' => { // RIS - Reset to Initial State: 重置终端到初始状态
                try self.resetTerminal();
            },
            '>' => { // DECPNM - 数字小键盘
                self.term.mode.app_keypad = false;
            },
            '=' => { // DECPAM - 应用小键盘
                self.term.mode.app_keypad = true;
            },
            '\\' => { // ST - 字符串终止符
                if (self.term.esc.str_end) {
                    try self.strHandle();
                }
            },
            else => {},
        }
    }

    /// 解析 CSI 参数
    fn csiParse(self: *Parser) !void {
        var p: usize = 0;

        self.csi.narg = 0;
        self.csi.priv = 0;
        self.csi.mode[1] = 0;

        if (self.csi.len == 0) return;

        // 检查私有标志 '?'
        if (self.csi.buf[p] == '?') {
            self.csi.priv = 1;
            p += 1;
        }

        self.csi.buf[self.csi.len] = 0;

        while (p < self.csi.len) {
            var val: i64 = 0;
            const start = p;
            while (p < self.csi.len and std.ascii.isDigit(self.csi.buf[p])) {
                val = val * 10 + @as(i64, @intCast(self.csi.buf[p] - '0'));
                p += 1;
            }

            if (p == start) {
                val = 0; // 空参数默认为 0
            }

            if (self.csi.narg < 32) {
                self.csi.arg[self.csi.narg] = val;
                self.csi.narg += 1;
            }

            if (p >= self.csi.len) break;

            const sep = self.csi.buf[p];
            if (sep == ';' or sep == ':') {
                p += 1;
                // 如果分隔符是最后一个字符，说明后面还有一个空参数
                if (p >= self.csi.len) {
                    if (self.csi.narg < 32) {
                        self.csi.arg[self.csi.narg] = 0;
                        self.csi.narg += 1;
                    }
                    break;
                }
            } else {
                // 可能是终止符或其他标志 (如 SP q)
                if (sep == ' ' and p + 1 < self.csi.len) {
                    self.csi.mode[1] = self.csi.buf[p + 1];
                    p += 2;
                }
                break;
            }
        }

        // 获取模式字符 (最后一个字符)
        self.csi.mode[0] = self.csi.buf[self.csi.len - 1];
    }

    /// 处理 CSI 序列
    fn csiHandle(self: *Parser) !void {
        const mode = self.csi.mode[0];

        // 如果没有参数，设置默认值 0
        if (self.csi.narg == 0) {
            self.csi.arg[0] = 0;
            self.csi.narg = 1;
        }

        // 处理带有空格的序列 (如 CSI SP q)
        if (self.csi.mode[1] != 0) {
            switch (self.csi.mode[1]) {
                'q' => { // DECSCUSR -- 设置光标样式
                    const style = self.csi.arg[0];
                    // 0: 默认（闪烁块）, 1: 闪烁块, 2: 稳定块
                    // 3: 闪烁下划线, 4: 稳定下划线
                    // 5: 闪烁竖条, 6: 稳定竖条
                    if (style >= 0 and style <= 8) {
                        self.term.cursor_style = @as(u8, @intCast(@max(0, @min(style, 8))));
                    }
                },
                else => {},
            }
            return;
        }

        switch (mode) {
            '@' => { // ICH - 插入空字符
                const n = @as(usize, @intCast(@max(1, self.csi.arg[0])));
                try self.insertBlank(n);
            },
            'b' => { // REP - 重复最后一个字符
                const n = @as(usize, @intCast(@max(1, @min(self.csi.arg[0], 65535))));
                if (self.term.lastc != 0) {
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        try self.writeChar(self.term.lastc);
                    }
                }
            },
            'c' => { // DA - 设备属性
                if (self.csi.arg[0] == 0) {
                    // 发送 VT100/VT220 识别字符串
                    self.ptyWrite("\x1B[?6c");
                }
            },
            'i' => { // MC - Media Copy (打印功能)
                switch (self.csi.arg[0]) {
                    0 => {
                        // 打印屏幕（暂不实现）
                    },
                    1 => {
                        // 打印当前行（暂不实现）
                    },
                    2 => {
                        // 打印选择（暂不实现）
                    },
                    4 => {
                        // 禁用打印模式
                        self.term.mode.print = false;
                    },
                    5 => {
                        // 启用打印模式
                        self.term.mode.print = true;
                    },
                    else => {},
                }
            },
            'A' => { // CUU - 光标上移
                const n = @as(i32, @intCast(@max(1, self.csi.arg[0])));
                try self.moveCursor(0, -n);
            },
            'B' => { // CUD - 光标下移
                const n = @as(i32, @intCast(@max(1, self.csi.arg[0])));
                try self.moveCursor(0, n);
            },
            'e' => { // VPR - 垂直位置相对
                const n = @as(i32, @intCast(@max(1, self.csi.arg[0])));
                try self.moveCursor(0, n);
            },
            'C' => { // CUF - 光标右移
                const n = @as(i32, @intCast(@max(1, self.csi.arg[0])));
                try self.moveCursor(n, 0);
            },
            'a' => { // HPR - 水平位置相对
                const n = @as(i32, @intCast(@max(1, self.csi.arg[0])));
                try self.moveCursor(n, 0);
            },
            'D' => { // CUB - 光标左移
                const n = @as(i32, @intCast(@max(1, self.csi.arg[0])));
                try self.moveCursor(-n, 0);
            },
            'E' => { // CNL - 光标到下一行开头
                const n = @as(i32, @intCast(@max(1, self.csi.arg[0])));
                const temp_y = @as(i32, @intCast(self.term.c.y)) + n;
                try self.moveTo(0, @as(usize, @intCast(temp_y)));
            },
            'F' => { // CPL - 光标到上一行开头
                const n = @as(i32, @intCast(@max(1, self.csi.arg[0])));
                const temp_y = @as(i32, @intCast(self.term.c.y)) - n;
                const new_y = @max(0, temp_y);
                try self.moveTo(0, @as(usize, @intCast(new_y)));
            },
            'G', '`' => { // CHA, HPA - 水平位置绝对
                const col = @max(1, self.csi.arg[0]) - 1;
                try self.moveTo(col, self.term.c.y);
            },
            'H', 'f' => { // CUP, HVP - 光标位置
                const row = @max(1, self.csi.arg[0]) - 1;
                const col = @max(1, self.csi.arg[1]) - 1;
                try self.moveTo(col, row);
            },
            'I' => { // CHT - 光标前进制表
                const n = @as(i32, @intCast(@max(1, self.csi.arg[0])));
                try self.putTab();
                // 重复 n-1 次
                var i: i32 = 1;
                while (i < n) : (i += 1) {
                    try self.putTab();
                }
            },
            'J' => { // ED - 擦除显示
                try self.eraseDisplay(@truncate(self.csi.arg[0]));
            },
            'K' => { // EL - 擦除行
                try self.eraseLine(@truncate(self.csi.arg[0]));
            },
            'L' => { // IL - 插入行
                const n = @as(usize, @intCast(@max(1, self.csi.arg[0])));
                try self.insertBlankLine(n);
            },
            'M' => { // DL - 删除行
                const n = @as(usize, @intCast(@max(1, self.csi.arg[0])));
                try self.deleteLine(n);
            },
            'P' => { // DCH - 删除字符
                const n = @as(usize, @intCast(@max(1, self.csi.arg[0])));
                try self.deleteChar(n);
            },
            'X' => { // ECH - 擦除字符
                const n = @as(usize, @intCast(@max(1, self.csi.arg[0])));
                try self.eraseChar(n);
            },
            'Z' => { // CBT - 光标后退制表
                const n = @as(i32, @intCast(@max(1, self.csi.arg[0])));
                var i: i32 = 0;
                while (i < n) : (i += 1) {
                    try self.putTab();
                    // 后退一个制表位
                    var x = self.term.c.x;
                    while (x > 0) : (x -= 1) {
                        if (self.term.tabs) |tabs| {
                            if (x < tabs.len and tabs[x]) {
                                break;
                            }
                        }
                    }
                    self.term.c.x = @max(0, x);
                }
            },
            'g' => { // TBC - 清除制表符
                const arg = if (self.csi.narg > 0) self.csi.arg[0] else 0;
                switch (arg) {
                    0 => { // 清除当前制表位
                        if (self.term.c.x < self.term.col) {
                            if (self.term.tabs) |tabs| {
                                tabs[self.term.c.x] = false;
                            }
                        }
                    },
                    3 => { // 清除所有制表位
                        if (self.term.tabs) |tabs| {
                            for (0..tabs.len) |i| {
                                tabs[i] = false;
                            }
                        }
                    },
                    else => {},
                }
            },
            'd' => { // VPA - 垂直位置绝对
                const row = @max(1, self.csi.arg[0]) - 1;
                try self.moveTo(self.term.c.x, row);
            },
            'S' => { // SU - 滚动向上 n 行
                if (self.csi.priv == 0) {
                    const n = @as(usize, @intCast(@max(1, self.csi.arg[0])));
                    try self.scrollUp(self.term.top, n);
                }
            },
            'T' => { // SD - 滚动向下 n 行
                const n = @as(usize, @intCast(@max(1, self.csi.arg[0])));
                try self.scrollDown(self.term.top, n);
            },
            'h' => { // SM - 设置模式
                try self.setMode(true);
            },
            'l' => { // RM - 重置模式
                try self.setMode(false);
            },
            'm' => { // SGR - 选择图形再现
                try self.setGraphicsMode();
            },
            'n' => { // DSR - 设备状态报告
                switch (self.csi.arg[0]) {
                    5 => { // 设备状态
                        self.ptyWrite("\x1B[0n"); // 设备正常
                    },
                    6 => { // 光标位置报告
                        var buf: [32]u8 = undefined;
                        var len: usize = 0;
                        buf[0] = 0x1b;
                        buf[1] = '[';
                        len = 2;
                        // 将 self.term.c.y + 1 写入
                        const y_val = self.term.c.y + 1;
                        if (y_val >= 10) {
                            buf[len] = '0' + @as(u8, @intCast(y_val / 10));
                            len += 1;
                        }
                        buf[len] = '0' + @as(u8, @intCast(y_val % 10));
                        len += 1;
                        buf[len] = ';';
                        len += 1;
                        // 将 self.term.c.x + 1 写入
                        const x_val = self.term.c.x + 1;
                        if (x_val >= 10) {
                            buf[len] = '0' + @as(u8, @intCast(x_val / 10));
                            len += 1;
                        }
                        buf[len] = '0' + @as(u8, @intCast(x_val % 10));
                        len += 1;
                        buf[len] = 'R';
                        len += 1;
                        self.ptyWrite(buf[0..len]);
                    },
                    else => {},
                }
            },
            'r' => { // DECSTBM - 设置滚动区域
                try self.setScrollRegion();
            },
            's' => { // DECSC - 保存光标
                try self.cursorSaveRestore(.save);
            },
            'u' => { // DECRC - 恢复光标
                if (self.csi.priv == 0) {
                    try self.cursorSaveRestore(.load);
                }
            },
            else => {},
        }
    }

    /// 设置滚动区域
    fn setScrollRegion(self: *Parser) !void {
        if (self.csi.priv != 0) return; // 不支持私有模式

        // 获取参数，默认值为 1 和 term.row
        const top_arg = if (self.csi.narg > 0 and self.csi.arg[0] > 0)
            @as(i32, @intCast(self.csi.arg[0]))
        else
            1;
        const bot_arg = if (self.csi.narg > 1 and self.csi.arg[1] > 0)
            @as(i32, @intCast(self.csi.arg[1]))
        else
            @as(i32, @intCast(self.term.row));

        // 转换为 0-based 索引并限制在有效范围内
        var top = top_arg - 1;
        var bot = bot_arg - 1;

        // 限制在屏幕范围内
        top = @max(0, @min(top, @as(i32, @intCast(self.term.row)) - 1));
        bot = @max(0, @min(bot, @as(i32, @intCast(self.term.row)) - 1));

        // 确保 top <= bot
        if (top > bot) {
            const temp = top;
            top = bot;
            bot = temp;
        }

        self.term.top = @as(usize, @intCast(top));
        self.term.bot = @as(usize, @intCast(bot));

        // 将光标移动到原点
        try self.moveTo(0, 0);
    }

    /// 保存/恢复光标
    fn cursorSaveRestore(self: *Parser, mode: types.CursorMove) !void {
        const alt_idx = @intFromBool(self.term.mode.alt_screen);
        switch (mode) {
            .save => {
                self.term.saved_cursor[alt_idx] = types.SavedCursor{
                    .attr = self.term.c.attr,
                    .x = self.term.c.x,
                    .y = self.term.c.y,
                    .state = self.term.c.state,
                };
            },
            .load => {
                const saved = self.term.saved_cursor[alt_idx];
                self.term.c.attr = saved.attr;
                try self.moveTo(saved.x, saved.y);
                self.term.c.state = saved.state;
            },
        }
    }

    /// 切换屏幕缓冲区
    fn swapScreen(self: *Parser) !void {
        if (self.term.line == null or self.term.alt == null) return;

        // 交换缓冲区
        const temp = self.term.line.?;
        self.term.line = self.term.alt;
        self.term.alt = temp;

        // 切换模式标志
        self.term.mode.alt_screen = !self.term.mode.alt_screen;

        // 标记所有行为脏
        if (self.term.dirty) |dirty| {
            for (0..dirty.len) |i| {
                dirty[i] = true;
            }
        }
    }

    /// 设置终端模式
    fn setMode(self: *Parser, set: bool) !void {
        if (self.csi.priv == 0) {
            // 非私有模式
            switch (self.csi.arg[0]) {
                2 => self.term.mode.kbdlock = set, // MODE_KBDLOCK
                4 => self.term.mode.insert = set,
                12 => self.term.mode.echo = !set, // MODE_ECHO (注意：set false 时启用 echo)
                20 => self.term.mode.crlf = set,
                else => {},
            }
        } else {
            // DEC 私有模式
            switch (self.csi.arg[0]) {
                1 => self.term.mode.app_cursor = set,
                5 => {
                    self.term.mode.reverse = set;
                    // 标记所有行为脏以便重新渲染
                    if (self.term.dirty) |dirty| {
                        for (0..dirty.len) |i| {
                            dirty[i] = true;
                        }
                    }
                },
                6 => {
                    if (set) {
                        self.term.c.state = .origin;
                        try self.moveTo(0, 0);
                    } else {
                        self.term.c.state = .default;
                    }
                },
                7 => self.term.mode.wrap = set,
                25 => self.term.mode.hide_cursor = !set,
                47 => { // 切换备用屏幕缓冲区
                    if (self.term.alt != null) {
                        // 如果当前在备用屏幕且要退出，先清除
                        if (!set and self.term.mode.alt_screen) {
                            if (self.term.alt) |alt| {
                                const clear_glyph = self.term.c.attr;
                                var glyph_var = clear_glyph;
                                glyph_var.u = ' ';
                                for (0..self.term.row) |y| {
                                    if (y < alt.len) {
                                        for (0..self.term.col) |x| {
                                            alt[y][x] = glyph_var;
                                        }
                                    }
                                }
                            }
                        }
                        // 如果要进入备用屏幕，或要退出且当前在备用屏幕
                        if (set != self.term.mode.alt_screen) {
                            try self.swapScreen();
                        }
                    }
                },
                1048 => { // 保存/恢复光标 (like DECSC/DECRC)
                    try self.cursorSaveRestore(if (set) .save else .load);
                },
                1049 => { // 交换屏幕并保存/恢复光标
                    try self.cursorSaveRestore(if (set) .save else .load);
                    if (self.term.alt != null) {
                        if (set and !self.term.mode.alt_screen) {
                            // 进入备用屏幕
                            if (self.term.alt) |alt| {
                                const clear_glyph = self.term.c.attr;
                                var glyph_var = clear_glyph;
                                glyph_var.u = ' ';
                                for (0..self.term.row) |y| {
                                    if (y < alt.len) {
                                        for (0..self.term.col) |x| {
                                            alt[y][x] = glyph_var;
                                        }
                                    }
                                }
                            }
                            try self.swapScreen();
                            try self.moveTo(0, 0);
                        } else if (!set and self.term.mode.alt_screen) {
                            // 退出备用屏幕
                            try self.swapScreen();
                            try self.cursorSaveRestore(.load);
                        }
                    }
                },
                1047 => { // 切换备用屏幕 (类似 47)
                    if (self.term.alt != null) {
                        if (set != self.term.mode.alt_screen) {
                            try self.swapScreen();
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// 处理 OSC/字符串序列
    fn strHandle(self: *Parser) !void {
        // 清除字符串序列标志
        self.term.esc.str = false;
        self.term.esc.str_end = false;

        // 解析字符串参数
        try self.strParse();

        // 获取第一个参数
        const par = if (self.str.narg > 0) std.fmt.parseInt(i32, self.str.args[0], 10) catch 0 else 0;

        switch (self.str.type) {
            ']' => { // OSC - 操作系统命令
                try self.oscHandle(par);
            },
            'P' => { // DCS - 设备控制字符串
                // 处理设备控制 (例如同步更新)
                if (std.mem.eql(u8, self.str.buf, "=1s")) {
                    // 开始同步更新
                } else if (std.mem.eql(u8, self.str.buf, "=2s")) {
                    // 结束同步更新
                }
            },
            'k' => { // 设置标题（兼容）
                // 老式标题设置兼容性
                if (self.str.narg > 0 and self.str.args[0].len > 0) {
                    // TODO: 设置窗口标题
                }
            },
            '_' => { // APC - 应用程序命令
                // 忽略
            },
            '^' => { // PM - 隐私消息
                // 忽略
            },
            else => {},
        }
    }

    /// 处理 OSC 序列
    fn oscHandle(self: *Parser, par: i32) !void {
        switch (par) {
            0 => { // 设置窗口和图标标题
                if (self.str.narg > 1 and self.str.args[1].len > 0) {
                    self.term.window_title = self.str.args[1];
                    self.term.window_title_dirty = true;
                }
            },
            1 => { // 设置图标标题
                if (self.str.narg > 1 and self.str.args[1].len > 0) {
                    self.term.window_title = self.str.args[1];
                    self.term.window_title_dirty = true;
                }
            },
            2 => { // 设置窗口标题
                if (self.str.narg > 1 and self.str.args[1].len > 0) {
                    self.term.window_title = self.str.args[1];
                    self.term.window_title_dirty = true;
                }
            },
            52 => { // 操作剪贴板数据
                // 格式: OSC 52 ; Pc ; Pdata ST
                // Pc: p (PRIMARY), s (SECONDARY), c (CLIPBOARD), q (查询)
                // Pdata: Base64 编码的数据
                if (self.str.narg >= 3) {
                    const selector = self.str.args[1];
                    const data = self.str.args[2];

                    if (selector.len > 0 and data.len > 0) {
                        switch (selector[0]) {
                            'p', 's', 'c' => {
                                // 设置剪贴板（暂时不实现实际复制）
                                // 需要调用 X11 剪贴板 API
                            },
                            'q' => {
                                // 查询剪贴板（暂时不实现）
                                // 需要调用 X11 剪贴板 API 并返回数据
                            },
                            else => {},
                        }
                    }
                }
            },
            10 => { // 设置前景颜色
                if (self.str.narg >= 2) {
                    if (try self.parseOscColor(self.str.args[1])) |color| {
                        self.term.default_fg = color;
                    }
                }
            },
            11 => { // 设置背景颜色
                if (self.str.narg >= 2) {
                    if (try self.parseOscColor(self.str.args[1])) |color| {
                        self.term.default_bg = color;
                    }
                }
            },
            12 => { // 设置光标颜色
                if (self.str.narg >= 2) {
                    if (try self.parseOscColor(self.str.args[1])) |color| {
                        self.term.default_cs = color;
                    }
                }
            },
            4 => { // 设置调色板颜色
                if (self.str.narg >= 3) {
                    const index = std.fmt.parseInt(usize, self.str.args[1], 10) catch 0;
                    if (index < 256) {
                        const color_opt = try self.parseOscColor(self.str.args[2]);
                        if (color_opt) |color| {
                            self.term.palette[index] = color;
                        }
                    }
                }
            },
            104 => { // 重置调色板颜色
                if (self.str.narg > 1) {
                    // 重置指定索引的调色板颜色
                    const index_str = self.str.args[1];
                    if (std.mem.eql(u8, index_str, "*")) {
                        // 重置所有调色板颜色
                        self.resetPalette();
                    } else {
                        // 重置单个索引
                        const index = std.fmt.parseInt(usize, index_str, 10) catch 0;
                        if (index < 256) {
                            self.term.palette[index] = @as(u32, @intCast(index));
                        }
                    }
                } else {
                    // 重置所有调色板颜色
                    self.resetPalette();
                }
            },
            110 => { // 重置前景色
                self.term.default_fg = config.Config.colors.foreground;
            },
            111 => { // 重置背景色
                self.term.default_bg = config.Config.colors.background;
            },
            112 => { // 重置光标颜色
                self.term.default_cs = config.Config.colors.cursor;
            },
            else => {},
        }
    }

    /// 解析 OSC 颜色字符串
    /// 支持: rgb:RR/GG/BB, #RRGGBB, RRGGBB, 索引数字
    fn parseOscColor(self: *Parser, color_str: []const u8) !?u32 {
        _ = self;

        // 跳过前导空格
        var start: usize = 0;
        while (start < color_str.len and color_str[start] == ' ') : (start += 1) {}

        if (start >= color_str.len) return null;

        const trimmed = color_str[start..];

        // 格式 1: rgb:RR/GG/BB
        if (std.mem.startsWith(u8, trimmed, "rgb:") or std.mem.startsWith(u8, trimmed, "rgb:")) {
            var parts = std.mem.splitScalar(u8, trimmed[4..], '/');
            var rgb = [3]u8{ 0, 0, 0 };
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                const part = parts.next() orelse break;
                if (part.len > 0) {
                    const hex = std.fmt.parseInt(u8, part, 16) catch 0;
                    rgb[i] = hex;
                }
            }
            return (0xFF << 24) | (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | @as(u32, rgb[2]);
        }

        // 格式 2: #RRGGBB
        if (trimmed[0] == '#') {
            const hex_str = trimmed[1..];
            if (hex_str.len >= 6) {
                const r = std.fmt.parseInt(u8, hex_str[0..2], 16) catch 0;
                const g = std.fmt.parseInt(u8, hex_str[2..4], 16) catch 0;
                const b = std.fmt.parseInt(u8, hex_str[4..6], 16) catch 0;
                return (0xFF << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
            }
        }

        // 格式 3: RRGGBB (6位十六进制)
        if (trimmed.len >= 6) {
            const r = std.fmt.parseInt(u8, trimmed[0..2], 16) catch null;
            const g = std.fmt.parseInt(u8, trimmed[2..4], 16) catch null;
            const b = std.fmt.parseInt(u8, trimmed[4..6], 16) catch null;
            if (r != null and g != null and b != null) {
                return (0xFF << 24) | (@as(u32, r.?) << 16) | (@as(u32, g.?) << 8) | @as(u32, b.?);
            }
        }

        // 格式 4: 纯数字（颜色索引）
        if (std.ascii.isDigit(trimmed[0])) {
            const index = std.fmt.parseInt(usize, trimmed, 10) catch 0;
            return @as(u32, @intCast(index));
        }

        return null;
    }

    /// 重置调色板为默认值
    fn resetPalette(self: *Parser) void {
        // 0-7: 标准 16 色中的暗色
        for (0..8) |i| {
            self.term.palette[i] = config.Config.colors.normal[i];
        }
        // 8-15: 标准 16 色中的亮色
        for (8..16) |i| {
            self.term.palette[i] = config.Config.colors.bright[i - 8];
        }
        // 16-231: 6x6x6 RGB 立方体
        // 格式: 16 + 36*r + 6*g + b
        // r, g, b 的值都是 0-5，映射到 0, 95, 135, 175, 215, 255
        var color_idx: u32 = 16;
        while (color_idx < 232) : (color_idx += 1) {
            const c = color_idx - 16;
            const r = c / 36;
            const g = (c % 36) / 6;
            const b = c % 6;
            const r_val: u8 = if (r == 0) 0 else @intCast(r * 40 + 55);
            const g_val: u8 = if (g == 0) 0 else @intCast(g * 40 + 55);
            const b_val: u8 = if (b == 0) 0 else @intCast(b * 40 + 55);
            self.term.palette[color_idx] = (@as(u32, r_val) << 16) | (@as(u32, g_val) << 8) | @as(u32, b_val);
        }
        // 232-255: 24 级灰度
        // 从 8 (0x080808) 到 238 (0xEEEEEE)，每步 10
        var gray_idx: u32 = 232;
        var gray_val: u32 = 8;
        while (gray_idx < 256) : (gray_idx += 1) {
            const val = gray_val * 0x010101; // 将灰度值转换为 0xRRGGBB 格式
            self.term.palette[gray_idx] = val;
            gray_val += 10;
        }
    }

    /// 解析字符串参数
    fn strParse(self: *Parser) !void {
        var start: usize = 0;
        self.str.narg = 0;
        if (self.str.len >= self.str.siz) {
            // 缓冲区已满，无法添加终止符
            return;
        }
        self.str.buf[self.str.len] = 0;

        while (self.str.narg < 16 and start < self.str.len) {
            const arg_start = start;

            // 查找分号或字符串结束
            while (start < self.str.len and self.str.buf[start] != 0 and self.str.buf[start] != ';') {
                start += 1;
            }

            // 创建参数切片
            self.str.args[self.str.narg] = self.str.buf[arg_start..start];

            if (start < self.str.len and self.str.buf[start] == ';') {
                start += 1; // 跳过分号
            }

            self.str.narg += 1;
        }
    }

    /// 添加字符到字符串缓冲区
    fn strPut(self: *Parser, c: u21) !void {
        if (self.str.len + 4 >= self.str.siz) {
            // 扩大缓冲区
            const new_size = self.str.siz * 2;
            const new_buf = try self.allocator.realloc(self.str.buf, new_size);
            self.str.buf = new_buf;
            self.str.siz = new_size;
        }

        var utf8_buf: [4]u8 = undefined;
        const len = try @import("unicode.zig").encode(c, &utf8_buf);

        const dest = self.str.buf[self.str.len..][0..len];
        for (0..len) |i| {
            dest[i] = utf8_buf[i];
        }
        self.str.len += len;
    }

    /// 重置字符串缓冲区
    fn strReset(self: *Parser) !void {
        if (self.str.buf.len == 0) {
            self.str.buf = try self.allocator.alloc(u8, 1024);
            self.str.siz = 1024;
        }
        self.str.len = 0;
        self.str.narg = 0;
    }

    /// 重置 CSI 缓冲区
    fn csiReset(self: *Parser) void {
        const csi_bytes = @as([*]u8, @ptrCast(&self.csi));
        for (0..@sizeOf(CSIEscape)) |i| {
            csi_bytes[i] = 0;
        }
    }
};
