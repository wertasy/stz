//! Parser 序列录制器
//!
//! 用于录制 parser 处理的所有转义序列和字符，便于调试问题。
//! 录制内容将写入到当前目录下的 stz.rec 文件中。

const std = @import("std");

const Recorder = @This();

file: ?std.fs.File = null,
enabled: bool = false,
start_time: i64 = 0,
byte_count: usize = 0,
allocator: std.mem.Allocator,

/// 初始化录制器
pub fn init(allocator: std.mem.Allocator) Recorder {
    return Recorder{
        .allocator = allocator,
        .file = null,
        .enabled = false,
        .start_time = 0,
        .byte_count = 0,
    };
}

/// 清理录制器
pub fn deinit(self: *Recorder) void {
    if (self.file) |f| {
        f.close();
        self.file = null;
    }
}

/// 开始录制
pub fn start(self: *Recorder) !void {
    if (self.enabled) {
        return; // 已经在录制中
    }

    // 打开录制文件 (追加模式)
    self.file = try std.fs.cwd().createFile("stz.rec", .{ .read = true });
    try self.file.?.seekFromEnd(0);

    self.enabled = true;
    self.start_time = std.time.milliTimestamp();
    self.byte_count = 0;

    // 写入录制开始标记
    const timestamp = getTimestamp();
    try self.writeComment("========== 录制开始 ==========", .{});
    try self.writeComment("时间: {s}", .{timestamp[0..10]}); // 只取前10位足够了
}

/// 停止录制
pub fn stop(self: *Recorder) void {
    if (!self.enabled) {
        return;
    }

    // 写入录制结束标记
    if (self.file) |f| {
        const timestamp = getTimestamp();
        self.writeComment("========== 录制结束 ==========", .{}) catch {};
        self.writeComment("时间: {s}", .{timestamp[0..10]}) catch {};
        self.writeComment("总字节数: {d}", .{self.byte_count}) catch {};
        self.writeComment("", .{}) catch {}; // 空行分隔

        f.close();
    }

    self.file = null;
    self.enabled = false;
    self.byte_count = 0;
}

/// 切换录制状态
pub fn toggle(self: *Recorder) !void {
    if (self.enabled) {
        self.stop();
        std.log.info("录制已停止,内容已保存到 stz.rec", .{});
    } else {
        try self.start();
        std.log.info("录制已开始,内容将保存到 stz.rec", .{});
    }
}

/// 录制原始字节
pub fn record(self: *Recorder, bytes: []const u8) !void {
    if (!self.enabled or self.file == null) {
        return;
    }

    const f = self.file.?;

    // 写入时间戳（固定宽度格式，便于对齐）
    const elapsed = std.time.milliTimestamp() - self.start_time;
    {
        var buf: [32]u8 = undefined;
        const header = try std.fmt.bufPrint(&buf, "[+{d:<7}ms] ", .{elapsed});
        try f.writeAll(header);
    }

    // 写入十六进制转储
    for (bytes, 0..) |b, i| {
        {
            var buf: [8]u8 = undefined;
            const hex = try std.fmt.bufPrint(&buf, "{x:0>2} ", .{b});
            try f.writeAll(hex);
        }

        // 每 16 字节换行
        if (i % 16 == 15) {
            try f.writeAll(" | ");

            // 写入 ASCII 表示
            for (bytes[i - 15 .. i + 1]) |c| {
                if (c >= 32 and c <= 126) {
                    try f.writeAll(&[_]u8{c});
                } else {
                    try f.writeAll(".");
                }
            }

            try f.writeAll("\n             "); // 13个空格，与时间戳宽度对齐
        }
    }

    // 处理最后一行
    if (bytes.len > 0 and bytes.len % 16 != 0) {
        const remaining = bytes.len % 16;
        const padding = 16 - remaining;

        // 填充空格
        for (0..padding) |_| {
            try f.writeAll("   ");
        }

        try f.writeAll(" | ");

        // 写入 ASCII 表示
        for (bytes[bytes.len - remaining ..]) |c| {
            if (c >= 32 and c <= 126) {
                try f.writeAll(&[_]u8{c});
            } else {
                try f.writeAll(".");
            }
        }

        try f.writeAll("\n");
    } else if (bytes.len > 0) {
        try f.writeAll("\n");
    }

    self.byte_count += bytes.len;
}

/// 录制转义序列 (带注释)
pub fn recordEscape(self: *Recorder, bytes: []const u8, comptime fmt: []const u8, args: anytype) !void {
    if (!self.enabled or self.file == null) {
        return;
    }

    // 写入注释
    try self.writeComment(fmt, args);

    // 写入原始字节
    try self.record(bytes);
}

/// 写入注释行
fn writeComment(self: *Recorder, comptime fmt: []const u8, args: anytype) !void {
    if (!self.enabled or self.file == null) {
        return;
    }

    var buffer: [1024]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buffer, "# " ++ fmt ++ "\n", args);
    try self.file.?.writeAll(msg);
}

/// 获取当前时间戳字符串
fn getTimestamp() [32]u8 {
    const timestamp = std.time.timestamp();
    var buf: [32]u8 = undefined;

    // 使用 Unix 时间戳
    _ = std.fmt.bufPrint(&buf, "{d}", .{timestamp}) catch return [1]u8{'?'} ** 32;
    return buf;
}
