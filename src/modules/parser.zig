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
                if (c != 0x1B) return;
            } else {
                try self.strPut(c);
                return;
            }
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
        var prev_charset: ?u8 = null;
        if (self.term.esc.tstate) {
            prev_charset = self.term.charset;
            self.term.charset = self.term.icharset;
            self.term.esc.tstate = false;
        }

        // 普通字符 - 写入到屏幕
        self.term.lastc = c;
        try self.writeChar(c);

        // 恢复临时切换前的字符集
        if (prev_charset) |pc| {
            self.term.charset = pc;
        }
    }

    /// VT100 字符集 0 (特殊图形字符集) 映射表
    const vt100_0 = init: {
        var mapping = [_]u21{0} ** 128;
        mapping['$'] = 0x00a3; // 0x24: 磅符号
        mapping['+'] = 0x2192; // 0x2b: 右箭头
        mapping[','] = 0x2190; // 0x2c: 左箭头
        mapping['-'] = 0x2191; // 0x2d: 上箭头
        mapping['.'] = 0x2193; // 0x2e: 下箭头
        mapping['0'] = 0x2588; // 0x30: 实心块
        mapping['a'] = 0x2592; // 0x61: 棋盘格
        mapping['f'] = 0x00b0; // 0x66: 度数符号
        mapping['g'] = 0x00b1; // 0x67: 正负号
        mapping['h'] = 0x2591; // 0x68: 浅色方块
        mapping['i'] = 0x000b; // 0x69: 灯笼符号 (VT100 0x0b)
        mapping['j'] = 0x2518; // 0x6a: 右下角
        mapping['k'] = 0x2510; // 0x6b: 右上角
        mapping['l'] = 0x250c; // 0x6c: 左上角
        mapping['m'] = 0x2514; // 0x6d: 左下角
        mapping['n'] = 0x253c; // 0x6e: 十十字架
        mapping['o'] = 0x23ba; // 0x6f: 扫描线 1
        mapping['p'] = 0x23bb; // 0x70: 扫描线 3
        mapping['q'] = 0x2500; // 0x71: 水平线
        mapping['r'] = 0x23bc; // 0x72: 扫描线 7
        mapping['s'] = 0x23bd; // 0x73: 扫描线 9
        mapping['t'] = 0x251c; // 0x74: 左 T 型
        mapping['u'] = 0x2524; // 0x75: 右 T 型
        mapping['v'] = 0x2534; // 0x76: 下 T 型
        mapping['w'] = 0x252c; // 0x77: 上 T 型
        mapping['x'] = 0x2502; // 0x78: 垂直线
        mapping['y'] = 0x2264; // 0x79: 小于等于
        mapping['z'] = 0x2265; // 0x7a: 大于等于
        mapping['{'] = 0x03c0; // 0x7b: Pi
        mapping['|'] = 0x2260; // 0x7c: 不等于
        mapping['}'] = 0x00a3; // 0x7d: 磅符号
        mapping['~'] = 0x00b7; // 0x7e: 中心点
        mapping['_'] = 0x0020; // 0x5f: 空格
        break :init mapping;
    };

    /// 写入字符到屏幕
    fn writeChar(self: *Parser, u: u21) !void {
        var codepoint = u;

        // 字符集转换
        if (self.term.trantbl[self.term.charset] == .graphic0) {
            if (codepoint >= 0x24 and codepoint <= 0x7e) {
                const translated = vt100_0[codepoint];
                if (translated != 0) {
                    codepoint = translated;
                }
            }
        }

        const width = @import("unicode.zig").runeWidth(codepoint);

        // 检查自动换行
        if (self.term.mode.wrap and self.term.c.state == .wrap_next) {
            if (width > 0) {
                // 设置前一个字符的 wrap 标志
                if (self.term.line) |lines| {
                    if (self.term.c.y < lines.len) {
                        lines[self.term.c.y][self.term.col - 1].attr.wrap = true;
                    }
                }
                try self.newLine();
            }
            self.term.c.state = .default;
        }

        // 检查是否需要换行（字符宽度超出边界）
        if (self.term.c.x + width > self.term.col) {
            if (self.term.mode.wrap) {
                if (self.term.line) |lines| {
                    if (self.term.c.y < lines.len) {
                        lines[self.term.c.y][self.term.col - 1].attr.wrap = true;
                    }
                }
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
                glyph.u = codepoint;
                if (width == 2) {
                    glyph.attr.wide = true;
                }
                lines[self.term.c.y][self.term.c.x] = glyph;
            }

            // 移动光标 - 处理宽字符
            if (width == 2 and self.term.c.x + 1 < self.term.col) {
                const dummy_x = self.term.c.x + 1;
                if (self.term.c.y < lines.len and dummy_x < lines[self.term.c.y].len) {
                    lines[self.term.c.y][dummy_x] = Glyph{
                        .u = 0,
                        .attr = self.term.c.attr.attr,
                        .fg = self.term.c.attr.fg,
                        .bg = self.term.c.attr.bg,
                    };
                    lines[self.term.c.y][dummy_x].attr.wide_dummy = true;
                }
                self.term.c.x += 2;
            } else if (width > 0) {
                self.term.c.x += width;
            }

            if (self.term.mode.wrap and self.term.c.x >= self.term.col) {
                self.term.c.state = .wrap_next;
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
                var i: usize = self.term.col - 1;
                while (i >= self.term.c.x + insert_count) : (i -= 1) {
                    if (i + insert_count < line.len) {
                        line[i + insert_count] = line[i];
                    }
                }
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
            3 => { // 清除历史缓冲区
                if (self.term.hist) |hist| {
                    for (hist) |line| {
                        for (line) |*glyph| {
                            glyph.* = .{
                                .u = ' ',
                                .fg = self.term.c.attr.fg,
                                .bg = self.term.c.attr.bg,
                                .attr = .{},
                            };
                        }
                    }
                }
                self.term.hist_cnt = 0;
                self.term.hist_idx = 0;
                self.term.scr = 0;
                if (self.term.dirty) |dirty| {
                    for (0..dirty.len) |i| dirty[i] = true;
                }
            },
            else => {},
        }
    }

    /// 擦除行
    fn eraseLine(self: *Parser, mode: i32) !void {
        const x = self.term.c.x;
        const y = self.term.c.y;

        switch (mode) {
            0 => try self.clearRegion(x, y, self.term.col - 1, y),
            1 => try self.clearRegion(0, y, x, y),
            2 => try self.clearRegion(0, y, self.term.col - 1, y),
            else => {},
        }
    }

    /// 清除区域
    fn clearRegion(self: *Parser, x1: usize, y1: usize, x2: usize, y2: usize) !void {
        var x_start = @min(x1, x2);
        var x_end = @max(x1, x2);
        var y_start = @min(y1, y2);
        var y_end = @max(y1, y2);

        x_start = @min(x_start, self.term.col - 1);
        x_end = @min(x_end, self.term.col - 1);
        y_start = @min(y_start, self.term.row - 1);
        y_end = @min(y_end, self.term.row - 1);

        if (self.term.line) |lines| {
            const clear_glyph = Glyph{ .u = ' ', .fg = self.term.c.attr.fg, .bg = self.term.c.attr.bg };
            var row = y_start;
            while (row <= y_end) : (row += 1) {
                if (row < lines.len) {
                    const line = lines[row];
                    var col = x_start;
                    while (col <= x_end) : (col += 1) {
                        if (col < line.len) line[col] = clear_glyph;
                    }
                }
            }
        }

        if (self.term.dirty) |dirty| {
            var row = y_start;
            while (row <= y_end) : (row += 1) {
                if (row < dirty.len) dirty[row] = true;
            }
        }
    }

    fn insertBlankLine(self: *Parser, n: usize) !void {
        if (self.term.c.y < self.term.top or self.term.c.y > self.term.bot) return;
        try self.scrollDown(self.term.c.y, n);
    }

    fn deleteLine(self: *Parser, n: usize) !void {
        if (self.term.c.y < self.term.top or self.term.c.y > self.term.bot) return;
        try self.scrollUp(self.term.c.y, n);
    }

    fn deleteChar(self: *Parser, n: usize) !void {
        const max_chars = self.term.col - self.term.c.x;
        const delete_count = @min(n, max_chars);
        if (delete_count == 0) return;

        if (self.term.line) |lines| {
            if (self.term.c.y < lines.len) {
                const line = lines[self.term.c.y];
                var i = self.term.c.x;
                while (i + delete_count < self.term.col) : (i += 1) {
                    if (i + delete_count < line.len) line[i] = line[i + delete_count];
                }
                var j: usize = @max(0, self.term.col - delete_count);
                while (j < self.term.col) : (j += 1) {
                    if (j < line.len) line[j] = Glyph{ .u = ' ', .fg = self.term.c.attr.fg, .bg = self.term.c.attr.bg };
                }
            }
        }

        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    fn scrollUp(self: *Parser, orig: usize, n: usize) !void {
        try screen.scrollUp(self.term, orig, n);
    }

    fn scrollDown(self: *Parser, orig: usize, n: usize) !void {
        try screen.scrollDown(self.term, orig, n);
    }

    fn eraseChar(self: *Parser, n: usize) !void {
        const max_chars = self.term.col - self.term.c.x;
        const erase_count = @min(n, max_chars);
        if (erase_count == 0) return;

        if (self.term.line) |lines| {
            if (self.term.c.y < lines.len) {
                const line = lines[self.term.c.y];
                const clear_glyph = Glyph{ .u = ' ', .fg = self.term.c.attr.fg, .bg = self.term.c.attr.bg };
                var i: usize = 0;
                while (i < erase_count and self.term.c.x + i < line.len) : (i += 1) {
                    line[self.term.c.x + i] = clear_glyph;
                }
            }
        }

        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    fn setGraphicsMode(self: *Parser) !void {
        var i: usize = 0;
        while (i < self.csi.narg) : (i += 1) {
            const arg = self.csi.arg[i];
            switch (arg) {
                0 => {
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
                    for (0..3) |j| self.term.c.attr.ucolor[j] = -1;
                },
                1 => self.term.c.attr.attr.bold = true,
                2 => self.term.c.attr.attr.faint = true,
                3 => self.term.c.attr.attr.italic = true,
                4 => {
                    self.term.c.attr.attr.underline = true;
                    if (i + 1 < self.csi.narg) {
                        const style = self.csi.arg[i + 1];
                        if (style >= 0 and style <= 5) {
                            self.term.c.attr.ustyle = @intCast(style);
                            i += 1;
                        }
                    }
                },
                5, 6 => self.term.c.attr.attr.blink = true,
                7 => self.term.c.attr.attr.reverse = true,
                8 => self.term.c.attr.attr.hidden = true,
                9 => self.term.c.attr.attr.struck = true,
                22 => {
                    self.term.c.attr.attr.bold = false;
                    self.term.c.attr.attr.faint = false;
                },
                23 => self.term.c.attr.attr.italic = false,
                24 => {
                    self.term.c.attr.attr.underline = false;
                    self.term.c.attr.ustyle = -1;
                },
                25 => self.term.c.attr.attr.blink = false,
                27 => self.term.c.attr.attr.reverse = false,
                28 => self.term.c.attr.attr.hidden = false,
                29 => self.term.c.attr.attr.struck = false,
                30...37 => self.term.c.attr.fg = @as(u32, @intCast(arg - 30)),
                38 => {
                    var color_submode: i64 = -1;
                    var r: i64 = -1;
                    var g: i64 = -1;
                    var b: i64 = -1;
                    var index: i64 = -1;
                    if (self.csi.carg[i][0] != -1) {
                        color_submode = self.csi.carg[i][0];
                        if (color_submode == 5) index = self.csi.carg[i][1] else if (color_submode == 2) {
                            r = self.csi.carg[i][1];
                            g = self.csi.carg[i][2];
                            b = self.csi.carg[i][3];
                        }
                    } else {
                        i += 1;
                        if (i < self.csi.narg) {
                            color_submode = self.csi.arg[i];
                            if (color_submode == 5) {
                                i += 1;
                                if (i < self.csi.narg) index = self.csi.arg[i];
                            } else if (color_submode == 2) {
                                i += 3;
                                if (i < self.csi.narg) {
                                    r = self.csi.arg[i - 2];
                                    g = self.csi.arg[i - 1];
                                    b = self.csi.arg[i];
                                }
                            }
                        }
                    }
                    if (color_submode == 5 and index >= 0 and index <= 255) self.term.c.attr.fg = @intCast(index) else if (color_submode == 2 and r != -1) self.term.c.attr.fg = (0xFF << 24) | (@as(u32, @intCast(r)) << 16) | (@as(u32, @intCast(g)) << 8) | @as(u32, @intCast(b));
                },
                39 => self.term.c.attr.fg = config.Config.colors.default_foreground,
                40...47 => self.term.c.attr.bg = @as(u32, @intCast(arg - 40)),
                48 => {
                    var color_submode: i64 = -1;
                    var r: i64 = -1;
                    var g: i64 = -1;
                    var b: i64 = -1;
                    var index: i64 = -1;
                    if (self.csi.carg[i][0] != -1) {
                        color_submode = self.csi.carg[i][0];
                        if (color_submode == 5) index = self.csi.carg[i][1] else if (color_submode == 2) {
                            r = self.csi.carg[i][1];
                            g = self.csi.carg[i][2];
                            b = self.csi.carg[i][3];
                        }
                    } else {
                        i += 1;
                        if (i < self.csi.narg) {
                            color_submode = self.csi.arg[i];
                            if (color_submode == 5) {
                                i += 1;
                                if (i < self.csi.narg) index = self.csi.arg[i];
                            } else if (color_submode == 2) {
                                i += 3;
                                if (i < self.csi.narg) {
                                    r = self.csi.arg[i - 2];
                                    g = self.csi.arg[i - 1];
                                    b = self.csi.arg[i];
                                }
                            }
                        }
                    }
                    if (color_submode == 5 and index >= 0 and index <= 255) self.term.c.attr.bg = @intCast(index) else if (color_submode == 2 and r != -1) self.term.c.attr.bg = (0xFF << 24) | (@as(u32, @intCast(r)) << 16) | (@as(u32, @intCast(g)) << 8) | @as(u32, @intCast(b));
                },
                49 => self.term.c.attr.bg = config.Config.colors.default_background,
                90...97 => self.term.c.attr.fg = @as(u32, @intCast(arg - 90 + 8)),
                100...107 => self.term.c.attr.bg = @as(u32, @intCast(arg - 100 + 8)),
                else => {},
            }
        }
    }

    fn newLine(self: *Parser) !void {
        if (self.term.dirty) |dirty| if (self.term.c.y < dirty.len) {
            dirty[self.term.c.y] = true;
        };
        if (self.term.c.y == self.term.bot) try self.scrollUp(self.term.top, 1) else self.term.c.y += 1;
        self.term.c.x = 0;
        if (self.term.dirty) |dirty| if (self.term.c.y < dirty.len) {
            dirty[self.term.c.y] = true;
        };
    }

    fn moveCursor(self: *Parser, dx: i32, dy: i32) !void {
        if (self.term.dirty) |dirty| if (self.term.c.y < dirty.len) {
            dirty[self.term.c.y] = true;
        };
        var new_x = @as(isize, @intCast(self.term.c.x)) + dx;
        var new_y = @as(isize, @intCast(self.term.c.y)) + dy;
        new_x = @max(0, @min(new_x, @as(isize, @intCast(self.term.col - 1))));
        new_y = @max(0, @min(new_y, @as(isize, @intCast(self.term.row - 1))));
        self.term.c.x = @as(usize, @intCast(new_x));
        self.term.c.y = @as(usize, @intCast(new_y));
        self.term.c.state = .default;
        if (self.term.dirty) |dirty| if (self.term.c.y < dirty.len) {
            dirty[self.term.c.y] = true;
        };
    }

    fn moveTo(self: *Parser, x: usize, y: usize) !void {
        if (self.term.dirty) |dirty| if (self.term.c.y < dirty.len) {
            dirty[self.term.c.y] = true;
        };
        var new_x = x;
        var new_y = y;
        if (self.term.c.state == .origin) new_y += self.term.top;
        new_x = @min(new_x, self.term.col - 1);
        new_y = @min(new_y, if (self.term.c.state == .origin) self.term.bot else self.term.row - 1);
        self.term.c.x = new_x;
        self.term.c.y = new_y;
        self.term.c.state = .default;
        if (self.term.dirty) |dirty| if (self.term.c.y < dirty.len) {
            dirty[self.term.c.y] = true;
        };
    }

    fn putTab(self: *Parser) !void {
        var x = self.term.c.x + 1;
        while (x < self.term.col) {
            if (self.term.tabs) |tabs| if (x < tabs.len and tabs[x]) break;
            x += 1;
        }
        self.term.c.x = @min(x, self.term.col - 1);
        self.term.c.state = .default;
        if (self.term.dirty) |dirty| if (self.term.c.y < dirty.len) {
            dirty[self.term.c.y] = true;
        };
    }

    fn decaln(self: *Parser) !void {
        if (self.term.line) |lines| {
            const glyph = self.term.c.attr;
            var glyph_var = glyph;
            glyph_var.u = 'E';
            for (0..self.term.row) |y| {
                for (0..self.term.col) |x| {
                    if (x < lines[y].len) {
                        lines[y][x] = glyph_var;
                    }
                }
            }
        }
        if (self.term.dirty) |dirty| {
            for (0..dirty.len) |i| {
                dirty[i] = true;
            }
        }
        try self.moveTo(0, 0);
    }

    fn resetTerminal(self: *Parser) !void {
        try self.eraseDisplay(2);
        try self.moveTo(0, 0);
        self.term.c.state = .default;
        self.term.c.attr = .{};
        self.term.c.attr.fg = config.Config.colors.default_foreground;
        self.term.c.attr.bg = config.Config.colors.default_background;
        self.term.top = 0;
        self.term.bot = self.term.row - 1;
        self.term.mode = .{ .utf8 = true, .wrap = true };
        for (0..4) |i| self.term.trantbl[i] = .usa;
        self.term.charset = 0;
        self.term.icharset = 0;
        if (self.term.tabs) |tabs| for (0..tabs.len) |i| {
            tabs[i] = (i % 8 == 0);
        };
        self.term.esc = .{};
        self.resetPalette();
        self.term.default_fg = config.Config.colors.default_foreground;
        self.term.default_bg = config.Config.colors.default_background;
        self.term.default_cs = config.Config.colors.default_cursor;
        self.term.window_title = "stz";
        self.term.window_title_dirty = true;
        for (0..2) |i| self.term.saved_cursor[i] = .{ .attr = self.term.c.attr, .x = 0, .y = 0, .state = .default, .top = 0, .bot = self.term.row - 1 };
        if (self.term.dirty) |dirty| for (0..dirty.len) |i| {
            dirty[i] = true;
        };
    }

    fn cursorSave(self: *Parser) void {
        const alt = if (self.term.mode.alt_screen) @as(usize, 1) else 0;
        self.term.saved_cursor[alt] = .{ .attr = self.term.c.attr, .x = self.term.c.x, .y = self.term.c.y, .state = self.term.c.state, .top = self.term.top, .bot = self.term.bot };
    }

    fn cursorRestore(self: *Parser) !void {
        const alt = if (self.term.mode.alt_screen) @as(usize, 1) else 0;
        const saved = self.term.saved_cursor[alt];
        self.term.c.attr = saved.attr;
        try self.moveTo(saved.x, saved.y);
        self.term.c.state = saved.state;
        self.term.top = saved.top;
        self.term.bot = saved.bot;
    }

    fn controlCode(self: *Parser, c: u8) !void {
        switch (c) {
            '\x08' => try self.moveCursor(-1, 0),
            '\x09' => try self.putTab(),
            '\x0A', '\x0B', '\x0C' => {
                try self.newLine();
                if (self.term.mode.crlf) self.term.c.x = 0;
            },
            '\x0D' => try self.moveTo(0, self.term.c.y),
            0x0E => self.term.charset = 1,
            0x0F => self.term.charset = 0,
            0x1B => {
                self.csiReset();
                self.term.esc.start = true;
            },
            0x84 => if (self.term.c.y == self.term.bot) try self.scrollUp(self.term.top, 1) else try self.moveCursor(0, 1),
            0x85 => {
                if (self.term.c.y == self.term.bot) try self.scrollUp(self.term.top, 1) else try self.moveCursor(0, 1);
                self.term.c.x = 0;
            },
            0x88 => if (self.term.c.x < self.term.col) if (self.term.tabs) |tabs| {
                tabs[self.term.c.x] = true;
            },
            0x8D => if (self.term.c.y == self.term.top) try self.scrollDown(self.term.top, 1) else try self.moveCursor(0, -1),
            0x8E => {
                self.term.esc.alt_charset = true;
                self.term.icharset = 2;
                self.term.esc.tstate = true;
            },
            0x8F => {
                self.term.esc.alt_charset = true;
                self.term.icharset = 3;
                self.term.esc.tstate = true;
            },
            0x9B => {
                self.term.esc.csi = true;
                self.term.esc.start = false;
            },
            0x90 => {
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = 'P';
            },
            0x9D => {
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = ']';
            },
            0x9E => {
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = '^';
            },
            0x9F => {
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = '_';
            },
            else => {},
        }
    }

    fn escapeHandle(self: *Parser, c: u21) !void {
        const cc: u8 = @truncate(c);
        switch (cc) {
            '[' => {
                self.term.esc.csi = true;
                self.term.esc.start = false;
            },
            'P', '_', '^', ']', 'k' => {
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = cc;
            },
            '(', ')', '*', '+' => {
                self.term.esc.alt_charset = true;
                self.term.icharset = cc - '(';
                self.term.esc.start = false;
            },
            '#' => {
                self.term.esc.decaln = true;
                self.term.esc.start = false;
            },
            '%' => {
                self.term.esc.utf8 = true;
                self.term.esc.start = false;
            },
            'G' => if (self.term.esc.utf8) {
                self.term.mode.utf8 = true;
                self.term.esc.utf8 = false;
            },
            '@' => if (self.term.esc.utf8) {
                self.term.mode.utf8 = false;
                self.term.esc.utf8 = false;
            },
            '7' => self.cursorSave(),
            '8' => if (self.term.esc.decaln) {
                try self.decaln();
                self.term.esc.decaln = false;
            } else try self.cursorRestore(),
            'n' => self.term.charset = 2,
            'o' => self.term.charset = 3,
            'D' => if (self.term.c.y == self.term.bot) try self.scrollUp(self.term.top, 1) else try self.moveCursor(0, 1),
            'E' => {
                if (self.term.c.y == self.term.bot) try self.scrollUp(self.term.top, 1) else try self.moveCursor(0, 1);
                self.term.c.x = 0;
            },
            'H' => if (self.term.c.x < self.term.col) if (self.term.tabs) |tabs| {
                tabs[self.term.c.x] = true;
            },
            'M' => if (self.term.c.y == self.term.top) try self.scrollDown(self.term.top, 1) else try self.moveCursor(0, -1),
            'Z' => self.ptyWrite("\x1B[?6c"),
            'c' => try self.resetTerminal(),
            '>' => self.term.mode.app_keypad = false,
            '=' => self.term.mode.app_keypad = true,
            '\\' => if (self.term.esc.str_end) try self.strHandle(),
            else => {},
        }
    }

    fn csiParse(self: *Parser) !void {
        var p: usize = 0;
        self.csi.narg = 0;
        self.csi.priv = 0;
        self.csi.mode[0] = 0;
        self.csi.mode[1] = 0;
        for (&self.csi.carg) |*row| for (row) |*cell| {
            cell.* = -1;
        };
        if (self.csi.len == 0) return;
        if (!std.ascii.isDigit(self.csi.buf[p]) and self.csi.buf[p] != ';' and self.csi.buf[p] != ':') {
            self.csi.priv = self.csi.buf[p];
            p += 1;
        }
        self.csi.buf[self.csi.len] = 0;
        while (p < self.csi.len) {
            if (!std.ascii.isDigit(self.csi.buf[p]) and self.csi.buf[p] != ';' and self.csi.buf[p] != ':') break;
            var val: i64 = 0;
            var has_val = false;
            while (p < self.csi.len and std.ascii.isDigit(self.csi.buf[p])) {
                val = val * 10 + @as(i64, @intCast(self.csi.buf[p] - '0'));
                p += 1;
                has_val = true;
            }
            if (!has_val) val = 0;
            if (self.csi.narg < 32) {
                self.csi.arg[self.csi.narg] = val;
                self.csi.narg += 1;
                if (p < self.csi.len and self.csi.buf[p] == ':') {
                    var ncar: usize = 0;
                    while (ncar < 16 and p < self.csi.len and self.csi.buf[p] == ':') {
                        p += 1;
                        var cval: i64 = 0;
                        var has_cval = false;
                        while (p < self.csi.len and std.ascii.isDigit(self.csi.buf[p])) {
                            cval = cval * 10 + @as(i64, @intCast(self.csi.buf[p] - '0'));
                            p += 1;
                            has_cval = true;
                        }
                        if (!has_cval) cval = 0;
                        self.csi.carg[self.csi.narg - 1][ncar] = cval;
                        ncar += 1;
                    }
                }
            } else while (p < self.csi.len and (std.ascii.isDigit(self.csi.buf[p]) or self.csi.buf[p] == ':')) p += 1;
            if (p >= self.csi.len) break;
            const sep = self.csi.buf[p];
            if (sep == ';') p += 1 else if (sep != ':') break;
        }
        if (p < self.csi.len and self.csi.buf[p] >= 0x20 and self.csi.buf[p] <= 0x2F) {
            self.csi.mode[1] = self.csi.buf[p];
            p += 1;
        }
        self.csi.mode[0] = self.csi.buf[self.csi.len - 1];
    }

    fn csiHandle(self: *Parser) !void {
        const mode = self.csi.mode[0];
        if (self.csi.narg == 0) {
            self.csi.arg[0] = 0;
            self.csi.narg = 1;
        }
        if (self.csi.mode[1] != 0) {
            switch (self.csi.mode[1]) {
                ' ' => if (mode == 'q') {
                    const style = self.csi.arg[0];
                    if (style >= 0 and style <= 8) self.term.cursor_style = @as(u8, @intCast(style));
                    return;
                },
                else => {},
            }
        }
        switch (mode) {
            '@' => try self.insertBlank(@as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'b' => if (self.term.lastc != 0) {
                for (0..@as(usize, @intCast(@max(1, self.csi.arg[0])))) |_| try self.writeChar(self.term.lastc);
            },
            'c' => if (self.csi.arg[0] == 0) {
                if (self.csi.priv == '>') self.ptyWrite("\x1B[>1;100;0c") else self.ptyWrite("\x1B[?6c");
            },
            'i' => switch (self.csi.arg[0]) {
                4 => self.term.mode.print = false,
                5 => self.term.mode.print = true,
                else => {},
            },
            'A' => try self.moveCursor(0, -@as(i32, @intCast(@max(1, self.csi.arg[0])))),
            'B', 'e' => try self.moveCursor(0, @as(i32, @intCast(@max(1, self.csi.arg[0])))),
            'C', 'a' => try self.moveCursor(@as(i32, @intCast(@max(1, self.csi.arg[0]))), 0),
            'D' => try self.moveCursor(-@as(i32, @intCast(@max(1, self.csi.arg[0]))), 0),
            'E' => try self.moveTo(0, @as(usize, @intCast(@as(i32, @intCast(self.term.c.y)) + @as(i32, @intCast(@max(1, self.csi.arg[0])))))),
            'F' => try self.moveTo(0, @as(usize, @intCast(@max(0, @as(i32, @intCast(self.term.c.y)) - @as(i32, @intCast(@max(1, self.csi.arg[0]))))))),
            'G', '`' => try self.moveTo(@as(usize, @intCast(@max(1, self.csi.arg[0]) - 1)), self.term.c.y),
            'H', 'f' => try self.moveTo(@as(usize, @intCast(@max(1, self.csi.arg[1]) - 1)), @as(usize, @intCast(@max(1, self.csi.arg[0]) - 1))),
            'I' => for (0..@as(usize, @intCast(@max(1, self.csi.arg[0])))) |_| try self.putTab(),
            'J' => try self.eraseDisplay(@truncate(self.csi.arg[0])),
            'K' => try self.eraseLine(@truncate(self.csi.arg[0])),
            'L' => try self.insertBlankLine(@as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'M' => try self.deleteLine(@as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'P' => try self.deleteChar(@as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'X' => try self.eraseChar(@as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'Z' => for (0..@as(usize, @intCast(@max(1, self.csi.arg[0])))) |_| {
                var x = self.term.c.x;
                if (x > 0) x -= 1;
                while (x > 0) : (x -= 1) if (self.term.tabs) |tabs| if (x < tabs.len and tabs[x]) break;
                self.term.c.x = x;
            },
            'd' => try self.moveTo(self.term.c.x, @as(usize, @intCast(@max(1, self.csi.arg[0]) - 1))),
            'S' => if (self.csi.priv == 0) try self.scrollUp(self.term.top, @as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'T' => try self.scrollDown(self.term.top, @as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'h' => try self.setMode(true),
            'l' => try self.setMode(false),
            'm' => try self.setGraphicsMode(),
            'n' => switch (self.csi.arg[0]) {
                5 => self.ptyWrite("\x1B[0n"),
                6 => {
                    var buf: [64]u8 = undefined;
                    const s = try std.fmt.bufPrint(&buf, "\x1B[{d};{d}R", .{ self.term.c.y + 1, self.term.c.x + 1 });
                    self.ptyWrite(s);
                },
                else => {},
            },
            'r' => try self.setScrollRegion(),
            's' => try self.cursorSaveRestore(.save),
            'u' => if (self.csi.priv == 0) try self.cursorSaveRestore(.load),
            else => {},
        }
    }

    fn setScrollRegion(self: *Parser) !void {
        if (self.csi.priv != 0) return;
        const top = @max(0, @min(@as(i32, @intCast(if (self.csi.narg > 0 and self.csi.arg[0] > 0) self.csi.arg[0] else 1)) - 1, @as(i32, @intCast(self.term.row)) - 1));
        const bot = @max(0, @min(@as(i32, @intCast(if (self.csi.narg > 1 and self.csi.arg[1] > 0) self.csi.arg[1] else @as(i64, @intCast(self.term.row)))) - 1, @as(i32, @intCast(self.term.row)) - 1));
        self.term.top = @as(usize, @intCast(@min(top, bot)));
        self.term.bot = @as(usize, @intCast(@max(top, bot)));
        try self.moveTo(0, 0);
    }

    fn cursorSaveRestore(self: *Parser, mode: types.CursorMove) !void {
        const alt = @intFromBool(self.term.mode.alt_screen);
        if (mode == .save) self.term.saved_cursor[alt] = .{ .attr = self.term.c.attr, .x = self.term.c.x, .y = self.term.c.y, .state = self.term.c.state, .top = self.term.top, .bot = self.term.bot } else {
            const s = self.term.saved_cursor[alt];
            self.term.c.attr = s.attr;
            try self.moveTo(s.x, s.y);
            self.term.c.state = s.state;
            self.term.top = s.top;
            self.term.bot = s.bot;
        }
    }

    fn swapScreen(self: *Parser) !void {
        if (self.term.line == null or self.term.alt == null) return;
        const tmp = self.term.line.?;
        self.term.line = self.term.alt;
        self.term.alt = tmp;
        self.term.mode.alt_screen = !self.term.mode.alt_screen;
        if (self.term.dirty) |dirty| for (0..dirty.len) |i| {
            dirty[i] = true;
        };
    }

    fn setMode(self: *Parser, set: bool) !void {
        if (self.csi.priv == 0) switch (self.csi.arg[0]) {
            2 => self.term.mode.kbdlock = set,
            4 => self.term.mode.insert = set,
            12 => self.term.mode.echo = !set,
            20 => self.term.mode.crlf = set,
            else => {},
        } else switch (self.csi.arg[0]) {
            1 => self.term.mode.app_cursor = set,
            5 => {
                self.term.mode.reverse = set;
                if (self.term.dirty) |dirty| for (0..dirty.len) |i| {
                    dirty[i] = true;
                };
            },
            6 => {
                if (set) {
                    self.term.c.state = .origin;
                    try self.moveTo(0, 0);
                } else self.term.c.state = .default;
            },
            7 => self.term.mode.wrap = set,
            25 => self.term.mode.hide_cursor = !set,
            1000 => self.term.mode.mouse = set,
            1002 => self.term.mode.mouse_btn = set,
            1003 => self.term.mode.mouse_many = set,
            1004 => self.term.mode.focused_report = set,
            1006 => self.term.mode.mouse_sgr = set,
            2026 => self.term.mode.sync_update = set,
            47, 1047 => if (self.term.alt != null and set != self.term.mode.alt_screen) try self.swapScreen(),
            1048 => try self.cursorSaveRestore(if (set) .save else .load),
            1049 => {
                try self.cursorSaveRestore(if (set) .save else .load);
                if (self.term.alt != null) {
                    if (set and !self.term.mode.alt_screen) {
                        if (self.term.alt) |alt| {
                            var g = self.term.c.attr;
                            g.u = ' ';
                            for (alt) |l| {
                                for (l) |*cell| {
                                    cell.* = g;
                                }
                            }
                        }
                        try self.swapScreen();
                        try self.moveTo(0, 0);
                    } else if (!set and self.term.mode.alt_screen) {
                        try self.swapScreen();
                        try self.cursorSaveRestore(.load);
                    }
                }
            },
            else => {},
        }
    }

    fn strHandle(self: *Parser) !void {
        self.term.esc.str = false;
        self.term.esc.str_end = false;
        try self.strParse();
        const par = if (self.str.narg > 0) std.fmt.parseInt(i32, self.str.args[0], 10) catch 0 else 0;
        switch (self.str.type) {
            ']' => try self.oscHandle(par),
            'P' => {}, // DCS
            'k' => {}, // Title
            else => {},
        }
    }

    fn oscHandle(self: *Parser, par: i32) !void {
        switch (par) {
            0, 1, 2 => if (self.str.narg > 1 and self.str.args[1].len > 0) {
                self.term.window_title = self.str.args[1];
                self.term.window_title_dirty = true;
            },
            10 => if (self.str.narg >= 2) if (try self.parseOscColor(self.str.args[1])) |c| {
                self.term.default_fg = c;
            },
            11 => if (self.str.narg >= 2) if (try self.parseOscColor(self.str.args[1])) |c| {
                self.term.default_bg = c;
            },
            12 => if (self.str.narg >= 2) if (try self.parseOscColor(self.str.args[1])) |c| {
                self.term.default_cs = c;
            },
            else => {},
        }
    }

    fn parseOscColor(self: *Parser, color_str: []const u8) !?u32 {
        _ = self;
        var start: usize = 0;
        while (start < color_str.len and color_str[start] == ' ') : (start += 1) {}

        if (start >= color_str.len) return null;
        const trimmed = color_str[start..];

        if (std.mem.startsWith(u8, trimmed, "rgb:")) {
            var parts = std.mem.splitScalar(u8, trimmed[4..], '/');
            var rgb = [3]u8{ 0, 0, 0 };
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                if (parts.next()) |p| {
                    rgb[i] = std.fmt.parseInt(u8, p, 16) catch 0;
                }
            }
            return (0xFF << 24) | (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | @as(u32, rgb[2]);
        }
        if (trimmed[0] == '#' and trimmed.len >= 7) return (0xFF << 24) | (std.fmt.parseInt(u32, trimmed[1..7], 16) catch 0);
        if (std.ascii.isDigit(trimmed[0])) return @as(u32, @intCast(std.fmt.parseInt(usize, trimmed, 10) catch 0));
        return null;
    }

    fn resetPalette(self: *Parser) void {
        for (0..8) |i| self.term.palette[i] = config.Config.colors.normal[i];
        for (8..16) |i| self.term.palette[i] = config.Config.colors.bright[i - 8];
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
        var gray_idx: u32 = 232;
        var gray_val: u32 = 8;
        while (gray_idx < 256) : (gray_idx += 1) {
            self.term.palette[gray_idx] = gray_val * 0x010101;
            gray_val += 10;
        }
    }

    fn strParse(self: *Parser) !void {
        var start: usize = 0;
        self.str.narg = 0;
        if (self.str.len >= self.str.siz) return;
        self.str.buf[self.str.len] = 0;
        while (self.str.narg < 16 and start < self.str.len) {
            const arg_start = start;
            while (start < self.str.len and self.str.buf[start] != 0 and self.str.buf[start] != ';') start += 1;
            self.str.args[self.str.narg] = self.str.buf[arg_start..start];
            if (start < self.str.len and self.str.buf[start] == ';') start += 1;
            self.str.narg += 1;
        }
    }

    fn strPut(self: *Parser, c: u21) !void {
        if (self.str.len + 4 >= self.str.siz) {
            const ns = self.str.siz * 2;
            self.str.buf = try self.allocator.realloc(self.str.buf, ns);
            self.str.siz = ns;
        }
        var b: [4]u8 = undefined;
        const l = try @import("unicode.zig").encode(c, &b);
        for (b[0..l], 0..) |ch, i| self.str.buf[self.str.len + i] = ch;
        self.str.len += l;
    }

    fn strReset(self: *Parser) !void {
        if (self.str.buf.len == 0) {
            self.str.buf = try self.allocator.alloc(u8, 1024);
            self.str.siz = 1024;
        }
        self.str.len = 0;
        self.str.narg = 0;
    }

    fn csiReset(self: *Parser) void {
        const bytes = @as([*]u8, @ptrCast(&self.csi));
        for (0..@sizeOf(CSIEscape)) |i| bytes[i] = 0;
    }
};
