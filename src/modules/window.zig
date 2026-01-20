//! SDL 窗口系统抽象层
//! 处理 SDL2 窗口创建、事件循环等

const std = @import("std");
const sdl = @import("sdl.zig");
const config = @import("config.zig");

pub const WindowError = error{
    InitFailed,
    CreateWindowFailed,
    CreateRendererFailed,
};

/// 窗口结构
pub const Window = struct {
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    font: ?*anyopaque = null, // TODO: 添加字体支持
    allocator: std.mem.Allocator,

    width: u32 = 0,
    height: u32 = 0,
    cell_width: u32 = 0,
    cell_height: u32 = 0,
    cols: usize = 0,
    rows: usize = 0,

    /// 初始化窗口
    pub fn init(title: [:0]const u8, cols: usize, rows: usize, allocator: std.mem.Allocator) !Window {

        // 初始化 SDL
        if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) < 0) {
            std.log.err("SDL init failed: {s}\n", .{sdl.SDL_GetError()});
            return error.InitFailed;
        }
        defer sdl.SDL_Quit();

        // 计算窗口大小
        const font_size = config.Config.font.size;
        const border = config.Config.window.border_pixels;

        const cell_w = font_size; // TODO: 实际字体度量
        const cell_h = font_size * 2;

        const win_w = @as(c_int, @intCast(cols * cell_w + border * 2));
        const win_h = @as(c_int, @intCast(rows * cell_h + border * 2));

        // 创建窗口
        const window = sdl.SDL_CreateWindow(
            title,
            sdl.SDL_WINDOWPOS_UNDEFINED,
            sdl.SDL_WINDOWPOS_UNDEFINED,
            win_w,
            win_h,
            sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIDDEN,
        ) orelse {
            std.log.err("Window creation failed: {s}\n", .{sdl.SDL_GetError()});
            return error.CreateWindowFailed;
        };

        // 创建渲染器
        const renderer = sdl.SDL_CreateRenderer(
            window,
            -1,
            sdl.SDL_RENDERER_ACCELERATED | sdl.SDL_RENDERER_PRESENTVSYNC,
        ) orelse {
            std.log.err("Renderer creation failed: {s}\n", .{sdl.SDL_GetError()});
            return error.CreateRendererFailed;
        };

        return Window{
            .window = window,
            .renderer = renderer,
            .allocator = allocator,
            .width = @intCast(win_w),
            .height = @intCast(win_h),
            .cell_width = cell_w,
            .cell_height = cell_h,
            .cols = cols,
            .rows = rows,
        };
    }

    /// 清理窗口
    pub fn deinit(self: *Window) void {
        sdl.SDL_DestroyRenderer(self.renderer);
    }

    /// 显示窗口
    pub fn show(self: *Window) void {
        sdl.SDL_ShowWindow(self.window);
    }

    /// 处理事件
    pub fn pollEvent(self: *Window) ?sdl.SDL_Event {
        _ = self;
        var event: sdl.SDL_Event = undefined;
        if (sdl.SDL_PollEvent(&event) != 0) {
            return event;
        }
        return null;
    }

    /// 清屏
    pub fn clear(self: *Window) void {
        if (self.renderer) |r| {
            _ = sdl.SDL_SetRenderDrawColor(r, 0, 0, 0, 255);
            _ = sdl.SDL_RenderClear(r);
        }
    }

    /// 呈现
    pub fn present(self: *Window) void {
        if (self.renderer) |r| {
            sdl.SDL_RenderPresent(r);
        }
    }

    /// 等待垂直同步
    pub fn waitVSync(self: *Window) void {
        _ = self;
        // SDL_RENDERER_PRESENTVSYNC 会自动处理
    }
};
