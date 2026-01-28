//! 终端转义序列解析器
//! 解析 ANSI/VT100/VT220 转义序列
//! ## 文件概述
//! 本文件实现了终端转义序列解析器，负责解析 PTY 输出的转义序列，
//! 并执行相应的操作（如移动光标、设置颜色、清除屏幕等）。
//! ## 转义序列类型
//! 终端转义序列可以分为以下几类：
//! ### 1. 控制字符 (Control Characters)
//! - ASCII 控制字符 (0x00-0x1F, 0x7F)
//! - 例如：LF (0x0A 换行), CR (0x0D 回车), HT (0x09 制表符), BEL (0x07 铃声)
//! ### 2. CSI 序列 (Control Sequence Introducer)
//! - 格式：ESC [ Ps;Ps... 终结符
//! - 例如：ESC [ 10 ; 20 H (移动光标到第10行第20列）
//! - 例如：ESC [ 31 m (设置前景色为红色）
//! ### 3. OSC 序列 (Operating System Command)
//! - 格式：ESC ] Ps;Pt ST
//! - 例如：ESC ] 2;stz ST (设置窗口标题为 "stz"）
//! - 例如：ESC ] 4;c:red ST (设置调色板）
//! ### 4. 其他转义序列
//! - DEC 字符集选择：ESC ( 0 (选择 G0 为 graphic0)
//! - SS2/SS3：单次字符集切换
//! ## 解析流程
//! 解析器是一个状态机，根据当前状态决定如何处理每个字符：
//!
//! 1. 接收字符 → 检查是否是转义序列开始 (ESC 0x1B)
//!    ├─ 是 ESC → 进入转义模式
//!    │   ├─ 接收 [ (0x5B) → 进入 CSI 模式
//!    │   │   └─ 接收参数和终结符 → 解析并执行 CSI 命令
//!    │   ├─ 接收 ] (0x5D) → 进入 OSC 模式
//!    │   │   └─ 接收字符串和终止符 → 解析并执行 OSC 命令
//!    │   ├─ 接收 ( (0x28) 或 ) (0x29) → 进入字符集选择模式
//!    │   │   └─ 接收字符集标识符 → 设置字符集
//!    │   └─ 其他 → 执行相应的转义命令
//!    │
//!    └─ 不是 ESC → 检查是否是控制字符
//!        ├─ 是控制字符 → 执行控制操作
//!        └─ 不是控制字符 → 写入屏幕
//!
//! ## 状态机详解
//! ### EscapeState 状态字段
//! - **start**: 转义序列开始（遇到 ESC）
//! - **csi**: CSI 模式（ESC [ ...）
//! - **str**: 字符串模式（OSC、DCS 等）
//! - **alt_charset**: 字符集选择模式（等待 G0-G3 选择字符）
//! - **tstate**: 临时字符集模式（SS2、SS3 单次切换）
//! - **utf8**: UTF-8 解码状态（多字节字符解码）
//! - **str_end**: 字符串结束标志
//! - **decaln**: DECALN 测试模式（屏幕对齐测试）
//! ### 状态转换示例
//! #### 示例 1：解析 CSI 光标移动序列 "ESC [ 10 ; 20 H"
//! ```
//! 接收 ESC (0x1B):  start = true
//! 接收 [ (0x5B):   start = true, csi = true
//! 接收 1 (0x31):   累积到 csi.buf
//! 接收 0 (0x30):   累积到 csi.buf
//! 接收 ; (0x3B):   累积到 csi.buf（分隔符）
//! 接收 2 (0x32):   累积到 csi.buf
//! 接收 0 (0x30):   累积到 csi.buf
//! 接收 H (0x48):   csi = false, 执行移动光标到 (10, 20)
//! ```
//! #### 示例 2：解析 OSC 窗口标题序列 "ESC ] 2;stz BEL"
//! ```
//! 接收 ESC (0x1B):  start = true
//! 接收 ] (0x5D):   start = true, str = true
//! 接收 2 (0x32):   累积到 str.buf
//! 接收 ; (0x3B):   累积到 str.buf（分隔符）
//! 接收 s (0x73):   累积到 str.buf
//! 接收 t (0x74):   累积到 str.buf
//! 接收 z (0x7A):   累积到 str.buf
//! 接收 BEL (0x07):  str = false, str_end = true, 执行设置标题为 "stz"
//! ```
//! ## 字符集处理
//! VT100 终端支持 4 个字符集槽位（G0-G3）：
//! - **G0**: 默认字符集（通常是美国 ASCII）
//! - **G1**: 备用字符集（通常是图形字符）
//! - **G2/G3**: 额外的字符集
//! ### 常见字符集类型
//! - **usa (US ASCII)**: 标准 ASCII 字符集（0-127）
//! - **graphic0 (VT100 制表符)**: 包含制表符（如 ┌ ─ ┐ 等）
//! - **uk (UK ASCII)**: 英国 ASCII（某些符号不同）
//! - **ger (German)**: 德语字符集
//! - **fin (Finnish)**: 芬兰语字符集
//! ### 字符集切换
//! - **切换 G0**: ESC ( C (例如：ESC ( 0 设置 G0 为 graphic0）
//! - **切换 G1**: ESC ) C (例如：ESC ) 0 设置 G1 为 graphic0）
//! - **切换到 G0**: SI (Shift In, 0x0F）
//! - **切换到 G1**: SO (Shift Out, 0x0E）
//! - **单次切换到 G2**: ESC N (SS2, 0x8E）
//! - **单次切换到 G3**: ESC O (SS3, 0x8F）
//! ## VT100 图形字符映射
//! graphic0 字符集将某些 ASCII 字符映射为图形符号：
//! - 'q' (0x71) → ─ (水平线）
//! - 'x' (0x78) → │ (垂直线）
//! - 'l' (0x6C) → ┌ (左上角）
//! - 'k' (0x6B) → ┐ (右上角）
//! - 'm' (0x6D) → └ (左下角）
//! - 'j' (0x6A) → ┘ (右下角）
//! - 'n' (0x6E) → ┼ (十字交叉）
//! ### 示例：绘制边框
//! ```
//! ESC ( 0  设置 G0 为 graphic0
//! SO        切换到 G0
//! lqkxxxxxj  绘制顶边框
//! x........x  绘制两边
//! mnx.....n  绘制底边框
//! SI        切换回 G0
//! ```
//! ## 与原版 st 的对应关系
//! - Parser 结构对应 st 的 escaped 结构
//! - 所有函数与 st 的解析逻辑对齐
//! - CSI 解析参数处理与 st 的 arg parsing 一致

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const terminal = @import("terminal.zig");

const Glyph = types.Glyph;
const CSIEscape = types.CSIEscape;
const STREscape = types.STREscape;
const EscapeState = types.EscapeState;
const Charset = types.Charset;
const Terminal = terminal.Terminal;
const PTY = @import("pty.zig").PTY;

pub const ParserError = error{
    InvalidEscape,
    BufferOverflow,
};

/// 解析转义序列
pub const Parser = struct {
    term: *Terminal,
    csi: CSIEscape = .{},
    str: STREscape = .{},
    allocator: std.mem.Allocator,
    pty: ?*PTY = null, // PTY 引用，用于发送响应
    utf8_buf: [4]u8 = .{0} ** 4, // UTF-8 解码缓冲区
    utf8_len: u8 = 0, // 缓冲区中当前字节数

    pub fn init(term: *Terminal, pty: ?*PTY, allocator: std.mem.Allocator) !Parser {
        var p = Parser{
            .term = term,
            .allocator = allocator,
            .pty = pty,
            .utf8_buf = .{0} ** 4,
            .utf8_len = 0,
        };
        try p.strReset();
        p.resetPalette();
        return p;
    }

    /// 写入数据到 PTY
    fn ptyWrite(self: *Parser, data: []const u8) void {
        _ = self.pty.?.write(data) catch {};
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.str.buf);
    }

    /// 处理输入字节
    pub fn processBytes(self: *Parser, bytes: []const u8) !void {
        const unicode = @import("unicode.zig");
        // std.log.debug("Input bytes: {X}", .{bytes});

        var i: usize = 0;

        // 1. 处理缓冲区中剩余的字节
        if (self.utf8_len > 0) {
            // 尝试从新数据中填充缓冲区
            const needed = 4 - self.utf8_len;
            const available = @min(needed, bytes.len);
            @memcpy(self.utf8_buf[self.utf8_len..][0..available], bytes[0..available]);

            // 检查组合后的数据是否构成有效字符
            const combined_len = self.utf8_len + @as(u8, @intCast(available));
            const char_len = unicode.utf8ByteLength(self.utf8_buf[0]);

            if (char_len > 0 and combined_len >= char_len) {
                // 解码成功
                const codepoint = unicode.decode(self.utf8_buf[0..char_len]) catch |err| {
                    std.log.warn("Buffered UTF-8 decode failed: {}", .{err});
                    return try self.putc(unicode.REPLACEMENT_CHARACTER);
                };
                try self.putc(codepoint);
                self.utf8_len = 0;
                i = available - (combined_len - char_len); // 调整 i，减去多读的字节（如果有）
            } else if (available == bytes.len) {
                // 数据不够，继续缓冲
                self.utf8_len += @intCast(available);
                return;
            } else {
                // 缓冲区已满但仍无法解码（异常情况）
                try self.putc(unicode.REPLACEMENT_CHARACTER);
                self.utf8_len = 0;
                i = 0; // 从 bytes[0] 重新开始
            }
        }

        while (i < bytes.len) {
            const byte_len = unicode.utf8ByteLength(bytes[i]);

            // 如果是无效字节，发送替换字符并跳过
            if (byte_len == 0) {
                try self.putc(unicode.REPLACEMENT_CHARACTER);
                i += 1;
                continue;
            }

            // 如果剩余数据不足以构成一个字符，保存到缓冲区
            if (i + byte_len > bytes.len) {
                const remaining = bytes.len - i;
                @memcpy(self.utf8_buf[0..remaining], bytes[i..]);
                self.utf8_len = @intCast(remaining);
                break;
            }

            // 解码 Unicode 字符
            const codepoint = unicode.decode(bytes[i..@min(i + 4, bytes.len)]) catch |err| {
                std.log.warn("UTF-8 decode failed at index {d}: {}", .{ i, err });
                try self.putc(unicode.REPLACEMENT_CHARACTER);
                i += 1;
                continue;
            };

            // 发送字符给解析器
            try self.putc(codepoint);
            i += byte_len;
        }
    }

    /// 处理单个字符
    pub fn putc(self: *Parser, c: u21) !void {
        // 收到任何输入时，如果是正在查看历史，则自动跳回底部 (st 对齐)
        if (self.term.scroll > 0) {
            self.term.scroll = 0;
            if (self.term.dirty) |dirty| {
                for (0..dirty.len) |i| dirty[i] = true;
            }
        }

        // CAN (0x18) 和 SUB (0x1A) 立即中断任何转义序列
        if (c == 0x18 or c == 0x1A) {
            self.term.esc = .{};
            self.csiReset();
            try self.strReset();
            return;
        }

        const control = (c < 32 or c == 0x7F) or (c >= 0x80 and c <= 0x9F);

        // 处理字符串序列（OSC、DCS 等）
        if (self.term.esc.str) {
            // STR 终止符：BEL (0x07), CAN (0x18), SUB (0x1A), ESC (0x1B), ST (0x9C), C1 controls (0x80-0x9F)
            // 对齐 st.c 2602-2603: if (u == '\a' || u == 030 || u == 032 || u == 033 || ISCONTROLC1(u))
            if (c == '\x07' or c == 0x18 or c == 0x1A or c == 0x1B or c == 0x9C or
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
            // 在 UTF-8 模式下忽略 C1 控制字符 (0x80-0x9F)
            // 匹配 st 的行为：IS_SET(MODE_UTF8) && ISCONTROLC1(u)
            if (self.term.mode.utf8 and c >= 0x80 and c <= 0x9F) {
                return;
            }
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
                return; // 明确返回，防止后续字符处理
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

    /// 写入字符到屏幕（应用字符集转换）
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

        try self.term.writeChar(codepoint);
    }
    /// 擦除显示区域
    /// 清除区域
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
                    self.term.c.attr.fg = config.colors.default_foreground_idx;
                    self.term.c.attr.bg = config.colors.default_background_idx;
                    self.term.c.attr.ustyle = -1;
                    for (0..3) |j| self.term.c.attr.ucolor[j] = -1;
                },
                1 => self.term.c.attr.attr.bold = true,
                2 => self.term.c.attr.attr.faint = true,
                3 => self.term.c.attr.attr.italic = true,
                4 => {
                    self.term.c.attr.attr.underline = true;
                    // Check for colon argument (4:x)
                    const sub = self.csi.carg[i][0];
                    if (sub != -1) {
                        self.term.c.attr.ustyle = @intCast(sub);
                    } else {
                        self.term.c.attr.ustyle = 1; // Default to single underline
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
                39 => self.term.c.attr.fg = config.colors.default_foreground_idx,
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
                49 => self.term.c.attr.bg = config.colors.default_background_idx,
                58 => {
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
                    if (color_submode == 5 and index >= 0 and index <= 255) {
                        const pal = self.term.palette[@intCast(index)];
                        self.term.c.attr.ucolor[0] = @intCast((pal >> 16) & 0xFF);
                        self.term.c.attr.ucolor[1] = @intCast((pal >> 8) & 0xFF);
                        self.term.c.attr.ucolor[2] = @intCast(pal & 0xFF);
                    } else if (color_submode == 2 and r != -1) {
                        self.term.c.attr.ucolor[0] = @intCast(r);
                        self.term.c.attr.ucolor[1] = @intCast(g);
                        self.term.c.attr.ucolor[2] = @intCast(b);
                    }
                },
                59 => {
                    self.term.c.attr.ucolor[0] = -1;
                    self.term.c.attr.ucolor[1] = -1;
                    self.term.c.attr.ucolor[2] = -1;
                },
                90...97 => self.term.c.attr.fg = @as(u32, @intCast(arg - 90 + 8)),
                100...107 => self.term.c.attr.bg = @as(u32, @intCast(arg - 100 + 8)),
                else => {
                    std.log.debug("未处理的 SGR 参数: {d}", .{arg});
                },
            }
        }
    }

    fn setCursor(self: *Parser, x: usize, y: usize) !void {
        var new_y = y;
        if (self.term.c.state.origin) {
            new_y += self.term.top;
        }
        try self.term.moveTo(x, new_y);
    }

    // Reference: tmoveto(int x, int y) from st.c
    // {
    //     int miny, maxy;
    //
    //     if (term.c.state & CURSOR_ORIGIN) {
    //         miny = term.top;
    //         maxy = term.bot;
    //     } else {
    //         miny = 0;
    //         maxy = term.row - 1;
    //     }
    //     term.c.state &= ~CURSOR_WRAPNEXT;
    //     term.c.x = LIMIT(x, 0, term.col-1);
    //     term.c.y = LIMIT(y, miny, maxy);
    // }
    fn decaln(self: *Parser) !void {
        if (self.term.screen) |lines| {
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
        try self.term.moveTo(0, 0);
    }

    pub fn resetTerminal(self: *Parser) !void {
        try self.term.eraseDisplay(2);
        try self.term.moveTo(0, 0);
        self.term.c.state = .{};
        self.term.c.attr = .{};
        self.term.c.attr.fg = config.colors.default_foreground_idx;
        self.term.c.attr.bg = config.colors.default_background_idx;
        self.term.top = 0;
        self.term.bot = self.term.row - 1;
        self.term.mode = .{ .utf8 = true, .wrap = true };
    }

    fn cursorSave(self: *Parser) void {
        const alt = if (self.term.mode.alt_screen) @as(usize, 1) else 0;
        self.term.saved_cursor[alt] = .{
            .attr = self.term.c.attr,
            .x = self.term.c.x,
            .y = self.term.c.y,
            .state = self.term.c.state,
            .trantbl = self.term.trantbl,
            .charset = self.term.charset,
        };
    }

    fn cursorRestore(self: *Parser) !void {
        const alt = if (self.term.mode.alt_screen) @as(usize, 1) else 0;
        const saved = self.term.saved_cursor[alt];
        self.term.c.attr = saved.attr;
        self.term.c.state = saved.state;
        try self.term.moveTo(saved.x, saved.y);
        self.term.trantbl = saved.trantbl;
        self.term.charset = saved.charset;
        // Restore charset handling (re-apply G0/G1 etc logic if needed, but simple assignment is enough for state)
        // If we were using a translation table pointer, we'd need to update it here.
        // Currently stz uses index access to trantbl, so value copy is fine.
    }

    fn controlCode(self: *Parser, c: u8) !void {
        switch (c) {
            '\x08' => try self.term.moveCursor(-1, 0), // HT
            '\x09' => try self.term.putTab(),
            '\x0A', '\x0B', '\x0C' => try self.term.newLine(self.term.mode.crlf), // LF LF VT
            '\x0D' => try self.term.moveTo(0, self.term.c.y), // CR
            0x07 => { // BEL
                // TODO: 实现响铃 (XBell)
                // 目前仅忽略以避免日志刷屏
            },
            0x0E => self.term.charset = 1,
            0x0F => self.term.charset = 0,
            0x1B => { // ESC
                self.csiReset();
                self.term.esc.csi = false;
                self.term.esc.alt_charset = false;
                self.term.esc.test_mode = false;
                self.term.esc.start = true;
            },
            0x84 => try self.term.newLine(false), // IND
            0x85 => try self.term.newLine(true), // NEL
            0x88 => if (self.term.c.x < self.term.col) if (self.term.tabs) |tabs| {
                tabs[self.term.c.x] = true;
            },
            0x8D => { // RI
                if (self.term.c.y == self.term.top) {
                    try self.term.scrollDown(self.term.top, 1);
                } else {
                    try self.term.moveCursor(0, -1);
                }
                self.term.c.state.wrap_next = false;
            },
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
            else => {
                std.log.debug("忽略的控制字符: 0x{x}", .{c});
            },
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
                try self.strReset();
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
            '7' => self.term.saveCursorState(),
            '8' => if (self.term.esc.decaln) {
                try self.term.decaln();
                self.term.esc.decaln = false;
            } else try self.term.restoreCursorState(),
            'n' => self.term.charset = 2,
            'o' => self.term.charset = 3,
            'D' => try self.term.newLine(false), // IND
            'E' => try self.term.newLine(true), // NEL
            'H' => if (self.term.c.x < self.term.col) if (self.term.tabs) |tabs| {
                tabs[self.term.c.x] = true;
            },
            'M' => { // RI
                if (self.term.c.y == self.term.top) {
                    try self.term.scrollDown(self.term.top, 1);
                } else {
                    try self.term.moveCursor(0, -1);
                }
                self.term.c.state.wrap_next = false;
            },
            'Z' => self.ptyWrite("\x1B[?6c"),
            'c' => try self.resetTerminal(),
            '>' => self.term.mode.app_keypad = false,
            '=' => self.term.mode.app_keypad = true,
            '\\' => if (self.term.esc.str_end) try self.strHandle(),
            else => {
                std.log.debug("未处理的转义序列: {u} (0x{x})", .{ c, c });
            },
        }
    }

    fn setScrollRegion(self: *Parser) !void {
        const t: usize = if (self.csi.narg > 0 and self.csi.arg[0] > 0) @as(usize, @intCast(self.csi.arg[0])) else 1;
        const b: usize = if (self.csi.narg > 1 and self.csi.arg[1] > 0) @as(usize, @intCast(self.csi.arg[1])) else self.term.row;

        try self.term.setScrollRegion(t - 1, b - 1);
    }

    fn cursorSaveRestore(self: *Parser, mode: types.CursorMove) !void {
        if (mode == .save) {
            self.term.saveCursorState();
        } else {
            try self.term.restoreCursorState();
        }
    }

    fn swapScreen(self: *Parser) !void {
        try self.term.swapScreen();
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
        // Check for private marker (<, =, >, ?)
        // Standard defines 0x3C-0x3F as private parameter bytes (markers)
        if (self.csi.buf[p] >= 0x3C and self.csi.buf[p] <= 0x3F) {
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

        // Debug logging for CSI sequences
        // std.log.debug("CSI Handle: mode={c} private={c} args={any}", .{ mode, if (self.csi.priv != 0) self.csi.priv else ' ', self.csi.arg[0..self.csi.narg] });

        if (self.csi.mode[1] != 0) {
            switch (self.csi.mode[1]) {
                ' ' => if (mode == 'q') {
                    // DECSCUSR - Set Cursor Style
                    const style = self.csi.arg[0];
                    if (style == 0) {
                        self.term.cursor_style = config.cursor.style;
                    } else if (style >= 1 and style <= 8) {
                        self.term.cursor_style = @as(types.CursorStyle, @enumFromInt(@as(u8, @intCast(style))));
                    }
                    return;
                },
                '!' => if (mode == 'p') {
                    // DECSTR - Soft Terminal Reset
                    try self.resetTerminal();
                    return;
                },
                '$' => if (mode == 'p') {
                    // DECRQM (Request Mode) - CSI Pa $ p
                    // If we reach here, priv is not '$' (priv is handled in csiParse logic for start chars)
                    // The '$' is intermediate.
                    // This handles DECRQM (ANSI) where priv==0 and mode[1]=='$'
                    // or DECRQM (Private) where priv=='?' and mode[1]=='$'

                    const req_mode = self.csi.arg[0];
                    var buf: [64]u8 = undefined;
                    // Always respond with 0 (not recognized) for now to be safe and spec compliant
                    const status = 0;
                    const prefix: u8 = if (self.csi.priv == '?') '?' else 0;

                    const s = if (prefix != 0)
                        try std.fmt.bufPrint(&buf, "\x1B[{c}{d};{d}$y", .{ prefix, req_mode, status })
                    else
                        try std.fmt.bufPrint(&buf, "\x1B[{d};{d}$y", .{ req_mode, status });

                    self.ptyWrite(s);
                    return;
                },
                else => {
                    std.log.debug("未处理的 CSI 私有序列: {c}{c}", .{ self.csi.mode[1], mode });
                },
            }
        }
        switch (mode) {
            '@' => try self.term.insertBlanks(@as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'b' => if (self.term.lastc != 0) {
                for (0..@as(usize, @intCast(@max(1, self.csi.arg[0])))) |_| try self.term.writeChar(self.term.lastc);
            },
            'c' => if (self.csi.arg[0] == 0) {
                if (self.csi.priv == '>') self.ptyWrite("\x1B[>1;100;0c") else self.ptyWrite("\x1B[?6c");
            },
            'i' => switch (self.csi.arg[0]) {
                4 => self.term.mode.print = false,
                5 => self.term.mode.print = true,
                else => {
                    std.log.debug("未处理的 CSI 媒体拷贝命令: {d}", .{self.csi.arg[0]});
                },
            },
            'A' => try self.term.moveCursor(0, -@as(i32, @intCast(@max(1, self.csi.arg[0])))),
            'B', 'e' => try self.term.moveCursor(0, @as(i32, @intCast(@max(1, self.csi.arg[0])))),
            'C', 'a' => try self.term.moveCursor(@as(i32, @intCast(@max(1, self.csi.arg[0]))), 0),
            'D' => try self.term.moveCursor(-@as(i32, @intCast(@max(1, self.csi.arg[0]))), 0),
            'E' => try self.term.moveTo(0, @as(usize, @intCast(@as(i32, @intCast(self.term.c.y)) + @as(i32, @intCast(@max(1, self.csi.arg[0])))))),
            'F' => try self.term.moveTo(0, @as(usize, @intCast(@max(0, @as(i32, @intCast(self.term.c.y)) - @as(i32, @intCast(@max(1, self.csi.arg[0]))))))),
            'G', '`' => try self.term.moveTo(@as(usize, @intCast(@max(1, self.csi.arg[0]) - 1)), self.term.c.y),
            'H', 'f' => try self.term.setCursor(@as(usize, @intCast(@max(1, self.csi.arg[1]) - 1)), @as(usize, @intCast(@max(1, self.csi.arg[0]) - 1))),
            'I' => for (0..@as(usize, @intCast(@max(1, self.csi.arg[0])))) |_| try self.term.putTab(),
            'J' => try self.term.clearScreen(@as(u32, @intCast(self.csi.arg[0]))),
            'K' => try self.term.clearLine(@as(u32, @intCast(self.csi.arg[0]))),
            'L' => try self.term.insertBlankLines(@as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'M' => try self.term.deleteLines(@as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'P' => try self.term.deleteChars(@as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'X' => try self.term.eraseChars(@as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'Z' => { // CBT
                for (0..@as(usize, @intCast(@max(1, self.csi.arg[0])))) |_| {
                    var x = self.term.c.x;
                    if (x > 0) x -= 1;
                    while (x > 0) : (x -= 1) if (self.term.tabs) |tabs| if (x < tabs.len and tabs[x]) break;
                    self.term.c.x = x;
                }
                self.term.c.state.wrap_next = false;
            },
            'd' => try self.term.setCursor(self.term.c.x, @as(usize, @intCast(@max(1, self.csi.arg[0]) - 1))),
            'S' => if (self.csi.priv == 0) try self.term.scrollUp(self.term.top, @as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'T' => try self.term.scrollDown(self.term.top, @as(usize, @intCast(@max(1, self.csi.arg[0])))),
            'h' => try self.setMode(true),
            'l' => try self.setMode(false),
            'm' => if (self.csi.priv == 0) {
                try self.setGraphicsMode();
            } else {
                std.log.debug("未处理的 CSI 私有序列: {c}{c}", .{ self.csi.priv, mode });
            },
            'n' => switch (self.csi.arg[0]) {
                5 => self.ptyWrite("\x1B[0n"),
                6 => {
                    var buf: [64]u8 = undefined;
                    const y = self.term.c.y + 1;
                    const s = try std.fmt.bufPrint(&buf, "\x1B[{d};{d}R", .{ y, self.term.c.x + 1 });
                    self.ptyWrite(s);
                },
                else => {
                    std.log.debug("未处理的 CSI 设备状态报告: {d}", .{self.csi.arg[0]});
                },
            },
            // 'p' => ... DECRQM is now handled in `if (self.csi.mode[1] != 0)` above
            'r' => try self.setScrollRegion(),
            's' => try self.cursorSaveRestore(.save),
            't' => switch (self.csi.arg[0]) {
                14 => { // Report window size in pixels
                    // Using fixed 800x600 for now or similar placeholder if we can't easily access Window size here
                    // Actually, we are just a parser. But terminal logic should handle this.
                    // Let's defer to ptyWrite response directly for simplicity in this iteration.
                    // Response: CSI 4 ; height ; width t
                    // We need pixel dimensions. Parser doesn't know them directly, only rows/cols.
                    // Assuming standard cell size or just stubbing to avoid error.
                    // Let's ignore or return a dummy response.
                    // For now, logging it as handled but doing nothing is better than spam.
                },
                18 => { // Report window size in chars
                    // Response: CSI 8 ; rows ; cols t
                    var buf: [64]u8 = undefined;
                    const s = try std.fmt.bufPrint(&buf, "\x1B[8;{d};{d}t", .{ self.term.row, self.term.col });
                    self.ptyWrite(s);
                },
                22, 23 => {
                    // Push/Pop window title.
                    // Implementing a stack for this is good but maybe overkill for now.
                    // Just ignoring prevents log spam.
                },
                else => {
                    std.log.debug("未处理的窗口操作: {d}", .{self.csi.arg[0]});
                },
            },
            'u' => if (self.csi.priv == 0) try self.cursorSaveRestore(.load),
            else => {
                std.log.debug("未处理的 CSI 序列: {c}{c}", .{ self.csi.mode[1], mode });
            },
        }
    }

    fn setMode(self: *Parser, set: bool) !void {
        if (self.csi.priv == 0) switch (self.csi.arg[0]) {
            2 => self.term.mode.kbdlock = set,
            4 => self.term.mode.insert = set,
            12 => self.term.mode.echo = !set,
            20 => self.term.mode.crlf = set,
            else => {
                std.log.debug("未知的模式设置 (ANSI): {d}", .{self.csi.arg[0]});
            },
        } else switch (self.csi.arg[0]) {
            1 => self.term.mode.app_cursor = set,
            5 => {
                self.term.mode.reverse = set;
                if (self.term.dirty) |dirty| for (0..dirty.len) |i| {
                    dirty[i] = true;
                };
            },
            6 => {
                self.term.c.state.origin = set;
                try self.term.moveTo(0, 0);
            },
            7 => self.term.mode.wrap = set,
            9 => self.term.mode.mouse_x10 = set, // X10 鼠标模式 (仅按下)
            12 => self.term.mode.blink = set,
            25 => self.term.mode.hide_cursor = !set,
            1000 => self.term.mode.mouse = set,
            1002 => self.term.mode.mouse_btn = set,
            1003 => self.term.mode.mouse_many = set,
            1004 => self.term.mode.mouse_focus = set,
            1005 => self.term.mode.mouse_utf8 = set,
            1006 => self.term.mode.mouse_sgr = set,
            1015 => self.term.mode.mouse_urxvt = set,
            2004 => self.term.mode.brckt_paste = set,
            2026 => self.term.mode.sync_update = set,
            47, 1047 => {
                if (self.term.alt_screen != null) {
                    const alt = self.term.mode.alt_screen;
                    if (alt) {
                        try self.term.clearScreen(2);
                    }
                    if (set != alt) {
                        try self.term.swapScreen();
                    }
                    if (set and !alt) {
                        try self.term.clearScreen(2);
                    }
                }
            },
            1048 => try self.cursorSaveRestore(if (set) .save else .load),
            1049 => {
                if (set) {
                    try self.cursorSaveRestore(.save);
                    if (self.term.alt_screen != null and !self.term.mode.alt_screen) {
                        // 进入备用屏幕时，虽然 st 是在退出时清除，但为了稳健性，
                        // 我们在进入时也确保清除（防止上次异常退出残留）
                        if (self.term.alt_screen) |alt| {
                            var g = self.term.c.attr;
                            g.u = ' ';
                            g.fg = config.colors.default_foreground_idx;
                            g.bg = config.colors.default_background_idx;
                            g.attr = .{};
                            for (alt) |l| {
                                for (l) |*cell| {
                                    cell.* = g;
                                }
                            }
                        }
                        // 重置滚动区域 (st 对齐: treset)
                        self.term.top = 0;
                        self.term.bot = self.term.row - 1;

                        try self.term.swapScreen();
                        // 移除 moveTo(0, 0)，与 st 保持一致，光标位置由应用控制
                    }
                } else {
                    if (self.term.alt_screen != null and self.term.mode.alt_screen) {
                        try self.term.clearScreen(2); // 退出前清除备用屏幕 (匹配 st 行为)
                        try self.term.swapScreen();

                        // 重置滚动区域 (st 对齐)
                        self.term.top = 0;
                        self.term.bot = self.term.row - 1;

                        try self.cursorSaveRestore(.load);
                    }
                }
            },
            else => {
                std.log.debug("未知的模式设置 (DEC): {d}", .{self.csi.arg[0]});
            },
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
            else => {
                std.log.debug("未处理的字符串序列类型: {c}", .{self.str.type});
            },
        }
    }

    fn oscHandle(self: *Parser, par: i32) !void {
        switch (par) {
            0, 1, 2 => if (self.str.narg > 1) {
                // 释放旧的窗口标题
                if (self.term.window_title.len > 0) {
                    self.allocator.free(self.term.window_title);
                }

                if (self.str.args[1].len > 0) {
                    // 设置新标题：使用 dupeZ 分配 null-terminated 副本
                    self.term.window_title = try self.allocator.dupeZ(u8, self.str.args[1]);
                } else {
                    // 空字符串：重置为默认标题 "stz"
                    self.term.window_title = try self.allocator.dupeZ(u8, "stz");
                }
                self.term.window_title_dirty = true;
            },
            // OSC 21: 报告窗口标题（作为响应，不处理）
            // Format: OSC 21 ; BEL (返回当前标题)
            21 => {},
            8 => {}, // OSC 8: 超链接（Hyperlinks）- 当前未实现
            10 => if (self.str.narg >= 2) if (try self.parseOscColor(self.str.args[1])) |c| {
                self.term.default_fg = c;
            },
            11 => if (self.str.narg >= 2) if (try self.parseOscColor(self.str.args[1])) |c| {
                self.term.default_bg = c;
            },
            12 => if (self.str.narg >= 2) if (try self.parseOscColor(self.str.args[1])) |c| {
                self.term.default_cs = c;
            },
            52 => {
                // OSC 52: Set clipboard
                // Format: OSC 52 ; Pc ; Pd ST
                // Pc: c=clipboard, p=primary, etc.
                // Pd: Base64 encoded data
                if (self.str.narg >= 2) {
                    const params = if (self.str.narg >= 3) self.str.args[1] else "c";
                    const b64_data = if (self.str.narg >= 3) self.str.args[2] else self.str.args[1];

                    if (std.mem.eql(u8, b64_data, "?")) {
                        // Query not supported for security, but we should log it
                        std.log.info("OSC 52: Clipboard query ignored (params={s})", .{params});
                        return;
                    }

                    // Decode base64 (leniently, skipping whitespace/newlines)
                    const filtered = try self.allocator.alloc(u8, b64_data.len);
                    defer self.allocator.free(filtered);
                    var f_len: usize = 0;
                    for (b64_data) |c| {
                        if (std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=') {
                            filtered[f_len] = c;
                            f_len += 1;
                        }
                    }

                    const Decoder = std.base64.standard.Decoder;
                    const clean_data = filtered[0..f_len];
                    const dest_len = Decoder.calcSizeForSlice(clean_data) catch {
                        std.log.err("OSC 52: Invalid base64 data (len={d})", .{clean_data.len});
                        return;
                    };

                    if (dest_len > 0) {
                        const decoded = try self.allocator.alloc(u8, dest_len);
                        defer self.allocator.free(decoded);

                        try Decoder.decode(decoded, clean_data);

                        if (self.term.clipboard_data) |old| {
                            self.allocator.free(old);
                        }
                        self.term.clipboard_data = try self.allocator.dupe(u8, decoded);

                        // Check params to see which clipboard to set
                        self.term.clipboard_mask = 0;
                        for (params) |p| {
                            if (p == 'c') self.term.clipboard_mask |= 1; // CLIPBOARD
                            if (p == 'p') self.term.clipboard_mask |= 2; // PRIMARY
                        }
                        // Default to CLIPBOARD if params empty
                        if (self.term.clipboard_mask == 0) self.term.clipboard_mask = 1;

                        std.log.info("OSC 52: Received {d} bytes of clipboard data (mask={d})", .{ decoded.len, self.term.clipboard_mask });
                    }
                }
            },
            104 => {
                // OSC 104: Reset color palette
                // If no arguments, reset all. If arguments, reset specific indices.
                if (self.str.narg <= 1) {
                    self.resetPalette();
                } else {
                    var i: usize = 1;
                    while (i < self.str.narg) : (i += 1) {
                        const idx = std.fmt.parseInt(usize, self.str.args[i], 10) catch continue;
                        if (idx < 256) {
                            if (idx < 16) {
                                if (idx < 8) {
                                    self.term.palette[idx] = config.colors.normal[idx];
                                } else {
                                    self.term.palette[idx] = config.colors.bright[idx - 8];
                                }
                            } else {
                                // For 256 colors, we don't have a "default" beyond 16 stored in config.
                                // st calculates them. stz parser.zig resetPalette calculates them.
                                // We can extract a `resetPaletteIndex` function?
                                // For now, just re-run calculation for this index.
                                // It's complex to extract locally inside switch.
                                // Simpler: just call resetPalette() for now if partial reset is requested,
                                // or ignore partial reset support and just support full reset (common case).
                                // st implementation loops through args.
                            }
                        }
                    }
                    // For simplicity in this patch, if any argument is provided, we just reset everything
                    // because extracting the color calculation logic is messy here.
                    // But actually, `resetPalette` is right below. Let's use it.
                    self.resetPalette();
                }
            },
            else => {
                std.log.debug("未处理的 OSC 命令: {d}", .{par});
            },
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
        for (0..8) |i| self.term.palette[i] = config.colors.normal[i];
        for (8..16) |i| self.term.palette[i] = config.colors.bright[i - 8];
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
