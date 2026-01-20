# AGENTS.md - src/stz 模块开发指南

终端模拟器核心模块 - 20 个子模块，179K 行代码

## OVERVIEW
所有终端核心功能的中心枢纽，导出 17 个类型到主程序

## WHERE TO LOOK
| 模块 | 关键功能 | 行数 |
|-------|---------|------|
| Terminal | 屏幕缓冲区、光标状态、滚动、备用屏幕 | 52K |
| Parser | VT100/VT220 转义序列解析（状态机） | 58K |
| Renderer | Xft/HarfBuzz 渲染、字体缓存、脏行检测 | 60K |
| Window | X11 窗口管理、双缓冲、输入法（XIM/XIC） | 11K |
| Input | 键盘/鼠标输入、应用模式、括号粘贴 | 16K |
| PTY | 伪终端 fork/exec、窗口大小调整 | 7.4K |
| Selector | 文本选择、剪贴板（PRIMARY/CLIPBOARD） | 15K |
| types | Glyph、GlyphAttr、Term、Selection 等核心数据结构 | 33K |
| unicode | UTF-8 编解码、CJK 宽度计算 | 6.6K |
| harfbuzz | HarfBuzz 字形缓存、连字支持 | 4.2K |
| url | URL 检测、Ctrl+点击打开 | 7.8K |
| config | 编译期配置（字体、颜色、快捷键） | 7.4K |

## CONVENTIONS

### 模块导出（stz.zig）
所有子模块通过 `stz.zig` 导出：
```zig
pub const Terminal = @import("Terminal.zig");
pub const Parser = @import("Parser.zig");
pub const Renderer = @import("Renderer.zig");
// ... 等 17 个导出
```

### Init/Deinit 模式
所有资源持有结构体必须实现：
```zig
pub fn init(allocator: std.mem.Allocator) !Self { /* 分配资源 */ }
pub fn deinit(self: *Self) void { /* 释放资源 */ }
```

### C 绑定导出（stz.zig）
X11 和 HarfBuzz 绑定通过 `stz.c.x11.*` 和 `stz.c.hb.*` 访问

## ANTI-PATTERNS（本项目禁止）

### 禁止模式
1. **禁止 `usingnamespace`** - 必须通过命名空间显式访问成员
2. **禁止 `anyerror`** - 各模块定义专属错误集
3. **禁止直接绘制到窗口** - 所有绘图在 Pixmap 上完成

### 必须遵循
1. **中文注释** - 公共接口和复杂逻辑必须使用中文注释
2. **资源管理** - Init/Deinit 模式，defer 确保释放
3. **宽字符处理** - `wide_dummy` 单元格占位符
4. **字体回退** - Renderer 实现主字体缺字时的备用字体遍历

### 避免模式
1. **避免刷屏日志** - KeyPress/MotionNotify 等高频事件不记录详细日志
2. **避免重复分配** - 颜色缓存、字体缓存减少 X11/Xft 调用
3. **避免闪烁** - 双缓冲（Pixmap → XCopyArea）
4. **避免内存泄漏** - 测试中使用 GPA 检测泄漏

## 核心模式

### Parser（转义序列解析器）
状态机处理：
- CSI 序列：`ESC [ ...`（光标移动、SGR 颜色等）
- OSC 序列：`ESC ] ...`（窗口标题、调色板等）
- 字符集切换：`ESC (` ` 和 `ESC ) `（G0/G1 字符集）
- UTF-8 解码：多字节字符的码点组合

**关键常量**：
- 支持 CSI 冒号参数（38:5:123 扩展颜色）
- 支持鼠标 SGR 1006 模式
- 支持下划线样式（4:3 curly, 58:5:123 color）

### Terminal（终端状态机）
屏幕缓冲区管理：
- 主屏幕（line）和备用屏幕（alt）切换
- 历史缓冲区（hist）循环存储滚出内容
- 脏标记（dirty）按行标记需要重绘的区域
- 滚动区域（top/bot）限制滚动范围

**宽字符处理**：
- 宽字符单元格（wide=true）存储实际字符
- 占位单元格（wide_dummy=true）标记第二个位置
- 光标跳过 wide_dummy，不修改其属性

### Renderer（渲染器）
双缓冲机制：
- Pixmap：离屏缓冲区，所有绘制操作在此完成
- 脏行检测：只重绘 dirty[i]=true 的行
- XCopyArea：一次性将 Pixmap 复制到窗口

**字体回退**：
- 主字体（font）优先尝试
- 遍历 fallbacks 列表中的备用字体
- HarfBuzz 字形缓存避免重复创建

### Input（输入处理器）
应用模式：
- 普通模式：方向键 → `ESC [ A/B/C/D`
- 应用模式：方向键 → `ESC O A/B/C/D`
- 括号粘贴模式：粘贴内容包裹在 `\x1B[200~ ... \x1B[201~`

**鼠标报告**：
- SGR 1006：发送 `<CSI><button>;<x>;<y>M` 格式
- 宽字符光标坐标：指向宽字符的起始位置（避免光标只显示一半）

### Selector（选择器）
选择模式：
- idle：无选择
- empty：单击但未拖动
- ready：完成，可复制

**吸附模式**：
- word：双击扩展到单词边界（Config.word_delimiters）
- line：三击扩展到整行
- none：单击精确到字符

**X11 选择机制**：
- PRIMARY：鼠标选择（中键粘贴）
- CLIPBOARD：Ctrl+C/Ctrl+V（现代应用）
- SelectionRequest：其他应用请求选择
- SelectionNotify：粘贴内容到达

## 命令
```bash
# 构建主程序
zig build

# 运行所有测试
zig build test --summary all

# 运行特定模块测试
zig build test --filter "Parser|Terminal|Renderer"

# 格式化代码
zig fmt .
```
