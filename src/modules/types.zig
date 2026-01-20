//! 核心数据类型定义

const std = @import("std");

/// 字符属性标志位
pub const GlyphAttr = packed struct(u16) {
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    struck: bool = false,
    wrap: bool = false,
    wide: bool = false,
    wide_dummy: bool = false,
    boxdraw: bool = false,
    url: bool = false,
    dirty_underline: bool = false,
    _padding: u2 = 0,
};

/// 字符单元
pub const Glyph = struct {
    u: u21 = ' ', // Unicode 码点
    attr: GlyphAttr = .{}, // 字符属性
    fg: u32 = 7, // 前景色索引
    bg: u32 = 0, // 背景色索引
    ustyle: i32 = -1, // 下划线样式
    ucolor: [3]i32 = [_]i32{ -1, -1, -1 }, // 下划线颜色 RGB
};

/// 光标状态
pub const CursorState = enum(u8) {
    default = 0,
    wrap_next = 1,
    origin = 2,
};

/// 光标移动模式
pub const CursorMove = enum(u8) {
    save,
    load,
};

/// 终端模式标志
pub const TermMode = packed struct(u32) {
    wrap: bool = false,
    insert: bool = false,
    alt_screen: bool = false,
    crlf: bool = false,
    echo: bool = false,
    print: bool = false,
    utf8: bool = false,
    app_cursor: bool = false,
    app_keypad: bool = false,
    hide_cursor: bool = false,
    reverse: bool = false, // DECSCNM - 反色模式
    kbdlock: bool = false, // 键盘锁定
    mouse: bool = false,
    mouse_btn: bool = false,
    mouse_motion: bool = false,
    mouse_many: bool = false,
    mouse_sgr: bool = false,
    mouse_focus: bool = false,
    brckt_paste: bool = false,
    num_lock: bool = false,
    _padding: u12 = 0,
};

/// 字符集
pub const Charset = enum(u8) {
    graphic0,
    graphic1,
    uk,
    usa,
    multi,
    ger,
    fin,
};

/// 转义序列状态
pub const EscapeState = packed struct(u16) {
    start: bool = false,
    csi: bool = false,
    str: bool = false, // DCS, OSC, PM, APC
    alt_charset: bool = false,
    tstate: bool = false,
    utf8: bool = false,
    str_end: bool = false,
    decaln: bool = false, // DECALN - ESC # 8
    test_mode: bool = false, // ESC # 测试模式
    _padding: u7 = 0,
};

/// 光标结构
pub const TCursor = struct {
    attr: Glyph = .{},
    x: usize = 0,
    y: usize = 0,
    state: CursorState = .default,
};

/// 保存的光标状态（用于 DECSC/DECRC）
pub const SavedCursor = struct {
    attr: Glyph = .{},
    x: usize = 0,
    y: usize = 0,
    state: CursorState = .default,
};

/// 选择模式
pub const SelectionMode = enum(u8) {
    idle,
    empty,
    ready,
};

/// 选择类型
pub const SelectionType = enum(u8) {
    regular = 1,
    rectangular = 2,
};

/// 选择吸附模式
pub const SelectionSnap = enum(u8) {
    word = 1,
    line = 2,
};

/// 选择结构
pub const Selection = struct {
    mode: SelectionMode = .idle,
    type: SelectionType = .regular,
    snap: SelectionSnap = .word,
    nb: Point = .{}, // 标准化开始坐标
    ne: Point = .{}, // 标准化结束坐标
    ob: Point = .{}, // 原始开始坐标
    oe: Point = .{}, // 原始结束坐标
    alt: bool = false, // 是否在备用屏幕
};

/// 点坐标
pub const Point = struct {
    x: usize = 0,
    y: usize = 0,
};

/// CSI 转义序列结构
pub const CSIEscape = struct {
    buf: [512]u8 = .{0} ** 512, // 原始字符串缓冲区
    len: usize = 0, // 已用长度
    priv: u8 = 0, // 私有模式标志
    arg: [32]i64 = .{0} ** 32, // 参数
    narg: usize = 0, // 参数数量
    mode: [2]u8 = .{0} ** 2, // 最终字符
};

/// STR 转义序列结构
pub const STREscape = struct {
    type: u8 = 0, // 转义序列类型
    buf: []u8 = &[_]u8{}, // 动态分配的字符串缓冲区
    siz: usize = 0, // 分配大小
    len: usize = 0, // 已用长度
    args: [16][]u8 = .{&[_]u8{}} ** 16, // 参数
    narg: usize = 0, // 参数数量
};

/// 终端结构
pub const Term = struct {
    // 屏幕尺寸
    row: usize = 0,
    col: usize = 0,

    // 屏幕缓冲区
    line: ?[][]Glyph = null,
    alt: ?[][]Glyph = null, // 备用屏幕

    // 历史记录
    hist: ?[][]Glyph = null, // 历史缓冲区
    hist_idx: usize = 0, // 历史缓冲区当前写入索引
    hist_cnt: usize = 0, // 历史缓冲区当前行数
    hist_max: usize = 0, // 历史缓冲区最大行数
    scr: usize = 0, // 滚动偏移 (0 = 底部)

    // 脏标记
    dirty: ?[]bool = null,

    // 光标
    c: TCursor = .{},
    ocx: usize = 0, // 旧光标列
    ocy: usize = 0, // 旧光标行

    // 滚动区域
    top: usize = 0,
    bot: usize = 0,

    // 模式
    mode: TermMode = .{},
    esc: EscapeState = .{},

    // 字符集
    trantbl: [4]Charset = [_]Charset{.usa} ** 4,
    charset: u8 = 0,
    icharset: u8 = 0,

    // 制表符
    tabs: ?[]bool = null,

    // 最后一个字符
    lastc: u21 = 0,

    // 分配器
    allocator: std.mem.Allocator,

    // 窗口标题
    window_title: []const u8 = "stz",
    window_title_dirty: bool = false,

    // 颜色调色板
    palette: [256]u32 = undefined,
    default_fg: u32 = 7, // 默认前景色 (白色)
    default_bg: u32 = 0, // 默认背景色 (黑色)
    default_cs: u32 = 7, // 默认光标颜色

    // 光标样式 (0-8, 参考配置文件)
    cursor_style: u8 = 1,

    // 保存的光标状态（主屏幕和备用屏幕各一个）
    saved_cursor: [2]SavedCursor = [_]SavedCursor{.{}} ** 2,
};
