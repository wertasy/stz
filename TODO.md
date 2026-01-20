# stz 开发计划 (TODO)

## 核心待办事项 (High Priority)

### 功能补全 (Gaps)
- [ ] **响铃 (Bell)**: 实现 `XBell` 支持 (Visual/Audible bell)，处理 `Ctrl+G` (BEL)。
- [ ] **字体缩放**: 实现 `ZoomIn` / `ZoomOut` / `ZoomReset` 逻辑。
  - 快捷键已在 `config.zig` 定义 (Ctrl+Shift+PgUp/PgDn)，但 `main.zig` 未处理。
- [ ] **透明度 (Transparency)**: 窗口透明度支持 (Alpha Channel)。
  - `window.zig` 中需配置 32-bit visual。
- [ ] **OSC 104 部分支持**: 目前 OSC 104 强制重置整个调色板，不支持按索引重置特定颜色。

### 缺陷修复 (Bugs)
- [ ] **Resize 闪烁**: 调整窗口大小时可能有短暂黑屏 (Known Issue)。

### 测试与质量
- [ ] 增加单元测试覆盖率 (Parser, Terminal 逻辑)。
- [ ] 完善错误处理和日志 (消除 `catch unreachable` 或未处理的 `void` 返回)。

## 已完成功能 (Completed Features)

> 核心功能已稳定，可满足日常使用。

### 终端核心
- [x] **VT100/VT220 兼容**: 完整支持 ANSI 转义序列、光标移动、SGR 属性。
- [x] **UTF-8 / CJK**: 完美支持多字节字符、宽字符渲染、G0-G3 字符集切换。
- [x] **TrueColor**: 24位真彩色支持 (SGR 38/48;2)。
- [x] **Box Drawing**: 内置手动绘制逻辑，不依赖字体即可完美绘制制表符。

### 交互体验
- [x] **输入法 (IME)**: XIM/XIC 集成，支持 fcitx5 等中文输入法。
- [x] **鼠标支持**: 点击、滚动、SGR 1006 扩展模式。
- [x] **文本选择**: 双击选词、三击选行、自动吸附、跨行选择。
- [x] **剪贴板**: 支持 PRIMARY (选中即复制) 和 CLIPBOARD (Ctrl+Shift+C/V)。
- [x] **URL 检测**: 自动识别 URL，Ctrl+点击 打开。

### 性能与架构
- [x] **双缓冲 (Double Buffering)**: 使用 Pixmap 彻底解决渲染撕裂。
- [x] **渲染优化**: 脏行检测 (Dirty rects)、XFlush 替代 XSync、Glyph 缓存。
- [x] **模块化**: 清晰分离 Parser, Terminal, Renderer, Window, PTY 模块。
- [x] **HarfBuzz**: 集成文本整形库，支持连字 (Ligatures)。
- [x] **打印/导出**: 支持屏幕内容导出 (Printer)。
