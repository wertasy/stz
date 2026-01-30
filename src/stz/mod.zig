pub const Terminal = @import("terminal.zig");
pub const Parser = @import("parser.zig");
pub const PTY = @import("pty.zig");
pub const Window = @import("window.zig");
pub const Renderer = @import("renderer.zig");
pub const Input = @import("input.zig");
pub const Selector = @import("selector.zig");
pub const UrlDetector = @import("url.zig");
pub const Printer = @import("printer.zig");
pub const Args = @import("args.zig");
pub const Config = @import("config.zig");
pub const types = @import("types.zig");
pub const unicode = @import("unicode.zig");
pub const x11_utils = @import("x11_utils.zig");
pub const harfbuzz = @import("harfbuzz.zig");

pub const c = struct {
    pub const x11 = @cImport({
        @cInclude("X11/Xlib.h");
        @cInclude("X11/Xatom.h");
        @cInclude("X11/Xutil.h");
        @cInclude("X11/Xft/Xft.h");
        @cInclude("X11/cursorfont.h");
        @cInclude("X11/keysym.h");
        @cInclude("X11/XKBlib.h");
    });

    pub const hb = @cImport({
        @cInclude("hb.h");
        @cInclude("hb-ft.h");
    });
};
