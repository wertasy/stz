//! 文本选择和复制功能
//! 支持鼠标拖选文本、复制到剪贴板

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const x11 = @import("x11.zig");

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
    pub fn extend(self: *Selector, col: usize, row: usize, sel_type: SelectionType, done: bool) void {
        // idle 表示完全空闲（未开始或已清除），不能扩展
        if (self.selection.mode == .idle) {
            return;
        }

        // done=true 且还是 empty 模式（点击后立即释放），清除选择
        if (done and self.selection.mode == .empty) {
            self.clear();
            return;
        }

        self.selection.oe.x = col;
        self.selection.oe.y = row;
        self.selection.type = sel_type;
        self.normalize();
        self.selection.mode = if (done) .idle else .ready;
    }

    /// 标准化选择
    pub fn normalize(self: *Selector) void {
        // 正常创建选择范围，即使是单字符选择
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
        self.snap(&self.selection.nb, -1);
        self.snap(&self.selection.ne, 1);
    }

    /// 吸附到单词或行
    pub fn snap(self: *Selector, point: *Point, direction: i8) void {
        switch (self.selection.snap) {
            .none => {},
            .word => {
                // TODO: 实现单词吸附
            },
            .line => {
                point.*.x = if (direction < 0) 0 else config.Config.window.cols - 1;
            },
        }
    }

    /// 检查是否选中
    pub fn isSelected(self: *Selector, x: usize, y: usize) bool {
        // idle 模式表示没有选择，直接返回 false
        if (self.selection.mode == .idle or self.selection.ob.x == std.math.maxInt(usize)) {
            return false;
        }

        // empty 模式（已点击，等待拖动），单点也要高亮
        if (self.selection.mode == .empty) {
            return (x == self.selection.ob.x and y == self.selection.ob.y);
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
        // 如果没有选择（mode == idle 或 empty），返回空
        if (self.selection.mode == .idle or self.selection.mode == .empty) {
            return &[_]u8{};
        }
        if (self.selection.ob.x == std.math.maxInt(usize)) {
            return &[_]u8{};
        }

        var buffer = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch return &[_]u8{};
        defer buffer.deinit(self.allocator);

        const screen_opt = if (term.mode.alt_screen) term.alt else term.line;
        if (screen_opt == null) return &[_]u8{};
        const screen = screen_opt.?;

        const y_start = self.selection.nb.y;
        const y_end = self.selection.ne.y;

        for (y_start..y_end + 1) |y| {
            if (y >= screen.len) break;

            var x_start: usize = 0;
            var x_end: usize = 0;

            if (self.selection.type == .rectangular) {
                x_start = self.selection.nb.x;
                x_end = self.selection.ne.x + 1;
            } else {
                x_start = if (y == y_start) self.selection.nb.x else 0;
                x_end = if (y == y_end) self.selection.ne.x + 1 else term.col;
            }

            // 修剪尾部空格，并确保 x_end 不小于 x_start
            while (x_end > x_start and x_end <= screen[y].len and screen[y][x_end - 1].u == ' ') {
                x_end -= 1;
            }

            for (x_start..x_end) |x| {
                if (x >= screen[y].len) break;
                const glyph = screen[y][x];
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

        // 复制到 selected_text
        if (self.selected_text) |text| {
            self.allocator.free(text);
        }
        self.selected_text = try buffer.toOwnedSlice(self.allocator);
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

    /// 复制到系统剪贴板
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

                // Use XStoreBytes for legacy CUT_BUFFER0 support (optional but good for compat)
                _ = x11.XStoreBytes(dpy, text.ptr, @intCast(text.len));

                std.log.info("已复制 {d} 字符到剪贴板 (Primary Selection Acquired)\n", .{text.len});
            } else {
                std.log.info("已复制 {d} 字符到剪贴板 (X11 未初始化)\n", .{text.len});
            }
        }
    }

    /// 请求粘贴 (Convert Selection)
    pub fn requestPaste(self: *Selector) !void {
        if (self.dpy) |dpy| {
            // Request UTF8_STRING atom
            const utf8_atom = x11.getUtf8Atom(dpy);
            const target = utf8_atom;

            // XConvertSelection: requestor (win), selection (PRIMARY), target (UTF8), property (PRIMARY), time
            // We use PRIMARY as the property to store the result
            const primary_atom = x11.getPrimaryAtom(dpy);
            _ = x11.XConvertSelection(dpy, primary_atom, target, primary_atom, self.win, x11.C.CurrentTime);
            std.log.info("请求粘贴...\n", .{});
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
