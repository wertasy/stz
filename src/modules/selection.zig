//! 文本选择和复制功能
//! 支持鼠标拖选文本、复制到剪贴板

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");

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

    /// 初始化选择器
    pub fn init(allocator: std.mem.Allocator) Selector {
        return Selector{
            .allocator = allocator,
        };
    }

    /// 清理选择器
    pub fn deinit(self: *Selector) void {
        if (self.selected_text) |text| {
            self.allocator.free(text);
        }
    }

    /// 开始选择
    pub fn start(self: *Selector, col: usize, row: usize, snap_mode: SelectionSnap) void {
        self.selection.mode = .empty;
        self.selection.type = .regular;
        self.selection.snap = snap_mode;
        self.selection.oe.x = col;
        self.selection.oe.y = row;
        self.selection.ob.x = col;
        self.selection.ob.y = row;
        self.normalize();
    }

    /// 扩展选择
    pub fn extend(self: *Selector, col: usize, row: usize, sel_type: SelectionType, done: bool) void {
        _ = col;
        _ = row;
        if (self.selection.mode == .idle) {
            return;
        }

        if (done and self.selection.mode == .empty) {
            self.clear();
            return;
        }

        self.selection.type = sel_type;
        self.normalize();
        self.selection.mode = if (done) .idle else .ready;
    }

    /// 标准化选择
    pub fn normalize(self: *Selector) void {
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
        self.snap(&self.selection.ne.x, 1);
    }

    /// 吸附到单词或行
    pub fn snap(self: *Selector, point: *Point, direction: i8) void {
        switch (self.selection.snap) {
            .word => {
                // TODO: 实现单词吸附
            },
            .line => {
                point.*.x = if (direction < 0) 0 else config.Config.window.cols - 1;
            },
            else => {},
        }
    }

    /// 检查是否选中
    pub fn isSelected(self: *Selector, x: usize, y: usize) bool {
        if (self.selection.mode == .empty or self.selection.ob.x == usize.max) {
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
        if (self.selection.ob.x == usize.max) {
            return &[_]u8{};
        }

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        const screen = if (term.mode.alt_screen) term.alt else term.line;
        if (screen == null) return &[_]u8{};

        const y_start = self.selection.nb.y;
        const y_end = self.selection.ne.y;

        for (y_start..y_end + 1) |y| {
            if (y >= screen.len) break;

            var x_start: usize = 0;
            var x_end: usize = 0;

            if (self.selection.type == .rectangular) {
                x_start = self.selection.nb.x;
                x_end = self.selection.ne.x;
            } else {
                x_start = if (y == y_start) self.selection.nb.x else 0;
                x_end = if (y == y_end) self.selection.ne.x else config.Config.window.cols - 1;
            }

            // 查找非空格的起始和结束位置
            while (x_start < screen[y].len and screen[y][x_start].u == ' ') {
                x_start += 1;
            }
            while (x_end > 0 and screen[y][x_end - 1].u == ' ') {
                x_end -= 1;
            }

            for (x_start..x_end) |x| {
                if (x >= screen[y].len) break;
                const glyph = screen[y][x];
                try buffer.append(glyph.u);
            }

            // 添加换行
            if (y < y_end or (self.selection.type == .rectangular)) {
                try buffer.append('\n');
            }
        }

        // 复制到 selected_text
        if (self.selected_text) |text| {
            self.allocator.free(text);
        }
        self.selected_text = try buffer.toOwnedSlice();
        return self.selected_text.?;
    }

    /// 清除选择
    pub fn clear(self: *Selector) void {
        self.selection.mode = .idle;
        self.selection.ob.x = usize.max;
    }

    /// 复制到系统剪贴板
    pub fn copyToClipboard(self: *Selector) !void {
        if (self.selected_text) |text| {
            // TODO: 使用 SDL 设置剪贴板
            std.log.info("已复制 {d} 字符到剪贴板\n", .{text.len});
        }
    }
};
