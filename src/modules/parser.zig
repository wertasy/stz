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
            try self.controlCode(@as(u8, c));
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
            if (self.csi.len >= @sizeOf(self.csi.buf) - 1) {
                self.csiReset();
                self.term.esc = .{};
                return;
            }
            self.csi.buf[self.csi.len] = @as(u8, c);
            self.csi.len += 1;

            // 检查序列是否完成
            if ((c >= 0x40 and c <= 0x7E) or self.csi.len >= @sizeOf(self.csi.buf) - 1) {
                self.term.esc = .{};
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

        // 普通字符 - 由 terminal 模块处理
        self.term.lastc = c;
    }

    /// 处理控制字符
    fn controlCode(self: *Parser, c: u8) !void {
        switch (c) {
            '\x08' => { // BS - 退格
                // 由 terminal 处理
            },
            '\x09' => { // HT - 水平制表符
                // 由 terminal 处理
            },
            '\x0A', '\x0B', '\x0C' => { // LF, VT, FF - 换行
                // 由 terminal 处理
            },
            '\x0D' => { // CR - 回车
                // 由 terminal 处理
            },
            '\x07' => { // BEL - 响铃
                // 由 window 处理
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
        const cc = @as(u8, c);
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
        var np: [*]const u8 = &self.csi.buf;

        self.csi.narg = 0;
        if (self.csi.buf[0] == '?') {
            self.csi.priv = 1;
            p += 1;
            np += 1;
        }

        self.csi.buf[self.csi.len] = 0;

        while (p < self.csi.len and self.csi.narg < 32) {
            const v = std.fmt.parseInt(i64, std.mem.span(np), 10) catch 0;
            self.csi.arg[self.csi.narg] = v;
            self.csi.narg += 1;

            while (p < self.csi.len and self.csi.buf[p] != ';' and self.csi.buf[p] != ':') {
                p += 1;
            }

            if (p < self.csi.len) {
                p += 1;
                np += 1;
            }
        }

        if (self.csi.narg < 2) {
            self.csi.mode[0] = if (p < self.csi.len) self.csi.buf[p] else 0;
            self.csi.mode[1] = if (p + 1 < self.csi.len) self.csi.buf[p + 1] else 0;
        }
    }

    /// 处理 CSI 序列
    fn csiHandle(self: *Parser) !void {
        const mode = self.csi.mode[0];

        // 设置默认参数
        if (self.csi.narg == 0) {
            self.csi.arg[0] = 0;
            self.csi.narg = 1;
        }

        switch (mode) {
            '@' => { // ICH - 插入空字符
                // 插入 n 个空字符
            },
            'A' => { // CUU - 光标上移
                // 光标上移 n 行
            },
            'B' => { // CUD - 光标下移
                // 光标下移 n 行
            },
            'C' => { // CUF - 光标右移
                // 光标右移 n 列
            },
            'D' => { // CUB - 光标左移
                // 光标左移 n 列
            },
            'E' => { // CNL - 光标到下一行开头
                // 光标下移 n 行到开头
            },
            'F' => { // CPL - 光标到上一行开头
                // 光标上移 n 行到开头
            },
            'G', '`' => { // CHA, HPA - 水平位置绝对
                // 光标移到第 n 列
            },
            'H', 'f' => { // CUP, HVP - 光标位置
                const row = @as(i32, self.csi.arg[0]);
                const col = @as(i32, self.csi.arg[1]);
                _ = row;
                _ = col;
                // 光标移到 (row, col)
            },
            'J' => { // ED - 擦除显示
                switch (self.csi.arg[0]) {
                    0 => { // 从光标到屏幕末尾
                        // 清除从光标到屏幕末尾
                    },
                    1 => { // 从屏幕开头到光标
                        // 清除从屏幕开头到光标
                    },
                    2 => { // 清除整个屏幕
                        // 清除整个屏幕
                    },
                    else => {},
                }
            },
            'K' => { // EL - 擦除行
                switch (self.csi.arg[0]) {
                    0 => { // 从光标到行末
                        // 清除从光标到行末
                    },
                    1 => { // 从行首到光标
                        // 清除从行首到光标
                    },
                    2 => { // 清除整行
                        // 清除整行
                    },
                    else => {},
                }
            },
            'L' => { // IL - 插入行
                // 在光标处插入 n 行
            },
            'M' => { // DL - 删除行
                // 删除光标处的 n 行
            },
            'P' => { // DCH - 删除字符
                // 删除光标处的 n 个字符
            },
            'X' => { // ECH - 擦除字符
                // 擦除光标处的 n 个字符
            },
            'Z' => { // CBT - 光标后退制表
                // 光标后退 n 个制表符
            },
            'd' => { // VPA - 垂直位置绝对
                // 光标移到第 n 行
            },
            'h' => { // SM - 设置模式
                try self.setMode(true);
            },
            'l' => { // RM - 重置模式
                try self.setMode(false);
            },
            'm' => { // SGR - 选择图形再现
                // 设置字符属性（颜色、加粗等）
            },
            'n' => { // DSR - 设备状态报告
                switch (self.csi.arg[0]) {
                    5 => { // 设备状态
                        // 报告 OK
                    },
                    6 => { // 光标位置
                        // 报告光标位置
                    },
                    else => {},
                }
            },
            'r' => { // DECSTBM - 设置滚动区域
                const top = @as(i32, self.csi.arg[0]);
                const bot = @as(i32, self.csi.arg[1]);
                _ = top;
                _ = bot;
                // 设置滚动区域
            },
            's' => { // DECSC - 保存光标
                // 保存光标位置和属性
            },
            'u' => { // DECRC - 恢复光标
                // 恢复光标位置和属性
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
                5 => self.term.mode.reverse = set,
                6 => {
                    self.term.c.state.origin = set;
                },
                7 => self.term.mode.wrap = set,
                25 => self.term.mode.hide_cursor = !set,
                else => {},
            }
        }
    }

    /// 处理 OSC/字符串序列
    fn strHandle(self: *Parser) !void {
        switch (self.str.type) {
            ']' => { // OSC - 操作系统命令
                try self.oscHandle();
            },
            'P' => { // DCS - 设备控制字符串
                // 处理设备控制
            },
            'k' => { // 设置标题（兼容）
                // 设置窗口标题
            },
            else => {},
        }
    }

    /// 处理 OSC 序列
    fn oscHandle(self: *Parser) !void {
        if (self.str.narg == 0) return;

        const cmd = std.fmt.parseInt(i32, self.str.args[0], 10) catch 0;

        switch (cmd) {
            0, 1, 2 => { // 设置标题
                if (self.str.narg > 1) {
                    // 设置窗口标题
                }
            },
            4 => { // 设置颜色
                if (self.str.narg >= 3) {
                    // 设置颜色索引
                }
            },
            10, 11, 12 => { // 设置前景、背景、光标颜色
                if (self.str.narg >= 2) {
                    // 设置颜色
                }
            },
            104 => { // 重置颜色
                // 重置颜色
            },
            else => {},
        }
    }

    /// 解析字符串参数
    fn strParse(self: *Parser) !void {
        var p: [*]const u8 = self.str.buf;
        self.str.narg = 0;
        self.str.buf[self.str.len] = 0;

        while (self.str.narg < 16 and p[0] != 0) {
            self.str.args[self.str.narg] = p;

            while (p[0] != 0 and p[0] != ';') {
                p += 1;
            }

            if (p[0] == ';') {
                p[0] = 0;
                p += 1;
            }

            self.str.narg += 1;
        }
    }

    /// 添加字符到字符串缓冲区
    fn strPut(self: *Parser, c: u21) !void {
        if (self.str.len + 4 >= self.str.siz) {
            // 扩大缓冲区
            const new_size = self.str.siz * 2;
            const new_buf = try self.allocator.realloc(u8, self.str.buf, new_size);
            self.str.buf = new_buf;
            self.str.siz = new_size;
        }

        var utf8_buf: [4]u8 = undefined;
        const len = try @import("unicode.zig").encode(c, &utf8_buf);

        std.mem.copy(u8, self.str.buf[self.str.len..][0..len], &utf8_buf);
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
        std.mem.set(u8, 0, @as([*]u8, @ptrCast(&self.csi))[0..@sizeOf(CSIEscape)]);
    }
};
