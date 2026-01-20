//! 核心数据类型定义
//!
//! ## 文件概述
//!
//! 本文件定义了终端模拟器的所有核心数据结构。理解这些类型是掌握终端模拟器的基础。
//!
//! ## 核心概念
//!
//! ### 1. 字符单元 (Glyph)
//! 终端屏幕上的每个位置不是简单的字符，而是"字符单元"。一个 Glyph 包含：
//! - **u**: Unicode 码点（实际显示的字符）
//! - **attr**: 字符属性（颜色、粗体、下划线等）
//! - **fg/bg**: 前景色和背景色索引
//!
//! ### 2. 字符属性 (GlyphAttr)
//! 使用位标志存储字符的显示属性。packed struct 确保与 C 语言的内存布局兼容。
//! 常见属性包括：bold(粗体)、underline(下划线)、blink(闪烁)、reverse(反色)等。
//!
//! ### 3. 终端结构 (Term)
//! 这是整个终端模拟器的核心数据结构，包含：
//! - 屏幕缓冲区（主屏幕和备用屏幕）
//! - 光标状态和位置
//! - 历史滚动缓冲区
//! - 模式标志（鼠标、回绕、备用屏幕等）
//! - 转义序列解析状态
//!
//! ## 与原版 st 的对应关系
//! - Glyph 对应 st 中的 Glyph 结构
//! - Term 对应 st 中的 Term 结构
//! - 所有 packed struct 与 C 语言的结构体位字段对齐

const std = @import("std");
const stz = @import("stz");
const config = stz.Config;

/// 字符属性标志位
///
/// ## 新手入门：什么是字符属性？
///
/// 在终端中，每个字符不仅有"是什么"，还有"怎么显示"。比如：
/// - 普通文本：白色前景，黑色背景
/// - 粗体文字：更粗的字形（某些终端会用亮色表示）
/// - 下划线：字符下方有一条线
/// - 反色：前景色和背景色互换
/// - 闪烁：文字周期性闪烁
///
/// 这些属性都存储在这个结构体中。
///
/// ## 技术细节
/// - **packed struct**: 紧凑内存布局，每个字段占用最少位数
/// - **u16**: 16位整数，可以存储15个布尔标志 + 2个填充位
/// - 与 C 语言的位字段兼容，便于与 xterm 等 VT100 终端对齐
pub const GlyphAttr = packed struct(u16) {
    bold: bool = false, // 粗体：文字显示更粗
    faint: bool = false, // 暗淡：文字颜色变暗（某些终端实现）
    italic: bool = false, // 斜体：文字倾斜
    underline: bool = false, // 下划线：字符下方显示线条
    blink: bool = false, // 闪烁：文字周期性显示/隐藏
    reverse: bool = false, // 反色：前景色和背景色互换
    hidden: bool = false, // 隐藏：文字不可见（鼠标选中可见）
    struck: bool = false, // 删除线：文字中间显示横线
    wrap: bool = false, // 自动换行：光标到达行尾时自动转到下一行
    wide: bool = false, // 宽字符标记：占用两个单元格（如中文、日文、韩文）
    wide_dummy: bool = false, // 宽字符占位：宽字符的第二个单元格（空占位符）
    boxdraw: bool = false, // 制表符：使用特殊绘制而非字体（如 ┌ ─ ┐）
    url: bool = false, // URL标记：识别为超链接（Ctrl+点击可打开）
    dirty_underline: bool = false, // 下划线脏标记：需要重新渲染下划线
    _padding: u2 = 0, // 填充位：确保对齐到16位边界

    pub fn matches(a: GlyphAttr, mask: GlyphAttr) bool {
        if (mask.bold and a.bold) return true;
        if (mask.faint and a.faint) return true;
        if (mask.italic and a.italic) return true;
        if (mask.underline and a.underline) return true;
        if (mask.blink and a.blink) return true;
        if (mask.reverse and a.reverse) return true;
        if (mask.hidden and a.hidden) return true;
        if (mask.struck and a.struck) return true;
        if (mask.wide and a.wide) return true;
        if (mask.wide_dummy and a.wide_dummy) return true;
        if (mask.url and a.url) return true;
        return false;
    }

    // 比较两个字符的属性是否相同（st 对齐）
    // 对应 st 的 ATTRCMP 宏，排除 wrap 属性的比较
    pub fn cmp(a: GlyphAttr, b: GlyphAttr) bool {
        // st: ((a).mode & (~ATTR_WRAP)) != ((b).mode & (~ATTR_WRAP)) || (a).fg != (b).fg || (a).bg != (b).bg
        // ATTR_WRAP = 1 << 8 = 256
        const ATTR_WRAP: u16 = 1 << 8;
        const a_attr_masked = @as(u16, @bitCast(a)) & (~ATTR_WRAP);
        const b_attr_masked = @as(u16, @bitCast(b)) & (~ATTR_WRAP);
        return a_attr_masked != b_attr_masked;
    }
};

/// 字符单元
///
/// ## 新手入门：终端屏幕的"像素"
///
/// 如果你把终端屏幕看作一个二维数组，那么 Glyph 就是数组中的每个元素。
/// 但与现代图形应用不同，终端的"像素"是字符单元，而不是物理像素。
///
/// 例如：一个 80x25 的终端有 80 列 25 行，共 2000 个 Glyph 单元。
///
/// ## 字符单元的组成
///
/// 1. **u (Unicode 码点)**: 实际显示的字符
///    - 可以是 ASCII 字符：'A', ' ', '#'
///    - 也可以是 Unicode 字符：'你', '€', '😀'
///    - u21 表示 21 位无符号整数，可以表示 Unicode 的所有码点（0-0x10FFFF）
///
/// 2. **attr (字符属性)**: 控制显示样式（粗体、颜色、下划线等）
///
/// 3. **fg/bg (前景色/背景色)**: 颜色索引
///    - 索引 0-15: 标准 16 色
///    - 索引 16-255: 256 色模式
///    - 索引 256+: 自定义颜色（RGB 直接值）
///
/// 4. **ustyle/ucolor (下划线样式和颜色)**: 高级下划线功能
///    - ustyle: 下划线样式（实线、波浪线等）
///    - ucolor: 自定义下划线颜色（RGB）
///
/// ## 示例
/// ```zig
/// // 创建一个红色的粗体字符 'A'
/// var g = Glyph{
///     .u = 'A',
///     .attr = GlyphAttr{ .bold = true },
///     .fg = 1,  // 红色索引
/// };
/// ```
pub const Glyph = struct {
    codepoint: u21 = ' ', // Unicode 码点：默认空格
    attr: GlyphAttr = .{}, // 字符属性：默认无特殊样式
    fg: u32 = config.colors.default_foreground_idx, // 前景色索引：默认前景色
    bg: u32 = config.colors.default_background_idx, // 背景色索引：默认背景色
    ustyle: i32 = -1, // 下划线样式：-1 表示使用默认样式
    ucolor: [3]i32 = [_]i32{ -1, -1, -1 }, // 下划线颜色 RGB：-1 表示使用默认颜色
    url_id: u32 = 0, // OSC 8 URL ID (0 = none)

    // 比较两个字符的属性是否相同（st 对齐）
    pub fn attrsCmp(a: Glyph, b: Glyph) bool {
        return a.attr.cmp(b.attr) or a.fg != b.fg or a.bg != b.bg or a.url_id != b.url_id;
    }
};

/// 光标状态
///
/// ## 新手入门：光标不仅是位置
///
/// 光标有两个维度：
/// 1. **位置**：在哪一行哪一列（存储在 TCursor.x/y）
/// 2. **状态**：光标的行为模式（存储在 CursorState）
///
/// ## 光标状态详解
///
/// 1. **wrap_next**: 自动换行标记
///    - 当光标到达行尾时，如果启用了 wrap 模式，光标会移动到下一行的开头
///    - wrap_next 标记用于处理"字符超出行尾"的特殊情况
///
/// 2. **origin**: 原点模式（Origin Mode, DEC Origin Mode）
///    - 假: 原点是 (0, 0)，即屏幕左上角（默认）
///    - 真: 原点是 (top, 0)，即滚动区域的左上角
///    - 这个模式影响光标移动和滚屏操作
///
/// ## 示例场景
/// 当在行尾写入字符时：
/// ```
/// 1. 字符被写入当前位置
/// 2. wrap_next = true
/// 3. 下一个字符被写入时，光标移动到下一行开头
/// 4. wrap_next = false
/// ```
pub const CursorState = packed struct(u8) {
    wrap_next: bool = false, // 换行标记：光标超出行尾时的自动换行标记
    origin: bool = false, // 原点模式：是否在滚动区域内移动
    _padding: u6 = 0, // 填充位：确保对齐到8位边界

    pub const default = @This(){}; // 默认光标状态（所有标记为 false）
};

/// 光标移动模式
///
/// ## 新手入门：保存和恢复光标
///
/// 许多 TUI 程序（如 vim、htop）在进入和退出时会保存/恢复光标状态。
/// 这确保用户回到终端时，光标位置和属性不变。
///
/// ## 操作说明
/// - **save (DECSC)**: 保存当前光标状态（位置、属性）
/// - **load (DECRC)**: 恢复之前保存的光标状态
///
/// ## 转义序列
/// - ESC 7: 保存光标 (DECSC)
/// - ESC 8: 恢复光标 (DECRC)
pub const CursorMove = enum(u8) {
    save, // 保存光标状态
    load, // 恢复光标状态
};

/// 光标样式 (DECSCUSR)
///
/// ## 新手入门：光标不是简单的方块
///
/// VT100 终端协议定义了多种光标样式，应用程序可以根据需要选择。
/// 例如：
/// - vim 通常使用下划线或竖线，方便编辑
/// - 普通终端使用块状光标，清晰可见
/// - 某些编辑器使用空心框，更现代
///
/// ## 光标样式详解
///
/// **块状光标 (Block)**: 覆盖整个字符单元
/// - 闪烁块: 周期性显示/隐藏
/// - 稳定块: 始终可见
///
/// **下划线光标 (Underline)**: 在字符下方显示线条
/// - 闪烁下划线: 线条周期性显示/隐藏
/// - 稳定下划线: 线条始终可见
///
/// **竖线光标 (Bar)**: 在字符左侧显示竖线（现代编辑器常用）
/// - 闪烁竖线: 竖线周期性显示/隐藏
/// - 稳定竖线: 竖线始终可见
///
/// **st 光标 (st_cursor)**: st 终端特有的空心框样式
/// - 看起来像字符轮廓，不遮挡文本内容
///
/// ## 转义序列
/// CSI ? P s SP q (DECSCUSR)
/// - P s = 0: 闪烁块
/// - P s = 1: 闪烁块（默认）
/// - P s = 2: 稳定块
/// - P s = 3: 闪烁下划线
/// - P s = 4: 稳定下划线
/// - P s = 5: 闪烁竖线
/// - P s = 6: 稳定竖线
pub const CursorStyle = enum(u8) {
    blinking_block = 0, // 闪烁块：周期性显示/隐藏的方块
    blinking_block_default = 1, // 闪烁块（默认样式）
    steady_block = 2, // 稳定块：始终可见的方块
    blinking_underline = 3, // 闪烁下划线：周期性显示/隐藏的下划线
    steady_underline = 4, // 稳定下划线：始终可见的下划线
    blinking_bar = 5, // 闪烁竖线：周期性显示/隐藏的竖线（现代编辑器常用）
    steady_bar = 6, // 稳定竖线：始终可见的竖线
    blinking_st_cursor = 7, // 闪烁 st 光标：st 终端特有的空心框
    steady_st_cursor = 8, // 稳定 st 光标：始终可见的空心框

    /// 判断光标样式是否应该闪烁
    ///
    /// ## 使用场景
    /// 在主事件循环中，需要定期检查是否需要切换光标的显示状态。
    /// 这个函数用于判断当前光标样式是否需要闪烁。
    pub fn shouldBlink(self: CursorStyle) bool {
        return switch (self) {
            .blinking_block, .blinking_block_default, .blinking_underline, .blinking_bar, .blinking_st_cursor => true,
            else => false,
        };
    }
};

/// 终端模式标志
///
/// ## 新手入门：终端不是静态的，它有很多"模式"
///
/// 终端模拟器可以通过转义序列改变各种行为模式。
/// 例如：
/// - 启用"备用屏幕"后，vim 等程序可以在单独的缓冲区显示
/// - 启用"鼠标模式"后，可以捕获鼠标点击事件
/// - 启用"回绕模式"后，超出行尾的字符自动换行
///
/// ## 模式分类
///
/// ### 基础模式
/// - **wrap**: 自动换行（默认启用）
/// - **insert**: 插入模式（新字符插入到光标位置，而不是覆盖）
/// - **crlf**: 回车换行模式（CR 自动添加 LF）
///
/// ### 屏幕模式
/// - **alt_screen**: 备用屏幕（应用程序专用屏幕，如 vim/less）
/// - **reverse**: 反色模式（所有字符前景色和背景色互换）
///
/// ### 鼠标模式
/// - **mouse**: 基础鼠标模式（捕获点击）
/// - **mouse_motion**: 鼠标移动模式（捕获移动）
/// - **mouse_many**: 频繁移动报告（即使不按按钮也报告）
/// - **mouse_sgr**: SGR 扩展鼠标模式（更现代的格式）
/// - **mouse_focus**: 焦点报告模式（窗口获得/失去焦点时通知程序）
///
/// ### 应用程序模式
/// - **app_cursor**: 应用程序光标键模式（方向键发送不同的转义序列）
/// - **app_keypad**: 应用程序小键盘模式（小键盘发送不同的转义序列）
///
/// ## 技术细节
/// - **packed struct(u32)**: 32位 packed struct，确保与 C 语言兼容
/// - 每个模式占用一个比特位，总共可以表示 24 种模式（去除填充位）
///
/// ## 转义序列示例
/// - CSI ? h / CSI ? l: 设置/重置 DEC 模式
/// - CSI > h / CSI > l: 设置/重置私有模式
pub const TermMode = packed struct(u32) {
    wrap: bool = false, // 自动换行：光标到达行尾时自动转到下一行
    insert: bool = false, // 插入模式：新字符插入光标位置，不覆盖
    alt_screen: bool = false, // 备用屏幕：切换到应用程序专用屏幕（如 vim）
    crlf: bool = false, // 回车换行：CR 自动添加 LF（Windows 风格）
    echo: bool = false, // 回显模式：将输入字符回显到屏幕（PTY 模式）
    print: bool = false, // 打印模式：将屏幕内容发送到打印机
    utf8: bool = false, // UTF-8 模式：启用 UTF-8 编码（默认启用）
    app_cursor: bool = false, // 应用光标：方向键发送应用程序转义序列
    app_keypad: bool = false, // 应用小键盘：小键盘发送应用程序转义序列
    hide_cursor: bool = false, // 隐藏光标：不显示光标（播放动画时有用）
    reverse: bool = false, // 反色模式：DECSCNM - 全局反色（前景/背景互换）
    kbdlock: bool = false, // 键盘锁定：键盘输入被忽略（DECCKM）
    mouse: bool = false, // 鼠标模式：DECSET 1000 (X11 鼠标)
    mouse_x10: bool = false, // X10 鼠标：DECSET 9 (仅报告按下)
    mouse_btn: bool = false, // 按钮移动：DECSET 1002 (按住按钮时报告移动)
    mouse_many: bool = false, // 所有移动：DECSET 1003 (无论是否按住都报告移动)
    mouse_sgr: bool = false, // 鼠标 SGR：DECSET 1006 (SGR 格式报告)
    mouse_focus: bool = false, // 鼠标焦点报告：DECSET 1004
    brckt_paste: bool = false, // 括号粘贴：DECSET 2004 (粘贴内容用特殊字符包裹)
    mouse_utf8: bool = false, // 鼠标 UTF-8: DECSET 1005 (已废弃，建议用 SGR)
    mouse_urxvt: bool = false, // 鼠标 URXVT: DECSET 1015 (已废弃，建议用 SGR)
    num_lock: bool = false, // 数字锁定：小键盘锁定在数字模式
    blink: bool = false, // 闪烁：光标/文本闪烁开关 (DECSCBNM)
    focused: bool = false, // 焦点状态：窗口是否有焦点 (只读状态)
    sync_update: bool = false, // 同步更新：DECSET 2026 (批量更新模式)
    _padding: u7 = 0, // 填充位

    /// 检查是否启用了任意鼠标模式
    pub fn isMouseEnabled(self: TermMode) bool {
        return self.mouse or self.mouse_x10 or self.mouse_btn or self.mouse_many;
    }
};

/// 字符集
///
/// ## 新手入门：终端支持多种字符集
///
/// VT100 终端支持在 4 个字符集槽位（G0-G3）之间切换。
/// 早期终端使用字符集来显示不同的图形和符号。
///
/// ## 字符集槽位
/// - **G0**: 默认字符集（通常是美国 ASCII）
/// - **G1**: 备用字符集（通常是图形字符）
/// - **G2/G3**: 额外的字符集
///
/// ## 常见字符集类型
/// - **usa (US ASCII)**: 标准 ASCII 字符集（0-127）
/// - **graphic0 (VT100 制表符)**: 包含制表符（如 ┌ ─ ┐ 等）
/// - **uk (UK ASCII)**: 英国 ASCII（某些符号不同）
/// - **ger (German)**: 德语字符集
/// - **fin (Finnish)**: 芬兰语字符集
///
/// ## 使用场景
///
/// ### 示例 1：显示制表符
/// 1. 将 G1 设置为 graphic0 字符集（ESC ( 0）
/// 2. 使用 SI (Shift In) 切换到 G1
/// 3. 某些字符（如 l q m x j）会被解释为制表符
///
/// ### 示例 2：使用 UK 字符集
/// 1. 将 G0 设置为 uk 字符集（ESC ( A）
/// 2. 钱币符号从 $ 变为 £
///
/// ## 转义序列
/// - ESC ( C: 选择 G0 字符集
/// - ESC ) C: 选择 G1 字符集
/// - ESC ( 0: 选择 G0 为 graphic0
/// - ESC ( B: 选择 G0 为 USA
pub const CharSet = enum(u8) {
    graphic0, // VT100 制表符（Line Drawing Character Set）
    graphic1, // 备用图形字符集（未广泛使用）
    uk, // 英国 ASCII（UK ASCII）
    usa, // 美国 ASCII（US ASCII - 默认）
    multi, // 多语言字符集（Multinational Character Set）
    ger, // 德语字符集（German Character Set）
    fin, // 芬兰语字符集（Finnish Character Set）
};

/// 转义序列状态
///
/// ## 新手入门：理解转义序列的"状态机"
///
/// 转义序列解析器是一个状态机。当解析器接收到一个字符时，
/// 它会根据当前状态决定如何处理这个字符。
///
/// ## 状态转换示例
///
/// ### 解析 CSI 光标移动序列 "ESC [ 10 ; 20 H"
/// ```
/// 1. 接收 ESC (0x1B)
///    → start = true（进入转义模式）
/// 2. 接收 [ (0x5B)
///    → start = true, csi = true（进入 CSI 模式）
/// 3. 接收 1 (0x31)
///    → 累积参数到 csi.buf
/// 4. 接收 0 (0x30)
///    → 累积参数到 csi.buf
/// 5. 接收 ; (0x3B)
///    → 分隔符，开始下一个参数
/// 6. 接收 2 (0x32)
///    → 累积参数到 csi.buf
/// 7. 接收 0 (0x30)
///    → 累积参数到 csi.buf
/// 8. 接收 H (0x48)
///    → csi = false（退出 CSI 模式）
///    → 执行移动光标到 (10, 20) 的操作
/// ```
///
/// ## 状态详解
///
/// - **start**: 转义序列开始（遇到 ESC）
/// - **csi**: CSI 模式（CSI = Control Sequence Introducer）
/// - **str**: 字符串模式（OSC、DCS、PM、APC 等字符串序列）
/// - **alt_charset**: 字符集选择模式（等待 G0-G3 选择字符）
/// - **tstate**: 临时字符集模式（SS2、SS3 单次切换）
/// - **utf8**: UTF-8 解码状态（用于多字节字符）
/// - **str_end**: 字符串结束标志
/// - **decaln**: DECALN 测试模式（屏幕对齐测试）
///
/// ## 常见转义序列类型
///
/// - CSI: ESC [ ... （控制序列，如光标移动、颜色设置）
/// - OSC: ESC ] ... Ps;ST （操作系统命令，如设置标题、剪贴板）
/// - DCS: ESC P ... ST （设备控制字符串）
/// - PM: ESC ^ ... ST （隐私消息）
/// - APC: ESC _ ... ST （应用程序程序命令）
pub const EscapeState = packed struct(u16) {
    start: bool = false, // 转义序列开始：遇到 ESC 字符（0x1B）
    csi: bool = false, // CSI 模式：控制序列（如 ESC [ ... H）
    str: bool = false, // 字符串模式：OSC、DCS、PM、APC 等字符串序列
    alt_charset: bool = false, // 字符集选择：等待 G0-G3 选择字符集
    tstate: bool = false, // 临时字符集：SS2、SS3 单次切换
    utf8: bool = false, // UTF-8 解码：多字节字符解码状态
    str_end: bool = false, // 字符串结束：字符串序列的结束标志
    decaln: bool = false, // DECALN：屏幕对齐测试模式（ESC # 8）
    test_mode: bool = false, // 测试模式：ESC # 开头的测试命令
    _padding: u7 = 0, // 填充位：确保对齐到16位边界
};

/// 光标结构
///
/// ## 新手入门：光标不仅仅是"闪烁的方块"
///
/// 光标包含三个关键信息：
/// 1. **位置**: (x, y) 坐标（在哪一行哪一列）
/// 2. **属性**: 字符属性（粗体、颜色等，继承自光标位置）
/// 3. **状态**: 行为模式（自动换行、原点模式等）
///
/// ## 光标位置规则
///
/// - **x**: 0 到 col-1（列号）
/// - **y**: 0 到 row-1（行号）
/// - 光标位置超出范围时，会发生滚动或换行
///
/// ## 使用示例
///
/// 移动光标到屏幕中心：
/// ```zig
/// term.cursor.x = term.col / 2;
/// term.cursor.y = term.row / 2;
/// ```
///
/// 保存光标位置：
/// ```zig
/// const saved_x = term.cursor.x;
/// const saved_y = term.cursor.y;
/// // ... 执行操作 ...
/// term.cursor.x = saved_x;
/// term.cursor.y = saved_y;
/// ```
pub const Cursor = struct {
    attr: Glyph = .{}, // 字符属性：光标位置的字符属性（颜色、粗体等）
    x: usize = 0, // 列位置：从 0 开始，最大值为 col-1
    y: usize = 0, // 行位置：从 0 开始，最大值为 row-1
    state: CursorState = .default, // 光标状态：换行标记、原点模式等
};

/// 保存的光标状态（用于 DECSC/DECRC）
///
/// ## 新手入门：为什么需要保存光标状态？
///
/// 很多 TUI 程序（如 vim、htop、nano）在运行时会：
/// 1. 保存当前光标状态（位置、属性）
/// 2. 使用备用屏幕显示自己的界面
/// 3. 退出时恢复光标状态
///
/// 这样用户回到终端时，不会看到光标乱跳或位置不对。
///
/// ## 保存的内容
///
/// - **attr**: 字符属性（粗体、颜色、下划线等）
/// - **x/y**: 光标位置
/// - **state**: 光标状态（换行标记、原点模式等）
/// - **trantbl**: 字符集映射表（G0-G3）
/// - **charset**: 当前字符集索引
///
/// ## 使用场景
///
/// 主屏幕和备用屏幕各有一个保存的光标状态：
/// - term.saved_cursor[0]: 主屏幕
/// - term.saved_cursor[1]: 备用屏幕
///
/// 这样切换屏幕时，光标状态不会混淆。
pub const SavedCursor = struct {
    attr: Glyph = .{}, // 字符属性：粗体、颜色、下划线等
    x: usize = 0, // 保存的列位置
    y: usize = 0, // 保存的行位置
    state: CursorState = .default, // 保存的光标状态
    style: CursorStyle = .blinking_block_default, // 保存的光标样式
    trantbl: [4]CharSet = [_]CharSet{.usa} ** 4, // 字符集映射表：G0-G3 的字符集
    charset: u8 = 0, // 当前字符集索引：0-3（G0-G3）
};

/// 选择模式
///
/// ## 新手入门：选择功能的状态机
///
/// 终端选择功能（鼠标拖拽选择文本）有几个状态：
/// 1. **idle**: 空闲，没有选择
/// 2. **empty**: 开始了选择但没有选中任何内容
/// 3. **ready**: 选择完成，可以复制
///
/// ## 状态转换
///
/// ```
/// idle → empty: 鼠标按下（开始选择）
/// empty → ready: 鼠标移动（扩展选择）
/// ready → idle: 点击别处（清除选择）
/// ```
pub const SelectionMode = enum(u8) {
    idle, // 空闲：没有选择
    empty, // 空：开始选择但未选中内容
    ready, // 就绪：选择完成，可以复制
};

/// 选择类型
///
/// ## 新手入门：有两种选择模式
///
/// 1. **regular**: 普通选择（矩形块选择）
///    - 从起点到终点的矩形区域
///    - 例如：选择 3 行的 5-10 列
///
/// 2. **rectangular**: 矩形选择（通常需要按住 Alt 键）
///    - 从起点到终点的矩形区域
///    - 与 regular 不同之处在于处理方式（某些实现）
///
/// ## 使用场景
///
/// - regular: 选择文本（默认）
/// - rectangular: 选择列数据（如表格的某一列）
pub const SelectionType = enum(u8) {
    regular = 1, // 普通选择：文本选择
    rectangular = 2, // 矩形选择：列选择
};

/// 选择吸附模式
///
/// ## 新手入门：智能选择边界
///
/// 当你双击或三击时，终端会自动扩展选择范围：
/// - **双击**: 选择整个单词
/// - **三击**: 选择整行
///
/// ## 吸附模式详解
///
/// - **none**: 不吸附，精确到字符位置（单击）
/// - **word**: 单词吸附（双击），自动扩展到单词边界
/// - **line**: 行吸附（三击），自动扩展到整行
///
/// ## 单词边界规则
///
/// 单词分隔符在 config.zig 中定义：
/// ```zig
/// word_delimiters = " ,'\"()[]{}";
/// ```
/// 任何遇到这些字符，单词边界就会被识别。
///
/// ## 示例
///
/// ### 单击（none）
/// 选中的是光标所在的单个字符
///
/// ### 双击（word）
/// 在 "hello world" 的 'e' 上双击
/// → 选中 "hello"
///
/// ### 三击（line）
/// 在任意位置三击
/// → 选中整行
pub const SelectionSnap = enum(u8) {
    none = 0, // 无吸附：精确到字符
    word = 1, // 单词吸附：扩展到单词边界
    line = 2, // 行吸附：扩展到整行
};

/// 选择结构
///
/// ## 新手入门：理解选择的"起点"和"终点"
///
/// 当你用鼠标选择文本时，终端需要记录：
/// 1. **ob/oe**: 鼠标按下的原始位置和拖拽到的位置
/// 2. **nb/ne**: 标准化后的选择区域（起点总是在终点之前）
///
/// ## 为什么要标准化？
///
/// 因为用户可以从任意方向拖拽选择：
/// - 从左上角拖到右下角：起点 < 终点（正常）
/// - 从右下角拖到左上角：起点 > 终点（需要翻转）
///
/// 标准化确保 nb 总是左上角，ne 总是右下角，方便处理。
///
/// ## 字段详解
///
/// - **mode**: 选择状态（idle/empty/ready）
/// - **type**: 选择类型（regular/rectangular）
/// - **snap**: 吸附模式（none/word/line）
/// - **nb (normalized begin)**: 标准化起点（左上角）
/// - **ne (normalized end)**: 标准化终点（右下角）
/// - **ob (original begin)**: 原始起点（鼠标按下位置）
/// - **oe (original end)**: 原始终点（鼠标释放位置）
/// - **alt**: 是否在备用屏幕
///
/// ## 示例
///
/// ### 从左上角向右下角选择
/// ```
/// ob = (5, 10)  // 鼠标按下位置
/// oe = (15, 20) // 鼠标拖拽位置
/// nb = (5, 10)  // 标准化起点（相同）
/// ne = (15, 20) // 标准化终点（相同）
/// ```
///
/// ### 从右下角向左上角选择
/// ```
/// ob = (15, 20) // 鼠标按下位置
/// oe = (5, 10)  // 鼠标拖拽位置
/// nb = (5, 10)  // 标准化起点（翻转后）
/// ne = (15, 20) // 标准化终点（翻转后）
/// ```
/// ob = (5, 10)  // 鼠标按下位置
/// oe = (15, 20) // 鼠标拖拽位置
/// nb = (5, 10)  // 标准化起点（相同）
/// ne = (15, 20) // 标准化终点（相同）
/// ```
///
/// ### 从右下角向左上角选择
/// ```
/// ob = (15, 20) // 鼠标按下位置
/// oe = (5, 10)  // 鼠标拖拽位置
/// nb = (5, 10)  // 标准化起点（翻转后）
/// ne = (15, 20) // 标准化终点（翻转后）
/// ```
pub const Selection = struct {
    mode: SelectionMode = .idle, // 选择模式：idle/empty/ready
    type: SelectionType = .regular, // 选择类型：regular/rectangular
    snap: SelectionSnap = .word, // 吸附模式：none/word/line
    nb: Point = .{}, // 标准化起点：左上角
    ne: Point = .{}, // 标准化终点：右下角
    ob: Point = .{}, // 原始起点：鼠标按下位置
    oe: Point = .{}, // 原始终点：鼠标拖拽位置
    alt: bool = false, // 是否在备用屏幕：主屏幕/备用屏幕
};

/// 点坐标
///
/// ## 新手入门：屏幕坐标系
///
/// 终端屏幕是一个二维网格：
/// - **x**: 列号（从左到右，0 到 col-1）
/// - **y**: 行号（从上到下，0 到 row-1）
///
/// ## 坐标示例
///
/// ```
/// (0, 0) (1, 0) (2, 0) ... (119, 0)
/// (0, 1) (1, 1) (2, 1) ... (119, 1)
/// (0, 2) (1, 2) (2, 2) ... (119, 2)
/// ...
/// (0, 34) ...
/// ```
///
/// ## 使用场景
///
/// - 光标位置：(c.x, c.y)
/// - 选择起点：selection.nb
/// - 选择终点：selection.ne
pub const Point = struct {
    x: usize = 0, // 列坐标：从 0 开始
    y: usize = 0, // 行坐标：从 0 开始
};

/// CSI 转义序列结构
///
/// ## 新手入门：CSI 是什么？
///
/// CSI = Control Sequence Introducer（控制序列引入符）
/// 格式：ESC [ ... Ps;Ps... 终结符
///
/// ## 示例 CSI 序列
///
/// ### 移动光标到第10行第20列
/// CSI 10 ; 20 H
/// - ESC: 转义字符 (0x1B)
/// - [: CSI 引入符 (0x5B)
/// - 10: 第一个参数（行号）
/// - ;: 参数分隔符
/// - 20: 第二个参数（列号）
/// - H: 终结符（光标定位）
///
/// ### 设置前景色为红色
/// CSI 31 m
/// - 31: 参数（红色前景色）
/// - m: 终结符（SGR - Select Graphic Rendition）
///
/// ## 字段详解
///
/// - **buf**: 原始字符串缓冲区（存储 ESC [ 和终结符之间的所有字符）
/// - **len**: 已用长度（缓冲区中有多少字符）
/// - **priv**: 私有模式标志（是否是私有序列，如 CSI ? 25 h）
/// - **arg**: 参数数组（解析后的参数，如 [10, 20]）
/// - **narg**: 参数数量（有多少个有效参数）
/// - **mode**: 终结符（如 'H', 'm', 'K' 等，存储为2个字符）
/// - **carg**: 冒号参数（扩展参数，用于 SGR 256色）
///
/// ## 冒号参数（Colon Arguments）
///
/// 现代 SGR 支持256色和24位真彩色，使用冒号分隔子参数：
/// CSI 38:2:255:0:0 m → 设置前景色为 RGB(255,0,0)（红色）
/// - 38: 设置前景色
/// - 2: RGB 模式
/// - 255: R 分量
/// - 0: G 分量
/// - 0: B 分量
///
/// ## 解析流程
///
/// 1. 遇到 ESC [，进入 CSI 模式
/// 2. 累积字符到 buf
/// 3. 遇到终结符（0x40-0x7E），退出 CSI 模式
/// 4. 解析 buf，提取参数到 arg 数组
/// 5. 根据 mode（终结符）执行相应操作
pub const CSIEscape = struct {
    buf: [512]u8 = .{0} ** 512, // 原始字符串缓冲区：ESC [ 后的字符
    len: usize = 0, // 已用长度：缓冲区中有多少字符
    priv: u8 = 0, // 私有模式标志：是否是私有序列（如 ?）
    arg: [32]i64 = .{0} ** 32, // 参数数组：解析后的参数（如 [10, 20]）
    narg: usize = 0, // 参数数量：有多少个有效参数
    mode: [2]u8 = .{0} ** 2, // 终结符：如 'H', 'm', 'K' 等
    carg: [32][16]i64 = .{.{0} ** 16} ** 32, // 冒号参数：扩展参数（用于256色）
};

/// STR 转义序列结构
///
/// ## 新手入门：STR 是什么？
///
/// STR = String（字符串序列）
/// 包含 OSC、DCS、PM、APC 等带字符串参数的转义序列。
///
/// ## 常见 STR 序列
///
/// ### OSC（操作系统命令）
/// ESC ] Ps;Pt ST
/// - 0: 设置窗口标题和图标名称
/// - 1: 设置图标名称
/// - 2: 设置窗口标题
/// - 52: 剪贴板操作
/// - 4: 设置调色板
///
/// ### 示例：设置窗口标题为 "stz"
/// ESC ] 2;stz ST
/// - 2: 设置窗口标题
/// - ;: 分隔符
/// - stz: 标题字符串
/// - ST: 字符串终止符（可以是 ESC \ 或 BEL）
///
/// ## 字段详解
///
/// - **type**: 转义序列类型（0=OSC, 1=DCS, 2=PM, 3=APC）
/// - **buf**: 动态分配的字符串缓冲区
/// - **siz**: 分配大小（缓冲区总容量）
/// - **len**: 已用长度（缓冲区当前使用了多少）
/// - **args**: 参数数组（多个字符串参数）
/// - **narg**: 参数数量（有多少个有效参数）
///
/// ## 字符串终止符（ST）
///
/// STR 序列可以用以下方式终止：
/// - ESC \ (0x1B 0x5C): 最常见的终止符
/// - BEL (0x07): 某些实现支持
/// - ST (String Terminator): 抽象概念
///
/// ## 解析流程
///
/// 1. 遇到 ESC ]，进入 OSC 模式
/// 2. 累积字符到 buf（包括分号分隔符）
/// 3. 遇到 ST（ESC \ 或 BEL），退出 STR 模式
/// 4. 按 ; 分隔符，将 buf 切分为多个参数
/// 5. 根据 args[0]（类型码）执行相应操作
pub const STREscape = struct {
    type: u8 = 0, // 转义序列类型：0=OSC, 1=DCS, 2=PM, 3=APC
    buf: []u8 = &[_]u8{}, // 动态分配的字符串缓冲区
    siz: usize = 0, // 分配大小：缓冲区总容量
    len: usize = 0, // 已用长度：缓冲区当前使用了多少
    args: [16][]u8 = .{&[_]u8{}} ** 16, // 参数数组：多个字符串参数
    narg: usize = 0, // 参数数量：有多少个有效参数
};

/// 终端结构
///
/// ## 新手入门：Term 是终端模拟器的"大脑"
///
/// Term 结构体包含了终端模拟器的所有状态：
/// - 屏幕内容（主屏幕和备用屏幕）
/// - 光标位置和状态
/// - 历史滚动缓冲区
/// - 各种模式标志
/// - 颜色调色板
/// - 窗口标题
///
/// ## 核心概念详解
///
/// ### 1. 屏幕缓冲区（line/alt）
///
/// 终端有两个屏幕：
/// - **主屏幕 (line)**: 普通的命令行界面
/// - **备用屏幕 (alt)**: TUI 程序专用（如 vim、htop）
///
/// TUI 程序运行时：
/// 1. 切换到备用屏幕（清空备用屏幕，显示自己的界面）
/// 2. 退出时切回主屏幕（恢复之前的命令行界面）
///
/// ### 2. 历史缓冲区（hist）
///
/// 当内容超出屏幕顶部时，会被推入历史缓冲区。
/// 用户可以用 Shift+PageUp/PageDown 向上滚动查看历史。
///
/// ### 3. 滚动区域（top/bot）
///
/// 某些程序会限制滚动的区域（如 vim 的状态栏不滚动）。
/// - **top**: 滚动区域顶部行（默认 0）
/// - **bot**: 滚动区域底部行（默认 row-1）
///
/// ### 4. 脏标记（dirty）
///
/// dirty[i] = true 表示第 i 行需要重新渲染。
/// 优化性能：只渲染发生变化的行，而不是整个屏幕。
///
/// ## 内存布局
///
/// ```
/// Term
/// ├── 屏幕尺寸：row x col
/// ├── 屏幕缓冲区
/// │   ├── line[][]Glyph: 主屏幕
/// │   └── alt[][]Glyph: 备用屏幕
/// ├── 历史缓冲区
/// │   └── hist[][]Glyph: 循环缓冲区
/// ├── 光标
/// │   ├── c: 当前光标
/// │   └── saved_cursor[2]: 保存的光标
/// ├── 模式
/// │   ├── mode: 终端模式标志
/// │   └── esc: 转义序列解析状态
/// └── 调色板
///     └── palette[256]: 颜色调色板
/// ```
pub const Term = stz.Terminal;
