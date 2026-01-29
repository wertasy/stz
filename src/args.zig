//! 命令行参数解析模块
//!
//! 支持 st 兼容的命令行参数：
//! - `-a`: 禁用备用屏幕
//! - `-c class`: 设置窗口类（未实现）
//! - `-e command [args...]`: 执行命令
//! - `-f font`: 设置字体
//! - `-g geometry`: 设置窗口几何尺寸 (colsxrows, 如 120x35)
//! - `-i`: 固定窗口（未实现）
//! - `-n name`: 设置窗口名称（未实现）
//! - `-T title` / `-t title`: 设置窗口标题
//! - `-v`: 显示版本号
//! - `-h` / `--help`: 显示帮助信息

const std = @import("std");

const VERSION = "0.1.0";

pub const Args = struct {
    // 布尔标志
    allow_altscreen: bool = true,
    // 字符串参数
    font: ?[]const u8 = null,
    shell_cmd: ?[:0]const u8 = null,
    shell_args: std.ArrayList([]const u8),
    title: ?[:0]const u8 = null,
    name: ?[:0]const u8 = null,
    class: ?[:0]const u8 = null,
    io_file: ?[:0]const u8 = null,
    line: ?[:0]const u8 = null,
    embed: ?[:0]const u8 = null,
    // 数值参数
    cols: ?usize = null,
    rows: ?usize = null,
    is_fixed: bool = false,
    // 请求帮助/版本
    show_help: bool = false,
    show_version: bool = false,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .shell_args = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shell_args.deinit(self.allocator);
    }

    /// 解析命令行参数
    pub fn parse(self: *Self, argv: [][:0]const u8) !void {
        var i: usize = 0;
        while (i < argv.len) {
            const arg = argv[i];

            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                self.show_help = true;
                return;
            } else if (std.mem.eql(u8, arg, "-v")) {
                self.show_version = true;
                return;
            } else if (std.mem.eql(u8, arg, "-a")) {
                self.allow_altscreen = false;
                i += 1;
            } else if (std.mem.eql(u8, arg, "-c")) {
                if (i + 1 >= argv.len) {
                    return error.MissingArgument;
                }
                self.class = argv[i + 1];
                i += 2;
            } else if (std.mem.eql(u8, arg, "-e")) {
                if (i + 1 >= argv.len) {
                    return error.MissingArgument;
                }
                self.shell_cmd = argv[i + 1];
                i += 2;

                // 将剩余参数作为命令参数
                while (i < argv.len) {
                    try self.shell_args.append(self.allocator, argv[i]);
                    i += 1;
                }
            } else if (std.mem.eql(u8, arg, "-f")) {
                if (i + 1 >= argv.len) {
                    return error.MissingArgument;
                }
                self.font = argv[i + 1];
                i += 2;
            } else if (std.mem.eql(u8, arg, "-g")) {
                if (i + 1 >= argv.len) {
                    return error.MissingArgument;
                }
                const geom = argv[i + 1];
                try self.parseGeometry(geom);
                i += 2;
            } else if (std.mem.eql(u8, arg, "-i")) {
                self.is_fixed = true;
                i += 1;
            } else if (std.mem.eql(u8, arg, "-l")) {
                if (i + 1 >= argv.len) {
                    return error.MissingArgument;
                }
                self.line = argv[i + 1];
                i += 2;
            } else if (std.mem.eql(u8, arg, "-n")) {
                if (i + 1 >= argv.len) {
                    return error.MissingArgument;
                }
                self.name = argv[i + 1];
                i += 2;
            } else if (std.mem.eql(u8, arg, "-o")) {
                if (i + 1 >= argv.len) {
                    return error.MissingArgument;
                }
                self.io_file = argv[i + 1];
                i += 2;
            } else if (std.mem.eql(u8, arg, "-T") or std.mem.eql(u8, arg, "-t")) {
                if (i + 1 >= argv.len) {
                    return error.MissingArgument;
                }
                self.title = argv[i + 1];
                i += 2;
            } else if (std.mem.eql(u8, arg, "-w")) {
                if (i + 1 >= argv.len) {
                    return error.MissingArgument;
                }
                self.embed = argv[i + 1];
                i += 2;
            } else {
                // 未识别的参数
                return error.UnknownOption;
            }
        }
    }

    /// 解析几何尺寸格式 "colsxrows"
    fn parseGeometry(self: *Self, geom: []const u8) !void {
        const x_pos = std.mem.indexOfScalar(u8, geom, 'x') orelse return error.InvalidGeometry;

        const cols_str = geom[0..x_pos];
        const rows_str = geom[x_pos + 1 ..];

        self.cols = try std.fmt.parseInt(usize, cols_str, 10);
        self.rows = try std.fmt.parseInt(usize, rows_str, 10);
    }

    /// 打印帮助信息
    pub fn printHelp(writer: anytype) !void {
        const help_text =
            \\用法: stz [选项]
            \\
            \\选项:
            \\  -a              禁用备用屏幕
            \\  -c class        设置窗口类 (X11 资源类)
            \\  -e command [args] 执行指定命令
            \\  -f font         设置字体 (FontConfig 格式)
            \\  -g geometry     设置窗口几何尺寸 (colsxrows, 如 120x35)
            \\  -h, --help      显示此帮助信息
            \\  -i              固定窗口大小
            \\  -l line         指定终端行号
            \\  -n name         设置窗口名称 (X11 资源名)
            \\  -o file         指定 I/O 文件
            \\  -T title        设置窗口标题
            \\  -t title        设置窗口标题 (同 -T)
            \\  -v              显示版本号
            \\  -w windowid     嵌入到指定窗口 ID
            \\
        ;
        try writer.writeAll(help_text);
    }

    /// 打印版本信息
    pub fn printVersion(writer: anytype) !void {
        try writer.print("stz {s}\n", .{VERSION});
    }

    /// 获取实际的列数（命令行优先于配置文件）
    pub fn getCols(self: *const Self, default_cols: usize) usize {
        return self.cols orelse default_cols;
    }

    /// 获取实际的行数（命令行优先于配置文件）
    pub fn getRows(self: *const Self, default_rows: usize) usize {
        return self.rows orelse default_rows;
    }

    /// 获取实际的字体（命令行优先于配置文件）
    pub fn getFont(self: *const Self, default_font: []const u8) []const u8 {
        return self.font orelse default_font;
    }

    /// 获取实际的标题（命令行优先于配置）
    pub fn getTitle(self: *const Self, default_title: []const u8) []const u8 {
        return self.title orelse default_title;
    }
};
