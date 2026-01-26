//! X11 窗口系统抽象层
//!
//! Window 模块负责创建和管理 X11 窗口，处理窗口事件。
//!
//! 核心功能：
//! - 窗口创建和配置：创建 X11 窗口，设置属性、事件掩码、鼠标光标
//! - 双缓冲管理：创建和管理 Pixmap（离屏缓冲区）
//! - 窗口大小调整：响应 ConfigureNotify 事件，调整窗口和缓冲区大小
//! - 事件轮询：使用 XNextEvent 或 XPending 获取窗口事件
//! - 输入法支持：创建 XIM/XIC 上下文，支持中文输入法
//! - 窗口标题：设置和更新窗口标题
//! - 显示和刷新：显示窗口、将 Pixmap 复制到窗口
//!
//! 双缓冲机制：
//! - Pixmap: 离屏缓冲区，所有绘图操作都在 Pixmap 上完成
//! - buf_w, buf_h: Pixmap 的尺寸
//! - renderer 渲染到 Pixmap
//! - present() 或 presentPartial() 将 Pixmap 复制到窗口
//! - 优点：避免闪烁、提高性能
//!
//! 窗口大小调整流程：
//! 1. 用户调整窗口大小 → WM 发送 ConfigureNotify 事件
//! 2. 计算新的行列数：cols = (width - 2*border) / cell_width
//! 3. 调整 PTY 大小：pty.resize(new_cols, new_rows)
//! 4. 调整终端大小：terminal.resize(new_rows, new_cols)
//! 5. 调整 Pixmap 大小：resizeBuffer(new_width, new_height)
//! 6. 重新渲染：renderer.render()
//!
//! 输入法支持 (XIM/XIC)：
//! - XIM (Input Method): 输入法上下文，与输入法服务器通信
//! - XIC (Input Context): 输入法上下文，处理特定窗口的输入
//! - 支持中文输入法（如 fcitx、ibus）
//! - 使用 Xutf8LookupString 获取输入的 UTF-8 字符
//!
//! 窗口属性：
//! - 背景色、边框色、光标
//! - 事件掩码：注册感兴趣的事件类型
//! - 重力方向：窗口调整时的对齐方式
//! - Colormap：颜色映射表
//!
//! 事件处理：
//! - KeyPress/KeyRelease: 键盘输入
//! - ButtonPress/ButtonRelease: 鼠标点击
//! - MotionNotify: 鼠标移动
//! - ConfigureNotify: 窗口大小调整
//! - Expose: 窗口重绘
//! - FocusIn/FocusOut: 焦点变化
//! - SelectionRequest/Notify: 剪贴板
//! - ClientMessage: 窗口管理器消息（如关闭窗口）

const std = @import("std");
const x11 = @import("x11.zig");
const config = @import("config.zig");

pub const WindowError = error{
    OpenDisplayFailed,
    CreateColormapFailed,
    CreateWindowFailed,
    CreateGCFailed,
};

pub const Window = struct {
    dpy: *x11.c.Display,
    win: x11.c.Window,
    screen: i32,
    root: x11.c.Window,
    vis: *x11.c.Visual,
    cmap: x11.c.Colormap,
    gc: x11.c.GC,
    im: ?x11.c.XIM = null,
    ic: ?x11.c.XIC = null,
    cursor: x11.c.Cursor = 0,
    wm_delete_window: x11.c.Atom = 0,

    // Double buffering
    buf: x11.c.Pixmap = 0,
    buf_w: u32 = 0,
    buf_h: u32 = 0,

    // Dimensions
    width: u32,
    height: u32,
    cell_width: u32,
    cell_height: u32,
    cols: usize,
    rows: usize,

    // Dynamic borders for centering
    hborder_px: u32,
    vborder_px: u32,

    allocator: std.mem.Allocator,

    pub fn init(title: [:0]const u8, cols: usize, rows: usize, allocator: std.mem.Allocator) !Window {
        const dpy = x11.c.XOpenDisplay(null) orelse return error.OpenDisplayFailed;
        const screen = x11.c.XDefaultScreen(dpy);
        const root = x11.c.XRootWindow(dpy, screen);
        const vis = x11.c.XDefaultVisual(dpy, screen);

        // TODO: Try to find a visual with alpha channel support for transparency?
        // For now use default

        const cmap = x11.c.XCreateColormap(dpy, root, vis, x11.c.AllocNone);

        // Calculate size using estimated cell dimensions
        // Note: These will be updated by renderer.init() after font is loaded
        const font_size = config.font.size;
        // Conservative estimates to ensure window is large enough
        // Actual font metrics will be loaded and cell_* will be updated
        const cell_w = @max(@as(u32, font_size / 2), 1);
        const cell_h = @as(u32, font_size);
        const border = config.window.border_pixels;

        const win_w = cols * cell_w + border * 2;
        const win_h = rows * cell_h + border * 2;

        // Set default mouse cursor (I-beam)
        const mouse_cursor = x11.c.XCreateFontCursor(dpy, x11.c.XC_xterm);

        var attrs: x11.c.XSetWindowAttributes = undefined;
        attrs.background_pixel = 0; // Black
        attrs.border_pixel = 0;
        attrs.bit_gravity = x11.c.NorthWestGravity;
        attrs.colormap = cmap;
        attrs.cursor = mouse_cursor;
        attrs.event_mask = x11.c.KeyPressMask | x11.c.KeyReleaseMask | x11.c.ButtonPressMask |
            x11.c.ButtonReleaseMask | x11.c.PointerMotionMask | x11.c.StructureNotifyMask |
            x11.c.ExposureMask | x11.c.FocusChangeMask | x11.c.EnterWindowMask | x11.c.LeaveWindowMask;

        const win = x11.c.XCreateWindow(dpy, root, 0, 0, @intCast(win_w), @intCast(win_h), 0, x11.c.XDefaultDepth(dpy, screen), x11.c.InputOutput, vis, x11.c.CWBackPixel | x11.c.CWBorderPixel | x11.c.CWBitGravity | x11.c.CWEventMask | x11.c.CWColormap | x11.c.CWCursor, &attrs);

        if (win == 0) return error.CreateWindowFailed;

        // Apply cursor
        if (mouse_cursor != 0) {
            _ = x11.c.XDefineCursor(dpy, win, mouse_cursor);
        }

        // Set title
        _ = x11.c.XStoreName(dpy, win, title);

        // Create GC
        const gc = x11.c.XCreateGC(dpy, win, 0, null);
        if (gc == null) return error.CreateGCFailed;

        // Initialize IME
        _ = x11.c.XSetLocaleModifiers("");
        const im = x11.c.XOpenIM(dpy, null, null, null);
        var ic: ?x11.c.XIC = null;
        if (im) |im_ptr| {
            ic = x11.c.XCreateIC(im_ptr, x11.c.XNInputStyle, x11.c.XIMPreeditNothing | x11.c.XIMStatusNothing, x11.c.XNClientWindow, win, x11.c.XNFocusWindow, win, @as(?*anyopaque, null));
        } else {
            std.log.warn("Failed to open X Input Method", .{});
        }

        // Setup WM_DELETE_WINDOW protocol
        const wm_delete_window = x11.getDeleteWindowAtom(dpy);
        var protocols = [_]x11.c.Atom{wm_delete_window};
        _ = x11.c.XSetWMProtocols(dpy, win, &protocols, protocols.len);

        return Window{
            .dpy = dpy,
            .win = win,
            .screen = screen,
            .root = root,
            .vis = vis,
            .cmap = cmap,
            .gc = gc,
            .im = im,
            .ic = ic,
            .cursor = mouse_cursor,
            .wm_delete_window = wm_delete_window,
            .width = @intCast(win_w),
            .height = @intCast(win_h),
            .cell_width = @intCast(cell_w),
            .cell_height = @intCast(cell_h),
            .cols = cols,
            .rows = rows,
            .hborder_px = border,
            .vborder_px = border,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Window) void {
        if (self.cursor != 0) {
            _ = x11.c.XFreeCursor(self.dpy, self.cursor);
        }
        if (self.ic) |ic| {
            _ = x11.c.XDestroyIC(ic);
        }
        if (self.im) |im| {
            _ = x11.c.XCloseIM(im);
        }
        if (self.buf != 0) {
            _ = x11.c.XFreePixmap(self.dpy, self.buf);
        }
        _ = x11.c.XFreeGC(self.dpy, self.gc);
        _ = x11.c.XDestroyWindow(self.dpy, self.win);
        _ = x11.c.XCloseDisplay(self.dpy);
    }

    pub fn show(self: *Window) void {
        _ = x11.c.XMapWindow(self.dpy, self.win);
        if (self.cursor != 0) {
            _ = x11.c.XDefineCursor(self.dpy, self.win, self.cursor);
        }
        _ = x11.c.XSync(self.dpy, x11.c.False);
    }

    pub fn pollEvent(self: *Window) ?x11.c.XEvent {
        if (x11.c.XPending(self.dpy) > 0) {
            var event: x11.c.XEvent = undefined;
            _ = x11.c.XNextEvent(self.dpy, &event);
            return event;
        }
        return null;
    }

    pub fn resizeBuffer(self: *Window, w: u32, h: u32) void {
        if (self.buf != 0 and self.buf_w == w and self.buf_h == h) return;

        if (self.buf != 0) {
            _ = x11.c.XFreePixmap(self.dpy, self.buf);
        }

        self.buf = x11.c.XCreatePixmap(self.dpy, self.win, @intCast(w), @intCast(h), @intCast(x11.c.XDefaultDepth(self.dpy, self.screen)));
        self.buf_w = w;
        self.buf_h = h;
    }

    // Clear buffer (fills with bg color)
    pub fn clear(self: *Window) void {
        _ = self;
        // This should probably be done via XftDrawRect in renderer
    }

    // Copy buffer to window
    pub fn present(self: *Window) void {
        if (self.buf != 0) {
            _ = x11.c.XCopyArea(self.dpy, self.buf, self.win, self.gc, 0, 0, @intCast(self.width), @intCast(self.height), 0, 0);
            _ = x11.c.XSync(self.dpy, x11.c.False); // Or XFlush
        }
    }

    // Copy partial buffer to window
    pub fn presentPartial(self: *Window, rect: x11.c.XRectangle) void {
        if (self.buf != 0) {
            // st-style: always sync to ensure consistency
            _ = x11.c.XCopyArea(self.dpy, self.buf, self.win, self.gc, rect.x, rect.y, rect.width, rect.height, rect.x, rect.y);
            _ = x11.c.XSync(self.dpy, x11.c.False);
        }
    }

    /// 设置窗口标题
    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        _ = x11.c.XStoreName(self.dpy, self.win, title);
    }

    /// 设置图标标题
    pub fn setIconTitle(self: *Window, title: [:0]const u8) void {
        _ = x11.c.XSetIconName(self.dpy, self.win, title);
    }

    /// 调整窗口大小以匹配期望的行列数（在加载实际字体后调用）
    pub fn resizeToGrid(self: *Window, cols: usize, rows: usize) void {
        // Note: st 在 xinit() 中计算窗口时不添加 border（因为 hborderpx/vborderpx = 0）
        // 窗口管理器可能会稍后调整窗口，那时才在 cresize() 中计算实际的边框
        // 因此这里也不添加 border * 2，与 st 的行为对齐
        const new_w = @as(u32, @intCast(cols * self.cell_width));
        const new_h = @as(u32, @intCast(rows * self.cell_height));

        if (new_w != self.width or new_h != self.height) {
            _ = x11.c.XResizeWindow(self.dpy, self.win, @intCast(new_w), @intCast(new_h));
            self.width = new_w;
            self.height = new_h;
            _ = x11.c.XSync(self.dpy, x11.c.False);
        }
    }
};
