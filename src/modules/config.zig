//! 终端配置模块
//! 包含颜色、字体、快捷键等配置
//! 与 /home/10292721@zte.intra/Github/suckless/st/config.h 对齐

const std = @import("std");

pub const Config = struct {
    // 字体配置
    pub const font = struct {
        pub const name = "Maple Mono NF:pixelsize=20:antialias=true:autohint=true";
        pub const size: u32 = 20; // 像素大小
        pub const bold: bool = true;
        pub const italic: bool = false;
        pub const cwscale: f32 = 1.0; // 字符宽度缩放
        pub const chscale: f32 = 1.0; // 字符高度缩放
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

        // 特殊颜色（索引 256-259）
        pub const default_cursor = 256; // #cccccc
        pub const reverse_cursor = 257; // #555555
        pub const default_foreground = 258; // #e3e3e3
        pub const default_background = 259; // #131314

        // 特殊颜色（RGB值）
        pub const foreground = 0xe3e3e3; // default foreground colour
        pub const background = 0x131314; // default background colour
        pub const cursor = 0xcccccc; // cursor
        pub const cursor_text = 0x555555; // rev cursor
        pub const default_attr: u32 = 11; // 默认属性
    };

    // 光标配置
    pub const cursor = struct {
        pub const style: u32 = 5; // 0:闪烁块, 1:闪烁块(default), 2:稳定块, 3:闪烁下划线, 4:稳定下划线, 5:闪烁竖线, 6:稳定竖线
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
};

// 初始化默认配置
pub fn defaultConfig() Config {
    return Config{};
}
