//! 终端模拟核心
//! 实现 VT100/VT220 终端模拟功能
//! ## 文件概述
//! 本文件实现了终端模拟器的核心逻辑层，是整个终端模拟器的"大脑"。
//! 它负责：
//! 1. 字符写入和光标移动
//! 2. 控制字符处理（如换行、回车、制表符）
//! 3. 屏幕清除和行操作
//! 4. 滚动区域管理
//! 5. 备用屏幕切换
//! 6. 历史滚动（Shift+PageUp/PageDown）
//! ## 核心概念
//! ### 1. 字符写入流程
//! 当 PTY 输出一个字符时，处理流程如下：
//! ```
//! PTY 输出字节 → processBytes() → 解码为 Unicode 码点 → parser.putc()
//! ↓
//! 如果是控制字符 → controlCode() → 执行控制操作（换行、回车等）
//! ↓
//! 如果是转义序列 → parser 解析 → 执行 CSI/OSC 命令
//! ↓
//! 如果是普通字符 → putchar() → 写入屏幕缓冲区 → 移动光标
//! ```
//! ### 2. 光标移动规则
//! 光标移动有两个维度：
//! - **相对移动** (moveCursor): 向上下左右移动 N 个字符
//! - **绝对移动** (moveTo): 移动到指定的 (x, y) 坐标
//! 坐标原点：
//! - **默认模式**: (0, 0) 是屏幕左上角
//! - **原点模式** (origin = true): (0, top) 是滚动区域的左上角
//! ### 3. 宽字符处理
//! 某些 Unicode 字符（如中文、日文）占用 2 个单元格：
//! - 宽字符单元格 (wide = true): 存储实际字符（如 '你'）
//! - 占位单元格 (wide_dummy = true): 存储占位标记（u = 0）
//! ### 示例：写入 "你好"
//! ```
//! 初始: 光标在 (0, 0)
//! 写入 '你' (宽字符):
//!   - (0, 0) = {u='你', wide=true}
//!   - (1, 0) = {u=0, wide_dummy=true}
//!   - 光标移动到 (2, 0)
//! 写入 '好' (宽字符):
//!   - (2, 0) = {u='好', wide=true}
//!   - (3, 0) = {u=0, wide_dummy=true}
//!   - 光标移动到 (4, 0)
//! ```
//! ### 4. 自动换行 (Wrap)
//! 当光标到达行尾时，如果启用了 wrap 模式：
//! - 设置 wrap_next = true
//! - 下一个字符会触发换行
//! - 光标移动到下一行的开头
//! ### 示例：在行尾写入字符
//! ```
//! 假设屏幕宽度为 80 列，当前光标在 (79, 0)
//! 写入字符 'A':
//!   - 光标超出范围，设置 wrap_next = true
//! 写入字符 'B':
//!   - 检测到 wrap_next = true
//!   - 换行，光标移动到 (0, 1)
//!   - wrap_next = false
//!   - 写入 'B' 到 (0, 1)
//! ```
//! ### 5. 滚动区域 (Scroll Region)
//! 某些程序（如 vim）会限制滚动的区域：
//! - 例如：vim 的状态栏（最后一行）不应该滚动
//! - 滚动区域由 top 和 bottom 指定
//! - 滚动操作只在 [top, bottom] 范围内有效
//! ### 示例：设置滚动区域为 [1, 24]
//! ```
//! 设置 top=1, bot=24:
//! - 第 0 行：固定（标题栏）
//! - 第 1-24 行：可滚动区域
//! - 当第 24 行满时，滚动内容在第 1-24 行
//! ```
//! ### 6. 备用屏幕 (Alternate Screen)
//! TUI 程序（如 vim、htop）使用备用屏幕显示自己的界面：
//! - 主屏幕 (line): 普通的命令行界面
//! - 备用屏幕 (alt): TUI 程序专用
//! ### 切换流程
//! ```
//! 程序启动 (vim):
//!   1. 保存主屏幕光标状态
//!   2. 切换到备用屏幕 (swapScreen)
//!   3. 清空备用屏幕
//!   4. 显示自己的界面
//! 程序退出 (vim 退出):
//!   1. 切换回主屏幕 (swapScreen)
//!   2. 恢复主屏幕光标状态
//!   3. 用户回到之前的命令行
//! ```
//! ### 7. 历史滚动 (History Scroll)
//! 当内容超出屏幕顶部时，会被推入历史缓冲区：
//! - 用户可以用 Shift+PageUp/PageDown 查看历史
//! - 历史缓冲区是一个循环缓冲区
//! - scr = 0 表示查看最新内容
//! - scr > 0 表示向上滚动的行数
//!  脏标记 (Dirty Flag)
//! 优化性能的关键：
//! - dirty[i] = true 表示第 i 行需要重新渲染
//! - 只有发生变化的行才会被标记为脏
//! - 渲染器只重新渲染脏行，而不是整个屏幕
//! ### 示例
//! ```
//! 写入字符到第 10 行:
//!   - dirty[10] = true
//! 渲染器渲染:
//!   - for i in 0..row:
//!   -   if dirty[i]:
//!   -     渲染第 i 行
//!   -     dirty[i] = false
//! ```
//!  与原版 st 的对应关系
//! - Terminal 结构对应 st 的 Terminal 结构
//! - 所有函数与 st 的终端逻辑对齐
//! - 宽字符处理与 st 的处理逻辑一致

const std = @import("std");
const types = @import("types.zig");
const screen = @import("screen.zig");
const unicode = @import("unicode.zig");

const Term = types.Term;
const Glyph = types.Glyph;
const GlyphAttr = types.GlyphAttr;
const TCursor = types.TCursor;
const Parser = @import("parser.zig").Parser;
const config = @import("config.zig");

const Printer = @import("printer.zig").Printer;

pub const TerminalError = error{
    OutOfBounds,
    InvalidSequence,
    PrinterError,
};

/// 终端模拟器
pub const Terminal = struct {
    term: Term,
    parser: Parser,
    allocator: std.mem.Allocator,
    printer: ?*Printer = null,

    /// 初始化终端
    pub fn init(row: usize, col: usize, allocator: std.mem.Allocator) !Terminal {
        var t: Terminal = undefined;
        t.allocator = allocator;
        t.term = Term{
            .allocator = allocator,
        };
        t.printer = null;

        try screen.init(&t.term, row, col, allocator);
        t.parser = try Parser.init(&t.term, allocator);

        // 设置默认模式
        t.term.mode.utf8 = true;
        t.term.mode.wrap = true;
        t.term.c = TCursor{};
        t.term.cursor_style = config.Config.cursor.style; // 使用配置中的光标样式（闪烁竖线）
        t.term.top = 0;
        t.term.bot = row - 1;

        // 初始化保存的光标状态
        for (0..2) |i| {
            t.term.saved_cursor[i] = types.SavedCursor{
                .attr = t.term.c.attr,
                .x = 0,
                .y = 0,
                .state = .default,
            };
        }

        return t;
    }

    /// 清理终端资源
    pub fn deinit(self: *Terminal) void {
        screen.deinit(&self.term);
        self.parser.deinit();
    }

    /// 处理输入字节
    pub fn processBytes(self: *Terminal, bytes: []const u8) !void {
        // Log incoming bytes for debugging
        // if (bytes.len > 0) std.log.debug("Input bytes: {any}", .{bytes});

        var i: usize = 0;
        while (i < bytes.len) {
            const byte_len = unicode.utf8ByteLength(bytes[i]);
            if (byte_len == 0 or i + byte_len > bytes.len) {
                i += 1;
                continue;
            }

            // 解码 Unicode 字符
            const codepoint = try unicode.decode(bytes[i..@min(i + 4, bytes.len)]);
            _ = unicode.runeWidth(codepoint);

            // 发送字符给解析器
            try self.parser.putc(codepoint);
            i += if (byte_len > 0) byte_len else 1;
        }
    }

    /// 设置打印机
    pub fn setPrinter(self: *Terminal, printer: *Printer) void {
        self.printer = printer;
    }

    /// 写入字符到终端
    pub fn putc(self: *Terminal, u: u21) !void {
        const is_control = unicode.isControl(u);

        // 如果开启了打印机模式，将所有字符（包括控制字符）发送到打印机
        if (self.term.mode.print) {
            if (self.printer) |p| {
                // 将 u21 转换为 utf8 字节并写入
                var buf: [4]u8 = undefined;
                const len = try unicode.encode(u, &buf);
                p.write(buf[0..len]) catch {};
            }
        }

        if (unicode.isControlC1(u) and self.term.mode.utf8) {
            return; // 在 UTF-8 模式下忽略 C1
        }

        // 控制字符由终端处理
        if (is_control) {
            try self.controlCode(@truncate(u));
            self.term.lastc = 0;
            return;
        }

        // 检查是否在转义序列中
        if (self.term.esc.start) {
            return; // 由解析器处理
        }

        // 写入字符到屏幕
        try self.putchar(u);
        self.term.lastc = u;
    }

    /// 处理控制字符
    fn controlCode(self: *Terminal, c: u8) !void {
        // std.log.debug("Terminal controlCode: 0x{x}", .{c});
        switch (c) {
            '\x09' => try self.putTab(), // HT
            '\x08' => try self.moveCursor(-1, 0), // BS
            '\x0D' => self.moveTo(0, @as(isize, self.term.c.y)), // CR
            '\x0A', '\x0B', '\x0C' => try self.newLine(self.term.mode.crlf), // LF, VT, FF
            '\x07' => { // BEL
                // 触发铃声
            },
            else => {
                std.log.debug("Terminal忽略的控制字符: 0x{x}", .{c});
            },
        }
    }

    /// 写入字符到屏幕
    fn putchar(self: *Terminal, u: u21) !void {
        const width = unicode.runeWidth(u);

        // 检查自动换行
        if (self.term.mode.wrap and self.term.c.state.wrap_next) {
            if (width > 0) {
                try self.newLine(true);
            }
            self.term.c.state.wrap_next = false;
        }

        // 检查是否需要换行
        if (self.term.c.x + width > self.term.col) {
            if (self.term.mode.wrap) {
                try self.newLine(true);
            } else {
                self.term.c.x = @max(self.term.c.x, width) - width;
            }
        }

        // 限制光标位置
        if (self.term.c.x >= self.term.col) {
            self.term.c.x = self.term.col - 1;
            self.term.c.state.wrap_next = true;
        }

        // 写入字符
        if (self.term.line) |lines| {
            if (self.term.c.y < lines.len and self.term.c.x < lines[self.term.c.y].len) {
                // 清理被覆盖的宽字符 (st 对齐: tsetchar)
                const old_glyph = lines[self.term.c.y][self.term.c.x];
                if (old_glyph.attr.wide) {
                    if (self.term.c.x + 1 < self.term.col) {
                        lines[self.term.c.y][self.term.c.x + 1] = Glyph{
                            .u = ' ',
                            .fg = self.term.c.attr.fg,
                            .bg = self.term.c.attr.bg,
                        };
                    }
                } else if (old_glyph.attr.wide_dummy) {
                    if (self.term.c.x > 0) {
                        lines[self.term.c.y][self.term.c.x - 1] = Glyph{
                            .u = ' ',
                            .fg = self.term.c.attr.fg,
                            .bg = self.term.c.attr.bg,
                        };
                    }
                }

                lines[self.term.c.y][self.term.c.x] = Glyph{
                    .u = u,
                    .attr = self.term.c.attr.attr,
                    .fg = self.term.c.attr.fg,
                    .bg = self.term.c.attr.bg,
                };
            }

            // 移动光标 - 处理宽字符
            if (width == 2 and self.term.c.x + 1 < self.term.col) {
                // 宽字符
                self.term.c.x += 2;
                if (self.term.c.y < lines.len and self.term.c.x < lines[self.term.c.y].len) {
                    lines[self.term.c.y][self.term.c.x - 1] = Glyph{
                        .u = 0,
                        .fg = self.term.c.attr.fg,
                        .bg = self.term.c.attr.bg,
                        .attr = .{ .wide_dummy = true },
                    };
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

    /// 移动光标
    pub fn moveCursor(self: *Terminal, dx: i32, dy: i32) !void {
        // Mark old cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }

        var new_x = @as(isize, @intCast(self.term.c.x)) + dx;
        var new_y = @as(isize, @intCast(self.term.c.y)) + dy;

        // 限制在范围内
        new_x = @max(0, @min(new_x, @as(isize, @intCast(self.term.col - 1))));
        new_y = @max(0, @min(new_y, @as(isize, @intCast(self.term.row - 1))));

        self.term.c.x = @as(usize, new_x);
        self.term.c.y = @as(usize, new_y);
        self.term.c.state.wrap_next = false;

        // Mark new cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// 移动光标到绝对位置
    pub fn moveTo(self: *Terminal, x: usize, y: usize) !void {
        // Mark old cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }

        var new_x = x;
        var new_y = y;

        // Determine boundaries based on origin mode
        var min_y: usize = 0;
        var max_y: usize = self.term.row - 1;

        if (self.term.c.state.origin) {
            min_y = self.term.top;
            max_y = self.term.bot;
        }

        // Clamp values
        new_x = @min(new_x, self.term.col - 1);
        new_y = @max(min_y, @min(new_y, max_y));

        self.term.c.x = new_x;
        self.term.c.y = new_y;
        self.term.c.state.wrap_next = false;

        // Mark new cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// 换行
    fn newLine(self: *Terminal, first_col: bool) !void {
        // Mark old cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }

        if (self.term.c.y == self.term.bot) {
            try screen.scrollUp(&self.term, self.term.top, 1);
        } else {
            // Move down with clamping respecting origin mode
            var next_y = self.term.c.y + 1;
            const max_y = if (self.term.c.state.origin) self.term.bot else self.term.row - 1;
            if (next_y > max_y) next_y = max_y;
            self.term.c.y = next_y;
        }

        self.term.c.x = if (first_col) 0 else self.term.c.x;
        self.term.c.state.wrap_next = false;

        // Mark new cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// 制表符
    fn putTab(self: *Terminal) !void {
        // Mark old cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }

        var x = self.term.c.x + 1;

        // 查找下一个制表位
        while (x < self.term.col and (self.term.tabs)) |tabs| {
            if (x < tabs.len and tabs[x]) {
                break;
            }
            x += 1;
        }

        self.term.c.x = @min(x, self.term.col - 1);
        self.term.c.state.wrap_next = false;

        // Mark new cursor line as dirty
        if (self.term.dirty) |dirty| {
            if (self.term.c.y < dirty.len) dirty[self.term.c.y] = true;
        }
    }

    /// 清除屏幕
    pub fn clearScreen(self: *Terminal, mode: u32) !void {
        switch (mode) {
            0 => { // 从光标到屏幕末尾
                try screen.clearRegion(&self.term, self.term.c.x, self.term.c.y, self.term.col - 1, self.term.row - 1);
                if (self.term.c.y > 0) {
                    try screen.clearRegion(&self.term, 0, 0, self.term.col - 1, self.term.c.y - 1);
                }
            },
            1 => { // 从屏幕开头到光标
                if (self.term.c.y > 0) {
                    try screen.clearRegion(&self.term, 0, 0, self.term.col - 1, self.term.c.y - 1);
                }
                try screen.clearRegion(&self.term, 0, self.term.c.y, self.term.c.x, self.term.c.y);
            },
            2 => { // 清除整个屏幕
                try screen.clearRegion(&self.term, 0, 0, self.term.col - 1, self.term.row - 1);
            },
            3 => { // 清除滚动区域
                try screen.clearRegion(&self.term, 0, self.term.top, self.term.col - 1, self.term.bot);
            },
            else => {
                std.log.debug("未知的清屏模式: {d}", .{mode});
            },
        }
    }

    /// 清除行
    pub fn clearLine(self: *Terminal, mode: u32) !void {
        switch (mode) {
            0 => { // 从光标到行末
                try screen.clearRegion(&self.term, self.term.c.x, self.term.c.y, self.term.col - 1, self.term.c.y);
            },
            1 => { // 从行首到光标
                try screen.clearRegion(&self.term, 0, self.term.c.y, self.term.c.x, self.term.c.y);
            },
            2 => { // 清除整行
                try screen.clearRegion(&self.term, 0, self.term.c.y, self.term.col - 1, self.term.c.y);
            },
            else => {
                std.log.debug("未知的清除行模式: {d}", .{mode});
            },
        }
    }

    /// 删除字符
    pub fn deleteChars(self: *Terminal, n: usize) !void {
        const count = @min(n, self.term.col - self.term.c.x);
        const screen_buf = self.term.line;

        if (screen_buf) |scr| {
            if (self.term.c.y < scr.len) {
                const row = scr[self.term.c.y];
                // 移动字符
                for (self.term.c.x..self.term.col - count) |i| {
                    row[i] = row[i + count];
                }

                // 清除尾部
                for (self.term.col - count..self.term.col) |i| {
                    row[i] = Glyph{
                        .u = ' ',
                        .fg = self.term.c.attr.fg,
                        .bg = self.term.c.attr.bg,
                        .attr = .{},
                    };
                }

                if (self.term.dirty) |dirty| {
                    if (self.term.c.y < dirty.len) {
                        dirty[self.term.c.y] = true;
                    }
                }
            }
        }
    }

    /// 插入空字符
    pub fn insertBlanks(self: *Terminal, n: usize) !void {
        const count = @min(n, self.term.col - self.term.c.x);
        const screen_buf = self.term.line;

        if (screen_buf) |scr| {
            if (self.term.c.y < scr.len) {
                const row = scr[self.term.c.y];
                // 移动字符
                var i: usize = self.term.col - 1;
                while (i >= self.term.c.x + count) : (i -= 1) {
                    row[i] = row[i - count];
                }

                // 插入空格
                for (self.term.c.x..self.term.c.x + count) |j| {
                    row[j] = Glyph{
                        .u = ' ',
                        .fg = self.term.c.attr.fg,
                        .bg = self.term.c.attr.bg,
                        .attr = .{},
                    };
                }

                if (self.term.dirty) |dirty| {
                    if (self.term.c.y < dirty.len) {
                        dirty[self.term.c.y] = true;
                    }
                }
            }
        }
    }

    /// 设置滚动区域
    pub fn setScrollRegion(self: *Terminal, top: usize, bot: usize) !void {
        const min_top = @min(top, self.term.row - 1);
        const min_bot = @min(bot, self.term.row - 1);

        self.term.top = @min(min_top, min_bot);
        self.term.bot = @max(min_top, min_bot);

        // 移动光标到区域原点
        try self.moveTo(0, 0);
    }

    /// 保存光标
    pub fn saveCursor(self: *Terminal) void {
        _ = self;
        // 保存光标位置和属性到栈中（简化实现）
        // 完整实现需要保存多个光标状态
    }

    /// 恢复光标
    pub fn restoreCursor(self: *Terminal) void {
        _ = self;
        // 从栈恢复光标状态（简化实现）
    }

    /// 切换到备用屏幕
    pub fn swapScreen(self: *Terminal) !void {
        const temp = self.term.line;
        self.term.line = self.term.alt;
        self.term.alt = temp;
        self.term.mode.alt_screen = !self.term.mode.alt_screen;
        screen.setFullDirty(&self.term);
    }

    /// 重置终端
    pub fn reset(self: *Terminal) !void {
        try self.parser.resetTerminal();
    }

    /// 调整终端大小
    pub fn resize(self: *Terminal, new_row: usize, new_col: usize) !void {
        try screen.resize(&self.term, new_row, new_col);
    }

    /// 向上滚动历史 (PageUp)
    pub fn kscrollUp(self: *Terminal, n: usize) void {
        const hist_len = self.term.hist_cnt;
        if (hist_len == 0) return;

        var next_scr = self.term.scr + n;
        if (next_scr > hist_len) {
            next_scr = hist_len;
        }

        if (next_scr != self.term.scr) {
            self.term.scr = next_scr;
            screen.setFullDirty(&self.term);
        }
    }

    /// 向下滚动历史 (PageDown)
    pub fn kscrollDown(self: *Terminal, n: usize) void {
        var next_scr = self.term.scr;
        if (n >= next_scr) {
            next_scr = 0;
        } else {
            next_scr -= n;
        }

        if (next_scr != self.term.scr) {
            self.term.scr = next_scr;
            screen.setFullDirty(&self.term);
        }
    }
};
