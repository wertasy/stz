# stz 开发计划 (TODO)

## ✅ 已完成功能

- [x] **行尾宽字符**: 优化宽字符在行边界处的自动换行行为
- [x] **字体回退增强**: 完善 Xft 备用字体搜索逻辑，提升 CJK 兼容性
- [x] **单词吸附**: 鼠标双击选中单词，三击选中整行功能
- [x] **CSI 冒号参数**: 支持 `1:2:3` 格式的子参数解析 (用于扩展颜色/样式)
- [x] **构建系统**: Zig build system (build.zig) 配置完成
- [x] **X11 窗口**: 基本 X11 窗口创建和事件循环
- [x] **PTY**: 伪终端创建、Fork、Exec 和 I/O 重定向
- [x] **ANSI 解析**: 状态机解析 VT100/VT220 转义序列 (包括私有模式处理)
- [x] **Xft 渲染**: 使用 FreeType/Xft 进行字体渲染 (支持 UTF-8)
- [x] **双缓冲**: 使用 X11 Pixmap 防止闪烁
- [x] **基本输入**: 键盘字符输入和简单控制键映射
- [x] **键盘输入完善**:
    - [x] 完整的功能键映射 (F1-F12, Home, End, PageUp, PageDown)
    - [x] 组合键支持 (Ctrl/Alt/Shift + Key)
    - [x] Keypad 模式支持 (支持 Application Keypad 和 Numeric Keypad)
- [x] **渲染优化**:
    - [x] 脏矩形优化 (目前全屏重绘)
    - [x] 粗体/斜体/下划线样式渲染 (支持 Bold 颜色, Underline, Reverse, Strikethrough)
    - [x] 宽字符 (CJK) 渲染对其问题修复 (`wcwidth` 逻辑修正)
    - [x] Box Drawing 字符手动绘制 (无需字体支持，扩展到双线、重线)
- [x] **字体处理**:
    - [x] 字体回退 (Fallback) 机制 (Config -> Default -> Fixed)
- [x] **剪贴板与选择**:
    - [x] 鼠标左键拖拽选择文本
    - [x] X11 PRIMARY Selection 支持
    - [x] 中键粘贴 (Middle click paste)
    - [x] 释放鼠标时自动复制到剪贴板
- [x] **控制序列修复**:
    - [x] BS/CR/LF/HT 处理 (解决双重回显和光标错位)
    - [x] CSI 参数解析修复 (支持 `?` 私有模式)
- [x] **滚动缓冲区 (Scrollback)**: 支持历史输出存储和 Shift+PgUp/PgDn 查看历史
- [x] **Resize 处理**:
    - [x] 滑动屏幕以保持光标位置
    - [x] 优化 resize 时的重绘逻辑
    - [x] PTY resize 通知
 - [x] **鼠标支持**:
      - [x] 鼠标点击报告 (X10, URXVT, SGR pixel mode 1006)
      - [x] 鼠标滚轮滚动
 - [x] **URL 点击打开**:
      - [x] URL 自动检测（http://, https://, ftp://）
      - [x] Ctrl+点击打开 URL（通过 xdg-open）
 - [x] **打印/导出功能**:
      - [x] 打印屏幕内容（Shift+Print - printscreen）
      - [x] 打印选择内容（Print - printsel）
      - [x] 切换自动打印模式（Ctrl+Print - toggleprinter）
 - [x] **光标特性**:
      - [x] 完整的光标样式支持 (Block, Underline, Bar, Hollow)
      - [x] 光标闪烁逻辑 (MODE_BLINK)
      - [x] 文本闪烁属性 (ATTR_BLINK)
      - [x] 焦点状态处理 (MODE_FOCUSED)
 - [x] **TrueColor**: 24 位真彩色支持

## 🚧 待完善 / 技术债 (Technical Debt)

本节列出了代码分析中发现的与 st 原生行为不一致或实现不完整的部分。

### 核心功能差距
- [ ] **IME 输入法支持**: 虽然已调用 `XOpenIM`/`XCreateIC`，但主事件循环缺失 `XFilterEvent`，导致无法在终端内输入中文。
- [ ] **OSC 52 剪贴板**: Parser 已实现 Base64 解码，但缺失将数据传递给 X11 `setSelection` 的管道 (Plumbing)，导致远程复制功能失效。
- [ ] **OSC 104 颜色重置**: 实现过于粗暴，目前强制重置整个调色板，不支持通过参数重置特定索引的颜色。

### 高级特性
- [ ] **透明度 (Alpha Channel)**: X11 Alpha 通道支持待实现。

### 代码质量
- [ ] **测试**: 增加单元测试覆盖率 (Parser, Screen)
- [ ] **文档**: 完善模块文档注释
- [ ] **错误处理**: 完善 Parser 与底层模块的错误传播机制

## 已知问题

1. **Resize 闪烁**: 调整窗口大小时可能会有短暂的黑屏或闪烁。
2. **IME**: 无法激活输入法。
