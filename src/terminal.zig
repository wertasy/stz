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
//! PTY 输出字节 → Parser.processBytes() → 解码为 Unicode 码点 → parser.putc()
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
const boxdraw = @import("boxdraw.zig");

const Glyph = types.Glyph;
const GlyphAttr = types.GlyphAttr;
const TCursor = types.TCursor;
const Parser = @import("parser.zig").Parser;
const config = @import("config.zig");
const TermMode = types.TermMode;
const EscapeState = types.EscapeState;
const Charset = types.Charset;
const CursorStyle = types.CursorStyle;
const SavedCursor = types.SavedCursor;
const Selection = types.Selection;

const Printer = @import("printer.zig").Printer;

pub const TerminalError = error{
    OutOfBounds,
    InvalidSequence,
    PrinterError,
};

/// 终端模拟器
pub const Terminal = struct {
    // ========== 屏幕尺寸 ==========
    row: usize = 0, // 行数：屏幕有多少行
    col: usize = 0, // 列数：屏幕有多少列

    // ========== 屏幕缓冲区 ==========
    line: ?[][]Glyph = null, // 主屏幕：普通的命令行界面
    alt: ?[][]Glyph = null, // 备用屏幕：TUI 程序专用（如 vim）

    // ========== 历史记录 ==========
    hist: ?[][]Glyph = null, // 历史缓冲区：循环缓冲区，存储滚出的内容
    hist_idx: usize = 0, // 历史写入索引：循环缓冲区的当前写入位置
    hist_cnt: usize = 0, // 历史行数：历史缓冲区当前存储了多少行
    hist_max: usize = 0, // 历史最大行数：历史缓冲区的容量（配置项）
    scr: usize = 0, // 滚动偏移：向上滚动的行数（0 = 底部，查看最新内容）

    // ========== 脏标记 ==========
    dirty: ?[]bool = null, // 脏标记：dirty[i]=true 表示第 i 行需要重新渲染

    // ========== 光标 ==========
    c: TCursor = .{}, // 当前光标：位置、属性、状态
    ocx: usize = 0, // 旧光标列：上一帧光标所在的列
    ocy: usize = 0, // 旧光标行：上一帧光标所在的行

    // ========== 滚动区域 ==========
    top: usize = 0, // 滚动区域顶部：可滚动的最小行（默认 0）
    bot: usize = 0, // 滚动区域底部：可滚动的最大行（默认 row-1）

    // ========== 模式 ==========
    mode: TermMode = .{}, // 终端模式：各种行为模式（鼠标、备用屏幕、回绕等）
    esc: EscapeState = .{}, // 转义状态：转义序列解析器的当前状态

    // ========== 字符集 ==========
    trantbl: [4]Charset = [_]Charset{.usa} ** 4, // 字符集映射表：G0-G3 的字符集
    charset: u8 = 0, // 当前字符集索引：0-3（G0-G3）
    icharset: u8 = 0, // 字符集选择索引：选择哪个槽位（G0-G3）

    // ========== 制表符 ==========
    tabs: ?[]bool = null, // 制表符标记：tabs[col]=true 表示该列是制表位

    // ========== 最后一个字符 ==========
    lastc: u21 = 0, // 最后一个字符：某些模式需要（如某些字符集的字符映射）

    // ========== 窗口标题 ==========
    window_title: []const u8 = "stz", // 窗口标题：显示在窗口标题栏的文字
    window_title_dirty: bool = false, // 标题脏标记：标题是否改变，需要更新窗口

    // ========== 颜色调色板 ==========
    palette: [256]u32 = undefined, // 颜色调色板：256种颜色的 RGB 值
    default_fg: u32 = config.colors.foreground, // 默认前景色 (RGB)
    default_bg: u32 = config.colors.background, // 默认背景色 (RGB)
    default_cs: u32 = config.colors.cursor, // 默认光标颜色 (RGB)
    default_rev_cs: u32 = config.colors.cursor_text, // 反转光标颜色 (RGB)

    // ========== 光标样式 ==========
    cursor_style: CursorStyle = .blinking_bar, // 光标样式：闪烁竖线（默认）

    // ========== 保存的光标状态 ==========
    saved_cursor: [2]SavedCursor = [_]SavedCursor{.{}} ** 2, // 保存的光标：[0]主屏幕，[1]备用屏幕

    // ========== 选择区域状态 ==========
    selection: Selection = .{}, // 选择状态：文本选择的信息（起点、终点、类型等）

    // ========== 剪贴板请求 (OSC 52) ==========
    clipboard_data: ?[]u8 = null, // 剪贴板数据：OSC 52 设置的剪贴板内容
    clipboard_mask: u8 = 0, // 剪贴板掩码：Bit 0=CLIPBOARD, Bit 1=PRIMARY

    allocator: std.mem.Allocator,
    printer: ?*Printer = null,

    /// 初始化终端
    pub fn init(row: usize, col: usize, allocator: std.mem.Allocator) !Terminal {
        var t = Terminal{
            .allocator = allocator,
            .printer = null,
        };

        // 初始化屏幕（包括尺寸、缓冲区、光标、模式等）
        try screen.init(&t, row, col, allocator);

        return t;
    }

    /// 清理终端资源
    pub fn deinit(self: *Terminal) void {
        screen.deinit(self);
    }

    /// 设置打印机
    pub fn setPrinter(self: *Terminal, printer: *Printer) void {
        self.printer = printer;
    }

    /// 清理可能被破坏的宽字符 (st 对齐: tsetchar 中的清理逻辑)
    /// 如果 (x, y) 是 wide_dummy，则清理 (x-1, y) 的 wide 标志
    /// 如果 (x, y) 是 wide，则清理 (x+1, y) 的 wide_dummy 标志
    pub fn clearWide(self: *Terminal, x: usize, y: usize) void {
        const lines = self.line orelse return;
        if (y >= lines.len) return;
        const row = lines[y];
        if (x >= row.len) return;

        const glyph = row[x];
        if (glyph.attr.wide) {
            if (x + 1 < row.len) {
                row[x + 1].u = ' ';
                row[x + 1].attr.wide_dummy = false;
            }
        } else if (glyph.attr.wide_dummy) {
            if (x > 0) {
                row[x - 1].u = ' ';
                row[x - 1].attr.wide = false;
            }
        }
    }

    /// 写入字符到终端（带字符集转换）
    pub fn writeChar(self: *Terminal, u: u21) !void {
        var codepoint = u;

        // 应用 VT100 graphic0 字符集转换（参考 parser.zig L323-337）
        if (self.trantbl[self.charset] == .graphic0) {
            if (codepoint >= 0x24 and codepoint <= 0x7e) {
                const mapping: [128]u21 = init: {
                    var m = [_]u21{0} ** 128;
                    m['$'] = 0x00a3;
                    m['+'] = 0x2192;
                    m[','] = 0x2190;
                    m['-'] = 0x2191;
                    m['.'] = 0x2193;
                    m['0'] = 0x2588;
                    m['a'] = 0x2592;
                    m['f'] = 0x00b0;
                    m['g'] = 0x00b1;
                    m['h'] = 0x2591;
                    m['i'] = 0x000b;
                    m['j'] = 0x2518;
                    m['k'] = 0x2510;
                    m['l'] = 0x250c;
                    m['m'] = 0x2514;
                    m['n'] = 0x253c;
                    m['o'] = 0x23ba;
                    m['p'] = 0x23bb;
                    m['q'] = 0x2500;
                    m['r'] = 0x23bc;
                    m['s'] = 0x23bd;
                    m['t'] = 0x251c;
                    m['u'] = 0x2524;
                    m['v'] = 0x2534;
                    m['w'] = 0x252c;
                    m['x'] = 0x2502;
                    m['y'] = 0x2264;
                    m['z'] = 0x2265;
                    m['{'] = 0x03c0;
                    m['|'] = 0x2260;
                    m['}'] = 0x00a3;
                    m['~'] = 0x00b7;
                    m['_'] = 0x0020;
                    break :init m;
                };
                const translated = mapping[@as(usize, @intCast(codepoint))];
                if (translated != 0) {
                    codepoint = translated;
                }
            }
        }

        try self.putchar(codepoint);
    }

    /// 写入字符到终端
    pub fn putc(self: *Terminal, u: u21) !void {
        const is_control = unicode.isControl(u);

        // 如果开启了打印机模式，将所有字符（包括控制字符）发送到打印机
        if (self.mode.print) {
            if (self.printer) |p| {
                // 将 u21 转换为 utf8 字节并写入
                var buf: [4]u8 = undefined;
                const len = try unicode.encode(u, &buf);
                p.write(buf[0..len]) catch {};
            }
        }

        if (unicode.isControlC1(u) and self.mode.utf8) {
            return; // 在 UTF-8 模式下忽略 C1
        }

        // 控制字符由终端处理
        if (is_control) {
            try self.controlCode(@truncate(u));
            self.lastc = 0;
            return;
        }

        // 检查是否在转义序列中
        if (self.esc.start) {
            // 重要：即使在转义序列中，解析器也可能回调 putc。
            // 例如，CSI序列的参数处理逻辑可能会直接调用 putc。
            // 但是，通常解析器会在处理完序列后重置 esc.start。
            // 如果这里直接 return，那么解析器内部调用的 putc 就无效了。
            //
            // 检查 parser.zig，发现 parser.processBytes -> parser.putc -> terminal.putc
            // 而 parser.processBytes 中已经根据状态机决定了是否调用 putc。
            // 如果 parser 认为这是个普通字符，它会调用 putc。
            //
            // 问题在于：esc.start 是由 terminal 维护的，还是 parser 维护的？
            // 在 st 中，term.esc 是一个状态掩码。
            // 如果我们在 ESC 序列中间，通常不应该打印字符。
            // 但如果 parser 已经解析出这是一个普通字符（例如序列结束后的字符，或者序列中断），
            // parser 会调用 putc。
            //
            // 在 parser.zig 中，解析器会调用 terminal.putc。
            // 如果解析器调用了 terminal.putc，说明它认为这是一个需要显示的字符。
            // 此时 terminal 不应该因为自己认为在 esc 状态就拒绝显示。
            // 事实上，term.esc 状态的维护可能存在同步问题，或者设计上 terminal 不应该再次检查 esc 状态。
            //
            // 移除此检查，完全信任 parser 的判断。
            if (self.esc.start) {
                return; // 由解析器处理
            }
        }

        // 写入字符到屏幕
        try self.putchar(u);
        self.lastc = u;
    }

    /// 处理控制字符
    fn controlCode(self: *Terminal, c: u8) !void {
        // std.log.debug("Terminal controlCode: 0x{x}", .{c});
        switch (c) {
            '\x09' => try self.putTab(), // HT
            '\x08' => try self.moveCursor(-1, 0), // BS
            '\x0D' => self.moveTo(0, @as(isize, self.c.y)), // CR
            '\x0A', '\x0B', '\x0C' => try self.newLine(self.mode.crlf), // LF, VT, FF
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
        if (self.mode.wrap and self.c.state.wrap_next) {
            if (width > 0) {
                try self.newLine(true);
            }
            self.c.state.wrap_next = false;
        }

        // 检查是否需要换行
        if (self.c.x + width > self.col) {
            if (self.mode.wrap) {
                try self.newLine(true);
            } else {
                self.c.x = @max(self.c.x, width) - width;
            }
        }

        // 限制光标位置
        if (self.c.x >= self.col) {
            self.c.x = self.col - 1;
            self.c.state.wrap_next = true;
        }

        // 写入字符
        if (self.line) |lines| {
            if (self.c.y < lines.len and self.c.x < lines[self.c.y].len) {
                // 清理被覆盖的宽字符 (st 对齐: tsetchar)
                self.clearWide(self.c.x, self.c.y);

                // 设置字符属性（如果宽字符则设置 wide 标志）

                var glyph_attr = self.c.attr.attr;
                if (width == 2) {
                    glyph_attr.wide = true;
                }
                // 检查是否是框线字符，设置 boxdraw 属性
                if (config.draw.boxdraw and boxdraw.BoxDraw.isBoxDraw(u)) {
                    glyph_attr.boxdraw = true;
                }
                lines[self.c.y][self.c.x] = Glyph{
                    .u = u,
                    .attr = glyph_attr,
                    .fg = self.c.attr.fg,
                    .bg = self.c.attr.bg,
                };
            }

            // 移动光标 - 处理宽字符
            if (width == 2 and self.c.x + 1 < self.col) {
                // 宽字符
                self.c.x += 2;
                if (self.c.y < lines.len and self.c.x < lines[self.c.y].len) {
                    lines[self.c.y][self.c.x - 1] = Glyph{
                        .u = 0,
                        .fg = self.c.attr.fg,
                        .bg = self.c.attr.bg,
                        .attr = .{ .wide_dummy = true },
                    };
                }
            } else if (width > 0) {
                self.c.x += width;
            }
        }

        // 设置脏标记
        if (self.dirty) |dirty| {
            if (self.c.y < dirty.len) {
                dirty[self.c.y] = true;
            }
        }
    }

    /// 移动光标
    pub fn moveCursor(self: *Terminal, dx: i32, dy: i32) !void {
        // Mark old cursor line as dirty
        if (self.dirty) |dirty| {
            if (self.c.y < dirty.len) dirty[self.c.y] = true;
        }

        var new_x = @as(isize, @intCast(self.c.x)) + dx;
        var new_y = @as(isize, @intCast(self.c.y)) + dy;

        // 限制在范围内
        new_x = @max(0, @min(new_x, @as(isize, @intCast(self.col - 1))));
        new_y = @max(0, @min(new_y, @as(isize, @intCast(self.row - 1))));

        self.c.x = @intCast(new_x);
        self.c.y = @intCast(new_y);
        self.c.state.wrap_next = false;

        // Mark new cursor line as dirty
        if (self.dirty) |dirty| {
            if (self.c.y < dirty.len) dirty[self.c.y] = true;
        }
    }

    /// 移动光标到绝对位置
    pub fn moveTo(self: *Terminal, x: usize, y: usize) !void {
        // Mark old cursor line as dirty
        if (self.dirty) |dirty| {
            if (self.c.y < dirty.len) dirty[self.c.y] = true;
        }

        var new_x = x;
        var new_y = y;

        // Determine boundaries based on origin mode
        var min_y: usize = 0;
        var max_y: usize = self.row - 1;

        if (self.c.state.origin) {
            min_y = self.top;
            max_y = self.bot;
        }

        // Clamp values
        new_x = @min(new_x, self.col - 1);
        new_y = @max(min_y, @min(new_y, max_y));

        self.c.x = new_x;
        self.c.y = new_y;
        self.c.state.wrap_next = false;

        // Mark new cursor line as dirty
        if (self.dirty) |dirty| {
            if (self.c.y < dirty.len) dirty[self.c.y] = true;
        }
    }

    /// 换行
    pub fn newLine(self: *Terminal, first_col: bool) !void {
        // Mark old cursor line as dirty
        if (self.dirty) |dirty| {
            if (self.c.y < dirty.len) dirty[self.c.y] = true;
        }

        if (self.c.y == self.bot) {
            try screen.scrollUp(self, self.top, 1);
        } else {
            // Move down with clamping respecting origin mode
            var next_y = self.c.y + 1;
            const max_y = if (self.c.state.origin) self.bot else self.row - 1;
            if (next_y > max_y) next_y = max_y;
            self.c.y = next_y;
        }

        self.c.x = if (first_col) 0 else self.c.x;
        self.c.state.wrap_next = false;

        // Mark new cursor line as dirty
        if (self.dirty) |dirty| {
            if (self.c.y < dirty.len) dirty[self.c.y] = true;
        }
    }

    /// 制表符
    pub fn putTab(self: *Terminal) !void {
        // Mark old cursor line as dirty
        if (self.dirty) |dirty| {
            if (self.c.y < dirty.len) dirty[self.c.y] = true;
        }

        var x = self.c.x + 1;

        // 查找下一个制表位
        while (x < self.col) {
            if (self.tabs) |tabs| {
                if (x < tabs.len and tabs[x]) {
                    break;
                }
            }
            x += 1;
        }

        self.c.x = @min(x, self.col - 1);
        self.c.state.wrap_next = false;

        // Mark new cursor line as dirty
        if (self.dirty) |dirty| {
            if (self.c.y < dirty.len) dirty[self.c.y] = true;
        }
    }

    /// 清除屏幕
    pub fn clearScreen(self: *Terminal, mode: u32) !void {
        switch (mode) {
            0 => { // 从光标到屏幕末尾
                // IMPORTANT: st's tclearregion is inclusive [x1, y1, x2, y2]
                // clearRegion(x, y, x, y) clears one cell.

                // Clear from cursor to end of line
                try screen.clearRegion(self, self.c.x, self.c.y, self.col - 1, self.c.y);

                // Clear remaining lines below
                if (self.c.y < self.row - 1) {
                    try screen.clearRegion(self, 0, self.c.y + 1, self.col - 1, self.row - 1);
                }
            },
            1 => { // From beginning of screen to cursor
                if (self.c.y > 0) {
                    try screen.clearRegion(self, 0, 0, self.col - 1, self.c.y - 1);
                }
                // Clear from start of line to cursor
                try screen.clearRegion(self, 0, self.c.y, self.c.x, self.c.y);
            },
            2 => { // Clear entire screen
                try screen.clearRegion(self, 0, 0, self.col - 1, self.row - 1);
            },
            3 => { // Clear scroll region (not supported by standard ED, but good to have)
                try screen.clearRegion(self, 0, self.top, self.col - 1, self.bot);
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
                try screen.clearRegion(self, self.c.x, self.c.y, self.col - 1, self.c.y);
            },
            1 => { // 从行首到光标
                try screen.clearRegion(self, 0, self.c.y, self.c.x, self.c.y);
            },
            2 => { // 清除整行
                try screen.clearRegion(self, 0, self.c.y, self.col - 1, self.c.y);
            },
            else => {
                std.log.debug("未知的清除行模式: {d}", .{mode});
            },
        }
    }

    /// 删除字符
    pub fn deleteChars(self: *Terminal, n: usize) !void {
        const count = @min(n, self.col - self.c.x);
        const screen_buf = self.line;

        if (screen_buf) |scr| {
            if (self.c.y < scr.len) {
                const row = scr[self.c.y];

                // 宽字符清理：检查删除起始位置
                if (self.c.x > 0 and row[self.c.x].attr.wide_dummy) {
                    row[self.c.x - 1].u = ' ';
                    row[self.c.x - 1].attr.wide = false;
                }
                // 检查删除范围的末尾
                const last_deleted_idx = self.c.x + count - 1;
                if (row[last_deleted_idx].attr.wide) {
                    if (last_deleted_idx + 1 < self.col) {
                        row[last_deleted_idx + 1].u = ' ';
                        row[last_deleted_idx + 1].attr.wide_dummy = false;
                    }
                }

                // 移动字符
                for (self.c.x..self.col - count) |i| {
                    row[i] = row[i + count];
                }

                // 清除尾部
                for (self.col - count..self.col) |i| {
                    row[i] = Glyph{
                        .u = ' ',
                        .fg = self.c.attr.fg,
                        .bg = self.c.attr.bg,
                        .attr = .{},
                    };
                }

                if (self.dirty) |dirty| {
                    if (self.c.y < dirty.len) {
                        dirty[self.c.y] = true;
                    }
                }
            }
        }
    }

    /// 插入空字符
    pub fn insertBlanks(self: *Terminal, n: usize) !void {
        const count = @min(n, self.col - self.c.x);
        const screen_buf = self.line;

        if (screen_buf) |scr| {
            if (self.c.y < scr.len) {
                const row = scr[self.c.y];

                // 宽字符清理：如果插入点是 wide_dummy，清理其前面的 wide 头
                if (self.c.x > 0 and row[self.c.x].attr.wide_dummy) {
                    row[self.c.x - 1].u = ' ';
                    row[self.c.x - 1].attr.wide = false;
                }

                // 移动字符
                var i: usize = self.col - 1;
                while (i >= self.c.x + count) : (i -= 1) {
                    row[i] = row[i - count];
                }

                // 插入空格
                for (self.c.x..self.c.x + count) |j| {
                    row[j] = Glyph{
                        .u = ' ',
                        .fg = self.c.attr.fg,
                        .bg = self.c.attr.bg,
                        .attr = .{},
                    };
                }

                // 宽字符清理：检查移动后的末尾边界是否破坏了宽字符
                const last_moved_idx = self.col - 1;
                if (row[last_moved_idx].attr.wide) {
                    row[last_moved_idx].u = ' ';
                    row[last_moved_idx].attr.wide = false;
                }

                if (self.dirty) |dirty| {
                    if (self.c.y < dirty.len) {
                        dirty[self.c.y] = true;
                    }
                }
            }
        }
    }

    /// 设置滚动区域
    pub fn setScrollRegion(self: *Terminal, top: usize, bot: usize) !void {
        const min_top = @min(top, self.row - 1);
        const min_bot = @min(bot, self.row - 1);

        self.top = @min(min_top, min_bot);
        self.bot = @max(min_top, min_bot);

        // std.log.debug("setScrollRegion top={}, bot={}", .{ self.top, self.bot });

        // 移动光标到区域原点
        try self.moveTo(0, 0);
    }

    /// 保存光标状态（完整实现）
    pub fn saveCursorState(self: *Terminal) void {
        const alt = if (self.mode.alt_screen) @as(usize, 1) else 0;
        self.saved_cursor[alt] = .{
            .attr = self.c.attr,
            .x = self.c.x,
            .y = self.c.y,
            .state = self.c.state,
            .style = self.cursor_style,
            .trantbl = self.trantbl,
            .charset = self.charset,
        };
    }

    /// 恢复光标状态（完整实现）
    pub fn restoreCursorState(self: *Terminal) !void {
        const alt = if (self.mode.alt_screen) @as(usize, 1) else 0;
        const saved = self.saved_cursor[alt];
        self.c.attr = saved.attr;
        self.c.state = saved.state;
        self.cursor_style = saved.style;
        self.trantbl = saved.trantbl;
        self.charset = saved.charset;
        try self.moveTo(saved.x, saved.y);
    }

    /// 切换到备用屏幕
    pub fn swapScreen(self: *Terminal) !void {
        const temp = self.line;
        self.line = self.alt;
        self.alt = temp;
        self.mode.alt_screen = !self.mode.alt_screen;
        screen.setFullDirty(self);
    }

    /// 调整终端大小
    pub fn resize(self: *Terminal, new_row: usize, new_col: usize) !void {
        try screen.resize(self, new_row, new_col);
    }

    /// 向上滚动历史 (PageUp)
    pub fn kscrollUp(self: *Terminal, n: usize) void {
        const hist_len = self.hist_cnt;
        if (hist_len == 0) return;

        var next_scr = self.scr + n;
        if (next_scr > hist_len) {
            next_scr = hist_len;
        }

        if (next_scr != self.scr) {
            self.scr = next_scr;
            screen.setFullDirty(self);
        }
    }

    /// 向下滚动历史 (PageDown)
    pub fn kscrollDown(self: *Terminal, n: usize) void {
        var next_scr = self.scr;
        if (n >= next_scr) {
            next_scr = 0;
        } else {
            next_scr -= n;
        }

        if (next_scr != self.scr) {
            self.scr = next_scr;
            screen.setFullDirty(self);
        }
    }

    /// 设置光标位置（考虑原点模式）
    pub fn setCursor(self: *Terminal, x: usize, y: usize) !void {
        var new_y = y;
        if (self.c.state.origin) {
            new_y += self.top;
        }
        try self.moveTo(x, new_y);
    }

    /// DECALN - 屏幕对齐测试（填充 E 字符）
    pub fn decaln(self: *Terminal) !void {
        if (self.line) |lines| {
            const glyph = self.c.attr;
            var glyph_var = glyph;
            glyph_var.u = 'E';
            for (0..self.row) |y| {
                for (0..self.col) |x| {
                    if (x < lines[y].len) {
                        lines[y][x] = glyph_var;
                    }
                }
            }
        }
        if (self.dirty) |dirty| {
            for (0..dirty.len) |i| {
                dirty[i] = true;
            }
        }
        try self.moveTo(0, 0);
    }

    /// 擦除从光标开始的 n 个字符（不移动后续字符）
    pub fn eraseChars(self: *Terminal, n: usize) !void {
        const max_chars = self.col - self.c.x;
        const erase_count = @min(n, max_chars);
        if (erase_count == 0) return;

        if (self.line) |lines| {
            if (self.c.y < lines.len) {
                const line = lines[self.c.y];
                const clear_glyph = Glyph{ .u = ' ', .fg = self.c.attr.fg, .bg = self.c.attr.bg };

                // 检查起始位置和结束位置是否切断了宽字符
                self.clearWide(self.c.x, self.c.y);
                const end_idx = self.c.x + erase_count;
                if (end_idx < line.len) {
                    self.clearWide(end_idx, self.c.y);
                }

                var i: usize = 0;
                while (i < erase_count and self.c.x + i < line.len) : (i += 1) {
                    line[self.c.x + i] = clear_glyph;
                }
            }
        }

        if (self.dirty) |dirty| {
            if (self.c.y < dirty.len) dirty[self.c.y] = true;
        }
    }

    /// 擦除显示 (ED)
    pub fn eraseDisplay(self: *Terminal, mode: i32) !void {
        const x = self.c.x;
        const y = self.c.y;

        switch (mode) {
            0 => { // 从光标到屏幕末尾
                try screen.clearRegion(self, x, y, self.col - 1, y);
                if (y < self.row - 1) {
                    try screen.clearRegion(self, 0, y + 1, self.col - 1, self.row - 1);
                }
            },
            1 => { // 从屏幕开头到光标
                if (y > 0) {
                    try screen.clearRegion(self, 0, 0, self.col - 1, y - 1);
                }
                try screen.clearRegion(self, 0, y, x, y);
            },
            2 => { // 清除整个屏幕
                try screen.clearRegion(self, 0, 0, self.col - 1, self.row - 1);
            },
            3 => { // 清除历史缓冲区
                if (self.hist) |hist| {
                    for (hist) |line| {
                        for (line) |*glyph| {
                            glyph.* = .{
                                .u = ' ',
                                .fg = self.c.attr.fg,
                                .bg = self.c.attr.bg,
                                .attr = .{},
                            };
                        }
                    }
                }
                self.hist_cnt = 0;
                self.hist_idx = 0;
                self.scr = 0;
                if (self.dirty) |dirty| {
                    for (0..dirty.len) |i| dirty[i] = true;
                }
            },
            else => {
                std.log.debug("未知的清除显示模式: {d}", .{mode});
            },
        }
    }

    /// 擦除行 (EL)
    pub fn eraseLine(self: *Terminal, mode: i32) !void {
        const x = self.c.x;
        const y = self.c.y;

        switch (mode) {
            0 => try screen.clearRegion(self, x, y, self.col - 1, y),
            1 => try screen.clearRegion(self, 0, y, x, y),
            2 => try screen.clearRegion(self, 0, y, self.col - 1, y),
            else => {
                std.log.debug("未知的清除行模式: {d}", .{mode});
            },
        }
    }

    /// 插入空白行（在滚动区域内）
    pub fn insertBlankLines(self: *Terminal, n: usize) !void {
        if (self.c.y < self.top or self.c.y > self.bot) return;
        try screen.scrollDown(self, self.c.y, n);
    }

    /// 删除行（在滚动区域内）
    pub fn deleteLines(self: *Terminal, n: usize) !void {
        if (self.c.y < self.top or self.c.y > self.bot) return;
        try screen.scrollUp(self, self.c.y, n);
    }
};
