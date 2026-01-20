//! stz - 简单终端模拟器 (Zig 重写版)
//! 主程序入口和事件循环

const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});
const x11 = @import("modules/x11.zig");

const Terminal = @import("modules/terminal.zig").Terminal;
const PTY = @import("modules/pty.zig").PTY;
const Window = @import("modules/window.zig").Window;
const Renderer = @import("modules/renderer.zig").Renderer;
const Input = @import("modules/input.zig").Input;
const Selector = @import("modules/selection.zig").Selector;
const UrlDetector = @import("modules/url.zig").UrlDetector;
const Printer = @import("modules/printer.zig").Printer;
const config = @import("modules/config.zig");
const types = @import("modules/types.zig");
const screen = @import("modules/screen.zig");
const c_locale = @cImport({
    @cInclude("locale.h");
});

// 配置重载标志（volatile 用于信号处理）
var reload_config: bool = false;

/// 信号处理函数（SIGHUP - 重新加载配置）
fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    // 标记需要重新加载配置
    reload_config = true;
}

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

    // Set locale for IME
    _ = c_locale.setlocale(c_locale.LC_CTYPE, "");

    // 设置信号处理器（SIGHUP - 重新加载配置）
    _ = c.signal(c.SIGHUP, signalHandler);

    // 解析命令行参数
    const cols = config.Config.window.cols;
    const rows = config.Config.window.rows;
    const shell_path = config.Config.shell;

    std.log.info("stz - Zig 终端模拟器 v0.1.0\n", .{});
    std.log.info("尺寸: {d}x{d}\n", .{ cols, rows });
    std.log.info("发送 SIGHUP 信号 (kill -HUP <pid>) 可重新加载配置\n", .{});

    // 设置 TERM 环境变量 (必须在 PTY 初始化前，以确保子进程能继承)
    _ = c.setenv("TERM", config.Config.term_type, 1);

    // 初始化 PTY
    var pty = try PTY.init(shell_path, cols, rows);
    defer pty.close();

    // 初始化终端
    var terminal = try Terminal.init(rows, cols, allocator);
    // 修复 Parser 中的 Term 和 PTY 指针
    terminal.parser.term = &terminal.term;
    terminal.parser.pty = &pty;
    defer terminal.deinit();

    // 初始化窗口
    var window = try Window.init("stz", cols, rows, allocator);
    defer window.deinit();

    // 显示窗口
    window.show();

    // 初始化渲染器
    var renderer = try Renderer.init(&window, allocator);
    defer renderer.deinit();

    // 修复窗口大小以匹配实际字体尺寸
    window.resizeToGrid(cols, rows);

    // 初始化输入处理器
    var input = Input.init(&pty, &terminal.term);

    // 初始化选择器
    var selector = Selector.init(allocator);
    selector.setX11Context(window.dpy, window.win);
    defer selector.deinit();

    // 初始化 URL 检测器
    var url_detector = UrlDetector.init(&terminal.term, allocator);

    // 初始化打印器
    var printer = Printer.init(allocator);
    defer printer.deinit();

    // 主事件循环
    const read_buffer = try allocator.alloc(u8, 8192);
    defer allocator.free(read_buffer);

    var quit: bool = false;
    var mouse_pressed: bool = false;
    var pressed_button: u32 = 0;
    var mouse_x: usize = 0;
    var mouse_y: usize = 0;

    // 点击检测变量
    var last_click_time: i64 = 0;
    var last_button: u32 = 0;
    var click_count: u32 = 0;

    // Paste buffer (for receiving X11 selection)
    var paste_buffer = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer paste_buffer.deinit(allocator);

    // 设置 PTY 为非阻塞模式
    try pty.setNonBlocking();

    while (!quit) {
        // Alias term for easy access
        const term = &terminal.term;

        // 0. 检查配置重载
        if (reload_config) {
            reload_config = false;
            std.log.info("正在重新加载配置...\n", .{});

            // 清除颜色缓存
            for (0..renderer.colors.len) |i| {
                renderer.loaded_colors[i] = false;
            }

            // 重绘整个屏幕
            screen.setFullDirty(term);

            // 强制重绘
            try renderer.render(term, &selector);
            try renderer.renderCursor(term);
            window.present();

            std.log.info("配置已重新加载\n", .{});
        }

        // 1. 处理所有挂起的 X11 事件
        while (window.pollEvent()) |event| {
            var ev = event;
            if (x11.XFilterEvent(&ev, x11.None) != 0) continue;

            switch (ev.type) {
                x11.ClientMessage => {
                    // TODO: Handle WM_DELETE_WINDOW
                    // if (ev.xclient.data.l[0] == wm_delete_window) ...
                },
                x11.KeyPress => {
                    renderer.resetCursorBlink(); // Reset blink on input

                    // Check for scroll shortcuts (Shift + PageUp/PageDown)
                    const state = ev.xkey.state;
                    const shift = (state & x11.ShiftMask) != 0;
                    const keycode = ev.xkey.keycode;
                    const keysym = x11.XkbKeycodeToKeysym(window.dpy, @intCast(keycode), 0, if (shift) 1 else 0);

                    const XK_Prior = 0xFF55; // PageUp
                    const XK_Next = 0xFF56; // PageDown
                    const XK_KP_Prior = 0xFF9A;
                    const XK_KP_Next = 0xFF9B;
                    const XK_Print = 0xFF61; // Print/SysRq

                    const ctrl = (state & x11.ControlMask) != 0;

                    if (shift and (keysym == XK_Prior or keysym == XK_KP_Prior)) {
                        selector.clear();
                        terminal.kscrollUp(term.row); // Scroll one screen up
                        try renderer.render(term, &selector);
                        try renderer.renderCursor(term);
                        window.present();
                    } else if (shift and (keysym == XK_Next or keysym == XK_KP_Next)) {
                        selector.clear();
                        terminal.kscrollDown(term.row); // Scroll one screen down
                        try renderer.render(term, &selector);
                        try renderer.renderCursor(term);
                        window.present();
                    } else if (ctrl and shift and (keysym == 'V' or keysym == 'v')) {
                        // Ctrl+Shift+V: 从 CLIPBOARD 粘贴 (与现代终端一致)
                        const dpy = window.dpy;
                        const clipboard = x11.XInternAtom(dpy, "CLIPBOARD", 0);
                        selector.requestSelection(clipboard) catch |err| {
                            std.log.err("Clipboard paste request failed: {}\n", .{err});
                        };
                    } else if (keysym == XK_Print) {
                        // Print key handling
                        if (ctrl) {
                            // Ctrl+Print: toggle printer mode
                            try printer.toggle(&terminal.term);
                        } else if (shift) {
                            // Shift+Print: print screen
                            try printer.printScreen(&terminal.term);
                        } else {
                            // Print: print selection
                            try printer.printSelection(&terminal.term, &selector);
                        }
                    } else {
                        // 开始输入时清除选择高亮
                        if (selector.selection.mode != .idle) {
                            selector.clear();
                            screen.setFullDirty(&terminal.term);
                        }

                        // 优先处理特殊按键（Backspace, Delete, 方向键等）
                        // 这样可以避免 XIM (Xutf8LookupString) 将 Backspace 转换为 \x08 (Ctrl-H)
                        if (try input.handleKey(&ev.xkey)) {
                            // 如果 handleKey 处理了该按键，直接跳过
                        } else if (window.ic) |ic| {
                            var status: x11.C.Status = undefined;
                            var buf: [128]u8 = undefined;
                            const len = x11.Xutf8LookupString(ic, &ev.xkey, &buf, buf.len, null, &status);
                            if (status == x11.C.XLookupChars or status == x11.C.XLookupBoth) {
                                if (len > 0) {
                                    _ = try pty.write(buf[0..@intCast(len)]);
                                }
                            }
                        } else {
                            // 备选方案
                        }
                    }
                },
                x11.ConfigureNotify => {
                    const e = ev.xconfigure;
                    const new_w = e.width;
                    const new_h = e.height;

                    if (new_w != window.width or new_h != window.height) {
                        window.width = @intCast(new_w);
                        window.height = @intCast(new_h);
                        window.resizeBuffer(@intCast(new_w), @intCast(new_h));
                        renderer.resize();

                        // 计算新的行列数（减去边框宽度）
                        const border = config.Config.window.border_pixels;
                        const content_width = @max(window.width, border * 2) - border * 2;
                        const content_height = @max(window.height, border * 2) - border * 2;
                        const new_cols = @divFloor(content_width, window.cell_width);
                        const new_rows = @divFloor(content_height, window.cell_height);

                        // 只有当行列数改变时才调整
                        if (new_cols != terminal.term.col or new_rows != terminal.term.row) {
                            // 调整终端大小
                            try terminal.resize(new_rows, new_cols);

                            // 调整 PTY 大小
                            try pty.resize(new_cols, new_rows);

                            std.log.info("Resize: {}x{} -> {}x{}\n", .{
                                terminal.term.col, terminal.term.row, new_cols, new_rows,
                            });

                            // 重绘
                            if (!terminal.term.mode.sync_update) {
                                try renderer.render(&terminal.term, &selector);
                                try renderer.renderCursor(&terminal.term);
                                window.present();
                            }
                        }
                    }
                },
                x11.Expose => {
                    if (!terminal.term.mode.sync_update) {
                        try renderer.render(&terminal.term, &selector);
                        try renderer.renderCursor(&terminal.term);
                        window.present();
                    }
                },
                x11.ButtonPress => {
                    const e = ev.xbutton;
                    const shift = (e.state & x11.ShiftMask) != 0;
                    const cell_w = @as(c_int, @intCast(window.cell_width));
                    const cell_h = @as(c_int, @intCast(window.cell_height));
                    const x = @as(usize, @intCast(@divTrunc(e.x, cell_w)));
                    const y = @as(usize, @intCast(@divTrunc(e.y, cell_h)));

                    // Limit to screen bounds
                    const cx = @min(x, terminal.term.col - 1);
                    const cy = @min(y, terminal.term.row - 1);

                    // Ctrl + Left Click: 打开 URL
                    if (e.button == x11.Button1 and
                        (e.state & x11.C.ControlMask) != 0)
                    {
                        if (url_detector.isUrlAt(cx, cy)) {
                            url_detector.openUrlAt(cx, cy) catch |err| {
                                std.log.err("打开 URL 失败: {}\n", .{err});
                            };
                        }
                        continue; // 跳到下一个事件，不处理选择
                    }

                    // 鼠标报告优先，除非按下 Shift 键强制进行终端选择
                    if (terminal.term.mode.mouse and !shift) {
                        // 如果当前有本地选择，点击时清除它
                        if (selector.selection.mode != .idle) {
                            selector.clear();
                            screen.setFullDirty(&terminal.term);
                        }
                        try input.sendMouseReport(cx, cy, e.button, e.state, 0);
                        if (e.button >= 1 and e.button <= 3) {
                            mouse_pressed = true;
                            pressed_button = e.button;
                        }
                        continue;
                    }

                    if (e.button == x11.Button1) {
                        // 检测双击/三击
                        const now = std.time.milliTimestamp();
                        if (e.button == last_button and now - last_click_time < config.Config.selection.double_click_timeout_ms) {
                            click_count = (click_count % 3) + 1;
                        } else {
                            click_count = 1;
                        }
                        last_click_time = now;
                        last_button = e.button;

                        const snap_mode: types.SelectionSnap = switch (click_count) {
                            2 => .word,
                            3 => .line,
                            else => .none,
                        };

                        // Left click: start selection
                        mouse_pressed = true;
                        pressed_button = e.button;
                        mouse_x = cx;
                        mouse_y = cy;
                        // Clear previous selection
                        selector.clear();
                        selector.start(cx, cy, snap_mode);
                        if (snap_mode != .none) {
                            selector.extend(&terminal.term, cx, cy, .regular, false);
                        }
                        screen.setFullDirty(&terminal.term);
                    } else if (e.button == x11.Button2) {
                        // Middle click: paste from PRIMARY selection
                        selector.requestPaste() catch |err| {
                            std.log.err("Paste request failed: {}\n", .{err});
                        };
                    } else if (e.button == x11.Button3) {
                        // Right click: extend selection or copy
                        mouse_pressed = true;
                        pressed_button = e.button;
                        selector.start(cx, cy, .none);
                    } else if (e.button == x11.Button4) { // Scroll Up
                        if (terminal.term.mode.mouse and !shift) {
                            try input.sendMouseReport(cx, cy, e.button, e.state, 0);
                        } else {
                            if (terminal.term.mode.alt_screen) {
                                // Alt Screen: send Up arrow key (3 times for speed)
                                for (0..3) |_| try input.writeArrow(false, 'A', false, false);
                            } else {
                                selector.clear();
                                terminal.kscrollUp(3);
                                try renderer.render(term, &selector);
                                try renderer.renderCursor(term);
                                window.present();
                            }
                        }
                    } else if (e.button == x11.Button5) { // Scroll Down
                        if (terminal.term.mode.mouse and !shift) {
                            try input.sendMouseReport(cx, cy, e.button, e.state, 0);
                        } else {
                            if (terminal.term.mode.alt_screen) {
                                // Alt Screen: send Down arrow key (3 times for speed)
                                for (0..3) |_| try input.writeArrow(false, 'B', false, false);
                            } else {
                                selector.clear();
                                terminal.kscrollDown(3);
                                try renderer.render(term, &selector);
                                try renderer.renderCursor(term);
                                window.present();
                            }
                        }
                    } else {
                        // Check if mouse reporting is enabled
                        if (terminal.term.mode.mouse) {
                            try input.sendMouseReport(cx, cy, e.button, e.state, 0);
                        }
                    }
                },
                x11.ButtonRelease => {
                    const e = ev.xbutton;
                    const cell_w = @as(c_int, @intCast(window.cell_width));
                    const cell_h = @as(c_int, @intCast(window.cell_height));
                    const border = @as(i32, @intCast(config.Config.window.border_pixels));
                    const x = @as(usize, @intCast(@divTrunc(@max(0, e.x - border), cell_w)));
                    const y = @as(usize, @intCast(@divTrunc(@max(0, e.y - border), cell_h)));
                    const cx = @min(x, terminal.term.col - 1);
                    const cy = @min(y, terminal.term.row - 1);
                    const shift = (e.state & x11.ShiftMask) != 0;

                    if (terminal.term.mode.mouse and !shift) {
                        try input.sendMouseReport(cx, cy, e.button, e.state, 1);
                        mouse_pressed = false;
                        pressed_button = 0;
                        continue;
                    }

                    if (mouse_pressed) {
                        const was_dragging = (selector.selection.mode == .ready);
                        mouse_pressed = false;
                        pressed_button = 0;

                        // 结束选择扩展
                        selector.extend(&terminal.term, cx, cy, .regular, true);

                        // 只有在 ready 模式下且是 Button1 释放时，才复制到 PRIMARY
                        if (was_dragging and e.button == x11.Button1) {
                            // Only copy to clipboard if we actually performed a selection drag
                            const text = selector.getText(&terminal.term) catch "";
                            if (text.len > 0) {
                                selector.copyToClipboard() catch {};
                            }
                        }

                        // Redraw to clear selection highlight
                        try renderer.render(&terminal.term, &selector);
                        try renderer.renderCursor(&terminal.term);
                        window.present();
                    }
                },
                x11.MotionNotify => {
                    const e = ev.xmotion;
                    const cell_w = @as(c_int, @intCast(window.cell_width));
                    const cell_h = @as(c_int, @intCast(window.cell_height));
                    const border = @as(i32, @intCast(config.Config.window.border_pixels));
                    const x = @as(usize, @intCast(@divTrunc(@max(0, e.x - border), cell_w)));
                    const y = @as(usize, @intCast(@divTrunc(@max(0, e.y - border), cell_h)));
                    const cx = @min(x, terminal.term.col - 1);
                    const cy = @min(y, terminal.term.row - 1);
                    const shift = (e.state & x11.ShiftMask) != 0;

                    if (terminal.term.mode.mouse and !shift) {
                        try input.sendMouseReport(cx, cy, pressed_button, e.state, 2);
                        continue;
                    }

                    if (mouse_pressed) {
                        selector.extend(&terminal.term, cx, cy, .regular, false);
                        screen.setFullDirty(&terminal.term);

                        // Redraw with selection
                        try renderer.render(&terminal.term, &selector);
                        // Draw selection highlight (simplified: just redraw)
                        window.present();
                    }
                },
                x11.SelectionRequest => {
                    const e = ev.xselectionrequest;
                    std.log.info("SelectionRequest received (target={d})\n", .{e.target});

                    var notify: x11.XEvent = undefined;
                    notify.type = x11.SelectionNotify;
                    notify.xselection.display = e.display;
                    notify.xselection.requestor = e.requestor;
                    notify.xselection.selection = e.selection;
                    notify.xselection.target = e.target;
                    notify.xselection.time = e.time;
                    notify.xselection.property = e.property;

                    if (notify.xselection.property == 0) notify.xselection.property = e.target;

                    const utf8 = x11.getUtf8Atom(window.dpy);
                    const targets = x11.XInternAtom(window.dpy, "TARGETS", 0);

                    var success = false;
                    if (e.target == targets) {
                        const supported = [_]x11.C.Atom{ targets, utf8, x11.XA_STRING };
                        _ = x11.XChangeProperty(window.dpy, e.requestor, notify.xselection.property, x11.C.XA_ATOM, 32, x11.C.PropModeReplace, @ptrCast(&supported), supported.len);
                        success = true;
                    } else if (e.target == utf8 or e.target == x11.C.XA_STRING) {
                        if (selector.selected_text) |text| {
                            _ = x11.XChangeProperty(window.dpy, e.requestor, notify.xselection.property, e.target, 8, x11.C.PropModeReplace, text.ptr, @intCast(text.len));
                            success = true;
                        }
                    }

                    if (!success) notify.xselection.property = 0;

                    _ = x11.XSendEvent(window.dpy, e.requestor, 1, 0, &notify);
                },
                x11.SelectionNotify => {
                    const e = ev.xselection;
                    std.log.info("SelectionNotify received\n", .{});

                    if (e.property != 0) {
                        var text_prop: x11.XTextProperty = undefined;
                        // Use ev.property (which should be PRIMARY)
                        if (x11.XGetTextProperty(window.dpy, e.requestor, &text_prop, e.property) > 0) {
                            defer {
                                _ = x11.XFree(@ptrCast(text_prop.value));
                            }

                            if (text_prop.value) |value| {
                                const len = @as(usize, @intCast(text_prop.nitems));
                                const paste_text = try allocator.dupe(u8, value[0..len]);
                                defer allocator.free(paste_text);

                                // 将 \n 转换为 \r 以适应终端
                                for (paste_text) |*char| {
                                    if (char.* == '\n') char.* = '\r';
                                }

                                // Send to PTY
                                const written = try pty.write(paste_text);
                                std.log.info("已将 {d} 字节写入 PTY: {s}\n", .{ written, paste_text });

                                // Also add to paste buffer
                                try paste_buffer.appendSlice(allocator, paste_text);

                                std.log.info("粘贴: {s}\n", .{paste_text});
                            }
                        }
                    }

                    // 粘贴完成后清除选择高亮
                    selector.clear();
                    screen.setFullDirty(&terminal.term);
                    try renderer.render(&terminal.term, &selector);
                    try renderer.renderCursor(&terminal.term);
                    window.present();
                },
                x11.SelectionClear => {
                    const e = ev.xselectionclear;
                    std.log.info("SelectionClear received\n", .{});
                    selector.handleSelectionClear(&e);
                    // Redraw to clear highlight
                    try renderer.render(&terminal.term, &selector);
                    window.present();
                },
                x11.FocusIn => {
                    std.log.info("FocusIn\n", .{});
                    terminal.term.mode.focused = true;
                    if (window.ic) |ic| x11.XSetICFocus(ic);
                    if (terminal.term.mode.focused_report) {
                        _ = pty.write("\x1B[I") catch {};
                    }
                    try renderer.render(&terminal.term, &selector);
                    try renderer.renderCursor(&terminal.term);
                    window.present();
                },
                x11.FocusOut => {
                    std.log.info("FocusOut\n", .{});
                    terminal.term.mode.focused = false;
                    if (window.ic) |ic| x11.XUnsetICFocus(ic);
                    if (terminal.term.mode.focused_report) {
                        _ = pty.write("\x1B[O") catch {};
                    }
                    try renderer.render(&terminal.term, &selector);
                    try renderer.renderCursor(&terminal.term);
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
                try renderer.render(&terminal.term, &selector);
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

        // 3. 检查子进程是否还活着
        if (!pty.isChildAlive()) {
            std.log.info("子进程已退出\n", .{});
            quit = true;
            break;
        }

        // 4. 处理 PTY 数据

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

            std.log.info("Read {d} bytes from PTY\n", .{n});

            // 记录处理前的同步模式状态
            const was_sync = terminal.term.mode.sync_update;

            // 处理终端数据
            try terminal.processBytes(read_buffer[0..n]);

            // 检查是否有剪贴板请求 (OSC 52)
            if (term.clipboard_data) |data| {
                try selector.copyTextToClipboard(data, term.clipboard_mask);
                allocator.free(data);
                term.clipboard_data = null;
            }

            // 如果有新输出且当前在查看历史，回到实时屏幕
            if (n > 0 and terminal.term.scr > 0) {
                terminal.term.scr = 0;
                screen.setFullDirty(&terminal.term);
            }

            // 检测并高亮 URL
            try url_detector.highlightUrls();

            // 检查窗口标题更新
            if (terminal.term.window_title_dirty) {
                var title_buf: [512]u8 = undefined;
                const copy_len = @min(terminal.term.window_title.len, title_buf.len - 1);
                std.mem.copyForwards(u8, title_buf[0..copy_len], terminal.term.window_title[0..copy_len]);
                title_buf[copy_len] = 0;
                window.setTitle(title_buf[0..copy_len :0]);
                terminal.term.window_title_dirty = false;
            }

            // 渲染判定：
            // 1. 如果当前不在同步更新模式，则渲染。
            // 2. 如果刚刚关闭了同步更新模式 (was_sync=true, now=false)，则必须强制渲染一次。
            if (!terminal.term.mode.sync_update or (was_sync and !terminal.term.mode.sync_update)) {
                try renderer.render(&terminal.term, &selector);
                try renderer.renderCursor(&terminal.term);
                window.present();
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
