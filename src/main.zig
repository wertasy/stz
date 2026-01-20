//! stz - 简单终端模拟器 (Zig 重写版)
//! 主程序入口和事件循环（SDL2 版本）

const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});
const sdl = @import("modules/sdl.zig");

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
    var selector = Selector.init(allocator);

    // 初始化 URL 检测器
    var url_detector = UrlDetector.init(&terminal.term, allocator);

    // 主事件循环
    const read_buffer = try allocator.alloc(u8, 8192);
    defer allocator.free(read_buffer);

    var quit: bool = false;
    var mouse_pressed: bool = false;
    var mouse_x: usize = 0;
    var mouse_y: usize = 0;

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
        }

        // 处理 SDL 事件
        while (true) {
            const event = window.pollEvent() orelse break;

            switch (event.type) {
                sdl.SDL_QUIT => {
                    std.log.info("退出请求\n", .{});
                    quit = true;
                    break;
                },

                sdl.SDL_KEYDOWN => {
                    // 处理键盘输入
                    try input.handleKey(&event.key);
                },

                sdl.SDL_KEYUP => {
                    // 释放键
                },

                sdl.SDL_MOUSEBUTTONDOWN => {
                    // 鼠标按下
                    const button = event.button.button;

                    if (button == sdl.SDL_BUTTON_LEFT) {
                        if (!mouse_pressed) {
                            // 开始选择
                            selector.start(mouse_x, mouse_y, .word);
                            mouse_pressed = true;
                        }
                    }
                },

                sdl.SDL_MOUSEBUTTONUP => {
                    // 鼠标释放
                    const button = event.button.button;

                    if (button == sdl.SDL_BUTTON_LEFT and mouse_pressed) {
                        // 结束选择并复制
                        selector.clearHighlights(&terminal.term);
                        try selector.copyToClipboard();
                        try url_detector.highlightUrls();
                        mouse_pressed = false;
                    }
                },

                sdl.SDL_MOUSEMOTION => {
                    // 鼠标移动
                    if (mouse_pressed) {
                        // 扩展选择
                        const rect_x = @as(i32, @intCast(event.motion.x)) - @as(i32, @intCast(config.Config.window.border_pixels));
                        const rect_y = @as(i32, @intCast(event.motion.y)) - @as(i32, @intCast(config.Config.window.border_pixels));
                        const cell_width_i32 = @as(i32, @intCast(window.cell_width));
                        const cell_height_i32 = @as(i32, @intCast(window.cell_height));
                        const col = @max(0, @min(@divTrunc(rect_x, cell_width_i32), @as(i32, @intCast(cols)) - 1));
                        const row = @max(0, @min(@divTrunc(rect_y, cell_height_i32), @as(i32, @intCast(rows)) - 1));

                        selector.extend(col, row, .regular, false);
                    }
                    const rect_x = @as(i32, @intCast(event.motion.x)) - @as(i32, @intCast(config.Config.window.border_pixels));
                    const rect_y = @as(i32, @intCast(event.motion.y)) - @as(i32, @intCast(config.Config.window.border_pixels));
                    const cell_width_i32 = @as(i32, @intCast(window.cell_width));
                    const cell_height_i32 = @as(i32, @intCast(window.cell_height));
                    mouse_x = @max(0, @min(@divTrunc(rect_x, cell_width_i32), @as(i32, @intCast(cols)) - 1));
                    mouse_y = @max(0, @min(@divTrunc(rect_y, cell_height_i32), @as(i32, @intCast(rows)) - 1));
                },

                sdl.SDL_WINDOWEVENT => {
                    // 窗口事件
                    if (event.window.event == sdl.SDL_WINDOWEVENT_RESIZED) {
                        const new_w = event.window.data1;
                        const new_h = event.window.data2;
                        std.log.info("窗口调整: {d}x{d}\n", .{ new_w, new_h });

                        // 计算新的列数和行数
                        const border_w = @as(i32, @intCast(config.Config.window.border_pixels)) * 2;
                        const new_cols_w = new_w - border_w;
                        const new_rows_h = new_h - border_w;
                        const cell_w_i32 = @as(i32, @intCast(window.cell_width));
                        const cell_h_i32 = @as(i32, @intCast(window.cell_height));
                        const new_cols = @max(config.Config.window.min_cols, @as(usize, @intCast(@divTrunc(new_cols_w, cell_w_i32))));
                        const new_rows = @max(config.Config.window.min_rows, @as(usize, @intCast(@divTrunc(new_rows_h, cell_h_i32))));

                        // 调整终端
                        try terminal.resize(new_rows, new_cols);

                        // 调整 PTY
                        try pty.resize(new_cols, new_rows);
                    }
                },

                else => {},
            }
        }

        // 渲染终端内容
        try renderer.render(&terminal.term);

        // 渲染光标
        try renderer.renderCursor(&terminal.term);

        // 呈现
        window.present();

        // 垂直同步由 SDL_RENDERER_PRESENTVSYNC 自动处理
    }

    // 清除 URL 高亮
    url_detector.clearHighlights();

    // 等待子进程结束
    const exit_status = try pty.wait();
    std.log.info("子进程退出，状态: {d}\n", .{exit_status});

    return exit_status;
}
