//! 文本选择和复制功能
//! 支持鼠标拖选文本、复制到剪贴板
//!
//! 选择器的核心功能：
//! - 鼠标拖拽选择：开始选择（ButtonPress）、扩展选择（MotionNotify）、结束选择（ButtonRelease）
//! - 智能选择边界：单词吸附（双击）、行吸附（三击）
//! - 选择标准化：始终将选择区域规范化为左上角到右下角
//! - 复制到剪贴板：X11 PRIMARY 和 CLIPBOARD 选择
//! - 从剪贴板粘贴：接收 SelectionNotify 事件，粘贴到 PTY
//!
//! 选择模式：
//! - idle: 空闲，没有选择
//! - empty: 开始了选择但未拖动（单击）
//! - ready: 选择完成，可以复制
//!
//! 选择类型：
//! - regular: 普通选择（文本选择）
//! - rectangular: 矩形选择（列选择）
//!
//! 选择吸附模式：
//! - none: 不吸附，精确到字符（单击）
//! - word: 单词吸附，扩展到单词边界（双击）
//! - line: 行吸附，扩展到整行（三击）
//!
//! 单词边界规则：
//! - 单词分隔符在 config.zig 的 word_delimiters 中定义
//! - 默认分隔符：空格、逗号、引号、括号等
//! - 吸附时会扩展到最近的分隔符
//!
//! 选择流程：
//! 1. ButtonPress: 调用 start()，设置起点（ob, oe）
//! 2. MotionNotify: 调用 extend()，更新终点（oe），规范化区域（nb, ne）
//! 3. ButtonRelease: 调用 copy()，复制到 X11 剪贴板
//!
//! 选择区域规范化：
//! - 无论用户从哪个方向拖拽，nb 总是左上角，ne 总是右下角
//! - 方便处理选择文本和渲染高亮
//!
//! X11 选择机制：
//! - PRIMARY: 鼠标选择（中键粘贴）
//! - CLIPBOARD: Ctrl+C/Ctrl+V 选择（现代应用）
//! - SelectionRequest: 其他应用请求选择内容
//! - SelectionNotify: 其他应用发送选择内容（粘贴）
//!
//! 与剪贴板的交互：
//! - copy(): 将选择的文本编码为 UTF-8，设置到 X11 剪贴板
//! - requestPaste(): 请求 X11 剪贴板内容（中键粘贴）
//! - handleSelectionRequest(): 处理其他应用的请求
//! - handleSelectionNotify(): 处理其他应用发送的内容（粘贴）

const std = @import("std");
const stz = @import("stz");

const types = stz.types;
const Terminal = stz.Terminal;
const config = stz.Config;
const x11 = stz.c.x11;
const x11_utils = stz.x11_utils;

const Selection = types.Selection;
const SelectionMode = types.SelectionMode;
const SelectionType = types.SelectionType;
const SelectionSnap = types.SelectionSnap;
const Point = types.Point;

pub const SelectionError = error{
    OutOfBounds,
};

/// 选择器
const Selector = @This();
allocator: std.mem.Allocator,
selected_text: ?[]u8 = null,
// X11 context (set externally)
dpy: ?*x11.Display = null,
win: x11.Window = 0,

/// 初始化选择器
pub fn init(allocator: std.mem.Allocator) Selector {
    return Selector{
        .allocator = allocator,
    };
}

/// 设置 X11 上下文
pub fn setX11Context(self: *Selector, dpy: *x11.Display, win: x11.Window) void {
    self.dpy = dpy;
    self.win = win;
}

/// 清理选择器
pub fn deinit(self: *Selector) void {
    if (self.selected_text) |text| {
        self.allocator.free(text);
    }
}

/// 开始选择
pub fn start(self: *Selector, term: *Terminal, col: usize, row: usize, snap_mode: SelectionSnap) void {
    _ = self;
    const sel = &term.selection;
    sel.mode = .empty; // 已点击，但还没有拖动扩展
    sel.type = .regular;
    sel.snap = snap_mode;
    sel.oe.x = col;
    sel.oe.y = row;
    sel.ob.x = col;
    sel.ob.y = row;
    sel.alt = term.mode.alt_screen;
    // 重置范围到无效状态，等待拖动扩展
    sel.nb.x = std.math.maxInt(usize);
    sel.nb.y = std.math.maxInt(usize);
    sel.ne.x = 0;
    sel.ne.y = 0;
}

/// 扩展选择
pub fn extend(self: *Selector, term: *Terminal, col: usize, row: usize, sel_type: SelectionType, done: bool) void {
    const sel = &term.selection;
    // idle 表示完全空闲（未开始或已清除），不能扩展
    if (sel.mode == .idle) {
        return;
    }

    if (done) {
        // 如果释放时还是 empty（点击未拖动），则根据 snap 模式决定是否进入 ready
        if (sel.mode == .empty) {
            if (sel.snap != .none) {
                sel.mode = .ready;
            } else {
                self.clear(term);
                return;
            }
        }
        // 拖动完成后保持状态以显示高亮
    } else {
        // 只要有位移或 MotionNotify，就进入 .ready 模式
        sel.mode = .ready;
    }

    sel.oe.x = col;
    sel.oe.y = row;
    sel.type = sel_type;
    self.normalize(term);
}

/// 标准化选择
pub fn normalize(self: *Selector, term: *Terminal) void {
    const sel = &term.selection;
    // 只有在 ready 模式下才计算有效范围，支持单字符（ob == oe）
    if (sel.mode != .ready and sel.mode != .empty) return;

    if (sel.type == .regular and sel.ob.y != sel.oe.y) {
        sel.nb.x = if (sel.ob.y < sel.oe.y)
            sel.ob.x
        else
            sel.oe.x;
        sel.ne.x = if (sel.ob.y < sel.oe.y)
            sel.oe.x
        else
            sel.ob.x;
    } else {
        sel.nb.x = @min(sel.ob.x, sel.oe.x);
        sel.ne.x = @max(sel.ob.x, sel.oe.x);
    }

    sel.nb.y = @min(sel.ob.y, sel.oe.y);
    sel.ne.y = @max(sel.ob.y, sel.oe.y);

    // 吸附处理
    self.snap(term, &sel.nb, -1);
    self.snap(term, &sel.ne, 1);
}

/// 吸附到单词或行
pub fn snap(self: *Selector, term: *const Terminal, point: *Point, direction: i8) void {
    _ = self;
    const sel = &term.selection;
    switch (sel.snap) {
        .none => {},
        .word => {
            const delimiters = config.selection.word_delimiters;
            var x = point.x;
            const y = point.y;
            const line = term.getVisibleLine(y);
            if (x >= line.len) return;

            const initial_c = line[x].codepoint;
            const initial_is_delim = isDelim(initial_c, delimiters);

            if (direction < 0) { // 向左扩展
                while (x > 0) {
                    const next_x = x - 1;
                    if (isDelim(line[next_x].codepoint, delimiters) != initial_is_delim) break;
                    x = next_x;
                }
            } else { // 向右扩展
                while (x < line.len - 1) {
                    const next_x = x + 1;
                    if (isDelim(line[next_x].codepoint, delimiters) != initial_is_delim) break;
                    x = next_x;
                }
            }
            point.x = x;
        },
        .line => {
            point.x = if (direction < 0) 0 else term.col - 1;
        },
    }
}

fn isDelim(c: u21, delimiters: []const u8) bool {
    if (c == ' ' or c == 0) return true;
    for (delimiters) |d| {
        if (c == d) return true;
    }
    return false;
}

/// 检查是否选中
pub fn isSelected(self: *Selector, term: *const Terminal, x: usize, y: usize) bool {
    _ = self;
    return term.isInsideSelection(x, y);
}

/// 获取选中的文本
pub fn getText(self: *Selector, term: *const Terminal) ![]u8 {
    const sel = &term.selection;
    // nb.x 为 maxInt 表示没有有效选择范围
    if (sel.nb.x == std.math.maxInt(usize)) {
        return &[_]u8{};
    }

    var buffer = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch return &[_]u8{};
    defer buffer.deinit(self.allocator);

    const y_start = sel.nb.y;
    const y_end = sel.ne.y;

    for (y_start..y_end + 1) |y| {
        if (y >= term.row) break;

        var x_start: usize = 0;
        var x_end: usize = 0;

        const line = term.getVisibleLine(y);

        if (sel.type == .rectangular) {
            x_start = sel.nb.x;
            x_end = sel.ne.x + 1;
        } else {
            x_start = if (y == y_start) sel.nb.x else 0;
            x_end = if (y == y_end) sel.ne.x + 1 else term.col;
        }

        // 检查行尾换行属性 (st 对齐)
        const is_wrapped = line[line.len - 1].attr.wrap;

        // 修剪尾部空格，并确保 x_end 不小于 x_start
        if (!is_wrapped) {
            while (x_end > x_start and x_end <= line.len and line[x_end - 1].codepoint == ' ') {
                x_end -= 1;
            }
        }

        for (x_start..x_end) |x| {
            if (x >= line.len) break;
            const glyph = line[x];
            // Convert Unicode code point to UTF-8 bytes
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(glyph.codepoint, &buf) catch 1;
            for (buf[0..len]) |byte| {
                try buffer.append(self.allocator, byte);
            }
        }

        // 添加换行
        if (y < y_end or (sel.type == .rectangular)) {
            if (sel.type == .rectangular or !is_wrapped) {
                try buffer.append(self.allocator, '\n');
            }
        }
    }

    // 复制到 selected_text (去除首尾空白)
    const raw_text = try buffer.toOwnedSlice(self.allocator);
    defer self.allocator.free(raw_text);
    const trimmed = std.mem.trim(u8, raw_text, " \n\r\t");

    if (self.selected_text) |text| {
        self.allocator.free(text);
    }
    self.selected_text = try self.allocator.dupe(u8, trimmed);
    return self.selected_text.?;
}

/// 复制当前选中的文本
pub fn copy(self: *Selector, term: *const Terminal) !void {
    _ = try self.getText(term);
    try self.copyToClipboard();
}

/// 清除选择
pub fn clear(self: *Selector, term: *Terminal) void {
    _ = self;
    term.selClear();
}

/// 清除高亮标记
pub fn clearHighlights(self: *Selector, term: *Terminal) void {
    _ = self;
    _ = term;
    // TODO: 清除脏标记或重绘选择区域
}

/// 复制指定文本到系统剪贴板
pub fn copyTextToClipboard(self: *Selector, text: []const u8, mask: u8) !void {
    if (text.len == 0) return;

    if (self.dpy) |dpy| {
        if ((mask & 2) != 0) {
            // PRIMARY
            const primary_atom = x11_utils.getPrimaryAtom(dpy);
            _ = x11.XSetSelectionOwner(dpy, primary_atom, self.win, x11.CurrentTime);
        }
        if ((mask & 1) != 0) {
            // CLIPBOARD
            const clipboard_atom = x11_utils.getClipboardAtom(dpy);
            _ = x11.XSetSelectionOwner(dpy, clipboard_atom, self.win, x11.CurrentTime);
        }

        // 更新 selected_text 以便 SelectionRequest 处理
        if (self.selected_text) |old| {
            self.allocator.free(old);
        }
        self.selected_text = try self.allocator.dupe(u8, text);

        // XStoreBytes for legacy
        _ = x11.XStoreBytes(dpy, text.ptr, @intCast(text.len));

        std.log.info("已通过 OSC 52 复制 {d} 字符到剪贴板", .{text.len});
    }
}

/// 复制到系统剪贴板 (PRIMARY)
pub fn copyToClipboard(self: *Selector) !void {
    if (self.selected_text) |text| {
        // 不要复制空文本
        if (text.len == 0) return;

        if (self.dpy) |dpy| {
            // Use XSetSelectionOwner to claim PRIMARY selection
            const primary_atom = x11_utils.getPrimaryAtom(dpy);
            _ = x11.XSetSelectionOwner(dpy, primary_atom, self.win, x11.CurrentTime);

            if (x11.XGetSelectionOwner(dpy, primary_atom) != self.win) {
                std.log.err("Failed to acquire selection ownership", .{});
                return;
            }

            // 也顺便更新 CLIPBOARD，方便 Ctrl+V
            const clipboard_atom = x11_utils.getClipboardAtom(dpy);
            _ = x11.XSetSelectionOwner(dpy, clipboard_atom, self.win, x11.CurrentTime);

            // Use XStoreBytes for legacy CUT_BUFFER0 support (optional but good for compat)
            _ = x11.XStoreBytes(dpy, text.ptr, @intCast(text.len));

            // std.log.info("已复制 {d} 字符到剪贴板 (PRIMARY & CLIPBOARD)", .{text.len});
        } else {
            std.log.info("已复制 {d} 字符到剪贴板 (X11 未初始化)", .{text.len});
        }
    }
}

/// 请求粘贴 (从 PRIMARY 选区)
pub fn requestPaste(self: *Selector) !void {
    if (self.dpy) |dpy| {
        try self.requestSelection(x11_utils.getPrimaryAtom(dpy));
    }
}

/// 从指定的 Selection (PRIMARY, CLIPBOARD 等) 请求数据
pub fn requestSelection(self: *Selector, selection: x11.Atom) !void {
    if (self.dpy) |dpy| {
        const utf8_atom = x11_utils.getUtf8Atom(dpy);
        // XConvertSelection: requestor (win), selection, target (UTF8), property (selection), time
        // 对齐 st：使用 selection atom 作为 property 名
        _ = x11.XConvertSelection(dpy, selection, utf8_atom, selection, self.win, x11.CurrentTime);
    }
}

/// 处理 SelectionClear 事件
pub fn handleSelectionClear(self: *Selector, term: *Terminal, event: *const x11.XSelectionClearEvent) void {
    _ = event;
    // 如果我们丢失了选区的所有权，清除当前高亮
    self.clear(term);
}
