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
const stz = @import("stz");

const types = stz.types;
const sdl2 = stz.c.sdl2;

const CursorStyle = types.CursorStyle;

// 字体配置
pub const font = struct {
    // SDL2_ttf 使用字体文件路径或简短字体名称
    // 常见选项：DejaVuSansMono, FreeMono, LiberationMono, NotoSansMono
    pub const name = "Maple Mono NF CN";
    pub const size: u32 = 18; // 像素大小
    pub const bold: bool = true;
    pub const italic: bool = false;
    pub const cwscale: f32 = 1.0; // 字符宽度缩放
    pub const chscale: f32 = 1.0; // 字符高度缩放
    pub const bold_weight: i32 = 210; // 粗体字体权重 (FontConfig: BOLD=200, EXTRABOLD=205, BLACK=210)

    // 回退字体列表 (spare fonts)，用于主字体不支持某些字符时
    // 包含支持各种 Unicode 字符的字体：CJK、Emoji、Symbol、数学符号等
    pub const fallback_fonts = [_][:0]const u8{
        "Apple Color Emoji", // macOS emoji 字体
        "Symbola", // 符号字体（数学、Unicode 符号）
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
    // 标准颜色 (16色) - 使用字符串表示
    pub const normal = [_][:0]const u8{
        "#1B1D1E", // black
        "#cd0000", // darkred
        "#82B414", // darkgreen
        "#FD971F", // darkyellow
        "#266C98", // darkblue
        "#cd00cd", // darkmagenta
        "#56ADBC", // darkcyan
        "#CCCCCC", // gray
    };

    pub const bright = [_][:0]const u8{
        "#808080", // darkgray
        "#F92672", // red
        "#A6E22E", // green
        "#E6DB74", // yellow
        "#FF6188", // blue
        "#D63AE1", // magenta
        "#66D9EF", // cyan
        "#F8F8F2", // white
    };

    // 特殊颜色索引常量
    pub const default_foreground_idx = 256 + 0;
    pub const default_background_idx = 256 + 1;
    pub const default_cursor_idx = 256 + 2;
    pub const reverse_cursor_idx = 256 + 3;

    // 特殊颜色
    pub const foreground: [:0]const u8 = "#F8F8F2"; // default foreground
    pub const background: [:0]const u8 = "#1B1D1E"; // default background
    pub const cursor: [:0]const u8 = "#f8f8f0"; // cursor
    pub const cursor_text: [:0]const u8 = "#555555"; // rev cursor
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
    pub const disable_bold_font: bool = false; // 禁用粗体字体，使用亮色模拟粗体（st 的传统行为）

    // 双图集配置（推荐）：分离文本和 emoji 的图集以优化性能
    pub const use_dual_atlas: bool = true;
    pub const text_atlas_cell_size: u32 = 64; // 文本图集单元格大小（64x64 = 4096槽位，用于CJK字符）
    pub const emoji_atlas_cell_size: u32 = 256; // Emoji图集单元格大小（256x256 = 256槽位，用于彩色emoji）

    // 单图集配置（已弃用）：仅当 use_dual_atlas = false 时使用
    pub const atlas_cell_size: u32 = 128; // 纹理图集单元格大小（已弃用，请使用 use_dual_atlas 配置）
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
    ToggleRecord, // <-- New action for recording parser sequence
    None,
};

pub const KeyBinding = struct {
    mod: u16,
    key: u32,
    action: KeyAction,
    arg: i32 = 0,
};

// 键盘快捷键配置
pub const shortcuts = [_]KeyBinding{
    .{ .mod = sdl2.KMOD_SHIFT, .key = sdl2.SDLK_PAGEUP, .action = .ScrollUp, .arg = 0 },
    .{ .mod = sdl2.KMOD_SHIFT, .key = sdl2.SDLK_PAGEDOWN, .action = .ScrollDown, .arg = 0 },
    .{ .mod = sdl2.KMOD_CTRL | sdl2.KMOD_SHIFT, .key = sdl2.SDLK_PAGEUP, .action = .ZoomIn },
    .{ .mod = sdl2.KMOD_CTRL | sdl2.KMOD_SHIFT, .key = sdl2.SDLK_PAGEDOWN, .action = .ZoomOut },
    .{ .mod = sdl2.KMOD_CTRL | sdl2.KMOD_SHIFT, .key = sdl2.SDLK_HOME, .action = .ZoomReset },
    .{ .mod = sdl2.KMOD_CTRL | sdl2.KMOD_SHIFT, .key = sdl2.SDLK_v, .action = .Paste },
    .{ .mod = sdl2.KMOD_CTRL | sdl2.KMOD_SHIFT, .key = sdl2.SDLK_V, .action = .Paste },
    .{ .mod = sdl2.KMOD_CTRL, .key = sdl2.SDLK_PRINTSCREEN, .action = .PrintToggle },
    .{ .mod = sdl2.KMOD_SHIFT, .key = sdl2.SDLK_PRINTSCREEN, .action = .PrintScreen },
    .{ .mod = 0, .key = sdl2.SDLK_PRINTSCREEN, .action = .PrintSelection },
    .{ .mod = sdl2.KMOD_CTRL | sdl2.KMOD_SHIFT, .key = sdl2.SDLK_r, .action = .ToggleRecord },
    .{ .mod = sdl2.KMOD_CTRL | sdl2.KMOD_SHIFT, .key = sdl2.SDLK_R, .action = .ToggleRecord },
};
