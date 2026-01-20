# stz - 简单终端模拟器 (Zig 实现)

[![Zig](https://img.shields.io/badge/Zig-0.15.2-blue.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

stz 是使用 Zig 语言重写的 st (simple terminal) 终端模拟器。

> ⚠️ **重要提示**: 当前代码使用 **SDL3** API，但环境只有 **SDL2**。需要先完成 SDL2 兼容性改造。详见 [TODO.md](TODO.md)。

## ✨ 特性

### 已实现 ✅

- ✅ 完整的 VT100/VT220 转义序列支持 (CSI, OSC, DCS 等)
- ✅ UTF-8 编解码 (使用 Zig 标准库 `std.unicode`)
- ✅ 屏幕缓冲区管理 (滚动、清除、脏标记)
- ✅ 终端模拟核心 (光标移动、字符写入、模式设置)
- ✅ 模块化代码结构，职责清晰
- ⚠️  基础渲染框架 (需要字体支持)
- ⚠️ 简化的字符渲染 (需要 FreeType 集成)
- ⚠️ 文本选择功能 (需要剪贴板集成)
- ⚠️ URL 检测 (需要完整实现)
- ⚠️ 框线字符支持 (需要完整绘制)
- ⚠️ **SDL3 窗口系统 (需要迁移到 SDL2)**
- ⚠️ **POSIX PTY 支持 (仅 Linux)**

### 待实现 ⚠️

详见 [TODO.md](TODO.md) 完整的功能清单。

## 🚀 快速开始

### 环境要求

- **Zig**: 0.15.2
- **SDL2**: 2.28+ (SDL3 待迁移)
- **编译器**: C 编译器 (用于系统头文件)
- **操作系统**: Linux, BSD, macOS (理论支持)

### 安装依赖

```bash
# Ubuntu/Debian
sudo apt install libsdl2-dev libfontconfig1-dev libfreetype-dev pkg-config

# Fedora/RHEL
sudo dnf install SDL2-devel fontconfig-devel freetype-devel pkgconfig

# Arch Linux
sudo pacman -S sdl2 fontconfig freetype2 pkg-config

# macOS
brew install sdl2 fontconfig freetype pkg-config
```

### 获取 SDL 依赖

**注意**: 需要使用 SDL2 版本

```bash
# 方式 1: 使用 zig-fetch (推荐)
zig fetch --save sdl2

# 方式 2: 手动添加到 build.zig.zon
# 然后在 build.zig 中手动配置
```

### 编译

```bash
# 克隆项目
git clone <repository-url>
cd stz

# 编译
zig build

# 运行
./zig-out/bin/stz
# 或者
zig build run
```

## 📁 项目结构

```
stz/
├── build.zig              # Zig 构建配置
├── build.zig.zon           # Zig 包管理配置 (需要 SDL2)
├── README.md              # 项目文档 (本文件)
├── TODO.md               # 待完成功能清单 ⭐
└── src/
    ├── main.zig          # 主程序入口和事件循环
    └── modules/
        ├── config.zig    # 配置管理
        ├── types.zig     # 核心数据类型定义
        ├── unicode.zig   # UTF-8 编解码
        ├── screen.zig    # 屏幕缓冲区管理
        ├── parser.zig    # ANSI/VT100 转义序列解析
        ├── terminal.zig  # 终端模拟核心逻辑
        ├── window.zig    # ⚠️ SDL 窗口系统 (SDL3 → SDL2 待迁移)
        ├── renderer.zig  # 字符渲染系统
        ├── input.zig     # 键盘和鼠标输入处理
        ├── pty.zig       # 伪终端管理
        ├── selection.zig  # 文本选择和复制
        ├── url.zig       # URL 检测和高亮
        └── boxdraw.zig   # 框线字符绘制
```

## ⚙️ 配置

配置选项在 `src/modules/config.zig` 中定义：

### 字体设置
- `font.name`: 字体名称 (默认: "monospace")
- `font.size`: 字体大小 (默认: 20)
- `font.bold`: 粗体 (默认: true)
- `font.italic`: 斜体 (默认: false)

### 窗口设置
- `window.cols`: 列数 (默认: 120)
- `window.rows`: 行数 (默认: 35)
- `window.border_pixels`: 边框宽度 (默认: 2)

### 颜色设置
- 标准 16 色
- 高亮 16 色
- 特殊颜色 (前景、背景、光标)

### 其他设置
- Shell 路径
- Tab 间隔 (默认: 8)
- URL 检测规则
- 选择超时 (双击 300ms, 三击 600ms)

## 🔧 开发计划

详细开发计划请查看 [TODO.md](TODO.md)。

### 当前状态
- ✅ 核心框架完成
- ⚠️ 需要迁移到 SDL2
- ⚠️ 需要字体渲染支持
- 🚀 准备开始功能增强

## 🐛 故障排除

### 编译错误

```bash
# 清理构建缓存
rm -rf .zig-cache

# 重新构建
zig build
```

### 运行时错误

如果遇到 SDL 初始化失败：
```bash
# 检查 SDL 版本
sdl2-config --version

# 检查库路径
pkg-config --cflags --libs sdl2
```

## 📚 参考

### 官方文档
- [Zig 0.15.2 标准库文档](http://127.0.0.1:42857/)
- [SDL2 官方文档](https://wiki.libsdl.org/)
- [SDL2 API 参考](https://wiki.libsdl.org/CategoryAPI)

### 终端标准
- [VT100 标准](https://vt100.net/)
- [VT220 手册](https://vt100.net/docs/vt220.html)
- [xterm 控制序列](http://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
- [ANSI 转义序列](https://en.wikipedia.org/wiki/ANSI_escape_code)
- [ECMA-48 标准](https://www.ecma-international.org/publications/standards/Ecma-048.htm)

### 字体和渲染
- [FontConfig](https://www.freedesktop.org/wiki/Software/fontconfig)
- [FreeType2](https://freetype.org/)
- [Unicode 宽度标准](https://www.unicode.org/reports/tr11/)

### 其他终端模拟器
- [st 源码](https://st.suckless.org/) - 原版 C 实现
- [Alacritty 源码](https://github.com/alacritty/alacritty) - Rust 实现，值得参考
- [kitty 源码](https://github.com/kovidgoyal/kitty) - Python 实现

## 📄 许可证

与原版 st 保持一致，使用相同的 MIT/X11 许可证。

## 🤝 贡献

欢迎贡献！请先查看 [TODO.md](TODO.md) 了解需要的工作。

### 提交代码

1. Fork 本仓库
2. 创建功能分支 (`git checkout -b feature/amazing-feature`)
3. 提交更改 (`git commit -m 'Add some amazing feature'`)
4. 推送到分支 (`git push origin feature/amazing-feature`)
5. 创建 Pull Request

### 代码风格

- 遵循 Zig 代码风格
- 使用 `zig fmt` 格式化代码
- 避免使用 `@as` 和 `@ptrCast`，除非必要
- 使用 `packed struct` 进行位操作

---

**stz** - 用 Zig 重写的简单而强大的终端模拟器

🔗 相关链接: [st](https://st.suckless.org/) | [Zig](https://ziglang.org/) | [SDL](https://www.libsdl.org/)
