# AGENTS.md - stz 项目开发指南

本文档为在 stz 项目中工作的 AI 代理提供开发指南，确保代码一致性与功能对齐。

**项目结构**: 终端模拟器核心模块位于 `src/stz/`，主入口在 `src/main.zig`
**总代码量**: 18 Zig 文件，~6k 行代码
**最大深度**: 4 层 (./src/stz/*)

## 项目结构

```
stz/
├── build.zig              # 构建配置（双模块架构，自动测试发现）
├── build.zig.zon           # 项目元数据（版本 0.1.0，Zig 0.15.2+）
├── src/
│   ├── main.zig          # 主程序入口（初始化 + 事件循环）
│   ├── stz.zig           # Zig 模块导出配置
│   └── stz/
│       ├── AGENTS.md      # 核心模块开发指南
│       ├── types.zig      # 数据类型定义（Glyph, GlyphAttr, Term, Selection 等）
│       ├── Terminal.zig   # 终端状态机（屏幕缓冲区、光标、滚动）
│       ├── Parser.zig     # 转义序列解析器（VT100/VT220）
│       ├── Renderer.zig   # Xft/HarfBuzz 渲染器（60K 行，字体缓存）
│       ├── Window.zig     # X11 窗口管理（双缓冲、输入法）
│       ├── Input.zig      # 键盘/鼠标输入处理（16K 行）
│       ├── PTY.zig        # 伪终端进程控制器
│       ├── Selector.zig   # 文本选择和剪贴板管理
│       ├── UrlDetector.zig # URL 检测引擎
│       ├── unicode.zig    # UTF-8 编解码（CJK 宽字符处理）
│       ├── HarfBuzz.zig   # HarfBuzz 字形缓存
│       ├── BoxDraw.zig    # 自定义制表符绘制
│       ├── x11_utils.zig  # X11 工具函数
│       ├── Args.zig       # 命令行参数解析
│       ├── Config.zig     # 编译期配置（字体、颜色、快捷键）
│       ├── Printer.zig    # 屏幕打印功能
│       └── Recorder.zig   # 终端会话录制
└── tests/
    ├── AGENTS.md         # 测试开发指南
    ├── parser_test.zig   # 转义序列测试
    ├── terminal_test.zig # 终端状态测试
    ├── selection_test.zig # 选择机制测试
    ├── unicode_test.zig  # Unicode 宽度测试
    └── window_title_test.zig # 窗口标题测试
```

## WHERE TO LOOK（任务定位）

| 任务 | 位置 | 说明 |
|------|--------|------|
| 终端状态、屏幕缓冲区 | `src/stz/Terminal.zig` | 字符写入、光标移动、滚动、备用屏幕 |
| 转义序列解析 | `src/stz/Parser.zig` | CSI/OSC/控制字符、字符集切换 |
| 渲染逻辑 | `src/stz/Renderer.zig` | 字体加载、字符绘制、脏行检测 |
| X11 窗口管理 | `src/stz/Window.zig` | 窗口创建、事件轮询、输入法 |
| 键盘/鼠标输入 | `src/stz/Input.zig` | 特殊键转换、鼠标报告、括号粘贴 |
| 文本选择 | `src/stz/Selector.zig` | 拖拽选择、单词/行吸附、剪贴板 |
| 数据类型定义 | `src/stz/types.zig` | Glyph, GlyphAttr, Term, Selection 结构体 |
| 主程序入口 | `src/main.zig` | 初始化顺序、主事件循环 |
| 字体渲染优化 | `src/stz/HarfBuzz.zig` | HarfBuzz 字形缓存、连字支持 |
| Unicode 处理 | `src/stz/unicode.zig` | UTF-8 编解码、字符宽度计算 |
| 伪终端控制 | `src/stz/PTY.zig` | fork/exec、窗口大小调整 |
| 编译期配置 | `src/stz/Config.zig` | 字体、颜色、快捷键 |

## CONVENTIONS（本项目特有）

### 模块导出模式
```zig
// src/stz.zig 统一导出所有子模块
pub const Terminal = @import("stz/Terminal.zig");
pub const Parser = @import("stz/Parser.zig");
pub const Renderer = @import("stz/Renderer.zig");
// ... 等 17 个导出
```

### Init/Deinit 模式
所有资源持有结构体必须实现：
```zig
pub fn init(...) !Self { /* 分配资源 */ }
pub fn deinit(self: *Self) void { /* 释放资源 */ }
```

### 双模块架构（非标准但有意为之）
- `stz` 模块：核心库（基于 `src/stz.zig`）
- `root_module`：应用程序入口（基于 `src/main.zig`，导入 `stz`）

### 自动测试发现
`build.zig` 自动发现 `tests/` 目录下的所有 `.zig` 测试文件，无需手动配置。

## ANTI-PATTERNS（本项目禁止）

### 禁止模式
1. **禁止使用 `usingnamespace`** - 必须通过命名空间显式访问成员
2. **禁止 `anyerror`** - 优先在各模块定义专属错误集
3. **禁止重复分配** - 使用颜色缓存、字体缓存避免重复分配
4. **禁止直接绘制到窗口** - 所有绘图必须在 Pixmap 上完成，通过 XCopyArea 呈现

### 必须遵循
1. **中英文注释** - 所有公共接口和复杂逻辑必须使用中文注释
2. **资源管理** - Init/Deinit 模式，使用 defer 确保释放
3. **字体回退** - Renderer 必须实现 Fallback 机制
4. **宽字符处理** - 渲染宽字符时需处理 `wide_dummy` 单元格

### 避免模式
1. **避免 `anyerror`** - 定义模块专属错误集
2. **避免刷屏日志** - 输入/窗口事件日志应节制
3. **避免闪烁** - 双缓冲是必须的
4. **避免内存泄漏** - 使用 GPA 在测试中检测泄漏

## 常用命令

```bash
# 构建并运行终端
zig build run

# 仅编译项目 (Debug)
zig build

# 运行所有单元测试 (包含 Parser 和 Selection)
zig build test --summary all

# 运行特定测试过滤 (例如仅测试 Parser)
zig build test --filter "Parser"

# 运行特定测试过滤 (例如仅测试 Selection)
zig build test --filter "Selection"

# 格式化所有代码
zig fmt .

# 检查代码格式 (CI 模式)
zig fmt --check .

# 清理构建缓存
rm -rf .zig-cache zig-out
```

## 代码风格指南

### 1. 导入风格
- **禁止使用 `usingnamespace`**：必须通过命名空间显式访问成员。
- **路径引用**：跨目录使用项目完整相对路径，同级使用 `./`。
- **排序**：标准库 > 第三方库 > 本地模块，各组间空行分隔。
```zig
const std = @import("std");

const stz = @import("stz");
const x11 = stz.x11;

const Terminal = stz.Terminal;
```

### 2. 命名约定
- **类型 (Struct, Enum, Union)**: `PascalCase` (如 `Term`, `GlyphAttr`)。
- **函数**: `camelCase` (如 `processBytes`, `init`)。
- **变量/字段/常量**: `snake_case` (如 `char_width`, `max_lines`)。
- **私有成员**: 结构体私有字段建议使用 `_` 前缀。

### 3. 注释风格
- **规则**：所有公共接口和复杂逻辑必须使用 **中文注释**。
- `//!`: 文件头部文档注释。
- `///`: 结构体、常量或函数文档注释。
- `//`: 代码块内部逻辑说明。

### 4. 错误处理
- **自定义错误集**：优先在各模块定义专属错误集，避免 `anyerror`。
- **错误捕获**：使用 `try` 向上传递，或 `catch` 处理并记录中文错误日志。
```zig
const result = someFunction() catch |err| {
    std.log.err("操作失败: {}", .{err});
    return err;
};
```

### 5. 资源管理
- **Init/Deinit 模式**：任何持有堆内存或系统句柄（如 X11 资源）的结构体必须实现 `init` 和 `deinit`。
- **显式分配器**：分配器通过 `init` 参数传递并存储在结构体中。
- **内存安全**：利用 `defer` 确保资源释放，关注 XftFont 等外部库资源的及时关闭。

### 6. 类型系统
- **Packed Structs**：位标志（Attributes, Modes）使用 `packed struct` 定义以匹配底层协议。
- **显式转换**：使用 `@intCast`, `@truncate`, `@floatFromInt`。

## 项目核心规范

### 终端模拟标准
- 严格遵循 VT100/VT220 标准，对齐 `xterm` 转义序列。
- **CSI 参数**：解析器必须支持冒号分隔的子参数 (Colon Arguments)，用于 SGR 扩展颜色。

### 字符与字体渲染
- **Unicode**: 使用 `std.unicode` 进行编码转换。
- **CJK 支持**: 渲染宽字符时需处理 `wide_dummy` 单元格。
- **字体回退**: `Renderer` 必须实现 Fallback 机制。若主字体缺少码点，应遍历备用字体列表。

### 交互行为
- **选择机制**: 支持双击选中单词 (Word Snap) 和三击选中整行 (Line Snap)。单词边界参考 `Config.zig` 中的 `word_delimiters`。
- **双缓冲**: 所有绘图必须在 Pixmap 上完成，最后通过 `XCopyArea` 呈现。

## 代码审查清单 (Checklist)

- [ ] `zig build test` 通过且无 Regression。
- [ ] 代码经过 `zig fmt .` 处理。
- [ ] 核心 API 均有中文文档注释。
- [ ] 检查内存泄漏 (GPA 在测试结束时会输出泄露报告)。
- [ ] 宽字符写入行尾的 `wrap_next` 逻辑符合 `st` 预期。

## 参考资料
- [Zig 0.15.2 文档](https://ziglang.org/documentation/0.15.2/)
- [Xterm 控制序列手册](http://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
