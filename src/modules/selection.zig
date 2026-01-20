//! 文本选择和复制功能
//! 支持鼠标拖选文本、复制到剪贴板

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const x11 = @import("x11.zig");
const scr_mod = @import("screen.zig");

const Selection = types.Selection;
const SelectionMode = types.SelectionMode;
const SelectionType = types.SelectionType;
const SelectionSnap = types.SelectionSnap;
const Point = types.Point;

pub const SelectionError = error{
    OutOfBounds,
};

/// 选择器
pub const Selector = struct {
    selection: Selection = .{},
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
    pub fn start(self: *Selector, col: usize, row: usize, snap_mode: SelectionSnap) void {
        self.selection.mode = .empty; // 已点击，但还没有拖动扩展
        self.selection.type = .regular;
        self.selection.snap = snap_mode;
        self.selection.oe.x = col;
        self.selection.oe.y = row;
        self.selection.ob.x = col;
        self.selection.ob.y = row;
        // 重置范围到无效状态，等待拖动扩展
        self.selection.nb.x = std.math.maxInt(usize);
        self.selection.nb.y = std.math.maxInt(usize);
        self.selection.ne.x = 0;
        self.selection.ne.y = 0;
    }

    /// 扩展选择
    pub fn extend(self: *Selector, term: *const types.Term, col: usize, row: usize, sel_type: SelectionType, done: bool) void {
        // idle 表示完全空闲（未开始或已清除），不能扩展
        if (self.selection.mode == .idle) {
            return;
        }

        if (done) {
            // 如果释放时还是 empty（点击未拖动），则根据 snap 模式决定是否进入 ready
            if (self.selection.mode == .empty) {
                if (self.selection.snap != .none) {
                    self.selection.mode = .ready;
                } else {
                    self.clear();
                    return;
                }
            }
            // 拖动完成后保持状态以显示高亮
        } else {
            // 只要有位移或 MotionNotify，就进入 .ready 模式
            self.selection.mode = .ready;
        }

        self.selection.oe.x = col;
        self.selection.oe.y = row;
        self.selection.type = sel_type;
        self.normalize(term);
    }

    /// 标准化选择
    pub fn normalize(self: *Selector, term: *const types.Term) void {
        // 只有在 ready 模式下才计算有效范围，支持单字符（ob == oe）
        if (self.selection.mode != .ready and self.selection.mode != .empty) return;

        if (self.selection.type == .regular and self.selection.ob.y != self.selection.oe.y) {
            self.selection.nb.x = if (self.selection.ob.y < self.selection.oe.y)
                self.selection.ob.x
            else
                self.selection.oe.x;
            self.selection.ne.x = if (self.selection.ob.y < self.selection.oe.y)
                self.selection.oe.x
            else
                self.selection.ob.x;
        } else {
            self.selection.nb.x = @min(self.selection.ob.x, self.selection.oe.x);
            self.selection.ne.x = @max(self.selection.ob.x, self.selection.oe.x);
        }

        self.selection.nb.y = @min(self.selection.ob.y, self.selection.oe.y);
        self.selection.ne.y = @max(self.selection.ob.y, self.selection.oe.y);

        // 吸附处理
        self.snap(term, &self.selection.nb, -1);
        self.snap(term, &self.selection.ne, 1);
    }

    /// 吸附到单词或行
    pub fn snap(self: *Selector, term: *const types.Term, point: *Point, direction: i8) void {
        switch (self.selection.snap) {
            .none => {},
            .word => {
                const delimiters = config.Config.selection.word_delimiters;
                var x = point.x;
                const y = point.y;
                const line = scr_mod.getVisibleLine(term, y);
                if (x >= line.len) return;

                const initial_c = line[x].u;
                const initial_is_delim = isDelim(initial_c, delimiters);

                if (direction < 0) { // 向左扩展
                    while (x > 0) {
                        const next_x = x - 1;
                        if (isDelim(line[next_x].u, delimiters) != initial_is_delim) break;
                        x = next_x;
                    }
                } else { // 向右扩展
                    while (x < line.len - 1) {
                        const next_x = x + 1;
                        if (isDelim(line[next_x].u, delimiters) != initial_is_delim) break;
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
    pub fn isSelected(self: *Selector, x: usize, y: usize) bool {
        if (self.selection.mode == .idle or self.selection.nb.x == std.math.maxInt(usize)) {
            return false;
        }

        if (self.selection.type == .regular) {
            return self.isSelectedRegular(x, y);
        } else {
            return self.isSelectedRectangular(x, y);
        }
    }

    /// 检查是否选中（常规模式）
    fn isSelectedRegular(self: *const Selector, x: usize, y: usize) bool {
        return (y >= self.selection.nb.y and y <= self.selection.ne.y) and
            (y != self.selection.nb.y or x >= self.selection.nb.x) and
            (y != self.selection.ne.y or x <= self.selection.ne.x);
    }

    /// 检查是否选中（矩形模式）
    fn isSelectedRectangular(self: *const Selector, x: usize, y: usize) bool {
        return (x >= self.selection.nb.x and x <= self.selection.ne.x and
            y >= self.selection.nb.y and y <= self.selection.ne.y);
    }

    /// 获取选中的文本
    pub fn getText(self: *Selector, term: *const types.Term) ![]u8 {
        // nb.x 为 maxInt 表示没有有效选择范围
        if (self.selection.nb.x == std.math.maxInt(usize)) {
            return &[_]u8{};
        }

        var buffer = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch return &[_]u8{};
        defer buffer.deinit(self.allocator);

        const y_start = self.selection.nb.y;
        const y_end = self.selection.ne.y;

        for (y_start..y_end + 1) |y| {
            if (y >= term.row) break;

            var x_start: usize = 0;
            var x_end: usize = 0;

            const line = scr_mod.getVisibleLine(term, y);

            if (self.selection.type == .rectangular) {
                x_start = self.selection.nb.x;
                x_end = self.selection.ne.x + 1;
            } else {
                x_start = if (y == y_start) self.selection.nb.x else 0;
                x_end = if (y == y_end) self.selection.ne.x + 1 else term.col;
            }

            // 修剪尾部空格，并确保 x_end 不小于 x_start
            while (x_end > x_start and x_end <= line.len and line[x_end - 1].u == ' ') {
                x_end -= 1;
            }

            for (x_start..x_end) |x| {
                if (x >= line.len) break;
                const glyph = line[x];
                // Convert Unicode code point to UTF-8 bytes
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(glyph.u, &buf) catch 1;
                for (buf[0..len]) |byte| {
                    try buffer.append(self.allocator, byte);
                }
            }

            // 添加换行
            if (y < y_end or (self.selection.type == .rectangular)) {
                try buffer.append(self.allocator, '\n');
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

    /// 清除选择
    pub fn clear(self: *Selector) void {
        self.selection.mode = .idle;
        // 重置所有坐标到无效状态
        self.selection.ob.x = std.math.maxInt(usize);
        self.selection.ob.y = std.math.maxInt(usize);
        self.selection.oe.x = 0;
        self.selection.oe.y = 0;
        self.selection.nb.x = std.math.maxInt(usize);
        self.selection.nb.y = std.math.maxInt(usize);
        self.selection.ne.x = 0;
        self.selection.ne.y = 0;
    }

    /// 清除高亮标记
    pub fn clearHighlights(self: *Selector, term: *types.Term) void {
        _ = self;
        _ = term;
        // TODO: 清除脏标记或重绘选择区域
    }

    /// 复制到系统剪贴板 (PRIMARY)
    pub fn copyToClipboard(self: *Selector) !void {
        if (self.selected_text) |text| {
            // 不要复制空文本
            if (text.len == 0) return;

            if (self.dpy) |dpy| {
                // Use XSetSelectionOwner to claim PRIMARY selection
                const primary_atom = x11.getPrimaryAtom(dpy);
                _ = x11.XSetSelectionOwner(dpy, primary_atom, self.win, x11.C.CurrentTime);

                if (x11.XGetSelectionOwner(dpy, primary_atom) != self.win) {
                    std.log.err("Failed to acquire selection ownership\n", .{});
                    self.clear();
                    return;
                }

                // 也顺便更新 CLIPBOARD，方便 Ctrl+V
                const clipboard_atom = x11.XInternAtom(dpy, "CLIPBOARD", 0);
                _ = x11.XSetSelectionOwner(dpy, clipboard_atom, self.win, x11.C.CurrentTime);

                // Use XStoreBytes for legacy CUT_BUFFER0 support (optional but good for compat)
                _ = x11.XStoreBytes(dpy, text.ptr, @intCast(text.len));

                std.log.info("已复制 {d} 字符到剪贴板 (PRIMARY & CLIPBOARD)\n", .{text.len});
            } else {
                std.log.info("已复制 {d} 字符到剪贴板 (X11 未初始化)\n", .{text.len});
            }
        }
    }

    /// 请求粘贴 (从 PRIMARY 选区)
    pub fn requestPaste(self: *Selector) !void {
        if (self.dpy) |dpy| {
            try self.requestSelection(x11.getPrimaryAtom(dpy));
        }
    }

    /// 从指定的 Selection (PRIMARY, CLIPBOARD 等) 请求数据
    pub fn requestSelection(self: *Selector, selection: x11.C.Atom) !void {
        if (self.dpy) |dpy| {
            const utf8_atom = x11.getUtf8Atom(dpy);
            // XConvertSelection: requestor (win), selection, target (UTF8), property (PRIMARY), time
            // 我们使用 PRIMARY 属性名作为临时存储
            const prop_atom = x11.getPrimaryAtom(dpy);
            _ = x11.XConvertSelection(dpy, selection, utf8_atom, prop_atom, self.win, x11.C.CurrentTime);
            std.log.info("请求选区内容...\n", .{});
        }
    }

    /// 处理 SelectionClear 事件
    pub fn handleSelectionClear(self: *Selector, event: *const x11.C.XSelectionClearEvent) void {
        _ = event;
        // 如果我们丢失了 PRIMARY 选区的所有权，清除当前选择
        // 实际上应该检查 event.selection 是否为 XA_PRIMARY
        self.clear();
        // 触发重绘? 需要通知外部
    }
};
