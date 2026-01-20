# stz - 简单终端模拟器 (Zig 实现)

[![Zig](https://img.shields.io/badge/Zig-0.15.2-blue.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

stz 是使用 Zig 语言重写的 st (simple terminal) 终端模拟器。

> ⚠️ **开发状态**: 核心功能（PTY、VT100解析、X11渲染）已工作，但处于早期开发阶段，存在输入处理不完善等问题。

## ✨ 特性

### 已实现 ✅

 - ✅ **X11 后端**: 使用 Xlib 和 Xft 进行窗口管理和字体渲染
 - ✅ **VT100/VT220 支持**: 解析 ANSI 转义序列，支持光标移动、颜色、文本属性等
 - ✅ **UTF-8 支持**: 正确处理 UTF-8 编码字符和宽字符
 - ✅ **PTY 集成**: 与 shell 进程的伪终端通信
 - ✅ **基本输入**: 支持普通字符和部分控制键输入
 - ✅ **模块化架构**: 职责清晰的模块划分 (Terminal, Screen, Parser, Renderer, PTY)
 - ✅ **URL 点击**: 自动检测并点击打开 URL（Ctrl+点击）
 - ✅ **打印/导出**: 支持打印屏幕和选择内容（Print/Shift+Print）

### 待实现 ⚠️

详见 [TODO.md](TODO.md)。

## 🚀 快速开始

### 环境要求

- **Zig**: 0.15.2
- **X11**: libX11, libXft
- **FontConfig/FreeType**: 用于字体管理
- **C 编译器**: 用于编译 C 依赖

### 安装依赖

```bash
# Ubuntu/Debian
sudo apt install libx11-dev libxft-dev libfontconfig1-dev libfreetype-dev pkg-config

# Fedora/RHEL
sudo dnf install libX11-devel libXft-devel fontconfig-devel freetype-devel pkgconfig

# Arch Linux
sudo pacman -S libx11 libxft fontconfig freetype2 pkg-config
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
├── AGENTS.md              # AI 代理开发指南
├── README.md              # 项目文档
├── TODO.md               # 待完成任务清单
└── src/
    ├── main.zig          # 主程序入口和事件循环
    └── modules/
        ├── config.zig    # 配置管理
        ├── types.zig     # 核心数据类型
        ├── x11.zig       # X11 C API 绑定
        ├── window.zig    # X11 窗口管理
        ├── renderer.zig  # Xft 字符渲染
        ├── input.zig     # 键盘输入处理
        ├── terminal.zig  # 终端逻辑核心
        ├── screen.zig    # 屏幕缓冲区
        ├── parser.zig    # ANSI 转义序列解析
        ├── pty.zig       # PTY 管理
        ├── unicode.zig   # UTF-8 工具
        ├── selection.zig # 文本选择
        └── printer.zig  # 打印/导出功能
```

## ⚙️ 配置

配置选项在 `src/modules/config.zig` 中定义：

- **字体**: 默认 "Monospace:pixelsize=20"
- **窗口**: 默认 120x35
- **颜色**: 支持标准 256 色和 24 位真彩色

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！请先查看 [TODO.md](TODO.md) 和 [AGENTS.md](AGENTS.md)。

---

**stz** - Zig 编写的现代 st 实现
🔗 相关链接: [st](https://st.suckless.org/) | [Zig](https://ziglang.org/)
