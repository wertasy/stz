# stz - 简单终端模拟器 (Zig 实现)

[![Zig](https://img.shields.io/badge/Zig-0.15.2-blue.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Beta-yellow.svg)](TODO.md)

**stz** 是著名终端模拟器 [st (simple terminal)](https://st.suckless.org/) 的 Zig 语言重写版。它保留了 st 极简、高效的设计哲学，同时利用 Zig 语言的现代特性提升了安全性、模块化程度和可维护性。

> **核心目标**: 提供一个代码清晰、性能卓越、功能完备且易于扩展的现代终端模拟器。

## ✨ 核心特性

- **现代架构**: 使用 Zig 语言重写，模块化设计 (Parser, Terminal, Renderer, Window 分离)，内存安全。
- **极致性能**:
  - **双缓冲渲染**: 使用 SDL2 Texture 彻底解决画面撕裂和闪烁。
  - **脏行检测**: 智能增量渲染，仅重绘变化区域，CPU 占用极低。
  - **硬件加速**: 使用 SDL2 硬件加速渲染器，充分利用 GPU 性能。
- **卓越的显示效果**:
  - **TrueColor**: 完整支持 24 位真彩色 (1600万色)。
  - **Box Drawing**: 内置像素级制表符绘制逻辑，无需特殊字体也能完美显示 TUI 边框。
  - **HarfBuzz 集成**: 支持高级字体特性和连字 (Ligatures)。
  - **字体回退**: 自动处理缺字情况，完美支持中英文混排。
- **完备的交互**:
  - **输入法支持**: 使用 SDL2 文本输入 API，支持 fcitx5 等中文输入法。
  - **智能选择**: 支持双击选词、三击选行、语义化单词边界。
  - **剪贴板**: 无缝集成系统剪贴板 (SDL2 CLIPBOARD)。
  - **URL 交互**: 自动检测 URL，支持 Ctrl+点击 打开。
  - **鼠标支持**: 完整支持 SGR 1006 鼠标模式，完美兼容 vim/tmux 鼠标操作。

## 🚀 快速开始

### 1. 环境要求

- **Zig**: 0.15.2 或更新版本
- **SDL2 开发库**: SDL2, SDL2_ttf
- **字体库**: FreeType, HarfBuzz, FontConfig

### 2. 安装依赖

**Debian/Ubuntu:**
```bash
sudo apt install libsdl2-dev libsdl2-ttf-dev libfreetype-dev libharfbuzz-dev libfontconfig1-dev pkg-config
```

**Arch Linux:**
```bash
sudo pacman -S sdl2 sdl2_ttf freetype2 harfbuzz fontconfig pkg-config
```

**Fedora:**
```bash
sudo dnf install SDL2-devel SDL2_ttf-devel freetype-devel harfbuzz-devel fontconfig-devel pkgconfig
```

### 3. 编译与运行

```bash
# 克隆仓库
git clone https://github.com/wertasy/stz
cd stz

# 编译 (Debug 模式)
zig build

# 运行
./zig-out/bin/stz

# 或者直接编译运行
zig build run

# 编译 (Release 模式，性能更佳)
zig build -Doptimize=ReleaseFast
```

## ⌨️ 快捷键

默认快捷键配置（可在 `src/config.zig` 中修改）：

| 快捷键 | 功能 |
|--------|------|
| `Ctrl + Shift + C` | 复制到系统剪贴板 |
| `Ctrl + Shift + V` | 从系统剪贴板粘贴 |
| `Shift + PgUp` | 向上滚动历史 |
| `Shift + PgDn` | 向下滚动历史 |
| `Ctrl + Click` | 打开鼠标下的 URL |
| `Shift + Print` | 打印屏幕内容 |

## 🛠️ 项目结构

```
stz/
├── build.zig           # 构建脚本 (链接 SDL2/HarfBuzz)
├── src/
│   ├── main.zig        # 入口与主事件循环
│   ├── terminal.zig    # 终端状态机与屏幕缓冲区
│   ├── parser.zig      # ANSI/VT100 转义序列解析
│   ├── renderer.zig    # SDL2_ttf/HarfBuzz 渲染器
│   ├── window.zig      # SDL2 窗口管理
│   ├── pty.zig         # 伪终端进程控制
│   ├── input.zig       # 键盘/鼠标输入处理
│   ├── selection.zig   # 文本选择与剪贴板管理
│   ├── boxdraw.zig     # 自定义制表符绘制逻辑
│   ├── url.zig         # URL 检测引擎
│   ├── sdl2_utils.zig  # SDL2 辅助函数
│   └── config.zig      # 编译期配置文件
└── tests/              # 单元测试
```

## 🧩 配置

`stz` 采用编译期配置（这也是 suckless 的哲学）。修改 `src/config.zig` 后需重新编译。

```zig
// src/config.zig 示例
pub const font = "Maple Mono NF CN:pixelsize=18"; // 字体设置
pub const term_type = "xterm-256color";           // TERM 环境变量
pub const colors = ...;                           // 调色板配置
```

## 📈 开发状态

虽然 stz 已经具备了日常使用的能力，但仍有一些高级特性正在开发中：

- [ ] 窗口透明度 (Transparency)
- [ ] 字体动态缩放 (Zoom)
- [ ] 视觉/听觉响铃 (Bell)

详细计划请参阅 [TODO.md](TODO.md)。

## 🤝 贡献

欢迎提交 Issue 或 Pull Request！
在开始之前，请阅读 [AGENTS.md](AGENTS.md) 了解开发规范和代码风格。

---

**stz** - Modern, Fast, Simple.
Based on [st](https://st.suckless.org/). Powered by [Zig](https://ziglang.org/).
