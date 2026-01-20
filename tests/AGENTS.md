# AGENTS.md - tests/ 测试指南

单元测试套件 - 5 个测试文件，724 行测试代码

## OVERVIEW
独立的测试目录，通过 build.zig 自动发现并运行

## WHERE TO LOOK
| 测试文件 | 覆盖范围 | 行数 |
|-----------|---------|------|
| parser_test.zig | 转义序列解析（SGR、OSC、鼠标模式） | 331 |
| terminal_test.zig | 终端状态、脏标记、滚动 | 117 |
| selection_test.zig | 选择机制（单词/行吸附） | 60 |
| unicode_test.zig | Unicode 宽度计算（CJK、emoji） | 140 |
| window_title_test.zig | OSC 序列窗口标题、内存泄漏检测 | 76 |

## CONVENTIONS

### 自动发现测试（build.zig）
```zig
// build.zig 第 52-99 行：自动发现 tests/ 下的所有 .zig 文件
var tests_dir = std.fs.cwd().openDir(tests_dir_path, .{ .iterate = true }) catch |err| {
    // 如果目录不存在，打印警告但不要崩溃
};
while (walker.next()) |entry| {
    if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zig")) {
        // 为每个测试文件创建独立的可执行文件
    }
}
```

### 测试结构模式
```zig
//! 模块单元测试

const std = @import("std");
const stz = @import("stz");

const Terminal = stz.Terminal;
const Parser = stz.Parser;

test "测试名称" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();

    var parser = try Parser.init(&term, null, allocator);
    defer parser.deinit();

    // 验证行为
    try expectEqual(@as(u32, expected), actual);
}
```

### 内存泄漏检测
```zig
test "测试内存管理" {
    const gpa = std.testing.allocator;  // GPA 自动检测泄漏
    // ... 测试代码 ...
    // 测试结束时 GPA 输出泄漏报告
}
```

### 双语命名（中文 + 英文）
```zig
test "窗口标题 OSC 序列" {        // 中文：上下文
    // ...
}
test "SGR reset sequence" {          // 英文：技术术语
    // ...
}
```

## ANTI-PATTERNS（测试规范）

### 必须遵循
1. **GPA 分配器** - 使用 `std.testing.allocator` 检测内存泄漏
2. **defer 清理** - 所有资源必须用 defer 确保释放
3. **逐字符输入** - 转义序列测试应逐字符输入（真实模拟）

### 跳过测试规范
```zig
test "CJK 字符应该宽度为 2" {
    // SKIP: libc wcwidth 在最小环境中常对 CJK 失败
    // try std.testing.expectEqual(@as(u8, 2), unicode.runeWidth(0x4E00));
}
```
- 明确注释 `// SKIP:` 说明跳过原因
- 不要删除测试代码，保持文档价值

### 避免模式
1. **避免测试内部状态** - 验证终端状态变化，而非 Parser 内部变量
2. **避免硬编码尺寸** - 使用配置值（24x80）或参数化测试

## 唯一约定

### Locale 感知 Unicode 测试
```zig
const libc = @cImport({ @cInclude("locale.h"); });
var locale_set = false;

fn ensureLocale() void {
    if (!locale_set) {
        _ = libc.setlocale(libc.LC_CTYPE, "C.UTF-8");
        locale_set = true;
    }
}

test "Unicode 宽度" {
    ensureLocale();  // 确保 wcwidth() 对 CJK 正确返回宽度
    // ...
}
```
- 每个测试套件只调用一次（静态标志）
- 确保 `wcwidth()` 对 CJK/Powerline 字符返回正确宽度

### Terminal/Parser 集成测试
```zig
test "集成测试" {
    const allocator = std.testing.allocator;
    var term = try Terminal.init(24, 80, allocator);
    defer term.deinit();

    var parser = try Parser.init(&term, null, allocator);
    defer parser.deinit();

    // 逐字符输入转义序列
    const sequence = "\x1b[38:5:123m";
    for (sequence) |c| try parser.putc(@intCast(c));

    // 断言终端状态变化
    try expectEqual(@as(u32, 123), term.cursor.attr.fg);
}
```
- 通过 Parser → Terminal 集成测试真实行为
- 不直接测试 Parser 内部状态机变量

### 系统库集成
所有测试自动链接：
- X11, Xft, fontconfig, freetype, harfbuzz
- 支持完整渲染行为测试

## 命令
```bash
# 运行所有测试
zig build test --summary all

# 运行特定测试套件
zig build test --filter "Parser"    # 仅 Parser 测试
zig build test --filter "Selection"  # 仅 Selection 测试
zig build test --filter "Unicode"    # 仅 Unicode 测试

# 运行多个测试套件
zig build test --filter "Parser|Terminal|Renderer"
```

## 已知限制
- `unicode_test.zig`: 部分 CJK/emoji 测试被跳过（libc wcwidth 在最小环境中不可靠）
- `window_title_test.zig`: 依赖 GPA 检测内存泄漏，100 次迭代标题变化
