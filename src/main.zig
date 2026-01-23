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

    // 解析命令行参数
    const cols = config.Config.window.cols;
    const rows = config.Config.window.rows;
    const shell_path = config.Config.shell;

    std.log.info("stz - Zig 终端模拟器 v0.1.0\n", .{});
    std.log.info("配置尺寸: {d}x{d}\n", .{ cols, rows });

    // 初始化窗口
    var window = try Window.init("stz", cols, rows, allocator);
    defer window.deinit();

    // 初始化渲染器 (这将加载字体并确定实际的字符宽高)
    var renderer = try Renderer.init(&window, allocator);
    defer renderer.deinit();

    // 修复窗口大小以匹配实际字体尺寸
    // 注意：这将根据字体度量调整窗口大小，可能改变行数/列数
    window.resizeToGrid(cols, rows);
    window.resizeBuffer(window.width, window.height);
    renderer.resize();

    // 显示窗口
    window.show();

    // 设置 TERM 环境变量
    _ = c.setenv("TERM", config.Config.term_type, 1);

    // 初始化 PTY
    // 直接使用配置的行列数初始化，因为我们刚刚请求了 resizeToGrid
    // 如果 WM 不遵守请求，后续的 ConfigureNotify 会修正 PTY 大小
    var pty = try PTY.init(shell_path, cols, rows);
    defer pty.close();

    // 初始化终端
    var terminal = try Terminal.init(rows, cols, allocator);

    // 修复 Parser 中的 Term 和 PTY 指针
    terminal.parser.term = &terminal.term;
    terminal.parser.pty = &pty;
    defer terminal.deinit();

    // 设置 PTY 为非阻塞模式
    try pty.setNonBlocking();

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

    // 渲染限制 (60 FPS)
    const min_frame_time_ms: i64 = 1000 / 60;
    var last_render_time: i64 = std.time.milliTimestamp();
    var pending_render: bool = false;

    // 初始渲染
    if (try renderer.render(&terminal.term, &selector)) |_| {
        window.present();
    }

    while (!quit) {
        // Alias term for easy access
        const term = &terminal.term;

        // 1. 处理所有挂起的 X11 事件
        while (window.pollEvent()) |event| {
            var ev = event;
            if (x11.XFilterEvent(&ev, x11.None) != 0) continue;

            switch (ev.type) {
                x11.ClientMessage => {
                    if (@as(x11.Atom, @intCast(ev.xclient.data.l[0])) == window.wm_delete_window) {
                        quit = true;
                        break;
                    }
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
                        selector.clear(term);
                        terminal.kscrollUp(term.row); // Scroll one screen up
                        if (try renderer.render(term, &selector)) |rect| {
                            try renderer.renderCursor(term);
                            window.presentPartial(rect);
                        }
                    } else if (shift and (keysym == XK_Next or keysym == XK_KP_Next)) {
                        selector.clear(term);
                        terminal.kscrollDown(term.row); // Scroll one screen down
                        if (try renderer.render(term, &selector)) |rect| {
                            try renderer.renderCursor(term);
                            window.presentPartial(rect);
                        }
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
                        if (term.selection.mode != .idle) {
                            selector.clear(term);
                            screen.setFullDirty(term);
                        }

                        // 优先处理特殊按键（Backspace, Delete, 方向键等）
                        // 这样可以避免 XIM (Xutf8LookupString) 将 Backspace 转换为 \x08 (Ctrl-H)
                        if (try input.handleKey(&ev.xkey)) {
                            // 如果 handleKey 处理了该按键，直接跳过
                        } else if (window.ic) |ic| {
                            var status: x11.Status = undefined;
                            var kbuf: [32]u8 = undefined;
                            const n = x11.Xutf8LookupString(ic, &ev.xkey, &kbuf, kbuf.len, null, &status);
                            if (status == x11.XLookupChars or status == x11.XLookupBoth) {
                                if (n > 0) {
                                    _ = try pty.write(kbuf[0..@as(usize, @intCast(n))]);
                                }
                            }
                        } else {
                            var kbuf: [32]u8 = undefined;
                            const n = x11.XLookupString(&ev.xkey, &kbuf, kbuf.len, null, null);
                            if (n > 0) {
                                _ = try pty.write(kbuf[0..@as(usize, @intCast(n))]);
                            }
                        }
                    }
                },
                x11.ConfigureNotify => {
                    const width = @as(u32, @intCast(ev.xconfigure.width));
                    const height = @as(u32, @intCast(ev.xconfigure.height));

                    if (width != window.width or height != window.height) {
                        window.width = width;
                        window.height = height;

                        const b = config.Config.window.border_pixels;
                        const fudge = window.cell_height / 2;
                        const avail_w = if (window.width > 2 * b) window.width - 2 * b + fudge else 0;
                        const avail_h = if (window.height > 2 * b) window.height - 2 * b + fudge else 0;

                        const new_cols = avail_w / window.cell_width;
                        const new_rows = avail_h / window.cell_height;

                        if (new_cols > 0 and new_rows > 0) {
                            if (new_cols != terminal.term.col or new_rows != terminal.term.row) {
                                try terminal.resize(new_rows, new_cols);
                                try pty.resize(new_cols, new_rows);
                                window.resizeBuffer(window.width, window.height);
                                renderer.resize();
                                if (try renderer.render(&terminal.term, &selector)) |_| {
                                    window.present(); // Resize always needs full present
                                }
                            }
                        }
                    }
                },
                x11.Expose => {
                    if (!terminal.term.mode.sync_update) {
                        if (try renderer.render(&terminal.term, &selector)) |_| {
                            try renderer.renderCursor(&terminal.term);
                            window.present();
                        } else {
                            // Expose should always refresh window from pixmap at least
                            window.present();
                        }
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
                        (e.state & x11.ControlMask) != 0)
                    {
                        if (url_detector.isUrlAt(cx, cy)) {
                            url_detector.openUrlAt(cx, cy) catch |err| {
                                std.log.err("打开 URL 失败: {}\n", .{err});
                            };
                        }
                        continue; // 跳到下一个事件，不处理选择
                    }

                    // 鼠标报告优先，除非按下 Shift 键强制进行终端选择
                    if (term.mode.mouse and !shift) {
                        // 如果当前有本地选择，点击时清除它
                        if (term.selection.mode != .idle) {
                            selector.clear(term);
                            screen.setFullDirty(term);
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
                        selector.clear(term);
                        selector.start(term, cx, cy, snap_mode);
                        if (snap_mode != .none) {
                            selector.extend(term, cx, cy, .regular, false);
                        }
                        screen.setFullDirty(term);
                    } else if (e.button == x11.Button2) {
                        // Middle click: paste from PRIMARY selection
                        selector.requestPaste() catch |err| {
                            std.log.err("Paste request failed: {}\n", .{err});
                        };
                    } else if (e.button == x11.Button3) {
                        // Right click: extend selection or copy
                        mouse_pressed = true;
                        pressed_button = e.button;
                        selector.start(term, cx, cy, .none);
                    } else if (e.button == x11.Button4) { // Scroll Up
                        if (term.mode.mouse and !shift) {
                            try input.sendMouseReport(cx, cy, e.button, e.state, 0);
                        } else {
                            if (term.mode.alt_screen) {
                                // In alt screen (vi/less), send arrow keys
                                _ = try pty.write("\x1B[A");
                            } else {
                                selector.clear(term);
                                terminal.kscrollUp(3);
                                if (try renderer.render(term, &selector)) |rect| {
                                    try renderer.renderCursor(term);
                                    window.presentPartial(rect);
                                }
                            }
                        }
                    } else if (e.button == x11.Button5) { // Scroll Down
                        if (term.mode.mouse and !shift) {
                            try input.sendMouseReport(cx, cy, e.button, e.state, 0);
                        } else {
                            if (term.mode.alt_screen) {
                                // In alt screen (vi/less), send arrow keys
                                _ = try pty.write("\x1B[B");
                            } else {
                                selector.clear(term);
                                terminal.kscrollDown(3);
                                if (try renderer.render(term, &selector)) |rect| {
                                    try renderer.renderCursor(term);
                                    window.presentPartial(rect);
                                }
                            }
                        }
                    }
                },
                x11.ButtonRelease => {
                    const e = ev.xbutton;
                    const shift = (e.state & x11.ShiftMask) != 0;
                    const cell_w = @as(c_int, @intCast(window.cell_width));
                    const cell_h = @as(c_int, @intCast(window.cell_height));
                    const x = @as(usize, @intCast(@divTrunc(e.x, cell_w)));
                    const y = @as(usize, @intCast(@divTrunc(e.y, cell_h)));
                    const cx = @min(x, terminal.term.col - 1);
                    const cy = @min(y, terminal.term.row - 1);

                    if (terminal.term.mode.mouse and !shift) {
                        try input.sendMouseReport(cx, cy, e.button, e.state, 1);
                        mouse_pressed = false;
                        pressed_button = 0;
                        continue;
                    }

                    if (e.button == pressed_button) {
                        mouse_pressed = false;
                        pressed_button = 0;

                        if (e.button == x11.Button1) {
                            // Copy on release
                            selector.copy(term) catch |err| {
                                std.log.err("Copy failed: {}\n", .{err});
                            };
                        }
                    }
                },
                x11.MotionNotify => {
                    const e = ev.xmotion;
                    const shift = (e.state & x11.ShiftMask) != 0;
                    const cell_w = @as(c_int, @intCast(window.cell_width));
                    const cell_h = @as(c_int, @intCast(window.cell_height));
                    const x = @as(usize, @intCast(@divTrunc(e.x, cell_w)));
                    const y = @as(usize, @intCast(@divTrunc(e.y, cell_h)));
                    const cx = @min(x, terminal.term.col - 1);
                    const cy = @min(y, terminal.term.row - 1);

                    if (terminal.term.mode.mouse and !shift) {
                        // Only send motion if button is pressed or mouse_many/mouse_motion is set
                        const send_motion = terminal.term.mode.mouse_many or
                            (terminal.term.mode.mouse_motion and mouse_pressed);
                        if (send_motion) {
                            try input.sendMouseReport(cx, cy, 0, e.state, 2);
                        }
                        continue;
                    }

                    if (mouse_pressed and pressed_button == x11.Button1) {
                        // Update selection
                        selector.extend(term, cx, cy, .regular, false);
                        screen.setFullDirty(term);
                        if (try renderer.render(term, &selector)) |rect| {
                            window.presentPartial(rect);
                        }
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
                        const supported = [_]x11.Atom{ targets, utf8, x11.XA_STRING };
                        _ = x11.XChangeProperty(window.dpy, e.requestor, notify.xselection.property, x11.XA_ATOM, 32, x11.PropModeReplace, @ptrCast(&supported), supported.len);
                        success = true;
                    } else if (e.target == utf8 or e.target == x11.XA_STRING) {
                        if (selector.selected_text) |text| {
                            _ = x11.XChangeProperty(window.dpy, e.requestor, notify.xselection.property, e.target, 8, x11.PropModeReplace, text.ptr, @intCast(text.len));
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
                    selector.clear(term);
                    screen.setFullDirty(term);
                    if (try renderer.render(term, &selector)) |rect| {
                        try renderer.renderCursor(term);
                        window.presentPartial(rect);
                    }
                },
                x11.SelectionClear => {
                    const e = ev.xselectionclear;
                    std.log.info("SelectionClear received\n", .{});
                    selector.handleSelectionClear(term, &e);
                    // Redraw to clear highlight
                    if (try renderer.render(term, &selector)) |rect| {
                        window.presentPartial(rect);
                    }
                },
                x11.FocusIn => {
                    std.log.info("FocusIn\n", .{});
                    term.mode.focused = true;
                    if (window.ic) |ic| x11.XSetICFocus(ic);
                    if (term.mode.focused_report) {
                        _ = pty.write("\x1B[I") catch {};
                    }
                    if (try renderer.render(term, &selector)) |rect| {
                        try renderer.renderCursor(term);
                        window.presentPartial(rect);
                    } else {
                        try renderer.renderCursor(term);
                    }
                },
                x11.FocusOut => {
                    std.log.info("FocusOut\n", .{});
                    term.mode.focused = false;
                    if (window.ic) |ic| x11.XUnsetICFocus(ic);
                    if (term.mode.focused_report) {
                        _ = pty.write("\x1B[O") catch {};
                    }
                    if (try renderer.render(term, &selector)) |rect| {
                        try renderer.renderCursor(term);
                        window.presentPartial(rect);
                    } else {
                        try renderer.renderCursor(term);
                    }
                },
                x11.EnterNotify, x11.LeaveNotify, x11.ReparentNotify, x11.MapNotify, x11.NoExpose, x11.KeyRelease => {
                    // 忽略这些常见但当前无需处理的事件，避免日志刷屏
                },
                else => {
                    std.log.debug("未处理的 X11 事件: {d}\n", .{ev.type});
                },
            }
        }

        if (quit) break;

        // Check for cursor blink update
        const now = std.time.milliTimestamp();
        var timeout_ms: i32 = -1;

        // 渲染检查: 如果有待处理的渲染请求且时间间隔已到，则渲染
        if (pending_render and (now - last_render_time >= min_frame_time_ms)) {
            if (!terminal.term.mode.sync_update) {
                if (try renderer.render(&terminal.term, &selector)) |rect| {
                    try renderer.renderCursor(&terminal.term);
                    window.presentPartial(rect);
                }
                last_render_time = std.time.milliTimestamp();
                pending_render = false;
            }
        }

        if (config.Config.cursor.blink_interval_ms > 0) {
            const next_blink = renderer.last_blink_time + config.Config.cursor.blink_interval_ms;
            if (now >= next_blink) {
                // Time to toggle blink state
                term.mode.blink = !term.mode.blink;

                // 1. 如果有文本闪烁属性，标记相关行为脏
                if (screen.isAttrSet(term, .{ .blink = true })) {
                    screen.setDirtyAttr(term, .{ .blink = true });
                }

                // 2. 如果光标需要闪烁，标记光标行为脏
                if (term.cursor_style.shouldBlink()) {
                    if (term.dirty) |dirty| {
                        if (term.c.y < dirty.len) {
                            dirty[term.c.y] = true;
                        }
                    }
                }

                renderer.last_blink_time = now;
                pending_render = true;
                timeout_ms = 0;
            } else {
                timeout_ms = @intCast(next_blink - now);
            }
        }

        // 如果有待处理的渲染，缩短 poll 超时时间以保证帧率
        if (pending_render) {
            const time_since = std.time.milliTimestamp() - last_render_time;
            const remaining = min_frame_time_ms - time_since;
            const wait_ms: i32 = if (remaining > 0) @intCast(remaining) else 0;
            if (timeout_ms == -1 or wait_ms < timeout_ms) {
                timeout_ms = wait_ms;
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

            if (n > 0) {
                try terminal.processBytes(read_buffer[0..n]);
                pending_render = true;
            }
        }
    }

    return 0;
}
