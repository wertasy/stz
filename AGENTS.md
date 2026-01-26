# AGENTS.md - stz 项目开发指南

本文档为在 stz 项目中工作的 AI 代理提供开发指南，确保代码一致性与功能对齐。

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
const x11 = @import("x11.zig");

const types = @import("types.zig");
const terminal = @import("terminal.zig");
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
- **选择机制**: 支持双击选中单词 (Word Snap) 和三击选中整行 (Line Snap)。单词边界参考 `config.zig` 中的 `word_delimiters`。
- **双缓冲**: 所有绘图必须在 Pixmap 上完成，最后通过 `XCopyArea` 呈现。

## 代码审查清单 (Checklist)

- [ ] `zig build test` 通过且无 Regression。
- [ ] 代码经过 `zig fmt .` 处理。
- [ ] 核心 API 均有中文文档注释。
- [ ] 检查内存泄漏 (GPA 在测试结束时会输出泄露报告)。
- [ ] 宽字符写入行尾的 `wrap_next` 逻辑符合 `st` 预期。

## 参考资料
- 原始 C 版 st 路径: `/home/$USER/Github/suckless/st`
- [Zig 0.15.2 文档](https://ziglang.org/documentation/0.15.2/)
- [Xterm 控制序列手册](http://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
