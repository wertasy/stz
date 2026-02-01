//! SDL2 辅助函数
//!
//! 提供 SDL2 相关的工具函数和常量

const std = @import("std");
const stz = @import("stz");
const sdl2 = stz.c.sdl2;

/// 剪贴板模式
pub const ClipboardMode = enum {
    primary,
    clipboard,
};

/// 获取剪贴板文本
/// 注意：返回的字符串由调用者使用分配器管理，需要在使用后释放
pub fn getClipboardText(allocator: std.mem.Allocator, mode: ClipboardMode) !?[:0]const u8 {
    _ = mode; // SDL2 只支持 CLIPBOARD
    if (sdl2.SDL_HasClipboardText() != sdl2.SDL_TRUE) {
        return null;
    }
    const text = sdl2.SDL_GetClipboardText() orelse return null;
    defer sdl2.SDL_free(text);

    const len = std.mem.len(text);
    const copy = try allocator.dupeZ(u8, text[0..len]);
    return copy;
}

/// 设置剪贴板文本
pub fn setClipboardText(text: []const u8, mode: ClipboardMode) !void {
    _ = mode; // SDL2 只支持 CLIPBOARD
    const result = sdl2.SDL_SetClipboardText(text.ptr);
    if (result != 0) {
        return error.SetClipboardFailed;
    }
}
