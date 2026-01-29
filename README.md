# stz - 简单终端模拟器 (Zig 实现)

[![Zig](https://img.shields.io/badge/Zig-0.15.2-blue.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

stz 是使用 Zig 语言重写的 [st](https://st.suckless.org/) (simple terminal) 终端模拟器。

> **开发状态**: 核心功能已完成，可日常使用。

## 特性

### 已实现

- **X11 后端**: Xlib 窗口管理 + Xft/FreeType 字体渲染
- **VT100/VT220 支持**: ANSI 转义序列解析，支持光标移动、颜色、文本属性
- **UTF-8 支持**: 正确处理多字节字符和宽字符 (CJK)
- **输入法支持**: XIM/XIC 集成，支持中文输入
- **PTY 集成**: 与 shell 进程的伪终端通信
- **键盘输入**: 完整的功能键映射 (F1-F12, Home, End, PageUp, PageDown)、组合键、Keypad 模式
- **鼠标支持**: 点击报告 (X10, URXVT, SGR 1006)、滚轮滚动、拖拽选择
- **文本选择**: 鼠标拖选、双击选词、三击选行、X11 PRIMARY/CLIPBOARD 支持
- **滚动缓冲区**: 历史输出存储，Shift+PgUp/PgDn 查看历史
- **URL 点击**: 自动检测 URL，Ctrl+点击打开
- **打印/导出**: 打印屏幕 (Shift+Print)、打印选择 (Print)、切换自动打印 (Ctrl+Print)
- **Box Drawing**: 内置制表符绘制，支持单线、双线、重线、Braille 点阵
- **光标样式**: Block、Underline、Bar、Hollow，支持闪烁
- **TrueColor**: 24 位真彩色支持
- **字体回退**: 主字体缺失字符时自动使用备用字体
- **双缓冲**: Pixmap 离屏渲染，避免闪烁
- **HarfBuzz**: 连字 (Ligature) 支持

### 待实现

详见 [TODO.md](TODO.md)。

## 与 st 的差异

- **Box Drawing**: 内置手动绘制制表符逻辑，不依赖字体
- **模块化**: 代码拆分为多个职责单一的 Zig 模块
- **HarfBuzz**: 集成 HarfBuzz 支持连字渲染

## 快速开始

### 环境要求

- **Zig**: 0.15.2
- **X11**: libX11, libXft
- **FontConfig/FreeType**: 字体管理
- **HarfBuzz**: 文本整形
- **C 编译器**: 编译 C 依赖

### 安装依赖

```bash
# Ubuntu/Debian
sudo apt install libx11-dev libxft-dev libfontconfig1-dev libfreetype-dev libharfbuzz-dev pkg-config

# Fedora/RHEL
sudo dnf install libX11-devel libXft-devel fontconfig-devel freetype-devel harfbuzz-devel pkgconfig

# Arch Linux
sudo pacman -S libx11 libxft fontconfig freetype2 harfbuzz pkg-config
```

### 编译

```bash
git clone https://github.com/wertasy/stz
cd stz

# 编译
zig build

# 运行
./zig-out/bin/stz
# 或
zig build run
```

### 测试

```bash
# 运行所有测试
zig build test --summary all

# 运行特定测试
zig build test --filter "Parser"
zig build test --filter "Selection"
```

## 项目结构

```
stz/
├── build.zig           # Zig 构建配置
├── AGENTS.md           # AI 代理开发指南
├── README.md           # 项目文档
├── TODO.md             # 待完成任务清单
├── src/
│   ├── main.zig        # 主程序入口和事件循环
│   ├── config.zig      # 配置管理（字体、颜色、快捷键）
│   ├── types.zig       # 核心数据类型（Glyph, GlyphAttr, Mode 等）
│   ├── terminal.zig    # 终端逻辑核心（字符写入、光标、滚动）
│   ├── parser.zig      # ANSI 转义序列解析（CSI, OSC, DCS）
│   ├── x11.zig         # X11 C API 绑定
│   ├── window.zig      # X11 窗口管理（创建、事件、双缓冲）
│   ├── renderer.zig    # Xft 字符渲染（字体、颜色、光标）
│   ├── renderer_utils.zig # 渲染辅助函数
│   ├── input.zig       # 键盘输入处理
│   ├── pty.zig         # PTY 管理（fork、exec、I/O）
│   ├── selection.zig   # 文本选择和剪贴板
│   ├── unicode.zig     # UTF-8 编解码和字符宽度
│   ├── boxdraw.zig     # 框线字符绘制
│   ├── boxdraw_data.zig # 框线字符数据表
│   ├── url.zig         # URL 检测和打开
│   ├── printer.zig     # 打印/导出功能
│   ├── ft.zig          # FreeType2 C API 绑定
│   ├── parser_test.zig # Parser 单元测试
│   ├── selection_test.zig # Selection 单元测试
│   ├── unicode_test.zig # Unicode 单元测试
│   └── ternimal_test.zig # Terminal 单元测试
└── tests/
    └── window_title_test.zig # 窗口标题测试
```

## 配置

配置选项在 `src/config.zig` 中定义：

- **字体**: 默认 "Maple Mono NF CN:pixelsize=18"，支持回退字体列表
- **窗口**: 默认 120x35，可配置边框像素
- **颜色**: 标准 256 色 + 24 位真彩色
- **光标**: 样式、粗细、闪烁间隔
- **快捷键**: Shift+PgUp/PgDn 滚动、Ctrl+Shift+V 粘贴、Print 打印

## 贡献

欢迎提交 Issue 和 Pull Request！请先查看 [TODO.md](TODO.md) 和 [AGENTS.md](AGENTS.md)。

---

**stz** - Zig 编写的现代 st 实现

相关链接: [st](https://st.suckless.org/) | [Zig](https://ziglang.org/)
