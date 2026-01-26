//! stz - 简单终端模拟器 (Zig 重写版)
//! 主程序入口和事件循环
//!
//! ## 文件概述
//!
//! 本文件是终端模拟器的入口点，负责：
//! 1. 初始化所有子系统（窗口、渲染器、PTY、终端等）
//! 2. 运行主事件循环（处理 X11 事件和 PTY 数据）
//! 3. 管理键盘输入、鼠标事件、窗口大小调整
//! 4. 协调渲染和屏幕更新
//!
//! ## 核心概念
//!
//! ### 1. 主事件循环
//! 终端模拟器是一个事件驱动程序，主循环不断等待和处理事件：
//! - **X11 事件**：键盘输入、鼠标点击、窗口调整、焦点变化
//! - **PTY 数据**：shell 程序输出的字节流
//!
//! ### 2. 初始化顺序
//! 1. Window（窗口）：创建 X11 窗口
//! 2. Renderer（渲染器）：加载字体，初始化 Xft
//! 3. PTY（伪终端）：创建 fork/exec 子进程
//! 4. Terminal（终端）：初始化屏幕缓冲区、光标、解析器
//!
//! ### 3. 事件处理流程
//!
//! ```
//! while (!quit) {
//!     // 1. 处理所有挂起的 X11 事件
//!     while (window.pollEvent()) |event| {
//!         switch (event.type) {
//!             KeyPress: 处理键盘输入，发送给 PTY
//!             ButtonPress/Release: 处理鼠标选择
//!             ConfigureNotify: 处理窗口大小调整
//!             Expose: 处理窗口重绘
//!             FocusIn/Out: 处理焦点变化
//!             SelectionRequest/Notify: 处理剪贴板
//!         }
//!     }
//!
//!     // 2. 检查 PTY 数据
//!     if (pty.read(read_buffer)) |n| {
//!         terminal.processBytes(buffer[0..n]);  // 解析并更新屏幕
//!         pending_render = true;                 // 标记需要渲染
//!     }
//!
//!     // 3. 如果需要渲染，更新屏幕
//!     if (pending_render) {
//!         renderer.render(&terminal);  // 渲染屏幕到 Pixmap
//!         window.present();                  // 显示 Pixmap 到窗口
//!         pending_render = false;
//!     }
//! }
//! ```
//!
//! ## 新手入门：理解终端模拟器的工作原理
//!
//! ### 终端模拟器 = 窗口 + 渲染器 + PTY + 解析器
//!
//! 1. **Window (窗口)**: X11 窗口，接收用户输入（键盘、鼠标）
//! 2. **Renderer (渲染器)**: 使用 Xft 将字符绘制到窗口
//! 3. **PTY (伪终端)**: 与 shell 程序通信的双向通道
//! 4. **Terminal (终端)**: 解析 PTY 输出的转义序列，更新屏幕缓冲区
//!
//! ### 数据流向
//!
//! #### 输入（用户 → Shell）
//! ```
//! 键盘输入 → KeyPress 事件 → 处理特殊键 → 发送给 PTY → Shell 程序
//! ```
//!
//! #### 输出（Shell → 屏幕）
//! ```
//! Shell 程序 → PTY 输出 → 转义序列 → 解析器 → 屏幕缓冲区 → 渲染器 → 窗口
//! //!
//!
//! ## 新手入门：理解终端模拟器的工作原理
//!
//! ### 终端模拟器 = 窗口 + 渲染器 + PTY + 解析器
//!
//! 1. **Window (窗口)**: X11 窗口，接收用户输入（键盘、鼠标）
//! 2. **Renderer (渲染器)**: 使用 Xft 将字符绘制到窗口
//! 3. **PTY (伪终端)**: 与 shell 程序通信的双向通道
//! 4. **Terminal (终端)**: 解析 PTY 输出的转义序列，更新屏幕缓冲区
//!
//! ### 数据流向
//!
//! #### 输入（用户 → Shell）
//! ```
//! 键盘输入 → KeyPress 事件 → 处理特殊键 → 发送给 PTY → Shell 程序
//! ```
//!
//! #### 输出（Shell → 屏幕）
//! ```
//! Shell 程序 → PTY 输出 → 转义序列 → 解析器 → 屏幕缓冲区 → 渲染器 → 窗口
//! //!
//!
//! ## 与原版 st 的对应关系
//! - main() 函数对应 st 的 main() 函数
//! - 主事件循环对应 st 的 run() 函数
//! - 所有 X11 事件处理与 st 的事件处理逻辑对齐

const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});
const x11 = @import("x11.zig");

const Terminal = @import("terminal.zig").Terminal;
const Parser = @import("parser.zig").Parser;
const PTY = @import("pty.zig").PTY;
const Window = @import("window.zig").Window;
const Renderer = @import("renderer.zig").Renderer;
const Input = @import("input.zig").Input;
const Selector = @import("selection.zig").Selector;
const UrlDetector = @import("url.zig").UrlDetector;
const Printer = @import("printer.zig").Printer;
const config = @import("config.zig");
const types = @import("types.zig");
const screen = @import("screen.zig");
const c_locale = @cImport({
    @cInclude("locale.h");
});

pub fn main() !u8 {
    // ========== 获取内存分配器 ==========
    //
    // 使用 Zig 的 GeneralPurposeAllocator（GPA），这是一个通用的内存分配器。
    // GPA 会检测内存泄漏，在程序结束时报告泄漏情况。
    //
    // 为什么需要分配器？
    // - 动态分配屏幕缓冲区（line、alt、hist）
    // - 动态分配转义序列字符串缓冲区（str.buf）
    // - 动态分配选择文本缓冲区（selector.selected_text）
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
    //
    // 设置 LC_CTYPE 为空字符串，使用系统默认本地化。
    // 这对于输入法（IME）是必需的。
    //
    // 什么是本地化？
    // - 本地化决定了字符编码、字符分类（如大写字母、小写字母、数字等）
    // - 对中文输入法非常重要
    _ = c_locale.setlocale(c_locale.LC_CTYPE, "");

    // ========== 解析命令行参数 ==========
    //
    // 当前实现：从配置文件读取行列数
    // 未来扩展：可以添加命令行参数支持（如 --cols 120 --rows 35）
    const cols = config.window.cols;
    const rows = config.window.rows;
    const shell_path = config.shell;

    std.log.info("stz - Zig 终端模拟器 v0.1.0", .{});
    std.log.info("配置尺寸: {d}x{d}", .{ cols, rows });

    // ========== 初始化窗口 ==========
    //
    // 创建 X11 窗口，但此时窗口还不可见。
    // 窗口初始化步骤：
    // 1. 连接到 X11 服务器
    // 2. 创建窗口（使用默认大小）
    // 3. 设置输入法上下文（IC，用于中文输入）
    var window = try Window.init("stz", cols, rows, allocator);
    defer window.deinit();

    // ========== 初始化渲染器 ==========
    //
    // 渲染器负责：
    // 1. 加载字体（使用 FontConfig）
    // 2. 初始化 Xft 渲染器
    // 3. 计算字符的宽度和高度
    //
    // 注意：此时字体还未加载，需要调用 resize() 来加载字体并计算尺寸。
    var renderer = try Renderer.init(&window, allocator);
    defer renderer.deinit();

    // ========== 调整窗口大小以匹配实际字体尺寸 ==========
    //
    // 步骤：
    // 1. resizeToGrid(): 根据配置的行列数和字体尺寸，调整窗口像素大小
    // 2. resizeBuffer(): 调整 Pixmap（双缓冲）的大小
    // 3. renderer.resize(): 加载字体并计算字符宽高
    //
    // 为什么需要这一步？
    // - 配置文件指定的行列数是逻辑值（如 120x35）
    // - 窗口需要的是像素值（如 2400x700）
    // - 需要根据字体尺寸进行转换（假设 20x20 像素，则 120x35 = 2400x700）
    window.resizeToGrid(cols, rows);
    window.resizeBuffer(window.width, window.height);
    renderer.resize();

    // ========== 显示窗口 ==========
    //
    // 窗口现在对用户可见。
    // 但此时窗口内容为空（PTY 还未初始化，还没有输出）。
    window.show();

    // ========== 等待窗口映射完成（与原版 st 对齐）==========
    //
    // 原版 st 在 run() 函数中等待 MapNotify 事件，确保窗口完全映射后再继续。
    // 同时处理可能的 ConfigureNotify 事件，以获取准确的窗口尺寸。
    var mapped = false;
    while (!mapped) {
        var event: x11.c.XEvent = undefined;
        _ = x11.c.XNextEvent(window.dpy, &event);
        if (x11.c.XFilterEvent(&event, x11.c.None) != 0) continue;

        switch (event.type) {
            x11.c.MapNotify => {
                mapped = true;
            },
            x11.c.ConfigureNotify => {
                // 窗口管理器可能已经调整了窗口尺寸
                const width = @as(u32, @intCast(event.xconfigure.width));
                const height = @as(u32, @intCast(event.xconfigure.height));
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
                    // 此时终端和 PTY 尚未初始化，暂不调整它们
                    // 后续的 ConfigureNotify 事件会处理调整
                }
            },
            else => {},
        }
    }

    // ========== 设置 TERM 环境变量 ==========
    //
    // TERM 环境变量告诉 shell 程序终端的类型。
    // - xterm-256color: 告诉程序终端支持 256 色和真彩色
    // - st: 原版 st 终端的 TERM 值
    //
    // 为什么需要？
    // - 程序根据 TERM 值决定发送哪些转义序列
    // - 例如：vim 会根据 TERM 值决定是否使用 256 色
    _ = c.setenv("TERM", config.term_type, 1);

    // ========== 初始化 PTY（伪终端）==========
    //
    // PTY = Pseudo-TTY（伪终端），是内核提供的一种虚拟终端设备。
    // PTY 的作用：在终端模拟器和 shell 程序之间建立双向通信通道。
    //
    // 初始化步骤：
    // 1. 打开 /dev/ptmx（伪终端主设备）
    // 2. 设置终端属性（波特率、字符大小等）
    // 3. Fork 子进程
    // 4. 子进程中：打开从设备，exec shell
    // 5. 父进程中：返回 PTY 句柄，用于读写
    //
    // 注意：此时使用配置的行列数初始化。
    // 如果窗口管理器不遵守我们请求的大小，
    // 后续的 ConfigureNotify 事件会修正 PTY 大小。
    var pty = try PTY.init(shell_path, cols, rows);
    defer pty.close();

    // ========== 初始化终端 ==========
    //
    // 终端（Terminal）是终端模拟器的核心逻辑层。
    // 它负责：
    // 1. 管理屏幕缓冲区（line、alt、hist）
    // 2. 管理光标位置和状态
    // 3. 解析转义序列（由 Parser 负责）
    //
    // 初始化后，屏幕缓冲区被填充为空格字符。
    var terminal = try Terminal.init(rows, cols, allocator);
    defer terminal.deinit();

    // ========== 设置 Parser ==========
    //
    // Parser 需要 Term 和 PTY 的引用：
    // - Term: 解析转义序列后，需要更新 Term 的屏幕缓冲区
    // - PTY: 某些转义序列需要向 PTY 发送响应（如终端标识查询）
    var parser = try Parser.init(&terminal, &pty, allocator);
    defer parser.deinit();

    // ========== 设置 PTY 为非阻塞模式 ==========
    //
    // 非阻塞模式：read() 立即返回，不等待数据。
    // - 如果有数据：返回读取的字节数
    // - 如果没有数据：返回 EAGAIN（错误：会再次尝试）
    //
    // 为什么需要？
    // - 主事件循环需要同时等待 X11 事件和 PTY 数据
    // - 使用 poll() 等待多个文件描述符
    // - PTY 非阻塞模式确保循环不会被阻塞
    try pty.setNonBlocking();

    // ========== 初始化输入处理器 ==========
    //
    // 输入处理器负责：
    // 1. 处理键盘输入（KeyPress 事件）
    // 2. 将特殊键转换为转义序列（如方向键 → ESC [ A）
    // 3. 发送给 PTY
    var input = Input.init(&pty, &terminal);

    // ========== 初始化选择器 ==========
    //
    // 选择器负责：
    // 1. 处理鼠标拖拽选择（ButtonPress、MotionNotify、ButtonRelease）
    // 2. 智能选择边界（单词吸附、行吸附）
    // 3. 复制/粘贴到 X11 剪贴板（PRIMARY、CLIPBOARD）
    var selector = Selector.init(allocator);
    selector.setX11Context(window.dpy, window.win);
    defer selector.deinit();

    // ========== 初始化 URL 检测器 ==========
    //
    // URL 检测器负责：
    // 1. 识别屏幕上的 URL（http://、https://、ftp://）
    // 2. Ctrl+点击打开 URL（使用 xdg-open）
    var url_detector = UrlDetector.init(&terminal, allocator);

    // ========== 初始化打印器 ==========
    //
    // 打印器负责：
    // 1. 打印屏幕内容（Print 键）
    // 2. 打印选择内容（Shift+Print 键）
    // 3. 打印模式切换（Ctrl+Print 键）
    var printer = Printer.init(allocator);
    defer printer.deinit();

    // ========== 主事件循环 ==========
    //
    // 这是终端模拟器的核心循环，不断处理 X11 事件和 PTY 数据。
    //
    // 变量说明：
    // - read_buffer: PTY 数据缓冲区（8KB）
    // - quit: 退出标志（设置为 true 时退出循环）
    // - mouse_pressed: 鼠标按下状态
    // - last_click_time: 上次点击时间（用于检测双击/三击）
    // - paste_buffer: X11 剪贴板缓冲区
    // - pending_render: 待渲染标志（屏幕内容改变时设置为 true）
    //
    // 限制帧率：
    // - min_frame_time_ms: 最小帧间隔（1000 / 60 = 16.67ms）
    // - last_render_time: 上次渲染时间
    // - pending_render: 标记需要渲染
    const read_buffer = try allocator.alloc(u8, 8192);
    defer allocator.free(read_buffer);

    var quit: bool = false;
    var mouse_pressed: bool = false;
    var pressed_button: u32 = 0;
    var mouse_x: usize = 0;
    var mouse_y: usize = 0;

    // 点击检测变量（用于双击/三击检测）
    var last_click_time: i64 = 0; // 上次点击时间（毫秒）
    var last_button: u32 = 0; // 上次点击的按钮
    var click_count: u32 = 0; // 点击计数（1=单击，2=双击，3=三击）

    // X11 剪贴板缓冲区（用于接收粘贴内容）
    var paste_buffer = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer paste_buffer.deinit(allocator);

    // ========== 渲染限制 (60 FPS) ==========
    //
    // 为什么要限制帧率？
    // - 避免不必要的渲染（节省 CPU）
    // - 避免闪烁（双缓冲）
    // - 减少电源消耗（笔记本电脑）
    //
    // 如何实现？
    // - 记录上次渲染时间
    // - 如果距离上次渲染时间 < 16.67ms，延迟渲染
    // - 使用 poll() 的超时参数控制延迟
    const min_frame_time_ms: i64 = 1000 / 60; // 60 FPS = 16.67ms
    var last_render_time: i64 = std.time.milliTimestamp(); // 上次渲染时间
    var pending_render: bool = false; // 待渲染标志

    // ========== 初始渲染 ==========
    //
    // 渲染初始屏幕（全空格），然后显示窗口。
    // 此时 PTY 还未输出任何内容，所以屏幕是空的。
    if (try renderer.render(&terminal, &selector)) |_| {
        window.present();
    }

    // ========== 主循环 ==========
    while (!quit) {
        // Alias term for easy access
        const term = &terminal;

        // ========== 步骤 1：处理所有挂起的 X11 事件 ==========
        //
        // X11 事件包括：
        // - ClientMessage: 窗口关闭请求
        // - KeyPress: 键盘输入
        // - ConfigureNotify: 窗口大小调整
        // - Expose: 窗口重绘
        // - ButtonPress/Release: 鼠标点击/释放
        // - MotionNotify: 鼠标移动
        // - FocusIn/Out: 焦点变化
        // - SelectionRequest/Notify: 剪贴板请求/通知
        //
        // XFilterEvent():
        // - 处理输入法（IME）事件
        // - 如果事件被输入法处理，返回非零，跳过该事件
        while (window.pollEvent()) |event| {
            var ev = event;
            if (x11.c.XFilterEvent(&ev, x11.c.None) != 0) continue;

            switch (ev.type) {
                // ========== ClientMessage: 窗口关闭请求 ==========
                // 窗口管理器（如 i3、GNOME Shell）发送关闭请求
                x11.c.ClientMessage => {
                    if (@as(x11.c.Atom, @intCast(ev.xclient.data.l[0])) == window.wm_delete_window) {
                        quit = true;
                        break;
                    }
                },

                // ========== KeyPress: 键盘输入 ==========
                // 处理键盘输入，包括：
                // - 普通字符（a-z、0-9、符号）
                // - 特殊键（方向键、Backspace、Delete 等）
                // - 功能键（F1-F12）
                // - 组合键（Ctrl+C、Ctrl+Shift+V 等）
                x11.c.KeyPress => {
                    renderer.resetCursorBlink(); // Reset blink on input

                    // Check for scroll shortcuts (Shift + PageUp/PageDown)
                    const state = ev.xkey.state;
                    const shift = (state & x11.c.ShiftMask) != 0;
                    const keycode = ev.xkey.keycode;
                    const keysym = x11.c.XkbKeycodeToKeysym(window.dpy, @intCast(keycode), 0, if (shift) 1 else 0);

                    const XK_Prior = 0xFF55; // PageUp
                    const XK_Next = 0xFF56; // PageDown
                    const XK_KP_Prior = 0xFF9A;
                    const XK_KP_Next = 0xFF9B;
                    const XK_Print = 0xFF61; // Print/SysRq

                    const ctrl = (state & x11.c.ControlMask) != 0;

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
                        const clipboard = x11.getClipboardAtom(dpy);
                        selector.requestSelection(clipboard) catch |err| {
                            std.log.err("Clipboard paste request failed: {}", .{err});
                        };
                    } else if (keysym == XK_Print) {
                        // Print key handling
                        if (ctrl) {
                            // Ctrl+Print: toggle printer mode
                            try printer.toggle(&terminal);
                        } else if (shift) {
                            // Shift+Print: print screen
                            try printer.printScreen(&terminal);
                        } else {
                            // Print: print selection
                            try printer.printSelection(&terminal, &selector);
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
                            var status: x11.c.Status = undefined;
                            var kbuf: [32]u8 = undefined;
                            const n = x11.c.Xutf8LookupString(ic, &ev.xkey, &kbuf, kbuf.len, null, &status);

                            // Debug logging for input troubleshooting
                            // std.log.debug("XIM Input: n={d}, status={d}", .{n, status});

                            // 宽松的输入检查：只要有返回数据且未溢出缓冲区，就写入 PTY
                            // 移除对 status 的严格检查，因为某些环境下 status 可能不符合预期 (如 XLookupKeySym)
                            // 这与原版 st 的行为一致 (st 忽略 status，仅检查 len)
                            if (n > 0 and n <= kbuf.len) {
                                _ = try pty.write(kbuf[0..@as(usize, @intCast(n))]);
                            } else if (n == 0) {
                                // Fallback: If XIM returns nothing (e.g. broken locale), try raw XLookupString
                                // This ensures basic ASCII input works even if IME is misconfigured
                                var buf: [32]u8 = undefined;
                                const len = x11.c.XLookupString(&ev.xkey, &buf, buf.len, null, null);
                                if (len > 0) {
                                    std.log.info("XIM fallback used for keycode {d}: '{s}'", .{ ev.xkey.keycode, buf[0..@as(usize, @intCast(len))] });
                                    _ = try pty.write(buf[0..@as(usize, @intCast(len))]);
                                }
                            }
                        } else {
                            var kbuf: [32]u8 = undefined;
                            const n = x11.c.XLookupString(&ev.xkey, &kbuf, kbuf.len, null, null);
                            if (n > 0) {
                                _ = try pty.write(kbuf[0..@as(usize, @intCast(n))]);
                            }
                        }
                    }
                },
                x11.c.ConfigureNotify => {
                    const width = @as(u32, @intCast(ev.xconfigure.width));
                    const height = @as(u32, @intCast(ev.xconfigure.height));

                    if (width != window.width or height != window.height) {
                        window.width = width;
                        window.height = height;

                        const b = config.window.border_pixels;
                        // remove fudge factor to match st behavior (strict truncation)
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
                                if (try renderer.render(&terminal, &selector)) |_| {
                                    window.present(); // Resize always needs full present
                                }
                            }
                        }
                    }
                },
                x11.c.Expose => {
                    if (!terminal.mode.sync_update) {
                        if (try renderer.render(&terminal, &selector)) |_| {
                            try renderer.renderCursor(&terminal);
                            window.present();
                        } else {
                            // Expose should always refresh window from pixmap at least
                            window.present();
                        }
                    }
                },
                x11.c.ButtonPress => {
                    const e = ev.xbutton;
                    const shift = (e.state & x11.c.ShiftMask) != 0;

                    const border_x = @as(c_int, @intCast(window.hborder_px));
                    const border_y = @as(c_int, @intCast(window.vborder_px));
                    const cell_w = @as(c_int, @intCast(window.cell_width));
                    const cell_h = @as(c_int, @intCast(window.cell_height));

                    var mx = e.x - border_x;
                    var my = e.y - border_y;

                    const term_w = @as(c_int, @intCast(terminal.col)) * cell_w;
                    const term_h = @as(c_int, @intCast(terminal.row)) * cell_h;

                    mx = @max(0, @min(mx, term_w - 1));
                    my = @max(0, @min(my, term_h - 1));

                    const cx = @as(usize, @intCast(@divTrunc(mx, cell_w)));
                    const cy = @as(usize, @intCast(@divTrunc(my, cell_h)));

                    // Ctrl + Left Click: 打开 URL
                    if (e.button == x11.c.Button1 and
                        (e.state & x11.c.ControlMask) != 0)
                    {
                        if (url_detector.isUrlAt(cx, cy)) {
                            url_detector.openUrlAt(cx, cy) catch |err| {
                                std.log.err("打开 URL 失败: {}", .{err});
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

                    if (e.button == x11.c.Button1) {
                        // 检测双击/三击
                        const now = std.time.milliTimestamp();
                        if (e.button == last_button and now - last_click_time < config.selection.double_click_timeout_ms) {
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
                        if (try renderer.render(term, &selector)) |rect| {
                            window.presentPartial(rect);
                        }
                    } else if (e.button == x11.c.Button2) {
                        // Middle click: paste from PRIMARY selection
                        selector.requestPaste() catch |err| {
                            std.log.err("Paste request failed: {}", .{err});
                        };
                    } else if (e.button == x11.c.Button3) {
                        // Right click: extend selection or copy
                        mouse_pressed = true;
                        pressed_button = e.button;
                        selector.start(term, cx, cy, .none);
                    } else if (e.button == x11.c.Button4) { // Scroll Up
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
                    } else if (e.button == x11.c.Button5) { // Scroll Down
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
                x11.c.ButtonRelease => {
                    const e = ev.xbutton;
                    const shift = (e.state & x11.c.ShiftMask) != 0;

                    const border_x = @as(c_int, @intCast(window.hborder_px));
                    const border_y = @as(c_int, @intCast(window.vborder_px));
                    const cell_w = @as(c_int, @intCast(window.cell_width));
                    const cell_h = @as(c_int, @intCast(window.cell_height));

                    var mx = e.x - border_x;
                    var my = e.y - border_y;

                    const term_w = @as(c_int, @intCast(terminal.col)) * cell_w;
                    const term_h = @as(c_int, @intCast(terminal.row)) * cell_h;

                    mx = @max(0, @min(mx, term_w - 1));
                    my = @max(0, @min(my, term_h - 1));

                    const cx = @as(usize, @intCast(@divTrunc(mx, cell_w)));
                    const cy = @as(usize, @intCast(@divTrunc(my, cell_h)));

                    if (terminal.mode.mouse and !shift) {
                        try input.sendMouseReport(cx, cy, e.button, e.state, 1);
                        mouse_pressed = false;
                        pressed_button = 0;
                        continue;
                    }

                    if (e.button == pressed_button) {
                        mouse_pressed = false;
                        pressed_button = 0;

                        if (e.button == x11.c.Button1) {
                            // Copy on release
                            selector.copy(term) catch |err| {
                                std.log.err("Copy failed: {}", .{err});
                            };
                        }
                    }
                },
                x11.c.MotionNotify => {
                    const e = ev.xmotion;
                    const shift = (e.state & x11.c.ShiftMask) != 0;

                    const border_x = @as(c_int, @intCast(window.hborder_px));
                    const border_y = @as(c_int, @intCast(window.vborder_px));
                    const cell_w = @as(c_int, @intCast(window.cell_width));
                    const cell_h = @as(c_int, @intCast(window.cell_height));

                    var mx = e.x - border_x;
                    var my = e.y - border_y;

                    const term_w = @as(c_int, @intCast(terminal.col)) * cell_w;
                    const term_h = @as(c_int, @intCast(terminal.row)) * cell_h;

                    mx = @max(0, @min(mx, term_w - 1));
                    my = @max(0, @min(my, term_h - 1));

                    const cx = @as(usize, @intCast(@divTrunc(mx, cell_w)));
                    const cy = @as(usize, @intCast(@divTrunc(my, cell_h)));

                    if (terminal.mode.mouse and !shift) {
                        // Only send motion if button is pressed or mouse_many/mouse_motion is set
                        const send_motion = terminal.mode.mouse_many or
                            (terminal.mode.mouse_motion and mouse_pressed);
                        if (send_motion) {
                            try input.sendMouseReport(cx, cy, 0, e.state, 2);
                        }
                        continue;
                    }

                    if (mouse_pressed and pressed_button == x11.c.Button1) {
                        // Update selection
                        selector.extend(term, cx, cy, .regular, false);
                        screen.setFullDirty(term);
                        if (try renderer.render(term, &selector)) |rect| {
                            window.presentPartial(rect);
                        }
                    }
                },
                x11.c.SelectionRequest => {
                    const e = ev.xselectionrequest;
                    std.log.info("SelectionRequest received (target={d})", .{e.target});

                    var notify: x11.c.XEvent = undefined;
                    notify.type = x11.c.SelectionNotify;
                    notify.xselection.display = e.display;
                    notify.xselection.requestor = e.requestor;
                    notify.xselection.selection = e.selection;
                    notify.xselection.target = e.target;
                    notify.xselection.time = e.time;
                    notify.xselection.property = e.property;

                    if (notify.xselection.property == 0) notify.xselection.property = e.target;

                    const utf8 = x11.getUtf8Atom(window.dpy);
                    const targets = x11.getTargetsAtom(window.dpy);

                    var success = false;
                    if (e.target == targets) {
                        const supported = [_]x11.c.Atom{ targets, utf8, x11.c.XA_STRING };
                        _ = x11.c.XChangeProperty(window.dpy, e.requestor, notify.xselection.property, x11.c.XA_ATOM, 32, x11.c.PropModeReplace, @ptrCast(&supported), supported.len);
                        success = true;
                    } else if (e.target == utf8 or e.target == x11.c.XA_STRING) {
                        if (selector.selected_text) |text| {
                            _ = x11.c.XChangeProperty(window.dpy, e.requestor, notify.xselection.property, e.target, 8, x11.c.PropModeReplace, text.ptr, @intCast(text.len));
                            success = true;
                        }
                    }

                    if (!success) notify.xselection.property = 0;

                    _ = x11.c.XSendEvent(window.dpy, e.requestor, 1, 0, &notify);
                },
                x11.c.SelectionNotify => {
                    const e = ev.xselection;
                    std.log.info("SelectionNotify received", .{});

                    if (e.property != 0) {
                        var text_prop: x11.c.XTextProperty = undefined;
                        // Use ev.property (which should be PRIMARY)
                        if (x11.c.XGetTextProperty(window.dpy, e.requestor, &text_prop, e.property) > 0) {
                            defer {
                                _ = x11.c.XFree(@ptrCast(text_prop.value));
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
                                std.log.info("已将 {d} 字节写入 PTY: {s}", .{ written, paste_text });

                                // Also add to paste buffer
                                try paste_buffer.appendSlice(allocator, paste_text);

                                std.log.info("粘贴: {s}", .{paste_text});
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
                x11.c.SelectionClear => {
                    const e = ev.xselectionclear;
                    std.log.info("SelectionClear received", .{});
                    selector.handleSelectionClear(term, &e);
                    // Redraw to clear highlight
                    if (try renderer.render(term, &selector)) |rect| {
                        window.presentPartial(rect);
                    }
                },
                x11.c.FocusIn => {
                    // std.log.info("FocusIn", .{});
                    term.mode.focused = true;
                    if (window.ic) |ic| x11.c.XSetICFocus(ic);
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
                x11.c.FocusOut => {
                    // std.log.info("FocusOut", .{});
                    term.mode.focused = false;
                    if (window.ic) |ic| x11.c.XUnsetICFocus(ic);
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
                x11.c.EnterNotify,
                x11.c.LeaveNotify,
                x11.c.ReparentNotify,
                x11.c.MapNotify,
                x11.c.NoExpose,
                x11.c.KeyRelease,
                => {
                    // 忽略这些常见但当前无需处理的事件，避免日志刷屏
                },
                else => {
                    std.log.debug("未处理的 X11 事件: {d}", .{ev.type});
                },
            }
        }

        if (quit) break;

        // Check for cursor blink update
        const now = std.time.milliTimestamp();
        var timeout_ms: i32 = -1;

        // 渲染检查: 如果有待处理的渲染请求且时间间隔已到，则渲染
        if (pending_render and (now - last_render_time >= min_frame_time_ms)) {
            if (!terminal.mode.sync_update) {
                const rect = try renderer.render(&terminal, &selector);
                try renderer.renderCursor(&terminal);

                if (rect) |r| {
                    window.presentPartial(r);
                } else {
                    // 如果没有脏行，但 pending_render 为 true（可能是光标闪烁或移动），则刷新全屏或光标区域
                    // 为了稳健性，这里刷新全屏。在双缓冲下，开销很小。
                    window.present();
                }

                last_render_time = std.time.milliTimestamp();
                pending_render = false;
            }
        }

        if (config.cursor.blink_interval_ms > 0) {
            const next_blink = renderer.last_blink_time + config.cursor.blink_interval_ms;
            if (now >= next_blink) {
                // Time to toggle blink state
                term.mode.blink = !term.mode.blink;
                renderer.cursor_blink_state = !renderer.cursor_blink_state;

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
            .{
                .fd = pty.master,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = x11.c.XConnectionNumber(window.dpy),
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        _ = std.posix.poll(&fds, timeout_ms) catch |err| {
            std.log.err("Poll failed: {}", .{err});
            continue;
        };

        // 3. 检查子进程是否还活着
        if (!pty.isChildAlive()) {
            std.log.info("子进程已退出", .{});
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
                try parser.processBytes(read_buffer[0..n]);
                pending_render = true;
            }
        }
    }

    return 0;
}
