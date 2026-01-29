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
//! ### 屏幕缓冲区管理
//! 负责管理终端屏幕的行、字符、滚动、脏标记等
//!
//! 核心功能：
//! - 屏幕缓冲区初始化和清理：分配主屏幕、备用屏幕、历史缓冲区
//! - 滚动操作：向上/向下滚动指定行数
//! - 清除操作：清除屏幕区域、清除行、删除字符、插入空格
//! - 脏标记管理：设置全屏脏、设置属性脏、检查属性设置
//! - 历史滚动：支持用户用 Shift+PageUp/PageDown 查看历史
//!
//! 屏幕缓冲区结构：
//! - 主屏幕 (line): 普通的命令行界面
//! - 备用屏幕 (alt): TUI 程序专用（如 vim）
//! - 历史缓冲区 (hist): 循环缓冲区，存储滚出的内容
//! - 脏标记 (dirty): dirty[i]=true 表示第 i 行需要重新渲染
//!
//! 滚动机制：
//! - 当内容超出屏幕顶部时，会被推入历史缓冲区
//! - 滚动区域由 term.top 和 term.bot 限定
//! - 滚动操作只在 [top, bot] 范围内有效
//!
//! 屏幕缓冲区结构：
//! - 主屏幕 (line): 普通的命令行界面
//! - 备用屏幕 (alt): TUI 程序专用（如 vim）
//! - 历史缓冲区 (hist): 循环缓冲区，存储滚出的内容
//! - 脏标记 (dirty): dirty[i]=true 表示第 i 行需要重新渲染
//!
//! 滚动机制：
//! - 当内容超出屏幕顶部时，会被推入历史缓冲区
//! - 滚动区域由 term.top 和 term.bot 限定
//! - 滚动操作只在 [top, bot] 范围内有效
//!
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
    screen: ?[][]Glyph = null, // 主屏幕：普通的命令行界面
    alt_screen: ?[][]Glyph = null, // 备用屏幕：TUI 程序专用（如 vim）

    // ========== 历史记录 ==========
    hist: ?[][]Glyph = null, // 历史缓冲区：循环缓冲区，存储滚出的内容
    hist_idx: usize = 0, // 历史写入索引：循环缓冲区的当前写入位置
    hist_cnt: usize = 0, // 历史行数：历史缓冲区当前存储了多少行
    hist_max: usize = 0, // 历史最大行数：历史缓冲区的容量（配置项）
    scroll: usize = 0, // 滚动偏移：向上滚动的行数（0 = 底部，查看最新内容）

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
    window_title: [:0]u8 = @constCast(&[_:0]u8{}), // 窗口标题：动态分配的 null-terminated 字符串
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

    // ========== URL Store (OSC 8) ==========
    url_store: std.ArrayList([]const u8),
    url_map: std.StringHashMap(u32),

    allocator: std.mem.Allocator,
    printer: ?*Printer = null,

    /// 初始化终端
    pub fn init(row: usize, col: usize, allocator: std.mem.Allocator) !Terminal {
        var term = Terminal{
            .allocator = allocator,
            .printer = null,
            .url_store = try std.ArrayList([]const u8).initCapacity(allocator, 16),
            .url_map = std.StringHashMap(u32).init(allocator),
        };

        // ========== 屏幕尺寸 ==========
        term.row = row;
        term.col = col;
        term.allocator = allocator;

        // ========== 分配内存 ==========
        // 分配主屏幕
        const line_buf = try allocator.alloc([]Glyph, row);
        errdefer allocator.free(line_buf);
        term.screen = line_buf;

        // 分配备用屏幕
        const alt_buf = try allocator.alloc([]Glyph, row);
        errdefer allocator.free(alt_buf);
        term.alt_screen = alt_buf;

        // 分配历史缓冲区
        const hist_rows = config.scroll.history_lines;
        const hist_buf = try allocator.alloc([]Glyph, hist_rows);
        errdefer allocator.free(hist_buf);
        term.hist = hist_buf;
        term.hist_max = hist_rows;
        term.hist_idx = 0;
        term.hist_cnt = 0;
        term.scroll = 0;

        // 分配脏标记
        const dirty_buf = try allocator.alloc(bool, row);
        errdefer allocator.free(dirty_buf);
        term.dirty = dirty_buf;

        // 分配制表符
        const tabs_buf = try allocator.alloc(bool, col);
        errdefer allocator.free(tabs_buf);
        term.tabs = tabs_buf;

        // ========== 初始化屏幕内容 ==========
        // 初始化每一行
        for (0..row) |y| {
            term.screen.?[y] = try allocator.alloc(Glyph, col);
            term.alt_screen.?[y] = try allocator.alloc(Glyph, col);
            term.dirty.?[y] = true;

            // 初始化为空格字符
            for (0..col) |x| {
                term.screen.?[y][x] = Glyph{};
                term.alt_screen.?[y][x] = Glyph{};
            }
        }

        // 初始化历史缓冲区
        for (0..term.hist_max) |y| {
            term.hist.?[y] = try allocator.alloc(Glyph, col);
            for (0..col) |x| {
                term.hist.?[y][x] = Glyph{};
            }
        }

        // ========== 初始化制表符 ==========
        for (term.tabs.?) |*tab| {
            tab.* = false;
        }

        // 设置默认制表符间隔（每8列一个）
        for (0..col) |x| {
            if (x % 8 == 0) {
                term.tabs.?[x] = true;
            }
        }

        // ========== 初始化字符集 ==========
        term.trantbl = [_]Charset{.usa} ** 4;
        term.charset = 0;
        term.icharset = 0;

        // ========== 初始化光标 ==========
        term.c = TCursor{};

        // ========== 初始化保存的光标状态 ==========
        term.cursor_style = config.cursor.style;
        for (0..2) |i| {
            term.saved_cursor[i] = types.SavedCursor{
                .attr = term.c.attr,
                .x = 0,
                .y = 0,
                .state = .default,
                .style = .blinking_bar,
                .trantbl = [_]Charset{.usa} ** 4,
                .charset = 0,
            };
        }

        // ========== 设置默认模式 ==========
        term.mode.utf8 = true;
        term.mode.wrap = true;

        // ========== 初始化滚动区域 ==========
        term.top = 0;
        term.bot = row - 1;

        // ========== 初始化窗口标题 ==========
        term.window_title = try allocator.dupeZ(u8, "stz");

        return term;
    }

    /// Add URL to store and return ID (1-based)
    pub fn addUrl(self: *Terminal, url: []const u8) !u32 {
        if (self.url_map.get(url)) |id| {
            return id;
        }
        const url_copy = try self.allocator.dupe(u8, url);
        try self.url_store.append(self.allocator, url_copy);
        const id = @as(u32, @intCast(self.url_store.items.len)); // 1-based ID (index 0 -> ID 1)
        try self.url_map.put(url_copy, id);
        return id;
    }

    /// 清理终端资源
    pub fn deinit(self: *Terminal) void {
        const allocator = self.allocator;

        if (self.screen) |lines| {
            for (lines) |line| {
                allocator.free(line);
            }
            allocator.free(lines);
        }

        if (self.alt_screen) |lines| {
            for (lines) |line| {
                allocator.free(line);
            }
            allocator.free(lines);
        }

        if (self.hist) |lines| {
            for (lines) |line| {
                allocator.free(line);
            }
            allocator.free(lines);
        }

        if (self.dirty) |d| {
            allocator.free(d);
        }

        if (self.tabs) |t| {
            allocator.free(t);
        }

        if (self.window_title.len > 0) {
            allocator.free(self.window_title);
        }

        if (self.clipboard_data) |data| {
            allocator.free(data);
        }

        // Clean up URL store
        for (self.url_store.items) |url| {
            allocator.free(url);
        }
        self.url_store.deinit(allocator);
        self.url_map.deinit();

        self.screen = null;
        self.alt_screen = null;
        self.hist = null;
        self.dirty = null;
        self.tabs = null;
    }

    /// 设置打印机
    pub fn setPrinter(self: *Terminal, printer: *Printer) void {
        self.printer = printer;
    }

    /// 清理可能被破坏的宽字符 (st 对齐: tsetchar 中的清理逻辑)
    /// 如果 (x, y) 是 wide_dummy，则清理 (x-1, y) 的 wide 标志
    /// 如果 (x, y) 是 wide，则清理 (x+1, y) 的 wide_dummy 标志
    pub fn clearWide(self: *Terminal, x: usize, y: usize) void {
        const lines = self.screen orelse return;
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
        if (self.screen) |lines| {
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
                    .url_id = self.c.attr.url_id,
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
            try self.scrollUp(self.top, 1);
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
                try self.clearRegion(self.c.x, self.c.y, self.col - 1, self.c.y);

                // Clear remaining lines below
                if (self.c.y < self.row - 1) {
                    try self.clearRegion(0, self.c.y + 1, self.col - 1, self.row - 1);
                }
            },
            1 => { // From beginning of screen to cursor
                if (self.c.y > 0) {
                    try self.clearRegion(0, 0, self.col - 1, self.c.y - 1);
                }
                // Clear from start of line to cursor
                try self.clearRegion(0, self.c.y, self.c.x, self.c.y);
            },
            2 => { // Clear entire screen
                try self.clearRegion(0, 0, self.col - 1, self.row - 1);
            },
            3 => { // Clear scroll region (not supported by standard ED, but good to have)
                try self.clearRegion(0, self.top, self.col - 1, self.bot);
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
                try self.clearRegion(self.c.x, self.c.y, self.col - 1, self.c.y);
            },
            1 => { // 从行首到光标
                try self.clearRegion(0, self.c.y, self.c.x, self.c.y);
            },
            2 => { // 清除整行
                try self.clearRegion(0, self.c.y, self.col - 1, self.c.y);
            },
            else => {
                std.log.debug("未知的清除行模式: {d}", .{mode});
            },
        }
    }

    /// 删除字符
    pub fn deleteChars(self: *Terminal, n: usize) !void {
        const count = @min(n, self.col - self.c.x);
        const screen_buf = self.screen;

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
        const screen_buf = self.screen;

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
        const temp = self.screen;
        self.screen = self.alt_screen;
        self.alt_screen = temp;
        self.mode.alt_screen = !self.mode.alt_screen;
        self.setFullDirty();
    }

    /// 向上滚动历史 (PageUp)
    pub fn kscrollUp(self: *Terminal, n: usize) void {
        const hist_len = self.hist_cnt;
        if (hist_len == 0) return;

        var next_scroll = self.scroll + n;
        if (next_scroll > hist_len) {
            next_scroll = hist_len;
        }

        if (next_scroll != self.scroll) {
            self.scroll = next_scroll;
            self.setFullDirty();
        }
    }

    /// 向下滚动历史 (PageDown)
    pub fn kscrollDown(self: *Terminal, n: usize) void {
        var next_scroll = self.scroll;
        if (n >= next_scroll) {
            next_scroll = 0;
        } else {
            next_scroll -= n;
        }

        if (next_scroll != self.scroll) {
            self.scroll = next_scroll;
            self.setFullDirty();
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
        if (self.screen) |lines| {
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

        if (self.screen) |lines| {
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
                try self.clearRegion(x, y, self.col - 1, y);
                if (y < self.row - 1) {
                    try self.clearRegion(0, y + 1, self.col - 1, self.row - 1);
                }
            },
            1 => { // 从屏幕开头到光标
                if (y > 0) {
                    try self.clearRegion(0, 0, self.col - 1, y - 1);
                }
                try self.clearRegion(0, y, x, y);
            },
            2 => { // 清除整个屏幕
                try self.clearRegion(0, 0, self.col - 1, self.row - 1);
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
                self.scroll = 0;
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
            0 => try self.clearRegion(x, y, self.col - 1, y),
            1 => try self.clearRegion(0, y, x, y),
            2 => try self.clearRegion(0, y, self.col - 1, y),
            else => {
                std.log.debug("未知的清除行模式: {d}", .{mode});
            },
        }
    }

    /// 插入空白行（在滚动区域内）
    pub fn insertBlankLines(self: *Terminal, n: usize) !void {
        if (self.c.y < self.top or self.c.y > self.bot) return;
        try self.scrollDown(self.c.y, n);
    }

    /// 删除行（在滚动区域内）
    pub fn deleteLines(self: *Terminal, n: usize) !void {
        if (self.c.y < self.top or self.c.y > self.bot) return;
        try self.scrollUp(self.c.y, n);
    }

    /// 获取当前可见的行数据（考虑滚动偏移）
    pub fn getVisibleLine(self: *const Terminal, y: usize) []Glyph {
        // 如果处于备用屏幕模式，直接返回当前行（因为 line/alt 已经交换过了）
        // 此时 term.screen 指向的是备用屏幕缓冲区
        if (self.mode.alt_screen) {
            return self.screen.?[y];
        }

        if (self.scroll > 0) {
            if (y < self.scroll) {
                // 在历史记录中
                const newest_idx = (self.hist_idx + self.hist_max - 1) % self.hist_max;
                const offset = self.scroll - y - 1;
                if (self.hist_cnt > 0) {
                    if (offset < self.hist_cnt) {
                        const hist_fetch_idx = (newest_idx + self.hist_max - offset) % self.hist_max;
                        return self.hist.?[hist_fetch_idx];
                    }
                }
                // 超出历史记录，返回第一行
                return self.screen.?[0];
            } else {
                // 在当前屏幕
                return self.screen.?[y - self.scroll];
            }
        }

        return self.screen.?[y];
    }

    /// 调整终端大小
    /// 参考 st 的 tresize 实现，滑动屏幕以保持光标位置
    pub fn resize(self: *Terminal, new_row: usize, new_col: usize) !void {
        const allocator = self.allocator;

        if (new_row < 1 or new_col < 1) {
            return error.InvalidSize;
        }

        const old_row = self.row;
        const old_col = self.col;

        // 滑动屏幕内容以保持光标位置
        // 如果光标在新屏幕外面，向上滚动屏幕
        var valid_rows: usize = 0;
        if (self.c.y >= new_row) {
            const shift = self.c.y - new_row + 1;
            // 释放顶部的行
            for (0..shift) |y| {
                if (self.screen) |lines| allocator.free(lines[y]);
                if (self.alt_screen) |alt| allocator.free(alt[y]);
            }

            valid_rows = old_row - shift;
            // 如果有效行数依然超过新屏幕高度，进一步释放
            if (valid_rows > new_row) {
                for (new_row..valid_rows) |y| {
                    if (self.screen) |lines| allocator.free(lines[y + shift]);
                    if (self.alt_screen) |alt| allocator.free(alt[y + shift]);
                }
                valid_rows = new_row;
            }

            // 移动剩余的行到顶部
            if (self.screen) |lines| {
                for (0..valid_rows) |y| {
                    lines[y] = lines[y + shift];
                }
            }
            if (self.alt_screen) |alt| {
                for (0..valid_rows) |y| {
                    alt[y] = alt[y + shift];
                }
            }
            self.c.y -= shift;
        } else {
            valid_rows = old_row;
            // 如果新屏幕比旧屏幕矮，释放超出的行
            if (new_row < old_row) {
                for (new_row..old_row) |y| {
                    if (self.screen) |lines| allocator.free(lines[y]);
                    if (self.alt_screen) |alt| allocator.free(alt[y]);
                }
                valid_rows = new_row;
            }
        }

        // 重新分配行数组
        self.screen = try allocator.realloc(self.screen.?, new_row);
        self.alt_screen = try allocator.realloc(self.alt_screen.?, new_row);

        // 调整现有行的宽度
        for (0..valid_rows) |y| {
            self.screen.?[y] = try allocator.realloc(self.screen.?[y], new_col);
            self.alt_screen.?[y] = try allocator.realloc(self.alt_screen.?[y], new_col);

            // 清除新扩展的区域（使用当前光标颜色，st 对齐）
            if (new_col > old_col) {
                for (old_col..new_col) |x| {
                    self.screen.?[y][x] = Glyph{
                        .u = ' ',
                        .fg = self.c.attr.fg,
                        .bg = self.c.attr.bg,
                    };
                    self.alt_screen.?[y][x] = Glyph{
                        .u = ' ',
                        .fg = self.c.attr.fg,
                        .bg = self.c.attr.bg,
                    };
                }
            }
        }

        // 分配并初始化新行 (st 对齐)
        for (valid_rows..new_row) |y| {
            self.screen.?[y] = try allocator.alloc(Glyph, new_col);
            self.alt_screen.?[y] = try allocator.alloc(Glyph, new_col);
            for (0..new_col) |x| {
                self.screen.?[y][x] = Glyph{
                    .u = ' ',
                    .fg = self.c.attr.fg,
                    .bg = self.c.attr.bg,
                };
                self.alt_screen.?[y][x] = Glyph{
                    .u = ' ',
                    .fg = self.c.attr.fg,
                    .bg = self.c.attr.bg,
                };
            }
        }

        // 调整历史缓冲区（如果宽度改变）
        if (new_col != old_col) {
            if (self.hist) |hist| {
                for (0..self.hist_max) |y| {
                    hist[y] = try allocator.realloc(hist[y], new_col);
                    // 清除新扩展的区域
                    if (new_col > old_col) {
                        for (old_col..new_col) |x| {
                            hist[y][x] = Glyph{};
                        }
                    }
                }
            }
            self.scroll = 0;
        }

        // 调整脏标记
        self.dirty = try allocator.realloc(self.dirty.?, new_row);
        for (0..new_row) |y| {
            self.dirty.?[y] = true;
        }

        // 调整制表符
        const tab_spaces = config.tab_spaces;
        self.tabs = try allocator.realloc(self.tabs.?, new_col);
        if (new_col > old_col) {
            // 从旧边界开始，按步进设置新的制表位
            var x = old_col;
            // 找到旧区域最后一个制表位（或起始点）
            while (x > 0 and !self.tabs.?[x - 1]) : (x -= 1) {}
            if (x == 0) {
                x = tab_spaces;
            } else {
                x += tab_spaces - 1;
            }

            // 清除新区域并设置新制表位
            for (old_col..new_col) |i| {
                self.tabs.?[i] = false;
            }
            var i = x;
            while (i < new_col) : (i += tab_spaces) {
                self.tabs.?[i] = true;
            }
        }

        self.row = new_row;
        self.col = new_col;

        // 重置滚动区域
        self.top = 0;
        self.bot = new_row - 1;

        // 限制光标位置
        if (self.c.x >= new_col) {
            self.c.x = new_col - 1;
        }
        if (self.c.y >= new_row) {
            self.c.y = new_row - 1;
        }

        // 限制保存的光标位置 (st 对齐)
        for (0..2) |i| {
            if (self.saved_cursor[i].x >= new_col) {
                self.saved_cursor[i].x = new_col - 1;
            }
            if (self.saved_cursor[i].y >= new_row) {
                self.saved_cursor[i].y = new_row - 1;
            }
        }

        self.c.state.wrap_next = false;
    }

    /// 清除区域
    pub fn clearRegion(self: *Terminal, x1: usize, y1: usize, x2: usize, y2: usize) !void {
        const gx1 = @min(x1, x2);
        const gx2 = @max(x1, x2);
        const gy1 = @min(y1, y2);
        const gy2 = @max(y1, y2);

        // 限制在屏幕范围内
        const sx1 = @min(gx1, self.col - 1);
        const sx2 = @min(gx2, self.col - 1);
        const sy1 = @min(gy1, self.row - 1);
        const sy2 = @min(gy2, self.row - 1);

        const screen = self.screen;

        for (sy1..sy2 + 1) |y| {
            if (self.dirty) |dirty| {
                dirty[y] = true;
            }
            for (sx1..sx2 + 1) |x| {
                // 清理宽字符
                self.clearWide(x, y);

                // 如果清除的单元格在选择范围内，清除选择 (st 对齐)

                if (self.selection.mode != .idle) {
                    if (isInsideSelection(self, x, y)) {
                        selClear(self);
                    }
                }

                if (screen) |scr| {
                    scr[y][x] = .{
                        .u = ' ',
                        .fg = self.c.attr.fg,
                        .bg = self.c.attr.bg,
                        .attr = .{},
                    };
                }
            }
        }
    }

    /// 屏幕向上滚动
    pub fn scrollUp(self: *Terminal, orig: usize, n: usize) !void {
        if (orig > self.bot) return;
        const limit_n = @min(n, self.bot - orig + 1);
        if (limit_n == 0) return;

        // Log scroll event
        // std.log.debug("SCROLL_UP: orig={d}, n={d}, bot={d}, cursor=({d},{d})", .{ orig, n, term.bot, term.c.x, term.c.y });

        const screen = self.screen;

        if (orig == 0 and limit_n > 0 and !self.mode.alt_screen) {
            // Save lines to history
            for (0..limit_n) |i| {
                const line_idx = orig + i;
                const src_line = screen.?[line_idx];
                const dest_line = self.hist.?[self.hist_idx];

                @memcpy(dest_line, src_line);

                self.hist_idx = (self.hist_idx + 1) % self.hist_max;
                if (self.hist_cnt < self.hist_max) {
                    self.hist_cnt += 1;
                }
            }
        }

        // 移动行
        var i: usize = orig;
        while (i + limit_n <= self.bot) : (i += 1) {
            const temp = screen.?[i];
            screen.?[i] = screen.?[i + limit_n];
            screen.?[i + limit_n] = temp;
        }

        // 更新选择区域位置 (st 对齐)
        selScroll(self, orig, -@as(i32, @intCast(limit_n)));

        // Mark affected region as dirty
        setDirty(self, orig, self.bot);

        // 清除底部行
        for (0..limit_n) |k| {
            const idx = self.bot + 1 - limit_n + k;
            if (screen) |scr| {
                for (scr[idx]) |*glyph| {
                    glyph.* = .{
                        .u = ' ',
                        .fg = self.c.attr.fg,
                        .bg = self.c.attr.bg,
                        .attr = .{},
                    };
                }
            }
        }
    }

    /// 屏幕向下滚动
    pub fn scrollDown(self: *Terminal, orig: usize, n: usize) !void {
        if (orig > self.bot) return;
        const limit_n = @min(n, self.bot - orig + 1);
        if (limit_n == 0) return;
        const screen = self.screen;

        // 移动行
        var i: usize = self.bot;
        while (i >= orig + limit_n) : (i -= 1) {
            const temp = screen.?[i];
            screen.?[i] = screen.?[i - limit_n];
            screen.?[i - limit_n] = temp;
        }

        // 更新选择区域位置 (st 对齐)
        selScroll(self, orig, @as(i32, @intCast(limit_n)));

        // Mark affected region as dirty
        setDirty(self, orig, self.bot);

        // 清除顶部行
        for (0..limit_n) |k| {
            const idx = orig + k;
            if (screen) |scr| {
                for (scr[idx]) |*glyph| {
                    glyph.* = .{
                        .u = ' ',
                        .fg = self.c.attr.fg,
                        .bg = self.c.attr.bg,
                        .attr = .{},
                    };
                }
            }
        }
    }

    /// 设置所有行为脏
    pub fn setFullDirty(self: *Terminal) void {
        if (self.dirty) |dirty| {
            for (dirty) |*d| {
                d.* = true;
            }
        }
    }

    /// 设置行为脏
    pub fn setDirty(self: *Terminal, top: usize, bot: usize) void {
        const t = @min(top, self.row - 1);
        const b = @min(bot, self.row - 1);

        if (t <= b) {
            if (self.dirty) |dirty| {
                for (t..b + 1) |i| {
                    dirty[i] = true;
                }
            }
        }
    }

    /// 将包含特定属性的所有行标记为脏
    pub fn setDirtyAttr(self: *Terminal, attr_mask: types.GlyphAttr) void {
        const screen = self.screen orelse return;
        const dirty = self.dirty orelse return;

        for (0..self.row) |y| {
            if (dirty[y]) continue;
            for (0..self.col) |x| {
                // 使用自定义的属性检查逻辑 (st 的 tsetdirtattr)
                const glyph_attr = screen[y][x].attr;
                // 检查 bitmask
                if (glyph_attr.matches(attr_mask)) {
                    dirty[y] = true;
                    break;
                }
            }
        }
    }

    /// 检查屏幕上是否存在带有特定属性的字符
    pub fn isAttrSet(self: *Terminal, attr_mask: types.GlyphAttr) bool {
        const screen = self.screen orelse return false;

        for (0..self.row) |y| {
            for (0..self.col) |x| {
                if (screen[y][x].attr.matches(attr_mask)) return true;
            }
        }
        return false;
    }

    /// 获取行长度（忽略尾部空格）
    pub fn lineLength(self: *Terminal, y: usize) usize {
        const screen = self.screen;
        if (screen) |scr| {
            // 检查是否换行到下一行
            if (scr[y][self.col - 1].attr.wrap) {
                return self.col;
            }

            // 从末尾向前查找非空格
            var len: usize = self.col;
            while (len > 0 and scr[y][len - 1].u == ' ') {
                len -= 1;
            }
            return len;
        }
        return 0;
    }

    /// 清除当前选择 (st 对齐)
    pub fn selClear(self: *Terminal) void {
        self.selection.mode = .idle;
        self.selection.ob.x = std.math.maxInt(usize);
        self.selection.nb.x = std.math.maxInt(usize);
    }

    /// 检查坐标是否在选择区域内 (st 对齐)
    pub fn isInsideSelection(self: *const Terminal, x: usize, y: usize) bool {
        const sel = self.selection;
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
    pub fn selScroll(self: *Terminal, orig: usize, n: i32) void {
        const sel = &self.selection;
        if (sel.mode == .idle) return;

        // 如果选择区域不在当前屏幕模式（主/备），则不处理
        if (sel.alt != self.mode.alt_screen) return;

        const top = orig;
        const bot = self.bot;

        const start_in = (sel.nb.y >= top and sel.nb.y <= bot);
        const end_in = (sel.ne.y >= top and sel.ne.y <= bot);

        if (start_in != end_in) {
            // 部分在滚动区域内，清除选择
            selClear(self);
        } else if (start_in) {
            // 全部在滚动区域内，移动
            const new_ob_y = @as(isize, @intCast(sel.ob.y)) + n;
            const new_oe_y = @as(isize, @intCast(sel.oe.y)) + n;
            const new_nb_y = @as(isize, @intCast(sel.nb.y)) + n;
            const new_ne_y = @as(isize, @intCast(sel.ne.y)) + n;

            if (new_nb_y < @as(isize, @intCast(top)) or new_nb_y > @as(isize, @intCast(bot)) or
                new_ne_y < @as(isize, @intCast(top)) or new_ne_y > @as(isize, @intCast(bot)))
            {
                selClear(self);
            } else {
                sel.ob.y = @as(usize, @intCast(new_ob_y));
                sel.oe.y = @as(usize, @intCast(new_oe_y));
                sel.nb.y = @as(usize, @intCast(new_nb_y));
                sel.ne.y = @as(usize, @intCast(new_ne_y));
            }
        }
    }
};
