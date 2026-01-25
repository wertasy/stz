//! URL 检测和处理
//! 自动检测终端中的 URL 并提供打开功能

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const terminal = @import("terminal.zig");

const Terminal = terminal.Terminal;
const Glyph = types.Glyph;

pub const UrlError = error{
    NoUrlFound,
};

/// URL 检测器
pub const UrlDetector = struct {
    term: *Terminal,
    allocator: std.mem.Allocator,

    /// 初始化 URL 检测器
    pub fn init(term: *Terminal, allocator: std.mem.Allocator) UrlDetector {
        return UrlDetector{
            .term = term,
            .allocator = allocator,
        };
    }

    /// 高亮显示终端中的 URL
    pub fn highlightUrls(self: *UrlDetector) !void {
        const screen = if (self.term.mode.alt_screen) self.term.alt else self.term.line;
        if (screen == null) return;

        const line_buffer = try self.allocator.alloc(u8, self.term.col + 1);
        defer self.allocator.free(line_buffer);

        for (0..self.term.row) |y| {
            // 将行转换为字符串
            var line_len: usize = 0;
            for (0..self.term.col) |x| {
                const glyph = screen.?[y][x];
                const u_value = glyph.u;
                line_buffer[line_len] = if (u_value < 128) @intCast(u_value) else ' ';
                line_len += 1;
            }
            line_buffer[line_len] = 0;

            // 检测 URL
            var url_start: ?usize = null;
            for (0..line_len - 1) |i| {
                for (config.Config.url.prefixes) |prefix| {
                    if (std.mem.startsWith(u8, line_buffer[i..], prefix)) {
                        url_start = i;
                        break;
                    }
                }

                if (url_start != null) {
                    url_start = i;
                    break;
                }
            }

            if (url_start) |start| {
                // 找到 URL 前缀，继续查找 URL 结束
                var url_end: usize = start;
                while (url_end < line_len) {
                    const c = line_buffer[url_end];
                    const is_url_char = for (config.Config.url.chars) |ch| {
                        if (c == ch) {
                            break true;
                        }
                    } else false;

                    if (!is_url_char) {
                        break;
                    }
                    url_end += 1;
                }

                // 标记 URL 字符
                for (start..url_end) |x| {
                    if (x < self.term.col and x < screen.?[y].len) {
                        screen.?[y][x].attr.url = true;
                    }
                }
            }
        }
    }

    /// 清除 URL 高亮
    pub fn clearHighlights(self: *UrlDetector) void {
        const screen = if (self.term.mode.alt_screen) self.term.alt else self.term.line;
        if (screen == null) return;

        for (0..@min(self.term.row, screen.?.len)) |y| {
            for (0..@min(self.term.col, screen.?[y].len)) |x| {
                screen.?[y][x].attr.url = false;
            }
        }
    }

    /// 检查指定位置是否是 URL
    pub fn isUrlAt(self: *UrlDetector, x: usize, y: usize) bool {
        const screen = if (self.term.mode.alt_screen) self.term.alt else self.term.line;
        if (screen == null) return false;
        if (y >= screen.?.len) return false;
        if (x >= self.term.col) return false;

        return screen.?[y][x].attr.url;
    }

    /// 获取指定位置的 URL
    pub fn getUrlAt(self: *UrlDetector, x: usize, y: usize) ![]u8 {
        const screen = if (self.term.mode.alt_screen) self.term.alt else self.term.line;
        if (screen == null) return error.NoUrlFound;
        if (y >= screen.?.len) return error.NoUrlFound;
        if (x >= self.term.col) return error.NoUrlFound;

        // 查找 URL 的开始和结束
        var url_start: ?usize = null;
        var url_end: ?usize = null;

        // 向前查找 URL 开始
        var sx = x;
        while (sx > 0) {
            if (!screen.?[y][sx].attr.url) {
                if (sx + 1 < self.term.col and screen.?[y][sx + 1].attr.url) {
                    url_start = sx + 1;
                    break;
                }
            }
            sx -= 1;
        }

        if (url_start == null) {
            url_start = x;
        }

        // 向后查找 URL 结束
        var ex = url_start.?;
        while (ex < self.term.col) {
            if (!screen.?[y][ex].attr.url) {
                url_end = ex;
                break;
            }
            ex += 1;
        }

        if (url_end == null) {
            url_end = self.term.col;
        }

        // 提取 URL 字符
        const url_len = url_end.? - url_start.?;
        const url = try self.allocator.alloc(u8, url_len);
        defer self.allocator.free(url);

        for (0..url_len) |i| {
            if (screen.?[y][url_start.? + i].u < 128) {
                url[i] = @intCast(screen.?[y][url_start.? + i].u);
            } else {
                url[i] = ' ';
            }
        }

        return url;
    }

    /// 打开指定位置的 URL
    pub fn openUrlAt(self: *UrlDetector, x: usize, y: usize) !void {
        const url = try self.getUrlAt(x, y);
        defer self.allocator.free(url);

        // 移除可能的控制字符
        const len: usize = url.len;
        var start: usize = 0;
        while (start < len and std.ascii.isControl(url[start])) : (start += 1) {}

        // 分配一个带 null 终止符的缓冲区
        const url_slice = url[start..len];
        const url_terminated = try self.allocator.allocSentinel(u8, url_slice.len, 0);
        defer self.allocator.free(url_terminated);

        @memcpy(url_terminated, url_slice);

        // 构建命令并执行

        // 使用 fork + exec 来打开 URL
        const pid = std.os.linux.fork();
        if (pid < 0) {
            std.log.err("Fork failed\n", .{});
            return;
        }

        if (pid == 0) {
            // 子进程
            // 获取 URL handler
            const handler = config.Config.url.handler;

            // 准备参数（使用临时分配器）
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const argv = try arena.allocator().allocSentinel(?[*:0]const u8, 3, null);
            argv[0] = handler;
            argv[1] = url_terminated;
            argv[2] = null;

            // 执行（成功则不会返回，失败则返回错误）
            const err = std.posix.execvpeZ(argv[0].?, argv.ptr, std.c.environ);
            std.log.err("Exec failed: {}\n", .{err});
            std.posix.exit(1);
        }
    }
};
