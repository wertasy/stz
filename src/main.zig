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
    var selector = Selector.init(allocator);
    selector.setX11Context(window.dpy, window.win);
    defer selector.deinit();

    // 初始化 URL 检测器
    var url_detector = UrlDetector.init(&terminal.term, allocator);

    // 主事件循环
    const read_buffer = try allocator.alloc(u8, 8192);
    defer allocator.free(read_buffer);

    var quit: bool = false;
    var mouse_pressed: bool = false;
    var mouse_x: usize = 0;
    var mouse_y: usize = 0;

    // Paste buffer (for receiving X11 selection)
    var paste_buffer = try std.ArrayList(u8).initCapacity(allocator, 4096);

    // 设置 PTY 为非阻塞模式
    try pty.setNonBlocking();

    while (!quit) {
        // Alias term for easy access
        const term = &terminal.term;

        // 1. 处理所有挂起的 X11 事件
        while (window.pollEvent()) |event| {
            switch (event.type) {
                x11.ClientMessage => {
                    // TODO: Handle WM_DELETE_WINDOW
                    // if (event.xclient.data.l[0] == wm_delete_window) ...
                },
                x11.KeyPress => {
                    renderer.resetCursorBlink(); // Reset blink on input

                    // Check for scroll shortcuts (Shift + PageUp/PageDown)
                    const state = event.xkey.state;
                    const shift = (state & x11.ShiftMask) != 0;
                    const keycode = event.xkey.keycode;
                    const keysym = x11.XkbKeycodeToKeysym(window.dpy, @intCast(keycode), 0, if (shift) 1 else 0);

                    const XK_Prior = 0xFF55; // PageUp
                    const XK_Next = 0xFF56; // PageDown
                    const XK_KP_Prior = 0xFF9A;
                    const XK_KP_Next = 0xFF9B;

                    if (shift and (keysym == XK_Prior or keysym == XK_KP_Prior)) {
                        terminal.kscrollUp(term.row); // Scroll one screen up
                    } else if (shift and (keysym == XK_Next or keysym == XK_KP_Next)) {
                        terminal.kscrollDown(term.row); // Scroll one screen down
                    } else {
                        try input.handleKey(&event.xkey);
                    }
                },
                x11.ConfigureNotify => {
                    const ev = event.xconfigure;
                    const new_w = ev.width;
                    const new_h = ev.height;

                    if (new_w != window.width or new_h != window.height) {
                        window.width = @intCast(new_w);
                        window.height = @intCast(new_h);
                        window.resizeBuffer(@intCast(new_w), @intCast(new_h));
                        renderer.resize();

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
                x11.ButtonPress => {
                    const ev = event.xbutton;
                    const cell_w = @as(c_int, @intCast(window.cell_width));
                    const cell_h = @as(c_int, @intCast(window.cell_height));
                    const x = @as(usize, @intCast(@divTrunc(ev.x, cell_w)));
                    const y = @as(usize, @intCast(@divTrunc(ev.y, cell_h)));

                    // Limit to screen bounds
                    const cx = @min(x, terminal.term.col - 1);
                    const cy = @min(y, terminal.term.row - 1);

                    if (ev.button == x11.Button1) {
                        // Left click: start selection
                        mouse_pressed = true;
                        mouse_x = cx;
                        mouse_y = cy;
                        selector.start(cx, cy, .word);
                        // Clear previous selection
                        selector.clear();
                    } else if (ev.button == x11.Button2) {
                        // Middle click: paste from PRIMARY selection
                        selector.requestPaste() catch |err| {
                            std.log.err("Paste request failed: {}\n", .{err});
                        };
                    } else if (ev.button == x11.Button3) {
                        // Right click: extend selection or copy
                        mouse_pressed = true;
                        selector.start(cx, cy, .word);
                    } else if (ev.button == x11.Button4) { // Scroll Up
                        if (terminal.term.mode.mouse) {
                            try input.sendMouseReport(cx, cy, ev.button, ev.state, false);
                        } else {
                            terminal.kscrollUp(3);
                        }
                    } else if (ev.button == x11.Button5) { // Scroll Down
                        if (terminal.term.mode.mouse) {
                            try input.sendMouseReport(cx, cy, ev.button, ev.state, false);
                        } else {
                            terminal.kscrollDown(3);
                        }
                    } else {
                        // Check if mouse reporting is enabled
                        if (terminal.term.mode.mouse) {
                            try input.sendMouseReport(cx, cy, ev.button, ev.state, false);
                        }
                    }
                },
                x11.ButtonRelease => {
                    const ev = event.xbutton;
                    const cell_w = @as(c_int, @intCast(window.cell_width));
                    const cell_h = @as(c_int, @intCast(window.cell_height));
                    const x = @as(usize, @intCast(@divTrunc(ev.x, cell_w)));
                    const y = @as(usize, @intCast(@divTrunc(ev.y, cell_h)));
                    const cx = @min(x, terminal.term.col - 1);
                    const cy = @min(y, terminal.term.row - 1);

                    if (terminal.term.mode.mouse) {
                        try input.sendMouseReport(cx, cy, ev.button, ev.state, true);
                    }

                    if (mouse_pressed) {
                        mouse_pressed = false;

                        // On release, copy to clipboard
                        _ = selector.getText(&terminal.term) catch {};
                        selector.copyToClipboard() catch {};

                        // Redraw to clear selection highlight
                        try renderer.render(&terminal.term);
                        try renderer.renderCursor(&terminal.term);
                        window.present();
                    }
                },
                x11.MotionNotify => {
                    if (mouse_pressed) {
                        const ev = event.xmotion;
                        const cell_w = @as(c_int, @intCast(window.cell_width));
                        const cell_h = @as(c_int, @intCast(window.cell_height));
                        const x = @as(usize, @intCast(@divTrunc(ev.x, cell_w)));
                        const y = @as(usize, @intCast(@divTrunc(ev.y, cell_h)));
                        const cx = @min(x, terminal.term.col - 1);
                        const cy = @min(y, terminal.term.row - 1);

                        selector.extend(cx, cy, .regular, false);

                        // Redraw with selection
                        try renderer.render(&terminal.term);
                        // Draw selection highlight (simplified: just redraw)
                        window.present();
                    }
                },
                x11.SelectionRequest => {
                    const ev = event.xselectionrequest;
                    std.log.info("SelectionRequest received\n", .{});

                    // Send SelectionNotify with no property (failure) for now
                    var notify: x11.XEvent = undefined;
                    notify.type = x11.SelectionNotify;
                    notify.xselection.selection = ev.selection;
                    notify.xselection.target = ev.target;
                    notify.xselection.property = 0; // Failure
                    notify.xselection.time = ev.time;
                    notify.xselection.requestor = ev.requestor;

                    _ = x11.XSendEvent(window.dpy, ev.requestor, x11.False, 0, &notify);
                },
                x11.SelectionNotify => {
                    const ev = event.xselection;
                    std.log.info("SelectionNotify received\n", .{});

                    if (ev.property != 0) {
                        var text_prop: x11.XTextProperty = undefined;
                        // Use ev.property (which should be PRIMARY)
                        if (x11.XGetTextProperty(window.dpy, ev.requestor, &text_prop, ev.property) > 0) {
                            defer {
                                _ = x11.XFree(@ptrCast(text_prop.value));
                            }

                            if (text_prop.value) |value| {
                                const len = @as(usize, @intCast(text_prop.nitems));
                                const paste_text = value[0..len];

                                // Send to PTY
                                _ = try pty.write(paste_text);

                                // Also add to paste buffer
                                try paste_buffer.appendSlice(allocator, paste_text);

                                std.log.info("粘贴: {s}\n", .{paste_text});
                            }
                        }
                    }
                },
                x11.SelectionClear => {
                    const ev = event.xselectionclear;
                    std.log.info("SelectionClear received\n", .{});
                    selector.handleSelectionClear(&ev);
                    // Redraw to clear highlight
                    try renderer.render(&terminal.term);
                    window.present();
                },
                else => {},
            }
        }

        if (quit) break;

        // Check for cursor blink update
        const now = std.time.milliTimestamp();
        var timeout_ms: i32 = -1;

        if (config.Config.cursor.blink_interval_ms > 0) {
            const next_blink = renderer.last_blink_time + config.Config.cursor.blink_interval_ms;
            if (now >= next_blink) {
                // Time to toggle blink, force redraw
                // We don't change state here, renderCursor handles state toggling based on time.
                // We just ensure we wake up to draw it.
                try renderer.render(&terminal.term);
                try renderer.renderCursor(&terminal.term);
                window.present();
                timeout_ms = @intCast(config.Config.cursor.blink_interval_ms);
            } else {
                timeout_ms = @intCast(next_blink - now);
            }
        }

        // 2. Poll 等待新数据
        var fds = [_]std.posix.pollfd{
            .{ .fd = pty.master, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = x11.XConnectionNumber(window.dpy), .events = std.posix.POLL.IN, .revents = 0 },
        };

        _ = std.posix.poll(&fds, timeout_ms) catch |err| {
            std.log.err("Poll failed: {}\n", .{err});
            continue;
        };

        // 3. 处理 PTY 数据

        if ((fds[0].revents & std.posix.POLL.IN) != 0) {
            const n = pty.read(read_buffer) catch |err| {
                if (err == error.WouldBlock) {
                    continue;
                }
                if (err == error.InputOutput) {
                    // PTY 关闭 (EIO)
                    quit = true;
                    break;
                }
                return err;
            };

            if (n == 0) {
                // EOF
                std.log.info("PTY EOF\n", .{});
                quit = true;
                break;
            }

            // std.log.info("Read {d} bytes from PTY\n", .{n});
            if (n > 0) {
                std.log.debug("PTY Read: {d} bytes: {s}\n", .{ n, read_buffer[0..n] });
            }

            // 处理终端数据
            try terminal.processBytes(read_buffer[0..n]);

            // 检测并高亮 URL
            try url_detector.highlightUrls();

            // 渲染
            try renderer.render(&terminal.term);
            try renderer.renderCursor(&terminal.term);
            window.present();
        }
    }

    // 清除 URL 高亮
    url_detector.clearHighlights();

    // 等待子进程结束
    const exit_status = try pty.wait();
    std.log.info("子进程退出，状态: {d}\n", .{exit_status});

    return exit_status;
}
