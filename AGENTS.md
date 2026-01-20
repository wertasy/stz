# AGENTS.md - stz 项目开发指南

本文档为在 stz 项目中工作的 AI 代理提供开发指南。

## 构建命令

```bash
# 清理、编译、运行
rm -rf .zig-cache zig-out && zig build && zig build run

# 发布构建
zig build -Drelease-fast

# 测试
zig build test                              # 所有测试
zig test src/modules/terminal.zig           # 单个文件
zig test src/modules/screen.zig --filter-test "scroll" # 过滤

# 格式化和检查
zig fmt .                                   # 格式化
zig fmt --check .                            # 检查格式
zig build -freference-trace                  # 详细错误
```

## 代码风格指南

### 导入风格
```zig
const std = @import("std");
const terminal = @import("modules/terminal.zig");
const types = @import("types.zig");
```
**规则：** 
- 命名空间： 严禁直接提取成员，通过 terminal.Device 明确来源，规避冲突。
- 路径引用： 跨目录使用项目完整路径，同级使用相对路径。
- 排序： 按 标准库 > 第三方库 > 本地模块 分组，空行分隔。
- 例外： 仅 print 等极高频工具函数允许直接定义别名。

### 注释风格
```zig
//! 文件级别文档注释
/// 结构体/函数文档注释
// 行内注释
```
**规则：** 使用中文注释

### 命名约定
```zig
// 类型：PascalCase
pub const Terminal = struct { ... };
// 函数：camelCase
pub fn init() !Terminal { ... }
// 常量/变量：snake_case
pub const max_lines: usize = 1000;
// 私有字段：下划线前缀
_padding: u3 = 0,
```

### 错误处理
```zig
pub const ModuleError = error { OutOfBounds, InvalidSequence };
pub fn someFunction() !void { return error.AllocationFailed; }
try someFunction();
const result = try otherFunction() catch |err| {
    std.log.err("错误: {}\n", .{err});
    return err;
};
```
**规则：** 自定义错误集（不用 `anyerror`），错误消息用中文

### 资源管理
```zig
const gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true });
defer {
    const deinit_status = gpa.deinit();
    if (deinit_status == .leak) std.log.err("内存泄漏\n", .{});
}
const allocator = gpa.allocator();

const buffer = try allocator.alloc(u8, 1024);
defer allocator.free(buffer);

pub const SomeStruct = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) !SomeStruct {
        return SomeStruct{ .allocator = allocator };
    }
    pub fn deinit(self: *SomeStruct) void { }
};
var obj = try SomeStruct.init(allocator);
defer obj.deinit();
```
**规则：** 用 `defer` 清理，分配器通过参数传递，`init()` / `deinit()` 模式

### 类型系统
```zig
pub const GlyphAttr = packed struct(u16) {
    bold: bool = false,
    italic: bool = false,
    _padding: u3 = 0,
};
const x: usize = @intCast(value);
const n: u32 = @truncate(value);
const f: f32 = @floatFromInt(value);
```
**规则：** 位标志用 `packed struct`，避免 `@as`，用显式转换函数

### 配置管理
```zig
pub const Config = struct {
    pub const window = struct {
        pub const cols: usize = 120;
    };
};
const cols = Config.window.cols;
```
**规则：** 所有配置在 `src/modules/config.zig`，用嵌套结构体组织

## 项目特定要求

### SDL 版本
⚠️ **重要：当前代码使用 SDL3，但目标环境只有 SDL2。**

优先使用 SDL2 API，参考 `TODO.md` 中的 SDL3→SDL2 映射表，等待 SDL2 迁移完成后再添加新 SDL 功能。

### 终端标准
遵循 VT100/VT220 标准，参考 xterm 控制序列文档，实现完整的 ANSI 转义序列支持。

### Unicode 处理
使用 `std.unicode` 而非自定义实现，支持宽字符（CJK 等），正确处理 UTF-8 编码。

### 内存分配
使用 `GeneralPurposeAllocator` 开发，检测内存泄漏，考虑线程安全性。

## 代码审查检查清单

- [ ] `zig fmt .` 格式化
- [ ] `zig build` 编译通过
- [ ] `zig build test` 测试通过
- [ ] 检查内存泄漏
- [ ] `zig fmt --check .` 验证格式
- [ ] 代码符合风格指南
- [ ] 添加中文注释
- [ ] 更新相关文档

## 调试技巧

```bash
zig build -freference-trace
zig build -Demit-asm=zig-out/asm.s
zig build -Ddebug && lldb zig-out/bin/stz
zig build -Drelease-fast && perf record -g ./zig-out/bin/stz && perf report
```

## 参考资料

- [Zig 0.15.2 标准库](http://127.0.0.1:42857/)
- [Zig 学习资源](https://ziglang.org/learn/)
- [SDL2 文档](https://wiki.libsdl.org/CategoryAPI)
- [VT100 标准](https://vt100.net/)
- [xterm 控制序列](http://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
