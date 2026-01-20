//! 终端配置模块
//! 包含颜色、字体、快捷键等配置

const std = @import("std");

pub const Config = struct {
    // 字体配置
    pub const font = struct {
        pub const name = "monospace";
        pub const size: u32 = 20;
        pub const bold: bool = true;
        pub const italic: bool = false;
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

    // Shell 配置
    pub const shell = "/bin/sh";

    // 颜色配置
    pub const colors = struct {
        // 标准颜色 (16色)
        pub const normal = [_]u32{
            0x1a1b26, // black
            0xf7768e, // red
            0x9ece6a, // green
            0xe0af68, // yellow
            0x7aa2f7, // blue
            0xbb9af7, // magenta
            0x7dcfff, // cyan
            0xa9b1d6, // white
        };

        pub const bright = [_]u32{
            0x414868, // bright black
            0xff9e64, // bright red
            0xb9f27c, // bright green
            0xffdf88, // bright yellow
            0x7da6ff, // bright blue
            0xdb4bff, // bright magenta
            0xd4dbff, // bright cyan
            0xc0caf5, // bright white
        };

        // 特殊颜色
        pub const foreground = 0xc0caf5;
        pub const background = 0x1a1b26;
        pub const cursor = 0xc0caf5;
        pub const cursor_text = 0x1a1b26;
    };

    // 光标配置
    pub const cursor = struct {
        pub const style: u32 = 6; // 5: 闪烁竖线，6: 稳定竖线
        pub const blink_interval_ms: u32 = 500;
    };

    // 滚动配置
    pub const scroll = struct {
        pub const history_lines: usize = 1000;
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
        pub const word_delimiters = " ,'\"()[]{}";
        pub const double_click_timeout_ms: u32 = 300;
        pub const triple_click_timeout_ms: u32 = 600;
    };

    // Tab 配置
    pub const tab_spaces: u32 = 8;
};

// 初始化默认配置
pub fn defaultConfig() Config {
    return Config{};
}

