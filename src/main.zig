//! stz - Zig 终端模拟器
//! 基于 st (simple terminal) 的设计哲学，使用 Zig 语言和 SDL2 重写。
//!
//! 核心模块说明：
//! - main.zig: 程序入口，处理命令行参数，初始化各组件，运行主事件循环。
//! - Terminal: 终端状态机，管理屏幕缓冲区（行、属性、光标）。
//! - Parser: 转义序列解析器，处理 ANSI/VT 序列并更新 Terminal 状态。
//! - Window: SDL2 窗口管理，处理底层窗口事件。
//! - Renderer: 字符渲染引擎，使用 SDL2 和 FreeType 进行硬件加速绘图。
//! - PTY: 伪终端管理，负责与 shell 子进程通信。
//! - Input: 输入处理器，将键盘/鼠标事件转换为字符或序列发送给 PTY。
//! - Selector: 文本选择与剪贴板管理器。
//!
//! 主循环逻辑：
//! 1. 处理 SDL2 事件（键盘、鼠标、窗口调整等）
//! 2. 从 PTY 读取 shell 输出数据
//! 3. 调用 Parser 解析数据并更新终端缓冲区
//! 4. 调用 Renderer 将缓冲区内容绘制到窗口
//! - 所有 SDL2 事件处理与 st 的事件处理逻辑对齐

const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("locale.h");
});

const stz = @import("stz");
const sdl2 = stz.c.sdl2;

const Terminal = stz.Terminal;
const Parser = stz.Parser;
const PTY = stz.PTY;
const Window = stz.Window;
const Renderer = stz.Renderer;
const Input = stz.Input;
const Selector = stz.Selector;
const UrlDetector = stz.UrlDetector;
const Printer = stz.Printer;
const Args = stz.Args;
const config = stz.Config;
const SelectionSnap = stz.types.SelectionSnap;

/// 将鼠标坐标转换为单元格坐标
/// 参数：
///   - mx, my: 鼠标在窗口中的原始像素坐标
///   - window: 窗口对象（获取边框和单元格尺寸）
///   - terminal: 终端对象（获取行列数）
/// 返回：
///   - cx, cy: 对应的单元格坐标
fn mouseToCell(mx: i32, my: i32, window: *Window, terminal: *Terminal) struct { cx: usize, cy: usize } {
    const border_x = @as(i32, @intCast(window.hborder_px));
    const border_y = @as(i32, @intCast(window.vborder_px));
    const cell_w = @as(i32, @intCast(window.cell_width));
    const cell_h = @as(i32, @intCast(window.cell_height));

    var adj_mx = mx - border_x;
    var adj_my = my - border_y;

    const term_w = @as(i32, @intCast(terminal.col)) * cell_w;
    const term_h = @as(i32, @intCast(terminal.row)) * cell_h;

    adj_mx = @max(0, @min(adj_mx, @max(0, term_w - 1)));
    adj_my = @max(0, @min(adj_my, @max(0, term_h - 1)));

    return .{
        .cx = @as(usize, @intCast(@divTrunc(adj_mx, cell_w))),
        .cy = @as(usize, @intCast(@divTrunc(adj_my, cell_h))),
    };
}

pub fn main() !u8 {
    // ========== 获取内存分配器 ==========
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("内存泄漏", .{});
        }
    }
    const allocator = gpa.allocator();

    // ========== 设置本地化（Locale）==========
    _ = c.setlocale(c.LC_CTYPE, "");

    // ========== 解析命令行参数 ==========
    var args = Args.init(allocator);
    defer args.deinit();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    _ = args_iter.next();

    var args_list = std.ArrayList([:0]const u8).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (args_list.items) |arg| {
            allocator.free(arg);
        }
        args_list.deinit(allocator);
    }

    while (args_iter.next()) |arg| {
        const arg_dup = try allocator.dupeZ(u8, arg);
        try args_list.append(allocator, arg_dup);
    }

    const argv = args_list.items;

    args.parse(argv) catch |err| {
        switch (err) {
            error.MissingArgument => {
                std.debug.print("错误: 选项缺少参数\n", .{});
            },
            error.UnknownOption => {
                std.debug.print("错误: 未知的选项\n", .{});
            },
            error.InvalidGeometry => {
                std.debug.print("错误: 无效的几何尺寸格式 (应为 colsxrows)\n", .{});
            },
            else => {
                std.debug.print("错误: {}\n", .{err});
            },
        }
        try args.printHelp(std.fs.File.stderr());
        return 1;
    };

    if (args.show_help) {
        try args.printHelp(std.fs.File.stderr());
        return 0;
    }

    if (args.show_version) {
        std.debug.print("stz 0.1.0\n", .{});
        return 0;
    }

    const cols = args.getCols(config.window.cols);
    const rows = args.getRows(config.window.rows);

    var shell_path: ?[:0]const u8 = config.shell;

    var shell_cmd_args_list = std.ArrayList([:0]const u8).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (shell_cmd_args_list.items) |arg| {
            allocator.free(arg);
        }
        shell_cmd_args_list.deinit(allocator);
    }

    if (args.shell_cmd) |cmd| {
        shell_path = cmd;
        for (args.shell_args.items) |arg| {
            const arg_dup = try allocator.dupeZ(u8, arg);
            try shell_cmd_args_list.append(allocator, arg_dup);
        }
    }

    const shell_cmd_args: []const [:0]const u8 = shell_cmd_args_list.items;

    std.log.info("stz - Zig 终端模拟器 v0.1.0", .{});
    std.log.info("配置尺寸: {d}x{d}", .{ cols, rows });

    // ========== 初始化窗口 ==========
    const window_title = if (args.title) |t| t else "stz";
    var window = try Window.init(window_title, cols, rows, allocator);
    defer window.deinit();

    // ========== 初始化渲染器 ==========
    var renderer = try Renderer.init(&window, allocator);
    defer renderer.deinit();

    window.resizeToGrid(cols, rows);
    window.resizeBuffer(window.width, window.height);
    renderer.resize();

    sdl2.SDL_StartTextInput();

    // ========== 设置 TERM 环境变量 ==========
    _ = c.setenv("TERM", config.term_type, 1);

    // ========== 初始化 PTY ==========
    var pty = try PTY.initWithArgs(shell_path, cols, rows, shell_cmd_args);
    defer pty.close();

    // ========== 初始化终端 ==========
    var terminal = try Terminal.init(rows, cols, allocator);
    defer terminal.deinit();

    // ========== 设置 Parser ==========
    var parser = try Parser.init(&terminal, &pty, allocator);
    defer parser.deinit();

    parser.allow_altscreen = args.allow_altscreen;

    try pty.setNonBlocking();

    // ========== 初始化输入/选择/工具 ==========
    var input = Input.init(&pty, &terminal);

    var selector = Selector.init(allocator);
    defer selector.deinit();

    var url_detector = UrlDetector.init(&terminal, allocator);

    var printer = Printer.init(allocator);
    defer printer.deinit();

    // ========== 主事件循环 ==========
    const read_buffer = try allocator.alloc(u8, 8192);
    defer allocator.free(read_buffer);

    var quit: bool = false;
    var mouse_pressed: bool = false;
    var pressed_button: u32 = 0;

    var last_click_time: i64 = 0;
    var last_button: u32 = 0;
    var click_count: u32 = 0;

    // 跟踪当前鼠标位置（用于滚轮事件）
    var current_mouse_x: i32 = 0;
    var current_mouse_y: i32 = 0;

    const min_frame_time_ms: i64 = 1000 / 60;
    var last_render_time: i64 = std.time.milliTimestamp();
    var pending_render: bool = true;
    var window_shown: bool = false; // 跟踪窗口是否已显示

    var last_url_check_time: i64 = 0;
    var url_check_pending: bool = false;
    const url_check_interval_ms: i64 = 500;

    var keydown_handled: bool = false;

    while (!quit) {
        const term = &terminal;

        // 步骤 1：处理 SDL2 事件
        while (window.pollEvent()) |event| {
            switch (event.type) {
                sdl2.SDL_QUIT => {
                    quit = true;
                    break;
                },
                sdl2.SDL_WINDOWEVENT => {
                    switch (event.window.event) {
                        sdl2.SDL_WINDOWEVENT_RESIZED, sdl2.SDL_WINDOWEVENT_SIZE_CHANGED => {
                            const width: u32 = @intCast(event.window.data1);
                            const height: u32 = @intCast(event.window.data2);

                            if (width != window.width or height != window.height) {
                                window.width = width;
                                window.height = height;

                                const b = config.window.border_pixels;
                                const avail_w = if (window.width > 2 * b) window.width - 2 * b else 0;
                                const avail_h = if (window.height > 2 * b) window.height - 2 * b else 0;

                                const new_cols = @max(1, avail_w / window.cell_width);
                                const new_rows = @max(1, avail_h / window.cell_height);

                                window.hborder_px = (window.width - @as(u32, @intCast(new_cols)) * window.cell_width) / 2;
                                window.vborder_px = (window.height - @as(u32, @intCast(new_rows)) * window.cell_height) / 2;

                                if (new_cols > 0 and new_rows > 0) {
                                    if (new_cols != terminal.col or new_rows != terminal.row) {
                                        try terminal.resize(new_rows, new_cols);
                                        try pty.resize(new_cols, new_rows);
                                        window.resizeBuffer(window.width, window.height);
                                        renderer.resize();
                                        pending_render = true;
                                    }
                                }
                            }
                        },
                        sdl2.SDL_WINDOWEVENT_EXPOSED => {
                            pending_render = true;
                        },
                        sdl2.SDL_WINDOWEVENT_FOCUS_GAINED => {
                            term.mode.focused = true;
                            if (term.mode.mouse_focus) {
                                _ = pty.write("\x1B[I") catch {};
                            }
                            pending_render = true;
                        },
                        sdl2.SDL_WINDOWEVENT_FOCUS_LOST => {
                            term.mode.focused = false;
                            if (term.mode.mouse_focus) {
                                _ = pty.write("\x1B[O") catch {};
                            }
                            pending_render = true;
                        },
                        else => {},
                    }
                },
                sdl2.SDL_KEYDOWN => {
                    renderer.resetCursorBlink();
                    keydown_handled = false;
                    const key = event.key.keysym.sym;
                    const mod = event.key.keysym.mod;
                    const shift = (mod & sdl2.KMOD_SHIFT) != 0;
                    const ctrl = (mod & sdl2.KMOD_CTRL) != 0;

                    if (shift and (key == sdl2.SDLK_PAGEUP)) {
                        selector.clear(term);
                        terminal.kscrollUp(term.row);
                        pending_render = true;
                        keydown_handled = true;
                    } else if (shift and (key == sdl2.SDLK_PAGEDOWN)) {
                        selector.clear(term);
                        terminal.kscrollDown(term.row);
                        pending_render = true;
                        keydown_handled = true;
                    } else if (ctrl and shift and (key == sdl2.SDLK_c)) {
                        selector.copyToClipboard() catch |err| {
                            std.log.err("Clipboard copy failed: {}", .{err});
                        };
                        keydown_handled = true;
                    } else if (ctrl and shift and (key == sdl2.SDLK_v)) {
                        if (selector.requestPaste()) |paste_text| {
                            try input.sendPaste(paste_text);
                            selector.clear(term);
                            term.setFullDirty();
                            pending_render = true;
                        } else |err| {
                            std.log.err("Clipboard paste failed: {}", .{err});
                        }
                        keydown_handled = true;
                    } else if (key == sdl2.SDLK_PRINTSCREEN) {
                        if (ctrl) {
                            try printer.toggle(&terminal);
                        } else if (shift) {
                            try printer.printScreen(&terminal);
                        } else {
                            try printer.printSelection(&terminal, &selector);
                        }
                        keydown_handled = true;
                    } else {
                        if (term.selection.mode != .idle) {
                            selector.clear(term);
                            term.setFullDirty();
                        }
                        keydown_handled = try input.handleKey(key, mod);
                    }
                },
                sdl2.SDL_TEXTINPUT => {
                    if (!keydown_handled) {
                        const text = std.mem.sliceTo(&event.text.text, 0);
                        // Alt+单字节字符需要发送 ESC 前缀（标准终端行为）
                        if (text.len == 1 and (sdl2.SDL_GetModState() & sdl2.KMOD_ALT) != 0) {
                            var alt_buf: [2]u8 = .{ 0x1B, text[0] };
                            _ = try pty.write(&alt_buf);
                        } else {
                            _ = try pty.write(text);
                        }
                    }
                },
                sdl2.SDL_MOUSEBUTTONDOWN => {
                    const e = event.button;
                    const shift = (sdl2.SDL_GetModState() & sdl2.KMOD_SHIFT) != 0;
                    const ctrl = (sdl2.SDL_GetModState() & sdl2.KMOD_CTRL) != 0;

                    // 更新鼠标位置
                    current_mouse_x = e.x;
                    current_mouse_y = e.y;

                    const cell = mouseToCell(e.x, e.y, &window, &terminal);
                    const cx = cell.cx;
                    const cy = cell.cy;

                    if (e.button == sdl2.SDL_BUTTON_LEFT and ctrl) {
                        if (url_detector.isUrlAt(cx, cy)) {
                            url_detector.openUrlAt(cx, cy) catch |err| {
                                std.log.err("打开 URL 失败: {}", .{err});
                            };
                        }
                        continue;
                    }

                    if (term.mode.isMouseEnabled() and !shift) {
                        try input.sendMouseReport(cx, cy, e.button, @intCast(sdl2.SDL_GetModState()), 0);
                        if (e.button >= 1 and e.button <= 3) {
                            mouse_pressed = true;
                            pressed_button = e.button;
                        }
                        continue;
                    }

                    if (e.button == sdl2.SDL_BUTTON_LEFT) {
                        const now = std.time.milliTimestamp();
                        if (e.button == last_button and now - last_click_time < config.selection.double_click_timeout_ms) {
                            click_count = (click_count % 3) + 1;
                        } else {
                            click_count = 1;
                        }
                        last_click_time = now;
                        last_button = e.button;

                        const snap_mode: SelectionSnap = switch (click_count) {
                            2 => .word,
                            3 => .line,
                            else => .none,
                        };

                        mouse_pressed = true;
                        pressed_button = e.button;

                        selector.clear(term);
                        selector.start(term, cx, cy, snap_mode);
                        if (snap_mode != .none) {
                            selector.extend(term, cx, cy, .regular, false);
                        }
                        term.setFullDirty();
                        pending_render = true;
                    } else if (e.button == sdl2.SDL_BUTTON_MIDDLE) {
                        if (selector.requestPaste()) |paste_text| {
                            try input.sendPaste(paste_text);
                            selector.clear(term);
                            term.setFullDirty();
                            pending_render = true;
                        } else |_| {}
                    } else if (e.button == sdl2.SDL_BUTTON_RIGHT) {
                        mouse_pressed = true;
                        pressed_button = e.button;
                        selector.start(term, cx, cy, .none);
                    }
                },
                sdl2.SDL_MOUSEBUTTONUP => {
                    const e = event.button;
                    const shift = (sdl2.SDL_GetModState() & sdl2.KMOD_SHIFT) != 0;

                    // 更新鼠标位置
                    current_mouse_x = e.x;
                    current_mouse_y = e.y;

                    const cell = mouseToCell(e.x, e.y, &window, &terminal);
                    const cx = cell.cx;
                    const cy = cell.cy;

                    if (term.mode.isMouseEnabled() and !shift) {
                        try input.sendMouseReport(cx, cy, e.button, @intCast(sdl2.SDL_GetModState()), 1);
                        mouse_pressed = false;
                        pressed_button = 0;
                        continue;
                    }

                    if (e.button == pressed_button) {
                        mouse_pressed = false;
                        pressed_button = 0;

                        if (e.button == sdl2.SDL_BUTTON_LEFT) {
                            if (!term.mode.isMouseEnabled() or shift) {
                                selector.extend(term, cx, cy, .regular, true);
                                if (term.selection.mode == .ready) {
                                    selector.copy(term) catch |err| {
                                        std.log.err("Copy failed: {}", .{err});
                                    };
                                }
                            } else {
                                selector.clear(term);
                                term.setFullDirty();
                                pending_render = true;
                            }
                        }
                    }
                },
                sdl2.SDL_MOUSEMOTION => {
                    const e = event.motion;
                    const shift = (sdl2.SDL_GetModState() & sdl2.KMOD_SHIFT) != 0;

                    // 更新鼠标位置
                    current_mouse_x = e.x;
                    current_mouse_y = e.y;

                    const cell = mouseToCell(e.x, e.y, &window, &terminal);
                    const cx = cell.cx;
                    const cy = cell.cy;

                    if (term.mode.isMouseEnabled() and !shift) {
                        const send_motion = term.mode.mouse_many or
                            (term.mode.mouse_btn and mouse_pressed);
                        if (send_motion) {
                            try input.sendMouseReport(cx, cy, pressed_button, @intCast(sdl2.SDL_GetModState()), 2);
                        }
                    }

                    if (mouse_pressed and pressed_button == sdl2.SDL_BUTTON_LEFT) {
                        selector.extend(term, cx, cy, .regular, false);
                        term.setFullDirty();
                        pending_render = true;
                    }
                },
                sdl2.SDL_MOUSEWHEEL => {
                    const shift = (sdl2.SDL_GetModState() & sdl2.KMOD_SHIFT) != 0;
                    if (event.wheel.y != 0) {
                        if (term.mode.isMouseEnabled() and !shift) {
                            const cell = mouseToCell(current_mouse_x, current_mouse_y, &window, &terminal);
                            const btn: u32 = if (event.wheel.y > 0) 4 else 5;
                            try input.sendMouseReport(cell.cx, cell.cy, btn, @intCast(sdl2.SDL_GetModState()), 0);
                        } else {
                            if (event.wheel.y > 0) {
                                if (term.mode.alt_screen) {
                                    _ = try pty.write("\x1B[A");
                                } else {
                                    selector.clear(term);
                                    terminal.kscrollUp(3);
                                    pending_render = true;
                                }
                            } else {
                                if (term.mode.alt_screen) {
                                    _ = try pty.write("\x1B[B");
                                } else {
                                    selector.clear(term);
                                    terminal.kscrollDown(3);
                                    pending_render = true;
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }

        if (quit) break;

        // 步骤 2：处理 PTY 数据和渲染
        const now = std.time.milliTimestamp();
        var timeout_ms: i32 = 100; // 默认 100ms，降低 CPU 占用

        if (pending_render) {
            // 如果有待渲染内容，使用较短的超时
            timeout_ms = @min(timeout_ms, 10);
        }

        if (pending_render and (now - last_render_time >= min_frame_time_ms)) {
            if (!terminal.mode.sync_update) {
                if (url_check_pending and (now - last_url_check_time >= url_check_interval_ms)) {
                    url_detector.clearHighlights();
                    url_detector.highlightUrls() catch |err| {
                        std.log.err("URL 高亮失败: {}", .{err});
                    };
                    last_url_check_time = now;
                    url_check_pending = false;
                }

                _ = try renderer.render(&terminal, &selector, true);
                window.present();

                // 首次渲染完成后显示窗口，避免启动闪烁
                if (!window_shown) {
                    window.show();
                    window_shown = true;
                }

                last_render_time = std.time.milliTimestamp();
                pending_render = false;
            }
        }

        if (config.cursor.blink_interval_ms > 0) {
            const next_blink = renderer.last_blink_time + config.cursor.blink_interval_ms;
            if (now >= next_blink) {
                term.mode.blink = !term.mode.blink;
                renderer.cursor_blink_state = !renderer.cursor_blink_state;
                if (term.isAttrSet(.{ .blink = true })) {
                    term.setDirtyAttr(.{ .blink = true });
                }
                if (term.cursor_style.shouldBlink()) {
                    if (term.dirty) |dirty| {
                        if (term.cursor.y < dirty.len) {
                            dirty[term.cursor.y] = true;
                        }
                    }
                }
                renderer.last_blink_time = now;
                pending_render = true;
                timeout_ms = 0;
            } else {
                const wait = @as(i32, @intCast(next_blink - now));
                timeout_ms = @min(timeout_ms, wait);
            }
        }

        var fds = [_]std.posix.pollfd{
            .{ .fd = pty.master, .events = std.posix.POLL.IN, .revents = 0 },
        };

        _ = std.posix.poll(&fds, timeout_ms) catch |err| {
            if (err != error.Interrupted) {
                std.log.err("Poll failed: {}", .{err});
            }
        };

        if (!pty.isChildAlive()) {
            std.log.info("子进程已退出", .{});
            quit = true;
            break;
        }

        if ((fds[0].revents & std.posix.POLL.IN) != 0) {
            const n = pty.read(read_buffer) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.InputOutput) {
                    quit = true;
                    break;
                }
                return err;
            };

            if (n > 0) {
                try parser.parseBytes(read_buffer[0..n]);
                pending_render = true;
                url_check_pending = true;

                if (term.window_title_dirty) {
                    window.setTitle(term.window_title);
                    term.window_title_dirty = false;
                }

                if (term.clipboard_data) |data| {
                    if (term.mode.focused) {
                        selector.copyTextToClipboard(data, term.clipboard_mask) catch |err| {
                            std.log.err("OSC 52 剪贴板同步失败: {}", .{err});
                        };
                        allocator.free(data);
                        term.clipboard_data = null;
                    }
                }
            }
        }
        window.updateImeSpot(term.cursor.x, term.cursor.y);
    }

    return 0;
}
