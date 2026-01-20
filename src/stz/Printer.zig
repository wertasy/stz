//! 终端打印/导出模块
//! 实现屏幕内容打印、选择文本导出等功能

const std = @import("std");
const stz = @import("stz");

const posix = std.posix;
const types = stz.types;
const Selector = stz.Selector;
const unicode = stz.unicode;
const Terminal = stz.Terminal;

/// 打印器配置
pub const Config = struct {
    /// 是否启用自动打印模式
    enabled: bool = false,
    /// 输出文件路径（默认为 stdout）
    output_file: ?[]const u8 = null,
    /// 输出文件描述符
    fd: posix.fd_t = posix.STDOUT_FILENO,
};

const Printer = @This();

allocator: std.mem.Allocator,
config: Config,

/// 初始化打印器
pub fn init(allocator: std.mem.Allocator) Printer {
    return Printer{
        .allocator = allocator,
        .config = Config{},
    };
}

/// 反初始化打印器
pub fn deinit(self: *Printer) void {
    if (self.config.fd != posix.STDOUT_FILENO and self.config.fd != posix.STDERR_FILENO) {
        posix.close(self.config.fd);
    }
}

/// 切换打印模式
pub fn toggle(self: *Printer, term: *Terminal) !void {
    self.config.enabled = !self.config.enabled;
    if (self.config.enabled) {
        std.log.info("打印模式已启用", .{});
    } else {
        std.log.info("打印模式已禁用", .{});
    }
    term.mode.print = self.config.enabled;
}

/// 打印当前屏幕内容（printscreen）
pub fn printScreen(self: *Printer, term: *Terminal) !void {
    const screen = if (term.mode.alt_screen) term.alt_screen else term.screen;
    if (screen == null) return;

    for (0..term.row) |y| {
        try self.dumpLine(screen.?[y], term.col);
        try self.write("\n");
    }

    std.log.info("已打印屏幕内容", .{});
}

/// 打印选择内容（printsel）
pub fn printSelection(self: *Printer, term: *Terminal, sel: *Selector) !void {
    const text = try sel.getText(term);

    try self.write(text);
    try self.write("\n");

    std.log.info("已打印选择内容", .{});
}

/// 打印单行内容
fn dumpLine(self: *Printer, line: []types.Glyph, col: usize) !void {
    var buf: [4]u8 = undefined;

    // 找到最后一个非空字符
    var end: usize = col;
    while (end > 0 and line[end - 1].codepoint == ' ') {
        end -= 1;
    }

    // 如果整行都是空格，只打印换行
    if (end == 0) return;

    // 打印字符
    for (0..end) |x| {
        const glyph = line[x];
        if (glyph.codepoint == 0) {
            // 跳过空字符
            continue;
        }

        const len = unicode.encode(glyph.codepoint, &buf) catch |err| {
            std.log.err("UTF-8 编码失败: {}", .{err});
            continue;
        };

        try self.write(buf[0..len]);
    }
}

/// 打印任意文本（用于自动打印模式）
pub fn printText(self: *Printer, text: []const u8) !void {
    if (self.config.enabled) {
        try self.write(text);
    }
}

/// 写入数据到输出
fn write(self: *Printer, data: []const u8) !void {
    const bytes_written = posix.write(self.config.fd, data) catch |err| {
        std.log.err("写入输出失败: {}", .{err});
        if (self.config.fd != posix.STDOUT_FILENO and self.config.fd != posix.STDERR_FILENO) {
            posix.close(self.config.fd);
            self.config.fd = posix.STDOUT_FILENO;
        }
        return err;
    };

    if (bytes_written != data.len) {
        std.log.err("写入不完整: {} / {}", .{ bytes_written, data.len });
        return error.WriteIncomplete;
    }
}

/// 打印字符（用于自动打印模式）
pub fn printChar(self: *Printer, c: u32) !void {
    if (!self.config.enabled) return;

    var buf: [4]u8 = undefined;
    const len = unicode.encode(c, &buf) catch |err| {
        std.log.err("UTF-8 编码失败: {}", .{err});
        return err;
    };

    try self.write(buf[0..len]);
}

/// 打印控制序列（用于自动打印模式）
pub fn printControl(self: *Printer, c: u8) !void {
    if (!self.config.enabled) return;

    // 简单的控制字符处理
    const str = switch (c) {
        '\n' => "\n",
        '\r' => "\r",
        '\t' => "\t",
        else => {
            std.log.debug("Printer忽略的控制字符: 0x{x}", .{c});
            return;
        },
    };

    try self.write(str);
}
