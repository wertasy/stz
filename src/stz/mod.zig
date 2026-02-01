pub const Terminal = @import("terminal.zig");
pub const Parser = @import("parser.zig");
pub const PTY = @import("pty.zig");
pub const Window = @import("window.zig");
pub const Renderer = @import("renderer.zig");
pub const Input = @import("input.zig");
pub const Selector = @import("selector.zig");
pub const UrlDetector = @import("url.zig");
pub const Printer = @import("printer.zig");
pub const Recorder = @import("recorder.zig");
pub const Args = @import("args.zig");
pub const Config = @import("config.zig");
pub const types = @import("types.zig");
pub const unicode = @import("unicode.zig");
pub const sdl2_utils = @import("sdl2_utils.zig");
pub const harfbuzz = @import("harfbuzz.zig");
pub const TextureAtlas = @import("texture_atlas.zig");

pub const c = struct {
    pub const sdl2 = @cImport({
        @cInclude("SDL2/SDL.h");
        // 移除 SDL2_ttf，改用 FreeType
    });

    pub const ft = @cImport({
        @cInclude("ft2build.h");
        @cInclude("freetype/freetype.h");
        @cInclude("freetype/ftglyph.h");
        @cInclude("freetype/ftbitmap.h");
        @cInclude("freetype/ftrender.h");
    });

    pub const fc = @cImport({
        @cInclude("fontconfig/fontconfig.h");
    });

    pub const hb = @cImport({
        @cInclude("ft2build.h");
        @cInclude("freetype/freetype.h");
        @cInclude("hb.h");
        @cInclude("hb-ft.h");
    });
};
