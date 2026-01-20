//! stz - 简单终端模拟器 (Zig 重写版)
//! 主程序入口和事件循环（SDL2 版本）

const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});
const x11 = @import("modules/x11.zig");

const Terminal = @import("modules/terminal.zig").Terminal;
const PTY = @import("modules/pty.zig").PTY;
const Window = @import("modules/window.zig").Window;
const Renderer = @import("modules/renderer.zig").Renderer;
const Input = @import("modules/input.zig").Input;
const Selector = @import("modules/selection.zig").Selector;
const UrlDetector = @import("modules/url.zig").UrlDetector;
const config = @import("modules/config.zig");

pub fn main() !u8 {
    // 获取分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("内存泄漏\n", .{});
        }
    }
    const allocator = gpa.allocator();

    // 解析命令行参数
    const cols = config.Config.window.cols;
    const rows = config.Config.window.rows;
    const shell_path = config.Config.shell;

    std.log.info("stz - Zig 终端模拟器 v0.1.0\n", .{});
    std.log.info("尺寸: {d}x{d}\n", .{ cols, rows });

    // 初始化 PTY
    var pty = try PTY.init(shell_path, cols, rows);
    defer pty.close();

    std.log.info("PTY PID: {d}\n", .{pty.pid});

    // 设置 TERM 环境变量
    _ = c.setenv("TERM", config.Config.term_type, 1);

    // 初始化终端
    var terminal = try Terminal.init(rows, cols, allocator);
    // 修复 Parser 中的 Term 指针（解决移动语义导致的悬垂指针问题）
    terminal.parser.term = &terminal.term;
    defer terminal.deinit();

    // 初始化窗口
    var window = try Window.init("stz", cols, rows, allocator);
    defer window.deinit();

    // 显示窗口
    window.show();

    // 初始化渲染器
    var renderer = try Renderer.init(&window, allocator);
    defer renderer.deinit();

    // 初始化输入处理器
    var input = Input.init(&pty);

    // 初始化选择器
    // var selector = Selector.init(allocator);

    // 初始化 URL 检测器
    var url_detector = UrlDetector.init(&terminal.term, allocator);

    // 主事件循环
    const read_buffer = try allocator.alloc(u8, 8192);
    defer allocator.free(read_buffer);

    var quit: bool = false;
    // var mouse_pressed: bool = false;
    // var mouse_x: usize = 0;
    // var mouse_y: usize = 0;

    while (!quit) {
        // 读取 PTY 数据
        const n = pty.read(read_buffer) catch |err| {
            if (err == error.ReadFailed) {
                // PTY 关闭
                quit = true;
                break;
            }
            return err;
        };

        if (n > 0) {
            // 处理终端数据
            try terminal.processBytes(read_buffer[0..n]);

            // 检测并高亮 URL
            try url_detector.highlightUrls();

            // 渲染
            try renderer.render(&terminal.term);
            try renderer.renderCursor(&terminal.term);
            window.present();
        }

        // 处理 X11 事件
        while (window.pollEvent()) |event| {
            switch (event.type) {
                x11.ClientMessage => {
                    // TODO: Handle WM_DELETE_WINDOW
                    // if (event.xclient.data.l[0] == wm_delete_window) ...
                },
                x11.KeyPress => {
                    try input.handleKey(&event.xkey);
                },
                x11.ConfigureNotify => {
                    const ev = event.xconfigure;
                    const new_w = ev.width;
                    const new_h = ev.height;

                    if (new_w != window.width or new_h != window.height) {
                        window.width = @intCast(new_w);
                        window.height = @intCast(new_h);
                        window.resizeBuffer(@intCast(new_w), @intCast(new_h));

                        // Resize terminal
                        // ... calculation logic ...
                        // try terminal.resize(new_rows, new_cols);
                        // try pty.resize(new_cols, new_rows);
                    }
                },
                x11.Expose => {
                    try renderer.render(&terminal.term);
                    try renderer.renderCursor(&terminal.term);
                    window.present();
                },
                else => {},
            }
        }
    }

    // 清除 URL 高亮
    url_detector.clearHighlights();

    // 等待子进程结束
    const exit_status = try pty.wait();
    std.log.info("子进程退出，状态: {d}\n", .{exit_status});

    return exit_status;
}
