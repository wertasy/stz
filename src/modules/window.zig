//! X11 窗口系统抽象层
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
    dpy: *x11.Display,
    win: x11.Window,
    screen: i32,
    root: x11.Window,
    vis: *x11.Visual,
    cmap: x11.Colormap,
    gc: x11.GC,

    // Double buffering
    buf: x11.Pixmap = 0,
    buf_w: u32 = 0,
    buf_h: u32 = 0,

    // Dimensions
    width: u32,
    height: u32,
    cell_width: u32,
    cell_height: u32,
    cols: usize,
    rows: usize,

    allocator: std.mem.Allocator,

    pub fn init(title: [:0]const u8, cols: usize, rows: usize, allocator: std.mem.Allocator) !Window {
        const dpy = x11.XOpenDisplay(null) orelse return error.OpenDisplayFailed;
        const screen = x11.XDefaultScreen(dpy);
        const root = x11.XRootWindow(dpy, screen);
        const vis = x11.XDefaultVisual(dpy, screen);

        // TODO: Try to find a visual with alpha channel support for transparency?
        // For now use default

        const cmap = x11.XCreateColormap(dpy, root, vis, x11.AllocNone);

        // Calculate size
        // TODO: Get actual font metrics first. For now estimate.
        const font_size = config.Config.font.size;
        const cell_w = font_size;
        const cell_h = font_size * 2;
        const border = config.Config.window.border_pixels;

        const win_w = cols * cell_w + border * 2;
        const win_h = rows * cell_h + border * 2;

        var attrs: x11.XSetWindowAttributes = undefined;
        attrs.background_pixel = 0; // Black
        attrs.border_pixel = 0;
        attrs.colormap = cmap;
        attrs.event_mask = x11.KeyPressMask | x11.KeyReleaseMask | x11.ButtonPressMask |
            x11.ButtonReleaseMask | x11.PointerMotionMask | x11.StructureNotifyMask |
            x11.ExposureMask | x11.FocusChangeMask;

        const win = x11.XCreateWindow(dpy, root, 0, 0, @intCast(win_w), @intCast(win_h), 0, x11.XDefaultDepth(dpy, screen), x11.InputOutput, vis, x11.CWBackPixel | x11.CWBorderPixel | x11.CWEventMask | x11.CWColormap, &attrs);

        if (win == 0) return error.CreateWindowFailed;

        // Set title
        _ = x11.XStoreName(dpy, win, title);

        // Create GC
        const gc = x11.XCreateGC(dpy, win, 0, null);
        if (gc == null) return error.CreateGCFailed;

        return Window{
            .dpy = dpy,
            .win = win,
            .screen = screen,
            .root = root,
            .vis = vis,
            .cmap = cmap,
            .gc = gc,
            .width = @intCast(win_w),
            .height = @intCast(win_h),
            .cell_width = @intCast(cell_w),
            .cell_height = @intCast(cell_h),
            .cols = cols,
            .rows = rows,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Window) void {
        if (self.buf != 0) {
            _ = x11.XFreePixmap(self.dpy, self.buf);
        }
        _ = x11.XFreeGC(self.dpy, self.gc);
        _ = x11.XDestroyWindow(self.dpy, self.win);
        _ = x11.XCloseDisplay(self.dpy);
    }

    pub fn show(self: *Window) void {
        _ = x11.XMapWindow(self.dpy, self.win);
        _ = x11.XSync(self.dpy, x11.False);
    }

    pub fn pollEvent(self: *Window) ?x11.XEvent {
        if (x11.XPending(self.dpy) > 0) {
            var event: x11.XEvent = undefined;
            _ = x11.XNextEvent(self.dpy, &event);
            return event;
        }
        return null;
    }

    pub fn resizeBuffer(self: *Window, w: u32, h: u32) void {
        if (self.buf != 0 and self.buf_w == w and self.buf_h == h) return;

        if (self.buf != 0) {
            _ = x11.XFreePixmap(self.dpy, self.buf);
        }

        self.buf = x11.XCreatePixmap(self.dpy, self.win, @intCast(w), @intCast(h), @intCast(x11.XDefaultDepth(self.dpy, self.screen)));
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
            _ = x11.XCopyArea(self.dpy, self.buf, self.win, self.gc, 0, 0, @intCast(self.width), @intCast(self.height), 0, 0);
            _ = x11.XSync(self.dpy, x11.False); // Or XFlush
        }
    }
};
