//! SDL2 窗口系统抽象层
//!
//! Window 模块负责创建和管理 SDL2 窗口，处理窗口事件。
//!
//! 核心功能：
//! - 窗口创建和配置：创建 SDL2 窗口，设置属性、事件掩码、鼠标光标
//! - 双缓冲管理：创建和管理 Texture（离屏缓冲区）
//! - 窗口大小调整：响应窗口大小变化事件
//! - 事件轮询：使用 SDL_PollEvent 获取窗口事件
//! - 窗口标题：设置和更新窗口标题
//! - 显示和刷新：显示窗口、渲染内容到窗口
//!
//! 双缓冲机制：
//! - Texture: 离屏缓冲区，所有绘图操作都在 Texture 上完成
//! - buf_w, buf_h: Texture 的尺寸
//! - renderer 渲染到 Texture
//! - present() 或 presentPartial() 将 Texture 复制到窗口
//! - 优点：避免闪烁、提高性能

const std = @import("std");
const stz = @import("stz");

const sdl2 = stz.c.sdl2;
const config = stz.Config;

pub const WindowError = error{
    InitFailed,
    CreateWindowFailed,
    CreateRendererFailed,
    CreateTextureFailed,
};

const Window = @This();

window: *sdl2.SDL_Window,
renderer: *sdl2.SDL_Renderer,
texture: ?*sdl2.SDL_Texture = null,
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
    // 初始化 SDL2
    if (sdl2.SDL_Init(sdl2.SDL_INIT_VIDEO) != 0) {
        std.log.err("SDL2 初始化失败: {s}", .{sdl2.SDL_GetError()});
        return error.InitFailed;
    }

    // FreeType 初始化已移至 Renderer
    // 不再需要 SDL2_ttf

    // 计算窗口大小
    const font_size = config.font.size;
    const cell_w = @max(@as(u32, font_size / 2), 1);
    const cell_h = @as(u32, font_size);
    const border = config.window.border_pixels;

    const win_w = cols * cell_w + border * 2;
    const win_h = rows * cell_h + border * 2;

    // 创建窗口（初始隐藏，避免启动时闪烁）
    const window = sdl2.SDL_CreateWindow(
        title,
        sdl2.SDL_WINDOWPOS_UNDEFINED,
        sdl2.SDL_WINDOWPOS_UNDEFINED,
        @intCast(win_w),
        @intCast(win_h),
        sdl2.SDL_WINDOW_HIDDEN | sdl2.SDL_WINDOW_RESIZABLE,
    ) orelse {
        std.log.err("创建窗口失败: {s}", .{sdl2.SDL_GetError()});
        return error.CreateWindowFailed;
    };

    // 创建渲染器
    // 注意：不使用 SDL_RENDERER_PRESENTVSYNC 以避免输入延迟
    // VSync 会导致 present() 等待垂直同步（16.67ms），造成打字不跟手
    // 我们通过 min_frame_time_ms 限制帧率，不需要 VSync
    const renderer = sdl2.SDL_CreateRenderer(
        window,
        -1,
        sdl2.SDL_RENDERER_ACCELERATED,
    ) orelse {
        std.log.err("创建渲染器失败: {s}", .{sdl2.SDL_GetError()});
        sdl2.SDL_DestroyWindow(window);
        return error.CreateRendererFailed;
    };

    return Window{
        .window = window,
        .renderer = renderer,
        .texture = null,
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
    if (self.texture) |tex| {
        sdl2.SDL_DestroyTexture(tex);
    }
    sdl2.SDL_DestroyRenderer(self.renderer);
    sdl2.SDL_DestroyWindow(self.window);
    // TTF_Quit() 已移至 Renderer
    sdl2.SDL_Quit();
}

pub fn show(self: *Window) void {
    // 显示窗口（避免启动时闪烁，在首次渲染完成后调用）
    sdl2.SDL_ShowWindow(self.window);
}

pub fn pollEvent(self: *Window) ?sdl2.SDL_Event {
    _ = self;
    var event: sdl2.SDL_Event = undefined;
    if (sdl2.SDL_PollEvent(&event) != 0) {
        return event;
    }
    return null;
}

pub fn resizeBuffer(self: *Window, w: u32, h: u32) void {
    if (self.texture) |tex| {
        var format: u32 = undefined;
        var access: i32 = undefined;
        var tex_w: i32 = undefined;
        var tex_h: i32 = undefined;
        if (sdl2.SDL_QueryTexture(tex, &format, &access, &tex_w, &tex_h) == 0) {
            if (@as(u32, @intCast(tex_w)) == w and @as(u32, @intCast(tex_h)) == h) {
                return;
            }
        }
        sdl2.SDL_DestroyTexture(tex);
    }

    const new_texture = sdl2.SDL_CreateTexture(
        self.renderer,
        sdl2.SDL_PIXELFORMAT_ABGR8888,
        sdl2.SDL_TEXTUREACCESS_TARGET,
        @intCast(w),
        @intCast(h),
    ) orelse {
        std.log.err("创建纹理失败: {s}", .{sdl2.SDL_GetError()});
        return;
    };

    // 设置线性过滤，获得更平滑的渲染效果
    _ = sdl2.SDL_SetTextureScaleMode(new_texture, sdl2.SDL_ScaleModeLinear);

    self.texture = new_texture;
    self.buf_w = w;
    self.buf_h = h;
}

// Clear buffer (fills with bg color)
pub fn clear(self: *Window) void {
    _ = self;
    // 在 renderer.zig 中实现
}

// Copy buffer to window
pub fn present(self: *Window) void {
    if (self.texture) |tex| {
        _ = sdl2.SDL_RenderClear(self.renderer);
        _ = sdl2.SDL_RenderCopy(self.renderer, tex, null, null);
        sdl2.SDL_RenderPresent(self.renderer);
    }
}

// Copy partial buffer to window
pub fn presentPartial(self: *Window, rect: sdl2.SDL_Rect) void {
    _ = rect;
    // 在硬件加速的 SDL2 中，局部更新不保证后台缓冲区内容的持久性
    // 始终执行完整呈现以避免闪烁，现代 GPU 处理此操作开销极小
    self.present();
}

/// 设置窗口标题
pub fn setTitle(self: *Window, title: [:0]const u8) void {
    sdl2.SDL_SetWindowTitle(self.window, title);
}

/// 设置图标标题
pub fn setIconTitle(self: *Window, title: [:0]const u8) void {
    _ = self;
    _ = title;
    // SDL2 没有直接对应的功能，可以忽略
}

/// 设置输入法光标位置
pub fn updateImeSpot(self: *Window, x: usize, y: usize) void {
    const rect = sdl2.SDL_Rect{
        .x = @intCast(@as(i32, @intCast(x * self.cell_width)) + @as(i32, @intCast(self.hborder_px))),
        .y = @intCast(@as(i32, @intCast(y * self.cell_height)) + @as(i32, @intCast(self.vborder_px))),
        .w = @intCast(self.cell_width),
        .h = @intCast(self.cell_height),
    };
    sdl2.SDL_SetTextInputRect(&rect);
}

/// 调整窗口大小以匹配期望的行列数（在加载实际字体后调用）
pub fn resizeToGrid(self: *Window, cols: usize, rows: usize) void {
    const new_w = @as(u32, @intCast(cols * self.cell_width));
    const new_h = @as(u32, @intCast(rows * self.cell_height));

    if (new_w != self.width or new_h != self.height) {
        sdl2.SDL_SetWindowSize(self.window, @intCast(new_w), @intCast(new_h));
        self.width = new_w;
        self.height = new_h;
    }
}
