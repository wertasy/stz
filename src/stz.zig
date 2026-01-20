pub const Terminal = @import("stz/Terminal.zig");
pub const Parser = @import("stz/Parser.zig");
pub const PTY = @import("stz/PTY.zig");
pub const Window = @import("stz/Window.zig");
pub const Renderer = @import("stz/Renderer.zig");
pub const Input = @import("stz/Input.zig");
pub const Selector = @import("stz/Selector.zig");
pub const Printer = @import("stz/Printer.zig");
pub const Recorder = @import("stz/Recorder.zig");
pub const Args = @import("stz/Args.zig");
pub const Config = @import("stz/Config.zig");
pub const types = @import("stz/types.zig");
pub const unicode = @import("stz/unicode.zig");
pub const x11_utils = @import("stz/x11_utils.zig");
pub const HarfBuzz = @import("stz/HarfBuzz.zig");
pub const BoxDraw = @import("stz/BoxDraw.zig");

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
