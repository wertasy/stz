//! 终端转义序列解析器
//! 解析 ANSI/VT100/VT220 转义序列

const std = @import("std");
const types = @import("types.zig");

const Term = types.Term;
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

    pub fn init(term: *Term, allocator: std.mem.Allocator) !Parser {
        var p = Parser{
            .term = term,
            .allocator = allocator,
        };
        try p.strReset();
        return p;
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
                !self.term.esc.utf8 and !self.term.esc.tstate)
            {
                self.term.esc = .{};
            }
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
                    var dummy = self.term.c.attr;
                    dummy.u = 0;
                    dummy.attr.wide_dummy = true;
                    lines[self.term.c.y][self.term.c.x - 1] = dummy;
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

        const scroll_lines = @min(n, self.term.bot - self.term.c.y + 1);
        if (scroll_lines == 0) return;

        if (self.term.line) |lines| {
            // 滚动现有内容向下
            var y = self.term.bot;
            while (y >= self.term.c.y + scroll_lines) : (y -= 1) {
                if (y < lines.len and y - scroll_lines < lines.len) {
                    @memcpy(lines[y], lines[y - scroll_lines]);
                }
            }
            // 插入新行
            var i: usize = 0;
            while (i < scroll_lines) : (i += 1) {
                const insert_y = self.term.c.y + i;
                if (insert_y < lines.len) {
                    var j: usize = 0;
                    while (j < self.term.col) : (j += 1) {
                        var glyph = self.term.c.attr;
                        glyph.u = ' ';
                        lines[insert_y][j] = glyph;
                    }
                }
            }
        }

        // 设置脏标记
        if (self.term.dirty) |dirty| {
            var row = self.term.c.y;
            while (row <= self.term.bot) : (row += 1) {
                if (row < dirty.len) dirty[row] = true;
            }
        }
    }

    /// 删除行
    fn deleteLine(self: *Parser, n: usize) !void {
        if (self.term.c.y < self.term.top or self.term.c.y > self.term.bot) {
            return;
        }

        const scroll_lines = @min(n, self.term.bot - self.term.c.y + 1);
        if (scroll_lines == 0) return;

        if (self.term.line) |lines| {
            // 向上滚动内容
            var y = self.term.c.y;
            while (y + scroll_lines <= self.term.bot) : (y += 1) {
                if (y < lines.len and y + scroll_lines < lines.len) {
                    @memcpy(lines[y], lines[y + scroll_lines]);
                }
            }
            // 清除底部行
            var i: usize = 0;
            while (i < scroll_lines) : (i += 1) {
                const clear_y = self.term.bot - i + 1;
                if (clear_y < lines.len) {
                    var j: usize = 0;
                    while (j < self.term.col) : (j += 1) {
                        var glyph = self.term.c.attr;
                        glyph.u = ' ';
                        lines[clear_y][j] = glyph;
                    }
                }
            }
        }

        // 设置脏标记
        if (self.term.dirty) |dirty| {
            var row = self.term.c.y;
            while (row <= self.term.bot) : (row += 1) {
                if (row < dirty.len) dirty[row] = true;
            }
        }
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
                    self.term.c.attr.fg = 7; // 默认白色
                    self.term.c.attr.bg = 0; // 默认黑色
                },
                1 => { // 加粗
                    self.term.c.attr.attr.bold = true;
                },
                3 => { // 斜体
                    self.term.c.attr.attr.italic = true;
                },
                4 => { // 下划线
                    self.term.c.attr.attr.underline = true;
                },
                7 => { // 反色
                    self.term.c.attr.attr.reverse = true;
                },
                22 => { // 关闭加粗
                    self.term.c.attr.attr.bold = false;
                    self.term.c.attr.attr.faint = false;
                },
                23 => { // 关闭斜体
                    self.term.c.attr.attr.italic = false;
                },
                24 => { // 关闭下划线
                    self.term.c.attr.attr.underline = false;
                },
                27 => { // 关闭反色
                    self.term.c.attr.attr.reverse = false;
                },
                9 => { // 删除线
                    self.term.c.attr.attr.struck = true;
                },
                29 => { // 关闭删除线
                    self.term.c.attr.attr.struck = false;
                },
                else => {
                    // 处理颜色
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
        self.term.c.y += 1;
        if (self.term.c.y > self.term.bot) {
            self.term.c.y = self.term.bot;
            if (self.term.line) |lines| {
                // 滚动屏幕
                var y = self.term.top;
                while (y < self.term.bot) : (y += 1) {
                    if (y + 1 < lines.len) {
                        @memcpy(lines[y], lines[y + 1]);
                    }
                }
                // 清除最后一行
                var clear_glyph = self.term.c.attr;
                clear_glyph.u = ' ';
                for (0..self.term.col) |x| {
                    lines[self.term.bot][x] = clear_glyph;
                }
            }
        }
    }

    /// 移动光标
    fn moveCursor(self: *Parser, dx: i32, dy: i32) !void {
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
            0x1B => { // ESC
                self.csiReset();
                self.term.esc.start = true;
                self.term.esc.csi = false;
                self.term.esc.str = false;
                self.term.esc.alt_charset = false;
                self.term.esc.tstate = false;
                self.term.esc.utf8 = false;
                self.term.esc.str_end = false;
            },
            0x84 => { // IND - 向下滚动一行
                // 滚动
            },
            0x88 => { // HTS - 设置水平制表符
                if (self.term.c.x < self.term.col) {
                    if (self.term.tabs) |tabs| {
                        tabs[self.term.c.x] = true;
                    }
                }
            },
            0x9B => { // CSI
                self.term.esc.csi = true;
                self.term.esc.start = false;
            },
            0x90 => { // DCS
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = 'P';
            },
            0x9D => { // OSC
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = ']';
            },
            0x9E => { // PM
                self.term.esc.str = true;
                self.term.esc.start = false;
                self.csiReset();
                self.str.type = '^';
            },
            0x9F => { // APC
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
            'D' => { // IND - 向下滚动
                // 滚动一行
            },
            'E' => { // NEL - 下一行
                // 移动到下一行开头
            },
            'H' => { // HTS
                // 设置制表符
            },
            'M' => { // RI - 向上滚动
                // 向上滚动一行
            },
            'Z' => { // DECID - 终端识别
                // 发送设备属性
            },
            'c' => { // RIS - 重置终端
                // 重置终端
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
        self.csi.priv = 0; // 重置 private 标志

        // 检查私有标志 '?'
        if (p < self.csi.len and self.csi.buf[p] == '?') {
            self.csi.priv = 1;
            p += 1;
        }

        self.csi.buf[self.csi.len] = 0;

        while (p < self.csi.len and self.csi.narg < 32) {
            // 跳过非数字
            while (p < self.csi.len and !std.ascii.isDigit(self.csi.buf[p]) and self.csi.buf[p] != ';' and self.csi.buf[p] != ':') {
                // 如果遇到终止字符，停止解析
                if (self.csi.buf[p] >= 0x40 and self.csi.buf[p] <= 0x7E) break;
                p += 1;
            }

            if (p >= self.csi.len) break;

            // 解析数字
            var val_end = p;
            while (val_end < self.csi.len and std.ascii.isDigit(self.csi.buf[val_end])) {
                val_end += 1;
            }

            if (val_end > p) {
                const v = std.fmt.parseInt(i64, self.csi.buf[p..val_end], 10) catch 0;
                self.csi.arg[self.csi.narg] = v;
                p = val_end;
            } else {
                // 默认值 0
                self.csi.arg[self.csi.narg] = 0;
            }
            self.csi.narg += 1;

            // 处理分隔符
            if (p < self.csi.len and (self.csi.buf[p] == ';' or self.csi.buf[p] == ':')) {
                p += 1;
            }
        }

        // 获取模式字符 (最后一个字符)
        if (self.csi.len > 0) {
            self.csi.mode[0] = self.csi.buf[self.csi.len - 1];
        }
    }

    /// 处理 CSI 序列
    fn csiHandle(self: *Parser) !void {
        const mode = self.csi.mode[0];

        // 如果没有参数，设置默认值 0
        if (self.csi.narg == 0) {
            self.csi.arg[0] = 0;
            self.csi.narg = 1;
        }

        switch (mode) {
            '@' => { // ICH - 插入空字符
                const n = @as(usize, @intCast(@max(1, self.csi.arg[0])));
                try self.insertBlank(n);
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
                try self.putTab();
                // 后退 n-1 次
                var i: i32 = 1;
                while (i < n) : (i += 1) {
                    try self.putTab();
                }
            },
            'd' => { // VPA - 垂直位置绝对
                const row = @max(1, self.csi.arg[0]) - 1;
                try self.moveTo(self.term.c.x, row);
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
                        // TODO: 报告 OK - 需要 PTY 写入功能
                    },
                    6 => { // 光标位置
                        // TODO: 报告光标位置 - 需要 PTY 写入功能
                    },
                    else => {},
                }
            },
            'r' => { // DECSTBM - 设置滚动区域
                // TODO: 需要修复类型转换问题
            },
            's' => { // DECSC - 保存光标
                // TODO: 保存光标位置和属性
            },
            'u' => { // DECRC - 恢复光标
                // TODO: 恢复光标位置和属性
            },
            else => {},
        }
    }

    /// 设置终端模式
    fn setMode(self: *Parser, set: bool) !void {
        if (self.csi.priv == 0) {
            // 非私有模式
            switch (self.csi.arg[0]) {
                4 => self.term.mode.insert = set,
                20 => self.term.mode.crlf = set,
                else => {},
            }
        } else {
            // DEC 私有模式
            switch (self.csi.arg[0]) {
                1 => self.term.mode.app_cursor = set,
                5 => {}, // TODO: reverse mode not implemented
                6 => {
                    self.term.c.state = .origin;
                },
                7 => self.term.mode.wrap = set,
                25 => self.term.mode.hide_cursor = !set,
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
            10 => { // 设置前景颜色
                if (self.str.narg >= 2) {
                    // TODO: 解析颜色并设置前景色
                }
            },
            11 => { // 设置背景颜色
                if (self.str.narg >= 2) {
                    // TODO: 解析颜色并设置背景色
                }
            },
            12 => { // 设置光标颜色
                if (self.str.narg >= 2) {
                    // TODO: 解析颜色并设置光标颜色
                }
            },
            4 => { // 设置调色板颜色
                if (self.str.narg >= 3) {
                    // TODO: 设置调色板索引颜色
                }
            },
            104 => { // 重置调色板颜色
                // TODO: 重置调色板颜色
            },
            110, 111, 112 => { // 重置前景/背景/光标颜色
                // TODO: 重置到默认值
            },
            else => {},
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
