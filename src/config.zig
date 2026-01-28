//! 终端配置模块
//! 包含颜色、字体、快捷键等配置
//! 与 /home/10292721@zte.intra/Github/suckless/st/config.h 对齐
//!
//! 配置项说明：
//! - 字体配置：字体名称、大小、粗细、斜体、缩放
//! - 窗口配置：默认行列数、最小尺寸、边框像素
//! - 颜色配置：标准16色、亮色、特殊颜色（光标、前景、背景）
//! - 光标配置：样式、粗细、闪烁间隔
//! - 绘制配置：延迟、盒线绘制
//! - 滚动配置：历史缓冲区行数
//! - URL 配置：处理器、字符集、前缀
//! - 选择配置：单词分隔符、双击超时
//! - 鼠标配置：强制修饰符
//! - 键盘快捷键：各种操作的键绑定

const std = @import("std");
const types = @import("types.zig");
const x11 = @import("x11.zig");

const CursorStyle = types.CursorStyle;

// 字体配置
pub const font = struct {
    pub const name = "Maple Mono NF CN:pixelsize=18:antialias=true:autohint=false";
    pub const size: u32 = 20; // 像素大小
    pub const bold: bool = true;
    pub const italic: bool = false;
    pub const cwscale: f32 = 1.0; // 字符宽度缩放
    pub const chscale: f32 = 1.0; // 字符高度缩放

    // 回退字体列表 (spare fonts)，用于主字体不支持某些字符时
    // 包含支持各种 Unicode 字符的字体：CJK、Emoji、Symbol、数学符号等
    pub const fallback_fonts = [_][:0]const u8{
        "FreeMono:pixelsize=18:antialias=true",
        "FreeSans:pixelsize=18:antialias=true",
        "FreeSerif:pixelsize=18:antialias=true",
        "Noto Sans Mono:pixelsize=18:antialias=true",
        "Noto Sans CJK SC:pixelsize=18:antialias=true",
        "Noto Color Emoji:pixelsize=18:antialias=true",
    };
};

// 窗口配置
pub const window = struct {
    pub const cols: usize = 120;
    pub const rows: usize = 35;
    pub const min_cols: usize = 10;
    pub const min_rows: usize = 5;
    pub const border_pixels: u32 = 2;
};

// 终端类型
pub const term_type = "xterm-256color";
pub const vt_identification = "\x1B[?6c"; // 终端标识序列

// Shell 配置
pub const shell = "/usr/bin/zsh";
pub const stty_args = "stty raw pass8 nl -echo -iexten -cstopb 38400";

// 颜色配置
pub const colors = struct {
    // 标准颜色 (16色) - 使用与 st 一致的 RGB 值
    pub const normal = [_]u32{
        0x000000, // black
        0xcd0000, // red3
        0x00cd00, // green3
        0xcdcd00, // yellow3
        0x0000ee, // blue2
        0xcd00cd, // magenta3
        0x00cdcd, // cyan3
        0xe5e5e5, // gray90
    };

    pub const bright = [_]u32{
        0x7f7f7f, // gray50
        0xff0000, // red
        0x00ff00, // green
        0xffff00, // yellow
        0x5c5cff, // #5c5cff
        0xff00ff, // magenta
        0x00ffff, // cyan
        0xffffff, // white
    };

    // 特殊颜色索引常量
    pub const default_foreground_idx = 256 + 0;
    pub const default_background_idx = 256 + 1;
    pub const default_cursor_idx = 256 + 2;
    pub const reverse_cursor_idx = 256 + 3;

    // 特殊颜色（RGB值）
    pub const foreground = 0xe3e3e3; // default foreground colour
    pub const background = 0x131314; // default background colour
    pub const cursor = 0xcccccc; // cursor
    pub const cursor_text = 0x555555; // rev cursor
};

// 光标配置
pub const cursor = struct {
    pub const style: CursorStyle = .blinking_bar; // 默认使用闪烁竖线
    pub const thickness: u32 = 2; // 光标粗细（像素）
    pub const blink_interval_ms: u32 = 500; // 闪烁间隔
};

// 字符属性配置
pub const attributes = struct {
    pub const blink_timeout_ms: u32 = 500; // 闪烁属性超时
    pub const undercurl_style: u32 = 1; // 0: curly, 1: spiky, 2: capped
};

// 绘制配置
pub const draw = struct {
    pub const min_latency_ms: u32 = 2;
    pub const max_latency_ms: u32 = 33;
    pub const su_timeout_ms: u32 = 200; // 同步更新超时
    pub const boxdraw: bool = true; // 框线字符绘制
    pub const boxdraw_bold: bool = true;
    pub const boxdraw_braille: bool = true;
};

// 滚动配置
pub const scroll = struct {
    pub const history_lines: usize = 1000;
    pub const scroll_program = ""; // scroll 程序路径
};

// URL 配置
pub const url = struct {
    pub const handler = "xdg-open";
    pub const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#@!$&'*+,;=%";
    pub const prefixes = [_][]const u8{
        "http://",
        "https://",
        "ftp://",
    };
};

// 选择配置
pub const selection = struct {
    pub const word_delimiters = " ,'\"()[]{}"; // 与 config.def.h 对齐
    pub const double_click_timeout_ms: u32 = 300;
    pub const triple_click_timeout_ms: u32 = 600;
    pub const rectangular_mask: u32 = 0; // ALT 键（与 selmasks 对齐）
};

// 鼠标配置
pub const mouse = struct {
    pub const force_modifier: u32 = 1; // Shift 键（forcemousemod = ShiftMask）
};

// 杂项配置
pub const misc = struct {
    pub const bell_volume: i32 = 0; // 铃声音量 (-100 到 100)
    pub const allow_altscreen: bool = true; // allowaltscreen
    pub const allow_window_ops: bool = true; // allowwindowops
    pub const utmp_file = ""; // utmp 文件路径
};

// Tab 配置
pub const tab_spaces: u32 = 8;

// 键盘绑定动作
pub const KeyAction = enum {
    Paste,
    Copy,
    ScrollUp,
    ScrollDown,
    ZoomIn,
    ZoomOut,
    ZoomReset,
    PrintScreen,
    PrintSelection,
    PrintToggle,
    None,
};

pub const KeyBinding = struct {
    mod: u32,
    key: x11.c.KeySym,
    action: KeyAction,
    arg: i32 = 0,
};

// 键盘快捷键配置
pub const shortcuts = [_]KeyBinding{
    .{ .mod = x11.c.ShiftMask, .key = x11.c.XK_Prior, .action = .ScrollUp, .arg = 0 }, // PageUp
    .{ .mod = x11.c.ShiftMask, .key = x11.c.XK_Next, .action = .ScrollDown, .arg = 0 }, // PageDown
    .{ .mod = x11.c.ShiftMask, .key = x11.c.XK_KP_Prior, .action = .ScrollUp, .arg = 0 },
    .{ .mod = x11.c.ShiftMask, .key = x11.c.XK_KP_Next, .action = .ScrollDown, .arg = 0 },
    .{ .mod = x11.c.ControlMask | x11.c.ShiftMask, .key = x11.c.XK_Prior, .action = .ZoomIn },
    .{ .mod = x11.c.ControlMask | x11.c.ShiftMask, .key = x11.c.XK_Next, .action = .ZoomOut },
    .{ .mod = x11.c.ControlMask | x11.c.ShiftMask, .key = x11.c.XK_KP_Prior, .action = .ZoomIn },
    .{ .mod = x11.c.ControlMask | x11.c.ShiftMask, .key = x11.c.XK_KP_Next, .action = .ZoomOut },
    .{ .mod = x11.c.ControlMask | x11.c.ShiftMask, .key = x11.c.XK_Home, .action = .ZoomReset },
    .{ .mod = x11.c.ControlMask | x11.c.ShiftMask, .key = x11.c.XK_KP_Home, .action = .ZoomReset },
    .{ .mod = x11.c.ControlMask | x11.c.ShiftMask, .key = x11.c.XK_V, .action = .Paste },
    .{ .mod = x11.c.ControlMask | x11.c.ShiftMask, .key = x11.c.XK_v, .action = .Paste },
    // Print shortcuts
    .{ .mod = x11.c.ControlMask, .key = x11.c.XK_Print, .action = .PrintToggle },
    .{ .mod = x11.c.ShiftMask, .key = x11.c.XK_Print, .action = .PrintScreen },
    .{ .mod = 0, .key = x11.c.XK_Print, .action = .PrintSelection },
};
